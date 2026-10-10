"""管理后台优化 — 补充边界测试(专职测试阶段新增,不修改既有 T1-T17)。

跑在 feat-ms-api 容器里(`docker exec -w /app feat-ms-api python -m pytest
tests/test_boundary_ext.py -q`)。
唯一需求依据:docs/qdev/2026-10-10-admin-console-opt.md(F1-F7、接口 §1-§11、
决策 D1-D11)+ 既有测试(T1-T17)未覆盖的边界。

覆盖清单(既有用例未覆盖的边界):
  B1  GET /admin/directory/users limit=0 / limit=201 / limit<0 → 422;
      offset 超界 → 200 且 items=[] / total 不变;GET /projects/deleted 同款边界
  B2  PATCH /admin/directory/users/{id} 空 body(全缺省)→ 200 且不改任何字段
  B3  PATCH name="" → 422;name 全空格 → 契约「提供则须非空」应 422(边界)
  B4  email 非法格式:POST 建用户 / PATCH 均应 422 且不落库
  B5  建用户 username 重复 → 409,且 group_ids 不产生任何副作用(原子)
  B6  建用户 group_ids 重复 uuid → 去重(成员落库恰好一次、审计恰好一条)
  B7  PATCH group_ids=[] → 清空全部组(diff 全 removed);重复提交幂等
  B8  PATCH group_ids>50(51 个 ghost id)→ 422 invalid_group_ids 且不变更
  B9  GET /admin/directory/users/{ghost} → 404 user_not_found
  B10 删除项目后分享链接/申请链接行为(D10:全不动 → 解析请求不得 500,
      且按「行为不变」应照常 200;restore 后同样 200)
  B11 非 admin(普通成员 bob / 新建普通用户)GET /projects/deleted → 403
      (T13 已覆盖 fake outsider,这里补真实普通用户)
  B12 admin 对 public / stealth 项目删除行为一致(主列表 public 兜底分支同样
      过滤已删;deleted 列表均可见;restore 恢复)

前置(同 test_directory_users_ext.py / test_project_soft_delete.py):
  1. seed_demo_data.py 已跑(Evan=system admin;bob=普通 member;outsider=零权限)
  2. OpenFGA store/model 已 push(含 project_deleter)
  3. env=dev(X-User-Id 模拟身份)

清理惯例(沿用现状):组在 finally 里删;用户无删除 API,靠唯一 marker 圈定
断言;自建项目收尾一律逻辑删除(已删除 404 吞掉),不留活跃项目挤占列表;
B10 的 folder/asset 随项目隐藏,不做物理清理(深隐藏不可见)。
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import create_app

# seed 写死的真 user / fake outsider(同既有测试)
EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"
BOB_ID = "00000000-0000-0000-0000-000000000002"        # 普通 member(非系统 admin)
OUTSIDER_ID = "00000000-0000-0000-0000-0000000000aa"

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


def _project_code() -> str:
    return f"bx-{uuid.uuid4().hex[:12]}"


# ─── 测试内现建辅助(照既有惯例)───────────────────────────────────────────────
async def _create_group(client: AsyncClient, prefix: str = "bx_grp") -> dict:
    r = await client.post(
        "/api/v1/admin/directory/groups",
        json={"name": _uniq(prefix), "description": "boundary ext 测试组"},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text
    return r.json()


async def _create_user(
    client: AsyncClient,
    prefix: str = "bx_user",
    *,
    name: str | None = None,
    email: str | None = None,
    group_ids: list[str] | None = None,
) -> dict:
    body: dict = {"username": _uniq(prefix), "name": name or f"BX {prefix}"}
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
    r = await client.get(f"/api/v1/admin/directory/users/{uid}", headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    return r.json()


async def _group_members(client: AsyncClient, gid: str) -> list[dict]:
    r = await client.get(
        f"/api/v1/admin/directory/groups/{gid}/members", headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    return r.json()


async def _user_audit_details(
    client: AsyncClient, event_type: str, uid: str,
) -> list[dict]:
    """按 event_type + actor(EVAN)拉 audit,返回 details.user_id == uid 的条目。"""
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


async def _group_audit_details(
    client: AsyncClient, event_type: str, gid: str,
) -> list[dict]:
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


async def _create_project(
    client: AsyncClient, *, admin_uid: str = EVAN_ID, name: str | None = None,
) -> dict:
    body: dict = {
        "code": _project_code(),
        "name": name or _uniq("bx边界项目"),
        "minio_bucket": "ms-dev",
        "admin_user_id": admin_uid,
    }
    r = await client.post("/api/v1/projects", json=body, headers=_h(EVAN_ID))
    assert r.status_code == 201, r.text
    return r.json()


async def _soft_delete(client: AsyncClient, pid: str) -> None:
    """收尾:把仍活跃的自建项目逻辑删除(已删除 404 视为成功,吞掉)。"""
    import warnings

    try:
        r = await client.delete(f"/api/v1/projects/{pid}", headers=_h(EVAN_ID))
        assert r.status_code in (200, 404), r.text
    except Exception as e:
        warnings.warn(f"soft delete project {pid} failed: {e}; 残留活跃项目", stacklevel=2)


async def _main_list_ids(client: AsyncClient, actor_id: str) -> list[str]:
    r = await client.get("/api/v1/projects", params={"limit": 200}, headers=_h(actor_id))
    assert r.status_code == 200, r.text
    return [p["id"] for p in r.json()]


async def _set_visibility(pid: str, visibility: str) -> None:
    """DB 直改 visibility(public/stealth 无法经 API 创建;照 archived 直改惯例)。"""
    from sqlalchemy import update

    from app.db.session import get_sessionmaker
    from app.db.tables import Project

    async with get_sessionmaker()() as db:
        await db.execute(
            update(Project)
            .where(Project.id == uuid.UUID(pid))
            .values(visibility=visibility)
        )
        await db.commit()


async def _insert_asset(folder_id: str, filename: str) -> str:
    """直插 asset 行(照 test_trash_and_purge 惯例;presign PUT 容器内不通)。"""
    from app.db.session import get_sessionmaker
    from app.db.tables import Asset

    aid = uuid.uuid4()
    async with get_sessionmaker()() as db:
        db.add(Asset(
            id=aid,
            folder_id=uuid.UUID(folder_id),
            filename=filename,
            minio_bucket="ms-dev",
            minio_key=f"bx-test/{filename}",
            size_bytes=11,
            content_type="text/plain",
            uploader_id=uuid.UUID(EVAN_ID),
            deleted_at=None,
            tags={},
        ))
        await db.commit()
    return str(aid)


# ─── B1:users 列表 limit 边界 + offset 超界;deleted 列表同款 ─────────────────
@pytest.mark.asyncio
async def test_users_list_limit_bounds_and_offset_overrun(client: AsyncClient) -> None:
    """B1:limit=0 / 201 / 负数 → 422(Pydantic ge=1/le=200);limit=200 → 200;
    offset 超界 → 200、items=[]、total 与 offset=0 一致(D4 结构)。
    GET /projects/deleted 的 limit/offset 同款边界(契约 §7 同为 ge=1/le=200)。"""
    marker = _uniq("bxlimit")
    u1 = await _create_user(client, "bx_lmt", name=f"{marker} 甲")
    u2 = await _create_user(client, "bx_lmt", name=f"{marker} 乙")

    for bad in ("0", "201", "-1"):
        r = await client.get(
            "/api/v1/admin/directory/users",
            params={"q": marker, "limit": bad}, headers=_h(EVAN_ID),
        )
        assert r.status_code == 422, f"limit={bad} 应 422: {r.text}"

    full = await client.get(
        "/api/v1/admin/directory/users",
        params={"q": marker, "limit": 200}, headers=_h(EVAN_ID),
    )
    assert full.status_code == 200, full.text
    body = full.json()
    assert body["total"] == 2 and {u["id"] for u in body["items"]} == {
        u1["id"], u2["id"],
    }, body

    over = await client.get(
        "/api/v1/admin/directory/users",
        params={"q": marker, "limit": 200, "offset": 999_999}, headers=_h(EVAN_ID),
    )
    assert over.status_code == 200, over.text
    ob = over.json()
    assert ob["items"] == [] and ob["total"] == 2 and ob["offset"] == 999_999, ob

    # deleted 列表边界(EVAN = org admin → require_project_deleter 通过)
    for bad in (0, 201):
        rd = await client.get(
            "/api/v1/projects/deleted",
            params={"limit": bad}, headers=_h(EVAN_ID),
        )
        assert rd.status_code == 422, f"deleted limit={bad} 应 422: {rd.text}"
    rd_ok = await client.get(
        "/api/v1/projects/deleted",
        params={"limit": 200, "offset": 999_999}, headers=_h(EVAN_ID),
    )
    assert rd_ok.status_code == 200, rd_ok.text
    assert rd_ok.json()["items"] == [], rd_ok.json()


# ─── B2:PATCH 空 body(全缺省)= 不改 ─────────────────────────────────────────
@pytest.mark.asyncio
async def test_patch_user_empty_body_changes_nothing(client: AsyncClient) -> None:
    """B2(契约 §3「全部可选键,缺省=不改」):PATCH {} → 200,name/email/
    所属组全部保持原值,不得把 email 清空 / 组清空。"""
    g = await _create_group(client, "bx_empty")
    try:
        email = f"{_uniq('bx_empty')}@example.com"
        u = await _create_user(
            client, "bx_empty", name="B2 原名", email=email, group_ids=[g["id"]],
        )
        uid = u["id"]

        r = await client.patch(
            f"/api/v1/admin/directory/users/{uid}", json={}, headers=_h(EVAN_ID),
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["name"] == "B2 原名", body
        assert body["email"] == email, body

        detail = await _get_user_detail(client, uid)
        assert detail["name"] == "B2 原名" and detail["email"] == email, detail
        assert detail["group_ids"] == [g["id"]], detail
        members = await _group_members(client, g["id"])
        assert [m["user_id"] for m in members] == [uid], members
    finally:
        await _delete_group(client, g["id"])


# ─── B3:PATCH name 空串 / 全空格 ──────────────────────────────────────────────
@pytest.mark.asyncio
async def test_patch_user_name_blank_and_whitespace_422(client: AsyncClient) -> None:
    """B3(契约 §3「name 提供则须非空」):name="" → 422;name 全空格语义上
    为空 → 应 422(若实现放行则为本用例失败,上报评审)。失败后 name 不变。"""
    u = await _create_user(client, "bx_blank", name="B3 原名")
    uid = u["id"]

    r = await client.patch(
        f"/api/v1/admin/directory/users/{uid}", json={"name": ""}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 422, f"name 空串应 422: {r.text}"

    r2 = await client.patch(
        f"/api/v1/admin/directory/users/{uid}", json={"name": "   "}, headers=_h(EVAN_ID),
    )
    assert r2.status_code == 422, (
        f"name 全空格应按「非空」校验 422(实际 {r2.status_code}): {r2.text}"
    )

    assert (await _get_user_detail(client, uid))["name"] == "B3 原名"


# ─── B4:email 非法格式 → 422 且不落库(POST/PATCH 双路径)─────────────────────
@pytest.mark.asyncio
async def test_user_email_invalid_format_422(client: AsyncClient) -> None:
    """B4(D6「仅格式校验」):缺 @ / 缺域名点 / 含空格,POST 与 PATCH 均应 422;
    POST 路径用户不得创建(校验先于落库);PATCH 路径 email 保持原值。"""
    uname = _uniq("bx_badmail")
    r = await client.post(
        "/api/v1/admin/directory/users",
        json={"username": uname, "name": "B4 非法邮箱", "email": "not-an-email"},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 422, f"POST email 无 @ 应 422: {r.text}"
    rl = await client.get(
        "/api/v1/admin/directory/users",
        params={"q": uname, "limit": 200}, headers=_h(EVAN_ID),
    )
    assert rl.status_code == 200, rl.text
    assert rl.json()["total"] == 0, "422 的用户不得创建"

    u = await _create_user(
        client, "bx_mail", name="B4 目标", email=f"{_uniq('bx_mail')}@example.com",
    )
    uid = u["id"]
    old_email = u["email"]

    for bad in ("a@b", "a b@c.d", "a@b.", "@b.c"):
        rp = await client.patch(
            f"/api/v1/admin/directory/users/{uid}",
            json={"email": bad}, headers=_h(EVAN_ID),
        )
        assert rp.status_code == 422, f"PATCH email={bad!r} 应 422: {rp.text}"

    assert (await _get_user_detail(client, uid))["email"] == old_email


# ─── B5:建用户 username 重复 409 且 group_ids 无副作用 ────────────────────────
@pytest.mark.asyncio
async def test_create_user_duplicate_username_409_no_group_side_effect(
    client: AsyncClient,
) -> None:
    """B5:username 唯一冲突 → 409「登录名已存在」;冲突发生在组写入前,
    group_ids 不得产生任何成员/审计副作用(F3.3 原子语义顺延)。"""
    g = await _create_group(client, "bx_dup")
    try:
        u1 = await _create_user(client, "bx_dup", name="B5 首次")
        r = await client.post(
            "/api/v1/admin/directory/users",
            json={
                "username": u1["username"], "name": "B5 重复",
                "group_ids": [g["id"]],
            },
            headers=_h(EVAN_ID),
        )
        assert r.status_code == 409, f"重复 username 应 409: {r.text}"
        assert "登录名已存在" in r.text, r.text

        # 组无副作用:成员数不变(0)、无 group_member_added 审计
        assert await _group_members(client, g["id"]) == []
        added = await _group_audit_details(client, "group_member_added", g["id"])
        assert added == [], f"409 路径不得产生成员审计: {added}"

        # 该 username 仍只有 1 个用户
        rl = await client.get(
            "/api/v1/admin/directory/users",
            params={"q": u1["username"], "limit": 200}, headers=_h(EVAN_ID),
        )
        assert rl.json()["total"] == 1, rl.json()
    finally:
        await _delete_group(client, g["id"])


# ─── B6:建用户 group_ids 重复 uuid → 去重 ─────────────────────────────────────
@pytest.mark.asyncio
async def test_create_user_duplicate_group_ids_deduped(client: AsyncClient) -> None:
    """B6:group_ids=[g,g,g] → 201;详情/成员表/审计均恰好一次(去重保序,
    不因重复触发唯一键冲突 500 或重复审计)。"""
    g = await _create_group(client, "bx_dedup")
    try:
        u = await _create_user(
            client, "bx_dedup", name="B6 去重", group_ids=[g["id"], g["id"], g["id"]],
        )
        uid = u["id"]

        detail = await _get_user_detail(client, uid)
        assert detail["group_ids"] == [g["id"]], detail

        members = await _group_members(client, g["id"])
        assert [m["user_id"] for m in members] == [uid], members

        created = await _user_audit_details(client, "user_created", uid)
        assert len(created) == 1 and created[0]["group_ids"] == [g["id"]], created
        added = await _user_audit_details(client, "group_member_added", uid)
        assert len(added) == 1 and added[0]["group_id"] == g["id"], added
        assert added[0].get("source") == "user_create", added
    finally:
        await _delete_group(client, g["id"])


# ─── B7:PATCH group_ids=[] 清空全部组 + 幂等 ──────────────────────────────────
@pytest.mark.asyncio
async def test_patch_user_group_ids_empty_clears_all(client: AsyncClient) -> None:
    """B7(D3 全量同步边界):终态空集 → 全部移除(成员表/详情/审计);
    第二次 PATCH [] 幂等:不产生新的 member 事件。"""
    g1 = await _create_group(client, "bx_clr1")
    g2 = await _create_group(client, "bx_clr2")
    try:
        u = await _create_user(
            client, "bx_clr", name="B7 清空", group_ids=[g1["id"], g2["id"]],
        )
        uid = u["id"]

        r = await client.patch(
            f"/api/v1/admin/directory/users/{uid}",
            json={"group_ids": []}, headers=_h(EVAN_ID),
        )
        assert r.status_code == 200, r.text

        detail = await _get_user_detail(client, uid)
        assert detail["group_ids"] == [] and detail["group_names"] == [], detail
        for g in (g1, g2):
            assert all(m["user_id"] != uid for m in await _group_members(client, g["id"]))

        removed = await _user_audit_details(client, "group_member_removed", uid)
        assert {d["group_id"] for d in removed} == {g1["id"], g2["id"]}, removed
        events = await _user_audit_details(client, "user_updated", uid)
        assert len(events) == 1, events
        assert events[0]["changes"]["groups_removed"], events[0]
        assert events[0]["changes"].get("groups_added") == [], events[0]

        # 幂等:再清一次,无新增 member 事件
        r2 = await client.patch(
            f"/api/v1/admin/directory/users/{uid}",
            json={"group_ids": []}, headers=_h(EVAN_ID),
        )
        assert r2.status_code == 200, r2.text
        removed2 = await _user_audit_details(client, "group_member_removed", uid)
        assert len(removed2) == 2, f"重复清空不得新增移除事件: {removed2}"
        assert (await _get_user_detail(client, uid))["group_ids"] == []
    finally:
        await _delete_group(client, g1["id"])
        await _delete_group(client, g2["id"])


# ─── B8:PATCH group_ids>50 → 422 且不变更 ────────────────────────────────────
@pytest.mark.asyncio
async def test_patch_user_group_ids_over_50_422_no_change(client: AsyncClient) -> None:
    """B8(D9 上限在 PATCH 路径同样生效):51 个 id(ghost 即可,条数校验先于
    存在性校验)→ 422 invalid_group_ids;用户 name/email/组均不变更。"""
    g = await _create_group(client, "bx_o50")
    try:
        u = await _create_user(
            client, "bx_o50", name="B8 原名", group_ids=[g["id"]],
        )
        uid = u["id"]
        r = await client.patch(
            f"/api/v1/admin/directory/users/{uid}",
            json={"name": "B8 改名", "group_ids": [str(uuid.uuid4()) for _ in range(51)]},
            headers=_h(EVAN_ID),
        )
        assert r.status_code == 422, r.text
        assert _INVALID_GROUP_IDS in r.text, r.text

        detail = await _get_user_detail(client, uid)
        assert detail["name"] == "B8 原名" and detail["group_ids"] == [g["id"]], detail
    finally:
        await _delete_group(client, g["id"])


# ─── B9:GET 用户详情 ghost → 404 user_not_found ──────────────────────────────
@pytest.mark.asyncio
async def test_get_user_detail_ghost_404(client: AsyncClient) -> None:
    """B9(契约 §2 错误分支,T 系列只覆盖了 PATCH 404):ghost id → 404 且文案
    带 user_not_found。"""
    r = await client.get(
        f"/api/v1/admin/directory/users/{uuid.uuid4()}", headers=_h(EVAN_ID),
    )
    assert r.status_code == 404, r.text
    assert "user_not_found" in r.text, r.text


# ─── B10:删除项目后分享链接/申请链接行为(D10:全不动,解析不 500 且照常 200)──
@pytest.mark.asyncio
async def test_deleted_project_share_and_request_link_behaviour(
    client: AsyncClient,
) -> None:
    """B10(D10/F6.3「分享链接/申请链接全保留,行为不变」):
    项目删前建 asset 分享 + folder 分享 + project 申请链接 → 删除项目 →
    三个解析端点均不得 5xx,且按「行为不变」应照常 200;restore 后仍 200。
    收尾:项目保持已删除态(folder/asset 随项目深隐藏,不物理清理)。"""
    p = await _create_project(client, name=_uniq("B10 链接项目"))
    pid = p["id"]
    rf = await client.post(
        "/api/v1/folders",
        json={"project_id": pid, "name": _uniq("bx_folder")},
        headers=_h(EVAN_ID),
    )
    assert rf.status_code == 201, rf.text
    fid = rf.json()["id"]
    aid = await _insert_asset(fid, f"bx_{uuid.uuid4().hex[:8]}.txt")

    rs_asset = await client.post(
        f"/api/v1/share/assets/{aid}", json={"expires_in_seconds": 3600},
        headers=_h(EVAN_ID),
    )
    assert rs_asset.status_code == 200, rs_asset.text
    asset_token = rs_asset.json()["token"]
    rs_folder = await client.post(
        f"/api/v1/share/folders/{fid}", json={"expires_in_seconds": 3600},
        headers=_h(EVAN_ID),
    )
    assert rs_folder.status_code == 200, rs_folder.text
    folder_token = rs_folder.json()["token"]
    rr = await client.post(
        "/api/v1/request-links",
        json={"target_type": "project", "target_id": pid,
              "allowed_actions": ["download"]},   # access 仅限 sensitive_folder(服务端约束)
        headers=_h(EVAN_ID),
    )
    assert rr.status_code == 201, rr.text
    rl_token = rr.json()["token"]

    # 删前基线:三个解析端点都 200
    pre = [
        await client.get(f"/api/v1/share/{asset_token}", headers=_h(EVAN_ID)),
        await client.get(f"/api/v1/share/{folder_token}", headers=_h(EVAN_ID)),
        await client.get(f"/api/v1/request-links/{rl_token}", headers=_h(EVAN_ID)),
    ]
    for i, r in enumerate(pre):
        assert r.status_code == 200, f"删前解析 #{i} 应 200: {r.text}"

    # 删除项目 → 三个解析端点不 500 且行为不变(200,D10)
    rd = await client.delete(f"/api/v1/projects/{pid}", headers=_h(EVAN_ID))
    assert rd.status_code == 200, rd.text
    post = []
    for url in (
        f"/api/v1/share/{asset_token}",
        f"/api/v1/share/{folder_token}",
        f"/api/v1/request-links/{rl_token}",
    ):
        r = await client.get(url, headers=_h(EVAN_ID))
        post.append(r)
        assert r.status_code < 500, f"{url} 删除项目后不得 5xx: {r.status_code} {r.text}"
        assert r.status_code == 200, (
            f"{url} 删除项目后链接应保留(行为不变,D10),实际 {r.status_code}: {r.text}"
        )

    # restore 后依旧 200
    rr2 = await client.post(f"/api/v1/projects/{pid}/restore", headers=_h(EVAN_ID))
    assert rr2.status_code == 200, rr2.text
    for url in (
        f"/api/v1/share/{asset_token}",
        f"/api/v1/share/{folder_token}",
        f"/api/v1/request-links/{rl_token}",
    ):
        r = await client.get(url, headers=_h(EVAN_ID))
        assert r.status_code == 200, f"restore 后 {url} 应 200: {r.text}"

    await _soft_delete(client, pid)   # 收尾:重新隐藏


# ─── B11:非 admin(真实普通用户)GET projects/deleted → 403 ──────────────────
@pytest.mark.asyncio
async def test_deleted_list_forbidden_for_plain_users(client: AsyncClient) -> None:
    """B11(F6.5 守门 require_project_deleter):seed 普通成员 bob 与新建零组
    普通用户均 403(fake outsider 已在 T13 覆盖,此处补真实普通用户)。"""
    r = await client.get("/api/v1/projects/deleted", headers=_h(BOB_ID))
    assert r.status_code == 403, f"bob 应 403: {r.text}"

    plain = await _create_user(client, "bx_plain", name="B11 普通用户")
    r2 = await client.get("/api/v1/projects/deleted", headers=_h(plain["id"]))
    assert r2.status_code == 403, f"新建普通用户应 403: {r2.text}"


# ─── B12:public / stealth 项目删除行为一致(public 兜底分支同样过滤已删)──────
@pytest.mark.asyncio
async def test_public_and_stealth_project_delete_consistent(client: AsyncClient) -> None:
    """B12(F6.4/D1):public(列表兜底可见)与 stealth(完全隐藏)项目删除后
    行为一致 —— 主列表(含 public 兜底分支)不出现、详情 404、deleted 列表可见;
    restore 后 public 恢复对普通用户可见。"""
    marker = _uniq("bxvis")
    p_pub = await _create_project(client, name=f"{marker} 公开")
    p_stl = await _create_project(client, name=f"{marker} 隐身")
    await _set_visibility(p_pub["id"], "public")
    await _set_visibility(p_stl["id"], "stealth")

    # 前置:public 对 bob 可见(兜底分支),stealth 不可见
    assert p_pub["id"] in await _main_list_ids(client, BOB_ID)
    assert p_stl["id"] not in await _main_list_ids(client, BOB_ID)

    try:
        rd1 = await client.delete(f"/api/v1/projects/{p_pub['id']}", headers=_h(EVAN_ID))
        assert rd1.status_code == 200, rd1.text
        rd2 = await client.delete(f"/api/v1/projects/{p_stl['id']}", headers=_h(EVAN_ID))
        assert rd2.status_code == 200, rd2.text

        # 删除后一致:主列表(普通用户 public 兜底分支 + system admin)不可见
        assert p_pub["id"] not in await _main_list_ids(client, BOB_ID), (
            "public 项目删除后不得再经兜底分支出现"
        )
        for actor in (EVAN_ID, BOB_ID):
            assert p_pub["id"] not in await _main_list_ids(client, actor)
            assert p_stl["id"] not in await _main_list_ids(client, actor)
            d = await client.get(f"/api/v1/projects/{p_pub['id']}", headers=_h(actor))
            assert d.status_code == 404, f"actor={actor}: {d.text}"
            d2 = await client.get(f"/api/v1/projects/{p_stl['id']}", headers=_h(actor))
            assert d2.status_code == 404, f"actor={actor}: {d2.text}"

        # deleted 列表均可见(visibility 字段原样回显)
        rl = await client.get(
            "/api/v1/projects/deleted", params={"q": marker, "limit": 200},
            headers=_h(EVAN_ID),
        )
        assert rl.status_code == 200, rl.text
        body = rl.json()
        by_id = {it["id"]: it for it in body["items"]}
        assert set(by_id) == {p_pub["id"], p_stl["id"]}, body
        assert by_id[p_pub["id"]]["visibility"] == "public", by_id
        assert by_id[p_stl["id"]]["visibility"] == "stealth", by_id
        assert by_id[p_pub["id"]]["deleted_by_name"] == "Evan", by_id

        # restore public → bob 重新可见(兜底分支恢复)
        rr = await client.post(
            f"/api/v1/projects/{p_pub['id']}/restore", headers=_h(EVAN_ID),
        )
        assert rr.status_code == 200, rr.text
        assert p_pub["id"] in await _main_list_ids(client, BOB_ID)
    finally:
        await _soft_delete(client, p_pub["id"])
        # p_stl 保持已删除态(收尾即隐藏)
