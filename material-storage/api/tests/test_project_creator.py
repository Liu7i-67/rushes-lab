"""PR-2 组级「新建项目」权限 — 集成测试,跑在 ms-api 容器里(`docker exec ms-api pytest`)。

对应权威技术方案:`rushes-spec/material-storage/netdisk-import-batch-rename-roles-plan.md`
§2.6(测试清单,本文件用例编号 1-7)+ §2.2/§2.3/§2.4/§2.5(语义);接口契约表见
`docs/qdev/2026-10-08-batch-prefix-creator-template.md`「接口定义」。

契约要点(实现并行开发中,本文件按契约编写,两处冲突以方案为准):
  - POST /api/v1/admin/directory/groups 增 `can_create_project: bool = False`;
    PATCH /{gid} 增 tri-state `can_create_project: bool | None = None`(None=不动);
    DirectoryGroupOut 增 `can_create_project` 回显(create/update 按入参回填,
    组列表按真实 tuple 定向 read)
  - flag 写/删 `organization:<tenant_key>#project_creator` 的 `group:<gid>#member`
    tuple;组删除顺手删 tuple;audit `group_created`/`group_updated` details 增
    can_create_project
  - POST /projects 守门换 require_project_creator(口径 = is_org_admin ∨
    project_creator);非系统 admin 强制忽略 payload.organization_id 与
    minio_bucket(服务端默认值)
  - 弱门:GET /users、GET /groups、GET /admin/grant-templates 对 project creator
    放行;grant-templates 写端点(POST/PATCH/DELETE)保持 system admin
  - /me 增 is_project_creator(与守门同口径);GET /users 增 offset 且排序改
    (User.name, User.id) 含 tiebreaker
  - USER_DIRECT_RELATIONS 补 ("organization", "project_creator"):禁用闭环不得
    误删组主体 tuple

预期前置(同 test_v4_permissions.py):
  1. seed_demo_data.py 已跑过(Evan = 真 user + org admin;outsider = fake 零权限)
  2. OpenFGA store / model 已 push(含 project_creator relation)
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

# require_system_admin 的既有 403 文案(deps.py);契约表要求 create_project
# 守门的 403 文案与之区分(可辨识「缺新建项目权限」而非「非系统管理员」)
_REQUIRE_SYSTEM_ADMIN_COPY = (
    "system admin permission required(只有系统管理员可执行此操作)"
)


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


def _project_code() -> str:
    """项目 code 唯一(projects_code_key);pattern 限 ^[a-z0-9][a-z0-9\\-]*$。"""
    return f"pc-{uuid.uuid4().hex[:12]}"


# ─── 测试内现建辅助(seed 不写 groups 表数据,组一律测试内现建:真实 UUID+name)──
async def _create_group(
    client: AsyncClient, *, prefix: str = "pc_grp", can_create_project: bool = False,
) -> str:
    """现建目录组(照 test_directory.py 写法),可携带 can_create_project → gid。"""
    body: dict = {"name": _uniq(prefix), "description": "project_creator 测试组"}
    if can_create_project:
        body["can_create_project"] = True
    r = await client.post("/api/v1/admin/directory/groups", json=body, headers=_h(EVAN_ID))
    assert r.status_code == 201, r.text
    return r.json()["id"]


async def _create_user(client: AsyncClient, prefix: str = "pc_user") -> str:
    """现建 active 本地用户 → users.id。"""
    uname = _uniq(prefix)
    r = await client.post(
        "/api/v1/admin/directory/users",
        json={"username": uname, "name": f"PC {prefix}"},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text
    return r.json()["id"]


async def _add_group_member(client: AsyncClient, gid: str, uid: str) -> None:
    r = await client.post(
        f"/api/v1/admin/directory/groups/{gid}/members",
        json={"user_id": uid}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text


async def _remove_group_member(client: AsyncClient, gid: str, uid: str) -> None:
    r = await client.delete(
        f"/api/v1/admin/directory/groups/{gid}/members/{uid}", headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text


async def _delete_group(client: AsyncClient, gid: str) -> None:
    r = await client.delete(f"/api/v1/admin/directory/groups/{gid}", headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text


async def _default_org() -> tuple[str, str]:
    """default org 的 (org_id, tenant_key) —— OpenFGA organization object 用 tenant_key。"""
    from app.db.session import get_sessionmaker
    from app.services.org import get_default_organization

    async with get_sessionmaker()() as db:
        org = await get_default_organization(db)
    assert org is not None, "测试前置:settings.default_organization_id 未配置"
    return str(org[0]), org[1]


async def _creator_flag_on(perms, gid: str, tenant_key: str) -> bool:
    """组主体是否持有 organization#project_creator(组主体直查,check 自动展开)。"""
    return await perms.check(
        user_subject=f"group:{gid}#member", relation="project_creator",
        object_type="organization", object_id=tenant_key,
    )


async def _read_creator_tuple_exact(perms, gid: str, tenant_key: str) -> list:
    """全键 read 精确匹配组主体 tuple(user=group:<gid>#member)。

    check 只能回答「有/无」,无法证明 tuple 的 user 恰为组主体(而非被禁用的
    user 直连 tuple);部分键 read 该 SDK/服务端不支持(test_directory.py 已有
    结论),故用 user+relation+object 全键 read。
    """
    from openfga_sdk.models import ReadRequestTupleKey

    resp = await perms._client.read(ReadRequestTupleKey(  # type: ignore[attr-defined]
        user=f"group:{gid}#member", relation="project_creator",
        object=f"organization:{tenant_key}",
    ))
    return list(resp.tuples)


async def _group_audit_details_list(
    client: AsyncClient, event_type: str, gid: str,
) -> list[dict]:
    """按 event_type + actor 拉 audit,返回 details.group_id == gid 的全部条目。"""
    r = await client.get(
        "/api/v1/admin/audit",
        params={"event_type": event_type, "actor_user_id": EVAN_ID, "limit": 500},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    return [
        e.get("details") or {} for e in r.json()
        if (e.get("details") or {}).get("group_id") == gid
    ]


async def _list_group_echo(client: AsyncClient, gid: str, name: str) -> dict | None:
    """组列表按唯一 name 取回(回显真实 tuple 态;无组详情路由,编辑数据源即列表)。"""
    r = await client.get(
        "/api/v1/admin/directory/groups", params={"q": name}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    hits = [g for g in r.json() if g["id"] == gid]
    return hits[0] if hits else None


# ─── 用例 1:组 CRUD flag → tuple 写删 + 回显 + audit(方案 §2.6)──────────────
@pytest.mark.asyncio
async def test_group_create_flag_writes_tuple_and_echoes(
    client: AsyncClient, app_with_lifespan,
) -> None:
    """用例 1a:create 带 can_create_project=true → organization#project_creator
    有 group:<gid>#member tuple;create 响应与组列表均回显 can_create_project;
    group_created audit details 带 can_create_project。"""
    perms = app_with_lifespan.state.permissions
    _, tenant_key = await _default_org()

    gname = _uniq("pc_flag")
    r = await client.post(
        "/api/v1/admin/directory/groups",
        json={"name": gname, "can_create_project": True},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text
    body = r.json()
    gid = body["id"]
    try:
        # create 响应按入参回填(方案 §2.2)
        assert body["can_create_project"] is True, body

        # tuple 就位:组主体 check 命中 + 全键 read 精确匹配(SDK tuple 字段在 .key 下)
        assert await _creator_flag_on(perms, gid, tenant_key) is True
        tuples = await _read_creator_tuple_exact(perms, gid, tenant_key)
        assert len(tuples) == 1, tuples
        assert tuples[0].key.user == f"group:{gid}#member"
        assert tuples[0].key.relation == "project_creator"
        assert tuples[0].key.object == f"organization:{tenant_key}"

        # 组列表回显真实态(定向 read;方案 §2.2「flag 读回」)
        echo = await _list_group_echo(client, gid, gname)
        assert echo is not None, f"组列表应能按 name 找到: {gname}"
        assert echo["can_create_project"] is True, echo

        # audit details 带 can_create_project(方案 §2.2,不新增 event_type)
        events = await _group_audit_details_list(client, "group_created", gid)
        assert len(events) == 1, events
        assert events[0]["can_create_project"] is True, events
    finally:
        await _delete_group(client, gid)


@pytest.mark.asyncio
async def test_group_update_flag_tri_state_and_idempotent_clear(
    client: AsyncClient, app_with_lifespan,
) -> None:
    """用例 1b:update false → tuple 删;**仅改名的不带字段 PATCH → tuple 不动**
    (tri-state 防回归:非 Optional 布尔会把省略解析成 False 静默撤权);重复清除
    幂等(不 500);group_updated audit details 带字段。"""
    perms = app_with_lifespan.state.permissions
    _, tenant_key = await _default_org()
    gid = await _create_group(client, can_create_project=True)
    try:
        assert await _creator_flag_on(perms, gid, tenant_key) is True

        # 仅改名、PATCH body 不带 can_create_project 字段 → tuple 必须原样
        new_name = _uniq("pc_flag_renamed")
        r = await client.patch(
            f"/api/v1/admin/directory/groups/{gid}",
            json={"name": new_name},
            headers=_h(EVAN_ID),
        )
        assert r.status_code == 200, r.text
        assert await _creator_flag_on(perms, gid, tenant_key) is True, (
            "仅改名的不带字段 PATCH 不得撤 tuple(GroupUpdateIn 必须 tri-state)"
        )
        echo = await _list_group_echo(client, gid, new_name)
        assert echo is not None and echo["can_create_project"] is True, "改名后回显仍为 true"

        # update false → tuple 删 + 列表回显 False
        r2 = await client.patch(
            f"/api/v1/admin/directory/groups/{gid}",
            json={"can_create_project": False},
            headers=_h(EVAN_ID),
        )
        assert r2.status_code == 200, r2.text
        assert await _creator_flag_on(perms, gid, tenant_key) is False
        echo2 = await _list_group_echo(client, gid, new_name)
        assert echo2 is not None and echo2["can_create_project"] is False, echo2

        # 重复清除幂等:第二次 PATCH false 也是 200,不 500
        for _ in range(2):
            r3 = await client.patch(
                f"/api/v1/admin/directory/groups/{gid}",
                json={"can_create_project": False},
                headers=_h(EVAN_ID),
            )
            assert r3.status_code == 200, r3.text
        assert await _creator_flag_on(perms, gid, tenant_key) is False

        # audit:存在带 can_create_project=False 的 group_updated 条目
        events = await _group_audit_details_list(client, "group_updated", gid)
        assert any(e.get("can_create_project") is False for e in events), events
    finally:
        await _delete_group(client, gid)


@pytest.mark.asyncio
async def test_group_delete_removes_creator_tuple(
    client: AsyncClient, app_with_lifespan,
) -> None:
    """用例 1c:组删除后 organization#project_creator 的组主体 tuple 不残留。"""
    perms = app_with_lifespan.state.permissions
    _, tenant_key = await _default_org()
    gid = await _create_group(client, can_create_project=True)
    assert await _creator_flag_on(perms, gid, tenant_key) is True

    await _delete_group(client, gid)
    left = await _read_creator_tuple_exact(perms, gid, tenant_key)
    assert left == [], f"组删除应顺手删 project_creator tuple,不得残留: {left}"


# ─── 用例 2:守门(组员 201 / 移出组 403 / 非组员 403 / 系统 admin 201)─────────
@pytest.mark.asyncio
async def test_group_member_create_project_gate(client: AsyncClient) -> None:
    """用例 2(守门):组员 POST /projects 201(admin_user_id=自己:bootstrap 后
    是项目 admin、成员抽屉可列,initial_grants 可同时携带);移出组后 403 但已建
    项目不受影响(方案 §2.5);非组员非 admin(outsider)403 且文案与
    require_system_admin 区分(契约表);系统 admin 恒可建 201。"""
    gid = await _create_group(client, can_create_project=True)
    uid = await _create_user(client)
    await _add_group_member(client, gid, uid)
    helper_uid = await _create_user(client, "pc_helper")
    try:
        body = {
            "code": _project_code(),
            "name": _uniq("组长自建项目"),
            "minio_bucket": "ms-dev",
            "admin_user_id": uid,
            "initial_grants": [{"kind": "user", "id": helper_uid, "roles": ["viewer"]}],
        }
        r = await client.post("/api/v1/projects", json=body, headers=_h(uid))
        assert r.status_code == 201, r.text
        pid = r.json()["id"]

        # bootstrap 生效:创建者(admin_user_id=自己)是项目 admin
        r_me = await client.get(f"/api/v1/projects/{pid}", headers=_h(uid))
        assert r_me.status_code == 200, r_me.text
        assert "admin" in r_me.json()["my_roles"], r_me.json().get("my_roles")

        # 成员抽屉正常:创建者 admin + initial_grants 的 viewer 同时就位
        r_m = await client.get(f"/api/v1/projects/{pid}/members", headers=_h(uid))
        assert r_m.status_code == 200, r_m.text
        roles = {m["subject"]: set(m["roles"]) for m in r_m.json()}
        assert "admin" in roles.get(f"user:{uid}", set()), roles
        assert "viewer" in roles.get(f"user:{helper_uid}", set()), roles

        # 移出组 → 立即失建项目能力;已建项目不受影响
        await _remove_group_member(client, gid, uid)
        body2 = dict(body, code=_project_code(), name=_uniq("移出组后再建"))
        r2 = await client.post("/api/v1/projects", json=body2, headers=_h(uid))
        assert r2.status_code == 403, r2.text
        r3 = await client.get(f"/api/v1/projects/{pid}", headers=_h(uid))
        assert r3.status_code == 200, "flag 撤销不得影响组员已建的项目"

        # 非组员非 admin → 403,且文案与 require_system_admin 区分(契约表)
        body3 = dict(body2, admin_user_id=EVAN_ID)
        r4 = await client.post("/api/v1/projects", json=body3, headers=_h(OUTSIDER_ID))
        assert r4.status_code == 403, r4.text
        assert r4.json().get("detail") != _REQUIRE_SYSTEM_ADMIN_COPY, (
            f"守门 403 文案须与 require_system_admin 区分: {r4.text}"
        )

        # 系统 admin(org admin)恒可建,不受组 flag 影响
        r5 = await client.post("/api/v1/projects", json=body3, headers=_h(EVAN_ID))
        assert r5.status_code == 201, r5.text
    finally:
        await _delete_group(client, gid)


# ─── 用例 3:非 admin 创建者的 organization_id / minio_bucket 服务端收口 ───────
@pytest.mark.asyncio
async def test_non_admin_create_ignores_organization_and_bucket(
    client: AsyncClient, app_with_lifespan,
) -> None:
    """用例 3(收口):非 admin 创建者 POST 带 organization_id(随机 UUID)与
    minio_bucket:"evil-bucket" → 201,但项目落在 default org 且 bucket 为服务端
    默认值 —— 否则 creator 可 API 直调把项目 bootstrap 到任意 org / 指到任意
    bucket(方案 §2.3 新开的提权口)。方案 §2.3 写明「前端固定 ms-dev」「bucket
    默认 ms-dev」,故服务端默认值按 ms-dev 断言。"""
    gid = await _create_group(client, can_create_project=True)
    uid = await _create_user(client)
    await _add_group_member(client, gid, uid)
    org_id, _tenant_key = await _default_org()
    try:
        r = await client.post(
            "/api/v1/projects",
            json={
                "code": _project_code(),
                "name": _uniq("收口项目"),
                "organization_id": str(uuid.uuid4()),   # 随机 org,必须被强制忽略
                "minio_bucket": "evil-bucket",          # 攻击者自指 bucket,必须被强制忽略
                "admin_user_id": uid,
            },
            headers=_h(uid),
        )
        assert r.status_code == 201, r.text
        body = r.json()
        assert str(body["organization_id"]) == org_id, (
            f"非 admin 的 organization_id 必须被忽略,项目应落 default org: {body}"
        )
        assert body["minio_bucket"] != "evil-bucket", body
        assert body["minio_bucket"] == "ms-dev", (
            f"非 admin 的 minio_bucket 必须为服务端默认值 ms-dev(方案 §2.3): {body}"
        )
    finally:
        await _delete_group(client, gid)


# ─── 用例 4:弱门放宽(读放行 / 模板写保持 system admin)───────────────────────
@pytest.mark.asyncio
async def test_weak_gate_reads_allowed_writes_denied(client: AsyncClient) -> None:
    """用例 4(弱门):零项目组员 GET /users、GET /groups、
    GET /admin/grant-templates → 200(否则零项目组长填不了表单);grant-templates
    写端点(POST/PATCH/DELETE)保持 require_system_admin → 403。"""
    gid = await _create_group(client, can_create_project=True)
    uid = await _create_user(client)
    await _add_group_member(client, gid, uid)
    try:
        r = await client.get("/api/v1/users", params={"limit": 5}, headers=_h(uid))
        assert r.status_code == 200, r.text
        r2 = await client.get("/api/v1/groups", params={"limit": 5}, headers=_h(uid))
        assert r2.status_code == 200, r2.text
        r3 = await client.get("/api/v1/admin/grant-templates", headers=_h(uid))
        assert r3.status_code == 200, r3.text

        ghost = str(uuid.uuid4())
        r4 = await client.post(
            "/api/v1/admin/grant-templates",
            json={
                "name": _uniq("弱门禁写"),
                "items": [{"kind": "user", "id": uid, "roles": ["viewer"]}],
            },
            headers=_h(uid),
        )
        assert r4.status_code == 403, r4.text
        r5 = await client.patch(
            f"/api/v1/admin/grant-templates/{ghost}",
            json={"name": _uniq("弱门禁改")},
            headers=_h(uid),
        )
        assert r5.status_code == 403, r5.text
        r6 = await client.delete(
            f"/api/v1/admin/grant-templates/{ghost}", headers=_h(uid),
        )
        assert r6.status_code == 403, r6.text
    finally:
        await _delete_group(client, gid)


# ─── 用例 5:/me is_project_creator 与守门同口径 ───────────────────────────────
@pytest.mark.asyncio
async def test_me_is_project_creator(client: AsyncClient) -> None:
    """用例 5(/me):组员 is_project_creator=true;移出组后 false;
    系统 admin true(口径含 org admin);outsider false。"""
    gid = await _create_group(client, can_create_project=True)
    uid = await _create_user(client)
    await _add_group_member(client, gid, uid)
    try:
        me = (await client.get("/api/v1/auth/me", headers=_h(uid))).json()
        assert me["is_project_creator"] is True, me

        await _remove_group_member(client, gid, uid)
        me2 = (await client.get("/api/v1/auth/me", headers=_h(uid))).json()
        assert me2["is_project_creator"] is False, me2

        me_admin = (await client.get("/api/v1/auth/me", headers=_h(EVAN_ID))).json()
        assert me_admin["is_project_creator"] is True, me_admin

        me_out = (await client.get("/api/v1/auth/me", headers=_h(OUTSIDER_ID))).json()
        assert me_out["is_project_creator"] is False, me_out
    finally:
        await _delete_group(client, gid)


# ─── 用例 6:GET /users 分页 offset + (name, id) tiebreaker ──────────────────
@pytest.mark.asyncio
async def test_users_offset_pagination_stable_order(client: AsyncClient) -> None:
    """用例 6(GET /users 分页):offset 生效 —— 同 q 下按 limit 切窗,各页不重叠、
    拼接还原全量(排序稳定);同名用户相邻且按 users.id 升序(order_by(User.name,
    User.id) 的 tiebreaker,防同名用户翻页窗口漂移)。

    自建 7 个带唯一 marker 的用户做断言,不依赖 seed 数据量(造 >100 用户可简化
    为 offset 语义断言,见任务拆解)。
    """
    marker = _uniq("pcoff")   # q 关键字只命中本测试自建用户的 name
    made: list[str] = []
    twin = f"Twin同名{marker}"
    names = [
        twin, f"{marker} a", f"{marker} b", f"{marker} c",
        f"{marker} d", twin, f"{marker} e",
    ]
    for i, nm in enumerate(names):
        uname = _uniq(f"pcoffu{i}")
        r = await client.post(
            "/api/v1/admin/directory/users",
            json={"username": uname, "name": nm},
            headers=_h(EVAN_ID),
        )
        assert r.status_code == 201, r.text
        made.append(r.json()["id"])

    full = await client.get(
        "/api/v1/users", params={"q": marker, "limit": 50}, headers=_h(EVAN_ID),
    )
    assert full.status_code == 200, full.text
    rows = full.json()
    all_ids = [u["id"] for u in rows]
    assert sorted(all_ids) == sorted(made), "q 应恰好命中本测试自建的用户"

    page1 = (await client.get(
        "/api/v1/users", params={"q": marker, "limit": 3, "offset": 0}, headers=_h(EVAN_ID),
    )).json()
    page2 = (await client.get(
        "/api/v1/users", params={"q": marker, "limit": 3, "offset": 3}, headers=_h(EVAN_ID),
    )).json()
    page3 = (await client.get(
        "/api/v1/users", params={"q": marker, "limit": 3, "offset": 6}, headers=_h(EVAN_ID),
    )).json()
    ids1 = [u["id"] for u in page1]
    ids2 = [u["id"] for u in page2]
    ids3 = [u["id"] for u in page3]
    assert len(ids1) == 3 and len(ids2) == 3 and len(ids3) == 1, (ids1, ids2, ids3)
    assert ids1 + ids2 + ids3 == all_ids, "offset 窗口应稳定:各页按序拼接 == 全量"
    assert not (set(ids1) & set(ids2)) and not (set(ids2) & set(ids3)), "页间不得重叠"

    # tiebreaker:两个同名用户相邻且按 users.id 升序
    twin_ids = [u["id"] for u in rows if u["name"] == twin]
    assert len(twin_ids) == 2, rows
    assert uuid.UUID(twin_ids[0]) < uuid.UUID(twin_ids[1]), (
        f"同名用户必须按 id 升序(tiebreaker): {twin_ids}"
    )


# ─── 用例 7:disable 闭环不误删组主体 tuple ───────────────────────────────────
@pytest.mark.asyncio
async def test_disable_member_keeps_group_subject_tuple(
    client: AsyncClient, app_with_lifespan,
) -> None:
    """用例 7(disable 闭环):组员被禁用后,revoke_user_completely 按
    USER_DIRECT_RELATIONS(新增 ("organization","project_creator"))枚举时,
    list_objects 会「看见」经组派生的 org 对象,但全键 read 精确匹配不到该 user
    的直连 tuple —— 组主体 tuple 不得被误删,同组其他成员建项目能力不受影响。"""
    perms = app_with_lifespan.state.permissions
    _, tenant_key = await _default_org()
    gid = await _create_group(client, can_create_project=True)
    uid_disabled = await _create_user(client)
    uid_alive = await _create_user(client)
    await _add_group_member(client, gid, uid_disabled)
    await _add_group_member(client, gid, uid_alive)
    try:
        r = await client.post(
            f"/api/v1/admin/directory/users/{uid_disabled}/disable", headers=_h(EVAN_ID),
        )
        assert r.status_code == 200, r.text

        # 禁用 user 自身直连 tuple 全清(照 test_directory 的枚举断言)
        from app.services.permissions import USER_DIRECT_RELATIONS
        for obj_type, rel in USER_DIRECT_RELATIONS:
            objs = await perms.list_objects(
                user_subject=f"user:{uid_disabled}", relation=rel, object_type=obj_type,
            )
            assert objs == [], f"禁用后 user 不应残留 {obj_type}#{rel}: {objs}"

        # 组主体 tuple 原样(全键 read 精确匹配 —— check 无法区分 tuple 的 user)
        left = await _read_creator_tuple_exact(perms, gid, tenant_key)
        assert len(left) == 1 and left[0].key.user == f"group:{gid}#member", (
            f"禁用组员不得误删组主体的 project_creator tuple: {left}"
        )

        # 行为验证:同组另一成员仍可建项目(组路径未断)
        body = {
            "code": _project_code(),
            "name": _uniq("禁用后同组仍可建"),
            "minio_bucket": "ms-dev",
            "admin_user_id": uid_alive,
        }
        r2 = await client.post("/api/v1/projects", json=body, headers=_h(uid_alive))
        assert r2.status_code == 201, r2.text
    finally:
        await _delete_group(client, gid)
