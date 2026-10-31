"""Host 守门 / 会话-PAT 绑定 / XFP 归一 / 日志脱敏(中间件层单测)。"""

from __future__ import annotations

import logging
from types import SimpleNamespace

import httpx
import pytest
from conftest import MockApi, make_settings

from ms_mcp.clients import ApiClient
from ms_mcp.middleware import McpGateMiddleware
from ms_mcp.session import SessionStore

SESSION_ID = "sess-SECRET-abc123"
PAT = "mspat_SECRETPAT_abc"


class DummyApp:
    """下游替身:记录 scope,并按需回写 Mcp-Session-Id。"""

    def __init__(self, session_id: str | None = None) -> None:
        self.scopes: list[dict] = []
        self.session_id = session_id
        self.status = 200

    async def __call__(self, scope, receive, send) -> None:
        self.scopes.append(scope)
        headers = [(b"content-type", b"text/plain")]
        if self.session_id:
            headers.append((b"mcp-session-id", self.session_id.encode()))
        await send({"type": "http.response.start", "status": self.status, "headers": headers})
        await send({"type": "http.response.body", "body": b"ok"})

    @property
    def last(self) -> dict:
        assert self.scopes
        return self.scopes[-1]


@pytest.fixture
async def ctx():
    settings = make_settings()
    api_mock = MockApi()
    api_mock.add("GET", "/api/v1/auth/me", json={"id": "u1", "name": "Evan"})
    api = ApiClient(settings.api_base_url, transport=httpx.MockTransport(api_mock.handler))
    store = SessionStore(max_sessions=4, ttl_seconds=600)
    dummy = DummyApp(session_id=SESSION_ID)
    gate = McpGateMiddleware(dummy, settings=settings, store=store, api=api)
    try:
        yield SimpleNamespace(settings=settings, api=api, api_mock=api_mock, store=store,
                              dummy=dummy, gate=gate)
    finally:
        await api.aclose()


def client_for(gate, base_url: str = "http://ms.local:8090") -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=gate), base_url=base_url)


async def test_host_not_allowlisted_is_403_without_downstream(ctx) -> None:
    async with client_for(ctx.gate, "http://evil.example") as client:
        resp = await client.post("/mcp", json={}, headers={"Authorization": f"Bearer {PAT}"})
    assert resp.status_code == 403
    assert ctx.dummy.scopes == []
    assert ctx.api_mock.calls == []


async def test_host_match_is_case_insensitive(ctx) -> None:
    async with client_for(ctx.gate, "http://MS.LOCAL:8090") as client:
        resp = await client.post("/mcp", json={}, headers={"Authorization": f"Bearer {PAT}"})
    assert resp.status_code == 200
    assert ctx.dummy.scopes


async def test_with_port_entry_matches_exact_host(ctx) -> None:
    async with client_for(ctx.gate, "http://47.108.196.211:18080") as client:
        resp = await client.post("/mcp", json={}, headers={"Authorization": f"Bearer {PAT}"})
    assert resp.status_code == 200
    assert ctx.dummy.last["state"]["mcp_forward"].host == "47.108.196.211:18080"


async def test_initialize_requires_authorization_and_probes_auth_me(ctx) -> None:
    async with client_for(ctx.gate) as client:
        resp = await client.post("/mcp", json={})
    assert resp.status_code == 401
    assert ctx.api_mock.calls == []          # 无凭证不调用 /auth/me
    assert ctx.dummy.scopes == []

    async with client_for(ctx.gate) as client:
        resp = await client.post("/mcp", json={}, headers={"Authorization": f"Bearer {PAT}"})
    assert resp.status_code == 200
    me = ctx.api_mock.find("GET", "/api/v1/auth/me")
    assert me.headers["authorization"] == f"Bearer {PAT}"
    assert me.headers["host"] == "ms.local:8090"
    assert ctx.store.get(SESSION_ID) == PAT


async def test_non_bearer_authorization_rejected(ctx) -> None:
    async with client_for(ctx.gate) as client:
        resp = await client.post("/mcp", json={}, headers={"Authorization": "Basic abc"})
    assert resp.status_code == 401
    assert ctx.dummy.scopes == []


async def test_invalid_pat_does_not_create_session(ctx) -> None:
    ctx.api_mock.add("GET", "/api/v1/auth/me", status=401, json={"detail": "令牌无效"})
    async with client_for(ctx.gate) as client:
        resp = await client.post("/mcp", json={}, headers={"Authorization": f"Bearer {PAT}"})
    assert resp.status_code == 401
    assert "令牌" in resp.json()["error"]
    assert ctx.store.get(SESSION_ID) is None
    assert ctx.dummy.scopes == []


async def test_session_reuses_bound_pat_without_authorization(ctx) -> None:
    ctx.store.bind(SESSION_ID, PAT)
    async with client_for(ctx.gate) as client:
        resp = await client.post("/mcp", json={}, headers={"mcp-session-id": SESSION_ID})
    assert resp.status_code == 200
    assert ctx.dummy.last["state"]["mcp_forward"].pat == PAT


async def test_same_session_with_same_pat_ok(ctx) -> None:
    ctx.store.bind(SESSION_ID, PAT)
    async with client_for(ctx.gate) as client:
        resp = await client.post(
            "/mcp", json={},
            headers={"mcp-session-id": SESSION_ID, "Authorization": f"Bearer {PAT}"},
        )
    assert resp.status_code == 200


async def test_same_session_with_different_pat_is_401(ctx) -> None:
    ctx.store.bind(SESSION_ID, PAT)
    async with client_for(ctx.gate) as client:
        resp = await client.post(
            "/mcp", json={},
            headers={"mcp-session-id": SESSION_ID, "Authorization": "Bearer mspat_other"},
        )
    assert resp.status_code == 401
    assert "绑定" in resp.json()["error"]
    assert ctx.dummy.scopes == []
    assert ctx.store.get(SESSION_ID) == PAT     # 不自动换绑


async def test_unknown_session_is_401(ctx) -> None:
    async with client_for(ctx.gate) as client:
        resp = await client.post("/mcp", json={}, headers={"mcp-session-id": "ghost"})
    assert resp.status_code == 401
    assert ctx.dummy.scopes == []


async def test_sessionless_get_is_400(ctx) -> None:
    async with client_for(ctx.gate) as client:
        resp = await client.get("/mcp", headers={"Authorization": f"Bearer {PAT}"})
    assert resp.status_code == 400


async def test_xfp_normalization_conflict_uses_entry_scheme(ctx) -> None:
    ctx.store.bind(SESSION_ID, PAT)
    async with client_for(ctx.gate) as client:
        await client.post(
            "/mcp", json={},
            headers={"mcp-session-id": SESSION_ID, "X-Forwarded-Proto": "https"},
        )
    assert ctx.dummy.last["state"]["mcp_forward"].xfp == "http"


async def test_xfp_missing_defaults_to_entry_scheme(ctx) -> None:
    ctx.store.bind(SESSION_ID, PAT)
    async with client_for(ctx.gate) as client:
        await client.post("/mcp", json={}, headers={"mcp-session-id": SESSION_ID})
    assert ctx.dummy.last["state"]["mcp_forward"].xfp == "http"

    # 命中 https 条目(公网域名)时默认 https
    async with client_for(ctx.gate, "http://bucket.taoxiplan.com") as client:
        await client.post("/mcp", json={}, headers={"mcp-session-id": SESSION_ID})
    assert ctx.dummy.last["state"]["mcp_forward"].xfp == "https"


async def test_xfp_consistent_value_passes_through(ctx) -> None:
    ctx.store.bind(SESSION_ID, PAT)
    async with client_for(ctx.gate, "http://bucket.taoxiplan.com") as client:
        await client.post(
            "/mcp", json={},
            headers={"mcp-session-id": SESSION_ID, "X-Forwarded-Proto": "https"},
        )
    assert ctx.dummy.last["state"]["mcp_forward"].xfp == "https"


async def test_xff_passthrough_single_value(ctx) -> None:
    ctx.store.bind(SESSION_ID, PAT)
    async with client_for(ctx.gate) as client:
        await client.post(
            "/mcp", json={},
            headers={"mcp-session-id": SESSION_ID, "X-Forwarded-For": "198.51.100.7"},
        )
    assert ctx.dummy.last["state"]["mcp_forward"].xff == "198.51.100.7"


async def test_delete_session_unbinds(ctx) -> None:
    ctx.store.bind(SESSION_ID, PAT)
    async with client_for(ctx.gate) as client:
        resp = await client.delete("/mcp", headers={"mcp-session-id": SESSION_ID})
    assert resp.status_code == 200
    assert ctx.store.get(SESSION_ID) is None


async def test_healthz_bypasses_gate(ctx) -> None:
    async with client_for(ctx.gate, "http://127.0.0.1:8000") as client:
        resp = await client.get("/healthz")
    assert resp.status_code == 200
    assert ctx.dummy.scopes


async def test_trailing_slash_is_normalized(ctx) -> None:
    ctx.store.bind(SESSION_ID, PAT)
    async with client_for(ctx.gate) as client:
        resp = await client.post("/mcp/", json={}, headers={"mcp-session-id": SESSION_ID})
    assert resp.status_code == 200
    assert ctx.dummy.last["path"] == "/mcp"


async def test_logs_do_not_leak_pat_or_session_id(ctx, caplog: pytest.LogCaptureFixture) -> None:
    with caplog.at_level(logging.INFO):
        async with client_for(ctx.gate) as client:
            await client.post("/mcp", json={}, headers={"Authorization": f"Bearer {PAT}"})
            await client.post("/mcp", json={}, headers={"mcp-session-id": SESSION_ID})
    assert PAT not in caplog.text
    assert SESSION_ID not in caplog.text
    assert "/mcp" in caplog.text
