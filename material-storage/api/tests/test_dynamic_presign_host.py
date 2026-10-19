"""预签名 URL 按请求来源 Host 动态签发(方案 docs/qdev/2026-10-12-dynamic-presign-host.md)。

策略分两层(与 test_download_attachment / test_upload_complete 的既有分工一致):

  离线单元(本机可跑,不连 DB / OpenFGA / MinIO → 文档「测试功能点」1-5):
    - presign 层:monkeypatch 把 boto3.client 换成记录替身工厂(Boto3ClientSpy),
      断言传 request_base 时动态 client 以该值为 endpoint_url 首见创建、同 base
      复用缓存、不传 request_base 回落静态 signer(零行为变化);
    - request_base_from:starlette Request 直构 scope,覆盖合法 host 三形态、
      非法三形态、X-Forwarded-Proto: https → scheme=https;
    - router 层:share resolve 直调 endpoint(stub 依赖),断言 request_base 透传。

  容器级(feat-ms 隔离栈,docker-compose.feat-ms.yml):
    - 必须打真 uvicorn socket 而非 ASGITransport:Dockerfile 启动带 --proxy-headers
      --forwarded-allow-ips '*',XFP → scope scheme 的改写发生在 uvicorn 中间件层,
      ASGITransport 会绕过它,测不到动态签发的 https 分支。API 直连模拟 nginx
      转发头(Host + X-Forwarded-Proto,即 hh2 nginx 会注入的两件,文档 B 节);
    - 栈不可达 / 宿主机缺容器 env 自动 skip(容器内 127.0.0.1:8000 /
      宿主机映射 127.0.0.1:8200),门控思路与 test_notifications_e2e 的
      DB 探测同款;数据自建自清(参照 test_upload_complete:EVAN 系统
      admin 直通 + seed_demo_data 项目)。
      运行:docker exec feat-ms-api pytest tests/test_dynamic_presign_host.py -v

被测契约以方案「功能点明细 A」为准(4 个签名方法 request_base: str | None = None、
helper request_base_from(request)、5 处调用点接入);各用例 docstring 标注功能点编号。
"""
from __future__ import annotations

import asyncio
import contextlib
import uuid
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace
from typing import Any
from urllib.parse import urlsplit

import boto3
import pytest
from botocore.client import Config
from httpx import AsyncClient
from starlette.requests import Request

from app.db.session import get_sessionmaker
from app.db.tables import Asset, Folder
from app.routers.share import resolve as share_resolve
from app.services.presign import PresignService, request_base_from
from app.settings import Settings, get_settings


# ─── 离线 helpers ─────────────────────────────────────────────────────────────
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
    """generate_presigned_url 替身:只记录入参,不触网。

    相比 test_download_attachment 的同名替身多了 endpoint_url / client_id 两个
    观测位:URL 回显二者,让「URL 前缀跟随 endpoint」与「client 同一性(缓存
    复用)」都能从返回值断言,不必伸进 PresignService 的私有属性。
    """

    def __init__(self, endpoint_url: str | None = None, client_id: int = 0) -> None:
        self.endpoint_url = endpoint_url
        self.client_id = client_id
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
        base = self.endpoint_url or "https://minio.example"
        return f"{base}/bucket/key?X-Amz-Signature=fake&client={self.client_id}"


class Boto3ClientSpy:
    """替身 boto3.client 工厂:记录每次创建的 service / endpoint_url。

    替换点 monkeypatch.setattr(boto3, "client", spy)——presign.py 顶层
    `import boto3` 后统一走 boto3.client(...) 建 client,替换该属性即可在
    不依赖缓存 dict 私有命名的前提下,观测「按 endpoint 建 client / 复用缓存」。
    """

    def __init__(self) -> None:
        self.created: list[dict[str, Any]] = []
        self.clients: list[RecordingSigner] = []

    def __call__(self, service_name: str, **kwargs: Any) -> RecordingSigner:
        self.created.append({"service": service_name, "endpoint_url": kwargs.get("endpoint_url")})
        client = RecordingSigner(
            endpoint_url=kwargs.get("endpoint_url"), client_id=len(self.clients) + 1,
        )
        self.clients.append(client)
        return client


def mk_request(
    host: str | None = None,
    scheme: str = "http",
    headers: dict[str, str] | None = None,
) -> Request:
    """直构 starlette Request(scope)——tests/ 无现成 helper,自建最小 scope。

    XFP 用例模拟的是 uvicorn --proxy-headers 处理后的 scope:scheme 已按
    X-Forwarded-Proto 改写为 https 且 XFP header 保留(ProxyHeadersMiddleware
    在 app 之前改写 scope["scheme"],handler 拿到的就是改写后的值);真实转发
    链路(nginx → uvicorn)由本文件容器级用例打真 socket 覆盖。
    """
    raw: list[tuple[bytes, bytes]] = []
    if host is not None:
        raw.append((b"host", host.encode("ascii")))
    for name, value in (headers or {}).items():
        raw.append((name.lower().encode("ascii"), value.encode("ascii")))
    scope: dict[str, Any] = {
        "type": "http",
        "asgi": {"version": "3.0", "spec_version": "2.3"},
        "http_version": "1.1",
        "method": "GET",
        "scheme": scheme,
        "path": "/api/v1/assets",
        "raw_path": b"/api/v1/assets",
        "query_string": b"",
        "root_path": "",
        "server": ("testserver", 80),
        "client": ("127.0.0.1", 54321),
        "headers": raw,
    }
    return Request(scope)


def mk_asset(filename: str) -> SimpleNamespace:
    # size_bytes / content_type:share resolve 出参 asset dict 的既有契约字段
    # (644de17 前就在读),与本文件被测的动态 host 正交,补齐避免 AttributeError
    # folder_id:W2b 起 share resolve 读它反查 Folder 补审计 target_project_id
    return SimpleNamespace(
        id=uuid.uuid4(),
        deleted_at=None,
        filename=filename,
        folder_id=uuid.uuid4(),
        minio_bucket="ms-proj",
        minio_key=f"folder-a/{filename}",
        size_bytes=1024,
        content_type="video/mp4",
    )


class StubDB:
    """最小 async db 替身:get 对 Asset 返预置 asset;对 Folder 返带 project_id
    的行(W2b 起 resolve 读 asset.folder_id 反查夹行补审计)。"""

    def __init__(self, asset: object) -> None:
        self._asset = asset

    async def get(self, model: object, pk: object) -> object | None:
        if model is Folder:
            return SimpleNamespace(id=pk, project_id=uuid.uuid4())
        return self._asset


class StubPermissions:
    """share resolve 直调替身:短链豁免 enforce(share owner 已 verified),
    check 不应被走到;万一实现侧动了,放行不误伤透传断言。"""

    def __init__(self) -> None:
        self.checks: list[dict[str, str]] = []

    async def check(self, **kw: str) -> bool:
        self.checks.append(kw)
        return True


class StubAudit:
    def __init__(self) -> None:
        self.events: list[dict[str, Any]] = []

    async def write(self, **kw: Any) -> None:
        self.events.append(kw)


class RecordingSharePresign:
    """share resolve 的 presign 替身:按契约记录 sign_get_url 实参(含 request_base)。"""

    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []

    def sign_get_url(
        self,
        bucket: str,
        key: str,
        expires_seconds: int,
        response_content_disposition: str | None = None,
        request_base: str | None = None,
    ) -> str:
        self.calls.append({
            "bucket": bucket,
            "key": key,
            "expires_seconds": expires_seconds,
            "response_content_disposition": response_content_disposition,
            "request_base": request_base,
        })
        return f"https://minio.example/{bucket}/{key}?X-Amz-Signature=fake"


async def call_share_resolve(
    monkeypatch: pytest.MonkeyPatch,
    asset: SimpleNamespace,
    presign: RecordingSharePresign,
    host: str,
    scheme: str = "http",
    headers: dict[str, str] | None = None,
) -> Any:
    """直调 share resolve endpoint(绕过 Depends);stub 依赖 + 打桩 resolve_share。"""
    info: dict[str, Any] = {
        "kind": "asset",
        "target_id": asset.id,
        "sharer_name": "夏威尔",
        "expires_at": datetime.now(UTC) + timedelta(hours=1),
    }

    async def fake_resolve_share(db: object, token: str) -> dict[str, Any]:
        return info

    monkeypatch.setattr("app.routers.share.resolve_share", fake_resolve_share)
    monkeypatch.setattr("app.routers.share.get_settings", lambda: mk_settings())
    return await share_resolve(
        "tok-123",
        request=mk_request(host=host, scheme=scheme, headers=headers),
        db=StubDB(asset),
        permissions=StubPermissions(),
        presign=presign,
        audit=StubAudit(),
        user=SimpleNamespace(id=uuid.uuid4(), subject="user:u1"),
        ctx={"request_ip": "127.0.0.1", "user_agent": "pytest"},
    )


# ─── ① 功能点 1:传 request_base → 动态 client endpoint 正确 ─────────────────
def test_1_sign_get_url_dynamic_endpoint_follows_request_base(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """功能点 1:https 域名入口 → 动态 client 以 request_base 为 endpoint_url
    首见创建,返回 URL 前缀跟随(request_base 进 Params 语义不变)。"""
    spy = Boto3ClientSpy()
    monkeypatch.setattr(boto3, "client", spy)
    service = PresignService(mk_settings())
    # 构造期 5 个静态 client(4 s3 + 1 sts)不在断言范围:created 与 clients
    # 一并清零 —— 只清 created 的话 clients[0] 仍指向从未签名的 _s3_internal,
    # 动态 client 的 client_id 也从 6 起算(断言 client=1 会错位)
    spy.created.clear()
    spy.clients.clear()

    url = service.sign_get_url(
        "ms-proj", "folder-a/视频 A.mp4", 600,
        request_base="https://bucket.taoxiplan.com",
    )

    assert spy.created == [{"service": "s3", "endpoint_url": "https://bucket.taoxiplan.com"}]
    assert url.startswith("https://bucket.taoxiplan.com/")
    assert spy.clients[0].operation == "get_object"
    assert spy.clients[0].params == {"Bucket": "ms-proj", "Key": "folder-a/视频 A.mp4"}


def test_1_sign_thumbnail_url_dynamic_endpoint_same_vhost(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """功能点 1 + 明细 A.5:缩略图动态 endpoint 同样整体替换 host(缩略图与
    原片同 vhost,nginx 按 /ms-thumbs/ 路径分流);Bucket 仍是缩略图 bucket。"""
    settings = mk_settings()
    spy = Boto3ClientSpy()
    monkeypatch.setattr(boto3, "client", spy)
    service = PresignService(settings)
    spy.created.clear()
    spy.clients.clear()  # 静态 client 清出观测窗口(同 test_1 首例注释)

    url = service.sign_thumbnail_url(
        "thumbs/a.jpg", 1800, request_base="https://bucket.taoxiplan.com",
    )

    assert spy.created == [{"service": "s3", "endpoint_url": "https://bucket.taoxiplan.com"}]
    assert url.startswith("https://bucket.taoxiplan.com/")
    assert spy.clients[0].params["Bucket"] == settings.minio_thumbnail_bucket


def test_1_sign_part_url_dynamic_endpoint_params_intact(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """功能点 1:上传分片 URL(assets.py sign_part 调用点)动态 endpoint;
    multipart 四参数原样进 Params(外网 IP:端口入口,含端口)。"""
    spy = Boto3ClientSpy()
    monkeypatch.setattr(boto3, "client", spy)
    service = PresignService(mk_settings())
    spy.created.clear()
    spy.clients.clear()

    url = service.sign_part_url(
        "ms-proj", "folder-a/a.mp4", "upload-1", 2, 600,
        request_base="http://47.108.196.211:18080",
    )

    assert spy.created == [{"service": "s3", "endpoint_url": "http://47.108.196.211:18080"}]
    assert url.startswith("http://47.108.196.211:18080/")
    assert spy.clients[0].operation == "upload_part"
    assert spy.clients[0].params == {
        "Bucket": "ms-proj", "Key": "folder-a/a.mp4",
        "UploadId": "upload-1", "PartNumber": 2,
    }


def test_1_sign_put_url_accepts_request_base(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """功能点 1 + 决策 D2:sign_put_url 现无调用方仍加同款参数(4 方法 API 一致)。"""
    spy = Boto3ClientSpy()
    monkeypatch.setattr(boto3, "client", spy)
    service = PresignService(mk_settings())
    spy.created.clear()
    spy.clients.clear()

    url = service.sign_put_url(
        "ms-proj", "folder-a/a.mp4", 600, request_base="http://192.168.110.221",
    )

    assert spy.created == [{"service": "s3", "endpoint_url": "http://192.168.110.221"}]
    assert url.startswith("http://192.168.110.221/")
    assert spy.clients[0].operation == "put_object"


# ─── ② 功能点 2:signer client 按 endpoint 缓存 ───────────────────────────────
def test_2_dynamic_client_cached_per_request_base(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """功能点 2:同一 request_base 二次调用复用缓存 client(URL 回显同一
    client_id);不同 request_base 各自建;再回到首个 base 仍复用。"""
    spy = Boto3ClientSpy()
    monkeypatch.setattr(boto3, "client", spy)
    service = PresignService(mk_settings())
    spy.created.clear()
    spy.clients.clear()  # 静态 client 清出去后动态 client 才从 client_id=1 起算

    https_base = "https://bucket.taoxiplan.com"
    wan_base = "http://47.108.196.211:18080"

    u1 = service.sign_get_url("ms-proj", "f/a.mp4", 600, request_base=https_base)
    u2 = service.sign_get_url("ms-proj", "f/b.mp4", 600, request_base=https_base)
    u3 = service.sign_get_url("ms-proj", "f/c.mp4", 600, request_base=wan_base)
    u4 = service.sign_get_url("ms-proj", "f/d.mp4", 600, request_base=https_base)

    # 首见创建:https 域名一个、外网 IP:端口一个;同 base 二次/三次不再建
    assert [c["endpoint_url"] for c in spy.created] == [https_base, wan_base]
    assert u1.endswith("&client=1")
    assert u2.endswith("&client=1")   # 复用缓存 client
    assert u3.endswith("&client=2")   # 不同 base 各自缓存
    assert u4.endswith("&client=1")   # 回到旧 base 仍复用第一个 client


# ─── ③ 功能点 3:不传 request_base → 静态 signer,零行为变化 ─────────────────
def test_3_no_request_base_uses_static_signer(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """功能点 3:不传 request_base 走静态 _s3_signer(MINIO_ENDPOINT_PUBLIC),
    Params 与旧版完全一致,且不按 endpoint 新建任何动态 client。"""
    settings = mk_settings()
    spy = Boto3ClientSpy()
    monkeypatch.setattr(boto3, "client", spy)
    service = PresignService(settings)
    static = RecordingSigner(endpoint_url=settings.minio_endpoint_public)
    monkeypatch.setattr(service, "_s3_signer", static)
    spy.created.clear()

    url = service.sign_get_url("ms-proj", "f/a.mp4", 600)

    assert spy.created == []            # 未按 endpoint 建任何动态 client
    assert static.params == {"Bucket": "ms-proj", "Key": "f/a.mp4"}
    assert url == f"{settings.minio_endpoint_public}/bucket/key?X-Amz-Signature=fake&client=0"


def test_3_no_request_base_thumb_falls_back_to_static_thumb_signer(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """功能点 3 + 明细 A.5:无请求上下文时缩略图回落静态 _s3_thumb_signer
    (MINIO_THUMBNAIL_ENDPOINT_PUBLIC 仅作回落,明细 A.5)。"""
    settings = mk_settings()
    spy = Boto3ClientSpy()
    monkeypatch.setattr(boto3, "client", spy)
    service = PresignService(settings)
    static_thumb = RecordingSigner(
        endpoint_url=settings.minio_thumbnail_endpoint_public or settings.minio_endpoint_public,
    )
    monkeypatch.setattr(service, "_s3_thumb_signer", static_thumb)
    spy.created.clear()

    service.sign_thumbnail_url("thumbs/a.jpg", 1800)

    assert spy.created == []
    assert static_thumb.params["Bucket"] == settings.minio_thumbnail_bucket
    assert static_thumb.params["Key"] == "thumbs/a.jpg"


# ─── ④ 功能点 4:request_base_from ────────────────────────────────────────────
def test_4_request_base_from_legal_host_forms() -> None:
    """功能点 4:合法 host 三形态 —— 裸域名 / IP:端口(含非标端口)/ IPv6,
    均原样拼 f"{scheme}://{host}"(Host 含端口,不剥不补)。"""
    cases: list[tuple[str, str]] = [
        ("bucket.taoxiplan.com", "http"),      # 裸域名(https 入口见 XFP 用例)
        ("192.168.110.221", "http"),           # 内网 IP(无端口)
        ("47.108.196.211:18080", "http"),      # 外网 IP:端口
        ("[::1]:8080", "http"),                # IPv6 带端口
    ]
    for host, scheme in cases:
        req = mk_request(host=host, scheme=scheme)
        assert request_base_from(req) == f"{scheme}://{host}", host


def test_4_request_base_from_missing_or_empty_host_returns_none() -> None:
    """功能点 4:Host header 缺失 / 空串 → None(回落静态,决策 D3 不报错)。"""
    assert request_base_from(mk_request(host=None)) is None
    assert request_base_from(mk_request(host="")) is None


def test_4_request_base_from_host_length_boundary() -> None:
    """功能点 4:长度校验边界 —— 契约 ≤253 合法,254 起判非法。"""
    assert request_base_from(mk_request(host="a" * 253)) is not None
    assert request_base_from(mk_request(host="a" * 254)) is None
    assert request_base_from(mk_request(host="a" * 400)) is None


def test_4_request_base_from_illegal_chars_returns_none() -> None:
    """功能点 4:非法字符(<script>、空格)不在字符集 ^[A-Za-z0-9.\\-:\\[\\]]+$ 内
    → None(防伪造 host 注入,回落静态)。"""
    assert request_base_from(mk_request(host="<script>")) is None
    assert request_base_from(mk_request(host="bad host")) is None


def test_4_request_base_from_xfp_https_scheme() -> None:
    """功能点 4:X-Forwarded-Proto: https → scheme=https(nginx 透传 XFP,
    uvicorn --proxy-headers 改写 scope scheme 后进 handler;此处直构改写后的
    scope,真实转发链路由容器级用例覆盖)。"""
    req = mk_request(
        host="bucket.taoxiplan.com",
        scheme="https",
        headers={"X-Forwarded-Proto": "https"},
    )
    assert request_base_from(req) == "https://bucket.taoxiplan.com"


# ─── ⑤ 功能点 5:share 直链路径透传 request_base ──────────────────────────────
async def test_5_share_resolve_passes_request_base_https_domain(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """功能点 5:share resolve(公开分享页直链下载,share.py sign_get_url 调用点)
    把 request_base_from(request) 透传给 presign;attachment 语义与出参结构不变。"""
    asset = mk_asset("视频 A.mp4")
    stub = RecordingSharePresign()

    out = await call_share_resolve(
        monkeypatch, asset, stub,
        host="bucket.taoxiplan.com", scheme="https",
        headers={"X-Forwarded-Proto": "https"},
    )

    assert len(stub.calls) == 1
    call = stub.calls[0]
    assert call["request_base"] == "https://bucket.taoxiplan.com"
    assert call["bucket"] == "ms-proj"
    assert call["key"] == "folder-a/视频 A.mp4"
    # 分享下载签发同走 attachment 语义(方案 §3.5),动态 host 正交
    assert call["response_content_disposition"] is not None
    assert "attachment" in call["response_content_disposition"]
    # 出参结构不变:download_url 透传 + ttl 来自 settings(仅 scheme/host 跟随入口)
    assert out.kind == "asset"
    assert out.download_url == (
        "https://minio.example/ms-proj/folder-a/视频 A.mp4?X-Amz-Signature=fake"
    )
    assert out.download_expires_in == 900


async def test_5_share_resolve_illegal_host_passes_none_fallback(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """功能点 5 + 决策 D3:Host 非法 → request_base_from 返 None 原样透传
    (回落静态 signer,不报错;内网 IP:端口等合法形态透传已见 ①/②)。"""
    asset = mk_asset("clip.mp4")
    stub = RecordingSharePresign()

    out = await call_share_resolve(
        monkeypatch, asset, stub,
        host="<script>", scheme="http",
    )

    assert stub.calls[0]["request_base"] is None
    assert out.download_url == (
        "https://minio.example/ms-proj/folder-a/clip.mp4?X-Amz-Signature=fake"
    )


# ══════════════════════════════════════════════════════════════════════════════
# 容器级:feat-ms 隔离栈,API 直连模拟 nginx 转发头
#
# 为什么打真 uvicorn socket 而不是 ASGITransport:Dockerfile 启动带 --proxy-headers
# --forwarded-allow-ips '*',XFP → scope scheme 的改写在 uvicorn 中间件层;
# ASGITransport 绕过它,永远拿不到 https 分支。Host / X-Forwarded-Proto 即
# hh2 nginx 改造后(文档 B 节)会注入的两件。
# 运行:docker exec feat-ms-api pytest tests/test_dynamic_presign_host.py -v
# (宿主机跑走 127.0.0.1:8200 映射;part 直传需 minio_endpoint_internal 可达)
# ══════════════════════════════════════════════════════════════════════════════

EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"          # 系统 admin(org admin)
PROJECT_EVENT = "11111111-1111-1111-1111-111111111103"    # public(与 test_upload_complete 同 seed)

HTTPS_HOST = "bucket.taoxiplan.com"
WAN_HOST = "47.108.196.211:18080"

PART_BODY = b"dynamic-presign-host-test" * 2

# 候选 base:容器内直连 uvicorn(8000)优先,宿主机映射端口(8200)兜底
_API_BASES = ("http://127.0.0.1:8000", "http://127.0.0.1:8200")


def _h(uid: str = EVAN_ID) -> dict[str, str]:
    return {"X-User-Id": uid}


def _entry_headers(host: str, xfp: str | None = None) -> dict[str, str]:
    """模拟 nginx 转发头:Host 必带;XFP 仅 https 入口注入(文档 B 节行为)。"""
    headers = {"X-User-Id": EVAN_ID, "Host": host}
    if xfp is not None:
        headers["X-Forwarded-Proto"] = xfp
    return headers


@pytest.fixture(scope="session")
async def api_base() -> str:
    """feat-ms 隔离栈可达性门控:/healthz 探测候选 base,全不通 → 整体 skip。

    与 test_notifications_e2e 的 DB 探测同款思路(运行环境探测而非硬编码
    skipif),离线用例不受影响;session 级对齐 pyproject 的 session loop scope。

    栈可达 ≠ 能跑(宿主机侧稳健 skip,容器内路径保持):part 直传要在本进程
    直连 MinIO 内部端点(_upload_part 走 get_settings() +
    minio_endpoint_internal)。宿主机 cwd 无 .env 时 Settings 构造即
    ValidationError;即便 env 凑齐,内部 endpoint 的容器网络主机名宿主机也
    多半不可达 —— 两道自检任一不过 → skip 并指路容器内跑法。容器内
    (docker exec feat-ms-api)env 齐备 + 内部 MinIO 可达,两道自检照常通过。
    """
    last_exc: Exception | None = None
    reachable: str | None = None
    for base in _API_BASES:
        try:
            async with AsyncClient(base_url=base, timeout=3.0) as probe:
                r = await probe.get("/healthz")
            if r.status_code == 200:
                reachable = base
                break
        except Exception as exc:
            last_exc = exc
    if reachable is None:
        pytest.skip(
            "feat-ms 隔离栈不可达(试过 127.0.0.1:8000 / 127.0.0.1:8200,"
            f"last_exc={last_exc})—— 动态 Host 容器级用例跳过,离线用例照常执行"
        )

    # 自检一:本进程能构造 Settings(容器级用例的依赖都在它身上)
    try:
        settings = get_settings()
    except Exception as exc:
        pytest.skip(
            f"feat-ms 栈可达({reachable})但本进程缺容器 env,get_settings() 失败"
            f"({type(exc).__name__})—— 宿主机跑容器级用例请走"
            "docker exec feat-ms-api pytest tests/test_dynamic_presign_host.py -v;"
            "离线用例不受影响"
        )

    # 自检二:minio_endpoint_internal 可达(_upload_part 直传 part 用)
    internal = urlsplit(settings.minio_endpoint_internal)
    try:
        _reader, writer = await asyncio.open_connection(
            internal.hostname or "", internal.port or 9000,
        )
    except OSError as exc:
        pytest.skip(
            f"feat-ms 栈可达但 minio_endpoint_internal"
            f"({settings.minio_endpoint_internal})不可达({exc})—— part 直传无法"
            "进行,容器级用例跳过(请在容器内跑);离线用例不受影响"
        )
    writer.close()
    with contextlib.suppress(OSError):
        await writer.wait_closed()
    return reachable


@pytest.fixture(scope="session")
async def client(api_base: str) -> AsyncClient:
    """直连隔离栈真 uvicorn socket(保留 XFP→scheme 中间件改写,被测链路一环)。"""
    async with AsyncClient(base_url=api_base, timeout=30.0) as ac:
        yield ac


async def _skip_if_no_dev_channel(client: AsyncClient) -> None:
    """X-User-Id 通道探测:thumbnail-url 对不存在 asset,404=通道可用,401=不可用。"""
    r = await client.get(f"/api/v1/assets/{uuid.uuid4()}/thumbnail-url", headers=_h())
    if r.status_code == 401:
        pytest.skip("X-User-Id 通道不可用(env != dev 或 seed_demo_data 未跑)—— 容器级用例跳过")


async def _create_folder(client: AsyncClient, project_id: str, name: str) -> dict:
    r = await client.post(
        "/api/v1/folders", json={"project_id": project_id, "name": name}, headers=_h(),
    )
    assert r.status_code == 201, r.text
    return r.json()


async def _create_multipart(client: AsyncClient, folder: dict, filename: str) -> dict:
    r = await client.post("/api/v1/assets/uploads", json={
        "folder_id": folder["id"],
        "filename": filename,
        "content_type": "text/plain",
        "size_bytes": len(PART_BODY),
    }, headers=_h())
    assert r.status_code == 200, r.text
    return r.json()  # {upload_id, key, bucket}


def _upload_part(bucket: str, key: str, upload_id: str) -> str:
    """直连 MinIO 内部端点传 1 个 part(公网签名 URL 是浏览器视角 host,容器内不通;
    与 test_upload_complete._upload_part 同款)。"""
    s = get_settings()
    s3 = boto3.client(
        "s3",
        endpoint_url=s.minio_endpoint_internal,
        aws_access_key_id=s.minio_access_key,
        aws_secret_access_key=s.minio_secret_key,
        config=Config(signature_version="s3v4", region_name="us-east-1"),
        region_name="us-east-1",
    )
    resp = s3.upload_part(
        Bucket=bucket, Key=key, PartNumber=1, UploadId=upload_id, Body=PART_BODY,
    )
    return resp["ETag"]


async def _complete(
    client: AsyncClient, upload_id: str, folder_id: str,
    bucket: str, key: str, parts: list[dict],
):
    return await client.post(
        f"/api/v1/assets/uploads/{upload_id}/complete",
        json={
            "upload_id": upload_id,
            "folder_id": folder_id,
            "bucket": bucket,
            "key": key,
            "parts": parts,
        },
        headers=_h(),
    )


async def _abort(client: AsyncClient, upload: dict) -> None:
    r = await client.delete(
        f"/api/v1/assets/uploads/{upload['upload_id']}",
        params={"bucket": upload["bucket"], "key": upload["key"]}, headers=_h(),
    )
    assert r.status_code == 204, r.text


async def _cleanup(client: AsyncClient, asset_ids: list[str], folder_ids: list[str]) -> None:
    """软删 + 彻底删除测试资产,再删空 folder(与 test_upload_complete._cleanup 同款)。"""
    for aid in asset_ids:
        r = await client.delete(f"/api/v1/assets/{aid}", headers=_h())
        assert r.status_code == 204, r.text
        r = await client.delete(f"/api/v1/assets/{aid}?hard=true", headers=_h())
        assert r.status_code == 204, r.text
    for fid in folder_ids:
        r = await client.delete(f"/api/v1/folders/{fid}", headers=_h())
        assert r.status_code == 204, r.text


async def _set_thumbnail_key(asset_id: str, key: str) -> None:
    """直改 DB tags.thumbnail_key:thumbnail-url 只读 tags,签名是本地计算不触
    MinIO,无需真生成缩略图(直连 DB 的范式见 test_upload_complete._get_asset)。"""
    async with get_sessionmaker()() as db:
        asset = await db.get(Asset, uuid.UUID(asset_id))
        assert asset is not None
        asset.tags = {**(asset.tags or {}), "thumbnail_key": key}
        await db.commit()


@pytest.mark.asyncio
async def test_c1_https_domain_entry_download_link_and_thumbnail(client: AsyncClient) -> None:
    """容器级:Host=bucket.taoxiplan.com + XFP=https(https 域名入口)→
    download-link 与 thumbnail-url 的 URL 均以 https://bucket.taoxiplan.com/ 开头
    (混合内容实锤场景的回归:旧实现此处返回 http://47.108.196.211:18080/... 被拦)。"""
    await _skip_if_no_dev_channel(client)
    uniq = uuid.uuid4().hex[:8]
    folder = await _create_folder(client, PROJECT_EVENT, f"zz_dph_{uniq}")
    upload: dict = {}
    asset_id = ""
    completed = False
    try:
        upload = await _create_multipart(client, folder, f"zz_dph_{uniq}.txt")
        etag = _upload_part(upload["bucket"], upload["key"], upload["upload_id"])
        r = await _complete(
            client, upload["upload_id"], folder["id"],
            upload["bucket"], upload["key"], [{"partNumber": 1, "etag": etag}],
        )
        assert r.status_code == 200, r.text
        completed = True
        asset_id = r.json()["id"]

        # download-link:https 域名入口
        r = await client.post(
            f"/api/v1/assets/{asset_id}/download-link",
            headers=_entry_headers(HTTPS_HOST, xfp="https"),
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["url"].startswith(f"https://{HTTPS_HOST}/"), body["url"]
        assert body["expires_in"] == 900

        # thumbnail-url:同 vhost 动态 host(明细 A.5)
        await _set_thumbnail_key(asset_id, f"thumbs/zz_dph_{uniq}.jpg")
        r = await client.get(
            f"/api/v1/assets/{asset_id}/thumbnail-url",
            headers=_entry_headers(HTTPS_HOST, xfp="https"),
        )
        assert r.status_code == 200, r.text
        assert r.json()["url"].startswith(f"https://{HTTPS_HOST}/"), r.json()["url"]
    finally:
        if upload and not completed:
            await _abort(client, upload)
        await _cleanup(client, [asset_id] if asset_id else [], [folder["id"]])


@pytest.mark.asyncio
async def test_c2_wan_ip_port_entry_download_link_without_xfp(client: AsyncClient) -> None:
    """容器级:Host=47.108.196.211:18080、无 X-Forwarded-Proto(外网 IP:端口入口)
    → download-link 的 URL 以 http://47.108.196.211:18080/ 开头(Host 含端口,
    nginx 用 $http_host 透传后端口不丢,否则 MinIO 403 —— 文档 B 节)。"""
    await _skip_if_no_dev_channel(client)
    uniq = uuid.uuid4().hex[:8]
    folder = await _create_folder(client, PROJECT_EVENT, f"zz_dphw_{uniq}")
    upload: dict = {}
    asset_id = ""
    completed = False
    try:
        upload = await _create_multipart(client, folder, f"zz_dphw_{uniq}.txt")
        etag = _upload_part(upload["bucket"], upload["key"], upload["upload_id"])
        r = await _complete(
            client, upload["upload_id"], folder["id"],
            upload["bucket"], upload["key"], [{"partNumber": 1, "etag": etag}],
        )
        assert r.status_code == 200, r.text
        completed = True
        asset_id = r.json()["id"]

        r = await client.post(
            f"/api/v1/assets/{asset_id}/download-link",
            headers=_entry_headers(WAN_HOST),  # 无 XFP:scheme 保持 http
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["url"].startswith(f"http://{WAN_HOST}/"), body["url"]
    finally:
        if upload and not completed:
            await _abort(client, upload)
        await _cleanup(client, [asset_id] if asset_id else [], [folder["id"]])
