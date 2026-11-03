"""ai_main(arq worker 壳)契约测试 — requeue 派发参数 / WorkerSettings 契约 / 意外
异常兜底(ai-tagging-slicing 方案 §8.2/§8.5;需求 §5 功能点 2/3,契约点 13)。

既有测试盲区补齐(2026-11-04 专职测试):sweeper 三臂 SQL 已有 test_ai_jobs_service
覆盖,但 **cron 本体的重派通道** 未测 —— 本文件覆盖:
  requeue_ai_jobs:重派 _job_id 一律带时间戳后缀 :s{ts}(绕 arq 墓碑键,§8.5)、
  _queue_name="ai"、annotate/slice 按行 kind 派发、refresh 不重派(钩子直派)、
  poison 行不重派、fire-and-forget(单条 enqueue 抛错不中断其余重派)。
  AIWorkerSettings 契约:三 job 的 timeout/max_tries/keep_result、cron 每 10min、
  queue_name="ai"、类级 keep_result=0(§8.2:JobExecutionFailed 路径只用 Worker 级值)、
  max_jobs=settings.ai_worker_max_jobs。
  ai_refresh_context:空参 no_target / id 直传语义。
  ai_annotate_asset / ai_slice_video 意外异常 → error_unhandled 且不写行(sweeper
  35min 接管,§8.3-7)。

设施:sweeper 用 aiosqlite 内存库跑真查询(test_ai_jobs_service 同款);
enqueue 用 recorder 替身;不连 Redis / 真服务。
"""
from __future__ import annotations

import os
import re
import time
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace
from typing import Any

for _k, _v in {
    "DB_URL": "postgresql+asyncpg://u:p@localhost/db", "REDIS_URL": "redis://localhost:6379/0",
    "MINIO_ENDPOINT_INTERNAL": "http://minio:9000", "MINIO_ENDPOINT_PUBLIC": "http://localhost:9000",
    "MINIO_ACCESS_KEY": "k", "MINIO_SECRET_KEY": "s",
    "OPENFGA_API_URL": "http://openfga:8080", "OPENFGA_STORE_ID": "01TEST",
    "WEB_APP_BASE_URL": "http://localhost/ms-static/web/",
    "SESSION_JWT_SECRET": "test-secret-0123456789abcdef",
}.items():
    os.environ.setdefault(_k, _v)

import pytest  # noqa: E402
from sqlalchemy import select  # noqa: E402
from sqlalchemy.ext.asyncio import (  # noqa: E402
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

import app.workers.ai_main as am  # noqa: E402
from app.db.tables import AiJob, Base  # noqa: E402
from app.services import ai_jobs  # noqa: E402
from app.settings import get_settings  # noqa: E402

_MV = get_settings().ai_model_version   # 与 write_model_version 同值(词表后缀已是 lm1)


@pytest.fixture
async def sm() -> AsyncIterator[async_sessionmaker[AsyncSession]]:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all, tables=[AiJob.__table__])
    factory = async_sessionmaker(engine, expire_on_commit=False)
    yield factory
    await engine.dispose()


def _dt(seconds_ago: float) -> datetime:
    return datetime.now(UTC) - timedelta(seconds=seconds_ago)


async def seed(sm: async_sessionmaker[AsyncSession], *, kind: str = "annotate",
               status: str = "pending", attempts: int = 0,
               updated_ago: float = 1200.0, heartbeat_ago: float | None = None,
               mv: str = _MV, last_error: str | None = None,
               claimed: bool = False) -> uuid.UUID:
    aid = uuid.uuid4()
    async with sm() as db:
        db.add(AiJob(
            id=uuid.uuid4(), asset_id=aid, kind=kind, status=status,
            attempts=attempts, model_version=mv,
            claim_token=uuid.uuid4() if claimed else None,
            heartbeat_at=_dt(heartbeat_ago) if heartbeat_ago is not None else None,
            last_error=last_error,
            created_at=_dt(updated_ago), updated_at=_dt(updated_ago),
        ))
        await db.commit()
    return aid


async def fetch(sm: async_sessionmaker[AsyncSession], asset_id: uuid.UUID,
                kind: str = "annotate") -> AiJob:
    async with sm() as db:
        return (await db.execute(
            select(AiJob).where(AiJob.asset_id == asset_id, AiJob.kind == kind),
        )).scalar_one()


class Pool:
    """arq pool 替身;可注入 per-call 异常(fire-and-forget 口径用例)。"""

    def __init__(self, fail_first: int = 0) -> None:
        self.jobs: list[tuple[str, tuple[Any, ...], dict[str, Any]]] = []
        self._fail_first = fail_first

    async def enqueue_job(self, name: str, *args: Any, **kw: Any) -> object:
        if self._fail_first > 0:
            self._fail_first -= 1
            raise RuntimeError("redis down")
        self.jobs.append((name, args, kw))
        return SimpleNamespace(name=name)


# ─── requeue_ai_jobs(重派通道;§8.5)────────────────────────────────────────


class TestRequeueDispatch:
    async def test_stale_pending_redispatch_params(
            self, sm: Any, monkeypatch: pytest.MonkeyPatch) -> None:
        """臂③:stale pending → ai_annotate_asset;_job_id 带 :s{ts} 时间戳后缀、
        _queue_name="ai"(绕墓碑键);行 updated_at 被 touch(防同拍重复重派)。"""
        aid = await seed(sm, kind="annotate", status="pending", updated_ago=1200)
        monkeypatch.setattr(am, "get_sessionmaker", lambda: sm)
        pool = Pool()
        ts_lo = int(time.time())
        res = await am.requeue_ai_jobs({"redis": pool})
        ts_hi = int(time.time())
        assert res == {"candidates": 1, "dispatched": 1}
        name, args, kw = pool.jobs[0]
        assert name == "ai_annotate_asset" and args == (str(aid),)
        assert kw["_queue_name"] == "ai"
        m = re.fullmatch(rf"ai:annotate:{aid}@{re.escape(_MV)}:s(\d+)", kw["_job_id"])
        assert m, f"重派 id 须带 :s{{ts}} 后缀:{kw['_job_id']}"
        assert ts_lo <= int(m.group(1)) <= ts_hi, "后缀时间戳应落在本次 cron 窗口"
        row = await fetch(sm, aid)
        assert row.status == "pending" and row.attempts == 0, "臂③不烧 attempts"

    async def test_slice_kind_maps_to_slice_fn(
            self, sm: Any, monkeypatch: pytest.MonkeyPatch) -> None:
        aid = await seed(sm, kind="slice", status="failed", updated_ago=1200,
                         last_error="ml_error")
        monkeypatch.setattr(am, "get_sessionmaker", lambda: sm)
        pool = Pool()
        res = await am.requeue_ai_jobs({"redis": pool})
        assert res == {"candidates": 1, "dispatched": 1}
        name, _args, kw = pool.jobs[0]
        assert name == "ai_slice_video"
        assert kw["_queue_name"] == "ai"
        assert ":s" in kw["_job_id"]

    async def test_refresh_kind_not_redispatched(
            self, sm: Any, monkeypatch: pytest.MonkeyPatch) -> None:
        """refresh 不由 sweeper 重派(钩子直派,candidates 计入但不派发)。"""
        aid = await seed(sm, kind="refresh", status="pending", updated_ago=1200)
        monkeypatch.setattr(am, "get_sessionmaker", lambda: sm)
        pool = Pool()
        res = await am.requeue_ai_jobs({"redis": pool})
        assert res == {"candidates": 1, "dispatched": 0}, res
        assert pool.jobs == []

    async def test_running_takeover_redispatched_with_attempt(
            self, sm: Any, monkeypatch: pytest.MonkeyPatch) -> None:
        """臂②:心跳过期 running → 接管(attempts+1 → pending)→ 重派。"""
        aid = await seed(sm, kind="annotate", status="running", attempts=1,
                         updated_ago=1200, heartbeat_ago=2400, claimed=True)
        monkeypatch.setattr(am, "get_sessionmaker", lambda: sm)
        pool = Pool()
        res = await am.requeue_ai_jobs({"redis": pool})
        assert res == {"candidates": 1, "dispatched": 1}
        row = await fetch(sm, aid)
        assert row.status == "pending" and row.attempts == 2
        assert row.claim_token is None and row.heartbeat_at is None
        name, _args, _kw = pool.jobs[0]
        assert name == "ai_annotate_asset"

    async def test_poison_arm_not_redispatched(
            self, sm: Any, monkeypatch: pytest.MonkeyPatch) -> None:
        """臂①:attempts≥5 未终态(含 failed)→ skipped(poison),不重派。"""
        aid = await seed(sm, kind="annotate", status="failed", attempts=5,
                         updated_ago=1200, last_error="ml_error")
        monkeypatch.setattr(am, "get_sessionmaker", lambda: sm)
        pool = Pool()
        res = await am.requeue_ai_jobs({"redis": pool})
        assert res == {"candidates": 0, "dispatched": 0}
        row = await fetch(sm, aid)
        assert row.status == "skipped" and row.last_error == "poison"

    async def test_dispatch_failure_is_fire_and_forget(
            self, sm: Any, monkeypatch: pytest.MonkeyPatch) -> None:
        """单条 enqueue 抛错不中断本轮(fire-and-forget 口径),其余照常派发。"""
        aid1 = await seed(sm, kind="annotate", status="pending", updated_ago=1200)
        aid2 = await seed(sm, kind="slice", status="failed", updated_ago=1200)
        monkeypatch.setattr(am, "get_sessionmaker", lambda: sm)
        pool = Pool(fail_first=1)
        res = await am.requeue_ai_jobs({"redis": pool})
        assert res == {"candidates": 2, "dispatched": 1}, res
        assert len(pool.jobs) == 1
        name, args, _kw = pool.jobs[0]
        assert name == "ai_slice_video" and args == (str(aid2),)
        # aid1 的行已 touch(本拍不重复重派),下拍由 sweeper 重新拾起
        row1 = await fetch(sm, aid1)
        assert row1.status == "pending" and row1.attempts == 0


# ─── AIWorkerSettings 契约(契约测试点 13)────────────────────────────────────


class TestWorkerSettingsContract:
    def test_functions_table(self) -> None:
        """三 job 逐个注册(漏注册 = arq 取出即 JobExecutionFailed 静默丢弃,§8.2)
        且 timeout/max_tries/keep_result 对齐契约 §2.4。"""
        by_name = {f.name: f for f in am.AIWorkerSettings.functions}
        assert set(by_name) == {"ai_annotate_asset", "ai_slice_video",
                                "ai_refresh_context"}
        ann = by_name["ai_annotate_asset"]
        assert ann.timeout_s == 120 and ann.max_tries == 2 and ann.keep_result_s == 0
        slc = by_name["ai_slice_video"]
        assert slc.timeout_s == 5400 and slc.max_tries == 1 and slc.keep_result_s == 0
        rfr = by_name["ai_refresh_context"]
        assert rfr.timeout_s == 300 and rfr.max_tries == 2 and rfr.keep_result_s == 0

    def test_cron_every_ten_minutes(self) -> None:
        cron = am.AIWorkerSettings.cron_jobs
        assert len(cron) == 1
        cj = cron[0]
        assert cj.coroutine.__name__ == "requeue_ai_jobs"
        assert cj.minute == set(range(0, 60, 10)), "minute=0..50 step10"
        assert cj.timeout_s == 300

    def test_class_attributes(self) -> None:
        assert am.AIWorkerSettings.queue_name == "ai"
        assert am.AIWorkerSettings.keep_result == 0, "类级兜底(JobExecutionFailed 路径)"
        assert am.AIWorkerSettings.max_jobs == get_settings().ai_worker_max_jobs


# ─── job 本体薄壳 ────────────────────────────────────────────────────────────


class TestJobBodies:
    async def test_refresh_context_no_target(
            self, monkeypatch: pytest.MonkeyPatch) -> None:
        """契约 §2.4:两者至少一个非空 —— 双空 no_target(不触 DB)。"""
        res = await am.ai_refresh_context({}, asset_ids=None, folder_id=None)
        assert res == {"status": "no_target", "updated": 0}

    async def test_refresh_context_parses_uuid_lists(
            self, monkeypatch: pytest.MonkeyPatch) -> None:
        aid1, aid2, fid = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
        rec = SimpleNamespace(calls=[])

        async def _refresh(_sm: Any, ids: Any, folder: Any, **kw: Any) -> int:
            rec.calls.append((ids, folder))
            return 2

        monkeypatch.setattr(am.ai_jobs, "refresh_context", _refresh)
        res = await am.ai_refresh_context({}, asset_ids=[str(aid1), str(aid2)],
                                          folder_id=str(fid))
        assert res == {"status": "ok", "updated": 2}
        assert rec.calls == [([aid1, aid2], fid)]

    async def test_refresh_context_unhandled_exception_no_raise(
            self, monkeypatch: pytest.MonkeyPatch) -> None:
        """意外异常 → error_unhandled 返回不 raise(§8.3-7 壳兜底,与 annotate/slice
        同款;丢失由 backfill --refresh-context 全量对账兜底)。"""

        async def _boom(_sm: Any, ids: Any, folder: Any, **kw: Any) -> int:
            raise RuntimeError("unexpected")

        monkeypatch.setattr(am.ai_jobs, "refresh_context", _boom)
        res = await am.ai_refresh_context({}, asset_ids=[str(uuid.uuid4())])
        assert res == {"status": "error_unhandled", "updated": 0}

    async def test_annotate_unhandled_exception_no_row_write(
            self, sm: Any, monkeypatch: pytest.MonkeyPatch) -> None:
        """意外异常 → error_unhandled 返回、行不被改写(留 running 由 sweeper
        接管,§8.3-7);不 raise 烧 arq tries。"""
        aid = await seed(sm, kind="annotate", status="running", claimed=True,
                         heartbeat_ago=0)

        async def _boom(asset_id: str) -> dict[str, Any]:
            raise RuntimeError("unexpected")

        monkeypatch.setattr(am, "run_annotate", _boom)
        res = await am.ai_annotate_asset({"redis": None}, str(aid))
        assert res == {"status": "error_unhandled", "asset_id": str(aid)}
        row = await fetch(sm, aid)
        assert row.status == "running", "意外异常不写行(sweeper 35min 接管)"
        assert row.claim_token is not None

    async def test_slice_unhandled_exception_no_row_write(
            self, sm: Any, monkeypatch: pytest.MonkeyPatch) -> None:
        aid = await seed(sm, kind="slice", status="running", claimed=True,
                         heartbeat_ago=0)

        async def _boom(asset_id: str, **kw: Any) -> dict[str, Any]:
            raise RuntimeError("unexpected")

        monkeypatch.setattr(am, "run_slice", _boom)
        res = await am.ai_slice_video({"redis": Pool()}, str(aid))
        assert res == {"status": "error_unhandled", "asset_id": str(aid)}
        row = await fetch(sm, aid, "slice")
        assert row.status == "running"

    async def test_annotate_happy_path_passthrough(
            self, monkeypatch: pytest.MonkeyPatch) -> None:
        async def _ok(asset_id: str) -> dict[str, Any]:
            return {"status": "done", "asset_id": asset_id}

        monkeypatch.setattr(am, "run_annotate", _ok)
        res = await am.ai_annotate_asset({}, "a")
        assert res == {"status": "done", "asset_id": "a"}


def test_sweep_constants_line_up() -> None:
    """节奏常量与方案 §8.5 对齐(漂移 = 时延口径变化,须显式改本断言)。"""
    assert ai_jobs.MAX_ATTEMPTS == 5
    assert ai_jobs.SWEEP_LIMIT == 500
    assert ai_jobs.STALE_RUNNING_S == 2100   # 35min
    assert ai_jobs.STALE_UPDATED_S == 600    # 10min
