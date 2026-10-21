"""arq Redis pool for ms-api → enqueue worker tasks。

由 main.py lifespan create + 挂 app.state.arq_pool。enqueue helper:
    await arq_pool.enqueue_job('generate_thumbnail', asset_id)
"""
from __future__ import annotations

import logging
from urllib.parse import urlparse

from arq import create_pool
from arq.connections import ArqRedis, RedisSettings

from app.settings import Settings

log = logging.getLogger(__name__)


async def create_arq_pool(settings: Settings) -> ArqRedis:
    url = urlparse(str(settings.redis_url))
    pool = await create_pool(RedisSettings(
        host=url.hostname or "localhost",
        port=url.port or 6379,
        database=int(url.path.lstrip("/") or 0),
        password=url.password,
    ))
    log.info("arq pool ready redis=%s:%s", url.hostname, url.port)
    return pool


async def enqueue_thumbnail(pool: ArqRedis, asset_id: str) -> None:
    """fire-and-forget;失败仅 log,不阻塞业务。"""
    try:
        await pool.enqueue_job("generate_thumbnail", asset_id)
    except Exception as e:  # noqa: BLE001
        log.warning("enqueue_thumbnail fail asset=%s err=%s", asset_id, e)


async def enqueue_video_thumbnail(pool: ArqRedis, asset_id: str) -> None:
    """fire-and-forget;失败仅 log,不阻塞业务。"""
    try:
        await pool.enqueue_job("generate_video_thumbnail", asset_id)
    except Exception as e:  # noqa: BLE001
        log.warning("enqueue_video_thumbnail fail asset=%s err=%s", asset_id, e)


async def enqueue_livp_thumbnail(pool: ArqRedis, asset_id: str) -> None:
    """fire-and-forget;失败仅 log,不阻塞业务。"""
    try:
        await pool.enqueue_job("generate_livp_thumbnail", asset_id)
    except Exception as e:  # noqa: BLE001
        log.warning("enqueue_livp_thumbnail fail asset=%s err=%s", asset_id, e)


async def enqueue_livp_download(pool: ArqRedis, asset_id: str) -> None:
    """livp 下载级解包派发(livp-download-unpack 方案 §2.1);fire-and-forget。

    入队带确定性 _job_id=f"livpdl:{asset_id}" + _expires≈3600 在途去重 —— 自愈 404
    重派与上传派发并发时同一资产不双跑;_expires 把崩溃残留的墓碑键(arq:job:{id},
    默认残留最长 24h)盲窗从默认压到 1h。返回 None(job id 撞墓碑/结果键被吞)只记
    warning 供排查,不抛 —— 调用方均为 fire-and-forget 口径。
    """
    try:
        job = await pool.enqueue_job(
            "generate_livp_download", asset_id,
            _job_id=f"livpdl:{asset_id}", _expires=3600,
        )
        if job is None:
            log.warning(
                "enqueue_livp_download 静默去重(墓碑键盲窗?)asset=%s", asset_id,
            )
    except Exception as e:  # noqa: BLE001
        log.warning("enqueue_livp_download fail asset=%s err=%s", asset_id, e)
