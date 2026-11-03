"""搜索第四路 on/off 态真实 SQL 行为测试(ai-tagging-slicing 方案 §11;需求 §5 功能点 6)。

既有 test_ai_api.py 以 FakeSearchDB 断言语句形状(compile 形状 + 回放);本文件补
**真实 SQL 行为**:aiosqlite 内存库上跑 routers.assets.search_assets 本体,
验证 —
  on 态:只有 active 版本 annotation 命中(非 active 行不命中,§8.1/验收 §15-14);
  软删资产经 AI 臂不命中;两臂重叠去重(同 asset 恰一次);
  off 态:annotation 完全不可见(仅三路命中面),与现状行为一致;
  权限先行:非可达 folder 的 AI 命中零泄露(真 folder_filter 烧进臂 B)。

sqlite 垫片:JSONB/ARRAY 以 JSON 渲染;array_to_string / ms_labels_text 注册为
确定性函数(表达式索引 DDL 与三路标签臂需要);id 绑 hex 对齐 ORM Uuid 惯例。
"""
from __future__ import annotations

import json
import os
import uuid
from collections.abc import AsyncIterator
from types import SimpleNamespace
from typing import Any

for _k, _v in {
    "DB_URL": "postgresql+asyncpg://u:p@localhost/db", "REDIS_URL": "redis://localhost:6379/0",
    "MINIO_ENDPOINT_INTERNAL": "http://minio:9000", "MINIO_ENDPOINT_PUBLIC": "http://localhost:9000",
    "MINIO_ACCESS_KEY": "k", "MINIO_SECRET_KEY": "s",
    "OPENFGA_API_URL": "http://openfga:8080", "OPENFGA_STORE_ID": "01TEST",
    "WEB_APP_BASE_URL": "http://localhost/ms-static/web/",
    "SESSION_JWT_SECRET": "test-secret-0123456789abcdef",
}.items():
    os.environ.setdefault(_k, _v)

import pytest  # noqa: E402
from sqlalchemy import event, text  # noqa: E402
from sqlalchemy.dialects.postgresql import ARRAY, JSONB  # noqa: E402
from sqlalchemy.ext.asyncio import (  # noqa: E402
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.ext.compiler import compiles  # noqa: E402

from app.db.tables import (  # noqa: E402
    Asset,
    AssetAiAnnotation,
    Base,
    Folder,
    Project,
)
from app.routers import assets as ar  # noqa: E402
from app.settings import Settings  # noqa: E402

ACTIVE = "smolvlm2-256m@p1+lm1"
OLD = "old-model@p0"


@compiles(JSONB, "sqlite")
def _jsonb_sqlite(type_: Any, compiler: Any, **kw: Any) -> str:  # type: ignore[no-untyped-def]
    return "JSON"


@compiles(ARRAY, "sqlite")
def _array_sqlite(type_: Any, compiler: Any, **kw: Any) -> str:  # type: ignore[no-untyped-def]
    return "JSON"


def mk_settings(ai_enabled: bool) -> Settings:
    return Settings(
        env="test", session_jwt_secret="test-secret",
        db_url="postgresql+asyncpg://u:p@localhost/db", redis_url="redis://localhost:6379/0",
        minio_endpoint_internal="http://minio:9000", minio_endpoint_public="http://localhost:9000",
        minio_access_key="k", minio_secret_key="s", openfga_api_url="http://openfga:8080",
        openfga_store_id="01TEST", web_app_base_url="http://localhost/ms-static/web/",
        ai_enabled=ai_enabled, ai_model_version=ACTIVE,
    )


@pytest.fixture
async def env(monkeypatch: pytest.MonkeyPatch) -> AsyncIterator[
        tuple[async_sessionmaker[AsyncSession], dict[uuid.UUID, uuid.UUID]]]:
    """建库 + 种子:4 资产覆盖 active/旧版本/无 annotation/软删 四态 + 2 folder。"""
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")

    @event.listens_for(engine.sync_engine, "connect")
    def _register(dbapi_conn: Any, _rec: Any) -> None:
        def _a2s(value: Any, sep: str) -> str:
            try:
                return sep.join(json.loads(value) if isinstance(value, str) else [])
            except Exception:
                return ""

        def _labels_text(value: Any) -> str:
            try:
                return " ".join(json.loads(value) if isinstance(value, str) else [])
            except Exception:
                return ""
        dbapi_conn.create_function("array_to_string", 2, _a2s, deterministic=True)
        dbapi_conn.create_function("ms_labels_text", 1, _labels_text, deterministic=True)

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all, tables=[
            Project.__table__, Folder.__table__, Asset.__table__,
            AssetAiAnnotation.__table__])
    sm = async_sessionmaker(engine, expire_on_commit=False)

    pid = uuid.uuid4()
    f1, f2 = uuid.uuid4(), uuid.uuid4()   # f1 = 可达普通夹;f2 = sensitive 夹
    ids: dict[str, uuid.UUID] = {}
    async with engine.begin() as conn:
        await conn.execute(text(
            "INSERT INTO projects (id, organization_id, code, name, minio_bucket,"
            " visibility, is_archived) VALUES (:a,:b,'p1','航拍项目','bkt','private',0)"),
            {"a": pid.hex, "b": uuid.uuid4().hex})
        for fid, name, sensitive in ((f1, "现场", 0), (f2, "机密", 1)):
            await conn.execute(text(
                "INSERT INTO folders (id, project_id, name, minio_prefix, is_sensitive)"
                " VALUES (:a,:b,:c,:d,:e)"),
                {"a": fid.hex, "b": pid.hex, "c": name,
                 "d": f"p/{name}", "e": sensitive})
        rows = [
            # (key, folder, filename, deleted, annotation_version, searchable)
            ("a_active", f1, "IMG_100.jpg", None, ACTIVE, "drone aerial 现场夜航"),
            ("b_oldver", f1, "IMG_200.jpg", None, OLD, "drone legacy 旧版行"),
            ("c_noann", f1, "drone_photo.jpg", None, None, None),
            ("d_deleted", f1, "IMG_300.jpg", "2026-01-01 00:00:00+00:00", ACTIVE,
             "drone secret 软删"),
            ("e_dup", f1, "drone_clip.mov", None, ACTIVE, "drone extra 重复命中"),
            ("f_sensitive", f2, "IMG_400.jpg", None, ACTIVE, "drone secret footage"),
        ]
        for key, fid, filename, deleted, ver, searchable in rows:
            aid = uuid.uuid4()
            ids[key] = aid
            await conn.execute(text(
                "INSERT INTO assets (id, folder_id, filename, minio_bucket, minio_key,"
                " size_bytes, media_metadata, tags, user_labels, deleted_at)"
                " VALUES (:a,:b,:c,'bkt',:k,1,'{}','{}','[]',:d)"),
                {"a": aid.hex, "b": fid.hex, "c": filename, "k": f"k/{filename}",
                 "d": deleted})
            if ver is not None:
                await conn.execute(text(
                    "INSERT INTO asset_ai_annotations (asset_id, model_version, tier,"
                    " context_path, tags_zh, tags_en, searchable_text, meta)"
                    " VALUES (:a,:b,'coarse',:c,'[]','[]',:s,'{}')"),
                    {"a": aid.hex, "b": ver, "c": f"航拍项目/现场/{filename}",
                     "s": searchable})
    yield sm, ids
    await engine.dispose()


class Perms:
    """permissions.list_objects 替身:只回可达 folder 集合(folder 型),sensitive_folder 恒空。"""

    def __init__(self, granted: list[uuid.UUID]) -> None:
        self._granted = [str(g) for g in granted]

    async def list_objects(self, *, user_subject: str, relation: str,
                           object_type: str) -> list[str]:
        assert relation == "can_view"
        return list(self._granted) if object_type == "folder" else []


# ─── on 态:active 版本过滤(非 active 行不命中)───────────────────────────────


async def test_on_state_only_active_version_hits(
        env: Any, monkeypatch: pytest.MonkeyPatch) -> None:
    sm, ids = env
    monkeypatch.setattr(ar, "get_settings", lambda: mk_settings(True))
    async with sm() as db:
        out = await ar.search_assets(
            q="drone", db=db, permissions=Perms([]), user=None,
            is_system_admin=True, limit=10, offset=0)
    got = {r.id for r in out}
    assert ids["a_active"] in got, "active 版本 annotation 命中"
    assert ids["c_noann"] in got, "臂 A 文件名命中"
    assert ids["e_dup"] in got and len(
        [r for r in out if r.id == ids["e_dup"]]) == 1, "两臂重叠去重恰一次"
    assert ids["b_oldver"] not in got, "非 active 版本行不得命中(§15-14)"
    assert ids["d_deleted"] not in got, "软删资产经 AI 臂不命中"
    hit = next(r for r in out if r.id == ids["a_active"])
    assert hit.folder_name == "现场" and hit.project_name == "航拍项目", \
        "AI 臂回查实体带 folder/project 冗余"


async def test_off_state_annotations_invisible(
        env: Any, monkeypatch: pytest.MonkeyPatch) -> None:
    """off 态(硬验收 §15-7):annotation 完全不进搜索,仅三路命中面。"""
    sm, ids = env
    monkeypatch.setattr(ar, "get_settings", lambda: mk_settings(False))
    async with sm() as db:
        out = await ar.search_assets(
            q="drone", db=db, permissions=Perms([]), user=None,
            is_system_admin=True, limit=10, offset=0)
    got = {r.id for r in out}
    assert got == {ids["c_noann"], ids["e_dup"]}, "仅文件名命中(annotation 不可见)"
    assert ids["a_active"] not in got, "on 态命中行在 off 态必须消失"


async def test_on_state_sensitive_folder_zero_leak_real_filter(
        env: Any, monkeypatch: pytest.MonkeyPatch) -> None:
    """非 admin:真 folder_filter 烧进臂 B —— sensitive 夹内的 AI 命中零泄露。"""
    sm, ids = env
    f1 = None
    async with sm() as db:
        row = (await db.execute(text("SELECT id FROM folders WHERE is_sensitive = 0"))).first()
        f1 = uuid.UUID(row[0])
    monkeypatch.setattr(ar, "get_settings", lambda: mk_settings(True))
    user = SimpleNamespace(subject="u1")
    async with sm() as db:
        out = await ar.search_assets(
            q="drone", db=db, permissions=Perms([f1]),
            user=SimpleNamespace(subject="u1"),
            is_system_admin=False, limit=10, offset=0)
    got = {r.id for r in out}
    assert ids["f_sensitive"] not in got, "sensitive 夹 AI 命中零泄露(真过滤)"
    assert ids["a_active"] in got, "可达夹 AI 命中正常"


async def test_on_state_limit_applies_after_merge(
        env: Any, monkeypatch: pytest.MonkeyPatch) -> None:
    """on 态合并排序后内存切片:limit=2 恰回 2 条;命中候选集正确
    (admin 全量臂 B:旧版本行与软删行不入候选;created_at 秒级并列时次序
    由 id tiebreak 定,不断言具体次序)。"""
    sm, ids = env
    monkeypatch.setattr(ar, "get_settings", lambda: mk_settings(True))
    async with sm() as db:
        out = await ar.search_assets(
            q="drone", db=db, permissions=Perms([]), user=None,
            is_system_admin=True, limit=2, offset=0)
    assert len(out) == 2
    candidates = {ids["a_active"], ids["c_noann"], ids["e_dup"], ids["f_sensitive"]}
    got = {r.id for r in out}
    assert got <= candidates, got
    assert ids["b_oldver"] not in got and ids["d_deleted"] not in got
