"""项目置顶(pin/unpin)集成测试,跑在 ms-api 容器里(`docker exec ms-api pytest`)。

唯一需求依据:`rushes-spec/material-storage/audit-drawer-project-pin-plan.md`
(§2.3 接口口径 / §2.4 列表改造 / §4.1 用例清单 7 组)+
`docs/qdev/2026-10-28-audit-drawer-project-pin.md` B1-B3。

契约要点(实现由并行任务交付,冲突以需求文档为准):
  - POST /api/v1/projects/{id}/pin → 204 幂等(pg insert on_conflict_do_nothing);
    DELETE /api/v1/projects/{id}/pin → 204 幂等(删不存在行=目标态达成)
  - 守门(两端点同口径):项目不存在 / 已逻辑删除(deleted_at 非空,对所有人含
    system admin —— 与详情端点 F6.4 深隐藏对齐,防 tuple 残留把「已删除」变可探测)/
    对当前用户不可见 → 404(统一 404 反探测,可见性判定=is_system_admin 直过,
    否则 OpenFGA can_view 或 visibility=public);已归档(is_archived)放行
  - GET /projects 两分支排序改 (exists pin).desc(), created_at.desc();
    ProjectOut 加 is_pinned(用户私有偏好),列表与详情 GET /projects/{id} 两处回填
  - 不记 audit_events(D3,用户私有 UI 偏好)

预期前置(同 test_project_soft_delete.py):
  1. seed_demo_data.py 已跑过(Evan = 真 user + org admin / system admin;
     outsider = fake 零权限)
  2. OpenFGA store / model 已 push
  3. env=dev(允许 X-User-Id header 模拟身份)

清理惯例(同 test_project_soft_delete.py):自建项目在 finally 里 API 逻辑删除
(已删除 404 视为成功);public/归档/created_at 经 DB 直改(无对应 API,照
test_boundary_ext / test_default_template 惯例);孤儿 pin 行无害保留(方案
§2.2.3,不主动清扫);用户无删除 API,靠唯一 marker 圈定,不清理(沿用现状)。
"""

from __future__ import annotations

import subprocess
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import create_app

# seed 写死的真 user / fake outsider(同 test_project_soft_delete.py)
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


def _project_code() -> str:
    """项目 code 唯一(projects_code_key);pattern 限 ^[a-z0-9][a-z0-9\\-]*$。"""
    return f"pin-{uuid.uuid4().hex[:12]}"


# ─── 测试内现建辅助(用户/项目一律测试内现建,照 test_project_soft_delete.py)──
async def _create_user(
    client: AsyncClient,
    prefix: str = "pp_user",
    *,
    name: str | None = None,
) -> str:
    """现建 active 本地用户 → users.id(照 test_project_soft_delete._create_user)。"""
    uname = _uniq(prefix)
    r = await client.post(
        "/api/v1/admin/directory/users",
        json={"username": uname, "name": name or f"PP {prefix}"},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text
    return r.json()["id"]


async def _create_project(
    client: AsyncClient,
    *,
    admin_uid: str = EVAN_ID,
    name: str | None = None,
    grants: list[dict] | None = None,
) -> dict:
    """EVAN(系统 admin)现建项目 → ProjectOut dict(默认 private;grants 走
    initial_grants,照 test_project_soft_delete._create_project)。"""
    body: dict = {
        "code": _project_code(),
        "name": name or _uniq("置顶项目"),
        "minio_bucket": "ms-dev",
        "admin_user_id": admin_uid,
    }
    if grants:
        body["initial_grants"] = grants
    r = await client.post("/api/v1/projects", json=body, headers=_h(EVAN_ID))
    assert r.status_code == 201, r.text
    return r.json()


def _grant_viewer(uid: str) -> list[dict]:
    """构造 initial_grants 里「该 user 授 viewer」一条(private 项目可见性来源)。"""
    return [{"kind": "user", "id": uid, "roles": ["viewer"]}]


async def _pin(client: AsyncClient, uid: str, pid: str):
    return await client.post(f"/api/v1/projects/{pid}/pin", headers=_h(uid))


async def _unpin(client: AsyncClient, uid: str, pid: str):
    return await client.delete(f"/api/v1/projects/{pid}/pin", headers=_h(uid))


async def _soft_delete(client: AsyncClient, pid: str) -> None:
    """收尾专用:把仍活跃的自建项目逻辑删除,防挤占 GET /projects 第一页。

    已删除(404)视为成功;失败吞掉 + warning,不掩盖原断言
    (照 test_project_soft_delete._soft_delete 惯例)。"""
    import warnings

    try:
        r = await client.delete(f"/api/v1/projects/{pid}", headers=_h(EVAN_ID))
        assert r.status_code in (200, 404), r.text
    except Exception as e:
        warnings.warn(f"soft delete project {pid} failed: {e}; 残留活跃项目", stacklevel=2)


async def _list_body(client: AsyncClient, actor_id: str) -> list[dict]:
    """GET /api/v1/projects 第一页(limit=200)完整 ProjectOut 列表。"""
    r = await client.get("/api/v1/projects", params={"limit": 200}, headers=_h(actor_id))
    assert r.status_code == 200, r.text
    return list(r.json())


async def _list_ids(client: AsyncClient, actor_id: str) -> list[str]:
    return [p["id"] for p in await _list_body(client, actor_id)]


def _relative_order(ids: list[str], wanted: set[str]) -> list[str]:
    """全量列表里抽出 wanted 集合的相对顺序(seed 项目穿插不影响断言)。"""
    return [pid for pid in ids if pid in wanted]


def _proj_by_id(body: list[dict], pid: str) -> dict:
    hits = [p for p in body if p["id"] == pid]
    assert len(hits) == 1, f"项目 {pid} 应恰在列表出现一次: {len(hits)}"
    return hits[0]


# ─── DB 直读/直改辅助(public/归档/created_at 无 API,照既有直改惯例)─────────
async def _pin_user_ids(pid: str) -> list[str]:
    """DB 直读 user_project_pins:该项目现有置顶的 user_id 列表(幂等/残留断言)。"""
    from sqlalchemy import select

    from app.db.session import get_sessionmaker
    from app.db.tables import UserProjectPin

    async with get_sessionmaker()() as db:
        rows = (
            (
                await db.execute(
                    select(UserProjectPin).where(UserProjectPin.project_id == uuid.UUID(pid)),
                )
            )
            .scalars()
            .all()
        )
        return [str(r.user_id) for r in rows]


async def _update_project_row(pid: str, **values) -> None:
    """DB 直改 projects 行(public/归档/created_at 均无对应 API,照
    test_boundary_ext._set_visibility / test_default_template._set_archived 惯例)。"""
    from sqlalchemy import update

    from app.db.session import get_sessionmaker
    from app.db.tables import Project

    async with get_sessionmaker()() as db:
        await db.execute(update(Project).where(Project.id == uuid.UUID(pid)).values(**values))
        await db.commit()


def _past(hours: int) -> datetime:
    """过去某时刻(时区感知;排序用 DB 直改 created_at 拉开间隔,防 now() 并列)。"""
    return datetime.now(timezone.utc) - timedelta(hours=hours)


# ─── §4.1 组1:pin 普通用户对可见项目 204;重复 pin 幂等 204 且表内仅一行 ─────
@pytest.mark.asyncio
@pytest.mark.parametrize(
    "scene",
    [
        pytest.param("private_granted", id="private_授权可见"),
        pytest.param("public", id="public_可见"),
    ],
)
async def test_pin_visible_project_204_idempotent_single_row(
    client: AsyncClient,
    scene: str,
) -> None:
    """普通用户对可见项目 pin → 204;重复 pin 仍 204(幂等),且 user_project_pins
    表内仅一行(复合主键兜底)。可见性两来源表驱动:private+viewer 授权 /
    public(DB 直改,无 API;每样本独立 actor + 独立项目)。"""
    actor = await _create_user(client, "pp_pin", name="置顶用户")
    grants = _grant_viewer(actor) if scene == "private_granted" else None
    p = await _create_project(client, admin_uid=EVAN_ID, grants=grants)
    pid = p["id"]
    if scene == "public":
        await _update_project_row(pid, visibility="public")
    try:
        # 前置:actor 确实可见(private 授权 / public)
        assert pid in await _list_ids(client, actor), f"scene={scene} 前置可见失败"

        r = await _pin(client, actor, pid)
        assert r.status_code == 204, r.text

        # 重复 pin 幂等:仍 204,表内仅一行且归属正确
        r2 = await _pin(client, actor, pid)
        assert r2.status_code == 204, r2.text
        assert await _pin_user_ids(pid) == [actor], "重复 pin 后表内必须恰一行"
    finally:
        await _soft_delete(client, pid)


# ─── §4.1 组2:unpin 已置顶 204 / 未置顶 204 / 表内无残留 ────────────────────
@pytest.mark.asyncio
async def test_unpin_idempotent_no_residue(client: AsyncClient) -> None:
    """unpin 三个形态:已置顶 → 204 行删;未置顶(含从未 pin 过)→ 204 幂等;
    全程无残留行;unpin 后可重新 pin(目标态语义)。"""
    actor = await _create_user(client, "pp_unpin", name="取消置顶用户")
    p = await _create_project(
        client,
        admin_uid=EVAN_ID,
        grants=_grant_viewer(actor),
    )
    pid = p["id"]
    try:
        # 未置顶先 unpin → 204(删不存在行=目标态达成)
        r0 = await _unpin(client, actor, pid)
        assert r0.status_code == 204, r0.text
        assert await _pin_user_ids(pid) == [], "未 pin 过不该有行"

        # pin → 204;unpin → 204 且行删
        r1 = await _pin(client, actor, pid)
        assert r1.status_code == 204, r1.text
        assert await _pin_user_ids(pid) == [actor]
        r2 = await _unpin(client, actor, pid)
        assert r2.status_code == 204, r2.text

        # 无残留;再 unpin 仍 204(幂等);unpin 后可重新 pin
        assert await _pin_user_ids(pid) == [], "unpin 后表内无残留"
        r3 = await _unpin(client, actor, pid)
        assert r3.status_code == 204, r3.text
        r4 = await _pin(client, actor, pid)
        assert r4.status_code == 204, r4.text
        assert await _pin_user_ids(pid) == [actor]
    finally:
        await _soft_delete(client, pid)


# ─── §4.1 组3:守门 —— 不可见 private / 不存在 id → 404(pin/unpin 同口径)────
@pytest.mark.asyncio
@pytest.mark.parametrize(
    "scene",
    [
        pytest.param("invisible_private", id="private_未授权不可见"),
        pytest.param("nonexistent_id", id="不存在id"),
    ],
)
async def test_pin_gate_invisible_and_nonexistent_404(
    client: AsyncClient,
    scene: str,
) -> None:
    """守门 404 两种形态(每样本独立 actor + 独立项目):不可见 private 项目
    pin/unpin 均 404(反探测,统一 404 而非详情端点的 403);不存在 id 同 404。"""
    actor = await _create_user(client, "pp_gate", name="守门用户")
    pid = ""
    if scene == "invisible_private":
        # 默认 private、不给 actor 任何授权 → 不可见
        pid = (await _create_project(client, admin_uid=EVAN_ID))["id"]
        assert pid not in await _list_ids(client, actor), "前置:actor 不可见"
    else:
        pid = str(uuid.uuid4())
    try:
        r = await _pin(client, actor, pid)
        assert r.status_code == 404, f"scene={scene}: {r.text}"
        r2 = await _unpin(client, actor, pid)
        assert r2.status_code == 404, f"scene={scene}: {r2.text}"
    finally:
        if pid and scene == "invisible_private":
            await _soft_delete(client, pid)


# ─── §4.1 组3:守门 —— 已逻辑删除对所有人 404(含 public / 原成员 / system admin)
@pytest.mark.asyncio
async def test_pin_soft_deleted_project_404_all_actors(client: AsyncClient) -> None:
    """已删除(deleted_at 非空)pin/unpin 均 404,对所有人一致(§2.3.3 深隐藏,
    与详情端点 F6.4 对齐):public 项目删除后零权限用户 404;原成员(FGA tuple
    残留、can_view 仍真)同样 404 —— 删除判定必须压过可见性判定;且删除前已置的
    pin 行保留(§2.2.3 孤儿 pin 无害,unpin 走守门 404 无法自清属设计内);system
    admin 对已删除项目同样 404。"""
    member = await _create_user(client, "pp_delm", name="删除前成员")
    pub_pid = (await _create_project(client, admin_uid=EVAN_ID))["id"]
    await _update_project_row(pub_pid, visibility="public")
    mem_pid = (
        await _create_project(
            client,
            admin_uid=EVAN_ID,
            grants=_grant_viewer(member),
        )
    )["id"]
    adm_pid = (await _create_project(client, admin_uid=EVAN_ID))["id"]

    # 原成员场景:删除前先 pin 成功(行存在),删除后 unpin 被守门拦下
    r_pre = await _pin(client, member, mem_pid)
    assert r_pre.status_code == 204, r_pre.text

    for pid in (pub_pid, mem_pid, adm_pid):
        rd = await client.delete(f"/api/v1/projects/{pid}", headers=_h(EVAN_ID))
        assert rd.status_code == 200, rd.text

    # 此后三个项目均已深隐藏,断言失败也无需项目收尾
    # public 已删:零权限 outsider pin/unpin 404
    assert (await _pin(client, OUTSIDER_ID, pub_pid)).status_code == 404
    assert (await _unpin(client, OUTSIDER_ID, pub_pid)).status_code == 404

    # 原成员已删:pin 404(can_view tuple 残留也不放行)、unpin 404 且行残留
    assert (await _pin(client, member, mem_pid)).status_code == 404
    assert (await _unpin(client, member, mem_pid)).status_code == 404
    assert await _pin_user_ids(mem_pid) == [member], (
        "已删项目的 pin 行应无害保留(§2.2.3),不被 unpin 清掉也不报 5xx"
    )

    # system admin 已删:pin/unpin 404(深隐藏对 admin 一视同仁)
    assert (await _pin(client, EVAN_ID, adm_pid)).status_code == 404
    assert (await _unpin(client, EVAN_ID, adm_pid)).status_code == 404


# ─── §4.1 组3:守门 —— 已归档放行 204(归档无 API,DB 直改 is_archived)────────
@pytest.mark.asyncio
async def test_pin_archived_project_allowed_204(client: AsyncClient) -> None:
    """已归档项目放行(§2.3.3 与已删除的差别处理):pin/unpin 均 204,pin 行
    正常增删(§2.2.3:恢复/取消归档后置顶自动重新生效的正向语义)。归档态经
    DB 直改 is_archived(照 test_default_template.py:246 先例)。"""
    actor = await _create_user(client, "pp_arch", name="归档置顶用户")
    p = await _create_project(
        client,
        admin_uid=EVAN_ID,
        grants=_grant_viewer(actor),
    )
    pid = p["id"]
    await _update_project_row(pid, is_archived=True)
    try:
        r = await _pin(client, actor, pid)
        assert r.status_code == 204, r.text
        assert await _pin_user_ids(pid) == [actor]

        r2 = await _unpin(client, actor, pid)
        assert r2.status_code == 204, r2.text
        assert await _pin_user_ids(pid) == [], "归档项目 unpin 同样应正常删行"
    finally:
        await _soft_delete(client, pid)  # 归档不拦删除,照常深隐藏收尾


# ─── §4.1 组3:system admin 分支 —— 非成员 private 项目 pin/unpin 直过 204 ────
@pytest.mark.asyncio
async def test_pin_system_admin_bypass_on_private_project(client: AsyncClient) -> None:
    """system admin 对非成员、非 public 的 private 项目 pin/unpin 均 204
    (§2.3.3 is_system_admin 直过口径);对照:同项目零权限 outsider 404,
    证明放行来自 system admin 直过而非项目可见。"""
    owner = await _create_user(client, "pp_own", name="项目归属管理员")
    p = await _create_project(client, admin_uid=owner)  # private,EVAN 无 FGA tuple
    pid = p["id"]
    try:
        # 对照:outsider 不可见 → 404(项目确为 private 不可见)
        assert (await _pin(client, OUTSIDER_ID, pid)).status_code == 404

        # system admin 直过
        r = await _pin(client, EVAN_ID, pid)
        assert r.status_code == 204, r.text
        assert await _pin_user_ids(pid) == [EVAN_ID]
        r2 = await _unpin(client, EVAN_ID, pid)
        assert r2.status_code == 204, r2.text
        assert await _pin_user_ids(pid) == [], "system admin unpin 后无残留"
    finally:
        await _soft_delete(client, pid)


# ─── §4.1 组4:排序 —— 置顶恒最前 / 多置顶按 created_at desc / 全置顶=原序 ────
@pytest.mark.asyncio
async def test_pin_ordering_pinned_first_created_desc_and_all_pinned(
    client: AsyncClient,
) -> None:
    """GET /projects 排序(§2.4.1):置顶恒在最前;多置顶之间按 created_at desc;
    全置顶 = 原序(created_at desc);未置顶部分保持 created_at desc。created_at
    是 server_default now() 可并列 —— 测试内 DB 直改拉开间隔(防偶发不稳定);
    并断言他人置顶不影响自己(用户私有)与 admin 分支排序同步改造。"""
    actor = await _create_user(client, "pp_sort", name="排序用户")
    p_old = (
        await _create_project(
            client,
            name=_uniq("排序旧"),
            grants=_grant_viewer(actor),
        )
    )["id"]
    p_mid = (
        await _create_project(
            client,
            name=_uniq("排序中"),
            grants=_grant_viewer(actor),
        )
    )["id"]
    p_new = (await _create_project(client, name=_uniq("排序新"), grants=_grant_viewer(actor)))["id"]
    mine = {p_old, p_mid, p_new}
    # DB 直改 created_at 拉开间隔:old < mid < new,自然序 = [new, mid, old]
    await _update_project_row(p_old, created_at=_past(3))
    await _update_project_row(p_mid, created_at=_past(2))
    await _update_project_row(p_new, created_at=_past(1))
    try:
        # 未置顶:原序 created_at desc
        assert _relative_order(await _list_ids(client, actor), mine) == [p_new, p_mid, p_old]

        # 置顶最旧的 → 置顶恒最前,未置顶保持 created_at desc
        r = await _pin(client, actor, p_old)
        assert r.status_code == 204, r.text
        assert _relative_order(await _list_ids(client, actor), mine) == [p_old, p_new, p_mid]

        # 再置顶最新的 → 多置顶之间也按 created_at desc
        r2 = await _pin(client, actor, p_new)
        assert r2.status_code == 204, r2.text
        assert _relative_order(await _list_ids(client, actor), mine) == [p_new, p_old, p_mid]

        # 全置顶 = 原序(created_at desc)
        r3 = await _pin(client, actor, p_mid)
        assert r3.status_code == 204, r3.text
        assert _relative_order(await _list_ids(client, actor), mine) == [p_new, p_mid, p_old]

        # 部分取消(取消最新的)→ 剩余置顶仍恒最前
        r4 = await _unpin(client, actor, p_new)
        assert r4.status_code == 204, r4.text
        assert _relative_order(await _list_ids(client, actor), mine) == [p_mid, p_old, p_new]

        # 他人置顶不影响自己的顺序(用户私有偏好独立):EVAN(admin 分支)未置顶
        assert _relative_order(await _list_ids(client, EVAN_ID), mine) == [p_new, p_mid, p_old]
    finally:
        for pid in (p_old, p_mid, p_new):
            await _soft_delete(client, pid)


# ─── §4.1 组5:is_pinned 回填 —— 用户隔离(自己 true 他人 false)+ 两端点一致 ──
@pytest.mark.asyncio
async def test_is_pinned_user_isolation_list_and_detail(client: AsyncClient) -> None:
    """is_pinned 回填(§2.4.2):自己置顶的 true、他人置顶的 false(用户私有);
    列表 GET /projects 与详情 GET /projects/{id} 两处回填一致;未置顶缺省 false。"""
    ua = await _create_user(client, "pp_iso_a", name="隔离甲")
    ub = await _create_user(client, "pp_iso_b", name="隔离乙")
    grants = [
        {"kind": "user", "id": ua, "roles": ["viewer"]},
        {"kind": "user", "id": ub, "roles": ["viewer"]},
    ]
    p = (await _create_project(client, admin_uid=EVAN_ID, grants=grants))["id"]
    q = (await _create_project(client, admin_uid=EVAN_ID, grants=grants))["id"]
    try:
        # 未置顶:双方列表均 false(缺省)
        body_a = _proj_by_id(await _list_body(client, ua), p)
        assert body_a["is_pinned"] is False, body_a

        # 甲 pin p:甲 true / 乙 false(用户隔离);q 未置顶恒 false
        r = await _pin(client, ua, p)
        assert r.status_code == 204, r.text
        assert _proj_by_id(await _list_body(client, ua), p)["is_pinned"] is True
        assert _proj_by_id(await _list_body(client, ub), p)["is_pinned"] is False
        assert _proj_by_id(await _list_body(client, ua), q)["is_pinned"] is False

        # 乙 pin q:互不串扰
        r2 = await _pin(client, ub, q)
        assert r2.status_code == 204, r2.text
        assert _proj_by_id(await _list_body(client, ua), q)["is_pinned"] is False
        assert _proj_by_id(await _list_body(client, ub), q)["is_pinned"] is True

        # 详情端点与列表一致(两处回填)
        assert (await client.get(f"/api/v1/projects/{p}", headers=_h(ua))).json()["is_pinned"] is True
        assert (await client.get(f"/api/v1/projects/{p}", headers=_h(ub))).json()["is_pinned"] is False
        assert (await client.get(f"/api/v1/projects/{q}", headers=_h(ua))).json()["is_pinned"] is False
        assert (await client.get(f"/api/v1/projects/{q}", headers=_h(ub))).json()["is_pinned"] is True

        # 甲取消后双方均回 false
        r3 = await _unpin(client, ua, p)
        assert r3.status_code == 204, r3.text
        assert _proj_by_id(await _list_body(client, ua), p)["is_pinned"] is False
        assert (await client.get(f"/api/v1/projects/{p}", headers=_h(ua))).json()["is_pinned"] is False
    finally:
        for pid in (p, q):
            await _soft_delete(client, pid)


# ─── §4.1 组5:is_pinned 回填 —— system admin 走 admin 分支同样正确 ───────────
@pytest.mark.asyncio
async def test_is_pinned_system_admin_branch_backfill(client: AsyncClient) -> None:
    """admin 分支(system admin 见全部 active)的回填同样正确:EVAN 置顶自己
    非成员的 private 项目 → EVAN 列表/详情均 true;项目 admin(成员分支)仍 false
    (用户隔离);取消后双方回 false。"""
    owner = await _create_user(client, "pp_bf_own", name="回填项目管理员")
    p = (await _create_project(client, admin_uid=owner))["id"]
    try:
        # 前置:双方均可见(EVAN 走 admin 分支;owner 走 FGA 成员分支),均 false
        assert _proj_by_id(await _list_body(client, EVAN_ID), p)["is_pinned"] is False
        assert _proj_by_id(await _list_body(client, owner), p)["is_pinned"] is False

        r = await _pin(client, EVAN_ID, p)
        assert r.status_code == 204, r.text
        # EVAN(admin 分支)true;owner(成员分支)false
        assert _proj_by_id(await _list_body(client, EVAN_ID), p)["is_pinned"] is True
        assert _proj_by_id(await _list_body(client, owner), p)["is_pinned"] is False
        # 详情端点同口径
        assert (await client.get(f"/api/v1/projects/{p}", headers=_h(EVAN_ID))).json()["is_pinned"] is True
        assert (await client.get(f"/api/v1/projects/{p}", headers=_h(owner))).json()["is_pinned"] is False

        # 取消 → 双方回 false
        r2 = await _unpin(client, EVAN_ID, p)
        assert r2.status_code == 204, r2.text
        assert _proj_by_id(await _list_body(client, EVAN_ID), p)["is_pinned"] is False
        assert _proj_by_id(await _list_body(client, owner), p)["is_pinned"] is False
    finally:
        await _soft_delete(client, p)


# ─── §4.1 组6:迁移冒烟 upgrade head → downgrade -1 → upgrade head ────────────
@pytest.mark.alembic
def test_migration_user_project_pins_upgrade_downgrade() -> None:
    """alembic 冒烟(2026_10_28_0019_user_project_pins:新建 user_project_pins
    复合主键表;存量数据迁移=无,downgrade drop_table 即弃全部置顶偏好)。

    独立可跳过:需在有 alembic.ini 的 material-storage/api 目录内运行(容器内
    WORKDIR 即该目录),且 alembic CLI 可用、DB 可连;不满足则 skip。
    末尾必回 head,顺序执行下不影响同 session 其他用例(未假设 xdist 并行)。
    注:pytest.mark.alembic 为自定义标记(pyproject 未注册,仅告警),便于
    `-m "not alembic"` 圈选跳过。(照 test_project_soft_delete.py:640 三段式)
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
            ["alembic", *args],
            cwd=str(api_dir),
            capture_output=True,
            text=True,
        )

    up1 = _run("upgrade", "head")
    assert up1.returncode == 0, f"upgrade head 失败: {up1.stderr or up1.stdout}"
    down = _run("downgrade", "-1")
    assert down.returncode == 0, f"downgrade -1 失败: {down.stderr or down.stdout}"
    up2 = _run("upgrade", "head")
    assert up2.returncode == 0, f"回 upgrade head 失败: {up2.stderr or up2.stdout}"
