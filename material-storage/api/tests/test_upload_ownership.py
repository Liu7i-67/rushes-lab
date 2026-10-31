"""上传归属(D9)— 三端点跨用户 403 / complete 的 path-body 一致性 / 自己正常。

需求:`docs/qdev/2026-10-30-mcp-service.md` D9(归属绑定必做)+ 测试功能点
「upload 归属」。契约钉死:

- 写键在 **create_upload 端点内**(gate 在端点前进入,拿不到 upload_id);
- owner 校验三处(sign_part / abort / complete)**全在 mcp_gate**;
- ``complete`` 只保留 ``payload.upload_id == path upload_id`` 断言(不一致 400)
  —— 校验键必须是 path 参数,否则「path=受害者、body=自己」可绕过;
- **键缺失一律 403**;Redis 异常 → 503 redis_down;session 路径不校验(现状)。

运行:dev 容器(需 **ms-redis**);DB/MinIO 用 fake 隔离(presign 替身)。
"""
from __future__ import annotations

import uuid
from types import SimpleNamespace
from typing import Any

import pytest
import redis.asyncio as redis_asyncio
from fastapi import Request
from httpx import ASGITransport, AsyncClient

from app.deps import CurrentUser, get_current_user
from app.main import create_app
from app.services.mcp_gate import PAT_UPLOAD_FORBIDDEN_DETAIL, upload_owner_key
from app.services.mcp_settings import McpSettings
from app.settings import get_settings

PAT_USER_ID = uuid.uuid4()
OTHER_USER_ID = uuid.uuid4()


@pytest.fixture(scope="session")
async def redis_client():
    settings = get_settings()
    client = redis_asyncio.from_url(str(settings.redis_url), decode_responses=True)
    try:
        await client.ping()
    except Exception:
        pytest.skip("Redis 不可达:本文件需 ms-redis(dev 容器内跑)")
    yield client
    await client.aclose()


class FakePresign:
    """presign 替身(端点里只剩 URL 签发与 abort;零 MinIO 依赖)。"""

    def __init__(self) -> None:
        self.aborted: list[tuple[str, str, str]] = []

    def sign_part_url(self, *args: Any, **kwargs: Any) -> str:
        return "http://minio.test/bucket/key?part=1&sig=stub"

    def abort_multipart_upload(self, bucket: str, key: str, upload_id: str) -> None:
        self.aborted.append((bucket, key, upload_id))


class _FailingRedis:
    async def get(self, key: str) -> str | None:
        raise ConnectionError("redis down(get)")

    async def set(self, *args: Any, **kwargs: Any) -> Any:
        raise ConnectionError("redis down(set)")

    async def delete(self, *args: Any, **kwargs: Any) -> Any:
        raise ConnectionError("redis down(delete)")


@pytest.fixture
async def client(redis_client: Any):
    app = create_app()
    app.state.redis = redis_client
    app.state.mcp_settings = SimpleNamespace()
    app.state.presign = FakePresign()

    async def _pat_user(request: Request) -> CurrentUser:
        request.state.auth_method = "pat"
        request.state.auth_token_id = uuid.uuid4()
        request.state.mcp_flag = McpSettings(True, 8, 4, 120, 600)
        return CurrentUser(id=PAT_USER_ID, name="pat-user")

    app.dependency_overrides[get_current_user] = _pat_user
    transport = ASGITransport(app=app, raise_app_exceptions=False)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac
    app.dependency_overrides.clear()


UPLOAD_ID = "up-owner-test"


@pytest.fixture(autouse=True)
async def _cleanup_owner_key(redis_client: Any):
    yield
    await redis_client.delete(upload_owner_key(UPLOAD_ID))


async def _set_owner(redis_client: Any, user_id: uuid.UUID) -> None:
    await redis_client.set(upload_owner_key(UPLOAD_ID), str(user_id), ex=86400)


def _detail(resp: Any) -> str:
    try:
        return str(resp.json().get("detail") or "")
    except Exception:
        return ""


# ─── 1) 三端点:他人 / 不存在 → 403 ────────────────────────────────────────
@pytest.mark.parametrize(
    ("method", "url", "kwargs"),
    [
        ("GET", "/api/v1/assets/uploads/{uid}/parts/1?bucket=b&key=k", {}),
        ("DELETE", "/api/v1/assets/uploads/{uid}?bucket=b&key=k", {}),
        (
            "POST", "/api/v1/assets/uploads/{uid}/complete",
            {"json": {"upload_id": "{uid}", "folder_id": str(uuid.uuid4()),
                      "bucket": "b", "key": "k", "parts": [{"PartNumber": 1, "ETag": "e"}]}},
        ),
    ],
)
async def test_other_users_upload_is_403(
    client: AsyncClient, redis_client: Any, method: str, url: str, kwargs: dict[str, Any],
) -> None:
    await _set_owner(redis_client, OTHER_USER_ID)
    body = kwargs.get("json")
    if isinstance(body, dict):
        body = {**body, "upload_id": UPLOAD_ID}
        kwargs = {"json": body}
    resp = await client.request(method, url.format(uid=UPLOAD_ID), **kwargs)
    assert resp.status_code == 403
    assert _detail(resp) == PAT_UPLOAD_FORBIDDEN_DETAIL


@pytest.mark.parametrize(
    ("method", "url"),
    [
        ("GET", "/api/v1/assets/uploads/{uid}/parts/1?bucket=b&key=k"),
        ("DELETE", "/api/v1/assets/uploads/{uid}?bucket=b&key=k"),
    ],
)
async def test_missing_owner_key_is_403(
    client: AsyncClient, redis_client: Any, method: str, url: str,
) -> None:
    """键缺失一律 403(不能把「无归属」当成「session 路径放行」)。"""
    await redis_client.delete(upload_owner_key(UPLOAD_ID))
    resp = await client.request(method, url.format(uid=UPLOAD_ID))
    assert resp.status_code == 403
    assert _detail(resp) == PAT_UPLOAD_FORBIDDEN_DETAIL


# ─── 2) 自己的 → 正常 ──────────────────────────────────────────────────────
async def test_own_upload_sign_and_abort_succeed(
    client: AsyncClient, redis_client: Any,
) -> None:
    await _set_owner(redis_client, PAT_USER_ID)
    resp = await client.get(f"/api/v1/assets/uploads/{UPLOAD_ID}/parts/1?bucket=b&key=k")
    assert resp.status_code == 200
    assert resp.json()["url"].startswith("http://minio.test/")

    resp = await client.delete(f"/api/v1/assets/uploads/{UPLOAD_ID}?bucket=b&key=k")
    assert resp.status_code == 204
    # 成功后释放归属键(complete/abort 都 DEL)
    assert await redis_client.get(upload_owner_key(UPLOAD_ID)) is None


# ─── 3) complete 的 path/body 一致性(校验键 = path)────────────────────────
async def test_complete_path_body_mismatch_is_400(
    client: AsyncClient, redis_client: Any,
) -> None:
    await _set_owner(redis_client, PAT_USER_ID)
    resp = await client.post(
        f"/api/v1/assets/uploads/{UPLOAD_ID}/complete",
        json={
            "upload_id": "another-upload",  # body 与 path 不一致
            "folder_id": str(uuid.uuid4()),
            "bucket": "b",
            "key": "k",
            "parts": [{"PartNumber": 1, "ETag": "e"}],
        },
    )
    assert resp.status_code == 400
    assert "upload_id" in _detail(resp)


# ─── 4) Redis 异常 → 503 fail-closed ───────────────────────────────────────
async def test_owner_lookup_redis_failure_is_503() -> None:
    app = create_app()
    app.state.redis = _FailingRedis()
    app.state.mcp_settings = SimpleNamespace()
    app.state.presign = FakePresign()

    async def _pat_user(request: Request) -> CurrentUser:
        request.state.auth_method = "pat"
        request.state.auth_token_id = uuid.uuid4()
        request.state.mcp_flag = McpSettings(True, 8, 4, 120, 600)
        return CurrentUser(id=PAT_USER_ID, name="pat-user")

    app.dependency_overrides[get_current_user] = _pat_user
    transport = ASGITransport(app=app, raise_app_exceptions=False)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        resp = await ac.get(f"/api/v1/assets/uploads/{UPLOAD_ID}/parts/1?bucket=b&key=k")
    app.dependency_overrides.clear()
    assert resp.status_code == 503
    assert _detail(resp) == "认证服务暂时不可用,请稍后重试"


# ─── 5) session 路径不校验归属(现状维持)──────────────────────────────────
async def test_session_request_skips_owner_check(redis_client: Any) -> None:
    app = create_app()
    app.state.redis = redis_client
    app.state.mcp_settings = SimpleNamespace()
    app.state.presign = FakePresign()

    async def _session_user(request: Request) -> CurrentUser:
        request.state.auth_method = "session"
        return CurrentUser(id=PAT_USER_ID, name="web-user")

    app.dependency_overrides[get_current_user] = _session_user
    transport = ASGITransport(app=app, raise_app_exceptions=False)
    await redis_client.delete(upload_owner_key(UPLOAD_ID))
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        resp = await ac.get(f"/api/v1/assets/uploads/{UPLOAD_ID}/parts/1?bucket=b&key=k")
    app.dependency_overrides.clear()
    assert resp.status_code == 200
