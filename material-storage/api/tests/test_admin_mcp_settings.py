"""GET/PUT /api/v1/admin/mcp-settings 集成测试(MCP 素材服务包 A3)。

需求依据:`docs/qdev/2026-10-30-mcp-service.md`(接口定义 B、D5/D6/D11、
测试功能点「配置缺失自救」「测试钩子」「PM 验收 10/12」)。覆盖:
  - GET:配置五字段 + 六个实时指标字段存在且类型正确;
  - PUT 成功:写 DB(system_flags)+ 审计 mcp_settings_changed(details 用既有
    changes 结构)+ 响应与 GET 同形;写后 GET 读到新值;
  - 非法组合(per_token_concurrency > max_concurrency、per_ip_rpm < 2*rpm)
    → 422(由 McpSettingsIn 的跨字段校验产生,不落库);
  - 表缺失(monkeypatch 让 write 抛 McpSettingsTableMissing)→ 503 + alembic 文案;
  - Redis 挂:指标字段 null、配置体正常返回(不 500);
  - in_flight = ZCOUNT mcp:conc:global now +inf(过期未裁剪成员不计入,证明不是
    ZCARD 口径);today_* = mcp:stats:{bucket}:{UTC yyyyMMdd}(缺失 = 0);
  - 非系统管理员 → 403。

预期前置(同 tests/test_usage_stats.py):seed_demo_data 已跑(Evan=system admin)、
OpenFGA 已 push、env=dev(允许 X-User-Id header 模拟身份)、迁移 0020 已 upgrade。
配置服务取 A2 在 lifespan 构造的 `app.state.mcp_settings`;本文件通过替换该
state(及 `app.state.redis`)注入故障,收尾由 _restore_state 恢复。

清理惯例:**保存‑恢复**用例前的通道配置(不得假定原值 = 内置默认:共享 dev 上
管理员可能已开启)。teardown 写回用例前的 DB 行(原本无行则删回缺失态),并刷新
``mcp:flag`` / 进程内缓存,避免污染后续用例与共享环境。
"""
from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import create_app
from app.services.mcp_settings import (
    DEFAULT_MCP_FLAG,
    DEFAULT_MCP_SETTINGS,
    MCP_FLAG_KEY,
    MCP_REDIS_KEY,
    McpSettings,
    McpSettingsService,
    McpSettingsTableMissing,
)

EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"  # system admin
BOB_ID = "00000000-0000-0000-0000-000000000002"   # 普通 member
URL = "/api/v1/admin/mcp-settings"
CONC_KEY = "mcp:conc:global"


@pytest.fixture(scope="session")
async def app_with_lifespan():
    app = create_app()
    async with app.router.lifespan_context(app):  # type: ignore[attr-defined]
        yield app


@pytest.fixture(scope="session")
async def client(app_with_lifespan):
    transport = ASGITransport(app=app_with_lifespan)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


@pytest.fixture(autouse=True)
async def _restore_state(app_with_lifespan):
    """用例后恢复 app.state 的 mcp_settings/redis,并**保存‑恢复**通道配置。

    原值可能是管理员已开启的配置(共享 dev),teardown 必须写回用例前的 DB 行,
    不能无条件写内置默认(那会把线上通道关掉)。原本无行 → 删回「行缺失」。
    恢复走服务层直写(不经过 admin PUT):避免为清理额外制造
    ``mcp_settings_changed`` 审计行、干扰本文件自己的审计断言。
    """
    state = app_with_lifespan.state
    prev_service = getattr(state, "mcp_settings", None)
    prev_redis = getattr(state, "redis", None)
    original = await _db_flag_value()  # None = 用例前就没有行
    try:
        yield
    finally:
        state.redis = prev_redis
        state.mcp_settings = prev_service
        await _restore_channel(prev_service, prev_redis, original)


async def _restore_channel(service: object, redis: object, original: object) -> None:
    """把通道配置写回用例前的状态(行存在 → upsert + 刷缓存;行缺失 → 删回缺失)。"""
    if not isinstance(service, McpSettingsService):
        # lifespan 之外的 app(_TableMissingService 等)没有可用的正本写入口
        return
    service.reset_local_cache()
    if isinstance(original, dict):
        from app.db.session import get_sessionmaker

        async with get_sessionmaker()() as db:
            # write = upsert + commit + publish(刷 mcp:flag EX 60 与本进程缓存)
            await service.write(db, McpSettings.from_dict(original))
    else:
        from sqlalchemy import delete

        from app.db.session import get_sessionmaker
        from app.db.tables import SystemFlag

        async with get_sessionmaker()() as db:
            await db.execute(delete(SystemFlag).where(SystemFlag.key == MCP_FLAG_KEY))
            await db.commit()
        # 行缺失:Redis 缓存也要清(否则残留测试写入的值)
        if redis is not None:
            await redis.delete(MCP_REDIS_KEY)  # type: ignore[attr-defined]
    service.reset_local_cache()  # 让后续用例回源 DB/Redis


def _h(user_id: str) -> dict[str, str]:
    return {"X-User-Id": user_id}


class _FailingRedis:
    """指标/配置读取用的故障 Redis(get/zcount 全抛)。"""

    async def get(self, key: str) -> str | None:
        raise ConnectionError(f"redis down(get {key})")

    async def zcount(self, key: str, minimum: object, maximum: object) -> int:
        raise ConnectionError(f"redis down(zcount {key})")


class _TableMissingService(McpSettingsService):
    """write 抛表缺失的 McpSettingsService(同 isinstance 契约,端点原样使用)。"""

    def __init__(self) -> None:
        super().__init__(None)

    async def read(self) -> McpSettings:  # type: ignore[override]
        return DEFAULT_MCP_SETTINGS

    async def write(self, db, value) -> None:  # type: ignore[no-untyped-def,override]
        raise McpSettingsTableMissing("system_flags 不存在")


async def _db_flag_value() -> object:
    from sqlalchemy import select

    from app.db.session import get_sessionmaker
    from app.db.tables import SystemFlag
    from app.services.mcp_settings import MCP_FLAG_KEY

    async with get_sessionmaker()() as db:
        row = (
            await db.execute(
                select(SystemFlag.value).where(SystemFlag.key == MCP_FLAG_KEY)
            )
        ).first()
    return None if row is None else row[0]


async def _mcp_settings_audits(since: datetime) -> list[dict]:
    """取 since 之后的 mcp_settings_changed 审计 details(只读,不清理)。"""
    from sqlalchemy import select

    from app.db.session import get_sessionmaker
    from app.db.tables import AuditEvent

    async with get_sessionmaker()() as db:
        rows = (
            await db.execute(
                select(AuditEvent.details).where(
                    AuditEvent.event_type == "mcp_settings_changed",
                    AuditEvent.event_time >= since,
                )
            )
        ).scalars().all()
    return [dict(r) for r in rows]


# ─── GET:配置五字段 + 指标六字段存在且类型正确 ───────────────────────────────
async def test_get_config_and_metric_shape(client: AsyncClient) -> None:
    r = await client.get(URL, headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    body = r.json()
    for key, typ in (
        ("enabled", bool),
        ("max_concurrency", int),
        ("per_token_concurrency", int),
        ("per_token_rpm", int),
        ("per_ip_rpm", int),
    ):
        assert key in body, body
        assert isinstance(body[key], typ), (key, body[key])
    for key in (
        "in_flight", "today_success", "today_rejected_policy",
        "today_rejected_quota", "rejected_infra_since_start",
        "dynamic_signers_cap_hits",
    ):
        assert key in body, f"指标字段缺失: {key}; body={body}"
    # Redis 正常时这四个是 int(缺失计数键 = 0);进程内计数同样非负
    assert isinstance(body["in_flight"], int), body["in_flight"]
    assert isinstance(body["today_success"], int), body["today_success"]
    assert isinstance(body["today_rejected_policy"], int)
    assert isinstance(body["today_rejected_quota"], int)
    if body["rejected_infra_since_start"] is not None:  # A2 未落地时该模块缺失 → null
        assert isinstance(body["rejected_infra_since_start"], int)
    assert isinstance(body["dynamic_signers_cap_hits"], int)


# ─── 行缺失:GET 回默认值(通道默认关,不自动插入)──────────────────────────
async def test_get_falls_back_to_defaults_when_row_missing(
    client: AsyncClient, app_with_lifespan,
) -> None:
    # 删 system_flags 行 + mcp:flag 缓存 + 本进程缓存(行缺失语义:GET 回默认,
    # 不自动插入;PUT 才 upsert,见 test_put_*)
    from sqlalchemy import delete

    from app.db.session import get_sessionmaker
    from app.db.tables import SystemFlag

    async with get_sessionmaker()() as db:
        await db.execute(delete(SystemFlag).where(SystemFlag.key == MCP_FLAG_KEY))
        await db.commit()
    await app_with_lifespan.state.redis.delete(MCP_REDIS_KEY)
    service = app_with_lifespan.state.mcp_settings
    if isinstance(service, McpSettingsService):
        service.reset_local_cache()

    body = (await client.get(URL, headers=_h(EVAN_ID))).json()
    assert body["enabled"] is False, "通道默认关闭"
    assert body["max_concurrency"] == 8
    assert body["per_token_concurrency"] == 4
    assert body["per_token_rpm"] == 120
    assert body["per_ip_rpm"] == 600


# ─── PUT:写库 + 审计 changes + 写后 GET 一致 ─────────────────────────────────
async def test_put_writes_db_audit_then_get(client: AsyncClient) -> None:
    start = datetime.now(UTC) - timedelta(seconds=5)
    before = await _db_flag_value()
    before_enabled = bool(before.get("enabled")) if isinstance(before, dict) else False
    payload = {
        "enabled": True,
        "max_concurrency": 6,
        "per_token_concurrency": 2,
        "per_token_rpm": 60,
        "per_ip_rpm": 300,
    }
    r = await client.put(URL, json=payload, headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    body = r.json()
    assert {k: body[k] for k in payload} == payload
    assert "in_flight" in body and "today_success" in body

    # DB 正本(system_flags.value)
    assert await _db_flag_value() == payload

    # GET 读回同一配置
    got = (await client.get(URL, headers=_h(EVAN_ID))).json()
    assert {k: got[k] for k in payload} == payload

    # 审计:mcp_settings_changed,details 用既有 changes 结构({字段:{old,new}})
    audits = await _mcp_settings_audits(start)
    matched = [
        a for a in audits
        if isinstance(a.get("changes"), dict)
        and a["changes"].get("enabled") == {"old": before_enabled, "new": True}
    ]
    assert matched, f"未找到 changes.enabled old/new 正确的审计: {audits}"
    changes = matched[0]["changes"]
    assert set(changes) == set(payload), changes
    for field in payload:
        assert set(changes[field]) == {"old", "new"}, changes[field]
        assert changes[field]["new"] == payload[field], changes[field]


# ─── 非法组合 → 422(跨字段校验,不落库)────────────────────────────────────
async def test_put_invalid_combinations_422(client: AsyncClient) -> None:
    before = await _db_flag_value()
    bad_cases = [
        # per_token_concurrency(8)> max_concurrency(4)
        {"enabled": True, "max_concurrency": 4, "per_token_concurrency": 8,
         "per_token_rpm": 60, "per_ip_rpm": 300},
        # per_ip_rpm(100)< 2 * per_token_rpm(120)
        {"enabled": True, "max_concurrency": 8, "per_token_concurrency": 4,
         "per_token_rpm": 120, "per_ip_rpm": 100},
        # 越界:max_concurrency 0 / per_ip_rpm 901
        {"enabled": True, "max_concurrency": 0, "per_token_concurrency": 4,
         "per_token_rpm": 60, "per_ip_rpm": 300},
        {"enabled": True, "max_concurrency": 8, "per_token_concurrency": 4,
         "per_token_rpm": 120, "per_ip_rpm": 901},
    ]
    for case in bad_cases:
        r = await client.put(URL, json=case, headers=_h(EVAN_ID))
        assert r.status_code == 422, (case, r.text)
    assert await _db_flag_value() == before, "422 不得落库"


# ─── 表缺失(迁移 0020 未跑)→ 503 + alembic 文案 ─────────────────────────────
async def test_put_table_missing_503(
    client: AsyncClient, app_with_lifespan,
) -> None:
    # 直接替换 state(由 _restore_state 收尾恢复),避免 monkeypatch 与 fixture
    # 的撤销顺序把 fake 余留给后续用例
    app_with_lifespan.state.mcp_settings = _TableMissingService()
    r = await client.put(URL, json=DEFAULT_MCP_FLAG, headers=_h(EVAN_ID))
    assert r.status_code == 503, r.text
    detail = r.json()["detail"]
    assert "alembic" in detail and "0020" in detail, detail


# ─── Redis 挂:指标 null,配置体正常返回(不 500)──────────────────────────────
async def test_redis_down_metrics_null_config_ok(
    client: AsyncClient, app_with_lifespan,
) -> None:
    failing = _FailingRedis()
    app_with_lifespan.state.redis = failing
    # 让配置服务也用故障 Redis(DB 仍可用 → 服务层回源 DB / 回落默认值)
    app_with_lifespan.state.mcp_settings = McpSettingsService(failing)  # type: ignore[arg-type]

    r = await client.get(URL, headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    body = r.json()
    # 配置体正常(五字段齐全)
    for key in ("enabled", "max_concurrency", "per_token_concurrency",
                "per_token_rpm", "per_ip_rpm"):
        assert key in body, body
    # Redis 指标读取失败 → null(不得 500 / 不得抛)
    for key in ("in_flight", "today_success", "today_rejected_policy",
                "today_rejected_quota"):
        assert body[key] is None, (key, body[key])


# ─── in_flight = ZCOUNT now +inf(过期成员不计入,证明非 ZCARD)─────────────────
async def test_in_flight_uses_zcount_now_inf(
    client: AsyncClient, app_with_lifespan,
) -> None:
    redis = app_with_lifespan.state.redis
    member_fresh = f"test:fresh:{uuid.uuid4().hex}"
    member_stale = f"test:stale:{uuid.uuid4().hex}"
    now_ms = int(datetime.now(UTC).timestamp() * 1000)
    try:
        before = int(await redis.zcount(CONC_KEY, now_ms, "+inf"))
        await redis.zadd(CONC_KEY, {member_fresh: now_ms + 600_000})
        await redis.zadd(CONC_KEY, {member_stale: now_ms - 60_000})
        body = (await client.get(URL, headers=_h(EVAN_ID))).json()
        # 过期未裁剪的成员不计入(ZCOUNT 口径;ZCARD 会多算 stale)
        assert body["in_flight"] == before + 1, (body["in_flight"], before)
    finally:
        await redis.zrem(CONC_KEY, member_fresh, member_stale)


# ─── today_* = mcp:stats:{bucket}:{UTC yyyyMMdd}(缺失 = 0)────────────────────
async def test_today_stats_keys_utc(client: AsyncClient, app_with_lifespan) -> None:
    redis = app_with_lifespan.state.redis
    day = datetime.now(UTC).strftime("%Y%m%d")
    keys = {
        "today_success": f"mcp:stats:requests:{day}",
        "today_rejected_policy": f"mcp:stats:rejected_policy:{day}",
        "today_rejected_quota": f"mcp:stats:rejected_quota:{day}",
    }
    previous: dict[str, str | None] = {}
    try:
        for key in keys.values():
            previous[key] = await redis.get(key)
            await redis.set(key, "0", ex=900)
        await redis.set(keys["today_success"], "7", ex=900)
        await redis.set(keys["today_rejected_policy"], "3", ex=900)
        await redis.set(keys["today_rejected_quota"], "2", ex=900)
        body = (await client.get(URL, headers=_h(EVAN_ID))).json()
        assert body["today_success"] == 7, body
        assert body["today_rejected_policy"] == 3, body
        assert body["today_rejected_quota"] == 2, body
    finally:
        for key, old in previous.items():
            if old is None:
                await redis.delete(key)
            else:
                await redis.set(key, old, ex=900)


# ─── 非系统管理员 → 403 ──────────────────────────────────────────────────────
async def test_non_admin_403(client: AsyncClient) -> None:
    assert (await client.get(URL, headers=_h(BOB_ID))).status_code == 403
    r = await client.put(URL, json=DEFAULT_MCP_FLAG, headers=_h(BOB_ID))
    assert r.status_code == 403, r.text
