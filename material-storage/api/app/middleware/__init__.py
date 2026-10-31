"""ASGI 中间件(纯 ASGI,禁 ``BaseHTTPMiddleware``)。

目前只有 MCP 通道流量统计 ``mcp_stats``;新增中间件请放在本包下并保持纯 ASGI
(``BaseHTTPMiddleware`` 会缓冲/改写响应体,流式端点与 SSE 都会受影响)。
"""
