"""MCP 通道配置服务单元/集成测试(app/services/mcp_settings.py,包 A1)。

需求依据:`docs/qdev/2026-10-30-mcp-service.md`(D5/D6/数据库修改 §3/
测试功能点「配置缺失自救」)。覆盖:
  - 默认值 = 迁移 0020 seed 行,且默认值必须通过 McpSettingsIn 校验(D6);
  - 非法组合 422 来源(模型层 validate):per_token_concurrency > max_concurrency、
    per_ip_rpm < 2 倍 per_token_rpm、越界值;
  - 读:行缺失回落默认值;DBAPIError 先 rollback 再回落默认值(Redis 正常但未命中);
    Redis 故障 → 回源 DB;Redis+DB 双失败 → McpSettingsUnavailable(fail-closed);
    进程内 5s 缓存(含失败负缓存);
  - 写:行缺失 upsert;表缺失 → McpSettingsTableMissing(A3 映射 503);
    Redis SET 失败 → DEL;DEL 也失败 → 写穿本进程缓存(其他 worker 靠 TTL 过期)。

含真实 DB 的用例需迁移 0020 已 upgrade(容器内 PM 统一执行);假 session 用例
不依赖 DB。FakeRedis/FakeSession 只实现服务实际用到的接口子集(照
tests/test_local_auth.py 的 FakeRedis 惯例)。
"""
from __future__ import annotations

import json

import pytest
from pydantic import ValidationError
from sqlalchemy.exc import ProgrammingError

from app.models import McpSettingsIn
from app.services.mcp_settings import (
    DEFAULT_MCP_FLAG,
    DEFAULT_MCP_SETTINGS,
    MCP_FLAG_KEY,
    MCP_FLAG_TTL_SECONDS,
    MCP_REDIS_KEY,
    LocalFlagCache,
    McpSettings,
    McpSettingsService,
    McpSettingsTableMissing,
    McpSettingsUnavailable,
)

_DB_ERROR = ProgrammingError("SELECT 1", {}, Exception("db down"))


class FakeRedis:
    """mcp_settings 用到的 redis 接口子集(get / set(ex) / delete)。"""

    def __init__(
        self, *, fail_get: bool = False, fail_set: bool = False, fail_delete: bool = False,
    ) -> None:
        self.store: dict[str, str] = {}
        self.set_calls: list[tuple[str, str, int | None]] = []
        self.delete_calls: list[tuple[str, ...]] = []
        self.fail_get = fail_get
        self.fail_set = fail_set
        self.fail_delete = fail_delete

    async def get(self, key: str) -> str | None:
        if self.fail_get:
            raise ConnectionError("redis down(get)")
        return self.store.get(key)

    async def set(self, key: str, value: str, ex: int | None = None) -> None:
        self.set_calls.append((key, value, ex))
        if self.fail_set:
            raise ConnectionError("redis down(set)")
        self.store[key] = value

    async def delete(self, *keys: str) -> None:
        self.delete_calls.append(keys)
        if self.fail_delete:
            raise ConnectionError("redis down(delete)")
        for k in keys:
            self.store.pop(k, None)


class _Result:
    def __init__(self, rows: list[tuple]) -> None:
        self._rows = rows

    def first(self):
        return self._rows[0] if self._rows else None


class FakeSession:
    """mcp_settings 用到的 AsyncSession 子集(execute / rollback / commit)。"""

    def __init__(self, *, rows: list[tuple] | None = None, error: Exception | None = None):
        self.rows = rows or []
        self.error = error
        self.execute_calls = 0
        self.rolled_back = False
        self.committed = False

    async def execute(self, stmt):  # type: ignore[no-untyped-def]
        self.execute_calls += 1
        if self.error is not None:
            raise self.error
        return _Result(self.rows)

    async def rollback(self) -> None:
        self.rolled_back = True

    async def commit(self) -> None:
        self.committed = True

    async def __aenter__(self) -> FakeSession:
        return self

    async def __aexit__(self, *exc) -> None:
        return None


class FakeFactory:
    def __init__(self, session: FakeSession) -> None:
        self.session = session

    def __call__(self) -> FakeSession:
        return self.session


class FakeClock:
    def __init__(self) -> None:
        self.now = 1000.0

    def advance(self, seconds: float) -> None:
        self.now += seconds


def _flag_row(**overrides) -> tuple:
    value = dict(DEFAULT_MCP_FLAG)
    value.update(overrides)
    return (value,)


# ─── 默认值 & 模型校验(D6)────────────────────────────────────────────────────
def test_default_flag_matches_migration_seed_and_validates() -> None:
    """默认值 = 迁移 0020 的 seed 行,且必须能通过 PUT 校验器(否则打开即非法态)。"""
    assert DEFAULT_MCP_FLAG == {
        "enabled": False,
        "max_concurrency": 8,
        "per_token_concurrency": 4,
        "per_token_rpm": 120,
        "per_ip_rpm": 600,
    }
    # 显式传默认值 / 全部省略(模型默认)都必须合法且结果一致
    assert McpSettingsIn(**DEFAULT_MCP_FLAG).model_dump() == DEFAULT_MCP_FLAG
    assert McpSettingsIn().model_dump() == DEFAULT_MCP_FLAG
    assert DEFAULT_MCP_SETTINGS.as_dict() == DEFAULT_MCP_FLAG


def test_invalid_combinations_rejected() -> None:
    """跨字段与区间校验(admin PUT 422 的唯一来源)。"""
    with pytest.raises(ValidationError):
        McpSettingsIn(max_concurrency=4, per_token_concurrency=5)
    with pytest.raises(ValidationError):
        McpSettingsIn(per_token_rpm=450, per_ip_rpm=600)
    with pytest.raises(ValidationError):
        McpSettingsIn(max_concurrency=9)
    with pytest.raises(ValidationError):
        McpSettingsIn(per_token_rpm=0)
    with pytest.raises(ValidationError):
        McpSettingsIn(per_ip_rpm=901)
    # 合法边界:per_token_concurrency == max_concurrency、per_ip_rpm == 2* rpm、上限
    ok = McpSettingsIn(
        enabled=True, max_concurrency=8, per_token_concurrency=8,
        per_token_rpm=450, per_ip_rpm=900,
    )
    assert ok.per_ip_rpm == 2 * ok.per_token_rpm


# ─── 读:真实 DB(行缺失回落默认值 / seed 行 = DB 当前值)─────────────────────
@pytest.mark.asyncio
async def test_read_seed_row_returns_db_value() -> None:
    """读命中 seed 行时必须返回 **DB 行当前值**(共享 dev 上管理员可能已开启,
    不得假定等于内置默认,也不为迁就测试去改 dev 的 mcp_channel)。"""
    from sqlalchemy import select

    from app.db.session import get_sessionmaker
    from app.db.tables import SystemFlag

    async with get_sessionmaker()() as db:
        row = (
            await db.execute(
                select(SystemFlag.value).where(SystemFlag.key == MCP_FLAG_KEY)
            )
        ).first()
    assert row is not None, "system_flags 缺 mcp_channel seed 行(迁移 0020 未跑?)"
    expected = dict(row[0])
    assert (await McpSettingsService(FakeRedis()).read()).as_dict() == expected


@pytest.mark.asyncio
async def test_read_row_missing_returns_default_and_backfills_redis() -> None:
    """行缺失 → 默认值(不自动插入),并回填 Redis EX 60。"""
    from sqlalchemy import delete

    from app.db.session import get_sessionmaker
    from app.db.tables import SystemFlag

    original = await _read_flag_row()  # 保存用例前的行(共享 dev 可能已开启)
    async with get_sessionmaker()() as db:
        await db.execute(delete(SystemFlag).where(SystemFlag.key == MCP_FLAG_KEY))
        await db.commit()
    redis = FakeRedis()
    try:
        value = await McpSettingsService(redis).read()
        assert value.as_dict() == DEFAULT_MCP_FLAG
        assert MCP_REDIS_KEY in redis.store
        assert redis.set_calls[-1][2] == MCP_FLAG_TTL_SECONDS
    finally:
        await _restore_flag_row(original)


async def _read_flag_row() -> dict | None:
    """直读 system_flags 的 mcp_channel 行(None = 行缺失)。"""
    from sqlalchemy import select

    from app.db.session import get_sessionmaker
    from app.db.tables import SystemFlag

    async with get_sessionmaker()() as db:
        row = (
            await db.execute(
                select(SystemFlag.value).where(SystemFlag.key == MCP_FLAG_KEY)
            )
        ).first()
    return None if row is None else dict(row[0])


async def _restore_flag_row(value: dict | None) -> None:
    """恢复用例前的 system_flags 行(不写内置默认覆盖管理员配置)。"""
    from sqlalchemy import delete
    from sqlalchemy.dialects.postgresql import insert as pg_insert

    from app.db.session import get_sessionmaker
    from app.db.tables import SystemFlag

    async with get_sessionmaker()() as db:
        if value is None:  # 原本无行 → 删回缺失态
            await db.execute(delete(SystemFlag).where(SystemFlag.key == MCP_FLAG_KEY))
        else:
            await db.execute(
                pg_insert(SystemFlag)
                .values(key=MCP_FLAG_KEY, value=value)
                .on_conflict_do_update(
                    index_elements=[SystemFlag.key], set_={"value": value},
                )
            )
        await db.commit()


# ─── 读:DBAPIError 全集(先 rollback 再回落默认值)───────────────────────────
@pytest.mark.asyncio
async def test_read_dbapi_error_rolls_back_then_default() -> None:
    """Redis 正常但未命中 + DB 抛 DBAPIError → 先 rollback 再回落默认值(不 500)。"""
    session = FakeSession(error=_DB_ERROR)
    svc = McpSettingsService(FakeRedis(), session_factory=FakeFactory(session))

    value = await svc.read()
    assert value.as_dict() == DEFAULT_MCP_FLAG
    assert session.rolled_back is True, "失败事务必须先 rollback(否则 InFailedSQLTransaction)"


@pytest.mark.asyncio
async def test_read_redis_and_db_double_failure_raises_and_negatively_caches() -> None:
    """Redis 读异常 + DB 回源失败 → McpSettingsUnavailable;5s 内不重复打 DB。"""
    session = FakeSession(error=_DB_ERROR)
    svc = McpSettingsService(
        FakeRedis(fail_get=True), session_factory=FakeFactory(session),
    )

    with pytest.raises(McpSettingsUnavailable):
        await svc.read()
    assert session.rolled_back is True
    assert session.execute_calls == 1

    # 负缓存:5s 内再读直接抛,不再触 DB/Redis
    with pytest.raises(McpSettingsUnavailable):
        await svc.read()
    assert session.execute_calls == 1


@pytest.mark.asyncio
async def test_read_redis_failure_falls_back_to_db() -> None:
    """Redis GET 异常,但 DB 可读 → 返回 DB 值(通道不因 Redis 抖动关闭)。"""
    session = FakeSession(rows=[_flag_row(enabled=True)])
    svc = McpSettingsService(
        FakeRedis(fail_get=True), session_factory=FakeFactory(session),
    )
    value = await svc.read()
    assert value.enabled is True
    assert session.rolled_back is False


@pytest.mark.asyncio
async def test_local_cache_ttl_5s() -> None:
    """进程内 5s 缓存:4s 内不重复回源,>5s 重新回源。"""
    clock = FakeClock()
    session = FakeSession(rows=[_flag_row()])
    # Redis GET 失败 ⇒ 本地缓存过期后必须回源 DB(Redis 正常时回填会命中 Redis,
    # 测不到本地 TTL;此处只关心进程内缓存窗口)
    svc = McpSettingsService(
        FakeRedis(fail_get=True),
        session_factory=FakeFactory(session),
        local_cache=LocalFlagCache(clock=lambda: clock.now),
    )
    await svc.read()
    assert session.execute_calls == 1

    clock.advance(4.0)
    await svc.read()
    assert session.execute_calls == 1, "5s 内应命中本地缓存"

    clock.advance(2.0)
    await svc.read()
    assert session.execute_calls == 2, "超过 5s 必须重新回源"


# ─── 写:upsert + 刷新缓存 / 表缺失 / Redis 失败路径 ──────────────────────────
@pytest.mark.asyncio
async def test_write_upserts_commits_and_publishes_redis() -> None:
    redis = FakeRedis()
    session = FakeSession()
    svc = McpSettingsService(redis, session_factory=FakeFactory(session))
    new_value = McpSettings.from_dict({
        "enabled": True, "max_concurrency": 6, "per_token_concurrency": 2,
        "per_token_rpm": 60, "per_ip_rpm": 300,
    })

    await svc.write(session, new_value)
    assert session.committed is True
    assert redis.set_calls[-1][0] == MCP_REDIS_KEY
    assert redis.set_calls[-1][2] == MCP_FLAG_TTL_SECONDS
    assert json.loads(redis.store[MCP_REDIS_KEY]) == new_value.as_dict()


@pytest.mark.asyncio
async def test_write_table_missing_raises_table_missing() -> None:
    """表缺失(迁移 0020 未跑)→ 专用异常(A3 映射 503「先跑 alembic 0020」)。"""
    from asyncpg.exceptions import UndefinedTableError

    err = ProgrammingError(
        "INSERT INTO system_flags ...", {}, UndefinedTableError("relation does not exist"),
    )
    session = FakeSession(error=err)
    svc = McpSettingsService(FakeRedis(), session_factory=FakeFactory(session))

    with pytest.raises(McpSettingsTableMissing):
        await svc.write(session, DEFAULT_MCP_SETTINGS)
    assert session.rolled_back is True


@pytest.mark.asyncio
async def test_write_redis_set_fail_del_succeeds() -> None:
    """SET 失败 → DEL 旧键(其他 worker 回源 DB);本进程写穿新值。"""
    redis = FakeRedis(fail_set=True)
    session = FakeSession()
    svc = McpSettingsService(redis, session_factory=FakeFactory(session))
    new_value = McpSettings.from_dict({"enabled": True})

    await svc.write(session, new_value)
    assert redis.delete_calls == [(MCP_REDIS_KEY,)]
    assert (await svc.read()).enabled is True


@pytest.mark.asyncio
async def test_write_redis_set_and_del_fail_write_through_local_cache() -> None:
    """SET 与 DEL 都失败 → 仍写穿本进程缓存(其他 worker 靠 TTL 60s 过期)。"""
    redis = FakeRedis(fail_set=True, fail_delete=True)
    session = FakeSession()
    svc = McpSettingsService(redis, session_factory=FakeFactory(session))
    new_value = McpSettings.from_dict({"enabled": True, "max_concurrency": 2,
                                       "per_token_concurrency": 2})

    await svc.write(session, new_value)
    assert redis.delete_calls == [(MCP_REDIS_KEY,)]

    # 本地缓存命中:不会触 DB/Redis,直接返回新值
    value = await svc.read()
    assert value.enabled is True
    assert value.max_concurrency == 2


@pytest.mark.asyncio
async def test_write_row_missing_upsert_then_read_back() -> None:
    """真实 DB:行缺失时 write 可 upsert(管理员自救),读回一致;收尾恢复原行。"""
    from sqlalchemy import delete, select

    from app.db.session import get_sessionmaker
    from app.db.tables import SystemFlag

    original = await _read_flag_row()  # 保存用例前的行(共享 dev 可能已开启)
    async with get_sessionmaker()() as db:
        await db.execute(delete(SystemFlag).where(SystemFlag.key == MCP_FLAG_KEY))
        await db.commit()

    new_value = McpSettings.from_dict({
        "enabled": True, "max_concurrency": 2, "per_token_concurrency": 2,
        "per_token_rpm": 30, "per_ip_rpm": 60,
    })
    try:
        async with get_sessionmaker()() as db:
            await McpSettingsService(None).write(db, new_value)

        async with get_sessionmaker()() as db:
            row = (
                await db.execute(
                    select(SystemFlag.value).where(SystemFlag.key == MCP_FLAG_KEY)
                )
            ).scalar_one()
        assert row == new_value.as_dict()
    finally:
        await _restore_flag_row(original)


# ─── from_dict 防御(Redis/DB 内容非法 → ValueError,由 read 回落)──────────────
def test_from_dict_invalid_payload_raises_value_error() -> None:
    with pytest.raises(ValueError):
        McpSettings.from_dict("not-json")
    with pytest.raises(ValueError):
        McpSettings.from_dict({"enabled": "maybe"})
    with pytest.raises(ValueError):
        McpSettings.from_dict([1, 2, 3])
    # bytes / JSON 字符串均可解析
    assert McpSettings.from_dict(json.dumps(DEFAULT_MCP_FLAG)).as_dict() == DEFAULT_MCP_FLAG
    assert McpSettings.from_dict(
        json.dumps(DEFAULT_MCP_FLAG).encode()
    ).as_dict() == DEFAULT_MCP_FLAG
