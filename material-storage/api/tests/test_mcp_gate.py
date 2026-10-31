"""``mcp_gate``(第六步两级 ZSET 并发闸)+ 挂载点回归 — 单元/Redis 集成测试。

需求:`docs/qdev/2026-10-30-mcp-service.md` C.6(单个 Lua 含全局拒回滚、
``MCP_CONC_LEASE_SECONDS`` 可注入、finally ZREM 只 log)+ 测试功能点
「四段闸」「ZSET 闸不泄漏不清零」「闸挂载点回归」。

运行位置:dev 容器(需 **ms-redis**;不经 HTTP/DB —— 直接驱动 async generator,
请求对象手造,key 用随机 token_id 隔离)。
"""
from __future__ import annotations

import asyncio
import uuid
from types import SimpleNamespace
from typing import Any

import pytest
import redis.asyncio as redis_asyncio
from fastapi import HTTPException, Request
from httpx import ASGITransport, AsyncClient

from app.deps import CurrentUser
from app.main import create_app
from app.services.mcp_gate import (
    DEFAULT_LEASE_SECONDS,
    LEASE_ENV_VAR,
    gate_routes_ok,
    lease_seconds,
    mcp_gate,
    route_template,
    set_gate_routes_ok,
    validate_gate_routes,
)
from app.services.mcp_limiter import (
    CONC_GLOBAL_KEY,
    acquire_concurrency,
    conc_token_key,
    in_flight,
)
from app.services.mcp_settings import McpSettings
from app.settings import get_settings


@pytest.fixture(scope="session")
async def redis_client():
    settings = get_settings()
    client = redis_asyncio.from_url(str(settings.redis_url), decode_responses=True)
    try:
        await client.ping()
    except Exception:
        pytest.skip("Redis 不可达:本文件需 ms-redis(dev 容器内跑)")
    yield client
    await client.aclose()


def make_request(
    *,
    token_id: uuid.UUID,
    redis: Any,
    flag: McpSettings | None = None,
    auth_method: str = "pat",
) -> Request:
    request = Request({
        "type": "http",
        "http_version": "1.1",
        "method": "GET",
        "scheme": "http",
        "path": "/api/v1/projects",
        "raw_path": b"/api/v1/projects",
        "query_string": b"",
        "root_path": "",
        "headers": [],
        "client": ("10.9.9.9", 5000),
        "server": ("test", 80),
        "app": SimpleNamespace(state=SimpleNamespace(redis=redis)),
        "state": {},
    })
    request.state.auth_method = auth_method
    request.state.mcp_flag = flag or McpSettings(True, 8, 4, 120, 600)
    request.state.auth_token_id = token_id
    return request


async def _enter(request: Request) -> Any:
    """驱动 yield 依赖到「已占位」状态;被拒时抛 HTTPException。"""
    user = CurrentUser(id=uuid.uuid4(), name="pat-user")
    agen = mcp_gate(request, user=user)
    await agen.__anext__()
    return agen


async def _async_cleanup(redis: Any, *keys: str) -> None:
    await redis.delete(*keys)


# ─── 1) session 请求 no-op ───────────────────────────────────────────────────
async def test_session_request_is_noop_without_redis() -> None:
    class _NoRedis:
        def __getattr__(self, name: str) -> Any:  # 任何访问都算失败
            raise AssertionError(f"session 请求不应触碰 Redis({name})")

    request = make_request(token_id=uuid.uuid4(), redis=_NoRedis(), auth_method="session")
    agen = await _enter(request)
    await agen.aclose()


# ─── 2) 占位/释放 ───────────────────────────────────────────────────────────
async def test_pat_acquires_and_releases_both_gates(redis_client: Any) -> None:
    token_id = uuid.uuid4()
    before = int(await in_flight(redis_client))
    request = make_request(token_id=token_id, redis=redis_client)
    agen = await _enter(request)
    assert int(await redis_client.zcard(conc_token_key(token_id))) == 1
    assert int(await in_flight(redis_client)) == before + 1
    await agen.aclose()
    assert int(await redis_client.zcard(conc_token_key(token_id))) == 0
    assert int(await in_flight(redis_client)) == before


# ─── 3) 饱和 → 429 + Retry-After ───────────────────────────────────────────
async def test_per_token_saturation_429_then_recovers(redis_client: Any) -> None:
    token_id = uuid.uuid4()
    flag = McpSettings(True, 8, 1, 120, 600)  # per_token_concurrency=1
    first = await _enter(make_request(token_id=token_id, redis=redis_client, flag=flag))
    second_request = make_request(token_id=token_id, redis=redis_client, flag=flag)
    with pytest.raises(HTTPException) as exc:
        await _enter(second_request)
    assert exc.value.status_code == 429
    assert exc.value.headers is not None
    assert exc.value.headers.get("Retry-After") == "1"
    assert second_request.state.mcp_reject_reason == "quota_conc"
    await first.aclose()
    third = await _enter(make_request(token_id=token_id, redis=redis_client, flag=flag))
    await third.aclose()


async def test_global_reject_does_not_self_fill_per_token(redis_client: Any) -> None:
    """★ 全局拒必须回滚 per-token,否则被拒请求把同令牌配额塞满。"""
    token_a, token_b = uuid.uuid4(), uuid.uuid4()
    flag = McpSettings(True, 1, 4, 120, 600)
    holder = await _enter(make_request(token_id=token_a, redis=redis_client, flag=flag))
    rejection = make_request(token_id=token_b, redis=redis_client, flag=flag)
    with pytest.raises(HTTPException) as exc:
        await _enter(rejection)
    assert exc.value.status_code == 429
    # 被拒的 per-token 成员已回滚(不自我塞满)
    assert int(await redis_client.zcard(conc_token_key(token_b))) == 0
    await holder.aclose()
    # 全局空闲后,同 token 立即可进
    retry = await _enter(make_request(token_id=token_b, redis=redis_client, flag=flag))
    assert int(await redis_client.zcard(conc_token_key(token_b))) == 1
    await retry.aclose()


# ─── 4) ZSET 自愈(注入短租约)──────────────────────────────────────────────
async def test_zset_self_heals_after_short_lease(
    redis_client: Any, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """崩溃请求(不 finally 释放)靠租约过期回收:注入 1s 租约,~1.2s 后可再进。"""
    monkeypatch.setenv(LEASE_ENV_VAR, "1")
    assert lease_seconds() == 1
    token_id = uuid.uuid4()
    crashed = uuid.uuid4().hex
    acquired = await acquire_concurrency(
        redis_client, token_id=token_id, req_id=crashed,
        lease_seconds=lease_seconds(), max_token=1, max_global=8,
    )
    assert acquired
    # 未释放(模拟进程被杀)→ 立即再进必被拒(该令牌名额被占)
    assert not await acquire_concurrency(
        redis_client, token_id=token_id, req_id=uuid.uuid4().hex,
        lease_seconds=1, max_token=1, max_global=8,
    )
    await asyncio.sleep(1.2)
    request = make_request(token_id=token_id, redis=redis_client, flag=McpSettings(True, 8, 1, 120, 600))
    agen = await _enter(request)  # 过期成员被 ZREMRANGEBYSCORE 清理
    await agen.aclose()
    await _async_cleanup(redis_client, conc_token_key(token_id))


# ─── 5) 释放失败只 log ─────────────────────────────────────────────────────
async def test_release_failure_does_not_raise(redis_client: Any) -> None:
    class _ReleaseFail:
        def __getattr__(self, name: str) -> Any:
            if name == "zrem":
                async def _boom(*args: Any, **kwargs: Any) -> None:
                    raise ConnectionError("redis down(zrem)")
                return _boom
            return getattr(redis_client, name)

    token_id = uuid.uuid4()
    # 失败路径:两闸的 ZREM 全部抛 → per-token 键与 global 成员都留下(租约自愈)。
    # 收尾必须两个都清(只删 per-token 会泄漏 global 成员 600s,占掉 1/8 全局配额
    # 并污染 in_flight)。req_id 在 gate 内部生成拿不到 → 用「前后差集」定位本用例成员。
    before_global = set(await redis_client.zrange(CONC_GLOBAL_KEY, 0, -1))
    leaked: set[str] = set()
    request = make_request(token_id=token_id, redis=_ReleaseFail())
    try:
        agen = await _enter(request)
        await agen.aclose()  # 不抛
        leaked = set(await redis_client.zrange(CONC_GLOBAL_KEY, 0, -1)) - before_global
        assert len(leaked) == 1, "前提:ZREM 失败确实留下 1 个 global 成员(靠租约自愈)"
    finally:
        if leaked:
            await redis_client.zrem(CONC_GLOBAL_KEY, *leaked)
        await _async_cleanup(redis_client, conc_token_key(token_id))
    # 跑完全局闸不得残留本用例成员
    assert not (set(await redis_client.zrange(CONC_GLOBAL_KEY, 0, -1)) - before_global)


# ─── 6) 启动自检 ───────────────────────────────────────────────────────────
async def test_gate_routes_broken_makes_pat_403(redis_client: Any) -> None:
    set_gate_routes_ok(False)
    try:
        request = make_request(token_id=uuid.uuid4(), redis=redis_client)
        with pytest.raises(HTTPException) as exc:
            await _enter(request)
        assert exc.value.status_code == 403
        assert request.state.mcp_reject_reason == "channel_unavailable"
    finally:
        set_gate_routes_ok(True)


async def test_validate_gate_routes_detects_missing_templates() -> None:
    fake_app = SimpleNamespace(routes=[])
    try:
        assert await validate_gate_routes(fake_app) is False
        assert gate_routes_ok() is False
    finally:
        await _restore_gate_flag()


async def _restore_gate_flag() -> None:
    app = create_app()
    assert await validate_gate_routes(app) is True
    assert gate_routes_ok() is True


def test_lease_env_parsing(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv(LEASE_ENV_VAR, raising=False)
    assert lease_seconds() == DEFAULT_LEASE_SECONDS == 600
    monkeypatch.setenv(LEASE_ENV_VAR, "3")
    assert lease_seconds() == 3
    monkeypatch.setenv(LEASE_ENV_VAR, "abc")
    assert lease_seconds() == DEFAULT_LEASE_SECONDS
    monkeypatch.setenv(LEASE_ENV_VAR, "0")
    assert lease_seconds() == DEFAULT_LEASE_SECONDS


def test_route_template_falls_back_to_scope_route() -> None:
    request = Request({
        "type": "http",
        "method": "GET",
        "path": "/api/v1/x/1",
        "headers": [],
        "route": SimpleNamespace(path="/api/v1/x/{x_id}"),
        "state": {},
    })
    assert route_template(request) == "/api/v1/x/{x_id}"


# ─── 7) 挂载点回归:闸未挂在 app 级 ─────────────────────────────────────────
async def test_healthz_maintenance_login_survive_broken_gate(redis_client: Any) -> None:
    """闸自检失败(= 最严)时:/healthz、/maintenance/banner、/auth/local/login 不被挡。"""
    app = create_app()
    app.state.redis = redis_client
    set_gate_routes_ok(False)
    try:
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as ac:
            r = await ac.get("/healthz")
            assert r.status_code == 200
            r = await ac.get("/api/v1/maintenance/banner")
            assert r.status_code == 200
            # 未配置 OIDC/local_auth 的裸 app 会 500,但**绝不能**是 403(被闸挡死)
            r = await ac.post(
                "/api/v1/auth/local/login", json={"username": "x", "password": "y"},
            )
            assert r.status_code != 403
    finally:
        set_gate_routes_ok(True)
