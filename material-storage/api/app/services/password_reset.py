"""邮箱找回密码 — 原语层(方案 §5.4/§5.5):token 签发 / 校验 / 原子消费 + 共享清理。

无状态模块函数(与 email_verification.py 同风格):db / redis / settings /
audit 由 router 注入。§5.4.2(申请 14 步)/ §5.4.3(verify)/ §5.4.4(confirm
9 步)的完整流程在 ``password_reset_flows.py``(单文件 500 行上限拆分;本文件
保留可被五个密码写点与 B2 邮箱模块复用的原语:键名 / 预算与冷却 / token 落库
与三态删行 / 原子消费 / 改密后清理 / 邮件正文)。

Redis 键(§5.7.1):
    pwreset:fail:ip:{ip}                     申请失败计数(不存在/停用;成功清零)
    pwreset:lock:ip:{ip}                     R8:IP 封控(5 次失败;**只锁 reset 端点**)
    pwreset:req:ip:{ip}:{epoch_hour}         每 IP 每小时申请预算(查库前原子 INCR)
    pwreset:send:ip:{ip}:{epoch_hour}        每 IP 每小时发信(先读;发送成功才 INCR)
    pwreset:send:user:{user_id}:{epoch_hour} 每账号每小时发信(先读;成功才 INCR)
    pwreset:cooldown:user:{user_id}          重置邮件冷却(SET NX 占位,只此一次)
    pwreset:confirm:ip:{ip}:{epoch_hour}     verify/confirm 共用每 IP 计数(进入时 INCR)

安全口径:
- token 明文 ``secrets.token_urlsafe(32)``(43 字符);落库只存 sha256 hex
  (复用 tokens.hash_token 唯一口径);30 分钟过期;并发双花靠 confirm 的
  ``UPDATE ... WHERE used_at IS NULL ... RETURNING`` 原子收口。
- 签发前事务级 ``pg_advisory_xact_lock(hashtext('pwreset:user:<uid>'))``
  (与 tokens.py 同款;SQLite 测试按方言跳过)。
- ``email_hash = sha256(email_fingerprint(email))`` 快照:verify/confirm 与当前
  邮箱指纹比对,兜住「签发后换绑/解绑」的窗口(D13 不依赖删除时机)。
- SMTP 三态删行策略(§5.4.2 第 13 步):成功删旧行 / 确定失败只删本次新行 /
  结果未知保留新行 + 最近一条旧行(≤2 条)。
"""
from __future__ import annotations

import hashlib
import logging
import secrets
import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

from sqlalchemy import delete, select, text, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.tables import PasswordResetToken, User
from app.services.email_utils import email_fingerprint
from app.services.email_verification import clear_password_failures, delete_code
from app.services.rate_limit import (
    RateLimitUnavailable,
    epoch_hour,
    get_int,
    incr_with_ttl,
    set_ex,
    set_nx_ex,
    ttl_seconds,
)
from app.services.tokens import TokenRef, hash_token, revoke_user_tokens
from app.settings import Settings

log = logging.getLogger(__name__)


# ─── Redis 键(§5.7.1)────────────────────────────────────────────────────────


def fail_ip_key(ip: str) -> str:
    return f"pwreset:fail:ip:{ip}"


def lock_ip_key(ip: str) -> str:
    return f"pwreset:lock:ip:{ip}"


def req_budget_key(ip: str, hour: int | None = None) -> str:
    return f"pwreset:req:ip:{ip}:{hour if hour is not None else epoch_hour()}"


def send_ip_key(ip: str, hour: int | None = None) -> str:
    return f"pwreset:send:ip:{ip}:{hour if hour is not None else epoch_hour()}"


def send_user_key(user_id: uuid.UUID | str, hour: int | None = None) -> str:
    return f"pwreset:send:user:{user_id}:{hour if hour is not None else epoch_hour()}"


def cooldown_key(user_id: uuid.UUID | str) -> str:
    return f"pwreset:cooldown:user:{user_id}"


def confirm_ip_key(ip: str, hour: int | None = None) -> str:
    return f"pwreset:confirm:ip:{ip}:{hour if hour is not None else epoch_hour()}"


class ResetTokenInvalid(Exception):
    """token 无校验失败(verify/confirm 同一套校验,§5.4.3)。

    reason ∈ bad_token / used_token / expired_token / inactive / email_changed,
    落审计 ``password_reset_failed``;detail 是给用户的 400 文案(统一口径,
    不泄露「具体是哪一种失效」之外的账号信息)。
    """

    def __init__(self, reason: str, detail: str = "链接已失效,请重新申请") -> None:
        super().__init__(reason)
        self.reason = reason
        self.detail = detail


def _utcnow() -> datetime:
    return datetime.now(UTC)


def _as_utc(value: datetime | None) -> datetime:
    """SQLite 读回的 naive datetime 一律按 UTC 补 tzinfo(与 PG 口径对齐)。"""
    if value is None:
        return _utcnow()
    if value.tzinfo is None:
        return value.replace(tzinfo=UTC)
    return value


def email_hash_of(user_email: str | None) -> str:
    """``sha256(email_fingerprint(email))`` —— email_hash 快照/比对同口径。"""
    return hashlib.sha256(email_fingerprint(user_email).encode()).hexdigest()


def generate_raw_token() -> str:
    """43 字符明文 token(§5.4.2 第 10 步);只出现在邮件正文,不落库不写日志。"""
    return secrets.token_urlsafe(32)


def _unavailable(exc: Exception) -> Exception:
    return RateLimitUnavailable(f"pwreset redis failed: {exc!r}")


def retry_after_headers(seconds: int) -> dict[str, str]:
    """429 统一 ``Retry-After`` 头(§5.7.4;Web/App 按它倒计时,不解析文案)。"""
    return {"Retry-After": str(max(1, seconds))}


# ─── IP 封控 / 预算 / 配额 / 冷却原语(§5.4.2 第 3-9 步)───────────────────────


async def ip_locked(redis: Any, ip: str) -> bool:
    try:
        return await redis.get(lock_ip_key(ip)) is not None
    except Exception as exc:
        raise _unavailable(exc) from exc


async def ip_lock_ttl(redis: Any, ip: str) -> int:
    return max(1, await ttl_seconds(redis, lock_ip_key(ip)))


async def record_ip_failure(
    redis: Any, *, max_failures: int, lock_seconds: int, ip: str,
) -> bool:
    """不存在/停用:INCR 失败计数(首次 EXPIRE=锁时长);≥max 写 IP 锁。

    返回本次是否触发锁(触发时调用方补一条 ``reason=ip_locked`` 审计,
    §5.4.2 第 6 步)。格式错误/冷却拒绝/SMTP 失败**不走这里**(只记真正失败)。
    """
    count = await incr_with_ttl(redis, fail_ip_key(ip), lock_seconds)
    if count >= max_failures:
        await set_ex(redis, lock_ip_key(ip), "1", lock_seconds)
        return True
    return False


async def incr_request_budget(redis: Any, ip: str) -> int:
    """请求预算:**原子自增后检查**(不是先读后写,防并发超限);超限由调用方判。"""
    return await incr_with_ttl(redis, req_budget_key(ip), 3600)


async def read_send_ip_quota(redis: Any, ip: str) -> int:
    return await get_int(redis, send_ip_key(ip))


async def read_send_user_quota(redis: Any, user_id: uuid.UUID) -> int:
    return await get_int(redis, send_user_key(user_id))


async def incr_send_ip_quota(redis: Any, ip: str) -> int:
    return await incr_with_ttl(redis, send_ip_key(ip), 3600)


async def incr_send_user_quota(redis: Any, user_id: uuid.UUID) -> int:
    return await incr_with_ttl(redis, send_user_key(user_id), 3600)


async def acquire_cooldown(
    redis: Any, *, cooldown_seconds: int, user_id: uuid.UUID,
) -> bool:
    """冷却 ``SET NX EX``:原子占位只此一次、不续期(§5.4.2 第 9 步)。"""
    return await set_nx_ex(redis, cooldown_key(user_id), "1", cooldown_seconds)


async def cooldown_ttl(redis: Any, user_id: uuid.UUID) -> int:
    return max(1, await ttl_seconds(redis, cooldown_key(user_id)))


async def incr_confirm_budget(redis: Any, ip: str) -> int:
    """verify/confirm 共用每 IP 计数:**每次进入时 INCR**(防拿 verify 当探测器)。"""
    return await incr_with_ttl(redis, confirm_ip_key(ip), 3600)


# ─── token 落库(§5.4.2 第 11 步)/ 三态删行(第 13 步)────────────────────────


async def _acquire_advisory_lock(db: AsyncSession, user_id: uuid.UUID) -> None:
    """事务级 advisory lock(与 tokens.py 同款;SQLite 测试按方言跳过)。"""
    bind = db.bind
    if bind is not None and bind.dialect.name == "postgresql":
        await db.execute(
            text("SELECT pg_advisory_xact_lock(hashtext(:lock_key))"),
            {"lock_key": f"pwreset:user:{user_id}"},
        )


async def issue_token(
    db: AsyncSession,
    *,
    settings: Settings,
    user_id: uuid.UUID,
    user_email: str | None,
    request_ip: str,
    user_agent: str | None,
) -> tuple[str, uuid.UUID]:
    """advisory lock → 清 used/过期旧行 → 插新行 → commit;返回 (明文, 行 id)。

    **先不删未用旧行**(第 13 步按 SMTP 结果决定);冷却 SET NX 已保证 60s 内
    无并发插入,删旧行不需要依赖进程时钟比较 created_at。
    """
    await _acquire_advisory_lock(db, user_id)
    # synchronize_session=False:ORM 侧不做 WHERE 的 Python 求值(SQLite 读回的
    # naive datetime 与 aware 参数比较会 TypeError);used_at 以库为准
    await db.execute(
        delete(PasswordResetToken).where(
            PasswordResetToken.user_id == user_id,
            (PasswordResetToken.used_at.isnot(None))
            | (PasswordResetToken.expires_at <= _utcnow()),
        ).execution_options(synchronize_session=False)
    )
    raw = generate_raw_token()
    row = PasswordResetToken(
        user_id=user_id,
        token_hash=hash_token(raw),
        expires_at=_utcnow() + timedelta(seconds=settings.password_reset_token_ttl_seconds),
        email_hash=email_hash_of(user_email),
        request_ip=request_ip[:64] or None,
        user_agent=(user_agent or "")[:512] or None,
    )
    db.add(row)
    await db.commit()
    await db.refresh(row)
    return raw, row.id


async def delete_unused_tokens(db: AsyncSession, user_id: uuid.UUID) -> None:
    """删该用户全部**未用**重置 token(不 commit;调用方事务内,D13)。

    五个密码写点共用:change-password / 管理员重置 / password-reset confirm /
    set_password.py / set_initial_admin.py;B2 的邮箱换绑/解绑也走它。
    """
    await db.execute(
        delete(PasswordResetToken).where(
            PasswordResetToken.user_id == user_id,
            PasswordResetToken.used_at.is_(None),
        )
    )


async def delete_other_unused_tokens(
    db: AsyncSession, *, user_id: uuid.UUID, keep_id: uuid.UUID,
) -> None:
    """发送成功:删其它未用 token(保留本次新行);失败只 log 不改 200(§5.4.2 第 13 步)。"""
    await db.execute(
        delete(PasswordResetToken).where(
            PasswordResetToken.user_id == user_id,
            PasswordResetToken.used_at.is_(None),
            PasswordResetToken.id != keep_id,
        )
    )
    await db.commit()


async def delete_token_row(db: AsyncSession, token_id: uuid.UUID) -> None:
    """确定失败:只删**本次新行**(旧行保留,用户之前的链接仍可用)。"""
    await db.execute(
        delete(PasswordResetToken).where(PasswordResetToken.id == token_id)
    )
    await db.commit()


async def keep_recent_two(
    db: AsyncSession, *, user_id: uuid.UUID, new_id: uuid.UUID,
) -> None:
    """结果未知:保留新行 + 最近一条旧行(``created_at DESC, id DESC``,同微秒
    用 id 兜底),删除更早的未用行(仍 ≤2 条,§5.4.2 第 13 步)。"""
    rows = list((
        await db.execute(
            select(PasswordResetToken.id).where(
                PasswordResetToken.user_id == user_id,
                PasswordResetToken.used_at.is_(None),
                PasswordResetToken.id != new_id,
            ).order_by(
                PasswordResetToken.created_at.desc(),
                PasswordResetToken.id.desc(),
            )
        )
    ).scalars().all())
    older = rows[1:]
    if older:
        await db.execute(
            delete(PasswordResetToken).where(PasswordResetToken.id.in_(older))
        )
    await db.commit()


# ─── verify/confirm 共用校验(§5.4.3)────────────────────────────────────────


async def load_valid_token(
    db: AsyncSession, raw_token: str,
) -> tuple[PasswordResetToken, User]:
    """verify 与 confirm 用同一套校验(避免「页面显示正在为 old@x 重置、点确认
    却 400」):不存在/已用/过期/停用/email_hash 不一致 → ``ResetTokenInvalid``。

    只读,不消费 token;``user.email is None`` 必须先兜底(空值比对会 500,
    §5.4.4 第 5 步)。
    """
    row = (
        await db.execute(
            select(PasswordResetToken).where(
                PasswordResetToken.token_hash == hash_token(raw_token)
            )
        )
    ).scalar_one_or_none()
    if row is None:
        raise ResetTokenInvalid("bad_token")
    if row.used_at is not None:
        raise ResetTokenInvalid("used_token")
    if _as_utc(row.expires_at) <= _utcnow():
        raise ResetTokenInvalid("expired_token")
    user = await db.get(User, row.user_id)
    if user is None or not user.is_active:
        raise ResetTokenInvalid("inactive")
    if user.email is None or (row.email_hash or "") != email_hash_of(user.email):
        raise ResetTokenInvalid("email_changed", "邮箱已变更,链接已失效")
    return row, user


async def consume_token_and_reset_password(
    db: AsyncSession,
    *,
    token_row: PasswordResetToken,
    user: User,
    new_password_hash: str,
) -> list[TokenRef]:
    """confirm 第 6 步:**同一次 commit 之前**完成原子消费 + 改密 + 会话版本
    自增 + PAT 吊销 + 删其它未用 token(§5.4.4;拆开会有「token 已作废、密码
    未改」或「密码已改 PAT 仍有效」的黑洞窗口)。

    消费失败(0 行)抛 ``ResetTokenInvalid("used_token")``(并发双花只剩一笔)。
    """
    consumed = (
        await db.execute(
            update(PasswordResetToken)
            .where(
                PasswordResetToken.id == token_row.id,
                PasswordResetToken.used_at.is_(None),
                PasswordResetToken.expires_at > _utcnow(),
            )
            .values(used_at=_utcnow())
            .returning(PasswordResetToken.id)
            # 0 行 = 已被并发消费(原子收口);不做 ORM 侧 WHERE 求值
            # (SQLite naive/aware datetime 比较会 TypeError,与上面 delete 同因)
            .execution_options(synchronize_session=False)
        )
    ).first()
    if consumed is None:
        raise ResetTokenInvalid("used_token")
    user.password_hash = new_password_hash
    user.must_change_password = False
    # D4:重置链接即证明邮箱控制权 —— 未验证邮箱借此完成验证
    user.email_verified_at = _utcnow()
    # §5.5:踢掉全部旧会话(本人当前请求用的 JWT 也失效,下一次 401)
    user.session_version = (user.session_version or 0) + 1
    revoked = await revoke_user_tokens(db, user_id=user.id, reason="password_reset")
    await delete_unused_tokens(db, user.id)
    await db.commit()
    return revoked


# ─── 改密/重置后的 Redis 兜底清理(§5.5.1 第 5 步,五个密码写点共用)──────────


async def post_password_change_cleanup(
    redis: Any, user_id: uuid.UUID | str,
) -> None:
    """commit 之后 best-effort:DEL ``email:code:{uid}``(旧验证码不能继续用于
    换绑)+ 清 ``email:chg:fail/lock``(重置后邮箱操作不该仍被 15 分钟锁挡)。

    redis 为 None(CLI 未配置短连接)→ 跳过,验证码 600s TTL 自然过期;
    **不要**裸调用未连接的 ``Redis()``。Redis 抖动只 log.warning,不把
    「密码已改」变成 500。IP 维度锁**绝不在这里清**(§5.4.4 第 8 步)。
    """
    if redis is None:
        return
    uid = user_id if isinstance(user_id, uuid.UUID) else uuid.UUID(str(user_id))
    try:
        await delete_code(redis, uid)
        await clear_password_failures(redis, uid)
    except Exception as exc:
        log.warning("pwreset post-change redis cleanup failed user=%s err=%r", user_id, exc)


# ─── 邮件正文(§5.6.2)───────────────────────────────────────────────────────


def build_reset_links(settings: Settings, token: str) -> tuple[str, str | None]:
    """(公网, 可选内网)链接;base 必填不回落 web_app_base_url(D15)。"""
    main = f"{(settings.email_link_base_url or '').rstrip('/')}/reset-password#token={token}"
    lan = None
    if settings.email_link_base_url_lan:
        lan = (
            f"{settings.email_link_base_url_lan.rstrip('/')}"
            f"/reset-password#token={token}"
        )
    return main, lan


def build_reset_mail(settings: Settings, *, token: str) -> tuple[str, str]:
    """(subject, body);LAN 配置时正文同时给两条链接并标注公网/内网(§5.6.2)。"""
    ttl_minutes = settings.password_reset_token_ttl_seconds // 60
    main, lan = build_reset_links(settings, token)
    lines = [f"点击链接重置密码({ttl_minutes} 分钟内有效,仅可使用一次):"]
    if lan is not None:
        lines.append(f"公网访问:{main}")
        lines.append(f"内网访问:{lan}")
    else:
        lines.append(main)
    lines.append("若非本人操作请忽略;如担心账号安全请联系管理员。")
    return "【素材库】重置密码", "\n".join(lines)
