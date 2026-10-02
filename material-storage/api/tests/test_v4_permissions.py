"""iter a1 e2e 集成测试 — 跑在 ms-api 容器里(`docker exec ms-api pytest`)。

#148:OpenFGA subject 已从飞书 open_id 切到 users.id UUID;
member/grant payload 用 user_id(users.id UUID),断言的 subject 为 user:<uuid>。

预期前置:
  1. seed_demo_data.py 已跑过(创建 3 项目 / 40 folder / 真 user Evan / fake outsider)
  2. OpenFGA store / model 已 push
  3. env=dev(允许 X-User-Id header 模拟身份)

覆盖:
  - permissions service 纯函数(fmt_subject)
  - 三种身份 list_projects 可见性
  - folder list 中 sensitive folder 过滤
  - admin (Evan) folder/invite/approval 流程
  - outsider 被拒
  - share 链路(创建 + GET token resolve)
"""
from __future__ import annotations

import uuid

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import create_app
from app.services.permissions import fmt_subject

# seed 写死的真 user 和 fake outsider id(种子脚本里 hardcode)
EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"
OUTSIDER_ID = "00000000-0000-0000-0000-0000000000aa"

PROJECT_WEDDING = "11111111-1111-1111-1111-111111111101"   # private
PROJECT_ZHANG = "11111111-1111-1111-1111-111111111102"     # private
PROJECT_EVENT = "11111111-1111-1111-1111-111111111103"     # public


# ─── 单元测试 ─────────────────────────────────────────────────────────────────
class TestFmtSubject:
    """fmt_subject:user 不加 #member;group 加(#154:department / organization 下线)。"""

    def test_user(self) -> None:
        assert fmt_subject("user", "ou_xxx") == "user:ou_xxx"

    def test_group(self) -> None:
        assert fmt_subject("group", "g1") == "group:g1#member"


# ─── HTTP 集成 fixture(session 级:asyncpg 不能跨 loop;同时减少 lifespan 反复) ─
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


# ─── /me ─────────────────────────────────────────────────────────────────────
@pytest.mark.asyncio
async def test_me_evan(client: AsyncClient) -> None:
    r = await client.get("/api/v1/auth/me", headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["id"] == EVAN_ID
    assert body["open_id"].startswith("ou_")
    assert body["name"] == "Evan"


@pytest.mark.asyncio
async def test_me_outsider(client: AsyncClient) -> None:
    r = await client.get("/api/v1/auth/me", headers=_h(OUTSIDER_ID))
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["open_id"] == "ou_fake_outsider"


# ─── projects list 可见性 ────────────────────────────────────────────────────
@pytest.mark.asyncio
async def test_projects_evan_sees_all(client: AsyncClient) -> None:
    """Evan 是创建者/admin,看到全部 3 个项目。"""
    r = await client.get("/api/v1/projects", headers=_h(EVAN_ID))
    assert r.status_code == 200
    ids = {p["id"] for p in r.json()}
    assert PROJECT_WEDDING in ids
    assert PROJECT_ZHANG in ids
    assert PROJECT_EVENT in ids


@pytest.mark.asyncio
async def test_projects_outsider_sees_only_public(client: AsyncClient) -> None:
    """Outsider 至少应见 public 项目(其他项目除非显式 grant)。"""
    r = await client.get("/api/v1/projects", headers=_h(OUTSIDER_ID))
    assert r.status_code == 200
    items = r.json()
    public_seen = [p for p in items if p["visibility"] == "public"]
    assert any(p["id"] == PROJECT_EVENT for p in public_seen)
    # 私有项目 wedding 不应见(除非测试中曾被 grant outsider)
    private_seen = [p for p in items
                    if p["id"] == PROJECT_WEDDING and p["visibility"] == "private"]
    assert not private_seen, "outsider 不应见 private wedding"


# ─── project 单条 access ──────────────────────────────────────────────────────
@pytest.mark.asyncio
async def test_project_get_private_denied_for_outsider(client: AsyncClient) -> None:
    r = await client.get(f"/api/v1/projects/{PROJECT_WEDDING}", headers=_h(OUTSIDER_ID))
    assert r.status_code == 403


@pytest.mark.asyncio
async def test_project_get_public_ok_for_outsider(client: AsyncClient) -> None:
    r = await client.get(f"/api/v1/projects/{PROJECT_EVENT}", headers=_h(OUTSIDER_ID))
    assert r.status_code == 200


# ─── folders list:sensitive 过滤 ────────────────────────────────────────────
@pytest.mark.asyncio
async def test_folders_evan_sees_sensitive(client: AsyncClient) -> None:
    """Evan 被 seed 显式 invite 进所有 sensitive folder,应能看到。"""
    r = await client.get(
        "/api/v1/folders", params={"project_id": PROJECT_WEDDING}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 200
    folders = r.json()
    sensitive_names = [f["name"] for f in folders if f["is_sensitive"]]
    # seed 里 wedding 有 2 个 sensitive folder
    assert any("VIP" in n for n in sensitive_names), sensitive_names


@pytest.mark.asyncio
async def test_folders_outsider_sees_only_public_project_normal_folders(client: AsyncClient) -> None:
    """Outsider 只能看 public project,且 sensitive folder 不可见(invited_* 为空)。"""
    r = await client.get(
        "/api/v1/folders", params={"project_id": PROJECT_EVENT}, headers=_h(OUTSIDER_ID),
    )
    assert r.status_code == 200
    folders = r.json()
    # public project 元数据可见(get_project 通过)但 folder 默认要 can_view,
    # outsider 没任何 tuple → 普通 folder 经 OR `is_sensitive=false` 全部返回(SQL 层),
    # sensitive folder 必须 OpenFGA can_view 才能见
    sensitive = [f for f in folders if f["is_sensitive"]]
    assert sensitive == [], f"outsider 不应见 sensitive: {sensitive}"


# ─── approval 流程 ────────────────────────────────────────────────────────────
async def _cleanup_wedding_download_approvals() -> None:
    """确定性清场:删掉本目标全部 download 申请(含历史 pending),保证测试可重入。

    API reject 之外兜底 —— reject 与 create 注册的 notify 后台任务在同行上有
    低概率竞态(观测过 reject 200 但未落库),不能依赖它收敛历史状态。
    """
    from sqlalchemy import delete

    from app.db.session import get_sessionmaker
    from app.db.tables import ApprovalRequest

    async with get_sessionmaker()() as db:
        res = await db.execute(delete(ApprovalRequest).where(
            ApprovalRequest.target_type == "project",
            ApprovalRequest.target_id == PROJECT_WEDDING,
            ApprovalRequest.action == "download",
        ))
        print(f"[cleanup] deleted rows: {res.rowcount}")
        await db.commit()


@pytest.mark.asyncio
async def test_approval_create_and_pending_state(client: AsyncClient) -> None:
    """Evan 提交 approval → 201 + pending;重复提交 → 400;结束清理保证可重入。"""
    await _cleanup_wedding_download_approvals()
    body = {
        "target_type": "project",
        "target_id": PROJECT_WEDDING,
        "action": "download",
        "duration_seconds": 3600,
        "reason": "test_v4 e2e — approval pending check",
    }
    r = await client.post("/api/v1/approvals", json=body, headers=_h(EVAN_ID))
    assert r.status_code == 201, r.text
    a = r.json()
    assert a["status"] == "pending"
    assert a["target_id"] == PROJECT_WEDDING

    # 同人同目标同动作重复提交 → 400(防刷屏)
    r_dup = await client.post("/api/v1/approvals", json=body, headers=_h(EVAN_ID))
    assert r_dup.status_code == 400

    # outsider 也能提(不同申请人不冲突);但 approve 不通过(无 admin)
    body2 = dict(body, reason="outsider 申请")
    r2 = await client.post("/api/v1/approvals", json=body2, headers=_h(OUTSIDER_ID))
    assert r2.status_code == 201
    # outsider 同目标重复 → 400
    r3 = await client.post("/api/v1/approvals", json=body2, headers=_h(OUTSIDER_ID))
    assert r3.status_code == 400

    # 清理:管理员(Evan)拒掉两条 pending,测试可重入(残留 pending 会让下次运行 400)。
    # reject 与 create 注册的 notify 后台任务在同行上有低概率竞态,重试一次兜底
    for aid in (a["id"], r2.json()["id"]):
        rr = await client.post(
            f"/api/v1/approvals/{aid}/reject", json={"decision_note": "test cleanup"},
            headers=_h(EVAN_ID),
        )
        if rr.status_code != 200:
            rr = await client.post(
                f"/api/v1/approvals/{aid}/reject", json={"decision_note": "test cleanup retry"},
                headers=_h(EVAN_ID),
            )
        assert rr.status_code == 200, rr.text


@pytest.mark.asyncio
async def test_approval_reject_by_non_admin_returns_403(client: AsyncClient) -> None:
    await _cleanup_wedding_download_approvals()
    # Evan 创建,然后 outsider 尝试 approve → 403
    body = {
        "target_type": "project", "target_id": PROJECT_WEDDING,
        "action": "download", "duration_seconds": 3600,
        "reason": "non-admin approve test",
    }
    r = await client.post("/api/v1/approvals", json=body, headers=_h(EVAN_ID))
    assert r.status_code == 201
    aid = r.json()["id"]
    r2 = await client.post(
        f"/api/v1/approvals/{aid}/approve", json={"decision_note": "noop"},
        headers=_h(OUTSIDER_ID),
    )
    assert r2.status_code == 403
    # 清理:Evan(项目 admin)拒掉,免得残留 pending 卡住下次运行
    rr = await client.post(
        f"/api/v1/approvals/{aid}/reject", json={"decision_note": "test cleanup"},
        headers=_h(EVAN_ID),
    )
    assert rr.status_code == 200


# ─── share 短链 ─────────────────────────────────────────────────────────────
@pytest.mark.asyncio
async def test_share_create_and_resolve(client: AsyncClient) -> None:
    # 拿一个 asset id(Evan 项目里随便挑一个)
    r = await client.get(
        "/api/v1/folders", params={"project_id": PROJECT_WEDDING}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 200
    normal_folder = next(f for f in r.json() if not f["is_sensitive"])
    r2 = await client.get(
        "/api/v1/assets", params={"folder_id": normal_folder["id"]}, headers=_h(EVAN_ID),
    )
    assert r2.status_code == 200, r2.text
    assets = r2.json()["items"]
    assert assets, "seed 应至少 1 个 asset"
    asset = assets[0]

    # 创建 share(不推 IM,只生成链接)
    r3 = await client.post(
        f"/api/v1/share/assets/{asset['id']}",
        json={"receive_open_ids": [], "expires_in_seconds": 3600},
        headers=_h(EVAN_ID),
    )
    assert r3.status_code == 200, r3.text
    share = r3.json()
    assert "token" in share
    token = share["token"]

    # GET resolve
    r4 = await client.get(f"/api/v1/share/{token}", headers=_h(EVAN_ID))
    assert r4.status_code == 200
    body = r4.json()
    assert body["kind"] == "asset"
    assert body["asset"]["id"] == asset["id"]
    assert body["download_url"].startswith("http"), body["download_url"]


@pytest.mark.asyncio
async def test_share_invalid_token_404(client: AsyncClient) -> None:
    r = await client.get("/api/v1/share/__not_a_real_token__", headers=_h(EVAN_ID))
    assert r.status_code == 404


# ─── D iter4:project members CRUD ───────────────────────────────────────────
@pytest.mark.asyncio
async def test_project_members_list(client: AsyncClient) -> None:
    """Evan(创建者 admin)能列 wedding 的成员。"""
    r = await client.get(f"/api/v1/projects/{PROJECT_WEDDING}/members", headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    items = r.json()
    assert any(m["kind"] == "user" and m["subject_id"] == EVAN_ID and "admin" in m["roles"]
               for m in items), f"应至少有一个 user admin: {items}"


@pytest.mark.asyncio
async def test_project_members_list_denied_for_non_admin(client: AsyncClient) -> None:
    """outsider 不是 admin 不能列。"""
    r = await client.get(f"/api/v1/projects/{PROJECT_WEDDING}/members", headers=_h(OUTSIDER_ID))
    assert r.status_code == 403


@pytest.mark.asyncio
async def test_project_member_add_remove_cycle(client: AsyncClient) -> None:
    """Evan 加 outsider 为 viewer → 再撤 → 验列表回退。"""
    add = await client.post(
        f"/api/v1/projects/{PROJECT_EVENT}/members",
        json={"user_id": OUTSIDER_ID, "role": "viewer"},
        headers=_h(EVAN_ID),
    )
    assert add.status_code == 204, add.text

    r1 = await client.get(f"/api/v1/projects/{PROJECT_EVENT}/members", headers=_h(EVAN_ID))
    assert r1.status_code == 200
    members1 = r1.json()
    assert any(m["subject"] == f"user:{OUTSIDER_ID}" and "viewer" in m["roles"]
               for m in members1)

    rev = await client.delete(
        f"/api/v1/projects/{PROJECT_EVENT}/members",
        params={"subject": f"user:{OUTSIDER_ID}", "role": "viewer"},
        headers=_h(EVAN_ID),
    )
    assert rev.status_code == 204

    r2 = await client.get(f"/api/v1/projects/{PROJECT_EVENT}/members", headers=_h(EVAN_ID))
    members2 = r2.json()
    assert not any(m["subject"] == f"user:{OUTSIDER_ID}" for m in members2)


# ─── a2:GET /users 搜索 ─────────────────────────────────────────────────────
@pytest.mark.asyncio
async def test_users_list_basic(client: AsyncClient) -> None:
    """无 q 列出前 N 个 active user。"""
    r = await client.get("/api/v1/users?limit=5", headers=_h(EVAN_ID))
    assert r.status_code == 200
    items = r.json()
    assert isinstance(items, list)
    assert len(items) <= 5
    if items:
        assert "open_id" in items[0]
        assert "name" in items[0]


@pytest.mark.asyncio
async def test_users_fuzzy_search(client: AsyncClient) -> None:
    """模糊搜 'Evan' → 至少 Evan 自己。"""
    r = await client.get("/api/v1/users?q=Evan&limit=10", headers=_h(EVAN_ID))
    assert r.status_code == 200
    names = {u["name"] for u in r.json()}
    assert "Evan" in names


@pytest.mark.asyncio
async def test_users_no_auth_401(client: AsyncClient) -> None:
    r = await client.get("/api/v1/users")
    assert r.status_code == 401


# ─── polish 1:folder explicit grants ───────────────────────────────────────
@pytest.mark.asyncio
async def test_folder_grants_cycle(client: AsyncClient) -> None:
    """普通一级 folder grants:list / add outsider downloader / delete / 验回退。"""
    # 找 wedding 项目下的一级普通 folder
    r = await client.get(
        "/api/v1/folders", params={"project_id": PROJECT_WEDDING}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 200
    normal_top = next(
        f for f in r.json()
        if not f["is_sensitive"] and f.get("parent_folder_id") is None
    )
    fid = normal_top["id"]

    # list 初始
    r1 = await client.get(f"/api/v1/folders/{fid}/grants", headers=_h(EVAN_ID))
    assert r1.status_code == 200
    before = len(r1.json())

    # add outsider downloader
    add = await client.post(
        f"/api/v1/folders/{fid}/grants",
        json={"user_id": OUTSIDER_ID, "level": "downloader"},
        headers=_h(EVAN_ID),
    )
    assert add.status_code == 204, add.text

    r2 = await client.get(f"/api/v1/folders/{fid}/grants", headers=_h(EVAN_ID))
    assert any(g["subject"] == f"user:{OUTSIDER_ID}" and g["level"] == "downloader"
               for g in r2.json())

    # delete
    rev = await client.delete(
        f"/api/v1/folders/{fid}/grants",
        params={"subject": f"user:{OUTSIDER_ID}", "level": "downloader"},
        headers=_h(EVAN_ID),
    )
    assert rev.status_code == 204
    r3 = await client.get(f"/api/v1/folders/{fid}/grants", headers=_h(EVAN_ID))
    assert len(r3.json()) == before


@pytest.mark.asyncio
async def test_folder_grants_sensitive_rejected(client: AsyncClient) -> None:
    """sensitive folder 不允许走 /grants(应走 /invite)。"""
    r = await client.get(
        "/api/v1/folders", params={"project_id": PROJECT_WEDDING}, headers=_h(EVAN_ID),
    )
    sens = next(f for f in r.json() if f["is_sensitive"])
    r2 = await client.get(f"/api/v1/folders/{sens['id']}/grants", headers=_h(EVAN_ID))
    assert r2.status_code == 400


# ─── folder 删除(一期:仅空文件夹硬删)────────────────────────────────────────
@pytest.mark.asyncio
async def test_folder_delete_empty_hard(client: AsyncClient) -> None:
    """空 folder:Evan 创建 → 删 204 → GET 404 → 重复删 404(硬删无 tombstone)。"""
    uniq = uuid.uuid4().hex[:8]
    r = await client.post(
        "/api/v1/folders",
        json={"project_id": PROJECT_EVENT, "name": f"zz_del_empty_{uniq}"},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text
    fid = r.json()["id"]

    r2 = await client.delete(f"/api/v1/folders/{fid}", headers=_h(EVAN_ID))
    assert r2.status_code == 204, r2.text

    r3 = await client.get(f"/api/v1/folders/{fid}", headers=_h(EVAN_ID))
    assert r3.status_code == 404

    r4 = await client.delete(f"/api/v1/folders/{fid}", headers=_h(EVAN_ID))
    assert r4.status_code == 404


@pytest.mark.asyncio
async def test_folder_delete_nonempty_rejected(client: AsyncClient) -> None:
    """非空:有子文件夹时删父 409;先删子、父变空后可删(同名也能立刻重建)。"""
    uniq = uuid.uuid4().hex[:8]
    r = await client.post(
        "/api/v1/folders",
        json={"project_id": PROJECT_EVENT, "name": f"zz_del_parent_{uniq}"},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text
    parent = r.json()["id"]

    r2 = await client.post(
        "/api/v1/folders",
        json={"project_id": PROJECT_EVENT, "name": f"zz_del_child_{uniq}",
              "parent_folder_id": parent},
        headers=_h(EVAN_ID),
    )
    assert r2.status_code == 201, r2.text
    child = r2.json()["id"]

    r3 = await client.delete(f"/api/v1/folders/{parent}", headers=_h(EVAN_ID))
    assert r3.status_code == 409

    r4 = await client.delete(f"/api/v1/folders/{child}", headers=_h(EVAN_ID))
    assert r4.status_code == 204, r4.text
    r5 = await client.delete(f"/api/v1/folders/{parent}", headers=_h(EVAN_ID))
    assert r5.status_code == 204

    # 硬删释放 uq_folder_project_prefix:同名可立即重建
    r6 = await client.post(
        "/api/v1/folders",
        json={"project_id": PROJECT_EVENT, "name": f"zz_del_parent_{uniq}"},
        headers=_h(EVAN_ID),
    )
    assert r6.status_code == 201, r6.text
    r7 = await client.delete(f"/api/v1/folders/{r6.json()['id']}", headers=_h(EVAN_ID))
    assert r7.status_code == 204


@pytest.mark.asyncio
async def test_folder_delete_denied_for_non_admin(client: AsyncClient) -> None:
    """无任何角色的 outsider(public 项目普通 folder)→ 403。

    普通夹删除门槛是 can_upload(uploader 可删空夹);outsider 既无
    can_upload 也无 can_admin,两个 relation 都过不了。
    """
    r = await client.get(
        "/api/v1/folders", params={"project_id": PROJECT_EVENT}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 200
    fid = r.json()[0]["id"]

    r2 = await client.delete(f"/api/v1/folders/{fid}", headers=_h(OUTSIDER_ID))
    assert r2.status_code == 403


@pytest.mark.asyncio
async def test_folder_delete_uploader_can_delete(client: AsyncClient) -> None:
    """普通夹删除降级为 can_upload:显式 uploader(非 admin)可删空 folder。"""
    uniq = uuid.uuid4().hex[:8]
    r = await client.post(
        "/api/v1/folders",
        json={"project_id": PROJECT_EVENT, "name": f"zz_del_uploader_{uniq}"},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text
    fid = r.json()["id"]

    # Evan 给 outsider 授 folder 显式 uploader(一级普通夹,走 /grants)
    add = await client.post(
        f"/api/v1/folders/{fid}/grants",
        json={"user_id": OUTSIDER_ID, "level": "uploader"},
        headers=_h(EVAN_ID),
    )
    assert add.status_code == 204, add.text

    r2 = await client.delete(f"/api/v1/folders/{fid}", headers=_h(OUTSIDER_ID))
    assert r2.status_code == 204, r2.text


@pytest.mark.asyncio
async def test_folder_delete_sensitive_still_requires_admin(client: AsyncClient) -> None:
    """sensitive 夹例外:invited downloader 隐含 can_upload,但删除仍需 can_admin。"""
    # 找 wedding 项目的 sensitive folder
    r = await client.get(
        "/api/v1/folders", params={"project_id": PROJECT_WEDDING}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 200
    sens = next(f for f in r.json() if f["is_sensitive"])

    # Evan 邀 outsider 作 downloader(→ sensitive 的 can_upload 为 true)
    inv = await client.post(
        f"/api/v1/folders/{sens['id']}/invite",
        json={"user_id": OUTSIDER_ID, "level": "downloader"},
        headers=_h(EVAN_ID),
    )
    assert inv.status_code == 204, inv.text
    try:
        r2 = await client.delete(
            f"/api/v1/folders/{sens['id']}", headers=_h(OUTSIDER_ID),
        )
        assert r2.status_code == 403, r2.text
    finally:
        # 清理:撤销邀请,不污染 seed 数据。撤销失败只告警 —— finally 里
        # assert 会掩盖 try 内真正的断言失败;残留 tuple 需人工清
        import warnings

        rev = await client.delete(
            f"/api/v1/folders/{sens['id']}/invite",
            params={"subject": f"user:{OUTSIDER_ID}", "level": "downloader",
                    "permanent": "true"},
            headers=_h(EVAN_ID),
        )
        if rev.status_code != 204:
            warnings.warn(
                f"sensitive invite cleanup failed ({rev.status_code}): {rev.text};"
                f" outsider 对 {sens['id']} 残留 invited_downloader tuple",
                stacklevel=2,
            )


@pytest.mark.asyncio
async def test_folder_delete_concurrent_double_delete(client: AsyncClient) -> None:
    """#177 并发回归:同时删同一文件夹,FOR UPDATE 串行化 → 恰好一个 204、
    另一个 404(锁等待后行已不存在),绝不出现 500。"""
    import asyncio

    uniq = uuid.uuid4().hex[:8]
    r = await client.post(
        "/api/v1/folders",
        json={"project_id": PROJECT_EVENT, "name": f"zz_del_race_{uniq}"},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text
    fid = r.json()["id"]

    results = await asyncio.gather(
        client.delete(f"/api/v1/folders/{fid}", headers=_h(EVAN_ID)),
        client.delete(f"/api/v1/folders/{fid}", headers=_h(EVAN_ID)),
        return_exceptions=True,
    )
    codes = sorted(
        500 if isinstance(r_, BaseException) else r_.status_code for r_ in results
    )
    assert codes == [204, 404], f"expected [204, 404], got {codes}"


# #154:admin feishu health / test-card 测试随飞书下线删除(ADR-0007)


# ─── 批次一:组授管理放开(§1.2 改动 1)+ admin 不变量加固(§1.2 改动 2)
# ─── + 主体名称解析(§2.2 helper)。建组照 tests/test_directory.py:127-135
# ─── (seed 脚本不建 groups 表数据,不存在现成 fixture 组)。
def _uniq(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:8]}"


async def _create_group(client: AsyncClient, name: str, member_ids: list[str]) -> str:
    """建目录组 + 挂成员,返回组 id。"""
    r = await client.post(
        "/api/v1/admin/directory/groups", json={"name": name}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text
    gid = r.json()["id"]
    for uid in member_ids:
        rm = await client.post(
            f"/api/v1/admin/directory/groups/{gid}/members",
            json={"user_id": uid}, headers=_h(EVAN_ID),
        )
        assert rm.status_code == 201, rm.text
    return gid


@pytest.mark.asyncio
async def test_project_member_group_admin_cycle(client: AsyncClient) -> None:
    """§1.4:建组(Evan+outsider)→ 组 admin 204 → 组内非创建者(outsider)
    list/add 成员成功(can_admin 生效)→ GET /members 该组带 admin 徽章 →
    DELETE 撤回 → outsider can_admin 消失。"""
    gid = await _create_group(client, _uniq("grp_cycle"), [EVAN_ID, OUTSIDER_ID])
    try:
        # 组 admin 放行(#162 重构回归的 guard 已删,§1.2 改动 1)
        add = await client.post(
            f"/api/v1/projects/{PROJECT_EVENT}/members",
            json={"group_id": gid, "roles": ["admin"]},
            headers=_h(EVAN_ID),
        )
        assert add.status_code == 204, add.text

        # 组内非创建者用户已具 can_admin:list 成员 / 加成员成功
        r1 = await client.get(
            f"/api/v1/projects/{PROJECT_EVENT}/members", headers=_h(OUTSIDER_ID),
        )
        assert r1.status_code == 200, r1.text
        add2 = await client.post(
            f"/api/v1/projects/{PROJECT_EVENT}/members",
            json={"user_id": OUTSIDER_ID, "role": "viewer"},
            headers=_h(OUTSIDER_ID),
        )
        assert add2.status_code == 204, add2.text

        # GET /members:该组带 admin 角色(前端「管理」徽章 + 🛡 数据源)
        r2 = await client.get(
            f"/api/v1/projects/{PROJECT_EVENT}/members", headers=_h(EVAN_ID),
        )
        assert r2.status_code == 200
        grp = next(m for m in r2.json() if m["subject"] == f"group:{gid}#member")
        assert "admin" in grp["roles"], r2.json()

        # DELETE 撤回组 admin(Evan 直授 admin 幸存 → 投影非空 → 204)
        rev = await client.delete(
            f"/api/v1/projects/{PROJECT_EVENT}/members",
            params={"subject": f"group:{gid}#member", "role": "admin"},
            headers=_h(EVAN_ID),
        )
        assert rev.status_code == 204, rev.text

        # can_admin 消失:outsider 再列成员 → 403;组不再出现在成员列表
        r3 = await client.get(
            f"/api/v1/projects/{PROJECT_EVENT}/members", headers=_h(OUTSIDER_ID),
        )
        assert r3.status_code == 403
        r4 = await client.get(
            f"/api/v1/projects/{PROJECT_EVENT}/members", headers=_h(EVAN_ID),
        )
        assert not any(m["subject"] == f"group:{gid}#member" for m in r4.json())
    finally:
        # 清场:撤 outsider 直授 viewer(若有)+ 删组(组 member tuple 由删组清理)
        await client.delete(
            f"/api/v1/projects/{PROJECT_EVENT}/members",
            params={"subject": f"user:{OUTSIDER_ID}", "role": "viewer"},
            headers=_h(EVAN_ID),
        )
        await client.delete(f"/api/v1/admin/directory/groups/{gid}", headers=_h(EVAN_ID))


@pytest.mark.asyncio
async def test_group_admin_lockout_guard(client: AsyncClient) -> None:
    """§1.4(§1.2 改动 2):组成为唯一 admin 来源后撤组 admin → 409 不放行;
    重新授一个 user admin 后再撤组 → 204 —— 直授 tuple 独立于组 tuple 幸存,
    这正是幸存 tuple 投影替代「leaf - 贡献集」减法的原因。"""
    gid = await _create_group(client, _uniq("grp_lockout"), [EVAN_ID, OUTSIDER_ID])
    try:
        # ① PROJECT_EVENT 天生有 Evan 的 bootstrap admin;② 授 2 人组 admin
        add = await client.post(
            f"/api/v1/projects/{PROJECT_EVENT}/members",
            json={"group_id": gid, "roles": ["admin"]},
            headers=_h(EVAN_ID),
        )
        assert add.status_code == 204, add.text
        # ③ outsider(组成员,已具 can_admin)撤掉 Evan 的 user admin → 204
        #    (幸存组 tuple 展开非空;此后组是唯一 admin 来源)
        rev_evan = await client.delete(
            f"/api/v1/projects/{PROJECT_EVENT}/members",
            params={"subject": f"user:{EVAN_ID}", "role": "admin"},
            headers=_h(OUTSIDER_ID),
        )
        assert rev_evan.status_code == 204, rev_evan.text
        # ④ 撤该组 admin → 409(幸存 leaf 投影为空,项目不失去管理入口)
        rev_grp = await client.delete(
            f"/api/v1/projects/{PROJECT_EVENT}/members",
            params={"subject": f"group:{gid}#member", "role": "admin"},
            headers=_h(OUTSIDER_ID),
        )
        assert rev_grp.status_code == 409, rev_grp.text
        # ⑤ 重新授 user admin(outsider 经组 can_admin 可操作)后再撤组 → 204
        re_add = await client.post(
            f"/api/v1/projects/{PROJECT_EVENT}/members",
            json={"user_id": EVAN_ID, "roles": ["admin"]},
            headers=_h(OUTSIDER_ID),
        )
        assert re_add.status_code == 204, re_add.text
        rev_grp2 = await client.delete(
            f"/api/v1/projects/{PROJECT_EVENT}/members",
            params={"subject": f"group:{gid}#member", "role": "admin"},
            headers=_h(OUTSIDER_ID),
        )
        assert rev_grp2.status_code == 204, rev_grp2.text
    finally:
        # 兜底恢复 seed 基线(Evan admin;Evan 是 org admin 可直通)+ 删组
        await client.post(
            f"/api/v1/projects/{PROJECT_EVENT}/members",
            json={"user_id": EVAN_ID, "roles": ["admin"]},
            headers=_h(EVAN_ID),
        )
        await client.delete(f"/api/v1/admin/directory/groups/{gid}", headers=_h(EVAN_ID))


@pytest.mark.asyncio
async def test_group_admin_overlap_direct_grant_survives(client: AsyncClient) -> None:
    """§1.4 重叠回归:Evan 直授 admin + 给含 Evan 的组授 admin → 撤组的 admin
    → 204 且 Evan 仍 can_admin(直授 tuple 幸存;减法算法会把差集错算成空、
    把本应 204 的撤销误杀成 409,该场景必须直拍)。"""
    gid = await _create_group(client, _uniq("grp_overlap"), [EVAN_ID, OUTSIDER_ID])
    try:
        # Evan 直授 admin(与 bootstrap 同 tuple,幂等)+ 组授 admin → 重叠授权
        direct = await client.post(
            f"/api/v1/projects/{PROJECT_EVENT}/members",
            json={"user_id": EVAN_ID, "roles": ["admin"]},
            headers=_h(EVAN_ID),
        )
        assert direct.status_code == 204, direct.text
        add = await client.post(
            f"/api/v1/projects/{PROJECT_EVENT}/members",
            json={"group_id": gid, "roles": ["admin"]},
            headers=_h(EVAN_ID),
        )
        assert add.status_code == 204, add.text

        # 撤组的 admin → 204(Evan 直授 tuple 幸存,幸存投影非空)
        rev = await client.delete(
            f"/api/v1/projects/{PROJECT_EVENT}/members",
            params={"subject": f"group:{gid}#member", "role": "admin"},
            headers=_h(EVAN_ID),
        )
        assert rev.status_code == 204, rev.text

        # Evan 仍 can_admin
        r = await client.get(
            f"/api/v1/projects/{PROJECT_EVENT}/members", headers=_h(EVAN_ID),
        )
        assert r.status_code == 200, r.text
        assert any(m["subject"] == f"user:{EVAN_ID}" and "admin" in m["roles"]
                   for m in r.json())
    finally:
        await client.delete(f"/api/v1/admin/directory/groups/{gid}", headers=_h(EVAN_ID))


@pytest.mark.asyncio
async def test_project_member_uuid_entry_validation(client: AsyncClient) -> None:
    """§1.2 配套入口校验:user_id / group_id 非 UUID → 400;DELETE subject 非
    user:<uuid> / group:<uuid>#member 形态 → 400(否则投影匹配不到该 tuple,
    204 假成功 + audit 记了 removed 但真实 tuple 残留)。"""
    base = f"/api/v1/projects/{PROJECT_EVENT}/members"

    # 存量非 UUID 组名(如 seed 的 grp_editors)当 group_id → 400
    r1 = await client.post(
        base, json={"group_id": "grp_editors", "roles": ["viewer"]}, headers=_h(EVAN_ID),
    )
    assert r1.status_code == 400, r1.text
    # user_id 非 UUID → 400
    r2 = await client.post(
        base, json={"user_id": "not-a-uuid", "roles": ["viewer"]}, headers=_h(EVAN_ID),
    )
    assert r2.status_code == 400, r2.text

    # DELETE:user: 后非 UUID → 400
    r3 = await client.delete(
        base, params={"subject": "user:not-a-uuid", "role": "viewer"}, headers=_h(EVAN_ID),
    )
    assert r3.status_code == 400, r3.text
    # DELETE:group 漏 #member 后缀 → 400
    r4 = await client.delete(
        base,
        params={"subject": f"group:{uuid.uuid4()}", "role": "viewer"},
        headers=_h(EVAN_ID),
    )
    assert r4.status_code == 400, r4.text
    # DELETE:无 kind 前缀的裸串 → 400
    r5 = await client.delete(
        base, params={"subject": "grp_editors", "role": "viewer"}, headers=_h(EVAN_ID),
    )
    assert r5.status_code == 400, r5.text


@pytest.mark.asyncio
async def test_project_members_group_name_resolved(client: AsyncClient) -> None:
    """§2.3:groups 表命中的组主体显示组名(不再是「用户组 xxx」)。"""
    gname = _uniq("命名组")
    gid = await _create_group(client, gname, [OUTSIDER_ID])
    try:
        add = await client.post(
            f"/api/v1/projects/{PROJECT_EVENT}/members",
            json={"group_id": gid, "roles": ["viewer"]},
            headers=_h(EVAN_ID),
        )
        assert add.status_code == 204, add.text
        r = await client.get(
            f"/api/v1/projects/{PROJECT_EVENT}/members", headers=_h(EVAN_ID),
        )
        assert r.status_code == 200
        grp = next(m for m in r.json() if m["subject"] == f"group:{gid}#member")
        assert grp["name"] == gname
    finally:
        await client.delete(
            f"/api/v1/projects/{PROJECT_EVENT}/members",
            params={"subject": f"group:{gid}#member", "role": "viewer"},
            headers=_h(EVAN_ID),
        )
        await client.delete(f"/api/v1/admin/directory/groups/{gid}", headers=_h(EVAN_ID))


@pytest.mark.asyncio
async def test_grants_overview_and_folder_grants_group_name(client: AsyncClient) -> None:
    """§2.3:给一级普通 folder 授组 viewer 后,folder grants 列表与项目授权总览
    的组主体都显示组名。"""
    gname = _uniq("grp_gov")
    gid = await _create_group(client, gname, [OUTSIDER_ID])
    r = await client.get(
        "/api/v1/folders", params={"project_id": PROJECT_WEDDING}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 200
    fid = next(
        f["id"] for f in r.json()
        if not f["is_sensitive"] and f.get("parent_folder_id") is None
    )
    try:
        add = await client.post(
            f"/api/v1/folders/{fid}/grants",
            json={"group_id": gid, "level": "viewer"},
            headers=_h(EVAN_ID),
        )
        assert add.status_code == 204, add.text

        # folder grants 列表:组名
        r1 = await client.get(f"/api/v1/folders/{fid}/grants", headers=_h(EVAN_ID))
        assert r1.status_code == 200
        g = next(x for x in r1.json() if x["subject"] == f"group:{gid}#member")
        assert g["name"] == gname

        # 项目授权总览(folder explicit_viewer 聚合进来):组名
        r2 = await client.get(
            f"/api/v1/projects/{PROJECT_WEDDING}/grants", headers=_h(EVAN_ID),
        )
        assert r2.status_code == 200
        rec = next(x for x in r2.json() if x["subject"] == f"group:{gid}#member")
        assert rec["name"] == gname
    finally:
        await client.delete(
            f"/api/v1/folders/{fid}/grants",
            params={"subject": f"group:{gid}#member", "level": "viewer"},
            headers=_h(EVAN_ID),
        )
        await client.delete(f"/api/v1/admin/directory/groups/{gid}", headers=_h(EVAN_ID))


@pytest.mark.asyncio
async def test_folder_members_group_name(client: AsyncClient) -> None:
    """§2.3:sensitive folder 成员列表(/members)的组主体显示组名。"""
    gname = _uniq("grp_sens")
    gid = await _create_group(client, gname, [OUTSIDER_ID])
    r = await client.get(
        "/api/v1/folders", params={"project_id": PROJECT_WEDDING}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 200
    sens = next(f for f in r.json() if f["is_sensitive"])
    try:
        inv = await client.post(
            f"/api/v1/folders/{sens['id']}/invite",
            json={"group_id": gid, "level": "viewer"},
            headers=_h(EVAN_ID),
        )
        assert inv.status_code == 204, inv.text
        r2 = await client.get(f"/api/v1/folders/{sens['id']}/members", headers=_h(EVAN_ID))
        assert r2.status_code == 200
        m = next(x for x in r2.json() if x["subject"] == f"group:{gid}#member")
        assert m["name"] == gname
    finally:
        await client.delete(
            f"/api/v1/folders/{sens['id']}/invite",
            params={"subject": f"group:{gid}#member", "level": "viewer",
                    "permanent": "true"},
            headers=_h(EVAN_ID),
        )
        await client.delete(f"/api/v1/admin/directory/groups/{gid}", headers=_h(EVAN_ID))


@pytest.mark.asyncio
async def test_members_legacy_non_uuid_group_fallback(client: AsyncClient) -> None:
    """§2.3 边界①:seed 写入的存量非 UUID 组主体 group:grp_editors#member 本就
    在 PROJECT_EVENT 成员列表里 → name 为 id 兜底值 "grp_editors…"(新格式,
    无「用户组」前缀),_parse_uuids 容错路径直拍,接口不 500。"""
    r = await client.get(f"/api/v1/projects/{PROJECT_EVENT}/members", headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    grp = next(m for m in r.json() if m["subject"] == "group:grp_editors#member")
    assert grp["name"] == "grp_editors…"


@pytest.mark.asyncio
async def test_members_deleted_group_tuple_fallback(client: AsyncClient) -> None:
    """§2.3 边界②:组删除后 project 上的 group:<gid>#member tuple 残留
    (ADR-0007 惯例不回收)→ name 回退 gid[:12]+…,接口不 500。"""
    gid = await _create_group(client, _uniq("grp_dead"), [OUTSIDER_ID])
    add = await client.post(
        f"/api/v1/projects/{PROJECT_EVENT}/members",
        json={"group_id": gid, "roles": ["viewer"]},
        headers=_h(EVAN_ID),
    )
    assert add.status_code == 204, add.text
    # 删组:组 member tuple 被清理,project 上的 subject 引用按惯例不回收
    dg = await client.delete(f"/api/v1/admin/directory/groups/{gid}", headers=_h(EVAN_ID))
    assert dg.status_code == 200, dg.text

    r = await client.get(f"/api/v1/projects/{PROJECT_EVENT}/members", headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    dead = next(m for m in r.json() if m["subject"] == f"group:{gid}#member")
    assert dead["name"] == gid[:12] + "…"

    # 清场:撤掉残留 tuple
    rev = await client.delete(
        f"/api/v1/projects/{PROJECT_EVENT}/members",
        params={"subject": f"group:{gid}#member", "role": "viewer"},
        headers=_h(EVAN_ID),
    )
    assert rev.status_code == 204, rev.text


@pytest.mark.asyncio
async def test_remove_member_stale_revoke_idempotent_204(client: AsyncClient) -> None:
    """§1.2 幂等撤销:同一 subject 同一 role 撤两次,第二次(stale 客户端重复
    撤销,被撤 tuple 本已不存在)也 204 no-op,不再裸 500;admin / viewer
    两角色各验一遍(语义对所有角色统一)。"""
    gid = await _create_group(client, _uniq("grp_stale"), [EVAN_ID])
    try:
        add = await client.post(
            f"/api/v1/projects/{PROJECT_EVENT}/members",
            json={"group_id": gid, "roles": ["viewer", "admin"]},
            headers=_h(EVAN_ID),
        )
        assert add.status_code == 204, add.text

        for role in ("viewer", "admin"):
            params = {"subject": f"group:{gid}#member", "role": role}
            rev1 = await client.delete(
                f"/api/v1/projects/{PROJECT_EVENT}/members",
                params=params, headers=_h(EVAN_ID),
            )
            assert rev1.status_code == 204, rev1.text
            rev2 = await client.delete(
                f"/api/v1/projects/{PROJECT_EVENT}/members",
                params=params, headers=_h(EVAN_ID),
            )
            assert rev2.status_code == 204, rev2.text
    finally:
        await client.delete(f"/api/v1/admin/directory/groups/{gid}", headers=_h(EVAN_ID))


@pytest.mark.asyncio
async def test_project_member_unknown_subject_400(client: AsyncClient) -> None:
    """存在性校验(与 create_project 的 initial_grants 前置校验同款语义):
    形状合法的随机 UUID 也必须 400,否则 OpenFGA 里留下幽灵 tuple ——
    user 须存在且 is_active、group 须存在,detail 指明 user/group + id。"""
    base = f"/api/v1/projects/{PROJECT_EVENT}/members"
    ghost = str(uuid.uuid4())

    r1 = await client.post(
        base, json={"user_id": ghost, "roles": ["viewer"]}, headers=_h(EVAN_ID),
    )
    assert r1.status_code == 400, r1.text
    assert "user" in r1.json()["detail"] and ghost in r1.json()["detail"], r1.text

    r2 = await client.post(
        base, json={"group_id": ghost, "roles": ["viewer"]}, headers=_h(EVAN_ID),
    )
    assert r2.status_code == 400, r2.text
    assert "group" in r2.json()["detail"] and ghost in r2.json()["detail"], r2.text
