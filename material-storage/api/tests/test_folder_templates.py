"""目录模板模块(folder templates)集成测试 — 跑在 ms-api 容器里(`docker exec ms-api pytest`)。

对应权威方案:`rushes-spec/material-storage/folder-templates-plan.md`
§4.1(4 个新端点 + 路径校验七条规则)、§4.2(POST /projects 挂接)、§4.3(组开关)、
§7(本文件用例清单);实施派发口径见 `docs/qdev/2026-10-10-folder-templates.md`。

契约要点(方案 §4;后端并行开发中,本文件按契约编写,两处冲突以方案为准):
  - GET    /api/v1/admin/folder-templates
           → 200 [{id, name, description, entry_count, entries: [{path}]}](按 name 排序)
  - POST   {name(1-128), description?(≤1024), entries: [{path}]}(1..200 条)→ 201
           返回与列表项同形的单对象;重名 409;entries 空/超 200 条/路径非法/重复
           path/去重后节点总数 >400 → 422
  - PATCH  /{id}:name/description/entries 均可选;description 显式 null=清空
           (model_fields_set);entries 未传=不改,传则全量替换且 ≥1 条;改名撞名 409
  - DELETE /{id} → 204 级联删 entries;不存在 404
  - POST /projects 增可选 folder_template_id:不存在/跨 org → 400;应用=把条目物化
    为 folders 行(前缀重叠幂等复用);project_created details 增 folder_template_id /
    created_folder_count(未选模板省略这些键);另记 folder_template_applied 一条
  - 组开关:组 POST 增 can_manage_folder_templates: bool = False;PATCH tri-state
    (None=不动 / true=写 / false=删);DirectoryGroupOut 回显;/me 增
    is_folder_template_manager

预期前置:
  1. seed_demo_data.py 已跑过(Evan = 真 user + org admin;outsider = fake 零权限)
  2. 本地隔离栈已 `bash api/scripts/local_up.sh --refresh-model` 重推含
     folder_template_manager relation 的 FGA model(⚠ 勿跑 openfga_write_model.sh,
     那是 hh2 远端部署脚本)
  3. env=dev(允许 X-User-Id header 模拟身份)

⚠ 本文件随 WP-3「只写不跑」交付:后端并行开发中,由 PM 在隔离栈统一执行。
"""
from __future__ import annotations

import uuid

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import create_app

# seed 写死的真 user / fake outsider / public 种子项目(同 test_v4_permissions.py)
EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"
OUTSIDER_ID = "00000000-0000-0000-0000-0000000000aa"
PROJECT_EVENT = "11111111-1111-1111-1111-111111111103"   # public,seed 建


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


# ─── 测试内现建辅助(seed 不建 groups 表数据;模板/项目 helper 照既有文件)──────
async def _create_user(client: AsyncClient, prefix: str = "ft_user") -> str:
    """现建 active 本地用户 → users.id(照 test_default_template.py 的写法)。"""
    uname = _uniq(prefix)
    r = await client.post(
        "/api/v1/admin/directory/users",
        json={"username": uname, "name": f"FT {prefix}"},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text
    return r.json()["id"]


async def _create_group(
    client: AsyncClient, *, prefix: str = "ft_grp",
    can_manage_folder_templates: bool = False,
) -> str:
    """现建用户组(照 test_directory.py 写法),可携带 can_manage_folder_templates → gid。"""
    body: dict = {"name": _uniq(prefix), "description": "folder_templates 测试组"}
    if can_manage_folder_templates:
        body["can_manage_folder_templates"] = True
    r = await client.post("/api/v1/admin/directory/groups", json=body, headers=_h(EVAN_ID))
    assert r.status_code == 201, r.text
    return r.json()["id"]


async def _add_group_member(client: AsyncClient, gid: str, uid: str) -> None:
    r = await client.post(
        f"/api/v1/admin/directory/groups/{gid}/members",
        json={"user_id": uid}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text


async def _patch_group_flag(
    client: AsyncClient, gid: str, value: bool | None,
) -> None:
    """PATCH 组的 can_manage_folder_templates(tri-state:None=不动 / true / false)。"""
    r = await client.patch(
        f"/api/v1/admin/directory/groups/{gid}",
        json={"can_manage_folder_templates": value}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text


async def _get_group_by_id(client: AsyncClient, gid: str) -> dict | None:
    """组列表回显里按 id 取回该组(验 DirectoryGroupOut.can_manage_folder_templates)。"""
    r = await client.get("/api/v1/admin/directory/groups", headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    return next((g for g in r.json() if g["id"] == gid), None)


async def _delete_group(client: AsyncClient, gid: str) -> None:
    """删组(组 member tuple 与组级 flag tuple 由删组清理,B9)。"""
    r = await client.delete(f"/api/v1/admin/directory/groups/{gid}", headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text


def _entries(*paths: str) -> list[dict]:
    return [{"path": p} for p in paths]


async def _post_template(
    client: AsyncClient,
    *,
    name: str,
    entries: list[dict],
    description: str | None = None,
    headers: dict[str, str] | None = None,
) -> dict:
    """POST 建模板 → 201 返回与列表项同形的单对象(契约 §4.1)。"""
    body: dict = {"name": name, "entries": entries}
    if description is not None:
        body["description"] = description
    r = await client.post(
        "/api/v1/admin/folder-templates", json=body,
        headers=headers if headers is not None else _h(EVAN_ID),
    )
    assert r.status_code == 201, r.text
    return r.json()


async def _get_template_by_name(client: AsyncClient, name: str) -> dict | None:
    r = await client.get("/api/v1/admin/folder-templates", headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    for t in r.json():
        if t["name"] == name:
            return t
    return None


async def _delete_template(client: AsyncClient, tid: str) -> None:
    r = await client.delete(f"/api/v1/admin/folder-templates/{tid}", headers=_h(EVAN_ID))
    assert r.status_code == 204, r.text


def _project_code() -> str:
    """项目 code 唯一(projects_code_key);pattern 限 ^[a-z0-9][a-z0-9\\-]*$。"""
    return f"ft-{uuid.uuid4().hex[:12]}"


async def _create_project(
    client: AsyncClient, *, folder_template_id: str | None = None,
) -> dict:
    """Evan(系统 admin)建项目;不带 folder_template_id = 现状零回归路径。"""
    body: dict = {
        "code": _project_code(),
        "name": _uniq("目录模板项目"),
        "minio_bucket": "ms-dev",
        "admin_user_id": EVAN_ID,
    }
    if folder_template_id is not None:
        body["folder_template_id"] = folder_template_id
    r = await client.post("/api/v1/projects", json=body, headers=_h(EVAN_ID))
    assert r.status_code == 201, r.text
    return r.json()


async def _archive_project(pid: str) -> None:
    """归档自建项目(收尾专用;照 test_default_template.py):项目无删除 API,
    is_archived=True 后不再进 GET /projects 列表,防多轮累积挤占第一页。"""
    import warnings

    from sqlalchemy import update

    from app.db.session import get_sessionmaker
    from app.db.tables import Project

    try:
        async with get_sessionmaker()() as db:
            await db.execute(
                update(Project)
                .where(Project.id == uuid.UUID(pid))
                .values(is_archived=True)
            )
            await db.commit()
    except Exception as e:
        warnings.warn(f"archive project {pid} failed: {e}; 残留活跃项目", stacklevel=2)


async def _create_org_row() -> str:
    """直插第二个 organization 行(跨 org 用例;照 test_default_template.py 先例)。
    org 行 FK RESTRICT 且无删除 API,按每轮唯一 id 保留。"""
    from sqlalchemy import insert

    from app.db.session import get_sessionmaker
    from app.db.tables import Organization

    oid = uuid.uuid4()
    async with get_sessionmaker()() as db:
        await db.execute(insert(Organization).values(
            id=oid, name=_uniq("ft_org2"), feishu_tenant_key=_uniq("ft_tk2"),
        ))
        await db.commit()
    return str(oid)


async def _set_template_org(template_id: str, org_id: str) -> None:
    """直改模板 organization_id 指向第二个 org(跨 org 用例)。

    ⚠ 此直改是必须的,勿「顺手修掉」:POST/PATCH 模板的服务端 organization_id
    只取 default org(方案 §4.1),第二个 org 的模板无法经 API 产生;而项目创建
    的跨 org 校验要求模板行真实挂在第二个 org 上。
    """
    from sqlalchemy import update

    from app.db.session import get_sessionmaker
    from app.db.tables import ProjectFolderTemplate

    async with get_sessionmaker()() as db:
        await db.execute(
            update(ProjectFolderTemplate)
            .where(ProjectFolderTemplate.id == uuid.UUID(template_id))
            .values(organization_id=uuid.UUID(org_id))
        )
        await db.commit()


async def _folders_by_prefix(pid: str) -> dict:
    """项目全部 folders 行,按 minio_prefix 索引(DB 直查:folders API 走 FGA
    过滤,断言「恰好 N 个夹」用全量集合更可靠)。"""
    from sqlalchemy import select

    from app.db.session import get_sessionmaker
    from app.db.tables import Folder

    async with get_sessionmaker()() as db:
        rows = (await db.execute(
            select(Folder).where(Folder.project_id == uuid.UUID(pid))
        )).scalars().all()
        return {f.minio_prefix: f for f in rows}


async def _audit_events(
    client: AsyncClient, event_type: str, project_id: str | None = None,
) -> list[dict]:
    """按 event_type(可选 + target_project_id)拉 audit,返回原始条目列表。"""
    params: dict = {"event_type": event_type, "limit": 500}
    if project_id is not None:
        params["project_id"] = project_id
    r = await client.get("/api/v1/admin/audit", params=params, headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    return r.json()


# ══════════════════════════════════════════════════════════════════════════════
# 一、模板 CRUD(方案 §7 第一组)
# ══════════════════════════════════════════════════════════════════════════════


@pytest.mark.asyncio
async def test_template_crud_cycle(client: AsyncClient) -> None:
    """POST 201(与列表项同形)→ GET 列表含条目 → PATCH 全量替换 entries →
    DELETE 204 级联删(GET 不在、重复 DELETE 404)。"""
    name = _uniq("ft_crud")
    tpl = await _post_template(
        client, name=name, description="CRUD cycle 用",
        entries=_entries("素材", "素材/视频", "素材/视频/原始", "交付"),
    )
    tid = tpl["id"]
    deleted = False
    try:
        assert tpl["name"] == name
        assert tpl["description"] == "CRUD cycle 用"
        assert tpl["entry_count"] == 4
        assert sorted(e["path"] for e in tpl["entries"]) == [
            "交付", "素材", "素材/视频", "素材/视频/原始",
        ]

        # GET 列表:同形字段 + 全量 entries(供 NewProjectModal 预览)
        got = await _get_template_by_name(client, name)
        assert got is not None and got["id"] == tid
        assert got["entry_count"] == 4
        assert sorted(e["path"] for e in got["entries"]) == [
            "交付", "素材", "素材/视频", "素材/视频/原始",
        ]

        # PATCH:改名 + description + entries 全量替换
        new_name = _uniq("ft_crud_renamed")
        r = await client.patch(
            f"/api/v1/admin/folder-templates/{tid}",
            json={"name": new_name, "description": "替换后",
                  "entries": _entries("成品", "成品/字幕")},
            headers=_h(EVAN_ID),
        )
        assert r.status_code == 200, r.text
        after = await _get_template_by_name(client, new_name)
        assert after is not None and after["id"] == tid
        assert after["description"] == "替换后"
        assert after["entry_count"] == 2
        assert sorted(e["path"] for e in after["entries"]) == ["成品", "成品/字幕"]
        assert await _get_template_by_name(client, name) is None, "旧 name 不应再命中"

        # DELETE → 204;级联删(GET 列表无);重复删 → 404
        r2 = await client.delete(f"/api/v1/admin/folder-templates/{tid}", headers=_h(EVAN_ID))
        assert r2.status_code == 204, r2.text
        deleted = True
        assert await _get_template_by_name(client, new_name) is None
        r3 = await client.delete(f"/api/v1/admin/folder-templates/{tid}", headers=_h(EVAN_ID))
        assert r3.status_code == 404, r3.text
    finally:
        if tid and not deleted:
            await _delete_template(client, tid)


@pytest.mark.asyncio
async def test_template_duplicate_name_409(client: AsyncClient) -> None:
    """同 org 重名 → 409(POST 撞名;PATCH 改名撞已有模板;PATCH 改回自身原名放行)。"""
    name_a = _uniq("ft_name_a")
    name_b = _uniq("ft_name_b")
    a = await _post_template(client, name=name_a, entries=_entries("素材"))
    b = await _post_template(client, name=name_b, entries=_entries("素材"))
    try:
        # POST 撞名
        r = await client.post(
            "/api/v1/admin/folder-templates",
            json={"name": name_a, "entries": _entries("素材")},
            headers=_h(EVAN_ID),
        )
        assert r.status_code == 409, r.text

        # PATCH 改名撞 a → 409
        r2 = await client.patch(
            f"/api/v1/admin/folder-templates/{b['id']}",
            json={"name": name_a}, headers=_h(EVAN_ID),
        )
        assert r2.status_code == 409, r2.text

        # PATCH 改回自身原名 → 放行
        r3 = await client.patch(
            f"/api/v1/admin/folder-templates/{b['id']}",
            json={"name": name_b}, headers=_h(EVAN_ID),
        )
        assert r3.status_code == 200, r3.text
        still = await _get_template_by_name(client, name_b)
        assert still is not None and still["id"] == b["id"]
    finally:
        await _delete_template(client, a["id"])
        await _delete_template(client, b["id"])


@pytest.mark.asyncio
async def test_template_empty_entries_422(client: AsyncClient) -> None:
    """entries 空 → 422(POST 与 PATCH 同;「清空模板」语义 = 删模板,§11)。"""
    r = await client.post(
        "/api/v1/admin/folder-templates",
        json={"name": _uniq("ft_empty"), "entries": []},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 422, r.text

    # PATCH 空 entries → 422,原条目不被清掉
    name = _uniq("ft_patch_empty")
    tpl = await _post_template(client, name=name, entries=_entries("素材"))
    try:
        r2 = await client.patch(
            f"/api/v1/admin/folder-templates/{tpl['id']}",
            json={"entries": []}, headers=_h(EVAN_ID),
        )
        assert r2.status_code == 422, r2.text
        kept = await _get_template_by_name(client, name)
        assert kept is not None and kept["entry_count"] == 1, (
            "PATCH entries: [] 422 后原条目不应被改动"
        )
    finally:
        await _delete_template(client, tpl["id"])


@pytest.mark.asyncio
async def test_template_over_200_entries_422(client: AsyncClient) -> None:
    """201 条一级路径 → 422(条数上限 200;各 1 节点共 201 节点 ≤400,
    不会先撞节点数规则,钉死拦的是条数)。"""
    entries = [{"path": f"dir{i}"} for i in range(201)]
    r = await client.post(
        "/api/v1/admin/folder-templates",
        json={"name": _uniq("ft_too_many"), "entries": entries},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 422, r.text


@pytest.mark.asyncio
async def test_template_duplicate_path_422(client: AsyncClient) -> None:
    """payload 内 path 重复 → 422,错误信息指明重复值(方案 §4.1 规则 6)。"""
    r = await client.post(
        "/api/v1/admin/folder-templates",
        json={"name": _uniq("ft_dup_path"),
              "entries": _entries("素材", "素材/视频", "素材")},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 422, r.text
    assert "素材" in r.text, f"422 应指明重复的 path 值: {r.text}"


@pytest.mark.asyncio
async def test_template_node_budget_over_400_422(client: AsyncClient) -> None:
    """去重后节点总数 >400 → 422(方案 §4.1 规则 7)。

    构造:150 条首段互异的三段路径 segNNN/a/b → 每条展开 3 个节点、互不共享
    = 450 节点 >400;150 条 ≤200 不触条数规则(勿用 201 条一级路径——会先撞
    条数且 201 节点本就 ≤400)。
    """
    entries = [{"path": f"seg{i:03d}/a/b"} for i in range(150)]
    r = await client.post(
        "/api/v1/admin/folder-templates",
        json={"name": _uniq("ft_node_budget"), "entries": entries},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 422, r.text


@pytest.mark.asyncio
async def test_template_invalid_paths_422(client: AsyncClient) -> None:
    """路径校验逐项 422(方案 §4.1 规则 1-5;不做静默归一化,非法即 422)。

    每个构造只命中目标规则:段长 ≤255、深度 ≤10、总长 ≤600 字符且 ≤900 字节,
    排除其他分支抢先 422 的干扰。
    """
    cases: list[tuple[str, str]] = [
        # 规则 2:`..` 段 / 空段(连续 //)
        ("`..` 段", "素材/../视频"),
        ("空段 a//b", "素材//视频"),
        # 规则 1:以 / 开头或结尾(显式拒绝,素材/ 与 素材 必须判非法而非等价)
        ("首 `/`", "/素材"),
        ("尾 `/`", "素材/"),
        # 规则 2:段含 `\`
        ("段含反斜杠", "素材\\视频"),
        # 规则 3:段首尾空白
        ("段尾空白", "素材 /视频"),
        # 规则 4:单段 256 字符(>255;总长 256 仍在 600/900 内)
        ("单段 256 字符", "a" * 256),
        # 规则 5:深度 11 段(>10;总长 21 字符)
        ("深度 11 段", "/".join(["s"] * 11)),
        # 规则 5:总长 >600 字符——多段构造(200+200+199+2 分隔=601;单段 601
        # 会先撞段长规则),每段 ≤255、深度 3、601 字节 ≤900
        ("总长 601 字符", "/".join(["a" * 200, "a" * 200, "a" * 199])),
        # 规则 5:总长 >900 字节——多段 CJK 构造:4 段、每段 76 个 CJK(每段 76 字符
        # ≤255、228 字节 ≤255)= 912 CJK 字节 + 3 个分隔符 >900;总字符
        # 307 ≤600、深度 4 ≤10(勿用单段 301 个 CJK——>255 字符会先撞段长规则)
        ("总长超 900 字节", "/".join(["目" * 76] * 4)),
    ]
    for reason, path in cases:
        r = await client.post(
            "/api/v1/admin/folder-templates",
            json={"name": _uniq("ft_bad_path"), "entries": [{"path": path}]},
            headers=_h(EVAN_ID),
        )
        assert r.status_code == 422, f"{reason}(path={path!r})应 422: {r.text}"


@pytest.mark.asyncio
async def test_patch_entries_omitted_keeps_entries(client: AsyncClient) -> None:
    """PATCH 不传 entries(只改描述)→ 条目不变(对齐 grant-templates
    items=None 不改先例;entries 是「未传=不改,传则全量替换」)。"""
    name = _uniq("ft_keep")
    tpl = await _post_template(
        client, name=name, entries=_entries("素材", "素材/视频"),
    )
    try:
        r = await client.patch(
            f"/api/v1/admin/folder-templates/{tpl['id']}",
            json={"description": "只改描述"}, headers=_h(EVAN_ID),
        )
        assert r.status_code == 200, r.text
        kept = await _get_template_by_name(client, name)
        assert kept is not None and kept["entry_count"] == 2
        assert sorted(e["path"] for e in kept["entries"]) == ["素材", "素材/视频"]
    finally:
        await _delete_template(client, tpl["id"])


@pytest.mark.asyncio
async def test_patch_description_tri_state(client: AsyncClient) -> None:
    """PATCH description 三态(钉死 §4.1 的 model_fields_set 语义,防实现写成
    None=不改):传值 → 更新;不传 → 不变;显式 null → 清空。"""
    name = _uniq("ft_desc")
    tpl = await _post_template(
        client, name=name, description="原始描述", entries=_entries("素材"),
    )
    try:
        # 传值 → 更新
        r = await client.patch(
            f"/api/v1/admin/folder-templates/{tpl['id']}",
            json={"description": "更新一"}, headers=_h(EVAN_ID),
        )
        assert r.status_code == 200, r.text
        got = await _get_template_by_name(client, name)
        assert got is not None and got["description"] == "更新一"

        # 不带 description 字段 → 原值不变
        r2 = await client.patch(
            f"/api/v1/admin/folder-templates/{tpl['id']}",
            json={"name": name}, headers=_h(EVAN_ID),
        )
        assert r2.status_code == 200, r2.text
        kept = await _get_template_by_name(client, name)
        assert kept is not None and kept["description"] == "更新一", (
            "PATCH 不带 description 字段不应改动原值"
        )

        # 显式 "description": null → 清空
        r3 = await client.patch(
            f"/api/v1/admin/folder-templates/{tpl['id']}",
            json={"description": None}, headers=_h(EVAN_ID),
        )
        assert r3.status_code == 200, r3.text
        cleared = await _get_template_by_name(client, name)
        assert cleared is not None and cleared["description"] is None, (
            "显式 null 应清空 description(前端「清空描述」依赖此语义)"
        )
    finally:
        await _delete_template(client, tpl["id"])


@pytest.mark.asyncio
async def test_template_patch_delete_missing_404(client: AsyncClient) -> None:
    """PATCH/DELETE 不存在的 id → 404。"""
    ghost = str(uuid.uuid4())
    r = await client.patch(
        f"/api/v1/admin/folder-templates/{ghost}",
        json={"name": _uniq("ft_ghost")}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 404, r.text
    r2 = await client.delete(f"/api/v1/admin/folder-templates/{ghost}", headers=_h(EVAN_ID))
    assert r2.status_code == 404, r2.text


# ══════════════════════════════════════════════════════════════════════════════
# 二、权限(方案 §7 第二组;403 由 deps 守门抛,不写 audit——勿断言 access_denied)
# ══════════════════════════════════════════════════════════════════════════════


@pytest.mark.asyncio
async def test_creator_without_flag_get_200_write_403(client: AsyncClient) -> None:
    """无 flag 的普通 project_creator(组级 can_create_project,非 org admin):
    GET 200(读门含 project_creator 面)/ POST·PATCH·DELETE → 403(写门只认
    org admin 或 folder_template_manager flag)。"""
    uid = await _create_user(client, "ft_creator")
    gid = await _create_group(client, prefix="ft_pc")
    await _add_group_member(client, gid, uid)
    r_flag = await client.patch(
        f"/api/v1/admin/directory/groups/{gid}",
        json={"can_create_project": True}, headers=_h(EVAN_ID),
    )
    assert r_flag.status_code == 200, r_flag.text
    tpl = await _post_template(client, name=_uniq("ft_perm"), entries=_entries("素材"))
    try:
        # 读:project_creator 在读门白名单内 → 200
        r = await client.get("/api/v1/admin/folder-templates", headers=_h(uid))
        assert r.status_code == 200, r.text
        # 写:三操作全 403
        r2 = await client.post(
            "/api/v1/admin/folder-templates",
            json={"name": _uniq("ft_by_creator"), "entries": _entries("素材")},
            headers=_h(uid),
        )
        assert r2.status_code == 403, r2.text
        r3 = await client.patch(
            f"/api/v1/admin/folder-templates/{tpl['id']}",
            json={"description": "越权改"}, headers=_h(uid),
        )
        assert r3.status_code == 403, r3.text
        r4 = await client.delete(
            f"/api/v1/admin/folder-templates/{tpl['id']}", headers=_h(uid),
        )
        assert r4.status_code == 403, r4.text
    finally:
        await _delete_template(client, tpl["id"])
        await _delete_group(client, gid)


@pytest.mark.asyncio
async def test_project_admin_only_get_403(client: AsyncClient) -> None:
    """仅项目管理员(某项目 admin,非 org admin / 非 project_creator / 无 flag):
    GET → 403 —— 钉死读门 require_folder_templates_reader 不含 has_any_project_admin
    (照抄 require_admin_or_project_creator 会把读门外溢到全部项目 admin)。"""
    uid = await _create_user(client, "ft_padmin")
    r = await client.post(
        f"/api/v1/projects/{PROJECT_EVENT}/members",
        json={"user_id": uid, "roles": ["admin"]}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 204, r.text
    try:
        r2 = await client.get("/api/v1/admin/folder-templates", headers=_h(uid))
        assert r2.status_code == 403, r2.text
    finally:
        rev = await client.delete(
            f"/api/v1/projects/{PROJECT_EVENT}/members",
            params={"subject": f"user:{uid}", "role": "admin"}, headers=_h(EVAN_ID),
        )
        assert rev.status_code == 204, rev.text


@pytest.mark.asyncio
async def test_flag_only_user_get_200_post_201(client: AsyncClient) -> None:
    """仅持 flag 用户(被置 can_manage_folder_templates 的组成员,非 org admin /
    非 project_creator):GET 200 + POST 201 —— 读门必须覆盖 flag 面,
    防「能写不能读」(管理页列表加载即挂)。"""
    uid = await _create_user(client, "ft_flag")
    gid = await _create_group(client, can_manage_folder_templates=True)
    await _add_group_member(client, gid, uid)
    name = _uniq("ft_by_flag")
    tid = ""
    try:
        r = await client.get("/api/v1/admin/folder-templates", headers=_h(uid))
        assert r.status_code == 200, r.text
        created = await _post_template(
            client, name=name, entries=_entries("素材", "交付"), headers=_h(uid),
        )
        tid = created["id"]
        assert created["entry_count"] == 2
        assert await _get_template_by_name(client, name) is not None
    finally:
        if tid:
            await _delete_template(client, tid)
        await _delete_group(client, gid)


@pytest.mark.asyncio
async def test_me_flag_tri_state(client: AsyncClient) -> None:
    """/me 的 is_folder_template_manager 三态:flag 置位 → true;同组撤销 → false;
    无关联用户恒 false。auth.py /me 是手拼 dict 无 schema 约束,漏写字段不报错,
    故必须显式断言(照 test_me_evan 先例)。"""
    uid = await _create_user(client, "ft_me")
    gid = await _create_group(client, can_manage_folder_templates=True)
    await _add_group_member(client, gid, uid)
    try:
        me = await client.get("/api/v1/auth/me", headers=_h(uid))
        assert me.status_code == 200, me.text
        assert me.json()["is_folder_template_manager"] is True, me.text

        # tri-state None(不动)→ 仍 true
        await _patch_group_flag(client, gid, None)
        me2 = await client.get("/api/v1/auth/me", headers=_h(uid))
        assert me2.json()["is_folder_template_manager"] is True, me2.text

        # 撤销(false)→ false
        await _patch_group_flag(client, gid, False)
        me3 = await client.get("/api/v1/auth/me", headers=_h(uid))
        assert me3.json()["is_folder_template_manager"] is False, me3.text
    finally:
        await _delete_group(client, gid)

    # 无关联用户(outsider 无任何 org 关系)恒 false
    me_out = await client.get("/api/v1/auth/me", headers=_h(OUTSIDER_ID))
    assert me_out.status_code == 200, me_out.text
    assert me_out.json()["is_folder_template_manager"] is False, me_out.text


@pytest.mark.asyncio
async def test_group_flag_gates_member_write(client: AsyncClient) -> None:
    """组开关全链:建组置 can_manage_folder_templates=true → 组成员 POST 201 且
    组列表回显 true;PATCH tri-state None → flag 不动(成员仍可写);false →
    组成员写 403且回显 false(删组清 tuple 由删组端点兜底)。"""
    uid = await _create_user(client, "ft_switch")
    gid = await _create_group(client, can_manage_folder_templates=True)
    await _add_group_member(client, gid, uid)
    tids: list[str] = []
    try:
        # 组列表回显(方案 §4.3:_read_flag_group_ids 按 FGA tuple 真实态)
        echo = await _get_group_by_id(client, gid)
        assert echo is not None and echo["can_manage_folder_templates"] is True, echo

        # 置位组成员可写
        c1 = await _post_template(
            client, name=_uniq("ft_sw1"), entries=_entries("素材"), headers=_h(uid),
        )
        tids.append(c1["id"])

        # tri-state None → flag 不动:回显仍 true,成员再建仍 201
        await _patch_group_flag(client, gid, None)
        echo2 = await _get_group_by_id(client, gid)
        assert echo2 is not None and echo2["can_manage_folder_templates"] is True, echo2
        c2 = await _post_template(
            client, name=_uniq("ft_sw2"), entries=_entries("交付"), headers=_h(uid),
        )
        tids.append(c2["id"])

        # false → 撤权:成员写 403,回显 false
        await _patch_group_flag(client, gid, False)
        r3 = await client.post(
            "/api/v1/admin/folder-templates",
            json={"name": _uniq("ft_sw3"), "entries": _entries("素材")},
            headers=_h(uid),
        )
        assert r3.status_code == 403, r3.text
        echo3 = await _get_group_by_id(client, gid)
        assert echo3 is not None and echo3["can_manage_folder_templates"] is False, echo3
    finally:
        for tid in tids:
            await _delete_template(client, tid)
        await _delete_group(client, gid)


@pytest.mark.asyncio
async def test_org_admin_write_direct_201(client: AsyncClient) -> None:
    """org admin / system admin(Evan = default org admin)写直通 201
    (写门 is_org_admin 支线;本文件其余用例经 helper 已反复覆盖,此处显式直拍)。"""
    name = _uniq("ft_admin_direct")
    tpl = await _post_template(client, name=name, entries=_entries("素材"))
    try:
        assert await _get_template_by_name(client, name) is not None
    finally:
        await _delete_template(client, tpl["id"])


# ══════════════════════════════════════════════════════════════════════════════
# 三、项目创建应用(方案 §7 第三组)
# ══════════════════════════════════════════════════════════════════════════════


@pytest.mark.asyncio
async def test_create_project_applies_template_folders_and_fga(
    client: AsyncClient, app_with_lifespan,
) -> None:
    """带 folder_template_id 建项目 → 201;folders 表逐级就位(parent_folder_id 链
    + minio_prefix=`素材/` 式拼接);FGA parent tuple 可查(根=project:<pid>,
    子=folder:<parent_id>;read_all_tuples)。"""
    name = _uniq("ft_apply")
    tpl = await _post_template(
        client, name=name,
        entries=_entries("素材", "素材/视频", "素材/视频/原始", "素材/音频", "交付"),
    )
    pid = ""
    try:
        proj = await _create_project(client, folder_template_id=tpl["id"])
        pid = proj["id"]

        folders = await _folders_by_prefix(pid)
        assert set(folders) == {
            "素材/", "素材/视频/", "素材/视频/原始/", "素材/音频/", "交付/",
        }, f"模板 5 条目应物化为恰好 5 个夹: {set(folders)}"
        assert all(not f.is_sensitive for f in folders.values())

        # parent 链
        assert folders["素材/"].parent_folder_id is None
        assert folders["交付/"].parent_folder_id is None
        assert folders["素材/视频/"].parent_folder_id == folders["素材/"].id
        assert folders["素材/视频/原始/"].parent_folder_id == folders["素材/视频/"].id
        assert folders["素材/音频/"].parent_folder_id == folders["素材/"].id

        # FGA parent tuple 就位(根挂 project,子挂父夹)
        perms = app_with_lifespan.state.permissions
        expectations = [
            ("素材/", f"project:{pid}"),
            ("素材/视频/", f"folder:{folders['素材/'].id}"),
            ("素材/视频/原始/", f"folder:{folders['素材/视频/'].id}"),
            ("素材/音频/", f"folder:{folders['素材/'].id}"),
            ("交付/", f"project:{pid}"),
        ]
        for prefix, parent_subject in expectations:
            fid = str(folders[prefix].id)
            tuples = await perms.read_all_tuples(object_type="folder", object_id=fid)
            pairs = {(u, rel) for u, rel, _o in tuples}
            assert (parent_subject, "parent") in pairs, (
                f"folder:{fid}({prefix})应挂 parent={parent_subject}: {pairs}"
            )
    finally:
        if pid:
            await _archive_project(pid)
        await _delete_template(client, tpl["id"])


@pytest.mark.asyncio
async def test_overlapping_prefix_entries_create_three_folders(client: AsyncClient) -> None:
    """前缀重叠条目(`素材` + `素材/视频/原始`)→ 恰好 3 个夹(去重节点集:
    素材、素材/视频、素材/视频/原始),ensure 幂等复用无重复无报错;
    parent 链与 minio_prefix(`素材/`、`素材/视频/`、`素材/视频/原始/`)正确。"""
    name = _uniq("ft_overlap")
    tpl = await _post_template(
        client, name=name, entries=_entries("素材", "素材/视频/原始"),
    )
    pid = ""
    try:
        proj = await _create_project(client, folder_template_id=tpl["id"])
        pid = proj["id"]

        folders = await _folders_by_prefix(pid)
        assert set(folders) == {"素材/", "素材/视频/", "素材/视频/原始/"}, (
            f"前缀重叠条目应恰好建 3 夹: {set(folders)}"
        )
        assert folders["素材/"].parent_folder_id is None
        assert folders["素材/视频/"].parent_folder_id == folders["素材/"].id
        assert folders["素材/视频/原始/"].parent_folder_id == folders["素材/视频/"].id
    finally:
        if pid:
            await _archive_project(pid)
        await _delete_template(client, tpl["id"])


@pytest.mark.asyncio
async def test_create_project_without_template_no_folders(client: AsyncClient) -> None:
    """不带 folder_template_id → 项目无额外 folders(现状零回归);且
    project_created audit details 不含 folder_template_id 键(省略而非 null,
    防 details 恒 null 噪音,方案 §4.2)。"""
    proj = await _create_project(client)
    pid = proj["id"]
    try:
        folders = await _folders_by_prefix(pid)
        assert folders == {}, f"未选模板不应建任何夹: {set(folders)}"

        events = await _audit_events(client, "project_created", project_id=pid)
        assert events, "project_created audit 应存在"
        for e in events:
            details = e.get("details") or {}
            assert "folder_template_id" not in details, (
                f"未选模板时 project_created 不应含 folder_template_id 键: {details}"
            )
    finally:
        await _archive_project(pid)


@pytest.mark.asyncio
async def test_create_project_template_not_found_400(client: AsyncClient) -> None:
    """folder_template_id 不存在 → 400 `folder template not found`(校验在
    initial_grants 校验段之后、DB 写入之前,项目不被创建)。"""
    ghost = str(uuid.uuid4())
    r = await client.post(
        "/api/v1/projects",
        json={
            "code": _project_code(), "name": _uniq("模板不存在"),
            "minio_bucket": "ms-dev", "admin_user_id": EVAN_ID,
            "folder_template_id": ghost,
        },
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 400, r.text
    assert "folder template" in r.text, f"400 应指明模板不存在: {r.text}"


@pytest.mark.asyncio
async def test_create_project_cross_org_template_400(client: AsyncClient) -> None:
    """跨 org 模板 → 400 `folder template belongs to another organization`。

    构造(方案 §7:注释写明为何必须直改,防后人「顺手修掉」):
    ① 先直插第二个 organizations 行 —— templates.organization_id 是 FK,不插行
    直指会违反外键;② POST 模板(服务端只取 default org)后再**直改**模板
    organization_id 指向第二个 org —— POST/PATCH 模板的 org 由服务端固定取
    default org,第二个 org 的模板无法经 API 产生,此直改是必须的。
    """
    org2 = await _create_org_row()
    tpl = await _post_template(client, name=_uniq("ft_xorg"), entries=_entries("素材"))
    await _set_template_org(tpl["id"], org2)
    try:
        r = await client.post(
            "/api/v1/projects",
            json={
                "code": _project_code(), "name": _uniq("跨org模板"),
                "minio_bucket": "ms-dev", "admin_user_id": EVAN_ID,
                "folder_template_id": tpl["id"],
            },
            headers=_h(EVAN_ID),
        )
        assert r.status_code == 400, r.text
        assert "folder template" in r.text, f"400 应指明跨 org: {r.text}"
    finally:
        await _delete_template(client, tpl["id"])


@pytest.mark.asyncio
async def test_folder_template_audit_events(client: AsyncClient) -> None:
    """audit 四点(方案 §4.1/§4.2):
    - folder_template_changed:create / update / delete 各一条(details 含
      action + name;create/update 额外带 entry_count)
    - folder_template_applied:建项目应用后恰好一条(details 含 template_id /
      template_name / created_folder_count)
    - project_created details 含 folder_template_id / created_folder_count"""
    name = _uniq("ft_audit")
    tpl = await _post_template(
        client, name=name, entries=_entries("素材", "素材/视频", "交付"),
    )
    tid = tpl["id"]
    pid = ""
    template_deleted = False
    try:
        # create → changed(action=create,entry_count=3)
        evs = await _audit_events(client, "folder_template_changed")
        mine = [e for e in evs if (e.get("details") or {}).get("name") == name]
        assert len(mine) == 1 and mine[0]["details"]["action"] == "create", evs
        assert mine[0]["details"]["entry_count"] == 3, mine[0]["details"]

        # update → changed(action=update)
        r = await client.patch(
            f"/api/v1/admin/folder-templates/{tid}",
            json={"description": "审计用"}, headers=_h(EVAN_ID),
        )
        assert r.status_code == 200, r.text
        evs = await _audit_events(client, "folder_template_changed")
        mine = [e for e in evs if (e.get("details") or {}).get("name") == name]
        assert any(e["details"]["action"] == "update" for e in mine), evs

        # 带模板建项目 → applied 恰一条 + project_created 带两键
        proj = await _create_project(client, folder_template_id=tid)
        pid = proj["id"]

        applied = await _audit_events(client, "folder_template_applied", project_id=pid)
        assert len(applied) == 1, applied
        d = applied[0]["details"]
        assert d["template_id"] == tid and d["template_name"] == name, d
        assert d["created_folder_count"] == 3, d

        created = await _audit_events(client, "project_created", project_id=pid)
        assert created, "project_created audit 应存在"
        cd = created[0]["details"]
        assert cd["folder_template_id"] == tid, cd
        assert cd["created_folder_count"] == 3, cd

        # delete → changed(action=delete;三操作各一条)
        r2 = await client.delete(f"/api/v1/admin/folder-templates/{tid}", headers=_h(EVAN_ID))
        assert r2.status_code == 204, r2.text
        template_deleted = True
        evs = await _audit_events(client, "folder_template_changed")
        mine = [e for e in evs if (e.get("details") or {}).get("name") == name]
        actions = sorted(e["details"]["action"] for e in mine)
        assert actions == ["create", "delete", "update"], (
            f"create/update/delete 应各记一条 folder_template_changed: {actions}"
        )
    finally:
        if pid:
            await _archive_project(pid)
        if not template_deleted:
            await _delete_template(client, tid)


# ══════════════════════════════════════════════════════════════════════════════
# 四、回归(方案 §7 第四组;存量行为断言式,不重跑存量文件)
# ══════════════════════════════════════════════════════════════════════════════


@pytest.mark.asyncio
async def test_manual_folder_creation_unchanged(client: AsyncClient) -> None:
    """回归:手工建夹 POST /folders 行为不变(未引入目录模板前的一级夹创建
    + 删除链路照旧)。"""
    uniq = _uniq("ft_manual")
    r = await client.post(
        "/api/v1/folders",
        json={"project_id": PROJECT_EVENT, "name": uniq},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["name"] == uniq
    assert body["parent_folder_id"] is None
    fid = body["id"]

    r2 = await client.get(
        "/api/v1/folders", params={"project_id": PROJECT_EVENT}, headers=_h(EVAN_ID),
    )
    assert r2.status_code == 200
    assert any(f["id"] == fid for f in r2.json()), "手工建的夹应出现在 folders 列表"

    r3 = await client.delete(f"/api/v1/folders/{fid}", headers=_h(EVAN_ID))
    assert r3.status_code == 204, r3.text
