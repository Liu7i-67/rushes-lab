"""11 个 MCP 工具的实际映射(工具注册在 tools.py,本模块可直接单测)。

设计要点:
- 每个 handler 接收 `ForwardContext`(PAT + 入口 Host/XFP/XFF),不做 MCP 协议耦合;
- 转发失败统一抛可读 `ToolError`(不落堆栈、不含凭证);
- 结构化字段一律白名单(不透 minio_key/minio_bucket/tags/openid/email),
  唯一例外:upload 三元组 upload_id/key/bucket 必须回传(complete 的入参)。
"""

from __future__ import annotations

import logging
from typing import Any
from urllib.parse import quote

import httpx
from mcp.server.fastmcp.exceptions import ToolError
from mcp.server.fastmcp.utilities.types import Image
from mcp.types import TextContent

from ms_mcp.clients import ApiClient, BytesClient, ForwardContext, describe_api_error
from ms_mcp.config import Settings
from ms_mcp.views import (
    asset_summary,
    build_folder_tree,
    project_summary,
    search_summary,
)

log = logging.getLogger(__name__)

MAX_UPLOAD_BYTES = 5 * 1024**3          # MinIO multipart 单 part 上限
LARGE_UPLOAD_HINT_BYTES = 1 * 1024**3   # 超过即提示「走内网入口」

LIST_FILES_PAGE_SIZE = 100
SEARCH_DEFAULT_LIMIT = 20
SEARCH_MAX_LIMIT = 50
PROJECTS_DEFAULT_LIMIT = 50
PROJECTS_MAX_LIMIT = 100

class ToolHandlers:
    def __init__(self, settings: Settings, api: ApiClient, bytes_client: BytesClient) -> None:
        self._settings = settings
        self._api = api
        self._bytes = bytes_client

    # ── 转发基础 ──────────────────────────────────────────────────────────────
    async def _send(
        self,
        method: str,
        path: str,
        fwd: ForwardContext,
        *,
        params: dict[str, str | int] | None = None,
        json: dict[str, object] | None = None,
        timeout_hint: str | None = None,
    ) -> httpx.Response:
        try:
            return await self._api.request(method, path, fwd, params=params, json=json)
        except httpx.TimeoutException:
            if timeout_hint:
                raise ToolError(timeout_hint) from None
            raise ToolError("请求素材 API 超时(30 秒),请稍后重试") from None
        except httpx.HTTPError:
            raise ToolError("无法连接素材 API 服务,请稍后重试") from None

    @staticmethod
    def _ensure_ok(resp: httpx.Response, action: str) -> None:
        if resp.status_code >= 400:
            raise ToolError(describe_api_error(resp, action).message)

    @staticmethod
    def _json(resp: httpx.Response, action: str) -> Any:
        try:
            return resp.json()
        except ValueError:
            raise ToolError(f"{action}失败:后端响应不是合法 JSON") from None

    @classmethod
    def _json_obj(cls, resp: httpx.Response, action: str) -> dict[str, Any]:
        data = cls._json(resp, action)
        if not isinstance(data, dict):
            raise ToolError(f"{action}失败:后端响应格式异常")
        return data

    @classmethod
    def _json_list(cls, resp: httpx.Response, action: str) -> list[dict[str, Any]]:
        data = cls._json(resp, action)
        if not isinstance(data, list):
            raise ToolError(f"{action}失败:后端响应格式异常")
        return [item for item in data if isinstance(item, dict)]

    # ── 身份 ─────────────────────────────────────────────────────────────────
    async def whoami(self, fwd: ForwardContext) -> dict[str, Any]:
        resp = await self._send("GET", "/api/v1/auth/me", fwd)
        self._ensure_ok(resp, "读取当前用户")
        data = self._json_obj(resp, "读取当前用户")
        # 白名单:不透 open_id / union_id / email / organization_id
        return {
            key: data.get(key)
            for key in (
                "id", "name", "is_active", "is_system_admin", "is_project_creator",
                "is_project_deleter", "is_folder_template_manager",
                "is_artist_account_creator", "is_file_deleter",
            )
        }

    # ── 浏览 ─────────────────────────────────────────────────────────────────
    async def list_projects(self, fwd: ForwardContext, page: int, limit: int) -> dict[str, Any]:
        limit = max(1, min(limit, PROJECTS_MAX_LIMIT))
        page = max(1, page)
        resp = await self._send(
            "GET", "/api/v1/projects", fwd,
            params={"limit": limit, "offset": (page - 1) * limit},
        )
        self._ensure_ok(resp, "列出项目")
        data = self._json_list(resp, "列出项目")
        items = [project_summary(p) for p in data]
        return {
            "items": items,
            "page": page,
            "limit": limit,
            "note": "API 不返回 total;返回条数达到 limit 时可能还有更多,请增大 page 继续翻页",
        }

    async def list_folders(self, fwd: ForwardContext, project_id: str) -> dict[str, Any]:
        resp = await self._send(
            "GET", "/api/v1/folders", fwd, params={"project_id": project_id}
        )
        self._ensure_ok(resp, "列出文件夹")
        data = self._json_list(resp, "列出文件夹")
        folders = data
        return {
            "project_id": project_id,
            "folder_count": len(folders),
            "roots": build_folder_tree(folders),
            "note": "direct_file_count=本夹直属文件数;subtree_file_count=整棵子树文件数",
        }

    async def list_files(self, fwd: ForwardContext, folder_id: str, page: int) -> dict[str, Any]:
        page = max(1, page)
        resp = await self._send(
            "GET", "/api/v1/assets", fwd,
            params={
                "folder_id": folder_id,
                "limit": LIST_FILES_PAGE_SIZE,
                "offset": (page - 1) * LIST_FILES_PAGE_SIZE,
            },
        )
        self._ensure_ok(resp, "列出文件")
        data = self._json_obj(resp, "列出文件")
        raw_items = data.get("items") or []
        items = [asset_summary(a) for a in raw_items if isinstance(a, dict)]
        total = int(data.get("total") or 0)
        return {
            "folder_id": folder_id,
            "page": page,
            "page_size": LIST_FILES_PAGE_SIZE,
            "total": total,
            "has_more": page * LIST_FILES_PAGE_SIZE < total,
            "items": items,
        }

    async def search_assets(self, fwd: ForwardContext, q: str, limit: int) -> dict[str, Any]:
        query = q.strip()
        if not query:
            raise ToolError("搜索关键词不能为空")
        limit = max(1, min(limit, SEARCH_MAX_LIMIT))
        resp = await self._send(
            "GET", "/api/v1/assets/search", fwd, params={"q": query, "limit": limit}
        )
        self._ensure_ok(resp, "搜索素材")
        data = self._json_list(resp, "搜索素材")
        items = [search_summary(a) for a in data]
        return {
            "q": query,
            "count": len(items),
            "items": items,
            "note": (
                "挑素材主路径:search_assets → get_thumbnail(先 small 看构图,需要细节再 large)"
                ";返回条数达到 limit 时可能还有更多,可提高 limit(≤50)"
            ),
        }

    # ── 缩略图 / 下载 ────────────────────────────────────────────────────────
    async def get_thumbnail(self, fwd: ForwardContext, asset_id: str, size: str) -> list[Any]:
        if size not in ("small", "large"):
            raise ToolError("size 只支持 small / large")
        # 该 URL 只被 ms-mcp 自己消费 → Host 固定取 MS_MCP_INTERNAL_BASE_URL(须在白名单内),
        # 而不是透传客户端 Host(否则公网入口会签出公网 URL,ms-mcp 需 hairpin 才能取字节)。
        thumb_fwd = ForwardContext(
            pat=fwd.pat,
            host=self._settings.internal_host,
            xfp=self._settings.internal_scheme,
            xff=fwd.xff,
        )
        resp = await self._send(
            "GET", f"/api/v1/assets/{quote(asset_id, safe='')}/thumbnail-url", thumb_fwd,
            params={"size": size},
        )
        if resp.status_code == 404:
            detail = ""
            try:
                detail = str(resp.json().get("detail") or "")
            except (ValueError, AttributeError):
                detail = ""
            if "thumbnail" in detail:
                raise ToolError(
                    "该素材尚未生成缩略图或不是图片"
                    "(thumbnail 可能仍在生成;非图片/视频请用 get_download_url)"
                )
            raise ToolError("素材不存在(可能已删除)")
        self._ensure_ok(resp, "签发缩略图")
        payload = self._json_obj(resp, "签发缩略图")
        url = payload.get("url")
        variant = payload.get("variant") or size
        expires_in = payload.get("expires_in") or 1800
        if not isinstance(url, str) or not url:
            raise ToolError("签发缩略图失败:后端未返回 URL")

        try:
            bresp = await self._bytes.get(url)
        except httpx.TimeoutException:
            raise ToolError("取缩略图字节超时(15 秒),请稍后重试") from None
        except httpx.HTTPError:
            raise ToolError("无法获取缩略图字节(请确认 MS_MCP_INTERNAL_BASE_URL 入口可达)") from None
        if bresp.status_code >= 400:
            raise ToolError(f"取缩略图字节失败(HTTP {bresp.status_code}),请稍后重试")
        content_type = (bresp.headers.get("content-type") or "").split(";")[0].strip().lower()
        if not content_type.startswith("image/"):
            raise ToolError(f"缩略图字节不是图片类型(content-type={content_type or '缺失'})")
        fmt = content_type.split("/", 1)[1] or "png"
        if fmt == "jpg":
            fmt = "jpeg"

        fallback = (
            "请求的 small 变体不存在,已回落返回 large(1024)主图"
            if size == "small" and variant == "large"
            else ""
        )
        text = (
            f"缩略图已返回(MCP image content)。实际规格 variant={variant}"
            f"(small=240px,large=1024px);签名有效期 {expires_in}s。"
            + (f"{fallback}。" if fallback else "")
            + "需要更高细节可再调用 get_thumbnail(size=\"large\")。"
        )
        return [Image(data=bresp.content, format=fmt), TextContent(type="text", text=text)]

    async def get_download_url(self, fwd: ForwardContext, asset_id: str) -> dict[str, Any]:
        resp = await self._send(
            "POST", f"/api/v1/assets/{quote(asset_id, safe='')}/download-link", fwd
        )
        self._ensure_ok(resp, "签发下载链接")
        data = self._json_obj(resp, "签发下载链接")
        return {
            "asset_id": asset_id,
            "url": data.get("url"),
            "expires_in": data.get("expires_in"),
            "is_sensitive": data.get("is_sensitive"),
            "notes": [
                "URL 15 分钟内有效;素材字节由 MCP 客户端自行 GET 下载,请勿反复续签",
                "该响应不含文件名/大小;需要展示请先用 search_assets / list_files 查 AssetOut",
                "能力边界:上传/下载都要求客户端具备 HTTP GET/PUT 能力;纯对话型客户端只能 search + thumbnail",
            ],
        }

    # ── 上传三步 ─────────────────────────────────────────────────────────────
    async def create_upload(
        self,
        fwd: ForwardContext,
        folder_id: str,
        filename: str,
        size_bytes: int,
        content_type: str,
    ) -> dict[str, Any]:
        if size_bytes > MAX_UPLOAD_BYTES:
            raise ToolError(
                "单文件上限 5GiB(MinIO multipart 单分片上限);更大文件的多分片上传属二期,请拆分或走网页上传"
            )
        if size_bytes < 0:
            raise ToolError("size_bytes 不能为负")
        resp = await self._send(
            "POST", "/api/v1/assets/uploads", fwd,
            json={
                "folder_id": folder_id,
                "filename": filename,
                "content_type": content_type,
                "size_bytes": size_bytes,
            },
        )
        if resp.status_code == 409:
            raise ToolError(describe_api_error(resp, "创建上传会话").message)
        self._ensure_ok(resp, "创建上传会话")
        data = self._json_obj(resp, "创建上传会话")
        upload_id = data.get("upload_id")
        key = data.get("key")
        bucket = data.get("bucket")
        if not upload_id or not key or not bucket:
            raise ToolError("创建上传会话失败:后端未返回 upload_id/key/bucket")

        try:
            part_resp = await self._send(
                "GET", f"/api/v1/assets/uploads/{quote(str(upload_id), safe='')}/parts/1", fwd,
                params={"bucket": str(bucket), "key": str(key)},
            )
            self._ensure_ok(part_resp, "签发分片 URL")
            part = self._json_obj(part_resp, "签发分片 URL")
        except ToolError:
            # 拿不到分片 URL 就不要留半成品 multipart
            await self._abort_quietly(fwd, str(upload_id), str(key), str(bucket))
            raise

        warnings: list[str] = []
        if size_bytes > LARGE_UPLOAD_HINT_BYTES:
            warnings.append(
                "文件 >1GiB:5GiB/900s ≈ 5.7MiB/s 持续上行,公网入口大概率跑不完;"
                "建议改走内网入口,失败请调用 abort_upload。"
            )
        return {
            "upload_id": upload_id,
            "key": key,
            "bucket": bucket,
            "first_part_url": part.get("url"),
            "part_number": 1,
            "expires_in": part.get("expires_in"),
            "warnings": warnings,
            "note": (
                "PUT URL 15 分钟内有效,拿到即传;直传 MinIO。"
                "PUT 成功后从响应头取 ETag,complete_upload 时回传。"
                "同一文件夹同名文件会 409,请重命名。"
            ),
        }

    async def get_part_url(
        self, fwd: ForwardContext, upload_id: str, key: str, bucket: str, part_number: int
    ) -> dict[str, Any]:
        resp = await self._send(
            "GET", f"/api/v1/assets/uploads/{quote(upload_id, safe='')}/parts/{part_number}", fwd,
            params={"bucket": bucket, "key": key},
        )
        self._ensure_ok(resp, "重签分片 URL")
        data = self._json_obj(resp, "重签分片 URL")
        return {
            "upload_id": upload_id,
            "part_number": part_number,
            "url": data.get("url"),
            "expires_in": data.get("expires_in"),
            "note": "同一 multipart 续传;勿重跑 create_upload(会另起孤儿 multipart)。只传自己刚创建的三元组",
        }

    async def abort_upload(
        self, fwd: ForwardContext, upload_id: str, key: str, bucket: str
    ) -> dict[str, Any]:
        resp = await self._send(
            "DELETE", f"/api/v1/assets/uploads/{quote(upload_id, safe='')}", fwd,
            params={"bucket": bucket, "key": key},
        )
        self._ensure_ok(resp, "中止上传")
        return {
            "upload_id": upload_id,
            "aborted": True,
            "note": "multipart 已中止;只传自己刚创建的三元组(他人 upload_id 会被拒)",
        }

    async def complete_upload(
        self,
        fwd: ForwardContext,
        upload_id: str,
        folder_id: str,
        key: str,
        bucket: str,
        etag: str,
        part_number: int,
    ) -> dict[str, Any]:
        filename = key.rsplit("/", 1)[-1]
        # 同夹同名窗口:create 期查重在 api,但 MCP 从 create 到 complete 可达分钟级
        # (web 是秒级),库上唯一约束在 version NULL 时拦不住两行同 key。complete 前
        # best-effort 复查一次(只缩小窗口、不是原子保证;方案明确不做端点改造)。
        if await self._same_name_exists(fwd, folder_id, filename):
            raise ToolError(
                f"目标文件夹已存在同名文件「{filename}」(可能上次 complete 已成功)。"
                "请先 search_assets / list_files 确认;确需上传请改名后重新 create_upload。"
            )
        body = {
            "upload_id": upload_id,
            "folder_id": folder_id,
            "bucket": bucket,
            "key": key,
            # API 契约 UploadCompleteIn.parts 是数组(单 etag 构造不出请求体 → 422)
            "parts": [{"PartNumber": part_number, "ETag": etag}],
        }
        resp = await self._send(
            "POST", f"/api/v1/assets/uploads/{quote(upload_id, safe='')}/complete", fwd,
            json=body,
            timeout_hint=(
                "complete 请求超时(30 秒):API 可能已经入库。请先 search_assets / list_files "
                "确认该文件是否已存在;已存在则勿重试,否则可 abort_upload 后重来。"
            ),
        )
        self._ensure_ok(resp, "完成上传")
        asset = self._json_obj(resp, "完成上传")
        summary = asset_summary(asset)
        summary["note"] = (
            "上传完成并已入库;缩略图由后台异步派生(稍后 get_thumbnail 可见)。"
        )
        return summary

    async def _same_name_exists(
        self, fwd: ForwardContext, folder_id: str, filename: str
    ) -> bool:
        """complete 前 best-effort 复查(搜索失败一律放行,不阻塞正常上传)。"""
        try:
            resp = await self._api.request(
                "GET", "/api/v1/assets/search", fwd,
                params={"q": filename, "limit": SEARCH_MAX_LIMIT},
            )
        except httpx.HTTPError:
            log.warning("complete 前同名复查请求失败,按未命中继续")
            return False
        if resp.status_code >= 400:
            log.warning("complete 前同名复查返回 HTTP %s,按未命中继续", resp.status_code)
            return False
        try:
            data = resp.json()
        except ValueError:
            return False
        if not isinstance(data, list):
            return False
        return any(
            isinstance(item, dict)
            and item.get("folder_id") == folder_id
            and item.get("filename") == filename
            for item in data
        )

    async def _abort_quietly(
        self, fwd: ForwardContext, upload_id: str, key: str, bucket: str
    ) -> None:
        try:
            resp = await self._api.request(
                "DELETE", f"/api/v1/assets/uploads/{quote(upload_id, safe='')}", fwd,
                params={"bucket": bucket, "key": key},
            )
            if resp.status_code >= 400:
                log.warning("create_upload 失败后的补偿 abort 未成功: HTTP %s", resp.status_code)
        except httpx.HTTPError:
            log.warning("create_upload 失败后的补偿 abort 网络异常")
