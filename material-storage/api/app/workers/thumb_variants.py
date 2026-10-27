"""small(240px) 缩略图变体派生(thumb-variant 方案 §4 B1/B5)。

- derive_small_bytes(source):1024 产物字节 → Pillow thumbnail(240) LANCZOS →
  JPEG q80(纯同步函数,调用方负责 asyncio.to_thread 包裹)
- derive_and_put_small(asset_id, source):put thumbnails/{id}_s.jpg 到缩略图桶
  (SSD)+ _merge_asset_tags 写 thumbnail_small_key / thumbnail_small_size_bytes
- derive_small_thumbnail(ctx, asset_id):独立回补 job —— 读缩略图桶 1024 产物
  派生 small;源缺失 → {"status": "source_missing"}(backfill --mode derive-small
  派发;注册见 main.WorkerSettings,漏注册 = arq 出队即 JobExecutionFailed)

⚠ 本模块对 app.workers.main 只做函数体内延迟 import(main 在模块底部才 import
本模块,顶部互拉会成环)。三族 job 调 derive_and_put_small 必须独立 try/except
仅 log(失败隔离:不得影响 1024 主产物与 thumbnail_key tags,方案 §4 B1)。
同步铁律:boto3 / Pillow 段一律 asyncio.to_thread(arq max_jobs 是单事件循环
协程数,同步阻塞体会冻结整个 worker —— main.py 同款口径)。
"""
from __future__ import annotations

import asyncio
import contextlib
import io
import logging
import uuid
from typing import Any

from PIL import Image, ImageOps

from app.db.session import get_sessionmaker
from app.services.thumb_exts import THUMB_SMALL_MAX_PX
from app.settings import get_settings

log = logging.getLogger("worker")

_SMALL_JPEG_QUALITY = 80  # 与 1024 主产物同质量口径(main._THUMBNAIL_QUALITY)


def derive_small_bytes(source: bytes) -> bytes:
    """1024 缩略图字节 → small(240px) JPEG 字节。

    thumbnail((240,240)) 只缩不放(源小于 240 保持原尺寸);exif_transpose 转正
    (手机 EXIF orientation);非 RGB/L 转 RGB(JPEG 编码需要)。
    """
    # 显式注解 Image.Image:mypy 严格模式下 Image.open 的推断类型是 ImageFile,
    # 后续 exif_transpose/convert 赋回 Image 会被判不兼容(Pillow stubs 口径)
    img: Image.Image = Image.open(io.BytesIO(source))
    with contextlib.suppress(Exception):
        img = ImageOps.exif_transpose(img)
    if img.mode not in ("RGB", "L"):
        img = img.convert("RGB")
    img.thumbnail((THUMB_SMALL_MAX_PX, THUMB_SMALL_MAX_PX), Image.Resampling.LANCZOS)
    out = io.BytesIO()
    img.save(out, format="JPEG", quality=_SMALL_JPEG_QUALITY, optimize=True)
    return out.getvalue()


def _small_key(asset_id: str) -> str:
    """small 变体对象 key(与 1024 主产物同目录,`_s` 后缀)。"""
    return f"thumbnails/{asset_id}_s.jpg"


async def derive_and_put_small(asset_id: str, source: bytes) -> str:
    """从 1024 产物字节派生 small 并落缩略图桶 + merge tags,返回 small key。

    tags 合并独立于各 job 的主 merge(jsonb_set 原子合并,先后互不覆盖);
    本函数自身异常由调用方隔离(三族 job 侧独立 try/except 仅 log)。
    """
    # 延迟 import:main 模块底部才 import 本模块,顶部互拉成环
    from app.workers.main import _merge_asset_tags, _thumb_s3_client

    small_key = _small_key(asset_id)
    small_bytes = await asyncio.to_thread(derive_small_bytes, source)
    settings = get_settings()
    thumb_s3 = _thumb_s3_client(settings)
    await asyncio.to_thread(
        thumb_s3.put_object,
        Bucket=settings.minio_thumbnail_bucket,
        Key=small_key,
        Body=io.BytesIO(small_bytes),
        ContentType="image/jpeg",
        Metadata={"source_asset": asset_id, "max_px": str(THUMB_SMALL_MAX_PX)},
    )
    await _merge_asset_tags(
        get_sessionmaker(),
        uuid.UUID(asset_id),
        sets={
            "thumbnail_small_key": small_key,
            "thumbnail_small_size_bytes": len(small_bytes),
        },
    )
    return small_key


async def derive_small_thumbnail(ctx: dict[str, Any], asset_id: str) -> dict[str, Any]:
    """small 回补 job(方案 §4 B5):读缩略图桶 1024 产物 → 派生 240 → put
    {id}_s.jpg → merge tags。

    源 1024 缺失(漂移/清理)→ log + {"status": "source_missing"},不碰原图、
    不写失败 tag(下次回补派发自然重试);其余异常照常抛给 arq(max_tries=1
    终态失败,由回补脚本 --include-failed 兜底重跑)。
    """
    # 延迟 import(同 derive_and_put_small,防与 main 的循环导入)
    from botocore.exceptions import ClientError  # type: ignore[import-untyped]

    from app.workers.main import _thumb_s3_client

    settings = get_settings()
    thumb_s3 = _thumb_s3_client(settings)
    thumb_bucket = settings.minio_thumbnail_bucket
    source_key = f"thumbnails/{asset_id}.jpg"

    def _fetch_source() -> bytes:
        """同步阻塞段(boto3 拉源)整体丢线程池。"""
        buf = io.BytesIO()
        thumb_s3.download_fileobj(thumb_bucket, source_key, buf)
        return buf.getvalue()

    try:
        source = await asyncio.to_thread(_fetch_source)
    except ClientError as e:
        code = str(e.response.get("Error", {}).get("Code", ""))
        if code in ("404", "NoSuchKey", "NoSuchBucket"):
            log.warning("derive small: source 1024 missing asset=%s key=%s",
                        asset_id, source_key)
            return {"status": "source_missing", "asset_id": asset_id}
        raise

    small_key = await derive_and_put_small(asset_id, source)
    log.info("small thumbnail derived asset=%s key=%s", asset_id, small_key)
    return {"status": "ok", "asset_id": asset_id, "thumbnail_small_key": small_key}
