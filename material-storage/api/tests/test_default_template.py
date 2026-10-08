"""PR-3 默认模板直通 + 刷新默认权限(apply-default)— 集成测试,跑在 ms-api 容器里。

对应权威技术方案:`rushes-spec/material-storage/netdisk-import-batch-rename-roles-plan.md`
§3.4(测试清单,本文件用例编号 8-14)+ §3.1/§3.2(语义);接口契约表见
`docs/qdev/2026-10-08-batch-prefix-creator-template.md`「接口定义」。

契约要点(实现并行开发中,本文件按契约编写,两处冲突以方案为准):
  - create_project 直通写完成后合并当前默认模板:最终授权 = payload initial_grants
    ∪ 默认模板 items,按 (kind,id) 合并、角色取并集、幂等;payload 校验(重复 400 /
    超 50 条 422 / stale 主体 400)与直通写不动;50 上限只拦 payload
  - 默认模板 stale 条目(user 已删/停用、group 已删)跳过 + log,不阻塞建项目;
    audit via 区分:initial_grants / default_template;幂等跳过不写 audit
  - POST /api/v1/admin/grant-templates/apply-default {project_ids(1..100)} →
    {results:[{project_id, applied?, skipped_stale?, error?}], total_applied,
    total_skipped};叠加不删;预检 400 指明第几个(不存在/跨 org/归档);无默认 400;
    非 admin 403;空选 / >100 → 422;部分成功(失败项计 error,继续其余)

预期前置(同 test_v4_permissions.py):
  1. seed_demo_data.py 已跑过(Evan = 真 user + org admin;outsider = fake 零权限)
  2. OpenFGA store / model 已 push
  3. env=dev(允许 X-User-Id header 模拟身份)
"""
from __future__ import annotations

import uuid

import pytest
from httpx import ASGITransport, AsyncClient, Response

from app.main import create_app

# seed 写死的真 user / fake outsider(同 test_v4_permissions.py)
EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"
OUTSIDER_ID = "00000000-0000-0000-0000-0000000000aa"

# project 全部角色(测试收尾撤 tuple 用,照 PROJECT_ROLES 顺序)
_ALL_ROLES = ("admin", "uploader", "downloader", "viewer")


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
    return f"dt-{uuid.uuid4().hex[:12]}"


# ─── 测试内现建辅助(seed 不建 groups 表数据;模板/项目 helper 照既有文件)──────
async def _create_group(client: AsyncClient, prefix: str = "dt_grp") -> str:
    """现建用户组(照 test_directory.py 的写法)→ gid。"""
    r = await client.post(
        "/api/v1/admin/directory/groups",
        json={"name": _uniq(prefix), "description": "default_template 测试组"},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text
    return r.json()["id"]


async def _delete_group(client: AsyncClient, gid: str) -> None:
    r = await client.delete(f"/api/v1/admin/directory/groups/{gid}", headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text


async def _create_user(client: AsyncClient, prefix: str = "dt_user") -> str:
    """现建 active 本地用户 → users.id。"""
    uname = _uniq(prefix)
    r = await client.post(
        "/api/v1/admin/directory/users",
        json={"username": uname, "name": f"DT {prefix}"},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text
    return r.json()["id"]


async def _disable_user(client: AsyncClient, uid: str) -> None:
    r = await client.post(f"/api/v1/admin/directory/users/{uid}/disable", headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text


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

    不依赖 POST 响应体形状:契约只写死 201,条目结构以 GET 列表为准
    (照 test_grant_templates.py 的 helper)。设 is_default=True 会同事务清掉
    旧 default —— 各用例自己设默认 + finally 删模板(删默认 = org 无默认),
    天然不跨用例污染。
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


async def _delete_template(client: AsyncClient, tid: str) -> None:
    r = await client.delete(f"/api/v1/admin/grant-templates/{tid}", headers=_h(EVAN_ID))
    assert r.status_code == 204, r.text


async def _clear_default_templates(client: AsyncClient) -> list[str]:
    """取消当前 org 全部默认模板(「无默认」态用例的前置),返回被清的模板 id。"""
    r = await client.get("/api/v1/admin/grant-templates", headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    cleared: list[str] = []
    for t in r.json():
        if t.get("is_default"):
            rp = await client.patch(
                f"/api/v1/admin/grant-templates/{t['id']}",
                json={"is_default": False},
                headers=_h(EVAN_ID),
            )
            assert rp.status_code == 200, rp.text
            cleared.append(t["id"])
    return cleared


async def _create_project(
    client: AsyncClient,
    *,
    initial_grants: list[dict] | None = None,
    admin_user_id: str = EVAN_ID,
) -> dict:
    """Evan 建项目(系统 admin 可调);code/name 随机防重跑冲突。返回响应 json
    (照 test_initial_grants.py 的 helper)。"""
    body: dict = {
        "code": _project_code(),
        "name": _uniq("默认模板项目"),
        "minio_bucket": "ms-dev",
        "admin_user_id": admin_user_id,
    }
    if initial_grants is not None:
        body["initial_grants"] = initial_grants
    r = await client.post("/api/v1/projects", json=body, headers=_h(EVAN_ID))
    assert r.status_code == 201, r.text
    return r.json()


async def _members(client: AsyncClient, pid: str) -> list[dict]:
    r = await client.get(f"/api/v1/projects/{pid}/members", headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    return r.json()


def _roles_map(members: list[dict]) -> dict[str, set[str]]:
    """成员列表 → {subject: 角色集合}(同一 subject 多 role 已聚合)。"""
    return {m["subject"]: set(m["roles"]) for m in members}


async def _added_audit(client: AsyncClient, pid: str) -> list[dict]:
    """项目上全部 project_member_added audit 的 details 列表。"""
    r = await client.get(
        "/api/v1/admin/audit",
        params={"event_type": "project_member_added", "project_id": pid, "limit": 500},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    return [e.get("details") or {} for e in r.json()]


async def _revoke_subject(client: AsyncClient, pid: str, subject: str) -> None:
    """撤掉某主体在某项目上的全部角色(项目无删除 API,收尾用;
    stale 重复撤销 204 幂等,test_v4_permissions 已证)。"""
    for role in _ALL_ROLES:
        r = await client.delete(
            f"/api/v1/projects/{pid}/members",
            params={"subject": subject, "role": role},
            headers=_h(EVAN_ID),
        )
        assert r.status_code == 204, r.text


async def _apply_default(
    client: AsyncClient, project_ids: list[str], headers: dict[str, str] | None = None,
) -> Response:
    """缺省以 Evan(系统 admin)调用;验 403 守门时显式传 `_h(OUTSIDER_ID)`。"""
    return await client.post(
        "/api/v1/admin/grant-templates/apply-default",
        json={"project_ids": project_ids},
        headers=headers if headers is not None else _h(EVAN_ID),
    )


def _results_by_pid(body: dict) -> dict[str, dict]:
    return {str(e["project_id"]): e for e in body["results"]}


# ─── 直插 DB 辅助(无归档 API;第二个 org 行无创建 API;照 test_directory 直写惯例)
async def _set_archived(pid: str, archived: bool) -> None:
    from sqlalchemy import update

    from app.db.session import get_sessionmaker
    from app.db.tables import Project

    async with get_sessionmaker()() as db:
        await db.execute(
            update(Project)
            .where(Project.id == uuid.UUID(pid))
            .values(is_archived=archived)
        )
        await db.commit()


async def _archive_project(pid: str) -> None:
    """归档自建项目(收尾专用):项目无删除 API,is_archived=True 后不再进
    GET /projects 列表(列表过滤 is_archived),防多轮全量累积把 seed 项目挤出
    第一页(专职测试 P1 测试卫生)。在 finally 里调用:失败吞掉 + warning,
    不掩盖原断言。"""
    import warnings

    try:
        await _set_archived(pid, True)
    except Exception as e:  # noqa: BLE001
        warnings.warn(f"archive project {pid} failed: {e}; 残留活跃项目", stacklevel=2)


async def _create_org_row() -> str:
    """直插第二个 organization 行(跨 org 预检用例);org/project 行 FK RESTRICT
    且无删除 API,按每轮唯一 id 保留(不影响其他用例)。"""
    from sqlalchemy import insert

    from app.db.session import get_sessionmaker
    from app.db.tables import Organization

    oid = uuid.uuid4()
    async with get_sessionmaker()() as db:
        await db.execute(insert(Organization).values(
            id=oid, name=_uniq("dt_org2"), feishu_tenant_key=_uniq("dt_tk2"),
        ))
        await db.commit()
    return str(oid)


# ─── 用例 8:create 合并三例(方案 §3.1 / §3.4 用户例逐条断言)─────────────────
@pytest.mark.asyncio
async def test_create_merges_selected_template_and_default(client: AsyncClient) -> None:
    """用例 8-例1:选中 A(组A 上传+下载)+ 默认 C(用户X 管理+上传+下载)
    → 建项目后成员含 A∪C 全部,角色不丢不串。"""
    ga = await _create_group(client, "dt_a")
    ux = await _create_user(client, "dt_x")
    tpl_a = await _post_template(
        client, name=_uniq("dt_tplA"),
        items=[_item_group(ga, ["uploader", "downloader"])],
    )
    tpl_c = await _post_template(
        client, name=_uniq("dt_tplC"), is_default=True,
        items=[_item_user(ux, ["admin", "uploader", "downloader"])],
    )
    pid = ""
    try:
        proj = await _create_project(client, initial_grants=[
            {"kind": "group", "id": ga, "roles": ["uploader", "downloader"]},
        ])
        pid = proj["id"]
        roles = _roles_map(await _members(client, pid))
        assert roles.get(f"group:{ga}#member") == {"uploader", "downloader"}, roles
        assert roles.get(f"user:{ux}") == {"admin", "uploader", "downloader"}, roles
    finally:
        if pid:
            await _archive_project(pid)
            await _revoke_subject(client, pid, f"group:{ga}#member")
            await _revoke_subject(client, pid, f"user:{ux}")
        await _delete_template(client, tpl_a["id"])
        await _delete_template(client, tpl_c["id"])   # 删默认 → org 复原无默认
        await _delete_group(client, ga)


@pytest.mark.asyncio
async def test_create_default_template_selected_no_duplication(client: AsyncClient) -> None:
    """用例 8-例2:payload 选中默认模板自身 → 结果 = 该模板不重复(read 差集后
    零补写:成员角色恰为模板角色集,audit 无 default_template 条目)。"""
    ux = await _create_user(client, "dt_self")
    roles_c = ["admin", "uploader", "downloader"]
    tpl_c = await _post_template(
        client, name=_uniq("dt_tplSelf"), is_default=True,
        items=[_item_user(ux, roles_c)],
    )
    pid = ""
    try:
        proj = await _create_project(client, initial_grants=[
            {"kind": "user", "id": ux, "roles": roles_c},
        ])
        pid = proj["id"]
        roles = _roles_map(await _members(client, pid))
        assert roles.get(f"user:{ux}") == set(roles_c), roles

        # payload 已写全 → 默认模板差集为空,不应出现 default_template 来源的 audit
        audits = await _added_audit(client, pid)
        assert all(a.get("via") != "default_template" for a in audits), audits
    finally:
        if pid:
            await _archive_project(pid)
            await _revoke_subject(client, pid, f"user:{ux}")
        await _delete_template(client, tpl_c["id"])


@pytest.mark.asyncio
async def test_create_role_union_same_subject(client: AsyncClient) -> None:
    """用例 8-例3:选中 A(组A 上传+下载)+ 默认 B(组A 管理)→ 同主体角色取并集:
    组A = 管理+上传+下载。"""
    ga = await _create_group(client, "dt_u")
    tpl_a = await _post_template(
        client, name=_uniq("dt_tplUA"),
        items=[_item_group(ga, ["uploader", "downloader"])],
    )
    tpl_b = await _post_template(
        client, name=_uniq("dt_tplUB"), is_default=True,
        items=[_item_group(ga, ["admin"])],
    )
    pid = ""
    try:
        proj = await _create_project(client, initial_grants=[
            {"kind": "group", "id": ga, "roles": ["uploader", "downloader"]},
        ])
        pid = proj["id"]
        roles = _roles_map(await _members(client, pid))
        assert roles.get(f"group:{ga}#member") == {"admin", "uploader", "downloader"}, roles
    finally:
        if pid:
            await _archive_project(pid)
            await _revoke_subject(client, pid, f"group:{ga}#member")
        await _delete_template(client, tpl_a["id"])
        await _delete_template(client, tpl_b["id"])
        await _delete_group(client, ga)


# ─── 用例 9:默认模板 stale 条目跳过,不阻塞建项目 ────────────────────────────
@pytest.mark.asyncio
async def test_create_skips_stale_default_entries(client: AsyncClient) -> None:
    """用例 9:默认模板含 stale 条目(已删组 + 停用用户)→ 建项目成功、stale 条目
    跳过、其余条目照常、audit 无 stale 条目。stale 判定照 initial_grants 直查
    (user is_active、group 存在;停用用户 found=True 不得漏拦)。"""
    ga = await _create_group(client, "dt_stale_g")
    u_dis = await _create_user(client, "dt_stale_u")
    u_ok = await _create_user(client, "dt_ok")
    ux = await _create_user(client, "dt_payload")
    tpl = await _post_template(
        client, name=_uniq("dt_tplStale"), is_default=True,
        items=[
            _item_group(ga, ["uploader"]),
            _item_user(u_dis, ["downloader"]),
            _item_user(u_ok, ["viewer"]),
        ],
    )
    pid = ""
    try:
        # 模板建好后制造 stale:删组 + 停用用户(模板条目仍在,创建时校验已过)
        await _delete_group(client, ga)
        await _disable_user(client, u_dis)

        proj = await _create_project(client, initial_grants=[
            {"kind": "user", "id": ux, "roles": ["viewer"]},
        ])
        pid = proj["id"]

        roles = _roles_map(await _members(client, pid))
        assert "viewer" in roles.get(f"user:{ux}", set()), roles
        assert "viewer" in roles.get(f"user:{u_ok}", set()), (
            f"非 stale 的默认条目应照常生效: {roles}"
        )
        assert f"group:{ga}#member" not in roles, f"已删组条目应被跳过: {roles}"
        assert f"user:{u_dis}" not in roles, f"停用用户条目应被跳过: {roles}"

        # audit 无 stale 条目(跳过不写)
        stale_subjects = {f"group:{ga}#member", f"user:{u_dis}"}
        audits = await _added_audit(client, pid)
        assert all(a.get("subject") not in stale_subjects for a in audits), audits
    finally:
        if pid:
            await _archive_project(pid)
            await _revoke_subject(client, pid, f"user:{ux}")
            await _revoke_subject(client, pid, f"user:{u_ok}")
        await _delete_template(client, tpl["id"])
        try:
            await _delete_group(client, ga)   # 已删过 → 幂等兜底(404 也不让收尾失败)
        except AssertionError:
            pass


# ─── 用例 10:audit via 区分 initial_grants / default_template ────────────────
@pytest.mark.asyncio
async def test_audit_via_distinguishes_sources(client: AsyncClient) -> None:
    """用例 10:手选/initial_grants 来源记 via="initial_grants";默认模板来源记
    via="default_template"(幂等跳过不写)。"""
    gg = await _create_group(client, "dt_via_g")
    ux = await _create_user(client, "dt_via_u")
    tpl = await _post_template(
        client, name=_uniq("dt_tplVia"), is_default=True,
        items=[_item_group(gg, ["uploader"])],
    )
    pid = ""
    try:
        proj = await _create_project(client, initial_grants=[_item_user(ux, ["viewer"])])
        pid = proj["id"]

        audits = await _added_audit(client, pid)
        by_subject_via: dict[tuple[str, str], set[str]] = {}
        for a in audits:
            key = (a.get("subject", ""), a.get("via", ""))
            by_subject_via.setdefault(key, set()).add(a.get("role", ""))

        assert by_subject_via.get((f"user:{ux}", "initial_grants")) == {"viewer"}, audits
        assert by_subject_via.get((f"group:{gg}#member", "default_template")) == {
            "uploader",
        }, audits
    finally:
        if pid:
            await _archive_project(pid)
            await _revoke_subject(client, pid, f"user:{ux}")
            await _revoke_subject(client, pid, f"group:{gg}#member")
        await _delete_template(client, tpl["id"])
        await _delete_group(client, gg)


# ─── 用例 11:payload 满 50 条 + 有默认模板 → 不 422 ──────────────────────────
@pytest.mark.asyncio
async def test_payload_50_entries_with_default_not_422(client: AsyncClient) -> None:
    """用例 11:payload 恰 50 条 initial_grants(上限)+ 有默认模板 → 201 不 422
    (50 上限只拦 payload,helper 补写不占上限),默认模板条目照常并入。

    成本说明:50 条 entry 须 50 个不同主体(dup 400),故现建 50 用户(容器内
    串行 POST,数十秒级可接受);残留 tuple 落在本测试独有的项目上,不影响其他
    用例,不再逐条撤。顺序:先造 50 用户 → 再建默认模板(主体 = payload 第 1 个
    用户,与 payload 重叠)→ 再建项目。
    """
    await _clear_default_templates(client)   # 保证建项目时默认态受本用例控制
    payload_users: list[str] = []
    pid = ""
    tpl: dict | None = None
    try:
        for i in range(50):
            payload_users.append(await _create_user(client, f"dt_cap{i:02d}"))
        # 默认模板主体取 payload 第 1 个用户(重叠)→ 断言角色并集
        tpl = await _post_template(
            client, name=_uniq("dt_tplCap"), is_default=True,
            items=[_item_user(payload_users[0], ["uploader"])],
        )
        proj = await _create_project(client, initial_grants=[
            {"kind": "user", "id": u, "roles": ["viewer"]} for u in payload_users
        ])
        pid = proj["id"]

        roles = _roles_map(await _members(client, pid))
        # 第 1 个 payload 主体与默认模板主体重叠 → payload viewer ∪ 默认 uploader
        assert roles.get(f"user:{payload_users[0]}") == {"viewer", "uploader"}, roles
        assert roles.get(f"user:{payload_users[-1]}") == {"viewer"}, roles
    finally:
        if pid:
            await _archive_project(pid)
            await _revoke_subject(client, pid, f"user:{payload_users[0]}")
        if tpl is not None:
            await _delete_template(client, tpl["id"])


# ─── 用例 12:无默认模板 → 建项目行为与现状一致(回归)────────────────────────
@pytest.mark.asyncio
async def test_no_default_template_regression(client: AsyncClient) -> None:
    """用例 12(回归):无默认模板 → 建项目行为与现状一致:仅 bootstrap + payload
    授权,无任何组主体进入,零权限 outsider 对该项目仍 403。"""
    await _clear_default_templates(client)
    ux = await _create_user(client, "dt_regress")
    pid = ""
    try:
        proj = await _create_project(client, initial_grants=[_item_user(ux, ["viewer"])])
        pid = proj["id"]

        roles = _roles_map(await _members(client, pid))
        assert "viewer" in roles.get(f"user:{ux}", set()), roles
        assert not any(s.startswith("group:") for s in roles), (
            f"无默认模板时不应有任何组主体进入: {roles}"
        )
        r = await client.get(f"/api/v1/projects/{pid}", headers=_h(OUTSIDER_ID))
        assert r.status_code == 403, "无默认模板时不得给 outsider 带来任何授权"
    finally:
        if pid:
            await _archive_project(pid)


# ─── 用例 13:apply-default 全 cycle / 幂等 / stale 计数 / 预检 / 形状 / 403 ──
@pytest.mark.asyncio
async def test_apply_default_full_cycle_and_idempotent(client: AsyncClient) -> None:
    """用例 13(全 cycle):两个项目各补默认模板授权(tuple 就位、results 计数
    正确);幂等二跑 applied=0(叠加不删:read 差集为空、零写入)。

    顺序必须是「先建项目(无默认模板状态,create 期无可合并)→ 再设默认模板
    → 再 apply-default」:方案 §3.1 下 create_project 遇默认模板本就会自行合并,
    先设默认会让 create 期授权已就位、apply 期差集恒空。
    """
    await _clear_default_templates(client)   # 保证建项目时 org 无默认模板
    gg = await _create_group(client, "dt_cyc_g")
    ux = await _create_user(client, "dt_cyc_u")
    p1 = (await _create_project(client))["id"]
    p2 = (await _create_project(client))["id"]
    tpl = await _post_template(
        client, name=_uniq("dt_tplCyc"), is_default=True,
        items=[_item_group(gg, ["uploader"]), _item_user(ux, ["downloader"])],
    )
    try:
        r = await _apply_default(client, [p1, p2])
        assert r.status_code == 200, r.text
        body = r.json()
        res = _results_by_pid(body)
        assert set(res) == {p1, p2}, body
        assert res[p1].get("applied") == 2 and res[p2].get("applied") == 2, body
        assert res[p1].get("skipped_stale", 0) == 0, body
        assert body["total_applied"] == 4, body
        assert body["total_skipped"] == 0, body

        # 两项目 tuple 就位
        for pid in (p1, p2):
            roles = _roles_map(await _members(client, pid))
            assert "uploader" in roles.get(f"group:{gg}#member", set()), roles
            assert "downloader" in roles.get(f"user:{ux}", set()), roles

        # 幂等二跑:applied=0
        r2 = await _apply_default(client, [p1, p2])
        assert r2.status_code == 200, r2.text
        body2 = r2.json()
        res2 = _results_by_pid(body2)
        assert res2[p1].get("applied", 0) == 0 and res2[p2].get("applied", 0) == 0, body2
        assert body2["total_applied"] == 0, body2
    finally:
        for pid in (p1, p2):
            await _archive_project(pid)
            await _revoke_subject(client, pid, f"group:{gg}#member")
            await _revoke_subject(client, pid, f"user:{ux}")
        await _delete_template(client, tpl["id"])
        await _delete_group(client, gg)


@pytest.mark.asyncio
async def test_apply_default_counts_skipped_stale(client: AsyncClient) -> None:
    """用例 13(stale 计数):默认模板的已删组 + 停用用户条目 → 该项目
    skipped_stale 计数 = 2,健在条目照常 applied。

    顺序同全 cycle 用例:先建项目(无默认模板状态)→ 再设默认模板(此时主体
    全部健在,过模板创建校验)→ 删组 + 停用用户制造 stale → apply-default。
    """
    await _clear_default_templates(client)   # 保证建项目时 org 无默认模板
    ga = await _create_group(client, "dt_sk_g")
    u_dis = await _create_user(client, "dt_sk_u")
    u_ok = await _create_user(client, "dt_sk_ok")
    pid = (await _create_project(client))["id"]
    tpl = await _post_template(
        client, name=_uniq("dt_tplSk"), is_default=True,
        items=[
            _item_group(ga, ["uploader"]),
            _item_user(u_dis, ["downloader"]),
            _item_user(u_ok, ["viewer"]),
        ],
    )
    try:
        # 模板建好后制造 stale:删组 + 停用用户(条目仍在,创建时校验已过)
        await _delete_group(client, ga)
        await _disable_user(client, u_dis)

        r = await _apply_default(client, [pid])
        assert r.status_code == 200, r.text
        res = _results_by_pid(r.json())
        assert res[pid].get("applied") == 1, r.text          # 仅 u_ok 的 viewer
        assert res[pid].get("skipped_stale") == 2, r.text    # 已删组 + 停用用户

        roles = _roles_map(await _members(client, pid))
        assert "viewer" in roles.get(f"user:{u_ok}", set()), roles
        assert f"group:{ga}#member" not in roles, roles
        assert f"user:{u_dis}" not in roles, roles
    finally:
        if pid:
            await _archive_project(pid)
            await _revoke_subject(client, pid, f"user:{u_ok}")
        await _delete_template(client, tpl["id"])
        try:
            await _delete_group(client, ga)
        except AssertionError:
            pass


@pytest.mark.asyncio
async def test_apply_default_requires_system_admin(client: AsyncClient) -> None:
    """用例 13:非 admin(outsider)调 apply-default → 403(body 合法,排除形状因素)。"""
    r = await _apply_default(client, [str(uuid.uuid4())], headers=_h(OUTSIDER_ID))
    assert r.status_code == 403, r.text


@pytest.mark.asyncio
async def test_apply_default_shape_422(client: AsyncClient) -> None:
    """用例 13:空选 → 422(min_length=1);>100(101 个)→ 422(勾选上限,
    超限在预检之前被 Pydantic 拦)。"""
    r = await client.post(
        "/api/v1/admin/grant-templates/apply-default",
        json={"project_ids": []},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 422, r.text

    r2 = await client.post(
        "/api/v1/admin/grant-templates/apply-default",
        json={"project_ids": [str(uuid.uuid4()) for _ in range(101)]},
        headers=_h(EVAN_ID),
    )
    assert r2.status_code == 422, r2.text


@pytest.mark.asyncio
async def test_apply_default_precheck_unknown_project_400(client: AsyncClient) -> None:
    """用例 13(预检):不存在的 project id → 400 且指明第几个。
    先设一个默认模板,隔离「无默认模板」分支(两分支契约都是 400)。"""
    tpl = await _post_template(
        client, name=_uniq("dt_tplGhost"), is_default=True,
        items=[_item_user(EVAN_ID, ["viewer"])],
    )
    try:
        ghost = str(uuid.uuid4())
        r = await _apply_default(client, [ghost])
        assert r.status_code == 400, r.text
        assert ghost in r.text or "第 1" in r.text or "第1" in r.text, (
            f"400 应指明第几个/哪个项目: {r.text}"
        )
    finally:
        await _delete_template(client, tpl["id"])


@pytest.mark.asyncio
async def test_apply_default_precheck_cross_org_project_400(client: AsyncClient) -> None:
    """用例 13(预检):跨 org 项目 → 400 指明第几个。
    第二个 org 行测试内直插(系统 admin 允许 POST /projects 指定任意存在的 org)。"""
    tpl = await _post_template(
        client, name=_uniq("dt_tplXorg"), is_default=True,
        items=[_item_user(EVAN_ID, ["viewer"])],
    )
    org2 = await _create_org_row()
    proj = await client.post(
        "/api/v1/projects",
        json={
            "code": _project_code(),
            "name": _uniq("跨org项目"),
            "organization_id": org2,
            "minio_bucket": "ms-dev",
            "admin_user_id": EVAN_ID,
        },
        headers=_h(EVAN_ID),
    )
    assert proj.status_code == 201, proj.text
    pid = proj.json()["id"]
    try:
        r = await _apply_default(client, [pid])
        assert r.status_code == 400, r.text
        assert pid in r.text or "第 1" in r.text or "第1" in r.text, (
            f"400 应指明第几个/哪个项目: {r.text}"
        )
    finally:
        await _archive_project(pid)
        await _delete_template(client, tpl["id"])


@pytest.mark.asyncio
async def test_apply_default_precheck_archived_project_400(client: AsyncClient) -> None:
    """用例 13(预检):归档项目 → 400 指明第几个(is_archived 由 DB 直改:现无
    归档 API;finally 恢复 false 保证可重入)。"""
    tpl = await _post_template(
        client, name=_uniq("dt_tplArch"), is_default=True,
        items=[_item_user(EVAN_ID, ["viewer"])],
    )
    pid = (await _create_project(client))["id"]
    await _set_archived(pid, True)
    try:
        r = await _apply_default(client, [pid])
        assert r.status_code == 400, r.text
        assert pid in r.text or "第 1" in r.text or "第1" in r.text, (
            f"400 应指明第几个/哪个项目: {r.text}"
        )
    finally:
        # 不恢复 active:项目无删除 API,保持归档态防残留活跃项目挤占
        # GET /projects 第一页(P1 测试卫生);幂等重置 True,失败吞掉 + warning
        await _archive_project(pid)
        await _delete_template(client, tpl["id"])


@pytest.mark.asyncio
async def test_apply_default_without_default_template_400(client: AsyncClient) -> None:
    """用例 13:org 无默认模板 → 400(UI 已 disabled,API 兜底)。"""
    await _clear_default_templates(client)
    pid = ""
    try:
        pid = (await _create_project(client))["id"]
        r = await _apply_default(client, [pid])
        assert r.status_code == 400, r.text
    finally:
        if pid:
            await _archive_project(pid)


# ─── 用例 14:部分成功(占位,见 skip reason)─────────────────────────────────
@pytest.mark.skip(reason=(
    "部分成功语义(方案 §3.2:执行期单项目 FGA/DB 失败 → 继续执行其余项目,失败项"
    "计入 results 的 {project_id, error},total_applied/total_skipped 只计成功项,"
    "success 与 failure 两种条目形状勿混用)需要向应用进程内注入单点故障"
    "(monkeypatch 共享 helper 或 OpenFGA client),HTTP 黑盒无法稳定构造:"
    "预检已拦不存在/跨 org/归档,运行期失败仅剩 FGA/DB 抖动。实现合入后如需覆盖,"
    "可在容器内 monkeypatch app.services.default_grants.apply_default_template_grants"
    "使第二个项目抛错后直拍断言 results[1].error 与 total 计数。"
))
@pytest.mark.asyncio
async def test_apply_default_partial_success(client: AsyncClient) -> None:
    """用例 14(部分成功,占位不执行):契约已固化在方案 §3.2,稳定注入手段落地后
    补直拍。"""
    r = await _apply_default(client, [str(uuid.uuid4())])
    assert r.status_code in (200, 400), r.text   # 占位断言,skip 下不执行
