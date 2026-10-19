"""C 包审计补名 — 补充边界用例(测试产物,不改既有用例)。

覆盖 test_audit_detail_names.py 14 条之外的任务书要求的边界:
  1. details 白名单键的组合行(单行多桶 folder/user/group/subject 一遍收集)
  2. subject 大小写 / 非 UUID 变体(大写 kind 前缀、大写 hex、带 #member 的 user、
     无前缀裸 uuid、非 UUID)
  3. resolved_names 与 W2b target 字段共存(target_asset_filename / resolved_names
     同行都在;asset 已 purge 时 W2b 回 null 但 resolved_names 照常)
  4. list 分页翻页:helper 只补当页 —— 每一页(各 offset)行都带补名
  5. CSV 导出内容级 diff(列数一致、无新列、补名不泄入 CSV)
  6. 非字符串标量值(folder_id=123/True/list/None/空串)静默跳过
  7. details=None 兜底(resolved_names 恒为 dict)

写法完全仿 tests/test_audit_detail_names.py;dedup/event_type 统一 `zz_cnamesx:`
前缀隔离,teardown 物理清干净。
"""
from __future__ import annotations

import csv as _csv
import io as _io
import uuid
from datetime import UTC, datetime
from typing import Any

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from app.db.session import get_sessionmaker
from app.db.tables import Asset, AuditEvent, Folder, Group, User
from app.main import create_app
from app.services.audit import AuditService

EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"        # 系统 admin(seed 契约账号)
PROJECT_EVENT = "11111111-1111-1111-1111-111111111103"  # public,bucket=ms-dev

AUDIT_URL = "/api/v1/admin/audit"
DEDUP_PREFIX = "zz_cnamesx:"
EVT = "zz_cnamesx_evt"  # 唯一 event_type:过滤天然隔离,不受其他用例事件干扰


def _h(uid: str = EVAN_ID) -> dict[str, str]:
    return {"X-User-Id": uid}


@pytest.fixture(scope="session")
async def app_with_lifespan():
    app = create_app()
    async with app.router.lifespan_context(app):  # type: ignore[attr-defined]
        yield app


@pytest.fixture(scope="session")
async def client(app_with_lifespan):
    transport = ASGITransport(app=app_with_lifespan)  # type: ignore[arg-type]
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


async def _make_folder(client: AsyncClient, name: str) -> dict:
    r = await client.post(
        "/api/v1/folders",
        json={"project_id": PROJECT_EVENT, "name": name},
        headers=_h(),
    )
    assert r.status_code == 201, r.text
    return r.json()


async def _write_event(**kw: Any) -> AuditEvent:
    kw.setdefault("event_type", EVT)
    async with get_sessionmaker()() as db:
        svc = AuditService(db)
        return await svc.write(dedup_key=f"{DEDUP_PREFIX}{uuid.uuid4().hex}", **kw)


async def _audit_rows(client: AsyncClient, t0: datetime) -> list[dict]:
    r = await client.get(
        AUDIT_URL,
        params={"event_type": EVT, "from": t0.isoformat(), "limit": 500},
        headers=_h(),
    )
    assert r.status_code == 200, r.text
    return r.json()


async def _row_by_event(client: AsyncClient, ev: AuditEvent) -> dict:
    rows = await _audit_rows(client, ev.event_time)
    mine = [e for e in rows if e["id"] == str(ev.id)]
    assert mine, f"应命中事件 id={ev.id}"
    return mine[-1]


@pytest.fixture(scope="module")
async def world(client: AsyncClient) -> Any:
    tag = uuid.uuid4().hex[:8]
    async with get_sessionmaker()() as db:
        u1 = User(id=uuid.uuid4(), name=f"组合用户_{tag}")
        u2 = User(id=uuid.uuid4(), name=f"分享人2_{tag}")
        g1 = Group(id=uuid.uuid4(), name=f"组合组_{tag}")
        db.add_all([u1, u2, g1])
        await db.commit()

    f1 = await _make_folder(client, f"zz_cnamesx_f1_{tag}")
    f2 = await _make_folder(client, f"zz_cnamesx_f2_{tag}")
    f3 = await _make_folder(client, f"zz_cnamesx_f3_{tag}")

    w: dict[str, Any] = {
        "tag": tag,
        "folders": [f1, f2, f3],
        "users": {"u1": u1, "u2": u2},
        "group": g1,
    }
    try:
        yield w
    finally:
        async with get_sessionmaker()() as db:
            await db.execute(
                AuditEvent.__table__.delete().where(
                    AuditEvent.dedup_key.like(f"{DEDUP_PREFIX}%"))
            )
            await db.commit()
        async with get_sessionmaker()() as db:
            for f in w["folders"]:
                await db.execute(
                    Folder.__table__.delete().where(Folder.id == uuid.UUID(f["id"]))
                )
            for u in w["users"].values():
                await db.execute(User.__table__.delete().where(User.id == u.id))
            await db.execute(Group.__table__.delete().where(Group.id == w["group"].id))
            await db.commit()


# ─── 1. 组合行:单行多桶键一遍收集 ─────────────────────────────────────────────
@pytest.mark.asyncio
async def test_combined_whitelist_keys_one_row(
    client: AsyncClient, world: dict,
) -> None:
    """一行 details 同含 folder_id/target_folder_id/user_id/sharer_user_id/
    group_id/subject(user:#member):四桶各键全部补名;非白名单键(task_id/
    project_id)不进 resolved_names。"""
    f1, f2, _ = world["folders"]
    u1, u2 = world["users"]["u1"], world["users"]["u2"]
    g1 = world["group"]
    ev = await _write_event(
        actor_user_id=uuid.UUID(EVAN_ID),
        details={
            "folder_id": str(f1["id"]),
            "target_folder_id": str(f2["id"]),
            "user_id": str(u1.id),
            "sharer_user_id": str(u2.id),
            "group_id": str(g1.id),
            "subject": f"user:{u1.id}#member",
            "task_id": "not-whitelisted",
            "project_id": PROJECT_EVENT,
        },
    )
    row = await _row_by_event(client, ev)
    rn = row["resolved_names"]
    assert rn["folder_id"] == f1["name"], row
    assert rn["target_folder_id"] == f2["name"], row
    assert rn["user_id"] == u1.name, row
    assert rn["sharer_user_id"] == u2.name, row
    assert rn["group_id"] == g1.name, row
    assert rn["subject"] == u1.name, row  # user:<uuid>#member 剥后缀命中
    assert set(rn) == {
        "folder_id", "target_folder_id", "user_id",
        "sharer_user_id", "group_id", "subject",
    }, row  # 白名单外键不混入


# ─── 2. subject 大小写 / 非 UUID 变体 ─────────────────────────────────────────
@pytest.mark.asyncio
async def test_subject_case_and_prefix_variants(
    client: AsyncClient, world: dict,
) -> None:
    """subject 变体:大写 kind 前缀(USER:)与大写 hex UUID 均不命中(resolve
    严格小写 kind + sid 字符串比对)→ 不进 resolved_names;group:<uuid> 无
    #member 后缀正常命中;非 UUID 与裸 uuid(无前缀)回落不进。"""
    u1 = world["users"]["u1"]
    g1 = world["group"]
    upper_hex = str(u1.id).upper()
    # 每行 details 只有一个 subject 键 → 拆多事件逐个验
    variants: list[tuple[str, bool]] = [
        (f"USER:{u1.id}", False),            # 大写 kind 前缀 → 不命中
        (f"user:{upper_hex}", False),        # 大写 hex → sid 串比对失败 → 不命中
        (f"group:{g1.id}", True),            # group 无 #member → 命中组名
        (f"user:not-a-uuid", False),         # 非 UUID → 不命中
        (str(g1.id), False),                 # 无前缀裸 uuid → kind='' → 不命中
        (f"user:{uuid.uuid4()}", False),     # 合法 UUID 但用户不存在 → 不命中
    ]
    for i, (subject, should_resolve) in enumerate(variants):
        ev_i = await _write_event(
            actor_user_id=uuid.UUID(EVAN_ID),
            details={"subject": subject},
        )
        row = await _row_by_event(client, ev_i)
        rn = row["resolved_names"]
        if should_resolve:
            expected = g1.name if subject.startswith("group:") else u1.name
            assert rn.get("subject") == expected, (subject, row)
        else:
            assert "subject" not in rn, (subject, row)
        assert row["details"]["subject"] == subject, row  # 原串原样


# ─── 3. resolved_names 与 W2b target 字段共存 ─────────────────────────────────
@pytest.mark.asyncio
async def test_resolved_names_coexist_with_w2b_target_fields(
    client: AsyncClient, world: dict,
) -> None:
    """W2b 派生列(target_asset_filename/target_project_name)与 C 包
    resolved_names 同行共存:真实 asset → 两侧都有值;asset 随机不存在(purge
    口径)→ W2b 回 null 键仍在,resolved_names 照常补。"""
    f1 = world["folders"][0]
    async with get_sessionmaker()() as db:
        res = await db.execute(select(Asset.id).limit(1))
        asset_id = res.scalar()
        if asset_id is None:
            # 环境无 asset:自插一条挂在本测试夹下(物理删,不留痕)
            tmp_asset = Asset(
                folder_id=uuid.UUID(f1["id"]), filename="zz_cnamesx_tmp.bin",
                minio_bucket="ms-dev", minio_key="zz_cnamesx/tmp.bin",
                size_bytes=1,
            )
            db.add(tmp_asset)
            await db.commit()
            asset_id = tmp_asset.id
        _tmp_asset_id = uuid.UUID(str(asset_id))

    ev_real = await _write_event(
        actor_user_id=uuid.UUID(EVAN_ID),
        target_asset_id=asset_id,  # 无 asset 数据则 None,退化为只验键共存
        details={"folder_id": str(f1["id"])},
    )
    row = await _row_by_event(client, ev_real)
    assert "resolved_names" in row and "target_asset_filename" in row, row
    assert row["resolved_names"]["folder_id"] == f1["name"], row
    if asset_id is not None:
        assert isinstance(row["target_asset_filename"], str), row
        assert isinstance(row["target_project_name"], str), row

    ev_gone = await _write_event(
        actor_user_id=uuid.UUID(EVAN_ID),
        target_asset_id=uuid.uuid4() if asset_id is None else _tmp_asset_id,
        details={"folder_id": str(f1["id"])},
    )
    # purge 模拟:FK ondelete=SET NULL,物理删 asset 后 target_asset_id 回 null
    # (悬空 asset id 因 FK 写不进 audit_events,只能走删行路径)
    if asset_id is not None:
        async with get_sessionmaker()() as db:
            await db.execute(
                Asset.__table__.delete().where(Asset.id == _tmp_asset_id)
            )
            await db.commit()
    row = await _row_by_event(client, ev_gone)
    assert row["target_asset_id"] is None, row
    assert row["target_asset_filename"] is None, row
    assert row["resolved_names"]["folder_id"] == f1["name"], row  # 互不干扰


# ─── 4. 分页翻页:helper 只补当页(每一页都补) ─────────────────────────────────
@pytest.mark.asyncio
async def test_pagination_helper_applies_per_page(
    client: AsyncClient, world: dict,
) -> None:
    """5 条事件各挂独立目录,limit=2 翻 3 页(offset 0/2/4):每一页行都带
    resolved_names(helper 作用于当页 rows,不是只有第一页)。"""
    folders = []
    for i in range(5):
        folders.append(await _make_folder(
            client, f"zz_cnamesx_page_{world['tag']}_{i}"))
    t0 = datetime.now(UTC)
    evs = []
    for f in folders:
        evs.append(await _write_event(
            actor_user_id=uuid.UUID(EVAN_ID),
            details={"folder_id": str(f["id"])},
        ))
    try:
        seen: dict[str, dict] = {}
        for offset in (0, 2, 4, 6):
            r = await client.get(
                AUDIT_URL,
                params={"event_type": EVT, "from": t0.isoformat(),
                        "limit": 2, "offset": offset},
                headers=_h(),
            )
            assert r.status_code == 200, r.text
            for e in r.json():
                if e["id"] in {str(x.id) for x in evs}:
                    seen[e["id"]] = e
        assert len(seen) == 5, f"翻页应覆盖全部 5 条,实际 {len(seen)}"
        for f, ev in zip(folders, evs):
            row = seen[str(ev.id)]
            assert row["resolved_names"].get("folder_id") == f["name"], row
    finally:
        async with get_sessionmaker()() as db:
            for f in folders:
                await db.execute(
                    Folder.__table__.delete().where(Folder.id == uuid.UUID(f["id"]))
                )
            await db.commit()


# ─── 5. CSV 导出内容级 diff ───────────────────────────────────────────────────
@pytest.mark.asyncio
async def test_csv_export_content_no_new_columns(
    client: AsyncClient, world: dict,
) -> None:
    """CSV 内容级:表头与数据行列数一致;无 resolved_names/user_agent 新列;
    补名(目录名)不泄入 CSV 任何单元格,裸 folder_id 仍在 details_json。"""
    f1 = world["folders"][0]
    ev = await _write_event(
        actor_user_id=uuid.UUID(EVAN_ID),
        user_agent="zz-cnamesx-ua/1.0",
        details={"folder_id": str(f1["id"])},
    )
    r = await client.get(
        "/api/v1/admin/audit/export.csv",
        params={"event_type": EVT, "from": ev.event_time.isoformat()},
        headers=_h(),
    )
    assert r.status_code == 200, r.text
    text = r.content.decode("utf-8-sig")
    rows = list(_csv.reader(_io.StringIO(text)))
    header, data_rows = rows[0], rows[1:]
    assert "resolved_names" not in header and "user_agent" not in header, header
    assert data_rows, "导出应含本用例事件"
    assert all(len(row) == len(header) for row in data_rows), header
    assert f1["name"] not in text, "补名不应出现在 CSV"
    assert str(f1["id"]) in text, "details_json 应保留裸 folder_id"


# ─── 6/7. 非字符串标量值跳过 + details=None 兜底 ───────────────────────────────
@pytest.mark.asyncio
async def test_non_string_scalars_and_null_details_skipped(
    client: AsyncClient, world: dict,
) -> None:
    """白名单键塞非字符串标量(123/True/list/null/空串):静默跳过不 500,
    resolved_names 为空 dict;details=None 行 details 回 {} 且不报错。"""
    f1 = world["folders"][0]
    ev = await _write_event(
        actor_user_id=uuid.UUID(EVAN_ID),
        details={
            "folder_id": 123,
            "target_folder_id": True,
            "user_id": [str(f1["id"])],
            "group_id": None,
            "sharer_user_id": "",
        },
    )
    row = await _row_by_event(client, ev)
    assert row["resolved_names"] == {}, row
    assert row["user_agent"] is None, row

    ev_none = await _write_event(
        actor_user_id=uuid.UUID(EVAN_ID), details=None,
    )
    row = await _row_by_event(client, ev_none)
    assert row["details"] == {}, row
    assert row["resolved_names"] == {}, row
