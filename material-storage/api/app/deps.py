"""FastAPI Dependency Injection — CurrentUser(SQL UUID 作 FK + OpenFGA subject)。

认证优先级(MCP 素材服务 D11 / 接口 C):cookie session → ``Authorization:
Bearer mspat_...``(PAT)→ dev ``X-User-Id``。PAT 链前五步顺序钉死,实现在
``app/services/mcp_auth.py::authenticate_pat``;第六步两级并发闸在
``app/services/mcp_gate.py`` —— 本模块只做**优先级判断**与 session/dev 通道。
"""
from __future__ import annotations

import logging
import uuid

from fastapi import Depends, Header, HTTPException, Request
from sqlalchemy import select

from app.db.session import get_sessionmaker
from app.db.tables import User
from app.services.audit import AuditService, bind_auth_context
from app.services.auth import CurrentUser as CurrentUser  # 显式重导出(定义已下沉 services/auth.py)
from app.services.auth import OIDCService, ensure_session_version
from app.services.local_auth import LocalAuthService
from app.services.mcp_auth import authenticate_pat, bearer_token
from app.services.permissions import PermissionsService
from app.services.presign import PresignService
from app.settings import Settings, get_settings

log = logging.getLogger(__name__)


def settings_dep() -> Settings:
    return get_settings()


def get_permissions(request: Request) -> PermissionsService:
    return request.app.state.permissions


def get_presign(request: Request) -> PresignService:
    return request.app.state.presign


def get_auth(request: Request) -> OIDCService:
    return request.app.state.auth


def get_local_auth(request: Request) -> LocalAuthService:
    return request.app.state.local_auth  # type: ignore[no-any-return]  # app.state 是 Any


async def get_audit(request: Request):
    """每请求新建 AuditService,绑当前 db session + request(D4 认证列延迟读 state)。"""
    from app.db.session import get_sessionmaker
    async with get_sessionmaker()() as session:
        yield AuditService(session, request)


# #149 review F15:must_change_password=true 的会话,后端只放行以下端点
# (改密页依赖 /me 报告状态、改密端点自身要能过守卫、logout 无鉴权但一并列出);
# 其余端点一律 403。口径与 /me 一致:必须已设本地密码才算强制改密(存量飞书用户不误伤)。
# ★ 仅 session 分支适用;PAT 分支无豁免清单(D13:强制改密态一律 403)。
_FORCED_CHANGE_OK_ROUTES = frozenset({"me", "change_password", "logout"})

# ─── current user(cookie session → Bearer PAT → dev header)─────────────────
async def load_active_user(
    uid: uuid.UUID, *, expected_session_version: int | None = None,
) -> tuple[CurrentUser, bool]:
    """按 users.id 查库,一次拿齐 F5(is_active)+ F15(强制改密)判定所需的列。

    F5:禁用必须立即下线,不能等 JWT 7 天过期 —— 所有需要登录的端点一律 401。
    返回 `(CurrentUser, forced_change)`(口径与 /me 一致)。**每次认证一次 PK 查询**:
    别拆成两次开 session,缩略图这类高频端点会被每请求两次 round-trip 放大。
    session / dev 通道 / PAT 链(``app/services/mcp_auth.py``)共用本实现。

    expected_session_version(邮箱账号方案 §5.5,仅 session 通道传):JWT payload
    的 ``ver`` 与库内 ``session_version`` 不一致 → 401「会话已失效」(改密/重置/
    禁用后旧 JWT 立即失效)。None = 不校验(PAT 走吊销、dev 通道无 JWT 版本)。
    """
    async with get_sessionmaker()() as db:
        stmt = select(
            User.id, User.name, User.is_active,
            User.must_change_password, User.password_hash,
            User.session_version,
        ).where(User.id == uid)
        row = (await db.execute(stmt)).first()
        if row is None:
            raise HTTPException(401, "用户不存在或已删除")
        if not row.is_active:
            raise HTTPException(401, "账号已停用,请联系管理员")
        # §5.5:ver 比对+401 文案在 services/auth.py::ensure_session_version(纯搬家)
        ensure_session_version(row.session_version, expected_session_version)
        forced_change = bool(row.must_change_password and row.password_hash is not None)
        return CurrentUser(id=row.id, name=row.name), forced_change


_load_active_user = load_active_user  # 旧私有名保留(历史引用兼容);新代码用公开名


async def get_current_user(
    request: Request,
    x_user_id: str | None = Header(default=None, alias="X-User-Id"),
) -> CurrentUser:
    """认证优先级:
      1. cookie 'ms_session'(JWT)— F5 查库校验 is_active(禁用 401)、F15 强制改密拦截;
         **仅 decode 失败(ValueError/KeyError)回落 PAT**;decode 成功但用户态 401
         (禁用/删除)→ 直接抛,不回落(F5「禁用立即下线」,生产不例外);
         dev 下 HTTPException 的既有回落行为保留(回落 PAT → X-User-Id)
      2. ``Bearer mspat_...``(PAT)— 前五步顺序钉死,实现在
         ``app/services/mcp_auth.py::authenticate_pat``(本模块只判优先级)
      3. ``X-User-Id``(dev fallback)— 生产 env != 'dev' 拒绝;dev 不做强制改密拦截
    """
    settings = get_settings()
    auth: OIDCService = request.app.state.auth
    dev_mode = settings.env == "dev"

    token = request.cookies.get(settings.session_cookie_name)
    user: CurrentUser | None = None
    forced_change = False
    session_failed = False
    if token:
        try:
            payload = auth.decode_session(token)
            uid = uuid.UUID(payload["sub"])
            # F5:is_active 校验放最前 —— 禁用账号任何端点一律 401(含改密/me),
            # 优先于 F15 的 403(禁用状态下的改密诉求无意义)
            # §5.5:ver 缺失/为 null 的存量 JWT 一律按 0 比对(迁移后全站不掉线)
            user, forced_change = await load_active_user(
                uid, expected_session_version=int(payload.get("ver") or 0),
            )
        except (ValueError, KeyError) as e:
            # decode 失败 ≠ 会话有效:回落 PAT(生产不再直接 401 —— 否则
            # ms-mcp 转发请求被浏览器残留 cookie 挡死);dev 下再回落 X-User-Id,
            # 本地栈重建 / secret 轮换后浏览器残留的旧 JWT 不卡死整个 UI
            session_failed = True
            log.info("session decode failed (%s), falling back to PAT/X-User-Id", e)
        except HTTPException as e:
            if not dev_mode:
                # decode 成功但用户态 401(禁用/删除)→ 直接抛,不回落(F5)
                raise
            session_failed = True
            log.info("dev: session user load failed (%s), falling back to X-User-Id", e.detail)

    if user is not None:
        # 认证已成功 → 先落 state:即便随后被 F15 403,统计中间件仍按 session 归因
        request.state.auth_method = "session"
        bind_auth_context("session", None)
        # F15:强制改密拦截(must_change_password=true 只放行改密/me/logout)
        route_name = getattr(request.scope.get("route"), "name", "")
        if forced_change and route_name not in _FORCED_CHANGE_OK_ROUTES:
            raise HTTPException(403, "首次登录请先设置新密码:请先完成修改密码再继续操作")
        return user

    if bearer_token(request) is not None:
        # Bearer 存在(PAT 或非 mspat 前缀):交给 authenticate_pat 判定,不回落
        return await authenticate_pat(request)

    if dev_mode and x_user_id:
        try:
            uid = uuid.UUID(x_user_id)
        except ValueError as e:
            raise HTTPException(400, "X-User-Id 必须是 UUID 格式") from e
        # dev fallback 反查 db(与 JWT 路径同一校验;dev 不做强制改密拦截)
        user, _ = await load_active_user(uid)
        request.state.auth_method = "session"
        bind_auth_context("session", None)
        return user

    if session_failed:
        raise HTTPException(401, "会话已过期或无效,请重新登录")
    raise HTTPException(401, "not authenticated — call /api/v1/auth/login")


async def require_session_auth(
    request: Request,
    user: CurrentUser = Depends(get_current_user),  # noqa: B008  FastAPI DI,repo 全量同款
) -> CurrentUser:
    """session-only 守卫(D13b):PAT 调令牌管理/改密端点一律 403(防自我续期/自助改密)。

    只用于**逐路由**挂载(``/auth/tokens`` 三端点 + ``POST /auth/change-password``);
    **勿给整个 auth router 挂** —— ``/auth/local/login`` / ``/auth/callback`` 会被挡死。
    """
    if getattr(request.state, "auth_method", None) == "pat":
        request.state.mcp_reject_reason = "pat_forbidden"
        raise HTTPException(403, "令牌不允许管理令牌/改密")
    return user


async def get_request_context(request: Request) -> dict[str, str | None]:
    """请求级 context:IP / User-Agent;给 audit 用。"""
    return {
        "request_ip": request.client.host if request.client else None,
        "user_agent": request.headers.get("user-agent"),
    }


# ─── admin enforce(polish — org admin OR 任意 project admin)─────────────────
from fastapi import Depends as _Depends  # noqa: E402


async def require_admin(
    request: Request,
    user: CurrentUser = _Depends(get_current_user),
) -> CurrentUser:
    """admin 守门 — 给 /admin/* / GET /users 用。

    判定:org admin(organization#admin)或任意 project can_admin。
    """
    perms: PermissionsService = request.app.state.permissions
    from app.services.org import get_default_organization
    async with get_sessionmaker()() as db:
        org = await get_default_organization(db)
    if org:
        _, tenant_key = org
        if await perms.is_org_admin(
            user_id=str(user.id), organization_tenant_key=tenant_key,
        ):
            return user
    if await perms.has_any_project_admin(user_id=str(user.id)):
        return user
    raise HTTPException(403, "admin permission required")


async def require_system_admin(
    request: Request,
    user: CurrentUser = _Depends(get_current_user),
) -> CurrentUser:
    """系统 admin 守门 — 仅 organization#admin(后台指定,不可 UI promote)。

    用于:POST /projects(只有系统 admin 能建项目)。
    """
    perms: PermissionsService = request.app.state.permissions
    from app.services.org import get_default_organization
    async with get_sessionmaker()() as db:
        org = await get_default_organization(db)
    if not org:
        raise HTTPException(500, "no default organization configured")
    _, tenant_key = org
    if not await perms.is_org_admin(
        user_id=str(user.id), organization_tenant_key=tenant_key,
    ):
        raise HTTPException(403, "system admin permission required(只有系统管理员可执行此操作)")
    return user


async def get_is_system_admin(
    request: Request,
    user: CurrentUser = _Depends(get_current_user),
) -> bool:
    """返当前 user 是否系统 admin(不抛 403,bool)。

    给业务 endpoint 用作 *直通* 判定:`if is_system_admin or await perms.check(...)`。
    系统 admin 在 *所有* project / folder / asset 上都视为有 admin/upload/download/view 权限,
    避免在每个 router 里复制一份 default-org → is_org_admin → try/except 逻辑。
    """
    perms: PermissionsService = request.app.state.permissions
    from app.services.org import get_default_organization
    async with get_sessionmaker()() as db:
        org = await get_default_organization(db)
    if not org:
        return False
    _, tenant_key = org
    try:
        return await perms.is_org_admin(
            user_id=str(user.id), organization_tenant_key=tenant_key,
        )
    except Exception:
        return False


# ─── 组级「新建项目」权限(方案 §2.3/§2.4)────────────────────────────────────
async def require_project_creator(
    request: Request,
    user: CurrentUser = _Depends(get_current_user),
) -> CurrentUser:
    """建项目守门 — POST /projects 用(替换原 require_system_admin)。

    口径:is_org_admin 或 check(organization#project_creator)—— 系统 admin
    恒可建(不受组 flag 影响),组开关成员经 group#member 自动展开。
    default org 缺失行为对齐 require_system_admin(500);FGA 异常不上吞
    (与 require_system_admin 同:部署顺序保证 model 先 push,见方案 §4)。
    403 文案与 require_system_admin 区分(契约表)。
    """
    perms: PermissionsService = request.app.state.permissions
    from app.services.org import get_default_organization
    async with get_sessionmaker()() as db:
        org = await get_default_organization(db)
    if not org:
        raise HTTPException(500, "no default organization configured")
    _, tenant_key = org
    if await perms.is_org_admin(
        user_id=str(user.id), organization_tenant_key=tenant_key,
    ):
        return user
    if not await perms.is_org_project_creator(
        user_id=str(user.id), organization_tenant_key=tenant_key,
    ):
        raise HTTPException(
            403,
            "project creator permission required(仅系统管理员或被授权「可新建项目」的组成员可创建项目)",
        )
    return user


async def get_is_project_creator(
    request: Request,
    user: CurrentUser = _Depends(get_current_user),
) -> bool:
    """返当前 user 是否可新建项目(不抛 403,bool;/me 与前端闸门用)。

    与 require_project_creator 同口径(is_org_admin 或 project_creator check);
    default org 缺失 → False、FGA 抖动 try/except → False(对齐
    get_is_system_admin 惯例,FGA 抖动 / model 未 push 不致 /me 500)。
    """
    perms: PermissionsService = request.app.state.permissions
    from app.services.org import get_default_organization
    async with get_sessionmaker()() as db:
        org = await get_default_organization(db)
    if not org:
        return False
    _, tenant_key = org
    try:
        if await perms.is_org_admin(
            user_id=str(user.id), organization_tenant_key=tenant_key,
        ):
            return True
        return await perms.is_org_project_creator(
            user_id=str(user.id), organization_tenant_key=tenant_key,
        )
    except Exception:
        return False


async def require_admin_or_project_creator(
    request: Request,
    user: CurrentUser = _Depends(get_current_user),
) -> CurrentUser:
    """弱门 — 原 require_admin 语义 或 project_creator(方案 §2.3 弱门放宽)。

    GET /users、GET /groups 用:零项目组员(project_creator 置位)也要能拉
    SubjectPicker / UserPicker 候选。project_creator 口径已含 is_org_admin,
    故合取 = is_org_admin 或 project_creator check 或任意 project can_admin。
    """
    perms: PermissionsService = request.app.state.permissions
    from app.services.org import get_default_organization
    async with get_sessionmaker()() as db:
        org = await get_default_organization(db)
    if org:
        _, tenant_key = org
        if await perms.is_org_admin(
            user_id=str(user.id), organization_tenant_key=tenant_key,
        ):
            return user
        if await perms.is_org_project_creator(
            user_id=str(user.id), organization_tenant_key=tenant_key,
        ):
            return user
    if await perms.has_any_project_admin(user_id=str(user.id)):
        return user
    raise HTTPException(403, "admin permission required")


async def require_project_deleter(
    request: Request,
    user: CurrentUser = _Depends(get_current_user),
) -> CurrentUser:
    """删/恢复项目守门 — DELETE /projects/{id}、restore、GET /projects/deleted 用(F6)。

    口径:is_org_admin 或 check(organization#project_deleter)—— 系统 admin 恒可删
    (不受组 flag 影响),组开关成员经 group#member 展开;**不要求目标项目 admin**
    (D2)。default org 缺失对齐 require_system_admin(500);FGA 异常不上吞(同
    require_project_creator:部署顺序保证 model 先 push,见需求 §11);403 文案区分(§6)。
    """
    perms: PermissionsService = request.app.state.permissions
    from app.services.org import get_default_organization
    async with get_sessionmaker()() as db:
        org = await get_default_organization(db)
    if not org:
        raise HTTPException(500, "no default organization configured")
    _, tenant_key = org
    if await perms.is_org_admin(
        user_id=str(user.id), organization_tenant_key=tenant_key,
    ):
        return user
    if not await perms.is_org_project_deleter(
        user_id=str(user.id), organization_tenant_key=tenant_key,
    ):
        raise HTTPException(
            403,
            "project deleter permission required(仅系统管理员或被授权「可删除项目」的组成员可删除/恢复项目)",
        )
    return user


async def require_folder_template_manager(
    request: Request,
    user: CurrentUser = _Depends(get_current_user),  # noqa: B008  FastAPI DI,repo 全量同款
) -> CurrentUser:
    """目录模板写守门 — POST/PATCH/DELETE /admin/folder-templates 用(方案 §3.3)。

    口径:is_org_admin 或 check(organization#folder_template_manager)—— 系统 admin
    恒可写(is_org_admin 蕴含直通,不写第三条独立支:本仓 system admin 即 default org
    的 organization#admin),组开关成员经 group#member 展开。default org 缺失对齐
    require_system_admin(500);FGA 异常不上吞(方案 §3.2);403 文案区分(契约 §4.1)。
    """
    perms: PermissionsService = request.app.state.permissions
    from app.services.org import get_default_organization
    async with get_sessionmaker()() as db:
        org = await get_default_organization(db)
    if not org:
        raise HTTPException(500, "no default organization configured")
    _, tenant_key = org
    if await perms.is_org_admin(
        user_id=str(user.id), organization_tenant_key=tenant_key,
    ):
        return user
    if not await perms.is_org_folder_template_manager(
        user_id=str(user.id), organization_tenant_key=tenant_key,
    ):
        raise HTTPException(
            403,
            "folder template manager permission required"
            "(仅系统管理员或被授权「管理目录模板」的组成员可维护目录模板)",
        )
    return user


async def require_folder_templates_reader(
    request: Request,
    user: CurrentUser = _Depends(get_current_user),  # noqa: B008  FastAPI DI,repo 全量同款
) -> CurrentUser:
    """目录模板读弱门 — GET /admin/folder-templates 用(方案 §3.3)。

    组合弱门:is_org_admin 或 project_creator 或 folder_template_manager —— 零项目
    creator 建项目要拉模板预览、持 flag 组员管理页要能读(防「能写不能读」)。**不含
    has_any_project_admin**(整抄会把读门外溢到全部项目 admin;grant-templates 的读
    放宽不可平移)。不新增 get_* bool 门 helper;/me 的 is_folder_template_manager 内联。
    """
    perms: PermissionsService = request.app.state.permissions
    from app.services.org import get_default_organization
    async with get_sessionmaker()() as db:
        org = await get_default_organization(db)
    if org:
        _, tenant_key = org
        if await perms.is_org_admin(
            user_id=str(user.id), organization_tenant_key=tenant_key,
        ):
            return user
        if await perms.is_org_project_creator(
            user_id=str(user.id), organization_tenant_key=tenant_key,
        ):
            return user
        if await perms.is_org_folder_template_manager(
            user_id=str(user.id), organization_tenant_key=tenant_key,
        ):
            return user
    raise HTTPException(
        403,
        "folder templates reader permission required"
        "(仅系统管理员、可新建项目者或被授权「管理目录模板」的组成员可查看目录模板)",
    )


async def require_inline_artist_creator(
    request: Request,
    user: CurrentUser = _Depends(get_current_user),  # noqa: B008  FastAPI DI,repo 全量同款
) -> CurrentUser:
    """内嵌建号组合弱门 — GET /users/username-available 用(艺人账号内嵌方案 §3.3/§4.2)。

    组合弱门:is_org_admin 或(project_creator 且 artist_account_creator),与 POST
    /projects 内嵌建号的真实能力判定同构(§4.1 阶段 2):合取堵住「仅有 artist flag」
    者把该端点当账号存在性 oracle(其提交 POST /projects 会先吃 403)。**不另建零挂载
    的单 flag dep**(全方案无消费点;能力校验只能端点内加验)。default org 缺失对齐
    require_project_creator(500);FGA 异常不上吞;守门 403 不写 audit(deps 惯例)。
    """
    perms: PermissionsService = request.app.state.permissions
    from app.services.org import get_default_organization
    async with get_sessionmaker()() as db:
        org = await get_default_organization(db)
    if not org:
        raise HTTPException(500, "no default organization configured")
    _, tenant_key = org
    if await perms.is_org_admin(
        user_id=str(user.id), organization_tenant_key=tenant_key,
    ):
        return user
    if await perms.is_org_project_creator(
        user_id=str(user.id), organization_tenant_key=tenant_key,
    ) and await perms.is_org_artist_account_creator(
        user_id=str(user.id), organization_tenant_key=tenant_key,
    ):
        return user
    raise HTTPException(
        403,
        "inline artist creator permission required"
        "(仅系统管理员或被授权「新建项目时创建艺人账号」的可建项目组成员可查询登录名占用)",
    )
