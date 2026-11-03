"""arq Redis pool for ms-api → enqueue worker tasks。

由 main.py lifespan create + 挂 app.state.arq_pool。enqueue helper:
    await arq_pool.enqueue_job('generate_thumbnail', asset_id)
"""
from __future__ import annotations

import logging
from typing import Any
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


# ─── ai 队列(打标/切片;AI 方案 §8.1/契约 §2.3)──────────────────────────────
# _job_id 确定性 = f"ai:{kind}:{asset_id}@{model_version}"(上传并发双派去重);
# _expires 按类区分(§8.1):annotate ≈1800(闸=2 x 8-15min 排队)、slice ≥86400
# ——太短会使取出时 job_key 已过期被判 expired 丢弃,退化到 sweeper 补派多付 10-25min。
# worker 侧 AIWorkerSettings.keep_result=0 防 result key 残留吞确定性 id 重派(§8.2)。
# 注:闸满自延迟重派的时间戳后缀 id(:d{ts})在 ai_pipeline;sweeper/回填的重派
# (:s{ts}/:b{ts})经 enqueue_ai_job_raw 的 job_id 参数注入 —— 拼装单一来源。
# kind 字面量 = ai_jobs.KIND_ANNOTATE/KIND_SLICE(契约常量;字面量写死避免
# import 环:arq_pool 被 api 侧多处早 import)。
_AI_JOB_FN = {"annotate": "ai_annotate_asset", "slice": "ai_slice_video"}
_AI_JOB_EXPIRES = {"annotate": 1800, "slice": 86400}


def _ai_model_version() -> str:
    """写入版本 —— 单一来源 ai_pipeline.write_model_version(含词表后缀,与
    ai_jobs 行 model_version / sweeper 重派 / backfill 完全一致;行认领按写入
    版本过滤,派发键错位 = 行永不可认领,P2-1 收敛)。函数体内延迟 import:
    arq_pool 被 api 侧多处早 import,顶层引 ai_pipeline 成环。"""
    from app.services.ai_pipeline import write_model_version
    return write_model_version()


async def enqueue_ai_job_raw(
    pool: ArqRedis, kind: str, asset_id: str, mv: str,
    *, job_id: str | None = None, expires: int | None = None,
) -> Any:
    """ai 队列纯派发(不写行)—— 拼装单一来源(P2-2):enqueue_ai_annotate /
    enqueue_ai_slice(链式首派)、workers/main._chain_ai(接力,ctx["redis"] 同为
    ArqRedis)、ai_main.requeue_ai_jobs(sweeper 重派)全部经它。

    - fn/_queue_name="ai" 按 kind 查表;未知 kind 防御性不派发(返回 None)。
    - job_id=None = 确定性 id ai:{kind}:{asset_id}@{mv}(上传并发双派去重);
      重派/回填通道传自带唯一后缀的 id(:s{ts}/:b{ts},绕 arq 墓碑键,§8.5)。
    - expires=None = 按 kind 默认(§8.1 _AI_JOB_EXPIRES);显式传值覆盖。
    """
    fn = _AI_JOB_FN.get(kind)
    if fn is None:
        log.warning("enqueue_ai_job_raw 未知 kind=%s asset=%s(不派发)", kind, asset_id)
        return None
    kw: dict[str, Any] = {
        "_job_id": job_id or f"ai:{kind}:{asset_id}@{mv}",
        "_queue_name": "ai",
        "_expires": _AI_JOB_EXPIRES.get(kind) if expires is None else expires,
    }
    return await pool.enqueue_job(fn, asset_id, **kw)


async def enqueue_ai_annotate(pool: ArqRedis, asset_id: str) -> None:
    """图片/livp 静态图打标派发(ai 队列);fire-and-forget 仅 log。"""
    try:
        job = await enqueue_ai_job_raw(pool, "annotate", asset_id, _ai_model_version())
        if job is None:
            log.warning("enqueue_ai_annotate 静默去重(墓碑/结果键盲窗?)asset=%s", asset_id)
    except Exception as e:
        log.warning("enqueue_ai_annotate fail asset=%s err=%s", asset_id, e)


async def enqueue_ai_slice(pool: ArqRedis, asset_id: str) -> None:
    """视频切片打标派发(ai 队列);fire-and-forget 仅 log。"""
    try:
        job = await enqueue_ai_job_raw(pool, "slice", asset_id, _ai_model_version())
        if job is None:
            log.warning("enqueue_ai_slice 静默去重(墓碑/结果键盲窗?)asset=%s", asset_id)
    except Exception as e:
        log.warning("enqueue_ai_slice fail asset=%s err=%s", asset_id, e)
