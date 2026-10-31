"""initialize 冒烟:真实 FastMCP Streamable HTTP + 守门中间件 + mock api。

覆盖:Host 白名单、initialize 必须带 PAT 且先调 /auth/me、会话绑定复用、
同会话换 PAT 401、Cookie/X-User-Id 剥离、健康检查。
"""

from __future__ import annotations

import logging
from types import SimpleNamespace

import httpx
import pytest
from conftest import MockApi, make_settings

from ms_mcp.server import build_server

PAT = "mspat_smoke_token"
SESSION_ID = "smoke-session-1"

ME = {
    "id": "u1", "name": "Evan", "email": "e@example.com", "open_id": "oid",
    "is_active": True, "is_system_admin": False,
}

ACCEPT = {"Accept": "application/json, text/event-stream"}

INITIALIZE = {
    "jsonrpc": "2.0", "id": 1, "method": "initialize",
    "params": {
        "protocolVersion": "2025-06-18",
        "capabilities": {},
        "clientInfo": {"name": "pytest", "version": "1"},
    },
}
INITIALIZED = {"jsonrpc": "2.0", "method": "notifications/initialized"}


def tools_call(call_id: int, name: str, arguments: dict) -> dict:
    return {
        "jsonrpc": "2.0", "id": call_id, "method": "tools/call",
        "params": {"name": name, "arguments": arguments},
    }


async def _start(api_mock: MockApi, *, bytes_transport=None) -> SimpleNamespace:
    settings = make_settings()
    built = build_server(
        settings,
        json_response=True,
        api_transport=httpx.MockTransport(api_mock.handler),
        bytes_transport=bytes_transport,
    )
    lifespan = built.inner.router.lifespan_context(built.inner)
    await lifespan.__aenter__()
    client = httpx.AsyncClient(
        transport=httpx.ASGITransport(app=built.app), base_url="http://ms.local:8090"
    )
    return SimpleNamespace(built=built, client=client, lifespan=lifespan, api_mock=api_mock)


async def _stop(env: SimpleNamespace) -> None:
    await env.client.aclose()
    await env.lifespan.__aexit__(None, None, None)
    await env.built.aclose()


async def test_healthz_no_auth() -> None:
    api_mock = MockApi()
    env = await _start(api_mock)
    try:
        resp = await env.client.get("/healthz")
        assert resp.status_code == 200
        assert resp.json()["status"] == "ok"
    finally:
        await _stop(env)


async def test_initialize_binds_pat_then_tool_call_reuses_it() -> None:
    api_mock = MockApi()
    api_mock.add("GET", "/api/v1/auth/me", json=ME)
    env = await _start(api_mock)
    try:
        resp = await env.client.post(
            "/mcp", json=INITIALIZE,
            headers={
                **ACCEPT,
                "Authorization": f"Bearer {PAT}",
                "Cookie": "ms_session=should-be-stripped",
                "X-User-Id": "should-be-stripped",
            },
        )
        assert resp.status_code == 200, resp.text
        session_id = resp.headers["mcp-session-id"]
        assert session_id

        probe = api_mock.find("GET", "/api/v1/auth/me")
        assert probe.headers["authorization"] == f"Bearer {PAT}"
        assert probe.headers["user-agent"].startswith("msmcp/")
        assert "cookie" not in probe.headers
        assert "x-user-id" not in probe.headers

        resp = await env.client.post(
            "/mcp", json=INITIALIZED, headers={**ACCEPT, "mcp-session-id": session_id}
        )
        assert resp.status_code == 202

        # 后续调用不带 Authorization:中间件按 Mcp-Session-Id 复用绑定的 PAT
        resp = await env.client.post(
            "/mcp", json=tools_call(2, "whoami", {}), headers={**ACCEPT, "mcp-session-id": session_id}
        )
        assert resp.status_code == 200, resp.text
        payload = resp.json()
        assert payload["result"]["isError"] is False
        whoami_calls = [c for c in api_mock.calls if c.path == "/api/v1/auth/me"]
        assert len(whoami_calls) == 2
        assert whoami_calls[-1].headers["authorization"] == f"Bearer {PAT}"
        text = payload["result"]["content"][0]["text"]
        assert "Evan" in text and "email" not in text
    finally:
        await _stop(env)


async def test_same_session_with_other_pat_is_401() -> None:
    api_mock = MockApi()
    api_mock.add("GET", "/api/v1/auth/me", json=ME)
    env = await _start(api_mock)
    try:
        resp = await env.client.post(
            "/mcp", json=INITIALIZE, headers={**ACCEPT, "Authorization": f"Bearer {PAT}"}
        )
        session_id = resp.headers["mcp-session-id"]
        resp = await env.client.post(
            "/mcp", json=tools_call(2, "whoami", {}),
            headers={**ACCEPT, "mcp-session-id": session_id, "Authorization": "Bearer mspat_other"},
        )
        assert resp.status_code == 401
    finally:
        await _stop(env)


async def test_host_not_allowlisted_403() -> None:
    api_mock = MockApi()
    env = await _start(api_mock)
    try:
        resp = await env.client.post(
            "/mcp", json=INITIALIZE,
            headers={**ACCEPT, "Authorization": f"Bearer {PAT}", "Host": "evil.example"},
        )
        assert resp.status_code == 403
    finally:
        await _stop(env)


async def test_initialize_with_invalid_pat_is_rejected_without_session() -> None:
    api_mock = MockApi()
    api_mock.add("GET", "/api/v1/auth/me", status=401, json={"detail": "令牌无效或已过期"})
    env = await _start(api_mock)
    try:
        resp = await env.client.post(
            "/mcp", json=INITIALIZE, headers={**ACCEPT, "Authorization": "Bearer mspat_bad"}
        )
        assert resp.status_code == 401
        assert "mcp-session-id" not in resp.headers

        # 伪造 session id 也不行
        resp = await env.client.post(
            "/mcp", json=INITIALIZED, headers={**ACCEPT, "mcp-session-id": SESSION_ID}
        )
        assert resp.status_code == 401
    finally:
        await _stop(env)


async def test_get_thumbnail_tool_returns_image_content() -> None:
    api_mock = MockApi()
    api_mock.add("GET", "/api/v1/auth/me", json=ME)
    api_mock.add(
        "GET", "/api/v1/assets/a1/thumbnail-url",
        json={"url": "http://192.168.110.221/ms-thumbs/a1.png?sign=1",
              "expires_in": 1800, "variant": "small"},
    )
    seen: list[httpx.Request] = []

    def bytes_handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, content=b"\x89PNG", headers={"content-type": "image/png"})

    env = await _start(api_mock, bytes_transport=httpx.MockTransport(bytes_handler))
    try:
        resp = await env.client.post(
            "/mcp", json=INITIALIZE, headers={**ACCEPT, "Authorization": f"Bearer {PAT}"}
        )
        session_id = resp.headers["mcp-session-id"]
        resp = await env.client.post(
            "/mcp", json=tools_call(2, "get_thumbnail", {"asset_id": "a1", "size": "small"}),
            headers={**ACCEPT, "mcp-session-id": session_id},
        )
        assert resp.status_code == 200, resp.text
        content = resp.json()["result"]["content"]
        assert any(block["type"] == "image" for block in content)
        assert any("variant=small" in block.get("text", "") for block in content)
        thumb_call = api_mock.find("GET", "/api/v1/assets/a1/thumbnail-url")
        assert thumb_call.headers["host"] == "192.168.110.221"
        assert seen and "authorization" not in seen[0].headers
    finally:
        await _stop(env)


async def test_thumbnail_presigned_url_not_logged(caplog: pytest.LogCaptureFixture) -> None:
    signature = "deadbeef" * 8
    signed = (
        "http://192.168.110.221/ms-thumbs/a1.png"
        f"?X-Amz-Credential=cred%2F20261031&X-Amz-Signature={signature}"
    )
    api_mock = MockApi()
    api_mock.add("GET", "/api/v1/auth/me", json=ME)
    api_mock.add(
        "GET", "/api/v1/assets/a1/thumbnail-url",
        json={"url": signed, "expires_in": 1800, "variant": "small"},
    )
    env = await _start(
        api_mock,
        bytes_transport=httpx.MockTransport(
            lambda _request: httpx.Response(
                200, content=b"\x89PNG", headers={"content-type": "image/png"}
            )
        ),
    )
    try:
        with caplog.at_level(logging.INFO):
            resp = await env.client.post(
                "/mcp", json=INITIALIZE, headers={**ACCEPT, "Authorization": f"Bearer {PAT}"}
            )
            session_id = resp.headers["mcp-session-id"]
            resp = await env.client.post(
                "/mcp", json=tools_call(2, "get_thumbnail", {"asset_id": "a1", "size": "small"}),
                headers={**ACCEPT, "mcp-session-id": session_id},
            )
        assert resp.status_code == 200, resp.text
        # 签名 query 不进日志(httpx INFO access log),但 path 仍可排障
        assert signature not in caplog.text
        assert "X-Amz-Signature" not in caplog.text
        assert "http://192.168.110.221/ms-thumbs/a1.png?<redacted>" in caplog.text
        # PAT / Session-Id 脱敏不回归
        assert PAT not in caplog.text
        assert session_id not in caplog.text
    finally:
        await _stop(env)


async def test_tool_error_is_error_true_without_stack() -> None:
    api_mock = MockApi()
    api_mock.add("GET", "/api/v1/auth/me", json=ME)
    env = await _start(api_mock)
    try:
        resp = await env.client.post(
            "/mcp", json=INITIALIZE, headers={**ACCEPT, "Authorization": f"Bearer {PAT}"}
        )
        session_id = resp.headers["mcp-session-id"]
        api_mock.add(
            "GET", "/api/v1/assets/search",
            status=403, json={"detail": "MCP 通道当前已由管理员关闭"},
        )
        resp = await env.client.post(
            "/mcp", json=tools_call(2, "search_assets", {"q": "猫"}),
            headers={**ACCEPT, "mcp-session-id": session_id},
        )
        assert resp.status_code == 200
        result = resp.json()["result"]
        assert result["isError"] is True
        text = result["content"][0]["text"]
        assert "MCP 通道当前已由管理员关闭" in text
        assert "Traceback" not in text
    finally:
        await _stop(env)


async def test_sdk_session_id_logs_are_redacted(caplog: pytest.LogCaptureFixture) -> None:
    api_mock = MockApi()
    api_mock.add("GET", "/api/v1/auth/me", json=ME)
    env = await _start(api_mock)
    try:
        with caplog.at_level(logging.INFO):
            resp = await env.client.post(
                "/mcp", json=INITIALIZE, headers={**ACCEPT, "Authorization": f"Bearer {PAT}"}
            )
            session_id = resp.headers["mcp-session-id"]
        assert session_id not in caplog.text
        assert "<session-id-redacted>" in caplog.text
    finally:
        await _stop(env)


@pytest.mark.parametrize("path", ["/", "/foo"])
async def test_unknown_paths_404(path: str) -> None:
    api_mock = MockApi()
    env = await _start(api_mock)
    try:
        resp = await env.client.get(path)
        assert resp.status_code == 404
    finally:
        await _stop(env)
