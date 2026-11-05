"""账号安全 router — 邮箱绑定/换绑/解绑 + 找回密码(方案 §5.2/§5.3/§5.4)。

统一挂 /api/v1/auth 前缀(main.py)。B1a 只含公开配置端点;B2(邮箱验证码
三端点)/ B3(找回密码三端点)按下方分区追加,不另开 router。

分区规划(B2/B3 落点,别挪):
  # ─── 公开端点(无需鉴权)── GET /public-config(本文件,B1a)
  # ─── B2:邮箱验证码(session-only)── POST /email/code|/email/confirm|/email/unbind
  # ─── B3:找回密码(公开)── POST /password-reset/request|verify|confirm
"""

from __future__ import annotations

import asyncio
import logging

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.session import get_db
from app.db.tables import User
from app.deps import (
    CurrentUser,
    get_audit,
    get_local_auth,
    get_request_context,
    require_session_auth,
)
from app.models import EmailCodeConfirmIn, EmailCodeIn, EmailUnbindIn
from app.services import email_verification as ev
from app.services.audit import AuditService
from app.services.email_utils import email_fingerprint, mask_email
from app.services.local_auth import LocalAuthService
from app.services.mailer import MailSendError, send_mail
from app.services.rate_limit import RateLimitUnavailable
from app.settings import get_settings

log = logging.getLogger(__name__)
router = APIRouter()


class PublicAuthConfigOut(BaseModel):
    """登录页「忘记密码」/ 设置页邮箱区的显隐依据(方案 §5.2);无秘密,可公开。

    email_auth_enabled = password_reset_enabled = mail_ready
    (lifespan 启动时经 resolve_mail_ready 算好挂 app.state,配置不合法降级 false)。
    """

    email_auth_enabled: bool
    password_reset_enabled: bool
    password_min_length: int


# ─── 公开端点(无需鉴权;高频轮询,不写审计)─────────────────────────────────
@router.get("/public-config", response_model=PublicAuthConfigOut)
async def public_config(request: Request) -> PublicAuthConfigOut:
    # getattr 兜底:lifespan 未跑(如部分单测/降级启动)时按 false 处理,
    # 公开配置宁可隐藏入口也不能 500
    mail_ready = getattr(request.app.state, "mail_ready", False)
    settings = get_settings()
    return PublicAuthConfigOut(
        email_auth_enabled=mail_ready,
        password_reset_enabled=mail_ready,
        password_min_length=settings.auth_password_min_length,
    )


# ─── B2:邮箱验证码(session-only;POST /email/code|/email/confirm|/email/unbind)──


def _require_mail_ready(request: Request) -> None:
    """有效开关检查(§5.3.2 第 2 步 / §5.3.3 第 1 步);/email/unbind 例外不依赖。"""
    if not getattr(request.app.state, "mail_ready", False):
        raise HTTPException(503, "邮箱功能未启用,请联系管理员")


async def _audit_requested(
    audit: AuditService, *, user: User, ip: str, ctx: dict[str, str | None],
    details: dict[str, object],
) -> None:
    """``email_verification_requested`` 审计统一出口(§5.9):best-effort,
    actor 快照恒为**当前**邮箱脱敏(该事件发生时新邮箱尚未生效)。"""
    await ev.write_audit_quiet(
        audit, event_type="email_verification_requested", actor_user_id=user.id,
        request_ip=ip, user_agent=ctx.get("user_agent"),
        details=details, actor_email_snapshot=mask_email(user.email),
    )


@router.post("/email/code")
async def request_email_code(
    request: Request,
    body: EmailCodeIn,
    cur: CurrentUser = Depends(require_session_auth),  # noqa: B008  # 步骤 1:PAT 403/强制改密 403
    db: AsyncSession = Depends(get_db),  # noqa: B008
    local_auth: LocalAuthService = Depends(get_local_auth),  # noqa: B008
    audit: AuditService = Depends(get_audit),  # noqa: B008
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008
) -> JSONResponse:
    """发送邮箱验证码(§5.3.2,15 步;**顺序即安全**)。

    绑定(bind)/ 换绑(change)/ 验证当前邮箱(verify)三态共用本端点;
    步骤编号对应方案 §5.3.2。步骤 5(email 严格归一)在 Pydantic 解析期完成,
    422 不进本流程、不消耗请求预算。
    """
    settings = get_settings()
    redis = request.app.state.redis
    ip = ctx.get("request_ip") or "unknown"

    _require_mail_ready(request)  # 步骤 2
    user = await db.get(User, cur.id)
    if user is None:
        raise HTTPException(401, "session user not found")

    try:
        # 步骤 3:密码失败锁
        lock_ttl = await ev.password_lock_ttl(redis, user.id)
        if lock_ttl > 0:
            raise HTTPException(
                429,
                f"密码错误次数过多,邮箱操作已锁定 {max(1, lock_ttl // 60)} 分钟,请稍后再试",
                headers={"Retry-After": str(lock_ttl)},
            )
        # 步骤 4:校验当前密码(错误计数与锁;正确才给请求预算)
        if user.password_hash is None:
            raise HTTPException(400, "该账号尚未设置本地密码,请先联系管理员初始化")
        if not local_auth.verify_password(body.password, user.password_hash):
            await ev.record_password_failure(
                redis, max_failures=settings.email_change_max_password_failures,
                lock_seconds=settings.email_change_password_lock_seconds, user_id=user.id,
            )
            await _audit_requested(
                audit, user=user, ip=ip, ctx=ctx,
                details={"ok": False, "reason": "wrong_password"},
            )
            raise HTTPException(400, "账号密码不正确")
        await ev.clear_password_failures(redis, user.id)
        # 步骤 4 续:每用户请求预算(密码通过后才 INCR;409 占用尝试也计数,防枚举)
        budget = await ev.incr_request_budget(redis, user.id)
        if budget > settings.email_code_request_per_user:
            wait = max(1, await ev.req_budget_ttl(redis, user.id))
            raise HTTPException(429, "操作过于频繁,请稍后再试",
                                headers={"Retry-After": str(wait)})
        # 步骤 6:purpose 三态
        target = body.email
        purpose = ev.determine_purpose(current_email=user.email, target=target)
        if purpose == "verify" and user.email_verified_at is not None:
            raise HTTPException(400, "该邮箱已验证,无需重复验证")
        # 步骤 7:占用检查(仅 bind/change;verify 不查,存量冲突走 §4.4 预检)
        if purpose in ("bind", "change"):
            if await ev.email_taken_by_other(db, target, exclude_id=user.id):
                await _audit_requested(
                    audit, user=user, ip=ip, ctx=ctx,
                    details={"ok": False, "purpose": purpose, "reason": "email_taken",
                             "email_masked": mask_email(target)},
                )
                raise HTTPException(
                    409, "该邮箱已被其他账号使用;如该邮箱属于你,请联系管理员解除其它账号的占用",
                )
            if await ev.username_cross_conflict(db, target, exclude_id=user.id):
                await _audit_requested(
                    audit, user=user, ip=ip, ctx=ctx,
                    details={"ok": False, "purpose": purpose, "reason": "username_taken",
                             "email_masked": mask_email(target)},
                )
                raise HTTPException(409, "该邮箱与某个登录名冲突,请联系管理员处理")
        # 步骤 8:IP 配额(先读;发送成功才 INCR)
        if await ev.read_ip_quota(redis, ip) >= settings.email_code_hourly_per_ip:
            raise HTTPException(429, "操作过于频繁,请稍后再试", headers={"Retry-After": "3600"})
        # 步骤 9:日配额(先查日配额再占冷却,避免第 11 次先吃 60s 冷却文案)
        if await ev.read_daily_quota(redis, user.id) >= settings.email_code_daily_per_user:
            wait = ev.seconds_until_cn_midnight()
            raise HTTPException(429, "今日验证码发送次数已达上限,请明天再试",
                                headers={"Retry-After": str(wait)})
    except RateLimitUnavailable:
        log.warning("email code rate-limit redis unavailable user=%s", user.id)
        raise HTTPException(503, "服务暂不可用,请稍后再试") from None

    # §5.6.3 拿槽(2s):位置钉死在冷却占位之前(步骤 9/10 之间);拿不到 =
    # 确定未发送(不占冷却、不消耗任何配额)
    sem: asyncio.Semaphore = request.app.state.mail_semaphore
    mail_tasks: set[asyncio.Task[None]] = request.app.state.mail_tasks
    try:
        async with asyncio.timeout(2):
            await sem.acquire()
    except TimeoutError:
        raise HTTPException(
            429, "邮件发送繁忙,请稍后再试", headers={"Retry-After": "2"},
        ) from None

    send_task: asyncio.Task[None] | None = None

    def _release_slot(t: asyncio.Task[None]) -> None:
        # shield 保证超时路径 task 不被 cancel:线程真正结束才释放槽;强引用
        # 集合防孤儿 task 被 GC 后 done_callback 不跑、槽位永久泄漏(§5.6.3)
        mail_tasks.discard(t)
        if not t.cancelled() and t.exception() is not None:
            log.warning("email code send task failed after timeout: %r", t.exception())
        sem.release()

    try:
        # 步骤 10:冷却(SET NX 原子占位,只此一次、不续期)
        if not await ev.acquire_cooldown(
            redis, resend_seconds=settings.email_code_resend_seconds, user_id=user.id,
        ):
            wait = await ev.cooldown_ttl(redis, user.id)
            raise HTTPException(429, f"发送过于频繁,请 {wait} 秒后再试",
                                headers={"Retry-After": str(wait)})
        # 步骤 11:生成验证码与哈希(先不写 Redis)
        code = ev.generate_code()
        code_hash = ev.compute_code_hash(settings.session_jwt_secret, user.id, code)
        cur_email_hash = ev.current_email_hash(user.email)
        # 步骤 12:发信前结束 DB 事务(前面只做了读;连接不能陪 SMTP 挂 20s)
        await db.commit()
        # 步骤 13:同步发送(独立 task + shield + wait_for 总预算,§5.6.3)
        send_task = asyncio.create_task(send_mail(
            settings, to=target, subject="【素材库】邮箱验证码",
            body=ev.code_mail_body(settings, code),
        ))
        mail_tasks.add(send_task)
        send_task.add_done_callback(_release_slot)
        outcome = "sent"
        try:
            await asyncio.wait_for(asyncio.shield(send_task),
                                   settings.smtp_total_timeout_seconds)
        except TimeoutError:
            outcome = "unknown"  # 结果未知:服务器可能已接受
        except MailSendError as exc:
            outcome = "failed" if exc.definite else "unknown"
    except RateLimitUnavailable:
        if send_task is None:
            sem.release()  # 未建发送 task:自己放槽
        log.warning("email code redis unavailable user=%s", user.id)
        raise HTTPException(503, "服务暂不可用,请稍后再试") from None
    except BaseException:
        if send_task is None:
            sem.release()  # 冷却 429 等分支:acquire 成功但未建 task,按标志放槽
        raise

    if outcome == "failed":
        # 确定失败:不写 Redis(旧码保留、不被覆盖),不消耗配额
        await _audit_requested(
            audit, user=user, ip=ip, ctx=ctx,
            details={"ok": False, "purpose": purpose, "reason": "smtp_failed",
                     "email_masked": mask_email(target)},
        )
        raise HTTPException(502, "验证码发送失败,请稍后重试")

    # sent / unknown:写入哈希(邮件可能已送达,验证码必须可用);单 Lua 定档
    try:
        await ev.store_code(
            redis, ttl_seconds=settings.email_code_ttl_seconds, user_id=user.id,
            code_hash=code_hash, email=target, purpose=purpose,
            cur_email_hash=cur_email_hash,
        )
    except RateLimitUnavailable:
        # 邮件已发出但 Redis 写失败:不能 200 让用户拿一个服务端无法验证的码
        log.error("email code store failed after mail sent user=%s", user.id)
        await _audit_requested(
            audit, user=user, ip=ip, ctx=ctx,
            details={"ok": False, "purpose": purpose, "reason": "store_failed",
                     "email_masked": mask_email(target)},
        )
        raise HTTPException(503, "邮件已发送但系统繁忙,请稍后重新获取") from None

    if outcome == "unknown":
        # 结果未知:验证码已写入可用;不消耗配额
        await _audit_requested(
            audit, user=user, ip=ip, ctx=ctx,
            details={"ok": False, "purpose": purpose, "reason": "smtp_timeout",
                     "email_masked": mask_email(target)},
        )
        raise HTTPException(502, "发送结果未知,请稍后检查邮箱;若未收到可重新获取")

    # 发送成功:INCR 第 8/9 步配额(冷却已在占位时定档,此处不动);计数失败只
    # log —— 邮件已发出,不能因计数抖动把成功变 503
    try:
        await ev.incr_ip_quota(redis, ip)
        await ev.incr_daily_quota(redis, user.id)
    except RateLimitUnavailable:
        log.warning("email code quota incr failed (mail already sent) user=%s", user.id)

    # 步骤 14:审计(ok=true;不含验证码)
    await _audit_requested(
        audit, user=user, ip=ip, ctx=ctx,
        details={"ok": True, "purpose": purpose, "email_masked": mask_email(target)},
    )
    # 步骤 15
    return JSONResponse({
        "status": "sent",
        "masked_email": mask_email(target),
        "expires_in": settings.email_code_ttl_seconds,
    })


@router.post("/email/confirm")
async def confirm_email_code(
    request: Request,
    body: EmailCodeConfirmIn,
    bg: BackgroundTasks,
    cur: CurrentUser = Depends(require_session_auth),  # noqa: B008  # 步骤由守卫先于流程
    db: AsyncSession = Depends(get_db),  # noqa: B008
    audit: AuditService = Depends(get_audit),  # noqa: B008
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008
) -> JSONResponse:
    """确认验证码:完成绑定 / 换绑 / 验证(§5.3.3,10 步)。`session_version` 不变。"""
    settings = get_settings()
    redis = request.app.state.redis
    ip = ctx.get("request_ip") or "unknown"

    _require_mail_ready(request)  # 步骤 1
    user = await db.get(User, cur.id)
    if user is None:
        raise HTTPException(401, "session user not found")

    try:
        stored = await ev.read_stored_code(redis, user.id)  # 步骤 2
        if stored is None:
            raise HTTPException(400, "请先获取验证码")
        if stored.attempts >= settings.email_code_max_attempts:  # 步骤 3
            await ev.delete_code(redis, user.id)
            raise HTTPException(400, "验证码错误次数过多,请重新获取")
        if not ev.verify_code(  # 步骤 4:HMAC 恒时比对;错误尝试 Lua 原子计数、不续期
            settings.session_jwt_secret, user.id, body.code, stored.code_hash,
        ):
            attempts = await ev.register_wrong_attempt(
                redis, ttl_seconds=settings.email_code_ttl_seconds, user_id=user.id,
            )
            if attempts is None:
                raise HTTPException(400, "请先获取验证码")  # key 恰好过期:不造新 key
            if attempts >= settings.email_code_max_attempts:
                await ev.delete_code(redis, user.id)
            raise HTTPException(400, "验证码错误或已失效")
        # 步骤 5:邮箱快照兜底 + (bind/change)并发窗口占用复核
        if stored.current_email_hash != ev.current_email_hash(user.email):
            await ev.delete_code(redis, user.id)
            raise HTTPException(400, "邮箱已变更,请重新获取验证码")
        if stored.purpose in ("bind", "change"):
            if await ev.email_taken_by_other(db, stored.email, exclude_id=user.id):
                await ev.delete_code(redis, user.id)
                await _audit_requested(
                    audit, user=user, ip=ip, ctx=ctx,
                    details={"ok": False, "purpose": stored.purpose, "reason": "email_taken",
                             "email_masked": mask_email(stored.email)},
                )
                raise HTTPException(
                    409, "该邮箱已被其他账号使用;如该邮箱属于你,请联系管理员解除其它账号的占用",
                )
            if await ev.username_cross_conflict(db, stored.email, exclude_id=user.id):
                await ev.delete_code(redis, user.id)
                await _audit_requested(
                    audit, user=user, ip=ip, ctx=ctx,
                    details={"ok": False, "purpose": stored.purpose, "reason": "username_taken",
                             "email_masked": mask_email(stored.email)},
                )
                raise HTTPException(409, "该邮箱与某个登录名冲突,请联系管理员处理")
        # 步骤 6:写库(单事务;快照在 service 内、赋值前取);竞态撞唯一索引 → 409
        try:
            old_email, old_verified, action = await ev.apply_confirm(db, user, stored)
        except HTTPException as exc:
            if exc.status_code == 409:  # IntegrityError 竞态:删 key + 审计再抛,不冒 500
                await ev.delete_code(redis, user.id)
                await _audit_requested(
                    audit, user=user, ip=ip, ctx=ctx,
                    details={"ok": False, "purpose": stored.purpose, "reason": "email_taken",
                             "email_masked": mask_email(stored.email)},
                )
            raise
        # 步骤 7:删 Redis key(确认成功,码一次性作废)
        await ev.delete_code(redis, user.id)
    except RateLimitUnavailable:
        log.warning("email confirm redis unavailable user=%s", user.id)
        raise HTTPException(503, "服务暂不可用,请稍后再试") from None

    # 步骤 8:换绑告知(仅 purpose=change 且旧邮箱已验证且值实际变化;大小写-only 不发)
    if (
        action == "change"
        and old_verified
        and old_email is not None
        and email_fingerprint(old_email) != stored.email
    ):
        bg.add_task(
            ev.send_mail_quiet, settings, to=old_email,
            subject="【素材库】账号邮箱已变更",
            body=(f"你的账号邮箱已由 {mask_email(old_email)} 变更为 {mask_email(stored.email)}。"
                  "若非本人操作,请立即联系管理员。"),
        )
    # 步骤 9:审计(actor 快照 = 新邮箱脱敏)
    if action == "change":
        await ev.write_audit_quiet(
            audit, event_type="email_changed", actor_user_id=user.id,
            request_ip=ip, user_agent=ctx.get("user_agent"),
            details={"old_masked": mask_email(old_email), "new_masked": mask_email(stored.email)},
            actor_email_snapshot=mask_email(stored.email),
        )
    else:
        await ev.write_audit_quiet(
            audit, event_type="email_verified", actor_user_id=user.id,
            request_ip=ip, user_agent=ctx.get("user_agent"),
            details={"action": action, "email_masked": mask_email(stored.email)},
            actor_email_snapshot=mask_email(stored.email),
        )
    # 步骤 10
    return JSONResponse({
        "status": "ok",
        "email": stored.email,
        "email_verified": True,
        "action": action,
    })


@router.post("/email/unbind")
async def unbind_email(
    request: Request,
    body: EmailUnbindIn,
    bg: BackgroundTasks,
    cur: CurrentUser = Depends(require_session_auth),  # noqa: B008
    db: AsyncSession = Depends(get_db),  # noqa: B008
    local_auth: LocalAuthService = Depends(get_local_auth),  # noqa: B008
    audit: AuditService = Depends(get_audit),  # noqa: B008
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008
) -> JSONResponse:
    """解除邮箱绑定(§5.3.4,8 步)。**不依赖 mail_ready**(SMTP 关闭仍可用);
    告知邮件 best-effort;Redis 故障仍 503(fail-closed)。"""
    settings = get_settings()
    redis = request.app.state.redis
    ip = ctx.get("request_ip") or "unknown"

    # 步骤 1:不依赖 mail_ready
    user = await db.get(User, cur.id)
    if user is None:
        raise HTTPException(401, "session user not found")
    oidc_enabled = request.app.state.auth.enabled  # router 注入,勿在 service 重算

    try:
        # 步骤 2:密码失败锁 / 校验(与 /email/code 共用 email:chg:* 计数)
        lock_ttl = await ev.password_lock_ttl(redis, user.id)
        if lock_ttl > 0:
            raise HTTPException(
                429,
                f"密码错误次数过多,邮箱操作已锁定 {max(1, lock_ttl // 60)} 分钟,请稍后再试",
                headers={"Retry-After": str(lock_ttl)},
            )
        if user.password_hash is None:
            raise HTTPException(400, "该账号尚未设置本地密码,请先联系管理员初始化")
        if not local_auth.verify_password(body.password, user.password_hash):
            await ev.record_password_failure(
                redis, max_failures=settings.email_change_max_password_failures,
                lock_seconds=settings.email_change_password_lock_seconds, user_id=user.id,
            )
            await _audit_requested(
                audit, user=user, ip=ip, ctx=ctx,
                details={"ok": False, "reason": "wrong_password"},
            )
            raise HTTPException(400, "账号密码不正确")
        await ev.clear_password_failures(redis, user.id)
        # 步骤 3-5:校验(未绑定 400 / 无独立登录名 400)→ 快照 → 清空 → 删未用
        # 重置 token → commit(apply_unbind 内单事务完成)
        old_email, old_verified = await ev.apply_unbind(db, user, oidc_enabled=oidc_enabled)
        # 步骤 5 末:残留验证码不能把邮箱重新绑上 → DEL email:code:{id}
        await ev.delete_code(redis, user.id)
    except RateLimitUnavailable:
        log.warning("email unbind redis unavailable user=%s", user.id)
        raise HTTPException(503, "服务暂不可用,请稍后再试") from None

    # 步骤 6:告知邮件(仅旧邮箱已验证;SMTP 关闭时 send_mail 抛 definite 错误,
    # _bg_mail_quiet 记 log 即「跳过」,不影响已成功的响应)
    if old_verified:
        bg.add_task(
            ev.send_mail_quiet, settings, to=old_email,
            subject="【素材库】账号邮箱已解绑",
            body=(f"你的账号已解除邮箱 {mask_email(old_email)} 的绑定,"
                  "将无法再通过邮箱找回密码。"),
        )
    # 步骤 7:审计(快照 = 清空前旧邮箱脱敏 —— email 已为 None,必须覆盖)
    await ev.write_audit_quiet(
        audit, event_type="email_unbound", actor_user_id=user.id,
        request_ip=ip, user_agent=ctx.get("user_agent"),
        details={"old_masked": mask_email(old_email)},
        actor_email_snapshot=mask_email(old_email),
    )
    # 步骤 8
    return JSONResponse({"status": "ok"})


# ─── B3:找回密码(公开;POST /password-reset/request|verify|confirm)──
# 本文件已达单文件行数上限,B3 端点独立在 routers/password_reset.py(与
# auth.py ← auth_tokens.py 同款 include 拆法);最终 URL 仍是
# /api/v1/auth/password-reset/*(本 router 由 main.py 以该前缀挂载)。
from app.routers.password_reset import router as _password_reset_router  # noqa: E402

router.include_router(_password_reset_router)
