"""批量文件名前缀(POST /api/v1/assets/batch-prefix)— 集成测试,容器内跑。

对应方案:`rushes-spec/material-storage/netdisk-import-batch-rename-roles-plan.md`
§1.1(API 契约与语义:skipped_reasons、NFC 两侧归一、逐 id UPDATE + 对账)、
§1.4(测试清单);实施文档 `docs/qdev/2026-10-08-batch-prefix-creator-template.md` PR-1;
F3 key 同步迁移见 `docs/qdev/2026-10-09-baidu-import-key-conflict-fix.md`。

用例 → 测试函数对照(§1.4 清单 + F3 逐条落函数):
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
  F3 集成点 8/9/10(key 迁移:对象搬家 / key_conflict / key_copy_failed)
    落同目录 test_batch_prefix_key_move.py(脚手架复用本文件,不重复落函数)
  纯逻辑:key 规则与 complete_upload 同源(本地可跑,无需容器栈)
                                                     → test_pure_new_asset_key_rule
                                                     test_pure_skipped_reasons_schema_keys

预期前置(同 test_v4_permissions.py / test_trash_and_purge.py):
  1. seed_demo_data.py 已跑过(Evan = 系统 admin;outsider = 无任何权限的契约账号)
  2. OpenFGA store / model 已 push
  3. env=dev(允许 X-User-Id header 模拟身份)
  4. MinIO 可达(F3 起改名会真实 copy/delete 对象;期望改名的用例须先播种
     源对象,见 _seed_object)

资产入库存走 DB 直插(presign 的 PUT 指向 MinIO 公网 endpoint,容器内不通,
与 test_trash_and_purge 同理由);F3 起改名不再「纯 DB」—— 逐文件跨资产 key
预检(DB)→ copy_object → UPDATE → commit 后删旧对象(真实 MinIO),故:
  - 期望改名的用例先 _seed_object 播种旧 key 对象,否则 copy NoSuchKey →
    key_copy_failed 跳过(该路径本身由 F3-10 用例覆盖);
  - 纯逻辑用例(test_pure_*)不依赖容器栈,本地 `pytest -k test_pure` 可跑。
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
from app.routers.assets import _new_asset_key

EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"          # 系统 admin(org admin)
OUTSIDER_ID = "00000000-0000-0000-0000-0000000000aa"      # 无任何角色的契约账号
PROJECT_EVENT = "11111111-1111-1111-1111-111111111103"    # public

# 「é」的两种 Unicode 形式:NFD 组合字符(macOS 拖入落库原样)/ NFC 预组合
NFD_E = "e\u0301"
NFC_E = "\u00e9"

# skipped_reasons 七个键,方案 §1.1 写死五类 + F3 增两类(键固定 ASCII,前端做中文映射)
SKIPPED_KEYS = {
    "too_long", "no_match", "already_prefixed", "empty_result", "deleted",
    "key_conflict", "key_copy_failed",
}

_TEST_BUCKET = "ms-dev"  # 与 _insert_asset 的 minio_bucket 一致(dev 默认桶)


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


def _minio_client():  # type: ignore[no-untyped-def]
    """容器内视角的 MinIO client(test_baidu_integration._minio_client 同款)。"""
    import boto3

    from app.settings import get_settings
    s = get_settings()
    return boto3.client(
        "s3",
        endpoint_url=s.minio_endpoint_internal,
        aws_access_key_id=s.minio_access_key,
        aws_secret_access_key=s.minio_secret_key,
        region_name="us-east-1",
    )


async def _seed_object(bucket: str, key: str, body: bytes = b"hello-bp") -> None:
    """播种 MinIO 对象(F3 起改名 = copy_object,源对象必须在位)。

    bucket 缺失则先建(与 test_baidu_integration 同款防御,dev 桶一般已存在)。
    ⚠️ MinIO 对象名上限 255 字符(比 S3 规范的 1024 严):超长名 PutObject 直接
    400 XMinioInvalidObjectName("unsupported characters"),造数时须守此限。
    """
    def _sync() -> None:
        c = _minio_client()
        try:
            c.head_bucket(Bucket=bucket)
        except c.exceptions.ClientError:
            c.create_bucket(Bucket=bucket)
        c.put_object(Bucket=bucket, Key=key, Body=body, ContentLength=len(body))

    await asyncio.to_thread(_sync)


async def _head_object(bucket: str, key: str) -> dict | None:
    """head 对象;404(不存在)返回 None,其余返回 size_bytes 等 meta。"""
    def _sync() -> dict | None:
        c = _minio_client()
        try:
            resp = c.head_object(Bucket=bucket, Key=key)
        except c.exceptions.ClientError:
            return None
        return {"size_bytes": int(resp.get("ContentLength", 0))}

    return await asyncio.to_thread(_sync)


async def _drop_object(bucket: str, key: str) -> None:
    """best-effort 删对象(清孤儿用;不存在时 S3 delete 幂等成功)。"""
    await asyncio.to_thread(_minio_client().delete_object, Bucket=bucket, Key=key)


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
    MinIO key 同步迁移(F3:key 末段 = 新 filename,旧对象删、新对象在位)。"""
    uniq = _uniq("zz_bp_add")
    folder = await _create_folder(client, PROJECT_EVENT, uniq)
    aid1 = await _insert_asset(folder["id"], f"{uniq}_a1.txt")
    aid2 = await _insert_asset(folder["id"], f"{uniq}_a2.txt")
    # F3:改名会 copy_object,先播种旧 key 对象(旧 key 与夹前缀刻意错位,
    # 复刻线上「filename≠key 残留」形态)
    old_key1 = f"zz-test/{uniq}_a1.txt"
    old_key2 = f"zz-test/{uniq}_a2.txt"
    await _seed_object(_TEST_BUCKET, old_key1)
    await _seed_object(_TEST_BUCKET, old_key2)
    t0 = datetime.now(timezone.utc)
    try:
        r = await _batch_prefix(client, [aid1, aid2], "add", f"{uniq}_P_")
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["renamed"] == 2
        assert body["skipped"] == 0
        # skipped_reasons 键固定存在且全 0(方案 §1.1 五类 + F3 两类,键固定 ASCII)
        assert set(body["skipped_reasons"]) == SKIPPED_KEYS
        assert all(v == 0 for v in body["skipped_reasons"].values())

        # 落库文件名 = prefix + filename(ASCII 场景 NFC 即原样);
        # F3:key = {folder.minio_prefix}/{新 filename}(与 complete_upload 同规则)
        fname1, key1 = await _get_asset_core(aid1)
        new_key1 = f"{uniq}/{uniq}_P_{uniq}_a1.txt"
        assert fname1 == f"{uniq}_P_{uniq}_a1.txt"
        assert key1 == new_key1
        fname2, key2 = await _get_asset_core(aid2)
        assert fname2 == f"{uniq}_P_{uniq}_a2.txt"
        assert key2 == f"{uniq}/{uniq}_P_{uniq}_a2.txt"

        # F3 对象语义【集成】:新对象在位且 size 不变;旧对象已删(commit 后清理)
        head_new = await _head_object(_TEST_BUCKET, new_key1)
        assert head_new is not None, "copy 后新 key 对象应在位"
        assert head_new["size_bytes"] == 8  # _seed_object 默认 body 长度
        assert await _head_object(_TEST_BUCKET, old_key1) is None, "旧 key 对象应已删除"

        # 聚合 audit:asset.batch_renamed,含 action / prefix / renamed / skipped / 采样
        rows = [e for e in await _audit_since("asset.batch_renamed", t0)
                if e.details.get("prefix") == f"{uniq}_P_"]
        assert rows, "应落一条 asset.batch_renamed audit"
        details = rows[-1].details
        assert details.get("action") == "add"
        assert details.get("renamed") == 2
        assert details.get("skipped") == 0
        assert details.get("key_moved") is True  # F3:本批发生了 key 迁移
        assert details.get("key_moved_count") == 2
        samples = _find_sample_list(details)
        assert samples is not None, f"audit 采样明细缺失: {details}"
        by_id = {str(s.get("id")): s for s in samples}
        s1 = by_id[str(aid1)]
        assert s1.get("old") == f"{uniq}_a1.txt"
        assert s1.get("new") == f"{uniq}_P_{uniq}_a1.txt"
    finally:
        # 清场:新 key 对象(旧 key 对象已被端点删;万一 skip 残留也兜底删掉)
        await _drop_object(_TEST_BUCKET, f"{uniq}/{uniq}_P_{uniq}_a1.txt")
        await _drop_object(_TEST_BUCKET, f"{uniq}/{uniq}_P_{uniq}_a2.txt")
        await _drop_object(_TEST_BUCKET, old_key1)
        await _drop_object(_TEST_BUCKET, old_key2)
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
    # F3:aid_new 会改名 → 播种源对象;aid_ap 已带前缀不动,无需播种
    await _seed_object(_TEST_BUCKET, f"zz-test/{uniq}_fresh.txt")
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
        await _drop_object(_TEST_BUCKET, f"{uniq}/{prefix}{uniq}_fresh.txt")
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
    # F3:仅 aid_hit 会改名 → 播种源对象
    await _seed_object(_TEST_BUCKET, f"zz-test/{prefix}hit.txt")
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
        await _drop_object(_TEST_BUCKET, f"{uniq}/hit.txt")
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
    # F3:remove 会命中 aid_rm 改名 → 播种源对象(插入 helper 用原串拼 key)
    await _seed_object(_TEST_BUCKET, f"zz-test/{NFD_E}{uniq}_etude.txt")
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
        await _drop_object(_TEST_BUCKET, f"{uniq}/{uniq}_etude.txt")
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
    提交只计一次(防重复计入 deleted / renamed)。

    F3 边界修正:MinIO 对象名上限 255 字符(超长 PutObject/CopyObject 直接
    400 XMinioInvalidObjectName),510/511 字符 filename 的真实对象既播不了种
    也搬不动 —— 故:
      - too_long 行(511L)在进入 key 迁移前就被过滤,**不播种任何对象**;
      - =512 边界行(510E)改为「minio_key 已是改名目标 key」的残留形态:
        new_key == old_key → 端点短路、只改 filename 不触 MinIO,边界语义
        (=512 恰好可改、renamed=1)保留,对象操作零参与。
    """
    uniq = _uniq("zz_bp_long")
    folder = await _create_folder(client, PROJECT_EVENT, uniq)
    long_name = "L" * 511  # 库内可行(≤512),add 2 字符前缀 → 513 > 512
    aid_long = await _insert_asset(folder["id"], long_name)
    edge_name = "E" * 510  # add 2 字符前缀 → 恰好 512,应成功
    aid_edge = await _insert_asset(folder["id"], edge_name)
    aid_dup = await _insert_asset(folder["id"], f"{uniq}_dup.txt")
    # F3:aid_dup 会改名 → 播种短名源对象;aid_long(too_long)不触 MinIO;
    # aid_edge 预置 key = 改名后的目标 key(见上方 F3 边界修正说明)
    await _seed_object(_TEST_BUCKET, f"zz-test/{uniq}_dup.txt")
    edge_target_key = f"{uniq}/AB{edge_name}"
    async with get_sessionmaker()() as db:
        await db.execute(
            update(Asset).where(Asset.id == aid_edge).values(minio_key=edge_target_key)
        )
        await db.commit()
    try:
        # too_long:>512 跳过(在 key 迁移之前过滤,不触 MinIO)
        r = await _batch_prefix(client, [aid_long], "add", "AB")
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["renamed"] == 0
        assert body["skipped"] == 1
        assert body["skipped_reasons"]["too_long"] == 1
        assert (await _filename_of(aid_long)) == long_name

        # 边界:结果恰 512 → 正常改名(new_key == old_key → 仅改 filename,
        # minio_key 原样、无对象操作)
        r_edge = await _batch_prefix(client, [aid_edge], "add", "AB")
        assert r_edge.status_code == 200, r_edge.text
        assert r_edge.json()["renamed"] == 1
        assert (await _filename_of(aid_edge)) == "AB" + edge_name
        assert (await _get_asset_core(aid_edge))[1] == edge_target_key

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
        # edge_target_key 超长(530 字符)且本就无对象 —— 不可也不必 drop
        # (MinIO 对超长名连 delete 都 400);edge 行的 hard purge 对该 key
        # 的删除失败由 purge 自身的 best-effort 吞掉,只留 warning 日志
        await _drop_object(_TEST_BUCKET, f"zz-test/{uniq}_dup.txt")
        await _drop_object(_TEST_BUCKET, f"{uniq}/P_{uniq}_dup.txt")
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

    F3 注意:请求在 UPDATE 等锁**之前**已完成 key 占用预检与 copy_object
    (MinIO 无行锁概念),故必须播种源对象;UPDATE 落空后已 copy 的新 key
    对象成孤儿 —— 清场时兜底删除(端点侧不删:raced 行的旧对象必须保留)。
    """
    uniq = _uniq("zz_bp_race")
    folder = await _create_folder(client, PROJECT_EVENT, uniq)
    name = f"{uniq}_race.txt"
    aid = await _insert_asset(folder["id"], name)
    await _seed_object(_TEST_BUCKET, f"zz-test/{name}")
    orphan_new_key = f"{uniq}/P_{name}"
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
        # 清孤儿 copy(端点对 raced 行不删任何对象);旧 key 对象走 hard purge
        await _drop_object(_TEST_BUCKET, orphan_new_key)
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
    # F3:受邀后那次改名会 copy → 播种源对象
    await _seed_object(_TEST_BUCKET, f"zz-test/{uniq}_sens.txt")
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
    # F3:仅 aid_ok 会改名 → 播种源对象
    await _seed_object(_TEST_BUCKET, f"zz-test/{uniq}_ok.txt")
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
        await _drop_object(_TEST_BUCKET, f"{uniq}/{prefix}{uniq}_ok.txt")
        await _hard_cleanup(client, [aid_ok, aid_ap, aid_long], [folder["id"]])


# ─── 纯逻辑(无容器栈,本地 pytest -k test_pure 可跑)───────────────────────────
def test_pure_new_asset_key_rule() -> None:
    """纯逻辑:key 规则与 complete_upload 同源 —— minio_prefix 尾斜杠归一
    (rstrip 后补一个),文件名原样拼接。百度导入按同一规则落库,三处必须
    一致,这里钉死 rstrip 语义。"""
    assert _new_asset_key("11/", "P_1.txt") == "11/P_1.txt"
    assert _new_asset_key("11", "1.txt") == "11/1.txt"          # 无尾斜杠补 /
    assert _new_asset_key("a/b/c//", "x.txt") == "a/b/c/x.txt"  # 多个尾斜杠全归一
    assert _new_asset_key("p/", "中文名.txt") == "p/中文名.txt"  # 非 ASCII 原样
    assert _new_asset_key("p/", "") == "p/"                     # 空名不崩(理论不可达)


def test_pure_skipped_reasons_schema_keys() -> None:
    """纯逻辑:响应契约 —— skipped_reasons 键集合固定为七类(§1.1 五类 + F3
    两类),前端 labels.ts 按此映射。"""
    from app.routers.assets import BatchPrefixReasonsOut

    assert set(BatchPrefixReasonsOut().model_dump()) == SKIPPED_KEYS
