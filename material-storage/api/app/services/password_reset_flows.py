"""邮箱找回密码 — 流程层(方案 §5.4):申请(14 步)/ verify / confirm(9 步)。

原语层在 ``password_reset.py``(键名 / 预算与冷却 / token 落库与三态删行 /
原子消费 / 共享清理);本文件按方案步骤顺序组装并落审计(无状态模块函数,
db / redis / settings / audit 由 router 注入;异常按仓库惯例直接抛
HTTPException)。步骤顺序即安全,勿重排。

审计口径(§5.9):重置链路全部未认证,``actor_user_id`` 一律 None 且
``auth_method`` 显式 ``"anonymous"``(不覆盖会在审计页看起来像会话行为);
成功路径上的审计统一 try/except + log.warning(邮件已发/密码已重置,审计失败
不能把成功变成 500)。
"""
from __future__ import annotations

import asyncio
import logging
import uuid
from typing import Any

from fastapi import HTTPException, Request
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.tables import User
from app.services.audit import AuditService
from app.services.email_utils import mask_email
from app.services.local_auth import LocalAuthService
from app.services.mailer import MailSendError, send_mail
from app.services.password_reset import (
    ResetTokenInvalid,
    _as_utc,
    acquire_cooldown,
    build_reset_mail,
    confirm_ip_key,
    consume_token_and_reset_password,
    cooldown_ttl,
    delete_other_unused_tokens,
    delete_token_row,
    fail_ip_key,
    incr_confirm_budget,
    incr_request_budget,
    incr_send_ip_quota,
    incr_send_user_quota,
    ip_lock_ttl,
    ip_locked,
    issue_token,
    keep_recent_two,
    load_valid_token,
    post_password_change_cleanup,
    read_send_ip_quota,
    read_send_user_quota,
    record_ip_failure,
    req_budget_key,
    retry_after_headers,
    send_ip_key,
    send_user_key,
)
from app.services.rate_limit import delete_keys, ttl_seconds
from app.settings import Settings

log = logging.getLogger(__name__)


async def request_reset(
    *,
    request: Request,
    db: AsyncSession,
    redis: Any,
    settings: Settings,
    audit: AuditService,
    email: str,
    ip: str,
    user_agent: str | None,
) -> dict[str, str]:
    """申请重置邮件(公开端点,§5.4.2 的 14 步;顺序即安全)。"""
    # 3. IP 封控(R8;只锁 reset 端点,不影响登录)
    if await ip_locked(redis, ip):
        ttl = await ip_lock_ttl(redis, ip)
        raise HTTPException(
            429, f"尝试次数过多,请 {max(1, ttl // 60)} 分钟后再试",
            headers=retry_after_headers(ttl),
        )
    # 4. 请求预算:原子 INCR 后检查(防不存在邮箱探测与审计刷屏;超预算不写审计)
    if await incr_request_budget(redis, ip) > settings.password_reset_hourly_request_per_ip:
        raise HTTPException(
            429, "操作过于频繁,请稍后再试",
            headers=retry_after_headers(await ttl_seconds(redis, req_budget_key(ip))),
        )
    # 5. 查用户(只取四列;email 必取 —— email_hash 快照要算,漏选会 500/空哈希)
    row = (
        await db.execute(
            select(
                User.id, User.email, User.is_active, User.password_hash,
            ).where(func.lower(User.email) == email).limit(1)
        )
    ).first()
    # 6. 不存在 / 停用:计入 IP 失败,同文案不暴露账号状态;未验证邮箱照常发(D4)
    if row is None or not row.is_active:
        reason = "not_found" if row is None else "inactive"
        masked = mask_email(email)
        triggered = await record_ip_failure(
            redis,
            max_failures=settings.password_reset_max_failures,
            lock_seconds=settings.password_reset_lock_seconds,
            ip=ip,
        )
        await audit.write(
            event_type="password_reset_failed", actor_user_id=None,
            request_ip=ip, user_agent=user_agent, auth_method="anonymous",
            details={"reason": reason, "email_masked": masked},
        )
        if triggered:
            # 锁定瞬间补一条(对齐 local_login_locked 补盲区的做法)
            await audit.write(
                event_type="password_reset_failed", actor_user_id=None,
                request_ip=ip, user_agent=user_agent, auth_method="anonymous",
                details={
                    "reason": "ip_locked", "email_masked": masked,
                    "ip": ip, "lock_seconds": settings.password_reset_lock_seconds,
                },
            )
        raise HTTPException(400, "该邮箱未绑定任何账号")
    # 7/8. 发信配额(先读后发,成功才 INCR —— SMTP 失败不烧额度)
    if await read_send_ip_quota(redis, ip) >= settings.password_reset_hourly_per_ip:
        await audit.write(
            event_type="password_reset_failed", actor_user_id=None,
            request_ip=ip, user_agent=user_agent, auth_method="anonymous",
            details={"reason": "send_quota_ip", "email_masked": mask_email(row.email)},
        )
        raise HTTPException(
            429, "操作过于频繁,请稍后再试",
            headers=retry_after_headers(await ttl_seconds(redis, send_ip_key(ip))),
        )
    if await read_send_user_quota(redis, row.id) >= settings.password_reset_hourly_per_user:
        await audit.write(
            event_type="password_reset_failed", actor_user_id=None,
            request_ip=ip, user_agent=user_agent, auth_method="anonymous",
            details={
                "reason": "send_quota_user", "email_masked": mask_email(row.email),
            },
        )
        raise HTTPException(
            429,
            f"该账号重置邮件发送过于频繁(每小时 {settings.password_reset_hourly_per_user} 次),请稍后再试",
            headers=retry_after_headers(await ttl_seconds(redis, send_user_key(row.id))),
        )
    # 8.5 §5.6.3 拿槽(钉死在冷却占位之前;拿不到 → 确定未发送,不占冷却/不插 token)
    sem: asyncio.Semaphore = request.app.state.mail_semaphore
    try:
        async with asyncio.timeout(2):
            await sem.acquire()
    except TimeoutError as exc:
        raise HTTPException(
            429, "邮件发送繁忙,请稍后重试", headers={"Retry-After": "2"},
        ) from exc
    send_task: asyncio.Task[None] | None = None
    try:
        # 9. 冷却 SET NX(占位后所有分支不再触碰/不续期;SMTP 失败也保留 60s)
        if not await acquire_cooldown(
            redis, cooldown_seconds=settings.password_reset_cooldown_seconds,
            user_id=row.id,
        ):
            ttl = await cooldown_ttl(redis, row.id)
            raise HTTPException(
                429, f"发送过于频繁,请 {ttl} 秒后再试", headers=retry_after_headers(ttl),
            )
        # 10/11. 签发 + 落库(先不删旧行)
        raw, token_id = await issue_token(
            db, settings=settings, user_id=row.id, user_email=row.email,
            request_ip=ip, user_agent=user_agent,
        )
        # 12/13. 链接 + 同步发送(独立 task + shield;超时不取消底层发送)
        subject, body = build_reset_mail(settings, token=raw)
        send_task = asyncio.create_task(
            send_mail(settings, to=row.email, subject=subject, body=body)
        )
        tasks: set[asyncio.Task[None]] = request.app.state.mail_tasks
        tasks.add(send_task)  # 强引用:防孤儿 task 被 GC 后 done_callback 不跑、槽永久泄漏

        def _release(t: asyncio.Task[None]) -> None:
            tasks.discard(t)
            if not t.cancelled() and t.exception() is not None:
                log.warning("reset mail send failed after timeout: %r", t.exception())
            sem.release()

        send_task.add_done_callback(_release)
        try:
            await asyncio.wait_for(
                asyncio.shield(send_task), settings.smtp_total_timeout_seconds,
            )
        except TimeoutError:
            await _send_unknown(db, audit=audit, ip=ip,
                                user_agent=user_agent, user_id=row.id,
                                email_masked=mask_email(row.email),
                                new_id=token_id)
        except MailSendError as exc:
            if exc.definite:
                await _send_definite_failure(
                    db, audit=audit, ip=ip, user_agent=user_agent,
                    user_id=row.id, email_masked=mask_email(row.email),
                    token_id=token_id,
                )
            else:
                await _send_unknown(db, audit=audit, ip=ip,
                                    user_agent=user_agent, user_id=row.id,
                                    email_masked=mask_email(row.email),
                                    new_id=token_id)
        else:
            return await _send_success(
                db, redis=redis, audit=audit, ip=ip, user_agent=user_agent,
                user_id=row.id, email_masked=mask_email(row.email),
                token_id=token_id,
            )
        raise AssertionError("unreachable")  # 分支函数必抛 HTTPException
    finally:
        # 拿槽后、task 建立前异常(冷却 429 / DB 失败):无人回调释放,手动还槽;
        # task 已建立则由 done_callback 在**线程真正结束后**释放(shield 语义)
        if send_task is None:
            sem.release()


async def _send_success(
    db: AsyncSession, *, redis: Any, audit: AuditService, ip: str,
    user_agent: str | None, user_id: uuid.UUID, email_masked: str | None,
    token_id: uuid.UUID,
) -> dict[str, str]:
    """发送成功:删旧行(失败只 log)→ 清失败链 → INCR 配额 → 审计 → 200。"""
    try:
        await delete_other_unused_tokens(db, user_id=user_id, keep_id=token_id)
    except Exception as exc:
        log.warning("delete old reset tokens failed user=%s err=%r", user_id, exc)
    try:
        await delete_keys(redis, fail_ip_key(ip))  # 成功即清零失败链
        await incr_send_ip_quota(redis, ip)
        await incr_send_user_quota(redis, user_id)
    except Exception as exc:
        log.warning("reset send quota accounting failed ip=%s err=%r", ip, exc)
    try:
        await audit.write(
            event_type="password_reset_requested", actor_user_id=None,
            request_ip=ip, user_agent=user_agent, auth_method="anonymous",
            details={"ok": True, "user_id": str(user_id), "email_masked": email_masked},
        )
    except Exception as exc:
        log.warning("audit password_reset_requested(ok) failed: %r", exc)
    return {"status": "sent"}


async def _send_definite_failure(
    db: AsyncSession, *, audit: AuditService, ip: str, user_agent: str | None,
    user_id: uuid.UUID, email_masked: str | None, token_id: uuid.UUID,
) -> None:
    """确定失败(未发出):只删本次新行(旧行保留,之前的链接仍可用)+ 502。"""
    try:
        await delete_token_row(db, token_id)
    except Exception as exc:
        log.warning("delete failed-issue reset token row failed: %r", exc)
    await audit.write(
        event_type="password_reset_requested", actor_user_id=None,
        request_ip=ip, user_agent=user_agent, auth_method="anonymous",
        details={
            "ok": False, "user_id": str(user_id),
            "email_masked": email_masked, "reason": "smtp_failed",
        },
    )
    raise HTTPException(502, "邮件发送失败,请稍后重试")


async def _send_unknown(
    db: AsyncSession, *, audit: AuditService, ip: str,
    user_agent: str | None, user_id: uuid.UUID, email_masked: str | None,
    new_id: uuid.UUID,
) -> None:
    """结果未知(超时,可能已发):保留新行 + 最近一条旧行(≤2)+ 502。"""
    try:
        await keep_recent_two(db, user_id=user_id, new_id=new_id)
    except Exception as exc:
        log.warning("keep-recent-two reset tokens failed user=%s err=%r", user_id, exc)
    await audit.write(
        event_type="password_reset_requested", actor_user_id=None,
        request_ip=ip, user_agent=user_agent, auth_method="anonymous",
        details={
            "ok": False, "user_id": str(user_id),
            "email_masked": email_masked, "reason": "smtp_timeout",
        },
    )
    raise HTTPException(
        502, "邮件发送结果未知,请稍后检查邮箱;若未收到可重新申请",
    )


async def _confirm_budget_check(redis: Any, settings: Settings, ip: str) -> None:
    """verify/confirm 共用每 IP 计数:进入时 INCR,>150/h → 429 + Retry-After。"""
    if await incr_confirm_budget(redis, ip) > settings.password_reset_hourly_confirm_per_ip:
        raise HTTPException(
            429, "操作过于频繁,请稍后再试",
            headers=retry_after_headers(await ttl_seconds(redis, confirm_ip_key(ip))),
        )


async def verify_reset(
    *,
    db: AsyncSession,
    redis: Any,
    settings: Settings,
    audit: AuditService,
    token: str,
    ip: str,
    user_agent: str | None,
) -> dict[str, str | bool]:
    """verify(只读不消费):重置页先行展示脱敏邮箱(§5.4.3)。"""
    await _confirm_budget_check(redis, settings, ip)
    try:
        row, user = await load_valid_token(db, token)
    except ResetTokenInvalid as exc:
        await audit.write(
            event_type="password_reset_failed", actor_user_id=None,
            request_ip=ip, user_agent=user_agent, auth_method="anonymous",
            details={"reason": exc.reason},
        )
        raise HTTPException(400, exc.detail) from exc
    return {
        "valid": True,
        "email_masked": mask_email(user.email) or "",
        "expires_at": _as_utc(row.expires_at).isoformat(),
    }


async def confirm_reset(
    *,
    db: AsyncSession,
    redis: Any,
    settings: Settings,
    local_auth: LocalAuthService,
    audit: AuditService,
    token: str,
    new_password: str,
    ip: str,
    user_agent: str | None,
) -> dict[str, str]:
    """confirm(§5.4.4 的 9 步):原子消费 + 改密 + 踢会话 + 吊销 PAT + 解锁。"""
    # 2. verify/confirm 共用每 IP 计数
    await _confirm_budget_check(redis, settings, ip)
    # 3. 密码策略
    policy_error = local_auth.validate_password_policy(new_password)
    if policy_error is not None:
        await audit.write(
            event_type="password_reset_failed", actor_user_id=None,
            request_ip=ip, user_agent=user_agent, auth_method="anonymous",
            details={"reason": "password_policy"},
        )
        raise HTTPException(400, policy_error)
    # 4/5. token 基础校验(同 verify)+ 用户态
    try:
        token_row, user = await load_valid_token(db, token)
    except ResetTokenInvalid as exc:
        await audit.write(
            event_type="password_reset_failed", actor_user_id=None,
            request_ip=ip, user_agent=user_agent, auth_method="anonymous",
            details={"reason": exc.reason},
        )
        raise HTTPException(400, exc.detail) from exc
    # 5b. 同密码比较;password_hash None → 允许首次设密(D4,跳过比较)
    if (
        user.password_hash is not None
        and local_auth.verify_password(new_password, user.password_hash)
    ):
        await audit.write(
            event_type="password_reset_failed", actor_user_id=None,
            request_ip=ip, user_agent=user_agent, auth_method="anonymous",
            details={"reason": "same_password", "email_masked": mask_email(user.email)},
        )
        raise HTTPException(400, "新密码不能与原密码相同")
    # 6. 同一事务:原子消费 + 改密 + verified_at + session_version + PAT + 删 token
    try:
        revoked = await consume_token_and_reset_password(
            db, token_row=token_row, user=user,
            new_password_hash=local_auth.hash_password(new_password),
        )
    except ResetTokenInvalid as exc:
        await audit.write(
            event_type="password_reset_failed", actor_user_id=None,
            request_ip=ip, user_agent=user_agent, auth_method="anonymous",
            details={"reason": exc.reason, "email_masked": mask_email(user.email)},
        )
        raise HTTPException(400, exc.detail) from exc
    # 7. 审计(commit 之后 try/except —— 重置已生效,审计失败不能把成功变成 500)
    try:
        await audit.write(
            event_type="password_reset_completed", actor_user_id=None,
            request_ip=ip, user_agent=user_agent, auth_method="anonymous",
            details={"user_id": str(user.id), "email_masked": mask_email(user.email)},
        )
        for ref in revoked:
            await audit.write(
                event_type="token_revoked", actor_user_id=None,
                request_ip=ip, user_agent=user_agent, auth_method="anonymous",
                details={
                    "user_id": str(user.id), "token_id": str(ref.id),
                    "token_prefix": ref.token_prefix,
                    "reason": "password_reset", "actor": "anonymous",
                },
            )
    except Exception as exc:
        log.warning("audit password_reset_completed failed: %r", exc)
    # 8. 解锁:只清 user 维度 username/email 两形态(include_name=False 绝不
    # 清 name 形态与 IP 锁)+ 清邮箱操作失败锁/计数 + DEL 验证码;全部 best-effort
    try:
        await local_auth.clear_locks(user, include_name=False)
        await post_password_change_cleanup(redis, user.id)
    except Exception as exc:
        log.warning("pwreset confirm unlock/cleanup failed user=%s err=%r", user.id, exc)
    log.info("password reset completed user_id=%s tokens_revoked=%d", user.id, len(revoked))
    # 9. 返回
    return {"status": "ok"}
