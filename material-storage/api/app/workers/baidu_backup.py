"""百度网盘备份 worker — 方案 §6 全机制(arq;批次 3)。

job:`baidu_backup_run(ctx, task_id, expected_seq)`,在 workers/main.py 以
`func(baidu_backup_run, timeout=3600, max_tries=1)` 注册(不设 48h 级 arq 超时 ——
in-progress TTL 按**全部注册 function 的最大超时**计算,注册 172800s 会让普通 job
的 in-progress key 在崩溃重启后残留 48h 被无限跳过)。

机制清单(方案 §6):
- 55min 接力:进程内锚点(job_started monotonic)+ 所有权守卫(relay_dispatch)
  + 行复位 + enqueue 失败交 sweeper;
- 租约 CAS:认领/续期含 status 与 runner_id 谓词;检查点优先级 cancel → 急停
  flag → 48h → 接力;
- 枚举:list_dir 递归(BFS;listall 未在客户端实现,退化方案即唯一路径)、
  ON CONFLICT(task_id, rel_path) 幂等、enum_done、退避封顶 20s/分片、
  20k manifest 护栏;
- 导入循环 7 步:建链先行(memoize)→ 权限复查(is_org_admin 直通 + 会话缓存)
  → skip/overwrite 清除-再导入(跨资产 key 预检 + purge head 断言)→ dlink 懒取
  → multipart 断点/死会话/head 快捷路径(overwrite 禁用)/md5 单段旁证 → asset
  落库(全谓词 + 预检 + baidu_file_imported 审计)→ 缩略图三分派 → 收尾完整谓词;
- sweeper cron:timeout=300、NULL/派发超时谓词、cancel_requested/flag 感知直
  终态化、48h 兜底、30d 孤儿清理逐行 try/except、确定性准入排序前 2。
"""
from __future__ import annotations

import asyncio
import logging
import mimetypes
import time
import uuid
from collections import deque
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from typing import Any

from sqlalchemy import exists, func, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.sql.elements import ColumnElement

from app.db.session import get_sessionmaker
from app.db.tables import Asset, BaiduBinding, Folder, Project
from app.db.tables import BaiduBackupTask as Task
from app.db.tables import BaiduBackupTaskFile as TaskFile
from app.services.asset_purge import PurgeIncompleteError, purge_active_asset
from app.services.audit import AuditService
from app.services.baidu_backup import (
    ACTIVE_STATUSES,
    ENUM_BACKOFF_CAP_S,
    ENUM_BACKOFF_MAX_ATTEMPTS,
    FAIL_BINDING_EXPIRED,
    FAIL_ENUM_FAILED,
    FAIL_ENUM_RATE_LIMITED,
    FAIL_FEATURE_DISABLED,
    FAIL_MANIFEST_TOO_LARGE,
    FAIL_TIMEOUT,
    SLEEP_SHARD_S,
    STATUS_CANCELLED,
    STATUS_COMPLETED,
    STATUS_ENUMERATING,
    STATUS_FAILED,
    STATUS_RUNNING,
    TERMINAL_STATUSES,
    BaiduTaskError,
    admission_top_task_ids,
    aggregate_and_finalize_if_done,
    bump_done_bytes,
    claim_task,
    compute_aggregates,
    dispatch_and_enqueue,
    enqueue_baidu_backup_run,
    ensure_fresh_access_token,
    finalize_rows_cancelled,
    finalize_rows_failed,
    finalize_task_terminal,
    force_refresh_access_token,
    format_key_conflict_message,
    mark_binding_expired,
    recompute_aggregates,
    relay_dispatch,
    release_for_queueing,
    renew_lease,
    reset_importing_rows,
    round_timed_out,
    source_dir_leaf_name,
    statement_rowcount,
    update_speed_anchor,
)
from app.services.baidu_client import (
    CATEGORY_AUTH_EXPIRED,
    CATEGORY_BAIDU_PERMISSION_DENIED,
    CATEGORY_LINK_EXPIRED,
    CATEGORY_NOT_FOUND,
    CATEGORY_RATE_LIMITED,
    BaiduApiError,
    BaiduNetdiskClient,
)
from app.services.baidu_storage import AsyncObjectStore, is_no_such_upload_error
from app.services.folder_chain import (
    FolderChainError,
    ensure_folder_chain,
    ensure_root_folder_at_project,
    guard_file_size,
    guard_rel_path,
)
from app.services.org import get_default_organization
from app.services.permissions import PermissionsService
from app.services.presign import PresignService
from app.services.token_crypto import TokenCryptoService
from app.settings import Settings, get_settings

log = logging.getLogger("worker.baidu")

# ─── 常量(§5.3/§6;时延主值收在 Settings,此处为节奏类常量)───────────────────
RENEW_INTERVAL_S = 5.0          # 下载流内检查点周期(租约 60s ≥ 2x 周期)
PERM_CACHE_TTL_S = 5.0          # (folder,user) 权限检查缓存一个检查点周期(§6 步骤 2)
DLINK_TTL_S = 8 * 3600          # dlink 8h 有效(§2.4)
DLINK_MARGIN_S = 600            # 提前 10min 余量重取
DLINK_BATCH = 100               # filemetas 每批 fsid 上限(§2.4)
ENUM_LIST_MAX_PAGES = 100       # list_dir 聚合页数上限(单目录 10 万条保险丝)
MANIFEST_MAX_FILES = 20_000     # manifest 护栏(§9)
MAX_FILE_ATTEMPTS = 5           # 单文件自动重试上限(§5.3)
FILE_BACKOFF_CAP_S = 20.0       # 单次退避封顶 ≤20s(≤ 租约/3,§5.3)
ORPHAN_BATCH = 50               # sweeper 30d 孤儿清理每轮上限(§6 ≤50 行/批)
SWEEP_BATCH = 50                # sweeper 候选任务每轮上限
ADMISSION_LIMIT = 2             # 确定性准入稳态恰 2(§6:保证缩略图/cron 至少 2 槽)
AUDIT_DEDUP_FMT = "baidu_task:{task_id}:{event}:{ref}:r{retry}:a{attempts}"

# checkpoint 结果:
#   "cancel"/"flag_off"/"timeout"  → 需按归位表终态化(consume_outcome)
#   "lost"                         → 所有权已失,仅停写不改行状态
#   "relayed"/"lost_relay"         → 接力已派发/派发失败交 sweeper,调用方正常退出
_CHECKPOINT_TERMINAL = frozenset({"cancel", "flag_off", "timeout"})
_CHECKPOINT_PASSIVE = frozenset({"lost", "relayed", "lost_relay"})


def _now() -> datetime:
    return datetime.now(UTC)


async def write_audit(**kwargs: Any) -> None:
    """worker 侧审计(独立 session;AuditService.write 自带 commit)。"""
    async with get_sessionmaker()() as session:
        await AuditService(session).write(**kwargs)


@dataclass
class Runner:
    """单次 job 的运行时上下文(租约身份/会话缓存/接力锚点)。"""

    task_id: uuid.UUID
    expected_seq: int
    runner_id: str
    store: AsyncObjectStore
    permissions: PermissionsService
    presign: PresignService
    crypto: TokenCryptoService
    client: BaiduNetdiskClient
    settings: Settings = field(default_factory=get_settings)
    pool: Any = None                     # ctx["redis"](ArqRedis),接力入队用
    binding_id: uuid.UUID | None = None
    user_id: uuid.UUID | None = None
    tenant_key: str | None = None
    folder_memo: dict[tuple[uuid.UUID, str], tuple[uuid.UUID, str]] = field(default_factory=dict)
    perm_cache: dict[tuple[uuid.UUID, uuid.UUID], tuple[float, bool]] = field(default_factory=dict)
    org_admin_cache: tuple[float, bool] | None = None
    consecutive_auth_expired: int = 0    # 吊销兜底计数(§5.3:同任务连续 2 次)
    job_started: float = field(default_factory=time.monotonic)  # 接力锚点(进程内)

    def owned_row_predicate(self) -> ColumnElement[bool]:
        """收尾写完整谓词(§6 步骤 7):lease_seq + runner_id + 活动 + 未取消。"""
        return exists().where(
            Task.id == self.task_id,
            Task.lease_seq == self.expected_seq,
            Task.runner_id == self.runner_id,
            Task.status.in_(ACTIVE_STATUSES),
            Task.cancel_requested.is_(False),
        )


# ─── job 入口 ────────────────────────────────────────────────────────────────


async def baidu_backup_run(ctx: dict[str, Any], task_id: str, expected_seq: int) -> dict[str, str]:
    """单任务全流程 job(§6)。max_tries=1:重试语义完全由自家状态机 + 租约接管实现。"""
    settings = get_settings()
    tid = uuid.UUID(task_id)
    runner_id = uuid.uuid4().hex[:32]
    sm = get_sessionmaker()
    async with sm() as db:
        task = await db.get(Task, tid)
        if task is None:
            return {"status": "task_not_found", "task_id": task_id}
        # job 启动认领 CAS(§6):0 行 = 已被更高 seq 取代,安静退出
        claimed = await claim_task(
            db, task_id=tid, expected_seq=expected_seq, runner_id=runner_id,
            now=_now(), lease_s=settings.baidu_lease_s,
        )
        await db.commit()
        if not claimed:
            return {"status": "claim_lost", "task_id": task_id}

        store = AsyncObjectStore(settings)
        permissions = PermissionsService(settings)
        presign = PresignService(settings)   # 同步 boto3:仅资产清除业务流内部 to_thread
        crypto = TokenCryptoService(settings)
        client = BaiduNetdiskClient(settings)
        runner = Runner(
            task_id=tid, expected_seq=expected_seq, runner_id=runner_id,
            store=store, permissions=permissions, presign=presign,
            crypto=crypto, client=client,
        )
        runner.pool = ctx.get("redis")
        runner.binding_id = task.binding_id
        runner.user_id = task.user_id
        try:
            async with store:
                status = await _run_claimed(db, runner)
        except asyncio.CancelledError:
            # arq 取消/SIGTERM:一律 re-raise 不落终态,交 sweeper 接管(§6);
            # 部署重启对在途任务无损
            raise
        except BaiduTaskError as e:
            log.warning("baidu job task error task=%s err=%s(交 sweeper 接管)", tid, e)
            return {"status": "task_error", "task_id": task_id}
        except Exception:
            log.exception("baidu job crashed task=%s(交 sweeper 接管,断点无损)", tid)
            return {"status": "error", "task_id": task_id}
        finally:
            await permissions.close()
            await client.close()
        return {"status": status, "task_id": task_id}


async def _run_claimed(db: AsyncSession, runner: Runner) -> str:
    """认领成功后的主路径:急停 flag → 确定性准入 → 枚举/导入分派。"""
    settings = runner.settings
    task = await db.get(Task, runner.task_id)
    if task is None:
        return "task_not_found"

    # 急停 flag(worker 启动兜底;§6 急停③)
    if not settings.baidu_backup_enabled:
        return await _finalize_failed_worker(
            db, runner, fail_reason=FAIL_FEATURE_DISABLED, reason_row="feature_disabled",
        )

    # 确定性准入(§6):非「活动中任务按 round_started_at NULLS LAST, created_at, id
    # 排序前 2 名」→ 复位轮钟并清租约,安静退出交 sweeper 重派(10min 节流);
    # 不可由 job 侧自派发(会形成认领→退出→再拾取的自旋热循环)
    top = await admission_top_task_ids(db, limit=ADMISSION_LIMIT)
    if runner.task_id not in top:
        await release_for_queueing(
            db, task_id=runner.task_id, expected_seq=runner.expected_seq,
            runner_id=runner.runner_id,
        )
        await db.commit()
        log.info("baidu job queued out(admission) task=%s", runner.task_id)
        return "queued"

    org = await get_default_organization(db)
    runner.tenant_key = org[1] if org else None

    if task.status == STATUS_ENUMERATING:
        return await _enumerate(db, runner)
    return await _import_loop(db, runner)


# ─── 检查点(§6 优先级:cancel → 急停 flag → 48h → 接力)──────────────────────


async def checkpoint(db: AsyncSession, runner: Runner) -> str | None:
    """租约续期(即心跳)+ 检查点判定;None = 继续。"""
    now = _now()
    state = await renew_lease(
        db, task_id=runner.task_id, expected_seq=runner.expected_seq,
        runner_id=runner.runner_id, now=now, lease_s=runner.settings.baidu_lease_s,
    )
    await db.commit()
    if state is None:
        return "lost"
    if state.cancel_requested:
        return "cancel"   # 取消意图恒最高优先(与「取消路径恒 cancelled 优先于聚合判定」一致)
    if not runner.settings.baidu_backup_enabled:
        return "flag_off"
    if round_timed_out(state.round_started_at, now, runner.settings.baidu_round_timeout_s):
        return "timeout"  # runner 主路径 48h 自判停(健康接力链上 sweeper 永不可见)
    if time.monotonic() - runner.job_started >= runner.settings.baidu_relay_after_s:
        seq = await relay_dispatch(
            db, task_id=runner.task_id, expected_seq=runner.expected_seq,
            runner_id=runner.runner_id, now=_now(),
        )
        await db.commit()
        if seq is None:
            return "lost"  # 失去所有权(被 sweeper 接管等),直接退出不入队
        if runner.pool is not None and await enqueue_baidu_backup_run(
            runner.pool, runner.task_id, seq,
        ):
            log.info("baidu relayed task=%s seq=%s", runner.task_id, seq)
            return "relayed"
        # enqueue 失败不重试、交 sweeper(UPDATE 已置 runner_id=NULL,重试派发的
        # 所有权守卫在本分支永不命中;断点无损,≤10-15min 接管,§6)
        log.warning("baidu relay enqueue failed task=%s seq=%s(交 sweeper)", runner.task_id, seq)
        return "lost_relay"
    await update_speed_anchor(
        db, task_id=runner.task_id, expected_seq=runner.expected_seq,
        runner_id=runner.runner_id, now=now,
    )
    await db.commit()
    return None


async def consume_outcome(db: AsyncSession, runner: Runner, outcome: str) -> str:
    """检查点终态分支的统一处置(归位表);返回传播结果。"""
    if outcome in _CHECKPOINT_PASSIVE:
        return outcome
    if outcome == "cancel":
        await _finalize_cancelled(db, runner)
        return "cancelled"
    if outcome == "flag_off":
        return await _finalize_failed_worker(
            db, runner, fail_reason=FAIL_FEATURE_DISABLED, reason_row="feature_disabled",
        )
    if outcome == "timeout":
        return await _finalize_failed_worker(
            db, runner, fail_reason=FAIL_TIMEOUT, reason_row="task_timeout",
        )
    return outcome


# ─── 终态化(worker 侧;async abort 走 AsyncObjectStore)──────────────────────


async def _abort_sessions_async(
    store: AsyncObjectStore, rows: list[Any],
) -> list[uuid.UUID]:
    """归位表 abort 分支的存储侧:abort 成功(含 NoSuchUpload=已清理)返回可清列
    的行;抛错保留列交 sweeper 30d 通道。rows 元素 (file_id, bucket, key, upload_id)。"""
    cleared: list[uuid.UUID] = []
    for file_id, bucket, key, upload_id in rows:
        try:
            await store.abort_multipart_upload(bucket, key, upload_id)
            cleared.append(file_id)
        except Exception as e:
            if is_no_such_upload_error(e):
                cleared.append(file_id)
            else:
                log.warning("abort session fail file=%s err=%s(保留列交 sweeper)", file_id, e)
    return cleared


async def _load_session_rows(db: AsyncSession, task_id: uuid.UUID) -> list[Any]:
    res = await db.execute(
        select(TaskFile.id, TaskFile.minio_bucket, TaskFile.minio_key, TaskFile.minio_upload_id)
        .where(TaskFile.task_id == task_id, TaskFile.minio_upload_id.is_not(None))
    )
    return list(res.all())


async def _clear_session_columns(db: AsyncSession, cleared: list[uuid.UUID]) -> None:
    if cleared:
        await db.execute(
            update(TaskFile)
            .where(TaskFile.id.in_(cleared))
            .values(minio_upload_id=None, bytes_done=0)
        )
        await db.commit()


async def _finalize_cancelled(db: AsyncSession, runner: Runner) -> None:
    """取消消费(归位表 cancelled 分支):行复位 → 终态化 → 聚合 → abort + 清列。"""
    session_rows = await _load_session_rows(db, runner.task_id)
    await finalize_rows_cancelled(db, task_id=runner.task_id)
    await finalize_task_terminal(db, task_id=runner.task_id, status=STATUS_CANCELLED)
    await recompute_aggregates(db, task_id=runner.task_id)
    await db.commit()
    cleared = await _abort_sessions_async(runner.store, session_rows)
    await _clear_session_columns(db, cleared)
    log.info("baidu task finalized cancelled task=%s aborted=%d", runner.task_id, len(cleared))


async def _finalize_failed_worker(
    db: AsyncSession, runner: Runner, *, fail_reason: str, reason_row: str,
) -> str:
    """failed 归位分支(检查点侧):timeout/feature_disabled 保留断点;
    binding_expired abort + 清空;系统侧终态以 actor=NULL 落 baidu_task_auto_finalized。"""
    keep_sessions = fail_reason in (FAIL_TIMEOUT, FAIL_FEATURE_DISABLED)
    session_rows = [] if keep_sessions else await _load_session_rows(db, runner.task_id)
    await finalize_rows_failed(db, task_id=runner.task_id, reason=reason_row, overwrite_note=True)
    await finalize_task_terminal(
        db, task_id=runner.task_id, status=STATUS_FAILED, fail_reason=fail_reason,
    )
    await recompute_aggregates(db, task_id=runner.task_id)
    await db.commit()
    if not keep_sessions:
        cleared = await _abort_sessions_async(runner.store, session_rows)
        await _clear_session_columns(db, cleared)
    await write_audit(
        event_type="baidu_task_auto_finalized",
        actor_user_id=None,
        details={"task_id": str(runner.task_id), "fail_reason": fail_reason,
                 "runner": "checkpoint"},
    )
    log.info("baidu task finalized failed task=%s reason=%s", runner.task_id, fail_reason)
    return f"failed:{fail_reason}"


async def _finalize_binding_expired(db: AsyncSession, runner: Runner) -> str:
    """refresh 确认失效 → binding=expired + 任务 failed('binding_expired')(§5.3);
    归位表:abort + 清空断点(此终态大概率伴随用户重新绑定)。"""
    if runner.binding_id is not None:
        await mark_binding_expired(db, runner.binding_id)
    return await _finalize_failed_worker(
        db, runner, fail_reason=FAIL_BINDING_EXPIRED, reason_row="binding_expired",
    )


async def _finalize_task_only_failed(
    db: AsyncSession, runner: Runner, *, fail_reason: str, message: str,
) -> str:
    """枚举期任务级失败(enum_* / manifest_too_large):pending 行原样保留
    (复活按 enum_done=false 走重枚举,机制自洽,§6 归位表)。"""
    await finalize_task_terminal(
        db, task_id=runner.task_id, status=STATUS_FAILED, fail_reason=fail_reason,
    )
    await recompute_aggregates(db, task_id=runner.task_id)
    await db.commit()
    await write_audit(
        event_type="baidu_task_auto_finalized",
        actor_user_id=None,
        details={"task_id": str(runner.task_id), "fail_reason": fail_reason,
                 "message": message[:256], "runner": "enum"},
    )
    log.warning("baidu enum failed task=%s reason=%s msg=%s", runner.task_id, fail_reason, message)
    return f"failed:{fail_reason}"


# ─── token(§5.3 单飞上收后的 worker 侧封装)──────────────────────────────────


async def _current_token(
    db: AsyncSession, runner: Runner, *, force_refresh: bool = False,
) -> str:
    binding = await db.get(BaiduBinding, runner.binding_id) if runner.binding_id else None
    if binding is None or binding.status != "active":
        raise BaiduTaskError("百度网盘绑定已失效", code="binding_inactive")
    if force_refresh or runner.consecutive_auth_expired >= 2:
        # 吊销兜底(§5.3):token 提前失效时强制走一次 refresh 单飞
        token = await force_refresh_access_token(
            db, binding.id, crypto=runner.crypto, client=runner.client,
        )
        runner.consecutive_auth_expired = 0
        return token
    return await ensure_fresh_access_token(db, binding, crypto=runner.crypto, client=runner.client)


# ─── 枚举期(§6;listall 未实现 → list 递归退化即唯一路径)────────────────────


async def _sharded_backoff(db: AsyncSession, runner: Runner, seconds: float) -> str | None:
    """分片退避(每 ≤10s 醒来做一次续期 + 取消检查,§5.3);返回检查点结果。"""
    remaining = seconds
    while remaining > 0:
        await asyncio.sleep(min(SLEEP_SHARD_S, remaining))
        remaining -= SLEEP_SHARD_S
        outcome = await checkpoint(db, runner)
        if outcome is not None:
            return outcome
    return None


async def _enum_list_with_retry(
    db: AsyncSession, runner: Runner, dir_path: str,
) -> tuple[Any | None, str | None]:
    """列单目录,带百度错误分类的枚举退避;返回 (result | None, outcome | None)。

    outcome 非 None 表示任务已被终态化/需退出(cancel/flag/timeout/relay/enum 失败)。
    """
    backoff = 1.0
    for attempt in range(ENUM_BACKOFF_MAX_ATTEMPTS):
        outcome = await checkpoint(db, runner)
        if outcome is not None:
            return None, outcome
        try:
            token = await _current_token(db, runner)
            result = await runner.client.list_dir(token, dir_path, max_pages=ENUM_LIST_MAX_PAGES)
            runner.consecutive_auth_expired = 0
            return result, None
        except BaiduApiError as e:
            if e.category == CATEGORY_AUTH_EXPIRED:
                runner.consecutive_auth_expired += 1
                continue  # 下轮 _current_token 走 ensure/force refresh
            if e.category == CATEGORY_RATE_LIMITED:
                log.info("baidu enum rate limited task=%s dir=%s attempt=%s backoff=%.1fs",
                         runner.task_id, dir_path, attempt + 1, backoff)
                outcome = await _sharded_backoff(db, runner, backoff)
                if outcome is not None:
                    return None, outcome
                backoff = min(backoff * 2, ENUM_BACKOFF_CAP_S)
                continue
            return None, f"enum_failed:{e.category}:{e.message}"
        except BaiduTaskError:
            # binding_inactive(refresh 确认失效/密钥轮换)→ 任务 failed(binding_expired)
            return None, "binding_expired"
    return None, f"enum_rate_limited:dir={dir_path}"


async def _insert_manifest_rows(
    db: AsyncSession, runner: Runner, rows: list[dict[str, Any]],
) -> None:
    """manifest 幂等写入(§6):ON CONFLICT(task_id, rel_path) DO NOTHING ——
    接管/重跑不得重置已有 success/skipped/failed 状态、不得因重枚举崩循环。"""
    if not rows:
        return
    stmt = pg_insert(TaskFile).values(rows).on_conflict_do_nothing(
        index_elements=["task_id", "rel_path"],
    )
    await db.execute(stmt)
    await db.commit()


async def _consume_enum_outcome(db: AsyncSession, runner: Runner, outcome: str) -> str:
    """枚举期检查点/错误结果的分派:checkpoint 三终态走统一消费;binding_expired
    与 enum_* 走任务级失败(pending 行原样保留,§6 归位表)。"""
    if outcome in _CHECKPOINT_TERMINAL or outcome in _CHECKPOINT_PASSIVE:
        return await consume_outcome(db, runner, outcome)
    if outcome == "binding_expired":
        return await _finalize_binding_expired(db, runner)
    if outcome.startswith("enum_rate_limited"):
        return await _finalize_task_only_failed(
            db, runner, fail_reason=FAIL_ENUM_RATE_LIMITED, message=outcome,
        )
    return await _finalize_task_only_failed(
        db, runner, fail_reason=FAIL_ENUM_FAILED, message=outcome.removeprefix("enum_failed:"),
    )


async def _enumerate(db: AsyncSession, runner: Runner) -> str:
    """枚举仅对 status='enumerating' 执行(§6;接管/续轮的 running 任务已有
    manifest,直接进导入循环);BFS list_dir 分页写 manifest。"""
    task = await db.get(Task, runner.task_id)
    if task is None:
        return "task_not_found"
    part_size = runner.settings.baidu_part_size_bytes

    # 枚举期静态护栏的 prefix 口径:target_folder_id 为 NULL(创建后夹被删)时,
    # auto_created 重建承接夹写回;显式目标 → 任务级失败(承接夹语义已不可恢复)
    target_folder_id = task.target_folder_id
    if target_folder_id is None:
        if task.target_auto_created:
            node = await ensure_root_folder_at_project(
                db, runner.permissions, project_id=task.project_id,
                name=source_dir_leaf_name(task.source_dir),
            )
            await db.execute(
                update(Task).where(Task.id == runner.task_id)
                .values(target_folder_id=node.folder_id)
            )
            await db.commit()
            target_folder_id = node.folder_id
        else:
            return await _finalize_task_only_failed(
                db, runner, fail_reason=FAIL_ENUM_FAILED, message="目标文件夹已被删除",
            )
    root = await db.get(Folder, target_folder_id)
    if root is None:
        return await _finalize_task_only_failed(
            db, runner, fail_reason=FAIL_ENUM_FAILED, message="目标文件夹已被删除",
        )
    prefix = root.minio_prefix

    dirs: deque[tuple[str, str]] = deque([(task.source_dir, "")])
    while dirs:
        dir_path, rel_prefix = dirs.popleft()
        result, outcome = await _enum_list_with_retry(db, runner, dir_path)
        if outcome is not None:
            return await _consume_enum_outcome(db, runner, outcome)
        assert result is not None
        if result.truncated:
            return await _finalize_task_only_failed(
                db, runner, fail_reason=FAIL_ENUM_FAILED,
                message=f"目录条目超聚合上限:{dir_path}",
            )
        manifest_rows: list[dict[str, Any]] = []
        for item in result.items:
            path = str(item.get("path") or "")
            if not path:
                continue
            if int(item.get("isdir", 0)) == 1:
                seg = path.rstrip("/").rpartition("/")[2]
                dirs.append((path, f"{rel_prefix}{seg}/"))
                continue
            seg = path.rpartition("/")[2]
            rel_path = f"{rel_prefix}{seg}"
            # 长度/大小护栏枚举期静态校验,不进下载流程;结构性失败一律
            # non_retryable=true(重试不可能改变路径/大小结构,§4)
            guard = guard_rel_path(prefix, rel_path) or guard_file_size(
                int(item.get("size", 0)), part_size,
            )
            row: dict[str, Any] = {
                "task_id": runner.task_id,
                "fs_id": int(item.get("fs_id", 0)),
                "source_path": path,
                "source_size": int(item.get("size", 0)),
                "rel_path": rel_path,
            }
            if guard is not None:
                row.update(status="failed", last_error=guard, non_retryable=True)
            manifest_rows.append(row)
        await _insert_manifest_rows(db, runner, manifest_rows)
        total = await db.scalar(
            select(func.count()).select_from(TaskFile).where(TaskFile.task_id == runner.task_id)
        )
        if (total or 0) > MANIFEST_MAX_FILES:
            return await _finalize_task_only_failed(
                db, runner, fail_reason=FAIL_MANIFEST_TOO_LARGE,
                message=f"manifest 超 {MANIFEST_MAX_FILES} 文件护栏",
            )

    # 枚举完成:0 行 → 直接 completed(空目录,§4);否则置 running + enum_done
    agg = await compute_aggregates(db, task_id=runner.task_id)
    await db.commit()
    if agg.total_files == 0:
        await finalize_task_terminal(db, task_id=runner.task_id, status=STATUS_COMPLETED)
        await recompute_aggregates(db, task_id=runner.task_id)
        await db.commit()
        log.info("baidu enum empty dir task=%s → completed(源目录为空)", runner.task_id)
        return "completed_empty"
    await db.execute(
        update(Task)
        .where(Task.id == runner.task_id, Task.status == STATUS_ENUMERATING)
        .values(status=STATUS_RUNNING, enum_done=True)
    )
    await recompute_aggregates(db, task_id=runner.task_id)
    await db.commit()
    log.info("baidu enum done task=%s total_files=%d → import loop", runner.task_id, agg.total_files)
    return await _import_loop(db, runner)


# ─── 导入循环(§6 步骤 1-7)──────────────────────────────────────────────────


class _LinkRefreshNeeded(Exception):
    """link_expired(含 errno 31360):清 dlink 缓存,重新 filemetas 后重试(§5.3)。"""


class _UploadSessionLost(Exception):
    """complete 时 NoSuchUpload(会话在传输窗口内被 lifecycle/并发清掉)。"""


async def _next_pending_row(db: AsyncSession, task_id: uuid.UUID) -> TaskFile | None:
    return (await db.execute(
        select(TaskFile)
        .where(TaskFile.task_id == task_id, TaskFile.status == "pending")
        .order_by(TaskFile.id)
        .limit(1)
    )).scalar_one_or_none()


async def _import_loop(db: AsyncSession, runner: Runner) -> str:
    """导入循环:每轮仅选取 status='pending' 的 manifest 行(§6;单文件 retry 不得
    触碰其他 failed 行);循环结束(无 pending/importing 行)时按三分支判定终态。"""
    while True:
        outcome = await checkpoint(db, runner)
        if outcome is not None:
            return await consume_outcome(db, runner, outcome)
        row = await _next_pending_row(db, runner.task_id)
        if row is None:
            break
        await db.execute(
            update(TaskFile)
            .where(TaskFile.id == row.id)
            .values(status="importing", attempts=TaskFile.attempts + 1)
        )
        await db.commit()
        result = await _import_one_file(db, runner, row)
        if result == "ok":
            runner.consecutive_auth_expired = 0
            continue
        if result in _CHECKPOINT_TERMINAL:
            # 传输中段的原始检查点结果(cancel/flag_off/timeout)在此统一消费
            return await consume_outcome(db, runner, result)
        return result   # checkpoint 已消费的终态/被动结果,向上传播
    status = await aggregate_and_finalize_if_done(db, task_id=runner.task_id)
    await db.commit()
    if status is None:
        return "done"   # 仍有 pending/importing(理论不可达:循环以无 pending 退出)
    log.info("baidu import loop finished task=%s status=%s", runner.task_id, status)
    return status


async def _fail_row(
    db: AsyncSession, runner: Runner, row: TaskFile, code: str, *,
    non_retryable: bool = False, message: str | None = None, clear_overwrite: bool = False,
) -> str:
    """行级失败(终态写带完整所有权谓词;§6 行级 failed 保留断点字段供续传)。"""
    values: dict[str, Any] = {
        "status": "failed",
        # last_error 统一 "<code>: <人类文案>" 结构化前缀(机器可断言;其后保留
        # 人类文案与原始 HTTP/errno,§5.3「last_error 保留原始 HTTP/errno 以区分」)
        "last_error": (f"{code}: {message}" if message else code)[:512],
        "non_retryable": non_retryable,
    }
    if clear_overwrite:
        values["overwrite"] = False
    res = await db.execute(
        update(TaskFile)
        .where(TaskFile.id == row.id, runner.owned_row_predicate())
        .values(**values)
    )
    if statement_rowcount(res) == 0:
        return "lost"
    await recompute_aggregates(db, task_id=runner.task_id)
    await db.commit()
    log.info("baidu file failed task=%s file=%s code=%s", runner.task_id, row.id, code)
    return "ok"


async def _mark_skipped(db: AsyncSession, runner: Runner, row: TaskFile) -> str:
    res = await db.execute(
        update(TaskFile)
        .where(TaskFile.id == row.id, runner.owned_row_predicate())
        .values(status="skipped_exists")
    )
    if statement_rowcount(res) == 0:
        return "lost"
    await recompute_aggregates(db, task_id=runner.task_id)
    await db.commit()
    return "ok"


async def _org_admin_allowed(runner: Runner) -> bool:
    """is_org_admin 直通(§6 步骤 2:org admin 在 FGA 中不必然持有 folder tuple,
    纯 check 会让系统管理员的任务全量失败);结果缓存一个检查点周期。"""
    if runner.tenant_key is None or runner.user_id is None:
        return False
    cached = runner.org_admin_cache
    if cached is not None and time.monotonic() < cached[0]:
        return cached[1]
    try:
        ok = await runner.permissions.is_org_admin(
            user_id=str(runner.user_id), organization_tenant_key=runner.tenant_key,
        )
    except Exception:
        ok = False
    runner.org_admin_cache = (time.monotonic() + PERM_CACHE_TTL_S, ok)
    return ok


async def _check_upload_perm(db: AsyncSession, runner: Runner, folder_id: uuid.UUID) -> bool:
    """can_upload 复查(is_org_admin or check,对齐 complete_upload 完成时复查先例);
    同一 (folder,user) 的 check 结果在 runner 会话内缓存一个检查点周期 ≤5s。"""
    if runner.user_id is None:
        return False
    cache_key = (folder_id, runner.user_id)
    cached = runner.perm_cache.get(cache_key)
    if cached is not None and time.monotonic() < cached[0]:
        return cached[1]
    allowed = await _org_admin_allowed(runner) or await runner.permissions.check(
        user_subject=f"user:{runner.user_id}", relation="can_upload",
        object_type="folder", object_id=str(folder_id),
    )
    runner.perm_cache[cache_key] = (time.monotonic() + PERM_CACHE_TTL_S, allowed)
    return allowed


async def _key_conflict_holders(
    db: AsyncSession, *, bucket: str, key: str, exclude_asset_id: uuid.UUID | None,
) -> list[Asset]:
    """跨资产 key 占用行明细(含软删,与既有跨资产 key 预检计数口径一致;§6
    步骤 2/5):F1 点名占用者与 F2a 逐行权限复查共用。"""
    conditions = [Asset.minio_bucket == bucket, Asset.minio_key == key]
    if exclude_asset_id is not None:
        conditions.append(Asset.id != exclude_asset_id)
    res = await db.execute(select(Asset).where(*conditions).order_by(Asset.id))
    return list(res.scalars().all())


def _holder_names(holders: list[Asset]) -> list[tuple[str, bool]]:
    """F1 文案入参:(filename, 是否软删)(软删者附`(回收站)`)。"""
    return [(h.filename, h.deleted_at is not None) for h in holders]


def _content_type_for(filename: str) -> str:
    return mimetypes.guess_type(filename)[0] or "application/octet-stream"


async def _import_one_file(db: AsyncSession, runner: Runner, row: TaskFile) -> str:
    """单文件导入(§6 步骤 1-7)。返回 "ok" / 已消费的 checkpoint 结果。"""
    task = await db.get(Task, runner.task_id)
    if task is None:
        return "task_not_found"
    project = await db.get(Project, task.project_id)
    if project is None:
        return await _fail_row(db, runner, row, "project_missing")
    bucket = project.minio_bucket
    filename = row.rel_path.rpartition("/")[2]
    dir_parts = row.rel_path.split("/")[:-1]

    # ── 步骤 1:建链先行(memoize 每轮仅首次写;结果写回 target_folder_id)──────
    target_folder_id = task.target_folder_id
    if target_folder_id is None:
        if task.target_auto_created:
            node = await ensure_root_folder_at_project(
                db, runner.permissions, project_id=task.project_id,
                name=source_dir_leaf_name(task.source_dir),
            )
            await db.execute(
                update(Task).where(Task.id == runner.task_id)
                .values(target_folder_id=node.folder_id)
            )
            await db.commit()
            target_folder_id = node.folder_id
            task.target_folder_id = node.folder_id
        else:
            # 显式目标夹被删(SET NULL)→ 行 failed('target_deleted')(§6 步骤 1)
            return await _fail_row(db, runner, row, "target_deleted")
    try:
        node = await ensure_folder_chain(
            db, runner.permissions, project_id=task.project_id,
            root_folder_id=target_folder_id, rel_dir_parts=dir_parts,
            leaf_name=filename, memo=runner.folder_memo,
        )
    except FolderChainError as e:
        return await _fail_row(
            db, runner, row, e.code, non_retryable=e.non_retryable, message=str(e),
        )
    if node.folder_id != row.target_folder_id:
        await db.execute(
            update(TaskFile).where(TaskFile.id == row.id)
            .values(target_folder_id=node.folder_id)
        )
        await db.commit()
    folder_id = node.folder_id
    key = f"{node.prefix.rstrip('/')}/{filename}"
    # F2b:预留 key 行(random-suffix 导入)全程用预定 key 落库,filename 不变
    # (head 快捷/md5 旁证/multipart 会话/complete 前复检/asset 落库均按最终 key)
    if row.reserved_key:
        key = row.reserved_key

    # ── 步骤 2:权限复查与同名处置(对象=建链后的行落位目录,§6)──────────────
    if not await _check_upload_perm(db, runner, folder_id):
        # 行级权限复查失败可重试(权限恢复后 retry 即可,§6)
        return await _fail_row(db, runner, row, "target_permission_denied")
    existing_assets = (await db.execute(
        select(Asset).where(
            Asset.folder_id == folder_id,
            Asset.filename == filename,
            Asset.deleted_at.is_(None),
        )
    )).scalars().all()
    if existing_assets and not row.overwrite and not row.reserved_key:
        # 预留 key 行的 key 不与同名行冲突(filename 重名不共享物理对象),不适用
        # 既有「同名跳过」语义(F2b:filename 保持网盘原文件名)
        return await _mark_skipped(db, runner, row)
    suppress_head_shortcut = False
    if existing_assets and row.overwrite and not row.reserved_key:
        # 清除-再导入:复查 can_admin + 目标夹非 sensitive + 跨资产 key → purge
        # (仅 canonical key 行;预留 key 行的同名文件与目标 key 无关,不得误清,
        # 其 key 占用统一交 _transfer_and_finalize 首检按 key 占用处置)
        fail = await _overwrite_precheck_and_purge(
            db, runner, row, existing_assets[0], folder_id, bucket, key,
            same_name_count=len(existing_assets), operator_user_id=task.user_id,
        )
        if fail is not None:
            return fail
    elif row.overwrite:
        # overwrite 行复查发现旧 asset 已不存在(含 purge_incomplete 重试场景)
        # → 视为已清除完成直接导入,且禁用 head 快捷路径直至 success(§6)
        suppress_head_shortcut = True

    # ── 步骤 3-4:dlink 懒取 + multipart 断点续传(含单文件自动重试 ≤5 次)────
    attempt = 1
    while attempt <= MAX_FILE_ATTEMPTS:
        outcome = await checkpoint(db, runner)
        if outcome is not None:
            return await consume_outcome(db, runner, outcome)
        try:
            dlink = await _ensure_dlink(db, runner, row)
        except BaiduApiError as e:
            handled = await _handle_baidu_error(db, runner, row, e)
            if handled is not None:
                return handled
            attempt += 1
            continue
        except BaiduTaskError:
            return await _finalize_binding_expired(db, runner)
        try:
            return await _transfer_and_finalize(
                db, runner, row, task, project, dlink,
                bucket=bucket, key=key, folder_id=folder_id, filename=filename,
                suppress_head_shortcut=suppress_head_shortcut,
            )
        except _LinkRefreshNeeded:
            attempt += 1
            continue
        except _UploadSessionLost:
            # complete 时 NoSuchUpload(会话在传输窗口内死亡)→ 行保持 importing,
            # 下一轮重试走 list_parts NoSuchUpload 路径从 0 重传
            log.info("baidu upload session lost task=%s file=%s(重试)",
                     runner.task_id, row.id)
            attempt += 1
            continue
        except BaiduTaskError:
            return await _finalize_binding_expired(db, runner)
        except BaiduApiError as e:
            if e.category == CATEGORY_RATE_LIMITED:
                # 403 甄别(§5.3):dlink_fetched_at 早于 token_rotated_at → 旧账号
                # dlink 配新 token 常表现为 403,先重取一次 filemetas 再归类
                await _maybe_invalidate_stale_dlink(db, runner, row)
                backoff = min(2.0 ** attempt, FILE_BACKOFF_CAP_S)
                log.info("baidu file rate limited task=%s file=%s attempt=%d backoff=%.1f",
                         runner.task_id, row.id, attempt, backoff)
                slp = await _sharded_backoff(db, runner, backoff)
                if slp is not None:
                    return await consume_outcome(db, runner, slp)
            else:
                handled = await _handle_baidu_error(db, runner, row, e)
                if handled is not None:
                    return handled
            attempt += 1
    # 退避耗尽 → 行 failed('rate_limited') 交手动重试(手动复活时 attempts 归零,§5.3)
    return await _fail_row(
        db, runner, row, "rate_limited",
        message="下载重试上限(百度账号级限速),请稍后手动重试",
    )


async def _maybe_invalidate_stale_dlink(
    db: AsyncSession, runner: Runner, row: TaskFile,
) -> None:
    """403 甄别(§5.3):dlink_fetched_at 早于 token_rotated_at(任何 token 覆盖
    写入都刷新该列)→ 先重取一次 filemetas 换新 dlink 再归类,防白耗退避配额。"""
    if row.dlink is None or row.dlink_fetched_at is None:
        return
    binding = await db.get(BaiduBinding, runner.binding_id) if runner.binding_id else None
    if binding is None or binding.token_rotated_at is None:
        return
    if row.dlink_fetched_at < binding.token_rotated_at:
        await db.execute(
            update(TaskFile).where(TaskFile.id == row.id)
            .values(dlink=None, dlink_expires_at=None)
        )
        await db.commit()
        row.dlink = None
        log.info("baidu stale dlink invalidated task=%s file=%s(403 甄别)", runner.task_id, row.id)


async def _handle_baidu_error(
    db: AsyncSession, runner: Runner, row: TaskFile, e: BaiduApiError,
) -> str | None:
    """非退避类百度错误的行级处置(§5.3);None = 已处理可继续重试。

    - baidu_permission_denied:行 failed 置 non_retryable、last_error 直译 errno
      (403 一刀切会把权限错误烧光退避并产出误导性"频控"失败原因)
    - not_found:以一次全新 filemetas 复核确认(复核确认才落 non_retryable ——
      防抖动期偶发 -9 不可逆置位);换绑后 last_error 文案甄别(快照列比较)
    - link_expired + errno=31045:refresh-first 回退(见 _handle_errno_31045)
    - auth_expired:计数,由 _current_token 在下轮走 refresh/force refresh
    """
    if e.category == CATEGORY_BAIDU_PERMISSION_DENIED:
        return await _fail_row(db, runner, row, "baidu_permission_denied",
                               non_retryable=True, message=e.message)
    if e.category == CATEGORY_NOT_FOUND:
        if await _refilemeta_not_found(db, runner, row.fs_id):
            task = await db.get(Task, runner.task_id)
            binding = await db.get(BaiduBinding, runner.binding_id) if runner.binding_id else None
            message = e.message
            if (task is not None and binding is not None
                    and task.bound_baidu_uid != binding.baidu_uid):
                message = "原绑定账号已更换,建议删除任务重建"
            return await _fail_row(db, runner, row, "not_found",
                                   non_retryable=True, message=message)
        return None
    if e.category == CATEGORY_LINK_EXPIRED and e.errno == 31045:
        # 31045(token 校验未通过,语义待定):§5.3 先按 auth_expired 试一次 refresh
        # 再回落 link_expired;两分支均以「重取 dlink + 交调用方重试循环」收尾,
        # 不误杀绑定、不落 non_retryable
        await _handle_errno_31045(db, runner, row)
        return None
    if e.category == CATEGORY_AUTH_EXPIRED:
        runner.consecutive_auth_expired += 1
        return None
    return None


async def _handle_errno_31045(
    db: AsyncSession, runner: Runner, row: TaskFile,
) -> None:
    """31045 refresh-first 回退(§5.3):先按 auth_expired 强制试一次 refresh
    (成功则原子覆盖 binding 双 token + 过期时间,与 §4 覆盖口径一致),随后按
    link_expired 语义重取一次 dlink;refresh 失败不重试不置 expired(按可重试
    处理,防误杀绑定),回落 link_expired 路径。重试循环凭内存中的新 dlink 续跑。

    已知取舍:此处绕过 refresh 单飞 helper 直调 client(force 语义 + 单任务
    单 runner 持有绑定,竞态窗口仅剩 API 侧自然过期刷新,可接受);仅内存更新
    行 dlink(dlink 本就是懒取缓存,崩溃后下轮重取自愈)。
    """
    binding = await db.get(BaiduBinding, runner.binding_id) if runner.binding_id else None
    refresh_token_plain = ""
    if binding is not None and binding.status == "active":
        try:
            refresh_token_plain = runner.crypto.decrypt(binding.refresh_token_enc)
        except Exception:
            refresh_token_plain = ""   # 密文不可解(密钥轮换)→ refresh 必败 → 回落
    refreshed_token: str | None = None
    try:
        tokens = await runner.client.refresh_token(refresh_token_plain)
    except Exception as refresh_err:
        log.info("baidu 31045 refresh-first failed task=%s file=%s err=%s(回落 link_expired)",
                 runner.task_id, row.id, refresh_err)
    else:
        if binding is not None:
            now = _now()
            binding.access_token_enc = runner.crypto.encrypt(tokens.access_token)
            binding.refresh_token_enc = runner.crypto.encrypt(tokens.refresh_token)
            binding.access_token_expires_at = now + timedelta(seconds=tokens.expires_in)
            binding.token_rotated_at = now   # 任何 token 覆盖写入都刷新(403 甄别锚点,§4)
            await db.commit()
        runner.consecutive_auth_expired = 0
        refreshed_token = tokens.access_token
        log.info("baidu 31045 refresh-first ok task=%s file=%s(重取 dlink 续跑)",
                 runner.task_id, row.id)
    await _refetch_dlink_once(db, runner, row, prefer_token=refreshed_token)


async def _refetch_dlink_once(
    db: AsyncSession, runner: Runner, row: TaskFile, *, prefer_token: str | None = None,
) -> None:
    """31045 处置的重取 dlink 步(link_expired 语义):一次批量 filemetas 换新
    dlink;仅内存更新行缓存(交调用方重试循环使用),任何失败静默返回 —— 循环
    会按原路径(_ensure_dlink/重试)再甄别,不在此放大错误。"""
    token = prefer_token
    if not token:
        try:
            token = await _current_token(db, runner)
        except Exception:
            token = ""   # 绑定不可用:仍发一次重取,失败交循环甄别
    try:
        metas = await runner.client.filemetas_batch(token, [row.fs_id], dlink=True)
    except Exception as meta_err:
        log.info("baidu 31045 dlink refetch failed task=%s file=%s err=%s",
                 runner.task_id, row.id, meta_err)
        return
    meta = next((m for m in metas if int(m.get("fs_id", 0)) == row.fs_id), None)
    dlink = str((meta or {}).get("dlink") or "")
    if not dlink:
        return
    now = _now()
    row.dlink = dlink
    row.dlink_fetched_at = now
    row.dlink_expires_at = now + timedelta(seconds=DLINK_TTL_S)


async def _refilemeta_not_found(db: AsyncSession, runner: Runner, fs_id: int) -> bool:
    """一次全新 filemetas 复核(§5.3「两次均 -9 才落 non_retryable」):复核成功
    返回空列表、或复核再次抛 -9(not_found 类),均计为第二次确认;复核其他错误
    不可确认保持可重试(抖动期偶发错误不得触发不可逆置位)。"""
    try:
        token = await _current_token(db, runner)
        metas = await runner.client.filemetas_batch(token, [fs_id], dlink=False)
    except BaiduApiError as e:
        return e.category == CATEGORY_NOT_FOUND
    except Exception:
        return False
    return len(metas) == 0


async def _ensure_dlink(db: AsyncSession, runner: Runner, row: TaskFile) -> str:
    """懒取 dlink(§6 步骤 3):行缓存(8h,提前 10min 余量)有效直接用;否则以
    本行为首、连同至多 99 个同样缺有效 dlink 的 pending 行批量 filemetas。"""
    now = _now()
    if row.dlink and row.dlink_expires_at and row.dlink_expires_at > now + timedelta(
        seconds=DLINK_MARGIN_S,
    ):
        return row.dlink
    token = await _current_token(db, runner)
    others = (await db.execute(
        select(TaskFile)
        .where(
            TaskFile.task_id == row.task_id,
            TaskFile.status == "pending",
            TaskFile.id != row.id,
            TaskFile.dlink.is_(None)
            | (TaskFile.dlink_expires_at.is_(None))
            | (TaskFile.dlink_expires_at < now + timedelta(seconds=DLINK_MARGIN_S)),
        )
        .order_by(TaskFile.id)
        .limit(DLINK_BATCH - 1)
    )).scalars().all()
    candidates = [row, *list(others)]
    metas = await runner.client.filemetas_batch(token, [c.fs_id for c in candidates], dlink=True)
    by_fs = {int(m.get("fs_id", 0)): m for m in metas}
    fresh_until = now + timedelta(seconds=DLINK_TTL_S)
    got = ""
    for cand in candidates:
        meta = by_fs.get(cand.fs_id)
        dlink = str(meta.get("dlink") or "") if meta else ""
        if not dlink:
            continue
        await db.execute(
            update(TaskFile).where(TaskFile.id == cand.id).values(
                dlink=dlink, dlink_fetched_at=now, dlink_expires_at=fresh_until,
            )
        )
        if cand.id == row.id:
            row.dlink = dlink
            row.dlink_expires_at = fresh_until
            got = dlink
    await db.commit()
    if not got:
        raise BaiduApiError(
            CATEGORY_NOT_FOUND, f"filemetas 未返回 dlink(fs_id={row.fs_id})", errno=-9,
        )
    return got


async def _purge_key_holders(
    db: AsyncSession, runner: Runner, row: TaskFile, *, folder_id: uuid.UUID,
    bucket: str, key: str, operator_user_id: uuid.UUID | None,
) -> str | None:
    """F2a:overwrite 行遇同 key 占用行 → 逐行权限复查 → purge_active_asset 物理清除。

    - 目标夹 sensitive 一律拒绝(与既有同名覆盖流同款,org admin 亦无豁免)
    - **全部占用行先复查权限,任一无权不动手**(函数自身范围内避免部分清除);
      不通过 → failed('overwrite_forbidden_for_holder') 点名无权占用者(清
      overwrite 标志,与既有 overwrite_forbidden 同理由:防 retry 复位后残留
      标志再触清除循环)。本函数亦是 _overwrite_precheck_and_purge 同名行
      purge 之后的二次复查兜底 —— 该窗口内才拒则同名行已 purge,不回滚
    - 逐行 purge(purge 前按 DB 现存占用行重查,已清行不重复 purge);purge 未证实
      → failed('purge_incomplete')(保留 overwrite 标志,重试续清剩余占用行)
    - 返回 None = key 已无占用行,可继续导入;否则为行级失败结果
    """
    folder = await db.get(Folder, folder_id)
    if folder is not None and folder.is_sensitive:
        return await _fail_row(db, runner, row, "overwrite_forbidden", clear_overwrite=True,
                               message="目标目录不允许覆盖导入")
    holders = await _key_conflict_holders(db, bucket=bucket, key=key, exclude_asset_id=None)
    if not holders:
        return None
    for holder in holders:
        allowed = await _org_admin_allowed(runner) or await runner.permissions.check(
            user_subject=f"user:{operator_user_id}" if operator_user_id else "user:unknown",
            relation="can_admin", object_type="asset", object_id=str(holder.id),
        )
        if not allowed:
            return await _fail_row(
                db, runner, row, "overwrite_forbidden_for_holder", clear_overwrite=True,
                message=f"对占用文件「{holder.filename}」无管理权限,覆盖导入被拒绝",
            )
    for holder in holders:
        async with get_sessionmaker()() as audit_session:
            try:
                await purge_active_asset(
                    db=db, permissions=runner.permissions, presign=runner.presign,
                    audit=AuditService(audit_session), asset_id=holder.id,
                    actor_user_id=operator_user_id,
                    audit_details={"task_id": str(runner.task_id), "file_id": str(row.id)},
                )
            except PurgeIncompleteError as e:
                # purge 未证实 → 行级 last_error 附结构化快照(重试按 DB 现存占用行续清)
                return await _fail_row(
                    db, runner, row, "purge_incomplete",
                    message=f"bucket={e.bucket} key={e.key}",
                )
    log.info("baidu overwrite purged key holders task=%s file=%s key=%s count=%d",
             runner.task_id, row.id, key, len(holders))
    return None


async def _overwrite_precheck_and_purge(
    db: AsyncSession, runner: Runner, row: TaskFile, existing_asset: Asset,
    folder_id: uuid.UUID, bucket: str, key: str, *,
    same_name_count: int, operator_user_id: uuid.UUID | None,
) -> str | None:
    """覆盖导入前置(§6 步骤 2):can_admin + 目标夹非 sensitive + 跨资产 key 预检
    → 活跃 asset 物理删除业务流。返回 None = 清除完成可导入;否则为行级失败结果。

    - 权限/引用复查未通过 → failed('overwrite_forbidden'/'overwrite_ambiguous'/
      'overwrite_forbidden_for_holder') 并**清 overwrite 标志**(仅限「旧 asset
      存在但复查未通过」的情形;否则 retry-failed 复位后残留标志会再次触发清除
      流程陷入循环)
    - F2a:同 key 的其他占用行(批量前缀 filename≠key 残留等,含软删)与既有同名行
      一并纳入清除范围 —— 动手前先对已知占用行全量复查权限(把「无权」尽量挡在
      purge 之前)。窄 TOCTOU 如实注记:同名行 purge 之后 _purge_key_holders
      还会按 DB 现值对占用行二次复查权限兜底,此时才拒 → 行失败
      overwrite_forbidden_for_holder,已 purge 的同名行不回滚(窗口内新增占用行
      或权限回退仅经此路径可达)
    - purge 未证实 → failed('purge_incomplete')(可重试;保留标志)
    - sensitive 防御断言命中一律拒绝,不做 org admin 豁免(v1 三层禁敏感目标使
      该分支正常不可达;assets.py:759-769 口径留 v2 评估)
    """
    folder = await db.get(Folder, folder_id)
    if folder is not None and folder.is_sensitive:
        return await _fail_row(db, runner, row, "overwrite_forbidden", clear_overwrite=True,
                               message="目标目录不允许覆盖导入")
    allowed = await _org_admin_allowed(runner) or await runner.permissions.check(
        user_subject=f"user:{operator_user_id}" if operator_user_id else "user:unknown",
        relation="can_admin", object_type="asset", object_id=str(existing_asset.id),
    )
    if not allowed:
        return await _fail_row(db, runner, row, "overwrite_forbidden", clear_overwrite=True,
                               message="对原文件无管理权限,覆盖导入被拒绝")
    if same_name_count > 1:
        return await _fail_row(db, runner, row, "overwrite_ambiguous", clear_overwrite=True,
                               message="目标位置存在多个同名文件,请先人工处理")
    # F2a:同 key 其他占用行先全部复查权限(把「无权」挡在动手前,尽力避免部分
    # 清除;无权者点名交 overwrite_forbidden_for_holder。窄 TOCTOU:同名行 purge
    # 后 _purge_key_holders 还有二次复查兜底,见函数 docstring)
    holders = await _key_conflict_holders(db, bucket=bucket, key=key,
                                          exclude_asset_id=existing_asset.id)
    for holder in holders:
        holder_allowed = await _org_admin_allowed(runner) or await runner.permissions.check(
            user_subject=f"user:{operator_user_id}" if operator_user_id else "user:unknown",
            relation="can_admin", object_type="asset", object_id=str(holder.id),
        )
        if not holder_allowed:
            return await _fail_row(
                db, runner, row, "overwrite_forbidden_for_holder", clear_overwrite=True,
                message=f"对占用文件「{holder.filename}」无管理权限,覆盖导入被拒绝",
            )
    # purge 前先做一次租约续期(缓解长 purge 期间无检查点触发 sweeper 接管 churn,§6)
    state = await renew_lease(
        db, task_id=runner.task_id, expected_seq=runner.expected_seq,
        runner_id=runner.runner_id, now=_now(), lease_s=runner.settings.baidu_lease_s,
    )
    await db.commit()
    if state is None:
        return "lost"
    # purge 前检查点(cancel 优先 —— 用户在清除开始前取消则不删原文件)
    outcome = await checkpoint(db, runner)
    if outcome is not None:
        return await consume_outcome(db, runner, outcome)
    async with get_sessionmaker()() as audit_session:
        try:
            await purge_active_asset(
                db=db, permissions=runner.permissions, presign=runner.presign,
                audit=AuditService(audit_session), asset_id=existing_asset.id,
                actor_user_id=operator_user_id,
                audit_details={"task_id": str(runner.task_id), "file_id": str(row.id)},
            )
        except PurgeIncompleteError as e:
            # purge 未证实 → 行级 last_error 附结构化快照 bucket/key(重试按快照
            # 直接 purge+head 断言,不依赖已删除的 asset 行反查)
            return await _fail_row(
                db, runner, row, "purge_incomplete",
                message=f"bucket={e.bucket} key={e.key}",
            )
    # F2a:同 key 其他占用行逐行清除(_purge_key_holders 按 DB 现存行重查并复检
    # 权限;同名行已 purge 不在列,不重复 purge)
    fail = await _purge_key_holders(
        db, runner, row, folder_id=folder_id, bucket=bucket, key=key,
        operator_user_id=operator_user_id,
    )
    if fail is not None:
        return fail
    log.info("baidu overwrite purged old asset task=%s file=%s asset=%s",
             runner.task_id, row.id, existing_asset.id)
    return None


# ─── 传输与落库(§6 步骤 4-7)────────────────────────────────────────────────


@dataclass
class _DownloadResult:
    """下载结果:outcome 非 None = 检查点要求中止(结果已消费/需传播);
    否则 parts/next_part 为可 complete 的最终态。"""

    outcome: str | None
    parts: list[dict[str, Any]] = field(default_factory=list)
    pos: int = 0
    next_part: int = 1


async def _resume_or_create_session(
    db: AsyncSession, runner: Runner, row: TaskFile, *, bucket: str, key: str,
    content_type: str,
) -> tuple[list[dict[str, Any]], str, int, int]:
    """接管/重启恢复:返回 (已完成 parts, upload_id, 已完成字节偏移, 下一分片号)。

    - list_parts NoSuchUpload(或 parts 空且 bytes_done>0)= 死会话 → 清空重创从 0
      (complete 之后 upload_id 即失效)
    - parts 非连续前缀(理论不可达:parts 严格串行上传)→ abort 重创从 0
    """
    if row.minio_upload_id and row.minio_bucket and row.minio_key:
        parts: list[dict[str, Any]] | None
        try:
            parts = await runner.store.list_parts(
                row.minio_bucket, row.minio_key, row.minio_upload_id,
            )
        except Exception as e:
            if is_no_such_upload_error(e):
                parts = None
            else:
                raise
        if parts:
            # 断言:已列 parts 恒为连续前缀(严格串行上传的前提)
            contiguous = all(p["PartNumber"] == i + 1 for i, p in enumerate(parts))
            if contiguous:
                offset = sum(int(p["Size"]) for p in parts)
                next_part = int(parts[-1]["PartNumber"]) + 1
                if offset != row.bytes_done:
                    await db.execute(
                        update(TaskFile).where(TaskFile.id == row.id)
                        .values(bytes_done=offset)
                    )
                    await db.commit()
                return parts, row.minio_upload_id, offset, next_part
            await runner.store.abort_multipart_upload(
                row.minio_bucket, row.minio_key, row.minio_upload_id,
            )
        # 死会话:清空 minio_upload_id/bytes_done、重新 create 从 0 重传(§6)
        await db.execute(
            update(TaskFile).where(TaskFile.id == row.id)
            .values(minio_upload_id=None, minio_bucket=None, minio_key=None, bytes_done=0)
        )
        await db.commit()
    upload_id = await runner.store.create_multipart_upload(bucket, key, content_type)
    # create_multipart_upload 时同事务落定三元组(§4:abort 按三元组直读)
    await db.execute(
        update(TaskFile).where(TaskFile.id == row.id).values(
            minio_upload_id=upload_id, minio_bucket=bucket, minio_key=key, bytes_done=0,
        )
    )
    await db.commit()
    return [], upload_id, 0, 1


async def _download_parts(
    db: AsyncSession, runner: Runner, row: TaskFile, dlink: str, *, bucket: str,
    key: str, upload_id: str, parts: list[dict[str, Any]], offset: int,
    next_part: int, part_size: int,
) -> _DownloadResult:
    """流式下载按 part 边界 upload_part(parts 严格按序号串行上传,§6 硬约束)。

    - 下载流内 ≤5s 检查点(续期 + cancel/flag/48h/接力)
    - 每次 upload_part 之前的所有权检查(0 行=已被接管,立即中止本文件;
      中止路径仅停写,不修改行状态/计数)
    - 每 part 成功后更新 bytes_done + 任务 done_bytes 快速通道(单个大文件下载
      期间字节进度与 ETA 不静止)
    """
    collected = list(parts)
    pos = offset
    pending = bytearray()
    last_ckpt = time.monotonic()
    token = await _current_token(db, runner)
    range_header = f"bytes={pos}-" if pos > 0 else None

    async def _flush(final: bool) -> str | None:
        nonlocal pos, next_part, last_ckpt
        while len(pending) >= part_size or (final and pending):
            if final:
                body = bytes(pending)
                pending.clear()
            else:
                body = bytes(pending[:part_size])
                del pending[:part_size]
            outcome = await checkpoint(db, runner)
            last_ckpt = time.monotonic()
            if outcome is not None:
                return outcome
            etag = await runner.store.upload_part(bucket, key, upload_id, next_part, body)
            collected.append({"PartNumber": next_part, "ETag": etag, "Size": len(body)})
            next_part += 1
            pos += len(body)
            await db.execute(
                update(TaskFile)
                .where(TaskFile.id == row.id, runner.owned_row_predicate())
                .values(bytes_done=pos)
            )
            if not await bump_done_bytes(
                db, task_id=runner.task_id, expected_seq=runner.expected_seq,
                runner_id=runner.runner_id, delta=len(body),
            ):
                return "lost"
            await db.commit()
        return None

    try:
        async for chunk in runner.client.stream_download(
            token, dlink, range_header=range_header,
        ):
            pending += chunk
            if time.monotonic() - last_ckpt >= RENEW_INTERVAL_S:
                outcome = await checkpoint(db, runner)
                last_ckpt = time.monotonic()
                if outcome is not None:
                    return _DownloadResult(outcome=outcome)
            stop = await _flush(final=False)
            if stop is not None:
                return _DownloadResult(outcome=stop)
        stop = await _flush(final=True)
        if stop is not None:
            return _DownloadResult(outcome=stop)
    except BaiduApiError as e:
        if e.category == CATEGORY_LINK_EXPIRED:
            # dlink 过期:清缓存,交上层重新 filemetas 后重试(§5.3)
            await db.execute(
                update(TaskFile).where(TaskFile.id == row.id)
                .values(dlink=None, dlink_expires_at=None)
            )
            await db.commit()
            raise _LinkRefreshNeeded from e
        raise
    # 断言:parts 恒为连续前缀(并行化会让断点偏移算法静默失真,§6)
    assert all(p["PartNumber"] == i + 1 for i, p in enumerate(collected)), \
        "multipart parts 必须按序号连续(串行上传约束)"
    return _DownloadResult(outcome=None, parts=collected, pos=pos, next_part=next_part)


async def _transfer_and_finalize(
    db: AsyncSession, runner: Runner, row: TaskFile, task: Task, project: Project,
    dlink: str, *, bucket: str, key: str, folder_id: uuid.UUID, filename: str,
    suppress_head_shortcut: bool,
) -> str:
    """下载 → multipart complete → asset 落库 → 缩略图 → 收尾写(§6 步骤 4-7)。"""
    part_size = runner.settings.baidu_part_size_bytes
    content_type = _content_type_for(filename)
    size = row.source_size

    # ── 跨资产 key 引用预检(所有落库路径的公共第一道,§6)────────────────────
    holders = await _key_conflict_holders(db, bucket=bucket, key=key, exclude_asset_id=None)
    if holders and row.overwrite:
        # F2a:覆盖行遇 key 占用(无同名行的 key_conflict 出路/预留 key TOCTOU)→
        # 租约续期 + 检查点后逐行复查权限并物理清除(与既有同名覆盖清除流同构;
        # 已清行按 DB 现存重查,不重复 purge)
        state = await renew_lease(
            db, task_id=runner.task_id, expected_seq=runner.expected_seq,
            runner_id=runner.runner_id, now=_now(), lease_s=runner.settings.baidu_lease_s,
        )
        await db.commit()
        if state is None:
            return "lost"
        outcome = await checkpoint(db, runner)
        if outcome is not None:
            return await consume_outcome(db, runner, outcome)
        fail = await _purge_key_holders(
            db, runner, row, folder_id=folder_id, bucket=bucket, key=key,
            operator_user_id=task.user_id,
        )
        if fail is not None:
            return fail
    elif holders:
        # F1:非覆盖导入点名占用者(保持可重试;行级出路=覆盖/随机后缀导入)
        return await _fail_row(
            db, runner, row, "key_conflict",
            message=format_key_conflict_message(key, _holder_names(holders)),
        )

    if size == 0:
        # size=0 空文件走 put_object 直传(multipart 无法 complete 0 parts,§6)
        await runner.store.put_object(bucket, key, b"", content_type)
    else:
        head_shortcut = False
        if not row.overwrite and not suppress_head_shortcut:
            head = await runner.store.head_object(bucket, key)
            if head is not None and int(head["size_bytes"]) == size:
                verdict = await _head_shortcut_md5_gate(db, runner, row, head_etag=head.get("etag"))
                if verdict == "mismatch":
                    if row.last_error is not None and row.last_error.startswith("md5_mismatch"):
                        # 非覆盖行重试:先 delete_object 清掉该孤儿对象(跨资产预检
                        # 已确保 count=0,删除安全)再从 0 重传(§6)
                        await runner.store.delete_object(bucket, key)
                    else:
                        return await _fail_row(
                            db, runner, row, "md5_mismatch",
                            message="对象内容与网盘元数据不一致",
                        )
                else:
                    head_shortcut = True
        if not head_shortcut:
            parts, upload_id, offset, next_part = await _resume_or_create_session(
                db, runner, row, bucket=bucket, key=key, content_type=content_type,
            )
            dl = await _download_parts(
                db, runner, row, dlink, bucket=bucket, key=key, upload_id=upload_id,
                parts=parts, offset=offset, next_part=next_part, part_size=part_size,
            )
            if dl.outcome is not None:
                return dl.outcome
            # ── complete 前跨资产 key 引用预检(普通导入同样做,收窄窗口,§6)──
            # F1:传输窗口内新出现占用行 → 点名失败(不在此 purge;重试走首检的
            # F2a 清除路径,避免 complete 前长 purge 拖住 multipart 会话)
            holders = await _key_conflict_holders(
                db, bucket=bucket, key=key, exclude_asset_id=None,
            )
            if holders:
                return await _fail_row(
                    db, runner, row, "key_conflict",
                    message=format_key_conflict_message(key, _holder_names(holders)),
                )
            try:
                await runner.store.complete_multipart_upload(bucket, key, upload_id, dl.parts)
            except Exception as e:
                if is_no_such_upload_error(e):
                    # 会话在传输窗口内死亡 → 行保持 importing,下一轮重试从 0 重传
                    raise _UploadSessionLost from e
                raise
            # complete 成功后同事务清空 minio_upload_id(防孤儿 sweep/DELETE 任务
            # 对已死会话反复 abort,§6)
            await db.execute(
                update(TaskFile).where(TaskFile.id == row.id).values(minio_upload_id=None)
            )
            await db.commit()

    # ── 步骤 5:asset 落库(insert 前最后一次租约所有权 CAS,完整谓词)──────────
    guard = await db.execute(
        update(Task)
        .where(
            Task.id == runner.task_id,
            Task.lease_seq == runner.expected_seq,
            Task.runner_id == runner.runner_id,
            Task.status.in_(ACTIVE_STATUSES),
            Task.cancel_requested.is_(False),
        )
        .values(lease_until=_now() + timedelta(seconds=runner.settings.baidu_lease_s))
    )
    if statement_rowcount(guard) == 0:
        # 任务已被接管/取消:放弃落库(complete 后孤儿对象无自动清理,§9 留通道)
        log.warning("baidu asset insert guard lost task=%s file=%s", runner.task_id, row.id)
        return "lost"
    await db.commit()

    head = await runner.store.head_object(bucket, key)
    if head is None:
        return await _fail_row(db, runner, row, "head_missing")
    if int(head["size_bytes"]) != size:
        # 完整性校验(§6):断点偏移错位会产出静默损坏文件,落库前必须拦下
        log.warning("baidu size mismatch task=%s file=%s(留清理通道 bucket=%s key=%s)",
                    runner.task_id, row.id, bucket, key)
        return await _fail_row(db, runner, row, "size_mismatch",
                               message=f"{head['size_bytes']} != {size}")
    asset = Asset(
        id=uuid.uuid4(),
        folder_id=folder_id,
        filename=filename,
        minio_bucket=bucket,
        minio_key=key,
        etag=head.get("etag"),
        minio_version_id=head.get("version_id"),
        size_bytes=int(head["size_bytes"]),
        content_type=head.get("content_type") or content_type,
        uploader_id=task.user_id,
    )
    db.add(asset)
    try:
        await db.commit()
    except Exception as e:
        # multipart 已 complete 但 asset 落库失败(key 超长/文件夹并发删除等):
        # 对象按现有先例记日志留清理通道(assets.py:177-194 口径)
        await db.rollback()
        log.warning("baidu asset db insert fail task=%s file=%s err=%s(对象留清理通道)",
                    runner.task_id, row.id, e)
        return await _fail_row(db, runner, row, "asset_db_error", message=str(e)[:512])
    await runner.permissions.bootstrap_asset(
        asset_id=str(asset.id), parent_type="folder", parent_id=str(folder_id),
    )
    await write_audit(
        event_type="baidu_file_imported",
        actor_user_id=task.user_id,
        target_asset_id=asset.id,
        target_project_id=project.id,
        target_minio_key=key,
        dedup_key=AUDIT_DEDUP_FMT.format(
            task_id=runner.task_id, event="baidu_file_imported", ref=row.id,
            retry=task.retry_count, attempts=row.attempts,
        ),
        details={
            "task_id": str(runner.task_id), "file_id": str(row.id),
            "source_path": row.source_path, "size_bytes": asset.size_bytes,
            "zero_byte": size == 0,
        },
    )

    # ── 步骤 6:缩略图三分派(livp→livp_thumbnail、image→thumbnail、video→…)──
    await _enqueue_thumbnail(
        ctx_pool=runner.pool, asset_id=asset.id, filename=filename,
        content_type=str(asset.content_type or ""),
    )

    # ── 步骤 7:收尾写(行→success + 聚合重算 + 锚点;完整谓词)────────────────
    res = await db.execute(
        update(TaskFile)
        .where(TaskFile.id == row.id, runner.owned_row_predicate())
        .values(status="success", asset_id=asset.id, bytes_done=size)
    )
    if statement_rowcount(res) == 0:
        # 直终态化未清 runner 的交错窗口:asset 行已 commit 而非仅对象,无审计则
        # 违背资产可追溯(baidu_task_auto_finalized,reason=finalize_race,§6)
        await write_audit(
            event_type="baidu_task_auto_finalized",
            actor_user_id=None,
            details={"reason": "finalize_race", "asset_id": str(asset.id),
                     "task_file_id": str(row.id), "task_id": str(runner.task_id)},
        )
        return "lost"
    await recompute_aggregates(db, task_id=runner.task_id)
    await update_speed_anchor(
        db, task_id=runner.task_id, expected_seq=runner.expected_seq,
        runner_id=runner.runner_id, now=_now(),
    )
    await db.commit()
    log.info("baidu file imported task=%s file=%s asset=%s size=%d",
             runner.task_id, row.id, asset.id, asset.size_bytes)
    return "ok"


async def _head_shortcut_md5_gate(
    db: AsyncSession, runner: Runner, row: TaskFile, *, head_etag: str | None,
) -> str:
    """head 快捷路径的 md5 单段旁证(§6):单段 ETag(不含 -N,单次 PUT 落成)且
    filemetas md5 存在时严格比对;multipart ETag(分片 md5 的 md5 形态)恒不等于
    内容 md5,不可比对,此类对象只按 size + 跨资产预检两道防线放行;md5 字段缺失
    /为空 → 退化为两道防线。返回 "pass" | "mismatch"。"""
    if not head_etag or "-" in head_etag:
        return "pass"
    try:
        token = await _current_token(db, runner)
        metas = await runner.client.filemetas_batch(token, [row.fs_id], dlink=False)
    except Exception:
        return "pass"   # 旁证不可得 → 退化为 size + 预检两道防线
    md5 = str(metas[0].get("md5") or "").lower() if metas else ""
    if not md5:
        return "pass"
    return "pass" if head_etag.lower() == md5 else "mismatch"


async def _enqueue_thumbnail(
    *, ctx_pool: Any, asset_id: uuid.UUID, filename: str, content_type: str,
) -> None:
    """缩略图三分派(复用 complete_upload 口径,§6 步骤 6);fire-and-forget。"""
    if ctx_pool is None:
        return
    job: str | None = None
    if filename.lower().endswith(".livp"):
        job = "generate_livp_thumbnail"
    elif content_type.startswith("image/"):
        job = "generate_thumbnail"
    elif content_type.startswith("video/"):
        job = "generate_video_thumbnail"
    if job is None:
        return
    try:
        await ctx_pool.enqueue_job(job, str(asset_id))
    except Exception as e:
        log.warning("enqueue thumbnail fail asset=%s job=%s err=%s", asset_id, job, e)


# ─── sweeper cron(§6;timeout=300 per-cron 覆盖,低于百度任务 3610s)──────────


async def sweep_stalled_baidu_tasks(ctx: dict[str, Any]) -> dict[str, int]:
    """接管「活动中 且 无租约/租约过期(含 NULL)且 派发超时(含从未派发)」的任务。

    分支顺序:急停 flag 感知 → cancel_requested 直终态化(不再入队,白省一次派发)
    → 48h 兜底判停 → 派发步(CAS + 接管复位在途行 + 入队)。另含 30d 终态孤儿会话
    清理(逐行 try/except,NoSuchUpload 视为已清理照常清列,防单行异常中断整批)。
    """
    settings = get_settings()
    now = _now()
    stats = {
        "candidates": 0, "flag_off": 0, "cancelled": 0, "timeout": 0,
        "dispatched": 0, "orphans_cleared": 0,
    }
    store = AsyncObjectStore(settings)
    async with store, get_sessionmaker()() as db:
            candidates = (await db.execute(
                select(Task)
                .where(
                    Task.status.in_(ACTIVE_STATUSES),
                    Task.lease_until.is_(None) | (Task.lease_until < now),   # NULL 显式
                    Task.dispatched_at.is_(None)
                    | (Task.dispatched_at
                       < now - timedelta(seconds=settings.baidu_sweep_throttle_s)),
                )
                .order_by(Task.created_at, Task.id)   # 确定性排序
                .limit(SWEEP_BATCH)
            )).scalars().all()
            stats["candidates"] = len(candidates)
            for task in candidates:
                if not settings.baidu_backup_enabled:
                    stats["flag_off"] += 1
                    await _sweep_finalize_failed(
                        db, task, fail_reason=FAIL_FEATURE_DISABLED, reason_row="feature_disabled",
                    )
                    continue
                if task.cancel_requested:
                    stats["cancelled"] += 1
                    await _sweep_finalize_cancelled(db, store, task)
                    continue
                if round_timed_out(task.round_started_at, now, settings.baidu_round_timeout_s):
                    stats["timeout"] += 1
                    await _sweep_finalize_failed(
                        db, task, fail_reason=FAIL_TIMEOUT, reason_row="task_timeout",
                    )
                    continue
                # 派发步(CAS;接管分支同事务复位在途行;不复位 round_started_at ——
                # 轮起点跨接管累计,否则反复崩溃可无限重置 48h 时钟,§6)
                await reset_importing_rows(db, task_id=task.id)
                pool = ctx.get("redis")
                if pool is None:
                    continue   # Redis 不可用:下一轮 cron 重试派发(dispatched_at 节流)
                outcome = await dispatch_and_enqueue(
                    db, pool, task_id=task.id, mode="sweep", now=_now(),
                    throttle_s=settings.baidu_sweep_throttle_s,
                )
                if outcome.seq is not None:
                    stats["dispatched"] += 1
                    log.info("sweep dispatched task=%s seq=%s enqueued=%s",
                             task.id, outcome.seq, outcome.enqueued)

            # ── 30d 孤儿清理(仅覆盖「任务行仍在、列未清」的终态残留,§6)─────
            orphans = (await db.execute(
                select(TaskFile.id, TaskFile.minio_bucket, TaskFile.minio_key,
                       TaskFile.minio_upload_id)
                .join(Task, Task.id == TaskFile.task_id)
                .where(
                    Task.status.in_(TERMINAL_STATUSES),
                    Task.updated_at < now - timedelta(days=30),
                    TaskFile.minio_upload_id.is_not(None),
                )
                .order_by(TaskFile.id)
                .limit(ORPHAN_BATCH)
            )).all()
            cleared = await _abort_sessions_async(store, list(orphans))
            if cleared:
                await db.execute(   # abort 成功后单独事务清空(abort 与 DB 无原子性)
                    update(TaskFile).where(TaskFile.id.in_(cleared))
                    .values(minio_upload_id=None, bytes_done=0)
                )
                await db.commit()
                stats["orphans_cleared"] = len(cleared)
    if any(v for k, v in stats.items() if k != "candidates"):
        log.info("sweep_stalled_baidu_tasks: %s", stats)
    return stats


async def _sweep_finalize_cancelled(db: AsyncSession, store: AsyncObjectStore, task: Task) -> None:
    """sweeper cancel_requested 分支:按归位表终态化 cancelled 并 abort,
    UPDATE 同步 SET runner_id=NULL, lease_until=NULL;不再入队(白省一次派发)。"""
    session_rows = await _load_session_rows(db, task.id)
    await finalize_rows_cancelled(db, task_id=task.id)
    await finalize_task_terminal(db, task_id=task.id, status=STATUS_CANCELLED)
    await recompute_aggregates(db, task_id=task.id)
    await db.commit()
    cleared = await _abort_sessions_async(store, session_rows)
    await _clear_session_columns(db, cleared)
    log.info("sweep finalized cancelled task=%s aborted=%d", task.id, len(cleared))


async def _sweep_finalize_failed(
    db: AsyncSession, task: Task, *, fail_reason: str, reason_row: str,
) -> None:
    """sweeper flag 感知 / 48h 兜底判停分支:均**保留 multipart 断点**
    (timeout 供下轮 list_parts 续传;feature_disabled 供重开功能后 retry-failed
    续传);系统侧终态以 actor=NULL 落 baidu_task_auto_finalized。"""
    await finalize_rows_failed(db, task_id=task.id, reason=reason_row, overwrite_note=True)
    await finalize_task_terminal(db, task_id=task.id, status=STATUS_FAILED, fail_reason=fail_reason)
    await recompute_aggregates(db, task_id=task.id)
    await db.commit()
    await write_audit(
        event_type="baidu_task_auto_finalized",
        actor_user_id=None,
        details={"task_id": str(task.id), "fail_reason": fail_reason, "runner": "sweeper"},
    )
    log.info("sweep finalized failed task=%s reason=%s", task.id, fail_reason)
