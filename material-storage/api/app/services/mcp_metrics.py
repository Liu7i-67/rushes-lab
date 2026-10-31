"""MCP 通道流量指标 — 写侧(纯 ASGI 中间件)与读侧(包 A3 管理端)共用的唯一口径。

需求:`docs/qdev/2026-10-30-mcp-service.md`(D11 / C.6 / 接口 B「实时指标字段」)。
**本模块的对外 API 是固定契约 —— 包 A3(`/admin/mcp-settings` 的
``today_success`` / ``today_rejected_policy`` / ``today_rejected_quota`` /
``rejected_infra_since_start``)直接 import,勿改名/改签名。**

对外 API:

    STATS_TTL_SECONDS = 8 * 86400
    def utc_day(now=None) -> str                        # yyyyMMdd(UTC 日口径)
    def stats_key(bucket, day=None) -> str              # mcp:stats:{bucket}:{yyyyMMdd}
    async def incr_stat(redis, bucket) -> None          # INCR + EXPIRE(内部 try/except)
    def record_infra_reject(reason) -> None             # 进程内 rejected_infra 计数
    def infra_rejects_since_start() -> int
    REASON_POLICY: frozenset[str]
    REASON_QUOTA: frozenset[str]
    REASON_INFRA: frozenset[str>
    BUCKET_REQUESTS / BUCKET_REJECTED_POLICY / BUCKET_REJECTED_QUOTA

口径钉死(勿改):
- 计数只认 **PAT 分支**:由调用方(``app/middleware/mcp_stats.py``)按
  ``request.state.auth_method == "pat"`` 判定,本模块不做认证判定;
- 拒绝量按 **``mcp_reject_reason``(9 个定版值)分桶**,不看状态码 ——
  业务权限不足也是 403,与「管理员关通道」必须分开;
- ``channel_closed`` / ``pat_forbidden`` / ``forced_change`` → Redis
  ``rejected_policy``;``quota_ip`` / ``quota_rpm`` / ``quota_conc`` /
  ``quota_batch`` → Redis ``rejected_quota``;``channel_unavailable`` /
  ``redis_down`` → **只进进程内 ``rejected_infra``(不写 Redis)** —— 该指标
  恰在 Redis 不可用 / 配置读不到时才该计,写 Redis 必然失败;精度 = 单 worker;
- 日键取 **UTC**(使用统计页 daily 是北京时间日,页面文案分别标注);
- 所有 Redis 操作 **try/except 只 log** —— 指标故障绝不影响响应。
"""
from __future__ import annotations

import logging
import threading
from datetime import UTC, datetime

log = logging.getLogger(__name__)

# 统计键保留 8 天(方案 C.6「均 EXPIRE 8 天」)
STATS_TTL_SECONDS = 8 * 86400

# Redis 桶名(键 = mcp:stats:{bucket}:{yyyyMMdd})
BUCKET_REQUESTS = "requests"
BUCKET_REJECTED_POLICY = "rejected_policy"
BUCKET_REJECTED_QUOTA = "rejected_quota"

# 9 个 reason 定版 → 三个桶(方案 C.6)
REASON_POLICY: frozenset[str] = frozenset(
    {"channel_closed", "pat_forbidden", "forced_change"}
)
REASON_QUOTA: frozenset[str] = frozenset(
    {"quota_ip", "quota_rpm", "quota_conc", "quota_batch"}
)
REASON_INFRA: frozenset[str] = frozenset({"channel_unavailable", "redis_down"})

_ALL_BUCKETS: frozenset[str] = frozenset(
    {BUCKET_REQUESTS, BUCKET_REJECTED_POLICY, BUCKET_REJECTED_QUOTA}
)

# 进程内 rejected_infra 计数(单 worker 局部值,重启清零;Redis 不可用时的唯一承载)
_infra_rejects = 0
_infra_lock = threading.Lock()


def utc_day(now: datetime | None = None) -> str:
    """UTC 日口径 ``yyyyMMdd``(方案 C.6:取 UTC 而非北京时间日)。"""
    current = now or datetime.now(UTC)
    return current.strftime("%Y%m%d")


def stats_key(bucket: str, day: str | None = None) -> str:
    """计数键 ``mcp:stats:{bucket}:{yyyyMMdd}``(day 缺省取当前 UTC 日)。"""
    return f"mcp:stats:{bucket}:{day or utc_day()}"


async def incr_stat(redis: object, bucket: str) -> None:
    """``INCR`` 当日桶 + ``EXPIRE 8d``;任何异常只 log(指标不影响响应)。

    ``redis`` 用 ``object`` 收 —— 调用方传 ``app.state.redis``(测试可传 fake),
    只用到 ``incr``/``expire`` 两个协程方法。
    """
    if bucket not in _ALL_BUCKETS:
        log.warning("mcp metrics: 未知桶 %r(忽略)", bucket)
        return
    key = stats_key(bucket)
    try:
        await redis.incr(key)  # type: ignore[attr-defined]
        await redis.expire(key, STATS_TTL_SECONDS)  # type: ignore[attr-defined]
    except Exception as e:  # 指标写失败绝不影响响应
        log.warning("mcp metrics: INCR %s 失败(忽略): %s", key, e)


def record_infra_reject(reason: str) -> None:
    """进程内 ``rejected_infra`` +1(只接受 ``REASON_INFRA`` 的 reason)。

    非 infra reason 传进来属调用方 bug:仍计数会让「配置读不到」与「主动关通道」
    混口径,故只 log.warning 不计数。
    """
    global _infra_rejects
    if reason not in REASON_INFRA:
        log.warning("mcp metrics: record_infra_reject 收到非 infra reason=%r(忽略)", reason)
        return
    with _infra_lock:
        _infra_rejects += 1


def infra_rejects_since_start() -> int:
    """进程内 infra 拒绝累计(自进程启动;单 worker 局部值)。"""
    with _infra_lock:
        return _infra_rejects


def reset_infra_rejects() -> None:
    """进程内计数归零(**仅测试钩子**)—— 生产无调用点。"""
    global _infra_rejects
    with _infra_lock:
        _infra_rejects = 0
