"""baidu_backup router — 百度网盘备份导入(方案 §5.2;批次 1 binding + 批次 2 tasks)。

挂载:main.py → prefix="/api/v1/baidu";受 settings.baidu_backup_enabled 门控
(默认 false),未启用时统一返回 404。

路由全集(14 条):
  GET    /backup/binding                绑定状态
  POST   /backup/binding/authorize-url  生成 oob 授权链接
  POST   /backup/binding                授权码换 token 落库(Fernet 加密 + 限流)
  DELETE /backup/binding                软解绑(行保留,密文清空;①取消活动中任务
                                        ②作废残留断点,方案 §5.2 覆盖前处置)
  GET    /backup/netdisk/folders        网盘目录树懒加载(folder=1 + 后端聚合分页
                                        + 60s (user_id,path) Redis 缓存)
  POST   /backup/tasks                  创建任务(校验链 + 派发步入队)
  GET    /backup/tasks                  任务列表(created_at DESC, id DESC 稳定排序)
  GET    /backup/tasks/{id}             任务详情
  GET    /backup/tasks/{id}/files       manifest 分页(target_path 行级拼装+两级回退)
  POST   /backup/tasks/{id}/cancel      取消(CAS 直终态化 {finalized})
  DELETE /backup/tasks/{id}             删除(终态 CAS + abort_leftover_sessions)
  POST   /backup/tasks/{id}/retry-failed       复活(统一前置见方案 §5.2)
  POST   /backup/tasks/{id}/files/{fid}/retry      单文件重试
  POST   /backup/tasks/{id}/files/{fid}/overwrite  覆盖导入(清除-再导入)

换绑/解绑的断点作废统一口径(§5.2 覆盖前处置①②,三处用户触发路径共用
`abort_leftover_sessions` helper,实现于 services/baidu_backup.py)。
"""
from __future__ import annotations

import hashlib
import logging
import uuid
from datetime import UTC, datetime, timedelta

from arq.connections import ArqRedis
from fastapi import APIRouter, Depends, HTTPException, Query, Request
from sqlalchemy import delete, func, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.session import get_db
from app.db.tables import BaiduBackupTask, BaiduBackupTaskFile, BaiduBinding, Folder, Project
from app.deps import CurrentUser, get_audit, get_current_user, get_request_context
from app.models import (
    BaiduAuthorizeUrlOut,
    BaiduBindIn,
    BaiduBindingOut,
    BaiduBindOut,
    BaiduCancelOut,
    BaiduNetdiskFolderOut,
    BaiduNetdiskFoldersOut,
    BaiduReviveOut,
    BaiduTaskCreateIn,
    BaiduTaskFileOut,
    BaiduTaskFilesPage,
    BaiduTaskOut,
    BaiduTasksPage,
)
from app.services.audit import AuditService
from app.services.baidu_backup import (
    ACTIVE_STATUSES,
    CANCEL_BINDING_REPLACED,
    CANCEL_USER,
    FILE_STATUSES,
    STATUS_CANCELLED,
    STATUS_ENUMERATING,
    STATUS_FAILED,
    STATUS_RUNNING,
    TERMINAL_STATUSES,
    BaiduTaskError,
    abort_leftover_sessions,
    assert_binding_active,
    assert_target_chain_not_sensitive,
    derive_eta_seconds,
    derive_queued,
    dispatch_and_enqueue,
    ensure_fresh_access_token,
    finalize_rows_cancelled,
    finalize_task_terminal,
    find_root_level_folder,
    guard_revival,
    has_active_task,
    lease_free,
    load_session_refs,
    recompute_aggregates,
    reset_failed_rows,
    reset_importing_rows,
    reset_one_failed_row,
    reset_skipped_row_for_overwrite,
    source_dir_leaf_name,
    statement_rowcount,
    validate_source_dir,
)
from app.services.baidu_client import BaiduApiError, BaiduNetdiskClient
from app.services.folder_chain import FolderChainError, ensure_root_folder_at_project
from app.services.org import get_default_organization
from app.services.permissions import PermissionsService
from app.services.presign import PresignService
from app.services.token_crypto import TokenCryptoService
from app.settings import get_settings

log = logging.getLogger(__name__)
router = APIRouter()

# ─── 限流 / 缓存常量(Redis 计数,先例 local_auth;命名空间与 arq queue 隔离)──
_BIND_RATE_KEY = "baidu:bind:cnt:user:{user_id}"
_BIND_RATE_MAX = 10             # 每小时至多 10 次绑定尝试(测试态另有百度侧 10 次/小时兜底)
_BIND_RATE_WINDOW_S = 3600
_TASK_RATE_KEY = "baidu:task:create:cnt:user:{user_id}"
_TASK_RATE_MAX = 10             # 每小时至多 10 次建任务(防反复建删白耗枚举配额,§5.2)
_TASK_RATE_WINDOW_S = 3600
_FOLDERS_CACHE_KEY = "baidu:netdisk:folders:{user_id}:{path_hash}"
_FOLDERS_CACHE_TTL_S = 60       # 方案 §9:60s (user_id,path) 缓存,省网盘 API 配额


def _ensure_enabled() -> None:
    """功能开关门控:未启用统一 404(§5.2;回滚急停后路由即 404)。"""
    if not get_settings().baidu_backup_enabled:
        raise HTTPException(404, "feature not found")


def _binding_inactive(message: str) -> HTTPException:
    """409 + 错误码 binding_inactive(§5.2:与创建/复活接口同码同义,前端免特判)。"""
    return HTTPException(409, detail={"code": "binding_inactive", "message": message})


def _task_error_to_http(e: BaiduTaskError) -> HTTPException:
    if e.http_status == 409 and e.code == "binding_inactive":
        return _binding_inactive(str(e))
    if e.code:
        return HTTPException(e.http_status, detail={"code": e.code, "message": str(e)})
    return HTTPException(e.http_status, str(e))


def _get_baidu_client(request: Request) -> BaiduNetdiskClient:
    return request.app.state.baidu_client  # type: ignore[no-any-return]  # app.state 是 Any


def _get_token_crypto(request: Request) -> TokenCryptoService:
    return request.app.state.token_crypto  # type: ignore[no-any-return]


def _get_presign(request: Request) -> PresignService:
    return request.app.state.presign  # type: ignore[no-any-return]


def _get_arq_pool(request: Request) -> ArqRedis:
    return request.app.state.arq_pool  # type: ignore[no-any-return]


async def _get_binding(db: AsyncSession, user_id: uuid.UUID) -> BaiduBinding | None:
    res = await db.execute(select(BaiduBinding).where(BaiduBinding.user_id == user_id))
    return res.scalar_one_or_none()


async def _own_task(
    db: AsyncSession, task_id: uuid.UUID, user_id: uuid.UUID,
) -> BaiduBackupTask:
    """任务读取 + 本人校验(任务与 manifest 全链路仅创建者可读/操作,§8;
    404 不区分存在性/归属,不暴露他人任务存在性)。"""
    task = await db.get(BaiduBackupTask, task_id)
    if task is None or task.user_id != user_id:
        raise HTTPException(404, "task not found")
    return task


async def _clear_dlink_cache(db: AsyncSession, user_id: uuid.UUID) -> None:
    """§5.2 覆盖前处置③:清全部 dlink 缓存 —— 旧账号 dlink 配新 token 常表现为
    403,会被误归类 rate_limited 白耗重试(同账号重授权也要清)。"""
    await db.execute(
        update(BaiduBackupTaskFile)
        .where(BaiduBackupTaskFile.task_id.in_(
            select(BaiduBackupTask.id).where(BaiduBackupTask.user_id == user_id),
        ))
        .values(dlink=None, dlink_expires_at=None)
        .execution_options(synchronize_session=False),  # onupdate expire 同防(服务层 _SYNC_OFF 同因)
    )


def _baidu_error_to_http(e: BaiduApiError) -> HTTPException:
    """BaiduApiError → HTTP(§5.3 六类;detail.code 供前端免特判)。"""
    if e.category == "auth_expired":
        return _binding_inactive("百度网盘绑定已失效,请重新绑定")
    if e.category == "rate_limited":
        return HTTPException(429, detail={"code": "baidu_rate_limited",
                                          "message": "百度接口限频,请稍后再试"})
    if e.category == "not_found":
        return HTTPException(404, detail={"code": "not_found",
                                          "message": "网盘文件或目录不存在"})
    if e.category == "baidu_permission_denied":
        return HTTPException(403, detail={"code": "baidu_permission_denied",
                                          "message": "百度网盘拒绝访问该路径(应用无该目录权限)"})
    if e.category == "link_expired":
        return HTTPException(502, detail={"code": "link_expired",
                                          "message": "下载链接已过期,请重试"})
    return HTTPException(502, detail={"code": "baidu_error",
                                      "message": "百度接口调用失败,请稍后重试"})


# ─── 断点作废①②(换绑/解绑共用,方案 §5.2 覆盖前处置)────────────────────────


async def _cancel_active_tasks_of_binding(
    db: AsyncSession, *, binding_id: uuid.UUID, now: datetime,
) -> list[uuid.UUID]:
    """① 取消名下活动中任务(cancel_reason='binding_replaced'):
    无活跃 runner → API 侧直接终态化(清 runner/租约,归位表 + 聚合重算);
    有活跃 runner → 置 cancel_requested 交在途 runner 于检查点消费(≤一个检查点周期)。"""
    tasks = (await db.execute(
        select(BaiduBackupTask).where(
            BaiduBackupTask.binding_id == binding_id,
            BaiduBackupTask.status.in_(ACTIVE_STATUSES),
        )
    )).scalars().all()
    finalized: list[uuid.UUID] = []
    for task in tasks:
        if lease_free(task.runner_id, task.lease_until, now):
            await finalize_rows_cancelled(db, task_id=task.id)
            if await finalize_task_terminal(db, task_id=task.id, status=STATUS_CANCELLED):
                await recompute_aggregates(db, task_id=task.id)
                finalized.append(task.id)
                continue
        res = await db.execute(
            update(BaiduBackupTask)
            .where(
                BaiduBackupTask.id == task.id,
                BaiduBackupTask.status.in_(ACTIVE_STATUSES),
            )
            .values(cancel_requested=True, cancel_reason=CANCEL_BINDING_REPLACED)
            .execution_options(synchronize_session=False)  # onupdate expire 同防(服务层 _SYNC_OFF 同因)
        )
        if statement_rowcount(res):
            log.info("baidu task cancel deferred to runner task=%s", task.id)
    await db.commit()
    return finalized


async def _invalidate_breakpoints(
    db: AsyncSession, presign: PresignService, *, user_id: uuid.UUID,
) -> dict[str, int]:
    """② 作废全部断点:名下**终态**任务中仍保留 minio_upload_id 的行
    (abort_leftover_sessions 统一口径;活跃任务的在途会话归其 runner 的取消
    消费路径处置,不在此抢)。"""
    refs = await load_session_refs(db, user_id=user_id, terminal_only=True)
    stats = await abort_leftover_sessions(db, presign, refs)
    await db.commit()
    return stats


# ─── 绑定四路由 ────────────────────────────────────────────────────────────────


@router.get("/backup/binding", response_model=BaiduBindingOut)
async def get_binding(
    user: CurrentUser = Depends(get_current_user),  # noqa: B008  # FastAPI DI,repo 全量同款
    db: AsyncSession = Depends(get_db),  # noqa: B008  # FastAPI DI,repo 全量同款
) -> BaiduBindingOut:
    _ensure_enabled()
    binding = await _get_binding(db, user.id)
    if binding is None or binding.status == "unbound":
        return BaiduBindingOut(bound=False, status=binding.status if binding else "unbound")
    return BaiduBindingOut(
        bound=binding.status == "active",
        status=binding.status,
        expires_at=binding.access_token_expires_at,
        baidu_uid=binding.baidu_uid,
        nickname=binding.nickname,
    )


@router.post("/backup/binding/authorize-url", response_model=BaiduAuthorizeUrlOut)
async def create_authorize_url(
    request: Request,
    user: CurrentUser = Depends(get_current_user),  # noqa: B008  # FastAPI DI,repo 全量同款
) -> BaiduAuthorizeUrlOut:
    _ensure_enabled()
    client = _get_baidu_client(request)
    if not client.credentials_ready:
        raise HTTPException(503, "百度应用凭证未配置(BAIDU_APP_KEY/BAIDU_APP_SECRET),无法绑定")
    return BaiduAuthorizeUrlOut(url=client.authorize_url())


async def _apply_binding_fields(
    binding: BaiduBinding,
    *,
    access_token_enc: str,
    refresh_token_enc: str,
    baidu_uid: str,
    nickname: str | None,
    expires_at: datetime,
    now: datetime,
) -> None:
    """重新授权 = 原子覆盖同一 user 行(两 token + uinfo 身份 + 两个甄别锚点)。"""
    binding.access_token_enc = access_token_enc
    binding.refresh_token_enc = refresh_token_enc
    binding.baidu_uid = baidu_uid
    binding.nickname = nickname
    binding.access_token_expires_at = expires_at
    binding.status = "active"
    # 仅 bind/重授权(调 uinfo)时刷新 —— 换绑甄别锚点之一(§4)
    binding.last_authorized_at = now
    # 任何 token 覆盖写入都刷新 —— 403 dlink 甄别锚点(§4)
    binding.token_rotated_at = now


@router.post("/backup/binding", response_model=BaiduBindOut)
async def bind(
    payload: BaiduBindIn,
    request: Request,
    user: CurrentUser = Depends(get_current_user),  # noqa: B008  # FastAPI DI,repo 全量同款
    db: AsyncSession = Depends(get_db),  # noqa: B008  # FastAPI DI,repo 全量同款
    audit: AuditService = Depends(get_audit),  # noqa: B008  # FastAPI DI,repo 全量同款
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008  # FastAPI DI,repo 全量同款
) -> BaiduBindOut:
    """授权码 → token(Fernet 加密落库)+ uinfo 身份(§5.2)。

    - 应用层限流:按用户维度 Redis 计数(先例 local_auth)
    - uinfo 失败/缺 uid → 本次绑定整体失败 502(NOT NULL 防线,§4)
    - 并发双请求撞 unique(user_id) → 回滚改走覆盖更新路径(folders.py 同款范式,
      等价重新授权语义)
    - 重新授权同 uid:跳过断点作废①②(multipart 会话在自家 MinIO,同账号续传
      无损坏风险),仅清 dlink 缓存③;不同 uid 走①取消活动中任务 + ②作废断点
    """
    _ensure_enabled()
    code = payload.code.strip()
    if not code:
        raise HTTPException(400, "授权码不能为空")
    client = _get_baidu_client(request)
    crypto = _get_token_crypto(request)
    if not client.credentials_ready:
        raise HTTPException(503, "百度应用凭证未配置(BAIDU_APP_KEY/BAIDU_APP_SECRET),无法绑定")

    # 应用层限流(Redis 计数;防接口滥用 —— 正式态放开百度侧频控后的本地防线)
    redis = request.app.state.redis
    rate_key = _BIND_RATE_KEY.format(user_id=user.id)
    pipe = redis.pipeline()
    pipe.incr(rate_key)
    pipe.expire(rate_key, _BIND_RATE_WINDOW_S)
    count, _ = await pipe.execute()
    if int(count) > _BIND_RATE_MAX:
        raise HTTPException(429, f"操作过于频繁,请稍后再试(每小时至多 {_BIND_RATE_MAX} 次)")

    # ①code 换 token(10 分钟内、单次;只存 token 不存 code)
    try:
        tokens = await client.exchange_code(code)
    except BaiduApiError as e:
        log.info("baidu bind exchange failed user=%s category=%s", user.id, e.category)
        raise HTTPException(
            400, "授权码无效或已过期,请重新获取授权码后再试(授权码 10 分钟内单次有效)",
        ) from e

    # ②uinfo 身份:失败/缺 uid → 整体失败(§4 NOT NULL 防线;此时什么都不落库)
    try:
        info = await client.uinfo(tokens.access_token)
    except BaiduApiError as e:
        log.warning("baidu bind uinfo failed user=%s category=%s", user.id, e.category)
        raise HTTPException(
            502, "获取百度账号信息失败,请稍后重试;本次绑定未生效",
        ) from e

    now = datetime.now(UTC)
    access_enc = crypto.encrypt(tokens.access_token)
    refresh_enc = crypto.encrypt(tokens.refresh_token)
    expires_at = now + timedelta(seconds=tokens.expires_in)

    existing = await _get_binding(db, user.id)
    same_uid = existing is not None and existing.baidu_uid == info.uid
    try:
        if existing is None:
            binding = BaiduBinding(user_id=user.id)
            db.add(binding)
        else:
            binding = existing
        await _apply_binding_fields(
            binding,
            access_token_enc=access_enc,
            refresh_token_enc=refresh_enc,
            baidu_uid=info.uid,
            nickname=info.nickname,
            expires_at=expires_at,
            now=now,
        )
        # 覆盖前处置③(两分支都清);不同 uid 的①②见下
        await _clear_dlink_cache(db, user.id)
        await db.commit()
    except IntegrityError as e:
        # 并发双请求撞 unique(user_id) → 回滚改走覆盖更新路径(等价重新授权语义;
        # folders.py:115-119 同款范式)
        await db.rollback()
        winner = await _get_binding(db, user.id)
        if winner is None:
            raise HTTPException(409, "绑定并发冲突,请重试") from e
        await _apply_binding_fields(
            winner,
            access_token_enc=access_enc,
            refresh_token_enc=refresh_enc,
            baidu_uid=info.uid,
            nickname=info.nickname,
            expires_at=expires_at,
            now=now,
        )
        await _clear_dlink_cache(db, user.id)
        await db.commit()

    if not same_uid:
        # §5.2 覆盖前处置①②:换绑不同账号 —— 取消活动中任务 + 作废全部断点
        # (防换绑后从旧字节偏移续传新账号内容,产出静默损坏文件)。
        # 并发双绑定竞态下以 DB 实际行为准(上面的 IntegrityError 路径里本地
        # binding 变量可能是未持久化的冲突实例,其 id 不一定等于落库行)。
        winner = await _get_binding(db, user.id)
        if winner is not None:
            finalized = await _cancel_active_tasks_of_binding(
                db, binding_id=winner.id, now=now,
            )
            presign = _get_presign(request)
            stats = await _invalidate_breakpoints(db, presign, user_id=user.id)
            log.info("baidu rebind invalidate user=%s finalized_tasks=%s sessions=%s",
                     user.id, len(finalized), stats)

    await audit.write(
        event_type="baidu_bind",
        actor_user_id=user.id,
        details={"baidu_uid": info.uid, "same_account": same_uid, "rebind": existing is not None},
        request_ip=ctx.get("request_ip"),
        user_agent=ctx.get("user_agent"),
    )
    log.info("baidu bind ok user=%s uid=%s same_account=%s", user.id, info.uid, same_uid)
    return BaiduBindOut(
        bound=True, status="active", expires_at=expires_at,
        baidu_uid=info.uid, nickname=info.nickname,
    )


@router.delete("/backup/binding", status_code=204)
async def unbind(
    request: Request,
    user: CurrentUser = Depends(get_current_user),  # noqa: B008  # FastAPI DI,repo 全量同款
    db: AsyncSession = Depends(get_db),  # noqa: B008  # FastAPI DI,repo 全量同款
    audit: AuditService = Depends(get_audit),  # noqa: B008  # FastAPI DI,repo 全量同款
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008  # FastAPI DI,repo 全量同款
) -> None:
    """软解绑(§5.2):①取消名下活动中任务(binding_replaced)②作废残留断点,
    再置 status=unbound + 清空两列 token 密文(行保留,历史任务 FK 仍引用);
    旧账号 dlink 缓存一并失效。"""
    _ensure_enabled()
    binding = await _get_binding(db, user.id)
    if binding is None or binding.status == "unbound":
        raise HTTPException(404, "尚未绑定百度网盘账号")

    now = datetime.now(UTC)
    finalized = await _cancel_active_tasks_of_binding(db, binding_id=binding.id, now=now)
    presign = _get_presign(request)
    stats = await _invalidate_breakpoints(db, presign, user_id=user.id)
    log.info("baidu unbind invalidate user=%s finalized_tasks=%s sessions=%s",
             user.id, len(finalized), stats)

    binding.status = "unbound"
    binding.access_token_enc = ""
    binding.refresh_token_enc = ""
    await _clear_dlink_cache(db, user.id)
    await db.commit()

    await audit.write(
        event_type="baidu_unbind",
        actor_user_id=user.id,
        details={"baidu_uid": binding.baidu_uid, "finalized_tasks": len(finalized),
                 "sessions": stats},
        request_ip=ctx.get("request_ip"),
        user_agent=ctx.get("user_agent"),
    )
    log.info("baidu unbind ok user=%s uid=%s", user.id, binding.baidu_uid)


# ─── 网盘目录浏览(懒加载)─────────────────────────────────────────────────────


@router.get("/backup/netdisk/folders", response_model=BaiduNetdiskFoldersOut)
async def list_netdisk_folders(
    request: Request,
    path: str = Query("/", description="网盘目录绝对路径(以 / 开头)"),
    user: CurrentUser = Depends(get_current_user),  # noqa: B008  # FastAPI DI,repo 全量同款
    db: AsyncSession = Depends(get_db),  # noqa: B008  # FastAPI DI,repo 全量同款
) -> BaiduNetdiskFoldersOut:
    """网盘目录树懒加载(§5.2):folder=1 仅目录;后端按 start/limit 循环聚合
    同目录全部子目录(>1000 子目录静默截断不可接受,聚合页数上限内未取尽置
    truncated=True 提示「目录过大,分批浏览」);60s (user_id,path) Redis 缓存;
    绑定非 active → 409 binding_inactive(与创建/复活接口同码同义)。"""
    _ensure_enabled()
    dir_path = (path or "/").strip() or "/"
    if not dir_path.startswith("/"):
        raise HTTPException(400, "path 必须是以 / 开头的网盘绝对路径")
    if len(dir_path) > 1024:
        raise HTTPException(400, "path 过长")

    binding = await _get_binding(db, user.id)
    if binding is None or binding.status != "active":
        raise _binding_inactive("请先绑定百度网盘账号")

    # 60s (user_id,path) 缓存(方案 §9 频控缓解;测试态网盘接口 10 次/小时)
    redis = request.app.state.redis
    cache_key = _FOLDERS_CACHE_KEY.format(
        user_id=user.id, path_hash=hashlib.sha256(dir_path.encode("utf-8")).hexdigest()[:32],
    )
    cached = await redis.get(cache_key)
    if cached:
        return BaiduNetdiskFoldersOut.model_validate_json(cached)

    client = _get_baidu_client(request)
    crypto = _get_token_crypto(request)
    access_token = await ensure_fresh_access_token(db, binding, crypto=crypto, client=client)
    try:
        result = await client.list_dir(access_token, dir_path, folders_only=True)
    except BaiduApiError as e:
        raise _baidu_error_to_http(e) from e

    folders = [
        BaiduNetdiskFolderOut(path=p, name=p.rstrip("/").rpartition("/")[2] or p)
        for item in result.items
        if (p := str(item.get("path") or ""))
    ]
    out = BaiduNetdiskFoldersOut(list=folders, truncated=result.truncated)
    await redis.set(cache_key, out.model_dump_json(), ex=_FOLDERS_CACHE_TTL_S)
    return out


# ─── 任务列表/详情 enrich(§3.1 前端契约对齐 WP2 字段)─────────────────────────


async def _build_task_outs(
    db: AsyncSession, tasks: list[BaiduBackupTask],
) -> list[BaiduTaskOut]:
    now = datetime.now(UTC)
    throttle_s = get_settings().baidu_sweep_throttle_s
    ids = [t.id for t in tasks]
    project_names: dict[uuid.UUID, str] = {}
    if tasks:
        pids = {t.project_id for t in tasks}
        rows = await db.execute(
            select(Project.id, Project.name).where(Project.id.in_(pids))
        )
        project_names = {row.id: row.name for row in rows}
    folder_names: dict[uuid.UUID, str] = {}
    fids = {t.target_folder_id for t in tasks if t.target_folder_id}
    if fids:
        rows = await db.execute(select(Folder.id, Folder.name).where(Folder.id.in_(fids)))
        folder_names = {row.id: row.name for row in rows}
    importing_ids: set[uuid.UUID] = set()
    retryable: dict[uuid.UUID, int] = {}
    if ids:
        rows = await db.execute(
            select(BaiduBackupTaskFile.task_id)
            .where(
                BaiduBackupTaskFile.task_id.in_(ids),
                BaiduBackupTaskFile.status == "importing",
            )
            .distinct()
        )
        importing_ids = {row.task_id for row in rows}
        rows = await db.execute(
            select(
                BaiduBackupTaskFile.task_id,
                func.count().label("cnt"),
            )
            .where(
                BaiduBackupTaskFile.task_id.in_(ids),
                BaiduBackupTaskFile.status == STATUS_FAILED,
                BaiduBackupTaskFile.non_retryable.is_(False),
            )
            .group_by(BaiduBackupTaskFile.task_id)
        )
        retryable = {row.task_id: int(row.cnt) for row in rows}
    outs: list[BaiduTaskOut] = []
    for t in tasks:
        outs.append(BaiduTaskOut(
            id=t.id,
            source_dir=t.source_dir,
            project_id=t.project_id,
            project_name=project_names.get(t.project_id),
            target_folder_id=t.target_folder_id,
            target_folder_name=folder_names.get(t.target_folder_id) if t.target_folder_id else None,
            target_auto_created=t.target_auto_created,
            status=t.status,
            queued=derive_queued(
                status=t.status, speed_bps=t.speed_bps,
                has_importing_rows=t.id in importing_ids,
                runner_id=t.runner_id, lease_until=t.lease_until,
                dispatched_at=t.dispatched_at, now=now, throttle_s=throttle_s,
            ),
            fail_reason=t.fail_reason,
            cancel_requested=t.cancel_requested,
            total_files=t.total_files,
            done_files=t.done_files,
            failed_files=t.failed_files,
            skipped_files=t.skipped_files,
            cancelled_files=t.cancelled_files,
            total_bytes=t.total_bytes,
            done_bytes=t.done_bytes,
            speed_bps=t.speed_bps,
            eta_seconds=derive_eta_seconds(
                total_bytes=t.total_bytes, done_bytes=t.done_bytes, speed_bps=t.speed_bps,
            ),
            retryable_failed_files=retryable.get(t.id, 0 if t.status == STATUS_FAILED else None),
            created_at=t.created_at,
            updated_at=t.updated_at,
        ))
    return outs


# ─── tasks 九路由(§5.2)──────────────────────────────────────────────────────


@router.post("/backup/tasks", response_model=BaiduTaskOut, status_code=201)
async def create_task(
    payload: BaiduTaskCreateIn,
    request: Request,
    user: CurrentUser = Depends(get_current_user),  # noqa: B008  # FastAPI DI,repo 全量同款
    db: AsyncSession = Depends(get_db),  # noqa: B008  # FastAPI DI,repo 全量同款
    audit: AuditService = Depends(get_audit),  # noqa: B008  # FastAPI DI,repo 全量同款
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008  # FastAPI DI,repo 全量同款
) -> BaiduTaskOut:
    """创建备份任务(§5.2):校验链(source_dir 护栏/绑定/归属/敏感祖先链/can_upload
    /承接夹解析/活动互斥)+ 派发步入队;撞 uq_baidu_task_active 统一 409。"""
    _ensure_enabled()
    try:
        source_dir = validate_source_dir(payload.source_dir)
    except BaiduTaskError as e:
        raise _task_error_to_http(e) from e

    # 用户维度频控(防反复建删任务白耗枚举配额与派发,§5.2)
    redis = request.app.state.redis
    rate_key = _TASK_RATE_KEY.format(user_id=user.id)
    pipe = redis.pipeline()
    pipe.incr(rate_key)
    pipe.expire(rate_key, _TASK_RATE_WINDOW_S)
    count, _ = await pipe.execute()
    if int(count) > _TASK_RATE_MAX:
        raise HTTPException(429, f"创建过于频繁,请稍后再试(每小时至多 {_TASK_RATE_MAX} 次)")

    binding = await _get_binding(db, user.id)
    try:
        await assert_binding_active(binding)
    except BaiduTaskError as e:
        raise _task_error_to_http(e) from e
    assert binding is not None

    project = await db.get(Project, payload.project_id)
    if project is None:
        raise HTTPException(404, "project not found")
    if await has_active_task(db, binding_id=binding.id):
        raise HTTPException(409, "同一绑定已有进行中的备份任务,请等待其结束")

    permissions: PermissionsService = request.app.state.permissions
    org = await get_default_organization(db)
    tenant_key = org[1] if org else None

    async def _is_org_admin() -> bool:
        if tenant_key is None:
            return False
        try:
            return await permissions.is_org_admin(
                user_id=str(user.id), organization_tenant_key=tenant_key,
            )
        except Exception:
            return False

    async def _deny(action: str, reason: str, project_id: uuid.UUID) -> HTTPException:
        await audit.write(
            event_type="access_denied",
            actor_user_id=user.id,
            target_project_id=project_id,
            details={"action": action, "reason": reason},
            request_ip=ctx.get("request_ip"),
            user_agent=ctx.get("user_agent"),
        )
        return HTTPException(403, "no permission(目标目录不可用或权限不足)")

    # ── 目标解析(§5.2):显式目录 / 项目根自动承接夹 ─────────────────────────
    if payload.target_folder_id is not None:
        folder = await db.get(Folder, payload.target_folder_id)
        if folder is None or folder.project_id != payload.project_id:
            raise HTTPException(400, "target_folder invalid for this project")
        try:
            await assert_target_chain_not_sensitive(db, folder)
        except BaiduTaskError as e:
            raise await _deny("baidu_task_create", f"target sensitive chain folder={folder.id}",
                              payload.project_id) from e
        allowed = await _is_org_admin() or await permissions.check(
            user_subject=user.subject, relation="can_upload",
            object_type="folder", object_id=str(folder.id),
        )
        if not allowed:
            raise await _deny("baidu_task_create",
                              f"openfga can_upload false folder={folder.id}",
                              payload.project_id)
        target_folder_id: uuid.UUID | None = folder.id
        target_auto_created = False
    else:
        allowed = await _is_org_admin() or await permissions.check(
            user_subject=user.subject, relation="can_upload",
            object_type="project", object_id=str(project.id),
        )
        if not allowed:
            raise await _deny("baidu_task_create",
                              f"openfga can_upload false project={project.id}",
                              payload.project_id)
        name = source_dir_leaf_name(source_dir)
        if len(name) > 255:
            raise HTTPException(400, "网盘目录名过长,无法作为目标文件夹名")
        existing = await find_root_level_folder(db, project_id=project.id, name=name)
        if existing is not None:
            # 同名复用前校验非 sensitive;文案不含「敏感」字样,防无 can_view 者借
            # 报错探测敏感夹存在性(§5.2)
            if existing.is_sensitive:
                raise HTTPException(400, "目标文件夹名不可用,请改名或另选目标")
            target_folder_id = existing.id
        else:
            try:
                node = await ensure_root_folder_at_project(
                    db, permissions, project_id=project.id, name=name,
                )
            except FolderChainError as e:
                # 并发窗口同名夹被判 sensitive(竞态创建)→ 与上方复用分支同文案
                if e.code == "target_sensitive_chain":
                    raise HTTPException(400, "目标文件夹名不可用,请改名或另选目标") from e
                raise
            target_folder_id = node.folder_id
        target_auto_created = True

    # ── 插入任务(bound_baidu_uid 创建时快照,换绑甄别锚点)────────────────────
    task = BaiduBackupTask(
        user_id=user.id,
        binding_id=binding.id,
        bound_baidu_uid=binding.baidu_uid,
        source_dir=source_dir,
        project_id=project.id,
        target_folder_id=target_folder_id,
        target_auto_created=target_auto_created,
        status=STATUS_ENUMERATING,
    )
    db.add(task)
    try:
        await db.commit()
    except IntegrityError as e:
        # partial unique index uq_baidu_task_active 兜底(并发创建/复活统一 409)
        await db.rollback()
        raise HTTPException(409, "同一绑定已有进行中的备份任务,请等待其结束") from e

    outcome = await dispatch_and_enqueue(
        db, _get_arq_pool(request), task_id=task.id, mode="create", now=datetime.now(UTC),
    )
    if outcome.seq is None:
        raise HTTPException(409, "任务派发失败(状态已变化),请重试")

    # INSERT 的 server_default 列(created_at/updated_at)与派发步 UPDATE 的落库值
    # 都不在会话内对象上(UPDATE 已 synchronize_session=False,不再靠 evaluate 回写),
    # 构造响应前显式 refresh —— 否则 _build_task_outs 读 updated_at 触发同步 IO
    # → MissingGreenlet(探针实证的 P0 500)。
    await db.refresh(task)

    await audit.write(
        event_type="baidu_task_create",
        actor_user_id=user.id,
        target_project_id=project.id,
        details={
            "task_id": str(task.id), "source_dir": source_dir,
            "target_folder_id": str(target_folder_id) if target_folder_id else None,
            "target_auto_created": target_auto_created, "dispatch_seq": outcome.seq,
        },
        request_ip=ctx.get("request_ip"),
        user_agent=ctx.get("user_agent"),
    )
    log.info("baidu task created id=%s user=%s source=%s dispatch_seq=%s",
             task.id, user.id, source_dir, outcome.seq)
    outs = await _build_task_outs(db, [task])
    return outs[0]


@router.get("/backup/tasks", response_model=BaiduTasksPage)
async def list_tasks(
    limit: int = Query(20, ge=1, le=100),
    offset: int = Query(0, ge=0),
    user: CurrentUser = Depends(get_current_user),  # noqa: B008  # FastAPI DI,repo 全量同款
    db: AsyncSession = Depends(get_db),  # noqa: B008  # FastAPI DI,repo 全量同款
) -> BaiduTasksPage:
    """任务列表(仅本人;ORDER BY created_at DESC, id DESC 稳定排序防翻页
    重复/漏行 —— 先例 assets.py:288;含进度统计与 ETA,§5.2)。"""
    _ensure_enabled()
    where = BaiduBackupTask.user_id == user.id
    total = await db.scalar(select(func.count()).select_from(BaiduBackupTask).where(where))
    rows = await db.execute(
        select(BaiduBackupTask)
        .where(where)
        .order_by(BaiduBackupTask.created_at.desc(), BaiduBackupTask.id.desc())
        .limit(limit)
        .offset(offset)
    )
    items = await _build_task_outs(db, list(rows.scalars().all()))
    return BaiduTasksPage(items=items, total=total or 0)


@router.get("/backup/tasks/{task_id}", response_model=BaiduTaskOut)
async def get_task(
    task_id: uuid.UUID,
    user: CurrentUser = Depends(get_current_user),  # noqa: B008  # FastAPI DI,repo 全量同款
    db: AsyncSession = Depends(get_db),  # noqa: B008  # FastAPI DI,repo 全量同款
) -> BaiduTaskOut:
    """任务详情(本人校验;字段与列表同口径)。"""
    _ensure_enabled()
    task = await _own_task(db, task_id, user.id)
    outs = await _build_task_outs(db, [task])
    return outs[0]


@router.get("/backup/tasks/{task_id}/files", response_model=BaiduTaskFilesPage)
async def list_task_files(
    task_id: uuid.UUID,
    status: str | None = Query(None, description="按行状态筛选"),
    limit: int = Query(100, ge=1, le=500),
    offset: int = Query(0, ge=0),
    user: CurrentUser = Depends(get_current_user),  # noqa: B008  # FastAPI DI,repo 全量同款
    db: AsyncSession = Depends(get_db),  # noqa: B008  # FastAPI DI,repo 全量同款
) -> BaiduTaskFilesPage:
    """manifest 分页(仅本人;预计导入路径在此拼装,§5.2:行级 folder 为 NULL 时
    回退按 tasks.target_folder_id + rel_path 拼;两者皆 NULL → target_path=None,
    前端显示源路径并标注「(目标已删除)」)。"""
    _ensure_enabled()
    task = await _own_task(db, task_id, user.id)
    conditions = [BaiduBackupTaskFile.task_id == task.id]
    if status is not None:
        if status not in FILE_STATUSES:
            raise HTTPException(400, f"status 取值须为 {FILE_STATUSES}")
        conditions.append(BaiduBackupTaskFile.status == status)
    total = await db.scalar(
        select(func.count()).select_from(BaiduBackupTaskFile).where(*conditions)
    )
    rows = await db.execute(
        select(BaiduBackupTaskFile)
        .where(*conditions)
        .order_by(BaiduBackupTaskFile.rel_path, BaiduBackupTaskFile.id)
        .limit(limit)
        .offset(offset)
    )
    files = list(rows.scalars().all())
    # 两级回退的 prefix 一次取全(行级 folder 集合 + 任务级 target folder)
    folder_ids = {f.target_folder_id for f in files if f.target_folder_id}
    if task.target_folder_id:
        folder_ids.add(task.target_folder_id)
    prefixes: dict[uuid.UUID, str] = {}
    if folder_ids:
        prows = await db.execute(
            select(Folder.id, Folder.minio_prefix).where(Folder.id.in_(folder_ids))
        )
        prefixes = {row.id: row.minio_prefix for row in prows}
    task_base = prefixes.get(task.target_folder_id) if task.target_folder_id else None

    def _target_path(f: BaiduBackupTaskFile) -> str | None:
        """预计导入路径两级回退(§5.2):行级 folder prefix → 任务级 target prefix
        → None(前端显示源路径并标注「(目标已删除)」)。"""
        prefix = prefixes.get(f.target_folder_id) if f.target_folder_id else None
        if prefix is None:
            prefix = task_base
        if prefix is None:
            return None
        return f"{prefix.rstrip('/')}/{f.rel_path}"

    items = [
        BaiduTaskFileOut(
            id=f.id,
            fs_id=f.fs_id,
            source_path=f.source_path,
            source_size=f.source_size,
            rel_path=f.rel_path,
            target_path=_target_path(f),
            status=f.status,
            overwrite=f.overwrite,
            bytes_done=f.bytes_done,
            attempts=f.attempts,
            last_error=f.last_error,
            non_retryable=f.non_retryable,
            asset_id=f.asset_id,
            created_at=f.created_at,
            updated_at=f.updated_at,
        )
        for f in files
    ]
    return BaiduTaskFilesPage(items=items, total=total or 0)


@router.post("/backup/tasks/{task_id}/cancel", response_model=BaiduCancelOut, status_code=202)
async def cancel_task(
    task_id: uuid.UUID,
    request: Request,
    user: CurrentUser = Depends(get_current_user),  # noqa: B008  # FastAPI DI,repo 全量同款
    db: AsyncSession = Depends(get_db),  # noqa: B008  # FastAPI DI,repo 全量同款
    audit: AuditService = Depends(get_audit),  # noqa: B008  # FastAPI DI,repo 全量同款
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008  # FastAPI DI,repo 全量同款
) -> BaiduCancelOut:
    """取消(§5.2):前置仅活动中任务可取消(终态 409,防回落路径留脏标志);
    无租约/租约过期(含 NULL)→ API 侧直接终态化(归位表 + SET runner 清空 +
    终态 CAS + 聚合重算 + 内联 abort 残留会话);否则回落仅置 cancel_requested
    交 worker 消费;202 响应 {finalized} 区分两条路径。"""
    _ensure_enabled()
    task = await _own_task(db, task_id, user.id)
    if task.status not in ACTIVE_STATUSES:
        raise HTTPException(409, "任务已结束,无法取消")
    now = datetime.now(UTC)
    finalized = False
    if lease_free(task.runner_id, task.lease_until, now):
        refs = await load_session_refs(db, task_id=task.id)
        await finalize_rows_cancelled(db, task_id=task.id)
        if await finalize_task_terminal(db, task_id=task.id, status=STATUS_CANCELLED):
            await recompute_aggregates(db, task_id=task.id)
            await db.commit()
            # 终态化后按统一口径清理残留 multipart,不等 sweeper(§5.2)
            stats = await abort_leftover_sessions(db, _get_presign(request), refs)
            await db.commit()
            finalized = True
            log.info("baidu task cancel finalized task=%s sessions=%s", task.id, stats)
        else:
            await db.rollback()  # 并发终态化抢先 → 回落 flag 路径
    if not finalized:
        res = await db.execute(
            update(BaiduBackupTask)
            .where(
                BaiduBackupTask.id == task.id,
                BaiduBackupTask.status.in_(ACTIVE_STATUSES),
            )
            .values(cancel_requested=True, cancel_reason=CANCEL_USER)
            .execution_options(synchronize_session=False)  # onupdate expire 同防(服务层 _SYNC_OFF 同因)
        )
        if statement_rowcount(res) == 0:
            raise HTTPException(409, "任务状态已变化,请刷新后重试")
        await db.commit()

    await audit.write(
        event_type="baidu_task_cancel",
        actor_user_id=user.id,
        details={"task_id": str(task.id), "finalized": finalized},
        request_ip=ctx.get("request_ip"),
        user_agent=ctx.get("user_agent"),
    )
    log.info("baidu task cancel task=%s user=%s finalized=%s", task.id, user.id, finalized)
    return BaiduCancelOut(finalized=finalized)


@router.delete("/backup/tasks/{task_id}", status_code=204)
async def delete_task(
    task_id: uuid.UUID,
    request: Request,
    user: CurrentUser = Depends(get_current_user),  # noqa: B008  # FastAPI DI,repo 全量同款
    db: AsyncSession = Depends(get_db),  # noqa: B008  # FastAPI DI,repo 全量同款
    audit: AuditService = Depends(get_audit),  # noqa: B008  # FastAPI DI,repo 全量同款
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008  # FastAPI DI,repo 全量同款
) -> None:
    """删除记录(§5.2):仅终态任务;DELETE 自带终态 CAS 谓词(rowcount=0 → 409,
    防与 overwrite 回摆的并发交错删除活动任务);残留 multipart 清理统一口径
    abort_leftover_sessions(≤20 全量内联分批 abort;>20 仅 importing 行,
    其余随行级联删除后依赖 bucket lifecycle 30d)。"""
    _ensure_enabled()
    task = await _own_task(db, task_id, user.id)
    if task.status not in TERMINAL_STATUSES:
        raise HTTPException(409, "仅已结束的任务可删除")
    refs = await load_session_refs(db, task_id=task.id)
    stats = await abort_leftover_sessions(db, _get_presign(request), refs)
    res = await db.execute(
        delete(BaiduBackupTask).where(
            BaiduBackupTask.id == task.id,
            BaiduBackupTask.status.in_(TERMINAL_STATUSES),
        )
    )
    if statement_rowcount(res) == 0:
        raise HTTPException(409, "任务状态已变化,请刷新后重试")
    await db.commit()

    await audit.write(
        event_type="baidu_task_delete",
        actor_user_id=user.id,
        details={
            "task_id": str(task.id), "source_dir": task.source_dir,
            "status_at_delete": task.status, "sessions": stats,
        },
        request_ip=ctx.get("request_ip"),
        user_agent=ctx.get("user_agent"),
    )
    log.info("baidu task deleted task=%s user=%s sessions=%s", task.id, user.id, stats)


async def _revive_and_dispatch(
    db: AsyncSession,
    request: Request,
    *,
    task: BaiduBackupTask,
    allowed_from: tuple[str, ...],
) -> str:
    """复活型统一前置的落库侧(§5.2):在途行复位 + 派发步(reset_round);
    撞 uq_baidu_task_active / CAS 0 行统一 409。返回复活后的目标状态
    (enum_done=false → enumerating 重枚举 / true → running,§4)。"""
    await reset_importing_rows(db, task_id=task.id)  # 接管/复活分支复位在途行
    try:
        outcome = await dispatch_and_enqueue(
            db, _get_arq_pool(request), task_id=task.id, mode="revive",
            allowed_from=allowed_from, now=datetime.now(UTC),
        )
    except IntegrityError as e:
        await db.rollback()
        raise HTTPException(409, "同一绑定已有进行中的任务,请等待其结束") from e
    if outcome.seq is None:
        raise HTTPException(409, "任务状态已变化,请刷新后重试")
    return STATUS_RUNNING if task.enum_done else STATUS_ENUMERATING


@router.post("/backup/tasks/{task_id}/retry-failed", response_model=BaiduReviveOut, status_code=202)
async def retry_failed(
    task_id: uuid.UUID,
    request: Request,
    user: CurrentUser = Depends(get_current_user),  # noqa: B008  # FastAPI DI,repo 全量同款
    db: AsyncSession = Depends(get_db),  # noqa: B008  # FastAPI DI,repo 全量同款
    audit: AuditService = Depends(get_audit),  # noqa: B008  # FastAPI DI,repo 全量同款
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008  # FastAPI DI,repo 全量同款
) -> BaiduReviveOut:
    """全部重试失败(§5.2 复活型):前置 task.status='failed'(cancelled 是用户
    终态不得复活);enum_done=false 的任务走重枚举复活不受 0 行限制,否则
    0 行可复位 → 409「无可重试文件」。"""
    _ensure_enabled()
    task = await _own_task(db, task_id, user.id)
    if task.status != STATUS_FAILED:
        raise HTTPException(409, "仅失败任务可全部重试")
    binding = await _get_binding(db, user.id)
    try:
        await guard_revival(db, task=task, binding=binding)
    except BaiduTaskError as e:
        raise _task_error_to_http(e) from e

    reset = await reset_failed_rows(db, task_id=task.id)
    if task.enum_done and reset == 0:
        raise HTTPException(409, "无可重试文件")
    target_status = await _revive_and_dispatch(
        db, request, task=task, allowed_from=(STATUS_FAILED,),
    )

    await audit.write(
        event_type="baidu_task_retry",
        actor_user_id=user.id,
        details={"task_id": str(task.id), "reset_rows": reset,
                 "retry_count": task.retry_count + 1},
        request_ip=ctx.get("request_ip"),
        user_agent=ctx.get("user_agent"),
    )
    log.info("baidu task retry-failed task=%s reset=%s", task.id, reset)
    return BaiduReviveOut(finalized=True, status=target_status)


@router.post(
    "/backup/tasks/{task_id}/files/{file_id}/retry",
    response_model=BaiduReviveOut, status_code=202,
)
async def retry_file(
    task_id: uuid.UUID,
    file_id: uuid.UUID,
    request: Request,
    user: CurrentUser = Depends(get_current_user),  # noqa: B008  # FastAPI DI,repo 全量同款
    db: AsyncSession = Depends(get_db),  # noqa: B008  # FastAPI DI,repo 全量同款
    audit: AuditService = Depends(get_audit),  # noqa: B008  # FastAPI DI,repo 全量同款
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008  # FastAPI DI,repo 全量同款
) -> BaiduReviveOut:
    """单文件重试(§5.2 复活型):failed → pending;non_retryable 行 409
    (结构性失败重试不可能自愈);单文件 retry 不得触碰其他 failed 行。"""
    _ensure_enabled()
    task = await _own_task(db, task_id, user.id)
    if task.status != STATUS_FAILED:
        raise HTTPException(409, "仅失败任务可重试文件")
    binding = await _get_binding(db, user.id)
    try:
        await guard_revival(db, task=task, binding=binding)
    except BaiduTaskError as e:
        raise _task_error_to_http(e) from e

    reset = await reset_one_failed_row(db, task_id=task.id, file_id=file_id)
    if reset == 0:
        raise HTTPException(409, "该文件不可重试(仅失败且非结构性失败的文件可重试)")
    target_status = await _revive_and_dispatch(
        db, request, task=task, allowed_from=(STATUS_FAILED,),
    )

    await audit.write(
        event_type="baidu_file_retry",
        actor_user_id=user.id,
        details={"task_id": str(task.id), "file_id": str(file_id)},
        request_ip=ctx.get("request_ip"),
        user_agent=ctx.get("user_agent"),
    )
    log.info("baidu file retry task=%s file=%s", task.id, file_id)
    return BaiduReviveOut(finalized=True, status=target_status)


@router.post(
    "/backup/tasks/{task_id}/files/{file_id}/overwrite",
    response_model=BaiduReviveOut, status_code=202,
)
async def overwrite_file(
    task_id: uuid.UUID,
    file_id: uuid.UUID,
    request: Request,
    user: CurrentUser = Depends(get_current_user),  # noqa: B008  # FastAPI DI,repo 全量同款
    db: AsyncSession = Depends(get_db),  # noqa: B008  # FastAPI DI,repo 全量同款
    audit: AuditService = Depends(get_audit),  # noqa: B008  # FastAPI DI,repo 全量同款
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008  # FastAPI DI,repo 全量同款
) -> BaiduReviveOut:
    """覆盖导入(§5.2 复活型):failed/completed 任务的 skipped_exists 行 →
    pending 且置 overwrite=true(清除-再导入;worker 导入时复查 can_admin);
    completed 回摆语义由派发步与聚合重算承接。"""
    _ensure_enabled()
    task = await _own_task(db, task_id, user.id)
    if task.status not in (STATUS_FAILED, "completed"):
        raise HTTPException(409, "仅失败或已完成任务支持覆盖导入")
    binding = await _get_binding(db, user.id)
    try:
        await guard_revival(db, task=task, binding=binding)
    except BaiduTaskError as e:
        raise _task_error_to_http(e) from e

    reset = await reset_skipped_row_for_overwrite(db, task_id=task.id, file_id=file_id)
    if reset == 0:
        raise HTTPException(409, "仅跳过(已存在)的文件可覆盖导入")
    target_status = await _revive_and_dispatch(
        db, request, task=task, allowed_from=(STATUS_FAILED, "completed"),
    )

    await audit.write(
        event_type="baidu_file_overwrite",
        actor_user_id=user.id,
        details={"task_id": str(task.id), "file_id": str(file_id)},
        request_ip=ctx.get("request_ip"),
        user_agent=ctx.get("user_agent"),
    )
    log.info("baidu file overwrite task=%s file=%s", task.id, file_id)
    return BaiduReviveOut(finalized=True, status=target_status)
