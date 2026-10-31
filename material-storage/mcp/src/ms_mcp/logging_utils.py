"""日志脱敏。

`Mcp-Session-Id` 等价于会话凭证(拿到者可冒用该会话),方案要求日志与绑定的 PAT
一样脱敏。mcp SDK 自己在 INFO/WARNING 里会打出 session id(`Created new transport
with session ID: <uuid4().hex>` / `Session <id> idle timeout` / `Rejecting request
for session <id> ...`),故在 SDK 的 logger 上装过滤器,把 32 位 hex 串替换掉;
同时给根 handler 也装一份,兜住其它路径。
"""

from __future__ import annotations

import logging
import re

_SESSION_ID_RE = re.compile(r"\b[0-9a-f]{32}\b")
_REDACTED = "<session-id-redacted>"

# SDK 里会打 session id 的 logger(SSE 传输未启用,但一并覆盖防未来切换)
_TARGET_LOGGERS = (
    "mcp.server.streamable_http_manager",
    "mcp.server.streamable_http",
    "mcp.server.sse",
)


class SessionIdRedactionFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        try:
            message = record.getMessage()
        except Exception:
            return True
        redacted = _SESSION_ID_RE.sub(_REDACTED, message)
        if redacted != message:
            # 提前格式化并清空 args,下游 handler 只拿到脱敏后的完整文本
            record.msg = redacted
            record.args = None
        return True


def install_log_redaction() -> None:
    """幂等安装(logger 级 + 根 handler 级)。"""
    flt = SessionIdRedactionFilter()
    for name in _TARGET_LOGGERS:
        logger = logging.getLogger(name)
        if not any(isinstance(f, SessionIdRedactionFilter) for f in logger.filters):
            logger.addFilter(flt)
    for handler in logging.getLogger().handlers:
        if not any(isinstance(f, SessionIdRedactionFilter) for f in handler.filters):
            handler.addFilter(flt)
