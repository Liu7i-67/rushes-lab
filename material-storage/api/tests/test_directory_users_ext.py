"""管理后台优化 — 目录用户扩展(建用户带组/编辑用户/用户分页)集成测试(T1-T9)。

跑在 ms-api 容器里(`docker exec ms-api pytest`)。
唯一需求依据:docs/qdev/2026-10-10-admin-console-opt.md「测试功能点」T1-T9 +
「接口定义」§1-§4。

契约要点(用户扩展端点由并行任务开发中,本文件按契约编写,冲突以需求文档为准):
  - POST /admin/directory/users 入参增 `group_ids: UUID[]`(默认 [],≤50,
    须全部存在;任一无效 → 422 `invalid_group_ids` 且用户不创建,F3.3 原子)
  - GET /admin/directory/users/{user_id}(新):DirectoryUserDetailOut,
    增 `group_ids` / `group_names`(同序);404 `user_not_found`
  - PATCH /admin/directory/users/{user_id}(新):UserUpdateIn 全可选键
    (name 提供则须非空 / email 显式 null=清空 / group_ids 全量同步终态);
    diff 以 group_memberships 现状为基线,added/removed 走现有加/移成员双写;
    无效组 → 422 整体失败不变更(F4.3)
  - GET /admin/directory/users 返回改 `{items,total,limit,offset}`(D4 破坏性),
    total=同条件(q/is_active)count;limit 默认 20、上限 200
  - 审计:user_created details 增 `"group_ids":[...]`;建用户路径每组
    group_member_added details 增 `"source":"user_create"`(F3.4);
    user_updated details:`{user_id, username, changes:{name:{old,new}?,
    email:{old,new}?, groups_added:[{group_id,group_name}], groups_removed:[...]}}`(F4.4)

预期前置(同 test_directory.py):
  1. seed_demo_data.py 已跑过(Evan = 真 user + org admin / system admin;
     outsider = fake 零权限)
  2. OpenFGA store / model 已 push
  3. env=dev(允许 X-User-Id header 模拟身份)

清理惯例(同 test_project_creator.py):组在 finally 里删;用户无删除 API,
靠唯一 marker 用 q 精确圈定本测试自建数据断言,不清理(沿用 test_directory.py 现状)。
"""
from __future__ import annotations

import uuid

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import create_app

# seed 写死的真 user / fake outsider(同 test_directory.py)
EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"
OUTSIDER_ID = "00000000-0000-0000-0000-0000000000aa"
PROJECT_WEDDING = "11111111-1111-1111-1111-111111111101"   # private,seed 建

# 契约 §1/§3:组 id 无效(不存在或超 50)的 422 错误标识
_INVALID_GROUP_IDS = "invalid_group_ids"


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


# ─── 测试内现建辅助(组/用户一律测试内现建:真实 UUID + 唯一名,照现有惯例)────
async def _create_group(client: AsyncClient, prefix: str = "du_grp") -> dict:
    """现建目录组(照 test_directory.py 写法)→ 组对象 dict(id/name 全)。"""
    r = await client.post(
        "/api/v1/admin/directory/groups",
        json={"name": _uniq(prefix), "description": "directory users ext 测试组"},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text
    return r.json()


async def _create_user(
    client: AsyncClient,
    prefix: str = "du_user",
    *,
    name: str | None = None,
    email: str | None = None,
    group_ids: list[str] | None = None,
) -> dict:
    """现建本地用户(可带 name/email/group_ids)→ UserCreateOut dict。

    201 响应含 temporary_password(临时密码弹窗语义不变,F3.1 前置)。"""
    body: dict = {"username": _uniq(prefix), "name": name or f"DU {prefix}"}
    if email is not None:
        body["email"] = email
    if group_ids is not None:
        body["group_ids"] = group_ids
    r = await client.post("/api/v1/admin/directory/users", json=body, headers=_h(EVAN_ID))
    assert r.status_code == 201, r.text
    return r.json()


async def _delete_group(client: AsyncClient, gid: str) -> None:
    r = await client.delete(f"/api/v1/admin/directory/groups/{gid}", headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text


async def _get_user_detail(client: AsyncClient, uid: str) -> dict:
    """GET /admin/directory/users/{uid}(契约 §2 DirectoryUserDetailOut)。"""
    r = await client.get(f"/api/v1/admin/directory/users/{uid}", headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    return r.json()


async def _user_audit_details_list(
    client: AsyncClient, event_type: str, uid: str,
) -> list[dict]:
    """按 event_type + actor(EVAN)拉 audit,返回 details.user_id == uid 的条目。

    user_created / user_updated / group_member_added / group_member_removed 的
    details.user_id 均为被操作用户 id,故同一 helper 覆盖四类事件。"""
    r = await client.get(
        "/api/v1/admin/audit",
        params={"event_type": event_type, "actor_user_id": EVAN_ID, "limit": 500},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    return [
        e.get("details") or {} for e in r.json()
        if (e.get("details") or {}).get("user_id") == uid
    ]


# ─── T1:建用户带 2 组 → 成员落库 + 详情回显 + 审计(F3.2/F3.4)────────────────
@pytest.mark.asyncio
async def test_create_user_with_two_groups_members_and_audit(
    client: AsyncClient,
) -> None:
    """T1:POST users 带 group_ids=[g1,g2] → 201;两组各含该成员(DB 成员接口);
    详情端点回显 group_ids/group_names;审计 user_created(details.group_ids)+
    2 条 group_member_added(details.source="user_create")。"""
    g1 = await _create_group(client, "du_t1a")
    g2 = await _create_group(client, "du_t1b")
    try:
        u = await _create_user(
            client, "du_t1", name="T1 带组用户", group_ids=[g1["id"], g2["id"]],
        )
        uid = u["id"]
        assert u["username"] and u["is_active"] is True
        assert u["must_change_password"] is True
        assert len(u["temporary_password"]) >= 8   # 临时密码弹窗语义不变(F3.1)
        assert "password_hash" not in u

        # 详情端点(契约 §2):group_ids / group_names 同序回显
        detail = await _get_user_detail(client, uid)
        assert set(detail["group_ids"]) == {g1["id"], g2["id"]}, detail
        # 同序配对:id→name 映射与建组事实一致(契约「group_names 与 group_ids 同序」)
        assert dict(zip(detail["group_ids"], detail["group_names"], strict=True)) == {
            g1["id"]: g1["name"], g2["id"]: g2["name"],
        }, detail

        # DB 成员落库:既有组成员接口可见(加成员双写与手工加人完全一致)
        for g in (g1, g2):
            rm = await client.get(
                f"/api/v1/admin/directory/groups/{g['id']}/members", headers=_h(EVAN_ID),
            )
            assert rm.status_code == 200, rm.text
            assert any(m["user_id"] == uid for m in rm.json()), rm.json()

        # 审计:user_created details 增 group_ids(F3.4)
        created = await _user_audit_details_list(client, "user_created", uid)
        assert len(created) == 1, created
        assert set(created[0]["group_ids"]) == {g1["id"], g2["id"]}, created

        # 审计:每成功一组一条 group_member_added,details.source="user_create"
        added = await _user_audit_details_list(client, "group_member_added", uid)
        assert len(added) == 2, added
        assert {d["group_id"] for d in added} == {g1["id"], g2["id"]}, added
        assert all(d.get("source") == "user_create" for d in added), added
    finally:
        await _delete_group(client, g1["id"])
        await _delete_group(client, g2["id"])


# ─── T2:group_ids 含不存在 UUID → 422 原子(用户不创建)──────────────────────
@pytest.mark.asyncio
async def test_create_user_invalid_group_422_atomic(client: AsyncClient) -> None:
    """T2:全 ghost 组 / 真 ghost 混合,均 422 invalid_group_ids 且用户不存在
    (F3.3:组 id 全部预先校验,原子无半吊子)。"""
    uname = _uniq("du_t2_ghost")
    r = await client.post(
        "/api/v1/admin/directory/users",
        json={"username": uname, "name": "T2 全 ghost",
              "group_ids": [str(uuid.uuid4())]},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 422, r.text
    assert _INVALID_GROUP_IDS in r.text, r.text

    g = await _create_group(client, "du_t2")
    try:
        uname2 = _uniq("du_t2_mixed")
        r2 = await client.post(
            "/api/v1/admin/directory/users",
            json={"username": uname2, "name": "T2 混合",
                  "group_ids": [g["id"], str(uuid.uuid4())]},
            headers=_h(EVAN_ID),
        )
        assert r2.status_code == 422, r2.text
        assert _INVALID_GROUP_IDS in r2.text, r2.text

        # 原子性:两个用户名均不存在(q 圈定 + items 判空,D4 新返回结构)
        rl = await client.get(
            "/api/v1/admin/directory/users",
            params={"q": "du_t2_", "limit": 200}, headers=_h(EVAN_ID),
        )
        assert rl.status_code == 200, rl.text
        names = {u["username"] for u in rl.json()["items"]}
        assert uname not in names and uname2 not in names, rl.json()

        # 真组也不得残留成员(422 前未写任何组)
        rm = await client.get(
            f"/api/v1/admin/directory/groups/{g['id']}/members", headers=_h(EVAN_ID),
        )
        assert all(m["user_id"] not in {u.get("id") for u in rl.json()["items"]}
                   for m in rm.json()), rm.json()
    finally:
        await _delete_group(client, g["id"])


# ─── T3:group_ids > 50 → 422(D9)────────────────────────────────────────────
@pytest.mark.asyncio
async def test_create_user_with_51_groups_422(client: AsyncClient) -> None:
    """T3:51 个**真实存在**的组仍 422(证明是条数上限而非存在性校验拦下),
    用户不创建;组在 finally 全部清理。"""
    gids: list[str] = []
    try:
        for i in range(51):
            g = await _create_group(client, f"du_t3_{i}")
            gids.append(g["id"])

        uname = _uniq("du_t3_many")
        r = await client.post(
            "/api/v1/admin/directory/users",
            json={"username": uname, "name": "T3 超 50 组", "group_ids": gids},
            headers=_h(EVAN_ID),
        )
        assert r.status_code == 422, r.text
        assert _INVALID_GROUP_IDS in r.text, r.text

        # 用户未创建
        rl = await client.get(
            "/api/v1/admin/directory/users",
            params={"q": uname, "limit": 200}, headers=_h(EVAN_ID),
        )
        assert all(u["username"] != uname for u in rl.json()["items"]), rl.json()
    finally:
        for gid in gids:
            await _delete_group(client, gid)


# ─── T4:PATCH 改 name+email → 生效 + user_updated 审计带 old/new(F4.2/F4.4)──
@pytest.mark.asyncio
async def test_patch_user_name_email_and_audit(client: AsyncClient) -> None:
    """T4:PATCH name/email → 响应与详情均生效;user_updated.details.changes
    含 {old,new};顺带校验 name 提供则须非空 / 超长 → 422 且不变更(契约 §3)。"""
    old_email = f"{_uniq('du_t4')}@example.com"
    u = await _create_user(client, "du_t4", name="T4 原名", email=old_email)
    uid = u["id"]
    new_email = f"{_uniq('du_t4_new')}@example.com"

    r = await client.patch(
        f"/api/v1/admin/directory/users/{uid}",
        json={"name": "T4 新名", "email": new_email},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["name"] == "T4 新名" and body["email"] == new_email, body
    assert "password_hash" not in body   # 返回 DirectoryUserOut,不泄露 hash

    detail = await _get_user_detail(client, uid)
    assert detail["name"] == "T4 新名" and detail["email"] == new_email, detail

    # 审计:user_updated.details.changes 带 old/new(F4.4)
    events = await _user_audit_details_list(client, "user_updated", uid)
    assert len(events) == 1, events
    assert events[0]["user_id"] == uid and events[0]["username"] == u["username"], events
    changes = events[0]["changes"]
    assert changes.get("name") == {"old": "T4 原名", "new": "T4 新名"}, changes
    assert changes.get("email") == {"old": old_email, "new": new_email}, changes

    # name 提供则须非空(契约 §3)→ 422 且 name 不变
    r2 = await client.patch(
        f"/api/v1/admin/directory/users/{uid}",
        json={"name": ""}, headers=_h(EVAN_ID),
    )
    assert r2.status_code == 422, r2.text
    # name 超 128 → 422(Pydantic max_length)
    r3 = await client.patch(
        f"/api/v1/admin/directory/users/{uid}",
        json={"name": "x" * 129}, headers=_h(EVAN_ID),
    )
    assert r3.status_code == 422, r3.text
    assert (await _get_user_detail(client, uid))["name"] == "T4 新名"


# ─── T5:PATCH email=null → 清空;缺省键=不改(D6/契约 §3)─────────────────────
@pytest.mark.asyncio
async def test_patch_user_email_null_clears(client: AsyncClient) -> None:
    """T5:先「仅改名的不带 email PATCH」→ email 保持(缺省=不改);
    再显式 email=null → 清空(D6);详情端点同样为 null。"""
    email = f"{_uniq('du_t5')}@example.com"
    u = await _create_user(client, "du_t5", name="T5 用户", email=email)
    uid = u["id"]

    # 缺省(不带 email 键)≠ 清空
    r = await client.patch(
        f"/api/v1/admin/directory/users/{uid}",
        json={"name": "T5 改名"}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    assert r.json()["email"] == email, r.json()

    # 显式 null → 清空
    r2 = await client.patch(
        f"/api/v1/admin/directory/users/{uid}",
        json={"email": None}, headers=_h(EVAN_ID),
    )
    assert r2.status_code == 200, r2.text
    assert r2.json()["email"] is None, r2.json()
    assert (await _get_user_detail(client, uid))["email"] is None

    # 改名不得把 name 也动掉(只提交的字段生效)
    r3 = await client.patch(
        f"/api/v1/admin/directory/users/{uid}",
        json={"email": f"{_uniq('du_t5b')}@example.com"}, headers=_h(EVAN_ID),
    )
    assert r3.status_code == 200, r3.text
    assert r3.json()["name"] == "T5 改名", r3.json()


# ─── T6:PATCH group_ids 全量同步(换 1 加 1 移)+ FGA 立即生效 + 2 条成员审计 ──
@pytest.mark.asyncio
async def test_patch_user_groups_full_sync_fga_and_audit(
    client: AsyncClient,
) -> None:
    """T6:基线 [ga,gb] → PATCH 终态 [gb,gc](移 ga 加 gc)。

    终态:详情回显 + 组成员接口;FGA 生效:ga 挂 seed 私有项目 viewer,
    移出后立即 403;gc 挂 viewer 后立即 200(D3 全量同步走现有加/移双写);
    审计:user_updated.changes.groups_added/removed + 各 1 条
    group_member_added / group_member_removed。"""
    ga = await _create_group(client, "du_t6a")
    gb = await _create_group(client, "du_t6b")
    gc = await _create_group(client, "du_t6c")
    try:
        u = await _create_user(
            client, "du_t6", name="T6 换组用户", group_ids=[ga["id"], gb["id"]],
        )
        uid = u["id"]

        # FGA 基线:ga 挂 PROJECT_WEDDING viewer → 组员立即可见(既有机制)
        r_attach = await client.post(
            f"/api/v1/projects/{PROJECT_WEDDING}/members",
            json={"group_id": ga["id"], "role": "viewer"}, headers=_h(EVAN_ID),
        )
        assert r_attach.status_code == 204, r_attach.text
        r_view = await client.get(f"/api/v1/projects/{PROJECT_WEDDING}", headers=_h(uid))
        assert r_view.status_code == 200, f"ga 组员应立即可见: {r_view.text}"

        # 全量同步:终态 {gb, gc}
        r = await client.patch(
            f"/api/v1/admin/directory/users/{uid}",
            json={"group_ids": [gb["id"], gc["id"]]}, headers=_h(EVAN_ID),
        )
        assert r.status_code == 200, r.text

        # 终态:详情回显(gb,gc;同序配对)+ 组成员接口
        detail = await _get_user_detail(client, uid)
        assert set(detail["group_ids"]) == {gb["id"], gc["id"]}, detail
        assert dict(zip(detail["group_ids"], detail["group_names"], strict=True)) == {
            gb["id"]: gb["name"], gc["id"]: gc["name"],
        }, detail
        rm_a = await client.get(
            f"/api/v1/admin/directory/groups/{ga['id']}/members", headers=_h(EVAN_ID),
        )
        assert all(m["user_id"] != uid for m in rm_a.json()), "ga 不应再含该用户"
        rm_c = await client.get(
            f"/api/v1/admin/directory/groups/{gc['id']}/members", headers=_h(EVAN_ID),
        )
        assert any(m["user_id"] == uid for m in rm_c.json()), "gc 应含该用户"

        # FGA 移出生效:ga tuple 已撤 → 立即失去 can_view
        r_view2 = await client.get(f"/api/v1/projects/{PROJECT_WEDDING}", headers=_h(uid))
        assert r_view2.status_code == 403, "移出 ga 后应立即失去 can_view"

        # FGA 加入生效:gc 挂 viewer → 立即可见
        r_attach2 = await client.post(
            f"/api/v1/projects/{PROJECT_WEDDING}/members",
            json={"group_id": gc["id"], "role": "viewer"}, headers=_h(EVAN_ID),
        )
        assert r_attach2.status_code == 204, r_attach2.text
        r_view3 = await client.get(f"/api/v1/projects/{PROJECT_WEDDING}", headers=_h(uid))
        assert r_view3.status_code == 200, f"gc 组员应立即可见: {r_view3.text}"

        # 审计:user_updated.changes.groups_added/removed(F4.4)
        events = await _user_audit_details_list(client, "user_updated", uid)
        assert len(events) == 1, events
        changes = events[0]["changes"]
        assert [x["group_id"] for x in changes.get("groups_added", [])] == [gc["id"]], changes
        assert {x["group_name"] for x in changes.get("groups_added", [])} == {gc["name"]}, changes
        assert [x["group_id"] for x in changes.get("groups_removed", [])] == [ga["id"]], changes

        # 审计:PATCH 路径恰好各 1 条成员事件(双写路径与手工加/移一致);
        # 排除建用户路径(F3.4,本用户带 ga/gb 两组 → source="user_create" 2 条)
        added = [d for d in await _user_audit_details_list(client, "group_member_added", uid)
                 if d.get("source") != "user_create"]
        assert len(added) == 1 and added[0]["group_id"] == gc["id"], added
        removed = await _user_audit_details_list(client, "group_member_removed", uid)
        assert len(removed) == 1 and removed[0]["group_id"] == ga["id"], removed
    finally:
        # 组删除顺手删组主体 tuple(既有惯例),seed 项目的挂载随之失效
        await _delete_group(client, ga["id"])
        await _delete_group(client, gb["id"])
        await _delete_group(client, gc["id"])


# ─── T7:PATCH 不存在用户 404;无效组 422 且整体不变更(F4.3)─────────────────
@pytest.mark.asyncio
async def test_patch_user_404_and_invalid_group_no_change(client: AsyncClient) -> None:
    """T7:PATCH ghost 用户 → 404;PATCH group_ids 含无效组 → 422 invalid_group_ids
    且 name/email/组成员**均不变更**(先全量校验再落库)。"""
    r = await client.patch(
        f"/api/v1/admin/directory/users/{uuid.uuid4()}",
        json={"name": "幽灵改名"}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 404, r.text

    g = await _create_group(client, "du_t7")
    try:
        email = f"{_uniq('du_t7')}@example.com"
        u = await _create_user(
            client, "du_t7", name="T7 原名", email=email, group_ids=[g["id"]],
        )
        uid = u["id"]

        r2 = await client.patch(
            f"/api/v1/admin/directory/users/{uid}",
            json={
                "name": "T7 新名",
                "email": f"{_uniq('du_t7_new')}@example.com",
                "group_ids": [str(uuid.uuid4())],   # 无效组 → 整体失败
            },
            headers=_h(EVAN_ID),
        )
        assert r2.status_code == 422, r2.text
        assert _INVALID_GROUP_IDS in r2.text, r2.text

        # 不变更:三字段全部保持原值
        detail = await _get_user_detail(client, uid)
        assert detail["name"] == "T7 原名", detail
        assert detail["email"] == email, detail
        assert set(detail["group_ids"]) == {g["id"]}, detail
    finally:
        await _delete_group(client, g["id"])


# ─── T8:GET users 分页 {items,total,limit,offset} + q/is_active total(D4/F5)─
@pytest.mark.asyncio
async def test_users_list_pagination_total_and_filters(client: AsyncClient) -> None:
    """T8:q 圈定 6 个自建用户(5 active + 1 disabled)→ total/翻页/q 过滤/
    is_active 过滤;返回结构为 {items,total,limit,offset},limit 默认 20(契约 §4)。"""
    marker = _uniq("dupage")   # q 只命中本测试自建 name(username 不含 marker)
    sub = f"{marker} zeta"     # 其中 2 个的 name 前缀,做 q 收窄断言
    names = [sub, sub, f"{marker} a", f"{marker} b", f"{marker} c"]
    uids: list[str] = []
    for i, nm in enumerate(names):
        u = await _create_user(client, f"du_t8_{i}", name=nm)
        uids.append(u["id"])
    # 第 6 个:同 marker 但禁用(is_active=false 过滤对象)
    dis = await _create_user(client, "du_t8_dis", name=f"{marker} disabled")
    rd = await client.post(
        f"/api/v1/admin/directory/users/{dis['id']}/disable", headers=_h(EVAN_ID),
    )
    assert rd.status_code == 200, rd.text

    # 全量(新返回结构 D4)
    full = await client.get(
        "/api/v1/admin/directory/users",
        params={"q": marker, "limit": 200}, headers=_h(EVAN_ID),
    )
    assert full.status_code == 200, full.text
    body = full.json()
    assert set(body.keys()) >= {"items", "total", "limit", "offset"}, body.keys()
    assert body["total"] == 6, f"q 应恰好圈定本测试 6 个用户: {body}"
    assert body["limit"] == 200 and body["offset"] == 0, body
    assert {u["id"] for u in body["items"]} == {*uids, dis["id"]}, body
    assert all("password_hash" not in u for u in body["items"])

    # q 过滤后 total=过滤值
    rsub = await client.get(
        "/api/v1/admin/directory/users",
        params={"q": sub, "limit": 200}, headers=_h(EVAN_ID),
    )
    assert rsub.json()["total"] == 2, rsub.json()
    assert {u["id"] for u in rsub.json()["items"]} == set(uids[:2]), rsub.json()

    # is_active 过滤 total 一致(与 q 叠加同条件 count,F5.1)
    ract = await client.get(
        "/api/v1/admin/directory/users",
        params={"q": marker, "is_active": True, "limit": 200}, headers=_h(EVAN_ID),
    )
    assert ract.json()["total"] == 5, ract.json()
    rin = await client.get(
        "/api/v1/admin/directory/users",
        params={"q": marker, "is_active": False, "limit": 200}, headers=_h(EVAN_ID),
    )
    assert rin.json()["total"] == 1, rin.json()
    assert rin.json()["items"][0]["id"] == dis["id"], rin.json()
    assert rin.json()["items"][0]["is_active"] is False

    # 翻页:limit=2 切窗,各页不重叠、按序拼接 == 全量(排序稳定)
    pages: list[list[str]] = []
    for off in (0, 2, 4, 6):
        rp = await client.get(
            "/api/v1/admin/directory/users",
            params={"q": marker, "limit": 2, "offset": off}, headers=_h(EVAN_ID),
        )
        assert rp.status_code == 200, rp.text
        pb = rp.json()
        assert pb["total"] == 6 and pb["limit"] == 2 and pb["offset"] == off, pb
        pages.append([u["id"] for u in pb["items"]])
    assert len(pages[3]) == 0, "offset=total 处应为空页"
    flat = pages[0] + pages[1] + pages[2]
    assert flat == [u["id"] for u in body["items"]], "offset 窗口应稳定:各页按序拼接 == 全量"
    assert len(set(flat)) == 6, "页间不得重叠"

    # 默认 limit=20(契约 §4:默认 20,≤200)
    rdef = await client.get("/api/v1/admin/directory/users", headers=_h(EVAN_ID))
    assert rdef.status_code == 200, rdef.text
    assert rdef.json()["limit"] == 20, rdef.json().get("limit")


# ─── T9:非 system admin 调 建用户/用户详情/PATCH → 403 ───────────────────────
@pytest.mark.asyncio
async def test_non_admin_forbidden_on_user_write_and_detail(client: AsyncClient) -> None:
    """T9:outsider(零权限)POST 建用户 / GET 用户详情 / PATCH 均在守门层 403;
    越权 PATCH 不得生效(403 先于 404 与变更)。"""
    u = await _create_user(client, "du_t9", name="T9 目标用户")
    uid = u["id"]

    # 建用户 403
    r = await client.post(
        "/api/v1/admin/directory/users",
        json={"username": _uniq("du_t9x"), "name": "T9 不该存在"},
        headers=_h(OUTSIDER_ID),
    )
    assert r.status_code == 403, r.text

    # 用户详情 403(新端点守门 system admin,契约 §2)
    r2 = await client.get(f"/api/v1/admin/directory/users/{uid}", headers=_h(OUTSIDER_ID))
    assert r2.status_code == 403, r2.text

    # PATCH 403(真实目标,证明守门先于存在性/变更)
    r3 = await client.patch(
        f"/api/v1/admin/directory/users/{uid}",
        json={"name": "T9 越权改名"}, headers=_h(OUTSIDER_ID),
    )
    assert r3.status_code == 403, r3.text

    # 越权 PATCH 不得生效
    assert (await _get_user_detail(client, uid))["name"] == "T9 目标用户"
