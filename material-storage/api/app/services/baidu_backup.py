"""百度网盘备份任务域服务 — 方案 §5.1(baidu_backup 服务)/§5.2/§6。

职责(批次 2+3):
- 任务创建校验链(source_dir 护栏 / target 归属与敏感祖先链 / 活动互斥)
- 派发步 / 接力变体 / 认领 / 续期四类租约 CAS(§6 全部谓词含 NULL 分支与所有权守卫)
- 复活型接口统一前置(§5.2)与文件行复位
- abort_leftover_sessions 统一断点作废 helper(≤20 行内联分批 abort,>20 仅 importing)
- 终态化归位表 + 三分支判定 + 聚合计数重算(done=success+skipped 口径,§6)
- 48h 轮判停纯函数与排队豁免口径
- refresh 单飞(自 router 上收,worker 共用,§5.3)

约定:所有涉及时间戳列的谓词显式含 NULL 分支(SQL 中 NULL 参与比较恒为假;
任务在「创建后未派发」「派发后未认领」两窗口 dispatched_at/runner_id/lease_until
均为 NULL);时间值与谓词统一用应用侧时钟(docker 单机栈同钟;谓词与写入同源
避免 DB/应用时钟混用)。
"""
from __future__ import annotations

import asyncio
import logging
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any, Literal

from arq.connections import ArqRedis
from botocore.exceptions import ClientError  # type: ignore[import-untyped]
from sqlalchemy import case, func, literal, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.sql.elements import ColumnElement

from app.db.tables import Asset, BaiduBinding, Folder
from app.db.tables import BaiduBackupTask as Task
from app.db.tables import BaiduBackupTaskFile as TaskFile
from app.services.baidu_client import BaiduNetdiskClient
from app.services.presign import PresignService
from app.services.token_crypto import TokenCryptoService, TokenDecryptError

log = logging.getLogger(__name__)

def _rowcount(result: Any) -> int:
    """UPDATE/DELETE 影响行数(session.execute 的静态类型是 Result[Any],rowcount
    实际在 CursorResult 上,经 Any 桥接;0 行 = CAS 未命中)。"""
    return int(getattr(result, "rowcount", 0) or 0)


def statement_rowcount(result: Any) -> int:
    """_rowcount 的公开入口(router 复用;UPDATE/DELETE 影响行数)。"""
    return _rowcount(result)


# 本域全部 ORM UPDATE 统一 execution_options(synchronize_session=False):
# 任务/清单表经 TimestampMixin 带 `updated_at onupdate=func.now()`,ORM UPDATE 默认
# auto/evaluate 同步无法 evaluate 该列,会把命中行对应的会话内对象**置 expire**;
# async 会话随后再读同对象(哪怕只读 updated_at)就是同步 IO → MissingGreenlet
# (POST /tasks 500 已实证)。本域取值一律走 RETURNING / rowcount / 重查,不依赖
# evaluate 的内存同步;凡调用方在 UPDATE 后需要读对象,必须显式 db.refresh 或重查。
_SYNC_OFF = {"synchronize_session": False}


# ─── 状态与谓词常量(§4)──────────────────────────────────────────────────────
STATUS_ENUMERATING = "enumerating"
STATUS_RUNNING = "running"
STATUS_COMPLETED = "completed"
STATUS_CANCELLED = "cancelled"
STATUS_FAILED = "failed"
ACTIVE_STATUSES = (STATUS_ENUMERATING, STATUS_RUNNING)
TERMINAL_STATUSES = (STATUS_COMPLETED, STATUS_CANCELLED, STATUS_FAILED)
FILE_STATUSES = ("pending", "skipped_exists", "importing", "success", "failed", "cancelled")

# fail_reason 取值域(§4)
FAIL_BINDING_EXPIRED = "binding_expired"
FAIL_TIMEOUT = "timeout"
FAIL_FILE_FAILED = "file_failed"
FAIL_ENUM_RATE_LIMITED = "enum_rate_limited"
FAIL_ENUM_FAILED = "enum_failed"
FAIL_MANIFEST_TOO_LARGE = "manifest_too_large"
FAIL_FEATURE_DISABLED = "feature_disabled"
# 任务级 fail_reason 允许集(防御拼写漂移)
FAIL_REASONS = frozenset({
    FAIL_BINDING_EXPIRED, FAIL_TIMEOUT, FAIL_FILE_FAILED, FAIL_ENUM_RATE_LIMITED,
    FAIL_ENUM_FAILED, FAIL_MANIFEST_TOO_LARGE, FAIL_FEATURE_DISABLED,
})

# cancel_reason 取值域(§4)
CANCEL_USER = "user_cancel"
CANCEL_BINDING_REPLACED = "binding_replaced"

# abort_leftover_sessions 统一 budget(§5.2 三处用户触发路径共用)
ABORT_INLINE_BUDGET = 20     # ≤20 行内联分批 abort
ABORT_BATCH_SIZE = 10        # 每批 10 行(to_thread)

# 枚举退避(§5.3/§6:单次退避封顶 ≤20s(≤租约/3),sleep 分片每 ≤10s 醒来做续期+取消检查)
ENUM_BACKOFF_MAX_ATTEMPTS = 5
ENUM_BACKOFF_CAP_S = 20.0
SLEEP_SHARD_S = 10.0

# refresh 单飞(§5.3;自 router 上收)
TOKEN_EXPIRY_MARGIN_S = 60   # 提前 60s 余量判过期(防时钟偏差)
REFRESH_MAX_ATTEMPTS = 3     # 连续 3 次失败才置 binding=expired
REFRESH_RETRY_BACKOFF_S = 0.5

# 归位表 overwrite 行注记(§6)
_CANCELLED_OVERWRITE_NOTE = "原文件已被删除且本任务已取消,如需恢复请新建备份任务重新导入"
_FAILED_OVERWRITE_NOTE = "原文件已被删除,如需恢复请重试该行"


class BaiduTaskError(Exception):
    """任务域业务错误;router 映射为 HTTP(detail.code 供前端免特判),worker 捕获记日志。"""

    def __init__(self, message: str, *, http_status: int = 409, code: str | None = None) -> None:
        super().__init__(message)
        self.http_status = http_status
        self.code = code


# ─── 纯函数(单测友好)───────────────────────────────────────────────────────


def lease_free(runner_id: str | None, lease_until: datetime | None, now: datetime) -> bool:
    """无租约/租约过期(§4):runner_id IS NULL OR lease_until < now(NULL 恒真)。"""
    return runner_id is None or lease_until is None or lease_until < now


def dispatch_timed_out(dispatched_at: datetime | None, now: datetime, throttle_s: int) -> bool:
    """派发超时(sweeper 节流放行,§4):dispatched_at IS NULL OR < now-throttle。"""
    return dispatched_at is None or dispatched_at < now - timedelta(seconds=throttle_s)


def round_timed_out(round_started_at: datetime | None, now: datetime, round_timeout_s: int) -> bool:
    """48h 轮判停(§6):round_started_at 非空且超时 —— NULL=从未运行/排队豁免,不参与判停。"""
    return round_started_at is not None and (
        now - round_started_at >= timedelta(seconds=round_timeout_s)
    )


def baidu_job_id(task_id: uuid.UUID, seq: int) -> str:
    """arq job_id 按 lease_seq 版本化(§6:每次派发全新 job_id,arq 层不承担互斥)。"""
    return f"baidu_backup_run:{task_id}:{seq}"


def derive_queued(
    *, status: str, speed_bps: int, has_importing_rows: bool, runner_id: str | None,
    lease_until: datetime | None, dispatched_at: datetime | None,
    now: datetime, throttle_s: int,
) -> bool:
    """「排队中」接口派生(§3.1):活动中但当前无 runner 实际推进。

    true = (running 且 speed_bps<=0 且无 importing 行)或(enumerating 且派发超时),
    且 runner_id IS NULL 或租约已过期(活跃租约必非排队 —— 消除建链/退避 sleep
    等活跃窗口的误显闪烁)。
    """
    if status not in ACTIVE_STATUSES:
        return False
    if not lease_free(runner_id, lease_until, now):
        return False
    if status == STATUS_RUNNING:
        return speed_bps <= 0 and not has_importing_rows
    return dispatch_timed_out(dispatched_at, now, throttle_s)


def derive_eta_seconds(*, total_bytes: int | None, done_bytes: int, speed_bps: int) -> int | None:
    """ETA = 剩余字节/滚动吞吐;speed_bps<=0 → None(前端显示「估算中」,§6)。"""
    if not total_bytes or speed_bps <= 0:
        return None
    remaining = total_bytes - done_bytes
    if remaining <= 0:
        return 0
    return int(remaining / speed_bps)


def validate_source_dir(source_dir: str) -> str:
    """创建期 source_dir 护栏(§5.2):以 / 开头的绝对路径且非根且 ≤600 字符。

    归一:rstrip('/') 防尾斜杠(承接夹名取末段防空名);根目录(全斜杠)400。
    """
    text = (source_dir or "").strip()
    if not text.startswith("/"):
        raise BaiduTaskError("source_dir 必须是以 / 开头的网盘绝对路径", http_status=400)
    if "\\" in text:
        raise BaiduTaskError("source_dir 路径格式不正确", http_status=400)
    normalized = text.rstrip("/") or "/"
    if normalized == "/":
        raise BaiduTaskError("请选择网盘具体目录(不支持根目录)", http_status=400)
    if len(normalized) > 600:
        raise BaiduTaskError("网盘目录路径过长(≤600 字符)", http_status=400)
    return normalized


def source_dir_leaf_name(source_dir: str) -> str:
    """承接夹名 = source_dir rstrip('/') 后末段(§5.2,防尾斜杠取出空名)。"""
    return source_dir.rstrip("/").rpartition("/")[2]


def format_key_conflict_message(key: str, holders: list[tuple[str, bool]]) -> str:
    """F1 错误文案(F2b 前端按 `key_conflict:` 前缀解析行级出路):
    `<key> 已被 <filename>[、<filename>…]占用`;软删占用者 filename 后附`(回收站)`,
    多占用者全列(总长截断由 _fail_row 的 [:512] 统一承担)。"""
    names = "、".join(f"{name}(回收站)" if deleted else name for name, deleted in holders)
    return f"{key} 已被 {names}占用"


def random_suffix_key(canonical_key: str, rand: str) -> str:
    """F2b 预定 key(D5):canonical key 的末段文件名插入随机段,目录前缀不变 ——
    `dir/1.txt → dir/1.<rand>.txt`;无扩展名(或 `.hidden` 形态)→ `dir/<name>.<rand>`。
    filename 本身不变,仅 key 漂移。"""
    dir_part, slash, filename = canonical_key.rpartition("/")
    stem, dot, ext = filename.rpartition(".")
    has_ext = bool(dot) and bool(stem)
    suffixed = f"{stem}.{rand}.{ext}" if has_ext else f"{filename}.{rand}"
    return f"{dir_part}{slash}{suffixed}"


# ─── 事件 ID / 入队 ───────────────────────────────────────────────────────────


async def enqueue_baidu_backup_run(pool: ArqRedis, task_id: uuid.UUID, seq: int) -> bool:
    """入队(§6):enqueue_job('baidu_backup_run', task_id, expected_seq, _job_id=...)。

    返回 False = 入队失败(job 为 None);Redis 队列整体丢失由 sweeper 兜底接管。
    """
    try:
        job = await pool.enqueue_job(
            "baidu_backup_run", str(task_id), seq, _job_id=baidu_job_id(task_id, seq),
        )
    except Exception as e:
        log.warning("baidu enqueue fail task=%s seq=%s err=%s", task_id, seq, e)
        return False
    return job is not None


@dataclass(frozen=True)
class DispatchOutcome:
    seq: int | None   # None = 派发 CAS 0 行(失去资格/并发取代)
    enqueued: bool    # 派发成功但入队失败 → sweeper 兜底(不再重试入队)


async def dispatch_and_enqueue(
    db: AsyncSession,
    pool: ArqRedis,
    *,
    task_id: uuid.UUID,
    mode: Literal["create", "revive", "sweep"],
    now: datetime,
    throttle_s: int = 0,
    allowed_from: tuple[str, ...] | None = None,
) -> DispatchOutcome:
    """派发步 + 入队(§6):入队失败需重试派发步(再次自增 seq),至多 3 次。

    - create:刚插入的任务行,无条件派发
    - revive:终态来源约束(allowed_from)+ 复位语义(见 dispatch_task)
    - sweep:活动中 + 无租约/过期 + 派发超时谓词
    """
    for _ in range(3):
        seq = await dispatch_task(
            db, task_id=task_id, mode=mode, now=now,
            throttle_s=throttle_s, allowed_from=allowed_from,
        )
        if seq is None:
            return DispatchOutcome(seq=None, enqueued=False)
        await db.commit()
        if await enqueue_baidu_backup_run(pool, task_id, seq):
            return DispatchOutcome(seq=seq, enqueued=True)
        log.warning("baidu dispatch enqueue failed task=%s seq=%s(retry dispatch)", task_id, seq)
    return DispatchOutcome(seq=None, enqueued=False)


# ─── 四类租约 CAS(§6;互斥唯一凭证)──────────────────────────────────────────


async def dispatch_task(
    db: AsyncSession,
    *,
    task_id: uuid.UUID,
    mode: Literal["create", "revive", "sweep"],
    now: datetime,
    throttle_s: int = 0,
    allowed_from: tuple[str, ...] | None = None,
) -> int | None:
    """派发步 CAS:lease_seq+1 + 清 runner/租约 + dispatched_at=now。

    - 复活型/接管分支同事务复位在途行(见 reset_importing_rows,由调用方与本次
      UPDATE 同事务执行 —— 本函数只管 tasks 行)
    - revive:status 按 enum_done 分叉(false→enumerating 重枚举 / true→running)、
      复位 round_started_at/retry_count+1/cancel 位/fail_reason;WHERE 带终态来源约束
    - sweep:WHERE 活动中 + 无租约/租约过期(含 NULL)+ 派发超时(含从未派发);
      不复位 round_started_at(轮起点跨接管累计,48h 判停才可达)
    - 派发不写未来租约(否则取消 API 的「无租约→直接终态化」快路径会被伪装租约挡住)
    """
    values: dict[str, object] = {
        "lease_seq": Task.lease_seq + 1,
        "runner_id": None,
        "lease_until": None,
        "dispatched_at": now,
    }
    stmt = update(Task).where(Task.id == task_id)
    if mode == "revive":
        values.update({
            "round_started_at": None,           # 复活 = 新一轮
            "retry_count": Task.retry_count + 1,
            "cancel_requested": False,          # 防上一轮残留取消位把复活任务「秒取消」
            "cancel_reason": None,
            "fail_reason": None,
            "status": case(
                (Task.enum_done.is_(True), literal(STATUS_RUNNING)),
                else_=literal(STATUS_ENUMERATING),
            ),
        })
        if allowed_from:
            stmt = stmt.where(Task.status.in_(allowed_from))
    elif mode == "sweep":
        deadline = now - timedelta(seconds=throttle_s)
        stmt = stmt.where(
            Task.status.in_(ACTIVE_STATUSES),
            Task.lease_until.is_(None) | (Task.lease_until < now),   # NULL 分支显式
            Task.dispatched_at.is_(None) | (Task.dispatched_at < deadline),
        )
    stmt = (
        stmt.values(**values)
        .execution_options(**_SYNC_OFF)   # 防 onupdate expire 会话内 task(P0)
        .returning(Task.lease_seq)
    )
    res = await db.execute(stmt)
    row = res.first()
    return int(row.lease_seq) if row is not None else None


async def reset_importing_rows(db: AsyncSession, *, task_id: uuid.UUID) -> int:
    """接管/复活/接力派发步必须同步复位在途行(§6):importing→pending,
    保留 bytes_done/minio_upload_id/attempts(单 runner 下至多 1 行)。"""
    res = await db.execute(
        update(TaskFile)
        .where(TaskFile.task_id == task_id, TaskFile.status == "importing")
        .values(status="pending")
        .execution_options(**_SYNC_OFF)
    )
    return _rowcount(res)


async def claim_task(
    db: AsyncSession, *, task_id: uuid.UUID, expected_seq: int, runner_id: str,
    now: datetime, lease_s: int,
) -> bool:
    """job 启动认领 CAS(§6):0 行 = 已被更高 seq 取代,安静退出。

    round_started_at 用 COALESCE 保留(接力/接管的新 job 认领不刷新轮起点,
    否则 48h 判停永不可达);speed 锚点随认领清零重采。
    """
    res = await db.execute(
        update(Task)
        .where(
            Task.id == task_id,
            Task.status.in_(ACTIVE_STATUSES),
            Task.lease_seq == expected_seq,
            Task.runner_id.is_(None),
        )
        .values(
            runner_id=runner_id,
            lease_until=now + timedelta(seconds=lease_s),
            round_started_at=func.coalesce(Task.round_started_at, now),
            speed_bps=0,
            speed_anchor_bytes=0,
            speed_anchor_at=None,
        )
        .execution_options(**_SYNC_OFF)
    )
    return _rowcount(res) == 1


@dataclass(frozen=True)
class RenewState:
    """续期 RETURNING 快照:检查点消费 cancel/48h 判停所需的任务态。"""

    cancel_requested: bool
    cancel_reason: str | None
    round_started_at: datetime | None


async def renew_lease(
    db: AsyncSession, *, task_id: uuid.UUID, expected_seq: int, runner_id: str,
    now: datetime, lease_s: int,
) -> RenewState | None:
    """续期/所有权检查 CAS(§6):含 status 条件(终态化后立即失去所有权);
    0 行 = 已被接管/直终态化 → None(调用方立即中止,仅停写不改行状态)。"""
    res = await db.execute(
        update(Task)
        .where(
            Task.id == task_id,
            Task.status.in_(ACTIVE_STATUSES),
            Task.lease_seq == expected_seq,
            Task.runner_id == runner_id,
        )
        .values(lease_until=now + timedelta(seconds=lease_s))
        .execution_options(**_SYNC_OFF)
        .returning(Task.cancel_requested, Task.cancel_reason, Task.round_started_at)
    )
    row = res.first()
    if row is None:
        return None
    return RenewState(
        cancel_requested=bool(row.cancel_requested),
        cancel_reason=row.cancel_reason,
        round_started_at=row.round_started_at,
    )


async def relay_dispatch(
    db: AsyncSession, *, task_id: uuid.UUID, expected_seq: int, runner_id: str,
    now: datetime,
) -> int | None:
    """接力派发变体(§6,55min 检查点触发,带所有权守卫):

    UPDATE ... WHERE id AND lease_seq=:expected AND runner_id=:uuid —— 0 行=已失去
    所有权(被 sweeper 接管等)→ None,调用方直接 return 不入队;影响 1 行才入队
    新 job。成功后同事务复位在途 importing 行(断点字段保留 —— 0.08MiB/s 下单个
    16MB part 约 200s,任何 >~264MB 的文件都必然跨越接力点且正处于 importing)。
    enqueue 由调用方执行;enqueue 失败不重试、交 sweeper(≤10-15min 接管)——
    本 UPDATE 已置 runner_id=NULL,「再次自增 seq 重试派发」的所有权守卫在本分支
    永不命中。不可复用 sweeper 条件(自持新租约恒不匹配)。
    """
    res = await db.execute(
        update(Task)
        .where(Task.id == task_id, Task.lease_seq == expected_seq, Task.runner_id == runner_id)
        .values(
            lease_seq=Task.lease_seq + 1, runner_id=None, lease_until=None, dispatched_at=now,
        )
        .execution_options(**_SYNC_OFF)
        .returning(Task.lease_seq)
    )
    row = res.first()
    if row is None:
        return None
    await reset_importing_rows(db, task_id=task_id)
    return int(row.lease_seq)


async def release_for_queueing(
    db: AsyncSession, *, task_id: uuid.UUID, expected_seq: int, runner_id: str,
) -> bool:
    """并发门控退出(§6 确定性准入):复位 round_started_at=NULL 并清 runner/租约。

    UPDATE 带 CAS 谓词(与全篇守卫风格一致);不留半租约干扰计数与接管判定。
    """
    res = await db.execute(
        update(Task)
        .where(Task.id == task_id, Task.lease_seq == expected_seq, Task.runner_id == runner_id)
        .values(round_started_at=None, runner_id=None, lease_until=None)
        .execution_options(**_SYNC_OFF)
    )
    return _rowcount(res) == 1


async def admission_top_task_ids(db: AsyncSession, *, limit: int = 2) -> list[uuid.UUID]:
    """确定性准入排序(§6):活动中任务按 round_started_at NULLS LAST, created_at, id。"""
    res = await db.execute(
        select(Task.id)
        .where(Task.status.in_(ACTIVE_STATUSES))
        .order_by(Task.round_started_at.nulls_last(), Task.created_at, Task.id)
        .limit(limit)
    )
    return list(res.scalars().all())


async def has_active_task(
    db: AsyncSession, *, binding_id: uuid.UUID, exclude_task_id: uuid.UUID | None = None,
) -> bool:
    """同绑定活动互斥应用层检查(§5.2;partial unique index 兜底 409)。"""
    stmt = select(Task.id).where(
        Task.binding_id == binding_id, Task.status.in_(ACTIVE_STATUSES),
    )
    if exclude_task_id is not None:
        stmt = stmt.where(Task.id != exclude_task_id)
    return (await db.execute(stmt.limit(1))).scalar_one_or_none() is not None


# ─── 残留 multipart 会话(断点作废统一口径,§5.2)────────────────────────────


@dataclass(frozen=True)
class UploadSessionRef:
    file_id: uuid.UUID
    task_id: uuid.UUID
    bucket: str
    key: str
    upload_id: str
    importing: bool   # 活跃会话行(>budget 时仅处理这些,其余交 sweeper/lifecycle)


async def load_session_refs(
    db: AsyncSession,
    *,
    task_id: uuid.UUID | None = None,
    user_id: uuid.UUID | None = None,
    terminal_only: bool = False,
) -> list[UploadSessionRef]:
    """收集仍保留 minio_upload_id 的行(三元组直读,防目标夹被删后 key 无法重建)。"""
    columns = (
        TaskFile.id, TaskFile.task_id, TaskFile.minio_bucket, TaskFile.minio_key,
        TaskFile.minio_upload_id, TaskFile.status,
    )
    conditions: list[ColumnElement[bool]] = [TaskFile.minio_upload_id.is_not(None)]
    stmt = select(*columns)
    if user_id is not None:
        stmt = stmt.join(Task, Task.id == TaskFile.task_id)
        conditions.append(Task.user_id == user_id)
        if terminal_only:
            conditions.append(Task.status.in_(TERMINAL_STATUSES))
    if task_id is not None:
        conditions.append(TaskFile.task_id == task_id)
    res = await db.execute(stmt.where(*conditions).order_by(TaskFile.id))
    refs: list[UploadSessionRef] = []
    for row in res.all():
        if row.minio_bucket and row.minio_key and row.minio_upload_id:
            refs.append(UploadSessionRef(
                file_id=row.id, task_id=row.task_id,
                bucket=row.minio_bucket, key=row.minio_key, upload_id=row.minio_upload_id,
                importing=row.status == "importing",
            ))
    return refs


def _is_no_such_upload(e: BaseException) -> bool:
    return isinstance(e, ClientError) and str(
        (e.response or {}).get("Error", {}).get("Code", "")
    ) in ("NoSuchUpload",)


async def abort_leftover_sessions(
    db: AsyncSession,
    presign: PresignService,
    refs: list[UploadSessionRef],
    *,
    budget: int = ABORT_INLINE_BUDGET,
) -> dict[str, int]:
    """统一断点作废 helper(§5.2;cancel/DELETE/换绑/解绑共用):

    - ≤budget 行:内联 asyncio.to_thread 分批(10 行/批)abort,成功(含
      NoSuchUpload=已清理)后清 minio_upload_id 并清零 bytes_done;
    - >budget 行:仅 abort importing 行(至多 1 行持活跃会话;failed 行存量可达
      数十至数百,全量内联会拖垮请求),其余交 sweeper 30d 孤儿通道与 bucket
      lifecycle 兜底;
    - abort 抛错(非 NoSuchUpload)→ 保留列由 sweeper 下轮重试。

    返回 {"aborted", "kept", "deferred"};清列 UPDATE 由调用方 commit。
    """
    deferred = max(0, len(refs) - budget)
    to_process = refs if len(refs) <= budget else [r for r in refs if r.importing]
    aborted_ids: list[uuid.UUID] = []
    kept = 0
    for i in range(0, len(to_process), ABORT_BATCH_SIZE):
        batch = to_process[i : i + ABORT_BATCH_SIZE]

        async def _abort_one(ref: UploadSessionRef) -> bool:
            try:
                await asyncio.to_thread(
                    presign.abort_multipart_upload, ref.bucket, ref.key, ref.upload_id,
                )
                return True
            except Exception as e:
                if _is_no_such_upload(e):
                    return True  # 会话已死(complete 后失效)→ 视为已清理
                log.warning("abort leftover session fail file=%s upload_id=%s err=%s",
                            ref.file_id, ref.upload_id, e)
                return False

        results = await asyncio.gather(*[_abort_one(r) for r in batch])
        for ref, ok in zip(batch, results, strict=True):
            if ok:
                aborted_ids.append(ref.file_id)
            else:
                kept += 1
    if aborted_ids:
        await db.execute(
            update(TaskFile)
            .where(TaskFile.id.in_(aborted_ids))
            .values(minio_upload_id=None, bytes_done=0)
        )
    return {"aborted": len(aborted_ids), "kept": kept, "deferred": deferred}


# ─── 复活型接口统一前置(§5.2)───────────────────────────────────────────────


async def guard_revival(
    db: AsyncSession, *, task: Task, binding: BaiduBinding | None,
) -> None:
    """复活型接口(retry/overwrite)统一前置;违规抛 BaiduTaskError(默认 409)。"""
    if binding is None or binding.status != "active":
        raise BaiduTaskError("请先重新绑定百度网盘账号", code="binding_inactive")
    if task.target_folder_id is None:
        raise BaiduTaskError("目标文件夹已被删除,请删除任务后重建")
    if task.bound_baidu_uid != binding.baidu_uid:
        raise BaiduTaskError("绑定账号已更换,请删除任务重建")
    if await has_active_task(db, binding_id=binding.id, exclude_task_id=task.id):
        raise BaiduTaskError("同一绑定已有进行中的任务,请等待其结束")


async def reset_failed_rows(db: AsyncSession, *, task_id: uuid.UUID) -> int:
    """retry-failed:failed 且 non_retryable=false 的行 → pending(attempts 归零重计,§5.3)。"""
    res = await db.execute(
        update(TaskFile)
        .where(
            TaskFile.task_id == task_id,
            TaskFile.status == "failed",
            TaskFile.non_retryable.is_(False),
        )
        .values(status="pending", attempts=0)
        .execution_options(**_SYNC_OFF)
    )
    return _rowcount(res)


async def reset_one_failed_row(
    db: AsyncSession, *, task_id: uuid.UUID, file_id: uuid.UUID,
) -> int:
    """单文件 retry:failed 且 non_retryable=false → pending(non_retryable 行由 router 409)。"""
    res = await db.execute(
        update(TaskFile)
        .where(
            TaskFile.id == file_id,
            TaskFile.task_id == task_id,
            TaskFile.status == "failed",
            TaskFile.non_retryable.is_(False),
        )
        .values(status="pending", attempts=0)
        .execution_options(**_SYNC_OFF)
    )
    return _rowcount(res)


async def reset_skipped_row_for_overwrite(
    db: AsyncSession, *, task_id: uuid.UUID, file_id: uuid.UUID,
) -> int:
    """overwrite:skipped_exists → pending 且置 overwrite=true(清除-再导入,§5.2)。"""
    res = await db.execute(
        update(TaskFile)
        .where(
            TaskFile.id == file_id,
            TaskFile.task_id == task_id,
            TaskFile.status == "skipped_exists",
        )
        .values(status="pending", attempts=0, overwrite=True)
        .execution_options(**_SYNC_OFF)
    )
    return _rowcount(res)


KEY_CONFLICT_PREFIX = "key_conflict:"


def is_key_conflict_error(last_error: str | None) -> bool:
    """F2 行级出路准入判定:failed 行的 last_error 是否为 key_conflict 失败(F1)。"""
    return last_error is not None and last_error.startswith(KEY_CONFLICT_PREFIX)


async def reset_failed_row_for_overwrite(
    db: AsyncSession, *, task_id: uuid.UUID, file_id: uuid.UUID,
) -> int:
    """F2a overwrite 扩展准入:key_conflict 失败行(可重试)→ pending 且置
    overwrite=true;worker 导入时对同 key 占用行做权限复查后物理清除。字段清理
    语义与既有 reset 一致(不动 last_error/non_retryable —— key_conflict 行本就
    non_retryable=false,last_error 留作历史)。"""
    res = await db.execute(
        update(TaskFile)
        .where(
            TaskFile.id == file_id,
            TaskFile.task_id == task_id,
            TaskFile.status == "failed",
            TaskFile.non_retryable.is_(False),
            TaskFile.last_error.like(f"{KEY_CONFLICT_PREFIX}%"),
        )
        .values(status="pending", attempts=0, overwrite=True)
        .execution_options(**_SYNC_OFF)
    )
    return _rowcount(res)


async def random_key_taken(
    db: AsyncSession, *, bucket: str, key: str,
    task_id: uuid.UUID, exclude_file_id: uuid.UUID,
) -> bool:
    """F2b 预定 key 冲突探测:任一 asset 行引用该 key(含软删,与 §6 预检口径一致),
    或同任务其他 manifest 行已预定同一 key(排除自身)→ True。"""
    asset_hit = await db.scalar(
        select(func.count()).select_from(Asset).where(
            Asset.minio_bucket == bucket, Asset.minio_key == key,
        )
    )
    if int(asset_hit or 0) > 0:
        return True
    row_hit = await db.scalar(
        select(func.count()).select_from(TaskFile).where(
            TaskFile.task_id == task_id,
            TaskFile.id != exclude_file_id,
            TaskFile.reserved_key == key,
        )
    )
    return int(row_hit or 0) > 0


async def reserve_random_key(
    db: AsyncSession, *, task_id: uuid.UUID, file_id: uuid.UUID, reserved_key: str,
) -> int:
    """F2b random-suffix 复位:key_conflict 失败行(或派发前中断的已预留 pending 行,
    幂等复用)→ pending + 写 reserved_key + 清 last_error + overwrite=false
    (attempts 归零按既有 reset 语义)。

    CAS 谓词防并发双请求双 key 漂移:两请求并发各自生成候选 key 时,先写者
    落 key(rowcount=1),后写者谓词不命中(rowcount=0,路由侧转 409)。
    修复注记(P2-1):原谓词只卡状态,行复位 pending 后仍命中,并发首次预定
    两事务先后写均 rowcount=1 → key 被后写者静默改写;现谓词要求「行尚未
    预定(reserved_key IS NULL,首次预定)」或「reserved_key 与本次写入值
    相等(幂等复用,覆盖 failed 重试 / pending 断点续派)」二者其一。"""
    res = await db.execute(
        update(TaskFile)
        .where(
            TaskFile.id == file_id,
            TaskFile.task_id == task_id,
            TaskFile.status.in_(("failed", "pending")),
            TaskFile.non_retryable.is_(False),
            # 首次预定或同值复用才命中;他请求已预定成别的 key → 0 行,不漂移
            or_(
                TaskFile.reserved_key.is_(None),
                TaskFile.reserved_key == reserved_key,
            ),
        )
        .values(
            status="pending", attempts=0, overwrite=False, last_error=None,
            non_retryable=False, reserved_key=reserved_key,
        )
        .execution_options(**_SYNC_OFF)
    )
    return _rowcount(res)


# ─── 终态化:归位表 + 三分支判定 + 聚合重算(§6)────────────────────────────


async def finalize_rows_cancelled(db: AsyncSession, *, task_id: uuid.UUID) -> int:
    """归位表 cancelled 分支:pending/importing → cancelled(overwrite 行加注)。"""
    res = await db.execute(
        update(TaskFile)
        .where(TaskFile.task_id == task_id, TaskFile.status.in_(("pending", "importing")))
        .values(
            status=STATUS_CANCELLED,
            last_error=case(
                (TaskFile.overwrite.is_(True), literal(_CANCELLED_OVERWRITE_NOTE)),
                else_=TaskFile.last_error,
            ),
        )
        .execution_options(**_SYNC_OFF)
    )
    return _rowcount(res)


async def finalize_rows_failed(
    db: AsyncSession, *, task_id: uuid.UUID, reason: str, overwrite_note: bool = False,
) -> int:
    """归位表 failed 分支(task_timeout/binding_expired/feature_disabled):
    pending/importing → failed(overwrite 行按统一规则补注「原文件已被删除」)。"""
    note = f"{reason}({_FAILED_OVERWRITE_NOTE})" if overwrite_note else reason
    res = await db.execute(
        update(TaskFile)
        .where(TaskFile.task_id == task_id, TaskFile.status.in_(("pending", "importing")))
        .values(
            status=STATUS_FAILED,
            last_error=case(
                (TaskFile.overwrite.is_(True), literal(note)),
                else_=literal(reason),
            ),
        )
        .execution_options(**_SYNC_OFF)
    )
    return _rowcount(res)


async def finalize_task_terminal(
    db: AsyncSession, *, task_id: uuid.UUID, status: str,
    fail_reason: str | None = None,
) -> bool:
    """任务终态化 CAS:仅活动中可落终态,同步清 runner/租约(§5.2 cancel:
    必须清 runner —— 否则长 purge 里的旧 runner 恢复后收尾写谓词仍命中)。"""
    res = await db.execute(
        update(Task)
        .where(Task.id == task_id, Task.status.in_(ACTIVE_STATUSES))
        .values(status=status, fail_reason=fail_reason, runner_id=None, lease_until=None)
        .execution_options(**_SYNC_OFF)
    )
    return _rowcount(res) == 1


@dataclass(frozen=True)
class TaskAggregates:
    """manifest 聚合口径(§6):done=success+skipped;字节=Σ(success+skipped)
    source_size + importing bytes_done(skipped 行字节同样「已消化」)。"""

    total_files: int = 0
    done_files: int = 0
    failed_files: int = 0
    skipped_files: int = 0
    cancelled_files: int = 0
    pending_files: int = 0
    importing_files: int = 0
    total_bytes: int = 0
    done_bytes: int = 0


async def compute_aggregates(db: AsyncSession, *, task_id: uuid.UUID) -> TaskAggregates:
    rows = (await db.execute(
        select(
            TaskFile.status,
            func.count().label("cnt"),
            func.coalesce(func.sum(TaskFile.source_size), 0).label("bytes"),
        )
        .where(TaskFile.task_id == task_id)
        .group_by(TaskFile.status)
    )).all()
    importing_bytes = int((await db.execute(
        select(func.coalesce(func.sum(TaskFile.bytes_done), 0))
        .where(TaskFile.task_id == task_id, TaskFile.status == "importing")
    )).scalar_one())
    agg = TaskAggregates()
    counts: dict[str, int] = {}
    sizes: dict[str, int] = {}
    for status, cnt, size in rows:
        counts[status] = int(cnt)
        sizes[status] = int(size)
    done = counts.get("success", 0) + counts.get("skipped_exists", 0)
    agg = TaskAggregates(
        total_files=sum(counts.values()),
        done_files=done,
        failed_files=counts.get(STATUS_FAILED, 0),
        skipped_files=counts.get("skipped_exists", 0),
        cancelled_files=counts.get(STATUS_CANCELLED, 0),
        pending_files=counts.get("pending", 0),
        importing_files=counts.get("importing", 0),
        total_bytes=sum(sizes.values()),
        done_bytes=sizes.get("success", 0) + sizes.get("skipped_exists", 0) + importing_bytes,
    )
    return agg


async def apply_aggregates(db: AsyncSession, *, task_id: uuid.UUID, agg: TaskAggregates) -> None:
    await db.execute(
        update(Task)
        .where(Task.id == task_id)
        .values(
            total_files=agg.total_files,
            done_files=agg.done_files,
            failed_files=agg.failed_files,
            skipped_files=agg.skipped_files,
            cancelled_files=agg.cancelled_files,
            total_bytes=agg.total_bytes,
            done_bytes=agg.done_bytes,
        )
        .execution_options(**_SYNC_OFF)
    )


async def recompute_aggregates(db: AsyncSession, *, task_id: uuid.UUID) -> TaskAggregates:
    """聚合计数重算(§6:一律由 manifest 行状态 GROUP BY 重算,不做增量维护)。"""
    agg = await compute_aggregates(db, task_id=task_id)
    await apply_aggregates(db, task_id=task_id, agg=agg)
    return agg


async def aggregate_and_finalize_if_done(
    db: AsyncSession, *, task_id: uuid.UUID,
) -> str | None:
    """导入循环结束(无 pending/importing 行)时的三分支判定(§6):
    failed_files>0 → failed('file_failed');cancelled_files>0 → cancelled;
    否则 completed。取消路径恒 cancelled 优先于本判定(调用方处理)。"""
    agg = await recompute_aggregates(db, task_id=task_id)
    if agg.pending_files > 0 or agg.importing_files > 0:
        return None
    if agg.failed_files > 0:
        ok = await finalize_task_terminal(db, task_id=task_id, status=STATUS_FAILED,
                                          fail_reason=FAIL_FILE_FAILED)
        return STATUS_FAILED if ok else None
    if agg.cancelled_files > 0:
        ok = await finalize_task_terminal(db, task_id=task_id, status=STATUS_CANCELLED)
        return STATUS_CANCELLED if ok else None
    ok = await finalize_task_terminal(db, task_id=task_id, status=STATUS_COMPLETED)
    return STATUS_COMPLETED if ok else None


async def bump_done_bytes(
    db: AsyncSession, *, task_id: uuid.UUID, expected_seq: int, runner_id: str, delta: int,
) -> bool:
    """导入中 done_bytes 快速通道(单个大文件下载期间进度/ETA 不静止,§6):
    增量累加带所有权守卫;聚合重算在行状态变更时覆盖校正。"""
    res = await db.execute(
        update(Task)
        .where(
            Task.id == task_id,
            Task.lease_seq == expected_seq,
            Task.runner_id == runner_id,
            Task.status.in_(ACTIVE_STATUSES),
        )
        .values(done_bytes=Task.done_bytes + delta)
        .execution_options(**_SYNC_OFF)
    )
    return _rowcount(res) == 1


async def update_speed_anchor(
    db: AsyncSession, *, task_id: uuid.UUID, expected_seq: int, runner_id: str,
    now: datetime, min_interval_s: float = 10.0,
) -> None:
    """检查点速度锚点差分(§6):speed_bps = Δdone_bytes/Δt;带所有权谓词
    (被接管后旧 runner 的污染写被挡);采样间隔不足则仅推进锚点。"""
    row = (await db.execute(
        select(Task.done_bytes, Task.speed_anchor_bytes, Task.speed_anchor_at)
        .where(Task.id == task_id)
    )).first()
    if row is None:
        return
    done, anchor_bytes, anchor_at = row
    values: dict[str, object] = {"speed_anchor_bytes": done, "speed_anchor_at": now}
    if anchor_at is not None:
        elapsed = (now - anchor_at).total_seconds()
        delta = done - (anchor_bytes or 0)
        if elapsed >= min_interval_s and delta > 0:
            values["speed_bps"] = int(delta / elapsed)
    await db.execute(
        update(Task)
        .where(
            Task.id == task_id,
            Task.lease_seq == expected_seq,
            Task.runner_id == runner_id,
        )
        .values(**values)
        .execution_options(**_SYNC_OFF)
    )


# ─── refresh 单飞(§5.3;自 router 上收,worker 共用)─────────────────────────


async def decrypt_access_token(
    db: AsyncSession, row: BaiduBinding, crypto: TokenCryptoService,
) -> str:
    """解密 access_token;失败(密钥轮换)→ 绑定置 expired → 409(§5.1 轮换影响)。"""
    try:
        return crypto.decrypt(row.access_token_enc)
    except TokenDecryptError:
        row.status = "expired"
        await db.commit()
        log.warning("baidu token decrypt failed binding=%s(加密密钥可能已轮换),已置 expired", row.id)
        raise BaiduTaskError(
            "绑定密钥已轮换,请重新绑定", code="binding_inactive",
        ) from None


async def _refresh_locked_once(
    db: AsyncSession, binding_id: uuid.UUID, *, crypto: TokenCryptoService,
    client: BaiduNetdiskClient, now: datetime,
) -> str:
    """拿行锁直接 refresh(单飞核心步);失败上抛,由调用方决定重试/置 expired。"""
    locked = (await db.execute(
        select(BaiduBinding).where(BaiduBinding.id == binding_id).with_for_update(),
    )).scalar_one_or_none()
    if locked is None or locked.status != "active":
        raise BaiduTaskError("百度网盘绑定已失效,请重新绑定", code="binding_inactive")
    if locked.access_token_expires_at > now + timedelta(seconds=TOKEN_EXPIRY_MARGIN_S):
        # 并发请求已完成刷新(单飞)→ 释放行锁直接复用现存 token
        await db.rollback()
        # rollback 会 expire 会话内全部对象;直接读 locked.access_token_enc 是
        # 同步 IO(async 下 MissingGreenlet),先显式 refresh 再解密
        await db.refresh(locked)
        return await decrypt_access_token(db, locked, crypto)
    try:
        tokens = await client.refresh_token(crypto.decrypt(locked.refresh_token_enc))
    except TokenDecryptError:
        locked.status = "expired"
        await db.commit()
        raise BaiduTaskError("绑定密钥已轮换,请重新绑定", code="binding_inactive") from None
    except Exception:
        await db.rollback()  # 释放行锁再重试(退避在行锁外,防锁持有放大,§5.3)
        raise
    locked.access_token_enc = crypto.encrypt(tokens.access_token)
    locked.refresh_token_enc = crypto.encrypt(tokens.refresh_token)
    locked.access_token_expires_at = now + timedelta(seconds=tokens.expires_in)
    locked.token_rotated_at = now  # 任何 token 覆盖写入都刷新(403 dlink 甄别锚点,§4)
    await db.commit()
    return tokens.access_token


async def ensure_fresh_access_token(
    db: AsyncSession,
    binding: BaiduBinding,
    *,
    crypto: TokenCryptoService,
    client: BaiduNetdiskClient,
) -> str:
    """取可用 access_token;自然过期走 §5.3 refresh 单飞:

    - 提前 60s 余量判过期;行锁内复查 expires_at(并发只刷一次)
    - refresh HTTP 失败退避在行锁外(每次重试重新拿锁、复查 expires_at 再试)
    - 连续 3 次失败才置 binding=expired(防单次网络抖动误杀绑定)
    """
    now = datetime.now(UTC)
    if binding.access_token_expires_at > now + timedelta(seconds=TOKEN_EXPIRY_MARGIN_S):
        return await decrypt_access_token(db, binding, crypto)
    last_err: Exception | None = None
    for attempt in range(REFRESH_MAX_ATTEMPTS):
        if attempt:
            await asyncio.sleep(REFRESH_RETRY_BACKOFF_S)  # 退避在行锁外
        try:
            return await _refresh_locked_once(
                db, binding.id, crypto=crypto, client=client, now=datetime.now(UTC),
            )
        except BaiduTaskError:
            raise  # binding_inactive / 密钥轮换:不重试
        except Exception as e:
            last_err = e
            log.warning("baidu token refresh failed binding=%s attempt=%s err=%s",
                        binding.id, attempt + 1, e)
    row = await db.get(BaiduBinding, binding.id)
    if row is not None:
        row.status = "expired"
        await db.commit()
    log.warning("baidu token refresh exhausted binding=%s last_err=%s", binding.id, last_err)
    raise BaiduTaskError(
        "百度 token 连续刷新失败,绑定已失效,请重新绑定", code="binding_inactive",
    )


async def force_refresh_access_token(
    db: AsyncSession, binding_id: uuid.UUID, *, crypto: TokenCryptoService,
    client: BaiduNetdiskClient,
) -> str:
    """吊销兜底(§5.3):token 提前失效(auth_expired 但 expires_at 未到)时
    强制走一次 refresh 单飞(不复用现存 token);失败重试口径同 ensure_fresh。"""
    last_err: Exception | None = None
    for attempt in range(REFRESH_MAX_ATTEMPTS):
        if attempt:
            await asyncio.sleep(REFRESH_RETRY_BACKOFF_S)
        try:
            return await _refresh_locked_once(
                db, binding_id, crypto=crypto, client=client, now=datetime.now(UTC),
            )
        except BaiduTaskError:
            raise
        except Exception as e:
            last_err = e
            log.warning("baidu token force refresh failed binding=%s attempt=%s err=%s",
                        binding_id, attempt + 1, e)
    row = await db.get(BaiduBinding, binding_id)
    if row is not None:
        row.status = "expired"
        await db.commit()
    log.warning("baidu token force refresh exhausted binding=%s last_err=%s", binding_id, last_err)
    raise BaiduTaskError(
        "百度 token 连续刷新失败,绑定已失效,请重新绑定", code="binding_inactive",
    )


async def mark_binding_expired(db: AsyncSession, binding_id: uuid.UUID) -> None:
    """refresh 确认失效 → binding=expired(§5.3);在途任务由调用方按
    failed('binding_expired') 终态化。"""
    row = await db.get(BaiduBinding, binding_id)
    if row is not None and row.status == "active":
        row.status = "expired"
        await db.commit()
        log.warning("baidu binding marked expired binding=%s", binding_id)


# ─── 创建校验链(§5.2 POST /backup/tasks)────────────────────────────────────


async def assert_binding_active(binding: BaiduBinding | None) -> BaiduBinding:
    if binding is None or binding.status != "active":
        raise BaiduTaskError("请先绑定百度网盘账号", code="binding_inactive")
    return binding


async def assert_target_chain_not_sensitive(db: AsyncSession, folder: Folder) -> None:
    """沿 parent_folder_id 链向上核查敏感祖先(§5.2):普通子夹挂在 sensitive 夹下
    是被允许的形态,但作为导入目标同样 403 快败,勿留到导入期逐行 non_retryable。"""
    seen: set[uuid.UUID] = set()
    current: Folder | None = folder
    while current is not None and current.id not in seen:
        if current.is_sensitive:
            raise BaiduTaskError("所选目标文件夹不可用作导入目标", http_status=403, code="access_denied")
        seen.add(current.id)
        current = await db.get(Folder, current.parent_folder_id) if current.parent_folder_id else None


async def find_root_level_folder(
    db: AsyncSession, *, project_id: uuid.UUID, name: str,
) -> Folder | None:
    stmt = select(Folder).where(
        Folder.project_id == project_id,
        Folder.parent_folder_id.is_(None),
        Folder.name == name,
    ).limit(1)
    return (await db.execute(stmt)).scalar_one_or_none()
