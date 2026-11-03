"""AI 端点 + 搜索第四路 + 上下文钩子(API 层)测试。

唯一需求依据:docs/qdev/2026-11-03-ai-tagging-slicing.md §2.6/§2.7;方案正本
rushes-spec/material-storage/ai-tagging-slicing-plan.md §11(搜索两臂合并)/§12
(端点与权限口径)/§8.6(上下文钩子)。

设施沿用仓库单元测试惯例(test_thumbnail_urls_batch / test_batch_download_link:
直调 endpoint + stub 依赖 + FakeDB 记录语句;不连真 DB / OpenFGA / MinIO /
Redis)。Settings 经 get_settings() 单例 monkeypatch 翻转 ai_enabled / active
版本(进程内,不查库)。

测试 → 验收映射:
  搜索 off 态 stmt 形状(硬验收:SQL 与现状逐字节一致)   → test_search_off_stmt_shape_baseline
  搜索 off 态行为等价(结果映射不变)                     → test_search_off_behavior_equivalence
  on 态臂 A/臂 B 语句形状(tiebreak/LIMIT/active 版本)    → test_search_on_stmt_shape_two_arms
  on 态两臂合并:重叠去重(臂 A 优先)                     → test_search_on_merge_dedup_arm_a_priority
  on 态排序 + 深分页 offset=2                             → test_search_on_sort_and_deep_pagination_offset2
  sensitive 零泄露(mock folder 集合,沿既有口径)          → test_search_on_sensitive_zero_leak
  public 项目非敏感夹豁免并入两臂过滤                     → test_search_on_public_exemption_in_filter
  GET /ai 三态权限(admin / public 豁免 / 无权 404)       → test_get_ai_permission_tri_state
  GET /ai 软删 404 + 不存在 404                           → test_get_ai_missing_and_soft_deleted_404
  GET /ai enabled=false → 404(总开关急停)                → test_get_ai_disabled_404
  GET /ai 空(annotation,segments)= null → 200            → test_get_ai_no_annotation_null_200
  GET /ai 契约形状(keyframe_count 不回 key 明细)          → test_get_ai_payload_shape
  keyframe-urls ≤10 闸(422 源)                           → test_keyframe_urls_over_10_422
  keyframe-urls 无效 idx 跳过 + 签发形状(TTL/入口 host)   → test_keyframe_urls_invalid_idx_skipped
  keyframe-urls 每请求一条 signed_url_issued 审计          → test_keyframe_urls_audit_one_row
  restore 钩子:删 skipped(asset_gone) + 补 pending 行重派 → test_restore_hook_restock
  restore 钩子:视频 slice 行被删 → 恢复后重建 + 按类派发   → test_restore_hook_restocks_slice_row
  restore 钩子 ai_enabled=false 零行为                    → test_restore_hook_disabled_noop
  restore 端点成功路径挂点(钩子必经 + pool 注入)          → test_restore_endpoint_hook_wiring
  batch_prefix 钩子触发 refresh(asset_ids 直传)           → test_batch_prefix_hook_triggers_refresh
  batch_move 钩子触发 refresh(moved ids)                 → test_batch_move_hook_triggers_refresh
  >500 分批派发语义(enqueue_ai_refresh_for_assets)       → test_refresh_for_assets_chunking_over_500
  update_folder 挂点存在(folder 子树模式)                 → test_update_folder_hook_call_site
  refresh 派发口径(_job_id / queue / worker 签名对齐)     → test_refresh_job_id_shape
"""
from __future__ import annotations

import inspect
import os
import uuid
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace
from typing import Any

import pytest
from pydantic import ValidationError
from sqlalchemy import Select

# settings 环境桩(单文件运行兜底):键集与 test_ai_chain_mount.py /
# test_ai_pipeline_grading.py 逐字一致 —— get_settings() 在 fixture 期实例化
# Settings,无 .env 的机器上缺必填键会让本文件用例集体 fixture error。
for _k, _v in {
    "DB_URL": "postgresql+asyncpg://u:p@localhost/db", "REDIS_URL": "redis://localhost:6379/0",
    "MINIO_ENDPOINT_INTERNAL": "http://minio:9000", "MINIO_ENDPOINT_PUBLIC": "http://localhost:9000",
    "MINIO_ACCESS_KEY": "k", "MINIO_SECRET_KEY": "s",
    "OPENFGA_API_URL": "http://openfga:8080", "OPENFGA_STORE_ID": "01TEST",
    "WEB_APP_BASE_URL": "http://localhost/ms-static/web/",
    "SESSION_JWT_SECRET": "test-secret-0123456789abcdef",
}.items():
    os.environ.setdefault(_k, _v)

from app.db.tables import Asset, Folder, Project  # noqa: E402
from app.models import SearchResultOut  # noqa: E402
from app.routers import ai_assets as ai_router  # noqa: E402
from app.routers import assets as assets_router  # noqa: E402
from app.routers import folders as folders_router  # noqa: E402
from app.routers.ai_assets import AssetAiOut, KeyframeUrlsIn, enqueue_ai_refresh_for_assets  # noqa: E402
from app.settings import get_settings  # noqa: E402

ACTIVE = "smolvlm2-256m@p1+lm1"


# ─── stub 工厂(test_thumbnail_urls_batch 同款手法)───────────────────────────
def mk_user(tag: str) -> SimpleNamespace:
    return SimpleNamespace(id=uuid.uuid4(), subject=f"user:{tag}")


def mk_asset(
    *,
    folder_id: uuid.UUID | None = None,
    deleted: bool = False,
    created_at: datetime | None = None,
    filename: str = "a.jpg",
) -> SimpleNamespace:
    return SimpleNamespace(
        id=uuid.uuid4(),
        folder_id=folder_id or uuid.uuid4(),
        filename=filename,
        minio_bucket="ms-dev",
        minio_key=f"proj/{filename}",
        etag=None,
        minio_version_id=None,
        size_bytes=11,
        content_type="image/jpeg",
        created_at=created_at or datetime.now(UTC),
        deleted_at=datetime.now(UTC) if deleted else None,
        tags={},
        user_labels=[],
        notes=None,
    )


def mk_folder(*, sensitive: bool = False, project_id: uuid.UUID | None = None,
              parent_folder_id: uuid.UUID | None = None) -> SimpleNamespace:
    return SimpleNamespace(
        id=uuid.uuid4(),
        project_id=project_id or uuid.uuid4(),
        is_sensitive=sensitive,
        parent_folder_id=parent_folder_id,
        minio_prefix="proj",
    )


def mk_request(pool: Any = None) -> Any:
    """直调用 Request:Host 头钉死(request_base 断言用),app.state.arq_pool 可注入。"""
    from starlette.requests import Request

    return Request({
        "type": "http",
        "asgi": {"version": "3.0", "spec_version": "2.3"},
        "http_version": "1.1",
        "method": "POST",
        "scheme": "http",
        "path": "/api/v1/assets/x",
        "raw_path": b"/api/v1/assets/x",
        "query_string": b"",
        "root_path": "",
        "server": ("testserver", 80),
        "client": ("127.0.0.1", 54321),
        "headers": [(b"host", b"entry.example")],
        "app": SimpleNamespace(state=SimpleNamespace(arq_pool=pool)),
    })


CTX = {"request_ip": "10.0.0.1", "user_agent": "pytest"}


def _sql(stmt: Any) -> str:
    """语句文本(pg 方言专用句式兜底编译;替身宽容)。"""
    try:
        return str(stmt).lower()
    except Exception:
        from sqlalchemy.dialects import postgresql

        return str(stmt.compile(dialect=postgresql.dialect())).lower()


class FakeResult:
    """execute 结果替身:同时兜 scalar_one_or_none / scalars().all() / rowcount。"""

    def __init__(self, rows: list[Any] | None = None, one: Any = None,
                 rowcount: int = 0) -> None:
        self._rows = list(rows or [])
        self._one = one
        self.rowcount = rowcount

    def scalar_one_or_none(self) -> Any:
        return self._one

    def scalars(self) -> FakeResult:
        return self

    def all(self) -> list[Any]:
        return list(self._rows)


class FakePool:
    """arq pool 替身:记录 enqueue_job(fn, *args, **kw)。"""

    def __init__(self) -> None:
        self.jobs: list[dict[str, Any]] = []

    async def enqueue_job(self, fn: str, *args: Any, **kw: Any) -> Any:
        self.jobs.append({"fn": fn, "args": args, **kw})
        return SimpleNamespace(job_id=kw.get("_job_id"))

    async def aclose(self) -> None:
        return None


class FakePerms:
    """permissions 替身:check / list_objects / FGA write 全部可控可观测。"""

    def __init__(self, check: bool = True, list_objects: tuple[str, ...] = ()) -> None:
        self._check = check
        self._list = list(list_objects)
        self.check_calls: list[dict[str, Any]] = []
        self._client = SimpleNamespace(write=self._write)

    async def _write(self, req: Any) -> None:
        return None

    async def check(self, **kw: Any) -> bool:
        self.check_calls.append(kw)
        return self._check

    async def list_objects(self, **kw: Any) -> list[str]:
        return list(self._list)

    async def read_all_tuples(self, **kw: Any) -> list[Any]:
        return []


class FakeAudit:
    def __init__(self) -> None:
        self.events: list[dict[str, Any]] = []

    async def write(self, **kw: Any) -> Any:
        self.events.append(kw)
        return SimpleNamespace(**kw)

    async def signed_url_issued(self, **kw: Any) -> Any:
        self.events.append({"event_type": "signed_url_issued", **kw})
        return SimpleNamespace(**kw)


class FakePresign:
    def __init__(self) -> None:
        self.signed: list[dict[str, Any]] = []

    def sign_thumbnail_url(self, key: str, ttl: int, request_base: str | None = None,
                           cache_control: str | None = None) -> str:
        self.signed.append({"key": key, "ttl": ttl, "request_base": request_base})
        return f"https://entry.example/ms-thumbs/{key}?X-Amz-Signature=fake"

    def copy_object(self, bucket: str, old_key: str, new_key: str) -> dict[str, str]:
        return {"etag": "e1"}

    def delete_object(self, bucket: str, key: str) -> None:
        return None


class _Params:
    """stmt.compile().params 安全提取(替身宽容:编译不可用 → 空表)。"""

    @staticmethod
    def of(stmt: Any) -> dict[str, Any]:
        try:
            return dict(stmt.compile().params)
        except Exception:
            return {}

    @staticmethod
    def list_values(params: dict[str, Any]) -> list[list[Any]]:
        return [list(v) for v in params.values() if isinstance(v, (list, tuple, set))]


# ─── settings 闸 fixture ──────────────────────────────────────────────────────
@pytest.fixture
def ai_on(monkeypatch: pytest.MonkeyPatch) -> Any:
    s = get_settings()
    monkeypatch.setattr(s, "ai_enabled", True)
    monkeypatch.setattr(s, "ai_active_model_version", ACTIVE)
    return s


@pytest.fixture
def ai_off(monkeypatch: pytest.MonkeyPatch) -> Any:
    s = get_settings()
    monkeypatch.setattr(s, "ai_enabled", False)
    return s


# ─── 搜索第四路(方案 §11)────────────────────────────────────────────────────
class FakeSearchDB:
    """search_assets 的 db 替身:按语句形状分派(公开夹查询 / 臂 B / 回查实体 /
    臂 A 默认),记录全部 execute 语句供形状断言。

    臂 B 侧按 active 版本 + 子串匹配 + folder IN bind 过滤(权限先行在端点侧已
    把 folder 集合烧进语句 bind —— 替身按真实请求参数过滤,沿 test_thumbnail_urls
    「不送错行」口径);回查实体按语句 IN 值取行。"""

    def __init__(
        self,
        *,
        arm_a_rows: list[tuple[Any, ...]],
        arm_b_candidates: list[tuple[Any, ...]] | None = None,
        entity_rows: dict[uuid.UUID, tuple[Any, ...]] | None = None,
        public_folder_ids: list[uuid.UUID] | None = None,
        pattern: str = "",
        known_folder_ids: set[uuid.UUID] | None = None,
    ) -> None:
        self.executed: list[Any] = []
        self.arm_a_rows = arm_a_rows
        self.arm_b_candidates = list(arm_b_candidates or [])
        self.entity_rows = dict(entity_rows or {})
        self.public_folder_ids = list(public_folder_ids or [])
        self.pattern = pattern.lower()  # 测试 q 不含 %/_ 通配,子串匹配即等价
        self.known_folder_ids = set(known_folder_ids or set())

    async def execute(self, stmt: Any, *a: Any, **kw: Any) -> FakeResult:
        self.executed.append(stmt)
        text = _sql(stmt)
        params = _Params.of(stmt)
        if "visibility" in text:  # public 项目非敏感夹豁免查询
            # 端点侧走 public_rows.scalars().all():替身 scalars() 是恒等,行即标量
            return FakeResult(rows=list(self.public_folder_ids))
        if "asset_ai_annotations" in text:  # 臂 B 候选 id 查询
            folder_ids = {
                f for lst in _Params.list_values(params) for f in lst
                if isinstance(f, uuid.UUID)
            }
            rows = [
                (aid,) for aid, mv, st, fid in self.arm_b_candidates
                if mv == get_settings().ai_active_version
                and self.pattern in (st or "").lower()
                and (not folder_ids or fid in folder_ids)
            ]
            return FakeResult(rows=rows)
        id_lists = [
            lst for lst in _Params.list_values(params)
            if lst and all(isinstance(x, uuid.UUID) for x in lst)
        ]
        if id_lists and not all(
            set(lst) <= self.known_folder_ids for lst in id_lists
        ):  # 臂 B 回查实体(WHERE id IN (…);folder IN 语句落默认臂 A 分支)
            wanted = {i for lst in id_lists for i in lst}
            return FakeResult(
                rows=[r for i, r in self.entity_rows.items() if i in wanted],
            )
        return FakeResult(rows=self.arm_a_rows)  # 臂 A / off 态唯一查询

    async def scalar(self, stmt: Any, *a: Any, **kw: Any) -> int:
        return 0

    def find(self, fragment: str) -> Any:
        """按片段找已执行语句(off 态恰 1 条;on 态臂 B 用表名定位,不按下标)。"""
        hits = [s for s in self.executed if fragment.lower() in _sql(s)]
        assert hits, f"未找到含 {fragment!r} 的语句"
        return hits[0]


def _search_row(asset: Any, folder_name: str = "夹", project_id: uuid.UUID | None = None,
                project_name: str = "项目") -> tuple[Any, ...]:
    return (asset, folder_name, project_id or uuid.uuid4(), project_name)


async def call_search(
    q: str, *, db: Any, permissions: Any, is_system_admin: bool,
    limit: int = 50, offset: int = 0,
) -> list[SearchResultOut]:
    return await assets_router.search_assets(  # type: ignore[call-arg]
        q=q, db=db, permissions=permissions, user=mk_user("searcher"),
        is_system_admin=is_system_admin, limit=limit, offset=offset,
    )


async def test_search_off_stmt_shape_baseline(ai_off: Any) -> None:
    """off 态(硬验收):单条查询、ORDER BY 仅 created_at(无 id tiebreak)、
    SQL LIMIT/OFFSET 分页、语句不含 AI 表 —— 与现状逐字节一致。"""
    db = FakeSearchDB(arm_a_rows=[])
    await call_search("wedding", db=db, permissions=FakePerms(), is_system_admin=True)
    assert len(db.executed) == 1, "off 态只跑既有三路,不得拼臂 B"
    sql = _sql(db.executed[0])
    assert "asset_ai_annotations" not in sql
    assert "order by assets.created_at desc" in sql
    assert "assets.id desc" not in sql, "off 态无 id tiebreak(现状不动)"
    assert " limit " in sql and " offset " in sql, "off 态仍走 SQL 层 LIMIT+OFFSET"


async def test_search_off_behavior_equivalence(ai_off: Any) -> None:
    """off 态行为等价:既有解析循环 → SearchResultOut 形状不变。"""
    a = mk_asset()
    db = FakeSearchDB(arm_a_rows=[_search_row(a, "现场原片")])
    out = await call_search("x", db=db, permissions=FakePerms(), is_system_admin=True)
    assert len(out) == 1
    assert isinstance(out[0], SearchResultOut)
    assert out[0].id == a.id
    assert out[0].folder_name == "现场原片"
    assert out[0].filename == a.filename


async def test_search_on_stmt_shape_two_arms(ai_on: Any) -> None:
    """on 态:臂 A 补 id tiebreak 且 LIMIT=offset+limit(无 SQL OFFSET);臂 B 语句
    含 active 版本过滤 + searchable_text ILIKE + 软删过滤,JOIN assets 权限先行。"""
    a = mk_asset()
    db = FakeSearchDB(arm_a_rows=[_search_row(a)], arm_b_candidates=[])
    await call_search("x", db=db, permissions=FakePerms(), is_system_admin=True,
                      limit=20, offset=5)
    assert len(db.executed) >= 2, "on 态至少臂 A + 臂 B 两条语句"
    arm_a_sql = _sql(db.executed[0])
    assert "order by assets.created_at desc, assets.id desc" in arm_a_sql, "臂 A 补 id tiebreak"
    assert " offset " not in arm_a_sql, "臂 A SQL 层不带 OFFSET(合并后应用层切片)"
    arm_b = db.executed[1]
    arm_b_sql = _sql(arm_b)
    assert "asset_ai_annotations" in arm_b_sql
    assert "searchable_text" in arm_b_sql and "deleted_at" in arm_b_sql
    assert " join assets " in arm_b_sql, "臂 B JOIN assets(软删 + folder 过滤载体)"
    params = _Params.of(arm_b)
    assert ACTIVE in params.values(), "臂 B 绑定 active 读取版本(settings 进程内取)"


async def test_search_on_merge_dedup_arm_a_priority(ai_on: Any) -> None:
    """两臂重叠:同 asset 只出现一次(臂 A 优先,先到先得)。"""
    a = mk_asset(filename="dup.jpg")          # 两臂都命中
    b = mk_asset(filename="only-a.jpg")       # 仅臂 A
    c = mk_asset(filename="only-b.jpg")       # 仅臂 B
    db = FakeSearchDB(
        arm_a_rows=[_search_row(a), _search_row(b)],
        arm_b_candidates=[
            (a.id, ACTIVE, "dup x stage", a.folder_id),
            (c.id, ACTIVE, "x drone night", c.folder_id),
        ],
        entity_rows={a.id: _search_row(a), c.id: _search_row(c)},
    )
    out = await call_search("x", db=db, permissions=FakePerms(), is_system_admin=True)
    ids = [r.id for r in out]
    assert len(ids) == len(set(ids)) == 3, "重叠资产去重后恰 3 条"
    assert set(ids) == {a.id, b.id, c.id}


async def test_search_on_sort_and_deep_pagination_offset2(ai_on: Any) -> None:
    """合并后按 (created_at, id) desc 重排 → 内存切片 [offset:offset+limit]:
    offset=2 深分页与 SQL LIMIT+OFFSET 语义等价;created_at 并列时 id tiebreak。"""
    base = datetime(2026, 11, 1, tzinfo=UTC)
    r1 = mk_asset(created_at=base)                                   # 较旧
    r2 = mk_asset(created_at=base + timedelta(days=1))               # 并列组
    r3 = mk_asset(created_at=base + timedelta(days=1))
    r4 = mk_asset(created_at=base + timedelta(days=2))               # 最新
    r5 = mk_asset(created_at=base - timedelta(days=1))               # 最旧
    tie = sorted([r2, r3], key=lambda x: x.id, reverse=True)  # 同 created_at 按 id desc
    expected_order = [r4, tie[0], tie[1], r1, r5]
    all_rows = {r.id: _search_row(r) for r in expected_order}
    db = FakeSearchDB(
        # 臂 A 只回 2 条(其余在臂 B)—— 排序/分页由应用层合并完成
        arm_a_rows=[all_rows[r4.id], all_rows[r1.id]],
        arm_b_candidates=[
            (r.id, ACTIVE, f"tag {r.id}", r.folder_id) for r in (r2, r3, r5)
        ],
        entity_rows=all_rows,
    )
    out = await call_search("x", db=db, permissions=FakePerms(), is_system_admin=True,
                            limit=2, offset=2)
    assert [r.id for r in out] == [r.id for r in expected_order[2:4]], (
        "offset=2 深分页:返回合并全序的第 2、3 位(含 tiebreak 决序)"
    )


async def test_search_on_sensitive_zero_leak(ai_on: Any) -> None:
    """sensitive 零泄露(沿既有口径):可达 folder 集合外的素材,AI 臂同样不可见
    —— folder_filter 权限先行烧进臂 B 语句,sensitive 夹不在集合内。"""
    ok_folder = uuid.uuid4()
    sensitive_folder = uuid.uuid4()
    visible = mk_asset(folder_id=ok_folder, filename="pub.jpg")
    hidden = mk_asset(folder_id=sensitive_folder, filename="secret.jpg")
    db = FakeSearchDB(
        arm_a_rows=[_search_row(visible)],
        # 两条臂 B 候选都命中关键词 —— 只有 folder 过滤能挡住 sensitive 那条
        arm_b_candidates=[
            (visible.id, ACTIVE, "pub secret stage", ok_folder),
            (hidden.id, ACTIVE, "secret stage", sensitive_folder),
        ],
        entity_rows={visible.id: _search_row(visible),
                     hidden.id: _search_row(hidden)},
        pattern="secret",
        known_folder_ids={ok_folder, sensitive_folder},
    )
    out = await call_search("secret", db=db,
                            permissions=FakePerms(list_objects=(str(ok_folder),)),
                            is_system_admin=False)
    ids = [r.id for r in out]
    assert hidden.id not in ids, "sensitive 夹素材零泄露(AI 臂同 folder 过滤)"
    assert visible.id in ids, "可达夹素材正常命中(臂 A)"
    # 双重检查:臂 B 语句的 folder IN bind 只含可达集合(权限先行证据)
    arm_b_params = _Params.of(db.find("asset_ai_annotations"))
    bind_folders = {
        f for lst in _Params.list_values(arm_b_params) for f in lst
        if isinstance(f, uuid.UUID)
    }
    assert bind_folders == {ok_folder}, "folder_filter 只含可达 folder(sensitive 不在)"


async def test_search_on_public_exemption_in_filter(ai_on: Any) -> None:
    """public 项目非敏感夹豁免与既有三路同语义:并入可达集合后再烧进臂 B 语句。"""
    granted = uuid.uuid4()
    public = uuid.uuid4()
    db = FakeSearchDB(
        arm_a_rows=[],
        public_folder_ids=[public],
        known_folder_ids={granted, public},
    )
    await call_search("x", db=db, permissions=FakePerms(list_objects=(str(granted),)),
                      is_system_admin=False)
    arm_b_params = _Params.of(db.find("asset_ai_annotations"))
    bind_folders = {
        f for lst in _Params.list_values(arm_b_params) for f in lst
        if isinstance(f, uuid.UUID)
    }
    assert bind_folders == {granted, public}, "豁免夹与授权夹并集进臂 B 过滤"


# ─── GET /assets/{id}/ai(契约 §2.6)──────────────────────────────────────────
class FakeAiDB:
    """GET /ai + keyframe-urls 的 db 替身:get() 按模型类分派,execute 按表名分派。"""

    def __init__(self, *, asset: Any = None, folder: Any = None, project: Any = None,
                 annotation: Any = None, segments: list[Any] | None = None) -> None:
        self.asset = asset
        self.folder = folder
        self.project = project
        self.annotation = annotation
        self.segments = list(segments or [])
        self.executed: list[Any] = []

    async def get(self, model: Any, key: Any) -> Any:
        if model is Asset:
            return self.asset
        if model is Folder:
            return self.folder
        if model is Project:
            return self.project
        return None

    async def execute(self, stmt: Any, *a: Any, **kw: Any) -> FakeResult:
        self.executed.append(stmt)
        text = _sql(stmt)
        if "asset_ai_annotations" in text:
            ann = self.annotation
            active = get_settings().ai_active_version
            if ann is not None and ann.model_version != active:
                ann = None  # 非 active 版本行不展示
            return FakeResult(one=ann)
        idx_lists = [
            lst for lst in _Params.list_values(_Params.of(stmt))
            if lst and all(isinstance(x, int) for x in lst)
        ]
        segs = self.segments
        if idx_lists:  # keyframe-urls 的 idx IN 查询:替身按真实请求 idx 过滤
            wanted = {i for lst in idx_lists for i in lst}
            segs = [s for s in segs if s.idx in wanted]
        return FakeResult(rows=sorted(segs, key=lambda s: s.idx))

    async def scalar(self, stmt: Any, *a: Any, **kw: Any) -> int:
        return 0

    async def commit(self) -> None:
        return None


def mk_annotation(version: str = ACTIVE, asset_id: uuid.UUID | None = None) -> Any:
    return SimpleNamespace(
        asset_id=asset_id or uuid.uuid4(),
        model_version=version,
        tier="coarse",
        context_path="发布会/现场视频/DJI_001.MP4",
        tags_zh=["发布会", "舞台"],
        tags_en=["stage", "lightshow"],
        description="户外舞台夜景",
        description_en="outdoor stage night",
        searchable_text="发布会 stage",
        meta={},
        updated_at=datetime(2026, 11, 3, tzinfo=UTC),
    )


def mk_segment(idx: int, *, keys: list[str] | None = None) -> Any:
    return SimpleNamespace(
        idx=idx, start_ms=idx * 60_000, end_ms=(idx + 1) * 60_000,
        keyframe_keys=keys if keys is not None else [f"keyframes/aid/{idx}_0.jpg"],
        tags_zh=["开场"], tags_en=["opening"],
        description=f"第 {idx} 段", meta={"segmented_by": "scene"},
        model_version=ACTIVE, created_at=datetime(2026, 11, 3, tzinfo=UTC),
    )


async def call_get_ai(asset_id: uuid.UUID, *, db: Any, permissions: Any,
                      is_system_admin: bool) -> AssetAiOut:
    return await ai_router.get_asset_ai(  # type: ignore[call-arg]
        asset_id=asset_id, db=db, permissions=permissions, user=mk_user("viewer"),
        is_system_admin=is_system_admin,
    )


def _visible_setup(*, sensitive: bool = False, deleted: bool = False,
                   visibility: str = "private") -> tuple[FakeAiDB, uuid.UUID]:
    project = SimpleNamespace(id=uuid.uuid4(), visibility=visibility)
    folder = mk_folder(sensitive=sensitive, project_id=project.id)
    asset = mk_asset(folder_id=folder.id, deleted=deleted)
    return FakeAiDB(asset=asset, folder=folder, project=project), asset.id


async def test_get_ai_permission_tri_state(ai_on: Any) -> None:
    """三态权限:① 系统 admin 对 sensitive 夹直通 200;② 零权限 outsider 对
    sensitive 夹 404;③ private 夹无 can_view → 404(不泄露存在性,先权限后数据)。"""
    db, aid = _visible_setup(sensitive=True)
    out = await call_get_ai(aid, db=db, permissions=FakePerms(check=False),
                            is_system_admin=True)
    assert out.annotation is None and out.segments is None  # admin 200(空值)

    db2, aid2 = _visible_setup(sensitive=True)
    with pytest.raises(Exception) as ei:
        await call_get_ai(aid2, db=db2, permissions=FakePerms(check=False),
                          is_system_admin=False)
    assert getattr(ei.value, "status_code", None) == 404

    db3, aid3 = _visible_setup(visibility="private")
    with pytest.raises(Exception) as ei3:
        await call_get_ai(aid3, db=db3, permissions=FakePerms(check=False),
                          is_system_admin=False)
    assert getattr(ei3.value, "status_code", None) == 404
    assert len(db3.executed) == 0, "无权不查 annotation/segments(先权限后数据)"


async def test_get_ai_public_folder_exemption_200(ai_on: Any) -> None:
    """public 项目非敏感夹:列表可见 → AI 区同口径可见(不 403),零权限直通。"""
    db, aid = _visible_setup(visibility="public")
    out = await call_get_ai(aid, db=db, permissions=FakePerms(check=False),
                            is_system_admin=False)
    assert out.model_version_active == ACTIVE
    assert len(db.executed) == 2, "通过后恰两条查询(annotation + segments)"


async def test_get_ai_missing_and_soft_deleted_404(ai_on: Any) -> None:
    """不存在 → 404;软删(回收站态)→ 404(对齐 get_live_preview_url 先例)。"""
    ghost = FakeAiDB()  # asset None
    with pytest.raises(Exception) as ei:
        await call_get_ai(uuid.uuid4(), db=ghost, permissions=FakePerms(),
                          is_system_admin=True)
    assert getattr(ei.value, "status_code", None) == 404

    db, aid = _visible_setup(deleted=True)
    with pytest.raises(Exception) as ei2:
        await call_get_ai(aid, db=db, permissions=FakePerms(), is_system_admin=True)
    assert getattr(ei2.value, "status_code", None) == 404


async def test_get_ai_disabled_404(ai_off: Any) -> None:
    """ai_enabled=false → 404(总开关急停语义,§13)。"""
    db, aid = _visible_setup()
    with pytest.raises(Exception) as ei:
        await call_get_ai(aid, db=db, permissions=FakePerms(), is_system_admin=True)
    assert getattr(ei.value, "status_code", None) == 404
    assert len(db.executed) == 0


async def test_get_ai_no_annotation_null_200(ai_on: Any) -> None:
    """无 annotation 行也 200:annotation/segments 均 null(空值,契约允许)。"""
    db, aid = _visible_setup()
    out = await call_get_ai(aid, db=db, permissions=FakePerms(), is_system_admin=True)
    assert out.annotation is None
    assert out.segments is None
    assert out.model_version_active == ACTIVE


async def test_get_ai_payload_shape(ai_on: Any) -> None:
    """契约形状:annotation 字段齐;segments 按 idx 升序、keyframe_count =
    len(keyframe_keys)、不回 keyframe key 明细;非 active 版本行不返回。"""
    db, aid = _visible_setup()
    db.annotation = mk_annotation(asset_id=aid)
    stale = mk_annotation(version="old@v0", asset_id=aid)  # 旧版本行(历史留存)
    db.segments = [
        mk_segment(1),
        mk_segment(0, keys=["k0a.jpg", "k0b.jpg", "k0c.jpg"]),
        mk_segment(2, keys=[]),
    ]

    out = await call_get_ai(aid, db=db, permissions=FakePerms(), is_system_admin=True)
    assert out.annotation is not None
    ann = out.annotation
    assert ann.context_path == "发布会/现场视频/DJI_001.MP4"
    assert ann.tags_zh == ["发布会", "舞台"] and ann.tags_en == ["stage", "lightshow"]
    assert ann.tier == "coarse" and ann.model_version == ACTIVE
    assert [s.idx for s in out.segments] == [0, 1, 2], "segments 按 idx 升序"
    assert [s.keyframe_count for s in out.segments] == [3, 1, 0]
    dumped = out.model_dump()
    assert "keyframe_keys" not in dumped["segments"][0], "不回 key 明细"
    assert dumped["segments"][0]["meta"] == {"segmented_by": "scene"}

    db.annotation = stale
    out2 = await call_get_ai(aid, db=db, permissions=FakePerms(), is_system_admin=True)
    assert out2.annotation is None, "只读 active 版本(旧版本行不展示)"


# ─── POST keyframe-urls(契约 §2.6)───────────────────────────────────────────
def _kf_setup() -> tuple[FakeAiDB, uuid.UUID, uuid.UUID]:
    project = SimpleNamespace(id=uuid.uuid4(), visibility="public")
    folder = mk_folder(sensitive=False, project_id=project.id)
    asset = mk_asset(folder_id=folder.id)
    db = FakeAiDB(asset=asset, folder=folder, project=project)
    return db, asset.id, project.id


def test_keyframe_urls_over_10_422() -> None:
    """入参闸:segment_idxs ≤10(pydantic 1..10,超限/空列表均 ValidationError)。"""
    with pytest.raises(ValidationError):
        KeyframeUrlsIn(segment_idxs=list(range(11)))
    with pytest.raises(ValidationError):
        KeyframeUrlsIn(segment_idxs=[])
    assert len(KeyframeUrlsIn(segment_idxs=list(range(10))).segment_idxs) == 10


async def test_keyframe_urls_invalid_idx_skipped(ai_on: Any) -> None:
    """无效 idx / 无 keyframes 的段跳过:urls 只含可签段,str(idx) 为键;
    TTL 沿缩略图口径(1800)、签发走缩略图桶 sign_thumbnail_url 同款、host 跟随入口。"""
    db, aid, _ = _kf_setup()
    db.segments = [mk_segment(0, keys=["kf/0_0.jpg", "kf/0_1.jpg"]),
                   mk_segment(1, keys=[]),           # 无 keyframes → 跳过
                   mk_segment(2, keys=["kf/2_0.jpg"])]
    presign = FakePresign()
    out = await ai_router.post_keyframe_urls(  # type: ignore[call-arg]
        asset_id=aid, payload=KeyframeUrlsIn(segment_idxs=[0, 1, 2, 99]),
        request=mk_request(FakePool()), db=db, permissions=FakePerms(check=False),
        presign=presign, audit=FakeAudit(), user=mk_user("v"),
        is_system_admin=False, ctx=dict(CTX),
    )
    assert set(out.urls) == {"0", "2"}, "无效 idx(99)与空 keyframes 段(1)跳过"
    assert out.urls["0"] == [
        "https://entry.example/ms-thumbs/kf/0_0.jpg?X-Amz-Signature=fake",
        "https://entry.example/ms-thumbs/kf/0_1.jpg?X-Amz-Signature=fake",
    ]
    assert all(c["ttl"] == 1800 for c in presign.signed), "TTL 沿缩略图口径"
    assert all(c["request_base"] == "http://entry.example" for c in presign.signed), (
        "签发 host 跟随入口(request_base_from)"
    )


async def test_keyframe_urls_audit_one_row(ai_on: Any) -> None:
    """每请求恰一条 signed_url_issued 审计,details 记 count(签发 URL 数)与
    对象前缀 keyframes/{asset_id}/。"""
    db, aid, folder_id = _kf_setup()
    db.segments = [mk_segment(0, keys=["kf/0_0.jpg"]), mk_segment(3, keys=["kf/3_0.jpg"])]
    audit = FakeAudit()
    out = await ai_router.post_keyframe_urls(  # type: ignore[call-arg]
        asset_id=aid, payload=KeyframeUrlsIn(segment_idxs=[0, 3]),
        request=mk_request(FakePool()), db=db, permissions=FakePerms(check=False),
        presign=FakePresign(), audit=audit, user=mk_user("v"),
        is_system_admin=False, ctx=dict(CTX),
    )
    assert len(out.urls) == 2
    audits = [e for e in audit.events if e.get("event_type") == "signed_url_issued"]
    assert len(audits) == 1, "每请求一条审计(不逐帧)"
    ev = audits[0]
    assert ev["details"]["count"] == 2
    assert ev["details"]["prefix"] == f"keyframes/{aid}/"
    assert ev["target_asset_id"] == aid
    assert ev["target_project_id"] == folder_id


# ─── 上下文钩子(§8.6)────────────────────────────────────────────────────────
class FakeHookDB:
    """restore 钩子的 db 替身:记录 delete/insert 语句与 commit,scalar 可控。
    bind 带 postgresql 方言标记(dialect_insert 按它选 insert 构造器);
    gone_kinds = 被删 skipped(asset_gone) 行的 kind 集合(SELECT 先于 DELETE)。"""

    def __init__(self, annotation_count: int = 0,
                 gone_kinds: list[str] | None = None) -> None:
        self.executed: list[Any] = []
        self.commits = 0
        self.annotation_count = annotation_count
        self.gone_kinds = list(gone_kinds or [])
        self.bind = SimpleNamespace(dialect=SimpleNamespace(name="postgresql"))

    async def execute(self, stmt: Any, *a: Any, **kw: Any) -> FakeResult:
        self.executed.append(stmt)
        if isinstance(stmt, Select):  # 被删行 kind 集合的 SELECT
            return FakeResult(rows=list(self.gone_kinds))
        return FakeResult(rowcount=1)  # INSERT .. ON CONFLICT 返回可派发(rowcount=1)

    async def scalar(self, stmt: Any, *a: Any, **kw: Any) -> int:
        return self.annotation_count

    async def commit(self) -> None:
        self.commits += 1


def _inserted_kinds(db: Any) -> set[str]:
    """从记录的 INSERT ai_jobs 语句参数里提取被补行的 kind 集合。"""
    kinds: set[str] = set()
    for s in db.executed:
        if "insert into ai_jobs" in _sql(s):
            kinds |= {v for v in _Params.of(s).values() if isinstance(v, str)
                      and v in ("annotate", "slice", "refresh")}
    return kinds


async def test_restore_hook_restock(ai_on: Any) -> None:
    """restore 钩子:① 先 SELECT 被删 skipped(asset_gone) 行的 kind 集合再 DELETE;
    ② 无 annotation → 补 pending annotate 行 + enqueue_ai_annotate(fire-and-forget);
    有 annotation 且无被删行时不补行。"""
    pool = FakePool()
    db = FakeHookDB(annotation_count=0)
    await ai_router.restore_restock_ai(db, pool, uuid.uuid4())
    sqls = [_sql(s) for s in db.executed]
    assert "select" in sqls[0] and "ai_jobs" in sqls[0], \
        "DELETE 前先 SELECT 被删行 kind 集合(删了就看不见)"
    assert any("delete from ai_jobs" in s for s in sqls), "第二步:DELETE ai_jobs"
    del_stmt = next(s for s in db.executed if "delete from ai_jobs" in _sql(s))
    dparams = _Params.of(del_stmt)
    assert "skipped" in dparams.values() and "asset_gone" in dparams.values(), \
        "精确谓词 status='skipped' AND last_error='asset_gone'(受控 token)"
    assert any("insert into ai_jobs" in s for s in sqls), "补 INSERT ai_jobs(pending)"
    assert any("on conflict" in s for s in sqls), "行先行幂等(ON CONFLICT DO NOTHING)"
    assert _inserted_kinds(db) == {"annotate"}, "无 annotation 只补 annotate 行"
    assert db.commits >= 1
    assert len(pool.jobs) == 1
    job = pool.jobs[0]
    assert job["fn"] == "ai_annotate_asset"
    assert job["_queue_name"] == "ai" and job["_expires"] == 1800

    # 已有 annotation(任意版本)且无被删行 → 只删不补行不派发
    db2 = FakeHookDB(annotation_count=1)
    pool2 = FakePool()
    await ai_router.restore_restock_ai(db2, pool2, uuid.uuid4())
    assert len(pool2.jobs) == 0, "有 annotation 不重派"
    assert not any("insert into ai_jobs" in _sql(s) for s in db2.executed)


async def test_restore_hook_restocks_slice_row(ai_on: Any) -> None:
    """视频 slice 行被删(asset_gone)→ 恢复后按原 kind 重建 slice 行 + 派发
    ai_slice_video(_expires=86400)—— 分段不丢(P1-2);该资产无 annotation 时
    再补 annotate(沿用原口径,两行各派一次)。"""
    pool = FakePool()
    db = FakeHookDB(annotation_count=0, gone_kinds=["slice"])
    await ai_router.restore_restock_ai(db, pool, uuid.uuid4())
    assert _inserted_kinds(db) == {"slice", "annotate"}, \
        f"slice 行按原 kind 重建 + 无 annotation 补 annotate:{_inserted_kinds(db)}"
    by_fn = {j["fn"]: j for j in pool.jobs}
    assert set(by_fn) == {"ai_annotate_asset", "ai_slice_video"}, f"按 kind 派发:{pool.jobs}"
    slc = by_fn["ai_slice_video"]
    assert slc["_queue_name"] == "ai" and slc["_expires"] == 86400
    assert slc["_job_id"].startswith("ai:slice:")
    ann = by_fn["ai_annotate_asset"]
    assert ann["_queue_name"] == "ai" and ann["_expires"] == 1800

    # 有 annotation 的视频 → 只按原 kind 补 slice 行,不补 annotate
    pool3 = FakePool()
    db3 = FakeHookDB(annotation_count=1, gone_kinds=["slice"])
    await ai_router.restore_restock_ai(db3, pool3, uuid.uuid4())
    assert _inserted_kinds(db3) == {"slice"}, "有 annotation 只补 slice 行"
    assert [j["fn"] for j in pool3.jobs] == ["ai_slice_video"]


async def test_restore_hook_disabled_noop(ai_off: Any) -> None:
    """ai_enabled=false:钩子零行为(不删不插不派发)。"""
    pool = FakePool()
    db = FakeHookDB()
    await ai_router.restore_restock_ai(db, pool, uuid.uuid4())
    assert db.executed == [] and db.commits == 0 and pool.jobs == []


async def test_restore_endpoint_hook_wiring(ai_on: Any,
                                            monkeypatch: pytest.MonkeyPatch) -> None:
    """端点级:restore 成功(audit asset_restored)后钩子必经且注入 arq_pool。
    端点 db 桩只覆盖主流程;钩子本体行为由 test_restore_hook_restock 覆盖。"""
    project = SimpleNamespace(id=uuid.uuid4(), visibility="public")
    folder = mk_folder(sensitive=False, project_id=project.id)
    asset = mk_asset(folder_id=folder.id, deleted=True)
    pool = FakePool()
    audit = FakeAudit()
    calls: list[tuple[Any, uuid.UUID]] = []

    async def _spy(db: Any, pool_arg: Any, asset_id: uuid.UUID) -> None:
        calls.append((pool_arg, asset_id))

    async def _get(model: Any, key: Any) -> Any:
        if model is Asset:
            return asset
        if model is Folder:
            return folder
        return None

    async def _commit() -> None:
        return None

    db = SimpleNamespace(get=_get, commit=_commit)
    monkeypatch.setattr(assets_router, "restore_restock_ai", _spy)
    await assets_router.restore_asset(  # type: ignore[call-arg]
        asset_id=asset.id, request=mk_request(pool), db=db,
        permissions=FakePerms(), audit=audit, user=mk_user("restorer"),
        is_system_admin=True, ctx=dict(CTX),
    )
    restored = [e for e in audit.events if e.get("event_type") == "asset_restored"]
    assert len(restored) == 1, "前置:恢复成功路径已走通"
    assert len(calls) == 1 and calls[0][1] == asset.id, "成功路径末尾触发恢复钩子"
    assert calls[0][0] is pool, "钩子拿到的 pool = app.state.arq_pool"


async def test_batch_prefix_hook_triggers_refresh(ai_on: Any) -> None:
    """batch_prefix 成功(commit 后)→ 按 renamed 资产 ids 派发 ai_refresh_context
    (fire-and-forget;改文件名 = context_path 尾段变化)。"""
    aid = uuid.uuid4()
    folder = mk_folder()
    asset_row = (aid, "a.jpg", folder.id, "ms-dev", "proj/a.jpg", "proj",
                 folder.project_id, False)
    db = SimpleNamespace(execute=None, scalar=None, commit=None)

    async def _execute(stmt: Any, *a: Any, **kw: Any) -> FakeResult:
        if isinstance(stmt, Select):
            return FakeResult(rows=[asset_row])  # 快照 select
        return FakeResult(rowcount=1)  # Core UPDATE(filename+minio_key)

    async def _scalar(stmt: Any, *a: Any, **kw: Any) -> int:
        return 0  # 占用预检 / 旧 key 复查都为 0

    async def _commit() -> None:
        return None

    db.execute, db.scalar, db.commit = _execute, _scalar, _commit
    from app.models import AssetBatchPrefixIn

    payload = AssetBatchPrefixIn(asset_ids=[aid], action="add", prefix="zz_")
    pool = FakePool()
    out = await assets_router.batch_prefix(  # type: ignore[call-arg]
        payload=payload, request=mk_request(pool), db=db,
        permissions=FakePerms(), presign=FakePresign(), audit=FakeAudit(),
        user=mk_user("renamer"), is_system_admin=True, ctx=dict(CTX),
    )
    assert out.renamed == 1
    assert len(pool.jobs) == 1, "成功路径派发一次 refresh"
    job = pool.jobs[0]
    assert job["fn"] == "ai_refresh_context"
    assert job["args"] == () and job["asset_ids"] == [str(aid)]
    assert job["folder_id"] is None and job["_queue_name"] == "ai"
    assert (job["_job_id"] or "").startswith("ai:refresh:")


async def test_batch_move_hook_triggers_refresh(ai_on: Any) -> None:
    """batch_move 成功 → 按 moved 资产 ids 派发 refresh(≤500 直传 asset_ids,
    folder_id=None);FGA 交换走替身成功路径。"""
    project_id = uuid.uuid4()
    src = mk_folder(project_id=project_id)
    target = mk_folder(project_id=project_id)
    aid = uuid.uuid4()
    rows = [(aid, "a.jpg", src.id, project_id, False)]
    db = SimpleNamespace(execute=None, get=None, commit=None)

    async def _execute(stmt: Any, *a: Any, **kw: Any) -> FakeResult:
        if isinstance(stmt, Select):
            return FakeResult(rows=rows)  # 快照 / 同名占用预检
        return FakeResult(rowcount=1)  # Core UPDATE(folder_id)

    async def _get(model: Any, key: Any) -> Any:
        return target if model is Folder else None

    async def _commit() -> None:
        return None

    db.execute, db.get, db.commit = _execute, _get, _commit
    from app.models import AssetBatchMoveIn

    payload = AssetBatchMoveIn(asset_ids=[aid], target_folder_id=target.id)
    pool = FakePool()
    out = await assets_router.batch_move_assets(  # type: ignore[call-arg]
        payload=payload, request=mk_request(pool), db=db,
        permissions=FakePerms(), audit=FakeAudit(), user=mk_user("mover"),
        is_system_admin=True, ctx=dict(CTX),
    )
    assert out.moved_count == 1 and out.fga_pending == []
    assert len(pool.jobs) == 1
    job = pool.jobs[0]
    assert job["fn"] == "ai_refresh_context"
    assert job["asset_ids"] == [str(aid)]
    assert job["folder_id"] is None


async def test_refresh_for_assets_chunking_over_500(ai_on: Any) -> None:
    """>500(跨夹改名等无单 folder 语义场景):分批派发,批间 _job_id 带序号
    防同秒确定性 id 被静默去重;≤500 单批直传。"""
    pool = FakePool()
    ids = [uuid.uuid4() for _ in range(501)]
    await enqueue_ai_refresh_for_assets(pool, ids)
    assert len(pool.jobs) == 2, "501 = 500 + 1 两批"
    assert len({j["_job_id"] for j in pool.jobs}) == 2, "批间 job id 不相撞"
    assert pool.jobs[0]["asset_ids"] == [str(i) for i in ids[:500]]
    assert pool.jobs[1]["asset_ids"] == [str(i) for i in ids[500:]]

    pool2 = FakePool()
    await enqueue_ai_refresh_for_assets(pool2, [uuid.uuid4()])
    assert len(pool2.jobs) == 1 and pool2.jobs[0]["args"] == ()


def test_update_folder_hook_call_site() -> None:
    """update_folder 挂点存在:成功路径(rename/reparent 落库并审计后)派发
    folder 子树模式 refresh —— 源码级断言(端点直调需全量 folder 校验链桩,
    收益不匹成本;派发语义由 enqueue_ai_refresh 相关单测覆盖)。"""
    src = inspect.getsource(folders_router.update_folder)
    assert "enqueue_ai_refresh" in src
    assert "folder_id=folder.id" in src, "子树模式:受影响 folder 整树下发"
    pos = src.find("enqueue_ai_refresh")
    assert src.find("return FolderOut.model_validate(folder)", pos) != -1, (
        "钩子在 return 之前(成功路径必经)"
    )


async def test_refresh_disabled_noop(ai_off: Any) -> None:
    """ai_enabled=false:refresh 派发零行为(asset_ids / folder_id 模式同闸)。"""
    pool = FakePool()
    await ai_router.enqueue_ai_refresh(pool, folder_id=uuid.uuid4())
    await ai_router.enqueue_ai_refresh(pool, asset_ids=[uuid.uuid4()])
    assert pool.jobs == []


async def test_refresh_job_id_shape(ai_on: Any) -> None:
    """refresh 派发口径:_job_id = ai:refresh:{unix_ts},入参形态对齐 worker
    签名(ai_refresh_context(ctx, asset_ids: list[str], folder_id: str))。"""
    pool = FakePool()
    fid = uuid.uuid4()
    await ai_router.enqueue_ai_refresh(pool, folder_id=fid)
    assert len(pool.jobs) == 1
    job = pool.jobs[0]
    assert job["fn"] == "ai_refresh_context"
    assert job["asset_ids"] is None and job["folder_id"] == str(fid)
    assert (job["_job_id"] or "").startswith("ai:refresh:")
    assert job["_queue_name"] == "ai" and job["_expires"] == 1800
