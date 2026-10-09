"""batch-prefix key 同步迁移(F3 根治)— DB 容器集成层。

对应需求文档(唯一依据):docs/qdev/2026-10-09-baidu-import-key-conflict-fix.md
测试功能点 8-10(功能点 11 为回归闸门项,不落独立用例 —— 映射见下表尾注)。
【集成】用例须跑容器栈(真实 PG/MinIO),门控与 tests/test_baidu_integration.stack
同款:PG/MinIO 任一不可达 → 整模块 skip。
运行方式:`docker exec ms-api pytest tests/test_batch_prefix_key_move.py -v`。

背景:本需求前 batch-prefix 是纯 DB 改名不触 MinIO(tests/test_batch_prefix.py
文件头同款说明);F3 后每个将改名的活跃行在 filename 确定后同步迁移 key:
新 key={folder.minio_prefix}{新 filename}(与 complete_upload 同规则)→
copy_object(旧 key→新 key)→ UPDATE 行(filename+minio_key)→ commit 后删旧
对象。改名语义本身(五类 skip/NFC 归一/审计采样)由 test_batch_prefix.py 承接,
本文件只覆盖 key 迁移行为。

脚手架(client/app fixture、batch-prefix 调用、建夹/清理、audit 拉取)imports
复用 tests/test_batch_prefix.py(与其既有惯例一致 —— 该文件即「照
test_trash_and_purge 形态」的复制先例,此处改为导入以免双份漂移);MinIO 播种与
head 断言 helper 本文件自含。沿用预写名约定:`skipped_reasons` 新增 `key_conflict`
/`key_copy_failed` 两键与 audit `batch_renamed` details 的 `key_moved` 标记,
后端实现落地前相关用例红,落地后转绿。

测试函数 → 需求「测试功能点」映射(PM 验收对照):
  8. F3 add 前缀:filename 与 key 末段一致、新对象在位(head 200/size 不变)、
     旧对象已删(head 404)、audit key_moved=true
                                              → test_batch_prefix_add_moves_key_old_object_deleted
     remove 同                                → test_batch_prefix_remove_moves_key_back
  9. F3 新 key 被其他行引用:skip key_conflict、原文件 filename/key 不动、
     双方对象原样、audit key_moved=false     → test_batch_prefix_new_key_occupied_skips_key_conflict
  10. F3 copy 失败(注入 copy_object 异常):skip key_copy_failed、行不动
                                              → test_batch_prefix_copy_failure_skips_key_copy_failed
  P1-1 专职测试实锤:链式改名同批互踩(Y 迁出让出的 key 恰被同批 X 迁入,
      删 Y 旧对象不得悬挂 X 引用)                            → test_batch_prefix_chain_rename_no_dangling_key
  11. 既有 66 集成用例回归全绿 + 本地单测回归 + ruff/mypy/lint/build 基线不升
      —— 闸门项,无独立测试函数:由全量 `pytest tests/`、`ruff check`、`mypy`
      与前端 build 基线对比承接(PM 验收阶段跑)。
"""
from __future__ import annotations

import asyncio
import uuid
from datetime import UTC, datetime
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import create_async_engine

from app.db.session import get_sessionmaker
from app.db.tables import Asset, Folder, Project
from app.settings import get_settings
from tests import test_batch_prefix as bp
from tests.test_batch_prefix import (  # 纯 helper 复用(与用例形参无同名冲突)
    EVAN_ID,
    PROJECT_EVENT,
    _audit_since,
    _batch_prefix,
    _create_folder,
    _find_sample_list,
    _hard_cleanup,
    _uniq,
)

# fixture 再输出(赋值形态:from-import 直引会与用例签名同名形参撞 ruff F811,
# 赋值绑定不触发;解析按函数对象身份,与 test_batch_prefix 内定义即同一 fixture)
app_with_lifespan = bp.app_with_lifespan
client = bp.client


# ─── MinIO 播种 / 读回(本文件自含;F3 后批量改名是真实对象操作)─────────────────
def _minio_client():
    import boto3

    s = get_settings()
    return boto3.client(
        "s3",
        endpoint_url=s.minio_endpoint_internal,
        aws_access_key_id=s.minio_access_key,
        aws_secret_access_key=s.minio_secret_key,
        region_name="us-east-1",
    )


def _list_buckets_sync() -> list[str]:
    return [b["Name"] for b in _minio_client().list_buckets().get("Buckets", [])]


def _put_sync(bucket: str, key: str, body: bytes) -> None:
    _minio_client().put_object(Bucket=bucket, Key=key, Body=body, ContentLength=len(body))


async def _put_object(bucket: str, key: str, body: bytes) -> None:
    await asyncio.to_thread(_put_sync, bucket, key, body)


def _head_sync(bucket: str, key: str) -> dict | None:
    try:
        return _minio_client().head_object(Bucket=bucket, Key=key)
    except Exception:
        return None   # None = 404(NoSuchKey/NoSuchBucket)


async def _head(bucket: str, key: str) -> dict | None:
    return await asyncio.to_thread(_head_sync, bucket, key)


async def _project_bucket() -> str:
    """seed 项目的真实 bucket(直插行的 minio_bucket 与对象播种统一用它)。"""
    async with get_sessionmaker()() as db:
        p = await db.get(Project, uuid.UUID(PROJECT_EVENT))
        assert p is not None, "seed 项目缺失(先跑 seed_demo_data.py,同 test_batch_prefix 前置)"
        return str(p.minio_bucket)


async def _folder_prefix(folder_id: str) -> str:
    async with get_sessionmaker()() as db:
        f = await db.get(Folder, uuid.UUID(folder_id))
        assert f is not None
        return str(f.minio_prefix or "")


async def _insert_asset_with_object(
    folder_id: str, filename: str, content: bytes, *, bucket: str,
) -> uuid.UUID:
    """直插 asset 行并同步播种 MinIO 对象(key={folder.minio_prefix}{filename},
    与 complete_upload 同规则 —— F3 的 copy 源必须是真实在位对象)。"""
    key = f"{await _folder_prefix(folder_id)}{filename}"
    await _put_object(bucket, key, content)
    async with get_sessionmaker()() as db:
        row = Asset(
            id=uuid.uuid4(),
            folder_id=uuid.UUID(folder_id),
            filename=filename,
            minio_bucket=bucket,
            minio_key=key,
            size_bytes=len(content),
            content_type="text/plain",
            uploader_id=uuid.UUID(EVAN_ID),
        )
        db.add(row)
        await db.commit()
        return row.id


async def _asset_core(asset_id: uuid.UUID) -> tuple[str, str]:
    """读回 (filename, minio_key)。"""
    async with get_sessionmaker()() as db:
        row = await db.get(Asset, asset_id)
        assert row is not None, f"asset {asset_id} 应仍在库中"
        return row.filename, str(row.minio_key)


def _latest_renamed_audit(audits: list[Any], prefix: str) -> dict[str, Any]:
    """按 prefix 过滤出本批 asset.batch_renamed 的 details(时间升序取最后一条)。"""
    rows = [e for e in audits if (e.details or {}).get("prefix") == prefix]
    assert rows, "应落一条 asset.batch_renamed audit"
    return rows[-1].details


# ─── 门控:PG/MinIO 探测 + seed 项目桶兜底创建(同 stack fixture 口径)───────────
@pytest.fixture(scope="session")
async def stack_ready():
    from sqlalchemy import text

    engine = create_async_engine(str(get_settings().db_url))
    try:
        async with engine.connect() as conn:
            await conn.execute(text("SELECT 1"))
    except Exception as exc:
        await engine.dispose()
        pytest.skip(f"no reachable PG — batch-prefix key move tests skipped: {exc}")
    await engine.dispose()
    try:
        await asyncio.to_thread(_list_buckets_sync)
    except Exception as exc:
        pytest.skip(f"no reachable MinIO — batch-prefix key move tests skipped: {exc}")
    # DB 直插不建桶(与 test_baidu_integration.world 同理):兜底确保项目桶在位
    bucket = await _project_bucket()

    def _ensure() -> None:
        c = _minio_client()
        try:
            c.head_bucket(Bucket=bucket)
        except Exception:
            c.create_bucket(Bucket=bucket)

    await asyncio.to_thread(_ensure)
    yield


# ─── 功能点 8:F3 add 前缀 —— key 同步迁移 ────────────────────────────────────────
@pytest.mark.asyncio
async def test_batch_prefix_add_moves_key_old_object_deleted(stack_ready, client: AsyncClient) -> None:
    """add 前缀成功行:filename 与 key 末段一致、key={folder.minio_prefix}{新 filename};
    新对象在位(head 200 且 size 不变)、旧对象已删(head 404);audit key_moved=true。
    【集成】需求点 8(add)"""
    content = b"key-move-bytes"
    uniq = _uniq("zz_km_add")
    folder = await _create_folder(client, PROJECT_EVENT, uniq)
    bucket = await _project_bucket()
    aid = await _insert_asset_with_object(folder["id"], f"{uniq}_a.txt", content, bucket=bucket)
    old_key = f"{await _folder_prefix(folder['id'])}{uniq}_a.txt"
    prefix = f"{uniq}_P_"
    t0 = datetime.now(UTC)
    try:
        r = await _batch_prefix(client, [aid], "add", prefix)
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["renamed"] == 1
        assert body["skipped"] == 0

        new_name = f"{prefix}{uniq}_a.txt"
        new_key = f"{await _folder_prefix(folder['id'])}{new_name}"
        fname, mkey = await _asset_core(aid)
        assert fname == new_name
        assert mkey == new_key, "minio_key 必须同步迁移为 folder 前缀 + 新 filename"
        assert mkey.rsplit("/", 1)[-1] == fname, "key 末段与 filename 一致"

        head = await _head(bucket, new_key)
        assert head is not None, "新 key 对象必须在位"
        assert head["ContentLength"] == len(content), "迁移不得损内容(size 不变)"
        assert await _head(bucket, old_key) is None, "旧 key 对象必须已删(commit 后 delete)"

        details = _latest_renamed_audit(await _audit_since("asset.batch_renamed", t0), prefix)
        assert details.get("key_moved") is True
        samples = _find_sample_list(details)
        assert samples is not None, f"audit 采样明细缺失: {details}"
        assert str(aid) in {str(s.get("id")) for s in samples}
    finally:
        await _hard_cleanup(client, [aid], [folder["id"]])


@pytest.mark.asyncio
async def test_batch_prefix_remove_moves_key_back(stack_ready, client: AsyncClient) -> None:
    """remove 前缀同款迁移:filename 剥离前缀、key 迁回 folder 前缀 + 新 filename,
    新对象在位、旧对象已删、audit key_moved=true。【集成】需求点 8(remove)"""
    content = b"remove-move-bytes"
    uniq = _uniq("zz_km_rm")
    folder = await _create_folder(client, PROJECT_EVENT, uniq)
    bucket = await _project_bucket()
    prefix = f"{uniq}_P_"
    aid = await _insert_asset_with_object(folder["id"], f"{prefix}report.txt", content, bucket=bucket)
    pre_key = f"{await _folder_prefix(folder['id'])}{prefix}report.txt"
    t0 = datetime.now(UTC)
    try:
        r = await _batch_prefix(client, [aid], "remove", prefix)
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["renamed"] == 1
        assert body["skipped"] == 0

        new_key = f"{await _folder_prefix(folder['id'])}report.txt"
        fname, mkey = await _asset_core(aid)
        assert fname == "report.txt"
        assert mkey == new_key and mkey.rsplit("/", 1)[-1] == fname

        head = await _head(bucket, new_key)
        assert head is not None and head["ContentLength"] == len(content)
        assert await _head(bucket, pre_key) is None

        details = _latest_renamed_audit(await _audit_since("asset.batch_renamed", t0), prefix)
        assert details.get("key_moved") is True
    finally:
        await _hard_cleanup(client, [aid], [folder["id"]])


# ─── 功能点 9:F3 新 key 被其他行引用 —— skip key_conflict ────────────────────────
@pytest.mark.asyncio
async def test_batch_prefix_new_key_occupied_skips_key_conflict(stack_ready, client: AsyncClient) -> None:
    """加前缀后的新 key 已被另一活跃行引用(排除自身)→ 该文件 skip 且
    skipped_reasons 新增 key_conflict 桶;原文件 filename/key 不动、双方对象原样;
    audit key_moved=false。【集成】需求点 9"""
    uniq = _uniq("zz_km_occ")
    folder = await _create_folder(client, PROJECT_EVENT, uniq)
    bucket = await _project_bucket()
    fp = await _folder_prefix(folder["id"])
    prefix = f"{uniq}_P_"
    holder_content, victim_content = b"holder-bytes", b"victim-bytes"
    # 占用行:filename 恰为 victim 加前缀后的新名,key 同规则(真实 complete_upload 形态)
    holder = await _insert_asset_with_object(
        folder["id"], f"{prefix}{uniq}_hit.txt", holder_content, bucket=bucket,
    )
    victim = await _insert_asset_with_object(folder["id"], f"{uniq}_hit.txt", victim_content, bucket=bucket)
    t0 = datetime.now(UTC)
    try:
        r = await _batch_prefix(client, [victim], "add", prefix)
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["renamed"] == 0
        assert body["skipped"] == 1
        assert body["skipped_reasons"]["key_conflict"] == 1, \
            f"新 key 被占必须落 key_conflict 桶: {body['skipped_reasons']}"

        # 原文件行与对象原样
        fname, mkey = await _asset_core(victim)
        assert fname == f"{uniq}_hit.txt"
        assert mkey == f"{fp}{uniq}_hit.txt"
        head = await _head(bucket, mkey)
        assert head is not None and head["ContentLength"] == len(victim_content)
        head_holder = await _head(bucket, f"{fp}{prefix}{uniq}_hit.txt")
        assert head_holder is not None and head_holder["ContentLength"] == len(holder_content)

        details = _latest_renamed_audit(await _audit_since("asset.batch_renamed", t0), prefix)
        assert details.get("key_moved") is False
    finally:
        await _hard_cleanup(client, [victim, holder], [folder["id"]])


# ─── 功能点 10:F3 copy 失败注入 —— skip key_copy_failed、行不动 ──────────────────
def _inject_copy_failure(monkeypatch: pytest.MonkeyPatch) -> None:
    """注入 MinIO copy_object 失败(双层,先命 whichever):

    ① PresignService.copy_object(若 Backend 按既有 delete_object 惯例封装)——
       同 test_overwrite_purge_incomplete 的同步 boom 注入口径(patch 必须同步函数);
    ② botocore BaseClient._make_api_call 拦截 operation_name == "CopyObject" ——
       与封装形状无关的兜底(实现直接用 boto client 时仍命中;本进程内仅迁移
       copy 会发 CopyObject,测试自身的 head/put 均不受影响)。
    """
    from app.services.presign import PresignService

    def _boom(*a: object, **k: object) -> None:
        raise RuntimeError("injected copy_object failure")

    if hasattr(PresignService, "copy_object"):
        monkeypatch.setattr(PresignService, "copy_object", _boom)

    import botocore.client

    original = botocore.client.BaseClient._make_api_call

    def _boom_call(self: object, operation_name: str, api_params: object) -> object:
        if operation_name == "CopyObject":
            raise RuntimeError("injected CopyObject failure")
        return original(self, operation_name, api_params)  # type: ignore[arg-type]

    monkeypatch.setattr(botocore.client.BaseClient, "_make_api_call", _boom_call)


@pytest.mark.asyncio
async def test_batch_prefix_copy_failure_skips_key_copy_failed(
    stack_ready, client: AsyncClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """copy_object 异常 → 该文件 skip 且落 key_copy_failed 桶、行完全不动
    (filename/minio_key 原样、对象只在旧 key);audit key_moved=false。
    【集成】需求点 10"""
    content = b"copy-fail-bytes"
    uniq = _uniq("zz_km_cp")
    folder = await _create_folder(client, PROJECT_EVENT, uniq)
    bucket = await _project_bucket()
    fp = await _folder_prefix(folder["id"])
    aid = await _insert_asset_with_object(folder["id"], f"{uniq}_c.txt", content, bucket=bucket)
    old_key = f"{fp}{uniq}_c.txt"
    prefix = f"{uniq}_P_"
    t0 = datetime.now(UTC)
    try:
        _inject_copy_failure(monkeypatch)
        r = await _batch_prefix(client, [aid], "add", prefix)
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["renamed"] == 0
        assert body["skipped"] == 1
        assert body["skipped_reasons"]["key_copy_failed"] == 1, \
            f"copy 失败必须落 key_copy_failed 桶: {body['skipped_reasons']}"

        # 行不动 + 对象只在旧 key(不得半迁移)
        fname, mkey = await _asset_core(aid)
        assert fname == f"{uniq}_c.txt" and mkey == old_key
        head = await _head(bucket, old_key)
        assert head is not None and head["ContentLength"] == len(content)
        assert await _head(bucket, f"{fp}{prefix}{uniq}_c.txt") is None

        details = _latest_renamed_audit(await _audit_since("asset.batch_renamed", t0), prefix)
        assert details.get("key_moved") is False
    finally:
        monkeypatch.undo()   # 先撤注入再清理(清理由 copy 正常路径无关的 API 完成)
        await _hard_cleanup(client, [aid], [folder["id"]])


# ─── P1-1:链式改名同批互踩 → 删旧对象不得悬挂他行引用(专职测试实锤回归)─────────
@pytest.mark.asyncio
async def test_batch_prefix_chain_rename_no_dangling_key(stack_ready, client: AsyncClient) -> None:
    """链式改名:同夹 Y=P_a.txt(key {fp}P_a.txt)与 X=P_P_a.txt(key {fp}P_P_a.txt)
    同批 remove P_,提交序 Y 在前 —— Y 先迁到 {fp}a.txt 让出 {fp}P_a.txt,X 的
    占用预检(读己之写)恰见该 key 空闲 → copy 落 {fp}P_a.txt 并 UPDATE。

    修复前:commit 后按 moved 列表删 Y 的旧对象 {fp}P_a.txt = 删掉 X 现指向的
    对象(X 行悬挂,接口仍报 renamed=2 成功 —— 静默数据丢失)。
    修复后:删前重验旧 key 的当前 DB 引用,已被 X 引用 → 保留对象,两行完好:
    各自 key head 200、内容各自正确、X 原对象 {fp}P_P_a.txt 正常删除。【集成】"""
    uniq = _uniq("zz_km_chain")
    folder = await _create_folder(client, PROJECT_EVENT, uniq)
    bucket = await _project_bucket()
    fp = await _folder_prefix(folder["id"])
    y_content, x_content = b"Y-chain-bytes", b"X-chain-bytes"
    # _insert_asset_with_object:filename 与 key 同规则(canonical),对象真实在位
    y = await _insert_asset_with_object(folder["id"], "P_a.txt", y_content, bucket=bucket)
    x = await _insert_asset_with_object(folder["id"], "P_P_a.txt", x_content, bucket=bucket)
    try:
        # 提交序 Y 在前:复刻「Y 先迁出让 key、X 后迁入同 key」的互踩时序
        r = await _batch_prefix(client, [y, x], "remove", "P_")
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["renamed"] == 2
        assert body["skipped_reasons"]["key_conflict"] == 0

        # Y:迁到 {fp}a.txt,对象在位且内容为 Y
        yf, yk = await _asset_core(y)
        assert (yf, yk) == ("a.txt", f"{fp}a.txt")
        hy = await _head(bucket, yk)
        assert hy is not None and hy["ContentLength"] == len(y_content)

        # X:迁到 {fp}P_a.txt(恰是 Y 的旧 key),对象必须仍在且内容为 X ——
        # 不得被「Y 旧对象清理」删成悬挂引用(P1-1 坏态断言点)
        xf, xk = await _asset_core(x)
        assert (xf, xk) == ("P_a.txt", f"{fp}P_a.txt")
        hx = await _head(bucket, xk)
        assert hx is not None, "X 现指向的对象被误删(悬挂 minio_key,静默数据丢失)"
        assert hx["ContentLength"] == len(x_content)

        # X 的原对象正常删除;Y 的旧对象因被 X 引用而保留(内容已是 X 的拷贝)
        assert await _head(bucket, f"{fp}P_P_a.txt") is None
    finally:
        await _hard_cleanup(client, [y, x], [folder["id"]])


# 清理兜底说明:_hard_cleanup 走 API 软删+hard purge(purge 内部 delete_object,
# 非 CopyObject),monkeypatch.undo() 只是防御性收敛注入窗口,正常无需手动。
