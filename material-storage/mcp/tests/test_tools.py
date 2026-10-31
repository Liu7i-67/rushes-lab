"""11 个工具的请求映射 / 响应白名单 / 上传约束 / 缩略图双客户端。"""

from __future__ import annotations

import httpx
import pytest
from conftest import FORWARD, MockApi, make_settings
from mcp.server.fastmcp.exceptions import ToolError
from mcp.server.fastmcp.utilities.types import Image
from mcp.types import TextContent

from ms_mcp.clients import ApiClient, BytesClient, ForwardContext
from ms_mcp.toolimpl import MAX_UPLOAD_BYTES, ToolHandlers

PROJECT = {
    "id": "p1", "code": "alpha", "name": "Alpha", "description": "d",
    "organization_id": "org-1", "minio_bucket": "ms-dev", "visibility": "public",
    "is_archived": False, "created_at": "2026-01-01T00:00:00Z",
    "admins": [{"user_id": "u1", "name": "Evan"}],
    "my_roles": ["admin"], "is_pinned": False,
}

ASSET = {
    "id": "a1", "folder_id": "f1", "filename": "x.png", "minio_bucket": "ms-dev",
    "minio_key": "p/f/x.png", "etag": "e", "minio_version_id": "v", "size_bytes": 10,
    "content_type": "image/png", "created_at": "2026-01-01T00:00:00Z",
    "deleted_at": None, "tags": {"thumbnail_key": "p/f/thumb-x.png"},
    "user_labels": ["猫"], "notes": "备注",
}

FOLDER_ROOT = {
    "id": "f1", "project_id": "p1", "parent_folder_id": None, "name": "root",
    "minio_prefix": "p/f1", "is_sensitive": False, "created_at": "2026-01-01T00:00:00Z",
    "subtree_file_count": 3, "direct_file_count": 1,
    "my_can_view": True, "my_can_download": True, "my_can_upload": True, "my_can_admin": False,
}
FOLDER_CHILD = {
    **FOLDER_ROOT, "id": "f2", "parent_folder_id": "f1", "name": "child",
    "minio_prefix": "p/f1/f2", "subtree_file_count": 2, "direct_file_count": 2,
}


def test_build_headers_transparent_and_stripped() -> None:
    headers = ApiClient.build_headers(FORWARD)
    assert headers["Authorization"] == f"Bearer {FORWARD.pat}"
    assert headers["Host"] == "ms.local:8090"
    assert headers["X-Forwarded-Proto"] == "http"
    assert headers["X-Forwarded-For"] == "203.0.113.9"
    assert headers["User-Agent"].startswith("msmcp/")
    lowered = {k.lower() for k in headers}
    assert "cookie" not in lowered
    assert "x-user-id" not in lowered


def test_build_headers_drops_crlf_xff() -> None:
    headers = ApiClient.build_headers(
        ForwardContext(pat="p", host="ms.local", xfp="http", xff="1.2.3.4\r\nX-Evil: 1")
    )
    assert "X-Forwarded-For" not in headers


async def test_whoami_maps_and_whitelists(bundle) -> None:
    bundle.api_mock.add(
        "GET", "/api/v1/auth/me",
        json={
            "id": "u1", "name": "Evan", "email": "e@example.com",
            "open_id": "oid", "union_id": "uid", "organization_id": "org",
            "is_active": True, "is_system_admin": False, "is_project_creator": True,
            "is_project_deleter": False, "is_folder_template_manager": False,
            "is_artist_account_creator": False, "is_file_deleter": True,
        },
    )
    out = await bundle.handlers.whoami(FORWARD)
    call = bundle.api_mock.last
    assert (call.method, call.path) == ("GET", "/api/v1/auth/me")
    assert call.headers["authorization"] == f"Bearer {FORWARD.pat}"
    assert call.headers["host"] == "ms.local:8090"
    assert out["id"] == "u1" and out["name"] == "Evan" and out["is_system_admin"] is False
    assert "email" not in out and "open_id" not in out and "union_id" not in out
    assert "organization_id" not in out


async def test_list_projects_pagination_and_whitelist(bundle) -> None:
    bundle.api_mock.add("GET", "/api/v1/projects", json=[PROJECT])
    out = await bundle.handlers.list_projects(FORWARD, page=2, limit=10)
    call = bundle.api_mock.last
    assert call.path == "/api/v1/projects"
    assert call.params == {"limit": "10", "offset": "10"}
    assert out["page"] == 2 and out["limit"] == 10
    assert out["note"]
    item = out["items"][0]
    assert item["id"] == "p1" and item["admins"] == [{"user_id": "u1", "name": "Evan"}]
    assert "minio_bucket" not in item and "organization_id" not in item


async def test_list_projects_clamps_limit_to_100(bundle) -> None:
    bundle.api_mock.add("GET", "/api/v1/projects", json=[])
    await bundle.handlers.list_projects(FORWARD, page=1, limit=999)
    assert bundle.api_mock.last.params["limit"] == "100"


async def test_list_folders_builds_tree_and_strips_internal(bundle) -> None:
    orphan = {**FOLDER_CHILD, "id": "f3", "parent_folder_id": "missing", "name": "orphan"}
    bundle.api_mock.add("GET", "/api/v1/folders", json=[FOLDER_ROOT, FOLDER_CHILD, orphan])
    out = await bundle.handlers.list_folders(FORWARD, "p1")
    call = bundle.api_mock.last
    assert call.path == "/api/v1/folders"
    assert call.params == {"project_id": "p1"}
    roots = out["roots"]
    assert [r["id"] for r in roots] == ["f1", "f3"]
    root = roots[0]
    assert [c["id"] for c in root["children"]] == ["f2"]
    assert root["subtree_file_count"] == 3 and root["direct_file_count"] == 1
    assert "minio_prefix" not in root and "is_sensitive" not in root


async def test_list_files_pagination(bundle) -> None:
    bundle.api_mock.add(
        "GET", "/api/v1/assets", json={"items": [ASSET], "total": 250, "locate_index": None}
    )
    out = await bundle.handlers.list_files(FORWARD, "f1", page=2)
    call = bundle.api_mock.last
    assert call.params == {"folder_id": "f1", "limit": "100", "offset": "100"}
    assert out["page"] == 2 and out["total"] == 250 and out["has_more"] is True
    item = out["items"][0]
    assert item["filename"] == "x.png" and item["user_labels"] == ["猫"]
    assert "minio_key" not in item and "minio_bucket" not in item and "tags" not in item


async def test_search_assets_trim_and_cap(bundle) -> None:
    result = {**ASSET, "folder_name": "f", "project_id": "p1", "project_name": "Alpha"}
    bundle.api_mock.add("GET", "/api/v1/assets/search", json=[result])
    out = await bundle.handlers.search_assets(FORWARD, "  猫  ", 999)
    call = bundle.api_mock.last
    assert call.path == "/api/v1/assets/search"
    assert call.params == {"q": "猫", "limit": "50"}
    assert out["q"] == "猫" and out["count"] == 1
    assert out["items"][0]["folder_name"] == "f"
    assert out["items"][0]["project_name"] == "Alpha"
    assert "minio_key" not in out["items"][0]
    assert "get_thumbnail" in out["note"]


async def test_search_assets_rejects_blank_q(bundle) -> None:
    with pytest.raises(ToolError):
        await bundle.handlers.search_assets(FORWARD, "   ", 20)
    assert bundle.api_mock.calls == []


async def test_get_thumbnail_uses_internal_host_and_bare_bytes_client(bundle) -> None:
    signed = "http://192.168.110.221/ms-thumbs/p/f/thumb-x.png?X-Amz-Signature=s"
    bundle.api_mock.add(
        "GET", "/api/v1/assets/a1/thumbnail-url",
        json={"url": signed, "expires_in": 1800, "variant": "small"},
    )
    out = await bundle.handlers.get_thumbnail(FORWARD, "a1", "small")

    call = bundle.api_mock.last
    assert call.path == "/api/v1/assets/a1/thumbnail-url"
    assert call.params == {"size": "small"}
    # Host 固定取 MS_MCP_INTERNAL_BASE_URL,不采信客户端入口 Host
    assert call.headers["host"] == "192.168.110.221"
    assert call.headers["x-forwarded-proto"] == "http"
    assert call.headers["authorization"] == f"Bearer {FORWARD.pat}"
    assert call.headers["x-forwarded-for"] == FORWARD.xff

    assert len(bundle.bytes_mock.requests) == 1
    bytes_req = bundle.bytes_mock.requests[0]
    assert str(bytes_req.url) == signed
    assert "authorization" not in bytes_req.headers
    assert "cookie" not in bytes_req.headers
    assert "x-user-id" not in bytes_req.headers

    assert isinstance(out[0], Image)
    assert out[0]._mime_type == "image/png"
    assert isinstance(out[1], TextContent)
    assert "variant=small" in out[1].text


async def test_get_thumbnail_small_fallback_mentions_large(bundle) -> None:
    bundle.api_mock.add(
        "GET", "/api/v1/assets/a1/thumbnail-url",
        json={"url": "http://h/ms-thumbs/x", "expires_in": 1800, "variant": "large"},
    )
    out = await bundle.handlers.get_thumbnail(FORWARD, "a1", "small")
    assert "回落" in out[1].text


async def test_get_thumbnail_missing_thumbnail_message(bundle) -> None:
    bundle.api_mock.add(
        "GET", "/api/v1/assets/a1/thumbnail-url",
        status=404, json={"detail": "no thumbnail yet(可能还在生成 / 非图片)"},
    )
    with pytest.raises(ToolError) as exc:
        await bundle.handlers.get_thumbnail(FORWARD, "a1", "small")
    assert "尚未生成" in str(exc.value)
    assert bundle.bytes_mock.requests == []


async def test_get_thumbnail_bytes_failure(bundle) -> None:
    bundle.api_mock.add(
        "GET", "/api/v1/assets/a1/thumbnail-url",
        json={"url": "http://h/ms-thumbs/x", "expires_in": 1800, "variant": "small"},
    )
    bundle.bytes_mock.status = 500
    with pytest.raises(ToolError):
        await bundle.handlers.get_thumbnail(FORWARD, "a1", "small")

    bundle.bytes_mock.status = 200
    bundle.bytes_mock.content_type = "text/html"
    with pytest.raises(ToolError) as exc:
        await bundle.handlers.get_thumbnail(FORWARD, "a1", "small")
    assert "不是图片" in str(exc.value)


async def test_get_thumbnail_bytes_timeout() -> None:
    def raising(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("slow", request=request)

    api_mock = _one_route(
        "GET", "/api/v1/assets/a1/thumbnail-url",
        {"url": "http://h/ms-thumbs/x", "expires_in": 1800, "variant": "small"},
    )
    api = ApiClient("http://ms-api:8000", transport=httpx.MockTransport(api_mock))
    bytes_client = BytesClient(transport=httpx.MockTransport(raising))
    handlers = ToolHandlers(_settings(), api, bytes_client)
    with pytest.raises(ToolError) as exc:
        await handlers.get_thumbnail(FORWARD, "a1", "small")
    assert "15 秒" in str(exc.value)
    await api.aclose()
    await bytes_client.aclose()


async def test_get_download_url(bundle) -> None:
    bundle.api_mock.add(
        "POST", "/api/v1/assets/a1/download-link",
        json={"url": "http://entry/ms-dev/x?sign", "expires_in": 900, "is_sensitive": False},
    )
    out = await bundle.handlers.get_download_url(FORWARD, "a1")
    call = bundle.api_mock.last
    assert (call.method, call.path) == ("POST", "/api/v1/assets/a1/download-link")
    assert out["url"] == "http://entry/ms-dev/x?sign"
    assert out["expires_in"] == 900
    assert any("勿反复续签" in note for note in out["notes"])
    assert any("MCP 客户端" in note for note in out["notes"])


async def test_create_upload_rejects_over_5gib(bundle) -> None:
    with pytest.raises(ToolError) as exc:
        await bundle.handlers.create_upload(FORWARD, "f1", "big.bin", MAX_UPLOAD_BYTES + 1, "application/octet-stream")
    assert "5GiB" in str(exc.value)
    assert bundle.api_mock.calls == []


async def test_create_upload_mapping_and_part_url(bundle) -> None:
    bundle.api_mock.add(
        "POST", "/api/v1/assets/uploads",
        json={"upload_id": "up-1", "key": "p/f1/a.bin", "bucket": "ms-dev"},
    )
    bundle.api_mock.add(
        "GET", "/api/v1/assets/uploads/up-1/parts/1",
        json={"url": "http://entry/ms-dev/p/f1/a.bin?part=1", "expires_in": 900},
    )
    out = await bundle.handlers.create_upload(FORWARD, "f1", "a.bin", 10, "application/octet-stream")

    create = bundle.api_mock.find("POST", "/api/v1/assets/uploads")
    assert create.body == {
        "folder_id": "f1", "filename": "a.bin",
        "content_type": "application/octet-stream", "size_bytes": 10,
    }
    part = bundle.api_mock.find("GET", "/api/v1/assets/uploads/up-1/parts/1")
    assert part.params == {"bucket": "ms-dev", "key": "p/f1/a.bin"}
    assert out["upload_id"] == "up-1" and out["key"] == "p/f1/a.bin" and out["bucket"] == "ms-dev"
    assert out["first_part_url"]
    assert out["expires_in"] == 900
    assert out["warnings"] == []
    assert "ETag" in out["note"]


async def test_create_upload_large_file_hint(bundle) -> None:
    bundle.api_mock.add(
        "POST", "/api/v1/assets/uploads",
        json={"upload_id": "up-2", "key": "p/f1/big.bin", "bucket": "ms-dev"},
    )
    bundle.api_mock.add(
        "GET", "/api/v1/assets/uploads/up-2/parts/1",
        json={"url": "http://entry/ms-dev/p/f1/big.bin", "expires_in": 900},
    )
    out = await bundle.handlers.create_upload(
        FORWARD, "f1", "big.bin", 2 * 1024**3, "application/octet-stream"
    )
    assert out["warnings"] and "内网入口" in out["warnings"][0]


async def test_create_upload_duplicate_name_passthrough(bundle) -> None:
    bundle.api_mock.add(
        "POST", "/api/v1/assets/uploads",
        status=409, json={"detail": "该文件夹已存在同名文件,请重命名后重新上传"},
    )
    with pytest.raises(ToolError) as exc:
        await bundle.handlers.create_upload(FORWARD, "f1", "a.bin", 1, "application/octet-stream")
    assert "同名" in str(exc.value)


async def test_create_upload_aborts_when_part_signing_fails(bundle) -> None:
    bundle.api_mock.add(
        "POST", "/api/v1/assets/uploads",
        json={"upload_id": "up-3", "key": "p/f1/c.bin", "bucket": "ms-dev"},
    )
    bundle.api_mock.add(
        "GET", "/api/v1/assets/uploads/up-3/parts/1", status=500, json={"detail": "boom"}
    )
    with pytest.raises(ToolError):
        await bundle.handlers.create_upload(FORWARD, "f1", "c.bin", 1, "application/octet-stream")
    abort = bundle.api_mock.find("DELETE", "/api/v1/assets/uploads/up-3")
    assert abort.params == {"bucket": "ms-dev", "key": "p/f1/c.bin"}


async def test_get_part_url_mapping(bundle) -> None:
    bundle.api_mock.add(
        "GET", "/api/v1/assets/uploads/up-1/parts/2",
        json={"url": "http://entry/u?part=2", "expires_in": 900},
    )
    out = await bundle.handlers.get_part_url(FORWARD, "up-1", "p/f1/a.bin", "ms-dev", 2)
    call = bundle.api_mock.last
    assert call.params == {"bucket": "ms-dev", "key": "p/f1/a.bin"}
    assert out["part_number"] == 2 and out["url"] == "http://entry/u?part=2"


async def test_abort_upload_mapping(bundle) -> None:
    bundle.api_mock.add("DELETE", "/api/v1/assets/uploads/up-1", status=204)
    out = await bundle.handlers.abort_upload(FORWARD, "up-1", "p/f1/a.bin", "ms-dev")
    call = bundle.api_mock.last
    assert (call.method, call.path) == ("DELETE", "/api/v1/assets/uploads/up-1")
    assert call.params == {"bucket": "ms-dev", "key": "p/f1/a.bin"}
    assert out["aborted"] is True


async def test_complete_upload_body_is_parts_array(bundle) -> None:
    bundle.api_mock.add("POST", "/api/v1/assets/uploads/up-1/complete", json=ASSET)
    out = await bundle.handlers.complete_upload(
        FORWARD, "up-1", "f1", "p/f1/x.png", "ms-dev", '"abc123"', 1
    )
    call = bundle.api_mock.last
    assert (call.method, call.path) == ("POST", "/api/v1/assets/uploads/up-1/complete")
    assert call.body == {
        "upload_id": "up-1",
        "folder_id": "f1",
        "bucket": "ms-dev",
        "key": "p/f1/x.png",
        "parts": [{"PartNumber": 1, "ETag": '"abc123"'}],
    }
    assert out["filename"] == "x.png"
    assert "minio_key" not in out and "minio_bucket" not in out


async def test_complete_upload_refuses_existing_same_name(bundle) -> None:
    bundle.api_mock.add(
        "GET", "/api/v1/assets/search",
        json=[{**ASSET, "folder_id": "f1", "filename": "x.png"}],
    )
    with pytest.raises(ToolError) as exc:
        await bundle.handlers.complete_upload(
            FORWARD, "up-1", "f1", "p/f1/x.png", "ms-dev", "e", 1
        )
    assert "同名" in str(exc.value)
    assert [c for c in bundle.api_mock.calls if c.method == "POST"] == []


async def test_complete_upload_allows_same_name_in_other_folder(bundle) -> None:
    bundle.api_mock.add(
        "GET", "/api/v1/assets/search",
        json=[{**ASSET, "folder_id": "f2", "filename": "x.png"}],
    )
    bundle.api_mock.add("POST", "/api/v1/assets/uploads/up-1/complete", json=ASSET)
    out = await bundle.handlers.complete_upload(
        FORWARD, "up-1", "f1", "p/f1/x.png", "ms-dev", "e", 1
    )
    assert out["filename"] == "x.png"
    bundle.api_mock.find("POST", "/api/v1/assets/uploads/up-1/complete")


async def test_complete_upload_recheck_failure_is_best_effort(bundle) -> None:
    bundle.api_mock.add("GET", "/api/v1/assets/search", status=500, json={"detail": "boom"})
    bundle.api_mock.add("POST", "/api/v1/assets/uploads/up-1/complete", json=ASSET)
    out = await bundle.handlers.complete_upload(
        FORWARD, "up-1", "f1", "p/f1/x.png", "ms-dev", "e", 1
    )
    assert out["filename"] == "x.png"


async def test_complete_upload_timeout_hint() -> None:
    def raising(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("slow", request=request)

    api = ApiClient("http://ms-api:8000", transport=httpx.MockTransport(raising))
    bytes_client = BytesClient(transport=httpx.MockTransport(lambda r: httpx.Response(200)))
    handlers = ToolHandlers(_settings(), api, bytes_client)
    with pytest.raises(ToolError) as exc:
        await handlers.complete_upload(FORWARD, "up-1", "f1", "k", "b", "e", 1)
    assert "search_assets" in str(exc.value)
    assert "可能已经入库" in str(exc.value)
    await api.aclose()
    await bytes_client.aclose()


async def test_api_error_detail_surfaced(bundle) -> None:
    bundle.api_mock.add(
        "GET", "/api/v1/projects",
        status=403, json={"detail": "MCP 通道当前已由管理员关闭"},
    )
    with pytest.raises(ToolError) as exc:
        await bundle.handlers.list_projects(FORWARD, 1, 10)
    assert "MCP 通道当前已由管理员关闭" in str(exc.value)


async def test_api_429_mentions_retry(bundle) -> None:
    bundle.api_mock.add(
        "GET", "/api/v1/projects", status=429,
        json={"detail": "rate limited"}, headers={"retry-after": "1"},
    )
    with pytest.raises(ToolError) as exc:
        await bundle.handlers.list_projects(FORWARD, 1, 10)
    assert "限流" in str(exc.value)


def _settings():
    return make_settings()


def _one_route(method: str, path: str, payload: dict):
    return MockApi().add(method, path, json=payload).handler
