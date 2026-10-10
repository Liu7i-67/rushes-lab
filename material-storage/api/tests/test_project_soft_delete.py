"""项目逻辑删除(深隐藏+可恢复)与组级 can_delete_project 集成测试(T10-T17)。

跑在 ms-api 容器里(`docker exec ms-api pytest`)。
唯一需求依据:docs/qdev/2026-10-10-admin-console-opt.md「测试功能点」T10-T17 +
「接口定义」§5-§11、决策 D1/D2/D10/D11。

契约要点(实现由并行任务交付,冲突以需求文档为准):
  - DELETE /api/v1/projects/{id}:守门 require_project_deleter(= is_org_admin 或
    organization#project_deleter check;**不要求目标项目 admin**,D2);动作=
    置 deleted_at/deleted_by,不动 FGA tuple/桶/资产/分享(D10);返回
    {ok,project_id,deleted_at};不存在**或已删除** → 404;审计 project_deleted
  - GET /api/v1/projects / GET /api/v1/projects/{id}:一律排除 deleted_at 非空,
    已删除详情(含 system admin 直访)→ 404
  - GET /api/v1/projects/deleted:守门同 DELETE;q(code/name 子串)+ limit/offset,
    返回 {items,total,limit,offset},deleted_at 倒序,带 deleted_by_name
  - POST /api/v1/projects/{id}/restore:仅作用于 deleted_at 非空者,清空两字段;
    否则 404(D11);审计 project_restored
  - PATCH /admin/directory/groups/{id} 增 tri-state `can_delete_project`
    (null/缺省=不变),组列表回显该字段,FGA tuple 同 project_creator 模式;
    审计 group_updated details 增 "can_delete_project": {old,new}(有变更时)
  - GET /api/v1/auth/me 增 `is_project_deleter`(与守门同口径)

预期前置(同 test_v4_permissions.py):
  1. seed_demo_data.py 已跑过(Evan = 真 user + org admin / system admin;
     outsider = fake 零权限)
  2. OpenFGA store / model 已 push(**含 project_deleter relation**,需求 §11:
     2026-10-10 版模型,部署/测试前须重推)
  3. env=dev(允许 X-User-Id header 模拟身份)

清理惯例(同 test_project_creator.py):组在 finally 里删;自建项目用本期
DELETE API 收尾(已删除 404 视为成功),不再需要 DB 直改归档;用户无删除 API,
靠唯一 marker 圈定断言,不清理(沿用现状)。
"""
from __future__ import annotations

import subprocess
import uuid
from pathlib import Path

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import create_app

# seed 写死的真 user / fake outsider(同 test_project_creator.py)
EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"
OUTSIDER_ID = "00000000-0000-0000-0000-0000000000aa"

# require_system_admin 的既有 403 文案(deps.py);契约要求项目删除守门的 403
# 文案与之区分(可辨识「缺删除项目权限」而非「非系统管理员」,D2 照搬 creator 模式)
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
    return f"sd-{uuid.uuid4().hex[:12]}"


# ─── 测试内现建辅助(组/用户/项目一律测试内现建,照 test_project_creator.py)──
async def _create_group(client: AsyncClient, prefix: str = "sd_grp") -> dict:
    """现建目录组(**不带** flag 建组 —— 需求 §5 只扩 PATCH;flag 一律 PATCH 置位)。"""
    r = await client.post(
        "/api/v1/admin/directory/groups",
        json={"name": _uniq(prefix), "description": "project_deleter 测试组"},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text
    return r.json()


async def _set_group_can_delete(
    client: AsyncClient, gid: str, value: bool,
) -> dict:
    """PATCH can_delete_project(契约 §5)→ 200 组对象(含回显字段)。"""
    r = await client.patch(
        f"/api/v1/admin/directory/groups/{gid}",
        json={"can_delete_project": value}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    return r.json()


async def _create_user(
    client: AsyncClient, prefix: str = "sd_user", *, name: str | None = None,
) -> str:
    """现建 active 本地用户 → users.id。"""
    uname = _uniq(prefix)
    r = await client.post(
        "/api/v1/admin/directory/users",
        json={"username": uname, "name": name or f"SD {prefix}"},
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


async def _delete_group(client: AsyncClient, gid: str) -> None:
    r = await client.delete(f"/api/v1/admin/directory/groups/{gid}", headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text


async def _list_group_echo(client: AsyncClient, gid: str, name: str) -> dict | None:
    """组列表按唯一 name 取回(回显真实 tuple 态;无组详情路由,数据源即列表)。"""
    r = await client.get(
        "/api/v1/admin/directory/groups", params={"q": name}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    hits = [g for g in r.json() if g["id"] == gid]
    return hits[0] if hits else None


async def _create_project(
    client: AsyncClient,
    *,
    admin_uid: str,
    name: str | None = None,
    grants: list[dict] | None = None,
) -> dict:
    """EVAN(系统 admin)现建项目 → ProjectOut dict(admin_uid 可为任意用户,
    便于构造「操作者非项目 admin」场景)。"""
    body: dict = {
        "code": _project_code(),
        "name": name or _uniq("软删除项目"),
        "minio_bucket": "ms-dev",
        "admin_user_id": admin_uid,
    }
    if grants:
        body["initial_grants"] = grants
    r = await client.post("/api/v1/projects", json=body, headers=_h(EVAN_ID))
    assert r.status_code == 201, r.text
    return r.json()


async def _soft_delete(client: AsyncClient, pid: str) -> None:
    """收尾专用:把仍活跃的自建项目逻辑删除,防挤占 GET /projects 第一页。

    已删除(404)视为成功;失败吞掉 + warning,不掩盖原断言
    (照 test_project_creator._archive_project 惯例)。"""
    import warnings

    try:
        r = await client.delete(f"/api/v1/projects/{pid}", headers=_h(EVAN_ID))
        assert r.status_code in (200, 404), r.text
    except Exception as e:
        warnings.warn(f"soft delete project {pid} failed: {e}; 残留活跃项目", stacklevel=2)


async def _main_list_ids(client: AsyncClient, actor_id: str) -> list[str]:
    """GET /api/v1/projects 第一页(limit=200)的 id 列表(新建项目 created_at
    倒序在最前,自建项目必在窗口内)。"""
    r = await client.get(
        "/api/v1/projects", params={"limit": 200}, headers=_h(actor_id),
    )
    assert r.status_code == 200, r.text
    return [p["id"] for p in r.json()]


async def _deleted_row(pid: str) -> tuple[object, object]:
    """DB 直读 projects.deleted_at/deleted_by(T10「落库」断言;
    DB 直写照 test_project_creator._archive_project 惯例)。"""
    from sqlalchemy import select

    from app.db.session import get_sessionmaker
    from app.db.tables import Project

    async with get_sessionmaker()() as db:
        row = (await db.execute(
            select(Project).where(Project.id == uuid.UUID(pid)),
        )).scalar_one()
        return row.deleted_at, row.deleted_by


async def _default_org() -> tuple[str, str]:
    """default org 的 (org_id, tenant_key) —— OpenFGA organization object 用 tenant_key。"""
    from app.db.session import get_sessionmaker
    from app.services.org import get_default_organization

    async with get_sessionmaker()() as db:
        org = await get_default_organization(db)
    assert org is not None, "测试前置:settings.default_organization_id 未配置"
    return str(org[0]), org[1]


async def _deleter_flag_on(perms, gid: str, tenant_key: str) -> bool:
    """组主体是否持有 organization#project_deleter(组主体直查,check 自动展开)。"""
    return await perms.check(
        user_subject=f"group:{gid}#member", relation="project_deleter",
        object_type="organization", object_id=tenant_key,
    )


async def _audit_events(
    client: AsyncClient, event_type: str, actor_user_id: str,
) -> list[dict]:
    """按 event_type + actor 拉 audit 原始条目(details/target_* 字段均在)。"""
    r = await client.get(
        "/api/v1/admin/audit",
        params={"event_type": event_type, "actor_user_id": actor_user_id, "limit": 500},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    return list(r.json())


async def _group_audit_details_list(
    client: AsyncClient, event_type: str, gid: str,
) -> list[dict]:
    """按 event_type + actor(EVAN)拉 audit,返回 details.group_id == gid 的条目。"""
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


# (deleter 构造惯例 = _create_group + PATCH can_delete_project true + 用户入组,
#  各用例内联三步,便于按需组合「非项目 admin」「仅 viewer」等变体。)

# ─── T15(开关语义):组 PATCH can_delete_project tri-state + 回显 + tuple + 审计 ─
@pytest.mark.asyncio
async def test_group_can_delete_project_flag_tri_state_and_audit(
    client: AsyncClient, app_with_lifespan,
) -> None:
    """T15 开关部分:PATCH true → organization#project_deleter 有组主体 tuple、
    组列表回显 True、group_updated 审计带 {old,new};仅改名的不带字段 PATCH →
    tuple 不动(tri-state 防回归,照 creator 用例 1b);false → tuple 删,重复
    清除幂等 200;建组默认回显 False。"""
    perms = app_with_lifespan.state.permissions
    _, tenant_key = await _default_org()
    g = await _create_group(client, "sd_flag")
    gid = g["id"]
    try:
        # 建组默认 False(契约:组列表返回增 can_delete_project: bool)
        echo0 = await _list_group_echo(client, gid, g["name"])
        assert echo0 is not None and echo0["can_delete_project"] is False, echo0
        assert await _deleter_flag_on(perms, gid, tenant_key) is False

        # PATCH true → tuple 写 + PATCH 响应/列表双回显
        r = await _set_group_can_delete(client, gid, True)
        assert r["can_delete_project"] is True, r
        assert await _deleter_flag_on(perms, gid, tenant_key) is True
        echo1 = await _list_group_echo(client, gid, g["name"])
        assert echo1 is not None and echo1["can_delete_project"] is True, echo1

        # 仅改名、PATCH body 不带 can_delete_project 字段 → tuple 必须原样
        new_name = _uniq("sd_flag_renamed")
        rn = await client.patch(
            f"/api/v1/admin/directory/groups/{gid}",
            json={"name": new_name}, headers=_h(EVAN_ID),
        )
        assert rn.status_code == 200, rn.text
        assert await _deleter_flag_on(perms, gid, tenant_key) is True, (
            "仅改名的不带字段 PATCH 不得撤 tuple(必须 tri-state)"
        )

        # false → tuple 删 + 回显 False;重复清除幂等(不 500)
        for _ in range(2):
            r2 = await _set_group_can_delete(client, gid, False)
            assert r2["can_delete_project"] is False, r2
        assert await _deleter_flag_on(perms, gid, tenant_key) is False
        echo2 = await _list_group_echo(client, gid, new_name)
        assert echo2 is not None and echo2["can_delete_project"] is False, echo2

        # 审计:group_updated details 增 "can_delete_project": {old,new}(契约 §5)
        events = await _group_audit_details_list(client, "group_updated", gid)
        on = [e for e in events if (e.get("can_delete_project") or {}).get("new") is True]
        assert on, f"应有 can_delete_project new=True 的 group_updated: {events}"
        assert on[0]["can_delete_project"]["old"] is False, on[0]
        off = [e for e in events if (e.get("can_delete_project") or {}).get("new") is False]
        assert off, f"应有 can_delete_project new=False 的 group_updated: {events}"
    finally:
        await _delete_group(client, gid)


# ─── T15(行为):true → 组内普通成员 DELETE 成功;false → 403 ──────────────────
@pytest.mark.asyncio
async def test_group_flag_gates_member_delete(client: AsyncClient) -> None:
    """T15 行为部分(亦是 T10 权限构造的独立验证):组员**非项目 admin**,
    flag false → DELETE 403;PATCH true → 200;再翻 false → 对另一项目 403。"""
    g = await _create_group(client, "sd_gate")
    gid = g["id"]
    uid = await _create_user(client, "sd_gate_user", name="开关组员")
    await _add_group_member(client, gid, uid)
    pids: list[str] = []

    async def _mk() -> str:
        p = await _create_project(client, admin_uid=EVAN_ID, name=_uniq("删除开关项目"))
        pids.append(p["id"])
        return p["id"]

    try:
        p1 = await _mk()
        # flag false → 组员 403
        r = await client.delete(f"/api/v1/projects/{p1}", headers=_h(uid))
        assert r.status_code == 403, r.text

        # flag true → 组员 DELETE 成功(ok/project_id 形状,契约 §6)
        await _set_group_can_delete(client, gid, True)
        r2 = await client.delete(f"/api/v1/projects/{p1}", headers=_h(uid))
        assert r2.status_code == 200, r2.text
        body = r2.json()
        assert body["ok"] is True and body["project_id"] == p1, body
        assert body["deleted_at"], body

        # 翻回 false → 对另一项目 403(开关实时生效)
        p2 = await _mk()
        await _set_group_can_delete(client, gid, False)
        r3 = await client.delete(f"/api/v1/projects/{p2}", headers=_h(uid))
        assert r3.status_code == 403, r3.text

        # 组列表回显最终 False
        echo = await _list_group_echo(client, gid, g["name"])
        assert echo is not None and echo["can_delete_project"] is False, echo
    finally:
        for p in pids:
            await _soft_delete(client, p)   # 未删成功的收尾;已删的 404 吞掉
        await _delete_group(client, gid)


# ─── T16:/me is_project_deleter 与守门同口径 ─────────────────────────────────
@pytest.mark.asyncio
async def test_me_is_project_deleter(client: AsyncClient) -> None:
    """T16:组员随组开关 true/false 翻转 is_project_deleter;org admin 恒 true;
    outsider false(F6.7,口径 = is_org_admin 或 organization#project_deleter)。"""
    g = await _create_group(client, "sd_me")
    gid = g["id"]
    uid = await _create_user(client, "sd_me_user", name="开关组员-me")
    await _add_group_member(client, gid, uid)
    try:
        me0 = (await client.get("/api/v1/auth/me", headers=_h(uid))).json()
        assert me0["is_project_deleter"] is False, me0   # 组未开 flag

        await _set_group_can_delete(client, gid, True)
        me1 = (await client.get("/api/v1/auth/me", headers=_h(uid))).json()
        assert me1["is_project_deleter"] is True, me1

        await _set_group_can_delete(client, gid, False)
        me2 = (await client.get("/api/v1/auth/me", headers=_h(uid))).json()
        assert me2["is_project_deleter"] is False, me2

        # org admin true(EVAN);outsider false
        me_admin = (await client.get("/api/v1/auth/me", headers=_h(EVAN_ID))).json()
        assert me_admin["is_project_deleter"] is True, me_admin
        me_out = (await client.get("/api/v1/auth/me", headers=_h(OUTSIDER_ID))).json()
        assert me_out["is_project_deleter"] is False, me_out
    finally:
        await _delete_group(client, gid)


# ─── T10:deleter 删除 → 落库 + 全员(含 system admin)不可见 + 审计 ───────────
@pytest.mark.asyncio
async def test_deleter_soft_delete_hides_project_everywhere(
    client: AsyncClient,
) -> None:
    """T10:组 deleter(仅 viewer、**非项目 admin**,D2「不要求项目 admin」)
    DELETE → 200;DB deleted_at/deleted_by 落库;主列表(deleter 可见范围与
    system admin 分支)不再出现;详情双方均 404;审计 project_deleted
    (details 含 project_id/code/name/deleted_by)。"""
    g = await _create_group(client, "sd_del")
    gid = g["id"]
    await _set_group_can_delete(client, gid, True)
    uid = await _create_user(client, "sd_del_user", name="删除员甲")
    await _add_group_member(client, gid, uid)
    # deleter 仅 viewer(initial_grants),项目 admin 是 EVAN → 删除纯靠 deleter 权限
    p = await _create_project(
        client, admin_uid=EVAN_ID, name=_uniq("深隐藏项目"),
        grants=[{"kind": "user", "id": uid, "roles": ["viewer"]}],
    )
    pid = p["id"]
    try:
        # 前置:deleter(viewer)可见
        pre = await client.get(f"/api/v1/projects/{pid}", headers=_h(uid))
        assert pre.status_code == 200, pre.text
        assert pid in await _main_list_ids(client, uid)

        # DELETE → 200 {ok, project_id, deleted_at}
        r = await client.delete(f"/api/v1/projects/{pid}", headers=_h(uid))
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["ok"] is True and body["project_id"] == pid, body
        assert body["deleted_at"], body

        # 落库:deleted_at 非空 + deleted_by=操作人
        deleted_at, deleted_by = await _deleted_row(pid)
        assert deleted_at is not None, "deleted_at 应落库"
        assert str(deleted_by) == uid, f"deleted_by 应为操作人: {deleted_by}"

        # 主列表消失:deleter 可见范围 + system admin 分支(F6.4)
        assert pid not in await _main_list_ids(client, uid), "deleter 列表不应含已删项目"
        assert pid not in await _main_list_ids(client, EVAN_ID), (
            "system admin 主列表同样不见"
        )

        # 详情 404:deleter(viewer)与 system admin 直访
        for actor in (uid, EVAN_ID):
            d = await client.get(f"/api/v1/projects/{pid}", headers=_h(actor))
            assert d.status_code == 404, f"actor={actor}: {d.text}"

        # 审计:project_deleted(details 按契约 §6)
        events = await _audit_events(client, "project_deleted", uid)
        hit = [e for e in events if (e.get("details") or {}).get("project_id") == pid]
        assert len(hit) == 1, events
        det = hit[0]["details"]
        assert det["code"] == p["code"] and det["name"] == p["name"], det
        assert det["deleted_by"] == uid, det
    finally:
        await _delete_group(client, gid)   # 项目保持已删除态(收尾即隐藏)


# ─── T11:无 deleter 权限(含项目 admin)DELETE → 403(守门层拦截不落业务审计)──
@pytest.mark.asyncio
async def test_delete_without_deleter_permission_403(
    client: AsyncClient,
) -> None:
    """T11:项目 admin **不**默认能删(D2)→ 403,文案与 require_system_admin
    区分;零权限 outsider 403;system admin 恒可删(D2 口径含 org admin)。

    守门层拦截不落业务审计(PM 裁定 2026-10-10:与 require_project_creator
    既有惯例一致),故不校验 access_denied 审计。"""
    pa = await _create_user(client, "sd_pa", name="T11 项目管理员")
    p = await _create_project(client, admin_uid=pa, name=_uniq("无权删除项目"))
    pid = p["id"]
    try:
        # 项目 admin 也 403(守门不要求项目 admin,反之项目 admin 也不自动获删权)
        r = await client.delete(f"/api/v1/projects/{pid}", headers=_h(pa))
        assert r.status_code == 403, r.text
        assert r.json().get("detail") != _REQUIRE_SYSTEM_ADMIN_COPY, (
            f"403 文案须与 require_system_admin 区分: {r.text}"
        )

        # 零权限 outsider 403
        r2 = await client.delete(f"/api/v1/projects/{pid}", headers=_h(OUTSIDER_ID))
        assert r2.status_code == 403, r2.text

        # system admin 恒可删
        r3 = await client.delete(f"/api/v1/projects/{pid}", headers=_h(EVAN_ID))
        assert r3.status_code == 200, r3.text
    finally:
        await _soft_delete(client, pid)   # 已删则 404 吞掉


# ─── T12:DELETE 已删除项目 → 404 ─────────────────────────────────────────────
@pytest.mark.asyncio
async def test_delete_already_deleted_project_404(client: AsyncClient) -> None:
    """T12:对已删除项目重复 DELETE → 404(对所有人一致,契约 §6)。"""
    p = await _create_project(client, admin_uid=EVAN_ID, name=_uniq("重复删除项目"))
    pid = p["id"]
    r = await client.delete(f"/api/v1/projects/{pid}", headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    r2 = await client.delete(f"/api/v1/projects/{pid}", headers=_h(EVAN_ID))
    assert r2.status_code == 404, r2.text
    r3 = await client.delete(f"/api/v1/projects/{pid}", headers=_h(OUTSIDER_ID))
    assert r3.status_code in (403, 404), "守门 403 或(已删后)404 均合理,不得 5xx"


# ─── T13:GET projects/deleted 分页/total/q/deleted_by_name ──────────────────
@pytest.mark.asyncio
async def test_deleted_list_pagination_q_and_deleted_by_name(
    client: AsyncClient,
) -> None:
    """T13:deleter 连删 3 个同 marker 项目 → deleted 列表 q 圈定 total=3,
    deleted_at 倒序,limit/offset 切窗稳定,deleted_by/deleted_by_name 正确;
    q 按 code 精确圈定单项;outsider 403(守门同 DELETE)。"""
    g = await _create_group(client, "sd_list")
    gid = g["id"]
    await _set_group_can_delete(client, gid, True)
    uid = await _create_user(client, "sd_list_user", name="删除员乙")
    await _add_group_member(client, gid, uid)

    marker = _uniq("sdlist")   # name 唯一 marker(q 圈定本测试删除的 3 个项目)
    projs = [
        await _create_project(client, admin_uid=EVAN_ID, name=f"{marker} 甲"),
        await _create_project(client, admin_uid=EVAN_ID, name=f"{marker} 乙"),
        await _create_project(client, admin_uid=EVAN_ID, name=f"{marker} 丙"),
    ]
    pids = [p["id"] for p in projs]
    try:
        # 按序删除(deleted_at 倒序断言的依据)
        for pid in pids:
            r = await client.delete(f"/api/v1/projects/{pid}", headers=_h(uid))
            assert r.status_code == 200, r.text

        # 列表:q 圈定 + 字段形状 + 操作人
        rl = await client.get(
            "/api/v1/projects/deleted",
            params={"q": marker, "limit": 200}, headers=_h(uid),
        )
        assert rl.status_code == 200, rl.text
        body = rl.json()
        assert set(body.keys()) >= {"items", "total", "limit", "offset"}, body.keys()
        assert body["total"] == 3, body
        assert {it["id"] for it in body["items"]} == set(pids), body
        for it in body["items"]:
            assert set(it.keys()) >= {
                "id", "code", "name", "description", "visibility",
                "deleted_at", "deleted_by", "deleted_by_name",
            }, it.keys()
            assert str(it["deleted_by"]) == uid, it
            assert it["deleted_by_name"] == "删除员乙", it
            assert it["deleted_at"], it

        # 排序:deleted_at 倒序(后删在前)
        assert [it["id"] for it in body["items"]] == list(reversed(pids)), (
            f"应按 deleted_at 倒序: {body['items']}"
        )

        # 分页:limit=2 切窗,页间不重叠、按序拼接 == 全量
        pg1 = await client.get(
            "/api/v1/projects/deleted",
            params={"q": marker, "limit": 2, "offset": 0}, headers=_h(uid),
        )
        pg2 = await client.get(
            "/api/v1/projects/deleted",
            params={"q": marker, "limit": 2, "offset": 2}, headers=_h(uid),
        )
        b1, b2 = pg1.json(), pg2.json()
        assert b1["total"] == 3 and b1["limit"] == 2 and b1["offset"] == 0, b1
        assert b2["total"] == 3 and len(b2["items"]) == 1, b2
        assert [it["id"] for it in b1["items"]] + [b2["items"][0]["id"]] == list(
            reversed(pids),
        ), "切窗应与全量同序"

        # q 过滤:按 code / 按单项目 name 各圈定 1 条
        rc = await client.get(
            "/api/v1/projects/deleted",
            params={"q": projs[0]["code"]}, headers=_h(uid),
        )
        assert rc.json()["total"] == 1, rc.json()
        assert rc.json()["items"][0]["id"] == pids[0], rc.json()
        rn = await client.get(
            "/api/v1/projects/deleted",
            params={"q": f"{marker} 乙"}, headers=_h(uid),
        )
        assert rn.json()["total"] == 1 and rn.json()["items"][0]["id"] == pids[1], rn.json()

        # 守门:outsider 403
        r403 = await client.get("/api/v1/projects/deleted", headers=_h(OUTSIDER_ID))
        assert r403.status_code == 403, r403.text
    finally:
        await _delete_group(client, gid)   # 3 个项目保持已删除态(收尾即隐藏)


# ─── T14:restore 往返 + 再 restore 404 + 审计 ────────────────────────────────
@pytest.mark.asyncio
async def test_restore_roundtrip_and_audit(client: AsyncClient) -> None:
    """T14:删除 → 全员不可见(deleted 列表在)→ restore → 主列表/详情恢复、
    deleted 列表移除 → 再 restore 404(D11);审计 project_restored
    (details 含 project_id/code/name/restored_by)。"""
    g = await _create_group(client, "sd_restore")
    gid = g["id"]
    await _set_group_can_delete(client, gid, True)
    uid = await _create_user(client, "sd_restore_user", name="删除员丙")
    await _add_group_member(client, gid, uid)
    p = await _create_project(
        client, admin_uid=EVAN_ID, name=_uniq("恢复项目"),
        grants=[{"kind": "user", "id": uid, "roles": ["viewer"]}],
    )
    pid = p["id"]
    code = p["code"]
    try:
        # 删除 → 详情 404、deleted 列表在
        r = await client.delete(f"/api/v1/projects/{pid}", headers=_h(uid))
        assert r.status_code == 200, r.text
        assert (await client.get(
            f"/api/v1/projects/{pid}", headers=_h(uid),
        )).status_code == 404
        dl = await client.get(
            "/api/v1/projects/deleted", params={"q": code}, headers=_h(uid),
        )
        assert dl.json()["total"] == 1, dl.json()

        # restore → 200 {ok, project_id}
        rr = await client.post(f"/api/v1/projects/{pid}/restore", headers=_h(uid))
        assert rr.status_code == 200, rr.text
        assert rr.json()["ok"] is True and rr.json()["project_id"] == pid, rr.json()

        # 恢复可见:详情(deleter 与 system admin)、主列表、deleted 列表移除
        for actor in (uid, EVAN_ID):
            d = await client.get(f"/api/v1/projects/{pid}", headers=_h(actor))
            assert d.status_code == 200, f"actor={actor}: {d.text}"
        assert pid in await _main_list_ids(client, uid)
        dl2 = await client.get(
            "/api/v1/projects/deleted", params={"q": code}, headers=_h(uid),
        )
        assert dl2.json()["total"] == 0, dl2.json()

        # 再 restore → 404(仅作用于 deleted_at 非空者,D11)
        rr2 = await client.post(f"/api/v1/projects/{pid}/restore", headers=_h(uid))
        assert rr2.status_code == 404, rr2.text

        # 审计:project_restored(契约 §8)
        events = await _audit_events(client, "project_restored", uid)
        hit = [e for e in events if (e.get("details") or {}).get("project_id") == pid]
        assert len(hit) == 1, events
        det = hit[0]["details"]
        assert det["code"] == code and det["name"] == p["name"], det
        assert det["restored_by"] == uid, det
    finally:
        await _soft_delete(client, pid)   # 恢复态收尾:再删掉防挤占列表


# ─── T17:迁移冒烟 upgrade head → downgrade -1 → upgrade head ─────────────────
@pytest.mark.alembic
def test_migration_project_soft_delete_upgrade_downgrade() -> None:
    """T17:alembic 冒烟(0015_project_soft_delete:projects 加 deleted_at/
    deleted_by 两列,均可空)。

    独立可跳过:需在有 alembic.ini 的 material-storage/api 目录内运行(容器内
    WORKDIR 即该目录),且 alembic CLI 可用、DB 可连;不满足则 skip。
    末尾必回 head,顺序执行下不影响同 session 其他用例(未假设 xdist 并行)。
    注:pytest.mark.alembic 为自定义标记(pyproject 未注册,仅告警),便于
    `-m "not alembic"` 圈选跳过。
    """
    api_dir = Path(__file__).resolve().parents[1]
    if not (api_dir / "alembic.ini").exists():
        pytest.skip(f"alembic.ini not found under {api_dir};需在 api/ 目录内运行")
    try:
        subprocess.run(["alembic", "--version"], check=True, capture_output=True)
    except (OSError, subprocess.CalledProcessError) as e:
        pytest.skip(f"alembic CLI 不可用: {e}")

    def _run(*args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["alembic", *args], cwd=str(api_dir), capture_output=True, text=True,
        )

    up1 = _run("upgrade", "head")
    assert up1.returncode == 0, f"upgrade head 失败: {up1.stderr or up1.stdout}"
    down = _run("downgrade", "-1")
    assert down.returncode == 0, f"downgrade -1 失败: {down.stderr or down.stdout}"
    up2 = _run("upgrade", "head")
    assert up2.returncode == 0, f"回 upgrade head 失败: {up2.stderr or up2.stdout}"
