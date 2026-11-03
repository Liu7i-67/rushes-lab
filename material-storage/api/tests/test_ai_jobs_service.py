"""ai_jobs 纯 DB 服务层单测(验收清单 #1/#2:行认领幂等 / 心跳 / 终态 CAS / 毒丸 /
sweeper 三臂)— aiosqlite 内存库跑真查询(无需外部 DB;test_local_auth.py 同款形态)。

时间谓词经 Python UTC datetime 绑定(sqlite 与 PG 语义一致,见 ai_jobs 模块 docstring);
心跳/终态/CAS 谓词分支逐条对齐正本 §8.3-1/§8.3-5/§8.5。
"""
from __future__ import annotations

import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.db.tables import AiJob, Base
from app.services import ai_jobs

_MV = "smolvlm2-256m@p1+lm1"
_NOW = datetime.now(UTC)


def _dt(seconds_ago: float) -> datetime:
    return _NOW - timedelta(seconds=seconds_ago)


def _aware(value: datetime | None) -> datetime | None:
    """SQLite 读回 timezone=True 列为 naive(存 UTC);统一补 UTC 供比较。"""
    if value is not None and value.tzinfo is None:
        return value.replace(tzinfo=UTC)
    return value


def _row(asset_id: uuid.UUID | None = None, *, kind: str = "annotate",
         status: str = "pending", attempts: int = 0, mv: str = _MV,
         claimed: bool = False, heartbeat_ago: float | None = None,
         updated_ago: float = 0.0, last_error: str | None = None) -> AiJob:
    return AiJob(
        id=uuid.uuid4(), asset_id=asset_id or uuid.uuid4(), kind=kind, status=status,
        attempts=attempts, model_version=mv,
        claim_token=uuid.uuid4() if claimed else None,
        heartbeat_at=_dt(heartbeat_ago) if heartbeat_ago is not None else None,
        last_error=last_error, created_at=_dt(updated_ago), updated_at=_dt(updated_ago),
    )


async def _fetch(db: AsyncSession, asset_id: uuid.UUID, kind: str = "annotate") -> AiJob:
    return (await db.execute(
        select(AiJob).where(AiJob.asset_id == asset_id, AiJob.kind == kind),
    )).scalar_one()


@pytest.fixture
async def sm() -> AsyncIterator[async_sessionmaker[AsyncSession]]:
    """内存 SQLite(AiJob 单表;FK 不强制,无需 assets 行)。"""
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all, tables=[AiJob.__table__])
    factory = async_sessionmaker(engine, expire_on_commit=False)
    yield factory
    await engine.dispose()


async def _seed(sm, *rows: AiJob) -> list[uuid.UUID]:
    async with sm() as db:
        db.add_all(rows)
        await db.commit()
    return [r.asset_id for r in rows]


async def _bind_token(sm, asset_id: uuid.UUID, kind: str = "annotate") -> uuid.UUID:
    """认领行并取回 claim_token(受控种子的 CAS 凭据)。"""
    outcome = await ai_jobs.claim_ai_job(sm, asset_id, kind, _MV)
    assert outcome.claimed and outcome.claim_token is not None
    return outcome.claim_token


# ─── ensure_ai_job(INSERT ON CONFLICT DO NOTHING)────────────────────────────


class TestEnsureAiJob:
    async def test_insert_new_then_conflict_noop(self, sm) -> None:
        aid = uuid.uuid4()
        assert await ai_jobs.ensure_ai_job(sm, aid, "annotate", _MV) is True
        assert await ai_jobs.ensure_ai_job(sm, aid, "annotate", _MV) is False

    async def test_conflict_keeps_existing_status(self, sm) -> None:
        """行已存在(任意状态)时 ensure 不改动 —— done 行不被复活。"""
        aid = await _seed(sm, _row(status="done", claimed=False))
        assert await ai_jobs.ensure_ai_job(sm, aid[0], "annotate", _MV) is False
        async with sm() as db:
            row = await _fetch(db, aid[0])
        assert row.status == "done"


# ─── claim_ai_job(CAS 谓词分支;§8.3-1)───────────────────────────────────────


class TestClaimCas:
    async def test_no_row(self, sm) -> None:
        outcome = await ai_jobs.claim_ai_job(sm, uuid.uuid4(), "annotate", _MV)
        assert outcome.claimed is False and outcome.reason == "no_row"

    async def test_pending_row_claimed(self, sm) -> None:
        aid = await _seed(sm, _row(status="pending"))
        outcome = await ai_jobs.claim_ai_job(sm, aid[0], "annotate", _MV)
        assert outcome.claimed is True and outcome.claim_token is not None
        async with sm() as db:
            row = await _fetch(db, aid[0])
        assert row.status == "running"
        assert row.claim_token == outcome.claim_token
        assert row.heartbeat_at is not None  # 认领即写心跳(sweeper 判活依据)

    async def test_failed_row_claimed(self, sm) -> None:
        aid = await _seed(sm, _row(status="failed", attempts=2, last_error="ml_error"))
        outcome = await ai_jobs.claim_ai_job(sm, aid[0], "annotate", _MV)
        assert outcome.claimed is True

    async def test_done_row_terminal(self, sm) -> None:
        aid = await _seed(sm, _row(status="done"))
        outcome = await ai_jobs.claim_ai_job(sm, aid[0], "annotate", _MV)
        assert outcome.claimed is False and outcome.reason == "terminal_done"

    async def test_skipped_row_terminal(self, sm) -> None:
        aid = await _seed(sm, _row(status="skipped", last_error="asset_gone"))
        outcome = await ai_jobs.claim_ai_job(sm, aid[0], "annotate", _MV)
        assert outcome.claimed is False and outcome.reason == "terminal_skipped"

    async def test_fresh_running_busy(self, sm) -> None:
        """running + 心跳新鲜 = 别的实例在跑 → busy(不双认领)。"""
        aid = await _seed(sm, _row(status="running", claimed=True, heartbeat_ago=60))
        outcome = await ai_jobs.claim_ai_job(sm, aid[0], "annotate", _MV)
        assert outcome.claimed is False and outcome.reason == "busy"

    async def test_stale_running_taken_over(self, sm) -> None:
        """running + 心跳过期(>35min)= 僵尸 → 接管成功。"""
        aid = await _seed(
            sm, _row(status="running", claimed=True, heartbeat_ago=35 * 60 + 1))
        outcome = await ai_jobs.claim_ai_job(sm, aid[0], "annotate", _MV,
                                             stale_after_s=2100)
        assert outcome.claimed is True and outcome.claim_token is not None

    async def test_second_claim_busy_after_first(self, sm) -> None:
        """同行两次认领:第一次成功,第二次 busy(CAS 消灭 TOCTOU 双认领)。"""
        aid = await _seed(sm, _row(status="pending"))
        first = await ai_jobs.claim_ai_job(sm, aid[0], "annotate", _MV)
        second = await ai_jobs.claim_ai_job(sm, aid[0], "annotate", _MV)
        assert first.claimed is True
        assert second.claimed is False and second.reason == "busy"
        assert second.claim_token != first.claim_token


# ─── heartbeat / 终态 CAS(WHERE claim_token)────────────────────────────────


class TestHeartbeatAndFinish:
    async def test_heartbeat_only_touches_heartbeat_at(self, sm) -> None:
        """心跳只刷 heartbeat_at(CAS 凭据列 claim_token / attempts / status 全不动,
        §17-10);updated_at 由 schema onupdate 维持(§2.1 契约,观测列不在谓词内)。"""
        aid = await _seed(sm, _row(status="pending", heartbeat_ago=600, updated_ago=600))
        token = await _bind_token(sm, aid[0])
        assert await ai_jobs.heartbeat_ai_job(sm, token) is True
        async with sm() as db:
            row = await _fetch(db, aid[0])
        assert row.status == "running"          # 认领置位,心跳不改状态
        assert row.claim_token == token         # CAS 凭据不变
        assert row.attempts == 0
        assert _aware(row.updated_at) > _dt(600)    # onupdate 维持(仅观测)
        assert _aware(row.heartbeat_at) is not None
        assert _aware(row.heartbeat_at) > _dt(600)  # 只刷 heartbeat_at

    async def test_heartbeat_unknown_token_false(self, sm) -> None:
        assert await ai_jobs.heartbeat_ai_job(sm, uuid.uuid4()) is False

    async def test_finish_done_clears_claim(self, sm) -> None:
        aid = await _seed(sm, _row(status="pending", heartbeat_ago=1))
        token = await _bind_token(sm, aid[0])
        final = await ai_jobs.finish_ai_job(sm, token, "done")
        assert final == "done"
        async with sm() as db:
            row = await _fetch(db, aid[0])
        assert row.status == "done"
        assert row.claim_token is None and row.heartbeat_at is None
        assert row.attempts == 0  # done 不计 attempts

    async def test_finish_failed_counts_attempt(self, sm) -> None:
        aid = await _seed(sm, _row(status="pending", attempts=1))
        token = await _bind_token(sm, aid[0])
        final = await ai_jobs.finish_ai_job(sm, token, "failed", last_error="ml_error",
                                            count_attempt=True)
        assert final == "failed"
        async with sm() as db:
            row = await _fetch(db, aid[0])
        assert row.status == "failed" and row.last_error == "ml_error"
        assert row.attempts == 2

    async def test_poison_at_threshold_writes_skipped(self, sm) -> None:
        """attempts+1 ≥ 5 → 直接写 skipped(poison)(终态可见,不卡 pending/failed)。"""
        aid = await _seed(sm, _row(status="pending", attempts=4))
        token = await _bind_token(sm, aid[0])
        final = await ai_jobs.finish_ai_job(sm, token, "failed", last_error="ml_error",
                                            count_attempt=True)
        assert final == "skipped"  # 实际写入的终态被改写为 poison
        async with sm() as db:
            row = await _fetch(db, aid[0])
        assert row.status == "skipped" and row.last_error == "poison"
        assert row.attempts == 5

    async def test_below_threshold_not_poisoned(self, sm) -> None:
        aid = await _seed(sm, _row(status="pending", attempts=3))
        token = await _bind_token(sm, aid[0])
        final = await ai_jobs.finish_ai_job(sm, token, "failed", last_error="ml_error",
                                            count_attempt=True)
        assert final == "failed"
        async with sm() as db:
            row = await _fetch(db, aid[0])
        assert row.status == "failed" and row.last_error == "ml_error"

    async def test_finish_after_takeover_returns_none(self, sm) -> None:
        """claim_token 已被接管清掉 → 终态写不进(旧执行者不交错写,§17-14)。"""
        aid = await _seed(sm, _row(status="running", claimed=True))
        async with sm() as db:  # 模拟「行被 sweeper 接管」:claim 已清
            row = await _fetch(db, aid[0])
            row.claim_token = None
            await db.commit()
        assert await ai_jobs.finish_ai_job(sm, uuid.uuid4(), "done") is None


# ─── count_running_slices(并发闸;§8.2 含僵尸过滤)───────────────────────────


class TestCountRunningSlices:
    async def test_counts_only_fresh_running_slices(self, sm) -> None:
        await _seed(
            sm,
            _row(kind="slice", status="running", claimed=True, heartbeat_ago=60),
            _row(kind="slice", status="running", claimed=True, heartbeat_ago=3600),  # 僵尸
            _row(kind="slice", status="pending"),
            _row(kind="annotate", status="running", claimed=True, heartbeat_ago=60),
        )
        assert await ai_jobs.count_running_slices(sm) == 1


# ─── sweep_requeue 三臂(§8.5)────────────────────────────────────────────────


class TestSweepRequeue:
    async def test_pending_arm_requeues_without_attempts(self, sm) -> None:
        """pending/failed 臂:陈旧行重派,attempts 不加,updated_at 被 touch。"""
        row = _row(status="pending", attempts=0, updated_ago=660)
        failed = _row(status="failed", attempts=1, updated_ago=660)
        await _seed(sm, row, failed)
        fresh = _row(status="pending", updated_ago=10)  # 不满 10min 陈旧阈值
        await _seed(sm, fresh)
        requeue = await ai_jobs.sweep_requeue(sm, _MV)
        assert (row.asset_id, "annotate") in requeue
        assert (failed.asset_id, "annotate") in requeue
        assert (fresh.asset_id, "annotate") not in requeue
        async with sm() as db:
            r = await _fetch(db, row.asset_id)
            f = await _fetch(db, failed.asset_id)
        assert r.status == "pending" and r.attempts == 0   # 排队不是失败
        assert f.attempts == 1                             # failed 臂同样不加
        assert _aware(r.updated_at) > _dt(600)             # 同拍 touch(防重复重派)

    async def test_running_arm_takes_over_with_attempts(self, sm) -> None:
        """running 接管臂:僵尸 → pending + attempts+1 且重派。"""
        row = _row(kind="slice", status="running", claimed=True, attempts=1,
                   heartbeat_ago=2200)
        await _seed(sm, row)
        requeue = await ai_jobs.sweep_requeue(sm, _MV)
        assert (row.asset_id, "slice") in requeue
        async with sm() as db:
            r = await _fetch(db, row.asset_id, "slice")
        assert r.status == "pending" and r.attempts == 2
        assert r.claim_token is None and r.heartbeat_at is None

    async def test_running_arm_poisons_at_threshold(self, sm) -> None:
        """接管时 attempts+1 达 5 → CASE 直接转 skipped(poison),且不重派。"""
        row = _row(status="running", claimed=True, attempts=4, heartbeat_ago=2200)
        await _seed(sm, row)
        requeue = await ai_jobs.sweep_requeue(sm, _MV)
        assert (row.asset_id, "annotate") not in requeue
        async with sm() as db:
            r = await _fetch(db, row.asset_id)
        assert r.status == "skipped" and r.last_error == "poison"

    async def test_fallback_arm_poisons_pending_and_failed(self, sm) -> None:
        """兜底臂:attempts ≥5 且未终态(**含 failed**)→ skipped(poison)。"""
        pending = _row(status="pending", attempts=5, updated_ago=660)
        failed = _row(status="failed", attempts=6, updated_ago=660)
        await _seed(sm, pending, failed)
        requeue = await ai_jobs.sweep_requeue(sm, _MV)
        assert requeue == []  # 被毒丸的行不重派
        async with sm() as db:
            p = await _fetch(db, pending.asset_id)
            f = await _fetch(db, failed.asset_id)
        assert p.status == "skipped" and p.last_error == "poison"
        assert f.status == "skipped" and f.last_error == "poison"

    async def test_model_version_filter(self, sm) -> None:
        """各臂带 model_version=写入版本过滤:旧版本残留行不被新权重错标。"""
        old = _row(status="pending", mv="smolvlm2-256m@p0+lm0", updated_ago=660)
        await _seed(sm, old)
        assert await ai_jobs.sweep_requeue(sm, _MV) == []
        async with sm() as db:
            r = await _fetch(db, old.asset_id)
        assert r.status == "pending"  # 原样保留(backfill 按需处理)

    async def test_running_arm_ignores_null_heartbeat(self, sm) -> None:
        """NULL heartbeat 不参与接管谓词(认领即写心跳,NULL=不可能状态,防御)。"""
        row = _row(status="running", claimed=True, heartbeat_ago=None)
        await _seed(sm, row)
        assert await ai_jobs.sweep_requeue(sm, _MV) == []

    async def test_batch_limit(self, sm) -> None:
        """批上限 LIMIT(默认 500):本测以小 limit 注入验证截断生效。"""
        rows = [_row(status="pending", updated_ago=660) for _ in range(5)]
        await _seed(sm, *rows)
        requeue = await ai_jobs.sweep_requeue(sm, _MV, limit=3)
        assert len(requeue) == 3


# ─── reset_ai_job(--force 语义,§8.7)────────────────────────────────────────


class TestResetAiJob:
    async def test_reset_done_row(self, sm) -> None:
        """--force 真重置:done 也复位 pending/attempts=0/claim 清空。"""
        aid = await _seed(sm, _row(status="done", attempts=2))
        assert await ai_jobs.reset_ai_job(sm, aid[0], "annotate", _MV) is True
        async with sm() as db:
            r = await _fetch(db, aid[0])
        assert r.status == "pending" and r.attempts == 0 and r.claim_token is None

    async def test_reset_skipped_row(self, sm) -> None:
        aid = await _seed(sm, _row(status="skipped", last_error="decode_failed"))
        assert await ai_jobs.reset_ai_job(sm, aid[0], "annotate", _MV) is True
        async with sm() as db:
            r = await _fetch(db, aid[0])
        assert r.status == "pending" and r.last_error is None

    async def test_reset_missing_row_false(self, sm) -> None:
        assert await ai_jobs.reset_ai_job(sm, uuid.uuid4(), "annotate", _MV) is False

    async def test_unclaim_to_pending_keeps_attempts(self, sm) -> None:
        """健康闸判死:置回 pending、attempts 不动、清 claim(§8.3-3)。"""
        aid = await _seed(sm, _row(status="pending", attempts=2))
        token = await _bind_token(sm, aid[0])
        assert await ai_jobs.unclaim_to_pending(sm, token) is True
        async with sm() as db:
            r = await _fetch(db, aid[0])
        assert r.status == "pending" and r.attempts == 2
        assert r.claim_token is None and r.heartbeat_at is None


# ─── build_searchable_text(纯函数,§9)───────────────────────────────────────


class TestBuildSearchableText:
    def test_joins_and_filters_empty_parts(self) -> None:
        text = ai_jobs.build_searchable_text("proj/夹/a.jpg", "舞台", "stage",
                                             "", " ", "夜拍")
        assert text == "proj/夹/a.jpg 舞台 stage 夜拍"

    def test_all_empty(self) -> None:
        assert ai_jobs.build_searchable_text(None, "", "  ") == ""
