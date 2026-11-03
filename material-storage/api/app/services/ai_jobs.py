"""ai_jobs 纯 DB 服务层(方案 ai-tagging-slicing-plan.md §8.3-1/§8.5;迁移 0021)。

只做 ai_jobs 行读写与 context_path/searchable_text 纯 DB 拼装;事务边界 = 每函数
自持 session + 一次 commit(worker/cron/backfill 独立调用)。对外 API:

    KIND_ANNOTATE/KIND_SLICE/KIND_REFRESH;MAX_ATTEMPTS=5;SWEEP_LIMIT=500
    STALE_RUNNING_S=2100(35min);STALE_UPDATED_S=600(10min)
    ensure_ai_job / claim_ai_job(→ClaimOutcome)/ heartbeat_ai_job / finish_ai_job
    unclaim_to_pending / touch_ai_job / count_running_slices / sweep_requeue
    reset_ai_job / build_context_path / build_searchable_text / refresh_context

语义钉死(§17-10/14):心跳只刷 heartbeat_at;终态/中间态 CAS 一律 WHERE
claim_token,绝不比较被心跳改写的列(否则执行者被自己挡死 → 接管死循环)。毒丸
(§8.3-5):count_attempt=True 时 attempts+1≥5 直接写 skipped(poison)。三臂(§8.5):
pending/failed 臂不加 attempts 只 touch updated_at;running 接管臂 attempts+1(达上限
转 poison);兜底臂 attempts≥5 含 failed → poison;各臂带 model_version=写入版本过滤。
时间谓词用 Python UTC datetime 绑定(与 now()-interval 语义等价,换 PG/SQLite 双方言
可跑 —— 单测 aiosqlite 内存库跑真查询)。
"""
from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from sqlalchemy import case, func, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.db.tables import AiJob, Asset, AssetAiAnnotation, AssetVideoSegment, Folder, Project

# ─── 常量(节奏值收模块常量;时延可调项由调用方传参)──────────────────────────
KIND_ANNOTATE, KIND_SLICE, KIND_REFRESH = "annotate", "slice", "refresh"
MAX_ATTEMPTS = 5                  # 毒丸阈值(§8.3-5/§8.5)
SWEEP_LIMIT = 500                 # 三臂每拍批上限(§8.5;沿百度 SWEEP_BATCH 批闸先例)
STALE_RUNNING_S = 2100            # 35min:心跳过期 = 可接管(与 §8.3-1 口径一致)
STALE_UPDATED_S = 600             # 10min:pending/failed 陈旧阈值(§8.5)

_SessionMaker = async_sessionmaker[AsyncSession]


def _now() -> datetime:
    return datetime.now(UTC)


@dataclass(frozen=True)
class ClaimOutcome:
    """认领结果;reason:claimed / no_row / terminal_done / terminal_skipped / busy。"""

    claimed: bool
    claim_token: uuid.UUID | None
    reason: str


# ─── 行写入与认领(§8.3-1)────────────────────────────────────────────────────


async def ensure_ai_job(sm: _SessionMaker, asset_id: uuid.UUID, kind: str,
                        model_version: str) -> bool:
    """INSERT ON CONFLICT (asset_id,kind,model_version) DO NOTHING(§8.1 行先行);
    链式挂载/restore 补派/backfill 共用:行存在(任意状态)不动,返回是否新插。"""
    now = _now()
    async with sm() as db:
        stmt = dialect_insert(db, AiJob.__table__).values(
            id=uuid.uuid4(), asset_id=asset_id, kind=kind, status="pending",
            attempts=0, model_version=model_version, created_at=now, updated_at=now,
        ).on_conflict_do_nothing(index_elements=["asset_id", "kind", "model_version"])
        res = await db.execute(stmt)
        await db.commit()
        return bool(res.rowcount)


def dialect_insert(db: AsyncSession, table):  # type: ignore[no-untyped-def]
    """方言感知的 INSERT .. ON CONFLICT 构造器(PG 正本 / SQLite 单测同语义);
    ai_pipeline 的 annotation upsert 同款复用。"""
    dialect = getattr(getattr(db.bind, "dialect", None), "name", "postgresql")
    return (sqlite_insert if dialect == "sqlite" else pg_insert)(table)


async def claim_ai_job(sm: _SessionMaker, asset_id: uuid.UUID, kind: str,
                       model_version: str,
                       stale_after_s: int = STALE_RUNNING_S) -> ClaimOutcome:
    """单条 CAS 认领(§8.3-1):先 SELECT 分支原因,再 CAS UPDATE。

    CAS 谓词 = status IN ('pending','failed') OR (status='running' AND heartbeat_at <
    now()-stale);0 行返回 busy(别的实例在跑且心跳新鲜)。CAS 消灭「回读→UPDATE」
    TOCTOU 双认领(沿百度 lease 先例)。
    """
    cutoff = _now() - timedelta(seconds=stale_after_s)
    async with sm() as db:
        row = (await db.execute(
            select(AiJob.id, AiJob.status).where(
                AiJob.asset_id == asset_id, AiJob.kind == kind,
                AiJob.model_version == model_version,
            ),
        )).first()
        if row is None:
            return ClaimOutcome(False, None, "no_row")
        if row.status in ("done", "skipped"):
            return ClaimOutcome(False, None, f"terminal_{row.status}")
        token = uuid.uuid4()
        res = await db.execute(
            update(AiJob).where(
                AiJob.id == row.id,
                AiJob.status.in_(("pending", "failed"))
                | ((AiJob.status == "running") & (AiJob.heartbeat_at < cutoff)),
            ).values(status="running", claim_token=token, heartbeat_at=_now()),
        )
        await db.commit()
        if not res.rowcount:
            return ClaimOutcome(False, None, "busy")
        return ClaimOutcome(True, token, "claimed")


# ─── 心跳 / 终态 / 中间态 CAS(WHERE claim_token;§8.3-1 P0 教训)──────────────


async def heartbeat_ai_job(sm: _SessionMaker, claim_token: uuid.UUID) -> bool:
    """心跳:只刷 heartbeat_at(5min 周期,调用方 asyncio 后台任务)。"""
    async with sm() as db:
        res = await db.execute(update(AiJob).where(AiJob.claim_token == claim_token)
                               .values(heartbeat_at=_now()))
        await db.commit()
        return bool(res.rowcount)


async def finish_ai_job(sm: _SessionMaker, claim_token: uuid.UUID, status: str,
                        last_error: str | None = None,
                        count_attempt: bool = False) -> str | None:
    """终态 CAS(WHERE claim_token)。返回实际写入的终态;None = claim 已失(被接管)。

    count_attempt=True = 真实执行失败计 attempts(§8.3-5);attempts+1 ≥ MAX_ATTEMPTS
    时直接写 skipped(poison)。last_error 受控 token 集。
    """
    async with sm() as db:
        row = (await db.execute(
            select(AiJob.attempts).where(AiJob.claim_token == claim_token),
        )).first()
        if row is None:
            return None
        final_status, final_err = status, last_error
        if count_attempt and row.attempts + 1 >= MAX_ATTEMPTS:
            final_status, final_err = "skipped", "poison"
        res = await db.execute(
            update(AiJob).where(AiJob.claim_token == claim_token).values(
                status=final_status, last_error=final_err, claim_token=None,
                heartbeat_at=None, updated_at=_now(),
                attempts=AiJob.attempts + (1 if count_attempt else 0),
            ),
        )
        await db.commit()
        return final_status if res.rowcount else None


async def unclaim_to_pending(sm: _SessionMaker, claim_token: uuid.UUID) -> bool:
    """健康闸判死置回 pending(§8.3-3):attempts 不动、清 claim,交 sweeper 重派。"""
    async with sm() as db:
        res = await db.execute(
            update(AiJob).where(AiJob.claim_token == claim_token).values(
                status="pending", claim_token=None, heartbeat_at=None,
                updated_at=_now(),
            ),
        )
        await db.commit()
        return bool(res.rowcount)


async def touch_ai_job(sm: _SessionMaker, asset_id: uuid.UUID, kind: str,
                       model_version: str) -> bool:
    """touch updated_at(闸满自延迟重排/sweeper 重派后同拍保鲜,§8.2/§8.5)。"""
    async with sm() as db:
        res = await db.execute(
            update(AiJob).where(
                AiJob.asset_id == asset_id, AiJob.kind == kind,
                AiJob.model_version == model_version,
            ).values(updated_at=_now()),
        )
        await db.commit()
        return bool(res.rowcount)


# ─── 并发闸与 sweeper(§8.2/§8.5)─────────────────────────────────────────────


async def count_running_slices(sm: _SessionMaker,
                               stale_after_s: int = STALE_RUNNING_S) -> int:
    """slice 并发闸计数:running 且心跳新鲜(35min 内),僵尸不占槽(§8.2)。"""
    cutoff = _now() - timedelta(seconds=stale_after_s)
    async with sm() as db:
        res = await db.execute(select(func.count()).select_from(AiJob).where(
            AiJob.kind == KIND_SLICE, AiJob.status == "running",
            AiJob.heartbeat_at > cutoff,
        ))
        return int(res.scalar_one())


async def sweep_requeue(sm: _SessionMaker, model_version: str, *,
                        stale_updated_s: int = STALE_UPDATED_S,
                        stale_running_s: int = STALE_RUNNING_S,
                        max_attempts: int = MAX_ATTEMPTS,
                        limit: int = SWEEP_LIMIT) -> list[tuple[uuid.UUID, str]]:
    """sweeper 三臂(§8.5),返回本拍应重派的 (asset_id, kind) 列表。

    臂① 毒丸兜底:attempts≥5 且未终态(**含 failed**)→ skipped(poison);臂②
    running 接管:heartbeat 过期 → pending + attempts+1(达上限 CASE 转 poison,
    被毒丸的行不重派);臂③ pending/failed 补派(**不加 attempts**,只 touch
    updated_at,`attempts < 上限` 与臂①衔接防同拍空派)。臂②③ touch 防重复重派;
    各臂带 model_version=写入版本过滤。
    """
    now = _now()
    requeue: list[tuple[uuid.UUID, str]] = []
    async with sm() as db:
        # 臂①:毒丸兜底(防 arq 超时杀死后行无终态的观测黑洞)
        await db.execute(
            update(AiJob).where(
                AiJob.model_version == model_version,
                AiJob.attempts >= max_attempts,
                AiJob.status.in_(("pending", "running", "failed")),
            ).values(status="skipped", last_error="poison", claim_token=None,
                     heartbeat_at=None, updated_at=now)
            .execution_options(synchronize_session=False),
        )
        # 臂②:running 接管(僵尸;真执行过才计 attempts)
        taken = (await db.execute(
            select(AiJob.id, AiJob.asset_id, AiJob.kind, AiJob.attempts).where(
                AiJob.model_version == model_version,
                AiJob.status == "running",
                AiJob.heartbeat_at < now - timedelta(seconds=stale_running_s),
            ).limit(limit),
        )).all()
        if taken:
            poisoned = case(
                (AiJob.attempts + 1 >= max_attempts, "skipped"), else_="pending",
            )
            poison_err = case(
                (AiJob.attempts + 1 >= max_attempts, "poison"), else_=None,
            )
            await db.execute(
                update(AiJob).where(AiJob.id.in_([r.id for r in taken])).values(
                    status=poisoned, last_error=poison_err, attempts=AiJob.attempts + 1,
                    claim_token=None, heartbeat_at=None, updated_at=now,
                ).execution_options(synchronize_session=False),
            )
            requeue.extend(
                (r.asset_id, r.kind) for r in taken if r.attempts + 1 < max_attempts
            )
        # 臂③:pending/failed 补派(排队/派发丢失不是失败,不烧 attempts)
        stale = (await db.execute(
            select(AiJob.id, AiJob.asset_id, AiJob.kind).where(
                AiJob.model_version == model_version,
                AiJob.status.in_(("pending", "failed")),
                AiJob.attempts < max_attempts,
                AiJob.updated_at < now - timedelta(seconds=stale_updated_s),
            ).order_by(AiJob.updated_at, AiJob.id).limit(limit),
        )).all()
        if stale:
            await db.execute(
                update(AiJob).where(AiJob.id.in_([r.id for r in stale]))
                .values(updated_at=now)
                .execution_options(synchronize_session=False),
            )
            requeue.extend((r.asset_id, r.kind) for r in stale)
        await db.commit()
    return requeue


async def reset_ai_job(sm: _SessionMaker, asset_id: uuid.UUID, kind: str,
                       model_version: str) -> bool:
    """backfill --force 语义(§8.7):置 pending/attempts=0/claim_token=NULL,
    含 done(否则幂等验收空洞通过);skipped 一并复位(--reset-skipped 通道)。"""
    async with sm() as db:
        res = await db.execute(
            update(AiJob).where(
                AiJob.asset_id == asset_id, AiJob.kind == kind,
                AiJob.model_version == model_version,
            ).values(status="pending", attempts=0, claim_token=None,
                     heartbeat_at=None, last_error=None, updated_at=_now()),
        )
        await db.commit()
        return bool(res.rowcount)


# ─── context_path / searchable_text(§8.3-2/§9)与 §8.6 上下文刷新 ────────────


async def build_context_path(sm: _SessionMaker, asset_id: uuid.UUID) -> str | None:
    """独立 session 包装(见 build_context_path_db);asset 不存在/软删 → None。"""
    async with sm() as db:
        return await build_context_path_db(db, asset_id)


async def build_context_path_db(db: AsyncSession, asset_id: uuid.UUID) -> str | None:
    """`{project.name}/{folder 链}/{filename}` DB 拼,截 600(§8.3-2)。

    上行 folder 链根→叶反转拼接;seen 集防脏数据成环(assets.py:1155 先例)。
    结构化事实不打扰模型(§9):「哪个项目」准确率 100% 由本函数保证。
    """
    asset = await db.get(Asset, asset_id)
    if asset is None or asset.deleted_at is not None:
        return None
    folder = await db.get(Folder, asset.folder_id)
    if folder is None:
        return None
    project = await db.get(Project, folder.project_id)
    names: list[str] = []
    node: Folder | None = folder
    seen: set[uuid.UUID] = set()
    while node is not None and node.id not in seen:
        seen.add(node.id)
        names.append(node.name)
        node = await db.get(Folder, node.parent_folder_id) if node.parent_folder_id else None
    chain = "/".join(reversed(names))
    parts = ((project.name if project else ""), chain, asset.filename or "")
    return "/".join(p for p in parts if p)[:600]


def build_searchable_text(*parts: str | None) -> str:
    """搜索第四路唯一命中面聚合(§9):空段过滤,单空格拼接。"""
    return " ".join(p.strip() for p in parts if p and p.strip())


async def refresh_context(sm: _SessionMaker, asset_ids: list[uuid.UUID] | None = None,
                          folder_id: uuid.UUID | None = None, *,
                          batch_size: int = SWEEP_LIMIT) -> int:
    """§8.6:重拼受影响资产的 annotation context_path + searchable_text。

    asset_ids 与 folder_id(子树全量)至少一个非空;分批 ≤500(顶层目录子树可达
    数千行)。软删/不存在的行跳过(恢复走 restore 钩子重派)。返回更新行数。
    """
    ids = list(asset_ids or [])
    if folder_id is not None:
        ids.extend(await _folder_subtree_asset_ids(sm, folder_id))
    ordered = list(dict.fromkeys(ids))  # 去重保序
    updated = 0
    for start in range(0, len(ordered), batch_size):
        updated += await _refresh_chunk(sm, ordered[start:start + batch_size])
    return updated


async def _folder_subtree_asset_ids(sm: _SessionMaker,
                                    folder_id: uuid.UUID) -> list[uuid.UUID]:
    """folder 子树(含自身)下全部未软删 asset id;BFS 逐层,parent 断链即止。"""
    async with sm() as db:
        folder_ids: list[uuid.UUID] = []
        frontier: list[uuid.UUID] = [folder_id]
        seen: set[uuid.UUID] = set()
        while frontier:
            frontier = [f for f in frontier if f not in seen]
            if not frontier:
                break
            seen.update(frontier)
            folder_ids.extend(frontier)
            rows = await db.execute(
                select(Folder.id).where(Folder.parent_folder_id.in_(frontier)),
            )
            frontier = [r[0] for r in rows]
        rows = await db.execute(
            select(Asset.id).where(
                Asset.folder_id.in_(folder_ids), Asset.deleted_at.is_(None),
            ),
        )
        return [r[0] for r in rows]


async def _refresh_chunk(sm: _SessionMaker, asset_ids: list[uuid.UUID]) -> int:
    """单批刷新(≤500):annotation 重拼 context + 重聚合 searchable(§8.6)。

    searchable 保留 tags/description 原值、只换上下文前缀与重聚合段描述;
    段描述跨版本取全量(segments UNIQUE(asset_id,idx),每资产恰一套)。
    """
    updated = 0
    async with sm() as db:
        anns = (await db.execute(
            select(AssetAiAnnotation).where(AssetAiAnnotation.asset_id.in_(asset_ids)),
        )).scalars().all()
        for ann in anns:
            ctx = await build_context_path_db(db, ann.asset_id)
            if ctx is None:
                continue
            seg_rows = (await db.execute(
                select(AssetVideoSegment.description).where(
                    AssetVideoSegment.asset_id == ann.asset_id,
                    AssetVideoSegment.description.is_not(None),
                ).order_by(AssetVideoSegment.idx),
            )).all()
            searchable = build_searchable_text(
                ctx, *(ann.tags_zh or []), *(ann.tags_en or []),
                ann.description, ann.description_en, *(r[0] for r in seg_rows),
            )
            await db.execute(
                update(AssetAiAnnotation).where(
                    AssetAiAnnotation.asset_id == ann.asset_id,
                    AssetAiAnnotation.model_version == ann.model_version,
                ).values(context_path=ctx, searchable_text=searchable, updated_at=_now()),
            )
            updated += 1
        await db.commit()
    return updated
