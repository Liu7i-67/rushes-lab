"""日志脱敏。

`Mcp-Session-Id` 等价于会话凭证(拿到者可冒用该会话),方案要求日志与绑定的 PAT
一样脱敏。mcp SDK 自己在 INFO/WARNING 里会打出 session id(`Created new transport
with session ID: <uuid4().hex>` / `Session <id> idle timeout` / `Rejecting request
for session <id> ...`),故在 SDK 的 logger 上装过滤器,把 32 位 hex 串替换掉;
同时给根 handler 也装一份,兜住其它路径。

预签名 URL 的查询串(`X-Amz-Signature` / `X-Amz-Credential` /
`X-Amz-Security-Token` 等)是 30 分钟有效的能力凭据,不能落日志。httpx 在 INFO
级 access log 里会打出完整 `request.url`(含 query),故统一把 URL 的 `?...`
替换为 `?<redacted>`(保留 scheme/host/path)。httpx logger 的过滤器必须直接挂
在它自己身上:uvicorn / pytest 可能给日志配独立 handler,不保证经过根 handler
的过滤器。
"""

from __future__ import annotations

import logging
import re

_SESSION_ID_RE = re.compile(r"\b[0-9a-f]{32}\b")
_SESSION_ID_REDACTED = "<session-id-redacted>"

# URL 的查询串整体脱敏:保留 scheme://host/path,只抹掉 `?...`。
# 不含引号/尖括号/空白,避免把日式文本里的引号、括号一起吃掉。
_URL_QUERY_RE = re.compile(
    r"(?P<base>[A-Za-z][A-Za-z0-9+.\-]*://[^\s\"'<>?]*)\?[^\s\"'<>()]*"
)
# 兜底:URL 无 scheme(或已被截断)但 query 里出现 S3 预签名参数。
_SIGNED_QUERY_RE = re.compile(
    r"\?(?=[^\s\"'<>]*X-Amz-(?:Signature|Credential|Security-Token))[^\s\"'<>()]*"
)
_QUERY_REDACTED = "?<redacted>"

# SDK 里会打 session id 的 logger(SSE 传输未启用,但一并覆盖防未来切换)
_TARGET_LOGGERS = (
    "mcp.server.streamable_http_manager",
    "mcp.server.streamable_http",
    "mcp.server.sse",
)

# httpx 的 INFO access log(`HTTP Request: GET <url> ...`)带完整查询串;
# httpcore 的 debug trace 只打 `repr(request)`(仅 method),故无需处理。
_HTTP_LOGGERS = ("httpx",)


def _redact_url_queries(message: str) -> str:
    """URL 查询串 → `?<redacted>`,保留 scheme/host/path,便于排障。"""
    message = _URL_QUERY_RE.sub(r"\g<base>" + _QUERY_REDACTED, message)
    return _SIGNED_QUERY_RE.sub(_QUERY_REDACTED, message)


class SessionIdRedactionFilter(logging.Filter):
    """脱敏日志里的 Session-Id 与 URL 查询串(预签名凭证)。"""

    def filter(self, record: logging.LogRecord) -> bool:
        try:
            message = record.getMessage()
        except Exception:
            return True
        redacted = _redact_url_queries(message)
        redacted = _SESSION_ID_RE.sub(_SESSION_ID_REDACTED, redacted)
        if redacted != message:
            # 提前格式化并清空 args,下游 handler 只拿到脱敏后的完整文本
            record.msg = redacted
            record.args = None
        return True


def install_log_redaction() -> None:
    """幂等安装(logger 级 + 根 handler 级)。"""
    flt = SessionIdRedactionFilter()
    for name in (*_TARGET_LOGGERS, *_HTTP_LOGGERS):
        logger = logging.getLogger(name)
        if not any(isinstance(f, SessionIdRedactionFilter) for f in logger.filters):
            logger.addFilter(flt)
    for handler in logging.getLogger().handlers:
        if not any(isinstance(f, SessionIdRedactionFilter) for f in handler.filters):
            handler.addFilter(flt)
