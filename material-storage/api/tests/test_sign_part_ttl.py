"""分片签名 TTL 独立化(docs/qdev/2026-11-27-ios-bg-upload.md §3 F8 / §4 包 F / §6)。

策略分两层(离线单测,不连 DB / OpenFGA / MinIO;基建与直调范式参照
test_dynamic_presign_host.py):

  - settings 层:默认值断言 —— presigned_part_ttl_seconds=7200(本次新增,
    仅分片 PUT 签名用),并守护 presigned_normal_ttl_seconds 仍为 900
    (下载/缩略图共享 TTL 不随本次放宽,决策 D5);
  - router 层:直调 sign_part endpoint(stub 依赖,绕过 Depends,同文件
    share resolve 直调同款),断言返回 expires_in=7200 且该值原样透传
    presign.sign_part_url 的 expires_seconds —— 端点内两处必须同源同值。

普通下载侧(assets.py 下载 link,assets.py:1612)不得随本次改动:其 900
契约由上方守护断言 + test_dynamic_presign_host 容器级用例
(test_c1 断言 download-link expires_in == 900)共同覆盖,本文件不重复
端到端 —— sign_part 的真链路连通(鉴权/动态 host)已有容器级先例,
本文件只盯 TTL 数值契约,离线可跑。
"""
from __future__ import annotations

import uuid
from types import SimpleNamespace
from typing import Any

from starlette.requests import Request

from app.routers.assets import sign_part
from app.settings import Settings


# ─── 离线 helpers ─────────────────────────────────────────────────────────────
def mk_settings(**overrides: object) -> Settings:
    """最小必填字段凑 Settings(与 test_dynamic_presign_host.mk_settings 同款)。"""
    base: dict[str, object] = {
        "env": "test",
        "db_url": "postgresql+asyncpg://u:p@localhost/db",
        "redis_url": "redis://localhost:6379/0",
        "minio_endpoint_internal": "http://minio:9000",
        "minio_endpoint_public": "http://localhost:9000",
        "minio_access_key": "k",
        "minio_secret_key": "s",
        "openfga_api_url": "http://openfga:8080",
        "openfga_store_id": "01TEST",
        "web_app_base_url": "http://localhost/ms-static/web/",
        "session_jwt_secret": "test-secret",
    }
    base.update(overrides)
    return Settings(**base)  # type: ignore[arg-type]


def mk_request(host: str | None = None) -> Request:
    """直构 starlette Request(最小 scope;TTL 契约与 host 正交,给个合法 host)。"""
    raw: list[tuple[bytes, bytes]] = []
    if host is not None:
        raw.append((b"host", host.encode("ascii")))
    scope: dict[str, Any] = {
        "type": "http",
        "asgi": {"version": "3.0", "spec_version": "2.3"},
        "http_version": "1.1",
        "method": "GET",
        "scheme": "http",
        "path": "/api/v1/assets/uploads/upload-1/parts/2",
        "raw_path": b"/api/v1/assets/uploads/upload-1/parts/2",
        "query_string": b"",
        "root_path": "",
        "server": ("testserver", 80),
        "client": ("127.0.0.1", 54321),
        "headers": raw,
    }
    return Request(scope)


class RecordingPresign:
    """sign_part_url 替身:按契约记录实参(重点 expires_seconds),不触网。"""

    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []

    def sign_part_url(
        self,
        bucket: str,
        key: str,
        upload_id: str,
        part_number: int,
        expires_seconds: int,
        request_base: str | None = None,
    ) -> str:
        self.calls.append({
            "bucket": bucket,
            "key": key,
            "upload_id": upload_id,
            "part_number": part_number,
            "expires_seconds": expires_seconds,
            "request_base": request_base,
        })
        return f"https://minio.example/{bucket}/{key}?X-Amz-Signature=fake"


# ─── settings 默认值(F8)──────────────────────────────────────────────────────
def test_settings_default_part_ttl_is_7200() -> None:
    """F8:presigned_part_ttl_seconds 默认 7200(env PRESIGNED_PART_TTL_SECONDS
    可覆盖;与相邻 presigned_* 字段同走 BaseSettings 大写蛇形映射,无特殊配置)。"""
    assert mk_settings().presigned_part_ttl_seconds == 7200


def test_settings_default_normal_ttl_still_900() -> None:
    """F8 守护(D5):普通下载/缩略图共享 TTL 不随本次放宽,默认仍 900。"""
    assert mk_settings().presigned_normal_ttl_seconds == 900


# ─── sign_part 端点(F8 / §6)──────────────────────────────────────────────────
async def test_sign_part_returns_and_passes_part_ttl_7200(
    monkeypatch: Any,
) -> None:
    """F8 / §6:sign_part 返回 expires_in=7200,且同一 7200 原样进
    sign_part_url 的 expires_seconds(端点内两处同源;url 透传不变)。"""
    settings = mk_settings()
    monkeypatch.setattr("app.routers.assets.get_settings", lambda: settings)
    presign = RecordingPresign()

    out = await sign_part(
        upload_id="upload-1",
        part_number=2,
        request=mk_request(host="bucket.taoxiplan.com"),
        bucket="ms-proj",
        key="folder-a/a.mp4",
        presign=presign,
        user=SimpleNamespace(id=uuid.uuid4()),  # 端点体不读 user,仅占位满足签名
    )

    assert out.expires_in == 7200
    assert out.url == "https://minio.example/ms-proj/folder-a/a.mp4?X-Amz-Signature=fake"
    assert len(presign.calls) == 1
    call = presign.calls[0]
    assert call["expires_seconds"] == 7200
    assert call["bucket"] == "ms-proj"
    assert call["key"] == "folder-a/a.mp4"
    assert call["upload_id"] == "upload-1"
    assert call["part_number"] == 2
