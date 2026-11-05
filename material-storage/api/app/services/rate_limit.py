"""通用 Redis 计数限流原语(方案 §5.1 / §5.7.2)— B2(邮箱验证码)/ B3(找回密码)共用。

设计钉子(§5.7.2):
- **不要每次请求都 EXPIRE**(429 会不断续期把用户永远锁住),也**不要裸
  ``INCR`` 后再 ``EXPIRE``**(两步之间进程被 kill 会留下永不过期的计数键);
  统一走单条 Lua:``INCR`` + 仅当 ``TTL < 0`` 才 ``EXPIRE``,一次 round-trip
  原子完成(Lua 形态照 ``services/mcp_limiter.py`` 的 ``_INCR_EXPIRE_LUA``)。
- **Redis 故障 fail-closed**:所有原语把 redis 异常收敛为 ``RateLimitUnavailable``,
  路由层统一映射 503「服务暂不可用」(与 MCP 链一致),不裸抛 500、不静默放行。

模块只做原子原语,不读配置、不知道键名语义(键名模板在
``email_verification.py`` / ``password_reset.py`` 各自定义);redis 实例由
router 从 ``request.app.state.redis`` 注入。
"""
from __future__ import annotations

import time

# INCR;TTL<0(键无过期时间)才 EXPIRE —— 首次写键定档 TTL,后续不续期
# (固定窗口语义;单脚本原子,防两步间崩溃留永久键)。照 mcp_limiter 同型。
_INCR_EXPIRE_LUA = """
local count = redis.call('INCR', KEYS[1])
if redis.call('TTL', KEYS[1]) < 0 then
  redis.call('EXPIRE', KEYS[1], tonumber(ARGV[1]))
end
return count
"""


class RateLimitUnavailable(RuntimeError):
    """Redis 不可达/命令失败 —— 调用方(fail-closed)统一映射 503。"""


def epoch_hour(now: float | None = None) -> int:
    """当前 epoch 小时(小时窗口键的时间片;只要求稳定,不要求对齐自然小时)。"""
    return int((now if now is not None else time.time()) // 3600)


async def incr_with_ttl(redis: object, key: str, ttl_seconds: int) -> int:
    """原子 ``INCR`` + 首次 ``EXPIRE``,返回自增后的计数(§5.7.2 计数实现钉子)。

    - 首次(键新建)才设置 TTL;已有 TTL 不续期 —— 429 重试不会滚动窗口;
    - Redis 异常 → ``RateLimitUnavailable``(fail-closed,调用方 503)。

    B3(找回密码)同用:请求预算 ``incr_with_ttl(...) 原子自增后检查``、
    失败计数(Lua INCR + 首次 EXPIRE = 锁 TTL)都走本函数。
    """
    try:
        value = await redis.eval(  # type: ignore[attr-defined]
            _INCR_EXPIRE_LUA, 1, key, int(ttl_seconds),
        )
    except RateLimitUnavailable:
        raise
    except Exception as exc:  # fail-closed 收口,不区分错误类型
        raise RateLimitUnavailable(f"rate limit redis eval failed: {exc!r}") from exc
    return int(value)


async def get_int(redis: object, key: str) -> int:
    """读计数键(``GET`` → int;缺键/非数值 → 0)。发信配额「先读后写」的读侧。

    Redis 异常 → ``RateLimitUnavailable``(读失败同样 fail-closed,不静默放行)。
    """
    try:
        raw = await redis.get(key)  # type: ignore[attr-defined]
    except Exception as exc:
        raise RateLimitUnavailable(f"rate limit redis get failed: {exc!r}") from exc
    if raw is None or raw == "":
        return 0
    try:
        return int(raw)
    except (TypeError, ValueError):
        return 0


async def ttl_seconds(redis: object, key: str) -> int:
    """键剩余 TTL(秒)。缺键 → 0;无过期 → -1 原样返回(调用方自判异常态)。

    429 的 ``Retry-After`` 头与文案里的剩余分钟/秒都用它(§5.7.4)。
    """
    try:
        return int(await redis.ttl(key))  # type: ignore[attr-defined]
    except Exception as exc:
        raise RateLimitUnavailable(f"rate limit redis ttl failed: {exc!r}") from exc


async def set_nx_ex(redis: object, key: str, value: str, ex_seconds: int) -> bool:
    """``SET key value NX EX``:原子占位,返回是否占到位(冷却,§5.3.2 第 10 步)。

    占位**只此一次、不续期** —— 占位成功即视为本次请求的发送窗口;后续所有
    分支(成功/失败/未知)都不再触碰该键。Redis 异常 → ``RateLimitUnavailable``。
    """
    try:
        ok = await redis.set(key, value, nx=True, ex=int(ex_seconds))  # type: ignore[attr-defined]
    except Exception as exc:
        raise RateLimitUnavailable(f"rate limit redis set_nx failed: {exc!r}") from exc
    return bool(ok)


async def delete_keys(redis: object, *keys: str) -> None:
    """删除键(计数清零 / 验证码作废)。异常 → ``RateLimitUnavailable``。"""
    if not keys:
        return
    try:
        await redis.delete(*keys)  # type: ignore[attr-defined]
    except Exception as exc:
        raise RateLimitUnavailable(f"rate limit redis delete failed: {exc!r}") from exc


async def set_ex(redis: object, key: str, value: str, ex_seconds: int) -> None:
    """普通 ``SET ... EX``(写锁键等;非占位语义)。异常 → ``RateLimitUnavailable``。"""
    try:
        await redis.set(key, value, ex=int(ex_seconds))  # type: ignore[attr-defined]
    except Exception as exc:
        raise RateLimitUnavailable(f"rate limit redis set failed: {exc!r}") from exc
