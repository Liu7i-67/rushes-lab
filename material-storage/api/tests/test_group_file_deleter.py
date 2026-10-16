"""组级「允许删除文件与文件夹」(file_deleter)集成测试(T1-T11)。

跑在 ms-api 容器里(`docker exec ms-api pytest`)。
唯一需求依据:docs/qdev/2026-10-16-group-file-delete-permission.md「测试功能点」
T1-T11 +「功能点明细」F1-F10 +「接口定义」§1-§6。
结构/夹具/身份模拟照抄先例 tests/test_project_soft_delete.py(can_delete_project
全套同构先例);资产构造照 tests/test_trash_and_purge.py 的 DB 直插。

契约要点(实现由并行任务交付,冲突以需求文档为准):
  - F1 organization 增 `file_deleter: [user, group#member]`;model 断言:
    org admin false / 授权组员 true
    ⚠️ **跑前须把含 file_deleter 的 model 重推到测试 store**
    (api/scripts/openfga_write_model.sh;ms-api 重启自动用 latest)——
    未重推时本文件所有组开关用例必挂
  - F2 组开关 can_delete_files:POST 创建即置位;PATCH tri-state(缺省=不改 /
    true=写 tuple / false=删 tuple);组列表回显;删组清 tuple;groups 表不加列
  - F3-F6 assets 守门扩为 is_system_admin ∨ asset#can_admin ∨
    (is_org_file_deleter ∧ asset#can_view ∧ 非 sensitive):软删 / hard purge /
    恢复 / 回收站列表四处;两步制(hard 须先软删,409)不变
  - F7 删夹守门:普通夹 can_upload ∨ (开关 ∧ folder#can_view);sensitive 夹维持
    sensitive_folder#can_admin(开关不穿透);空夹约束(无子夹+无活跃文件+回收站
    清空,409)不变
  - F8 FolderOut.my_delete_grant = is_org_file_deleter ∧ folder#can_view ∧
    非 sensitive(**不含**系统管理员直通);仅 get_folder 回填(my_can_* 同惯例)
  - F9 /me 增 is_file_deleter = is_system_admin or is_org_file_deleter
  - F10 审计保留,actor = 实际操作用户

与文档措辞的两处对照(测试按 API 现状写,疑点已单独上报 PM,见汇报):
  - 文档 T2/T3 写「200」:DELETE 软删 / restore / hard purge / 删夹的成功码沿
    现状为 **204**(无响应体),回收站列表/回显类才是 200;按现状断言。
  - 文档 T8「org admin(未授权组)false」在本代码库不可表达:is_system_admin 即
    organization#admin(deps.get_is_system_admin = perms.is_org_admin,唯一 admin
    概念,scripts/grant_org_admin.py 同证),F9 公式下 org admin 必为 true。
    按可表达部分断言:/me 口径按 F9 公式 + FGA 层「org admin 不自动蕴含
    file_deleter relation」(F1 model 断言的应用层可观测面)。

前端 T12-T14(组编辑弹窗 Switch/组员视角闸门/`pnpm build`+`pnpm lint`)**不在
本文件范围**:属人工真机 + 构建验收,pytest 不覆盖。

预期前置(同 test_project_soft_delete.py):
  1. seed_demo_data.py 已跑过(Evan = 真 user + org admin/system admin;
     outsider = fake 零权限;11111111-…-111111111103 = public 项目)
  2. OpenFGA store / model 已 push(**含 file_deleter relation**,见上 ⚠️)
  3. env=dev(允许 X-User-Id header 模拟身份)

清理惯例(同 test_project_soft_delete.py / test_trash_and_purge.py):组在
finally 里删;自建项目用 DELETE API 收尾(已删 404 视为成功);用户无删除 API,
靠唯一 marker 圈定,不清理(沿用现状);资产 DB 直插模拟已上传,并补
perms.bootstrap_asset 的 parent tuple(complete_upload 同款)—— 不补的话组员的
asset#can_view 恒 false,组开关分支永不命中(假绿/误红根源);purge 的 MinIO
对象删除是 best-effort,对象不存在只 log 不报错。
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

import pytest
from httpx import ASGITransport, AsyncClient

from app.db.session import get_sessionmaker
from app.db.tables import Asset
from app.main import create_app

# seed 写死的真 user / fake outsider(同 test_project_soft_delete.py)
EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"
OUTSIDER_ID = "00000000-0000-0000-0000-0000000000aa"
# seed 的 public 项目(组织内可浏览非敏感夹;T9 用,不新造 —— ProjectCreateIn
# 无 visibility 入参,新建项目恒 private)
PROJECT_PUBLIC = "11111111-1111-1111-1111-111111111103"

# require_system_admin 的既有 403 文案(deps.py);新守门的 403 文案须与之区分
# (可辨识「缺删除权限」而非「非系统管理员」,接口定义 §6,先例 D2 同款要求)
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
    return f"gfd-{uuid.uuid4().hex[:12]}"


# ─── 测试内现建辅助(组/用户/项目/夹/资产一律测试内现建,照先例)───────────────
async def _create_group(
    client: AsyncClient, prefix: str = "gfd_grp", *, can_delete_files: bool = False,
) -> dict:
    """现建目录组(接口定义 §1:POST 支持 can_delete_files,创建即置位)。"""
    r = await client.post(
        "/api/v1/admin/directory/groups",
        json={"name": _uniq(prefix), "description": "file_deleter 测试组",
              "can_delete_files": can_delete_files},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text
    return r.json()


async def _set_group_can_delete_files(
    client: AsyncClient, gid: str, value: bool,
) -> dict:
    """PATCH can_delete_files(接口定义 §2,tri-state)→ 200 组对象(含回显)。"""
    r = await client.patch(
        f"/api/v1/admin/directory/groups/{gid}",
        json={"can_delete_files": value}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    return r.json()


async def _set_group_can_delete_project(
    client: AsyncClient, gid: str, value: bool,
) -> dict:
    """PATCH 既有 can_delete_project(T11 回归用,先例同款)。"""
    r = await client.patch(
        f"/api/v1/admin/directory/groups/{gid}",
        json={"can_delete_project": value}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    return r.json()


async def _create_user(
    client: AsyncClient, prefix: str = "gfd_user", *, name: str | None = None,
) -> str:
    """现建 active 本地用户 → users.id。"""
    uname = _uniq(prefix)
    r = await client.post(
        "/api/v1/admin/directory/users",
        json={"username": uname, "name": name or f"GFD {prefix}"},
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
    admin_uid: str = EVAN_ID,
    name: str | None = None,
    grants: list[dict] | None = None,
) -> dict:
    """EVAN(系统 admin)现建 private 项目 → ProjectOut(新建项目恒 private,
    ProjectCreateIn 无 visibility 入参;public 场景用 seed 的 PROJECT_PUBLIC)。"""
    body: dict = {
        "code": _project_code(),
        "name": name or _uniq("删除权限项目"),
        "minio_bucket": "ms-dev",
        "admin_user_id": admin_uid,
    }
    if grants:
        body["initial_grants"] = grants
    r = await client.post("/api/v1/projects", json=body, headers=_h(EVAN_ID))
    assert r.status_code == 201, r.text
    return r.json()


async def _create_folder(
    client: AsyncClient, project_id: str, name: str, *, is_sensitive: bool = False,
) -> dict:
    """EVAN 现建 folder(系统 admin 直通 can_upload;敏感夹限挂 project 一级)。"""
    r = await client.post("/api/v1/folders", json={
        "project_id": project_id, "name": name, "is_sensitive": is_sensitive,
    }, headers=_h(EVAN_ID))
    assert r.status_code == 201, r.text
    return r.json()


async def _insert_asset(
    perms, folder_id: str, filename: str, *, sensitive: bool = False,
    deleted: bool = False,
) -> uuid.UUID:
    """DB 直插 asset 行(模拟已上传,test_trash_and_purge 同理由)+ 补 FGA
    parent tuple(complete_upload 同款 bootstrap_asset;无 parent tuple 则组员的
    asset#can_view 恒 false)。deleted=True 模拟软删后的回收站行。"""
    async with get_sessionmaker()() as db:
        row = Asset(
            id=uuid.uuid4(),
            folder_id=uuid.UUID(folder_id),
            filename=filename,
            minio_bucket="ms-dev",
            minio_key=f"zz-test/{filename}",   # filename 唯一 → key 唯一(uq 约束)
            size_bytes=11,
            content_type="text/plain",
            uploader_id=uuid.UUID(EVAN_ID),
            deleted_at=datetime.now(timezone.utc) if deleted else None,
            tags={},
        )
        db.add(row)
        await db.commit()
        aid = row.id
    await perms.bootstrap_asset(
        asset_id=str(aid),
        parent_type="sensitive_folder" if sensitive else "folder",
        parent_id=str(folder_id),
    )
    return aid


async def _invite_sensitive_viewer(
    client: AsyncClient, folder_id: str, uid: str,
) -> None:
    """邀请组员进敏感夹作 viewer(受邀制;给「开关不穿透 sensitive」提供
    can_view=true 的最强前提,排除「单纯看不见」的假绿)。"""
    r = await client.post(
        f"/api/v1/folders/{folder_id}/invite",
        json={"user_id": uid, "level": "viewer"}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 204, r.text


async def _revoke_sensitive_invite(
    client: AsyncClient, folder_id: str, uid: str,
) -> None:
    r = await client.delete(
        f"/api/v1/folders/{folder_id}/invite",
        params={"subject": f"user:{uid}", "level": "viewer", "permanent": "true"},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 204, r.text


async def _purge_asset(client: AsyncClient, aid: uuid.UUID) -> None:
    """EVAN 收尾:软删 + 彻底删除(两步制);行已不在时双双 404 视为成功。"""
    r = await client.delete(f"/api/v1/assets/{aid}", headers=_h(EVAN_ID))
    assert r.status_code in (204, 404), r.text
    r = await client.delete(
        f"/api/v1/assets/{aid}", params={"hard": "true"}, headers=_h(EVAN_ID),
    )
    assert r.status_code in (204, 404), r.text


async def _delete_folder_quiet(client: AsyncClient, fid: str) -> None:
    """EVAN 收尾删夹;409(上游清理失败有残留)也吞掉,不掩盖原断言。"""
    r = await client.delete(f"/api/v1/folders/{fid}", headers=_h(EVAN_ID))
    assert r.status_code in (204, 404, 409), r.text


async def _soft_delete_project(client: AsyncClient, pid: str) -> None:
    """收尾专用:把仍活跃的自建项目逻辑删除,防挤占 GET /projects 第一页
    (照 test_project_soft_delete._soft_delete 惯例;已删 404 视为成功)。"""
    import warnings

    try:
        r = await client.delete(f"/api/v1/projects/{pid}", headers=_h(EVAN_ID))
        assert r.status_code in (200, 404), r.text
    except Exception as e:
        warnings.warn(f"soft delete project {pid} failed: {e}; 残留活跃项目", stacklevel=2)


async def _default_org() -> tuple[str, str]:
    """default org 的 (org_id, tenant_key) —— OpenFGA organization object 用 tenant_key。"""
    from app.db.session import get_sessionmaker
    from app.services.org import get_default_organization

    async with get_sessionmaker()() as db:
        org = await get_default_organization(db)
    assert org is not None, "测试前置:settings.default_organization_id 未配置"
    return str(org[0]), org[1]


async def _file_deleter_flag_on(perms, gid: str, tenant_key: str) -> bool:
    """组主体是否持有 organization#file_deleter(组主体直查,check 自动展开)。"""
    return await perms.check(
        user_subject=f"group:{gid}#member", relation="file_deleter",
        object_type="organization", object_id=tenant_key,
    )


async def _audit_events(
    client: AsyncClient, event_type: str, actor_user_id: str,
) -> list[dict]:
    """按 event_type + actor 拉 audit 原始条目(target_*/details 字段均在)。"""
    r = await client.get(
        "/api/v1/admin/audit",
        params={"event_type": event_type, "actor_user_id": actor_user_id, "limit": 500},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    return list(r.json())


async def _make_deleter(
    client: AsyncClient, prefix: str = "gfd",
) -> tuple[str, str]:
    """标准授权组合:现建组(创建即置位 can_delete_files)+ 普通组员 → (gid, uid)。
    项目/夹/资产由各用例按需再建(便于组合 viewer/uploader/不可见等变体)。"""
    g = await _create_group(client, f"{prefix}_grp", can_delete_files=True)
    uid = await _create_user(client, f"{prefix}_user", name=f"{prefix} 删除组员")
    await _add_group_member(client, g["id"], uid)
    return g["id"], uid


# ─── T1:组开关 tri-state + 创建即置位 + 列表回显 + 删组清 tuple ───────────────
@pytest.mark.asyncio
async def test_t1_group_flag_tri_state_create_echo_and_delete_cleanup(
    client: AsyncClient, app_with_lifespan,
) -> None:
    """T1(F2):A 组不带 flag 建组 → 默认回显 False、无 tuple;PATCH true →
    tuple 写 + PATCH/列表双回显;仅改名的不带字段 PATCH → tuple 原样(tri-state
    防静默撤权);false ×2 → tuple 删 + 回显 False,重复清除幂等。B 组 POST 创建
    即置位 → 201 响应 True + tuple 已写 + 列表回显;删组 → file_deleter tuple 清理。"""
    perms = app_with_lifespan.state.permissions
    _, tenant_key = await _default_org()

    # A 组:不带 flag 建组(默认 False)
    ga = await _create_group(client, "gfd_flag")
    gida = ga["id"]
    try:
        echo0 = await _list_group_echo(client, gida, ga["name"])
        assert echo0 is not None and echo0["can_delete_files"] is False, echo0
        assert await _file_deleter_flag_on(perms, gida, tenant_key) is False

        # PATCH true → tuple 写 + 双回显
        r = await _set_group_can_delete_files(client, gida, True)
        assert r["can_delete_files"] is True, r
        assert await _file_deleter_flag_on(perms, gida, tenant_key) is True
        echo1 = await _list_group_echo(client, gida, ga["name"])
        assert echo1 is not None and echo1["can_delete_files"] is True, echo1

        # 仅改名、PATCH body 不带 can_delete_files 字段 → tuple 必须原样
        new_name = _uniq("gfd_flag_renamed")
        rn = await client.patch(
            f"/api/v1/admin/directory/groups/{gida}",
            json={"name": new_name}, headers=_h(EVAN_ID),
        )
        assert rn.status_code == 200, rn.text
        assert await _file_deleter_flag_on(perms, gida, tenant_key) is True, (
            "仅改名的不带字段 PATCH 不得撤 tuple(必须 tri-state)"
        )

        # false → tuple 删 + 回显 False;重复清除幂等(不 500)
        for _ in range(2):
            r2 = await _set_group_can_delete_files(client, gida, False)
            assert r2["can_delete_files"] is False, r2
        assert await _file_deleter_flag_on(perms, gida, tenant_key) is False
        echo2 = await _list_group_echo(client, gida, new_name)
        assert echo2 is not None and echo2["can_delete_files"] is False, echo2
    finally:
        await _delete_group(client, gida)

    # B 组:POST 创建即置位(接口定义 §1)→ 响应回 True + tuple 已写 + 列表回显
    gb = await _create_group(client, "gfd_create", can_delete_files=True)
    gidb = gb["id"]
    try:
        assert gb["can_delete_files"] is True, gb
        assert await _file_deleter_flag_on(perms, gidb, tenant_key) is True
        echob = await _list_group_echo(client, gidb, gb["name"])
        assert echob is not None and echob["can_delete_files"] is True, echob
    finally:
        await _delete_group(client, gidb)
    # 删组清 tuple(F2):组删后组主体不再持有 file_deleter
    assert await _file_deleter_flag_on(perms, gidb, tenant_key) is False, (
        "删组必须清理 organization#file_deleter tuple"
    )


# ─── T2:组员软删 —— 可见普通夹放行(进回收站),无 can_view 夹 403 ─────────────
@pytest.mark.asyncio
async def test_t2_member_soft_delete_visible_and_invisible_folder(
    client: AsyncClient, app_with_lifespan,
) -> None:
    """T2(F3):组员(仅项目 viewer、非 admin)对**有 can_view** 的普通夹文件
    软删 204(成功码沿现状 204,见文件头对照)且进回收站(组员回收站可见);
    对**无 can_view** 的夹(私密项目未授权)403,文案与 require_system_admin
    区分(接口定义 §6),资产行不受影响。"""
    perms = app_with_lifespan.state.permissions
    gid, uid = await _make_deleter(client, "t2")
    # 可见夹:私密项目 + 组员 viewer(initial_grants)→ FGA can_view 经 project 继承
    proj_v = await _create_project(
        client, grants=[{"kind": "user", "id": uid, "roles": ["viewer"]}],
    )
    f_v = await _create_folder(client, proj_v["id"], _uniq("t2_vis"))
    a_v = await _insert_asset(perms, f_v["id"], f"{_uniq('t2vis')}.txt")
    # 不可见夹:私密项目、组员无任何 grant
    proj_h = await _create_project(client, name=_uniq("T2 不可见项目"))
    f_h = await _create_folder(client, proj_h["id"], _uniq("t2_hid"))
    a_h = await _insert_asset(perms, f_h["id"], f"{_uniq('t2hid')}.txt")
    try:
        # 前置:组员对可见夹确有 can_view、对不可见夹确实看不到
        pre = await client.get(f"/api/v1/folders/{f_v['id']}", headers=_h(uid))
        assert pre.status_code == 200 and pre.json()["my_can_view"] is True, pre.text
        pre_h = await client.get(f"/api/v1/folders/{f_h['id']}", headers=_h(uid))
        assert pre_h.status_code == 403, pre_h.text

        # 可见普通夹:软删放行(204),文件进回收站
        r = await client.delete(f"/api/v1/assets/{a_v}", headers=_h(uid))
        assert r.status_code == 204, r.text
        tr = await client.get(
            "/api/v1/assets/trash", params={"folder_id": f_v["id"]}, headers=_h(uid),
        )
        assert tr.status_code == 200, tr.text
        assert tr.json()["total"] == 1, tr.json()
        assert tr.json()["items"][0]["id"] == str(a_v), tr.json()

        # 无 can_view 的夹:403(授权 ∧ 可见,缺一不可),文案可区分
        r2 = await client.delete(f"/api/v1/assets/{a_h}", headers=_h(uid))
        assert r2.status_code == 403, r2.text
        assert r2.json().get("detail") != _REQUIRE_SYSTEM_ADMIN_COPY, (
            f"403 文案须与 require_system_admin 区分: {r2.text}"
        )
        # 资产行未被动过(仍可被系统 admin 查到活跃列表)
        lst = await client.get(
            "/api/v1/assets", params={"folder_id": f_h["id"]}, headers=_h(EVAN_ID),
        )
        assert lst.status_code == 200 and lst.json()["total"] == 1, lst.text
    finally:
        await _purge_asset(client, a_v)
        await _purge_asset(client, a_h)
        await _delete_folder_quiet(client, f_v["id"])
        await _delete_folder_quiet(client, f_h["id"])
        await _soft_delete_project(client, proj_v["id"])
        await _soft_delete_project(client, proj_h["id"])
        await _delete_group(client, gid)


# ─── T3:组员恢复 + 彻底删除(非敏感)+ 两步制 409 不变 ────────────────────────
@pytest.mark.asyncio
async def test_t3_member_restore_and_purge_two_step(
    client: AsyncClient, app_with_lifespan,
) -> None:
    """T3(F4/F6):组员对可见普通夹的非敏感资产 restore 放行(回收站清空)、
    soft→hard purge 放行(行消失);未软删直接 hard → 409(两步制不变)。"""
    perms = app_with_lifespan.state.permissions
    gid, uid = await _make_deleter(client, "t3")
    proj = await _create_project(
        client, grants=[{"kind": "user", "id": uid, "roles": ["viewer"]}],
    )
    f = await _create_folder(client, proj["id"], _uniq("t3_f"))
    a_restore = await _insert_asset(perms, f["id"], f"{_uniq('t3restore')}.txt")
    a_purge = await _insert_asset(perms, f["id"], f"{_uniq('t3purge')}.txt")
    try:
        # 组员软删 a_restore → 回收站 1 条
        r = await client.delete(f"/api/v1/assets/{a_restore}", headers=_h(uid))
        assert r.status_code == 204, r.text

        # 未软删的 a_purge 直接 hard → 409(两步制,组员不放宽)
        r409 = await client.delete(
            f"/api/v1/assets/{a_purge}", params={"hard": "true"}, headers=_h(uid),
        )
        assert r409.status_code == 409, r409.text

        # 组员恢复 → 活跃列表回到 2 条、回收站清空
        rr = await client.post(f"/api/v1/assets/{a_restore}/restore", headers=_h(uid))
        assert rr.status_code == 204, rr.text
        lst = await client.get(
            "/api/v1/assets", params={"folder_id": f["id"]}, headers=_h(uid),
        )
        assert lst.status_code == 200 and lst.json()["total"] == 2, lst.text
        tr = await client.get(
            "/api/v1/assets/trash", params={"folder_id": f["id"]}, headers=_h(uid),
        )
        assert tr.status_code == 200 and tr.json()["total"] == 0, tr.text

        # 组员 soft → hard purge → 行消失、回收站清空
        r2 = await client.delete(f"/api/v1/assets/{a_restore}", headers=_h(uid))
        assert r2.status_code == 204, r2.text
        r3 = await client.delete(
            f"/api/v1/assets/{a_restore}", params={"hard": "true"}, headers=_h(uid),
        )
        assert r3.status_code == 204, r3.text
        async with get_sessionmaker()() as db:
            assert await db.get(Asset, a_restore) is None, "purge 后行应消失"
        tr2 = await client.get(
            "/api/v1/assets/trash", params={"folder_id": f["id"]}, headers=_h(uid),
        )
        assert tr2.status_code == 200 and tr2.json()["total"] == 0, tr2.text
    finally:
        await _purge_asset(client, a_restore)
        await _purge_asset(client, a_purge)
        await _delete_folder_quiet(client, f["id"])
        await _soft_delete_project(client, proj["id"])
        await _delete_group(client, gid)


# ─── T4:组员回收站列表 —— 普通夹 200,sensitive 夹 403 ────────────────────────
@pytest.mark.asyncio
async def test_t4_member_trash_list_normal_and_sensitive(
    client: AsyncClient, app_with_lifespan,
) -> None:
    """T4(F5):组员对可见普通夹的回收站列表放行(现状 can_admin 才可见,
    组开关扩为 can_view);sensitive 夹即便受邀 viewer(有 can_view)仍 403
    (开关不穿透 sensitive),系统 admin 回收站不受影响(正控)。"""
    perms = app_with_lifespan.state.permissions
    gid, uid = await _make_deleter(client, "t4")
    proj = await _create_project(
        client, grants=[{"kind": "user", "id": uid, "roles": ["viewer"]}],
    )
    f = await _create_folder(client, proj["id"], _uniq("t4_normal"))
    a = await _insert_asset(perms, f["id"], f"{_uniq('t4trash')}.txt", deleted=True)
    sf = await _create_folder(
        client, proj["id"], _uniq("t4_sensitive"), is_sensitive=True,
    )
    await _invite_sensitive_viewer(client, sf["id"], uid)
    try:
        # 普通夹:回收站 200 + 内容正确(软删行带 deleted_at)
        tr = await client.get(
            "/api/v1/assets/trash", params={"folder_id": f["id"]}, headers=_h(uid),
        )
        assert tr.status_code == 200, tr.text
        body = tr.json()
        assert body["total"] == 1 and body["items"][0]["id"] == str(a), body
        assert body["items"][0]["deleted_at"] is not None, body

        # sensitive 夹:受邀 viewer + 组开关 on → 仍 403(仅系统 admin)
        tr_s = await client.get(
            "/api/v1/assets/trash", params={"folder_id": sf["id"]}, headers=_h(uid),
        )
        assert tr_s.status_code == 403, tr_s.text

        # 系统 admin 正控:sensitive 夹回收站照常可见
        tr_a = await client.get(
            "/api/v1/assets/trash", params={"folder_id": sf["id"]}, headers=_h(EVAN_ID),
        )
        assert tr_a.status_code == 200, tr_a.text
    finally:
        await _revoke_sensitive_invite(client, sf["id"], uid)
        await _purge_asset(client, a)
        await _delete_folder_quiet(client, f["id"])
        await _delete_folder_quiet(client, sf["id"])
        await _soft_delete_project(client, proj["id"])
        await _delete_group(client, gid)


# ─── T5:sensitive 红线 —— 组开关不穿透敏感资产/敏感夹 ─────────────────────────
@pytest.mark.asyncio
async def test_t5_sensitive_red_line_for_group_member(
    client: AsyncClient, app_with_lifespan,
) -> None:
    """T5(F3/F4/F6/F7 红线):组员**受邀 viewer**(对敏感夹确有 can_view,排除
    「单纯看不见」的假绿)+ 组开关 on,对 sensitive 资产软删/恢复/hard purge、
    对 sensitive 夹删除一律 403 —— 组织开关分支不适用于 sensitive(决策 #3);
    系统 admin 对敏感资产的软删/恢复/清空正控不受影响(F1 既有红线不动)。"""
    perms = app_with_lifespan.state.permissions
    gid, uid = await _make_deleter(client, "t5")
    proj = await _create_project(client, name=_uniq("T5 敏感红线项目"))
    sf = await _create_folder(
        client, proj["id"], _uniq("t5_sensitive"), is_sensitive=True,
    )
    await _invite_sensitive_viewer(client, sf["id"], uid)
    sa = await _insert_asset(perms, sf["id"], f"{_uniq('t5sens')}.txt", sensitive=True)
    try:
        # 前置:组员对敏感夹确有 can_view(受邀制生效)
        pre = await client.get(f"/api/v1/folders/{sf['id']}", headers=_h(uid))
        assert pre.status_code == 200 and pre.json()["my_can_view"] is True, pre.text

        # 软删 403(can_admin 无;**组开关分支不得对 sensitive 生效**)
        r = await client.delete(f"/api/v1/assets/{sa}", headers=_h(uid))
        assert r.status_code == 403, r.text

        # 系统 admin 软删(现状直通)→ 组员 restore / hard purge 仍 403
        rs = await client.delete(f"/api/v1/assets/{sa}", headers=_h(EVAN_ID))
        assert rs.status_code == 204, rs.text
        rr = await client.post(f"/api/v1/assets/{sa}/restore", headers=_h(uid))
        assert rr.status_code == 403, rr.text
        rp = await client.delete(
            f"/api/v1/assets/{sa}", params={"hard": "true"}, headers=_h(uid),
        )
        assert rp.status_code == 403, rp.text

        # 系统 admin 恢复(正控,现状能力不回退)
        ra = await client.post(f"/api/v1/assets/{sa}/restore", headers=_h(EVAN_ID))
        assert ra.status_code == 204, ra.text

        # sensitive 夹删除:组员(有 can_view + 开关 on)仍 403(维持
        # sensitive_folder#can_admin,开关不穿透,F7)
        rf = await client.delete(f"/api/v1/folders/{sf['id']}", headers=_h(uid))
        assert rf.status_code == 403, rf.text
    finally:
        await _revoke_sensitive_invite(client, sf["id"], uid)
        await _purge_asset(client, sa)
        await _delete_folder_quiet(client, sf["id"])
        await _soft_delete_project(client, proj["id"])
        await _delete_group(client, gid)


# ─── T6:组员删夹 —— 可见空夹放行 / 非空 409 / 不可见 403 / sensitive 403 ──────
@pytest.mark.asyncio
async def test_t6_member_delete_folder_matrix(
    client: AsyncClient, app_with_lifespan,
) -> None:
    """T6(F7):组员删可见空普通夹 204(成功码沿现状);非空(活跃文件 /
    回收站未清)409 且文案区分两档(现状惯例);清空回收站后可删(组员自己
    purge 走组开关,闭环);不可见夹 403;sensitive 夹(受邀 viewer)403。"""
    perms = app_with_lifespan.state.permissions
    gid, uid = await _make_deleter(client, "t6")
    proj = await _create_project(
        client, grants=[{"kind": "user", "id": uid, "roles": ["viewer"]}],
    )
    proj_h = await _create_project(client, name=_uniq("T6 不可见项目"))
    f_empty = await _create_folder(client, proj["id"], _uniq("t6_empty"))
    f_live = await _create_folder(client, proj["id"], _uniq("t6_live"))
    a_live = await _insert_asset(perms, f_live["id"], f"{_uniq('t6live')}.txt")
    f_hidden = await _create_folder(client, proj_h["id"], _uniq("t6_hid"))
    sf = await _create_folder(
        client, proj["id"], _uniq("t6_sensitive"), is_sensitive=True,
    )
    await _invite_sensitive_viewer(client, sf["id"], uid)
    try:
        # 可见空普通夹 → 204
        r = await client.delete(f"/api/v1/folders/{f_empty['id']}", headers=_h(uid))
        assert r.status_code == 204, r.text

        # 活跃文件 → 409(不为空)
        r2 = await client.delete(f"/api/v1/folders/{f_live['id']}", headers=_h(uid))
        assert r2.status_code == 409, r2.text
        assert "不为空" in r2.json()["detail"], r2.text

        # 组员软删后回收站非空 → 仍 409(文案指向回收站,不带计数)
        rs = await client.delete(f"/api/v1/assets/{a_live}", headers=_h(uid))
        assert rs.status_code == 204, rs.text
        r3 = await client.delete(f"/api/v1/folders/{f_live['id']}", headers=_h(uid))
        assert r3.status_code == 409, r3.text
        assert "回收站" in r3.json()["detail"], r3.text
        assert not any(ch.isdigit() for ch in r3.json()["detail"]), r3.json()["detail"]

        # 组员清空回收站(非敏感 purge 走组开关)→ 删夹放行(闭环)
        rp = await client.delete(
            f"/api/v1/assets/{a_live}", params={"hard": "true"}, headers=_h(uid),
        )
        assert rp.status_code == 204, rp.text
        r4 = await client.delete(f"/api/v1/folders/{f_live['id']}", headers=_h(uid))
        assert r4.status_code == 204, r4.text

        # 不可见夹(私密项目无 grant)→ 403
        r5 = await client.delete(f"/api/v1/folders/{f_hidden['id']}", headers=_h(uid))
        assert r5.status_code == 403, r5.text
        assert r5.json().get("detail") != _REQUIRE_SYSTEM_ADMIN_COPY, r5.text

        # sensitive 夹(受邀 viewer + 开关 on)→ 403(维持 can_admin 门槛)
        r6 = await client.delete(f"/api/v1/folders/{sf['id']}", headers=_h(uid))
        assert r6.status_code == 403, r6.text
    finally:
        await _revoke_sensitive_invite(client, sf["id"], uid)
        await _purge_asset(client, a_live)
        await _delete_folder_quiet(client, f_live["id"])
        await _delete_folder_quiet(client, f_hidden["id"])
        await _delete_folder_quiet(client, sf["id"])
        await _soft_delete_project(client, proj["id"])
        await _soft_delete_project(client, proj_h["id"])
        await _delete_group(client, gid)


# ─── T7:失权 —— 移出组 / 关开关后全部 403(开关实时生效)──────────────────────
@pytest.mark.asyncio
async def test_t7_revoke_by_removing_member_and_by_flag_off(
    client: AsyncClient, app_with_lifespan,
) -> None:
    """T7:基线(开关 on + 在组)回收站 200;**移出组** → 软删 403、回收站 403、
    /me is_file_deleter 翻 false;重新入组恢复;**PATCH 关开关** → 软删/回收站/
    删夹全 403、/me false。"""
    perms = app_with_lifespan.state.permissions
    g = await _create_group(client, "t7_grp", can_delete_files=True)
    gid = g["id"]
    uid = await _create_user(client, "t7_user", name="T7 失权组员")
    await _add_group_member(client, gid, uid)
    proj = await _create_project(
        client, grants=[{"kind": "user", "id": uid, "roles": ["viewer"]}],
    )
    f = await _create_folder(client, proj["id"], _uniq("t7_f"))
    a = await _insert_asset(perms, f["id"], f"{_uniq('t7')}.txt")
    f_e = await _create_folder(client, proj["id"], _uniq("t7_empty"))
    try:
        # 基线:授权态回收站可见
        tr0 = await client.get(
            "/api/v1/assets/trash", params={"folder_id": f["id"]}, headers=_h(uid),
        )
        assert tr0.status_code == 200, tr0.text

        # 移出组 → 软删 403 / 回收站 403 / /me false
        await _remove_group_member(client, gid, uid)
        r = await client.delete(f"/api/v1/assets/{a}", headers=_h(uid))
        assert r.status_code == 403, r.text
        tr1 = await client.get(
            "/api/v1/assets/trash", params={"folder_id": f["id"]}, headers=_h(uid),
        )
        assert tr1.status_code == 403, tr1.text
        me1 = (await client.get("/api/v1/auth/me", headers=_h(uid))).json()
        assert me1["is_file_deleter"] is False, me1

        # 重新入组 → 授权恢复(软删/回收站回 200/204)
        await _add_group_member(client, gid, uid)
        r2 = await client.delete(f"/api/v1/assets/{a}", headers=_h(uid))
        assert r2.status_code == 204, r2.text
        tr2 = await client.get(
            "/api/v1/assets/trash", params={"folder_id": f["id"]}, headers=_h(uid),
        )
        assert tr2.status_code == 200, tr2.text
        rr = await client.post(f"/api/v1/assets/{a}/restore", headers=_h(uid))
        assert rr.status_code == 204, rr.text

        # PATCH 关开关 → 软删 / 回收站 / 删空夹全 403,/me false(开关实时生效)
        await _set_group_can_delete_files(client, gid, False)
        r3 = await client.delete(f"/api/v1/assets/{a}", headers=_h(uid))
        assert r3.status_code == 403, r3.text
        tr3 = await client.get(
            "/api/v1/assets/trash", params={"folder_id": f["id"]}, headers=_h(uid),
        )
        assert tr3.status_code == 403, tr3.text
        r4 = await client.delete(f"/api/v1/folders/{f_e['id']}", headers=_h(uid))
        assert r4.status_code == 403, r4.text
        me2 = (await client.get("/api/v1/auth/me", headers=_h(uid))).json()
        assert me2["is_file_deleter"] is False, me2
    finally:
        await _purge_asset(client, a)
        await _delete_folder_quiet(client, f["id"])
        await _delete_folder_quiet(client, f_e["id"])
        await _soft_delete_project(client, proj["id"])
        await _delete_group(client, gid)


# ─── T8:/me is_file_deleter 与守门口径一致 ────────────────────────────────────
@pytest.mark.asyncio
async def test_t8_me_is_file_deleter(
    client: AsyncClient, app_with_lifespan,
) -> None:
    """T8(F9):组员随开关翻转 is_file_deleter;普通用户/零权限 outsider false;
    系统 admin(EVAN)恒 true。FGA 层正控:org admin(EVAN)**不自动蕴含**
    file_deleter relation(F1 model 断言的应用层可观测面 —— tuple 只由组开关写)。

    注:文档 T8 的「org admin(未授权组)false」在本代码库不可表达 ——
    is_system_admin 即 organization#admin(同一判定,deps.get_is_system_admin /
    scripts/grant_org_admin.py),F9 公式下 org admin 必为 true;此处按 F9 公式
    断言 + FGA 层补「admin 直通不来自 file_deleter tuple」,差异已报 PM。"""
    perms = app_with_lifespan.state.permissions
    _, tenant_key = await _default_org()
    g = await _create_group(client, "t8_grp")
    gid = g["id"]
    uid = await _create_user(client, "t8_user", name="T8 开关组员")
    await _add_group_member(client, gid, uid)
    plain = await _create_user(client, "t8_plain", name="T8 普通用户")
    try:
        # 组未开 flag → false
        me0 = (await client.get("/api/v1/auth/me", headers=_h(uid))).json()
        assert me0["is_file_deleter"] is False, me0

        # 开 flag → true;关 → false(实时翻转)
        await _set_group_can_delete_files(client, gid, True)
        me1 = (await client.get("/api/v1/auth/me", headers=_h(uid))).json()
        assert me1["is_file_deleter"] is True, me1
        await _set_group_can_delete_files(client, gid, False)
        me2 = (await client.get("/api/v1/auth/me", headers=_h(uid))).json()
        assert me2["is_file_deleter"] is False, me2

        # 普通用户(无组无 admin)/ 零权限 outsider → false
        me_plain = (await client.get("/api/v1/auth/me", headers=_h(plain))).json()
        assert me_plain["is_file_deleter"] is False, me_plain
        me_out = (await client.get("/api/v1/auth/me", headers=_h(OUTSIDER_ID))).json()
        assert me_out["is_file_deleter"] is False, me_out

        # 系统 admin(EVAN = organization#admin)→ true(F9 第一支)
        me_admin = (await client.get("/api/v1/auth/me", headers=_h(EVAN_ID))).json()
        assert me_admin["is_file_deleter"] is True, me_admin
        # FGA 正控:该 true 来自 is_system_admin 直通,而非 file_deleter tuple
        # (org admin 不自动蕴含 relation,F1;组开关未对 EVAN 所属组置位)
        assert await perms.check(
            user_subject=f"user:{EVAN_ID}", relation="file_deleter",
            object_type="organization", object_id=tenant_key,
        ) is False, "org admin 不应自动持有 file_deleter tuple(F1)"
    finally:
        await _delete_group(client, gid)


# ─── T9:FolderOut.my_delete_grant 下发口径 ────────────────────────────────────
@pytest.mark.asyncio
async def test_t9_folder_out_my_delete_grant(
    client: AsyncClient, app_with_lifespan,
) -> None:
    """T9(F8):my_delete_grant = is_org_file_deleter ∧ folder#can_view ∧ 非
    sensitive(**不含**系统管理员直通,F8)。
    - 组员(开关 on)对可见普通夹 → True(且与 my_can_admin 正交:viewer 仍 False);
    - 同夹非组员 viewer(can_view 同为 True)→ False(非组员恒 false);
    - 开关 off → False;
    - sensitive 夹(受邀 viewer)→ False;
    - public 项目普通夹:组员经 public 可浏览(GET 200)但无 FGA can_view → False
      (钉 FGA folder#can_view 口径,与 F3/F5 守门的 asset#can_view 同源;若实现
      采 public 直通口径会在此挂红 —— 差异点已报 PM 裁决);
    - 系统 admin 对普通夹 → False(my_can_admin True;直通不经本字段表达)。"""
    perms = app_with_lifespan.state.permissions
    gid, uid = await _make_deleter(client, "t9")
    v2 = await _create_user(client, "t9_v2", name="T9 非组员viewer")   # 同夹 viewer、不入组
    proj = await _create_project(client, grants=[
        {"kind": "user", "id": uid, "roles": ["viewer"]},
        {"kind": "user", "id": v2, "roles": ["viewer"]},
    ])
    f = await _create_folder(client, proj["id"], _uniq("t9_normal"))
    sf = await _create_folder(
        client, proj["id"], _uniq("t9_sensitive"), is_sensitive=True,
    )
    await _invite_sensitive_viewer(client, sf["id"], uid)
    f_pub = await _create_folder(client, PROJECT_PUBLIC, _uniq("t9_public"))
    try:
        # 组员 + 开关 on + 可见普通夹 → True;my_can_admin 正交(False)
        me_f = await client.get(f"/api/v1/folders/{f['id']}", headers=_h(uid))
        assert me_f.status_code == 200, me_f.text
        assert me_f.json()["my_delete_grant"] is True, me_f.json()
        assert me_f.json()["my_can_admin"] is False, me_f.json()

        # 同夹非组员 viewer(can_view 同 True)→ False
        v2_f = await client.get(f"/api/v1/folders/{f['id']}", headers=_h(v2))
        assert v2_f.status_code == 200 and v2_f.json()["my_can_view"] is True, v2_f.text
        assert v2_f.json()["my_delete_grant"] is False, v2_f.json()

        # 开关 off → False;再开 → True(实时)
        await _set_group_can_delete_files(client, gid, False)
        off = await client.get(f"/api/v1/folders/{f['id']}", headers=_h(uid))
        assert off.status_code == 200 and off.json()["my_delete_grant"] is False, off.json()
        await _set_group_can_delete_files(client, gid, True)

        # sensitive 夹(受邀 viewer)→ False
        me_sf = await client.get(f"/api/v1/folders/{sf['id']}", headers=_h(uid))
        assert me_sf.status_code == 200, me_sf.text
        assert me_sf.json()["my_delete_grant"] is False, me_sf.json()

        # public 项目普通夹:组员可浏览(GET 200)但无 FGA can_view → False
        me_pub = await client.get(f"/api/v1/folders/{f_pub['id']}", headers=_h(uid))
        assert me_pub.status_code == 200, me_pub.text
        assert me_pub.json()["my_delete_grant"] is False, me_pub.json()

        # 系统 admin → False(my_can_admin True;F8 不含系统管理员直通)
        ev_f = await client.get(f"/api/v1/folders/{f['id']}", headers=_h(EVAN_ID))
        assert ev_f.status_code == 200, ev_f.text
        assert ev_f.json()["my_delete_grant"] is False, ev_f.json()
        assert ev_f.json()["my_can_admin"] is True, ev_f.json()
    finally:
        await _revoke_sensitive_invite(client, sf["id"], uid)
        await _delete_folder_quiet(client, f["id"])
        await _delete_folder_quiet(client, sf["id"])
        await _delete_folder_quiet(client, f_pub["id"])
        await _soft_delete_project(client, proj["id"])
        await _delete_group(client, gid)


# ─── T10:组员删除操作审计落库且 actor 正确 ────────────────────────────────────
@pytest.mark.asyncio
async def test_t10_audit_actor_is_member(
    client: AsyncClient, app_with_lifespan,
) -> None:
    """T10(F10):组员软删 / 彻底删除 / 删夹的既有审计保留,actor = 实际操作
    组员(不是系统 admin),details/target 可溯源。"""
    perms = app_with_lifespan.state.permissions
    gid, uid = await _make_deleter(client, "t10")
    proj = await _create_project(
        client, grants=[{"kind": "user", "id": uid, "roles": ["viewer"]}],
    )
    f = await _create_folder(client, proj["id"], _uniq("t10_f"))
    fname = f"{_uniq('t10asset')}.txt"
    a = await _insert_asset(perms, f["id"], fname)
    f2 = await _create_folder(client, proj["id"], _uniq("t10_empty"))
    try:
        r = await client.delete(f"/api/v1/assets/{a}", headers=_h(uid))
        assert r.status_code == 204, r.text
        # 软删审计:asset_deleted,actor=组员,target_asset_id / filename 可溯源
        ev_del = await _audit_events(client, "asset_deleted", uid)
        hit = [e for e in ev_del if e.get("target_asset_id") == str(a)]
        assert len(hit) == 1, ev_del
        assert hit[0]["actor_user_id"] == uid, hit[0]
        assert (hit[0].get("details") or {}).get("filename") == fname, hit[0]

        # 彻底删除审计:asset_purged,actor=组员,details.asset_id(hard)
        r2 = await client.delete(
            f"/api/v1/assets/{a}", params={"hard": "true"}, headers=_h(uid),
        )
        assert r2.status_code == 204, r2.text
        ev_purge = await _audit_events(client, "asset_purged", uid)
        hit2 = [
            e for e in ev_purge
            if (e.get("details") or {}).get("asset_id") == str(a)
        ]
        assert len(hit2) == 1, ev_purge
        assert hit2[0]["actor_user_id"] == uid, hit2[0]

        # 删夹审计:folder_deleted,actor=组员,details.folder_id
        r3 = await client.delete(f"/api/v1/folders/{f2['id']}", headers=_h(uid))
        assert r3.status_code == 204, r3.text
        ev_fold = await _audit_events(client, "folder_deleted", uid)
        hit3 = [
            e for e in ev_fold
            if (e.get("details") or {}).get("folder_id") == f2["id"]
        ]
        assert len(hit3) == 1, ev_fold
        assert hit3[0]["actor_user_id"] == uid, hit3[0]
    finally:
        await _purge_asset(client, a)
        await _delete_folder_quiet(client, f["id"])
        await _soft_delete_project(client, proj["id"])
        await _delete_group(client, gid)


# ─── T11:回归 —— 对象级路径/系统 admin/既有组级 flag 不受影响 ─────────────────
@pytest.mark.asyncio
async def test_t11_regression_object_paths_and_existing_flags(
    client: AsyncClient, app_with_lifespan,
) -> None:
    """T11(F15/T11):①对象级 can_admin 路径:项目 admin(非系统 admin、不入组,
    /me is_file_deleter false)软删/恢复/彻底删除照旧 204;②对象级 can_upload
    路径:uploader 删空普通夹照旧 204;③既有组级 flag project_deleter 不受影响:
    PATCH/开关互不覆盖(FGA tuple 独立),组员删/恢复项目照旧;④系统 admin 的
    is_file_deleter 由直通保证(T8 已断言),此处回归项目删除守门。"""
    # ③ 需要组名做列表回显(_list_group_echo 按 name 圈定),故不用 _make_deleter
    # (它只返回 gid/uid),在此等价内联:创建即置位 can_delete_files + 建用户 + 入组
    g = await _create_group(client, "t11_grp", can_delete_files=True)
    gid = g["id"]
    uid = await _create_user(client, "t11_user", name="T11 删除组员")
    await _add_group_member(client, gid, uid)
    perms = app_with_lifespan.state.permissions

    # ① 对象级 can_admin:项目 admin(无组开关)删除路径不变
    pa = await _create_user(client, "t11_pa", name="T11 项目管理员")
    proj_a = await _create_project(client, admin_uid=pa, name=_uniq("T11 对象级项目"))
    f_a = await _create_folder(client, proj_a["id"], _uniq("t11_pa"))
    a = await _insert_asset(perms, f_a["id"], f"{_uniq('t11obj')}.txt")
    try:
        me_pa = (await client.get("/api/v1/auth/me", headers=_h(pa))).json()
        assert me_pa["is_file_deleter"] is False, me_pa   # 无组开关,字段不亮
        r = await client.delete(f"/api/v1/assets/{a}", headers=_h(pa))
        assert r.status_code == 204, r.text               # can_admin 软删照旧
        rr = await client.post(f"/api/v1/assets/{a}/restore", headers=_h(pa))
        assert rr.status_code == 204, rr.text             # can_admin 恢复照旧
        r2 = await client.delete(f"/api/v1/assets/{a}", headers=_h(pa))
        assert r2.status_code == 204, r2.text
        r3 = await client.delete(
            f"/api/v1/assets/{a}", params={"hard": "true"}, headers=_h(pa),
        )
        assert r3.status_code == 204, r3.text             # can_admin purge 照旧
    finally:
        await _purge_asset(client, a)
        await _delete_folder_quiet(client, f_a["id"])
        await _soft_delete_project(client, proj_a["id"])

    # ② 对象级 can_upload:uploader 删空普通夹照旧(新守门不挤掉旧路径)
    up = await _create_user(client, "t11_up", name="T11 上传者")
    proj_u = await _create_project(
        client, grants=[{"kind": "user", "id": up, "roles": ["uploader"]}],
    )
    f_u = await _create_folder(client, proj_u["id"], _uniq("t11_up"))
    try:
        r = await client.delete(f"/api/v1/folders/{f_u['id']}", headers=_h(up))
        assert r.status_code == 204, r.text
    finally:
        await _delete_folder_quiet(client, f_u["id"])
        await _soft_delete_project(client, proj_u["id"])

    # ③ 既有 project_deleter flag 与新 flag 互不干扰,项目删除/恢复照旧
    await _set_group_can_delete_project(client, gid, True)
    proj_p = await _create_project(client, admin_uid=EVAN_ID, name=_uniq("T11 组删项目"))
    try:
        me_m = (await client.get("/api/v1/auth/me", headers=_h(uid))).json()
        assert me_m["is_project_deleter"] is True, me_m   # 既有 flag 生效如常

        # 双 flag 同组并开 → 列表回显互不覆盖
        r_echo = await _list_group_echo(client, gid, g["name"])
        assert r_echo is not None, r_echo
        assert r_echo["can_delete_project"] is True, r_echo
        assert r_echo["can_delete_files"] is True, r_echo

        # 项目删除/恢复(F6 既有能力)照旧
        rd = await client.delete(f"/api/v1/projects/{proj_p['id']}", headers=_h(uid))
        assert rd.status_code == 200, rd.text
        rres = await client.post(
            f"/api/v1/projects/{proj_p['id']}/restore", headers=_h(uid),
        )
        assert rres.status_code == 200, rres.text

        # 关新 flag → 既有 project_deleter tuple 不被牵连(tuple 独立 + 回显不变)
        await _set_group_can_delete_files(client, gid, False)
        _, tenant_key = await _default_org()
        assert await perms.check(
            user_subject=f"group:{gid}#member", relation="project_deleter",
            object_type="organization", object_id=tenant_key,
        ) is True, "关 can_delete_files 不得牵连 project_deleter tuple"
        echo2 = await _list_group_echo(client, gid, g["name"])
        assert echo2 is not None and echo2["can_delete_project"] is True, echo2
        assert echo2["can_delete_files"] is False, echo2
    finally:
        await _soft_delete_project(client, proj_p["id"])
        await _delete_group(client, gid)
