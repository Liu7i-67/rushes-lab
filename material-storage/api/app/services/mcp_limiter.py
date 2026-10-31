"""MCP 通道限流/并发闸的 Redis 原语(固定窗口桶 + 两级 ZSET 闸)。

需求:`docs/qdev/2026-10-30-mcp-service.md`(D5 / C.2 / C.5 / C.6)。
本模块只做**原子 Redis 原语**,不读配置、不抛 HTTP 异常:
- ``incr_window``:固定窗口 ``INCR`` + 「仅当 TTL<0 才 EXPIRE」(单 Lua,一次
  round-trip)。IP 桶与每令牌 RPM 共用(**键名含分钟,Redis 不会自动过期;
  漏 TTL 会无限增长**,且与 arq/登录防爆破共用同一 Redis,会连带伤到队列);
- ``acquire_concurrency``:两级 ZSET 的「清理过期 + per-token 检查 + ZADD +
  global 检查 + **全局拒时回滚 per-token** + ZADD + PEXPIRE」**单个 Lua 脚本**
  完成(检查与回滚拆两次 round-trip 会漏配额/自塞);
- ``release_concurrency``:两闸各 ``ZREM req_id``(对已过期成员幂等,多删无害)。

键(方案 C.6 钉死):
    mcp:rl:ip:{client_ip}:{epoch_minute}        # 认证前置 IP 桶(总请求/IP 粗上限)
    mcp:rl:{token_id}:{epoch_minute}            # 每令牌 RPM
    mcp:conc:tok:{token_id}                     # per-token 在途 ZSET(score=到期 ms)
    mcp:conc:global                             # 全局在途 ZSET(score=到期 ms)

租约语义:ZSET 成员 score = ``now_ms + lease_ms``,过期即被 ``ZREMRANGEBYSCORE``
清理 —— 租约**只决定崩溃回收上限**,正常请求靠 ``finally`` 的 ``ZREM`` 即时释放。
本仓 Redis 为单机(cache+arq 同一 Dsn),CROSSSLOT 不适用;若未来 Cluster 化,
两 key 须加 hash tag 同 slot。
"""
from __future__ import annotations

import time
import uuid

# 固定窗口 TTL:键名已含分钟,统一 120s 只为防 key 堆积(方案 C.2/C.5)
RATE_WINDOW_TTL_SECONDS = 120

IP_BUCKET_KEY_TEMPLATE = "mcp:rl:ip:{client_ip}:{minute}"
TOKEN_RPM_KEY_TEMPLATE = "mcp:rl:{token_id}:{minute}"
CONC_TOKEN_KEY_TEMPLATE = "mcp:conc:tok:{token_id}"
CONC_GLOBAL_KEY = "mcp:conc:global"

# INCR;TTL<0(键无过期时间)才 EXPIRE —— 避免每请求一次 TTL 往返,也不续期
# (固定窗口);避免两步间崩溃留无 TTL 永久键,且不依赖 Redis ≥7.0 的 EXPIRE NX
_INCR_EXPIRE_LUA = """
local count = redis.call('INCR', KEYS[1])
if redis.call('TTL', KEYS[1]) < 0 then
  redis.call('EXPIRE', KEYS[1], tonumber(ARGV[1]))
end
return count
"""

# 两级并发闸:检查 + 占位 + 全局拒回滚 + 刷新租约,**单脚本原子完成**
# KEYS[1]=mcp:conc:tok:{token_id}  KEYS[2]=mcp:conc:global
# ARGV[1]=now_ms  ARGV[2]=lease_ms  ARGV[3]=max_token  ARGV[4]=max_global  ARGV[5]=req_id
_ACQUIRE_CONCURRENCY_LUA = """
local now = tonumber(ARGV[1])
local lease = tonumber(ARGV[2])
redis.call('ZREMRANGEBYSCORE', KEYS[1], 0, now)
redis.call('ZREMRANGEBYSCORE', KEYS[2], 0, now)
if redis.call('ZCARD', KEYS[1]) >= tonumber(ARGV[3]) then
  return 0
end
redis.call('ZADD', KEYS[1], now + lease, ARGV[5])
if redis.call('ZCARD', KEYS[2]) >= tonumber(ARGV[4]) then
  redis.call('ZREM', KEYS[1], ARGV[5])
  return 0
end
redis.call('ZADD', KEYS[2], now + lease, ARGV[5])
redis.call('PEXPIRE', KEYS[1], lease + 5000)
redis.call('PEXPIRE', KEYS[2], lease + 5000)
return 1
"""


def epoch_minute(now: float | None = None) -> int:
    """当前 epoch 分钟(固定窗口键的时间片)。"""
    return int((now if now is not None else time.time()) // 60)


def ip_bucket_key(client_ip: str, minute: int | None = None) -> str:
    """IP 桶键(``client_ip`` 取 nginx W2a 还原后的 XFF 单值)。"""
    return IP_BUCKET_KEY_TEMPLATE.format(
        client_ip=client_ip, minute=minute if minute is not None else epoch_minute(),
    )


def token_rpm_key(token_id: uuid.UUID | str, minute: int | None = None) -> str:
    """每令牌 RPM 键(token_id 用 DB UUID;无效令牌无此键 → 由 IP 桶兜)。"""
    return TOKEN_RPM_KEY_TEMPLATE.format(
        token_id=token_id, minute=minute if minute is not None else epoch_minute(),
    )


def conc_token_key(token_id: uuid.UUID | str) -> str:
    return CONC_TOKEN_KEY_TEMPLATE.format(token_id=token_id)


async def incr_window(redis: object, key: str, ttl_seconds: int = RATE_WINDOW_TTL_SECONDS) -> int:
    """固定窗口计数 +1,返回计数后的值(单 Lua;异常原样抛给调用方 fail-closed)。"""
    value = await redis.eval(  # type: ignore[attr-defined]
        _INCR_EXPIRE_LUA, 1, key, int(ttl_seconds),
    )
    return int(value)


async def acquire_concurrency(
    redis: object,
    *,
    token_id: uuid.UUID | str,
    req_id: str,
    lease_seconds: int,
    max_token: int,
    max_global: int,
    now_ms: int | None = None,
) -> bool:
    """两级 ZSET 闸占位;``True`` = 已占位(调用方 finally 必须释放)。

    单 Lua 内完成:清理过期 → per-token 判满 → ZADD per-token → global 判满
    (**满则回滚 per-token 并返回 0**)→ ZADD global → PEXPIRE(lease+5s)。
    全局拒不回滚会把被拒请求自己的 per-token 配额塞满(方案 C.5 ★)。
    """
    now = int(now_ms if now_ms is not None else time.time() * 1000)
    lease_ms = int(lease_seconds) * 1000
    result = await redis.eval(  # type: ignore[attr-defined]
        _ACQUIRE_CONCURRENCY_LUA, 2,
        conc_token_key(token_id), CONC_GLOBAL_KEY,
        now, lease_ms, int(max_token), int(max_global), req_id,
    )
    return int(result) == 1


async def release_concurrency(redis: object, *, token_id: uuid.UUID | str, req_id: str) -> None:
    """释放两闸(对已过期成员幂等)。异常抛给调用方(按方案:只 log)。"""
    await redis.zrem(conc_token_key(token_id), req_id)  # type: ignore[attr-defined]
    await redis.zrem(CONC_GLOBAL_KEY, req_id)  # type: ignore[attr-defined]


async def in_flight(redis: object, now_ms: int | None = None) -> int:
    """在途并发读数 ``ZCOUNT mcp:conc:global now +inf``(管理端指标;勿用 ZCARD)。"""
    now = int(now_ms if now_ms is not None else time.time() * 1000)
    return int(await redis.zcount(CONC_GLOBAL_KEY, now, "+inf"))  # type: ignore[attr-defined]
