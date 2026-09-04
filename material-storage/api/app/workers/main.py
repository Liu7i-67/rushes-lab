"""arq worker entrypoint。

启动:
  arq app.workers.main.WorkerSettings

tasks:
  - generate_thumbnail(asset_id):图片 → Pillow thumbnail 1024 → MinIO thumbnails/
  - generate_video_thumbnail(asset_id):视频 → ffmpeg 抽帧 → MinIO thumbnails/(B-4 iter2, #101)
  - generate_livp_thumbnail(asset_id):iOS Live Photo(.livp = zip)→ 静态图 thumbnail
    + 实况短片 H.264 转码(实况预览)
  - mark_expired_approvals:cron 扫已过期 approval,改 status
"""
from __future__ import annotations

import contextlib
import io
import logging
import uuid
import zipfile
from pathlib import Path
from typing import Any

import boto3
from arq.connections import RedisSettings
from botocore.client import Config
from PIL import Image

from app.db.session import get_sessionmaker
from app.db.tables import Asset
from app.settings import get_settings

log = logging.getLogger("worker")

# pillow-heif 可选:livp 内的静态图在「高效」格式 iPhone 上是 HEIC。
# 缺依赖时 JPEG/PNG 静态图仍可处理,HEIC 单独失败并记 thumbnail_failed
try:
    from pillow_heif import register_heif_opener  # type: ignore[import-untyped]
    register_heif_opener()
except ImportError:  # pragma: no cover
    log.warning("pillow_heif 不可用,HEIC 静态图的 livp 预览将失败")

# image content_types we handle
_IMAGE_PREFIXES = ("image/",)
_THUMBNAIL_MAX_PX = 1024
_THUMBNAIL_QUALITY = 80


def _thumb_s3_client(settings: Any) -> Any:
    """缩略图上传用 S3 client(ADR-0008 P1:内部 endpoint 指 SSD 缩略图 MinIO;
    留空回落主 MinIO = 降级模式)。worker 在 docker 内,走内部 endpoint。"""
    return boto3.client(
        "s3",
        endpoint_url=settings.minio_thumbnail_endpoint_internal or settings.minio_endpoint_internal,
        aws_access_key_id=settings.minio_access_key,
        aws_secret_access_key=settings.minio_secret_key,
        config=Config(signature_version="s3v4", region_name="us-east-1"),
    )


def _ensure_thumbnail_bucket(s3: Any, settings: Any) -> None:
    """确保缩略图 bucket 存在(新 MinIO 实例无 bucket;head/create 幂等)。"""
    from botocore.exceptions import ClientError  # type: ignore[import-untyped]
    try:
        s3.head_bucket(Bucket=settings.minio_thumbnail_bucket)
    except ClientError as e:
        if e.response["Error"]["Code"] in ("404", "NoSuchBucket"):
            s3.create_bucket(Bucket=settings.minio_thumbnail_bucket)
            log.info("thumbnail bucket %s created", settings.minio_thumbnail_bucket)
        else:
            raise


async def generate_thumbnail(ctx: dict, asset_id: str) -> dict[str, Any]:
    """图片缩略图生成。

    流程:
      1. db 查 asset(content_type / minio_bucket / minio_key)
      2. content_type 不 image/* → skip
      3. boto3 download_fileobj 原图
      4. Pillow open + thumbnail(1024)+ JPEG quality=80
      5. 上传 thumbnails/{asset_id}.jpg
      6. db assets.tags['thumbnail_key'] 写入
      7. 失败 → tags['thumbnail_failed'] = reason(便于排查)
    """
    settings = get_settings()
    sm = get_sessionmaker()
    aid = uuid.UUID(asset_id)

    async with sm() as db:
        asset = await db.get(Asset, aid)
        if asset is None:
            return {"status": "asset_not_found", "asset_id": asset_id}
        if asset.deleted_at is not None:
            return {"status": "asset_deleted", "asset_id": asset_id}
        if not asset.content_type or not asset.content_type.startswith(_IMAGE_PREFIXES):
            return {"status": "skip_non_image", "content_type": asset.content_type}

        bucket = asset.minio_bucket
        src_key = asset.minio_key

    # MinIO client(internal endpoint — worker 在 docker 内)
    s3 = boto3.client(
        "s3",
        endpoint_url=settings.minio_endpoint_internal,
        aws_access_key_id=settings.minio_access_key,
        aws_secret_access_key=settings.minio_secret_key,
        config=Config(signature_version="s3v4", region_name="us-east-1"),
    )
    # ADR-0008 P1:缩略图上传目标 = 缩略图 MinIO(SSD)+ 独立 bucket(回落 = 主实例)
    thumb_s3 = _thumb_s3_client(settings)
    _ensure_thumbnail_bucket(thumb_s3, settings)
    thumb_bucket = settings.minio_thumbnail_bucket

    try:
        # 1) 拉原图(内存)
        buf = io.BytesIO()
        s3.download_fileobj(bucket, src_key, buf)
        buf.seek(0)

        # 2) Pillow 处理
        img = Image.open(buf)
        # 兼容 EXIF orientation(手机拍照常用)
        try:
            from PIL import ImageOps
            img = ImageOps.exif_transpose(img)
        except Exception:  # noqa: BLE001
            pass
        # RGBA / P / L → 转 RGB(JPEG 需要)
        if img.mode not in ("RGB", "L"):
            img = img.convert("RGB")
        img.thumbnail((_THUMBNAIL_MAX_PX, _THUMBNAIL_MAX_PX), Image.Resampling.LANCZOS)

        # 3) 编码 JPEG
        out = io.BytesIO()
        img.save(out, format="JPEG", quality=_THUMBNAIL_QUALITY, optimize=True)
        out.seek(0)
        thumbnail_size = out.getbuffer().nbytes

        # 4) 上传(ADR-0008 P1:走缩略图 MinIO + 独立 bucket)
        thumbnail_key = f"thumbnails/{asset_id}.jpg"
        thumb_s3.put_object(
            Bucket=thumb_bucket, Key=thumbnail_key, Body=out,
            ContentType="image/jpeg",
            Metadata={"source_asset": asset_id, "max_px": str(_THUMBNAIL_MAX_PX)},
        )
        log.info("thumbnail generated asset=%s bucket=%s key=%s size=%d w=%d h=%d",
                 asset_id, thumb_bucket, thumbnail_key, thumbnail_size, img.width, img.height)
    except Exception as e:
        log.exception("thumbnail fail asset=%s err=%s", asset_id, e)
        async with sm() as db:
            a = await db.get(Asset, aid)
            if a:
                tags = dict(a.tags or {})
                tags["thumbnail_failed"] = _thumb_fail_token(e)
                a.tags = tags
                await db.commit()
        return {"status": "failed", "asset_id": asset_id, "error": str(e)[:200]}

    # 5) 更新 db
    async with sm() as db:
        a = await db.get(Asset, aid)
        if a:
            tags = dict(a.tags or {})
            tags["thumbnail_key"] = thumbnail_key
            tags["thumbnail_size_bytes"] = thumbnail_size
            tags["thumbnail_width"] = img.width
            tags["thumbnail_height"] = img.height
            tags.pop("thumbnail_failed", None)
            a.tags = tags
            await db.commit()

    return {
        "status": "ok", "asset_id": asset_id,
        "thumbnail_key": thumbnail_key, "size_bytes": thumbnail_size,
    }


_VIDEO_PREFIXES = ("video/",)
_VIDEO_THUMBNAIL_MAX_BYTES = 50 * 1024 * 1024   # 50MB cap pilot(ROADMAP §63 风险段)
_VIDEO_HEAD_RANGE = 10 * 1024 * 1024            # 只拉头部 10MB 给 ffmpeg 用,避免大文件拉全
_FFMPEG_TIMEOUT_SEC = 30                         # subprocess 硬上限

# ─── livp(iOS Live Photo)────────────────────────────────────────────────────
# .livp 实为 zip:内含静态图(IMG_x.JPG.jpeg / .HEIC)+ 实况短片(IMG_x.JPG.mov)。
# 浏览器不识别该格式 → 上传侧按扩展名分派本 worker;预览 = 静态图缩略图 + 转码短片
_LIVP_IMAGE_EXTS = (".jpg", ".jpeg", ".heic", ".heif", ".png")
_LIVP_VIDEO_EXTS = (".mov", ".mp4")
_LIVP_MAX_BYTES = 200 * 1024 * 1024             # 防御上限:正常 livp 几 MB~几十 MB
# 解压后条目大小上限(zip 元数据可伪造,超限条目直接忽略)。静态图走内存 +
# Pillow DecompressionBomb 守卫,视频走磁盘解压 —— 无上限时恶意 zip(全零高
# 压缩比 ~1000:1)可把 200MB 包解出上百 GB 写满 worker 磁盘。iPhone 真实量级
# ~2-10MB,这里放两个数量级冗余
_LIVP_IMAGE_MAX_BYTES = 100 * 1024 * 1024
_LIVP_VIDEO_MAX_BYTES = 500 * 1024 * 1024
_LIVP_VIDEO_SECS = 3                            # Live Photo 实况约 3s,转码截断到同长
_LIVP_FFMPEG_TIMEOUT_SEC = 45                    # 需低于 WorkerSettings.job_timeout(60)
_LIVP_COPY_CHUNK = 1024 * 1024


def _pick_livp_entries(zf: zipfile.ZipFile) -> tuple[zipfile.ZipInfo | None, zipfile.ZipInfo | None]:
    """从 livp zip 里挑(最大静态图, 最大视频)条目;超大小上限的条目跳过。

    取最大而非首个:iPhone 导出可能带同名多份或小占位文件;条目名形如
    IMG_1234.JPG.jpeg / IMG_1234.mov,扩展名判类。file_size 是 zip 中央目录
    元数据(攻击者可控),只用作初筛 —— 真实落盘量由 _copy_livp_entry 计数兜底。
    """
    still: zipfile.ZipInfo | None = None
    video: zipfile.ZipInfo | None = None
    for info in zf.infolist():
        if info.is_dir():
            continue
        ext = Path(info.filename).suffix.lower()
        if ext in _LIVP_IMAGE_EXTS and info.file_size <= _LIVP_IMAGE_MAX_BYTES and (
            still is None or info.file_size > still.file_size
        ):
            still = info
        elif ext in _LIVP_VIDEO_EXTS and info.file_size <= _LIVP_VIDEO_MAX_BYTES and (
            video is None or info.file_size > video.file_size
        ):
            video = info
    return still, video


def _copy_livp_entry(src: Any, dst_path: Path, max_bytes: int) -> None:
    """zip 条目流式落盘,带硬性字节上限(声明值可再伪造,超限即断)。"""
    written = 0
    with dst_path.open("wb") as f:  # noqa: ASYNC230
        while True:
            chunk = src.read(_LIVP_COPY_CHUNK)
            if not chunk:
                return
            written += len(chunk)
            if written > max_bytes:
                raise RuntimeError(
                    f"livp 条目解压超上限(>{max_bytes} bytes,疑似异常文件)"
                )
            f.write(chunk)


def _read_livp_entry_capped(src: Any, max_bytes: int) -> bytes:
    """zip 条目全量读入内存,带硬性字节上限(静态图路径;与 _copy_livp_entry
    同款兜底 —— zip 声明的 file_size 可伪造,真实流计数才作数)。"""
    out = bytearray()
    while True:
        chunk = src.read(_LIVP_COPY_CHUNK)
        if not chunk:
            return bytes(out)
        out += chunk
        if len(out) > max_bytes:
            raise RuntimeError(
                f"livp 条目解压超上限(>{max_bytes} bytes,疑似异常文件)"
            )


def _thumb_fail_token(e: BaseException) -> str:
    """tags['thumbnail_failed'] 的入库值 —— 只存异常类型名:完整报错可能含
    容器内部路径,而该字段随 AssetOut 下发给能列到资产的用户(F5);
    排查细节看 worker 日志(有完整 traceback)。"""
    return type(e).__name__[:64]


def _transcode_live_video(in_path: Path, out_path: Path, timeout: int) -> bool:
    """实况短片 → H.264 MP4(浏览器兼容;原片多为 HEVC,Chrome 常放不了)。

    截 _LIVP_VIDEO_SECS + faststart(边下边播);失败返回 False,由调用方跳过
    实况部分(静态图缩略图不受影响)。
    """
    import subprocess
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error",
        "-i", str(in_path), "-t", str(_LIVP_VIDEO_SECS),
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
        "-vf", "scale=1024:-2",
        "-c:a", "aac", "-b:a", "96k",
        "-movflags", "+faststart",
        "-y", str(out_path),
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return False
    return proc.returncode == 0 and out_path.exists() and out_path.stat().st_size > 0


async def generate_livp_thumbnail(ctx: dict, asset_id: str) -> dict[str, Any]:
    """livp 预览生成:静态图缩略图(必做)+ 实况短片转码(best-effort)。

    产物(缩略图 MinIO / SSD):
      - thumbnails/{asset_id}.jpg   ← 静态图,复用通用缩略图链路(tags.thumbnail_key)
      - previews/{asset_id}_live.mp4 ← 实况短片,经
        GET /assets/{id}/live-preview-url 签发(走 can_download enforce)
    """
    settings = get_settings()
    sm = get_sessionmaker()
    aid = uuid.UUID(asset_id)

    async with sm() as db:
        asset = await db.get(Asset, aid)
        if asset is None:
            return {"status": "asset_not_found", "asset_id": asset_id}
        if asset.deleted_at is not None:
            return {"status": "asset_deleted", "asset_id": asset_id}
        if not (asset.filename or "").lower().endswith(".livp"):
            return {"status": "skip_not_livp", "filename": asset.filename}
        if asset.size_bytes and asset.size_bytes > _LIVP_MAX_BYTES:
            return {"status": "skip_too_large", "size_bytes": asset.size_bytes}
        bucket = asset.minio_bucket
        src_key = asset.minio_key

    s3 = boto3.client(
        "s3",
        endpoint_url=settings.minio_endpoint_internal,
        aws_access_key_id=settings.minio_access_key,
        aws_secret_access_key=settings.minio_secret_key,
        config=Config(signature_version="s3v4", region_name="us-east-1"),
    )
    thumb_s3 = _thumb_s3_client(settings)
    _ensure_thumbnail_bucket(thumb_s3, settings)

    import tempfile
    tmpdir = Path(tempfile.mkdtemp(prefix=f"livp-{asset_id}-"))
    zip_path = tmpdir / "in.livp"
    vid_in_path = tmpdir / "live.mov"
    vid_out_path = tmpdir / "live.mp4"
    thumbnail_key = f"thumbnails/{asset_id}.jpg"
    live_key = f"previews/{asset_id}_live.mp4"
    thumbnail_size = 0
    try:
        s3.download_file(bucket, src_key, str(zip_path))

        with zipfile.ZipFile(zip_path) as zf:
            still_info, video_info = _pick_livp_entries(zf)
            if still_info is None:
                raise RuntimeError("livp 内未找到静态图条目(jpg/heic/png)")

            # 1) 静态图 → 1024 JPEG(与 generate_thumbnail 同规格);解压带真实
            #    流硬上限(声明值可伪造,F4)
            with zf.open(still_info) as f:
                still_bytes = _read_livp_entry_capped(f, _LIVP_IMAGE_MAX_BYTES)
            img = Image.open(io.BytesIO(still_bytes))
            with contextlib.suppress(Exception):
                from PIL import ImageOps
                img = ImageOps.exif_transpose(img)
            if img.mode not in ("RGB", "L"):
                img = img.convert("RGB")
            img.thumbnail((_THUMBNAIL_MAX_PX, _THUMBNAIL_MAX_PX),
                          Image.Resampling.LANCZOS)
            out = io.BytesIO()
            img.save(out, format="JPEG", quality=_THUMBNAIL_QUALITY, optimize=True)
            out.seek(0)
            thumbnail_size = out.getbuffer().nbytes
            thumb_s3.put_object(
                Bucket=settings.minio_thumbnail_bucket, Key=thumbnail_key, Body=out,
                ContentType="image/jpeg",
                Metadata={"source_asset": asset_id, "kind": "livp_still"},
            )

            # 2) 静态图先落库(转码失败不影响照片预览)
            async with sm() as db:
                a = await db.get(Asset, aid)
                if a:
                    tags = dict(a.tags or {})
                    tags["thumbnail_key"] = thumbnail_key
                    tags["thumbnail_size_bytes"] = thumbnail_size
                    tags["thumbnail_width"] = img.width
                    tags["thumbnail_height"] = img.height
                    tags.pop("thumbnail_failed", None)
                    a.tags = tags
                    await db.commit()

            # 3) 实况短片转码(best-effort:解压超限 / HEVC 解码缺失 / ffmpeg 失败
            #    → 仅无实况,静态图已落库,不误标 thumbnail_failed)
            if video_info is not None:
                try:
                    with zf.open(video_info) as f:  # noqa: ASYNC230
                        _copy_livp_entry(f, vid_in_path, _LIVP_VIDEO_MAX_BYTES)
                    if _transcode_live_video(
                        vid_in_path, vid_out_path, _LIVP_FFMPEG_TIMEOUT_SEC,
                    ):
                        live_size = vid_out_path.stat().st_size
                        with vid_out_path.open("rb") as f:  # noqa: ASYNC230
                            thumb_s3.put_object(
                                Bucket=settings.minio_thumbnail_bucket, Key=live_key, Body=f,
                                ContentType="video/mp4",
                                Metadata={"source_asset": asset_id, "kind": "livp_video"},
                            )
                        async with sm() as db:
                            a = await db.get(Asset, aid)
                            if a:
                                tags = dict(a.tags or {})
                                tags["live_video_key"] = live_key
                                tags["live_video_size_bytes"] = live_size
                                a.tags = tags
                                await db.commit()
                        log.info("livp live video asset=%s key=%s size=%d",
                                 asset_id, live_key, live_size)
                    else:
                        log.warning(
                            "livp live transcode fail asset=%s(跳过实况,静态图已生成)",
                            asset_id)
                except Exception as e:  # noqa: BLE001
                    log.warning("livp live extract/transcode fail asset=%s err=%s"
                                "(跳过实况,静态图已生成)", asset_id, e)
        return {
            "status": "ok", "asset_id": asset_id,
            "thumbnail_key": thumbnail_key, "size_bytes": thumbnail_size,
            "live_video": video_info is not None,
        }
    except Exception as e:
        log.exception("livp thumbnail fail asset=%s err=%s", asset_id, e)
        async with sm() as db:
            a = await db.get(Asset, aid)
            if a:
                tags = dict(a.tags or {})
                tags["thumbnail_failed"] = _thumb_fail_token(e)
                a.tags = tags
                await db.commit()
        return {"status": "failed", "asset_id": asset_id, "error": str(e)[:200]}
    finally:
        import shutil as _shutil
        with contextlib.suppress(Exception):  # noqa: ASYNC240
            _shutil.rmtree(tmpdir, ignore_errors=True)


def _extract_video_frame(in_path: Any, out_path: Any, timeout: int) -> bool:
    """ffmpeg 抽 1 帧:先试 1s(避首帧黑屏)再兜底 0s。出非空 jpg 返 True,否则 False。

    subprocess.TimeoutExpired 不在此吞掉,交给调用方统一处理(走 ffmpeg_timeout 兜底)。
    head + fallback 两条路径都调本 helper,保证 fallback 也享受 1s/0s 双重试(#135)。
    """
    import subprocess
    for ss in ("1", "0"):
        cmd = [
            "ffmpeg", "-hide_banner", "-loglevel", "error",
            "-ss", ss, "-i", str(in_path),
            "-frames:v", "1", "-vf", "scale=1024:-2",
            "-q:v", "3", "-y", str(out_path),
        ]
        proc = subprocess.run(cmd, capture_output=True, timeout=timeout)
        if proc.returncode == 0 and out_path.exists() and out_path.stat().st_size > 0:
            return True
    return False


async def generate_video_thumbnail(ctx: dict, asset_id: str) -> dict[str, Any]:
    """视频缩略图生成(B-4 iter2, issue #101)。

    流程:
      1. db 查 asset(content_type / size / minio_bucket / minio_key)
      2. content_type 不 video/* → skip
      3. size > 50MB → skip(pilot;后续 deferred queue)
      4. boto3 get_object Range bytes=0-{HEAD_RANGE} 流式拉头部 → /tmp/<aid>.bin
      5. ffmpeg -ss 1 -i in -frames:v 1 -vf scale=1024:-1 out.jpg
         (-ss 1 抽 1s 帧,避开首帧黑屏;若 duration<1s 兜底 -ss 0)
      6. 上传 thumbnails/{asset_id}.jpg + 写 asset.tags.thumbnail_key
      7. 失败兜底 tags['thumbnail_failed']
      finally: cleanup /tmp
    """
    import pathlib
    import subprocess
    import tempfile
    settings = get_settings()
    sm = get_sessionmaker()
    aid = uuid.UUID(asset_id)

    async with sm() as db:
        asset = await db.get(Asset, aid)
        if asset is None:
            return {"status": "asset_not_found", "asset_id": asset_id}
        if asset.deleted_at is not None:
            return {"status": "asset_deleted", "asset_id": asset_id}
        if not asset.content_type or not asset.content_type.startswith(_VIDEO_PREFIXES):
            return {"status": "skip_non_video", "content_type": asset.content_type}
        if asset.size_bytes and asset.size_bytes > _VIDEO_THUMBNAIL_MAX_BYTES:
            return {
                "status": "skip_too_large",
                "size_bytes": asset.size_bytes,
                "cap": _VIDEO_THUMBNAIL_MAX_BYTES,
            }
        bucket = asset.minio_bucket
        src_key = asset.minio_key
        asset_size = asset.size_bytes  # #135: 判定是否需 fallback 拉完整文件(moov-at-end)

    s3 = boto3.client(
        "s3",
        endpoint_url=settings.minio_endpoint_internal,
        aws_access_key_id=settings.minio_access_key,
        aws_secret_access_key=settings.minio_secret_key,
        config=Config(signature_version="s3v4", region_name="us-east-1"),
    )
    # ADR-0008 P1:缩略图上传目标 = 缩略图 MinIO(SSD)+ 独立 bucket(回落 = 主实例)
    thumb_s3 = _thumb_s3_client(settings)
    _ensure_thumbnail_bucket(thumb_s3, settings)
    thumb_bucket = settings.minio_thumbnail_bucket

    tmpdir = pathlib.Path(tempfile.mkdtemp(prefix=f"vthumb-{asset_id}-"))
    in_path = tmpdir / "in.bin"
    out_path = tmpdir / "out.jpg"
    thumbnail_size = 0
    try:
        # 1) 先拉头部 ~10MB(关键帧通常在前几秒;faststart 文件 moov 也在头部)
        resp = s3.get_object(Bucket=bucket, Key=src_key,
                             Range=f"bytes=0-{_VIDEO_HEAD_RANGE - 1}")
        with open(in_path, "wb") as f:
            for chunk in resp["Body"].iter_chunks(chunk_size=1024 * 1024):
                f.write(chunk)

        # 2) ffmpeg 抽帧
        ok = _extract_video_frame(in_path, out_path, _FFMPEG_TIMEOUT_SEC)

        # 2b) #135 fallback:头部抽帧失败 + 文件可能比头部大 → 拉完整文件重试。
        #     moov box 在文件尾部(iOS / 屏录 / ffmpeg 默认输出)时,头部 10MB 不含 moov
        #     → demux fail。size_bytes None 视为"可能很大"一并 fallback。已被上面 50MB cap 兜住,
        #     fallback 最多拉 50MB。faststart 文件头部就成功,不进此路径,无性能回归。
        if not ok and (asset_size is None or asset_size > _VIDEO_HEAD_RANGE):
            log.info("video thumbnail head-fail, fallback to full file asset=%s size=%s",
                     asset_id, asset_size)
            s3.download_file(bucket, src_key, str(in_path))
            ok = _extract_video_frame(in_path, out_path, _FFMPEG_TIMEOUT_SEC)

        if not ok:
            raise RuntimeError("ffmpeg failed to extract frame (head + full fallback)")

        thumbnail_size = out_path.stat().st_size

        # 3) 上传(ADR-0008 P1:走缩略图 MinIO + 独立 bucket)
        thumbnail_key = f"thumbnails/{asset_id}.jpg"
        with open(out_path, "rb") as f:
            thumb_s3.put_object(
                Bucket=thumb_bucket, Key=thumbnail_key, Body=f,
                ContentType="image/jpeg",
                Metadata={"source_asset": asset_id, "kind": "video_frame"},
            )
        log.info("video thumbnail asset=%s bucket=%s key=%s size=%d",
                 asset_id, thumb_bucket, thumbnail_key, thumbnail_size)
    except subprocess.TimeoutExpired:
        log.warning("ffmpeg timeout asset=%s", asset_id)
        async with sm() as db:
            a = await db.get(Asset, aid)
            if a:
                tags = dict(a.tags or {})
                tags["thumbnail_failed"] = "ffmpeg_timeout"
                a.tags = tags
                await db.commit()
        return {"status": "failed", "asset_id": asset_id, "error": "ffmpeg_timeout"}
    except Exception as e:
        # log.exception:thumbnail_failed 只存类型名(F5),完整 traceback 是唯一排查入口
        log.exception("video thumbnail fail asset=%s err=%s", asset_id, e)
        async with sm() as db:
            a = await db.get(Asset, aid)
            if a:
                tags = dict(a.tags or {})
                tags["thumbnail_failed"] = _thumb_fail_token(e)
                a.tags = tags
                await db.commit()
        return {"status": "failed", "asset_id": asset_id, "error": str(e)[:200]}
    finally:
        # cleanup /tmp(无论成功失败)
        try:
            if in_path.exists():
                in_path.unlink()
            if out_path.exists():
                out_path.unlink()
            tmpdir.rmdir()
        except Exception:  # noqa: BLE001
            pass

    # 4) 更新 db
    async with sm() as db:
        a = await db.get(Asset, aid)
        if a:
            tags = dict(a.tags or {})
            tags["thumbnail_key"] = thumbnail_key
            tags["thumbnail_size_bytes"] = thumbnail_size
            tags["thumbnail_kind"] = "video_frame"
            tags.pop("thumbnail_failed", None)
            a.tags = tags
            await db.commit()

    return {
        "status": "ok", "asset_id": asset_id,
        "thumbnail_key": thumbnail_key, "size_bytes": thumbnail_size,
    }


async def mark_expired_approvals(ctx: dict) -> dict[str, Any]:
    """polish 3:扫 status='approved' 且 decided_at + duration < now 的 approval → expired。

    注:OpenFGA grant 本身因 non_expired_grant condition 已自动失效,
    这里只更新 status 字段让 UI 显示一致。
    """
    from datetime import datetime, timedelta, timezone

    from sqlalchemy import select, update

    from app.db.tables import ApprovalRequest

    sm = get_sessionmaker()
    now = datetime.now(timezone.utc)
    async with sm() as db:
        # 找候选(避免 SQL 表达式跨 dialect 复杂度,Python 侧 filter)
        stmt = select(ApprovalRequest).where(
            ApprovalRequest.status == "approved",
            ApprovalRequest.duration_seconds.is_not(None),
            ApprovalRequest.decided_at.is_not(None),
        )
        res = await db.execute(stmt)
        candidates = list(res.scalars())
        expired_ids = []
        for a in candidates:
            if a.decided_at is None or a.duration_seconds is None:
                continue
            expires_at = a.decided_at + timedelta(seconds=a.duration_seconds)
            if expires_at < now:
                expired_ids.append(a.id)
        if expired_ids:
            await db.execute(
                update(ApprovalRequest)
                .where(ApprovalRequest.id.in_(expired_ids))
                .values(status="expired")
            )
            await db.commit()
    log.info("mark_expired_approvals: scanned=%d expired=%d",
             len(candidates), len(expired_ids))
    return {"scanned": len(candidates), "expired": len(expired_ids)}


# ─── arq settings ────────────────────────────────────────────────────────────
def _build_redis_settings() -> RedisSettings:
    """从 settings.redis_url 解析(优先 env REDIS_URL)。"""
    from urllib.parse import urlparse
    settings = get_settings()
    url = urlparse(str(settings.redis_url))
    return RedisSettings(
        host=url.hostname or "localhost",
        port=url.port or 6379,
        database=int(url.path.lstrip("/") or 0),
        password=url.password,
    )


# cron schedule: 每 5min(/5 0..55)跑一次 mark_expired_approvals
from arq.cron import cron  # noqa: E402

_CRON_JOBS = [
    cron(mark_expired_approvals, minute=set(range(0, 60, 5))),
]


class WorkerSettings:
    functions = [
        generate_thumbnail,
        generate_video_thumbnail,
        generate_livp_thumbnail,
        mark_expired_approvals,
    ]
    cron_jobs = _CRON_JOBS
    redis_settings = _build_redis_settings()
    max_jobs = 4
    job_timeout = 60
    keep_result = 300
