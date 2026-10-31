# ms-mcp Dockerfile —— material-storage MCP 薄代理(官方 mcp 包 FastMCP)
# 单 stage;照抄 api/Dockerfile 的清华 APT/PIP build arg(避 GFW),但依赖闭包
# 独立于 api(见 constraints.txt 头注,勿混塞 api 闭包)。
FROM python:3.12-slim

ARG APT_MIRROR=mirrors.tuna.tsinghua.edu.cn
ARG PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple

RUN sed -i "s|deb.debian.org|${APT_MIRROR}|g" /etc/apt/sources.list.d/debian.sources \
 && apt-get update -qq \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && pip config set global.index-url ${PIP_INDEX_URL}

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app
COPY pyproject.toml constraints.txt README.md ./
COPY src /app/src
# -c constraints.txt:传递依赖闭包全 pin(只约束不强制,pyproject 新增依赖仍需补 pin)
RUN pip install --no-cache-dir -c constraints.txt .

# 非 root;运行期只读代码,无写盘需求(token 只在内存)
RUN useradd --create-home --uid 10001 --shell /usr/sbin/nologin msmcp
USER msmcp

EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=3)"]

CMD ["python", "-m", "ms_mcp"]
