"""两条 HTTP 通路 + 转发头语义。

1. `ApiClient`   —— 带 PAT 调 api 的转发客户端(UA=msmcp/<ver>,剥离 Cookie / X-User-Id,
   透传 Host + X-Forwarded-Proto + X-Forwarded-For,超时 30s)。
2. `BytesClient` —— 只用于取缩略图字节:独立客户端、**不带任何认证头**
   (S3/MinIO 对「query 签名 + Authorization 并存」回 400),超时 15s。

两个客户端共用同一 CA / verify 配置。token 只在本进程内存里流转,不落盘、不写日志。
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

import httpx

from ms_mcp import USER_AGENT

log = logging.getLogger(__name__)

FORWARD_TIMEOUT_SECONDS = 30.0
THUMBNAIL_TIMEOUT_SECONDS = 15.0
_MAX_DETAIL_CHARS = 200


@dataclass(frozen=True)
class ForwardContext:
    """一次 MCP 请求对应的转发语义(由守门中间件写入 scope state)。"""

    pat: str
    host: str               # 客户端入口 Host,原样(含端口)
    xfp: str                # 已按白名单条目归一
    xff: str | None         # 入口 nginx real_ip 还原后的单值;不要追加


class ApiError(Exception):
    """api 返回 >=400 或网络层失败的可读包装(不含堆栈 / 不含凭证)。"""

    def __init__(self, status: int, message: str, *, retry_after: str | None = None) -> None:
        super().__init__(message)
        self.status = status
        self.message = message
        self.retry_after = retry_after

    @property
    def is_retryable(self) -> bool:
        return self.status == 429 or self.status >= 500


def _clean_xff(raw: str | None) -> str | None:
    """XFF 原样透传单值:去掉首尾空白、拒绝 CR/LF 与超长(防头注入)。"""
    if not raw:
        return None
    value = raw.strip()
    if not value or "\r" in value or "\n" in value or len(value) > 256:
        return None
    return value


def _verify_arg(*, verify_tls: bool, ca_bundle: str | None) -> bool | str:
    if ca_bundle:
        return ca_bundle
    return verify_tls


def _short_detail(resp: httpx.Response) -> str:
    try:
        payload = resp.json()
    except ValueError:
        text = resp.text
        return " ".join(text.split())[:_MAX_DETAIL_CHARS]
    if isinstance(payload, dict):
        detail = payload.get("detail")
        if isinstance(detail, str):
            return " ".join(detail.split())[:_MAX_DETAIL_CHARS]
        if detail is not None:
            return " ".join(str(detail).split())[:_MAX_DETAIL_CHARS]
    return ""


def describe_api_error(resp: httpx.Response, action: str) -> ApiError:
    """把 api 状态码翻成给 AI 看的可读文案(不暴露堆栈)。"""
    status = resp.status_code
    if status == 401:
        base = "令牌无效或已过期,请在网页「设置 → 访问令牌」重新签发,并让 MCP 客户端重新 initialize"
    elif status == 403:
        base = "后端拒绝访问(可能 MCP 通道已关闭 / 无该操作权限 / 账号处于强制改密态)"
    elif status == 404:
        base = "目标不存在(可能已删除或尚未生成)"
    elif status == 409:
        base = "冲突"
    elif status == 429:
        base = "调用过于频繁(限流),请退避后重试"
    elif status == 503:
        base = "后端暂不可用(Redis 故障或上传会话初始化失败),请稍后重试"
    elif status >= 500:
        base = "后端内部错误,请稍后重试"
    else:
        base = "请求失败"
    detail = _short_detail(resp)
    message = f"{action}失败(HTTP {status}):{base}"
    if detail:
        message = f"{message} —— {detail}"
    return ApiError(status, message, retry_after=resp.headers.get("retry-after"))


class ApiClient:
    """带 PAT 的 api 转发客户端(单个长连接复用实例)。"""

    def __init__(
        self,
        base_url: str,
        *,
        verify_tls: bool = True,
        ca_bundle: str | None = None,
        timeout: float = FORWARD_TIMEOUT_SECONDS,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self._client = httpx.AsyncClient(
            base_url=base_url,
            timeout=httpx.Timeout(timeout, connect=10.0),
            verify=_verify_arg(verify_tls=verify_tls, ca_bundle=ca_bundle),
            transport=transport,
            follow_redirects=False,
            trust_env=False,
        )

    @staticmethod
    def build_headers(fwd: ForwardContext) -> dict[str, str]:
        headers = {
            "Authorization": f"Bearer {fwd.pat}",
            "User-Agent": USER_AGENT,
            # 反向代理语义:Host 原样(含端口),api 的动态预签名据此签 URL
            "Host": fwd.host,
            "X-Forwarded-Proto": fwd.xfp,
            "Accept": "application/json",
        }
        xff = _clean_xff(fwd.xff)
        if xff:
            headers["X-Forwarded-For"] = xff
        # 刻意不设置 Cookie / X-User-Id:前者会走 session 分支绕过 PAT 闸与统计,
        # 后者在 dev 环境可冒充身份。
        return headers

    async def request(
        self,
        method: str,
        path: str,
        fwd: ForwardContext,
        *,
        params: dict[str, str | int] | None = None,
        json: dict[str, object] | None = None,
    ) -> httpx.Response:
        try:
            resp = await self._client.request(
                method, path, params=params, json=json, headers=self.build_headers(fwd)
            )
        finally:
            # api 若返回 Set-Cookie,绝不能在后续工具调用里被重放
            self._client.cookies.clear()
        log.info("api %s %s -> %s", method, path, resp.status_code)
        return resp

    async def aclose(self) -> None:
        await self._client.aclose()


class BytesClient:
    """缩略图字节客户端:独立实例、无认证头(仅 URL 查询串签名)。"""

    def __init__(
        self,
        *,
        verify_tls: bool = True,
        ca_bundle: str | None = None,
        timeout: float = THUMBNAIL_TIMEOUT_SECONDS,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self._client = httpx.AsyncClient(
            timeout=httpx.Timeout(timeout, connect=10.0),
            verify=_verify_arg(verify_tls=verify_tls, ca_bundle=ca_bundle),
            transport=transport,
            follow_redirects=False,
            trust_env=False,
        )

    async def get(self, url: str) -> httpx.Response:
        # 只带 Accept:Authorization / Cookie / X-User-Id 全都不带
        try:
            return await self._client.get(url, headers={"Accept": "image/*"})
        finally:
            self._client.cookies.clear()

    async def aclose(self) -> None:
        await self._client.aclose()
