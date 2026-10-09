"""百度网盘开放平台 API 客户端(方案 §5.1;实测逻辑收敛自 scripts/task/baidu_*.py)。

实测约束(方案 §2):
- OAuth 授权码模式 + redirect_uri=oob;授权码 10 分钟单次有效 → 只换 token 不存 code;
  refresh_token 单次有效,刷新响应携带新值,须原子覆盖
- xpan 接口必须 UA=pan.baidu.com;下载 URL 必须拼 access_token 且 302 需跟随
- filemetas 批量在 /rest/2.0/xpan/multimedia(打 /xpan/file 同名 method 会静默返回空),
  每次最多 100 个 fsid;dlink 8 小时有效,仅存原始 dlink 不拼 token(下载时现拼)
- 下载 read timeout ≤15s(≤ 租约/4,§6 硬约束);302 逐跳校验宿主后缀白名单
  *.pcs.baidu.com / *.baidupcs.com(SSRF 防御)

统一错误对象 BaiduApiError:六类分类(§5.3 矩阵,纯函数 classify_baidu_failure);
错误对象/日志一律剥 URL query(access_token 脱敏)。
"""
from __future__ import annotations

import json
import logging
import re
from collections.abc import AsyncIterator, Sequence
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlencode

import httpx

from app.settings import Settings

log = logging.getLogger(__name__)

# ─── 端点与常量(端点路径与调研脚本实测一致;base 从 Settings 注入,便于测试)──
# openapi/pan 的 base URL 由 settings.baidu_openapi_base_url / baidu_pan_base_url
# 提供(默认生产端点),构造时拼出下列路径;下载 CDN 白名单与 d.pcs 重定向逻辑
# 不随此开关,见 _ALLOWED_DL_HOST_SUFFIXES / stream_download
_PAN_UA = "pan.baidu.com"          # xpan/下载接口官方要求 UA
_REDIRECT_URI_DEFAULT = "oob"
_OAUTH_SCOPE = "basic,netdisk"
_PAGE_LIMIT = 1000                 # list 单页官方建议上限
_FILEMETAS_MAX_FSIDS = 100         # filemetas 批量上限(方案 §2.4)
_MAX_REDIRECTS = 5                 # 下载 302 跟随上限
_READ_TIMEOUT_S = 15.0             # ≤ 租约/4(§6:防单次读阻塞跨过租约)
_ALLOWED_DL_HOST_SUFFIXES = ("pcs.baidu.com", "baidupcs.com")

# ─── 错误分类(§5.3 六类)────────────────────────────────────────────────────
CATEGORY_AUTH_EXPIRED = "auth_expired"
CATEGORY_RATE_LIMITED = "rate_limited"
CATEGORY_LINK_EXPIRED = "link_expired"
CATEGORY_NOT_FOUND = "not_found"
CATEGORY_BAIDU_PERMISSION_DENIED = "baidu_permission_denied"
CATEGORY_UNKNOWN = "unknown"
BAIDU_ERROR_CATEGORIES = (
    CATEGORY_AUTH_EXPIRED, CATEGORY_RATE_LIMITED, CATEGORY_LINK_EXPIRED,
    CATEGORY_NOT_FOUND, CATEGORY_BAIDU_PERMISSION_DENIED, CATEGORY_UNKNOWN,
)

# errno → 分类矩阵(§5.3;批次 1 实测核定后在此维护)
_AUTH_EXPIRED_ERRNOS = {-6, 111}     # 鉴权失效类 → 触发 refresh(单飞)
_LINK_EXPIRED_ERRNOS = {31360, 31045}
# 31045:官方下载文档与调研脚本注释均指向"token 校验未通过",语义待定 —— 归类保持
# link_expired,§5.3 的「先按 auth_expired 试一次 refresh 再回落 link_expired」由
# 调用方承担(workers/baidu_backup.py:_handle_baidu_error 的 31045 分支);错误对象
# 保留原始 errno 供甄别,批次 1 实测确认后再调整归类。
_NOT_FOUND_ERRNOS = {-9, 31064}      # 文件不存在(两次 filemetas 复核均命中才 non_retryable)
_PERMISSION_ERRNOS = {-7, 20011}     # 权限/路径越界类(403 先解析 body errno 甄别)

# OAuth grant 类错误(授权码/refresh_token 过期或已用)→ 按 auth_expired 分类
_OAUTH_GRANT_ERRORS = {"expired_token", "invalid_grant"}


@dataclass(frozen=True)
class BaiduApiError(Exception):
    """百度侧错误的统一对象(§5.3)。

    message 已剥 URL query(access_token 脱敏);errno/http_status 保留明文,
    供调用方做"403 甄别 dlink_fetched_at vs token_rotated_at"等二次判定。
    """

    category: str
    message: str
    errno: int | None = None
    http_status: int | None = None

    def __str__(self) -> str:
        return f"[{self.category}] {self.message}"


@dataclass(frozen=True)
class BaiduTokenPair:
    """exchange_code / refresh_token 的归一返回(原子覆盖落库的载体)。"""

    access_token: str
    refresh_token: str
    expires_in: int  # 秒


@dataclass(frozen=True)
class BaiduUserInfo:
    """uinfo(xpan/nas?method=uinfo)归一返回;绑定落库 NOT NULL 防线用(§4)。"""

    uid: str
    nickname: str | None  # 缺失时 UI 回退展示 uid


@dataclass(frozen=True)
class BaiduListResult:
    """list_dir 聚合结果;truncated=True 表示超页数上限,调用方提示「目录过大,分批浏览」。"""

    items: list[dict[str, Any]]
    truncated: bool


# ─── URL / 文本脱敏(§5.1:错误对象/日志必须剥 URL query)─────────────────────
def strip_url_query(url: str) -> str:
    """剥除 URL 的整个 query(百度请求 URL 携带 access_token,原样落日志即泄密)。"""
    return url.split("?", 1)[0]


_URL_WITH_QUERY_RE = re.compile(r"https?://\S+")


def sanitize_message(text: str) -> str:
    """自由文本兜底脱敏:消息里可能混入原始 URL(如 httpx 异常 str),统一剥 query。"""
    return _URL_WITH_QUERY_RE.sub(lambda m: strip_url_query(m.group(0)) + "?…", text)


def host_allowed(host: str | None) -> bool:
    """下载宿主白名单:*.pcs.baidu.com / *.baidupcs.com(含裸域)。

    DNS FQDN 尾点(根标记,如 "d.pcs.baidu.com.")先规范化剥除再比较(§5.1);
    其余按字面后缀匹配("pcs.baidu.com.evil.com" 类后缀欺骗仍拒绝)。
    """
    if not host:
        return False
    lowered = host.lower().rstrip(".")
    return any(
        lowered == suffix or lowered.endswith("." + suffix)
        for suffix in _ALLOWED_DL_HOST_SUFFIXES
    )


def classify_baidu_failure(*, http_status: int | None, errno: int | None = None) -> str:
    """§5.3 HTTP x errno 分类矩阵(纯函数,单测友好)。

    优先级:HTTP 401 > 403(先解析 body errno 甄别权限类,其余按频控)>
    5xx/429 > errno 表 > unknown。
    """
    if http_status == 401:
        return CATEGORY_AUTH_EXPIRED
    if http_status == 403:
        # 403 一刀切会把权限错误烧光退避并产出误导性"频控"失败原因(§5.3):
        # 先按 body errno 甄别权限/路径类,其余(频控特征)归 rate_limited
        if errno is not None and errno in _PERMISSION_ERRNOS:
            return CATEGORY_BAIDU_PERMISSION_DENIED
        return CATEGORY_RATE_LIMITED
    if http_status is not None and (http_status == 429 or http_status >= 500):
        return CATEGORY_RATE_LIMITED
    if errno is not None:
        if errno in _AUTH_EXPIRED_ERRNOS:
            return CATEGORY_AUTH_EXPIRED
        if errno in _LINK_EXPIRED_ERRNOS:
            return CATEGORY_LINK_EXPIRED
        if errno in _NOT_FOUND_ERRNOS:
            return CATEGORY_NOT_FOUND
        if errno in _PERMISSION_ERRNOS:
            return CATEGORY_BAIDU_PERMISSION_DENIED
    return CATEGORY_UNKNOWN


def _extract_errno(body: dict[str, Any]) -> int | None:
    """从响应体提取 errno;部分响应把 errno/list 包在 data 对象里(调研实测)。"""
    data = body.get("data")
    if isinstance(data, dict) and "errno" in data:
        return int(data["errno"])
    if "errno" in body:
        return int(body["errno"])
    return None


class BaiduNetdiskClient:
    """百度网盘 API 客户端;实例挂 app.state.baidu_client(lifespan 构造,单例 httpx)。"""

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        # 端点从 settings 拼(默认生产;测试/调试注入本地桩);rstrip 防末尾斜杠双 //
        openapi = settings.baidu_openapi_base_url.rstrip("/")
        pan = settings.baidu_pan_base_url.rstrip("/")
        self._oauth_authorize_url = f"{openapi}/oauth/2.0/authorize"
        self._oauth_token_url = f"{openapi}/oauth/2.0/token"
        self._xpan_file_url = f"{pan}/rest/2.0/xpan/file"
        self._xpan_multimedia_url = f"{pan}/rest/2.0/xpan/multimedia"
        self._xpan_nas_url = f"{pan}/rest/2.0/xpan/nas"
        # read timeout ≤15s(§6);follow_redirects 关闭 —— 下载 302 需逐跳做宿主白名单校验
        self._http = httpx.AsyncClient(
            timeout=httpx.Timeout(connect=10.0, read=_READ_TIMEOUT_S, write=15.0, pool=15.0),
            follow_redirects=False,
        )

    async def close(self) -> None:
        await self._http.aclose()

    @property
    def credentials_ready(self) -> bool:
        """AppKey/SecretKey 均已配置(绑定/授权链接前置检查)。"""
        return bool(self._settings.baidu_app_key and self._settings.baidu_app_secret)

    # ─── OAuth(授权码模式,oob)────────────────────────────────────────────
    def authorize_url(self, redirect_uri: str = _REDIRECT_URI_DEFAULT) -> str:
        """生成授权链接(oob):用户在任意可上网设备浏览器打开,授权后复制授权码回填。"""
        app_key = self._settings.baidu_app_key
        if not app_key:
            raise BaiduApiError(CATEGORY_UNKNOWN, "BAIDU_APP_KEY 未配置,无法生成授权链接")
        params = {
            "response_type": "code",
            "client_id": app_key,
            "redirect_uri": redirect_uri,
            "scope": _OAUTH_SCOPE,
        }
        return f"{self._oauth_authorize_url}?{urlencode(params)}"

    async def exchange_code(
        self, code: str, redirect_uri: str = _REDIRECT_URI_DEFAULT,
    ) -> BaiduTokenPair:
        """授权码 → token(10 分钟内、单次;失败多为 code 过期/已用,auth_expired 类)。"""
        if not (self._settings.baidu_app_key and self._settings.baidu_app_secret):
            raise BaiduApiError(CATEGORY_UNKNOWN, "百度应用凭证未配置(KEY/SECRET)")
        return await self._oauth_token_request({
            "grant_type": "authorization_code",
            "code": code,
            "client_id": self._settings.baidu_app_key,
            "client_secret": self._settings.baidu_app_secret,
            "redirect_uri": redirect_uri,
        }, context="授权码换取 token 失败")

    async def refresh_token(self, refresh_token: str) -> BaiduTokenPair:
        """刷新 token;响应携带新 refresh_token(单次有效),调用方必须原子覆盖落库。"""
        if not (self._settings.baidu_app_key and self._settings.baidu_app_secret):
            raise BaiduApiError(CATEGORY_UNKNOWN, "百度应用凭证未配置(KEY/SECRET)")
        return await self._oauth_token_request({
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "client_id": self._settings.baidu_app_key,
            "client_secret": self._settings.baidu_app_secret,
        }, context="刷新 token 失败")

    async def _oauth_token_request(
        self, data: dict[str, str], *, context: str,
    ) -> BaiduTokenPair:
        try:
            resp = await self._http.post(self._oauth_token_url, data=data)
        except httpx.HTTPError as e:
            raise BaiduApiError(
                CATEGORY_UNKNOWN, f"{context}:网络错误({sanitize_message(str(e))})",
            ) from e
        try:
            body: dict[str, Any] = resp.json()
        except ValueError as e:
            raise BaiduApiError(
                CATEGORY_UNKNOWN,
                f"{context}:HTTP {resp.status_code} 非 JSON 响应",
            ) from e
        if "access_token" not in body:
            # OAuth 错误响应:HTTP 400 + {"error", "error_description"}
            oauth_err = str(body.get("error") or "unknown")
            category = (
                CATEGORY_AUTH_EXPIRED if oauth_err in _OAUTH_GRANT_ERRORS else CATEGORY_UNKNOWN
            )
            raise BaiduApiError(
                category,
                f"{context}:{oauth_err}:{body.get('error_description', '')}",
                http_status=resp.status_code,
            )
        return BaiduTokenPair(
            access_token=str(body["access_token"]),
            refresh_token=str(body["refresh_token"]),
            expires_in=int(body.get("expires_in", 0)),
        )

    # ─── xpan 接口(UA=pan.baidu.com;access_token in query)────────────────
    async def uinfo(self, access_token: str) -> BaiduUserInfo:
        """绑定身份(xpan/nas?method=uinfo):uid 为绑定落库 NOT NULL 防线(方案 §4)。

        注:uid/nickname 的响应字段名待批次 1 真机实测核定(§10 批次 1),
        此处按官方文档口径多候选解析。
        """
        body = await self._xpan_get_json(self._xpan_nas_url, {"method": "uinfo"}, access_token)
        uid = body.get("user_id") or body.get("baidu_uid") or body.get("uk")
        if uid in (None, ""):
            raise BaiduApiError(
                CATEGORY_UNKNOWN,
                f"uinfo 未返回 uid(待实测核定字段),响应 keys={sorted(body.keys())}",
            )
        nickname = body.get("netdisk_name") or body.get("baidu_name") or body.get("nickname")
        return BaiduUserInfo(uid=str(uid), nickname=str(nickname) if nickname else None)

    async def list_dir(
        self,
        access_token: str,
        dir_path: str,
        *,
        folders_only: bool = False,
        max_pages: int = 10,
    ) -> BaiduListResult:
        """列目录(xpan file method=list),后端按 start/limit 循环聚合(§5.2)。

        单页上限 1000;>1000 条的目录静默截断不可接受 → 聚合至多 max_pages 页,
        仍未取尽置 truncated=True(调用方提示「目录过大,分批浏览」)。
        folders_only=True 时 folder=1(仅目录,条目仅含 path 字段)。
        """
        items: list[dict[str, Any]] = []
        start = 0
        for _page in range(max(1, max_pages)):
            params: dict[str, str | int] = {
                "method": "list",
                "dir": dir_path,
                "order": "name",
                "start": start,
                "limit": _PAGE_LIMIT,
            }
            if folders_only:
                params["folder"] = 1
            body = await self._xpan_get_json(self._xpan_file_url, params, access_token)
            page = body.get("data", {}).get("list") if isinstance(
                body.get("data"), dict,
            ) else body.get("list")
            rows: list[dict[str, Any]] = list(page or [])
            items.extend(rows)
            if len(rows) < _PAGE_LIMIT:
                return BaiduListResult(items=items, truncated=False)
            start += len(rows)
        return BaiduListResult(items=items, truncated=True)

    async def filemetas_batch(
        self, access_token: str, fsids: Sequence[int], *, dlink: bool = True,
    ) -> list[dict[str, Any]]:
        """批量取文件元信息(含 dlink)。

        端点必须打 /rest/2.0/xpan/multimedia —— /xpan/file 同名 method 会静默
        返回空列表(方案 §2.4 实测);每次至多 _FILEMETAS_MAX_FSIDS 个 fsid。
        """
        fsid_list = list(fsids)
        if not fsid_list:
            return []
        if len(fsid_list) > _FILEMETAS_MAX_FSIDS:
            raise ValueError(
                f"filemetas 单次至多 {_FILEMETAS_MAX_FSIDS} 个 fsid,收到 {len(fsid_list)}"
            )
        params: dict[str, str | int] = {
            "method": "filemetas",
            "fsids": json.dumps(fsid_list),
            "dlink": 1 if dlink else 0,
        }
        body = await self._xpan_get_json(self._xpan_multimedia_url, params, access_token)
        data = body.get("data")
        rows = data.get("list") if isinstance(data, dict) else body.get("list")
        return list(rows or [])

    async def _xpan_get_json(
        self, url: str, params: dict[str, str | int], access_token: str,
    ) -> dict[str, Any]:
        """xpan GET + JSON 解析 + errno/HTTP 状态统一归类(§5.3)。"""
        full_params = {**params, "access_token": access_token}
        try:
            resp = await self._http.get(url, params=full_params, headers={"User-Agent": _PAN_UA})
        except httpx.HTTPError as e:
            # 网络层错误(URL 已剥 query;httpx 异常文本兜底脱敏)
            raise BaiduApiError(
                CATEGORY_UNKNOWN,
                f"百度接口网络错误:{sanitize_message(str(e))}",
            ) from e
        if resp.status_code >= 400:
            # 百度 4xx/5xx 时 body 常仍是 JSON(含 errno / error 字段)—— 403 须先解析
            body_errno = self._safe_body_errno(resp)
            raise BaiduApiError(
                classify_baidu_failure(http_status=resp.status_code, errno=body_errno),
                f"百度接口 HTTP {resp.status_code}"
                + (f" errno={body_errno}" if body_errno is not None else "")
                + f" url={strip_url_query(str(resp.request.url))}",
                errno=body_errno,
                http_status=resp.status_code,
            )
        try:
            body: dict[str, Any] = resp.json()
        except ValueError as e:
            raise BaiduApiError(
                CATEGORY_UNKNOWN,
                f"百度接口返回非 JSON:HTTP {resp.status_code}"
                f" url={strip_url_query(str(resp.request.url))}",
            ) from e
        errno = _extract_errno(body)
        if errno:
            raise BaiduApiError(
                classify_baidu_failure(http_status=None, errno=errno),
                f"百度接口 errno={errno}"
                + (f" show_msg={body.get('show_msg')}" if body.get("show_msg") else "")
                + f" url={strip_url_query(str(resp.request.url))}",
                errno=errno,
                http_status=resp.status_code,
            )
        return body

    @staticmethod
    def _safe_body_errno(resp: httpx.Response) -> int | None:
        try:
            return _extract_errno(resp.json())
        except ValueError:
            return None

    # ─── 下载(Range / 302 白名单跟随 / 流式)───────────────────────────────
    async def stream_download(
        self,
        access_token: str,
        dlink: str,
        *,
        range_header: str | None = None,
        chunk_size: int = 64 * 1024,
    ) -> AsyncIterator[bytes]:
        """流式下载(§5.1):dlink 现拼 access_token,302 手动逐跳跟随。

        - 每一跳(含首跳)宿主做 *.pcs.baidu.com/*.baidupcs.com 后缀白名单校验
          (dlink 来自外部 API 响应字段,一行代码量级的 SSRF 防御)
        - Range 断点续传由调用方传 range_header(如 "bytes=1048576-");服务端
          忽略 Range 返回 200 全量属其自由(调研实测),调用方按实际读到的字节记账
        - read timeout ≤15s;错误统一 BaiduApiError(HTTP 状态 + body errno 分类)
        """
        if not dlink:
            raise BaiduApiError(CATEGORY_UNKNOWN, "dlink 为空,无法下载")
        sep = "&" if "?" in dlink else "?"
        url = f"{dlink}{sep}access_token={access_token}"
        headers = {"User-Agent": _PAN_UA}
        if range_header:
            headers["Range"] = range_header

        first_host = httpx.URL(url).host
        if not host_allowed(first_host):
            raise BaiduApiError(
                CATEGORY_UNKNOWN,
                f"下载宿主不在白名单,拒绝请求:{first_host}"
                f"(仅允许 *.{'/ *.'.join(_ALLOWED_DL_HOST_SUFFIXES)})",
            )

        resp: httpx.Response | None = None
        for _hop in range(_MAX_REDIRECTS + 1):
            req = self._http.build_request("GET", url, headers=headers)
            try:
                resp = await self._http.send(req, stream=True)
            except httpx.HTTPError as e:
                raise BaiduApiError(
                    CATEGORY_UNKNOWN,
                    f"下载网络错误:{sanitize_message(str(e))}",
                ) from e
            if resp.is_redirect:
                location = resp.headers.get("location", "")
                await resp.aclose()
                if not location:
                    raise BaiduApiError(
                        CATEGORY_UNKNOWN, f"302 缺少 Location:url={strip_url_query(url)}",
                    )
                next_url = str(httpx.URL(url).join(location))
                next_host = httpx.URL(next_url).host
                if not host_allowed(next_host):
                    raise BaiduApiError(
                        CATEGORY_UNKNOWN,
                        f"重定向宿主不在白名单,拒绝跟随:{next_host}"
                        "(仅允许 *.pcs.baidu.com / *.baidupcs.com)",
                    )
                url = next_url
                continue
            break
        else:
            raise BaiduApiError(
                CATEGORY_UNKNOWN,
                f"重定向次数超上限({_MAX_REDIRECTS}):url={strip_url_query(url)}",
            )
        assert resp is not None

        if resp.status_code not in (200, 206):
            body_errno = self._safe_body_errno(resp)
            await resp.aclose()
            raise BaiduApiError(
                classify_baidu_failure(http_status=resp.status_code, errno=body_errno),
                f"下载失败 HTTP {resp.status_code}"
                + (f" errno={body_errno}" if body_errno is not None else "")
                + f" url={strip_url_query(url)}",
                errno=body_errno,
                http_status=resp.status_code,
            )
        try:
            async for chunk in resp.aiter_bytes(chunk_size):
                yield chunk
        finally:
            await resp.aclose()
