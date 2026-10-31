"""PAT 认证链(get_current_user 的 Bearer 分支,前五步)—— 独立模块。

需求:`docs/qdev/2026-10-30-mcp-service.md` 接口 C。**顺序钉死,勿调换**:

    ① 通道闸(``mcp:flag`` 全关/读不到)→ ② 认证前置 IP 桶(``mcp:rl:ip:*``)
    → ③ token 查表(SHA-256,独立短 session + 未命中负缓存)
    → ④ 用户态(禁用 401;强制改密 403,**PAT 无 F15 豁免清单**)
    → ⑤ 每令牌 RPM(``mcp:rl:{token_id}:*``)→ ``last_used_at`` 节流回写

**第六步(两级并发闸)在 ``app/services/mcp_gate.py``**(router 级 yield 依赖),
**不写在这里**。本模块只负责「认证 + 前五步」,不含任何 router 级策略。

语义钉死(与方案 C 一致,改任一都是行为变更):
- 通道闸最先 —— 双挂 403 才可达;关闭期零 Redis/DB 计数(session 请求完全不受影响);
- ``Bearer`` 但非 ``mspat_`` 前缀 → **401(不落 reason)**;
- Redis 故障一律 **fail-closed 503**(reason=``redis_down``;绝不 fail-open);
- 配置读不到 → **403 ``channel_unavailable``**(不是 503,与「管理员关通道」区分);
- 401 不设 ``mcp_reject_reason``(401 不计入任何拒绝桶);
- ``last_used_at`` 非限流组件:**整段 try/except 只 log**,不影响本请求。

循环导入(重要):``app.deps`` 顶层 import 本模块;**本模块只在函数内延迟
``from app.deps import load_active_user``**,类型注解走 ``TYPE_CHECKING``。
"""
from __future__ import annotations

import logging
import time
import uuid
from collections import OrderedDict
from collections.abc import Callable
from datetime import UTC, datetime
from typing import TYPE_CHECKING, NoReturn

from fastapi import HTTPException, Request
from sqlalchemy import update

from app.db.session import get_sessionmaker
from app.db.tables import PersonalAccessToken
from app.services.audit import bind_auth_context
from app.services.mcp_limiter import epoch_minute, incr_window, ip_bucket_key, token_rpm_key
from app.services.mcp_settings import McpSettingsService, McpSettingsUnavailable
from app.services.tokens import PAT_PREFIX, ResolvedToken, hash_token, resolve_token

if TYPE_CHECKING:  # 仅注解:运行时延迟 import(app.deps ↔ 本模块 双向依赖)
    from app.deps import CurrentUser

log = logging.getLogger(__name__)

# 文案钉死(前端/测试按此断言;方案 C 末尾「状态码语义」)
MCP_CHANNEL_CLOSED_DETAIL = "MCP 通道当前已由管理员关闭"
MCP_CHANNEL_UNAVAILABLE_DETAIL = "MCP 通道配置不可用,请稍后重试"
PAT_INVALID_DETAIL = "令牌无效或已过期"
PAT_FORCED_CHANGE_DETAIL = "首次登录请先设置新密码:请先完成修改密码再继续操作"
MCP_RATE_LIMITED_DETAIL = "请求过于频繁,请稍后重试"
MCP_REDIS_DOWN_DETAIL = "认证服务暂时不可用,请稍后重试"
# 无任何凭据时的兜底文案(与 deps.get_current_user 的最终 401 同文)
NOT_AUTHENTICATED_DETAIL = "not authenticated — call /api/v1/auth/login"

# 未命中的 PAT 进程内负缓存(常数容量 LRU + TTL):只防「重复同一伪 token」
# 反复打唯一索引;洪水面由认证前置 IP 桶兜(方案 C.3)
NEGATIVE_PAT_CACHE_TTL_SECONDS = 60.0
NEGATIVE_PAT_CACHE_MAXSIZE = 1024

# last_used_at 节流:SET NX EX 300 成功才 UPDATE DB(方案 C.8)
LAST_USED_KEY_TEMPLATE = "mcp:lastused:{token_id}"
LAST_USED_THROTTLE_SECONDS = 300


class NegativeTokenCache:
    """常数容量 LRU + TTL(进程内,单 worker 局部值;不做洪水防护)。"""

    def __init__(
        self,
        ttl_seconds: float = NEGATIVE_PAT_CACHE_TTL_SECONDS,
        maxsize: int = NEGATIVE_PAT_CACHE_MAXSIZE,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._ttl = ttl_seconds
        self._maxsize = maxsize
        self._clock = clock
        self._data: OrderedDict[str, float] = OrderedDict()

    def seen(self, digest: str) -> bool:
        expires_at = self._data.get(digest)
        if expires_at is None:
            return False
        if expires_at <= self._clock():
            self._data.pop(digest, None)
            return False
        self._data.move_to_end(digest)
        return True

    def add(self, digest: str) -> None:
        self._data[digest] = self._clock() + self._ttl
        self._data.move_to_end(digest)
        while len(self._data) > self._maxsize:
            self._data.popitem(last=False)

    def clear(self) -> None:
        self._data.clear()


negative_token_cache = NegativeTokenCache()


def _reject_pat(
    request: Request,
    status_code: int,
    detail: str,
    reason: str,
    headers: dict[str, str] | None = None,
) -> NoReturn:
    """记 ``mcp_reject_reason``(中间件按它分桶)后抛 HTTPException。"""
    request.state.mcp_reject_reason = reason
    raise HTTPException(status_code, detail, headers=headers)


def _retry_after_seconds(now: float | None = None) -> str:
    """固定窗口的剩余秒数(向上取整 +1s 余量),给 429 的 Retry-After。"""
    current = time.time() if now is None else now
    return str(max(1, int(60 - (current % 60)) + 1))


def bearer_token(request: Request) -> str | None:
    """``Authorization: Bearer <token>`` 的令牌(scheme 大小写不敏感)。

    无 Authorization / 非 Bearer scheme / 空值 → None(由 ``get_current_user``
    继续走 dev X-User-Id 或 401);**Bearer 但非 ``mspat_`` 前缀** →
    ``authenticate_pat`` 判 401(不回落,方案 C)。
    """
    header = request.headers.get("authorization")
    if not header:
        return None
    parts = header.split(None, 1)
    if len(parts) != 2 or parts[0].lower() != "bearer":
        return None
    token = parts[1].strip()
    return token or None


async def touch_last_used(redis: object, token_id: uuid.UUID) -> None:
    """``last_used_at`` 节流回写(**整段 try/except 只 log**,不参与 fail-closed)。

    ``SET mcp:lastused:{token_id} 1 NX EX 300`` 成功才 UPDATE DB(独立短 session);
    DB 抖动也不能把已通过认证的请求变 500(方案 C.8)。
    """
    key = LAST_USED_KEY_TEMPLATE.format(token_id=token_id)
    try:
        fresh = await redis.set(  # type: ignore[attr-defined]
            key, "1", nx=True, ex=LAST_USED_THROTTLE_SECONDS,
        )
        if not fresh:
            return
        async with get_sessionmaker()() as db:
            await db.execute(
                update(PersonalAccessToken)
                .where(PersonalAccessToken.id == token_id)
                .values(last_used_at=datetime.now(UTC))
            )
            await db.commit()
    except Exception as e:  # 非限流组件,失败只 log
        log.warning("mcp: last_used_at 回写失败 token=%s: %s", token_id, e)


async def lookup_token(raw_token: str) -> ResolvedToken | None:
    """token_hash 查表(独立短 session,不写进端点请求事务;DB 故障不吞 → 500)。"""
    async with get_sessionmaker()() as db:
        return await resolve_token(db, raw_token)


def _mcp_settings_service(request: Request) -> McpSettingsService | None:
    return getattr(request.app.state, "mcp_settings", None)


def _redis_client(request: Request) -> object | None:
    return getattr(request.app.state, "redis", None)


async def authenticate_pat(request: Request) -> CurrentUser:
    """PAT 认证链前五步(**顺序钉死**,方案 C;第六步并发闸在 mcp_gate)。

    ① 通道闸 → ② 前置 IP 桶 → ③ token 查表 → ④ 用户态 → ⑤ 每令牌 RPM。
    Redis 故障一律 fail-closed 503(reason=redis_down),session 请求不受影响;
    成功写 ``request.state.auth_method="pat"`` / ``auth_token_id`` / ``mcp_flag``,
    并绑定审计 contextvar。
    """
    # 延迟 import:app.deps 顶层 import 本模块(避免循环导入)
    from app.deps import load_active_user

    raw_token = bearer_token(request)
    if raw_token is None:
        raise HTTPException(401, NOT_AUTHENTICATED_DETAIL)
    if not raw_token.startswith(PAT_PREFIX):
        # Bearer 但非 mspat_ 前缀:不是本服务的令牌形态 → 401(不落 reason)
        raise HTTPException(401, PAT_INVALID_DETAIL)

    # ① 通道闸 —— 必须最先:双挂 403 才可达;关闭期零 DB/Redis 计数
    service = _mcp_settings_service(request)
    if service is None:
        _reject_pat(request, 403, MCP_CHANNEL_UNAVAILABLE_DETAIL, "channel_unavailable")
    try:
        flag = await service.read()
    except McpSettingsUnavailable as e:
        log.warning("mcp: 通道配置不可用(fail-closed): %s", e)
        _reject_pat(request, 403, MCP_CHANNEL_UNAVAILABLE_DETAIL, "channel_unavailable")
    request.state.mcp_flag = flag
    if not flag.enabled:
        # 关闭期无效 token 也回 403(不泄露 token 有效性)
        _reject_pat(request, 403, MCP_CHANNEL_CLOSED_DETAIL, "channel_closed")

    redis = _redis_client(request)
    if redis is None:
        _reject_pat(request, 503, MCP_REDIS_DOWN_DETAIL, "redis_down")

    # ② 认证前置 IP 桶(先于 token 查表;仅通道开启后才计数)
    client_ip = request.client.host if request.client else "unknown"
    minute = epoch_minute()
    try:
        ip_hits = await incr_window(redis, ip_bucket_key(client_ip, minute))
    except Exception as e:  # Redis 故障 fail-closed
        log.warning("mcp: IP 桶计数失败(fail-closed): %s", e)
        _reject_pat(request, 503, MCP_REDIS_DOWN_DETAIL, "redis_down")
    if ip_hits > flag.per_ip_rpm:
        _reject_pat(
            request, 429, MCP_RATE_LIMITED_DETAIL, "quota_ip",
            headers={"Retry-After": _retry_after_seconds()},
        )

    # ③ token 查表(独立短 session + 未命中负缓存)
    digest = hash_token(raw_token)
    if negative_token_cache.seen(digest):
        raise HTTPException(401, PAT_INVALID_DETAIL)
    resolved = await lookup_token(raw_token)
    if resolved is None:
        negative_token_cache.add(digest)
        raise HTTPException(401, PAT_INVALID_DETAIL)
    if resolved.revoked_at is not None or resolved.expires_at <= datetime.now(UTC):
        # 吊销/过期立即失效(无缓存窗口;不落 reason)
        raise HTTPException(401, PAT_INVALID_DETAIL)

    # ④ 用户态(禁用 401;强制改密 403 —— PAT 无 F15 豁免清单)
    user, forced_change = await load_active_user(resolved.user_id)
    if forced_change:
        _reject_pat(request, 403, PAT_FORCED_CHANGE_DETAIL, "forced_change")

    # ⑤ 每令牌 RPM
    try:
        rpm_hits = await incr_window(redis, token_rpm_key(resolved.id, minute))
    except Exception as e:
        log.warning("mcp: 令牌 RPM 计数失败(fail-closed): %s", e)
        _reject_pat(request, 503, MCP_REDIS_DOWN_DETAIL, "redis_down")
    if rpm_hits > flag.per_token_rpm:
        _reject_pat(
            request, 429, MCP_RATE_LIMITED_DETAIL, "quota_rpm",
            headers={"Retry-After": _retry_after_seconds()},
        )

    # last_used_at 节流(失败只 log,不影响本请求)
    await touch_last_used(redis, resolved.id)

    request.state.auth_method = "pat"
    request.state.auth_token_id = resolved.id
    bind_auth_context("pat", resolved.id)
    return user
