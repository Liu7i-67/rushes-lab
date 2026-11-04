"""arq ai 队列 worker 入口(方案 §8.2/§8.5;独立容器 ms-ai-worker)。

启动:
  arq app.workers.ai_main.AIWorkerSettings

job(契约 §2.4;函数体薄:取 settings → 调 ai_pipeline / ai_jobs → 异常兜底):
  - ai_annotate_asset(asset_id):图片/livp 静态图打标(timeout=120 max_tries=2)
  - ai_slice_video(asset_id):视频切片+打标一体(timeout=5400 max_tries=1)
  - ai_refresh_context(asset_ids | folder_id):移动/改名后重拼上下文(timeout=300)
  - requeue_ai_jobs(cron,每 10min):sweeper 三臂 → 重派(:s{ts} 后缀 id)

意外异常兜底(§8.3-7):只 log 不写行状态 —— 行停留 running,35min 心跳过期后由
sweeper 接管(attempts+1),行为有界自愈;不 raise 烧 arq tries 无意义(CAS 谓词会
跳过已被自己认领的行)。keep_result=0 类属性兜底(§8.2):per-function keep_result
管不到 JobExecutionFailed 特殊路径(function not found / job expired),Worker 级
keep_result=0 封死 result key 残留吞确定性 id 重派的窗口。
"""
from __future__ import annotations

import logging
import time
import uuid
from typing import Any, ClassVar

from arq.connections import RedisSettings
from arq.cron import cron
from arq.worker import func

from app.db.session import get_sessionmaker
from app.services import ai_jobs
from app.services.ai_pipeline import run_annotate, run_slice, write_model_version
from app.services.arq_pool import enqueue_ai_job_raw
from app.settings import get_settings

log = logging.getLogger("worker.ai")

# sweeper 可重派的 kind 集(fn 拼装统一在 arq_pool.enqueue_ai_job_raw,P2-2;
# refresh 不在内 —— 钩子直派,丢失由 backfill --refresh-context 兜底)
_REDISPATCH_FN = {ai_jobs.KIND_ANNOTATE: "ai_annotate_asset",
                  ai_jobs.KIND_SLICE: "ai_slice_video"}


# ─── job 本体(薄壳;业务在 ai_pipeline / ai_jobs)────────────────────────────


async def ai_annotate_asset(ctx: dict[str, Any], asset_id: str) -> dict[str, Any]:
    """图片/livp 静态图打标(§8.3;timeout=120 覆盖 缩略图读取 + describe x3)。"""
    try:
        return await run_annotate(asset_id)
    except Exception:
        # 意外异常(§8.3-7):不写行 → sweeper 35min 接管;完整 traceback 只进日志
        log.exception("ai_annotate_asset unhandled asset=%s", asset_id)
        return {"status": "error_unhandled", "asset_id": asset_id}


async def ai_slice_video(ctx: dict[str, Any], asset_id: str) -> dict[str, Any]:
    """视频切片+打标一体(§8.4;timeout=5400 ≥ 检测600+抽帧+describe 最坏算术;
    max_tries=1:重试语义由 sweeper 接管实现)。"""
    try:
        return await run_slice(asset_id, pool=ctx.get("redis"))
    except Exception:
        log.exception("ai_slice_video unhandled asset=%s", asset_id)
        return {"status": "error_unhandled", "asset_id": asset_id}


async def ai_refresh_context(ctx: dict[str, Any], asset_ids: list[str] | None = None,
                             folder_id: str | None = None) -> dict[str, Any]:
    """上下文刷新(§8.6):移动/改名钩子派发;纯 DB,分批 ≤500/批(timeout=300)。"""
    try:
        ids = [uuid.UUID(s) for s in (asset_ids or [])]
        fid = uuid.UUID(folder_id) if folder_id else None
        if not ids and fid is None:  # 契约:两者至少一个非空
            return {"status": "no_target", "updated": 0}
        updated = await ai_jobs.refresh_context(get_sessionmaker(), ids or None, fid)
        log.info("ai_refresh_context updated=%d assets=%d folder=%s",
                 updated, len(ids), folder_id)
        return {"status": "ok", "updated": updated}
    except Exception:
        # 意外异常兜底(§8.3-7,与 annotate/slice 壳同款):不 raise 烧 arq tries
        # 无意义;丢失由 backfill --refresh-context 全量对账兜底(§8.6)
        log.exception("ai_refresh_context unhandled assets=%s folder=%s",
                      asset_ids, folder_id)
        return {"status": "error_unhandled", "updated": 0}


async def requeue_ai_jobs(ctx: dict[str, Any]) -> dict[str, int]:
    """sweeper cron(§8.5,每 10min):三臂 → 重派。

    重派 _job_id 一律带时间戳后缀 s{unix_ts}:绕开 arq 墓碑键(arq:in-progress:{id},
    kill -9 后存活 max_timeout+10)与残留 job key(TTL=_expires)的同 id 静默吞;
    重派条目互斥由行认领兜底(§8.3-1),job_id 只影响派发不去重。
    """
    settings = get_settings()
    mv = write_model_version(settings)
    requeue = await ai_jobs.sweep_requeue(get_sessionmaker(), mv)
    pool, dispatched = ctx.get("redis"), 0
    ts = int(time.time())
    for aid, kind in requeue:
        if kind not in _REDISPATCH_FN or pool is None:
            # refresh 不由 sweeper 重派(钩子直派);未知 kind 防御
            continue
        try:
            # 拼装经 arq_pool.enqueue_ai_job_raw 单一来源(P2-2);重派 id 带
            # :s{ts} 时间戳后缀绕 arq 墓碑键/残留 job key(§8.5),_expires 按
            # kind 默认(§8.1)
            job = await enqueue_ai_job_raw(
                pool, kind, str(aid), mv, job_id=f"ai:{kind}:{aid}@{mv}:s{ts}",
            )
            if job is not None:
                dispatched += 1
        except Exception as e:  # fire-and-forget 口径,失败仅 log
            log.warning("requeue dispatch fail kind=%s asset=%s err=%s",
                        kind, aid, type(e).__name__)
    log.info("requeue_ai_jobs candidates=%d dispatched=%d", len(requeue), dispatched)
    return {"candidates": len(requeue), "dispatched": dispatched}


# ─── worker settings(arq 0.28;契约 §2.4)────────────────────────────────────


def _build_redis_settings() -> RedisSettings:
    from urllib.parse import urlparse
    url = urlparse(str(get_settings().redis_url))
    return RedisSettings(
        host=url.hostname or "localhost",
        port=url.port or 6379,
        database=int(url.path.lstrip("/") or 0),
        password=url.password,
    )


async def _validate_ai_on_startup(ctx: dict[str, Any]) -> None:
    """on_startup 校验 ai 配置(§2.2;validate_ai_settings 只 warning 不炸 —— 灰度
    窗口 active≠写入版本合法)。worker 不跑 api lifespan,不校验则带病运行到首次使用。"""
    settings = get_settings()
    validate = getattr(settings, "validate_ai_settings", None)
    if callable(validate):
        validate()
    if not getattr(settings, "ai_enabled", False):
        log.warning("AI_ENABLED=false:worker 在跑但派发侧不写行不 enqueue(急停语义)")


class AIWorkerSettings:
    # §8.2:凡 ai 队列 job 必须逐个出现在 functions(漏注册 = arq 取出即判
    # JobExecutionFailed 静默丢弃);cron 归 cron_jobs,勿混进 functions
    functions: ClassVar[list[Any]] = [
        func(ai_annotate_asset, timeout=720, max_tries=2, keep_result=0),
        func(ai_slice_video, timeout=5400, max_tries=1, keep_result=0),
        func(ai_refresh_context, timeout=300, max_tries=2, keep_result=0),
    ]
    cron_jobs: ClassVar[list[Any]] = [
        cron(requeue_ai_jobs, minute=set(range(0, 60, 10)), timeout=300),
    ]
    queue_name = "ai"
    keep_result = 0  # 类属性兜底:JobExecutionFailed 路径只用 Worker 级值(§8.2)
    max_jobs = get_settings().ai_worker_max_jobs  # 对齐 ms-ml 8 推理进程(§7.3)
    on_startup = _validate_ai_on_startup
    redis_settings = _build_redis_settings()
