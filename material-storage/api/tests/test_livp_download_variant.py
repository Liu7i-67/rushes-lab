"""livp 下载 variant 端点 + share resolve 解包交付 — 契约测试(F2 注册 / F3 variant / F4 share)。

对应需求文档(唯一依据):docs/qdev/2026-10-21-livp-download-unpack.md「测试功能点」
权威方案:rushes-spec/material-storage/livp-download-unpack-plan.md §3/§4/§10。

设施沿用 tests/test_download_attachment.py 同款(定稿 §10 钦定「download-link
variant 挂 test_download_attachment.py 同款设施」):直调 endpoint 函数 + stub
依赖,不连真 DB / OpenFGA / MinIO / Redis;share resolve 同口径直调。

Seam 说明(契约钉死 / 仓库惯例假设):
  - endpoint:app.routers.assets.get_download_link(既有函数,variant 为 additive
    入参)—— 契约钉死;arq pool 若走依赖注入则按形参名(arq_pool/redis)补传,
    否则走 request.app.state.arq_pool(上传完成派发点既有惯例),两者都兜住;
  - 自愈 enqueue:调 app.services.arq_pool.enqueue_livp_download(F2 契约钉死,
    路由侧 function-body import,与缩略图三兄弟同款),_job_id=f"livpdl:{id}" /
    _expires≈3600;测试只 mock **pool 本体**(ArqRedis 亦是 redis 客户端,频控
    livpdl:heal:{asset_id} SETNX EX 600 走 pool.set(nx=True, ex=600)),不 mock
    enqueue_livp_download 本身 —— 保「频控占用不重派 / SETNX 异常照常 404」可测;
  - head 校验:presign.head_object(F6 扩展返回 Metadata),对象缺失以 botocore
    ClientError(404) 模拟 —— 孤儿 tag 按缺失走 404;
  - worker 注册:WorkerSettings.functions 含 generate_livp_download
    (timeout=300 / max_tries=2)—— F1/F2 契约钉死。

测试函数 → 需求文档「测试功能点」映射(PM 验收对照):
  variant 端点(定稿 §10 download-link variant 组)
    unpacked+就绪 → 200,URL 指向 derivatives zip,attachment 文件名 基名.zip,
        审计 details.variant,head 先于签发,不触发自愈
                                    → test_variant_unpacked_ready_signs_zip_with_attachment_basename
    中文基名 RFC5987(基名.zip)    → test_variant_unpacked_chinese_basename_rfc5987
    内联(无 as_attachment)签 zip 但无 disposition
                                    → test_variant_unpacked_inline_has_no_disposition
    .LIVP 大小写不敏感识别          → test_variant_livp_extension_case_insensitive
    非 livp + unpacked → 400        → test_non_livp_with_unpacked_400
    未就绪 → 404 + 自愈 enqueue 被调(确定性 _job_id + _expires=3600)
                                    → test_not_ready_404_selfheal_enqueue_contract
    频控 livpdl:heal:{id} SETNX 占用 → 404 且不重派
                                    → test_heal_rate_limited_no_redispatch
    download_zip_failed 有值 → 404 且不重派(永久失败闸门)
                                    → test_permanent_failed_tag_no_redispatch
    孤儿 tag(head 404)→ 404 + 自愈重派
                                    → test_orphan_tag_head_missing_404_and_selfheal
    SETNX 异常 → 只 log 照常 404(不 500)
                                    → test_heal_setnx_error_still_404
    403 与 original 完全一致(且不泄漏自愈 enqueue)
                                    → test_forbidden_parity_original_vs_unpacked
    original 默认/显式 → 零变化(无 head、无 enqueue、审计原形)
                                    → test_default_and_explicit_original_zero_regression
  注册(F1/F2)
    generate_livp_download timeout=300 / max_tries=2
                                    → test_generate_livp_download_registered
    enqueue_livp_download 确定性 _job_id + _expires=3600
                                    → test_enqueue_livp_download_helper_contract
  share resolve(F4)
    livp 就绪 → head 后签 zip + livp_unpacked:true
                                    → test_share_ready_livp_signs_zip_marks_unpacked
    livp 未就绪 → 原始 livp(回归) → test_share_not_ready_livp_original_regression
    非 livp → 原始(回归)           → test_share_non_livp_unchanged
"""
from __future__ import annotations

import inspect
import time
import uuid
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace
from typing import Any

import pytest
from botocore.exceptions import ClientError
from starlette.requests import Request

from app.db.tables import Folder
from app.routers import share as share_router
from app.routers.assets import (
    DownloadLinkIn,
    attachment_content_disposition,
    get_download_link,
    rfc5987_encode,
)
from app.services.arq_pool import enqueue_livp_download
from app.settings import Settings
from app.workers.main import WorkerSettings


# ─── 通用替身(沿用 test_download_attachment.py 惯例)─────────────────────────
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


class FakeArqPool:
    """arq pool 替身:记录 enqueue_job 入参;set/get 模拟 Redis(自愈频控 SETNX)。

    ArqRedis 继承 redis.asyncio.Redis,频控 livpdl:heal:{asset_id} 的
    SETNX(EX 600)走同一连接 —— 按 redis 语义实现:落成 True / 占用返回 None;
    hold() 可预置「已占用」形态(频控命中的用例前置)。
    """

    def __init__(self) -> None:
        self.enqueued: list[dict[str, Any]] = []
        self.set_calls: list[dict[str, Any]] = []
        self.set_raises: bool = False
        self._held: dict[str, tuple[str, float]] = {}

    def hold(self, name: str, value: str = "1") -> None:
        self._held[name] = (value, time.time() + 600)

    async def enqueue_job(self, function: str, *args: Any, **kwargs: Any) -> Any:
        self.enqueued.append({"function": function, "args": args, "kwargs": kwargs})
        return SimpleNamespace(job_id=kwargs.get("_job_id"))

    async def set(
        self, name: str, value: Any, *, nx: bool = False, ex: int | None = None, **kw: Any
    ) -> bool | None:
        self.set_calls.append({"name": name, "value": value, "nx": nx, "ex": ex})
        if self.set_raises:
            raise RuntimeError("redis down")
        if nx:
            if name in self._held:
                return None
            self._held[name] = (str(value), time.time() + (ex or 0))
        return True

    async def get(self, name: str) -> str | None:
        item = self._held.get(name)
        return item[0] if item else None


class StubDB:
    """最小 async db 替身(get 对 Asset 返预置行、对 Folder 返 project_id 占位)。"""

    def __init__(self, asset: object) -> None:
        self._asset = asset

    async def get(self, model: object, pk: object) -> object | None:
        if model is Folder:
            return SimpleNamespace(id=pk, project_id=uuid.uuid4())
        return self._asset


class StubPermissions:
    def __init__(self, allowed: bool = True) -> None:
        self.allowed = allowed
        self.checks: list[dict[str, Any]] = []

    async def check(self, **kw: Any) -> bool:
        self.checks.append(kw)
        return self.allowed


class StubAudit:
    def __init__(self) -> None:
        self.events: list[dict[str, Any]] = []

    async def write(self, **kw: Any) -> None:
        self.events.append({"event_type": kw.get("event_type", "write"), **kw})

    async def signed_url_issued(self, **kw: Any) -> None:
        self.events.append({"event_type": "signed_url_issued", **kw})

    def of_type(self, event_type: str) -> list[dict[str, Any]]:
        return [e for e in self.events if e.get("event_type") == event_type]


class HeadPresign:
    """presign 替身:记录 sign_get_url 实参;head_object 行为可控(可造孤儿 tag)。

    ops 为共享操作日志(["head", key] / ["sign", key])—— 断言 F3「签发前
    head 校验」。head_ok=False 时 head 抛 ClientError(404) 模拟对象缺失。
    """

    def __init__(self, *, head_ok: bool = True) -> None:
        self.calls: list[dict[str, Any]] = []
        self.head_calls: list[tuple[str, str]] = []
        self.ops: list[list[str]] = []
        self._head_ok = head_ok

    def head_object(self, bucket: str, key: str) -> dict[str, Any]:
        self.head_calls.append((bucket, key))
        self.ops.append(["head", key])
        if not self._head_ok:
            raise ClientError(
                {"Error": {"Code": "404", "Message": "Not Found"}}, "HeadObject"
            )
        return {
            "size_bytes": 123,
            "content_type": "application/zip",
            "etag": "e",
            "version_id": None,
            "last_modified": datetime.now(UTC),
            "metadata": {"kind": "livp_download_zip"},  # F6:Metadata(dict)
        }

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
        self.ops.append(["sign", key])
        return f"https://minio.example/{bucket}/{key}?X-Amz-Signature=fake"


def mk_asset(filename: str, *, tags: dict[str, Any] | None = None) -> SimpleNamespace:
    aid = uuid.uuid4()
    return SimpleNamespace(
        id=aid,
        deleted_at=None,
        filename=filename,
        folder_id=uuid.uuid4(),
        minio_bucket="ms-proj",
        minio_key=f"folder-a/{filename}",
        size_bytes=1024,
        content_type="application/octet-stream",
        tags=tags if tags is not None else {},
    )


def mk_request(pool: FakeArqPool | None = None) -> Request:
    """直构 starlette Request;scope 附 app(动态 host 惯例同款)。

    app.state.arq_pool 与 app.state.redis 指向同一 FakeArqPool —— variant 自愈
    enqueue 与 livpdl:heal 频控无论走哪个 seam 都能拿到替身。
    """
    app_obj = SimpleNamespace(state=SimpleNamespace(arq_pool=pool, redis=pool))
    return Request({
        "type": "http",
        "asgi": {"version": "3.0", "spec_version": "2.3"},
        "http_version": "1.1",
        "method": "GET",
        "scheme": "http",
        "path": "/api/v1/assets/none/download-link",
        "raw_path": b"/api/v1/assets/none/download-link",
        "query_string": b"",
        "root_path": "",
        "server": ("testserver", 80),
        "client": ("127.0.0.1", 54321),
        "headers": [],
        "app": app_obj,
    })


class CallResult:
    """call_download_link 的透出集:响应体 + 各替身,断言写起来不绕。"""

    def __init__(
        self,
        out: Any,
        presign: HeadPresign,
        audit: StubAudit,
        pool: FakeArqPool | None,
        permissions: StubPermissions,
    ) -> None:
        self.out = out
        self.presign = presign
        self.audit = audit
        self.pool = pool
        self.permissions = permissions


async def call_download_link(
    monkeypatch: pytest.MonkeyPatch,
    asset: SimpleNamespace,
    presign: HeadPresign,
    data: DownloadLinkIn | None,
    *,
    pool: FakeArqPool | None = None,
    allowed: bool = True,
    is_system_admin: bool = True,
) -> CallResult:
    """直调 endpoint(绕过 Depends);arq pool 按签名形参名补传(若实现了注入)。"""
    monkeypatch.setattr("app.routers.assets.get_settings", lambda: mk_settings())
    params = inspect.signature(get_download_link).parameters
    permissions = StubPermissions(allowed)
    audit = StubAudit()
    kw: dict[str, Any] = dict(
        request=mk_request(pool),
        data=data,
        db=StubDB(asset),
        permissions=permissions,
        presign=presign,
        audit=audit,
        user=SimpleNamespace(id=uuid.uuid4(), subject="user:u1"),
        is_system_admin=is_system_admin,
        ctx={"request_ip": "127.0.0.1", "user_agent": "pytest"},
    )
    if pool is not None:
        if "arq_pool" in params:
            kw["arq_pool"] = pool
        if "redis" in params:
            kw["redis"] = pool
    out = await get_download_link(asset.id, **kw)
    return CallResult(out, presign, audit, pool, permissions)


def heal_enqueues(pool: FakeArqPool) -> list[dict[str, Any]]:
    return [e for e in pool.enqueued if e["function"] == "generate_livp_download"]


def assert_attachment_basename(cd: str | None, zip_name: str) -> None:
    """disposition 落 基名.zip:纯 ASCII 名走 quoted-string 原名;非 ASCII 名走
    ASCII 兜底 quoted + filename*(RFC5987),与既有 attachment_content_disposition
    契约一致(test_download_attachment.py ③)。"""
    assert cd is not None, "as_attachment 时必须带 disposition"
    assert "attachment" in cd
    if zip_name.isascii():
        assert f'filename="{zip_name}"' in cd, f"文件名须为 {zip_name}: {cd!r}"
    else:
        assert rfc5987_encode(zip_name) in cd, f"filename* 须为 {zip_name}: {cd!r}"
        assert cd == attachment_content_disposition(zip_name), "须与既有 disposition 构造一致"


# ─── variant:就绪 200(URL 指 derivatives zip / attachment 基名.zip / variant)──
async def test_variant_unpacked_ready_signs_zip_with_attachment_basename(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """F3:unpacked+livp 就绪(tag 有 + head 命中)→ 200,URL 指 tags.download_zip_key
    的 zip;as_attachment 时文件名 基名.zip;审计 details.variant;head 先于签发;
    就绪路径不触发自愈。"""
    asset = mk_asset("IMG_0001.livp")
    asset.tags["download_zip_key"] = f"derivatives/{asset.id}/livp.zip"
    asset.tags["download_zip_size_bytes"] = 123
    pool = FakeArqPool()

    r = await call_download_link(
        monkeypatch, asset, HeadPresign(),
        DownloadLinkIn(as_attachment=True, variant="unpacked"), pool=pool,
    )

    assert len(r.presign.calls) == 1
    call = r.presign.calls[0]
    assert call["key"] == f"derivatives/{asset.id}/livp.zip", "URL 必须指向 derivatives zip"
    assert call["bucket"] == asset.minio_bucket
    assert_attachment_basename(call["response_content_disposition"], "IMG_0001.zip")
    # 签发前 head 校验(F3;孤儿 tag 才按缺失走 404)
    assert ["head", call["key"]] in r.presign.ops
    assert r.presign.ops.index(["head", call["key"]]) < r.presign.ops.index(["sign", call["key"]])
    # 审计:与 original 同口径 + details.variant
    issued = r.audit.of_type("signed_url_issued")
    assert len(issued) == 1
    assert issued[0]["details"].get("variant") == "unpacked"
    assert issued[0]["details"].get("expires_in_seconds") == 900
    # 响应形不变:{url, expires_in}
    assert r.out.url == f"https://minio.example/{asset.minio_bucket}/{call['key']}?X-Amz-Signature=fake"
    assert r.out.expires_in == 900
    assert r.out.is_sensitive is False
    assert pool is not None and heal_enqueues(pool) == [], "就绪路径不得触发自愈 enqueue"


async def test_variant_unpacked_chinese_basename_rfc5987(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """F3:中文基名 livp 的 attachment 文件名 = 基名.zip(RFC5987 pct 编码形态)。"""
    asset = mk_asset("实况 A.livp", tags={"download_zip_key": "x"})
    asset.tags["download_zip_key"] = f"derivatives/{asset.id}/livp.zip"

    r = await call_download_link(
        monkeypatch, asset, HeadPresign(),
        DownloadLinkIn(as_attachment=True, variant="unpacked"),
    )

    cd = r.presign.calls[0]["response_content_disposition"]
    assert_attachment_basename(cd, "实况 A.zip")
    # ASCII 兜底 + RFC5987 原名(沿用 attachment_content_disposition 既有契约)
    expected = attachment_content_disposition("实况 A.zip")
    assert cd == expected


async def test_variant_unpacked_inline_has_no_disposition(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """F3:disposition 仅在 as_attachment 时给 基名.zip;默认 inline 签 zip 但无该头。"""
    asset = mk_asset("IMG_0001.livp")
    asset.tags["download_zip_key"] = f"derivatives/{asset.id}/livp.zip"

    r = await call_download_link(
        monkeypatch, asset, HeadPresign(), DownloadLinkIn(variant="unpacked"),
    )

    call = r.presign.calls[0]
    assert call["key"] == f"derivatives/{asset.id}/livp.zip"
    assert call["response_content_disposition"] is None, "inline 不得带 disposition"


async def test_variant_livp_extension_case_insensitive(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """F3:.LIVP 大小写不敏感识别为 livp(非 livp 才 400)。"""
    asset = mk_asset("Holiday.LIVP")
    asset.tags["download_zip_key"] = f"derivatives/{asset.id}/livp.zip"

    r = await call_download_link(
        monkeypatch, asset, HeadPresign(),
        DownloadLinkIn(as_attachment=True, variant="unpacked"),
    )

    assert r.presign.calls[0]["key"] == f"derivatives/{asset.id}/livp.zip"
    assert_attachment_basename(r.presign.calls[0]["response_content_disposition"], "Holiday.zip")


# ─── variant:非 livp 400 ─────────────────────────────────────────────────────
async def test_non_livp_with_unpacked_400(monkeypatch: pytest.MonkeyPatch) -> None:
    """F3:unpacked 仅 livp —— 非 livp + unpacked → 400;不签 URL、不 head、
    不落 signed_url_issued(审计口径不变)。"""
    from fastapi import HTTPException

    asset = mk_asset("clip.mp4")
    presign = HeadPresign()
    audit = StubAudit()
    monkeypatch.setattr("app.routers.assets.get_settings", lambda: mk_settings())

    with pytest.raises(HTTPException) as ei:
        await get_download_link(
            asset.id,
            mk_request(),
            DownloadLinkIn(as_attachment=True, variant="unpacked"),
            db=StubDB(asset),
            permissions=StubPermissions(),
            presign=presign,
            audit=audit,
            user=SimpleNamespace(id=uuid.uuid4(), subject="user:u1"),
            is_system_admin=True,
            ctx={"request_ip": "127.0.0.1", "user_agent": "pytest"},
        )

    assert ei.value.status_code == 400
    assert presign.calls == [] and presign.head_calls == []
    assert audit.of_type("signed_url_issued") == []


# ─── variant:未就绪 404 + 自愈(mock arq pool)────────────────────────────────
async def test_not_ready_404_selfheal_enqueue_contract(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """F3:livp 未就绪(无 download_zip_key)→ 404 且自愈 enqueue 被调:走
    generate_livp_download,_job_id=livpdl:{asset_id}(确定性),_expires≈3600。"""
    from fastapi import HTTPException

    asset = mk_asset("IMG_0001.livp", tags={})
    pool = FakeArqPool()

    with pytest.raises(HTTPException) as ei:
        await call_download_link(
            monkeypatch, asset, HeadPresign(),
            DownloadLinkIn(as_attachment=True, variant="unpacked"), pool=pool,
        )

    assert ei.value.status_code == 404
    calls = heal_enqueues(pool)
    assert len(calls) == 1, "未就绪必须恰好重派一次自愈 job"
    c = calls[0]
    assert c["args"] and str(c["args"][0]) == str(asset.id)
    assert c["kwargs"].get("_job_id") == f"livpdl:{asset.id}", "确定性 job_id(F2)"
    assert c["kwargs"].get("_expires") == 3600, "_expires≈3600(F2)"
    # 频控 SETNX 落键:livpdl:heal:{asset_id},EX 600
    heal_set = [s for s in pool.set_calls if s["name"] == f"livpdl:heal:{asset.id}"]
    assert heal_set and heal_set[0]["nx"] and heal_set[0]["ex"] == 600


async def test_heal_rate_limited_no_redispatch(monkeypatch: pytest.MonkeyPatch) -> None:
    """F3:频控 livpdl:heal:{asset_id} SETNX 已占用 → 仍 404,但同资产不重派。"""
    from fastapi import HTTPException

    asset = mk_asset("IMG_0001.livp", tags={})
    pool = FakeArqPool()
    pool.hold(f"livpdl:heal:{asset.id}")

    with pytest.raises(HTTPException) as ei:
        await call_download_link(
            monkeypatch, asset, HeadPresign(),
            DownloadLinkIn(variant="unpacked"), pool=pool,
        )

    assert ei.value.status_code == 404
    assert heal_enqueues(pool) == [], "频控占用时不得重派(600s 一枚)"


async def test_permanent_failed_tag_no_redispatch(monkeypatch: pytest.MonkeyPatch) -> None:
    """F3:永久失败 tag download_zip_failed 有值 → 404 且不重派(自愈分级闸门:
    永久失败只等回填口径复核,404 自愈不烧 job)。"""
    from fastapi import HTTPException

    asset = mk_asset("IMG_0001.livp", tags={"download_zip_failed": "PillowDecompressionBombError"})
    pool = FakeArqPool()

    with pytest.raises(HTTPException) as ei:
        await call_download_link(
            monkeypatch, asset, HeadPresign(),
            DownloadLinkIn(variant="unpacked"), pool=pool,
        )

    assert ei.value.status_code == 404
    assert heal_enqueues(pool) == [], "永久失败 tag 有值不得重派"


async def test_orphan_tag_head_missing_404_and_selfheal(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """F3:孤儿 tag(tag 在对象不在)→ head 404 按缺失处理 → 404 + 自愈重派。"""
    from fastapi import HTTPException

    asset = mk_asset("IMG_0001.livp")
    asset.tags["download_zip_key"] = f"derivatives/{asset.id}/livp.zip"
    pool = FakeArqPool()
    presign = HeadPresign(head_ok=False)

    with pytest.raises(HTTPException) as ei:
        await call_download_link(
            monkeypatch, asset, presign,
            DownloadLinkIn(variant="unpacked"), pool=pool,
        )

    assert ei.value.status_code == 404
    assert len(heal_enqueues(pool)) == 1, "孤儿 tag 按缺失走自愈重派"
    assert presign.head_calls == [(asset.minio_bucket, f"derivatives/{asset.id}/livp.zip")], (
        "孤儿 tag 判定必须经 head 校验得出"
    )


async def test_heal_setnx_error_still_404(monkeypatch: pytest.MonkeyPatch) -> None:
    """F3:频控 SETNX 异常 → try/except 只 log,照常 404(不得 500 炸给用户)。"""
    from fastapi import HTTPException

    asset = mk_asset("IMG_0001.livp", tags={})
    pool = FakeArqPool()
    pool.set_raises = True

    with pytest.raises(HTTPException) as ei:
        await call_download_link(
            monkeypatch, asset, HeadPresign(),
            DownloadLinkIn(variant="unpacked"), pool=pool,
        )

    assert ei.value.status_code == 404, "SETNX 异常必须被吞掉,照常 404"


# ─── variant:403 与 original 回归 ────────────────────────────────────────────
async def test_forbidden_parity_original_vs_unpacked(monkeypatch: pytest.MonkeyPatch) -> None:
    """F3:权限/审计口径与 original 完全一致 —— 无权限时 original 与 unpacked 均
    403 + download_denied 审计;unpacked 不得在权限判定前泄漏自愈 enqueue。"""
    from fastapi import HTTPException

    for variant in (None, "unpacked"):
        asset = mk_asset("IMG_0001.livp", tags={})
        pool = FakeArqPool()
        presign = HeadPresign()

        with pytest.raises(HTTPException) as ei:
            await call_download_link(
                monkeypatch, asset, presign,
                DownloadLinkIn(as_attachment=True, variant="unpacked") if variant == "unpacked"
                else DownloadLinkIn(as_attachment=True),
                pool=pool, allowed=False, is_system_admin=False,
            )

        assert ei.value.status_code == 403, f"variant={variant!r} 必须 403"
        # 审计经局部重放透出(download_denied 与 original 同形)
        audit = StubAudit()
        with pytest.raises(HTTPException):
            await get_download_link(
                asset.id, mk_request(pool),
                DownloadLinkIn(as_attachment=True, variant="unpacked") if variant == "unpacked"
                else DownloadLinkIn(as_attachment=True),
                db=StubDB(asset), permissions=StubPermissions(allowed=False),
                presign=presign, audit=audit,
                user=SimpleNamespace(id=uuid.uuid4(), subject="user:u1"),
                is_system_admin=False,
                ctx={"request_ip": "127.0.0.1", "user_agent": "pytest"},
            )
        denied = audit.of_type("download_denied")
        assert len(denied) == 1 and denied[0]["target_asset_id"] == asset.id
        assert presign.calls == [], "403 不得签 URL"
        assert heal_enqueues(pool) == [], "403 不得泄漏自愈 enqueue"


async def test_default_and_explicit_original_zero_regression(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """F3:variant 默认 original;不传/显式 original 行为零变化 —— 签原 key、
    无 head、无自愈、审计 details 保持原形 {"expires_in_seconds": 900}。"""
    asset = mk_asset("IMG_0001.livp", tags={})  # 即便是 livp、无 tag,original 照签原 key
    bodies = [
        None,
        DownloadLinkIn(),
        DownloadLinkIn(as_attachment=True),
        DownloadLinkIn(variant="original"),
        DownloadLinkIn(as_attachment=True, variant="original"),
    ]
    for data in bodies:
        pool = FakeArqPool()
        presign = HeadPresign()

        r = await call_download_link(monkeypatch, asset, presign, data, pool=pool)

        assert len(presign.calls) == 1, f"body={data!r}"
        assert presign.calls[0]["key"] == asset.minio_key, "original 必须签原始对象 key"
        assert presign.head_calls == [], "original 不做 head 校验"
        assert heal_enqueues(pool) == [], "original 不触发自愈"
        issued = r.audit.of_type("signed_url_issued")
        assert len(issued) == 1
        assert issued[0]["details"] == {"expires_in_seconds": 900}, (
            f"original 审计 details 零变化: {issued[0]['details']!r}"
        )
        assert r.out.expires_in == 900


# ─── 注册段(F1/F2)───────────────────────────────────────────────────────────
def test_generate_livp_download_registered() -> None:
    """F1/F2:worker 注册 generate_livp_download,timeout=300 / max_tries=2。"""
    fns = {getattr(f, "name", None): f for f in WorkerSettings.functions}
    f = fns.get("generate_livp_download")
    assert f is not None, "WorkerSettings.functions 缺 generate_livp_download 注册"
    assert getattr(f, "timeout_s", None) == 300, "arq Function 属性为 timeout_s(F1)"
    assert getattr(f, "max_tries", None) == 2


async def test_enqueue_livp_download_helper_contract() -> None:
    """F2:enqueue_livp_download(pool, asset_id) → enqueue_job("generate_livp_download",
    asset_id, _job_id="livpdl:{asset_id}", _expires=3600)(确定性 id 在途去重)。"""
    pool = FakeArqPool()
    aid = uuid.uuid4()

    await enqueue_livp_download(pool, str(aid))  # type: ignore[arg-type]

    assert len(pool.enqueued) == 1
    c = pool.enqueued[0]
    assert c["function"] == "generate_livp_download"
    assert str(c["args"][0]) == str(aid)
    assert c["kwargs"].get("_job_id") == f"livpdl:{aid}"
    assert c["kwargs"].get("_expires") == 3600


# ─── share resolve(F4)────────────────────────────────────────────────────────
async def _call_share(
    monkeypatch: pytest.MonkeyPatch,
    asset: SimpleNamespace,
    presign: HeadPresign,
) -> Any:
    """直调 share resolve(绕过 Depends);resolve_share 打桩,审计/设置替换。"""

    async def fake_resolve(db: Any, token: str) -> dict[str, Any]:
        return {
            "kind": "asset",
            "target_id": asset.id,
            "sharer_name": "sharer",
            "expires_at": datetime.now(UTC) + timedelta(days=1),
        }

    monkeypatch.setattr(share_router, "resolve_share", fake_resolve)
    monkeypatch.setattr(share_router, "get_settings", lambda: mk_settings())
    request = Request({
        "type": "http",
        "asgi": {"version": "3.0", "spec_version": "2.3"},
        "http_version": "1.1",
        "method": "GET",
        "scheme": "http",
        "path": "/api/v1/share/tok",
        "raw_path": b"/api/v1/share/tok",
        "query_string": b"",
        "root_path": "",
        "server": ("testserver", 80),
        "client": ("127.0.0.1", 54321),
        "headers": [],
    })
    audit = StubAudit()
    return await share_router.resolve(
        "tok", request,
        db=StubDB(asset),
        permissions=StubPermissions(),
        presign=presign,
        audit=audit,
        user=SimpleNamespace(id=uuid.uuid4(), subject="user:u1"),
        ctx={"request_ip": "127.0.0.1", "user_agent": "pytest"},
    ), audit


async def test_share_ready_livp_signs_zip_marks_unpacked(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """F4:分享 resolve(asset 分支)livp 就绪 → head 校验后签 zip URL(attachment
    基名.zip),审计 details 加 livp_unpacked: true。"""
    asset = mk_asset("IMG_0001.livp")
    asset.tags["download_zip_key"] = f"derivatives/{asset.id}/livp.zip"
    presign = HeadPresign()

    out, audit = await _call_share(monkeypatch, asset, presign)

    call = presign.calls[0]
    assert call["key"] == f"derivatives/{asset.id}/livp.zip", "就绪 livp 分享改签 zip"
    assert_attachment_basename(call["response_content_disposition"], "IMG_0001.zip")
    assert presign.ops.index(["head", call["key"]]) < presign.ops.index(["sign", call["key"]]), (
        "F4:head 校验后签 zip"
    )
    accessed = audit.of_type("share_link_accessed")
    assert len(accessed) == 1
    assert accessed[0]["details"].get("livp_unpacked") is True
    assert out.download_url is not None
    assert out.asset["filename"] == "IMG_0001.livp"


async def test_share_not_ready_livp_original_regression(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """F4:livp 未就绪 → 原始 .livp(回归);审计 livp_unpacked: false。"""
    asset = mk_asset("IMG_0001.livp", tags={})
    presign = HeadPresign()

    out, audit = await _call_share(monkeypatch, asset, presign)

    call = presign.calls[0]
    assert call["key"] == asset.minio_key, "未就绪回落原始 livp"
    assert call["response_content_disposition"] == attachment_content_disposition("IMG_0001.livp")
    accessed = audit.of_type("share_link_accessed")
    assert accessed[0]["details"].get("livp_unpacked") is False
    assert out.download_url is not None


async def test_share_non_livp_unchanged(monkeypatch: pytest.MonkeyPatch) -> None:
    """F4:非 livp 资产分享行为零变化(原始 key + 原名 attachment,livp_unpacked false)。"""
    asset = mk_asset("clip.mp4")
    presign = HeadPresign()

    out, audit = await _call_share(monkeypatch, asset, presign)

    call = presign.calls[0]
    assert call["key"] == asset.minio_key
    assert call["response_content_disposition"] == attachment_content_disposition("clip.mp4")
    assert audit.of_type("share_link_accessed")[0]["details"].get("livp_unpacked") is False
    assert out.download_url is not None
