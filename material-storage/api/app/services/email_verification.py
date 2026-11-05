"""邮箱验证码业务逻辑(方案 §5.3)— 绑定 / 验证 / 换绑 / 解绑状态机。

无状态模块函数(与 notifications.py 同风格):db / redis / settings 由 router
从 ``get_db`` / ``request.app.state.redis`` / ``get_settings()`` 注入;不发
HTTP 请求、不碰 app.state。§5.3.2/§5.3.3/§5.3.4 的**步骤顺序**在 router
(``routers/account_security.py``)里钉死,本模块提供每一步的原语。

Redis 键(§5.7.1):
    email:code:{user_id}                      hash,600s:code_hash/email/purpose/
                                              current_email_hash/attempts
    email:code:cooldown:{user_id}             重发冷却(SET NX 占位)
    email:code:quota:{user_id}:{yyyymmdd}     每用户每日 10 条(到当日 24:00,UTC+8)
    email:code:req:user:{user_id}:{epoch_hour}  每用户每小时 30 次请求预算
    email:code:ip:{ip}:{epoch_hour}           每 IP 每小时 200 条
    email:chg:fail:user:{user_id}             密码错误计数(code/unbind 共用)
    email:chg:lock:user:{user_id}             密码错误锁(5 次)

安全口径:
- 验证码只存 HMAC-SHA256 哈希(key 由 HKDF 从 ``session_jwt_secret`` 派生
  ``info=b"email-code"`` 的专用 key,§5.3.3 第 4 步建议项)—— Redis 泄露时
  6 位码不能离线穷举;比对用 ``hmac.compare_digest``。
- ``current_email_hash = sha256(email_fingerprint(user.email))``:confirm 时
  兜住「发码后管理员改邮箱/解绑」的窗口(§5.3.3 第 5 步)。
- 错误尝试计数用 Lua 原子 ``HINCRBY`` + 仅 ``TTL < 0`` 补 ``EXPIRE``(不续期,
  否则有效期会从「签发起 10 分钟」漂成「最后一次错误起 10 分钟」);key 过期
  竞态返回 missing,不造只含 attempts 的永久 hash(§5.3.3 第 4 步)。
- 写库(绑定/换绑/解绑)单事务;换绑/绑定且邮箱值实际变化时作废未用重置
  token(D13);IntegrityError → 409 不 500(竞态窗口由唯一索引兜底)。
"""
from __future__ import annotations

import hashlib
import hmac
import logging
import secrets
import uuid
from datetime import UTC, datetime, timedelta, timezone
from functools import lru_cache
from typing import Any, Literal

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from fastapi import HTTPException
from sqlalchemy import delete, func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.tables import PasswordResetToken, User
from app.services.audit import AuditService
from app.services.email_utils import email_fingerprint, has_non_email_login, mask_email
from app.services.mailer import send_mail
from app.services.rate_limit import (
    RateLimitUnavailable,
    delete_keys,
    epoch_hour,
    get_int,
    incr_with_ttl,
    set_ex,
    set_nx_ex,
    ttl_seconds,
)
from app.settings import Settings

log = logging.getLogger(__name__)

# 每日配额的日界:UTC+8 固定偏移(中国无夏令时)。不要 ZoneInfo("Asia/Shanghai")
# —— python:3.12-slim 未装 tzdata,会抛 ZoneInfoNotFoundNotFoundError(§5.7.4)。
CN_TZ = timezone(timedelta(hours=8))

Purpose = Literal["bind", "verify", "change"]

# ─── Redis 键(§5.7.1)────────────────────────────────────────────────────────


def code_key(user_id: uuid.UUID | str) -> str:
    return f"email:code:{user_id}"


def cooldown_key(user_id: uuid.UUID | str) -> str:
    return f"email:code:cooldown:{user_id}"


def daily_quota_key(user_id: uuid.UUID | str, now: datetime | None = None) -> str:
    n = now or datetime.now(CN_TZ)
    return f"email:code:quota:{user_id}:{n.strftime('%Y%m%d')}"


def req_budget_key(user_id: uuid.UUID | str, hour: int | None = None) -> str:
    return f"email:code:req:user:{user_id}:{hour if hour is not None else epoch_hour()}"


def ip_quota_key(ip: str, hour: int | None = None) -> str:
    return f"email:code:ip:{ip}:{hour if hour is not None else epoch_hour()}"


def password_fail_key(user_id: uuid.UUID | str) -> str:
    return f"email:chg:fail:user:{user_id}"


def password_lock_key(user_id: uuid.UUID | str) -> str:
    return f"email:chg:lock:user:{user_id}"


def seconds_until_cn_midnight(now: datetime | None = None) -> int:
    """距当日 24:00(UTC+8)的秒数(每日配额 TTL,§5.3.2 第 9 步)。"""
    n = now or datetime.now(CN_TZ)
    tomorrow = (n + timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
    return max(1, int((tomorrow - n).total_seconds()))


# ─── 验证码生成 / HMAC(§5.3.2 第 11 步、§5.3.3 第 4 步)───────────────────────


def generate_code() -> str:
    """6 位数字码(``secrets.randbelow(1_000_000):06d``,§5.3.2 第 11 步)。"""
    return f"{secrets.randbelow(1_000_000):06d}"


@lru_cache(maxsize=8)
def _derive_code_key(secret: str) -> bytes:
    """HKDF(SHA256, info=b"email-code") 从 session_jwt_secret 派生专用 key。

    与 session JWT 签名、重置 token 哈希的密钥用途隔离;派生结果进程内缓存
    (secret 进程常量,重复派生只是浪费)。
    """
    return HKDF(
        algorithm=hashes.SHA256(), length=32, salt=None, info=b"email-code",
    ).derive(secret.encode())


def compute_code_hash(secret: str, user_id: uuid.UUID | str, code: str) -> str:
    """``HMAC-SHA256(hkdf(secret), f"{user_id}:{code}")`` 十六进制 —— 只存哈希。"""
    key = _derive_code_key(secret)
    return hmac.new(key, f"{user_id}:{code}".encode(), hashlib.sha256).hexdigest()


def current_email_hash(user_email: str | None) -> str:
    """``sha256(email_fingerprint(user.email))`` —— 发码时刻的用户邮箱快照。"""
    return hashlib.sha256(email_fingerprint(user_email).encode()).hexdigest()


def verify_code(secret: str, user_id: uuid.UUID | str, code: str, code_hash: str) -> bool:
    """恒时比对(``hmac.compare_digest``);secret/user_id/code 与签发时一致才通过。"""
    return hmac.compare_digest(compute_code_hash(secret, user_id, code), code_hash)


# ─── 验证码 hash 的原子读写(§5.3.2 第 13 步 / §5.3.3 第 2-4 步)───────────────

# 发送成功/结果未知后写入:整 hash 一次定档(覆盖旧码)+ EXPIRE,单 Lua 原子
_STORE_CODE_LUA = """
redis.call('HSET', KEYS[1],
  'code_hash', ARGV[1], 'email', ARGV[2], 'purpose', ARGV[3],
  'current_email_hash', ARGV[4], 'attempts', 0)
redis.call('EXPIRE', KEYS[1], tonumber(ARGV[5]))
return 1
"""

# 错误尝试计数:key 不存在返回 'missing'(按「请先获取验证码」,不造只含
# attempts 的永久 hash);HINCRBY 后仅 TTL<0 才补 EXPIRE —— 错误尝试不续期
_ATTEMPT_INCR_LUA = """
if redis.call('EXISTS', KEYS[1]) == 0 then
  return 'missing'
end
local n = redis.call('HINCRBY', KEYS[1], 'attempts', 1)
if redis.call('TTL', KEYS[1]) < 0 then
  redis.call('EXPIRE', KEYS[1], tonumber(ARGV[1]))
end
return n
"""


async def _eval(redis: Any, script: str, numkeys: int, *args: Any) -> Any:
    try:
        return await redis.eval(script, numkeys, *args)
    except Exception as exc:  # Redis 故障 fail-closed(§5.7.2)
        raise RateLimitUnavailable(f"email code redis eval failed: {exc!r}") from exc


async def store_code(
    redis: Any,
    *,
    ttl_seconds: int,
    user_id: uuid.UUID,
    code_hash: str,
    email: str,
    purpose: Purpose,
    cur_email_hash: str,
) -> None:
    """发送成功/结果未知后写验证码 hash(覆盖旧码,TTL 重新定档,§5.3.2 第 13 步)。

    确定失败**不要**调用本函数 —— 旧码继续有效,不能被一次失败覆盖作废。
    Redis 写失败抛 ``RateLimitUnavailable``(邮件已发出:调用方 503,不 200)。
    """
    await _eval(
        redis, _STORE_CODE_LUA, 1, code_key(user_id),
        code_hash, email, purpose, cur_email_hash, int(ttl_seconds),
    )


class StoredCode:
    """Redis 里待确认的验证码(hash 读出的快照)。"""

    __slots__ = ("attempts", "code_hash", "current_email_hash", "email", "purpose")

    def __init__(
        self,
        *,
        code_hash: str,
        email: str,
        purpose: str,
        current_email_hash: str,
        attempts: int,
    ) -> None:
        self.code_hash = code_hash
        self.email = email
        self.purpose = purpose
        self.current_email_hash = current_email_hash
        self.attempts = attempts


async def read_stored_code(redis: Any, user_id: uuid.UUID) -> StoredCode | None:
    """读 ``email:code:{id}``;缺键或缺 ``code_hash`` 字段 → None(按「请先获取验证码」)。

    ``code_hash`` 字段存在性先行:Lua 自增若在 key 过期后造出只含 attempts
    的 hash,缺字段按 missing 处理,而不是「验证码错误」(§5.3.3 第 4 步)。
    """
    try:
        data: dict[str, str] = await redis.hgetall(code_key(user_id))
    except Exception as exc:
        raise RateLimitUnavailable(f"email code redis hgetall failed: {exc!r}") from exc
    if not data or "code_hash" not in data:
        return None
    try:
        attempts = int(data.get("attempts", 0))
    except (TypeError, ValueError):
        attempts = 0
    return StoredCode(
        code_hash=data["code_hash"],
        email=data.get("email", ""),
        purpose=data.get("purpose", ""),
        current_email_hash=data.get("current_email_hash", ""),
        attempts=attempts,
    )


async def register_wrong_attempt(redis: Any, *, ttl_seconds: int, user_id: uuid.UUID) -> int | None:
    """验证码比对失败:原子 ``HINCRBY attempts``(+仅 TTL<0 补 EXPIRE,不续期)。

    返回自增后的次数;key 恰好过期 → None(调用方按「请先获取验证码」400,
    不要再造 key)。达到上限的删 key 由调用方做(§5.3.3 第 3/4 步)。
    """
    result = await _eval(redis, _ATTEMPT_INCR_LUA, 1, code_key(user_id), int(ttl_seconds))
    if result == "missing" or result is None:
        return None
    return int(result)


async def delete_code(redis: Any, user_id: uuid.UUID) -> None:
    """作废验证码(确认成功 / 邮箱变更兜底 / attempts 打满 / 解绑)。"""
    await delete_keys(redis, code_key(user_id))


# ─── 密码失败锁(§5.3.2 第 3-4 步,code/unbind 共用)─────────────────────────


async def password_lock_ttl(redis: Any, user_id: uuid.UUID) -> int:
    """密码错误锁剩余秒数;未锁返回 0(锁着的 429 文案与 Retry-After 用)。"""
    try:
        locked = await redis.get(password_lock_key(user_id))
    except Exception as exc:
        raise RateLimitUnavailable(f"email chg lock redis get failed: {exc!r}") from exc
    if not locked:
        return 0
    return max(1, await ttl_seconds(redis, password_lock_key(user_id)))


async def record_password_failure(
    redis: Any, *, max_failures: int, lock_seconds: int, user_id: uuid.UUID,
) -> int:
    """密码错误:INCR 失败计数(首次 EXPIRE = 锁时长);达到上限写锁。返回当前次数。

    计数与锁共用 ``EMAIL_CHANGE_PASSWORD_LOCK_SECONDS`` TTL(§5.7.1);计数本身
    不因达到上限清零(锁在,计数到点自然过期)。
    """
    count = await incr_with_ttl(redis, password_fail_key(user_id), lock_seconds)
    if count >= max_failures:
        await set_ex(redis, password_lock_key(user_id), "1", lock_seconds)
    return count


async def clear_password_failures(redis: Any, user_id: uuid.UUID) -> None:
    """密码校验通过后清失败计数与锁(§5.3.2 第 4 步「正确」分支)。"""
    await delete_keys(redis, password_fail_key(user_id), password_lock_key(user_id))


# ─── 占用检查(§5.3.2 第 7 步 / §5.3.3 第 5 步)───────────────────────────────


async def email_taken_by_other(
    db: AsyncSession, email: str, *, exclude_id: uuid.UUID | None,
) -> bool:
    """``lower(email)`` 已属他人(排除本人;新建时 exclude_id=None)。limit(1) 只答「是否被占」。"""
    stmt = select(User.id).where(func.lower(User.email) == email).limit(1)
    if exclude_id is not None:
        stmt = stmt.where(User.id != exclude_id)
    return (await db.execute(stmt)).first() is not None


async def username_cross_conflict(
    db: AsyncSession, email: str, *, exclude_id: uuid.UUID | None,
) -> bool:
    """跨列冲突:``lower(username) == email`` 且属他人。

    登录匹配 username 优先(local_auth),不拦会让「用邮箱登录」命中别人的
    username;排除本人兼容「username 本身是邮箱」的历史账号(§5.3.2 第 7 步)。
    """
    stmt = select(User.id).where(func.lower(User.username) == email).limit(1)
    if exclude_id is not None:
        stmt = stmt.where(User.id != exclude_id)
    return (await db.execute(stmt)).first() is not None


# ─── purpose 判定(§5.3.2 第 6 步)────────────────────────────────────────────


def determine_purpose(*, current_email: str | None, target: str) -> Purpose:
    """目标邮箱 → 三态:当前为空=bind / 目标==当前=verify / 其余=change。"""
    if not current_email:
        return "bind"
    if email_fingerprint(current_email) == target:
        return "verify"
    return "change"


# ─── 配额原语(§5.3.2 第 4/8/9 步;读侧先查、发送成功后才 INCR)──────────────


async def incr_request_budget(redis: Any, user_id: uuid.UUID) -> int:
    """每用户每小时请求预算:**密码校验通过后**原子 INCR(含 409 占用尝试,防枚举)。

    返回自增后计数(>budget → 429 由调用方判);此函数自身不判额度 —— 需要
    「只读不占」语义的调用方用 rate_limit.get_int。
    """
    return await incr_with_ttl(redis, req_budget_key(user_id), 3600)


async def read_ip_quota(redis: Any, ip: str) -> int:
    """每 IP 每小时验证码配额读侧(≥上限 → 429;发送成功后才 INCR)。"""
    return await get_int(redis, ip_quota_key(ip))


async def req_budget_ttl(redis: Any, user_id: uuid.UUID) -> int:
    """请求预算键剩余秒数(429 的 Retry-After 用)。"""
    return await ttl_seconds(redis, req_budget_key(user_id))


async def incr_ip_quota(redis: Any, ip: str) -> int:
    """发送成功后 INCR 每 IP 配额(首次 EXPIRE 3600s)。"""
    return await incr_with_ttl(redis, ip_quota_key(ip), 3600)


async def read_daily_quota(redis: Any, user_id: uuid.UUID) -> int:
    """每用户每日配额读侧(≥上限 → 429,**先查日配额再占冷却**,§5.3.2 第 9 步)。"""
    return await get_int(redis, daily_quota_key(user_id))


async def incr_daily_quota(redis: Any, user_id: uuid.UUID) -> int:
    """发送成功后 INCR 每日配额(首次 EXPIRE 到当日 24:00,UTC+8)。"""
    return await incr_with_ttl(redis, daily_quota_key(user_id), seconds_until_cn_midnight())


async def acquire_cooldown(redis: Any, *, resend_seconds: int, user_id: uuid.UUID) -> bool:
    """重发冷却 ``SET NX EX``:原子占位只此一次,不续期(§5.3.2 第 10 步)。"""
    return await set_nx_ex(redis, cooldown_key(user_id), "1", resend_seconds)


async def cooldown_ttl(redis: Any, user_id: uuid.UUID) -> int:
    """冷却剩余秒数(429 的 Retry-After)。"""
    return max(1, await ttl_seconds(redis, cooldown_key(user_id)))


# ─── 写库:绑定/换绑(§5.3.3 第 6 步)/ 解绑(§5.3.4 第 3-5 步)──────────────


async def write_audit_quiet(audit: AuditService, **kwargs: Any) -> None:
    """邮箱事件审计统一 best-effort(§5.9:审计失败不能把「邮件已发/绑定已成功」变 500)。"""
    try:
        await audit.write(**kwargs)
    except Exception:
        log.warning("audit write failed: event=%s", kwargs.get("event_type"), exc_info=True)


async def send_mail_quiet(settings: Settings, *, to: str, subject: str, body: str) -> None:
    """告知邮件 BackgroundTasks 体(§5.6.3):失败只 log,best-effort 不影响主流程。"""
    try:
        await send_mail(settings, to=to, subject=subject, body=body)
    except Exception:
        log.warning("notify mail failed (best-effort): to=%s subject=%r",
                    mask_email(to), subject, exc_info=True)


def code_mail_body(settings: Settings, code: str) -> str:
    """验证码正文(§5.6.2 纯文本;分钟数动态读配置,运维改 TTL 不用改文案)。"""
    return (
        f"你的验证码是 {code},{settings.email_code_ttl_seconds // 60} 分钟内有效。"
        "用于绑定/更换/验证邮箱。若非本人操作请忽略。"
    )


async def delete_unused_reset_tokens(db: AsyncSession, user_id: uuid.UUID) -> None:
    """作废该用户全部**未用**重置 token(必须在同一事务、commit 之前,D13)。

    管理员改邮箱 / 禁用、OIDC 同步改邮箱、绑定/换绑/解绑、改密/重置等全部
    「邮箱或密码状态变化」的写点共用(§5.3.5 / §5.4.4 / D13)。
    """
    await db.execute(
        delete(PasswordResetToken).where(
            PasswordResetToken.user_id == user_id,
            PasswordResetToken.used_at.is_(None),
        )
    )


async def apply_confirm(
    db: AsyncSession, user: User, stored: StoredCode,
) -> tuple[str | None, bool, Purpose]:
    """confirm 写库(单事务):落邮箱 + 置已验证 + (值变化时)作废未用重置 token。

    **先快照** old_email / old_verified 再赋值(第 8/9 步的告知与审计要用)。
    换绑/绑定且 ``(old_email or '').strip().lower() != target``(大小写-only
    归一化不算变化)才删 token —— verify 不改邮箱值,保留用户手里的重置链接。

    返回 ``(old_email, old_verified, action)``;并发抢占撞 lower(email) 唯一
    索引 → rollback + 409(不 500;调用方负责删 Redis key 与审计)。
    """
    old_email = user.email
    old_verified = user.email_verified_at is not None
    target = stored.email
    if stored.purpose == "change":
        action: Purpose = "change"
    elif stored.purpose == "bind":
        action = "bind"
    else:
        action = "verify"
    user.email = target
    user.email_verified_at = datetime.now(UTC)
    try:
        # 删 token 的 execute 会 autoflush 上面两条 UPDATE —— 并发抢占在这里
        # 撞 lower(email) 唯一索引与在 commit 撞等价,一并按 409 收口
        if stored.purpose in ("bind", "change") and email_fingerprint(old_email) != target:
            await delete_unused_reset_tokens(db, user.id)
        await db.commit()
    except IntegrityError as exc:
        await db.rollback()
        # ⚠️ rollback 把实例属性过期:AsyncSession 下直接读属性触发同步懒加载 →
        # MissingGreenlet(services/auth.py 同款坑),必须先 refresh 回到库内当前态
        await db.refresh(user)
        raise HTTPException(
            409, "该邮箱已被其他账号使用;如该邮箱属于你,请联系管理员解除其它账号的占用",
        ) from exc
    return old_email, old_verified, action


async def apply_unbind(
    db: AsyncSession, user: User, *, oidc_enabled: bool,
) -> tuple[str, bool]:
    """unbind 前置校验 + 写库:无邮箱 → 400;无可用登录方式 → 400;清空 + 删未用 token。

    ``oidc_enabled`` 由 router 从 ``request.app.state.auth.enabled`` 注入
    (§5.3.4 第 4 步,不要在本模块重算)。返回 ``(old_email, old_verified)``
    快照(告知邮件与审计用;email 已清空,快照必须在清空前取)。**DEL
    ``email:code`` 由调用方在 commit 后做**(Redis 与 DB 不在一个事务里)。
    """
    if user.email is None:
        raise HTTPException(400, "当前未绑定邮箱")
    if not has_non_email_login(user, oidc_enabled):
        raise HTTPException(
            400, "当前账号没有独立登录名,解除邮箱后将无法登录;请联系管理员先设置登录名",
        )
    old_email = user.email
    old_verified = user.email_verified_at is not None
    user.email = None
    user.email_verified_at = None
    await delete_unused_reset_tokens(db, user.id)
    await db.commit()
    return old_email, old_verified
