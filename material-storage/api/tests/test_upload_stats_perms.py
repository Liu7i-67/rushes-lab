"""文件上传数量统计端点(权限面)集成测试 — 权限矩阵 / 零泄露死角 / 聚合自洽(包 C)。

唯一需求依据:docs/qdev/2026-11-06-stats-panel-upload-stats.md
§7.5 权限矩阵 / §7.6 零泄露与死角 / §7.7 聚合自洽 / §7.4 非 admin 静默丢弃
+ §3.2 守门口径 / §4.4 数据权限(folder 级零泄露 + 行集合两层并集)。
窗口与归一 / 分类矩阵 / 软删活性在 tests/test_upload_stats.py(同域拆分,
两文件合计覆盖 §7 全部)。

⚠️ **跑前须把含 stats_viewer / usage_stats_viewer / upload_stats_viewer 三条新
relation 的 model 重推到测试 store**(api/scripts/openfga_write_model.sh;ms-api
重启自动用 latest,照 test_group_file_deleter.py:12-14 同款 ⚠️)—— 未重推时
check 撞未知 relation,组开关用例必挂。

契约要点(实现由并行包 A 交付,冲突以需求文档为准):
  - require_upload_stats_viewer 口径 = is_org_admin ∨ (stats_viewer ∧
    upload_stats_viewer);require_usage_stats_viewer 同构(子 flag 换
    usage_stats_viewer);两守门 403 文案均与 require_system_admin 区分(§3.2);
    **合取防「子开父关」不一致 tuple 绕面板直打接口**(D1)
  - 数据权限(§4.4,与盲搜 assets.py:667-691 同款 + 项目活性收紧):admin
    true() 直通;非 admin folder_id IN(list_objects(can_view,folder) ∪
    list_objects(can_view,sensitive_folder) ∪ public 项目非敏感 folder);
    未受邀 sensitive 零泄露、受邀照常计入;sensitive 不走 public 直通
  - 行集合:项目宇宙(同 GET /projects,排除归档/软删)零填充 ∪ 补充项目
    (仅 folder 级 grant、项目不可达 → 计数面含其资产,「有数即现」不零填充);
    project_ids 对两层取交集,不可见/归档/软删/未知 id 静默丢弃不 403
  - summary = rows 逐列和(后端为准);rows 排序 total desc → project_name asc

前置(同 test_usage_stats.py):seed 已跑(Evan=system admin);OpenFGA store /
model 已 push(**含三条新 relation**,见上 ⚠️);env=dev(X-User-Id 模拟身份)。
造数:组/用户/项目/夹一律测试内现建;asset DB 直插(同 test_upload_stats.py,
计数面走 folder 级 can_view,不补 parent tuple);组在 finally 删;项目软删收尾。
"""
from __future__ import annotations

import uuid
from datetime import date, datetime, time, timedelta, timezone

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import create_app

EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"  # seed:system admin
URL = "/api/v1/admin/stats/uploads"
USAGE_URL = "/api/v1/admin/usage/stats"
CN_TZ = timezone(timedelta(hours=8))
D_IN = date(2026, 3, 11)
W_FROM, W_TO = "2026-03-10", "2026-03-12"
# require_system_admin 的既有 403 文案(deps.py);新守门 403 文案须与之区分(§3.2)
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
    return f"usp-{uuid.uuid4().hex[:12]}"


def _dt(d: date, h: int = 0, m: int = 0, s: int = 0) -> datetime:
    return datetime.combine(d, time(h, m, s), tzinfo=CN_TZ)


def _q(f: str = W_FROM, t: str = W_TO, pids: str | list[str] | None = None) -> dict:
    p: dict = {"date_from": f, "date_to": t}
    if pids is not None:
        p["project_ids"] = ",".join(pids) if isinstance(pids, list) else pids
    return p


def _row(body: dict, pid: str) -> dict | None:
    return next((r for r in body["rows"] if r["project_id"] == str(pid)), None)


async def _create_user(client: AsyncClient, prefix: str) -> str:
    """现建 active 本地用户 → users.id(无删除 API,唯一 marker 圈定不清理,先例同)。"""
    r = await client.post("/api/v1/admin/directory/users", json={
        "username": _uniq(prefix), "name": f"USP {prefix}",
    }, headers=_h(EVAN_ID))
    assert r.status_code == 201, r.text
    return r.json()["id"]


async def _flag_member(
    client: AsyncClient, prefix: str, *, stats: bool, usage: bool, upload: bool,
) -> tuple[str, str]:
    """现建组(POST 全量传三 flag,创建即置位)+ 组员 → (gid, uid)(§3.3)。"""
    r = await client.post("/api/v1/admin/directory/groups", json={
        "name": _uniq(f"{prefix}_grp"), "description": "统计权限测试组",
        "can_view_stats": stats, "can_view_usage_stats": usage,
        "can_view_upload_stats": upload,
    }, headers=_h(EVAN_ID))
    assert r.status_code == 201, r.text
    gid = r.json()["id"]
    uid = await _create_user(client, f"{prefix}_u")
    rm = await client.post(f"/api/v1/admin/directory/groups/{gid}/members",
                           json={"user_id": uid}, headers=_h(EVAN_ID))
    assert rm.status_code == 201, rm.text
    return gid, uid


async def _delete_group(client: AsyncClient, gid: str) -> None:
    r = await client.delete(f"/api/v1/admin/directory/groups/{gid}", headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text


async def _create_project(
    client: AsyncClient, *, name: str | None = None, grants: list[dict] | None = None,
) -> dict:
    body: dict = {"code": _project_code(), "name": name or _uniq("统计权限项目"),
                  "minio_bucket": "ms-dev", "admin_user_id": EVAN_ID}
    if grants:
        body["initial_grants"] = grants
    r = await client.post("/api/v1/projects", json=body, headers=_h(EVAN_ID))
    assert r.status_code == 201, r.text
    return r.json()


async def _create_folder(
    client: AsyncClient, project_id: str, name: str, *, is_sensitive: bool = False,
) -> dict:
    r = await client.post("/api/v1/folders", json={
        "project_id": project_id, "name": name, "is_sensitive": is_sensitive,
    }, headers=_h(EVAN_ID))
    assert r.status_code == 201, r.text
    return r.json()


async def _insert_asset(folder_id: str, filename: str, *, content_type: str | None,
                        created_at: datetime) -> uuid.UUID:
    from app.db.session import get_sessionmaker
    from app.db.tables import Asset

    async with get_sessionmaker()() as db:
        row = Asset(
            id=uuid.uuid4(), folder_id=uuid.UUID(folder_id), filename=filename,
            minio_bucket="ms-dev", minio_key=f"zz-usp/{uuid.uuid4().hex}/{filename}",
            size_bytes=11, content_type=content_type, uploader_id=uuid.UUID(EVAN_ID),
            created_at=created_at, deleted_at=None, tags={},
        )
        db.add(row)
        await db.commit()
        return row.id


async def _set_project_db(pid: str, **values) -> None:
    """projects 表直改(visibility / is_archived:均无 API 入参,DB 直改先例同
    test_default_template.py 的 is_archived)。"""
    from sqlalchemy import update

    from app.db.session import get_sessionmaker
    from app.db.tables import Project

    async with get_sessionmaker()() as db:
        await db.execute(
            update(Project).where(Project.id == uuid.UUID(pid)).values(**values)
        )
        await db.commit()


async def _grant_folder(client: AsyncClient, fid: str, uid: str) -> None:
    """folder 级 explicit grant(仅一级夹;store.fga.yaml folder#explicit_viewer)。"""
    r = await client.post(f"/api/v1/folders/{fid}/grants",
                          json={"user_id": uid, "level": "viewer"}, headers=_h(EVAN_ID))
    assert r.status_code == 204, r.text


async def _invite_sensitive(client: AsyncClient, fid: str, uid: str) -> None:
    r = await client.post(f"/api/v1/folders/{fid}/invite",
                          json={"user_id": uid, "level": "viewer"}, headers=_h(EVAN_ID))
    assert r.status_code == 204, r.text


async def _revoke_invite(client: AsyncClient, fid: str, uid: str) -> None:
    r = await client.delete(f"/api/v1/folders/{fid}/invite",
                            params={"subject": f"user:{uid}", "level": "viewer",
                                    "permanent": "true"}, headers=_h(EVAN_ID))
    assert r.status_code in (204, 404), r.text


async def _cleanup(client: AsyncClient, *, aids=(), folder_ids=(), project_ids=()) -> None:
    """收尾:purge 资产 → 删夹 → 项目软删(容错不 assert,不掩盖用例内断言)。"""
    for aid in aids:
        await client.delete(f"/api/v1/assets/{aid}", headers=_h(EVAN_ID))
        await client.delete(f"/api/v1/assets/{aid}", params={"hard": "true"},
                            headers=_h(EVAN_ID))
    for fid in folder_ids:
        await client.delete(f"/api/v1/folders/{fid}", headers=_h(EVAN_ID))
    for pid in project_ids:
        await client.delete(f"/api/v1/projects/{pid}", headers=_h(EVAN_ID))


# ─── §7.5 权限矩阵(合取守门)─────────────────────────────────────────────────
async def test_permission_matrix_and_gate_conjunction(client: AsyncClient) -> None:
    """无 flag 403 / 仅父 403 / **仅子无父 403**(合取防不一致 tuple 的核心性质,
    显式钉死)/ 父∧子(upload)200;flag 按子模块隔离:父∧子(upload)查 usage
    403、父∧子(usage)查 upload 403,而父∧子(usage)→ /admin/usage/stats 200
    (usage 侧非 admin 正例 —— 缺它则 require_usage_stats_viewer 误 check 错
    relation 也全绿,§7.5 明示);org admin 直通全量;未认证 401。
    403 文案与 require_system_admin 区分(§3.2,照 test_group_file_deleter 先例)。"""
    for label, stats, usage, upload in [
        ("无 flag", False, False, False),
        ("仅父 stats_viewer", True, False, False),
        ("仅子无父 upload_stats_viewer", False, False, True),  # 合取核心
    ]:
        gid, uid = await _flag_member(client, "pmtx", stats=stats, usage=usage, upload=upload)
        r = await client.get(URL, params=_q(), headers=_h(uid))
        assert r.status_code == 403, f"{label} 应 403: {r.status_code} {r.text}"
        assert r.json().get("detail") != _REQUIRE_SYSTEM_ADMIN_COPY, label
        await _delete_group(client, gid)

    # 父∧子(upload):upload 200;跨模块查 usage 403(子 flag 不互换)
    gid, uid = await _flag_member(client, "pmtx", stats=True, usage=False, upload=True)
    ok = await client.get(URL, params=_q(), headers=_h(uid))
    assert ok.status_code == 200, ok.text
    cross = await client.get(USAGE_URL, headers=_h(uid))
    assert cross.status_code == 403, cross.text
    assert cross.json().get("detail") != _REQUIRE_SYSTEM_ADMIN_COPY, cross.text
    await _delete_group(client, gid)

    # 父∧子(usage):usage 200(§7.5 核心正例);upload 403
    gid, uid = await _flag_member(client, "pmtx", stats=True, usage=True, upload=False)
    ok2 = await client.get(USAGE_URL, headers=_h(uid))
    assert ok2.status_code == 200, ok2.text
    deny = await client.get(URL, params=_q(), headers=_h(uid))
    assert deny.status_code == 403, deny.text
    await _delete_group(client, gid)

    # org admin(系统 admin)直通全量;未认证 401
    r_admin = await client.get(URL, params=_q(), headers=_h(EVAN_ID))
    assert r_admin.status_code == 200, r_admin.text
    r_anon = await client.get(URL, params=_q())
    assert r_anon.status_code == 401, r_anon.text


# ─── §7.6 零泄露:未受邀 sensitive 不计 / 受邀计入 ───────────────────────────
async def test_sensitive_folder_zero_leak_and_invited_counted(client: AsyncClient) -> None:
    """可见项目内**未受邀** sensitive folder 资产不计数(成员行不见、admin 正控
    可见 —— 排除「夹具没插对」假绿;sensitive 不走 public 直通);**受邀**后照常
    计入(与盲搜浏览面同口径,§7.6 正反两用例)。"""
    gid, uid = await _flag_member(client, "sens", stats=True, usage=False, upload=True)
    pv = await _create_project(client, grants=[
        {"kind": "user", "id": uid, "roles": ["viewer"]},
    ])
    fn = await _create_folder(client, pv["id"], _uniq("sens_n"))
    sf = await _create_folder(client, pv["id"], _uniq("sens_s"), is_sensitive=True)
    a_pub = await _insert_asset(fn["id"], "pub.jpg", content_type="image/png",
                                created_at=_dt(D_IN, 12))
    a_sec = await _insert_asset(sf["id"], "sec.mp4", content_type="video/mp4",
                                created_at=_dt(D_IN, 12, 1))
    try:
        r = await client.get(URL, params=_q(pids=[pv["id"]]), headers=_h(uid))
        assert r.status_code == 200, r.text
        row = _row(r.json(), pv["id"])
        # 普通夹计入,未受邀 sensitive 夹不计 → 恰 1 张图、无视频
        assert row is not None and row["life_images"] == 1 and row["life_videos"] == 0, row
        assert row["total"] == 1, row
        # admin 正控:两夹都计(证明资产确实在窗口内、夹具无假绿)
        ra = await client.get(URL, params=_q(pids=[pv["id"]]), headers=_h(EVAN_ID))
        row_a = _row(ra.json(), pv["id"])
        assert row_a is not None and row_a["total"] == 2 and row_a["life_videos"] == 1, row_a
    finally:
        await _cleanup(client, aids=[a_pub, a_sec], folder_ids=[fn["id"], sf["id"]],
                       project_ids=[pv["id"]])
        await _delete_group(client, gid)

    # 受邀 sensitive viewer → 计入(邀请制不变,计数面与浏览面同口径)
    gid2, uid2 = await _flag_member(client, "seni", stats=True, usage=False, upload=True)
    pv2 = await _create_project(client, grants=[
        {"kind": "user", "id": uid2, "roles": ["viewer"]},
    ])
    fn2 = await _create_folder(client, pv2["id"], _uniq("seni_n"))
    sf2 = await _create_folder(client, pv2["id"], _uniq("seni_s"), is_sensitive=True)
    await _invite_sensitive(client, sf2["id"], uid2)
    b_pub = await _insert_asset(fn2["id"], "pub2.png", content_type="image/png",
                                created_at=_dt(D_IN, 12))
    b_sec = await _insert_asset(sf2["id"], "sec2.mov", content_type="video/quicktime",
                                created_at=_dt(D_IN, 12, 1))
    try:
        r2 = await client.get(URL, params=_q(pids=[pv2["id"]]), headers=_h(uid2))
        assert r2.status_code == 200, r2.text
        row2 = _row(r2.json(), pv2["id"])
        assert row2 is not None and row2["life_images"] == 1 and row2["life_videos"] == 1, row2
        assert row2["total"] == 2, row2
    finally:
        await _revoke_invite(client, sf2["id"], uid2)
        await _cleanup(client, aids=[b_pub, b_sec], folder_ids=[fn2["id"], sf2["id"]],
                       project_ids=[pv2["id"]])
        await _delete_group(client, gid2)


# ─── §7.6 public 项目非敏感夹计入 + 宇宙零填充 ───────────────────────────────
async def test_public_project_counted_and_zero_fill_rows(client: AsyncClient) -> None:
    """public 项目非敏感 folder 计入(public 直通分支,盲搜同款);零资产 public
    项目 → 项目宇宙**零填充全 0 行**(rows 恒返回数组、非空集,勿造 sentinel,
    §4.4;public 分支同加项目活性,此处项目活跃)。"""
    gid, uid = await _flag_member(client, "pub", stats=True, usage=False, upload=True)
    pp = await _create_project(client)
    pq = await _create_project(client)
    # ProjectCreateIn 无 visibility 入参 → DB 直改(test_default_template 先例同款)
    await _set_project_db(pp["id"], visibility="public")
    await _set_project_db(pq["id"], visibility="public")
    fp = await _create_folder(client, pp["id"], _uniq("pub_f"))
    a = await _insert_asset(fp["id"], "pub3.jpg", content_type="image/png",
                            created_at=_dt(D_IN, 12))
    try:
        r = await client.get(URL, params=_q(pids=[pp["id"], pq["id"]]), headers=_h(uid))
        assert r.status_code == 200, r.text
        row_p = _row(r.json(), pp["id"])
        assert row_p is not None and row_p["life_images"] == 1 and row_p["total"] == 1, row_p
        row_q = _row(r.json(), pq["id"])
        assert row_q is not None, "public 项目属成员宇宙,零填充行必须在"
        assert row_q["total"] == 0 and row_q["life_images"] == 0, row_q
    finally:
        await _cleanup(client, aids=[a], folder_ids=[fp["id"]],
                       project_ids=[pp["id"], pq["id"]])
        await _delete_group(client, gid)


# ─── §7.6 死角修正:仅 folder 级 grant 补充行 + §7.4 成员视角静默丢弃 ─────────
async def test_folder_grant_supplement_rows_and_silent_drop(client: AsyncClient) -> None:
    """死角修正(§4.4):仅 folder 级 explicit grant、项目不可达 → 计数面含其资产,
    行「有数即现」(补充项目,不零填充);显式传入该 id 合法(200 计数,不视为
    越权);窗口内计数 0 → 不产生行(rows 可少于所选数)。仅 sensitive 受邀、项目
    不可达同走补充路径(防实现只测普通 grant 分支,§7.6)。
    §7.4:不可见(无 grant)/归档/软删 id 显式传入 → 静默丢弃不 403。"""
    gid, uid = await _flag_member(client, "supp", stats=True, usage=False, upload=True)
    px = await _create_project(client)  # 项目不可达,仅 folder 级 grant
    py = await _create_project(client)  # 项目不可达,仅 sensitive 受邀
    ph = await _create_project(client)  # 完全不可见(静默丢弃对照)
    pa = await _create_project(client)  # 将归档
    pd = await _create_project(client)  # 将软删
    fx = await _create_folder(client, px["id"], _uniq("supp_f"))
    sy = await _create_folder(client, py["id"], _uniq("supp_s"), is_sensitive=True)
    a1 = await _insert_asset(fx["id"], "f.jpg", content_type="image/png",
                             created_at=_dt(D_IN, 12))
    a2 = await _insert_asset(sy["id"], "s.mp4", content_type="video/mp4",
                             created_at=_dt(D_IN, 12, 1))
    await _grant_folder(client, fx["id"], uid)
    await _invite_sensitive(client, sy["id"], uid)
    await _set_project_db(pa["id"], is_archived=True)
    rd = await client.delete(f"/api/v1/projects/{pd['id']}", headers=_h(EVAN_ID))
    assert rd.status_code == 200, rd.text
    try:
        # 缺省:两补充项目行「有数即现」;完全不可见项目不出现
        r = await client.get(URL, params=_q(), headers=_h(uid))
        assert r.status_code == 200, r.text
        body = r.json()
        rx = _row(body, px["id"])
        assert rx is not None and rx["life_images"] == 1, rx
        ry = _row(body, py["id"])
        assert ry is not None and ry["life_videos"] == 1, ry
        assert _row(body, ph["id"]) is None, "零可达项目行不得出现"
        # 显式传入补充项目 id:合法计数(两层并集 ∩ 所选),rows 恰一行
        r2 = await client.get(URL, params=_q(pids=[px["id"]]), headers=_h(uid))
        assert r2.status_code == 200, r2.text  # 不 403:folder 可达口径合法(§4.4)
        assert [x["project_id"] for x in r2.json()["rows"]] == [str(px["id"])], r2.json()
        assert r2.json()["rows"][0]["life_images"] == 1, r2.json()
        # 显式传入 + 窗口内计数 0 → 补充项目不零填充,不产生行(rows==[])
        r3 = await client.get(URL, params=_q(f="2020-01-01", t="2020-01-02",
                                             pids=[px["id"]]), headers=_h(uid))
        assert r3.status_code == 200, r3.text
        assert r3.json()["rows"] == [], r3.json()
        # 成员视角静默丢弃(§7.4):不可见/归档/软删/未知 id 一把传入 → 200 不 403,
        # 全部丢弃 → rows==[](ph 不可达、pa/pd 非活性,均不进任何一层)
        r4 = await client.get(URL, params=_q(pids=[ph["id"], pa["id"], pd["id"],
                                                   str(uuid.uuid4())]), headers=_h(uid))
        assert r4.status_code == 200, r4.text
        assert r4.json()["rows"] == [], r4.json()
    finally:
        await _revoke_invite(client, sy["id"], uid)
        await _cleanup(client, aids=[a1, a2], folder_ids=[fx["id"], sy["id"]],
                       project_ids=[px["id"], py["id"], ph["id"], pa["id"]])  # pd 已删
        await _delete_group(client, gid)


# ─── §7.7 聚合自洽:summary == rows 逐列和 / 零填充行 / 排序 ──────────────────
async def test_summary_equals_row_sums_and_sorting(client: AsyncClient) -> None:
    """summary == rows 五列逐列和(后端为准);排序 total desc → project_name asc
    (并列按名字典序;ASCII 名避免 CJK collation 歧义);窗口零计数项目零填充
    全 0 行且排最后。"""
    spec = [  # (项目名, [(filename, content_type)])
        ("us-b", [("b1.png", "image/png"), ("b2.png", "image/png"), ("b3.png", "image/png")]),
        ("us-a", [("a1.png", "image/png"), ("a2.png", "image/png"), ("a3.png", "image/png"),
                  ("a4.mp4", "video/mp4"), ("a5.zip", "application/zip")]),
        ("us-c", [("c1.png", "image/png"), ("c2.png", "image/png"),
                  ("c1.mov", "video/quicktime"), ("c2.mov", "video/quicktime"),
                  ("c5.ts", None)]),
    ]
    made: tuple[list, list, list] = ([], [], [])  # aids, folder_ids, project_ids
    try:
        for pname, assets in spec:
            proj = await _create_project(client, name=pname)
            folder = await _create_folder(client, proj["id"], _uniq("agg_f"))
            for i, (fname, ctype) in enumerate(assets):
                made[0].append(await _insert_asset(folder["id"], fname, content_type=ctype,
                                                   created_at=_dt(D_IN, 12, i)))
            made[1].append(folder["id"])
            made[2].append(proj["id"])
        pq = await _create_project(client, name="us-z")  # 窗口零计数 → 零填充行
        made[2].append(pq["id"])
        pids = list(made[2])
        r = await client.get(URL, params=_q(pids=pids), headers=_h(EVAN_ID))
        assert r.status_code == 200, r.text
        body = r.json()
        rows = body["rows"]
        assert len(rows) == 4, rows  # 单选交集:恰四行
        # 排序:total desc(5,5,3,0)→ 并列按 project_name asc(us-a < us-c)
        assert [(x["project_name"], x["total"]) for x in rows] == [
            ("us-a", 5), ("us-c", 5), ("us-b", 3), (rows[3]["project_name"], 0),
        ], rows
        # 零填充行:窗口零计数项目全 0 且排最后
        assert rows[3]["project_id"] == str(pq["id"]) and rows[3]["total"] == 0, rows
        assert all(rows[3][k] == 0 for k in ("life_images", "voice_videos",
                                             "life_videos", "others")), rows
        # summary == rows 五列逐列和(§4.1:后端为准,前端 Table Summary 同显)
        cols = ("life_images", "voice_videos", "life_videos", "others", "total")
        for col in cols:
            assert body["summary"][col] == sum(x[col] for x in rows), (col, body["summary"], rows)
        # 抽对:四桶期望 8/0/3/2,total 13
        assert body["summary"] == {"life_images": 8, "voice_videos": 0, "life_videos": 3,
                                   "others": 2, "total": 13}, body["summary"]
    finally:
        await _cleanup(client, aids=made[0], folder_ids=made[1], project_ids=made[2])
