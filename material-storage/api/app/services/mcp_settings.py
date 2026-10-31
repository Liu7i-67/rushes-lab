"""MCP 通道配置服务 — DB 为正本 + Redis 缓存(``mcp:flag``)+ 进程内 5s 缓存。

需求:`docs/qdev/2026-10-30-mcp-service.md`(D5/D6/数据库修改 §3/接口 B)。
供**包 A2**(``get_current_user`` 的通道闸)与**包 A3**(``GET/PUT
/admin/mcp-settings``)消费。

对外 API(模块 docstring 即契约):

    MCP_FLAG_KEY = "mcp_channel"                  # system_flags.key
    MCP_REDIS_KEY = "mcp:flag"                    # Redis 缓存键
    MCP_FLAG_TTL_SECONDS = 60
    MCP_LOCAL_CACHE_TTL_SECONDS = 5.0
    DEFAULT_MCP_FLAG: dict[str, bool | int]       # 迁移 0020 的 seed 行(默认全关)

    @dataclass(frozen=True)
    class McpSettings:
        enabled: bool
        max_concurrency: int
        per_token_concurrency: int
        per_token_rpm: int
        per_ip_rpm: int
        def as_dict(self) -> dict[str, bool | int]
        @classmethod
        def from_dict(cls, raw: object) -> McpSettings   # 非法 → ValueError

    class McpSettingsUnavailable(Exception)       # 读:Redis+DB 都读不到 → fail-closed
    class McpSettingsTableMissing(Exception)      # 写:system_flags 表不存在(迁移 0020 未跑)

    class McpSettingsService:
        def __init__(self, redis, *, session_factory=None, local_cache=None)
        async def read(self) -> McpSettings               # 读(见下)
        async def write(self, db, value) -> None          # 写(见下;内部 commit)
        async def publish(self, value) -> None            # 仅刷新缓存(DB 已写好时用)
        def reset_local_cache(self) -> None               # 测试钩子

**读**(``read()``):本地 5s 缓存 → Redis → DB 回源(成功回填 Redis ``EX 60``)。
- 统一捕获 ``DBAPIError`` 全集(``UndefinedTableError``/``ProgrammingError``
  (迁移未跑)、``OperationalError``/``InterfaceError``(连接故障)),**先
  ``await db.rollback()`` 再回落默认值** —— 失败事务处于 aborted 态,不 rollback
  会让后续查询连带 ``InFailedSQLTransaction``;
- **行缺失**同样回落默认值(不自动插入;防「代码先上、迁移后跑」窗口期);
- **Redis 与 DB 双失败**(Redis 读异常 + DB 回源失败)→ 抛
  ``McpSettingsUnavailable``(调用方 fail-closed 403 ``channel_unavailable``);
  **仅 DB 故障而 Redis 正常(未命中)→ 回落默认值**;失败结果同样进 5s 本地
  负缓存,避免故障期每请求一次 DB 风暴;
- 使用**独立短 session**回源(``session_factory`` 注入;默认 ``get_sessionmaker()``),
  不占用端点请求事务。

**写**(``write(db, value)``):DB upsert(行缺失可 upsert;表缺失 → 抛
``McpSettingsTableMissing`` 供 A3 映射 503「先跑 alembic 0020」)→ **内部
``commit``** → 刷新 Redis 并写穿本进程缓存。
- Redis ``SET`` 失败 → ``DEL mcp:flag``;``DEL`` 也失败 → 仍把新值写穿本进程
  缓存(其他 worker 依赖 TTL 60 自然过期);
- 口径:Redis 写或 DEL 成功 → 其他 worker ≤65s 内看到新值;双失败 → 本进程
  立即生效、其他 worker ≤65s。

注意:``write`` 会 commit 调用方传入的 session(契约如此,便于 A3 在审计前后
直接调用;审计走 ``get_audit`` 的独立 session)。
"""
from __future__ import annotations

import json
import logging
import time
from collections.abc import Callable
from contextlib import AbstractAsyncContextManager
from dataclasses import dataclass

from pydantic import ValidationError
from redis.asyncio import Redis
from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.session import get_sessionmaker
from app.db.tables import SystemFlag
from app.models import McpSettingsIn

log = logging.getLogger(__name__)

# system_flags 行键(DB 正本)
MCP_FLAG_KEY = "mcp_channel"
# Redis 缓存键 + TTL(关闭是安全动作,短 TTL 让陈旧窗口更小;miss 回源 DB)
MCP_REDIS_KEY = "mcp:flag"
MCP_FLAG_TTL_SECONDS = 60
# 进程内缓存(值或失败负缓存)
MCP_LOCAL_CACHE_TTL_SECONDS = 5.0

# 默认值 = 迁移 0020 的 seed 行(默认全关;**必须能通过 McpSettingsIn 校验**)
DEFAULT_MCP_FLAG: dict[str, bool | int] = {
    "enabled": False,
    "max_concurrency": 8,
    "per_token_concurrency": 4,
    "per_token_rpm": 120,
    "per_ip_rpm": 600,
}

SessionFactory = Callable[[], AbstractAsyncContextManager[AsyncSession]]


class McpSettingsUnavailable(Exception):
    """Redis 与 DB 都读不到通道配置(调用方 fail-closed 403 channel_unavailable)。"""


class McpSettingsTableMissing(Exception):
    """``system_flags`` 表不存在(迁移 0020 未跑;admin PUT 映射 503)。"""


@dataclass(frozen=True)
class McpSettings:
    """MCP 通道配置(字段合法域与跨字段约束由 ``McpSettingsIn`` 保证)。"""

    enabled: bool
    max_concurrency: int
    per_token_concurrency: int
    per_token_rpm: int
    per_ip_rpm: int

    def as_dict(self) -> dict[str, bool | int]:
        return {
            "enabled": self.enabled,
            "max_concurrency": self.max_concurrency,
            "per_token_concurrency": self.per_token_concurrency,
            "per_token_rpm": self.per_token_rpm,
            "per_ip_rpm": self.per_ip_rpm,
        }

    @classmethod
    def from_dict(cls, raw: object) -> McpSettings:
        """按 API 校验器解析(Redis/DB 内容防御性校验);非法 → ``ValueError``。"""
        if isinstance(raw, bytes):
            raw = raw.decode("utf-8")
        if isinstance(raw, str):
            raw = json.loads(raw)
        if not isinstance(raw, dict):
            raise ValueError(f"mcp flag 必须是 JSON object,实际 {type(raw).__name__}")
        try:
            parsed = McpSettingsIn.model_validate(raw)
        except ValidationError as e:
            raise ValueError(f"mcp flag 内容非法: {e}") from e
        return cls(
            enabled=parsed.enabled,
            max_concurrency=parsed.max_concurrency,
            per_token_concurrency=parsed.per_token_concurrency,
            per_token_rpm=parsed.per_token_rpm,
            per_ip_rpm=parsed.per_ip_rpm,
        )


DEFAULT_MCP_SETTINGS = McpSettings.from_dict(DEFAULT_MCP_FLAG)


class LocalFlagCache:
    """进程内 5s 缓存;``value=None`` 表示「上次读失败」的负缓存。"""

    def __init__(
        self,
        ttl_seconds: float = MCP_LOCAL_CACHE_TTL_SECONDS,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._ttl_seconds = ttl_seconds
        self._clock = clock
        self._expires_at = 0.0
        self._value: McpSettings | None = None

    def get(self) -> tuple[bool, McpSettings | None]:
        if self._clock() < self._expires_at:
            return True, self._value
        return False, None

    def set(self, value: McpSettings | None) -> None:
        self._value = value
        self._expires_at = self._clock() + self._ttl_seconds

    def invalidate(self) -> None:
        self._expires_at = 0.0
        self._value = None


def _is_undefined_table(exc: DBAPIError) -> bool:
    """SQLSTATE 42P01(UndefinedTable):asyncpg 异常带 ``sqlstate``。"""
    orig = exc.orig
    state = getattr(orig, "sqlstate", None) or getattr(orig, "pgcode", None)
    return state == "42P01"


class McpSettingsService:
    """通道配置读写;实例应在 lifespan 构造一次挂 ``app.state``(缓存需跨请求)。

    A2/A3 接线示例:``app.state.mcp_settings = McpSettingsService(app.state.redis)``。
    """

    def __init__(
        self,
        redis: Redis | None = None,  # type: ignore[type-arg]  # repo 惯例(local_auth)
        *,
        session_factory: SessionFactory | None = None,
        local_cache: LocalFlagCache | None = None,
    ) -> None:
        self._redis = redis
        self._session_factory: SessionFactory = session_factory or get_sessionmaker()
        self._cache = local_cache or LocalFlagCache()

    # ─── 读 ───────────────────────────────────────────────────────────────
    async def read(self) -> McpSettings:
        """读配置(本地 5s → Redis → DB);双挂抛 ``McpSettingsUnavailable``。"""
        hit, cached = self._cache.get()
        if hit:
            if cached is None:
                raise McpSettingsUnavailable("MCP 配置读取失败(本地负缓存,5s 内不重试)")
            return cached

        redis_failed = False
        if self._redis is not None:
            try:
                raw = await self._redis.get(MCP_REDIS_KEY)
            except Exception as e:  # Redis 故障 → 回源 DB,不吞别的路径
                redis_failed = True
                log.warning("mcp:flag redis 读取失败,回源 DB: %s", e)
            else:
                if raw is not None:
                    try:
                        redis_value = McpSettings.from_dict(raw)
                    except ValueError as e:
                        log.warning("mcp:flag redis 内容非法,回源 DB: %s", e)
                    else:
                        self._cache.set(redis_value)
                        return redis_value

        try:
            db_value = await self._read_db()
        except DBAPIError as e:
            if redis_failed:
                # Redis 与 DB 双挂:读不到任何值 → fail-closed(调用方 403
                # channel_unavailable);失败结果进 5s 负缓存,故障期不打 DB
                self._cache.set(None)
                log.warning("mcp:flag Redis 与 DB 均不可用(fail-closed): %s", e)
                raise McpSettingsUnavailable(
                    "MCP 配置不可用(Redis 与 DB 均读取失败)"
                ) from e
            # 仅 DB 故障(Redis 正常但未命中):先 rollback 再回落默认值
            # (默认全关 = 安全侧;DB 恢复后下一次回源自动纠正)
            log.warning("mcp:flag DB 回源失败,回落默认值(通道默认关闭): %s", e)
            db_value = None

        resolved = db_value if db_value is not None else DEFAULT_MCP_SETTINGS
        self._cache.set(resolved)
        # 回源成功即回填(行缺失回落的默认值也回填:60s 内其他 worker 走 Redis,
        # 不反复扫 DB;管理员 PUT 会直接覆盖 Redis,不存在「默认值锁死」)
        await self._backfill_redis(resolved)
        return resolved

    async def _read_db(self) -> McpSettings | None:
        """回源 system_flags;表缺失/连接故障先 rollback 再抛 DBAPIError;行缺失 → None。"""
        async with self._session_factory() as db:
            try:
                row = (
                    await db.execute(
                        select(SystemFlag.value).where(SystemFlag.key == MCP_FLAG_KEY)
                    )
                ).first()
            except DBAPIError:
                # aborted 事务不 rollback 会让后续查询连带 InFailedSQLTransaction
                await db.rollback()
                raise
        if row is None:
            return None
        try:
            return McpSettings.from_dict(row[0])
        except ValueError as e:
            log.warning("system_flags.%s 内容非法,回落默认值: %s", MCP_FLAG_KEY, e)
            return None

    async def _backfill_redis(self, value: McpSettings) -> None:
        if self._redis is None:
            return
        try:
            await self._redis.set(
                MCP_REDIS_KEY, _payload(value), ex=MCP_FLAG_TTL_SECONDS,
            )
        except Exception as e:  # 缓存回填失败只 log(DB 已读到值)
            log.warning("mcp:flag 回填 redis 失败(继续用本进程缓存): %s", e)

    # ─── 写 ───────────────────────────────────────────────────────────────
    async def write(self, db: AsyncSession, value: McpSettings) -> None:
        """DB upsert + commit,然后刷新 Redis/本进程缓存(语义见模块 docstring)。"""
        payload = value.as_dict()
        stmt = (
            pg_insert(SystemFlag)
            .values(key=MCP_FLAG_KEY, value=payload)
            .on_conflict_do_update(
                index_elements=[SystemFlag.key],
                set_={"value": payload, "updated_at": func.now()},
            )
        )
        try:
            await db.execute(stmt)
            await db.commit()
        except DBAPIError as e:
            await db.rollback()
            if _is_undefined_table(e):
                raise McpSettingsTableMissing(
                    "system_flags 表不存在(迁移 0020 未跑):请先 alembic upgrade head"
                ) from e
            raise
        await self.publish(value)

    async def publish(self, value: McpSettings) -> None:
        """刷新缓存(DB 已写好时单独调用;写失败的最坏陈旧窗口见模块 docstring)。"""
        if self._redis is not None:
            try:
                await self._redis.set(
                    MCP_REDIS_KEY, _payload(value), ex=MCP_FLAG_TTL_SECONDS,
                )
            except Exception as e:
                log.warning("mcp:flag redis 写入失败,尝试 DEL: %s", e)
                try:
                    await self._redis.delete(MCP_REDIS_KEY)
                except Exception as e2:
                    log.warning(
                        "mcp:flag redis DEL 也失败,仅写穿本进程缓存(其他 worker ≤65s 陈旧): %s",
                        e2,
                    )
        # 无论 Redis 结果如何都写穿本进程缓存:本进程立即可见
        self._cache.set(value)

    # ─── 测试钩子 ─────────────────────────────────────────────────────────
    def reset_local_cache(self) -> None:
        """清空进程内缓存(测试钩子)。"""
        self._cache.invalidate()


def _payload(value: McpSettings) -> str:
    return json.dumps(value.as_dict(), separators=(",", ":"), sort_keys=True)
