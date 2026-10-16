"""本地账号密码登录服务 — ADR-0007 身份自建(#149)。

职责:
  - argon2id 密码哈希(依赖 argon2-cffi,不用 passlib — 停维护)
  - 密码策略校验(最小长度 + 字母/数字)
  - 登录限流(Redis 计数,per IP + per username 双维度;失败 5 次锁 15min)
  - 管理员解锁(W1):clear_locks / clear_ip_locks 清三形态 user key 与 IP key,
    users_login_locked 供用户列表批量回显锁定状态
  - username 解析:不强制邮箱格式 — 拼音 / 工号友好;
    匹配优先级 username 精确 → email(含 @)→ name 兜底,全部忽略大小写;
    任一维度重复(如 name 重名)→ 拒绝登录

约定:
  - 服务实例挂 app.state.local_auth(main.py lifespan 构造,redis client 注入)
  - session JWT 复用 services/auth.py 的 encode_session,cookie 照抄 routers/auth.py
"""
from __future__ import annotations

import logging
import re
import uuid
from collections.abc import Iterable, Sequence
from dataclasses import dataclass

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerifyMismatchError
from redis.asyncio import Redis
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.tables import User
from app.settings import Settings

log = logging.getLogger(__name__)

# Redis key 前缀(#149 限流;与 arq queue / maintenance banner 命名空间隔离)
_FAIL_IP_KEY = "auth:fail:ip:{ip}"
_FAIL_USER_KEY = "auth:fail:user:{username}"
_LOCK_IP_KEY = "auth:lock:ip:{ip}"
_LOCK_USER_KEY = "auth:lock:user:{username}"


@dataclass
class ClearLocksResult:
    """clear_locks 结果(W1 解锁端点与 reset-password 共用的返回契约)。

    - forms:实际清到 key 的 lower() 形态(锁 key 或计数 key 任一命中);
      全部未命中时为空(= 本来就没锁,DEL 是幂等 no-op)
    - was_locked:任一形态的 ``auth:lock:user:*`` 锁 key 存在且被本次清除
      (unlock 响应的 was_locked / 审计 details 用;仅计数被清不算锁过)
    """

    forms: list[str]
    was_locked: bool

# 密码策略:字母与数字各至少一个(拼音/工号友好的同时保持基本强度)
_LETTER_RE = re.compile(r"[A-Za-z]")
_DIGIT_RE = re.compile(r"[0-9]")


class LocalAuthService:
    """密码哈希 + 登录限流。redis 由 lifespan 注入(app.state.redis)。"""

    def __init__(self, settings: Settings, redis: Redis):  # type: ignore[type-arg]
        self._settings = settings
        self._redis = redis
        # argon2id 默认参数(time_cost=3, memory_cost=65536, parallelism=4)
        self._hasher = PasswordHasher()

    # ─── 密码哈希 ─────────────────────────────────────────────────────────
    def hash_password(self, password: str) -> str:
        return self._hasher.hash(password)

    def verify_password(self, password: str, password_hash: str) -> bool:
        """校验密码;哈希非法(非 argon2 格式)记日志返回 False,不抛异常。"""
        try:
            return self._hasher.verify(password_hash, password)
        except VerifyMismatchError:
            return False
        except InvalidHashError:
            log.warning("invalid stored password hash(可能非 argon2 格式)")
            return False

    def validate_password_policy(self, password: str) -> str | None:
        """密码策略校验;返回错误文案,合规返回 None。"""
        if len(password) < self._settings.auth_password_min_length:
            return f"密码长度至少 {self._settings.auth_password_min_length} 位"
        if not _LETTER_RE.search(password):
            return "密码必须包含字母"
        if not _DIGIT_RE.search(password):
            return "密码必须包含数字"
        return None

    # ─── 登录限流(per IP + per username)──────────────────────────────────
    async def is_locked(self, ip: str, username: str) -> bool:
        """任一维度命中锁即拒绝。"""
        uname = username.lower()
        locked_ip = await self._redis.get(_LOCK_IP_KEY.format(ip=ip))
        locked_user = await self._redis.get(_LOCK_USER_KEY.format(username=uname))
        return locked_ip is not None or locked_user is not None

    async def record_failure(self, ip: str, username: str) -> list[str]:
        """记一次失败;任一维度计数 >= auth_max_failures 时写锁(锁定 auth_lock_seconds)。

        返回本次触发锁的维度(["ip"/"user"],空列表 = 未触发)——登录 router
        据此补写 local_login_locked 审计(W1:消除「锁定期间零审计」盲区)。
        """
        uname = username.lower()
        max_failures = self._settings.auth_max_failures
        lock_seconds = self._settings.auth_lock_seconds

        pipe = self._redis.pipeline()
        pipe.incr(_FAIL_IP_KEY.format(ip=ip))
        pipe.incr(_FAIL_USER_KEY.format(username=uname))
        # 计数 key 设窗口 TTL,失败在窗口内滑落(窗口 = 锁定期)
        pipe.expire(_FAIL_IP_KEY.format(ip=ip), lock_seconds)
        pipe.expire(_FAIL_USER_KEY.format(username=uname), lock_seconds)
        ip_count, user_count, _, _ = await pipe.execute()

        locked: list[str] = []
        if int(ip_count) >= max_failures:
            await self._redis.set(_LOCK_IP_KEY.format(ip=ip), "1", ex=lock_seconds)
            locked.append("ip")
            log.info("login rate limit: ip locked ip=%s", ip)
        if int(user_count) >= max_failures:
            await self._redis.set(_LOCK_USER_KEY.format(username=uname), "1", ex=lock_seconds)
            locked.append("user")
            log.info("login rate limit: username locked username=%s", uname)
        return locked

    async def reset_failures(self, ip: str, username: str) -> None:
        """登录成功清零计数(当前 IP + username 维度)。"""
        uname = username.lower()
        await self._redis.delete(
            _FAIL_IP_KEY.format(ip=ip),
            _FAIL_USER_KEY.format(username=uname),
        )

    # ─── 管理员解锁(W1)— key 形态派生与清理收敛在本服务,key 拼写勿外泄 ──
    @staticmethod
    def user_key_forms(user: User) -> list[str]:
        """user 的登录名三形态(username/email/name,非空去重 lower)。

        登录三级匹配按「输入 lower()」落 key,失败计数/锁会散在三种形态上,
        清理必须三形态全覆盖(否则静默清空 —— DEL 不存在的 key 不报错)。
        name 形态的 key 跨显示名相同的用户共享(方案 §1.3 已知并接受)。
        """
        out: list[str] = []
        for v in (user.username, user.email, user.name):
            if not v:
                continue
            u = v.lower()
            if u not in out:
                out.append(u)
        return out

    async def clear_locks(self, user: User) -> ClearLocksResult:
        """清 user 维度登录锁 + 失败计数(W1)。

        对三形态逐一 DEL ``auth:lock:user:{u}`` + ``auth:fail:user:{u}``
        (**必须 lower()**,与落 key 口径一致);unlock 端点与 reset-password
        共用本方法,返回实际清到的形态与是否存在过锁。
        """
        forms = self.user_key_forms(user)
        pipe = self._redis.pipeline()
        for u in forms:
            pipe.delete(_LOCK_USER_KEY.format(username=u))
            pipe.delete(_FAIL_USER_KEY.format(username=u))
        counts = await pipe.execute()  # [lock_0, fail_0, lock_1, fail_1, ...]
        hit: list[str] = []
        was_locked = False
        for i, u in enumerate(forms):
            lock_n, fail_n = int(counts[2 * i]), int(counts[2 * i + 1])
            if lock_n or fail_n:
                hit.append(u)
            if lock_n:
                was_locked = True
        return ClearLocksResult(forms=hit, was_locked=was_locked)

    async def clear_ip_locks(self, ips: Iterable[str]) -> list[str]:
        """清 IP 维度登录锁 + 失败计数(W1 unlock 端点连带清用)。

        返回实际清到 key 的 IP(去空去重保序);审计 details 记这份清单。
        """
        uniq = [ip for ip in dict.fromkeys(ips) if ip]
        if not uniq:
            return []
        pipe = self._redis.pipeline()
        for ip in uniq:
            pipe.delete(_LOCK_IP_KEY.format(ip=ip))
            pipe.delete(_FAIL_IP_KEY.format(ip=ip))
        counts = await pipe.execute()
        return [
            ip for i, ip in enumerate(uniq)
            if int(counts[2 * i]) or int(counts[2 * i + 1])
        ]

    async def users_login_locked(self, users: Sequence[User]) -> dict[uuid.UUID, bool]:
        """批量查 user 维度锁(列表端点 pipeline 一次往返,避免每行 3 次 GET)。

        只反映 user 维度;IP 维度命中时登录照样 429 但不在此显示(方案 §1.2,
        前端 pill 文案需标注「用户名维度」)。
        """
        pipe = self._redis.pipeline()
        forms_per_user = [self.user_key_forms(u) for u in users]
        for forms in forms_per_user:
            for u in forms:
                pipe.get(_LOCK_USER_KEY.format(username=u))
        values = await pipe.execute()
        out: dict[uuid.UUID, bool] = {}
        idx = 0
        for user, forms in zip(users, forms_per_user, strict=True):
            out[user.id] = any(
                values[idx + j] is not None for j in range(len(forms))
            )
            idx += len(forms)
        return out

    # ─── username → user 解析 ──────────────────────────────────────────────
    async def find_user_by_username(self, db: AsyncSession, username: str) -> User | None:
        """按登录输入找 user。匹配优先级:username 精确 → email(含 @)→ name 兜底。

        - username 是 #150 起的本地登录名(拼音/工号,管理后台建号必填);
          #149 落地时该列尚不存在(review F2 修正):优先匹配 username,
          老飞书用户 / 历史数据靠 email / name 兜底仍可登录
        - 全部忽略大小写;任一维度命中多行(如 name 重名)→ 记日志返回 None,
          避免歧义登录把重名用户全部锁死
        """
        lowered = username.lower()
        # ① 本地登录名 username(#150 管理后台建的账号)
        stmt = select(User).where(func.lower(User.username) == lowered).limit(2)
        res = await db.execute(stmt)
        users = list(res.scalars())
        # ② email(仅输入含 @ 时降级尝试;username 没命中才走这里)
        if not users and "@" in lowered:
            stmt = select(User).where(func.lower(User.email) == lowered).limit(2)
            res = await db.execute(stmt)
            users = list(res.scalars())
        # ③ 显示名 name 兜底(老飞书用户无 username / email)
        if not users:
            stmt = select(User).where(func.lower(User.name) == lowered).limit(2)
            res = await db.execute(stmt)
            users = list(res.scalars())
        if len(users) > 1:
            log.warning("login username ambiguous username=%s", username)
            return None
        return users[0] if users else None
