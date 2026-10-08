"""批次三(C-Step2)项目权限模板模块 — 集成测试,跑在 ms-api 容器里。

对应方案:`rushes-spec/material-storage/project-grant-templates-plan.md` §4.1(DB)、
§4.2(API 契约)、§4.5(边界)、§4.6(测试清单);接口定义见
`docs/qdev/2026-09-30-project-grant-templates.md`「接口定义」。

契约要点(方案 §4.2,require_system_admin,落在 /api/v1/admin/grant-templates):
  - GET    → [{id, name, description, is_default,
                items: [{kind, id, roles, name, missing}]}];
    item.name = resolve_subject_names 解析后的主体名,missing=true 仅当主体已删
    (found=False;停用用户行仍在,不标 missing)
  - POST   {name, description?, is_default?, items:[{kind,id,roles}]} → 201;
    organization_id 服务端取 default org;重名(同 org)409;payload 内
    (kind,id) 重复 400;主体不存在 400;items 超 50 条 422;roles/kind 非法 422;
    is_default=true 同事务清掉旧 default
  - PATCH /{id} → 200;items 全量替换;改名撞名 409(预检排除自身);
    is_default true→false = 直接取消默认(不产生新 default);id 不存在 404
  - DELETE /{id} → 204;级联删 items;id 不存在 404

预期前置(同 test_v4_permissions.py):
  1. seed_demo_data.py 已跑过(Evan = 真 user + org admin;outsider = fake)
  2. OpenFGA store / model 已 push
  3. env=dev(允许 X-User-Id header 模拟身份)
"""
from __future__ import annotations

import uuid

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import create_app

# seed 写死的真 user / fake outsider(同 test_v4_permissions.py)
EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"
OUTSIDER_ID = "00000000-0000-0000-0000-0000000000aa"


@pytest.fixture(scope="session")
async def app_with_lifespan():
    app = create_app()
    async with app.router.lifespan_context(app):  # type: ignore[attr-defined]
        yield app


@pytest.fixture(scope="session")
async def client(app_with_lifespan):
    transport = ASGITransport(app=app_with_lifespan)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


def _h(user_id: str) -> dict[str, str]:
    return {"X-User-Id": user_id}


def _uniq(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:8]}"


# ─── 测试内现建辅助(seed 不建 groups 表数据,不存在现成组)────────────────────
async def _create_group(client: AsyncClient, prefix: str = "gt_grp") -> str:
    """现建用户组(照 test_directory.py 的写法)→ gid。"""
    r = await client.post(
        "/api/v1/admin/directory/groups",
        json={"name": _uniq(prefix), "description": "grant_templates 测试组"},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text
    return r.json()["id"]


def _item_user(uid: str, roles: list[str]) -> dict:
    return {"kind": "user", "id": uid, "roles": roles}


def _item_group(gid: str, roles: list[str]) -> dict:
    return {"kind": "group", "id": gid, "roles": roles}


async def _post_template(
    client: AsyncClient,
    *,
    name: str,
    items: list[dict],
    description: str | None = None,
    is_default: bool = False,
) -> dict:
    """POST 建模板,断言 201 后经 GET 列表按唯一 name 取回完整条目(含 id)。

    不依赖 POST 响应体形状:契约只写死 201,条目结构以 GET 列表为准。
    """
    body: dict = {"name": name, "items": items, "is_default": is_default}
    if description is not None:
        body["description"] = description
    r = await client.post("/api/v1/admin/grant-templates", json=body, headers=_h(EVAN_ID))
    assert r.status_code == 201, r.text
    found = await _get_template_by_name(client, name)
    assert found is not None, f"POST 201 后 GET 列表应能按 name 找到模板: {name}"
    return found


async def _get_template_by_name(client: AsyncClient, name: str) -> dict | None:
    r = await client.get("/api/v1/admin/grant-templates", headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    for t in r.json():
        if t["name"] == name:
            return t
    return None


# ─── 1. CRUD 全 cycle(方案 §4.6 第 1 条)──────────────────────────────────────
@pytest.mark.asyncio
async def test_template_crud_cycle(client: AsyncClient) -> None:
    """POST 建(带 items)→ GET 列表含 items 与解析后的主体 name →
    PATCH 改名/替换 items/设默认 → DELETE → GET 不在。"""
    gid = await _create_group(client)
    name = _uniq("tpl_crud")

    tpl = await _post_template(
        client,
        name=name,
        description="CRUD cycle 用",
        items=[_item_group(gid, ["uploader"]), _item_user(EVAN_ID, ["admin"])],
    )
    tid = tpl["id"]
    assert tpl["description"] == "CRUD cycle 用"
    assert tpl["is_default"] is False
    assert len(tpl["items"]) == 2
    by_kind = {(i["kind"], i["id"]): i for i in tpl["items"]}
    # 解析后的主体名称:组 → groups.name;user → users.name(Evan)
    assert by_kind[("group", gid)]["name"] != "" and by_kind[("group", gid)]["name"] is not None
    assert by_kind[("user", EVAN_ID)]["name"] == "Evan"
    assert by_kind[("group", gid)]["roles"] == ["uploader"]
    assert by_kind[("group", gid)]["missing"] is False

    # PATCH:改名 + items 全量替换 + 设默认
    new_name = _uniq("tpl_crud_renamed")
    r = await client.patch(
        f"/api/v1/admin/grant-templates/{tid}",
        json={
            "name": new_name,
            "description": "改名后",
            "is_default": True,
            "items": [_item_user(OUTSIDER_ID, ["viewer", "downloader"])],
        },
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text

    after = await _get_template_by_name(client, new_name)
    assert after is not None, "改名后应能按新 name 找到"
    assert after["id"] == tid
    assert after["is_default"] is True
    assert after["description"] == "改名后"
    # 旧 items 已被全量替换(组条目消失,换成了 outsider)
    assert [(i["kind"], i["id"]) for i in after["items"]] == [("user", OUTSIDER_ID)]
    assert after["items"][0]["roles"] == ["viewer", "downloader"]
    assert await _get_template_by_name(client, name) is None, "旧 name 不应再命中"

    # DELETE → 204,GET 列表不在
    r2 = await client.delete(f"/api/v1/admin/grant-templates/{tid}", headers=_h(EVAN_ID))
    assert r2.status_code == 204, r2.text
    assert await _get_template_by_name(client, new_name) is None


# ─── 2. default 唯一性(方案 §4.2 POST/PATCH;§4.6 第 2 条)────────────────────
@pytest.mark.asyncio
async def test_template_default_uniqueness(client: AsyncClient) -> None:
    """第二个设 is_default=true → 第一个自动取消;true→false = 取消默认且
    不产生新 default(合法输入)。只对我们创建的模板断言,不依赖全 org 状态。"""
    name_a = _uniq("tpl_def_a")
    name_b = _uniq("tpl_def_b")

    a = await _post_template(
        client, name=name_a, is_default=True, items=[_item_user(EVAN_ID, ["viewer"])],
    )
    assert a["is_default"] is True

    # 第二个设 default → a 自动取消(partial unique index + 同事务清旧)
    b = await _post_template(
        client, name=name_b, is_default=True, items=[_item_user(EVAN_ID, ["viewer"])],
    )
    a_after = await _get_template_by_name(client, name_a)
    assert a_after is not None and a_after["is_default"] is False, "旧 default 应被自动取消"
    assert b["is_default"] is True

    # true→false:直接取消,不产生新 default(a 保持 false,b 取消后两者均非默认)
    r = await client.patch(
        f"/api/v1/admin/grant-templates/{b['id']}",
        json={"is_default": False},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    b_after = await _get_template_by_name(client, name_b)
    a_final = await _get_template_by_name(client, name_a)
    assert b_after is not None and b_after["is_default"] is False
    assert a_final is not None and a_final["is_default"] is False


# ─── 3. 同 org 重名 → 409;PATCH 改回自身原名放行(方案 §4.2 / §4.6 第 3 条)───
@pytest.mark.asyncio
async def test_template_duplicate_name_409(client: AsyncClient) -> None:
    """POST 重名 → 409;PATCH 改名撞已有模板 → 409(排除自身后仍撞才算);
    PATCH 改回自身原名 → 放行(200)。"""
    name_a = _uniq("tpl_name_a")
    name_b = _uniq("tpl_name_b")
    a = await _post_template(
        client, name=name_a, items=[_item_user(EVAN_ID, ["viewer"])],
    )
    b = await _post_template(
        client, name=name_b, items=[_item_user(EVAN_ID, ["viewer"])],
    )

    # POST 重名
    r = await client.post(
        "/api/v1/admin/grant-templates",
        json={"name": name_a, "items": [_item_user(EVAN_ID, ["viewer"])]},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 409, r.text

    # PATCH 改名撞 a 的名字 → 409
    r2 = await client.patch(
        f"/api/v1/admin/grant-templates/{b['id']}",
        json={"name": name_a},
        headers=_h(EVAN_ID),
    )
    assert r2.status_code == 409, r2.text

    # PATCH 改回自身原名 → 放行
    r3 = await client.patch(
        f"/api/v1/admin/grant-templates/{b['id']}",
        json={"name": name_b},
        headers=_h(EVAN_ID),
    )
    assert r3.status_code == 200, r3.text
    still = await _get_template_by_name(client, name_b)
    assert still is not None and still["id"] == b["id"]


# ─── 3b. PATCH description:超长 422 / 显式 null 清空 / 不传不改 ──────────────
@pytest.mark.asyncio
async def test_template_patch_description_null_and_limit(client: AsyncClient) -> None:
    """PATCH description 三态:2000 字符 → 422(与 CreateIn 同款 max_length=1024,
    此前漏校验裸 500);不带该字段 → 原值不变;显式 null → 清空(前端保存空
    描述时发 null,后端按 model_fields_set 区分「没传」与「显式 null」)。"""
    name = _uniq("tpl_desc")
    tpl = await _post_template(
        client, name=name, description="原始描述",
        items=[_item_user(EVAN_ID, ["viewer"])],
    )
    tid = tpl["id"]

    # 超长 → 422
    r_long = await client.patch(
        f"/api/v1/admin/grant-templates/{tid}",
        json={"description": "x" * 2000},
        headers=_h(EVAN_ID),
    )
    assert r_long.status_code == 422, r_long.text

    # 不带 description 字段 → 原值不变
    r_keep = await client.patch(
        f"/api/v1/admin/grant-templates/{tid}",
        json={"is_default": False},
        headers=_h(EVAN_ID),
    )
    assert r_keep.status_code == 200, r_keep.text
    kept = await _get_template_by_name(client, name)
    assert kept is not None and kept["description"] == "原始描述", (
        "PATCH 不带 description 字段不应改动原值"
    )

    # 显式 null → 清空(200,GET 后 description 为 null)
    r_null = await client.patch(
        f"/api/v1/admin/grant-templates/{tid}",
        json={"description": None},
        headers=_h(EVAN_ID),
    )
    assert r_null.status_code == 200, r_null.text
    after = await _get_template_by_name(client, name)
    assert after is not None and after["description"] is None, "显式 null 应清空 description"


# ─── 4. payload 内 (kind,id) 重复 → 400(方案 §4.2 预检)──────────────────────
@pytest.mark.asyncio
async def test_template_duplicate_subject_400(client: AsyncClient) -> None:
    """items 内同一 (kind,id) 出现两次 → 400(预检,勿裸抛 IntegrityError;
    DB 层 UniqueConstraint(template_id, subject_kind, subject_id) 的 API 前置)。"""
    r = await client.post(
        "/api/v1/admin/grant-templates",
        json={
            "name": _uniq("tpl_dup_item"),
            "items": [
                _item_user(OUTSIDER_ID, ["viewer"]),
                _item_user(OUTSIDER_ID, ["downloader"]),
            ],
        },
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 400, r.text


# ─── 5. 形状校验:422(方案 §4.2:条数上限 50 与 initial_grants 同一常量)──────
@pytest.mark.asyncio
async def test_template_items_shape_422(client: AsyncClient) -> None:
    """items 超 50 条 → 422;kind 非法(department 已下线,Literal 仅 user/group)
    → 422。超限用随机 UUID:条数校验先于主体存在性(同 §3.1 的校验顺序)。"""
    # 51 条 → 422
    r = await client.post(
        "/api/v1/admin/grant-templates",
        json={
            "name": _uniq("tpl_too_many"),
            "items": [
                _item_user(str(uuid.uuid4()), ["viewer"]) for _ in range(51)
            ],
        },
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 422, r.text

    # kind 非法 → 422(Literal["user", "group"])
    r2 = await client.post(
        "/api/v1/admin/grant-templates",
        json={
            "name": _uniq("tpl_bad_kind"),
            "items": [{"kind": "department", "id": OUTSIDER_ID, "roles": ["viewer"]}],
        },
        headers=_h(EVAN_ID),
    )
    assert r2.status_code == 422, r2.text

    # roles 非法值 → 422(Literal ProjectRole)
    r3 = await client.post(
        "/api/v1/admin/grant-templates",
        json={
            "name": _uniq("tpl_bad_role"),
            "items": [_item_user(OUTSIDER_ID, ["owner"])],
        },
        headers=_h(EVAN_ID),
    )
    assert r3.status_code == 422, r3.text


# ─── 6. PATCH/DELETE 不存在的 id → 404(方案 §4.2)────────────────────────────
@pytest.mark.asyncio
async def test_template_patch_delete_missing_404(client: AsyncClient) -> None:
    ghost = str(uuid.uuid4())
    r = await client.patch(
        f"/api/v1/admin/grant-templates/{ghost}",
        json={"name": _uniq("tpl_ghost")},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 404, r.text

    r2 = await client.delete(f"/api/v1/admin/grant-templates/{ghost}", headers=_h(EVAN_ID))
    assert r2.status_code == 404, r2.text


# ─── 7. DELETE 级联删 items(方案 §4.1 ondelete CASCADE / §4.6 级联删除)────────
@pytest.mark.asyncio
async def test_template_delete_cascades_items(client: AsyncClient) -> None:
    """删模板 → 204,GET 列表无该模板(连带 items 无残留);
    重复 DELETE → 404(行已硬删,级联随之,同 id 不可再得)。"""
    gid = await _create_group(client)
    name = _uniq("tpl_cascade")
    tpl = await _post_template(
        client, name=name, items=[_item_group(gid, ["viewer"]), _item_user(EVAN_ID, ["admin"])],
    )
    tid = tpl["id"]
    assert len(tpl["items"]) == 2

    r = await client.delete(f"/api/v1/admin/grant-templates/{tid}", headers=_h(EVAN_ID))
    assert r.status_code == 204, r.text

    # 直接查列表断言:模板与条目均无残留
    r_list = await client.get("/api/v1/admin/grant-templates", headers=_h(EVAN_ID))
    assert r_list.status_code == 200
    assert all(t["id"] != tid for t in r_list.json()), "删除后 GET 列表不应再有该模板"

    # 重复删 → 404(行已删;级联 items 一并消失,同 id 不可重建取得)
    r2 = await client.delete(f"/api/v1/admin/grant-templates/{tid}", headers=_h(EVAN_ID))
    assert r2.status_code == 404, r2.text


# ─── 8. 非 system admin → 403(方案 §4.2 require_system_admin)────────────────
@pytest.mark.asyncio
async def test_template_requires_system_admin(client: AsyncClient) -> None:
    """outsider(非 system admin)调 GET/POST → 403。"""
    r = await client.get("/api/v1/admin/grant-templates", headers=_h(OUTSIDER_ID))
    assert r.status_code == 403, r.text

    r2 = await client.post(
        "/api/v1/admin/grant-templates",
        json={"name": _uniq("tpl_nobody"), "items": [_item_user(OUTSIDER_ID, ["viewer"])]},
        headers=_h(OUTSIDER_ID),
    )
    assert r2.status_code == 403, r2.text


# ─── 9. 主体不存在 → 400(方案 §4.2:校验主体存在,user 需 active)─────────────
@pytest.mark.asyncio
async def test_template_unknown_subject_400(client: AsyncClient) -> None:
    """items 引用未知 user id / 未知 group id → 400(id 传合法 UUID 形状、查无此主体)。"""
    ghost_user = str(uuid.uuid4())
    r = await client.post(
        "/api/v1/admin/grant-templates",
        json={"name": _uniq("tpl_ghost_user"), "items": [_item_user(ghost_user, ["viewer"])]},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 400, r.text

    ghost_group = str(uuid.uuid4())
    r2 = await client.post(
        "/api/v1/admin/grant-templates",
        json={
            "name": _uniq("tpl_ghost_group"),
            "items": [_item_group(ghost_group, ["viewer"])],
        },
        headers=_h(EVAN_ID),
    )
    assert r2.status_code == 400, r2.text


# ─── 10. 主体已删 → 列表标 missing=true(方案 §4.2 / §4.5 第 1 行)─────────────
@pytest.mark.asyncio
async def test_template_item_missing_after_group_delete(client: AsyncClient) -> None:
    """现建组 → 建模板含该组 item → 删组(director 端点,照 test_directory 写法)
    → GET 列表该 item missing=true,name 回退 sid[:12]+"…"(§2.2 兜底格式,
    无「用户组」前缀)。"""
    gid = await _create_group(client, "gt_doomed")
    name = _uniq("tpl_missing")
    tpl = await _post_template(
        client, name=name, items=[_item_group(gid, ["uploader"])],
    )
    assert tpl["items"][0]["missing"] is False, "删组前主体健在,不应标 missing"

    # 删组(directory 域端点,DELETE → 200,同 test_directory.py 的写法)
    r_del = await client.delete(
        f"/api/v1/admin/directory/groups/{gid}", headers=_h(EVAN_ID),
    )
    assert r_del.status_code == 200, r_del.text

    after = await _get_template_by_name(client, name)
    assert after is not None, "删组不应影响模板行本身"
    item = next(i for i in after["items"] if i["kind"] == "group")
    assert item["id"] == gid
    assert item["missing"] is True, f"主体已删的 item 应标 missing=true: {after['items']}"
    assert item["name"] == f"{gid[:12]}…", (
        f"已删主体 name 应回退 sid[:12]+'…'(方案 §2.2): {item['name']}"
    )


# ─── 11. items 空数组 → 422(空模板无意义,UI 已拦,API 层兜底)─────────────────
@pytest.mark.asyncio
async def test_template_empty_items_422(client: AsyncClient) -> None:
    """POST items: [] → 422(min_length=1);PATCH items: [] → 422
    (UpdateIn 可选不传,但传了就必须 ≥1)。"""
    # POST 空数组 → 422
    r = await client.post(
        "/api/v1/admin/grant-templates",
        json={"name": _uniq("tpl_empty_items"), "items": []},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 422, r.text

    # PATCH 空数组 → 422(先建一个正常模板)
    name = _uniq("tpl_patch_empty")
    tpl = await _post_template(
        client, name=name, items=[_item_user(EVAN_ID, ["viewer"])],
    )
    r2 = await client.patch(
        f"/api/v1/admin/grant-templates/{tpl['id']}",
        json={"items": []},
        headers=_h(EVAN_ID),
    )
    assert r2.status_code == 422, r2.text
    # 原 items 不应被空数组替换
    kept = await _get_template_by_name(client, name)
    assert kept is not None and len(kept["items"]) == 1, (
        "PATCH items: [] 422 后原模板 items 不应被改动"
    )
