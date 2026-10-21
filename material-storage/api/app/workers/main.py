"""arq worker entrypoint。

启动:
  arq app.workers.main.WorkerSettings

tasks:
  - generate_thumbnail(asset_id):图片 → Pillow thumbnail 1024 → MinIO thumbnails/
  - generate_video_thumbnail(asset_id):视频 → ffmpeg 抽帧 → MinIO thumbnails/(B-4 iter2, #101)
  - generate_livp_thumbnail(asset_id):iOS Live Photo(.livp = zip)→ 静态图 thumbnail
    + 实况短片 H.264 转码(实况预览)
  - generate_livp_download(asset_id):livp 下载级解包(全分辨率 JPG + 全长 H.264 MP4
    组 zip 上传主桶 derivatives/{id}/livp.zip;timeout=300/max_tries=2 per-function
    覆盖,livp-download-unpack 方案 §2)
  - generate_batch_download_zip(user_id, job_token, asset_ids, bucket, key):PC 批量
    下载单 zip 异步打包(timeout=1800/max_tries=1,livp-download-unpack 方案 §6.2)
  - cleanup_batch_zips:cron 每 10 分钟清 derivatives/batch/ 超龄(>6h)批量包
    (形态粗筛 + Metadata kind 删除守卫;per-cron timeout=300,方案 §6.3)
  - mark_expired_approvals:cron 扫已过期 approval,改 status
  - baidu_backup_run(task_id, expected_seq):百度网盘备份导入(方案 §6;per-function
    timeout=3600/max_tries=1 —— 不设 48h 级超时,in-progress TTL 按全部 function 的
    最大超时计算;55min 接力模式续跑)
  - sweep_stalled_baidu_tasks:cron 扫无租约/派发超时的百度任务(per-cron timeout=300),
    急停 flag/cancel_requested/48h 感知 + 接管派发 + 30d 孤儿清理

启动钩子:on_startup 校验百度备份配置(validate_baidu_settings;worker 不跑 api
lifespan,不校验则非法配置带病运行到首次使用才炸)
"""
from __future__ import annotations

import asyncio
import contextlib
import io
import logging
import re
import threading
import uuid
import zipfile
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import boto3
from arq.connections import RedisSettings
from botocore.client import Config
from PIL import Image, ImageOps

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
    # 同步阻塞段(boto3 / Pillow)一律 asyncio.to_thread:arq 的 max_jobs 是单事件
    # 循环协程数,同步阻塞体会冻结整个 worker —— 在跑的百度任务 5s 租约续期停摆,
    # 被 sweeper 误判接管(livp-download-unpack 方案 §2.2 顺带项,不改行为)
    await asyncio.to_thread(_ensure_thumbnail_bucket, thumb_s3, settings)
    thumb_bucket = settings.minio_thumbnail_bucket

    try:
        # 1-3) 拉原图 + Pillow 缩放编码(同步阻塞段整体丢线程池)
        def _produce() -> tuple[bytes, int, int]:
            buf = io.BytesIO()
            s3.download_fileobj(bucket, src_key, buf)
            buf.seek(0)
            img = Image.open(buf)
            # 兼容 EXIF orientation(手机拍照常用)
            with contextlib.suppress(Exception):
                img = ImageOps.exif_transpose(img)
            # RGBA / P / L → 转 RGB(JPEG 需要)
            if img.mode not in ("RGB", "L"):
                img = img.convert("RGB")
            img.thumbnail((_THUMBNAIL_MAX_PX, _THUMBNAIL_MAX_PX), Image.Resampling.LANCZOS)
            out = io.BytesIO()
            img.save(out, format="JPEG", quality=_THUMBNAIL_QUALITY, optimize=True)
            return out.getvalue(), img.width, img.height

        thumbnail_bytes, img_w, img_h = await asyncio.to_thread(_produce)
        thumbnail_size = len(thumbnail_bytes)

        # 4) 上传(ADR-0008 P1:走缩略图 MinIO + 独立 bucket)
        thumbnail_key = f"thumbnails/{asset_id}.jpg"
        await asyncio.to_thread(
            thumb_s3.put_object,
            Bucket=thumb_bucket,
            Key=thumbnail_key,
            Body=io.BytesIO(thumbnail_bytes),
            ContentType="image/jpeg",
            Metadata={"source_asset": asset_id, "max_px": str(_THUMBNAIL_MAX_PX)},
        )
        log.info("thumbnail generated asset=%s bucket=%s key=%s size=%d w=%d h=%d",
                 asset_id, thumb_bucket, thumbnail_key, thumbnail_size, img_w, img_h)
    except Exception as e:
        log.exception("thumbnail fail asset=%s err=%s", asset_id, e)
        await _merge_asset_tags(sm, aid, sets={"thumbnail_failed": _thumb_fail_token(e)})
        return {"status": "failed", "asset_id": asset_id, "error": str(e)[:200]}

    # 5) 更新 db(jsonb_set 单条 UPDATE 原子合并 —— 双 writer 防线,§2.2 第 7 步)
    await _merge_asset_tags(
        sm, aid,
        sets={
            "thumbnail_key": thumbnail_key,
            "thumbnail_size_bytes": thumbnail_size,
            "thumbnail_width": img_w,
            "thumbnail_height": img_h,
        },
        removes=("thumbnail_failed",),
    )

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
        # endswith 判类而非 Path.suffix:点文件('.jpg' 空基名条目)的 suffix
        # 是 '' 会被判无扩展名 → 静态图挑不出 → 缩略图失败
        # (2026-10-20 iOS 真机 livp 上送 '.jpg'/'.mov' 条目实锤)
        name = info.filename.lower()
        if name.endswith(_LIVP_IMAGE_EXTS) and info.file_size <= _LIVP_IMAGE_MAX_BYTES and (
            still is None or info.file_size > still.file_size
        ):
            still = info
        elif name.endswith(_LIVP_VIDEO_EXTS) and info.file_size <= _LIVP_VIDEO_MAX_BYTES and (
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


async def _merge_asset_tags(
    sm: Any,
    aid: uuid.UUID,
    sets: dict[str, Any],
    removes: tuple[str, ...] = (),
) -> None:
    """tags 单条 UPDATE 原子合并:`UPDATE assets SET tags = jsonb_set(tags - 'x', '{k}', :v)`。

    双 writer 防线(livp-download-unpack 方案 §2.2 第 7 步 / §9 必做项):livp 下载
    job 与三族缩略图 job 在上传/百度导入派发点并排入队,并发写同一 tags 列 —— 旧
    「读-改-写」整列回写会把对方刚落的 key 覆盖丢失;jsonb_set / jsonb '-' 让合并
    收敛在 PG 单条 UPDATE 行内,后写者保留先写者的 key。sets 逐 key 套 jsonb_set;
    removes 逐 key 用 '-' 删除(jsonb_set 塞 'null' 只会留下 null 键,删不干净)。
    行不存在(并发 hard purge)时 UPDATE 零行,静默 no-op(与旧 db.get 判空同语义)。
    """
    from sqlalchemy import TEXT, func, literal, update
    from sqlalchemy.dialects.postgresql import ARRAY, JSONB

    expr: Any = Asset.tags
    for key in removes:
        expr = expr.op("-")(key)
    for key, value in sets.items():
        if key in removes:
            raise ValueError(f"tags 同 key 同时 set 与 remove:{key}")
        expr = func.jsonb_set(
            expr,
            literal([key], type_=ARRAY(TEXT())),
            literal(value, type_=JSONB),
        )
    async with sm() as db:
        await db.execute(update(Asset).where(Asset.id == aid).values(tags=expr))
        await db.commit()


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
    # 同步阻塞段(boto3 / zip 解压 / Pillow / subprocess)一律 asyncio.to_thread
    #(livp-download-unpack 方案 §2.2 顺带项:最坏 = 200MB 拉取 + ffmpeg 45s,已逼近
    # 百度 60s 租约;冻结事件循环会让在跑百度任务的 5s 租约续期停摆被 sweeper 接管)
    await asyncio.to_thread(_ensure_thumbnail_bucket, thumb_s3, settings)

    import tempfile
    tmpdir = Path(tempfile.mkdtemp(prefix=f"livp-{asset_id}-"))
    zip_path = tmpdir / "in.livp"
    vid_in_path = tmpdir / "live.mov"
    vid_out_path = tmpdir / "live.mp4"
    thumbnail_key = f"thumbnails/{asset_id}.jpg"
    live_key = f"previews/{asset_id}_live.mp4"
    thumbnail_size = 0
    try:
        await asyncio.to_thread(s3.download_file, bucket, src_key, str(zip_path))

        def _produce_still() -> tuple[bytes, int, int, bool]:
            """静态图 → 1024 JPEG(同步阻塞段:zip 解压 + Pillow 解码,线程池执行)。

            返回 (jpeg 字节, 宽, 高, 是否有实况条目)。"""
            with zipfile.ZipFile(zip_path) as zf:
                still_info, video_info = _pick_livp_entries(zf)
                if still_info is None:
                    raise RuntimeError("livp 内未找到静态图条目(jpg/heic/png)")
                # 解压带真实流硬上限(声明值可伪造,F4)
                with zf.open(still_info) as f:
                    still_bytes = _read_livp_entry_capped(f, _LIVP_IMAGE_MAX_BYTES)
            img = Image.open(io.BytesIO(still_bytes))
            with contextlib.suppress(Exception):
                img = ImageOps.exif_transpose(img)
            if img.mode not in ("RGB", "L"):
                img = img.convert("RGB")
            img.thumbnail((_THUMBNAIL_MAX_PX, _THUMBNAIL_MAX_PX),
                          Image.Resampling.LANCZOS)
            out = io.BytesIO()
            img.save(out, format="JPEG", quality=_THUMBNAIL_QUALITY, optimize=True)
            return out.getvalue(), img.width, img.height, video_info is not None

        thumb_bytes, img_w, img_h, has_video = await asyncio.to_thread(_produce_still)
        thumbnail_size = len(thumb_bytes)
        await asyncio.to_thread(
            thumb_s3.put_object,
            Bucket=settings.minio_thumbnail_bucket,
            Key=thumbnail_key,
            Body=io.BytesIO(thumb_bytes),
            ContentType="image/jpeg",
            Metadata={"source_asset": asset_id, "kind": "livp_still"},
        )

        # 2) 静态图先落库(jsonb_set 原子合并;转码失败不影响照片预览)
        await _merge_asset_tags(
            sm, aid,
            sets={
                "thumbnail_key": thumbnail_key,
                "thumbnail_size_bytes": thumbnail_size,
                "thumbnail_width": img_w,
                "thumbnail_height": img_h,
            },
            removes=("thumbnail_failed",),
        )

        # 3) 实况短片转码(best-effort:解压超限 / HEVC 解码缺失 / ffmpeg 失败
        #    → 仅无实况,静态图已落库,不误标 thumbnail_failed)
        if has_video:
            try:
                def _produce_video() -> int | None:
                    """解出实况条目 + 转码(同步阻塞段:解压落盘 + ffmpeg subprocess)。"""
                    with zipfile.ZipFile(zip_path) as zf:
                        _, video_info = _pick_livp_entries(zf)
                        if video_info is None:
                            return None
                        with zf.open(video_info) as f:  # noqa: ASYNC230
                            _copy_livp_entry(f, vid_in_path, _LIVP_VIDEO_MAX_BYTES)
                    if not _transcode_live_video(
                        vid_in_path, vid_out_path, _LIVP_FFMPEG_TIMEOUT_SEC,
                    ):
                        return None
                    return vid_out_path.stat().st_size

                live_size = await asyncio.to_thread(_produce_video)
                if live_size is not None:
                    with vid_out_path.open("rb") as f:  # noqa: ASYNC230
                        await asyncio.to_thread(
                            thumb_s3.put_object,
                            Bucket=settings.minio_thumbnail_bucket,
                            Key=live_key,
                            Body=f,
                            ContentType="video/mp4",
                            Metadata={"source_asset": asset_id, "kind": "livp_video"},
                        )
                    await _merge_asset_tags(
                        sm, aid,
                        sets={"live_video_key": live_key, "live_video_size_bytes": live_size},
                    )
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
            "live_video": has_video,
        }
    except Exception as e:
        log.exception("livp thumbnail fail asset=%s err=%s", asset_id, e)
        await _merge_asset_tags(sm, aid, sets={"thumbnail_failed": _thumb_fail_token(e)})
        return {"status": "failed", "asset_id": asset_id, "error": str(e)[:200]}
    finally:
        import shutil as _shutil
        with contextlib.suppress(Exception):  # noqa: ASYNC240
            _shutil.rmtree(tmpdir, ignore_errors=True)


# ─── livp 下载级解包(livp-download-unpack 方案 §2)───────────────────────────
# 下载级规格:全分辨率 JPG + 全长 H.264 MP4 组 zip(预览级是 1024px q80 / 截 3s)
_LIVP_DL_JPEG_QUALITY = 90
_LIVP_DL_FFMPEG_TIMEOUT_SEC = 120                # 须低于本 job timeout=300(§2.1 核算)
# 静态图解码段显式调高 Pillow DecompressionBomb 守卫:预览链路依赖默认值(~1.78 亿
# 像素),合法超大全景图会被它判死且归入「解码失败=永久失败」;下载级要放行,防滥用
# 由 livp 200MB 入口上限兜。只在解码段内抬高并恢复(§2.2 第 3 步),不放大预览链路
# 的守卫口径。⚠ MAX_IMAGE_PIXELS 是模块级全局:并发 livp job 的解码段跑在不同
# to_thread 线程,裸「捕获→抬高→finally 恢复」会互踩(B 捕获到 A 已抬高的值,A 先
# 退出恢复默认,B 后退出把全局恢复成 6 亿 —— 预览链路守卫被永久放大,同 worker 进程
# 的缩略图链路守卫随之失守)。故用模块级锁串行化解码段(单 job 解码互不依赖吞吐,
# 串行无代价):锁内严格「进抬退恢复」,锁外任何时刻全局值恒为默认
_LIVP_DL_MAX_IMAGE_PIXELS = 600_000_000
_LIVP_DECODE_LOCK = threading.Lock()

# §2.3 zip 内名清洗:Windows 非法字符(含控制字符)与保留设备名
_LIVP_DL_ILLEGAL_CHARS = re.compile(r'[<>:"/\\|?*\x00-\x1f]')
_LIVP_DL_RESERVED_NAMES = frozenset({
    "CON", "PRN", "AUX", "NUL",
    *(f"COM{i}" for i in range(1, 10)),
    *(f"LPT{i}" for i in range(1, 10)),
})


class _LivpDownloadPermanentError(RuntimeError):
    """livp 下载 zip 的永久失败(重派注定同结果):无静态图条目 / 静态图处理失败。"""


def _livp_download_base_name(filename: str, asset_id: str) -> str:
    """zip 内条目基名(§2.3,纯函数):去 .livp 尾缀(大小写不敏感)→ Windows 非法
    字符/控制字符换 _ → 去尾部点/空格(「名字.」「名字 」资源管理器解压同样出错)
    → 保留设备名加 _(含带扩展名形态:Windows 保留名判的是首个点之前的首段)→
    清洗后空串回落 asset_{id 前 8 位}。非 ASCII(中文)保留 —— zipfile 对非 ASCII
    条目名自动打 UTF-8 flag,Win10+ 资源管理器正确解出。"""
    base = filename[: -len(".livp")] if filename.lower().endswith(".livp") else filename
    base = _LIVP_DL_ILLEGAL_CHARS.sub("_", base)
    base = base.rstrip(". ")
    stem, dot, ext = base.partition(".")
    if stem.upper() in _LIVP_DL_RESERVED_NAMES:
        base = f"{stem}_{dot}{ext}"
    if not base:
        base = f"asset_{asset_id.replace('-', '')[:8]}"
    return base


def _encode_livp_still_jpeg(still_bytes: bytes) -> bytes:
    """HEIC/PNG 静态图 → 下载级全分辨率 JPEG(纯函数,只碰内存字节)。

    - exif_transpose 转正像素;**EXIF 取 transpose 返回对象自带的 exif** —— 必须是
      已剥除 orientation 标签的 EXIF,带原 orientation 落盘会让 Windows 查看器二次
      旋转(Pillow 各版本此处行为有差异,以单测钉住,pillow==12.3.0 实测已剥);
    - ICC 原样保留(防 P3 色偏);只传 ICC 不传 EXIF 会丢拍摄时间等元数据,「高效」
      iPhone 恰是本方案主场景(§2.2 第 3 步);
    - RGBA/P 透明区贴白底合成(裸 convert("RGB") 会把 alpha 丢成黑底);
    - DecompressionBomb 守卫解码段内抬高、退出恢复(见 _LIVP_DL_MAX_IMAGE_PIXELS);
      全局抬抬落落经 _LIVP_DECODE_LOCK 串行,并发 job 的解码段互斥,预览链路守卫
      口径不受影响。
    """
    with _LIVP_DECODE_LOCK:
        prev_cap = Image.MAX_IMAGE_PIXELS
        Image.MAX_IMAGE_PIXELS = _LIVP_DL_MAX_IMAGE_PIXELS
        try:
            img = Image.open(io.BytesIO(still_bytes))
            img = ImageOps.exif_transpose(img)
            if img.mode not in ("RGB", "L"):
                if img.mode in ("RGBA", "LA", "P") or "transparency" in img.info:
                    rgba = img.convert("RGBA")
                    bg = Image.new("RGB", rgba.size, (255, 255, 255))
                    bg.paste(rgba, mask=rgba.getchannel("A"))
                    img = bg
                else:
                    img = img.convert("RGB")
            save_kwargs: dict[str, Any] = {
                "quality": _LIVP_DL_JPEG_QUALITY, "optimize": True,
            }
            icc = img.info.get("icc_profile")
            if icc:
                save_kwargs["icc_profile"] = icc
            # transpose 返回对象自带的 exif(已剥 orientation);无则不传(老客户端
            # 无元数据可丢,好过一个带原 orientation 的 EXIF)
            exif_bytes = img.info.get("exif")
            if exif_bytes:
                save_kwargs["exif"] = exif_bytes
            out = io.BytesIO()
            img.save(out, format="JPEG", **save_kwargs)
            return out.getvalue()
        finally:
            Image.MAX_IMAGE_PIXELS = prev_cap


def _transcode_livp_video_download(in_path: Path, out_path: Path, timeout: int) -> bool:
    """实况短片下载规格全转码(§2.2 第 4 步):去掉预览链路的 scale=1024 与 -t 3,
    加 -pix_fmt yuv420p(防 10-bit HEVC 源产出播放器不认的 10-bit H.264)。
    失败(超时 / ffmpeg 非零 / HEVC 解码缺失)返回 False,调用方降级「仅 jpg 的 zip」。
    """
    import subprocess
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error",
        "-i", str(in_path),
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "21",
        "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-b:a", "128k",
        "-movflags", "+faststart",
        "-y", str(out_path),
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return False
    return proc.returncode == 0 and out_path.exists() and out_path.stat().st_size > 0


def _build_livp_download_zip(
    out_path: Path,
    photo_path: Path,
    video_path: Path | None,
    base_name: str,
) -> int:
    """组下载 zip(纯函数,只碰本地文件;单测钉内名 / 降级形态 / 压缩口径)。

    内名 {基名}.jpg + {基名}.mp4(无视频条目则仅 jpg —— 视频转码失败降级交付);
    ZIP_STORED:jpg/mp4 均为已压缩数据,deflate 只白烧 CPU 不减体积(§2.2 第 5 步)。
    返回 zip 字节数。
    """
    with zipfile.ZipFile(out_path, "w", compression=zipfile.ZIP_STORED) as zf:
        zf.write(photo_path, arcname=f"{base_name}.jpg")
        if video_path is not None:
            zf.write(video_path, arcname=f"{base_name}.mp4")
    return out_path.stat().st_size


async def generate_livp_download(ctx: dict, asset_id: str) -> dict[str, Any]:
    """livp 下载级解包(§2):全分辨率 JPG + 全长 H.264 MP4 组 zip,上传主桶
    derivatives/{asset_id}/livp.zip,tags 落 download_zip_key / download_zip_size_bytes
    (jsonb_set 原子合并)。

    失败分级(自愈回路的关键,§2.2 第 7 步):
      - 永久(无静态图条目 / 静态图处理失败 / 超限,guard 落)→ download_zip_failed
        落库后正常 return(arq 不重试;§3 的 404 自愈见 tag 有值不重派);
      - 瞬时(MinIO/网络异常、超时)→ 不落 tag,只留日志 + re-raise(arq 按
        max_tries=2 重试),404 自愈按 600s 频控自然重派 —— 落了就把资产挡在自愈
        回路外;
      - 视频转码失败不是 job 失败:降级「仅 jpg 的 zip」,落 download_zip_video_failed
        时间戳供观测(对齐预览链路 best-effort 口径)。
    阻塞段(拉源/解包/解码/转码/组 zip/上传)全部 asyncio.to_thread —— arq 的
    max_jobs 是单事件循环协程数,同步阻塞体会冻结整个 worker(§2.2 铁律)。
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
            # 超 200MB 防御上限 = 永久失败(重派注定同结果):落 tag 挡住 404 自愈重派
            await _merge_asset_tags(sm, aid, sets={"download_zip_failed": "oversize"})
            return {"status": "skip_too_large", "size_bytes": asset.size_bytes}
        bucket = asset.minio_bucket
        src_key = asset.minio_key
        base_name = _livp_download_base_name(asset.filename or "", asset_id)

    s3 = boto3.client(
        "s3",
        endpoint_url=settings.minio_endpoint_internal,
        aws_access_key_id=settings.minio_access_key,
        aws_secret_access_key=settings.minio_secret_key,
        config=Config(signature_version="s3v4", region_name="us-east-1"),
    )

    import tempfile
    tmpdir = Path(tempfile.mkdtemp(prefix=f"livpdl-{asset_id}-"))
    zip_path = tmpdir / "in.livp"
    zip_out = tmpdir / "download.zip"
    try:
        def _produce() -> tuple[int, str | None]:
            """同步阻塞段:拉源 → 解包 → 静态图 → 视频 best-effort 转码 → 组 zip。

            返回 (zip 字节数, download_zip_video_failed 时间戳 | None)。"""
            s3.download_file(bucket, src_key, str(zip_path))
            photo_path = tmpdir / "photo"
            video_src = tmpdir / "live.src"
            video_out = tmpdir / "live.mp4"
            video_failed: str | None = None
            with zipfile.ZipFile(zip_path) as zf:
                still_info, video_info = _pick_livp_entries(zf)
                if still_info is None:
                    raise _LivpDownloadPermanentError(
                        "livp 内未找到静态图条目(jpg/heic/png)")
                # 静态图:JPG 原字节透传(零重压缩损失,EXIF 原样保留);HEIC/PNG
                # 转下载级 JPEG —— 处理失败(损坏/超限)是确定性失败 → 永久
                try:
                    with zf.open(still_info) as f:
                        still_bytes = _read_livp_entry_capped(f, _LIVP_IMAGE_MAX_BYTES)
                    if still_info.filename.lower().endswith((".jpg", ".jpeg")):
                        photo_path.write_bytes(still_bytes)
                    else:
                        photo_path.write_bytes(_encode_livp_still_jpeg(still_bytes))
                except _LivpDownloadPermanentError:
                    raise
                except Exception as e:
                    raise _LivpDownloadPermanentError(
                        f"静态图处理失败({type(e).__name__})") from e
                # 视频:全规格转码 best-effort(失败降级「仅 jpg 的 zip」,不判 job 失败)
                if video_info is not None:
                    try:
                        with zf.open(video_info) as f:
                            _copy_livp_entry(f, video_src, _LIVP_VIDEO_MAX_BYTES)
                        if not _transcode_livp_video_download(
                            video_src, video_out, _LIVP_DL_FFMPEG_TIMEOUT_SEC,
                        ):
                            video_failed = datetime.now(UTC).isoformat()
                    except Exception:
                        video_failed = datetime.now(UTC).isoformat()
            has_video = video_failed is None and video_out.exists()
            return (
                _build_livp_download_zip(
                    zip_out, photo_path, video_out if has_video else None, base_name,
                ),
                video_failed,
            )

        zip_size, video_failed_ts = await asyncio.to_thread(_produce)

        # 上传主桶(HDD 实例,与原片同 bucket;同 key 覆盖写,重跑幂等)
        dl_key = f"derivatives/{asset_id}/livp.zip"

        def _upload() -> None:
            with zip_out.open("rb") as f:
                s3.put_object(
                    Bucket=bucket, Key=dl_key, Body=f,
                    ContentType="application/zip",
                    Metadata={"source_asset": asset_id, "kind": "livp_download_zip"},
                )

        await asyncio.to_thread(_upload)
    except _LivpDownloadPermanentError as e:
        log.warning("livp download permanent fail asset=%s err=%s", asset_id, e)
        await _merge_asset_tags(
            sm, aid, sets={"download_zip_failed": _thumb_fail_token(e)},
        )
        return {"status": "failed_permanent", "asset_id": asset_id, "error": str(e)[:200]}
    except BaseException as e:
        # 瞬时失败不落 download_zip_failed,只留日志。except BaseException:arq
        # timeout 走 wait_for 取消,except Exception 捕不到 CancelledError(§2.2
        # 第 7 步);留日志后必须 re-raise 交给 arq 计 retry(max_tries=2)
        log.exception("livp download transient fail asset=%s err=%r", asset_id, e)
        raise
    finally:
        import shutil as _shutil
        with contextlib.suppress(Exception):
            _shutil.rmtree(tmpdir, ignore_errors=True)

    # 成功落 tags(jsonb_set 原子合并):key / size,删 download_zip_failed;全成功
    # 时顺带清掉旧的 video 降级观测标记(再降级会重新落)
    sets: dict[str, Any] = {
        "download_zip_key": dl_key,
        "download_zip_size_bytes": zip_size,
    }
    removes = ["download_zip_failed"]
    if video_failed_ts is not None:
        sets["download_zip_video_failed"] = video_failed_ts
    else:
        removes.append("download_zip_video_failed")
    await _merge_asset_tags(sm, aid, sets=sets, removes=tuple(removes))
    log.info("livp download zip asset=%s bucket=%s key=%s size=%d video_degraded=%s",
             asset_id, bucket, dl_key, zip_size, video_failed_ts is not None)
    return {
        "status": "ok", "asset_id": asset_id,
        "download_zip_key": dl_key, "size_bytes": zip_size,
        "video_degraded": video_failed_ts is not None,
    }


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
    # 同步阻塞段(boto3 / subprocess)一律 asyncio.to_thread(livp-download-unpack
    # 方案 §2.2 顺带项,不改行为 —— 冻结事件循环会让百度 5s 租约续期停摆被接管)
    await asyncio.to_thread(_ensure_thumbnail_bucket, thumb_s3, settings)
    thumb_bucket = settings.minio_thumbnail_bucket

    tmpdir = pathlib.Path(tempfile.mkdtemp(prefix=f"vthumb-{asset_id}-"))
    in_path = tmpdir / "in.bin"
    out_path = tmpdir / "out.jpg"
    thumbnail_size = 0
    try:
        # 1) 先拉头部 ~10MB(关键帧通常在前几秒;faststart 文件 moov 也在头部)
        def _fetch_head() -> None:
            resp = s3.get_object(Bucket=bucket, Key=src_key,
                                 Range=f"bytes=0-{_VIDEO_HEAD_RANGE - 1}")
            with open(in_path, "wb") as f:
                for chunk in resp["Body"].iter_chunks(chunk_size=1024 * 1024):
                    f.write(chunk)

        await asyncio.to_thread(_fetch_head)

        # 2) ffmpeg 抽帧(subprocess 同步阻塞,同批 to_thread 化)
        ok = await asyncio.to_thread(
            _extract_video_frame, in_path, out_path, _FFMPEG_TIMEOUT_SEC,
        )

        # 2b) #135 fallback:头部抽帧失败 + 文件可能比头部大 → 拉完整文件重试。
        #     moov box 在文件尾部(iOS / 屏录 / ffmpeg 默认输出)时,头部 10MB 不含 moov
        #     → demux fail。size_bytes None 视为"可能很大"一并 fallback。已被上面 50MB cap 兜住,
        #     fallback 最多拉 50MB。faststart 文件头部就成功,不进此路径,无性能回归。
        if not ok and (asset_size is None or asset_size > _VIDEO_HEAD_RANGE):
            log.info("video thumbnail head-fail, fallback to full file asset=%s size=%s",
                     asset_id, asset_size)
            await asyncio.to_thread(s3.download_file, bucket, src_key, str(in_path))
            ok = await asyncio.to_thread(
                _extract_video_frame, in_path, out_path, _FFMPEG_TIMEOUT_SEC,
            )

        if not ok:
            raise RuntimeError("ffmpeg failed to extract frame (head + full fallback)")

        thumbnail_size = out_path.stat().st_size

        # 3) 上传(ADR-0008 P1:走缩略图 MinIO + 独立 bucket)
        thumbnail_key = f"thumbnails/{asset_id}.jpg"
        with open(out_path, "rb") as f:
            await asyncio.to_thread(
                thumb_s3.put_object,
                Bucket=thumb_bucket,
                Key=thumbnail_key,
                Body=f,
                ContentType="image/jpeg",
                Metadata={"source_asset": asset_id, "kind": "video_frame"},
            )
        log.info("video thumbnail asset=%s bucket=%s key=%s size=%d",
                 asset_id, thumb_bucket, thumbnail_key, thumbnail_size)
    except subprocess.TimeoutExpired:
        log.warning("ffmpeg timeout asset=%s", asset_id)
        await _merge_asset_tags(sm, aid, sets={"thumbnail_failed": "ffmpeg_timeout"})
        return {"status": "failed", "asset_id": asset_id, "error": "ffmpeg_timeout"}
    except Exception as e:
        # log.exception:thumbnail_failed 只存类型名(F5),完整 traceback 是唯一排查入口
        log.exception("video thumbnail fail asset=%s err=%s", asset_id, e)
        await _merge_asset_tags(sm, aid, sets={"thumbnail_failed": _thumb_fail_token(e)})
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

    # 4) 更新 db(jsonb_set 单条 UPDATE 原子合并 —— 双 writer 防线,§2.2 第 7 步)
    await _merge_asset_tags(
        sm, aid,
        sets={
            "thumbnail_key": thumbnail_key,
            "thumbnail_size_bytes": thumbnail_size,
            "thumbnail_kind": "video_frame",
        },
        removes=("thumbnail_failed",),
    )

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
from arq.worker import func  # noqa: E402

from app.workers.baidu_backup import (  # noqa: E402
    baidu_backup_run,
    sweep_stalled_baidu_tasks,
)
from app.workers.batch_download import (  # noqa: E402
    cleanup_batch_zips,
    generate_batch_download_zip,
)

_CRON_JOBS = [
    cron(mark_expired_approvals, minute=set(range(0, 60, 5))),
    # 百度任务 sweeper(方案 §6):每 5min;per-cron timeout=300(低于百度任务
    # 的 3610s,不影响全局 in-progress TTL)
    cron(sweep_stalled_baidu_tasks, minute=set(range(0, 60, 5)), timeout=300),
    # 批量包清理(livp-download-unpack 方案 §6.3):每 10min;per-cron timeout=300;
    # list_buckets 迭代全部桶 + 形态粗筛 + Metadata kind 删除守卫
    cron(cleanup_batch_zips, minute=set(range(0, 60, 10)), timeout=300),
]


async def _validate_baidu_settings_on_startup(ctx: dict[str, Any]) -> None:
    """worker 启动钩子(arq on_startup):百度备份配置启动断言(传输容错方案 §3.4)。

    worker 进程不跑 api lifespan,现状 validate_baidu_settings 仅 api 启动时调用
    —— 本方案的部署形态恰是 worker-only 重启,不补校验则非法配置带病运行到首次
    使用才炸。on_startup 时点晚于模块导入(worker settings 单例已实例化)、早于
    首个 job,校验失败 arq 启动即报错,满足「不带病运行」。
    """
    get_settings().validate_baidu_settings()


class WorkerSettings:
    functions = [
        generate_thumbnail,
        generate_video_thumbnail,
        generate_livp_thumbnail,
        # livp 下载级解包:timeout=300/max_tries=2 per-function 覆盖(先例:百度任务
        # baidu_backup_run;全局 job_timeout=60 装不下全分辨率转码,300s = 200MB 拉源
        # + HEIC 全分辨率解码 + ffmpeg ≤120s + zip + 上传的核算余量,§2.1;max_tries
        # 显式设定,勿用 arq 默认 5 —— 瞬时失败一次重试,永久失败由 tag 挡住不重派)
        func(generate_livp_download, timeout=300, max_tries=2),
        mark_expired_approvals,
        # 百度备份导入(方案 §6):timeout=3600/max_tries=1 per-function 覆盖;
        # 55min 接力模式续跑,重试语义由自家状态机 + 租约接管实现
        func(baidu_backup_run, timeout=3600, max_tries=1),
        # 批量打包(livp-download-unpack 方案 §6.2):timeout=1800/max_tries=1 ——
        # 自动重试会与端点 retry:true 手动通道叠加(try-2 自动派发时用户已点重试
        # 清标记入新队,两个 10GB 级 job 并发双跑、双跑 finally 还会互相误删锁);
        # 重试语义统一交给手动通道,瞬时失败由用户一次重试恢复
        func(generate_batch_download_zip, timeout=1800, max_tries=1),
    ]
    cron_jobs = _CRON_JOBS
    # crons 别名:arq 本体只认 cron_jobs;契约测试按 WorkerSettings.crons 读取,
    # 同一列表两个名字,零行为差异
    crons = _CRON_JOBS
    on_startup = _validate_baidu_settings_on_startup
    redis_settings = _build_redis_settings()
    # 并发方案 §3.2/§3.3:百度准入并发 2→4 后 max_jobs 4→8(4 百度槽 + ≥4 缩略图
    # /cron 槽,不动会把缩略图挤饿);Settings 参数化,env 可调(改后须 force-
    # recreate ms-worker,restart 不重读 env_file)
    max_jobs = get_settings().worker_max_jobs
    job_timeout = 60
    keep_result = 300
