"""Folders 子树活跃文件计数(subtree_file_count)集成测试 — 跑在 ms-api 容器里。

对应需求文档:`docs/qdev/2026-10-15-folder-subtree-file-badge.md`(测试功能点 T1-T8);
权威技术方案:`rushes-spec/material-storage/folder-subtree-file-badge-plan.md`
  §3(list 端点聚合 + 真根后序回累契约)、§6.3/§6.4(孤儿口径 = 受众信任边界三态)、
  §8(用例清单与造数注意);两者冲突以方案为准。

用例 → T 编号对照(方案 §8):
  T1 子树计数精确(多夹多文件)          → test_t1_subtree_counts_exact_multi_folder
  T2 深层回累(三层嵌套)                → test_t2_deep_nesting_rollup_three_ancestors
  T3 软删排除 / 恢复回加                → test_t3_soft_delete_excluded_restore_readd
  T4 空模板项目全夹 0                   → test_t4_empty_template_project_all_zero
  T5 不可见 sensitive 不泄漏+被邀请者   → test_t5_invisible_sensitive_no_leak_invitee_exact
  T6 单条 / 创建恒默认 0                → test_t6_single_get_and_create_always_zero
  T7 自拟 minio_prefix 仍按结构链       → test_t7_self_chosen_minio_prefix_still_structure_based
  T8 孤儿三态(私有/public/邀请撤销)    → test_t8_orphan_private_member_zero_invitee_backfill_and_chain_break
                                         test_t8_orphan_public_variant_under_report_zero
                                         test_t8_invite_revoke_falls_back_to_zero

预期前置(同 test_v4_permissions.py / test_trash_and_purge.py):
  1. seed_demo_data.py 已跑过(Evan = 系统 admin;outsider = 无任何角色的契约账号)
  2. OpenFGA store / model 已 push
  3. env=dev(允许 X-User-Id header 模拟身份)
  4. DB 直达 —— 资产一律 DB 直插(presign 的 PUT 指向 MinIO 公网 endpoint,
     容器内不通,与 test_trash_and_purge 同理由)

⚠ 本文件随 WP-T「只写不跑」交付:后端 WP-B(list_folders 聚合 + 回累、
FolderOut.subtree_file_count 字段)并行开发中,本文件按契约断言(契约要点见
方案 §3:仅 GET /folders 列表端点回填;单条/创建恒默认 0;孤儿行缺键默认 0),
由 PM 在隔离栈统一执行。

    造数注意(方案 §8):敏感父下的普通子夹 can_upload 内容链断(除系统 admin 外
    无人能向其传文件),且线上该结构的文件来源本就只有系统 admin 与百度导入两条 ——
    本文件一律 DB 直插模拟已上传文件(与既有测试同款;uploader 记 EVAN)。
"""
from __future__ import annotations

import uuid
import warnings
from datetime import datetime, timezone

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import update

from app.db.session import get_sessionmaker
from app.db.tables import Asset, Project
from app.main import create_app

# seed 写死的真 user / 契约账号(同 test_v4_permissions.py)
EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"        # 系统 admin(org admin)
OUTSIDER_ID = "00000000-0000-0000-0000-0000000000aa"    # 无任何角色;按需授项目 viewer
# seed 项目本文件不用:计数用例全部现建项目,防污染共享 fixture 与既有断言


def _h(uid: str = EVAN_ID) -> dict[str, str]:
    return {"X-User-Id": uid}


def _uniq(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:8]}"


def _project_code() -> str:
    """项目 code 唯一(projects.code unique);pattern 限 ^[a-z0-9][a-z0-9\\-]*$。"""
    return f"ffc-{uuid.uuid4().hex[:12]}"


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


# ─── 造数 helper(建项目/建夹照 test_folder_templates、直插资产照 test_trash_and_purge)──
def _viewer_grant(uid: str) -> list[dict]:
    """POST /projects 的 initial_grants 条目:给 uid 授项目 viewer。

    viewer → can_view(project)(list_folders 的私有项目门槛);普通夹 can_view
    经 FGA parent 链(folder ← project)继承,成员视角足以读全部普通夹列表。
    """
    return [{"kind": "user", "id": uid, "roles": ["viewer"]}]


async def _create_project(
    client: AsyncClient, *,
    initial_grants: list[dict] | None = None,
    folder_template_id: str | None = None,
) -> dict:
    """Evan(系统 admin)建私有项目 → 201(照 test_default_template.py helper)。"""
    body: dict = {
        "code": _project_code(),
        "name": _uniq("子树计数项目"),
        "minio_bucket": "ms-dev",
        "admin_user_id": EVAN_ID,
    }
    if initial_grants is not None:
        body["initial_grants"] = initial_grants
    if folder_template_id is not None:
        body["folder_template_id"] = folder_template_id
    r = await client.post("/api/v1/projects", json=body, headers=_h())
    assert r.status_code == 201, r.text
    return r.json()


async def _create_folder(
    client: AsyncClient, project_id: str, name: str, *,
    parent_id: str | None = None, sensitive: bool = False,
    minio_prefix: str | None = None,
) -> dict:
    """Evan(系统 admin)建夹 → 201 FolderOut。

    一律系统 admin 操作:敏感父下建普通子夹需 sensitive 父的 can_upload,而该链
    除系统 admin 外对任何人都断(方案 §6.3;被邀请者亦然 —— 邀请写的是
    sensitive_folder:<父> 的 tuple,folder:<父> 永无 tuple)。
    """
    body: dict = {"project_id": project_id, "name": name, "is_sensitive": sensitive}
    if parent_id is not None:
        body["parent_folder_id"] = parent_id
    if minio_prefix is not None:
        body["minio_prefix"] = minio_prefix
    r = await client.post("/api/v1/folders", json=body, headers=_h())
    assert r.status_code == 201, r.text
    return r.json()


async def _insert_asset(folder_id: str, filename: str, *, deleted: bool = False) -> uuid.UUID:
    """直插一条 asset 行(模拟已上传文件;deleted=True 模拟软删后的回收站行)。

    敏感父下普通子夹 can_upload 链断、容器内 presign 又不通 —— 直插是唯一
    稳定造数路径(方案 §8 明示「或直写 DB」;uploader 记系统 admin)。
    """
    async with get_sessionmaker()() as db:
        row = Asset(
            id=uuid.uuid4(),
            folder_id=uuid.UUID(folder_id),
            filename=filename,
            minio_bucket="ms-dev",
            minio_key=f"zz-ffc/{filename}",  # uq_asset_minio_object_version:文件名全局唯一
            size_bytes=11,
            content_type="text/plain",
            uploader_id=uuid.UUID(EVAN_ID),
            deleted_at=datetime.now(timezone.utc) if deleted else None,
        )
        db.add(row)
        await db.commit()
        return row.id


async def _list_folders(
    client: AsyncClient, project_id: str, *, uid: str = EVAN_ID,
) -> list[dict]:
    """GET /folders?project_id= → 200 列表(契约:每夹含 subtree_file_count:int)。"""
    r = await client.get(
        "/api/v1/folders", params={"project_id": project_id}, headers=_h(uid),
    )
    assert r.status_code == 200, r.text
    return r.json()


def _subtree_by_name(folders: list[dict]) -> dict[str, int]:
    """列表响应 → {夹名: subtree_file_count}。

    夹名在各用例内唯一;整体字典等值断言 = 既验计数逐夹精确,又验集合事实
    (sensitive 行被过滤 / 孤儿行在列)—— 防计数泄漏到任何未预期节点。
    """
    return {f["name"]: f["subtree_file_count"] for f in folders}


async def _invite(
    client: AsyncClient, folder_id: str, uid: str, *,
    level: str = "viewer", duration_seconds: int | None = None,
) -> None:
    """Evan 邀请 uid 进 sensitive 夹(204)。

    duration_seconds=None → 永久 invited_*;int → 时间限定 explicit_invited_*
    (带 non_expired_grant 条件,permissions.invite_to_sensitive_folder)。
    """
    body: dict = {"user_id": uid, "level": level}
    if duration_seconds is not None:
        body["duration_seconds"] = duration_seconds
    r = await client.post(f"/api/v1/folders/{folder_id}/invite", json=body, headers=_h())
    assert r.status_code == 204, r.text


async def _revoke_invite_best_effort(
    client: AsyncClient, folder_id: str, uid: str, *,
    level: str = "viewer", permanent: bool = True,
) -> None:
    """撤销 sensitive 邀请(照 test_v4_permissions / test_batch_prefix 收尾惯例:
    失败只告警 —— finally 里 assert 会掩盖 try 内真正的断言失败;残留 tuple
    挂在本用例现建的夹 UUID 上,不复用即天然失效)。"""
    r = await client.delete(
        f"/api/v1/folders/{folder_id}/invite",
        params={"subject": f"user:{uid}", "level": level,
                "permanent": "true" if permanent else "false"},
        headers=_h(),
    )
    if r.status_code != 204:
        warnings.warn(
            f"sensitive invite cleanup failed ({r.status_code}): {r.text};"
            f" outsider 对 {folder_id} 残留 invite tuple",
            stacklevel=2,
        )


async def _hard_cleanup(
    client: AsyncClient, asset_ids: list[uuid.UUID], folder_ids: list[str],
) -> None:
    """软删 + 彻底删除测试资产,再删空 folder(删夹要求无子夹、无活文件、
    回收站空)。folder_ids 必须按「先子后父」顺序传入。"""
    for aid in asset_ids:
        r = await client.delete(f"/api/v1/assets/{aid}", headers=_h())
        assert r.status_code == 204, r.text
        r = await client.delete(f"/api/v1/assets/{aid}?hard=true", headers=_h())
        assert r.status_code == 204, r.text
    for fid in folder_ids:
        r = await client.delete(f"/api/v1/folders/{fid}", headers=_h())
        assert r.status_code == 204, r.text


async def _delete_project_folders_best_effort(client: AsyncClient, project_id: str) -> None:
    """删空项目下全部夹(T4 收尾专用;归档项目前调用,防顺序依赖)。

    GET /folders(Evan = 系统 admin 视角拿全量,不经成员可见性裁剪)后按
    minio_prefix 长度降序逐个 DELETE —— 先子后父:模板物化的子夹前缀 =
    父前缀 + name + /,恒长于父夹;同长度者互不为祖先,顺序无关。模板夹
    无资产必为空夹,正常应逐个 204。best-effort:失败仅告警,不掩盖 try 内
    真正的断言失败(残留夹挂在已归档项目下,UUID 不复用即无害但脏)。
    """
    r = await client.get(
        "/api/v1/folders", params={"project_id": project_id}, headers=_h(),
    )
    if r.status_code != 200:
        warnings.warn(
            f"T4 收尾列夹失败 ({r.status_code}): {r.text}; 跳过删夹,残留夹行",
            stacklevel=2,
        )
        return
    for f in sorted(r.json(), key=lambda x: len(x["minio_prefix"]), reverse=True):
        rd = await client.delete(f"/api/v1/folders/{f['id']}", headers=_h())
        if rd.status_code != 204:
            warnings.warn(
                f"T4 收尾删夹失败 ({rd.status_code}): folder={f['id']} "
                f"prefix={f['minio_prefix']} body={rd.text}; 残留夹行",
                stacklevel=2,
            )


async def _archive_project(pid: str) -> None:
    """归档自建项目(收尾专用;照 test_folder_templates._archive_project):
    项目无删除 API,is_archived=True 后不再进 GET /projects 列表。"""
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


async def _set_project_visibility(pid: str, visibility: str) -> None:
    """直改项目 visibility(T8 public 变体专用)。

    ⚠ 此直改是必须的,勿「顺手修掉」:ProjectCreateIn 无 visibility 字段、
    projects 路由亦无改 visibility 的端点(该列只读),seed 脚本同走直写
    (seed_demo_data.py);不复用 seed 公开项目 PROJECT_EVENT —— 那是共享
    fixture,本用例要往里建 sensitive 结构,污染面太大。
    """
    async with get_sessionmaker()() as db:
        await db.execute(
            update(Project)
            .where(Project.id == uuid.UUID(pid))
            .values(visibility=visibility)
        )
        await db.commit()


async def _post_template(client: AsyncClient, *, name: str, entries: list[dict]) -> dict:
    """POST /admin/folder-templates 建目录模板(照 test_folder_templates;
    Evan = org admin 写直通)。"""
    r = await client.post(
        "/api/v1/admin/folder-templates",
        json={"name": name, "entries": entries},
        headers=_h(),
    )
    assert r.status_code == 201, r.text
    return r.json()


async def _delete_template(client: AsyncClient, tid: str) -> None:
    r = await client.delete(f"/api/v1/admin/folder-templates/{tid}", headers=_h())
    assert r.status_code == 204, r.text


def _entries(*paths: str) -> list[dict]:
    return [{"path": p} for p in paths]


# ══════════════════════════════════════════════════════════════════════════════
# T1-T4:计数语义(普通结构,成员视角)
# ══════════════════════════════════════════════════════════════════════════════


@pytest.mark.asyncio
async def test_t1_subtree_counts_exact_multi_folder(client: AsyncClient) -> None:
    """T1 子树计数精确:多夹多文件,各夹 subtree = 自身直接 + 全部后代之和。

    结构(私有新项目,OUTSIDER 项目成员视角):
      R1(直 2)┬─ C1(直 1)─ G(直 1)
               └─ C2(直 3)
      R2(直 0)
      R3(直 4)
    期望:R1=2+1+1+3=7,C1=1+1=2,G=1,C2=3,R2=0,R3=4。
    """
    proj = await _create_project(client, initial_grants=_viewer_grant(OUTSIDER_ID))
    pid = proj["id"]
    r1 = await _create_folder(client, pid, _uniq("t1_r1"))
    c1 = await _create_folder(client, pid, _uniq("t1_c1"), parent_id=r1["id"])
    g1 = await _create_folder(client, pid, _uniq("t1_g1"), parent_id=c1["id"])
    c2 = await _create_folder(client, pid, _uniq("t1_c2"), parent_id=r1["id"])
    r2 = await _create_folder(client, pid, _uniq("t1_r2"))
    r3 = await _create_folder(client, pid, _uniq("t1_r3"))
    aids: list[uuid.UUID] = []
    # 文件名以夹的 uniq 名为前缀:uq_asset_minio_object_version 要求全局唯一
    for folder, n in ((r1, 2), (c1, 1), (g1, 1), (c2, 3), (r3, 4)):
        for i in range(n):
            aids.append(await _insert_asset(folder["id"], f"t1_{folder['name']}_{i}.txt"))
    try:
        folders = await _list_folders(client, pid, uid=OUTSIDER_ID)
        # 整字典等值:计数逐夹精确,且无多夹/少夹(R2 空 = 0 也要在列)
        assert _subtree_by_name(folders) == {
            r1["name"]: 7, c1["name"]: 2, g1["name"]: 1,
            c2["name"]: 3, r2["name"]: 0, r3["name"]: 4,
        }, f"T1 子树计数不精确: {_subtree_by_name(folders)}"
    finally:
        await _hard_cleanup(
            client, aids,
            [g1["id"], c1["id"], c2["id"], r1["id"], r2["id"], r3["id"]],
        )
        await _archive_project(pid)


@pytest.mark.asyncio
async def test_t2_deep_nesting_rollup_three_ancestors(client: AsyncClient) -> None:
    """T2 深层回累:三层嵌套,文件只在最深层 → 爷爷=爸爸=最深层=1;
    无文件的兄弟分支不影响(=0)。

    回累只从真根(parent_folder_id is None)后序遍历 —— 文件在叶,三层祖先
    必须全部计入,钉死「只标直接包含」的退化实现。
    """
    proj = await _create_project(client, initial_grants=_viewer_grant(OUTSIDER_ID))
    pid = proj["id"]
    grand = await _create_folder(client, pid, _uniq("t2_grand"))
    father = await _create_folder(client, pid, _uniq("t2_father"), parent_id=grand["id"])
    son = await _create_folder(client, pid, _uniq("t2_son"), parent_id=father["id"])
    empty = await _create_folder(client, pid, _uniq("t2_empty"))
    aid = await _insert_asset(son["id"], f"t2_deep_{grand['name']}.txt")
    try:
        folders = await _list_folders(client, pid, uid=OUTSIDER_ID)
        assert _subtree_by_name(folders) == {
            grand["name"]: 1, father["name"]: 1, son["name"]: 1, empty["name"]: 0,
        }, f"T2 深层回累缺失: {_subtree_by_name(folders)}"
    finally:
        await _hard_cleanup(client, [aid], [son["id"], father["id"], grand["id"], empty["id"]])
        await _archive_project(pid)


@pytest.mark.asyncio
async def test_t3_soft_delete_excluded_restore_readd(client: AsyncClient) -> None:
    """T3 软删排除:软删后计数减(deleted_at IS NULL 口径)、恢复后加回。

    软删/恢复由系统 admin 操作(资产行直插;成员视角读计数,2 → 1 → 2)。"""
    proj = await _create_project(client, initial_grants=_viewer_grant(OUTSIDER_ID))
    pid = proj["id"]
    folder = await _create_folder(client, pid, _uniq("t3_f"))
    aid1 = await _insert_asset(folder["id"], f"t3_{folder['name']}_a.txt")
    aid2 = await _insert_asset(folder["id"], f"t3_{folder['name']}_b.txt")
    try:
        folders = await _list_folders(client, pid, uid=OUTSIDER_ID)
        assert _subtree_by_name(folders) == {folder["name"]: 2}

        # 软删一个 → 活跃计数减 1
        r = await client.delete(f"/api/v1/assets/{aid1}", headers=_h())
        assert r.status_code == 204, r.text
        folders = await _list_folders(client, pid, uid=OUTSIDER_ID)
        assert _subtree_by_name(folders) == {folder["name"]: 1}, "软删文件应被排除"

        # 恢复 → 计数加回
        r = await client.post(f"/api/v1/assets/{aid1}/restore", headers=_h())
        assert r.status_code == 204, r.text
        folders = await _list_folders(client, pid, uid=OUTSIDER_ID)
        assert _subtree_by_name(folders) == {folder["name"]: 2}, "恢复后计数应加回"
    finally:
        await _hard_cleanup(client, [aid1, aid2], [folder["id"]])
        await _archive_project(pid)


@pytest.mark.asyncio
async def test_t4_empty_template_project_all_zero(client: AsyncClient) -> None:
    """T4 空模板项目:目录模板物化的多层夹、全项目未传任何文件 → 全夹
    subtree_file_count = 0(原始痛点场景回归:模板批量建夹后侧栏应全空心)。"""
    tpl = await _post_template(
        client, name=_uniq("t4_tpl"),
        entries=_entries("素材", "素材/视频", "素材/视频/原始", "素材/音频", "交付"),
    )
    pid = ""
    try:
        # 建项目即应用模板:条目物化为 folders(parent 链 + minio_prefix 拼接),
        # 不传任何资产 → 全夹计数 0
        proj = await _create_project(
            client,
            initial_grants=_viewer_grant(OUTSIDER_ID),
            folder_template_id=tpl["id"],
        )
        pid = proj["id"]
        folders = await _list_folders(client, pid, uid=OUTSIDER_ID)
        assert len(folders) == 5, f"模板 5 条目应物化恰好 5 夹: {[f['name'] for f in folders]}"
        assert all(f["subtree_file_count"] == 0 for f in folders), (
            f"空模板项目应全夹 0: {_subtree_by_name(folders)}"
        )
    finally:
        # 收尾对齐其余用例的删夹惯例(P2-2):归档前先删模板物化的夹
        # (先子后父,空夹应逐个 204;失败 best-effort 告警不掩盖断言)
        if pid:
            await _delete_project_folders_best_effort(client, pid)
            await _archive_project(pid)
        await _delete_template(client, tpl["id"])


# ══════════════════════════════════════════════════════════════════════════════
# T5-T7:契约与口径边界
# ══════════════════════════════════════════════════════════════════════════════


@pytest.mark.asyncio
async def test_t5_invisible_sensitive_no_leak_invitee_exact(client: AsyncClient) -> None:
    """T5 权限:不可见 sensitive 夹的文件不计入任何可见节点;被邀请者视角
    sensitive 夹自身计数正确。

    成员(未受邀)视角:sensitive 行被过滤,唯一可见夹 N 计数 = 自身文件数
    (S 的 2 个文件不得吸入任何返回节点);被邀请后 S 以真根身份在列,自身
    计数 = 自身直接文件数。"""
    proj = await _create_project(client, initial_grants=_viewer_grant(OUTSIDER_ID))
    pid = proj["id"]
    n = await _create_folder(client, pid, _uniq("t5_normal"))
    s = await _create_folder(client, pid, _uniq("t5_secret"), sensitive=True)
    aid_n = await _insert_asset(n["id"], f"t5_{n['name']}.txt")
    aid_s1 = await _insert_asset(s["id"], f"t5_{s['name']}_1.txt")
    aid_s2 = await _insert_asset(s["id"], f"t5_{s['name']}_2.txt")
    try:
        # 未受邀成员视角:sensitive 行被过滤;唯一可见夹 N=1(S 的文件不泄漏)
        folders = await _list_folders(client, pid, uid=OUTSIDER_ID)
        assert s["name"] not in {f["name"] for f in folders}, "未受邀不应见 sensitive 夹"
        assert _subtree_by_name(folders) == {n["name"]: 1}, (
            f"S 的文件不得计入任何可见节点: {_subtree_by_name(folders)}"
        )

        # 被邀请者视角:S 真根可见,自身计数 = 自身直接 2(回累含其子树,此处无子夹)
        await _invite(client, s["id"], OUTSIDER_ID, level="viewer")
        folders2 = await _list_folders(client, pid, uid=OUTSIDER_ID)
        assert _subtree_by_name(folders2) == {n["name"]: 1, s["name"]: 2}, (
            f"被邀请者视角 S 自身计数应正确: {_subtree_by_name(folders2)}"
        )
    finally:
        await _revoke_invite_best_effort(client, s["id"], OUTSIDER_ID)
        await _hard_cleanup(client, [aid_n, aid_s1, aid_s2], [n["id"], s["id"]])
        await _archive_project(pid)


@pytest.mark.asyncio
async def test_t6_single_get_and_create_always_zero(client: AsyncClient) -> None:
    """T6 契约钉死(方案 §3.4):GET /folders/{id} 单条与 POST /folders 201 的
    subtree_file_count 恒为默认 0 —— 仅 list 端点回填,夹内有文件也不回填。"""
    proj = await _create_project(client, initial_grants=_viewer_grant(OUTSIDER_ID))
    pid = proj["id"]
    folder = await _create_folder(client, pid, _uniq("t6_f"))
    assert folder["subtree_file_count"] == 0, "POST /folders 201 应恒默认 0"
    aid = await _insert_asset(folder["id"], f"t6_{folder['name']}.txt")
    try:
        # 单条(成员视角;200 即证 can_view 经 parent 链成立)有文件仍 0
        r = await client.get(f"/api/v1/folders/{folder['id']}", headers=_h(OUTSIDER_ID))
        assert r.status_code == 200, r.text
        assert r.json()["subtree_file_count"] == 0, (
            f"GET 单条应恒默认 0(仅 list 回填): {r.json()}"
        )
    finally:
        await _hard_cleanup(client, [aid], [folder["id"]])
        await _archive_project(pid)


@pytest.mark.asyncio
async def test_t7_self_chosen_minio_prefix_still_structure_based(client: AsyncClient) -> None:
    """T7 自拟 minio_prefix(方案 §2/§8):客户端建子夹时显式传与结构路径完全
    错位的 minio_prefix,子树口径仍按 parent_folder_id 结构链 —— 防实现退化为
    minio_prefix 前缀匹配(那样 P 的子树会丢掉 C 的文件)。"""
    proj = await _create_project(client, initial_grants=_viewer_grant(OUTSIDER_ID))
    pid = proj["id"]
    p = await _create_folder(client, pid, _uniq("t7_p"))
    bogus_prefix = f"zz_t7_bogus/{_uniq('self_made')}/"
    c = await _create_folder(
        client, pid, _uniq("t7_c"), parent_id=p["id"], minio_prefix=bogus_prefix,
    )
    assert not c["minio_prefix"].startswith(p["minio_prefix"]), "造数自证:前缀刻意错位"
    aid_p = await _insert_asset(p["id"], f"t7_{p['name']}.txt")
    aid_c = await _insert_asset(c["id"], f"t7_{c['name']}.txt")
    try:
        folders = await _list_folders(client, pid, uid=OUTSIDER_ID)
        # P=2(自身直 1 + 结构子 C 的 1):前缀匹配实现会算出 1,在此钉死
        assert _subtree_by_name(folders) == {p["name"]: 2, c["name"]: 1}, (
            f"子树口径必须按 parent_folder_id 而非 minio_prefix: "
            f"{_subtree_by_name(folders)}"
        )
    finally:
        await _hard_cleanup(client, [aid_p, aid_c], [c["id"], p["id"]])
        await _archive_project(pid)


# ══════════════════════════════════════════════════════════════════════════════
# T8:孤儿结构三态(方案 §6.3/§6.4 受众信任边界)+ 链断回归锚
# ══════════════════════════════════════════════════════════════════════════════


@pytest.mark.asyncio
async def test_t8_orphan_private_member_zero_invitee_backfill_and_chain_break(
    client: AsyncClient,
) -> None:
    """T8 变体①(私有项目)+ 链断回归锚(方案 §6.6 前提)。

    结构:S(敏感根,直 3)─ C(普通子夹,直 1)─ G(孙夹,直 2);N(普通根,直 1)= 控制组。
    - 未受邀成员视角:list 200,S 被过滤;C/G 孤儿行**在列**但
      subtree_file_count=0(§6.3:行返回给全体成员而内容链断,回填=泄露规模);
      N=1 不受 S 直下文件影响;
    - 被邀请者(viewer)视角:S 真根可见 → S=3+1+2=6、C=1+2=3、G=2 正常回填
      (§6.4:受众全在信任边界内);
    - 链断回归:被邀请者对 C/G 的 GET /assets?folder_id= 应 403 —— 邀请写的是
      sensitive_folder:<S> 的 tuple,而 C 的 FGA parent 是 folder:<S>(永无
      tuple),can_view(folder:C)=false。若未来有人「修复」该链,本断言与
      孤儿口径全部须回审(方案 §6.6)。

    造数:C/G can_upload 链断,文件一律 DB 直插(见文件头「造数注意」)。
    """
    proj = await _create_project(client, initial_grants=_viewer_grant(OUTSIDER_ID))
    pid = proj["id"]
    s = await _create_folder(client, pid, _uniq("t8_secret"), sensitive=True)
    c = await _create_folder(client, pid, _uniq("t8_child"), parent_id=s["id"])
    g = await _create_folder(client, pid, _uniq("t8_grand"), parent_id=c["id"])
    n = await _create_folder(client, pid, _uniq("t8_normal"))
    aids: list[uuid.UUID] = []
    for i in range(3):
        aids.append(await _insert_asset(s["id"], f"t8_s_{i}.txt"))
    aids.append(await _insert_asset(c["id"], "t8_c_0.txt"))
    for i in range(2):
        aids.append(await _insert_asset(g["id"], f"t8_g_{i}.txt"))
    aids.append(await _insert_asset(n["id"], "t8_n_0.txt"))
    try:
        # ① 未受邀成员视角:孤儿行在列但计数 0(三态之「孤儿行 0」)
        folders = await _list_folders(client, pid, uid=OUTSIDER_ID)
        names = {f["name"] for f in folders}
        assert s["name"] not in names, "未受邀不应见 sensitive 父"
        assert {c["name"], g["name"], n["name"]} <= names, "孤儿行应在返回列表里"
        assert _subtree_by_name(folders) == {c["name"]: 0, g["name"]: 0, n["name"]: 1}, (
            f"孤儿行必须 0、控制组不受影响: {_subtree_by_name(folders)}"
        )

        # ② 被邀请者视角:可见敏感根下正常回填(三态之「回填」)
        await _invite(client, s["id"], OUTSIDER_ID, level="viewer")
        folders2 = await _list_folders(client, pid, uid=OUTSIDER_ID)
        assert _subtree_by_name(folders2) == {
            s["name"]: 6, c["name"]: 3, g["name"]: 2, n["name"]: 1,
        }, f"被邀请者视角应正常回填: {_subtree_by_name(folders2)}"

        # ③ 链断回归锚(§6.6 前提):被邀请者对敏感父下普通子夹/孙夹 403
        for target, label in ((c, "子夹 C"), (g, "孙夹 G")):
            r = await client.get(
                "/api/v1/assets", params={"folder_id": target["id"]}, headers=_h(OUTSIDER_ID),
            )
            assert r.status_code == 403, (
                f"被邀请者对{label}的 GET /assets 应 403(FGA 内容链断,§6.6 前提): "
                f"{r.status_code} {r.text}"
            )
    finally:
        await _revoke_invite_best_effort(client, s["id"], OUTSIDER_ID)
        await _hard_cleanup(client, aids, [g["id"], c["id"], s["id"], n["id"]])
        await _archive_project(pid)


@pytest.mark.asyncio
async def test_t8_orphan_public_variant_under_report_zero(client: AsyncClient) -> None:
    """T8 变体②(public 项目):孤儿行同为 0(§6.3「接受 API 层少报」——
    计数唯一渲染面 FolderTree 不渲染孤儿,0 无受众;统一口径不为窄场景按
    visibility 分支回累)。

    public 项目无项目成员门槛(list_folders 对 public 直通),用无任何角色的
    OUTSIDER 直拍 —— 受众比成员更广,「少报」结论更强。"""
    proj = await _create_project(client)
    pid = proj["id"]
    await _set_project_visibility(pid, "public")
    s = await _create_folder(client, pid, _uniq("t8p_secret"), sensitive=True)
    c = await _create_folder(client, pid, _uniq("t8p_child"), parent_id=s["id"])
    g = await _create_folder(client, pid, _uniq("t8p_grand"), parent_id=c["id"])
    aids: list[uuid.UUID] = []
    for i in range(2):
        aids.append(await _insert_asset(s["id"], f"t8p_s_{i}.txt"))
    aids.append(await _insert_asset(c["id"], "t8p_c_0.txt"))
    aids.append(await _insert_asset(g["id"], "t8p_g_0.txt"))
    try:
        folders = await _list_folders(client, pid, uid=OUTSIDER_ID)
        names = {f["name"] for f in folders}
        assert s["name"] not in names, "未受邀不应见 sensitive 父(public 同)"
        assert {c["name"], g["name"]} <= names, "孤儿行应在返回列表里(public 同)"
        # 同为 0 = 接受 API 层少报(public 变体钉死,防有人「修」成 public 回填)
        assert _subtree_by_name(folders) == {c["name"]: 0, g["name"]: 0}, (
            f"public 孤儿行应同为 0(接受少报): {_subtree_by_name(folders)}"
        )
    finally:
        await _hard_cleanup(client, aids, [g["id"], c["id"], s["id"]])
        await _archive_project(pid)


@pytest.mark.asyncio
async def test_t8_invite_revoke_falls_back_to_zero(client: AsyncClient) -> None:
    """T8 变体③(邀请时间性边界):explicit_invited_* 失效 → 敏感父重新不可见
    → 原回填计数回落 0(三态回到「孤儿行 0」)。

    OpenFGA non_expired_grant 条件的时间到期不可在测试内快进,按派发口径用
    「撤销 explicit invite」等价替代并在此注明:邀请走 duration_seconds 时间
    限定路径(覆盖 explicit_invited_* 分支),撤销删的是同一个条件 tuple,
    权限失效语义等价于到期。"""
    proj = await _create_project(client, initial_grants=_viewer_grant(OUTSIDER_ID))
    pid = proj["id"]
    s = await _create_folder(client, pid, _uniq("t8x_secret"), sensitive=True)
    c = await _create_folder(client, pid, _uniq("t8x_child"), parent_id=s["id"])
    aid_s = await _insert_asset(s["id"], f"t8x_{s['name']}.txt")
    aid_c = await _insert_asset(c["id"], f"t8x_{c['name']}.txt")
    invited = False
    try:
        # 时间限定邀请(explicit_invited_viewer + non_expired_grant 条件)
        await _invite(client, s["id"], OUTSIDER_ID, level="viewer", duration_seconds=3600)
        invited = True
        folders = await _list_folders(client, pid, uid=OUTSIDER_ID)
        assert _subtree_by_name(folders) == {s["name"]: 2, c["name"]: 1}, (
            f"explicit 邀请有效期内应正常回填: {_subtree_by_name(folders)}"
        )

        # 撤销 explicit invite(permanent=False 删 explicit_invited_*)≡ 到期
        await _revoke_invite_best_effort(
            client, s["id"], OUTSIDER_ID, level="viewer", permanent=False,
        )
        invited = False
        folders2 = await _list_folders(client, pid, uid=OUTSIDER_ID)
        assert s["name"] not in {f["name"] for f in folders2}, "邀请失效后敏感父应重新不可见"
        assert _subtree_by_name(folders2) == {c["name"]: 0}, (
            f"原回填应回落 0(孤儿行): {_subtree_by_name(folders2)}"
        )
    finally:
        # 正文已撤销则跳过(重复撤不存在的 tuple 只会刷告警噪音)
        if invited:
            await _revoke_invite_best_effort(
                client, s["id"], OUTSIDER_ID, level="viewer", permanent=False,
            )
        await _hard_cleanup(client, [aid_s, aid_c], [c["id"], s["id"]])
        await _archive_project(pid)
