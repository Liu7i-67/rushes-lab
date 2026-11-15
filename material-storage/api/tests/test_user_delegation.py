"""用户模块组级授权开放 — 后端集成测试(T1-T15)。

跑在 ms-api 容器里(`docker exec ms-api pytest`)。唯一需求依据:
docs/qdev/2026-11-15-user-delegation.md「接口定义」§5 +「测试功能点」§7 T1-T15
(迁移存量回填不在用例范围)。harness/夹具照抄 test_directory_users_ext.py 与
test_group_file_deleter.py;组在 finally 删、用户无删除 API 靠唯一 marker 不清理。
各用例契约细节见其 docstring;要点:4 端点守门放宽(GET/POST /users、GET
/users/{id}、reset-password → 非 granted 403,非 admin 仅见 created_by=自己),
PATCH/disable/enable/unlock 与 groups 全族仍 admin-only;建号组校验 422
invalid_group_ids(空组可建 D3);user_create_grants tri-state(None=不动 /
list=全量替换终态 / []=撤销),出参 ids/names 同序按组名排序,删组级联(F13);
/me 增 is_user_manager + user_create_groups 三态;审计 user_created.created_by
(非管理员 source=delegated_create)+ group_updated 授权 diff。
预期前置(同 test_directory.py,另加迁移):seed_demo_data.py 已跑过(Evan = 真
user + org admin;outsider = fake 零权限);OpenFGA store/model 已 push;env=dev
(X-User-Id header 模拟身份);迁移 20261115_0021 已 upgrade(users.created_by +
user_create_grants 表)。
"""
from __future__ import annotations

import uuid

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import text

from app.db.session import get_sessionmaker
from app.main import create_app

# seed 写死的真 user / fake outsider(同 test_directory.py)
EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"
OUTSIDER_ID = "00000000-0000-0000-0000-0000000000aa"
# 契约 §5.1/§5.2:组 id 无效(不存在/超 50/非授权)的 422 错误标识
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


# ── 测试内现建辅助(组/用户一律测试内现建;原始响应 helper 状态码由调用方断言)──
async def _create_group(client: AsyncClient, prefix: str = "ud_grp") -> dict:
    r = await client.post("/api/v1/admin/directory/groups", json={
        "name": _uniq(prefix), "description": "user delegation 测试组",
    }, headers=_h(EVAN_ID))
    assert r.status_code == 201, r.text
    return r.json()


async def _post_user(client: AsyncClient, actor: str, username: str, name: str,
                     group_ids: list[str] | None = None):
    """POST /admin/directory/users 原始响应(actor 可为 admin/组长)。"""
    body: dict = {"username": username, "name": name}
    if group_ids is not None:
        body["group_ids"] = group_ids
    return await client.post("/api/v1/admin/directory/users", json=body, headers=_h(actor))


async def _create_user(client: AsyncClient, prefix: str = "ud_user", *,
                       name: str | None = None) -> dict:
    """EVAN(系统 admin)现建本地用户 → UserCreateOut dict(含 temporary_password)。"""
    r = await _post_user(client, EVAN_ID, _uniq(prefix), name or f"UD {prefix}")
    assert r.status_code == 201, r.text
    return r.json()


async def _add_group_member(client: AsyncClient, gid: str, uid: str) -> None:
    r = await client.post(f"/api/v1/admin/directory/groups/{gid}/members",
                          json={"user_id": uid}, headers=_h(EVAN_ID))
    assert r.status_code == 201, r.text


async def _delete_group(client: AsyncClient, gid: str) -> None:
    """删组;已删(404)视为成功(finally 幂等兜底,file_deleter 收尾惯例)。"""
    r = await client.delete(f"/api/v1/admin/directory/groups/{gid}", headers=_h(EVAN_ID))
    assert r.status_code in (200, 404), r.text


async def _cleanup_groups(client: AsyncClient, *gids: str) -> None:
    """finally 批量删组(幂等;用户无删除 API 不清理,照现有惯例)。"""
    for gid in gids:
        await _delete_group(client, gid)


async def _patch_group_raw(client: AsyncClient, gid: str, body: dict):
    """PATCH 组原始响应(422 场景不断言 200)。"""
    return await client.patch(
        f"/api/v1/admin/directory/groups/{gid}", json=body, headers=_h(EVAN_ID))


async def _patch_group(client: AsyncClient, gid: str, body: dict) -> dict:
    r = await _patch_group_raw(client, gid, body)
    assert r.status_code == 200, r.text
    return r.json()


async def _group_echo_by_id(client: AsyncClient, gid: str) -> dict | None:
    """组列表按 id 取回(无组详情路由,读接口回显 user_create_grants 真实态)。"""
    r = await client.get("/api/v1/admin/directory/groups", headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    hits = [g for g in r.json() if g["id"] == gid]
    return hits[0] if hits else None


async def _make_delegator(client: AsyncClient, prefix: str = "ud",
                          target_ids: list[str] | None = None) -> tuple[str, str, str]:
    """标准授权组合:建组 + 组长用户 + 入组 + PATCH 授权目标组 → (gid, uid, 组长name)。
    target_ids=None 不带授权键(tri-state None=不动基线),[] =显式撤销态。"""
    g = await _create_group(client, f"{prefix}_mgr")
    r = await _post_user(client, EVAN_ID, _uniq(f"{prefix}_boss"), f"{prefix} 授权组长")
    assert r.status_code == 201, r.text
    uid = r.json()["id"]
    await _add_group_member(client, g["id"], uid)
    if target_ids is not None:
        await _patch_group(client, g["id"], {"user_create_group_ids": list(target_ids)})
    return g["id"], uid, f"{prefix} 授权组长"


async def _me(client: AsyncClient, uid: str) -> dict:
    r = await client.get("/api/v1/auth/me", headers=_h(uid))
    assert r.status_code == 200, r.text
    return r.json()


async def _login(client: AsyncClient, username: str, password: str):
    """POST /auth/local/login(账号密码登录;只验响应,session cookie 不使用)。"""
    return await client.post(
        "/api/v1/auth/local/login", json={"username": username, "password": password})


async def _reset_pw(client: AsyncClient, actor: str, uid: str):
    return await client.post(
        f"/api/v1/admin/directory/users/{uid}/reset-password", headers=_h(actor))


async def _get_user(client: AsyncClient, actor: str, uid: str):
    return await client.get(f"/api/v1/admin/directory/users/{uid}", headers=_h(actor))


async def _list_users(client: AsyncClient, actor: str, **params: object) -> dict:
    """GET /users → {items,total,limit,offset}(EVAN 全量,组长按 created_by 过滤)。"""
    r = await client.get("/api/v1/admin/directory/users",
                         params=params or None, headers=_h(actor))
    assert r.status_code == 200, r.text
    return r.json()


async def _audit_events(client: AsyncClient, event_type: str, actor_user_id: str) -> list[dict]:
    """按 event_type + actor 拉 audit 原始条目(audit 接口 admin-only,固定用 EVAN 读)。"""
    r = await client.get("/api/v1/admin/audit", params={
        "event_type": event_type, "actor_user_id": actor_user_id, "limit": 500,
    }, headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    return list(r.json())


def _grant_change_ids(node: dict | None, key: str) -> list[str]:
    """从 group_updated details(或 details.changes)取 user_create_group_ids_added/
    removed 的组 id 列表;条目兼容裸 id 字符串与 {group_id,...} 两种形态(并行交付)。"""
    entries = (node or {}).get(key) or []
    return [e if isinstance(e, str) else str(e.get("group_id")) for e in entries]


def _assert_grant_echo(echo: dict | None, targets: list[dict]) -> None:
    """出参 ids/names 同序按组名排序 + 配对与目标组事实一致(§5.2)。"""
    assert echo is not None
    ids, names = echo["user_create_group_ids"], echo["user_create_group_names"]
    assert dict(zip(ids, names, strict=True)) == {t["id"]: t["name"] for t in targets}, echo
    assert sorted(names) == names and set(ids) == {t["id"] for t in targets}, echo


async def _grant_row_count(group_id: str | None = None, target_id: str | None = None) -> int:
    """user_create_grants 行数(按 group_id 或 target_group_id 圈定;级联断言用)。"""
    col, val = ("group_id", group_id) if group_id else ("target_group_id", target_id)
    async with get_sessionmaker()() as db:
        res = await db.execute(
            text(f"SELECT count(*) FROM user_create_grants WHERE {col} = :v"), {"v": val})
        return int(res.scalar_one())


@pytest.mark.asyncio
async def test_delegation_t01_ungranted_all_403(client: AsyncClient) -> None:
    """T1:未授权真用户(入组但组无授权 / 完全不在组)与 fake outsider 对
    list/create/detail/reset 四端点全 403(守门先于存在性;目标真实存在也 403)。"""
    y = await _create_user(client, "ud_t1_target", name="T1 admin建的目标")
    plain = await _create_user(client, "ud_t1_plain", name="T1 无组用户")
    gid, uid, _ = await _make_delegator(client, "ud_t1")   # 入组但无授权
    try:
        for boss in (uid, plain["id"], OUTSIDER_ID):
            r = await client.get("/api/v1/admin/directory/users", headers=_h(boss))
            assert r.status_code == 403, (boss, r.text)
            assert (await _post_user(client, boss, _uniq("ud_t1x"), "T1 不该存在")
                    ).status_code == 403, boss
            assert (await _get_user(client, boss, y["id"])).status_code == 403, boss
            assert (await _reset_pw(client, boss, y["id"])).status_code == 403, boss
    finally:
        await _delete_group(client, gid)


@pytest.mark.asyncio
async def test_delegation_t02_admin_sees_all_and_creator_names(client: AsyncClient) -> None:
    """T2(F2/F6):admin 列表不被 created_by 过滤(q 圈定两个不同创建人的用户全见,
    含 total);列表与详情的 created_by_name 均回显创建人 name。"""
    admin_name = (await _me(client, EVAN_ID))["name"]
    marker = _uniq("udt2")
    a1 = await _create_user(client, "ud_t2_a", name=f"{marker} admin建")
    t1 = await _create_group(client, "ud_t2_tgt")
    gid, uid, boss_name = await _make_delegator(client, "ud_t2", [t1["id"]])
    try:
        r = await _post_user(client, uid, _uniq("ud_t2_b"), f"{marker} 组长建")
        assert r.status_code == 201, r.text
        x = r.json()
        body = await _list_users(client, EVAN_ID, q=marker, limit=200)
        assert body["total"] == 2, body  # admin 全量:admin建 + 组长建都可见
        by_id = {u["id"]: u for u in body["items"]}
        assert by_id[a1["id"]]["created_by_name"] == admin_name, body
        assert by_id[x["id"]]["created_by_name"] == boss_name, body
        det = await _get_user(client, EVAN_ID, x["id"])
        assert det.status_code == 200 and det.json()["created_by_name"] == boss_name, det.text
    finally:
        await _cleanup_groups(client, gid, t1["id"])


@pytest.mark.asyncio
async def test_delegation_t03_delegator_sees_only_own_created(client: AsyncClient) -> None:
    """T3(F6):被授权非 admin GET /users 只见 created_by=自己 的用户(q 圈定下
    admin 建的同 marker 用户不可见);total=过滤后 count;自建用户详情可看。"""
    marker = _uniq("udt3")
    await _create_user(client, "ud_t3_admin", name=f"{marker} admin建不该被看到")
    t1 = await _create_group(client, "ud_t3_tgt")
    gid, uid, boss_name = await _make_delegator(client, "ud_t3", [t1["id"]])
    try:
        mine = []
        for i in range(2):
            r = await _post_user(client, uid, _uniq(f"ud_t3_b{i}"), f"{marker} 组长建{i}")
            assert r.status_code == 201, r.text
            mine.append(r.json())
        body = await _list_users(client, uid, q=marker, limit=200)
        assert set(body.keys()) >= {"items", "total", "limit", "offset"}, body.keys()
        assert body["total"] == 2, body  # admin 建的同 marker 用户被 created_by 过滤掉
        assert {u["id"] for u in body["items"]} == {u["id"] for u in mine}, body
        assert all(u["created_by_name"] == boss_name for u in body["items"]), body
        assert (await _get_user(client, uid, mine[0]["id"])).status_code == 200
    finally:
        await _cleanup_groups(client, gid, t1["id"])


@pytest.mark.asyncio
async def test_delegation_t04_create_granted_temp_pw_login(client: AsyncClient) -> None:
    """T4(F7/F8):组长建号 group_ids=[授权目标组] → 201 + 临时密码回显;临时密码
    可直接登录且 must_change_password=true;created_by 落库;用户真入目标组。"""
    t1 = await _create_group(client, "ud_t4_tgt")
    gid, uid, boss_name = await _make_delegator(client, "ud_t4", [t1["id"]])
    try:
        uname = _uniq("ud_t4_new")
        r = await _post_user(client, uid, uname, "T4 组长建的用户", [t1["id"]])
        assert r.status_code == 201, r.text
        x = r.json()
        assert x["must_change_password"] is True and len(x["temporary_password"]) >= 8, x
        lg = await _login(client, uname, x["temporary_password"])   # 临时密码可登录
        assert lg.status_code == 200 and lg.json()["must_change_password"] is True, lg.text
        det = await _get_user(client, EVAN_ID, x["id"])       # created_by 落库(admin 视角)
        assert det.status_code == 200 and det.json()["created_by_name"] == boss_name, det.text
        rm = await client.get(f"/api/v1/admin/directory/groups/{t1['id']}/members",
                              headers=_h(EVAN_ID))
        assert any(m["user_id"] == x["id"] for m in rm.json()), rm.json()  # 真入目标组
    finally:
        await _cleanup_groups(client, gid, t1["id"])


@pytest.mark.asyncio
async def test_delegation_t05_create_ungranted_group_422(client: AsyncClient) -> None:
    """T5(F7):组长建号 group_ids 含非授权真实组/不存在组 → 422 invalid_group_ids
    且两者消息区分;原子(用户不创建)。"""
    t1 = await _create_group(client, "ud_t5_tgt")
    other = await _create_group(client, "ud_t5_other")   # 真实存在但未授权
    gid, uid, _ = await _make_delegator(client, "ud_t5", [t1["id"]])
    try:
        u_g, u_u, u_m = _uniq("ud_t5_g"), _uniq("ud_t5_u"), _uniq("ud_t5_m")
        r_ghost = await _post_user(client, uid, u_g, "T5 ghost", [str(uuid.uuid4())])
        assert r_ghost.status_code == 422 and _INVALID_GROUP_IDS in r_ghost.text, r_ghost.text
        r_ungrant = await _post_user(client, uid, u_u, "T5 未授权组", [other["id"]])
        assert r_ungrant.status_code == 422 and _INVALID_GROUP_IDS in r_ungrant.text, (
            r_ungrant.text)
        assert r_ghost.json()["detail"] != r_ungrant.json()["detail"], "消息须区分(§5.1)"
        r_mix = await _post_user(client, uid, u_m, "T5 混合", [t1["id"], other["id"]])
        assert r_mix.status_code == 422 and _INVALID_GROUP_IDS in r_mix.text, r_mix.text
        # 原子性:三个用户名均不存在(q 圈定 + items 判无)
        names = {u["username"] for u in (await _list_users(client, EVAN_ID, q="ud_t5_",
                                                           limit=200))["items"]}
        assert not {u_g, u_u, u_m} & names, names
    finally:
        await _cleanup_groups(client, gid, other, t1["id"])


@pytest.mark.asyncio
async def test_delegation_t06_create_empty_groups_201(client: AsyncClient) -> None:
    """T6(D3):被授权组长建号不带 group_ids / 显式 [] 均可(与管理员一致)。"""
    t1 = await _create_group(client, "ud_t6_tgt")
    gid, uid, _ = await _make_delegator(client, "ud_t6", [t1["id"]])
    try:
        for uname, groups in ((_uniq("ud_t6_a"), None), (_uniq("ud_t6_b"), [])):
            r = await _post_user(client, uid, uname, "T6 空组", groups)
            assert r.status_code == 201, r.text
    finally:
        await _cleanup_groups(client, gid, t1["id"])


@pytest.mark.asyncio
async def test_delegation_t07_reset_own_old_pw_invalid(client: AsyncClient) -> None:
    """T7(F9):组长重置自己建的用户 → 200 新临时密码;旧密码登录 401,新密码登录
    200 且 must_change_password=true;列表态同样回 true。"""
    t1 = await _create_group(client, "ud_t7_tgt")
    gid, uid, _ = await _make_delegator(client, "ud_t7", [t1["id"]])
    try:
        uname = _uniq("ud_t7_new")
        r0 = await _post_user(client, uid, uname, "T7 自建用户")
        assert r0.status_code == 201, r0.text
        x = r0.json()
        old_pw = x["temporary_password"]
        r = await _reset_pw(client, uid, x["id"])
        assert r.status_code == 200, r.text
        new_pw = r.json()["temporary_password"]
        assert new_pw != old_pw, "新临时密码不应与旧密码相同"
        assert (await _login(client, uname, old_pw)).status_code == 401, "旧密码必须已失效"
        lg = await _login(client, uname, new_pw)
        assert lg.status_code == 200 and lg.json()["must_change_password"] is True, lg.text
        body = await _list_users(client, uid, q=uname)   # 列表态 must_change_password=true
        hit = next(u for u in body["items"] if u["id"] == x["id"])
        assert hit["must_change_password"] is True, body
    finally:
        await _cleanup_groups(client, gid, t1["id"])


@pytest.mark.asyncio
async def test_delegation_t08_reset_others_403_ghost_404(client: AsyncClient) -> None:
    """T8(F9/D4):组长重置 admin 建的 / 其他组长建的用户 → 403(即便同为被授权
    组长,created_by 不符);不存在的目标 → 404(优先于 created_by 403)。"""
    t1 = await _create_group(client, "ud_t8_tgt")
    gid1, uid1, _ = await _make_delegator(client, "ud_t8a", [t1["id"]])
    gid2, uid2, _ = await _make_delegator(client, "ud_t8b", [t1["id"]])
    try:
        y = await _create_user(client, "ud_t8_admin", name="T8 admin建")  # created_by=admin
        assert (await _reset_pw(client, uid1, y["id"])).status_code == 403
        # uid2 建的用户 created_by=uid2 ≠ uid1 → 即便都被授权也 403
        r2 = await _post_user(client, uid2, _uniq("ud_t8_b2"), "T8 别组长建")
        assert r2.status_code == 201, r2.text
        assert (await _reset_pw(client, uid1, r2.json()["id"])).status_code == 403
        # 目标不存在 → 404(存在性校验优先于 created_by 比对)
        assert (await _reset_pw(client, uid1, str(uuid.uuid4()))).status_code == 404
    finally:
        await _cleanup_groups(client, gid1, gid2, t1["id"])


@pytest.mark.asyncio
async def test_delegation_t09_other_ops_admin_only_403(client: AsyncClient) -> None:
    """T9(F10/D8):被授权组长对自己建的用户 PATCH/停用/启用/解锁全 403(自建目标
    也 403,证明是操作级门不是归属);他人详情 403;groups 全族不变 admin-only。"""
    t1 = await _create_group(client, "ud_t9_tgt")
    gid, uid, _ = await _make_delegator(client, "ud_t9", [t1["id"]])
    try:
        r0 = await _post_user(client, uid, _uniq("ud_t9_new"), "T9 自建目标")
        assert r0.status_code == 201, r0.text
        x = r0.json()
        y = await _create_user(client, "ud_t9_admin", name="T9 admin建目标")
        r = await client.patch(f"/api/v1/admin/directory/users/{x['id']}",
                               json={"name": "T9 越权改名"}, headers=_h(uid))
        assert r.status_code == 403, r.text
        for path in ("disable", "enable", "unlock"):
            rp = await client.post(
                f"/api/v1/admin/directory/users/{x['id']}/{path}", headers=_h(uid))
            assert rp.status_code == 403, (path, rp.text)
        assert (await _get_user(client, uid, y["id"])).status_code == 403  # 他人详情
        # groups 全族仍 require_system_admin(D8:授权配置是管理员动作)
        rg = await client.get("/api/v1/admin/directory/groups", headers=_h(uid))
        assert rg.status_code == 403, rg.text
        rc = await client.post("/api/v1/admin/directory/groups",
                               json={"name": _uniq("ud_t9_grp")}, headers=_h(uid))
        assert rc.status_code == 403, rc.text
        rm = await client.patch(f"/api/v1/admin/directory/groups/{t1['id']}",
                                json={"name": _uniq("ud_t9_ren")}, headers=_h(uid))
        assert rm.status_code == 403, rm.text
        rd = await client.delete(f"/api/v1/admin/directory/groups/{t1['id']}", headers=_h(uid))
        assert rd.status_code == 403, rd.text
        det = await _get_user(client, EVAN_ID, x["id"])   # 越权 PATCH 未生效
        assert det.json()["name"] == "T9 自建目标", det.text
    finally:
        await _cleanup_groups(client, gid, t1["id"])


@pytest.mark.asyncio
async def test_delegation_t10_grant_patch_set_replace_clear_echo(client: AsyncClient) -> None:
    """T10(F3/F4):POST 建组带 user_create_group_ids → 201 回显;PATCH 设/换(list=
    全量替换终态)/清([]=撤销)/不带键(None=不动)后,响应与组列表读接口均按
    真实态回显 ids+names 同序按组名排序。"""
    t1 = await _create_group(client, "ud_t10_a")
    t2 = await _create_group(client, "ud_t10_b")
    t3 = await _create_group(client, "ud_t10_c")
    gid = (await _create_group(client, "ud_t10_mgr"))["id"]
    try:
        # POST 创建即授权 → 201 回显
        rc = await client.post("/api/v1/admin/directory/groups", json={
            "name": _uniq("ud_t10_new"), "user_create_group_ids": [t1["id"], t2["id"]],
        }, headers=_h(EVAN_ID))
        assert rc.status_code == 201, rc.text
        gid_new = rc.json()["id"]
        _assert_grant_echo(rc.json(), [t1, t2])
        # PATCH 设 [t1,t2] → 响应 + 列表读接口双回显
        r1 = await _patch_group(client, gid, {"user_create_group_ids": [t1["id"], t2["id"]]})
        _assert_grant_echo(r1, [t1, t2])
        _assert_grant_echo(await _group_echo_by_id(client, gid), [t1, t2])
        # 不带键(仅改名)→ None=不动
        r2 = await _patch_group(client, gid, {"name": _uniq("ud_t10_ren")})
        _assert_grant_echo(r2, [t1, t2])
        # list=全量替换终态:[t2,t3] 替换掉 [t1,t2]
        r3 = await _patch_group(client, gid, {"user_create_group_ids": [t2["id"], t3["id"]]})
        _assert_grant_echo(r3, [t2, t3])
        _assert_grant_echo(await _group_echo_by_id(client, gid), [t2, t3])
        # []=撤销授权
        r4 = await _patch_group(client, gid, {"user_create_group_ids": []})
        _assert_grant_echo(r4, [])
        _assert_grant_echo(await _group_echo_by_id(client, gid), [])
        await _patch_group(client, gid_new, {"user_create_group_ids": []})  # 收尾一致
    finally:
        await _cleanup_groups(client, gid, gid_new, t3["id"], t2["id"], t1["id"])


@pytest.mark.asyncio
async def test_delegation_t11_group_delete_grant_cascade(client: AsyncClient) -> None:
    """T11(F13):删目标组 → 该组被引用的授权行级联消失(组回显随之清空);删授权
    组 → 其名下授权行全部级联消失(DB 直查 user_create_grants 防孤儿)。"""
    t1 = await _create_group(client, "ud_t11_tgt")
    gid, _, _ = await _make_delegator(client, "ud_t11", [t1["id"]])
    try:
        assert await _grant_row_count(group_id=gid) == 1
        assert await _grant_row_count(target_id=t1["id"]) == 1
        # 删目标组 → 授权行级联删除,授权组回显变空
        await _delete_group(client, t1["id"])
        assert await _grant_row_count(target_id=t1["id"]) == 0, "目标组删除须级联清授权行"
        assert await _grant_row_count(group_id=gid) == 0, "不应残留孤儿行"
        gecho = await _group_echo_by_id(client, gid)
        assert gecho is not None and gecho["user_create_group_ids"] == [], gecho
        # 删授权组 → 名下授权行级联消失
        await _delete_group(client, gid)
        assert await _grant_row_count(group_id=gid) == 0, "授权组删除须级联清授权行"
    finally:
        await _delete_group(client, gid)      # 已删 404 视为成功(幂等兜底)
        await _delete_group(client, t1["id"])


@pytest.mark.asyncio
async def test_delegation_t12_me_tri_state_is_user_manager(client: AsyncClient) -> None:
    """T12(F5):admin → is_user_manager=true 且 user_create_groups=[];被授权非
    admin → true + 目标组集合(含名称);撤销授权后 → false + [];普通用户 false。"""
    t1 = await _create_group(client, "ud_t12_a")
    t2 = await _create_group(client, "ud_t12_b")
    gid, uid, _ = await _make_delegator(client, "ud_t12", [t1["id"], t2["id"]])
    plain = await _create_user(client, "ud_t12_plain", name="T12 普通用户")
    try:
        me_admin = await _me(client, EVAN_ID)
        assert me_admin["is_user_manager"] is True and me_admin["user_create_groups"] == [], (
            me_admin)
        me_boss = await _me(client, uid)
        assert me_boss["is_user_manager"] is True, me_boss
        assert {(g["id"], g["name"]) for g in me_boss["user_create_groups"]} == {
            (t1["id"], t1["name"]), (t2["id"], t2["name"])}, me_boss
        # 撤销授权 → 即时 false + [](F11 的 /me 面)
        await _patch_group(client, gid, {"user_create_group_ids": []})
        me_revoked = await _me(client, uid)
        assert me_revoked["is_user_manager"] is False, me_revoked
        assert me_revoked["user_create_groups"] == [], me_revoked
        # 普通用户(无组无 admin)→ false
        me_plain = await _me(client, plain["id"])
        assert me_plain["is_user_manager"] is False, me_plain
    finally:
        await _cleanup_groups(client, gid, t2["id"], t1["id"])


@pytest.mark.asyncio
async def test_delegation_t13_revoke_immediate_loss_of_access(client: AsyncClient) -> None:
    """T13(F11/D6):授权清空后,原被授权成员端点立即 403(含此前自建用户不再可见/
    不可重置);用户归属不变(admin 仍可见且 created_by_name 仍是原组长)。"""
    t1 = await _create_group(client, "ud_t13_tgt")
    gid, uid, boss_name = await _make_delegator(client, "ud_t13", [t1["id"]])
    try:
        r0 = await _post_user(client, uid, _uniq("ud_t13_new"), "T13 自建用户")
        assert r0.status_code == 201, r0.text
        x = r0.json()
        pre = await _list_users(client, uid, q=x["username"])
        assert pre["total"] == 1, pre   # 基线:授权态可见自建
        await _patch_group(client, gid, {"user_create_group_ids": []})   # 撤销授权
        r = await client.get("/api/v1/admin/directory/users", headers=_h(uid))
        assert r.status_code == 403, r.text
        assert (await _get_user(client, uid, x["id"])).status_code == 403
        assert (await _reset_pw(client, uid, x["id"])).status_code == 403
        # 归属不变:admin 仍可见,created_by_name 仍是原组长
        lst = await _list_users(client, EVAN_ID, q=x["username"])
        assert lst["total"] == 1 and lst["items"][0]["created_by_name"] == boss_name, lst
    finally:
        await _cleanup_groups(client, gid, t1["id"])


@pytest.mark.asyncio
async def test_delegation_t14_grant_targets_invalid_over50_422(client: AsyncClient) -> None:
    """T14(§5.2):PATCH/POST 组授权目标组含不存在组 → 422 invalid_group_ids 且组不
    创建/现态不变;51 个真实组 → 422(条数上限);重复 id 去重容忍(200)。"""
    t1 = await _create_group(client, "ud_t14_tgt")
    gid, _, _ = await _make_delegator(client, "ud_t14", [t1["id"]])
    many: list[str] = []
    try:
        # PATCH ghost → 422,现态 [t1] 不变
        r = await _patch_group_raw(client, gid, {"user_create_group_ids": [str(uuid.uuid4())]})
        assert r.status_code == 422 and _INVALID_GROUP_IDS in r.text, r.text
        _assert_grant_echo(await _group_echo_by_id(client, gid), [t1])
        # POST ghost → 422 且组未创建
        ghost_name = _uniq("ud_t14_new")
        rc = await client.post("/api/v1/admin/directory/groups", json={
            "name": ghost_name, "user_create_group_ids": [str(uuid.uuid4())],
        }, headers=_h(EVAN_ID))
        assert rc.status_code == 422 and _INVALID_GROUP_IDS in rc.text, rc.text
        rl = await client.get("/api/v1/admin/directory/groups",
                              params={"q": ghost_name}, headers=_h(EVAN_ID))
        assert all(g["name"] != ghost_name for g in rl.json()), rl.json()
        # 重复 id → 去重容忍,200 且终态 [t1]
        rd = await _patch_group(client, gid, {"user_create_group_ids": [t1["id"], t1["id"]]})
        _assert_grant_echo(rd, [t1])
        # 51 个真实组 → 422(条数上限而非存在性),现态仍 [t1]
        for i in range(51):
            many.append((await _create_group(client, f"ud_t14_m{i}"))["id"])
        r51 = await _patch_group_raw(client, gid, {"user_create_group_ids": many})
        assert r51.status_code == 422 and _INVALID_GROUP_IDS in r51.text, r51.text
        _assert_grant_echo(await _group_echo_by_id(client, gid), [t1])
    finally:
        await _cleanup_groups(client, *many, gid, t1["id"])


@pytest.mark.asyncio
async def test_delegation_t15_audit_created_by_and_grant_diff(client: AsyncClient) -> None:
    """T15(F12):user_created details 增 created_by(admin 链路 source=admin_create,
    非管理员链路 source=delegated_create);group_updated 落授权 diff
    user_create_group_ids_added/removed(设/换/清各一条真实转变)。"""
    t1 = await _create_group(client, "ud_t15_a")
    t2 = await _create_group(client, "ud_t15_b")
    gid, uid, _ = await _make_delegator(client, "ud_t15", [t1["id"]])
    try:
        # admin 建号:user_created.created_by=EVAN + source=admin_create
        a1 = await _create_user(client, "ud_t15_admin", name="T15 admin建")
        ev_admin = await _audit_events(client, "user_created", EVAN_ID)
        d_admin = next(e["details"] for e in ev_admin
                       if (e.get("details") or {}).get("user_id") == a1["id"])
        assert d_admin["created_by"] == EVAN_ID and d_admin["source"] == "admin_create", d_admin
        # 组长建号:created_by=组长 + source=delegated_create
        r = await _post_user(client, uid, _uniq("ud_t15_new"), "T15 组长建")
        assert r.status_code == 201, r.text
        ev_boss = await _audit_events(client, "user_created", uid)
        d_boss = next(e["details"] for e in ev_boss
                      if (e.get("details") or {}).get("user_id") == r.json()["id"])
        assert d_boss["created_by"] == uid and d_boss["source"] == "delegated_create", d_boss
        # 组授权 diff:基线 [t1](_make_delegator 已设)→ 换 [t1,t2] → 清 []
        await _patch_group(client, gid, {"user_create_group_ids": [t1["id"], t2["id"]]})
        await _patch_group(client, gid, {"user_create_group_ids": []})
        evs = [e for e in await _audit_events(client, "group_updated", EVAN_ID)
               if (e.get("details") or {}).get("group_id") == gid]
        nodes = [(e.get("details") or {}).get("changes") or (e.get("details") or {})
                 for e in evs]
        added = [_grant_change_ids(n, "user_create_group_ids_added") for n in nodes]
        removed = [_grant_change_ids(n, "user_create_group_ids_removed") for n in nodes]
        assert [t1["id"]] in added, (added, evs)   # 设:[t1] 从无到有
        assert [t2["id"]] in added, (added, evs)   # 换:增 t2
        assert any({*rr} == {t1["id"], t2["id"]} for rr in removed), (
            removed, evs)  # 清:双删
    finally:
        await _cleanup_groups(client, gid, t2["id"], t1["id"])
