"""共享测试夹具:mock api / 缩略图字节服务 / ToolHandlers。"""

from __future__ import annotations

import json
from dataclasses import dataclass
from types import SimpleNamespace
from typing import Any

import httpx
import pytest

from ms_mcp.clients import ApiClient, BytesClient, ForwardContext
from ms_mcp.config import Settings, parse_allowlist
from ms_mcp.toolimpl import ToolHandlers

ALLOWLIST = (
    "ms.local=http,ms.local:8090=http,127.0.0.1=http,192.168.110.221=http,"
    "47.108.196.211:18080=http,bucket.taoxiplan.com=https"
)

FORWARD = ForwardContext(pat="mspat_unit_token", host="ms.local:8090", xfp="http", xff="203.0.113.9")


def make_settings(**overrides: Any) -> Settings:
    kwargs: dict[str, Any] = {
        "api_base_url": "http://ms-api:8000",
        "internal_base_url": "http://192.168.110.221",
        "internal_host": "192.168.110.221",
        "internal_scheme": "http",
        "allowlist": parse_allowlist(ALLOWLIST),
        "session_ttl": 60.0,
        "verify_tls": True,
    }
    kwargs.update(overrides)
    return Settings(**kwargs)


@dataclass
class RecordedCall:
    method: str
    path: str
    params: dict[str, str]
    headers: httpx.Headers
    body: Any


class MockApi:
    """按 (method, path) 路由的最小 mock api;记录每次请求供断言。"""

    def __init__(self) -> None:
        self.calls: list[RecordedCall] = []
        self._routes: dict[tuple[str, str], dict[str, Any]] = {}

    def add(
        self,
        method: str,
        path: str,
        *,
        status: int = 200,
        json: Any = None,
        headers: dict[str, str] | None = None,
        content: bytes | None = None,
    ) -> MockApi:
        self._routes[(method.upper(), path)] = {
            "status": status, "json": json, "headers": headers or {}, "content": content,
        }
        return self

    def handler(self, request: httpx.Request) -> httpx.Response:
        body: Any = None
        if request.content:
            try:
                body = json.loads(request.content)
            except ValueError:
                body = request.content.decode("utf-8", "replace")
        self.calls.append(
            RecordedCall(
                method=request.method,
                path=request.url.path,
                params=dict(request.url.params),
                headers=request.headers,
                body=body,
            )
        )
        spec = self._routes.get((request.method, request.url.path))
        if spec is None:
            return httpx.Response(404, json={"detail": "not found"})
        return httpx.Response(
            spec["status"],
            json=spec["json"] if spec["content"] is None else None,
            content=spec["content"],
            headers=spec["headers"],
        )

    @property
    def last(self) -> RecordedCall:
        assert self.calls, "mock api 没有收到请求"
        return self.calls[-1]

    def find(self, method: str, path: str) -> RecordedCall:
        for call in self.calls:
            if call.method == method.upper() and call.path == path:
                return call
        raise AssertionError(f"未找到 {method} {path};实际={[(c.method, c.path) for c in self.calls]}")


class MockBytes:
    def __init__(self) -> None:
        self.requests: list[httpx.Request] = []
        self.status = 200
        self.content = b"\x89PNG\r\n\x1a\nfake"
        self.content_type = "image/png"

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        return httpx.Response(
            self.status, content=self.content, headers={"content-type": self.content_type}
        )


@pytest.fixture
async def bundle():
    settings = make_settings()
    api_mock = MockApi()
    bytes_mock = MockBytes()
    api = ApiClient(settings.api_base_url, transport=httpx.MockTransport(api_mock.handler))
    bytes_client = BytesClient(transport=httpx.MockTransport(bytes_mock.handler))
    handlers = ToolHandlers(settings, api, bytes_client)
    yield SimpleNamespace(
        settings=settings,
        api=api,
        api_mock=api_mock,
        bytes_client=bytes_client,
        bytes_mock=bytes_mock,
        handlers=handlers,
    )
    await api.aclose()
    await bytes_client.aclose()
