"""MCP 通道统计中间件(纯 ASGI)— 分桶口径 + 不误计 + 故障不外溢。

需求:`docs/qdev/2026-10-30-mcp-service.md` D11 / C.6「通道统计计数」+
测试功能点「统计中间件:关闭期拒绝量递增;业务 403 不计;Redis 挂时 metrics 不炸」。

覆盖:
- 只认 ``auth_method == "pat"``;session(+手带 mspat 头)不误计;
  无 auth_method(认证未完成即被拒)时仅以 ``Authorization: Bearer mspat_`` 兜底;
- 2xx → ``mcp:stats:requests:{yyyyMMdd}``(UTC 日);拒绝量按 reason 分桶
  (policy / quota → Redis;infra → 进程内);业务 403 / 401 / 400 / 404 / 500 不计;
- Redis 异常只 log(响应不受影响);非 http scope 直通。
"""
from __future__ import annotations

import asyncio
import uuid
from types import SimpleNamespace
from typing import Any

import pytest
import redis.asyncio as redis_asyncio
from fastapi import Request
from httpx import ASGITransport, AsyncClient

from app.deps import CurrentUser, get_current_user
from app.main import create_app
from app.middleware.mcp_stats import MCPStatsMiddleware, _is_pat_request
from app.services.mcp_metrics import (
    BUCKET_REJECTED_POLICY,
    BUCKET_REJECTED_QUOTA,
    BUCKET_REQUESTS,
    STATS_TTL_SECONDS,
    infra_rejects_since_start,
    reset_infra_rejects,
    stats_key,
    utc_day,
)
from app.services.mcp_settings import McpSettings
from app.settings import get_settings


class FakeRedis:
    """mcp_metrics 用到的接口子集(incr / expire)。"""

    def __init__(self, *, fail_incr: bool = False) -> None:
        self.counters: dict[str, int] = {}
        self.expires: dict[str, int] = {}
        self.fail_incr = fail_incr

    async def incr(self, key: str) -> int:
        if self.fail_incr:
            raise ConnectionError("redis down(incr)")
        self.counters[key] = self.counters.get(key, 0) + 1
        return self.counters[key]

    async def expire(self, key: str, ttl: int) -> bool:
        self.expires[key] = ttl
        return True


class _InnerApp:
    """假下游:按给定 status 回包,并在 state 里写 auth_method / reject_reason。"""

    def __init__(
        self,
        *,
        status: int = 200,
        state: dict[str, Any] | None = None,
    ) -> None:
        self.status = status
        self.state = state or {}

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        scope.setdefault("state", {}).update(self.state)
        await send({"type": "http.response.start", "status": self.status, "headers": []})
        await send({"type": "http.response.body", "body": b"{}"})


def make_scope(
    *, redis: Any, bearer: str | None = None, scope_type: str = "http",
) -> dict[str, Any]:
    headers: list[tuple[bytes, bytes]] = []
    if bearer is not None:
        headers.append((b"authorization", bearer.encode("latin-1")))
    return {
        "type": scope_type,
        "http_version": "1.1",
        "method": "GET",
        "scheme": "http",
        "path": "/api/v1/projects",
        "raw_path": b"/api/v1/projects",
        "query_string": b"",
        "root_path": "",
        "headers": headers,
        "client": ("10.9.9.1", 5000),
        "server": ("test", 80),
        "app": SimpleNamespace(state=SimpleNamespace(redis=redis)),
        "state": {},
    }


async def _drive(mw: MCPStatsMiddleware, scope: dict[str, Any]) -> list[dict[str, Any]]:
    sent: list[dict[str, Any]] = []

    async def send(message: dict[str, Any]) -> None:
        sent.append(message)

    async def receive() -> dict[str, Any]:
        return {"type": "http.request", "body": b"", "more_body": False}

    await mw(scope, receive, send)
    return sent


# ─── 1) 计数判定 ───────────────────────────────────────────────────────────
async def test_pat_2xx_counts_requests() -> None:
    redis = FakeRedis()
    inner = _InnerApp(status=200, state={"auth_method": "pat"})
    sent = await _drive(MCPStatsMiddleware(inner), make_scope(redis=redis))
    assert sent[0]["status"] == 200
    key = stats_key(BUCKET_REQUESTS)
    assert redis.counters == {key: 1}
    assert redis.expires[key] == STATS_TTL_SECONDS == 8 * 86400
    assert key.startswith("mcp:stats:requests:")
    assert key.endswith(utc_day())
    assert len(utc_day()) == 8 and utc_day().isdigit()


async def test_session_request_with_pat_header_is_not_counted() -> None:
    """有效 session + 手带 mspat 头不得误计(只认 auth_method)。"""
    redis = FakeRedis()
    inner = _InnerApp(status=200, state={"auth_method": "session"})
    scope = make_scope(redis=redis, bearer="Bearer mspat_abcdef")
    await _drive(MCPStatsMiddleware(inner), scope)
    assert redis.counters == {}


async def test_auth_method_missing_uses_bearer_fallback() -> None:
    redis = FakeRedis()
    inner = _InnerApp(status=200, state={})
    await _drive(MCPStatsMiddleware(inner), make_scope(redis=redis, bearer="bearer mspat_x"))
    assert redis.counters == {stats_key(BUCKET_REQUESTS): 1}


async def test_authorization_non_bearer_or_non_pat_is_not_counted() -> None:
    redis = FakeRedis()
    await _drive(
        MCPStatsMiddleware(_InnerApp(status=200)),
        make_scope(redis=redis, bearer="Basic abc"),
    )
    await _drive(
        MCPStatsMiddleware(_InnerApp(status=200)),
        make_scope(redis=redis, bearer="Bearer some-jwt"),
    )
    assert redis.counters == {}


@pytest.mark.parametrize(
    ("reason", "expected_bucket"),
    [
        ("channel_closed", BUCKET_REJECTED_POLICY),
        ("pat_forbidden", BUCKET_REJECTED_POLICY),
        ("forced_change", BUCKET_REJECTED_POLICY),
        ("quota_ip", BUCKET_REJECTED_QUOTA),
        ("quota_rpm", BUCKET_REJECTED_QUOTA),
        ("quota_conc", BUCKET_REJECTED_QUOTA),
        ("quota_batch", BUCKET_REJECTED_QUOTA),
    ],
)
async def test_reject_reasons_are_bucketed_by_reason_not_status(
    reason: str, expected_bucket: str,
) -> None:
    """状态码不可靠(业务 403 也是 403):按 reason 分桶,不看 status。"""
    redis = FakeRedis()
    inner = _InnerApp(status=403, state={"auth_method": "pat", "mcp_reject_reason": reason})
    await _drive(MCPStatsMiddleware(inner), make_scope(redis=redis))
    assert redis.counters == {stats_key(expected_bucket): 1}


@pytest.mark.parametrize("reason", ["channel_unavailable", "redis_down"])
async def test_infra_reasons_are_in_process_only(reason: str) -> None:
    reset_infra_rejects()
    redis = FakeRedis()
    inner = _InnerApp(status=503, state={"auth_method": "pat", "mcp_reject_reason": reason})
    await _drive(MCPStatsMiddleware(inner), make_scope(redis=redis))
    assert redis.counters == {}, "infra 拒绝不得写 Redis(Redis 挂时才该计)"
    assert infra_rejects_since_start() == 1
    reset_infra_rejects()


@pytest.mark.parametrize("status", [400, 401, 403, 404, 422, 500])
async def test_business_errors_are_not_counted(status: int) -> None:
    """业务 403(无 can_upload 等)/401/400/404/422/500 一律不计。"""
    redis = FakeRedis()
    inner = _InnerApp(status=status, state={"auth_method": "pat"})
    await _drive(MCPStatsMiddleware(inner), make_scope(redis=redis))
    assert redis.counters == {}


async def test_redis_failure_does_not_break_response() -> None:
    redis = FakeRedis(fail_incr=True)
    inner = _InnerApp(status=200, state={"auth_method": "pat"})
    sent = await _drive(MCPStatsMiddleware(inner), make_scope(redis=redis))
    assert [m["type"] for m in sent] == ["http.response.start", "http.response.body"]


async def test_non_http_scope_passthrough() -> None:
    redis = FakeRedis()
    scope = make_scope(redis=redis, scope_type="lifespan")
    sent = await _drive(MCPStatsMiddleware(_InnerApp(status=200)), scope)
    assert sent  # 直通,不计数
    assert redis.counters == {}


def test_is_pat_request_state_takes_precedence() -> None:
    scope = make_scope(redis=None, bearer="Bearer mspat_x")
    assert _is_pat_request(scope, {"auth_method": "session"}) is False
    assert _is_pat_request(scope, {"auth_method": "pat"}) is True
    assert _is_pat_request(scope, {}) is True  # 兜底看头


# ─── 2) 真实 app:被排除路由的拒绝量递增 ───────────────────────────────────
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


async def test_real_app_excluded_route_increments_policy_bucket(redis_client: Any) -> None:
    app = create_app()
    app.state.redis = redis_client
    app.state.mcp_settings = SimpleNamespace()

    async def _pat_user(request: Request) -> CurrentUser:
        request.state.auth_method = "pat"
        request.state.auth_token_id = uuid.uuid4()
        request.state.mcp_flag = McpSettings(True, 8, 4, 120, 600)
        return CurrentUser(id=uuid.uuid4(), name="pat-user")

    app.dependency_overrides[get_current_user] = _pat_user
    key = stats_key(BUCKET_REJECTED_POLICY)
    await redis_client.delete(key)
    try:
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as ac:
            resp = await ac.post("/api/v1/assets/batch-prefix", json={"asset_ids": []})
        await asyncio.sleep(0)  # 计数在响应发完后落地(同一任务内已完成,容错留一拍)
        assert resp.status_code == 403
        assert int(await redis_client.get(key) or 0) == 1
        assert int(await redis_client.ttl(key)) > 0
    finally:
        await redis_client.delete(key)
        app.dependency_overrides.clear()
