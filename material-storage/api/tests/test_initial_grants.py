"""批次二(C-Step1)initial_grants 创建时直通 — 集成测试,跑在 ms-api 容器里。

对应方案:`rushes-spec/material-storage/project-grant-templates-plan.md` §3.1(API 契约)、
§3.3(测试清单);接口定义见 `docs/qdev/2026-09-30-project-grant-templates.md`「接口定义」。

契约要点(方案 §3.1,错误语义写死):
  - POST /projects 新增可选 `initial_grants: [{kind: "user"|"group", id: UUID, roles}]`
  - 前置校验在建项目之前(原子):条数 ≤50(超出 422)→ payload 内 (kind,id) 重复 400
    → 逐条查 user(active)/group 存在性,任一不满足 400(指明第几条、什么主体);
    roles 空数组 / 非法值 → 422(Pydantic min_length=1 + Literal)
  - 写入幂等:is_already_exists_error 跳过(admin_user_id 与 initial_grants 重复授
    admin 是合理输入,不报错)
  - 不传 / 空 = 现行为完全不变(兼容)

预期前置(同 test_v4_permissions.py):
  1. seed_demo_data.py 已跑过(Evan = 真 user + org admin;outsider = fake)
  2. OpenFGA store / model 已 push
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
    return f"ig-{uuid.uuid4().hex[:12]}"


# ─── 测试内现建辅助(seed 脚本不建 groups 表数据,不存在现成组)────────────────
async def _create_group(client: AsyncClient, prefix: str = "ig_grp") -> str:
    """现建用户组(照 test_directory.py 的 POST /admin/directory/groups 写法)→ gid。"""
    r = await client.post(
        "/api/v1/admin/directory/groups",
        json={"name": _uniq(prefix), "description": "initial_grants 测试组"},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text
    return r.json()["id"]


async def _add_group_member(client: AsyncClient, gid: str, uid: str) -> None:
    r = await client.post(
        f"/api/v1/admin/directory/groups/{gid}/members",
        json={"user_id": uid},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text


async def _create_user(client: AsyncClient, prefix: str = "ig_user") -> str:
    """现建 active 本地用户 → users.id。"""
    uname = _uniq(prefix)
    r = await client.post(
        "/api/v1/admin/directory/users",
        json={"username": uname, "name": f"IG {prefix}"},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text
    return r.json()["id"]


async def _create_project(
    client: AsyncClient,
    *,
    initial_grants: list[dict] | None = None,
    admin_user_id: str = EVAN_ID,
) -> dict:
    """Evan 建项目(系统 admin 可调);code/name 随机防重跑冲突。返回响应 json。"""
    body: dict = {
        "code": _project_code(),
        "name": _uniq("初始授权项目"),
        "minio_bucket": "ms-dev",
        "admin_user_id": admin_user_id,
    }
    if initial_grants is not None:
        body["initial_grants"] = initial_grants
    r = await client.post("/api/v1/projects", json=body, headers=_h(EVAN_ID))
    assert r.status_code == 201, r.text
    return r.json()


# ─── 1. 生效性:组 uploader + user downloader(方案 §3.3 第 1 条)──────────────
@pytest.mark.asyncio
async def test_initial_grants_take_effect(client: AsyncClient, app_with_lifespan) -> None:
    """建项目带 initial_grants=[{group, uploader}, {user, downloader}] → 201。

    断言(照既有 check 断言思路,HTTP 行为 + OpenFGA check 双验证):
    - 组内成员(outsider)对该项目获得 can_upload:POST /folders 建根目录成功
      (folder 创建门槛 = project can_upload,照 test_folder_delete_uploader_can_delete
      的显式 uploader 验证写法),且 perms.check(user:outsider, can_upload, project) 为真;
    - 单个 user(现建用户)获得 can_download:perms.check 对项目下 folder 的
      can_download 为真(project downloader → folder can_download 继承),
      GET /projects/{id} 的 my_roles 含 downloader;
    - 角色不串:uploader 组成员无 can_download,downloader 用户无 can_upload。
    """
    perms = app_with_lifespan.state.permissions

    # 现建组(挂 outsider)+ 现建 downloader 用户
    gid = await _create_group(client)
    await _add_group_member(client, gid, OUTSIDER_ID)
    duid = await _create_user(client, "ig_downloader")

    proj = await _create_project(client, initial_grants=[
        {"kind": "group", "id": gid, "roles": ["uploader"]},
        {"kind": "user", "id": duid, "roles": ["downloader"]},
    ])
    pid = proj["id"]

    # ── 组成员 can_upload 生效:HTTP 行为验证(outsider 能在项目下建根目录)──
    r_folder = await client.post(
        "/api/v1/folders",
        json={"project_id": pid, "name": _uniq("ig_grp_folder")},
        headers=_h(OUTSIDER_ID),
    )
    assert r_folder.status_code == 201, (
        f"组 uploader 成员应能在项目下建目录(can_upload 生效): {r_folder.text}"
    )
    fid = r_folder.json()["id"]

    # OpenFGA check 间接验证(同 test_directory.py 用 app.state.permissions 的思路)
    assert await perms.check(
        user_subject=f"user:{OUTSIDER_ID}", relation="can_upload",
        object_type="project", object_id=pid,
    ), "组成员应对项目有 can_upload(uploader)"

    # ── user can_download 生效:folder 继承 project downloader ──
    assert await perms.check(
        user_subject=f"user:{duid}", relation="can_download",
        object_type="folder", object_id=fid,
    ), "downloader 用户应对项目 folder 有 can_download"
    r_me = await client.get(f"/api/v1/projects/{pid}", headers=_h(duid))
    assert r_me.status_code == 200, r_me.text
    assert "downloader" in r_me.json()["my_roles"], r_me.json()["my_roles"]

    # ── 角色不串 ──
    assert not await perms.check(
        user_subject=f"user:{OUTSIDER_ID}", relation="can_download",
        object_type="folder", object_id=fid,
    ), "uploader 不应获得 can_download"
    assert not await perms.check(
        user_subject=f"user:{duid}", relation="can_upload",
        object_type="project", object_id=pid,
    ), "downloader 不应获得 can_upload"


# ─── 2. 兼容:不带 initial_grants 的旧调用不变(方案 §3.3 第 2 条)─────────────
@pytest.mark.asyncio
async def test_create_project_without_initial_grants_compat(client: AsyncClient) -> None:
    """不带 initial_grants 建项目 → 201,现行为不变:除 bootstrap 的创建者 admin
    外无任何初始授权(outsider 对该 private 项目仍 403)。"""
    proj = await _create_project(client)  # 不带 initial_grants 字段
    pid = proj["id"]

    # Evan(创建者兼 admin)正常可见
    r = await client.get(f"/api/v1/projects/{pid}", headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    assert "admin" in r.json()["my_roles"]

    # outsider 无任何 tuple → private 项目 403(证明没有发生额外授权)
    r2 = await client.get(f"/api/v1/projects/{pid}", headers=_h(OUTSIDER_ID))
    assert r2.status_code == 403


# ─── 3. 主体存在性校验:400(方案 §3.1 前置校验 / §3.3 第 3 条)───────────────
@pytest.mark.asyncio
async def test_initial_grants_unknown_subjects_400(client: AsyncClient) -> None:
    """未知 user id / 不存在的 group id → 400(id 传合法 UUID 形状、查无此主体;
    非法 UUID 形状会走 Pydantic 422,不是本条语义)。错误应指明该主体。"""
    ghost_user = str(uuid.uuid4())
    r = await client.post(
        "/api/v1/projects",
        json={
            "code": _project_code(), "name": _uniq("未知用户"), "minio_bucket": "ms-dev",
            "admin_user_id": EVAN_ID,
            "initial_grants": [{"kind": "user", "id": ghost_user, "roles": ["viewer"]}],
        },
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 400, r.text
    assert ghost_user in r.text, f"400 应指明不存在的主体: {r.text}"

    ghost_group = str(uuid.uuid4())
    r2 = await client.post(
        "/api/v1/projects",
        json={
            "code": _project_code(), "name": _uniq("未知组"), "minio_bucket": "ms-dev",
            "admin_user_id": EVAN_ID,
            "initial_grants": [{"kind": "group", "id": ghost_group, "roles": ["viewer"]}],
        },
        headers=_h(EVAN_ID),
    )
    assert r2.status_code == 400, r2.text
    assert ghost_group in r2.text, f"400 应指明不存在的主体: {r2.text}"


# ─── 4. 形状校验:422(方案 §3.1:roles min_length=1 + Literal;条数 ≤50)──────
@pytest.mark.asyncio
async def test_initial_grants_shape_422(client: AsyncClient) -> None:
    """roles 空数组 → 422;initial_grants 超 50 条 → 422;非法角色值 → 422。

    条数上限的 51 条用随机 UUID:方案 §3.1 的前置校验顺序为 条数(422)→
    重复(400)→ 存在性(400),超限应先于存在性被拦。
    """
    base = {
        "code": _project_code(), "name": _uniq("形状校验"), "minio_bucket": "ms-dev",
        "admin_user_id": EVAN_ID,
    }

    # roles 空数组(Pydantic min_length=1)
    r = await client.post("/api/v1/projects", json={
        **base,
        "initial_grants": [{"kind": "user", "id": OUTSIDER_ID, "roles": []}],
    }, headers=_h(EVAN_ID))
    assert r.status_code == 422, r.text

    # 超 50 条(51 条)
    r2 = await client.post("/api/v1/projects", json={
        **base,
        "initial_grants": [
            {"kind": "user", "id": str(uuid.uuid4()), "roles": ["viewer"]}
            for _ in range(51)
        ],
    }, headers=_h(EVAN_ID))
    assert r2.status_code == 422, r2.text

    # 非法角色值(Literal 之外)
    r3 = await client.post("/api/v1/projects", json={
        **base,
        "initial_grants": [{"kind": "user", "id": OUTSIDER_ID, "roles": ["superuser"]}],
    }, headers=_h(EVAN_ID))
    assert r3.status_code == 422, r3.text


# ─── 5. payload 内 (kind,id) 重复 → 400(方案 §3.1 前置校验)─────────────────
@pytest.mark.asyncio
async def test_initial_grants_duplicate_subject_400(client: AsyncClient) -> None:
    """同一 (kind,id) 在 payload 内出现两次(即便 roles 不同)→ 400,
    不允许静默合并或裸 IntegrityError。"""
    r = await client.post(
        "/api/v1/projects",
        json={
            "code": _project_code(), "name": _uniq("重复主体"), "minio_bucket": "ms-dev",
            "admin_user_id": EVAN_ID,
            "initial_grants": [
                {"kind": "user", "id": OUTSIDER_ID, "roles": ["viewer"]},
                {"kind": "user", "id": OUTSIDER_ID, "roles": ["downloader"]},
            ],
        },
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 400, r.text


# ─── 6. admin_user_id 与 initial_grants 重叠 → 幂等 201(方案 §3.1 第 3 步)────
@pytest.mark.asyncio
async def test_initial_grants_admin_overlap_idempotent_201(client: AsyncClient) -> None:
    """admin_user_id 同时出现在 initial_grants 授 admin → 201 不报错:
    bootstrap 已写过创建者 admin tuple,initial_grants 再写必须按
    is_already_exists_error 幂等跳过(重复 tuple 不算错)。"""
    proj = await _create_project(client, initial_grants=[
        {"kind": "user", "id": EVAN_ID, "roles": ["admin", "viewer"]},
    ])
    pid = proj["id"]

    # Evan 仍是 admin(幂等跳过后原 tuple 完好)
    r = await client.get(f"/api/v1/projects/{pid}", headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    assert "admin" in r.json()["my_roles"], r.json()["my_roles"]

    # 同理:group 主体重复授 admin 亦不报错(批次一放开后 group#member admin 合法)
    gid = await _create_group(client)
    r2 = await client.post(
        "/api/v1/projects",
        json={
            "code": _project_code(), "name": _uniq("组admin幂等"), "minio_bucket": "ms-dev",
            "admin_user_id": EVAN_ID,
            "initial_grants": [{"kind": "group", "id": gid, "roles": ["admin"]}],
        },
        headers=_h(EVAN_ID),
    )
    assert r2.status_code == 201, r2.text
