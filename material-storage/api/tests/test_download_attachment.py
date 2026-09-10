"""移动端下载 attachment 语义(方案 §3.5)— 单元测试。

策略:本机无 docker/容器运行时,不连真 DB / OpenFGA / MinIO:
  - presign 层:PresignService 可离线构造(boto3 client 创建无网络 IO),
    monkeypatch 把 _s3_signer 换成记录替身,断言 generate_presigned_url
    实际收到的 Params;
  - router 层:直接调 endpoint 函数(stub 依赖 + monkeypatch get_settings),
    断言 as_attachment 的透传与默认兼容行为。
容器内全链路(真签 URL + MinIO 响应头)由既有 e2e 覆盖,不在本文件范围。
"""
from __future__ import annotations

import uuid
from types import SimpleNamespace
from typing import Any

import pytest

from app.routers.assets import (
    DownloadLinkIn,
    attachment_content_disposition,
    get_download_link,
    rfc5987_encode,
)
from app.services.presign import PresignService
from app.settings import Settings


# ─── helpers ──────────────────────────────────────────────────────────────────
def mk_settings(**overrides: object) -> Settings:
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


class RecordingSigner:
    """generate_presigned_url 替身:只记录入参,不触网。"""

    def __init__(self) -> None:
        self.operation: str | None = None
        self.params: dict[str, Any] = {}

    def generate_presigned_url(
        self,
        operation_name: str,
        Params: dict[str, Any] | None = None,
        ExpiresIn: int | None = None,
    ) -> str:
        self.operation = operation_name
        self.params = dict(Params or {})
        return "https://minio.example/bucket/key?X-Amz-Signature=fake"


class StubDB:
    """最小 async db 替身:get 恒返预置 asset。"""

    def __init__(self, asset: object) -> None:
        self._asset = asset

    async def get(self, model: object, pk: object) -> object | None:
        return self._asset


class StubPermissions:
    def __init__(self) -> None:
        self.checks: list[dict[str, str]] = []

    async def check(self, **kw: str) -> bool:
        self.checks.append(kw)
        return False  # is_system_admin=True 直通,不应走到这里


class StubAudit:
    def __init__(self) -> None:
        self.events: list[dict[str, Any]] = []

    async def write(self, **kw: Any) -> None:
        self.events.append(kw)

    async def signed_url_issued(self, **kw: Any) -> None:
        self.events.append({"event_type": "signed_url_issued", **kw})


class StubPresign:
    """router 层替身:记录 sign_get_url 收到的实参。"""

    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []

    def sign_get_url(
        self,
        bucket: str,
        key: str,
        expires_seconds: int,
        response_content_disposition: str | None = None,
    ) -> str:
        self.calls.append({
            "bucket": bucket,
            "key": key,
            "expires_seconds": expires_seconds,
            "response_content_disposition": response_content_disposition,
        })
        return f"https://minio.example/{bucket}/{key}?X-Amz-Signature=fake"


def mk_asset(filename: str) -> SimpleNamespace:
    return SimpleNamespace(
        id=uuid.uuid4(),
        deleted_at=None,
        filename=filename,
        minio_bucket="ms-proj",
        minio_key=f"folder-a/{filename}",
    )


async def call_download_link(
    monkeypatch: pytest.MonkeyPatch,
    asset: SimpleNamespace,
    presign: StubPresign,
    data: DownloadLinkIn | None,
) -> Any:
    """直调 endpoint(绕过 Depends);系统 admin 直通跳过 OpenFGA。"""
    monkeypatch.setattr("app.routers.assets.get_settings", lambda: mk_settings())
    return await get_download_link(
        asset.id,
        data,
        db=StubDB(asset),
        permissions=StubPermissions(),
        presign=presign,
        audit=StubAudit(),
        user=SimpleNamespace(id=uuid.uuid4(), subject="user:u1"),
        is_system_admin=True,
        ctx={"request_ip": "127.0.0.1", "user_agent": "pytest"},
    )


# ─── ① presign 层:attachment 语义进 Params ───────────────────────────────────
def test_sign_get_url_params_include_response_content_disposition(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = PresignService(mk_settings())
    recorder = RecordingSigner()
    monkeypatch.setattr(service, "_s3_signer", recorder)

    cd = attachment_content_disposition("视频 A.mp4")
    url = service.sign_get_url(
        "ms-proj", "folder-a/视频 A.mp4", 600,
        response_content_disposition=cd,
    )

    assert url == "https://minio.example/bucket/key?X-Amz-Signature=fake"
    assert recorder.operation == "get_object"
    assert recorder.params["Bucket"] == "ms-proj"
    assert recorder.params["Key"] == "folder-a/视频 A.mp4"
    assert "ResponseContentDisposition" in recorder.params
    value = recorder.params["ResponseContentDisposition"]
    assert "attachment" in value
    assert "filename*=UTF-8''" in value


def test_sign_get_url_ascii_filename_quoted_without_filename_star(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = PresignService(mk_settings())
    recorder = RecordingSigner()
    monkeypatch.setattr(service, "_s3_signer", recorder)

    cd = attachment_content_disposition("clip.mp4")
    service.sign_get_url("ms-proj", "f/clip.mp4", 600, response_content_disposition=cd)

    assert recorder.params["ResponseContentDisposition"] == 'attachment; filename="clip.mp4"'


# ─── ② 默认 / None:Params 不含该键(预览路径零变化)───────────────────────────
def test_sign_get_url_default_params_unchanged(monkeypatch: pytest.MonkeyPatch) -> None:
    service = PresignService(mk_settings())
    recorder = RecordingSigner()
    monkeypatch.setattr(service, "_s3_signer", recorder)

    service.sign_get_url("ms-proj", "f/clip.mp4", 600)
    service.sign_get_url("ms-proj", "f/clip.mp4", 600, response_content_disposition=None)

    assert recorder.params == {"Bucket": "ms-proj", "Key": "f/clip.mp4"}
    assert "ResponseContentDisposition" not in recorder.params


# ─── ③ RFC 5987 编码:中文文件名 ──────────────────────────────────────────────
def test_rfc5987_chinese_filename_pct_encoded() -> None:
    assert rfc5987_encode("视频.mp4") == "%E8%A7%86%E9%A2%91.mp4"
    assert rfc5987_encode("视频 A.mp4") == "%E8%A7%86%E9%A2%91%20A.mp4"


def test_attachment_disposition_chinese_has_ascii_fallback_and_rfc5987() -> None:
    cd = attachment_content_disposition("视频 A.mp4")
    assert cd == (
        'attachment; filename="__ A.mp4"; '
        "filename*=UTF-8''%E8%A7%86%E9%A2%91%20A.mp4"
    )


def test_attachment_disposition_pure_ascii_only_quoted() -> None:
    cd = attachment_content_disposition("clip.mp4")
    assert cd == 'attachment; filename="clip.mp4"'
    assert "filename*" not in cd


def test_attachment_disposition_escapes_quote() -> None:
    assert attachment_content_disposition('we"ird.mp4') == 'attachment; filename="we\\"ird.mp4"'
    # 全非 ASCII 文件名兜底退化为下划线串,原文名完整进 filename*
    assert attachment_content_disposition("视频") == (
        "attachment; filename=\"__\"; filename*=UTF-8''%E8%A7%86%E9%A2%91"
    )


# ─── router 层:as_attachment 透传与向后兼容 ──────────────────────────────────
async def test_endpoint_as_attachment_true_passes_disposition(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    asset = mk_asset("视频 A.mp4")
    stub = StubPresign()

    out = await call_download_link(monkeypatch, asset, stub, DownloadLinkIn(as_attachment=True))

    assert len(stub.calls) == 1
    cd = stub.calls[0]["response_content_disposition"]
    assert cd is not None
    assert "attachment" in cd
    assert "filename*=UTF-8''" in cd
    assert stub.calls[0]["key"] == "folder-a/视频 A.mp4"
    # DownloadLinkOut 结构不变:url / expires_in / is_sensitive
    assert out.url.startswith("https://minio.example/ms-proj/")
    assert out.expires_in == 900
    assert out.is_sensitive is False


async def test_endpoint_default_and_false_body_keep_inline(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    asset = mk_asset("clip.mp4")
    stub = StubPresign()

    # 无 body(向后兼容:老调用方不带 body 也不报错,AssetPreviewModal 路径)
    out_no_body = await call_download_link(monkeypatch, asset, stub, None)
    # 显式 False(等价前端 POST {})
    out_false = await call_download_link(
        monkeypatch, asset, stub, DownloadLinkIn(as_attachment=False),
    )

    assert stub.calls[0]["response_content_disposition"] is None
    assert stub.calls[1]["response_content_disposition"] is None
    assert out_no_body.url == out_false.url
    assert out_no_body.expires_in == out_false.expires_in


async def test_endpoint_as_attachment_true_still_audits(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """audit 逻辑不动:attachment 语义不改变 signed_url_issued 落库。"""
    monkeypatch.setattr("app.routers.assets.get_settings", lambda: mk_settings())
    asset = mk_asset("clip.mp4")
    audit = StubAudit()

    await get_download_link(
        asset.id,
        DownloadLinkIn(as_attachment=True),
        db=StubDB(asset),
        permissions=StubPermissions(),
        presign=StubPresign(),
        audit=audit,
        user=SimpleNamespace(id=uuid.uuid4(), subject="user:u1"),
        is_system_admin=True,
        ctx={"request_ip": "127.0.0.1", "user_agent": "pytest"},
    )

    assert any(e.get("event_type") == "signed_url_issued" for e in audit.events)
