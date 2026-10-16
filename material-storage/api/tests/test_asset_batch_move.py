"""W6 一期 文件项目内批量移动(POST /api/v1/assets/batch-move)— 集成测试(容器内跑,面向契约)。

唯一需求依据:`docs/qdev/2026-10-17-six-optimizations.md` §3.6(W6 一期 批量移动)+
§4(事件命名 asset_batch_moved)+ §5(测试功能点 W6 行);上游方案
`rushes-spec/material-storage/admin-audit-folder-mobile-optimization-plan.md` §6
(现状基础/实施方案/验收标准)。写法仿 tests/test_batch_prefix.py(httpx
ASGITransport + Evan=系统 admin 直通 + 资产 DB 直插 + 对账恒等式断言)。

契约要点(后端包2并行开发中,冲突以需求文档 §3.6 为准):
  - POST /api/v1/assets/batch-move,body `{asset_ids: [uuid] ≤1000 必填,
    target_folder_id: uuid 必填}`;守门 get_current_user + 逐源夹 FGA 分组 check
  - 返回 200:`{"moved_count": int, "skipped": [{"asset_id", "reason"}],
    "fga_pending": [uuid]}`;**对账恒等式:moved + skipped + fga_pending = 提交数**
  - 校验:整批恰属一个项目否则 400;target_folder.project_id == 批次 project_id
    否则 400;单资产同夹 skip=duplicate_location;软删行不迁;目标夹同名
    (查重排除软删)skip=duplicate_filename;sensitive 目标=敏感夹本身允许
    (can_admin)/目标=敏感后代普通子夹一律禁;sensitive 源/目标门槛 can_admin
  - 物理:object_key 不动,只 UPDATE folder_id;一期无 MinIO 操作
  - FGA:每资产 write+delete 同一 WriteRequest,分批;失败批次进 fga_pending,
    **DB 已 commit 后 FGA 失败不得 500**(fga_pending 路径)
  - 审计 asset_batch_moved(details:from/to folder、成功数、skipped 汇总)
  - D1-B 前置:create_upload 对 (folder_id, filename, 未软删) 已存在 → 409

前置(同 test_batch_prefix.py):seed_demo_data.py 已跑过(Evan = 系统 admin;
outsider = 零权限契约账号);OpenFGA store/model 已 push;env=dev;
PROJECT_EVENT public 项目 bucket=ms-dev 由 seed 建出(create_upload 控制组需要)。
"""
from __future__ import annotations

import json
import uuid
import warnings
from datetime import UTC, datetime
from typing import Any

import pytest
from httpx import ASGITransport, AsyncClient

from app.db.session import get_sessionmaker
from app.db.tables import Asset, AuditEvent, Folder, Organization, Project
from app.main import create_app
from app.settings import get_settings

EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"        # 系统 admin(seed 契约账号)
OUTSIDER_ID = "00000000-0000-0000-0000-0000000000aa"    # 零权限(seed 契约账号)
PROJECT_EVENT = "11111111-1111-1111-1111-111111111103"  # public,bucket=ms-dev

BATCH_MOVE_URL = "/api/v1/assets/batch-move"
UPLOADS_URL = "/api/v1/assets/uploads"

# 契约钉死的 skip reason(§3.6);软删/幽灵行 reason 沿用 batch-prefix「deleted」
# 惯例但文档未钉死,断言只要求条目存在
REASON_DUPLICATE_LOCATION = "duplicate_location"
REASON_DUPLICATE_FILENAME = "duplicate_filename"

# sensitive 目标禁入的契约未钉死状态码(结构禁令,反探测文案惯例)
SENSITIVE_REJECT_CODES = (400, 403, 409)


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


# ─── 建夹 / 直插资产 / 移动 / 读回 / 清理(照 test_batch_prefix 形态)────────────
async def _mkfolder(client: AsyncClient, name: str, *,
                    parent: str | None = None, sensitive: bool = False) -> dict:
    r = await client.post(
        "/api/v1/folders",
        json={"project_id": PROJECT_EVENT, "name": name,
              "parent_folder_id": parent, "is_sensitive": sensitive},
        headers=_h(),
    )
    assert r.status_code == 201, r.text
    return r.json()


async def _insert_asset(folder_id: str, filename: str, *,
                        deleted: bool = False) -> uuid.UUID:
    """直插一条 asset 行(模拟已上传文件;deleted=True 模拟回收站行)。"""
    async with get_sessionmaker()() as db:
        row = Asset(
            id=uuid.uuid4(),
            folder_id=uuid.UUID(folder_id),
            filename=filename,
            minio_bucket="ms-dev",
            minio_key=f"zz-bm/{filename}",
            size_bytes=11,
            content_type="text/plain",
            uploader_id=uuid.UUID(EVAN_ID),
            deleted_at=datetime.now(UTC) if deleted else None,
        )
        db.add(row)
        await db.commit()
        return row.id


async def _folder_id_of(asset_id: uuid.UUID) -> uuid.UUID | None:
    async with get_sessionmaker()() as db:
        row = await db.get(Asset, asset_id)
        return row.folder_id if row else None


async def _batch_move(client: AsyncClient, asset_ids: list[uuid.UUID],
                      target_folder_id: str, *, uid: str = EVAN_ID) -> Any:
    return await client.post(
        BATCH_MOVE_URL,
        json={"asset_ids": [str(a) for a in asset_ids],
              "target_folder_id": target_folder_id},
        headers=_h(uid),
    )


async def _purge_if_exists(client: AsyncClient, asset_id: uuid.UUID) -> None:
    """清场:软删 + 彻底删除(对象不存在,purge 内部 best-effort 吞掉)。"""
    r = await client.delete(f"/api/v1/assets/{asset_id}", headers=_h())
    assert r.status_code in (204, 404), r.text
    r = await client.delete(f"/api/v1/assets/{asset_id}?hard=true", headers=_h())
    assert r.status_code in (204, 404), r.text


async def _cleanup(client: AsyncClient, asset_ids: list[uuid.UUID],
                   folder_ids: list[str]) -> None:
    for aid in asset_ids:
        try:
            await _purge_if_exists(client, aid)
        except AssertionError:
            warnings.warn(f"asset cleanup failed id={aid}", stacklevel=2)
    # 删夹要求空(leaf 先删:调用方按 [根, ..., 叶] 传入,内部 reversed)
    for fid in reversed(folder_ids):
        r = await client.delete(f"/api/v1/folders/{fid}", headers=_h())
        if r.status_code != 204:
            warnings.warn(
                f"folder cleanup failed id={fid} ({r.status_code}): {r.text}",
                stacklevel=2)


def _ensure_project_bucket() -> None:
    """防御:确保 PROJECT_EVENT 的 bucket 在 MinIO 存在(seed 已建,防裸栈缺桶)。"""
    import boto3

    s = get_settings()
    c = boto3.client(
        "s3",
        endpoint_url=s.minio_endpoint_internal,
        aws_access_key_id=s.minio_access_key,
        aws_secret_access_key=s.minio_secret_key,
        region_name="us-east-1",
    )
    try:
        c.head_bucket(Bucket="ms-dev")
    except c.exceptions.ClientError:
        c.create_bucket(Bucket="ms-dev")


# ─── 对账恒等式 + duplicate_location / 软删 / 幽灵行 + 审计 ─────────────────────
@pytest.mark.asyncio
async def test_reconciliation_identity_mixed_batch(client: AsyncClient) -> None:
    """混批:1 可移 + 1 已在目标夹(duplicate_location)+ 1 软删 + 1 幽灵 id →
    200;**恒等式 moved + skipped + fga_pending = 提交数**;各归其位,DB 终态
    与清单一致;写 asset_batch_moved 审计(details 含 from/to folder 与汇总)。"""
    uniq = _uniq("bm_id")
    src = await _mkfolder(client, f"{uniq}_src")
    tgt = await _mkfolder(client, f"{uniq}_tgt")
    a_move = await _insert_asset(src["id"], f"{uniq}_move.txt")
    a_in_tgt = await _insert_asset(tgt["id"], f"{uniq}_inplace.txt")
    a_del = await _insert_asset(src["id"], f"{uniq}_dead.txt", deleted=True)
    ghost = uuid.uuid4()
    t0 = datetime.now(UTC)
    try:
        r = await _batch_move(client, [a_move, a_in_tgt, a_del, ghost], tgt["id"])
        assert r.status_code == 200, r.text
        body = r.json()
        assert set(body) >= {"moved_count", "skipped", "fga_pending"}, body

        # 严格对账恒等式(§3.6):成功 + skipped + fga_pending = 提交数(4)
        assert body["moved_count"] + len(body["skipped"]) \
            + len(body["fga_pending"]) == 4, body
        assert body["moved_count"] == 1
        assert body["fga_pending"] == [], body
        skipped = {e["asset_id"]: e["reason"] for e in body["skipped"]}
        assert set(skipped) == {str(a_in_tgt), str(a_del), str(ghost)}, body
        # 契约钉死的 reason:同夹 = duplicate_location
        assert skipped[str(a_in_tgt)] == REASON_DUPLICATE_LOCATION, body
        # 软删/幽灵条目存在且 reason 非空(命名沿用惯例,契约不钉死)
        assert skipped[str(a_del)] and skipped[str(ghost)], body

        # DB 终态:可移行已迁;软删行不迁(留原地);object_key 不动
        assert await _folder_id_of(a_move) == uuid.UUID(tgt["id"])
        assert await _folder_id_of(a_del) == uuid.UUID(src["id"])

        # 审计 asset_batch_moved:details 可溯源 from/to folder
        async with get_sessionmaker()() as db:
            rows = list((await db.execute(
                AuditEvent.__table__.select().where(
                    AuditEvent.event_type == "asset_batch_moved",
                    AuditEvent.event_time >= t0,
                ).order_by(AuditEvent.event_time.asc())
            )).mappings())
        mine = [dict(r) for r in rows
                if json.dumps(r["details"] or {}, ensure_ascii=False)
                .find(tgt["id"]) >= 0]
        assert mine, f"应写 asset_batch_moved 审计:{len(rows)} rows since t0"
        blob = json.dumps(mine[-1]["details"], ensure_ascii=False)
        assert src["id"] in blob, f"details 应记 from folder:{blob}"
    finally:
        await _cleanup(client, [a_move, a_in_tgt, a_del], [src["id"], tgt["id"]])


# ─── 混批(跨项目)400 / 目标夹异项目 400 ───────────────────────────────────────
@pytest.mark.asyncio
async def test_cross_project_batches_rejected_400(client: AsyncClient) -> None:
    """一期只做项目内:① 整批混两个项目 → 400;② 整批单项目但目标夹在另一
    项目 → 400(显式断言,防「项目内」端点成为事实上的跨项目入口)。"""
    uniq = _uniq("bm_xp")
    src = await _mkfolder(client, f"{uniq}_src")
    tgt = await _mkfolder(client, f"{uniq}_tgt")
    a_local = await _insert_asset(src["id"], f"{uniq}_local.txt")

    # 另一项目(直插 org/project/folder,不产生 FGA 副作用)
    tag = uuid.uuid4().hex[:8]
    async with get_sessionmaker()() as db:
        org = Organization(name=f"it-bm-{tag}", feishu_tenant_key=f"it_bm_{tag}")
        db.add(org)
        await db.flush()
        p2 = Project(organization_id=org.id, code=f"itbm_{tag}",
                     name=f"it-bm-project-{tag}", minio_bucket=f"itbm-{tag}",
                     visibility="private")
        db.add(p2)
        await db.flush()
        f2 = Folder(project_id=p2.id, name="itbm-target",
                    minio_prefix="itbm-target/")
        db.add(f2)
        await db.commit()
        p2_id, f2_id, org_id = p2.id, f2.id, org.id
    async with get_sessionmaker()() as db:
        a_far = Asset(
            id=uuid.uuid4(), folder_id=f2_id, filename=f"{uniq}_far.txt",
            minio_bucket=f"itbm-{tag}", minio_key=f"itbm-target/{uniq}_far.txt",
            size_bytes=11, uploader_id=uuid.UUID(EVAN_ID),
        )
        db.add(a_far)
        await db.commit()
        a_far_id = a_far.id
    try:
        # ① 混批(两项目各一资产)→ 400
        r = await _batch_move(client, [a_local, a_far_id], tgt["id"])
        assert r.status_code == 400, r.text
        # ② 目标夹在另一项目 → 400
        r = await _batch_move(client, [a_local], str(f2_id))
        assert r.status_code == 400, r.text
        # 两次都整批不动
        assert await _folder_id_of(a_local) == uuid.UUID(src["id"])
        assert await _folder_id_of(a_far_id) == f2_id
    finally:
        async with get_sessionmaker()() as db:
            await db.execute(Asset.__table__.delete().where(Asset.id == a_far_id))
            await db.execute(Folder.__table__.delete().where(Folder.id == f2_id))
            await db.execute(Project.__table__.delete().where(Project.id == p2_id))
            await db.execute(Organization.__table__.delete().where(
                Organization.id == org_id))
            await db.commit()
        await _cleanup(client, [a_local], [src["id"], tgt["id"]])


# ─── 形状校验 422(≤1000 必填 / target_folder_id 必填)──────────────────────────
@pytest.mark.asyncio
async def test_payload_shape_422(client: AsyncClient) -> None:
    """空 asset_ids / 缺 target_folder_id / 1001 个 id → 一律 422(形状错误)。"""
    uniq = _uniq("bm_422")
    tgt = await _mkfolder(client, f"{uniq}_tgt")
    try:
        r = await client.post(
            BATCH_MOVE_URL,
            json={"asset_ids": [], "target_folder_id": tgt["id"]}, headers=_h())
        assert r.status_code == 422, r.text

        r = await client.post(
            BATCH_MOVE_URL, json={"asset_ids": [str(uuid.uuid4())]}, headers=_h())
        assert r.status_code == 422, r.text

        r = await client.post(
            BATCH_MOVE_URL,
            json={"asset_ids": [str(uuid.uuid4()) for _ in range(1001)],
                  "target_folder_id": tgt["id"]},
            headers=_h())
        assert r.status_code == 422, r.text
    finally:
        await _cleanup(client, [], [tgt["id"]])


# ─── 同名 skip(duplicate_filename),查重排除软删 ───────────────────────────────
@pytest.mark.asyncio
async def test_duplicate_filename_skip_and_soft_deleted_excluded(
    client: AsyncClient,
) -> None:
    """目标夹已有同 filename 活资产 → skip=duplicate_filename,不产生同夹同名;
    软删行**不参与查重**(百度口径)—— 把目标的同名行软删后重提,应能迁入。"""
    uniq = _uniq("bm_dup")
    src = await _mkfolder(client, f"{uniq}_src")
    tgt = await _mkfolder(client, f"{uniq}_tgt")
    fname = f"{uniq}_same.txt"
    a_tgt_live = await _insert_asset(tgt["id"], fname)
    a_src = await _insert_asset(src["id"], fname)
    try:
        # 第一轮:目标有同名活行 → skip,原夹不动
        r = await _batch_move(client, [a_src], tgt["id"])
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["moved_count"] == 0 and body["fga_pending"] == [], body
        skipped = {e["asset_id"]: e["reason"] for e in body["skipped"]}
        assert skipped == {str(a_src): REASON_DUPLICATE_FILENAME}, body
        assert body["moved_count"] + len(body["skipped"]) \
            + len(body["fga_pending"]) == 1
        assert await _folder_id_of(a_src) == uuid.UUID(src["id"])

        # 第二轮:目标同名行软删(回收站)→ 查重排除软删,迁入放行
        r = await client.delete(f"/api/v1/assets/{a_tgt_live}", headers=_h())
        assert r.status_code == 204, r.text
        r = await _batch_move(client, [a_src], tgt["id"])
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["moved_count"] == 1
        assert body["skipped"] == [] and body["fga_pending"] == [], body
        assert await _folder_id_of(a_src) == uuid.UUID(tgt["id"])
    finally:
        await _cleanup(client, [a_src, a_tgt_live], [src["id"], tgt["id"]])


# ─── sensitive 目标规则:敏感夹本身允许(can_admin)/敏感后代一律禁;
#     sensitive 源门槛 can_admin(downloader 不够)────────────────────────────────
@pytest.mark.asyncio
async def test_sensitive_target_and_source_rules(client: AsyncClient) -> None:
    uniq = _uniq("bm_sens")
    src = await _mkfolder(client, f"{uniq}_src")
    sens = await _mkfolder(client, f"{uniq}_s", sensitive=True)
    inner = await _mkfolder(client, f"{uniq}_in", parent=sens["id"])  # 孤儿位子夹
    a_to_sens = await _insert_asset(src["id"], f"{uniq}_a.txt")
    a_to_inner = await _insert_asset(src["id"], f"{uniq}_b.txt")

    # sensitive 源门槛:outsider 受邀 downloader(= can_upload 但非 can_admin)
    s2 = await _mkfolder(client, f"{uniq}_s2", sensitive=True)
    a_in_s2 = await _insert_asset(s2["id"], f"{uniq}_c.txt")
    inv = await client.post(
        f"/api/v1/folders/{s2['id']}/invite",
        json={"user_id": OUTSIDER_ID, "level": "downloader"},
        headers=_h(),
    )
    assert inv.status_code == 204, inv.text
    try:
        # ① 目标 = sensitive 夹本身 → 允许(can_admin;资产本可存于敏感夹)
        r = await _batch_move(client, [a_to_sens], sens["id"])
        assert r.status_code == 200, r.text
        assert r.json()["moved_count"] == 1 and r.json()["fga_pending"] == [], r.text
        assert await _folder_id_of(a_to_sens) == uuid.UUID(sens["id"])

        # ② 目标 = sensitive 后代的普通子夹(孤儿位)→ 一律禁(含系统 admin)
        r = await _batch_move(client, [a_to_inner], inner["id"])
        assert r.status_code in SENSITIVE_REJECT_CODES, r.text
        assert await _folder_id_of(a_to_inner) == uuid.UUID(src["id"])

        # ③ sensitive 源 + 目标普通夹:outsider 只有 downloader(can_upload)→ 403
        r = await _batch_move(client, [a_in_s2], src["id"], uid=OUTSIDER_ID)
        assert r.status_code == 403, (
            f"sensitive 源门槛应为 can_admin(downloader 不够):{r.text}")
        assert await _folder_id_of(a_in_s2) == uuid.UUID(s2["id"])
    finally:
        # 撤销 outsider 对 s2 的邀请(残留 tuple 会漏权限)
        rev = await client.delete(
            f"/api/v1/folders/{s2['id']}/invite",
            params={"subject": f"user:{OUTSIDER_ID}", "level": "downloader",
                    "permanent": "true"},
            headers=_h(),
        )
        if rev.status_code != 204:
            warnings.warn(
                f"sensitive invite cleanup failed ({rev.status_code}): {rev.text};"
                f" outsider 对 {s2['id']} 残留 invited_downloader tuple",
                stacklevel=2,
            )
        await _cleanup(client, [a_to_sens, a_to_inner, a_in_s2],
                       [src["id"], sens["id"], s2["id"], inner["id"]])


# ─── fga_pending 路径:FGA write 全挂 → 200 + 分叉清单,DB 不回滚不 500 ──────────
@pytest.mark.asyncio
async def test_fga_pending_when_fga_write_fails(
    client: AsyncClient, app_with_lifespan, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """契约红线:DB commit 成功后 FGA 失败**不得 500** —— 该批资产进 fga_pending,
    恒等式仍闭合,DB 已迁(folder_id 已更新),等后台幂等巡检兜底。

    打桩方式:对 app.state.permissions 的 OpenFGA client 的写方法整体置炸
    (check/read 不受影响,权限判定照常走;仓库既有 FGA 写路径是
    client.write / write_tuples,见 assets.py purge 先例)。"""
    uniq = _uniq("bm_fga")
    src = await _mkfolder(client, f"{uniq}_src")
    tgt = await _mkfolder(client, f"{uniq}_tgt")
    a1 = await _insert_asset(src["id"], f"{uniq}_1.txt")
    a2 = await _insert_asset(src["id"], f"{uniq}_2.txt")

    async def _boom(*args: Any, **kwargs: Any) -> None:
        raise RuntimeError("simulated openfga outage (test stub)")

    perms = app_with_lifespan.state.permissions
    monkeypatch.setattr(perms._client, "write", _boom, raising=False)
    monkeypatch.setattr(perms._client, "write_tuples", _boom, raising=False)
    try:
        r = await _batch_move(client, [a1, a2], tgt["id"])
        assert r.status_code == 200, f"FGA 失败不得 500:{r.status_code} {r.text}"
        body = r.json()
        # 恒等式在分叉形态下仍闭合:0 + 0 + 2 = 2
        assert body["moved_count"] + len(body["skipped"]) \
            + len(body["fga_pending"]) == 2, body
        assert body["moved_count"] == 0 and body["skipped"] == [], body
        assert set(body["fga_pending"]) == {str(a1), str(a2)}, body

        # DB 已 commit:两行 folder_id 都已迁到目标夹(key 不动)
        assert await _folder_id_of(a1) == uuid.UUID(tgt["id"])
        assert await _folder_id_of(a2) == uuid.UUID(tgt["id"])
    finally:
        monkeypatch.undo()
        await _cleanup(client, [a1, a2], [src["id"], tgt["id"]])


# ─── D1-B 前置:create_upload 同夹同名(未软删)→ 409 ────────────────────────────
@pytest.mark.asyncio
async def test_create_upload_duplicate_filename_409(client: AsyncClient) -> None:
    """上传侧同名查重:目标夹已有同 filename 活资产 → create_upload 409;
    软删行不拦(回收站语义);不同名控制组 200(随即 abort 不留会话)。"""
    _ensure_project_bucket()
    uniq = _uniq("bm_up")
    tgt = await _mkfolder(client, f"{uniq}_tgt")
    fname = f"{uniq}_dup.txt"
    a_live = await _insert_asset(tgt["id"], fname)
    a_dead = await _insert_asset(tgt["id"], f"{uniq}_dead.txt", deleted=True)
    try:
        # 同夹同名(活行)→ 409
        r = await client.post(
            UPLOADS_URL,
            json={"folder_id": tgt["id"], "filename": fname, "size_bytes": 1},
            headers=_h(),
        )
        assert r.status_code == 409, r.text

        # 控制组:不同名 → 200(拿到 key 后立即 abort)
        r2 = await client.post(
            UPLOADS_URL,
            json={"folder_id": tgt["id"], "filename": f"{uniq}_fresh.txt",
                  "size_bytes": 1},
            headers=_h(),
        )
        assert r2.status_code == 200, r2.text
        r3 = await client.delete(
            f"{UPLOADS_URL}/{r2.json()['upload_id']}",
            params={"bucket": r2.json()["bucket"], "key": r2.json()["key"]},
            headers=_h(),
        )
        assert r3.status_code == 204, r3.text
    finally:
        await _cleanup(client, [a_live, a_dead], [tgt["id"]])
