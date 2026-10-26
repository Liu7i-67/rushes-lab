"""缩略图批量签发端点(POST /api/v1/assets/thumbnail-urls)— 契约测试(T7-T10)。

唯一需求依据:docs/qdev/2026-10-26-app-thumbnail-storm-fix.md「功能点明细」W3
(#13/#14)与「测试功能点」T7-T10。设施沿用仓库单元测试惯例
(test_batch_download_link.py 直调 endpoint + stub 依赖;test_asset_batch_move.py
create_app + ASGITransport + lifespan;不连真 DB / OpenFGA / MinIO;路由级用例
的 lifespan 需 redis/arq/openfga —— 常规在 hh2 dev 容器跑,本地不跑 docker)。

契约要点(文档「契约」节钉死):
  - 入参 ThumbUrlsIn{asset_ids: [uuid] 1..100 必填}(超限 pydantic 入参约束回
    422,风格对齐 BatchDownloadLinkIn);认证同单发端点 get_current_user,
    不做 per-asset FGA
  - 响应 ThumbUrlsOut{urls: [{asset_id, url, expires_in}], missing: [uuid]}:
    urls 只含有 thumbnail_key 的行;missing = 不存在或无 thumbnail_key;
    重复 id 以唯一 id 出;软删行照常返回;request_base 跟随入口;
    响应顺序不保证,App 按 asset_id 匹配
  - 物理:单条 SELECT … WHERE id IN(禁止 N+1);逐行 sign_thumbnail_url
    (本地 HMAC,ttl=1800 与单发同值)

测试函数 → 需求文档「测试功能点」映射(PM 验收对照):
  T7 批量端点正常:N 个有缩略图资产 → urls 全量返回,URL 前缀/形状 +
      expires_in=1800      → test_batch_all_signed_url_shape_and_ttl
  T8 部分 missing:混合无 thumbnail_key / 不存在 → missing 精确;
      重复 id 以唯一 id 出  → test_batch_partial_missing_and_duplicate_ids
  T9 入参与认证:模型级空列表 / 101 个 → ValidationError;路由级 422 / 401
                           → test_model_rejects_empty_and_over_100
                           → test_route_422_and_401
  T10 软删照常返回;单条 IN 查询(假 session 记录 execute 次数 = 1,非 N+1)
                           → test_soft_deleted_returned_and_single_in_query
"""
from __future__ import annotations

import inspect
import uuid
from datetime import UTC, datetime
from types import SimpleNamespace
from typing import Any

import pytest
from httpx import ASGITransport, AsyncClient
from pydantic import ValidationError
from starlette.requests import Request

from app.db.session import get_db
from app.deps import get_current_user, get_presign
from app.main import create_app
from app.routers.assets import ThumbUrlsIn
from app.routers.assets import router as assets_router

# ─── 常量(契约值)─────────────────────────────────────────────────────────────
THUMB_URLS = "/api/v1/assets/thumbnail-urls"
TTL = 1800                       # 30 min — 与单发端点同值
ENTRY_HOST = "thumb-entry.example"
REQUEST_BASE = f"http://{ENTRY_HOST}"   # mk_request Host 头 → request_base_from 产物
THUMB_PREFIX = f"https://{ENTRY_HOST}/ms-thumbs/"


def mk_user(tag: str) -> SimpleNamespace:
    return SimpleNamespace(id=uuid.uuid4(), subject=f"user:{tag}")


def mk_asset(
    *,
    tags: dict[str, Any] | None = None,
    deleted: bool = False,
) -> SimpleNamespace:
    """资产行替身:deleted=True 模拟软删(回收站行,deleted_at 置位)。"""
    return SimpleNamespace(
        id=uuid.uuid4(),
        deleted_at=datetime.now(UTC) if deleted else None,
        tags=tags if tags is not None else {},
    )


def mk_with_thumb() -> SimpleNamespace:
    return mk_asset(tags={"thumbnail_key": f"derivatives/{uuid.uuid4().hex}/thumb.jpg"})


def fld(obj: Any, name: str) -> Any:
    """响应字段读取(直调返回 pydantic 模型或 dict,两种都兜住)。"""
    if isinstance(obj, dict):
        return obj.get(name)
    return getattr(obj, name)


# ─── presign / db 替身 ────────────────────────────────────────────────────────
class ThumbPresign:
    """presign 替身:只实现 sign_thumbnail_url,记录每次调用;URL 形态钉死
    入口 host + /ms-thumbs/ 前缀(nginx 按路径分流的既有约定)。"""

    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []

    def sign_thumbnail_url(
        self, key: str, expires_seconds: int, request_base: str | None = None
    ) -> str:
        self.calls.append({
            "key": key,
            "expires_seconds": expires_seconds,
            "request_base": request_base,
        })
        return f"{THUMB_PREFIX}{key}?X-Amz-Signature=fake&X-Amz-Expires={expires_seconds}"


class FakeResult:
    def __init__(self, rows: list[Any]) -> None:
        self._rows = list(rows)

    def scalars(self) -> FakeResult:
        return self

    def all(self) -> list[Any]:
        return list(self._rows)


def _stmt_in_ids(stmt: Any) -> set[Any]:
    """从语句编译参数提取 IN 绑定值(替身按真实请求 id 过滤返回行 —— 不在请求
    id 集内的预置行不返回,防替身送错行掩盖实现缺陷;编译失败视作空集)。"""
    try:
        params = stmt.compile().params
    except Exception:  # noqa: BLE001  替身宽容:编译不可用 → 空集(全部视为不存在)
        return set()
    wanted: set[Any] = set()
    for v in params.values():
        if isinstance(v, (list, tuple, set)):
            wanted.update(v)
        else:
            wanted.add(v)
    return wanted


class FakeDB:
    """db 替身:execute 记录每次调用(T10 非 N+1 断言:次数 == 1)并按 IN 参数
    过滤预置行;不在预置集 = 不存在。"""

    def __init__(self, assets: list[Any]) -> None:
        self._assets = list(assets)
        self.executed: list[Any] = []

    async def execute(self, stmt: Any, *a: Any, **kw: Any) -> FakeResult:
        self.executed.append(stmt)
        wanted = _stmt_in_ids(stmt)
        return FakeResult([a for a in self._assets if a.id in wanted])


# ─── 端点直调(函数名无关:经路由表解析,先例 test_batch_download_link.py)────
def _thumbnail_urls_endpoint_fn() -> Any:
    for route in assets_router.routes:
        path = getattr(route, "path", "")
        methods = {str(m).upper() for m in (getattr(route, "methods", None) or set())}
        if path.endswith("/thumbnail-urls") and "POST" in methods:
            return route.endpoint
    raise LookupError("路由 POST /api/v1/assets/thumbnail-urls 未注册 —— 批量端点代码未就位")


def mk_request() -> Request:
    """直调用 Request:Host 头钉死入口 host(request_base 跟随入口断言用)。"""
    return Request({
        "type": "http",
        "asgi": {"version": "3.0", "spec_version": "2.3"},
        "http_version": "1.1",
        "method": "POST",
        "scheme": "http",
        "path": THUMB_URLS,
        "raw_path": THUMB_URLS.encode(),
        "query_string": b"",
        "root_path": "",
        "server": ("testserver", 80),
        "client": ("127.0.0.1", 54321),
        "headers": [(b"host", ENTRY_HOST.encode())],
        "app": SimpleNamespace(state=SimpleNamespace()),
    })


class ThumbCall:
    def __init__(self, out: Any, db: FakeDB, presign: ThumbPresign) -> None:
        self.out = out
        self.db = db
        self.presign = presign


async def call_thumbnail_urls(
    ids: list[uuid.UUID],
    *,
    user: Any,
    assets: list[Any],
    presign: ThumbPresign | None = None,
) -> ThumbCall:
    """直调批量端点:按形参名填 stub,不认识的必选形参显式报错(seam 需对齐)。"""
    fn = _thumbnail_urls_endpoint_fn()
    presign = presign if presign is not None else ThumbPresign()
    db = FakeDB(assets)
    kw: dict[str, Any] = {}
    for name, p in inspect.signature(fn).parameters.items():
        if name == "payload" or name in ("data", "body"):
            kw[name] = ThumbUrlsIn(asset_ids=list(ids))
        elif name == "request":
            kw[name] = mk_request()
        elif name == "db":
            kw[name] = db
        elif name == "presign":
            kw[name] = presign
        elif name == "user":
            kw[name] = user
        elif p.default is inspect.Parameter.empty:
            raise LookupError(f"批量端点出现无法满足的必选形参 {name!r}(seam 需对齐)")
    out = await fn(**kw)
    return ThumbCall(out, db, presign)


# ─── T7 批量端点正常 ──────────────────────────────────────────────────────────
async def test_batch_all_signed_url_shape_and_ttl() -> None:
    """T7:N 个有缩略图资产 → urls 全量返回;URL 前缀/形状(入口 host +
    /ms-thumbs/ + key + 签名)+ expires_in=1800;签名 ttl 与 request_base
    (跟随入口)逐条与单发同拍。"""
    a = mk_with_thumb()
    b = mk_with_thumb()

    out = await call_thumbnail_urls([a.id, b.id], user=mk_user("t7"), assets=[a, b])

    urls = fld(out.out, "urls")
    got = {str(fld(u, "asset_id")): u for u in urls}
    assert set(got) == {str(a.id), str(b.id)}, "有 thumbnail_key 的行全量签发"
    key_of = {str(a.id): a.tags["thumbnail_key"], str(b.id): b.tags["thumbnail_key"]}
    for aid, entry in got.items():
        url = fld(entry, "url")
        assert url.startswith(THUMB_PREFIX), f"URL 前缀(入口 host + /ms-thumbs/): {url!r}"
        assert key_of[aid] in url and "X-Amz-Signature" in url, f"URL 形状(key+签名): {url!r}"
        assert fld(entry, "expires_in") == TTL, "expires_in 与单发同值(30 min)"
    assert fld(out.out, "missing") == [], "全部命中时 missing 为空"
    # 逐条 sign_thumbnail_url:ttl=1800、request_base 跟随入口(Host 头)
    assert len(out.presign.calls) == 2
    assert all(c["expires_seconds"] == TTL for c in out.presign.calls)
    assert all(c["request_base"] == REQUEST_BASE for c in out.presign.calls)


# ─── T8 部分 missing + 重复 id 归一 ───────────────────────────────────────────
async def test_batch_partial_missing_and_duplicate_ids() -> None:
    """T8:混合无 thumbnail_key / 不存在资产 → missing 精确;重复 id 以唯一 id
    出(urls 恰一条、只签一次)。"""
    ok = mk_with_thumb()
    no_key = mk_asset(tags={})       # 无 key(还没生成 / 非图片)
    ghost = mk_asset()               # 不入 db 预置集 = 不存在

    out = await call_thumbnail_urls(
        [ok.id, no_key.id, ghost.id, ok.id],        # ok.id 重复提交
        user=mk_user("t8"),
        assets=[ok, no_key],
    )

    url_ids = [str(fld(u, "asset_id")) for u in fld(out.out, "urls")]
    assert url_ids == [str(ok.id)], "重复 id 归一:urls 恰一条唯一 id"
    missing = {str(m) for m in fld(out.out, "missing")}
    assert missing == {str(no_key.id), str(ghost.id)}, "无 key 与不存在都进 missing"
    assert len(out.presign.calls) == 1, "重复 id 只签一次"


# ─── T9 入参与认证(模型级 + 路由级)─────────────────────────────────────────
def test_model_rejects_empty_and_over_100() -> None:
    """T9(模型级):asset_ids 空列表 / 101 个 → pydantic ValidationError;
    恰 100 个放行(风格对齐 BatchDownloadLinkIn 的 1..100 约束)。"""
    with pytest.raises(ValidationError) as ei:
        ThumbUrlsIn(asset_ids=[])
    assert "asset_ids" in str(ei.value)

    with pytest.raises(ValidationError):
        ThumbUrlsIn(asset_ids=[uuid.uuid4() for _ in range(101)])

    ok = ThumbUrlsIn(asset_ids=[uuid.uuid4() for _ in range(100)])
    assert len(ok.asset_ids) == 100


@pytest.fixture(scope="session")
async def app_with_lifespan():
    """先例 test_asset_batch_move.py:app.state 仅 lifespan 设置,裸 client 会 500。"""
    app = create_app()
    async with app.router.lifespan_context(app):  # type: ignore[attr-defined]
        yield app


async def test_route_422_and_401(app_with_lifespan: Any) -> None:
    """T9(路由级):无认证 → 401(真 get_current_user,合法 body);auth/presign/db
    以 dependency_overrides 注入 stub 后,超限 101 / 空列表 → 422(入参约束)。"""
    transport = ASGITransport(app=app_with_lifespan)  # type: ignore[arg-type]
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        # 401:不带 cookie / X-User-Id 直打(合法 body,只有认证可挂)
        r = await ac.post(THUMB_URLS, json={"asset_ids": [str(uuid.uuid4())]})
        assert r.status_code == 401, f"无认证必须 401: {r.status_code} {r.text}"

        # 422:认证/依赖注入 stub 后,只有入参约束可挂
        async def fake_db():
            yield FakeDB([])

        app_with_lifespan.dependency_overrides[get_current_user] = lambda: mk_user("t9")
        app_with_lifespan.dependency_overrides[get_presign] = ThumbPresign
        app_with_lifespan.dependency_overrides[get_db] = fake_db
        try:
            r = await ac.post(
                THUMB_URLS,
                json={"asset_ids": [str(uuid.uuid4()) for _ in range(101)]},
            )
            assert r.status_code == 422, f"101 个超限必须 422: {r.status_code} {r.text}"
            r = await ac.post(THUMB_URLS, json={"asset_ids": []})
            assert r.status_code == 422, f"空列表必须 422: {r.status_code} {r.text}"
        finally:
            app_with_lifespan.dependency_overrides.clear()


# ─── T10 软删照常返回 + 单条 IN 查询(非 N+1)─────────────────────────────────
async def test_soft_deleted_returned_and_single_in_query() -> None:
    """T10:软删(deleted_at 置位)行照常签发(回收站缩略图与单发同口径);
    一次请求只发单条 SELECT … WHERE id IN —— 假 session 记录 execute 次数 = 1,
    逐资产 db.get 的 N+1 实现在此必红。"""
    alive = mk_with_thumb()
    trashed = mk_with_thumb()
    trashed.deleted_at = datetime.now(UTC)

    out = await call_thumbnail_urls(
        [alive.id, trashed.id], user=mk_user("t10"), assets=[alive, trashed],
    )

    url_ids = {str(fld(u, "asset_id")) for u in fld(out.out, "urls")}
    assert url_ids == {str(alive.id), str(trashed.id)}, "软删行照常返回"
    assert fld(out.out, "missing") == []
    assert len(out.presign.calls) == 2
    assert len(out.db.executed) == 1, (
        f"必须单条 IN 查询(非 N+1): execute 次数 = {len(out.db.executed)}"
    )
    assert " IN " in str(out.db.executed[0]).upper(), "查询形态是 WHERE id IN (…)"
