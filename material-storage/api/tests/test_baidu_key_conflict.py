"""百度网盘导入 key 冲突修复(批量前缀残留场景)— DB 容器集成层。

对应需求文档(唯一依据):docs/qdev/2026-10-09-baidu-import-key-conflict-fix.md
测试功能点 1-7(功能点 11 为回归闸门项,不落独立用例 —— 映射见下表尾注)。
【集成】用例须跑容器栈(真实 PG/Redis/MinIO + OpenFGA),门控与
tests/test_baidu_integration.py 同款:任一栈不可达 → 整模块 skip。
运行方式:`docker exec ms-api pytest tests/test_baidu_key_conflict.py -v`。

脚手架全量复用 tests/test_baidu_integration.py(world/mock_baidu/client 等 fixture
与任务/资产构造 helper;fixture 按「被装饰函数对象」解析,跨模块同名导入即同一
fixture,session 级 stack/client 同进程共享,不重复建 app)。沿用该文件的预写名
约定:本需求涉及的 `baidu_backup_task_files.reserved_key` 列(migration 0014)、
`POST .../files/{fid}/random-suffix` 端点与 F1/F2 错误码格式,本分支后端实现
落地前尚不存在 —— 用例断言按需求文档契约预写;实现落地后 collection 即通过,
真实执行转绿(未实现时相关用例红,正是验收口径)。

测试函数 → 需求「测试功能点」映射(PM 验收对照):
  1. 回归直拍:est 残留(filename≠key)→ 导入 failed 点名占用者、可重试
                                              → test_key_conflict_regression_names_holder_and_retryable
  1 补. 多占用者全列 + 软删者附(回收站)(F1 格式补充)     → test_key_conflict_multi_holder_lists_all_with_trash_mark
  2. F2a 覆盖成功:purge 占用行(行+对象+FGA tuple+audit 收尾)再落新文件
                                              → test_f2a_overwrite_purges_holder_then_lands_new_file
  3. F2a 无权限:占用行无 can_admin → overwrite_forbidden_for_holder 点名
                                              → test_f2a_overwrite_without_holder_permission_fails_named
  4. F2b 随机后缀:reserved_key 形态/不冲突、filename 保持网盘原名、占用者完好
                                              → test_f2b_random_suffix_lands_reserved_key_keeps_filename
  5. F2b 幂等:中断(模拟)后再请求复用同一 reserved_key   → test_f2b_random_suffix_reuses_reserved_key_on_reapply
  6. 回收站占用:点名(回收站)、random-suffix 成功且软删行不受影响
                                              → test_trash_holder_named_recycle_bin_and_random_suffix_unaffected
  7. 同名活行回归:目标夹同名活跃文件默认仍 skipped_exists(不走 key_conflict)
                                              → test_same_name_active_row_still_skipped_exists
  P2-1 专职测试实锤:reserve_random_key CAS 并发首次预定先写者胜、后写者 0 行
      (双事务先后 reserve,服务层交错断言)    → test_reserve_random_key_first_write_wins_no_drift
  11. 既有 66 集成用例回归全绿 + 本地单测回归 + ruff/mypy/lint/build 基线不升
      —— 闸门项,无独立测试函数:由全量 `pytest tests/`、`ruff check`、`mypy`
      与前端 build 基线对比承接(PM 验收阶段跑)。
"""
from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

import pytest
from sqlalchemy import select, update

from app.db.tables import Asset, AuditEvent, BaiduBackupTaskFile, Folder, User
from app.services.permissions import PermissionsService
from app.settings import get_settings
from tests import test_baidu_integration as it
from tests.test_baidu_integration import (  # 纯 helper 复用(与用例形参无同名冲突)
    BA,
    World,
    _audit_count,
    _claim_and_run,
    _db,
    _dispatch_claim_run,
    _get_file,
    _get_task,
    _h,
    _head,
    _mk_asset,
    _mk_file,
    _mk_task,
    _put_object,
    _task_key,
    _touch_task,
)

# fixture 再输出(赋值形态:from-import 直引会与用例签名同名形参撞 ruff F811,
# 赋值绑定不触发;解析按函数对象身份,与 test_baidu_integration 内定义即同一 fixture)
enable_baidu = it.enable_baidu
client = it.client
mock_baidu = it.mock_baidu
stack = it.stack
world = it.world


# ─── 残留造数(filename≠key 的占用行;batch-prefix 历史残留的 DB 形态)──────────
async def _mk_asset_with_key(
    world: World, folder: Folder, filename: str, key: str, content: bytes,
    *, uploader: User | None = None, deleted: bool = False,
) -> Asset:
    """直插一条 minio_key 与 filename 解耦的资产行(模拟批量前缀只改名不改 key 的残留)。

    与 tests/test_baidu_integration._mk_asset 同构:真实对象落于指定 key(软删行
    不落对象,同既有 helper 口径),并 bootstrap asset 的 parent tuple —— 漏写会让
    F2a 的 asset 级 can_admin 复查与 purge 的 FGA 收尾全体失真(该文件同款注释)。
    """
    if not deleted:
        await _put_object(world.project.minio_bucket, key, content)
    a = Asset(
        folder_id=folder.id, filename=filename,
        minio_bucket=world.project.minio_bucket, minio_key=key,
        size_bytes=len(content), uploader_id=(uploader or world.member).id,
        deleted_at=datetime.now(UTC) if deleted else None,
    )
    async with _db() as db:
        db.add(a)
        await db.commit()
        await db.refresh(a)
    perms = PermissionsService(get_settings())
    await perms.bootstrap_asset(asset_id=str(a.id), parent_type="folder", parent_id=str(folder.id))
    await perms.close()
    return a


async def _assets_with_key(world: World, key: str) -> list[Asset]:
    async with _db() as db:
        rows = (await db.execute(
            select(Asset).where(
                Asset.minio_bucket == world.project.minio_bucket, Asset.minio_key == key)
        )).scalars().all()
        db.expunge_all()
        return list(rows)


async def _mk_scene(
    world: World, *,
    holder_filename: str = "est_1.txt",
    holder_deleted: bool = False,
    holder_uploader: User | None = None,
    incoming_size: int | None = None,
) -> tuple[Any, Any, Any, str]:
    """最小冲突场景:占用行(filename≠key,key=canonical)+ 新导入任务行 1.txt。

    返回 (task, row, holder_asset, canonical_key);任务属主/操作者 = world.member
    (带 active binding,F2b 随机后缀无 purge 权限要求);F2a 成功路径用例自建
    admin 属主任务。incoming_size:新导入行 source_size(最终落库内容须与之等长,
    走 success 路径的用例必传)。"""
    content = b"holder-residual-bytes"
    key = _task_key(world.folder, "1.txt")
    holder = await _mk_asset_with_key(
        world, world.folder, holder_filename, key, content,
        uploader=holder_uploader, deleted=holder_deleted,
    )
    task = await _mk_task(world, status="running")
    row = await _mk_file(task, "1.txt", size=incoming_size if incoming_size is not None else len(content))
    return task, row, holder, key


# ─── 功能点 1:回归直拍 —— failed 点名占用者、可重试 ─────────────────────────────
async def test_key_conflict_regression_names_holder_and_retryable(
    world: World, mock_baidu, stack,
) -> None:
    """007 实测场景直拍:est_1.txt(key=11/1.txt)残留 → 导入 1.txt 行 failed,
    last_error 精确 F1 格式点名占用者,non_retryable=false 保持可重试。【集成】需求点 1"""
    task, row, _holder, key = await _mk_scene(world)
    incoming = b"incoming-bytes!"
    mock_baidu.add((await _get_file(row.id)).fs_id, incoming)

    await _dispatch_claim_run(task.id)

    frow = await _get_file(row.id)
    assert frow.status == "failed"
    # F1 逐字格式(与 format_key_conflict_message 一致):`key_conflict: <key> 已被 <name>占用`
    # —— names 与「占用」之间无空格
    assert frow.last_error == f"key_conflict: {key} 已被 est_1.txt占用", \
        f"F1 格式必须精确点名占用者: {frow.last_error!r}"
    assert frow.non_retryable is False, "key_conflict 失败保持可重试(F1)"
    assert frow.asset_id is None, "失败行不得落 asset"
    # 未落库:canonical key 上仍是占用者的旧对象,引用行仍只有占用行一份
    head = await _head(world.project.minio_bucket, key)
    assert head is not None and head["ContentLength"] == len(b"holder-residual-bytes")
    assert len(await _assets_with_key(world, key)) == 1
    t = await _get_task(task.id)
    assert t.status == "failed" and t.fail_reason == "file_failed"


async def test_key_conflict_multi_holder_lists_all_with_trash_mark(
    world: World, mock_baidu, stack,
) -> None:
    """多占用者(1 活跃 + 1 软删)全列:F1 格式 `key_conflict: <key> 已被 <f>[、<f>…]占用`,
    软删占用者 filename 后附 (回收站);行仍可重试。【集成】需求点 1(多占用者/回收站标注补充)"""
    key = _task_key(world.folder, "1.txt")
    await _mk_asset_with_key(world, world.folder, "est_1.txt", key, b"holder-a")
    await _mk_asset_with_key(world, world.folder, "old.txt", key, b"holder-b", deleted=True)
    task = await _mk_task(world, status="running")
    row = await _mk_file(task, "1.txt", size=9)
    mock_baidu.add((await _get_file(row.id)).fs_id, b"incoming9")

    await _dispatch_claim_run(task.id)

    frow = await _get_file(row.id)
    assert frow.status == "failed"
    err = frow.last_error or ""
    assert err.startswith(f"key_conflict: {key} 已被 "), f"F1 前缀: {err!r}"
    assert "est_1.txt" in err and "old.txt(回收站)" in err, \
        f"多占用者全列且软删者附 (回收站): {err!r}"
    assert "、" in err, "多占用者以 、 分隔(F1 格式)"
    assert frow.non_retryable is False


# ─── 功能点 2:F2a 覆盖成功 —— purge 占用行(含 FGA/audit 收尾)后按 canonical key 落库 ──
async def test_f2a_overwrite_purges_holder_then_lands_new_file(
    world: World, mock_baidu, client, enable_baidu, stack,
) -> None:
    """有权限者(admin)对 failed+key_conflict 行 overwrite → 202 → 行 success、
    canonical key 对象为新文件、est 占用行物理清除(行 + 对象 + FGA tuple +
    asset_purged 审计收尾)。【集成】需求点 2"""
    holder_content = b"est-holder-bytes"
    key = _task_key(world.folder, "1.txt")
    holder = await _mk_asset_with_key(
        world, world.folder, "est_1.txt", key, holder_content, uploader=world.admin,
    )
    task = await _mk_task(world, status="running", user_id=world.admin.id)
    new_content = b"overwritten-new!"   # 与行 source_size 等长(落库 head size 校验)
    row = await _mk_file(task, "1.txt", size=len(new_content))

    # 前置 sanity:admin 对占用资产可达 can_admin;FGA tuple 在位(可下载)
    perms = PermissionsService(get_settings())
    try:
        assert await perms.check(
            user_subject=f"user:{world.admin.id}", relation="can_admin",
            object_type="folder", object_id=str(world.folder.id),
        ), "用例前提不成立:admin 应持有 folder can_admin"
        assert await perms.check(
            user_subject=f"user:{world.admin.id}", relation="can_download",
            object_type="asset", object_id=str(holder.id),
        ), "用例前提不成立:purge 前 holder 的 asset tuple 应可达"
    finally:
        await perms.close()

    # 第一轮直拍:制造 failed+key_conflict 行(真实走一轮导入)
    mock_baidu.add((await _get_file(row.id)).fs_id, b"first-attempt!")
    await _dispatch_claim_run(task.id)
    frow = await _get_file(row.id)
    assert frow.status == "failed" and (frow.last_error or "").startswith("key_conflict:")

    # F2a:overwrite 准入扩展到 failed+key_conflict 行
    r = await client.post(f"{BA}/tasks/{task.id}/files/{row.id}/overwrite",
                          headers=_h(world.admin.id))
    assert r.status_code == 202, r.text
    frow = await _get_file(row.id)
    assert frow.status == "pending" and frow.overwrite is True, "行复位 pending 且 overwrite=true"

    mock_baidu.add((await _get_file(row.id)).fs_id, new_content)
    await _claim_and_run(task.id)

    t = await _get_task(task.id)
    assert t.status == "completed"
    frow = await _get_file(row.id)
    assert frow.status == "success" and frow.asset_id is not None
    # canonical key 对象内容为新文件;引用行恰一份(新行)
    head = await _head(world.project.minio_bucket, key)
    assert head is not None and head["ContentLength"] == len(new_content)
    rows_on_key = await _assets_with_key(world, key)
    assert len(rows_on_key) == 1 and rows_on_key[0].id != holder.id
    assert rows_on_key[0].size_bytes == len(new_content)
    # 占用行物理清除(非软删)+ FGA tuple 收尾
    async with _db() as db:
        assert await db.get(Asset, holder.id) is None, "占用行必须物理删除"
    perms = PermissionsService(get_settings())
    try:
        assert not await perms.check(
            user_subject=f"user:{world.admin.id}", relation="can_download",
            object_type="asset", object_id=str(holder.id),
        ), "purge 后 holder 的 asset tuple 必须已撤销"
    finally:
        await perms.close()
    # audit 收尾(与既有 purge 用例同款断言口径):asset_purged 快照含 holder
    async with _db() as db:
        purged = (await db.execute(select(AuditEvent).where(
            AuditEvent.event_type == "asset_purged"))).scalars().all()
    mine = [p for p in purged if (p.details or {}).get("asset_id") == str(holder.id)]
    assert mine, f"asset_purged 审计缺失: {[p.details for p in purged][-5:]}"
    assert all(p.target_asset_id is None for p in mine), "行已删,不得带 target_asset_id(FK)"
    assert await _audit_count("baidu_file_imported") >= 1


# ─── 功能点 3:F2a 无权限 —— overwrite_forbidden_for_holder 点名 ─────────────────
async def test_f2a_overwrite_without_holder_permission_fails_named(
    world: World, mock_baidu, client, enable_baidu, stack,
) -> None:
    """操作者对占用资产行无 can_admin(member 非 folder admin)→ 行失败
    overwrite_forbidden_for_holder 且信息点名无权限的占用者;占用者行/对象原样。【集成】需求点 3"""
    key = _task_key(world.folder, "1.txt")
    holder = await _mk_asset_with_key(
        world, world.folder, "est_1.txt", key, b"holder-bytes", uploader=world.admin,
    )
    task = await _mk_task(world, status="running")   # 属主/操作者 = member
    row = await _mk_file(task, "1.txt", size=9)

    perms = PermissionsService(get_settings())
    try:
        if await perms.check(
            user_subject=f"user:{world.member.id}", relation="can_admin",
            object_type="folder", object_id=str(world.folder.id),
        ):
            pytest.skip("member 意外持有 can_admin,用例前提不成立")
    finally:
        await perms.close()

    mock_baidu.add((await _get_file(row.id)).fs_id, b"first-run")
    await _dispatch_claim_run(task.id)
    frow = await _get_file(row.id)
    assert frow.status == "failed" and (frow.last_error or "").startswith("key_conflict:")

    r = await client.post(f"{BA}/tasks/{task.id}/files/{row.id}/overwrite",
                          headers=_h(world.member.id))
    assert r.status_code == 202, r.text
    mock_baidu.add((await _get_file(row.id)).fs_id, b"should-not-land")
    await _claim_and_run(task.id)

    frow = await _get_file(row.id)
    assert frow.status == "failed"
    err = frow.last_error or ""
    assert "overwrite_forbidden_for_holder" in err, f"须落 overwrite_forbidden_for_holder: {err!r}"
    assert "est_1.txt" in err, f"信息必须点名无权限的占用者: {err!r}"
    # 占用者行与对象原样保留,未产生新落库
    async with _db() as db:
        assert await db.get(Asset, holder.id) is not None
    head = await _head(world.project.minio_bucket, key)
    assert head is not None and head["ContentLength"] == len(b"holder-bytes")
    assert len(await _assets_with_key(world, key)) == 1


# ─── 功能点 4/5:F2b 随机后缀 ─────────────────────────────────────────────────────
def _assert_reserved_shape(key: str, folder_prefix: str, stem: str, ext: str) -> None:
    """D5/实现 random_suffix_key 形态:有扩展名 → {stem}.{rand8}.{ext};
    无扩展名/.hidden → {name}.{rand8}。rand = secrets.token_hex(4),恒 8 位 hex。"""
    assert key is not None and key.startswith(folder_prefix)
    rest = key[len(folder_prefix):]
    parts = rest.split(".")
    if ext:
        assert len(parts) == 3, f"形态应为 stem.rand8.ext: {rest!r}"
        assert parts[0] == stem and parts[2] == ext, f"stem/ext 段不符: {rest!r}"
        rand = parts[1]
    else:
        assert len(parts) == 2, f"无扩展名形态应为 name.rand8: {rest!r}"
        assert parts[0] == stem, f"stem 段不符: {rest!r}"
        rand = parts[1]
    assert len(rand) == 8 and all(c in "0123456789abcdef" for c in rand), \
        f"随机段须为 8 位 hex(token_hex(4)): {rest!r}"


async def _reserve(world: World, client, task, row) -> str:
    """调 random-suffix 并断言行复位形态,返回预定 key。"""
    r = await client.post(f"{BA}/tasks/{task.id}/files/{row.id}/random-suffix",
                          headers=_h(world.member.id))
    assert r.status_code == 202, r.text
    frow = await _get_file(row.id)
    assert frow.status == "pending" and frow.overwrite is False, "行复位 pending(overwrite=false)"
    assert frow.reserved_key, "路由侧必须预写 reserved_key"
    return str(frow.reserved_key)


async def test_f2b_random_suffix_lands_reserved_key_keeps_filename(
    world: World, mock_baidu, client, enable_baidu, stack,
) -> None:
    """random-suffix → 202 → 行按预定 key 落库:filename 保持网盘原名 1.txt、
    key={prefix}1.{rand8}.txt 不与任何行冲突、原 est_1.txt 行/对象完好、
    新审计事件 baidu_file_random_suffix。【集成】需求点 4"""
    task, row, holder, key = await _mk_scene(world, incoming_size=len(b"random-suffix-bytes"))
    new_content = b"random-suffix-bytes"           # 与行 source_size 等长
    mock_baidu.add((await _get_file(row.id)).fs_id, new_content)

    # 先制造 failed+key_conflict 行(直拍一轮),再走 F2b
    await _dispatch_claim_run(task.id)
    frow = await _get_file(row.id)
    assert frow.status == "failed" and (frow.last_error or "").startswith("key_conflict:")

    reserved = await _reserve(world, client, task, row)
    folder_prefix = f"{world.folder.minio_prefix.rstrip('/')}/"
    _assert_reserved_shape(reserved, folder_prefix, "1", "txt")
    assert not await _assets_with_key(world, reserved), "预定 key 不得与任何行冲突"
    assert (await _get_file(row.id)).reserved_key == reserved

    await _claim_and_run(task.id)

    t = await _get_task(task.id)
    assert t.status == "completed"
    frow = await _get_file(row.id)
    assert frow.status == "success" and frow.asset_id is not None
    async with _db() as db:
        asset = await db.get(Asset, frow.asset_id)
    assert asset is not None
    assert asset.filename == "1.txt", "filename 必须保持网盘原文件名(不混入随机段)"
    assert asset.minio_key == reserved, "落库 key 必须是预定 key"
    assert asset.minio_bucket == world.project.minio_bucket
    head = await _head(world.project.minio_bucket, reserved)
    assert head is not None and head["ContentLength"] == len(new_content)
    # 原占用者完好(行 + 对象),canonical key 未被新文件占用
    async with _db() as db:
        assert await db.get(Asset, holder.id) is not None
    head_old = await _head(world.project.minio_bucket, key)
    assert head_old is not None and head_old["ContentLength"] == len(b"holder-residual-bytes")
    assert len(await _assets_with_key(world, key)) == 1
    assert await _audit_count("baidu_file_random_suffix") >= 1, "须落 baidu_file_random_suffix 审计"


async def test_f2b_random_suffix_reuses_reserved_key_on_reapply(
    world: World, mock_baidu, client, enable_baidu, monkeypatch, stack,
) -> None:
    """幂等:预留后模拟中断(该行与任务双双再次失败)再次 random-suffix →
    复用同一 reserved_key,不重新生成(中断重试不漂移),并最终按预定 key 落库
    success。【集成】需求点 5

    注意任务级门:random-suffix 与 overwrite 同构,仅 failed/completed 任务可调
    (活动任务 409)—— 第一次请求已把任务置 running,真实幂等场景是「任务再次
    失败」,故中断模拟须把行与任务一并直改回 failed,否则二次请求先撞任务级 409。
    """
    task, row, _holder, key = await _mk_scene(world, incoming_size=len(b"payload-12"))
    mock_baidu.add((await _get_file(row.id)).fs_id, b"payload-12")
    await _dispatch_claim_run(task.id)
    frow = await _get_file(row.id)
    assert frow.status == "failed" and (frow.last_error or "").startswith("key_conflict:")

    reserved_first = await _reserve(world, client, task, row)

    # 模拟中断:导入未完成,该行再次失败、任务随之 failed(直改 DB 构造,同既有
    # 故障注入口径;行 last_error 按 F1 实现格式逐字构造 —— names 与「占用」间无空格)
    async with _db() as db:
        await db.execute(update(BaiduBackupTaskFile).where(BaiduBackupTaskFile.id == row.id).values(
            status="failed",
            last_error=f"key_conflict: {key} 已被 est_1.txt占用",
            attempts=1,
        ))
        await db.commit()
    await _touch_task(task.id, status="failed")

    reserved_again = await _reserve(world, client, task, row)
    assert reserved_again == reserved_first, \
        f"已有预定 key 必须复用: first={reserved_first!r} again={reserved_again!r}"
    frow = await _get_file(row.id)
    assert frow.status == "pending" and frow.overwrite is False
    assert (await _get_file(row.id)).reserved_key == reserved_first

    # 复用的预定 key 真实可用:按预定 key 落库至 success(不漂移的端到端证明)
    mock_baidu.add((await _get_file(row.id)).fs_id, b"payload-12")
    await _claim_and_run(task.id)
    t = await _get_task(task.id)
    assert t.status == "completed"
    frow = await _get_file(row.id)
    assert frow.status == "success" and frow.asset_id is not None
    async with _db() as db:
        asset = await db.get(Asset, frow.asset_id)
    assert asset is not None
    assert asset.minio_key == reserved_first and asset.filename == "1.txt"
    head = await _head(world.project.minio_bucket, reserved_first)
    assert head is not None and head["ContentLength"] == len(b"payload-12")


# ─── 功能点 6:回收站占用 ─────────────────────────────────────────────────────────
async def test_trash_holder_named_recycle_bin_and_random_suffix_unaffected(
    world: World, mock_baidu, client, enable_baidu, stack,
) -> None:
    """软删 1.txt(key=11/1.txt)→ 导入 1.txt:failed 点名 `1.txt(回收站)`;
    random-suffix 成功且软删行不受影响(deleted_at/filename 原样)。【集成】需求点 6"""
    key = _task_key(world.folder, "1.txt")
    holder = await _mk_asset_with_key(
        world, world.folder, "1.txt", key, b"trashed-object", deleted=True,
    )
    task = await _mk_task(world, status="running")
    new_content = b"fresh-incoming!"   # 与行 source_size 等长
    row = await _mk_file(task, "1.txt", size=len(new_content))
    mock_baidu.add((await _get_file(row.id)).fs_id, new_content)

    await _dispatch_claim_run(task.id)

    frow = await _get_file(row.id)
    assert frow.status == "failed", "软删占用同 key 也必须拦截(不因软删放行)"
    assert frow.last_error == f"key_conflict: {key} 已被 1.txt(回收站)占用", \
        f"须点名 (回收站): {frow.last_error!r}"
    assert frow.non_retryable is False
    # 拦截发生在落库前:canonical key 上无任何对象写出
    assert await _head(world.project.minio_bucket, key) is None

    # F2b 出路:random-suffix 成功,软删行不受影响
    reserved = await _reserve(world, client, task, row)
    assert reserved != key
    mock_baidu.add((await _get_file(row.id)).fs_id, new_content)
    await _claim_and_run(task.id)

    t = await _get_task(task.id)
    assert t.status == "completed"
    frow = await _get_file(row.id)
    assert frow.status == "success"
    async with _db() as db:
        asset = await db.get(Asset, frow.asset_id)
        holder_row = await db.get(Asset, holder.id)
    assert asset is not None and asset.minio_key == reserved and asset.filename == "1.txt"
    assert holder_row is not None, "软删占用行必须原样保留"
    assert holder_row.deleted_at is not None and holder_row.filename == "1.txt"
    assert await _head(world.project.minio_bucket, reserved) is not None
    assert await _head(world.project.minio_bucket, key) is None, "canonical key 不得被写出"


# ─── 功能点 7:同名活行回归 —— 默认仍 skip,不走 key_conflict ─────────────────────
async def test_same_name_active_row_still_skipped_exists(
    world: World, mock_baidu, stack,
) -> None:
    """目标夹已有同名活跃文件 → 默认 skipped_exists(既有语义不因本次改动改道
    key_conflict 失败)。【集成】需求点 7"""
    await _mk_asset(world, world.folder, "dup.mp4", b"already-there")
    task = await _mk_task(world, status="running")
    row = await _mk_file(task, "dup.mp4", size=12)
    mock_baidu.add((await _get_file(row.id)).fs_id, b"dup-content!")

    await _dispatch_claim_run(task.id)

    frow = await _get_file(row.id)
    assert frow.status == "skipped_exists", \
        f"同名活行默认仍 skip: {frow.status}/{frow.last_error!r}"
    assert "key_conflict" not in (frow.last_error or "")
    t = await _get_task(task.id)
    assert t.status == "completed", "纯 skip 无失败 → 任务 completed"


# ─── P2-1:reserve_random_key CAS —— 并发首次预定先写者胜,后写者 0 行不漂移 ────
async def test_reserve_random_key_first_write_wins_no_drift(
    world: World, stack,
) -> None:
    """service 层 CAS 回归(P2-1):同一 failed 行两事务先后 reserve 不同候选
    key —— 首写落定 rowcount=1,后写谓词不命中 rowcount=0,reserved_key 保持
    先写者值。修复前:谓词只卡 status,行复位 pending 后仍命中,双事务先后
    写均 rowcount=1 → key 被后写者静默改写(与 docstring 宣称相悖)。末段
    顺带钉住同值幂等复用分支(行已有 K1 再 reserve K1 仍 rowcount=1)。
    【集成】复用测试者实锤手法:两事务先后 reserve。"""
    from app.services.baidu_backup import reserve_random_key

    task = await _mk_task(world, status="failed")
    row = await _mk_file(
        task, "cas.txt", status="failed",
        # F1 真实格式:names 与「占用」间无空格(format_key_conflict_message)
        last_error="key_conflict: cas.txt 已被 other.txt占用", non_retryable=False,
    )
    prefix = f"{world.folder.minio_prefix.rstrip('/')}/"
    k1, k2 = f"{prefix}1.aaaa1111.txt", f"{prefix}1.bbbb2222.txt"

    # 事务 1(先写者):行 reserved_key IS NULL → 命中,落定 K1
    async with _db() as db:
        n1 = await reserve_random_key(db, task_id=task.id, file_id=row.id, reserved_key=k1)
        await db.commit()
    assert n1 == 1

    # 事务 2(后写者):行已有 K1 ≠ 本次 K2 → 谓词不命中 → 0 行(key 不漂移)
    async with _db() as db:
        n2 = await reserve_random_key(db, task_id=task.id, file_id=row.id, reserved_key=k2)
        await db.commit()
    assert n2 == 0, "并发首次预定的后写者必须 0 行(否则 reserved_key 被静默改写)"

    # 现值:先写者的 key 原样保留,行复位 pending(overwrite=false)
    frow = await _get_file(row.id)
    assert str(frow.reserved_key) == k1, f"reserved_key 必须保持先写者值: {frow.reserved_key!r}"
    assert frow.status == "pending" and frow.overwrite is False

    # 同值幂等复用分支不回退:行已有 K1 再 reserve K1 仍命中(failed/pending 复用)
    async with _db() as db:
        n3 = await reserve_random_key(db, task_id=task.id, file_id=row.id, reserved_key=k1)
        await db.commit()
    assert n3 == 1
    assert str((await _get_file(row.id)).reserved_key) == k1
