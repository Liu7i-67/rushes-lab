"""Host 入口守门 + 会话与 PAT 绑定(纯 ASGI 中间件,不碰 SSE 流语义)。

职责顺序(任一失败即拒,不透传下游):
1. `/healthz` 直接放过(容器健康检查,不要求认证);
2. 只放行 `/mcp`;其它路径 404;
3. Host ∈ `MS_MCP_ENTRY_ALLOWLIST`(lower 后比较,含端口),未命中 403 不回落;
4. 归一 XFP(与命中条目 scheme 冲突时以条目为准;缺失/非法按条目置默认);
5. 有 `Mcp-Session-Id` → 查内存绑定:缺失 401;带不同 PAT 401(不自动换绑);
   无该头(新会话)→ 必须是携带 Bearer PAT 的 POST,先带该 PAT 调 `GET /auth/me`
   确认有效,才放行给 MCP SDK 建会话;
6. 把 ForwardContext(pat / Host / XFP / XFF)写进 scope state 供工具读取;
7. 从 initialize 响应头捕获新 `Mcp-Session-Id` 并绑定 PAT。

日志只记方法/路径/状态/耗时/Host,**永不记 Authorization、PAT、Mcp-Session-Id**。
"""

from __future__ import annotations

import json
import logging
import time

import httpx
from starlette.datastructures import Headers
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from ms_mcp import HEALTH_PATH, MCP_PATH, MCP_SESSION_HEADER
from ms_mcp.clients import ApiClient, ForwardContext, describe_api_error
from ms_mcp.config import Settings
from ms_mcp.session import SessionStore

log = logging.getLogger(__name__)

# initialize 前必须调用的有效性校验端点(顺带受通道闸/IP 桶/RPM 约束)
AUTH_ME_PATH = "/api/v1/auth/me"


def _json_start(status: int, payload: dict[str, object]) -> tuple[Message, Message]:
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    start: Message = {
        "type": "http.response.start",
        "status": status,
        "headers": [
            (b"content-type", b"application/json; charset=utf-8"),
            (b"content-length", str(len(body)).encode("ascii")),
            (b"cache-control", b"no-store"),
        ],
    }
    return start, {"type": "http.response.body", "body": body}


async def _send_json(send: Send, status: int, payload: dict[str, object]) -> None:
    start, body = _json_start(status, payload)
    await send(start)
    await send(body)


def _parse_bearer(raw: str | None) -> str | None:
    """返回 Bearer token;头缺失返回 None;头存在但不是合法 Bearer 也返回 None。

    调用方需先判断 `raw is None` 区分「没带凭证」与「带了别的凭证」。
    """
    if raw is None:
        return None
    scheme, _, token = raw.partition(" ")
    if scheme.lower() != "bearer":
        return None
    token = token.strip()
    return token or None


class McpGateMiddleware:
    def __init__(
        self,
        app: ASGIApp,
        *,
        settings: Settings,
        store: SessionStore,
        api: ApiClient,
    ) -> None:
        self.app = app
        self._settings = settings
        self._store = store
        self._api = api

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        path = scope.get("path") or ""
        if path == HEALTH_PATH:
            await self.app(scope, receive, send)
            return
        if path == MCP_PATH + "/":
            # 容忍客户端把 URL 配成 /mcp/(否则会 404):内部归一为 /mcp,
            # 避免 Starlette 307 重定向让 MCP POST 丢 body。
            scope = dict(scope)
            scope["path"] = MCP_PATH
            scope["raw_path"] = MCP_PATH.encode("ascii")
            path = MCP_PATH
        if path != MCP_PATH:
            await _send_json(send, 404, {"error": "not found"})
            return

        started = time.monotonic()
        status = await self._handle_mcp(scope, receive, send)
        log.info(
            "mcp %s %s -> %s (%.0fms) host=%s",
            scope.get("method", "?"), MCP_PATH, status,
            (time.monotonic() - started) * 1000.0,
            (Headers(scope=scope).get("host") or "-")[:120],
        )

    async def _handle_mcp(self, scope: Scope, receive: Receive, send: Send) -> int:
        headers = Headers(scope=scope)
        host = headers.get("host")
        entry = self._settings.entry_for_host(host)
        if entry is None or host is None:
            await _send_json(send, 403, {"error": "入口 Host 不在 MS_MCP_ENTRY_ALLOWLIST 内"})
            return 403

        xfp = self._settings.normalized_xfp(entry, headers.get("x-forwarded-proto"))
        xff = headers.get("x-forwarded-for")

        raw_auth = headers.get("authorization")
        pat_from_header: str | None = None
        if raw_auth is not None:
            pat_from_header = _parse_bearer(raw_auth)
            if pat_from_header is None:
                await _send_json(send, 401, {"error": "Authorization 头必须是 Bearer <PAT>"})
                return 401

        session_id = headers.get(MCP_SESSION_HEADER)
        pending_pat: str | None = None

        if session_id:
            bound_pat = self._store.get(session_id)
            if bound_pat is None:
                await _send_json(
                    send, 401,
                    {"error": "MCP 会话不存在或已过期,请重新 initialize(会话绑定仅存于本进程)"},
                )
                return 401
            if pat_from_header is not None and pat_from_header != bound_pat:
                await _send_json(
                    send, 401,
                    {"error": "该 MCP 会话已绑定其它访问令牌,不会自动换绑,请重新 initialize"},
                )
                return 401
            effective_pat = bound_pat
        else:
            if scope.get("method") != "POST":
                await _send_json(send, 400, {"error": "缺少 Mcp-Session-Id,请先 initialize"})
                return 400
            if pat_from_header is None:
                await _send_json(send, 401, {"error": "initialize 必须携带 Authorization: Bearer <PAT>"})
                return 401
            probe_fwd = ForwardContext(pat=pat_from_header, host=host, xfp=xfp, xff=xff)
            probe = await self._probe_pat(probe_fwd, send)
            if probe is not None:
                return probe
            effective_pat = pat_from_header
            pending_pat = pat_from_header

        state = scope.setdefault("state", {})
        state["mcp_forward"] = ForwardContext(
            pat=effective_pat, host=host, xfp=xfp, xff=xff
        )

        captured: dict[str, object] = {"session_id": None, "status": None}

        async def send_wrapper(message: Message) -> None:
            if message["type"] == "http.response.start":
                captured["status"] = message["status"]
                for key, value in message.get("headers", ()):
                    if key.lower() == b"mcp-session-id":
                        captured["session_id"] = value.decode("ascii", "ignore")
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        finally:
            if pending_pat is not None:
                new_sid = captured["session_id"]
                resp_status = captured["status"]
                if (
                    isinstance(new_sid, str) and new_sid
                    and isinstance(resp_status, int) and resp_status < 400
                ):
                    self._store.bind(new_sid, pending_pat)
            elif session_id and scope.get("method") == "DELETE":
                # 客户端显式结束会话:立即清绑定,不等 TTL
                resp_status = captured["status"]
                if isinstance(resp_status, int) and resp_status < 400:
                    self._store.unbind(session_id)
        final_status = captured["status"]
        return final_status if isinstance(final_status, int) else 500

    async def _probe_pat(self, fwd: ForwardContext, send: Send) -> int | None:
        """initialize 前校验 PAT 有效(带该 PAT 调 GET /auth/me)。

        返回 None = 校验通过;返回 int = 已把失败响应写回客户端(镜像 api 状态码)。
        """
        try:
            resp = await self._api.request("GET", AUTH_ME_PATH, fwd)
        except httpx.TimeoutException:
            await _send_json(send, 503, {"error": "校验访问令牌超时(API 不可达),请稍后重试"})
            return 503
        except httpx.HTTPError:
            await _send_json(send, 503, {"error": "无法连接素材 API 校验访问令牌,请稍后重试"})
            return 503
        if not (200 <= resp.status_code < 300):
            err = describe_api_error(resp, "initialize 令牌校验")
            # 只镜像有语义的状态码;3xx / 422 等异常形态一律 502(别把重定向丢给 MCP 客户端)
            passthrough = {401, 403, 429, 503}
            status_out = (
                resp.status_code
                if resp.status_code in passthrough or resp.status_code >= 500
                else 502
            )
            await _send_json(send, status_out, {"error": err.message})
            return status_out
        return None
