"""盲搜跳转定位 — GET /api/v1/assets 增 locate 参数的后端集成测试(T1–T5)。

跑在 ms-api 容器内(docker exec ms-api pytest tests/test_asset_locate.py)。
预期前置(同 test_search_labels / test_v4_permissions):
  1. seed_demo_data.py 已跑过(3 项目 / 契约账号 Evan = 系统 admin,outsider = 零权限)
  2. OpenFGA store / model 已 push
  3. env=dev(允许 X-User-Id header 模拟身份)

契约(需求文档「接口定义」+ 定稿方案 §2.1–§2.3):
  GET /api/v1/assets?folder_id=<uuid>&locate=<uuid>[&limit&offset]
  - locate_index:目标在同排序(created_at DESC, id DESC,deleted_at IS NULL,本夹)
    下的 0 基全量序号;
  - locate 缺省 / 目标不存在 / 已软删 / 他夹 → null(不区分原因);
  - locate 非 UUID 格式 → FastAPI 422;无 folder can_view → 403(权限先于 locate);
  - limit/offset 窗口不影响 locate_index(恒全量序号)。

不变式(定稿方案 §2.2,本文件的断言锚点):对任意夹与目标 X,按对齐窗口
`limit=页大小, offset=locate_index//页大小*页大小` 取窗,items[locate_index % 页大小]
必是 X —— 断言按公式写,与夹规模无关。

造数/清理:自建 zz_locate_* 夹(Evan 经 API 建)+ DB 直插 asset 行
(test_trash_and_purge._insert_asset 同手法);created_at 显式错开(T1/T5)或
同事务并列(T2:PG now() 是事务时间戳,同一事务内全部并列 —— 即「同秒批量」形态)。
收尾 DB 直删夹内行(测试自插行无 FGA tuple / audit 依赖,直删不留残)+ API 删空夹,
不污染 seed 基线;对 seed 数据只读(T4 直接复用 seed 夹与 demo asset)。
"""
from __future__ import annotations

import asyncio
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete, select

from app.db.session import get_sessionmaker
from app.db.tables import Asset
from app.main import create_app

# seed 写死的契约账号(同 test_v4_permissions / test_search_labels / test_trash_and_purge)
EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"      # 系统 admin(org admin)
OUTSIDER_ID = "00000000-0000-0000-0000-0000000000aa"  # 零权限普通用户(无任何 FGA tuple)

PROJECT_WEDDING = "11111111-1111-1111-1111-111111111101"  # private
PROJECT_EVENT = "11111111-1111-1111-1111-111111111103"    # public

# seed 的 folder 用 API 按名查找(同 test_search_labels 惯例)
WEDDING_FOLDER_NAME = "现场原片"
WEDDING_SENSITIVE_NAME = "客户私密照(VIP)"
EVENT_FOLDER_NAME = "现场视频"

# 对齐窗口公式的除数(前端列表页大小);不变式断言对任意页大小取值都成立
_PAGE_SIZE = 30


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


def _h(user_id: str) -> dict[str, str]:
    return {"X-User-Id": user_id}


# ─── 造数 helpers(自建夹 + DB 直插;收尾自清理,不污染 seed 基线)────────────
async def _mk_folder(client: AsyncClient, tag: str) -> str:
    """Evan(系统 admin)在 public 项目下建一个唯一命名的测试夹,返回 folder_id。"""
    r = await client.post(
        "/api/v1/folders",
        json={"project_id": PROJECT_EVENT, "name": f"zz_locate_{tag}_{uuid.uuid4().hex[:8]}"},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text
    return r.json()["id"]


async def _db_insert(folder_id: str, specs: list[dict[str, Any]]) -> list[uuid.UUID]:
    """单事务批量直插 asset 行(同 test_trash_and_purge._insert_asset 的 DB 直写手法)。

    spec 可显式给 created_at / deleted_at;不给则走 server_default now() ——
    PG 的 now() 是事务时间戳,同事务内全部行并列(T2 的「同秒批量」即由此构造)。
    返回按插入顺序排列的 id 列表。
    """
    ids: list[uuid.UUID] = []
    async with get_sessionmaker()() as db:
        for spec in specs:
            values: dict[str, Any] = {
                "id": uuid.uuid4(),
                "folder_id": uuid.UUID(folder_id),
                "filename": spec["filename"],
                # key 内嵌随机段防撞 uq_asset_minio_object_version;对象本身不入
                # MinIO(容器内不通,直插只造 DB 行,同 trash 测试口径)
                "minio_bucket": "ms-dev",
                "minio_key": f"zz-locate/{uuid.uuid4().hex}/{spec['filename']}",
                "size_bytes": 11,
                "content_type": "text/plain",
                "uploader_id": uuid.UUID(EVAN_ID),
            }
            # 未指定的列必须整个省略(显式传 None 会绕过 server_default 写 NULL)
            if spec.get("created_at") is not None:
                values["created_at"] = spec["created_at"]
            if spec.get("deleted_at") is not None:
                values["deleted_at"] = spec["deleted_at"]
            row = Asset(**values)
            db.add(row)
            ids.append(row.id)
        await db.commit()
    return ids


async def _cleanup_folder(client: AsyncClient, folder_id: str) -> None:
    """自清理:DB 直删本夹全部 asset 行(自插行无 FGA tuple/audit 依赖),
    再经 API 删空夹(test_trash_and_purge 收尾同口径)。"""
    async with get_sessionmaker()() as db:
        await db.execute(delete(Asset).where(Asset.folder_id == uuid.UUID(folder_id)))
        await db.commit()
    r = await client.delete(f"/api/v1/folders/{folder_id}", headers=_h(EVAN_ID))
    assert r.status_code == 204, r.text


# ─── 查询 helpers ─────────────────────────────────────────────────────────────
async def _list_all(client: AsyncClient, folder_id: str, user_id: str = EVAN_ID) -> dict:
    """全量拉夹内列表(limit=500 上限),返回响应 body。"""
    r = await client.get(
        "/api/v1/assets",
        params={"folder_id": folder_id, "limit": 500},
        headers=_h(user_id),
    )
    assert r.status_code == 200, r.text
    return r.json()  # type: ignore[no-any-return]


async def _folder_id(client: AsyncClient, project_id: str, name: str) -> str:
    """按项目 + 名字找 seed 夹(同 test_search_labels._folder_id)。"""
    r = await client.get(
        "/api/v1/folders", params={"project_id": project_id}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    folder = next(f for f in r.json() if f["name"] == name)
    return folder["id"]  # type: ignore[no-any-return]


async def _assert_window_invariant(
    client: AsyncClient, folder_id: str, target_id: str, locate_index: int,
) -> None:
    """§2.2 不变式自检:按对齐窗口公式反查(与夹规模无关),
    窗口 items[locate_index % 页大小] 必是目标。"""
    offset = locate_index // _PAGE_SIZE * _PAGE_SIZE
    r = await client.get(
        "/api/v1/assets",
        params={
            "folder_id": folder_id, "locate": target_id,
            "limit": _PAGE_SIZE, "offset": offset,
        },
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    items = r.json()["items"]
    idx = locate_index % _PAGE_SIZE
    assert idx < len(items), f"对齐窗口只有 {len(items)} 行,不含下标 {idx}(locate_index={locate_index})"
    assert items[idx]["id"] == target_id, (
        f"不变式破坏:locate_index={locate_index} 反查窗口第 {idx} 行 "
        f"= {items[idx]['id']},应为目标 {target_id}"
    )


# ─── 共享造数夹(module 级,fixture teardown 自清理)──────────────────────────
@pytest.fixture(scope="module")
async def t1_folder(client: AsyncClient):
    """T1/T5 共用:7 个 asset 显式错开 created_at(第 0 行最新,每行差 1 分钟),
    列表全量序 = 插入序,期望 locate_index 完全确定。"""
    fid = await _mk_folder(client, "t1")
    base = datetime.now(timezone.utc)
    ids = await _db_insert(fid, [
        {"filename": f"zz-locate-t1-{i}.txt", "created_at": base - timedelta(minutes=i)}
        for i in range(7)
    ])
    try:
        yield fid, [str(i) for i in ids]  # ordered[i] 的全量序位置恰为 i
    finally:
        await _cleanup_folder(client, fid)


@pytest.fixture(scope="module")
async def t2_folder(client: AsyncClient):
    """T2 专用:先单独事务插 1 行 old,再同事务批量插 5 行(created_at 并列)。

    前置自检 5 行 created_at 确实并列且严格晚于 old —— 保证用例前提成立,
    防止 PG 时钟/驱动行为漂移让 tiebreaker 断言假绿。
    """
    fid = await _mk_folder(client, "t2")
    old_id = (await _db_insert(fid, [{"filename": "zz-locate-t2-old.txt"}]))[0]
    await asyncio.sleep(0.02)  # 两个事务间隔 > PG 微秒精度,now() 必不同
    tied_ids = await _db_insert(
        fid, [{"filename": f"zz-locate-t2-b{i}.txt"} for i in range(5)],
    )
    async with get_sessionmaker()() as db:
        res = await db.execute(
            select(Asset.id, Asset.created_at).where(Asset.id.in_([*tied_ids, old_id]))
        )
        ts = {rid: created for rid, created in res.all()}
    tied_ts = ts[tied_ids[0]]
    assert len({ts[i] for i in tied_ids}) == 1, "同事务批量插入的 created_at 应全部并列"
    assert ts[old_id] < tied_ts, "old 行应严格早于并列批(否则用例前提不成立)"
    try:
        yield fid, [str(i) for i in tied_ids], str(old_id)
    finally:
        await _cleanup_folder(client, fid)


@pytest.fixture(scope="module")
async def t3_data(client: AsyncClient):
    """T3 专用:夹 A(1 活 + 1 预置软删行)+ 夹 B(1 活),供各 null 分支复用。"""
    folder_a = await _mk_folder(client, "t3a")
    folder_b = await _mk_folder(client, "t3b")
    live = (await _db_insert(folder_a, [{"filename": "zz-locate-t3-live.txt"}]))[0]
    gone = (await _db_insert(folder_a, [{
        "filename": "zz-locate-t3-deleted.txt",
        "deleted_at": datetime.now(timezone.utc),  # 预置软删行(回收站态)
    }]))[0]
    other = (await _db_insert(folder_b, [{"filename": "zz-locate-t3-other.txt"}]))[0]
    try:
        yield {
            "folder_a": folder_a, "folder_b": folder_b,
            "live": str(live), "gone": str(gone), "other": str(other),
        }
    finally:
        await _cleanup_folder(client, folder_a)
        await _cleanup_folder(client, folder_b)


# ─── T1 正常定位 + 不变式自检 ─────────────────────────────────────────────────
@pytest.mark.asyncio
@pytest.mark.parametrize("pick", ["first", "middle", "last"])
async def test_t1_locate_position_and_invariant(client: AsyncClient, t1_folder, pick: str) -> None:
    """T1:夹内多文件,目标(最新/中间/最旧)的 locate_index = 全量序中的下标,
    且对齐窗口反查必见目标(不变式,与夹规模无关)。"""
    fid, ordered = t1_folder
    target = {"first": ordered[0], "middle": ordered[3], "last": ordered[-1]}[pick]

    # 基线:全量列表顺序与显式 created_at 错开序完全一致(列表排序即 locate 的排序口径)
    full = await _list_all(client, fid)
    assert full["total"] == 7
    assert [a["id"] for a in full["items"]] == ordered

    r = await client.get(
        "/api/v1/assets",
        params={"folder_id": fid, "locate": target},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    body = r.json()
    expected = ordered.index(target)
    assert body.get("locate_index") == expected, (
        f"{pick} 目标 {target} locate_index 应为全量序下标 {expected},实际 {body.get('locate_index')}"
    )
    await _assert_window_invariant(client, fid, target, body["locate_index"])


# ─── T2 created_at 并列(同事务批量)id tiebreaker ────────────────────────────
@pytest.mark.asyncio
async def test_t2_created_at_tie_id_tiebreaker(client: AsyncClient, t2_folder) -> None:
    """T2:5 个同事务并列行必须各得互不相同的 locate_index(= 全量序位置,
    由 id DESC 决定)—— 只比 created_at 的实现会给出相同 index / 漂位;
    不变式对并列行仍成立。"""
    fid, tied, old = t2_folder
    full_ids = [a["id"] for a in (await _list_all(client, fid))["items"]]
    # old 更早 → 全量序在并列批之后;并列批内部按 id DESC
    assert full_ids[-1] == old
    assert sorted(full_ids[:5]) == sorted(tied)
    expected = {aid: pos for pos, aid in enumerate(full_ids)}

    locates: dict[str, int] = {}
    for aid in tied:
        r = await client.get(
            "/api/v1/assets", params={"folder_id": fid, "locate": aid}, headers=_h(EVAN_ID),
        )
        assert r.status_code == 200, r.text
        idx = r.json()["locate_index"]
        assert idx == expected[aid], (
            f"并列行 {aid} locate_index={idx} 应为 id tiebreaker 决定的全量序位置 {expected[aid]}"
        )
        locates[aid] = idx
        await _assert_window_invariant(client, fid, aid, idx)
    # 5 个并列行拿到 5 个互不相同的 index —— tiebreaker 生效的直接证据
    assert set(locates.values()) == {0, 1, 2, 3, 4}

    # old 行:恰在并列批之后(位置 5)
    r2 = await client.get(
        "/api/v1/assets", params={"folder_id": fid, "locate": old}, headers=_h(EVAN_ID),
    )
    assert r2.status_code == 200, r2.text
    assert r2.json()["locate_index"] == 5


# ─── T3 null 分支(不区分原因)+ malformed 422 ────────────────────────────────
@pytest.mark.asyncio
async def test_t3_soft_deleted_returns_null(client: AsyncClient, t3_data) -> None:
    """T3a:locate 指向已软删行(回收站态)→ locate_index 为 null。"""
    r = await client.get(
        "/api/v1/assets",
        params={"folder_id": t3_data["folder_a"], "locate": t3_data["gone"]},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    assert r.json().get("locate_index") is None


@pytest.mark.asyncio
async def test_t3_cross_folder_returns_null(client: AsyncClient, t3_data) -> None:
    """T3b:locate 是别夹的活文件(本夹调 locate)→ null(不越夹定位)。"""
    r = await client.get(
        "/api/v1/assets",
        params={"folder_id": t3_data["folder_a"], "locate": t3_data["other"]},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    assert r.json().get("locate_index") is None


@pytest.mark.asyncio
async def test_t3_unknown_uuid_returns_null(client: AsyncClient, t3_data) -> None:
    """T3c:locate 是不存在的随机 UUID → null(不 404、不 500)。"""
    r = await client.get(
        "/api/v1/assets",
        params={"folder_id": t3_data["folder_a"], "locate": str(uuid.uuid4())},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    assert r.json().get("locate_index") is None


@pytest.mark.asyncio
async def test_t3_absent_returns_null(client: AsyncClient, t3_data) -> None:
    """T3d:缺省不传 locate → locate_index 为 null,列表行为完全不变。

    用 .get() 断言:兼容「键为 null」与「键缺省」两种序列化形态(老后端混合窗口)。
    """
    r = await client.get(
        "/api/v1/assets", params={"folder_id": t3_data["folder_a"]}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body.get("locate_index") is None
    assert body["total"] == 1 and body["items"][0]["id"] == t3_data["live"]


@pytest.mark.asyncio
async def test_t3_malformed_uuid_422(client: AsyncClient, t3_data) -> None:
    """T3e:locate 非 UUID 字符串 → FastAPI 参数校验 422(类型声明兜底)。"""
    r = await client.get(
        "/api/v1/assets",
        params={"folder_id": t3_data["folder_a"], "locate": "not-a-uuid"},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 422, r.text


# ─── T4 权限:权限判定先于 locate,无新权限面 ─────────────────────────────────
@pytest.mark.asyncio
async def test_t4_no_can_view_403(client: AsyncClient) -> None:
    """T4a:零权限 outsider 对 private 项目普通夹带 locate 调用 → 与现状一致的
    403(权限先于 locate —— 是 403,不是 200 + null)。"""
    fid = await _folder_id(client, PROJECT_WEDDING, WEDDING_FOLDER_NAME)
    target = (await _list_all(client, fid))["items"][0]["id"]
    r = await client.get(
        "/api/v1/assets",
        params={"folder_id": fid, "locate": target},
        headers=_h(OUTSIDER_ID),
    )
    assert r.status_code == 403, r.text


@pytest.mark.asyncio
async def test_t4_public_folder_org_pass(client: AsyncClient) -> None:
    """T4b:public 项目非敏感夹,零权限 outsider 直通(列表 public 兜底路径),
    locate 同路径生效:最新行 locate_index=0 且不变式成立。"""
    fid = await _folder_id(client, PROJECT_EVENT, EVENT_FOLDER_NAME)
    items = (await _list_all(client, fid, OUTSIDER_ID))["items"]
    assert items, "seed public 夹应至少 1 个 asset"
    target = items[0]["id"]

    r = await client.get(
        "/api/v1/assets",
        params={"folder_id": fid, "locate": target},
        headers=_h(OUTSIDER_ID),
    )
    assert r.status_code == 200, r.text
    assert r.json().get("locate_index") == 0  # 目标即全量序最新一行
    await _assert_window_invariant(client, fid, target, 0)


@pytest.mark.asyncio
async def test_t4_system_admin_pass(client: AsyncClient) -> None:
    """T4c:系统 admin 对 sensitive 夹(public 兜底不适用,受邀制)直通,
    locate 生效:最新行 locate_index=0 且不变式成立。"""
    fid = await _folder_id(client, PROJECT_WEDDING, WEDDING_SENSITIVE_NAME)
    items = (await _list_all(client, fid))["items"]
    assert items, "seed sensitive 夹应至少 1 个 asset"
    target = items[0]["id"]

    r = await client.get(
        "/api/v1/assets",
        params={"folder_id": fid, "locate": target},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    assert r.json().get("locate_index") == 0
    await _assert_window_invariant(client, fid, target, 0)


# ─── T5 窗口与 locate 共存:locate_index 恒全量序号 ────────────────────────────
@pytest.mark.asyncio
async def test_t5_locate_index_full_sequence_under_window(client: AsyncClient, t1_folder) -> None:
    """T5:带 limit/offset 时 locate_index 不受窗口影响,仍是不含窗口的全量序号。

    用最旧目标(全量序位置 6):先取一个不含目标的窗口 [2,4),再取前端探测形态
    limit=1 —— 两种窗口下 locate_index 都必须是 6,而非窗口内相对位置。
    """
    fid, ordered = t1_folder
    target = ordered[-1]  # 全量序位置 6(显式 created_at 最旧)

    r = await client.get(
        "/api/v1/assets",
        params={"folder_id": fid, "locate": target, "limit": 2, "offset": 2},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    body = r.json()
    # 窗口本身语义不变:offset=2&limit=2 返回全量序第 2、3 行(不含目标)
    assert [a["id"] for a in body["items"]] == ordered[2:4]
    assert body["locate_index"] == 6, f"窗口下 locate_index 应仍为全量序号 6,实际 {body['locate_index']}"

    # 前端探测形态(limit=1, offset=0):items 只含最新一行,目标序号仍是 6
    r2 = await client.get(
        "/api/v1/assets",
        params={"folder_id": fid, "locate": target, "limit": 1, "offset": 0},
        headers=_h(EVAN_ID),
    )
    assert r2.status_code == 200, r2.text
    body2 = r2.json()
    assert [a["id"] for a in body2["items"]] == [ordered[0]]
    assert body2["locate_index"] == 6
