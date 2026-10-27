"""单发/批量缩略图 URL 端点 size 参数 + presign cache_control — 契约测试。

唯一需求依据:docs/qdev/2026-10-27-thumb-variant-video-cover.md §3.2/§3.3 与
「测试功能点」7/8。设施沿用 tests/test_thumbnail_urls_batch.py 的直调 + stub
风格(不连真 DB / MinIO / Redis / OpenFGA;端点经路由表按路径解析,函数名无关)。

测试函数 → 需求文档「测试功能点」映射(PM 验收对照):
  功能点7 单发 size=small 有 small key → 签 {…}_s.jpg + variant=small
                                   → test_single_small_key_signs_small_variant
  功能点7 单发 size=small 无 small key → 回落签 large + variant=large
                                   → test_single_small_missing_falls_back_large
  功能点7 单发 size=large/缺省 → 现行为(签 thumbnail_key,variant=large)
                                   → test_single_large_or_default_unchanged
  功能点7 单发无 thumbnail_key → 404(契约不变)
                                   → test_single_no_thumbnail_key_404
  功能点7 批量 body size 生效 + 响应含 variant + missing/去重/上限 100 不变
                                   → test_batch_body_size_small_effective
                                   → test_batch_default_large_ignores_small_key
                                   → test_batch_invariants_unchanged_with_size_field
  功能点8 presign cache_control 传入 → presigned params 含 ResponseCacheControl
         (URL 可见 response-cache-control);不传 → 不含;live-preview-url 调用不含
                                   → test_presign_sign_thumbnail_url_cache_control
                                   → test_live_preview_call_passes_no_cache_control
"""
from __future__ import annotations

import inspect
import os
import uuid
from types import SimpleNamespace
from typing import Any
from urllib.parse import parse_qs, urlparse

# app.workers.main / app.main 在模块导入期即构造 Settings(get_settings 缓存),
# 无 conftest 注入点 —— 按仓库惯例在此 setdefault 环境桩(本文件与后续导入的
# test_thumbnail_urls_batch.py 共享同一缓存 Settings,值仅需可构造、不触网)
for _k, _v in {
    "DB_URL": "postgresql+asyncpg://u:p@localhost/db",
    "REDIS_URL": "redis://localhost:6379/0",
    "MINIO_ENDPOINT_INTERNAL": "http://minio:9000",
    "MINIO_ENDPOINT_PUBLIC": "http://localhost:9000",
    "MINIO_ACCESS_KEY": "k",
    "MINIO_SECRET_KEY": "s",
    "OPENFGA_API_URL": "http://openfga:8080",
    "OPENFGA_STORE_ID": "01TEST",
    "WEB_APP_BASE_URL": "http://localhost/ms-static/web/",
    "SESSION_JWT_SECRET": "test-secret-0123456789abcdef",
}.items():
    os.environ.setdefault(_k, _v)

import pytest  # noqa: E402
from fastapi import HTTPException  # noqa: E402
from pydantic import ValidationError  # noqa: E402
from starlette.requests import Request  # noqa: E402

from app.routers.assets import ThumbUrlsIn  # noqa: E402
from app.routers.assets import router as assets_router  # noqa: E402
from app.services.presign import PresignService  # noqa: E402
from app.settings import get_settings  # noqa: E402

# ─── 常量(契约值)─────────────────────────────────────────────────────────────
TTL = 1800
CACHE_CONTROL = "public, max-age=604800"
ENTRY_HOST = "thumb-entry.example"
THUMB_PREFIX = f"https://{ENTRY_HOST}/ms-thumbs/"


def mk_user() -> SimpleNamespace:
    return SimpleNamespace(id=uuid.uuid4())


def mk_asset(tags: dict[str, Any]) -> SimpleNamespace:
    return SimpleNamespace(id=uuid.uuid4(), tags=tags)


def mk_request() -> Request:
    """直调用 Request:Host 头钉死入口 host(request_base 跟随入口断言用)。"""
    path = "/api/v1/assets/x"
    return Request({
        "type": "http",
        "asgi": {"version": "3.0", "spec_version": "2.3"},
        "http_version": "1.1",
        "method": "GET",
        "scheme": "http",
        "path": path,
        "raw_path": path.encode(),
        "query_string": b"",
        "root_path": "",
        "server": ("testserver", 80),
        "client": ("127.0.0.1", 54321),
        "headers": [(b"host", ENTRY_HOST.encode())],
        "app": SimpleNamespace(state=SimpleNamespace()),
    })


# ─── 替身 ────────────────────────────────────────────────────────────────────
class RecordingPresign:
    """presign 替身:记录 sign_thumbnail_url 全部入参;URL 反映 cache_control
    (有则带 response-cache-control 查询参数,与真 presign 行为同拍)。"""

    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []

    def sign_thumbnail_url(
        self, key: str, expires_seconds: int, request_base: str | None = None,
        cache_control: str | None = None,
    ) -> str:
        self.calls.append({
            "key": key, "expires_seconds": expires_seconds,
            "request_base": request_base, "cache_control": cache_control,
        })
        url = f"{THUMB_PREFIX}{key}?X-Amz-Signature=fake&X-Amz-Expires={expires_seconds}"
        if cache_control is not None:
            from urllib.parse import quote
            url += f"&response-cache-control={quote(cache_control)}"
        return url


class SingleDB:
    def __init__(self, asset: Any) -> None:
        self._asset = asset

    async def get(self, model: Any, pk: Any) -> Any:
        return self._asset


class FakeResult:
    def __init__(self, rows: list[Any]) -> None:
        self._rows = rows

    def scalars(self) -> FakeResult:
        return self

    def all(self) -> list[Any]:
        return list(self._rows)


class BatchDB:
    """批量端点 db 替身:按语句 IN 绑定值过滤预置行(不在集 = 不存在)。"""

    def __init__(self, assets: list[Any]) -> None:
        self._assets = assets

    async def execute(self, stmt: Any, *a: Any, **kw: Any) -> FakeResult:
        wanted: set[Any] = set()
        try:
            for v in stmt.compile().params.values():
                if isinstance(v, (list, tuple, set)):
                    wanted.update(v)
                else:
                    wanted.add(v)
        except Exception:  # 替身宽容:编译不可用 → 全部视为不存在
            pass
        return FakeResult([a for a in self._assets if a.id in wanted])


def _endpoint(method: str, suffix: str) -> Any:
    for route in assets_router.routes:
        path = getattr(route, "path", "")
        methods = {str(m).upper() for m in (getattr(route, "methods", None) or set())}
        if path.endswith(suffix) and method in methods:
            return route.endpoint
    raise LookupError(f"路由 {method} …{suffix} 未注册 —— 端点代码未就位")


def _fill_kwargs(fn: Any, spec: dict[str, Any]) -> dict[str, Any]:
    """按形参名填 stub;无法满足的必选形参显式报错(seam 需对齐)。"""
    kw: dict[str, Any] = {}
    for name, p in inspect.signature(fn).parameters.items():
        if name in spec:
            kw[name] = spec[name]
        elif p.default is inspect.Parameter.empty:
            raise LookupError(f"端点出现无法满足的必选形参 {name!r}(seam 需对齐)")
    return kw


async def call_single(
    asset: SimpleNamespace, *, size: str | None = None,
    presign: RecordingPresign | None = None,
) -> tuple[dict[str, Any], RecordingPresign]:
    """直调单发端点 GET /{asset_id}/thumbnail-url;size=None 表示不传(缺省)。"""
    fn = _endpoint("GET", "/thumbnail-url")
    presign = presign if presign is not None else RecordingPresign()
    spec: dict[str, Any] = {
        "asset_id": asset.id, "request": mk_request(), "db": SingleDB(asset),
        "presign": presign, "user": mk_user(),
    }
    if size is not None:
        spec["size"] = size
    return await fn(**_fill_kwargs(fn, spec)), presign


async def call_batch(
    assets: list[SimpleNamespace], ids: list[uuid.UUID], *, size: str | None = None,
    presign: RecordingPresign | None = None,
) -> tuple[Any, RecordingPresign]:
    """直调批量端点 POST /thumbnail-urls;size=None → 模型缺省(large)。"""
    fn = _endpoint("POST", "/thumbnail-urls")
    presign = presign if presign is not None else RecordingPresign()
    payload_kw = ThumbUrlsIn(asset_ids=list(ids)) if size is None else \
        ThumbUrlsIn(asset_ids=list(ids), size=size)
    spec: dict[str, Any] = {
        "payload": payload_kw, "data": payload_kw, "body": payload_kw,
        "request": mk_request(), "db": BatchDB(assets),
        "presign": presign, "user": mk_user(),
    }
    return await fn(**_fill_kwargs(fn, spec)), presign


# ─── 功能点7 单发端点 size 参数 ───────────────────────────────────────────────
async def test_single_small_key_signs_small_variant() -> None:
    """size=small 且有 thumbnail_small_key → 签 {…}_s.jpg + variant=small;
    TTL 1800、request_base 跟随入口、cache_control 契约值均不变。"""
    aid = uuid.uuid4()
    small_key, large_key = f"thumbnails/{aid}_s.jpg", f"thumbnails/{aid}.jpg"
    out, presign = await call_single(
        mk_asset({"thumbnail_key": large_key, "thumbnail_small_key": small_key}),
        size="small",
    )
    assert out["variant"] == "small", "variant=实际签发对象规格"
    assert out["expires_in"] == TTL
    assert small_key in out["url"] and large_key not in out["url"]
    assert out["url"].startswith(THUMB_PREFIX)
    assert len(presign.calls) == 1
    c = presign.calls[0]
    assert c["key"] == small_key and c["expires_seconds"] == TTL
    assert c["request_base"] == f"http://{ENTRY_HOST}"
    assert c["cache_control"] == CACHE_CONTROL, "签发时传 cache_control(§3.2)"


async def test_single_small_missing_falls_back_large() -> None:
    """size=small 但无 small key → 回落签 thumbnail_key(large),variant=large;
    不 404(回落让三端切换与存量回补解耦,§3.2)。"""
    aid = uuid.uuid4()
    large_key = f"thumbnails/{aid}.jpg"
    out, presign = await call_single(mk_asset({"thumbnail_key": large_key}), size="small")
    assert out["variant"] == "large"
    assert large_key in out["url"]
    assert presign.calls[0]["key"] == large_key


async def test_single_large_or_default_unchanged() -> None:
    """size=large / 缺省 → 现行为:签 thumbnail_key,variant=large;已有 small
    key 也不影响 large 请求。"""
    aid = uuid.uuid4()
    small_key, large_key = f"thumbnails/{aid}_s.jpg", f"thumbnails/{aid}.jpg"
    asset = mk_asset({"thumbnail_key": large_key, "thumbnail_small_key": small_key})
    for size in (None, "large"):
        out, presign = await call_single(asset, size=size)
        assert out["variant"] == "large", f"size={size!r} → variant=large"
        assert large_key in out["url"] and small_key not in out["url"]
        assert presign.calls[0]["key"] == large_key


async def test_single_no_thumbnail_key_404() -> None:
    """无 thumbnail_key(还没生成 / 非图片)→ 404,与 size 无关(契约不变)。"""
    with pytest.raises(HTTPException) as ei:
        await call_single(mk_asset({}), size="small")
    assert ei.value.status_code == 404
    with pytest.raises(HTTPException) as ei:
        await call_single(mk_asset({}))
    assert ei.value.status_code == 404


# ─── 功能点7 批量端点 body size ───────────────────────────────────────────────
async def test_batch_body_size_small_effective() -> None:
    """body size=small 生效:有 small key → 签 small + variant=small;无 small
    key → 回落 large + variant=large;无 thumbnail_key → missing;每项含 variant。"""
    a = mk_asset({"thumbnail_key": "thumbnails/a.jpg", "thumbnail_small_key": "thumbnails/a_s.jpg"})
    b = mk_asset({"thumbnail_key": "thumbnails/b.jpg"})
    c = mk_asset({})

    out, presign = await call_batch([a, b, c], [a.id, b.id, c.id], size="small")

    entries = {str(e.asset_id): e for e in out.urls}
    assert set(entries) == {str(a.id), str(b.id)}, "无 key 行进 missing"
    assert entries[str(a.id)].variant == "small"
    assert "thumbnails/a_s.jpg" in entries[str(a.id)].url
    assert entries[str(b.id)].variant == "large", "缺 small 回落 large"
    assert "thumbnails/b.jpg" in entries[str(b.id)].url
    assert {str(m) for m in out.missing} == {str(c.id)}
    assert [c["key"] for c in presign.calls] == ["thumbnails/a_s.jpg", "thumbnails/b.jpg"]


async def test_batch_default_large_ignores_small_key() -> None:
    """缺省 size=large:两 key 齐全也只签 thumbnail_key(现行为零变化)。"""
    a = mk_asset({"thumbnail_key": "thumbnails/a.jpg", "thumbnail_small_key": "thumbnails/a_s.jpg"})
    out, presign = await call_batch([a], [a.id])
    assert out.urls[0].variant == "large"
    assert "thumbnails/a.jpg" in out.urls[0].url
    assert presign.calls[0]["key"] == "thumbnails/a.jpg"


async def test_batch_invariants_unchanged_with_size_field() -> None:
    """size 字段加入后,missing/去重/上限 100/入参约束语义不变(T7-T10 回归)。"""
    ok = mk_asset({"thumbnail_key": "thumbnails/ok.jpg", "thumbnail_small_key": "thumbnails/ok_s.jpg"})
    no_key = mk_asset({})
    # 去重 + missing:重复 id 只签一次,size=small 下同样成立
    out, presign = await call_batch([ok, no_key], [ok.id, no_key.id, ok.id], size="small")
    assert [str(e.asset_id) for e in out.urls] == [str(ok.id)]
    assert {str(m) for m in out.missing} == {str(no_key.id)}
    assert len(presign.calls) == 1
    # 上限 100 放行 / 101 拒绝 / 非法 size 字面量拒绝(Literal 约束)
    assert len(ThumbUrlsIn(asset_ids=[uuid.uuid4() for _ in range(100)]).asset_ids) == 100
    with pytest.raises(ValidationError):
        ThumbUrlsIn(asset_ids=[uuid.uuid4() for _ in range(101)])
    with pytest.raises(ValidationError):
        ThumbUrlsIn(asset_ids=[uuid.uuid4()], size="medium")  # type: ignore[arg-type]
    with pytest.raises(ValidationError):
        ThumbUrlsIn(asset_ids=[])


# ─── 功能点8 presign cache_control ───────────────────────────────────────────
def test_presign_sign_thumbnail_url_cache_control() -> None:
    """真 PresignService(纯本地签名,不触网):cache_control 传入 → presigned
    params 含 ResponseCacheControl(URL 可见 response-cache-control);不传 →
    params 与旧版完全一致(不含)。"""
    svc = PresignService(get_settings())
    with_cc = svc.sign_thumbnail_url(
        "thumbnails/x.jpg", TTL, cache_control=CACHE_CONTROL,
    )
    without_cc = svc.sign_thumbnail_url("thumbnails/x.jpg", TTL)

    q_with = parse_qs(urlparse(with_cc).query)
    assert q_with.get("response-cache-control") == [CACHE_CONTROL], (
        f"ResponseCacheControl 应进 presigned params: {with_cc}"
    )
    q_without = parse_qs(urlparse(without_cc).query)
    assert not any("cache" in k for k in q_without), "默认 None 不含该参数"
    assert q_without.get("X-Amz-Expires") == [str(TTL)]


async def test_live_preview_call_passes_no_cache_control() -> None:
    """live-preview-url 调用点不传 cache_control(§3.3:livp 实况短片会被重跑
    覆盖,不缓存)→ 签出的 URL 无 response-cache-control;权限/审计语义不变。"""
    from app.db.session import get_db
    from app.deps import get_presign

    live_key = f"previews/{uuid.uuid4()}_live.mp4"
    folder_id, project_id = uuid.uuid4(), uuid.uuid4()
    asset = SimpleNamespace(
        id=uuid.uuid4(), deleted_at=None, folder_id=folder_id, minio_key="p/a.livp",
        tags={"live_video_key": live_key},
    )
    folder = SimpleNamespace(project_id=project_id)

    class LiveDB:
        async def get(self, model: Any, pk: Any) -> Any:
            return asset if model.__name__ == "Asset" else folder

    class Perms:
        async def check(self, **kw: Any) -> bool:
            return True

    class Audit:
        async def signed_url_issued(self, **kw: Any) -> None:
            return None

    presign = RecordingPresign()
    fn = _endpoint("GET", "/live-preview-url")
    spec: dict[str, Any] = {
        "asset_id": asset.id, "request": mk_request(), "db": LiveDB(),
        "permissions": Perms(), "presign": presign, "audit": Audit(),
        "user": mk_user(), "is_system_admin": True, "ctx": {},
    }
    # 未注入的依赖走 app.deps 真默认值也不触网:user/db 仅在直通分支前消费
    _ = get_db, get_presign
    out = await fn(**_fill_kwargs(fn, spec))
    assert live_key in out["url"] and out["expires_in"] == TTL
    assert "response-cache-control" not in out["url"], "live-preview 不带缓存头"
    assert presign.calls[0]["cache_control"] is None, "调用点未传 cache_control"
    assert presign.calls[0]["key"] == live_key
