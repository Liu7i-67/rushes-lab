"""MCP 工具注册(11 个):薄封装 + 工具描述 + 按调用粒度的信号量。

工具描述是给 AI 看的操作契约(主路径、上限、过期、ETag、409、超时处置),
改动时保持与 toolimpl / 方案表一致。
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
from typing import Annotated, Any

from mcp.server.fastmcp import Context, FastMCP
from mcp.server.fastmcp.exceptions import ToolError
from pydantic import Field

from ms_mcp.clients import ForwardContext
from ms_mcp.config import Settings
from ms_mcp.toolimpl import (
    LIST_FILES_PAGE_SIZE,
    MAX_UPLOAD_BYTES,
    PROJECTS_DEFAULT_LIMIT,
    PROJECTS_MAX_LIMIT,
    SEARCH_DEFAULT_LIMIT,
    SEARCH_MAX_LIMIT,
    ToolHandlers,
)

SERVER_INSTRUCTIONS = (
    "素材库(Material Storage)助手。身份=用户本人的访问令牌(PAT),权限与网页登录一致。\n"
    "挑素材主路径:search_assets 搜索 → get_thumbnail 看缩略图(先 size=small 看构图,需要细节再 size=large)。\n"
    "下载:get_download_url 返回 15 分钟有效的 presigned URL,字节由客户端自行 GET 取,勿反复续签。\n"
    "上传:create_upload → 客户端 PUT 直传 MinIO(URL 15 分钟内有效)→ complete_upload"
    "(ETag 取自分片 PUT 的响应头)。单分片 ≤5GiB;同一文件夹同名文件会 409。\n"
    "complete_upload 超时后先 search_assets/list_files 确认资产是否已入库,再决定重试或 abort_upload。"
)

DESC_WHOAMI = "查看当前访问令牌对应的用户身份与权限标记(不透邮箱/open_id 等内部字段)。"

DESC_LIST_PROJECTS = (
    "列出当前用户可见的项目(自动按权限过滤)。page 从 1 开始,limit 默认 50、上限 100。"
    "API 不返回 total:返回条数达到 limit 时可能还有更多,请增大 page 继续翻页。"
)

DESC_LIST_FOLDERS = (
    "列出项目内全部可见文件夹并组装成 children 树(服务端已组树)。"
    "direct_file_count=本夹直属文件数,subtree_file_count=整棵子树文件数。"
)

DESC_LIST_FILES = (
    f"分页列出文件夹内文件(每页固定 {LIST_FILES_PAGE_SIZE} 条,page 从 1 开始),含文件名/大小/类型/标签/备注。"
    "返回 total 与 has_more。"
)

DESC_SEARCH = (
    "跨文件夹盲搜素材(匹配文件名/标签/备注,权限过滤内建)。挑素材主路径:先 search_assets,"
    "再对候选调 get_thumbnail(先 small,需要细节再 large)。limit 默认 20、上限 50。"
)

DESC_GET_THUMBNAIL = (
    "获取素材缩略图并以 MCP image content 返回(可直接看图)。size=small(240px,优先)或 large(1024px)。"
    "返回文本里标注 variant 实际规格(small 变体缺失时会回落 large)。无缩略图(尚未生成/非图片)会明确报错。"
)

DESC_GET_DOWNLOAD_URL = (
    "签发素材原片下载 URL(15 分钟有效,host 跟随你的入口)。返回的是 URL 不是字节:"
    "请由 MCP 客户端自行 HTTP GET 取字节,勿反复续签。响应不含文件名/大小,需要时先 search_assets/list_files。"
    "上传/下载都要求客户端具备 HTTP GET/PUT 能力;纯对话型客户端只能搜索+看缩略图。"
)

DESC_CREATE_UPLOAD = (
    "创建单分片上传会话(单文件 ≤5GiB;API 不校验上限,本工具先拒)。返回 upload_id/key/bucket、"
    "第一个分片的 presigned PUT URL(15 分钟内有效,拿到即传)与提示。客户端直接 PUT 到 MinIO,"
    "完成后从 PUT 响应头取 ETag 调 complete_upload。同一文件夹同名文件会 409。"
    "文件 >1GiB 会提示走内网入口(5GiB/900s ≈ 5.7MiB/s 持续上行)。"
)

DESC_GET_PART_URL = (
    "重签某个分片的 PUT URL(同一 multipart 续传;勿重跑 create_upload 另起孤儿 multipart)。"
    "单分片上传通常只需第 1 片;只传自己刚创建的三元组 upload_id/key/bucket。"
)

DESC_ABORT_UPLOAD = (
    "中止 multipart 上传(重试/放弃前显式调用,不留 MinIO 半成品)。"
    "只传自己刚创建的三元组 upload_id/key/bucket;重复中止幂等。"
)

DESC_COMPLETE_UPLOAD = (
    "完成上传并落库(创建资产)。etag 必须取自该分片 PUT 的响应头 ETag(不是本地计算的 MD5),"
    "part_number 默认 1。同一文件夹同名可能 409。超时后不要盲目重试:先 search_assets/list_files "
    "确认资产是否已入库;未入库再重试或 abort_upload。"
)


@dataclass
class AppContext:
    settings: Settings
    handlers: ToolHandlers
    tool_semaphore: asyncio.Semaphore


def _forward_of(ctx: Context) -> ForwardContext:
    request = ctx.request_context.request
    fwd = getattr(getattr(request, "state", None), "mcp_forward", None)
    if not isinstance(fwd, ForwardContext):
        raise ToolError("会话未完成认证(PAT 绑定缺失),请重新 initialize")
    return fwd


def register_tools(mcp: FastMCP, app: AppContext) -> None:
    handlers = app.handlers

    async def run(ctx: Context, fn: Any, *args: Any, **kwargs: Any) -> Any:
        fwd = _forward_of(ctx)
        # 按工具调用粒度(非连接粒度)限制在途调用:SSE 长连接不占名额
        async with app.tool_semaphore:
            return await fn(fwd, *args, **kwargs)

    @mcp.tool(name="whoami", description=DESC_WHOAMI)
    async def whoami(ctx: Context) -> dict[str, Any]:
        return await run(ctx, handlers.whoami)

    @mcp.tool(name="list_projects", description=DESC_LIST_PROJECTS)
    async def list_projects(
        ctx: Context,
        page: Annotated[int, Field(description="页码,从 1 开始", ge=1)] = 1,
        limit: Annotated[
            int,
            Field(
                description=f"每页条数(默认 {PROJECTS_DEFAULT_LIMIT},上限 {PROJECTS_MAX_LIMIT})",
                ge=1,
                le=PROJECTS_MAX_LIMIT,
            ),
        ] = PROJECTS_DEFAULT_LIMIT,
    ) -> dict[str, Any]:
        return await run(ctx, handlers.list_projects, page, limit)

    @mcp.tool(name="list_folders", description=DESC_LIST_FOLDERS)
    async def list_folders(
        ctx: Context,
        project_id: Annotated[str, Field(description="项目 UUID")],
    ) -> dict[str, Any]:
        return await run(ctx, handlers.list_folders, project_id)

    @mcp.tool(name="list_files", description=DESC_LIST_FILES)
    async def list_files(
        ctx: Context,
        folder_id: Annotated[str, Field(description="文件夹 UUID")],
        page: Annotated[int, Field(description="页码,从 1 开始", ge=1)] = 1,
    ) -> dict[str, Any]:
        return await run(ctx, handlers.list_files, folder_id, page)

    @mcp.tool(name="search_assets", description=DESC_SEARCH)
    async def search_assets(
        ctx: Context,
        q: Annotated[str, Field(description="关键词(文件名/标签/备注)", min_length=1, max_length=200)],
        limit: Annotated[
            int,
            Field(description=f"返回条数(默认 {SEARCH_DEFAULT_LIMIT},上限 {SEARCH_MAX_LIMIT})", ge=1, le=SEARCH_MAX_LIMIT),
        ] = SEARCH_DEFAULT_LIMIT,
    ) -> dict[str, Any]:
        return await run(ctx, handlers.search_assets, q, limit)

    @mcp.tool(name="get_thumbnail", description=DESC_GET_THUMBNAIL, structured_output=False)
    async def get_thumbnail(
        ctx: Context,
        asset_id: Annotated[str, Field(description="素材 UUID")],
        size: Annotated[str, Field(description="small=240px(优先) / large=1024px")] = "small",
    ) -> list[Any]:
        if size not in ("small", "large"):
            raise ToolError("size 只支持 small / large")
        return await run(ctx, handlers.get_thumbnail, asset_id, size)

    @mcp.tool(name="get_download_url", description=DESC_GET_DOWNLOAD_URL)
    async def get_download_url(
        ctx: Context,
        asset_id: Annotated[str, Field(description="素材 UUID")],
    ) -> dict[str, Any]:
        return await run(ctx, handlers.get_download_url, asset_id)

    @mcp.tool(name="create_upload", description=DESC_CREATE_UPLOAD)
    async def create_upload(
        ctx: Context,
        folder_id: Annotated[str, Field(description="目标文件夹 UUID")],
        filename: Annotated[str, Field(description="文件名(不含路径)", min_length=1, max_length=512)],
        size_bytes: Annotated[int, Field(description="文件字节数", ge=0)],
        content_type: Annotated[str, Field(description="MIME 类型")] = "application/octet-stream",
    ) -> dict[str, Any]:
        if size_bytes > MAX_UPLOAD_BYTES:
            raise ToolError("单文件上限 5GiB(单分片);超过请拆分或走网页上传")
        return await run(ctx, handlers.create_upload, folder_id, filename, size_bytes, content_type)

    @mcp.tool(name="get_part_url", description=DESC_GET_PART_URL)
    async def get_part_url(
        ctx: Context,
        upload_id: Annotated[str, Field(description="create_upload 返回的 upload_id")],
        key: Annotated[str, Field(description="create_upload 返回的 key")],
        bucket: Annotated[str, Field(description="create_upload 返回的 bucket")],
        part_number: Annotated[int, Field(description="分片号(单分片=1)", ge=1)] = 1,
    ) -> dict[str, Any]:
        return await run(ctx, handlers.get_part_url, upload_id, key, bucket, part_number)

    @mcp.tool(name="abort_upload", description=DESC_ABORT_UPLOAD)
    async def abort_upload(
        ctx: Context,
        upload_id: Annotated[str, Field(description="create_upload 返回的 upload_id")],
        key: Annotated[str, Field(description="create_upload 返回的 key")],
        bucket: Annotated[str, Field(description="create_upload 返回的 bucket")],
    ) -> dict[str, Any]:
        return await run(ctx, handlers.abort_upload, upload_id, key, bucket)

    @mcp.tool(name="complete_upload", description=DESC_COMPLETE_UPLOAD)
    async def complete_upload(
        ctx: Context,
        upload_id: Annotated[str, Field(description="create_upload 返回的 upload_id")],
        folder_id: Annotated[str, Field(description="目标文件夹 UUID(与 create 时一致)")],
        key: Annotated[str, Field(description="create_upload 返回的 key")],
        bucket: Annotated[str, Field(description="create_upload 返回的 bucket")],
        etag: Annotated[str, Field(description="分片 PUT 响应头里的 ETag")],
        part_number: Annotated[int, Field(description="分片号(单分片=1)", ge=1)] = 1,
    ) -> dict[str, Any]:
        return await run(
            ctx, handlers.complete_upload, upload_id, folder_id, key, bucket, etag, part_number
        )
