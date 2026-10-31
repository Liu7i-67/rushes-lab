"""MCP 通道流量统计 — 纯 ASGI 中间件(**禁 ``BaseHTTPMiddleware``**)。

需求:`docs/qdev/2026-10-30-mcp-service.md`(D11 / C.6「通道统计计数」)。
计数口径全在 ``app/services/mcp_metrics.py``(本中间件只做判定 + 派发)。

为什么必须是中间件:
- 依赖拿不到最终 response.status(2xx 成功数要在响应头就绪后才有);
- 上游 ``get_current_user`` 抛 403/429/503 时 ``mcp_gate`` 根本不进入
  (`mcp_gate` 的 yield 能捕获的是下游/端点异常,不是上游认证拒绝)——
  通道默认全关,上线首日所有请求在第 1 步即 403,必须由本层覆盖整条 PAT 链。

判定(勿放宽):
1. 只看 ``http`` scope;``http.response.start`` 取 status,不缓冲/不改响应体;
2. **只认 PAT 分支显式写入的 ``scope["state"]["auth_method"] == "pat"``**;
   无 ``auth_method``(认证未完成即被拒)时**仅**以 ``Authorization: Bearer
   mspat_`` 头作兜底 —— 有效 session + 手带 mspat 头(``auth_method="session"``)
   不得误计;
3. 拒绝量按 ``mcp_reject_reason`` 分桶(**状态码不可靠**:业务权限不足也是 403):
   policy/quota → Redis;infra → 进程内(不写 Redis);
4. 2xx → ``mcp:stats:requests:{yyyyMMdd}``(UTC 日);
5. 一切 Redis 操作 try/except 只 log(在 ``mcp_metrics`` 内收口)——
   指标故障绝不影响响应;session 请求零影响(一次 dict 判断即返回)。
"""
from __future__ import annotations

import logging
from typing import Any

from app.services.mcp_metrics import (
    BUCKET_REJECTED_POLICY,
    BUCKET_REJECTED_QUOTA,
    BUCKET_REQUESTS,
    REASON_INFRA,
    REASON_POLICY,
    REASON_QUOTA,
    incr_stat,
    record_infra_reject,
)

log = logging.getLogger(__name__)

# PAT 明文前缀(与 app/services/tokens.py PAT_PREFIX 同值;此处不 import 服务层,
# 避免中间件对 DB 服务的间接依赖)
_PAT_PREFIX = "mspat_"


def _is_pat_request(scope: dict[str, Any], state: dict[str, Any]) -> bool:
    """``auth_method == "pat"``;认证未完成时仅以 Bearer mspat_ 头兜底。"""
    method = state.get("auth_method")
    if method is not None:
        # 已认证:只认 PAT(session/dev 一律不计,即使手带了 Authorization 头)
        return isinstance(method, str) and method == "pat"
    for raw_name, raw_value in scope.get("headers") or ():
        try:
            name = str(raw_name.decode("latin-1"))
        except Exception:  # 非法头名只跳过
            continue
        if name.lower() != "authorization":
            continue
        try:
            value = str(raw_value.decode("latin-1"))
        except Exception:
            return False
        parts = value.split(None, 1)
        if len(parts) != 2:
            return False
        return parts[0].lower() == "bearer" and parts[1].startswith(_PAT_PREFIX)
    return False


def _reject_bucket(reason: str) -> str | None:
    """reason → Redis 桶名(policy/quota);infra 与未知 reason 返回 None。"""
    if reason in REASON_POLICY:
        return BUCKET_REJECTED_POLICY
    if reason in REASON_QUOTA:
        return BUCKET_REJECTED_QUOTA
    return None


class MCPStatsMiddleware:
    """按最终响应状态 / 拒绝原因累加 MCP 通道指标(纯 ASGI)。"""

    def __init__(self, app: Any) -> None:
        self.app = app

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        if scope.get("type") != "http":
            await self.app(scope, receive, send)
            return

        # 与下游 Request.state 同一个 dict(Starlette 用 setdefault("state", {}))
        state: dict[str, Any] = scope.setdefault("state", {})
        status_holder = {"status": 0}

        async def send_wrapper(message: dict[str, Any]) -> None:
            if message.get("type") == "http.response.start":
                status_holder["status"] = int(message.get("status") or 0)
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        finally:
            # 响应已发完才计数:不给响应起点加任何等待,也不触碰响应体
            await self._record(scope, state, status_holder["status"])

    async def _record(
        self, scope: dict[str, Any], state: dict[str, Any], status: int,
    ) -> None:
        try:
            if not _is_pat_request(scope, state):
                return
            reason = state.get("mcp_reject_reason")
            if isinstance(reason, str) and reason:
                if reason in REASON_INFRA:
                    # infra 只进进程内(不写 Redis:Redis 挂时才该计,写必失败)
                    record_infra_reject(reason)
                    return
                bucket = _reject_bucket(reason)
                if bucket is None:
                    log.debug("mcp stats: 未知 reject reason=%r(不计)", reason)
                    return
                await incr_stat(self._redis(scope), bucket)
                return
            if 200 <= status < 300:
                await incr_stat(self._redis(scope), BUCKET_REQUESTS)
        except Exception as e:  # 指标层任何异常都不外溢
            log.warning("mcp stats: 计数失败(忽略): %s", e)

    @staticmethod
    def _redis(scope: dict[str, Any]) -> Any:
        app = scope.get("app")
        return getattr(getattr(app, "state", None), "redis", None)
