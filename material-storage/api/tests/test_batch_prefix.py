"""PR-1 批量文件名前缀(POST /api/v1/assets/batch-prefix)— 集成测试,容器内跑。

对应方案:`rushes-spec/material-storage/netdisk-import-batch-rename-roles-plan.md`
§1.1(API 契约与语义:五类 skipped_reasons、NFC 两侧归一、逐 id UPDATE + 对账)、
§1.4(测试清单);实施文档 `docs/qdev/2026-10-08-batch-prefix-creator-template.md` PR-1。

用例 → 测试函数对照(§1.4 清单逐条落函数):
  1. add 全成功 + audit `asset.batch_renamed` 采样  → test_batch_prefix_add_all_renamed_and_audit
  2. add 时已带前缀跳过(already_prefixed,不叠双层)→ test_batch_prefix_add_already_prefixed_skipped
  3. remove 部分匹配(no_match / empty_result)      → test_batch_prefix_remove_partial_matches
  4. NFD 存量名 + NFC 前缀两侧归一命中              → test_batch_prefix_nfd_filename_cross_normalization
  5. 无权限 outsider 403(笼统文案 + access_denied)→ test_batch_prefix_forbidden_outsider_generic_403_and_audit
  6. 形状校验 422(>1000 / 空列表 / prefix 非法)    → test_batch_prefix_payload_shape_422
  7. 超长跳过(too_long)+ 重复 id 去重              → test_batch_prefix_too_long_skip_and_duplicate_ids_dedup
  8. 软删跳过(预置 + SELECT/UPDATE 间并发软删)     → test_batch_prefix_soft_deleted_skipped
                                                      test_batch_prefix_soft_deleted_between_select_and_update
  9. 敏感夹按 sensitive_folder check                → test_batch_prefix_sensitive_folder_permission
  10. labels_mode=merge 并集 + 默认 replace 不变    → test_meta_labels_mode_merge_and_default_replace
                                                      test_meta_labels_mode_merge_cap_50
  11. 对账 renamed + skipped == 去重后提交数        → test_batch_prefix_reconciliation_add_mixed

预期前置(同 test_v4_permissions.py / test_trash_and_purge.py):
  1. seed_demo_data.py 已跑过(Evan = 系统 admin;outsider = 无任何权限的契约账号)
  2. OpenFGA store / model 已 push
  3. env=dev(允许 X-User-Id header 模拟身份)

资产入库存走 DB 直插(presign 的 PUT 指向 MinIO 公网 endpoint,容器内不通,
与 test_trash_and_purge 同理由);批量改名是纯 DB 操作,不触 MinIO。
"""
from __future__ import annotations

import asyncio
import uuid
import warnings
from datetime import datetime, timezone

import pytest
from httpx import ASGITransport, AsyncClient, Response
from sqlalchemy import select, update

from app.db.session import get_sessionmaker
from app.db.tables import Asset, AuditEvent
from app.main import create_app

EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"          # 系统 admin(org admin)
OUTSIDER_ID = "00000000-0000-0000-0000-0000000000aa"      # 无任何角色的契约账号
PROJECT_EVENT = "11111111-1111-1111-1111-111111111103"    # public

# 「é」的两种 Unicode 形式:NFD 组合字符(macOS 拖入落库原样)/ NFC 预组合
NFD_E = "e\u0301"
NFC_E = "\u00e9"

# skipped_reasons 五个键,方案 §1.1 写死(键固定 ASCII,前端做中文映射)
SKIPPED_KEYS = {"too_long", "no_match", "already_prefixed", "empty_result", "deleted"}


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


# ─── 建夹 / 直插资产 / 读回 / 清理(照 test_trash_and_purge 形态)────────────────
async def _create_folder(
    client: AsyncClient, project_id: str, name: str, *, sensitive: bool = False,
) -> dict:
    r = await client.post(
        "/api/v1/folders",
        json={"project_id": project_id, "name": name, "is_sensitive": sensitive},
        headers=_h(),
    )
    assert r.status_code == 201, r.text
    return r.json()


async def _insert_asset(
    folder_id: str, filename: str, *, deleted: bool = False,
    labels: list[str] | None = None,
) -> uuid.UUID:
    """直插一条 asset 行(模拟已上传文件;deleted=True 模拟软删后的回收站行)。"""
    async with get_sessionmaker()() as db:
        row = Asset(
            id=uuid.uuid4(),
            folder_id=uuid.UUID(folder_id),
            filename=filename,
            minio_bucket="ms-dev",
            minio_key=f"zz-test/{filename}",
            size_bytes=11,
            content_type="text/plain",
            uploader_id=uuid.UUID(EVAN_ID),
            deleted_at=datetime.now(timezone.utc) if deleted else None,
            user_labels=labels or [],
        )
        db.add(row)
        await db.commit()
        return row.id


async def _get_asset_core(asset_id: uuid.UUID) -> tuple[str, str]:
    """读回 (filename, minio_key)(行必须存在;batch 改名不得动 MinIO key)。"""
    async with get_sessionmaker()() as db:
        row = await db.get(Asset, asset_id)
        assert row is not None, f"asset {asset_id} 应仍在库中"
        return row.filename, row.minio_key


async def _filename_of(asset_id: uuid.UUID) -> str:
    async with get_sessionmaker()() as db:
        row = await db.get(Asset, asset_id)
        assert row is not None
        return row.filename


async def _labels_of(asset_id: uuid.UUID) -> list[str]:
    async with get_sessionmaker()() as db:
        row = await db.get(Asset, asset_id)
        assert row is not None
        return list(row.user_labels or [])


async def _hard_cleanup(client: AsyncClient, asset_ids: list[uuid.UUID], folder_ids: list[str]) -> None:
    """软删 + 彻底删除测试资产,再删空 folder(删夹要求无活文件且回收站空)。"""
    for aid in asset_ids:
        r = await client.delete(f"/api/v1/assets/{aid}", headers=_h())
        assert r.status_code == 204, r.text
        r = await client.delete(f"/api/v1/assets/{aid}?hard=true", headers=_h())
        assert r.status_code == 204, r.text
    for fid in folder_ids:
        r = await client.delete(f"/api/v1/folders/{fid}", headers=_h())
        assert r.status_code == 204, r.text


async def _batch_prefix(
    client: AsyncClient, asset_ids: list[uuid.UUID], action: str, prefix: str,
    *, uid: str = EVAN_ID,
) -> Response:
    return await client.post(
        "/api/v1/assets/batch-prefix",
        json={
            "asset_ids": [str(a) for a in asset_ids],
            "action": action,
            "prefix": prefix,
        },
        headers=_h(uid),
    )


async def _audit_since(event_type: str, since: datetime, *, actor: str | None = None) -> list[AuditEvent]:
    """拉某 event_type 在 since 之后的 audit 行(可选按 actor 过滤),时间升序。"""
    stmt = select(AuditEvent).where(
        AuditEvent.event_type == event_type,
        AuditEvent.event_time >= since,
    )
    if actor is not None:
        stmt = stmt.where(AuditEvent.actor_user_id == uuid.UUID(actor))
    stmt = stmt.order_by(AuditEvent.event_time.asc())
    async with get_sessionmaker()() as db:
        return list((await db.execute(stmt)).scalars().all())


def _find_sample_list(details: dict) -> list | None:
    """在 audit details 里找「采样明细」列表(元素含 id 与 old/new 的 dict)。

    方案 §1.1 只约定采样内容为 {id, old, new} 前 50 条,未写死外层键名,
    这里按形状探测,不断言外层键(避免过度约束实现命名)。
    """
    for value in details.values():
        if (
            isinstance(value, list) and value
            and isinstance(value[0], dict)
            and "id" in value[0] and ("old" in value[0] or "new" in value[0])
        ):
            return value
    return None


# ─── 用例 1:add 全成功 + asset.batch_renamed 聚合 audit ───────────────────────
@pytest.mark.asyncio
async def test_batch_prefix_add_all_renamed_and_audit(client: AsyncClient) -> None:
    """多文件 add 全部改名:filename 落库为 NFC(prefix + filename)、renamed 计数、
    audit `asset.batch_renamed` 落库(action / prefix / renamed / skipped + 采样明细)、
    MinIO key 不动(纯 DB 改名)。"""
    uniq = _uniq("zz_bp_add")
    folder = await _create_folder(client, PROJECT_EVENT, uniq)
    aid1 = await _insert_asset(folder["id"], f"{uniq}_a1.txt")
    aid2 = await _insert_asset(folder["id"], f"{uniq}_a2.txt")
    t0 = datetime.now(timezone.utc)
    try:
        r = await _batch_prefix(client, [aid1, aid2], "add", f"{uniq}_P_")
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["renamed"] == 2
        assert body["skipped"] == 0
        # 五个 skipped_reasons 键固定存在且全 0(方案 §1.1:键固定 ASCII)
        assert set(body["skipped_reasons"]) == SKIPPED_KEYS
        assert all(v == 0 for v in body["skipped_reasons"].values())

        # 落库文件名 = prefix + filename(ASCII 场景 NFC 即原样);MinIO key 不动
        fname1, key1 = await _get_asset_core(aid1)
        assert fname1 == f"{uniq}_P_{uniq}_a1.txt"
        assert key1 == f"zz-test/{uniq}_a1.txt"
        assert (await _filename_of(aid2)) == f"{uniq}_P_{uniq}_a2.txt"

        # 聚合 audit:asset.batch_renamed,含 action / prefix / renamed / skipped / 采样
        rows = [e for e in await _audit_since("asset.batch_renamed", t0)
                if e.details.get("prefix") == f"{uniq}_P_"]
        assert rows, "应落一条 asset.batch_renamed audit"
        details = rows[-1].details
        assert details.get("action") == "add"
        assert details.get("renamed") == 2
        assert details.get("skipped") == 0
        samples = _find_sample_list(details)
        assert samples is not None, f"audit 采样明细缺失: {details}"
        by_id = {str(s.get("id")): s for s in samples}
        s1 = by_id[str(aid1)]
        assert s1.get("old") == f"{uniq}_a1.txt"
        assert s1.get("new") == f"{uniq}_P_{uniq}_a1.txt"
    finally:
        await _hard_cleanup(client, [aid1, aid2], [folder["id"]])


# ─── 用例 2:add 时已带前缀跳过(不叠双层)────────────────────────────────────────
@pytest.mark.asyncio
async def test_batch_prefix_add_already_prefixed_skipped(client: AsyncClient) -> None:
    """add:已带该前缀的文件计 already_prefixed 且原样不动(不出现双层前缀);
    未带的正常改名。"""
    uniq = _uniq("zz_bp_ap")
    folder = await _create_folder(client, PROJECT_EVENT, uniq)
    prefix = f"{uniq}_P_"
    aid_ap = await _insert_asset(folder["id"], f"{prefix}already.txt")  # 已带前缀
    aid_new = await _insert_asset(folder["id"], f"{uniq}_fresh.txt")
    try:
        r = await _batch_prefix(client, [aid_ap, aid_new], "add", prefix)
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["renamed"] == 1
        assert body["skipped"] == 1
        assert body["skipped_reasons"]["already_prefixed"] == 1

        # 已带前缀的原样保留(绝不是 prefix + prefix + already.txt)
        assert (await _filename_of(aid_ap)) == f"{prefix}already.txt"
        assert (await _filename_of(aid_new)) == f"{prefix}{uniq}_fresh.txt"
    finally:
        await _hard_cleanup(client, [aid_ap, aid_new], [folder["id"]])


# ─── 用例 3:remove 部分匹配(命中剥离一次 / no_match / empty_result)───────────
@pytest.mark.asyncio
async def test_batch_prefix_remove_partial_matches(client: AsyncClient) -> None:
    """remove:恰好以 prefix 开头的剥离一次;不匹配计 no_match;剥离后空串计
    empty_result;对账 renamed + skipped == 提交数。"""
    uniq = _uniq("zz_bp_rm")
    folder = await _create_folder(client, PROJECT_EVENT, uniq)
    prefix = f"{uniq}_P_"
    aid_hit = await _insert_asset(folder["id"], f"{prefix}hit.txt")
    aid_miss = await _insert_asset(folder["id"], f"{uniq}_miss.txt")
    aid_empty = await _insert_asset(folder["id"], prefix)  # 剥离后变空串
    try:
        r = await _batch_prefix(client, [aid_hit, aid_miss, aid_empty], "remove", prefix)
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["renamed"] == 1
        assert body["skipped"] == 2
        assert body["skipped_reasons"]["no_match"] == 1
        assert body["skipped_reasons"]["empty_result"] == 1
        # 对账(用例 11 的逐请求形态):renamed + skipped == 提交数
        assert body["renamed"] + body["skipped"] == 3

        assert (await _filename_of(aid_hit)) == "hit.txt"
        assert (await _filename_of(aid_miss)) == f"{uniq}_miss.txt"
        assert (await _filename_of(aid_empty)) == prefix  # 空串结果不落库
    finally:
        await _hard_cleanup(client, [aid_hit, aid_miss, aid_empty], [folder["id"]])


# ─── 用例 4:NFD 存量名 + NFC 前缀两侧归一命中 ──────────────────────────────────
@pytest.mark.asyncio
async def test_batch_prefix_nfd_filename_cross_normalization(client: AsyncClient) -> None:
    """NFC 归一是两侧的:存量 NFD 形式文件名(macOS 拖入原样落库)与 NFC 前缀
    比较前须归一 — remove 要能命中(余量按 NFC 码点切),add 的 already_prefixed
    判定同样跨形式命中(不叠双层)。"""
    uniq = _uniq("zz_bp_nfd")
    folder = await _create_folder(client, PROJECT_EVENT, uniq)
    # NFD 存量名:"é" 写成 e + 组合尖音符(U+0301),码点 2 个
    aid_rm = await _insert_asset(folder["id"], f"{NFD_E}{uniq}_etude.txt")
    # 已带「NFD 形式前缀」的存量,add NFC 前缀时应判 already_prefixed
    aid_ap = await _insert_asset(folder["id"], f"{NFD_E}{uniq}_has.txt")
    try:
        # remove:NFC 前缀命中 NFD 存量名
        r = await _batch_prefix(client, [aid_rm], "remove", NFC_E)
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["renamed"] == 1
        assert body["skipped_reasons"]["no_match"] == 0
        # 余量 = NFC(filename)[len(prefix_nfc):](不能按原串字节/码点切)
        assert (await _filename_of(aid_rm)) == f"{uniq}_etude.txt"

        # add:已带前缀(NFD 形式)跨归一判定 already_prefixed,不叠双层
        r2 = await _batch_prefix(client, [aid_ap], "add", NFC_E)
        assert r2.status_code == 200, r2.text
        body2 = r2.json()
        assert body2["renamed"] == 0
        assert body2["skipped_reasons"]["already_prefixed"] == 1
        assert (await _filename_of(aid_ap)) == f"{NFD_E}{uniq}_has.txt"
    finally:
        await _hard_cleanup(client, [aid_rm, aid_ap], [folder["id"]])


# ─── 用例 5:无权限 outsider → 403 笼统文案 + access_denied audit ──────────────
@pytest.mark.asyncio
async def test_batch_prefix_forbidden_outsider_generic_403_and_audit(client: AsyncClient) -> None:
    """无 can_upload 的用户 → 403 整批不执行;文案笼统(不含 folder 名 / 文件名,
    反探测约定);写 access_denied audit。"""
    uniq = _uniq("zz_bp_403")
    folder = await _create_folder(client, PROJECT_EVENT, uniq)
    aid = await _insert_asset(folder["id"], f"{uniq}_secret.txt")
    t0 = datetime.now(timezone.utc)
    try:
        r = await _batch_prefix(client, [aid], "add", "P_", uid=OUTSIDER_ID)
        assert r.status_code == 403, r.text
        detail = r.json()["detail"]
        # 笼统文案:不暴露 folder 名与文件名
        assert folder["name"] not in detail
        assert f"{uniq}_secret" not in detail
        # 整批不执行:文件名原样
        assert (await _filename_of(aid)) == f"{uniq}_secret.txt"

        # access_denied audit 落库
        denied = await _audit_since("access_denied", t0, actor=OUTSIDER_ID)
        assert denied, "403 应写 access_denied audit"
    finally:
        await _hard_cleanup(client, [aid], [folder["id"]])


# ─── 用例 6:形状校验 422 ────────────────────────────────────────────────────────
@pytest.mark.asyncio
async def test_batch_prefix_payload_shape_422(client: AsyncClient) -> None:
    """>1000 个 asset_ids / 空列表 / prefix 含 "/" 或控制字符或 strip 后为空 /
    空 prefix / 超 128 → 一律 422(形状错误,不触权限与业务)。"""
    uniq = _uniq("zz_bp_422")
    folder = await _create_folder(client, PROJECT_EVENT, uniq)
    aid = await _insert_asset(folder["id"], f"{uniq}_shape.txt")
    try:
        # 1001 个 id(上限 1000)
        r = await _batch_prefix(client, [uuid.uuid4() for _ in range(1001)], "add", "P_")
        assert r.status_code == 422, r.text

        # 空列表(下限 1)
        r = await _batch_prefix(client, [], "add", "P_")
        assert r.status_code == 422, r.text

        # prefix 含 "/"
        r = await _batch_prefix(client, [aid], "add", "a/b")
        assert r.status_code == 422, r.text

        # prefix 含控制字符(BEL)
        r = await _batch_prefix(client, [aid], "add", "a\u0007b")
        assert r.status_code == 422, r.text

        # prefix strip 后为空
        r = await _batch_prefix(client, [aid], "add", "   ")
        assert r.status_code == 422, r.text

        # prefix 空串 / 超 128(Pydantic 长度边界)
        r = await _batch_prefix(client, [aid], "add", "")
        assert r.status_code == 422, r.text
        r = await _batch_prefix(client, [aid], "add", "x" * 129)
        assert r.status_code == 422, r.text

        # 全部被拦:文件名未动
        assert (await _filename_of(aid)) == f"{uniq}_shape.txt"
    finally:
        await _hard_cleanup(client, [aid], [folder["id"]])


# ─── 用例 7:超长跳过(too_long)+ 重复 id 去重 ─────────────────────────────────
@pytest.mark.asyncio
async def test_batch_prefix_too_long_skip_and_duplicate_ids_dedup(client: AsyncClient) -> None:
    """add 结果 >512 计 too_long 原样跳过(=512 恰好可改,边界含);同一 id 重复
    提交只计一次(防重复计入 deleted / renamed)。"""
    uniq = _uniq("zz_bp_long")
    folder = await _create_folder(client, PROJECT_EVENT, uniq)
    long_name = "L" * 511  # 库内可行(≤512),add 2 字符前缀 → 513 > 512
    aid_long = await _insert_asset(folder["id"], long_name)
    edge_name = "E" * 510  # add 2 字符前缀 → 恰好 512,应成功
    aid_edge = await _insert_asset(folder["id"], edge_name)
    aid_dup = await _insert_asset(folder["id"], f"{uniq}_dup.txt")
    try:
        # too_long:>512 跳过
        r = await _batch_prefix(client, [aid_long], "add", "AB")
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["renamed"] == 0
        assert body["skipped"] == 1
        assert body["skipped_reasons"]["too_long"] == 1
        assert (await _filename_of(aid_long)) == long_name

        # 边界:结果恰 512 → 正常改名
        r_edge = await _batch_prefix(client, [aid_edge], "add", "AB")
        assert r_edge.status_code == 200, r_edge.text
        assert r_edge.json()["renamed"] == 1
        assert (await _filename_of(aid_edge)) == "AB" + edge_name

        # 重复 id 提交只计一次:renamed + skipped == 去重后提交数(1)
        r2 = await _batch_prefix(client, [aid_dup, aid_dup], "add", "P_")
        assert r2.status_code == 200, r2.text
        body2 = r2.json()
        assert body2["renamed"] == 1
        assert body2["skipped"] == 0
        assert body2["renamed"] + body2["skipped"] == 1
        # 前缀只叠一层
        assert (await _filename_of(aid_dup)) == f"P_{uniq}_dup.txt"
    finally:
        await _hard_cleanup(client, [aid_long, aid_edge, aid_dup], [folder["id"]])


# ─── 用例 8a:软删文件跳过(预置 deleted_at)────────────────────────────────────
@pytest.mark.asyncio
async def test_batch_prefix_soft_deleted_skipped(client: AsyncClient) -> None:
    """回收站文件(deleted_at 非空)不在 SELECT 结果里 → 计入 deleted 桶,
    文件名原样(天然跳过)。"""
    uniq = _uniq("zz_bp_del")
    folder = await _create_folder(client, PROJECT_EVENT, uniq)
    aid = await _insert_asset(folder["id"], f"{uniq}_trashed.txt", deleted=True)
    try:
        r = await _batch_prefix(client, [aid], "add", "P_")
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["renamed"] == 0
        assert body["skipped"] == 1
        assert body["skipped_reasons"]["deleted"] == 1
        assert (await _filename_of(aid)) == f"{uniq}_trashed.txt"

        # 幽灵 id(不存在)同样归 deleted 桶,不细分(方案 §1.1)
        r2 = await _batch_prefix(client, [uuid.uuid4()], "add", "P_")
        assert r2.status_code == 200, r2.text
        assert r2.json()["skipped_reasons"]["deleted"] == 1
    finally:
        await _hard_cleanup(client, [aid], [folder["id"]])


# ─── 用例 8b:SELECT 与 UPDATE 间并发软删 → 对账进 deleted 桶 ───────────────────
@pytest.mark.asyncio
async def test_batch_prefix_soft_deleted_between_select_and_update(client: AsyncClient) -> None:
    """模拟 SELECT 与逐 id UPDATE 之间的并发软删窗口:

    ① 测试连接先 SELECT ... FOR UPDATE 锁住目标行(事务不提交);
    ② 后台发起 batch-prefix:其 SELECT(MVCC,不加锁)看到活行并算好新名,
       逐 id UPDATE 在行锁上阻塞;
    ③ 测试连接在持锁事务内直接 UPDATE 置 deleted_at 并提交(即「SELECT 与
       UPDATE 之间夹塞的软删」);
    ④ endpoint 的 UPDATE 恢复后按 READ COMMITTED 对新行版本复检
       `deleted_at IS NULL` → 0 行 → 对账归入 deleted 桶。

    行锁保证次序确定:请求的 UPDATE 必然晚于软删提交,断言无竞态。
    """
    uniq = _uniq("zz_bp_race")
    folder = await _create_folder(client, PROJECT_EVENT, uniq)
    name = f"{uniq}_race.txt"
    aid = await _insert_asset(folder["id"], name)
    try:
        async with get_sessionmaker()() as locker:
            # ① 行锁(事务保持打开)
            await locker.execute(select(Asset).where(Asset.id == aid).with_for_update())
            # ② 后台发请求;稍候片刻让它走完 FGA check + SELECT、停在 UPDATE 上
            #    (仅缩短持锁时间,正确性不依赖此时长 —— 行锁保证次序)
            task = asyncio.create_task(_batch_prefix(client, [aid], "add", "P_"))
            await asyncio.sleep(0.3)
            # ③ 同事务内软删并提交(自持锁,不阻塞;提交即放锁)
            await locker.execute(
                update(Asset).where(Asset.id == aid).values(
                    deleted_at=datetime.now(timezone.utc),
                )
            )
            await locker.commit()
        # ④ 请求返回:该 id 应对账进 deleted 桶
        r = await asyncio.wait_for(task, timeout=30)
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["renamed"] == 0
        assert body["skipped"] == 1
        assert body["skipped_reasons"]["deleted"] == 1
        assert (await _filename_of(aid)) == name
    finally:
        # 已软删的行:第一个 DELETE 幂等 204,再 hard purge 清场
        await _hard_cleanup(client, [aid], [folder["id"]])


# ─── 用例 9:敏感夹按 sensitive_folder 类型 check ───────────────────────────────
@pytest.mark.asyncio
async def test_batch_prefix_sensitive_folder_permission(client: AsyncClient) -> None:
    """敏感夹批量改名走 sensitive_folder 类型 check:未受邀者 403;受邀
    downloader 亦有改名能力(sensitive 的 can_upload = can_download)。"""
    uniq = _uniq("zz_bp_sens")
    folder = await _create_folder(client, PROJECT_EVENT, uniq, sensitive=True)
    aid = await _insert_asset(folder["id"], f"{uniq}_sens.txt")
    try:
        # 未受邀 → 403(整批不执行)
        r = await _batch_prefix(client, [aid], "add", "S_", uid=OUTSIDER_ID)
        assert r.status_code == 403, r.text
        assert (await _filename_of(aid)) == f"{uniq}_sens.txt"

        # 受邀 downloader(sensitive 邀请制)→ can_upload 生效,可批量改名
        inv = await client.post(
            f"/api/v1/folders/{folder['id']}/invite",
            json={"user_id": OUTSIDER_ID, "level": "downloader"},
            headers=_h(),
        )
        assert inv.status_code == 204, inv.text
        try:
            r2 = await _batch_prefix(client, [aid], "add", "S_", uid=OUTSIDER_ID)
            assert r2.status_code == 200, r2.text
            body = r2.json()
            assert body["renamed"] == 1
            assert (await _filename_of(aid)) == f"S_{uniq}_sens.txt"
        finally:
            # 清理:撤销邀请,不污染后续测试(outsider 残留 tuple 会漏权限)
            rev = await client.delete(
                f"/api/v1/folders/{folder['id']}/invite",
                params={"subject": f"user:{OUTSIDER_ID}", "level": "downloader",
                        "permanent": "true"},
                headers=_h(),
            )
            if rev.status_code != 204:
                warnings.warn(
                    f"sensitive invite cleanup failed ({rev.status_code}): {rev.text};"
                    f" outsider 对 {folder['id']} 残留 invited_downloader tuple",
                    stacklevel=2,
                )
    finally:
        await _hard_cleanup(client, [aid], [folder["id"]])


# ─── 用例 10:labels_mode=merge 并集 + 默认 replace 不变 ────────────────────────
@pytest.mark.asyncio
async def test_meta_labels_mode_merge_and_default_replace(client: AsyncClient) -> None:
    """PATCH /assets/{id}/meta 增 labels_mode:
    - 缺省(与显式 replace)= 整条替换,现行为不变;
    - merge = DB 现值在前取并集、顺序写死、去重;
    - 非法 labels_mode → 422(Literal)。"""
    uniq = _uniq("zz_bp_lbl")
    folder = await _create_folder(client, PROJECT_EVENT, uniq)
    aid = await _insert_asset(folder["id"], f"{uniq}_lbl.txt",
                              labels=["existing_a", "existing_b"])
    try:
        # 缺省 = replace:整条替换(现行为不变)
        r = await client.patch(
            f"/api/v1/assets/{aid}/meta",
            json={"user_labels": ["new_only"]},
            headers=_h(),
        )
        assert r.status_code == 200, r.text
        assert r.json()["user_labels"] == ["new_only"]

        # merge:DB 现值在前 + 并集去重
        r2 = await client.patch(
            f"/api/v1/assets/{aid}/meta",
            json={"user_labels": ["new_only", "added_c"], "labels_mode": "merge"},
            headers=_h(),
        )
        assert r2.status_code == 200, r2.text
        assert r2.json()["user_labels"] == ["new_only", "added_c"]

        # 显式 replace:整条替换
        r3 = await client.patch(
            f"/api/v1/assets/{aid}/meta",
            json={"user_labels": ["final"], "labels_mode": "replace"},
            headers=_h(),
        )
        assert r3.status_code == 200, r3.text
        assert r3.json()["user_labels"] == ["final"]
        assert (await _labels_of(aid)) == ["final"]

        # 非法 labels_mode → 422
        r4 = await client.patch(
            f"/api/v1/assets/{aid}/meta",
            json={"user_labels": ["x"], "labels_mode": "append"},
            headers=_h(),
        )
        assert r4.status_code == 422, r4.text
    finally:
        await _hard_cleanup(client, [aid], [folder["id"]])


@pytest.mark.asyncio
async def test_meta_labels_mode_merge_cap_50(client: AsyncClient) -> None:
    """merge 并集仍过 _normalize_labels 的 50 条上限(方案 §1.2:DB 现值占满 50
    时新标签被静默截断,已知行为)。"""
    uniq = _uniq("zz_bp_lbl50")
    folder = await _create_folder(client, PROJECT_EVENT, uniq)
    full = [f"lbl{i:02d}" for i in range(50)]
    aid = await _insert_asset(folder["id"], f"{uniq}_full.txt", labels=full)
    try:
        r = await client.patch(
            f"/api/v1/assets/{aid}/meta",
            json={"user_labels": ["overflow"], "labels_mode": "merge"},
            headers=_h(),
        )
        assert r.status_code == 200, r.text
        # DB 现值在前:50 条占满,新标签被截断,原 50 条顺序不变
        assert r.json()["user_labels"] == full
        assert (await _labels_of(aid)) == full
    finally:
        await _hard_cleanup(client, [aid], [folder["id"]])


# ─── 用例 11:对账 — renamed + skipped == 去重后提交数(混合桶单请求)────────────
@pytest.mark.asyncio
async def test_batch_prefix_reconciliation_add_mixed(client: AsyncClient) -> None:
    """单请求混合四类结果(add:成功 / already_prefixed / too_long / deleted 幽灵 id,
    重复 id 去重),严格对账:renamed + skipped == 去重后提交数(4 个唯一 id)。"""
    uniq = _uniq("zz_bp_rec")
    folder = await _create_folder(client, PROJECT_EVENT, uniq)
    prefix = f"{uniq}_P_"
    aid_ok = await _insert_asset(folder["id"], f"{uniq}_ok.txt")
    aid_ap = await _insert_asset(folder["id"], f"{prefix}ap.txt")
    aid_long = await _insert_asset(folder["id"], "X" * 511)
    ghost = uuid.uuid4()  # 不存在 → deleted 桶
    try:
        # 提交 5 个原始 id(aid_ok 重复一次 → 去重后 4 个唯一 id)
        r = await _batch_prefix(
            client, [aid_ok, aid_ap, aid_long, ghost, aid_ok], "add", prefix,
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["renamed"] == 1  # aid_ok
        assert body["skipped"] == 3  # already_prefixed + too_long + deleted 各 1
        assert body["skipped_reasons"]["already_prefixed"] == 1
        assert body["skipped_reasons"]["too_long"] == 1
        assert body["skipped_reasons"]["deleted"] == 1
        # 严格对账:renamed + skipped == 去重后提交数(4),重复 id 不多算
        assert body["renamed"] + body["skipped"] == 4

        assert (await _filename_of(aid_ok)) == f"{prefix}{uniq}_ok.txt"
        assert (await _filename_of(aid_ap)) == f"{prefix}ap.txt"
        assert (await _filename_of(aid_long)) == "X" * 511
    finally:
        await _hard_cleanup(client, [aid_ok, aid_ap, aid_long], [folder["id"]])
