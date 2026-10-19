"""W4+W5 目录改名 / 目录拖拽层级(PATCH /api/v1/folders/{id})— 集成测试(容器内跑,面向契约)。

唯一需求依据:`docs/qdev/2026-10-17-six-optimizations.md` §3.5(W4+W5 目录改名/移动)+
§4(事件命名 folder_renamed / folder_moved)+ §5(测试功能点 W4/W5 行);上游方案
`rushes-spec/material-storage/admin-audit-folder-mobile-optimization-plan.md` §5
(关键前提/实施方案/验收标准)。写法仿 tests/test_batch_prefix.py(httpx
ASGITransport + Evan=系统 admin 直通 + DB 直插造数)+ test_v4_permissions.py
(/grants 授权、/invite 敏感夹邀请)。

契约要点(后端包3并行开发中,冲突以需求文档 §3.5 为准):
  - PATCH /api/v1/folders/{id},body `{name?, parent_folder_id?}`(至少传一);
    `parent_folder_id=null` = 移为项目一级(合法方向)
  - 权限:普通夹 can_upload(系统 admin 直通)、sensitive 夹 can_admin;
    reparent 额外要求目标夹(非敏感)can_upload,无权限 403
  - 校验:name 过 check_segment_name + 拒首尾空白 → 422;同父同名 409;
    新 prefix 逐夹过 check_prefix_budget → 400;跨项目 400;防环(自/后代)409;
    带 explicit grant 的一级夹禁 reparent 409;sensitive 三句式:
      ① 源 sensitive 禁 ② 目标 sensitive 或其子树禁 ③ 普通夹移出敏感子树允许
  - D1-B:子树 minio_prefix DB 重算(不动物理对象);新上传按新 prefix 拼 key
  - FGA:单次 WriteRequest 原子交换;形态按方向分派 —— 一级→嵌套删 `project:<pid>`;
    嵌套→删 `folder:<旧父>`(即便旧父 sensitive);移为一级删 `folder:<旧父>` 写 `project:<pid>`
  - 审计:folder_renamed / folder_moved(details 记 old/new name、parent、prefix)
  - 并发互为目标 reparent:恰一成一 409(uuid 定序双行 FOR UPDATE 防环)

前置(同 test_batch_prefix.py):seed_demo_data.py 已跑过(Evan = 系统 admin);
OpenFGA store/model 已 push;env=dev;MinIO 可达(仅 create_upload 需要真实桶,
ms-dev 由 seed 建出;上传会话即刻 abort,不留对象)。
"""
from __future__ import annotations

import asyncio
import json
import uuid
import warnings
from datetime import UTC, datetime
from typing import Any

import pytest
from httpx import ASGITransport, AsyncClient

from app.db.session import get_sessionmaker
from app.db.tables import AuditEvent, Folder, Organization, Project
from app.main import create_app

EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"        # 系统 admin(seed 契约账号)
OUTSIDER_ID = "00000000-0000-0000-0000-0000000000aa"    # 零权限(seed 契约账号)
PROJECT_EVENT = "11111111-1111-1111-1111-111111111103"  # public,bucket=ms-dev

FOLDERS_URL = "/api/v1/folders"

# sensitive 三句式契约未钉死状态码(方案 §5.3 口径「409/400,文案照反探测惯例」)
SENSITIVE_REJECT_CODES = (400, 409)


def _h(uid: str = EVAN_ID) -> dict[str, str]:
    return {"X-User-Id": uid}


def _uniq(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:8]}"


@pytest.fixture(scope="session")
async def app_with_lifespan():
    app = create_app()
    async with app.router.lifespan_context(app):  # type: ignore[attr-defined]
        yield app


@pytest.fixture(scope="session")
async def client(app_with_lifespan):
    transport = ASGITransport(app=app_with_lifespan)  # type: ignore[arg-type]
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


# ─── 建夹 / 改夹 / 读回 / FGA tuple 读取 / 清理 ─────────────────────────────────
async def _mkfolder(
    client: AsyncClient, name: str, *, parent: str | None = None,
    sensitive: bool = False, uid: str = EVAN_ID,
) -> dict:
    r = await client.post(
        FOLDERS_URL,
        json={"project_id": PROJECT_EVENT, "name": name,
              "parent_folder_id": parent, "is_sensitive": sensitive},
        headers=_h(uid),
    )
    assert r.status_code == 201, r.text
    return r.json()


async def _patch(client: AsyncClient, folder_id: str, body: dict,
                 uid: str = EVAN_ID) -> Any:
    return await client.patch(f"{FOLDERS_URL}/{folder_id}", json=body, headers=_h(uid))


async def _get_folder_row(folder_id: str) -> Folder:
    async with get_sessionmaker()() as db:
        row = await db.get(Folder, uuid.UUID(folder_id))
        assert row is not None, f"folder {folder_id} 应在库中"
        return row


async def _parent_tuples(app: Any, folder_id: str) -> set[str]:
    """读 folder:<id> 上 relation=parent 的 user 形态集合
    ({"project:<pid>"} / {"folder:<fid>"}),FGA 形态分派断言用。"""
    perms = app.state.permissions
    tuples = await perms.read_all_tuples(
        object_type="folder", object_id=str(folder_id), relation="parent")
    return {user for user, _rel, _obj in tuples}


async def _cleanup_folders(client: AsyncClient, folder_ids: list[str]) -> None:
    """leaf 先删的清场(删夹要求空:无子夹、无活文件、回收站空);失败只告警。"""
    for fid in reversed(folder_ids):
        r = await client.delete(f"{FOLDERS_URL}/{fid}", headers=_h())
        if r.status_code != 204:
            warnings.warn(
                f"folder cleanup failed id={fid} ({r.status_code}): {r.text}",
                stacklevel=2,
            )


# ─── W4:改名 200 + 子树 prefix 重算 + 新上传落新 prefix ────────────────────────
@pytest.mark.asyncio
async def test_rename_ok_prefix_recomputed_and_new_upload_lands_new_prefix(
    client: AsyncClient,
) -> None:
    uniq = _uniq("ren")
    root = await _mkfolder(client, f"{uniq}_root")
    child = await _mkfolder(client, f"{uniq}_child", parent=root["id"])
    try:
        new_name = f"{uniq}_root2"
        r = await _patch(client, root["id"], {"name": new_name})
        assert r.status_code == 200, r.text

        # 目录详情/列表(树)显示新名;D1-B:子树 prefix DB 重算,不动物理对象
        r = await client.get(f"{FOLDERS_URL}/{root['id']}", headers=_h())
        assert r.status_code == 200, r.text
        assert r.json()["name"] == new_name
        assert r.json()["minio_prefix"] == f"{new_name}/"

        r = await client.get(
            FOLDERS_URL, params={"project_id": PROJECT_EVENT}, headers=_h())
        assert r.status_code == 200, r.text
        by_id = {f["id"]: f for f in r.json()}
        assert by_id[root["id"]]["name"] == new_name
        assert by_id[child["id"]]["minio_prefix"] == f"{new_name}/{uniq}_child/", (
            "子夹 prefix 应随改名重算")

        # 新上传 key 落新 prefix:create_upload 按「当下 prefix + filename」拼 key
        fname = f"fresh_{uniq}.txt"
        r = await client.post(
            "/api/v1/assets/uploads",
            json={"folder_id": child["id"], "filename": fname, "size_bytes": 1},
            headers=_h(),
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["key"] == f"{new_name}/{uniq}_child/{fname}", body
        # 即刻 abort,不留 multipart 会话
        r = await client.delete(
            f"/api/v1/assets/uploads/{body['upload_id']}",
            params={"bucket": body["bucket"], "key": body["key"]},
            headers=_h(),
        )
        assert r.status_code == 204, r.text
    finally:
        await _cleanup_folders(client, [root["id"], child["id"]])


# ─── W4:段名非法 / 首尾空白 / 超长 → 422 ───────────────────────────────────────
@pytest.mark.asyncio
async def test_rename_invalid_names_422(client: AsyncClient) -> None:
    uniq = _uniq("bad")
    folder = await _mkfolder(client, f"{uniq}_keep")
    try:
        bad_names = [
            "a/b",          # 段内路径分隔符
            "a\\b",         # 反斜杠
            ".",            # 路径穿越段
            "..",
            " spaced ",     # 首尾空白(对齐目录模板口径:拒而非静默 strip)
            "\ttab\t",
            "",             # 空段(Pydantic min_length)
            "x" * 256,      # 超 255 字符
        ]
        for name in bad_names:
            r = await _patch(client, folder["id"], {"name": name})
            assert r.status_code == 422, f"name={name!r}: {r.text}"

        # 全部被拦:名字原样
        row = await _get_folder_row(folder["id"])
        assert row.name == f"{uniq}_keep"
    finally:
        await _cleanup_folders(client, [folder["id"]])


# ─── W4:子树 prefix 预算超限 → 400 ─────────────────────────────────────────────
@pytest.mark.asyncio
async def test_rename_prefix_budget_400(client: AsyncClient) -> None:
    """链 R(200) > c1..c4(各 200):现前缀最深 804 < 1024 可建;把 R 改名为
    255 字符 → 最深叶子新前缀 1060 > 1024 → 400(check_prefix_budget 逐夹过)。"""
    long_r = "R" * 200
    long_c = "C" * 200
    root = await _mkfolder(client, long_r)
    ids = [root["id"]]
    parent = root["id"]
    for _ in range(4):
        child = await _mkfolder(client, long_c, parent=parent)
        ids.append(child["id"])
        parent = child["id"]
    leaf_before = (await _get_folder_row(ids[-1])).minio_prefix
    try:
        r = await _patch(client, root["id"], {"name": "N" * 255})
        assert r.status_code == 400, r.text
        # 全树原样(含 R 的名字与叶子 prefix)
        assert (await _get_folder_row(root["id"])).name == long_r
        assert (await _get_folder_row(ids[-1])).minio_prefix == leaf_before
    finally:
        await _cleanup_folders(client, ids)


# ─── W4:同父同名 → 409 ─────────────────────────────────────────────────────────
@pytest.mark.asyncio
async def test_rename_same_parent_conflict_409(client: AsyncClient) -> None:
    uniq = _uniq("dup")
    fa = await _mkfolder(client, f"{uniq}_a")
    fb = await _mkfolder(client, f"{uniq}_b")
    try:
        r = await _patch(client, fb["id"], {"name": f"{uniq}_a"})
        assert r.status_code == 409, r.text
        assert (await _get_folder_row(fb["id"])).name == f"{uniq}_b"
    finally:
        await _cleanup_folders(client, [fa["id"], fb["id"]])


# ─── W5:reparent 200 + FGA 形态分派 + 防环 + 跨项目 400 ────────────────────────
@pytest.mark.asyncio
async def test_reparent_fga_dispatch_cycle_and_cross_project(
    client: AsyncClient, app_with_lifespan,
) -> None:
    uniq = _uniq("mv")
    fa = await _mkfolder(client, f"{uniq}_a")
    fb = await _mkfolder(client, f"{uniq}_b")
    try:
        # ① 一级 → 嵌套:旧 parent tuple 是 project:<pid>,须删并写 folder:<fb>
        assert await _parent_tuples(app_with_lifespan, fa["id"]) == {
            f"project:{PROJECT_EVENT}"}
        r = await _patch(client, fa["id"], {"parent_folder_id": fb["id"]})
        assert r.status_code == 200, r.text
        row = await _get_folder_row(fa["id"])
        assert str(row.parent_folder_id) == fb["id"]
        assert row.minio_prefix == f"{uniq}_b/{uniq}_a/"
        assert await _parent_tuples(app_with_lifespan, fa["id"]) == {
            f"folder:{fb['id']}"}, "一级→嵌套应删 project: 写 folder:"

        # ② 防环:不能移进自身或自身后代
        r = await _patch(client, fb["id"], {"parent_folder_id": fa["id"]})
        assert r.status_code == 409, f"移进自己的子夹应 409:{r.text}"
        r = await _patch(client, fb["id"], {"parent_folder_id": fb["id"]})
        assert r.status_code == 409, f"移进自身应 409:{r.text}"

        # ③ 跨项目 400:目标夹属另一项目(直插造数,不产生 FGA 副作用)
        tag = uuid.uuid4().hex[:8]
        async with get_sessionmaker()() as db:
            org = Organization(name=f"it-fmv-{tag}",
                               feishu_tenant_key=f"it_fmv_{tag}")
            db.add(org)
            await db.flush()
            p2 = Project(organization_id=org.id, code=f"itfmv_{tag}",
                         name=f"it-fmv-project-{tag}", minio_bucket=f"itfmv-{tag}",
                         visibility="private")
            db.add(p2)
            await db.flush()
            f2 = Folder(project_id=p2.id, name="itfmv-target",
                        minio_prefix="itfmv-target/")
            db.add(f2)
            await db.commit()
            p2_id, f2_id, org_id = p2.id, f2.id, org.id
        try:
            r = await _patch(client, fa["id"], {"parent_folder_id": str(f2_id)})
            assert r.status_code == 400, f"跨项目 reparent 应 400:{r.text}"
        finally:
            async with get_sessionmaker()() as db:
                await db.execute(Folder.__table__.delete().where(Folder.id == f2_id))
                await db.execute(Project.__table__.delete().where(Project.id == p2_id))
                await db.execute(Organization.__table__.delete().where(
                    Organization.id == org_id))
                await db.commit()

        # ④ 移为一级(parent_folder_id=null 合法):删 folder:<旧父> 写 project:<pid>
        r = await _patch(client, fa["id"], {"parent_folder_id": None})
        assert r.status_code == 200, r.text
        row = await _get_folder_row(fa["id"])
        assert row.parent_folder_id is None
        assert row.minio_prefix == f"{uniq}_a/"
        assert await _parent_tuples(app_with_lifespan, fa["id"]) == {
            f"project:{PROJECT_EVENT}"}, "移为一级应删 folder: 写 project:"
    finally:
        await _cleanup_folders(client, [fa["id"], fb["id"]])


# ─── W5:reparent 目标夹 can_upload 403(普通用户)───────────────────────────────
@pytest.mark.asyncio
async def test_reparent_target_without_can_upload_403(client: AsyncClient) -> None:
    """对源夹有显式 uploader、对目标夹无任何权限的用户:改名 200(源门槛过),
    reparent 进目标夹 403(目标夹 can_upload 门槛,删除闸门不复用)。"""
    uniq = _uniq("perm")
    src = await _mkfolder(client, f"{uniq}_src")
    tgt = await _mkfolder(client, f"{uniq}_tgt")
    try:
        r = await client.post(
            f"{FOLDERS_URL}/{src['id']}/grants",
            json={"user_id": OUTSIDER_ID, "level": "uploader"},
            headers=_h(),
        )
        assert r.status_code == 204, r.text

        # 正向:对源夹 can_upload → 改名放行
        r = await _patch(client, src["id"], {"name": f"{uniq}_src2"},
                         uid=OUTSIDER_ID)
        assert r.status_code == 200, r.text

        # 反向:目标夹无 can_upload → 403(文案照反探测惯例,不暴露目标夹名)
        r = await _patch(client, src["id"], {"parent_folder_id": tgt["id"]},
                         uid=OUTSIDER_ID)
        assert r.status_code == 403, r.text
        assert tgt["name"] not in r.json()["detail"], r.text
        # 源夹未被移动
        assert (await _get_folder_row(src["id"])).parent_folder_id is None
    finally:
        # 撤 grant(删夹不清 explicit tuple,残留会漏权限给 outsider)
        r = await client.delete(
            f"{FOLDERS_URL}/{src['id']}/grants",
            params={"subject": f"user:{OUTSIDER_ID}", "level": "uploader"},
            headers=_h(),
        )
        if r.status_code != 204:
            warnings.warn(f"grant revoke failed: {r.status_code} {r.text}",
                          stacklevel=2)
        await _cleanup_folders(client, [src["id"], tgt["id"]])


# ─── W5:并发互为目标 reparent,恰一成一 409,无环 ──────────────────────────────
@pytest.mark.asyncio
async def test_concurrent_mutual_reparent_exactly_one_success(
    client: AsyncClient,
) -> None:
    """T1 把 A 移入 B、T2 把 B 移入 A 并发执行:行锁须覆盖双端 —— 恰一个 200、
    一个 409;终态无环(A.parent=B 则 B.parent≠A)。"""
    uniq = _uniq("race")
    fa = await _mkfolder(client, f"{uniq}_a")
    fb = await _mkfolder(client, f"{uniq}_b")
    cleanup = [fa["id"], fb["id"]]  # 兜底序;断言通过后按实际父子关系重排
    try:
        r1, r2 = await asyncio.gather(
            _patch(client, fa["id"], {"parent_folder_id": fb["id"]}),
            _patch(client, fb["id"], {"parent_folder_id": fa["id"]}),
        )
        codes = sorted([r1.status_code, r2.status_code])
        assert codes == [200, 409], (
            f"应恰一成一 409,实际 {r1.status_code}/{r2.status_code}:"
            f" {r1.text} | {r2.text}")

        # 终态无环:两夹不得互为父
        pa = (await _get_folder_row(fa["id"])).parent_folder_id
        pb = (await _get_folder_row(fb["id"])).parent_folder_id
        assert not (pa == uuid.UUID(fb["id"]) and pb == uuid.UUID(fa["id"])), (
            f"并发 reparent 成环:{pa} / {pb}")
        # 清场按「子夹先删」(_cleanup_folders 输入根在前、内部 reversed):
        # 胜者未定,按落库父子关系排
        if pa == uuid.UUID(fb["id"]):
            cleanup = [fb["id"], fa["id"]]
        elif pb == uuid.UUID(fa["id"]):
            cleanup = [fa["id"], fb["id"]]
    finally:
        await _cleanup_folders(client, cleanup)


# ─── W5:sensitive 三句式(源禁 / 目标及子树禁 / 移出允许)+ 嵌套 tuple 形态 ─────
@pytest.mark.asyncio
async def test_sensitive_move_rules_and_nested_tuple_shape(
    client: AsyncClient, app_with_lifespan,
) -> None:
    """三句式:① 源 sensitive 禁移;② 目标 sensitive 或其子树禁移入;
    ③ 普通夹移出敏感子树允许(修复性操作)—— 子夹经 API 建(有 folder:<sid>
    tuple),历史孤儿经直插 DB 造(无 tuple)。sensitive 夹改名允许。"""
    uniq = _uniq("sens")
    sens = await _mkfolder(client, f"{uniq}_s", sensitive=True)
    normal = await _mkfolder(client, f"{uniq}_n")
    # 敏感夹下的普通子夹(经 API 建:bootstrap 写 folder:<sid>,孤儿位形态)
    inner = await _mkfolder(client, f"{uniq}_in", parent=sens["id"])
    # 直插 DB 造历史孤儿(无任何 FGA tuple,「移出」正例的GUI不可达形态)
    orphan_id = uuid.uuid4()
    async with get_sessionmaker()() as db:
        db.add(Folder(
            id=orphan_id, project_id=uuid.UUID(PROJECT_EVENT),
            parent_folder_id=uuid.UUID(sens["id"]), name=f"{uniq}_orph",
            minio_prefix=f"{sens['minio_prefix']}{uniq}_orph/",
            is_sensitive=False,
        ))
        await db.commit()
    try:
        # ① 源 sensitive → 禁(连改名都允许、移动不允许:一级内改名无结构变化)
        r = await _patch(client, sens["id"], {"parent_folder_id": normal["id"]})
        assert r.status_code in SENSITIVE_REJECT_CODES, f"源 sensitive 移动应禁:{r.text}"
        r = await _patch(client, sens["id"], {"name": f"{uniq}_s2"})
        assert r.status_code == 200, f"sensitive 夹改名应允许:{r.text}"

        # ② 目标为 sensitive 夹 → 禁;目标为 sensitive 后代普通子夹(孤儿位)→ 禁
        r = await _patch(client, normal["id"], {"parent_folder_id": sens["id"]})
        assert r.status_code in SENSITIVE_REJECT_CODES, f"移入 sensitive 应禁:{r.text}"
        r = await _patch(client, normal["id"], {"parent_folder_id": inner["id"]})
        assert r.status_code in SENSITIVE_REJECT_CODES, (
            f"移入 sensitive 子树应禁:{r.text}")

        # ③ 移出敏感子树允许(API 子夹形态):旧 tuple 按 folder:<sid> 删
        # (即便旧父 sensitive,不得按 sensitive_folder: 拼错删空)
        assert await _parent_tuples(app_with_lifespan, inner["id"]) == {
            f"folder:{sens['id']}"}
        r = await _patch(client, inner["id"], {"parent_folder_id": normal["id"]})
        assert r.status_code == 200, f"移出敏感子树应允许:{r.text}"
        assert await _parent_tuples(app_with_lifespan, inner["id"]) == {
            f"folder:{normal['id']}"}

        # ③' 移出敏感子树允许(直插孤儿形态,移为一级):写 project:<pid>
        r = await _patch(client, str(orphan_id), {"parent_folder_id": None})
        assert r.status_code == 200, f"孤儿夹移出(移为一级)应允许:{r.text}"
        row = await _get_folder_row(str(orphan_id))
        assert row.parent_folder_id is None
        assert row.minio_prefix == f"{uniq}_orph/"
        assert await _parent_tuples(app_with_lifespan, str(orphan_id)) == {
            f"project:{PROJECT_EVENT}"}
    finally:
        # 终态:inner 在 normal 下(orphan 已移为一级、sens 空)→ 子夹先删
        await _cleanup_folders(
            client, [sens["id"], str(orphan_id), normal["id"], inner["id"]])


# ─── W5:带 explicit grant 的一级夹禁 reparent(MVP 决策 10)────────────────────
@pytest.mark.asyncio
async def test_level1_folder_with_grant_banned_from_reparent(
    client: AsyncClient,
) -> None:
    """一级夹上存在 explicit grant → 禁移出一级 409(grant 管理能力语义防漂移)。"""
    uniq = _uniq("grant")
    src = await _mkfolder(client, f"{uniq}_src")
    tgt = await _mkfolder(client, f"{uniq}_tgt")
    try:
        r = await client.post(
            f"{FOLDERS_URL}/{src['id']}/grants",
            json={"user_id": OUTSIDER_ID, "level": "viewer"},
            headers=_h(),
        )
        assert r.status_code == 204, r.text

        r = await _patch(client, src["id"], {"parent_folder_id": tgt["id"]})
        assert r.status_code == 409, f"带 grant 一级夹禁移应 409:{r.text}"
        assert (await _get_folder_row(src["id"])).parent_folder_id is None

        # 对照:无 grant 的一级夹 reparent 不受限(grant 是禁移的充分条件)
        clean = await _mkfolder(client, f"{uniq}_clean")
        try:
            r = await _patch(client, clean["id"], {"parent_folder_id": tgt["id"]})
            assert r.status_code == 200, r.text
        finally:
            await _cleanup_folders(client, [tgt["id"], clean["id"]])
    finally:
        r = await client.delete(
            f"{FOLDERS_URL}/{src['id']}/grants",
            params={"subject": f"user:{OUTSIDER_ID}", "level": "viewer"},
            headers=_h(),
        )
        if r.status_code != 204:
            warnings.warn(f"grant revoke failed: {r.status_code} {r.text}",
                          stacklevel=2)
        await _cleanup_folders(client, [src["id"]])


# ─── 审计:folder_renamed / folder_moved details ────────────────────────────────
@pytest.mark.asyncio
async def test_rename_move_audit_events(client: AsyncClient) -> None:
    """改名写 folder_renamed(details 含 old/new 名与 prefix)、移动写
    folder_moved(details 含 old/new parent)—— 事件名按 §4 全局契约。"""
    uniq = _uniq("aud")
    src = await _mkfolder(client, f"{uniq}_s")
    tgt = await _mkfolder(client, f"{uniq}_t")
    old_name = f"{uniq}_s"
    t0 = datetime.now(UTC)
    try:
        r = await _patch(client, src["id"], {"name": f"{uniq}_s2"})
        assert r.status_code == 200, r.text
        r = await _patch(client, src["id"], {"parent_folder_id": tgt["id"]})
        assert r.status_code == 200, r.text

        async with get_sessionmaker()() as db:
            rows = list((await db.execute(
                AuditEvent.__table__.select().where(
                    AuditEvent.event_type.in_(["folder_renamed", "folder_moved"]),
                    AuditEvent.event_time >= t0,
                ).order_by(AuditEvent.event_time.asc())
            )).mappings())

        def _events(event_type: str) -> list[dict]:
            return [dict(r) for r in rows
                    if r["event_type"] == event_type
                    and json.dumps(r["details"] or {}, ensure_ascii=False)
                    .find(src["id"]) >= 0]

        renamed = _events("folder_renamed")
        assert renamed, "应写 folder_renamed 审计"
        blob = json.dumps(renamed[-1]["details"], ensure_ascii=False)
        assert old_name in blob and f"{uniq}_s2" in blob, blob

        moved = _events("folder_moved")
        assert moved, "应写 folder_moved 审计"
        blob = json.dumps(moved[-1]["details"], ensure_ascii=False)
        assert tgt["id"] in blob, f"details 应记新 parent:{blob}"
    finally:
        # 终态 src 在 tgt 下 → 子夹先删
        await _cleanup_folders(client, [tgt["id"], src["id"]])
