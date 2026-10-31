"""组装 ms-mcp:FastMCP(Streamable HTTP)+ Host/会话守门中间件 + 健康检查。"""

from __future__ import annotations

import asyncio
import logging
import os
from dataclasses import dataclass, field

import httpx
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.types import ASGIApp

from ms_mcp import HEALTH_PATH, MCP_PATH, __version__
from ms_mcp.clients import (
    FORWARD_TIMEOUT_SECONDS,
    THUMBNAIL_TIMEOUT_SECONDS,
    ApiClient,
    BytesClient,
)
from ms_mcp.config import Settings, settings_from_env
from ms_mcp.logging_utils import install_log_redaction
from ms_mcp.middleware import McpGateMiddleware
from ms_mcp.session import SessionStore
from ms_mcp.toolimpl import ToolHandlers
from ms_mcp.tools import SERVER_INSTRUCTIONS, AppContext, register_tools

log = logging.getLogger(__name__)

SERVER_NAME = "ms-mcp"
LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = 8000


@dataclass
class BuiltServer:
    app: ASGIApp
    inner: Starlette          # FastMCP 原生 ASGI(测试用它跑 session manager lifespan)
    context: AppContext
    mcp: FastMCP
    api: ApiClient
    bytes_client: BytesClient
    _closed: bool = field(default=False, repr=False)

    async def aclose(self) -> None:
        if self._closed:
            return
        self._closed = True
        await self.api.aclose()
        await self.bytes_client.aclose()


def build_transport_security(settings: Settings) -> TransportSecuritySettings:
    """FastMCP 的 DNS-rebinding 白名单(与 ms-mcp 自己的 Host 守门是两层概念)。

    mcp==1.30.0 实测口径:`allowed_hosts` 是对请求 Host 头的**精确匹配(含端口)**,
    另有 `host:*` 通配;`allowed_origins` 匹配 `scheme://host` 或 `origin:*`。
    故必须把双入口的带端口/不带端口拼法都列上,并补 localhost 调试项。
    """
    hosts = {entry.host for entry in settings.allowlist.values()}
    hosts |= {"localhost", "127.0.0.1", "[::1]", "localhost:*", "127.0.0.1:*", "[::1]:*"}
    origins = {f"{entry.scheme}://{entry.host}" for entry in settings.allowlist.values()}
    origins |= {"http://localhost:*", "http://127.0.0.1:*", "http://[::1]:*"}
    return TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=sorted(hosts),
        allowed_origins=sorted(origins),
    )


def build_server(
    settings: Settings,
    *,
    json_response: bool = False,
    api_transport: httpx.AsyncBaseTransport | None = None,
    bytes_transport: httpx.AsyncBaseTransport | None = None,
    store: SessionStore | None = None,
) -> BuiltServer:
    """构造完整 ASGI 应用。测试可注入 httpx 传输层与会话表。"""
    install_log_redaction()
    api = ApiClient(
        settings.api_base_url,
        verify_tls=settings.verify_tls,
        ca_bundle=settings.ca_bundle,
        timeout=FORWARD_TIMEOUT_SECONDS,
        transport=api_transport,
    )
    bytes_client = BytesClient(
        verify_tls=settings.verify_tls,
        ca_bundle=settings.ca_bundle,
        timeout=THUMBNAIL_TIMEOUT_SECONDS,
        transport=bytes_transport,
    )
    handlers = ToolHandlers(settings, api, bytes_client)
    context = AppContext(
        settings=settings,
        handlers=handlers,
        tool_semaphore=asyncio.Semaphore(settings.tool_concurrency),
    )
    session_store = store or SessionStore(settings.session_cap, settings.session_ttl)

    mcp = FastMCP(
        name=SERVER_NAME,
        instructions=SERVER_INSTRUCTIONS,
        # ① 监听地址:必须 0.0.0.0(容器内),否则 nginx 连不上
        host=LISTEN_HOST,
        port=LISTEN_PORT,
        streamable_http_path=MCP_PATH,
        json_response=json_response,
        stateless_http=False,
        # 会话上限 / 空闲 TTL 与 ms-mcp 自己的绑定表同源(双层兜底)
        max_sessions=settings.session_cap,
        session_idle_timeout=settings.session_ttl,
        # ② DNS-rebinding 白名单:双入口地址 + localhost(不配则 initialize 直接 403/421)
        transport_security=build_transport_security(settings),
    )
    register_tools(mcp, context)

    @mcp.custom_route(HEALTH_PATH, methods=["GET"])
    async def healthz(_request: Request) -> JSONResponse:
        return JSONResponse(
            {
                "status": "ok",
                "service": SERVER_NAME,
                "version": __version__,
                "sessions": len(session_store),
            }
        )

    inner: Starlette = mcp.streamable_http_app()
    app = McpGateMiddleware(inner, settings=settings, store=session_store, api=api)
    return BuiltServer(
        app=app, inner=inner, context=context, mcp=mcp, api=api, bytes_client=bytes_client
    )


def main() -> None:
    logging.basicConfig(
        level=os.environ.get("MS_MCP_LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    settings = settings_from_env()
    log.info(
        "ms-mcp starting version=%s api=%s internal=%s allowlist_entries=%d session_ttl=%ss",
        __version__, settings.api_base_url, settings.internal_base_url,
        len(settings.allowlist), settings.session_ttl,
    )
    server = build_server(settings)
    import uvicorn

    uvicorn.run(server.app, host=LISTEN_HOST, port=LISTEN_PORT, log_level="info")
