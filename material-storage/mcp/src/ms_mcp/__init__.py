"""ms-mcp —— material-storage 的 MCP 薄代理(官方 mcp 包 FastMCP / Streamable HTTP)。"""

__version__ = "0.1.0"

USER_AGENT = f"msmcp/{__version__}"

MCP_PATH = "/mcp"
HEALTH_PATH = "/healthz"
MCP_SESSION_HEADER = "mcp-session-id"
