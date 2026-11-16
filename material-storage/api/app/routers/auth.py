"""auth router — 通用 OIDC RP(#154:provider 配置留口)+ 本地账号密码登录(#149)。

endpoints:
  GET  /api/v1/auth/login           → 302 → OIDC provider authorize(未配置 = 400 提示纯本地登录)
  GET  /api/v1/auth/callback        → exchange code + set session cookie + redirect next
  GET  /api/v1/auth/me              → 返当前 session user(JSON)
  POST /api/v1/auth/logout          → 清 session cookie
  POST /api/v1/auth/local/login     → 账号密码登录(限流 + audit;session JWT 复用 #149)
  POST /api/v1/auth/change-password → 修改密码(首登 must_change_password 强制流程 #149)
  /api/v1/auth/tokens*              → PAT 自助管理三端点(实现在 app/routers/auth_tokens.py,
                                      此处 include_router 挂载)
"""
from __future__ import annotations

import asyncio
import logging
import uuid
from collections.abc import Coroutine
from typing import Any

from fastapi import APIRouter, Cookie, Depends, HTTPException, Query, Request
from fastapi.responses import JSONResponse, RedirectResponse
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.session import get_db
from app.db.tables import Group, GroupMembership, User, UserCreateGrant
from app.deps import (
    CurrentUser,
    _org_stats_sub_allowed,  # 统计面板子 flag 合取单一事实源(方案 §3.2;/me 内联复用)
    get_audit,
    get_current_user,
    get_local_auth,
    get_request_context,
    require_session_auth,
)
from app.models import ChangePasswordIn, LocalLoginIn
from app.routers.auth_tokens import router as tokens_router
from app.services.audit import AuditService
from app.services.auth import OIDCService
from app.services.local_auth import LocalAuthService
from app.services.mcp_gate import mcp_gate
from app.services.tokens import revoke_user_tokens
from app.settings import get_settings

log = logging.getLogger(__name__)
router = APIRouter()
# PAT 自助管理三端点(/api/v1/auth/tokens...):实现独立在 auth_tokens.py,
# 最终 URL 与拆分前一致(本 router 由 main.py 以 /api/v1/auth 前缀挂载)
router.include_router(tokens_router, prefix="/tokens")


# 复用 lifespan-wired single service instance
def get_auth_service(request: Request) -> OIDCService:
    return request.app.state.auth


_OIDC_STATE_COOKIE = "ms_oidc_state"
_OIDC_NEXT_COOKIE = "ms_oidc_next"
# 默认回 SPA 入口;nginx `/` 路由到 MinIO Console,不能用 "/"
_DEFAULT_AFTER_LOGIN = "/ms-static/web/"


@router.get("/login")
async def login(
    next: str = Query(default=_DEFAULT_AFTER_LOGIN, description="登录后回跳地址(相对路径)"),
    auth: OIDCService = Depends(get_auth_service),
) -> RedirectResponse:
    if not auth.enabled:
        # 纯本地登录模式:前端走 /auth/local/login;直接访问此入口给明确提示
        raise HTTPException(400, "OIDC provider 未配置 — 当前为纯本地登录,请使用账号密码登录")

    nonce, _ = OIDCService.generate_state()
    url = auth.build_authorize_url(state=nonce)

    resp = RedirectResponse(url=url, status_code=302)
    settings = get_settings()
    # state cookie(防 CSRF)+ next cookie(透传 redirect 目标)
    common = {
        "httponly": True,
        "secure": settings.session_cookie_secure,
        "samesite": settings.session_cookie_samesite,
        "max_age": 600,   # 10 min,callback 必须在此期内完成
        "path": "/api/v1/auth",
    }
    resp.set_cookie(_OIDC_STATE_COOKIE, nonce, **common)
    resp.set_cookie(_OIDC_NEXT_COOKIE, next, **common)
    return resp


@router.get("/callback")
async def callback(
    code: str = Query(...),
    state: str = Query(...),
    expected_state: str | None = Cookie(default=None, alias=_OIDC_STATE_COOKIE),
    next_url: str = Cookie(default=_DEFAULT_AFTER_LOGIN, alias=_OIDC_NEXT_COOKIE),
    db: AsyncSession = Depends(get_db),
    auth: OIDCService = Depends(get_auth_service),
) -> RedirectResponse:
    if not auth.enabled:
        raise HTTPException(400, "OIDC provider 未配置 — 当前为纯本地登录")
    if expected_state is None or state != expected_state:
        raise HTTPException(400, "state mismatch(可能 CSRF 或 cookie 过期,请重新 /login)")

    # 1) code → access_token
    token = await auth.exchange_code_for_token(code)
    # 2) access_token → userinfo
    userinfo = await auth.fetch_userinfo(token["access_token"])
    # 3) upsert(按 oidc_sub 匹配)
    user = await auth.upsert_user_from_userinfo(db, userinfo)
    if not user.is_active:
        raise HTTPException(403, "用户已离职 / 被禁用,请联系管理员")

    # 4) 签 session JWT + set cookie
    session_token = auth.encode_session(user)
    settings = get_settings()
    resp = RedirectResponse(url=next_url, status_code=302)
    resp.set_cookie(
        settings.session_cookie_name,
        session_token,
        httponly=True,
        secure=settings.session_cookie_secure,
        samesite=settings.session_cookie_samesite,
        max_age=settings.session_jwt_ttl_seconds,
        path="/",
    )
    # 清 OIDC 中间 cookie
    resp.delete_cookie(_OIDC_STATE_COOKIE, path="/api/v1/auth")
    resp.delete_cookie(_OIDC_NEXT_COOKIE, path="/api/v1/auth")
    log.info("login success user_id=%s", user.id)
    return resp


async def _me_flag_check(coro: Coroutine[Any, Any, bool]) -> bool:
    """单 flag FGA check 的逐 flag 容错包裹(/me flags gather 并行化用)。

    2026-11-06 统计面板方案 §3.2 把 /me 的组级 flag 补查(既有五 flag + 新增
    三 flag)一并 asyncio.gather 并行化(交付项);gather 无法逐项 try/except,
    本包裹等价承载原「逐 flag 内联 try/except → False」口径:FGA 抖动 /
    model 未 push 只吞成该 flag False,不致 /me 500、不影响其余 flag。
    """
    try:
        return await coro
    except Exception:  # noqa: BLE001
        return False


@router.get("/me", dependencies=[Depends(mcp_gate)])
async def me(
    request: Request,
    cur: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> dict:
    user = await db.get(User, cur.id)
    if not user:
        raise HTTPException(401, "session user not found")

    # 查 is_system_admin(organization#admin)给前端判 NewProjectModal 是否可用
    is_system_admin = False
    # is_project_creator 与 create_project 守门同口径(方案 §2.3/§2.4:
    # is_org_admin 或 organization#project_creator check,组开关经 group#member
    # 自动展开;故系统 admin 恒为 true,只在非 admin 时补查)
    from app.services.org import get_default_organization
    org = await get_default_organization(db)
    is_project_creator = False
    is_project_deleter = False
    is_folder_template_manager = False
    is_artist_account_creator = False
    is_file_deleter = False
    # 组级统计三 flag(2026-11-06 统计面板方案 §3.2):父 stats_viewer 仅控面板
    # 入口;两子 flag 守门口径 = is_org_admin ∨ (stats_viewer ∧ 子)
    is_stats_viewer = False
    is_usage_stats_viewer = False
    is_upload_stats_viewer = False
    if org:
        _, tenant_key = org
        perms = request.app.state.permissions
        try:
            is_system_admin = await perms.is_org_admin(
                user_id=str(user.id), organization_tenant_key=tenant_key,
            )
        except Exception:  # noqa: BLE001
            pass
        # 系统 admin 直通 true(admin 蕴含于守门口径,不重复 check);
        # 非 admin 才进下方 gather 补查覆盖该组值。2026-11-06 统计面板方案 §3.2
        # 交付项:新增三 flag 与既有五 flag 一并 asyncio.gather 并行化 —— /me 是
        # 前端冷启动热路径,8 次 FGA check 一次并行往返(原串行逐 flag
        # try/except 的容错口径由 _me_flag_check 等价承载);is_stats_viewer 的
        # check 结果计算一次、供两个合取子项复用(按 flag 粒度独立实现会多打
        # 父 check,补查计数 5→8 次的前提,勿)
        is_project_creator = bool(is_system_admin)
        is_project_deleter = bool(is_system_admin)
        is_folder_template_manager = bool(is_system_admin)
        is_artist_account_creator = bool(is_system_admin)
        is_file_deleter = bool(is_system_admin)
        is_stats_viewer = bool(is_system_admin)
        is_usage_stats_viewer = bool(is_system_admin)
        is_upload_stats_viewer = bool(is_system_admin)
        if not is_system_admin:
            (
                creator_r, deleter_r, tmpl_r, artist_r, file_del_r,
                stats_r, usage_r, upload_r,
            ) = await asyncio.gather(
                _me_flag_check(perms.is_org_project_creator(
                    user_id=str(user.id), organization_tenant_key=tenant_key,
                )),
                _me_flag_check(perms.is_org_project_deleter(
                    user_id=str(user.id), organization_tenant_key=tenant_key,
                )),
                _me_flag_check(perms.is_org_folder_template_manager(
                    user_id=str(user.id), organization_tenant_key=tenant_key,
                )),
                _me_flag_check(perms.is_org_artist_account_creator(
                    user_id=str(user.id), organization_tenant_key=tenant_key,
                )),
                _me_flag_check(perms.is_org_file_deleter(
                    user_id=str(user.id), organization_tenant_key=tenant_key,
                )),
                _me_flag_check(perms.is_org_stats_viewer(
                    user_id=str(user.id), organization_tenant_key=tenant_key,
                )),
                _me_flag_check(perms.is_org_usage_stats_viewer(
                    user_id=str(user.id), organization_tenant_key=tenant_key,
                )),
                _me_flag_check(perms.is_org_upload_stats_viewer(
                    user_id=str(user.id), organization_tenant_key=tenant_key,
                )),
            )
            is_project_creator = creator_r
            # 组级「删除项目」权限(F6.7):与 require_project_deleter 守门同口径
            # (is_org_admin 或 organization#project_deleter,组开关经 group#member 展开)
            is_project_deleter = deleter_r
            # 组级「管理目录模板」权限(目录模板方案 §3.3):与写守门
            # require_folder_template_manager 同口径(is_org_admin 或
            # organization#folder_template_manager,组开关经 group#member 展开)
            is_folder_template_manager = tmpl_r
            # 组级「新建项目时创建艺人账号」权限(艺人账号内嵌方案 §3.3/§4.4):与写守门
            # 同口径(is_org_admin 或 organization#artist_account_creator,组开关经
            # group#member 展开);POST /projects 的端点内组合校验另含 project_creator 支
            is_artist_account_creator = artist_r
            # 组级「删除文件/文件夹」权限(2026-10-16 组删除授权 F9):口径 =
            # is_system_admin 或 organization#file_deleter(组开关经 group#member 展开)。
            # **不含** org admin 直通 —— org admin 删文件走既有对象级权限,现状即如此,
            # 不借本需求扩大;对资产的完整删除守门另需对象 can_view 且非 sensitive
            # (见 assets.py / folders.py),本字段只是前端闸门的开关半边
            is_file_deleter = file_del_r
            # 组级「统计面板」父权限(2026-11-06 统计面板方案 §3.2):
            # is_org_admin ∨ check(organization#stats_viewer);结果只算一次
            is_stats_viewer = stats_r
            # 两子 flag 合取复用 deps helper(口径单一事实源,三边已算好、helper
            # 不再打 FGA):is_org_admin ∨ (stats_viewer ∧ 子) —— 父∧子合取防
            # 「子开父关」不一致 tuple 下前端显卡片而 API 403
            is_usage_stats_viewer = await _org_stats_sub_allowed(
                perms, user_id=str(user.id), organization_tenant_key=tenant_key,
                sub_relation="usage_stats_viewer",
                is_admin=is_system_admin, parent_check=stats_r, sub_check=usage_r,
            )
            is_upload_stats_viewer = await _org_stats_sub_allowed(
                perms, user_id=str(user.id), organization_tenant_key=tenant_key,
                sub_relation="upload_stats_viewer",
                is_admin=is_system_admin, parent_check=stats_r, sub_check=upload_r,
            )

    # 用户模块组级授权开放(2026-11-15 user-delegation §5.4):DB 直查放 FGA
    # gather 块之后单独一次查询(勿动上方既有 flag 逻辑)—— admin 恒 true 且
    # 组列表回 [];非 admin 一条 join 出授权目标组集合,集合非空 = is_user_manager
    is_user_manager = is_system_admin
    user_create_groups: list[dict[str, str]] = []
    if not is_system_admin:
        grant_rows = (
            await db.execute(
                select(UserCreateGrant.target_group_id, Group.name)
                .join(GroupMembership, GroupMembership.group_id == UserCreateGrant.group_id)
                .join(Group, Group.id == UserCreateGrant.target_group_id)
                .where(GroupMembership.user_id == user.id)
                .order_by(Group.name)
                .distinct()
            )
        ).all()
        user_create_groups = [
            {"id": str(target_id), "name": name} for target_id, name in grant_rows
        ]
        is_user_manager = bool(user_create_groups)

    return {
        "id": str(user.id),
        # #154:open_id/union_id 保留只读(历史对照),不再参与登录与权限
        "open_id": user.feishu_open_id,
        "union_id": user.feishu_union_id,
        "name": user.name,
        "email": user.email,
        "organization_id": str(user.organization_id) if user.organization_id else None,
        "is_active": user.is_active,
        "is_system_admin": is_system_admin,
        # 组级「新建项目」权限(方案 §2.4):与守门同口径;前端闸门用
        "is_project_creator": is_project_creator,
        # 组级「删除项目」权限(F6.7):与守门同口径;前端闸门用
        "is_project_deleter": is_project_deleter,
        # 组级「管理目录模板」权限(目录模板方案 §3.3):与守门同口径;前端闸门用
        "is_folder_template_manager": is_folder_template_manager,
        # 组级「新建项目时创建艺人账号」权限(艺人账号内嵌方案 §4.4):与守门同口径;
        # 前端闸门用(前端回落 is_artist_account_creator ?? is_system_admin)
        "is_artist_account_creator": is_artist_account_creator,
        # 组级「删除文件/文件夹」权限(2026-10-16 F9):与守门开关半边同口径
        # (is_system_admin or organization#file_deleter,不含 org admin 直通);
        # 前端闸门用
        "is_file_deleter": is_file_deleter,
        # 组级「统计面板」父权限(2026-11-06 统计面板方案 §3.2):与守门口径一致
        # (is_org_admin 或 organization#stats_viewer);仅控面板入口,前端三态门
        # is_stats_viewer ?? is_system_admin 消费
        "is_stats_viewer": is_stats_viewer,
        # 组级「使用统计」子权限(2026-11-06 统计面板方案 §3.2):与守门合取口径
        # 一致(is_org_admin 或 stats_viewer ∧ 本 flag);前端闸门用
        "is_usage_stats_viewer": is_usage_stats_viewer,
        # 组级「文件上传数量统计」子权限(2026-11-06 统计面板方案 §3.2):合取
        # 口径同上;前端闸门用
        "is_upload_stats_viewer": is_upload_stats_viewer,
        # 用户模块组级授权开放(2026-11-15 user-delegation §5.4):is_user_manager
        # admin 恒 true、非 admin = 授权目标组集合非空;user_create_groups =
        # 目标组集合(非 admin 被授权时,建号表单组选项;admin 返回 [],走
        # directory groups 接口取全量选项);前端菜单闸门用
        "is_user_manager": is_user_manager,
        "user_create_groups": user_create_groups,
        # #149:本地认证字段(加在 /me 供前端路由守卫用)。
        # password_set = 是否已设本地密码;must_change_password 仅在已设密码时生效
        # (存量飞书用户无本地密码,must_change_password 对他们是假值,不会误跳改密页)
        "password_set": user.password_hash is not None,
        "must_change_password": bool(user.must_change_password and user.password_hash is not None),
        # 百度网盘备份(方案 §5.2):菜单显隐开关(批次 4 前端依赖;读 settings,与用户无关)
        "baidu_backup_enabled": get_settings().baidu_backup_enabled,
    }


@router.post("/logout")
async def logout() -> JSONResponse:
    settings = get_settings()
    resp = JSONResponse({"status": "ok"})
    resp.delete_cookie(settings.session_cookie_name, path="/")
    return resp


# ─── 本地账号密码登录(#149)— #154 后为纯本地主路径 ──────────────────────────


async def _audit_login_locked(
    audit: AuditService,
    *,
    user_id: uuid.UUID | None,
    ip: str,
    ctx: dict[str, str | None],
    username: str,
    dimensions: list[str],
) -> None:
    """触发登录锁的审计事件(W1:锁定期间零审计盲区补齐)。

    调用形态照既有 local_login_failed(request_ip 是独立审计列,
    details 只放 username / 命中维度);audit.write 自带 commit。
    """
    await audit.write(
        event_type="local_login_locked",
        actor_user_id=user_id,
        request_ip=ip,
        user_agent=ctx.get("user_agent"),
        details={"username": username, "dimensions": dimensions},
    )


@router.post("/local/login")
async def local_login(
    body: LocalLoginIn,
    db: AsyncSession = Depends(get_db),  # noqa: B008  # FastAPI DI,repo 全量同款
    auth: OIDCService = Depends(get_auth_service),  # noqa: B008  # 只用 encode_session
    local_auth: LocalAuthService = Depends(get_local_auth),  # noqa: B008
    audit: AuditService = Depends(get_audit),  # noqa: B008
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008
) -> JSONResponse:
    """账号密码登录 → 复用 encode_session 签 session JWT + set cookie。

    限流:per IP + per username 双维度 Redis 计数,失败 5 次锁 15min(#149)。
    username 不强制邮箱格式:含 @ 匹配 email,否则匹配 name(拼音/工号友好)。
    """
    settings = get_settings()
    ip = ctx.get("request_ip") or "unknown"
    username = body.username.strip()
    if not username:
        raise HTTPException(400, "用户名不能为空")

    if await local_auth.is_locked(ip, username):
        raise HTTPException(
            429,
            f"登录失败次数过多,账号已锁定 {settings.auth_lock_seconds // 60} 分钟,请稍后再试",
        )

    user = await local_auth.find_user_by_username(db, username)
    # 统一文案:用户不存在 / 未设本地密码 / 密码错误都不区分(不泄露账号存在性)
    ok = (
        user is not None
        and user.password_hash is not None
        and local_auth.verify_password(body.password, user.password_hash)
    )
    if not ok:
        locked_dims = await local_auth.record_failure(ip, username)
        await audit.write(
            event_type="local_login_failed",
            actor_user_id=user.id if user else None,
            request_ip=ip,
            user_agent=ctx.get("user_agent"),
            details={"username": username, "reason": "bad_credentials"},
        )
        if locked_dims:
            # W1:触发锁瞬间补审计(此前锁定期 429 不写任何审计,存在盲区)
            await _audit_login_locked(
                audit, user_id=user.id if user else None, ip=ip, ctx=ctx,
                username=username, dimensions=locked_dims,
            )
        raise HTTPException(401, "用户名或密码错误")

    assert user is not None  # ok=True 蕴含 user 存在
    if not user.is_active:
        locked_dims = await local_auth.record_failure(ip, username)
        await audit.write(
            event_type="local_login_failed",
            actor_user_id=user.id,
            request_ip=ip,
            user_agent=ctx.get("user_agent"),
            details={"username": username, "reason": "inactive"},
        )
        if locked_dims:
            await _audit_login_locked(
                audit, user_id=user.id, ip=ip, ctx=ctx,
                username=username, dimensions=locked_dims,
            )
        raise HTTPException(403, "用户已离职 / 被禁用,请联系管理员")

    await local_auth.reset_failures(ip, username)
    await audit.write(
        event_type="local_login_success",
        actor_user_id=user.id,
        request_ip=ip,
        user_agent=ctx.get("user_agent"),
        details={"username": username},
    )

    session_token = auth.encode_session(user)
    resp = JSONResponse({
        "status": "ok",
        "user_id": str(user.id),
        "name": user.name,
        "must_change_password": user.must_change_password,
    })
    resp.set_cookie(
        settings.session_cookie_name,
        session_token,
        httponly=True,
        secure=settings.session_cookie_secure,
        samesite=settings.session_cookie_samesite,  # type: ignore[arg-type]
        max_age=settings.session_jwt_ttl_seconds,
        path="/",
    )
    log.info("local login success user_id=%s", user.id)
    return resp


@router.post("/change-password")
async def change_password(
    body: ChangePasswordIn,
    # D13b:PAT 一律 403「令牌不允许管理令牌/改密」—— 否则持 PAT 者可用旧密码
    # 自助改密,绕开「改密须由 session 发起」的语义(D11 口径依赖此)。
    # **逐路由守卫,勿给整个 auth router 挂**(/auth/local/login 会被挡死)。
    cur: CurrentUser = Depends(require_session_auth),  # noqa: B008
    db: AsyncSession = Depends(get_db),  # noqa: B008
    local_auth: LocalAuthService = Depends(get_local_auth),  # noqa: B008
    audit: AuditService = Depends(get_audit),  # noqa: B008
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008
) -> JSONResponse:
    """修改密码;首登 must_change_password=true 时前端强制走此流程(#149)。

    原密码校验通过 → 新密码过策略 → 写库 + must_change_password 置 false。
    已登录 session 不失效(stateless JWT,机制零改动)。
    """
    ip = ctx.get("request_ip") or "unknown"
    user = await db.get(User, cur.id)
    if not user:
        raise HTTPException(401, "session user not found")

    if user.password_hash is None:
        # 存量飞书用户从未设本地密码:拒绝盲改,走管理后台初始化(P2)
        raise HTTPException(400, "该账号尚未设置本地密码,请联系管理员初始化")

    if not local_auth.verify_password(body.old_password, user.password_hash):
        await audit.write(
            event_type="password_changed",
            actor_user_id=user.id,
            request_ip=ip,
            user_agent=ctx.get("user_agent"),
            details={"ok": False, "reason": "wrong_old_password"},
        )
        raise HTTPException(400, "原密码不正确")

    policy_error = local_auth.validate_password_policy(body.new_password)
    if policy_error:
        raise HTTPException(400, policy_error)
    if body.new_password == body.old_password:
        raise HTTPException(400, "新密码不能与原密码相同")

    user.password_hash = local_auth.hash_password(body.new_password)
    user.must_change_password = False
    # D13 安全不变量:密码变更 ⇒ 吊销该用户全部活跃 PAT。吊销 UPDATE 必须与
    # password_hash 写入同事务、同一次 commit 之前(commit 之后再吊销会造出
    # 「密码已改而 PAT 仍有效」的窗口);审计在 commit 之后逐条写(只写本次
    # 真正被吊销的行,无活跃令牌则不写),审计失败只 log 不回滚。
    revoked_tokens = await revoke_user_tokens(db, user_id=user.id, reason="password_changed")
    await db.commit()

    await audit.write(
        event_type="password_changed",
        actor_user_id=user.id,
        request_ip=ip,
        user_agent=ctx.get("user_agent"),
        details={"ok": True},
    )
    for ref in revoked_tokens:
        await audit.write(
            event_type="token_revoked",
            actor_user_id=user.id,
            request_ip=ip,
            user_agent=ctx.get("user_agent"),
            details={
                "user_id": str(user.id),
                "token_id": str(ref.id),
                "token_prefix": ref.token_prefix,
                "reason": "password_changed",
                "actor": "self",
            },
        )
    log.info("password changed user_id=%s tokens_revoked=%d", user.id, len(revoked_tokens))
    return JSONResponse({"status": "ok"})
