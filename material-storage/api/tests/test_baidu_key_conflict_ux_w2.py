"""百度备份 key 冲突体验优化 W2 —— 导入期 key 冲突自动随机后缀(默认行为)— worker 层。

对应需求文档(唯一依据):docs/qdev/2026-10-20-baidu-key-conflict-ux.md
权威方案:rushes-spec/material-storage/baidu-key-conflict-ux-plan.md §2「测试功能点」
(W2-T1 至 T9,逐条对应,一条不少)。触发口径:非 overwrite 行 + key 占用 +
占用者全部属于其他项目 → 自动后缀;同项目占用/归属不明 → 维持现状 key_conflict。
【集成】用例须跑容器栈(真实 PG/Redis/MinIO + OpenFGA),门控与
tests/test_baidu_integration.py 同款:任一栈不可达 → 整模块 skip。
运行方式:`docker exec ms-api pytest tests/test_baidu_key_conflict_ux_w2.py -v`。

脚手架全量复用 tests/test_baidu_integration.py(world/mock_baidu/stack/client
fixture 与任务/资产行构造、派发驱动 helper —— 用法与 tests/test_baidu_key_conflict.py
同款:fixture 按「被装饰函数对象」解析,session 级 stack/client 同进程共享)。
本文件仅新增两类造数/观测面:
- siblings:「跨项目同前缀」世界工厂(4da4b1c1 形态 —— 另一项目共用同物理桶,
  其同名承接夹 minio_prefix 与本项目逐字相同;物理编号不含项目名是既有规则),
  收尾自清理(先于 world 清理执行);
- _script_holders/_script_token_hex:对既有锚点 `_key_conflict_holders`
  (workers 查询层)与候选随机源 `secrets.token_hex` 的脚本化包装 —— 只在
  既有函数边界注入,不耦合 W2 新增内部符号。

断言口径:全部落在 DB 状态 / 任务行状态 / reserved_key 值 / 对象存储 head /
list_parts 等可观测面;`random_key_taken`/`random_suffix_key`/`KEY_MAX_CHARS`
为方案锚点既有函数,允许直引。

测试函数 → 方案 §2「测试功能点」映射(PM 验收对照):
  W2-T1 跨项目占用自动后缀落库成功(两资产独立/占用者不动/任务 completed/
        行 reserved_key=后缀 key/审计落新 key)
                                        → test_w2_t1_cross_project_holder_auto_suffix_lands_reserved_key
  W2-T2 同项目占用维持现状失败(F1 逐字文案,复活覆盖流出路保留)
                                        → test_w2_t2_same_project_holder_still_fails_key_conflict
  W2-T2 混合占用(同项目+跨项目并存)→ 同样不自动后缀
                                        → test_w2_t2_mixed_holders_no_auto_suffix
  W2-T2 folder 缺失归属不明(防御分支;Asset.folder_id RESTRICT 使 DB seed
        不可构造,仅 mock 查询层 —— 归属 masked None)→ 维持现状失败
                                        → test_w2_t2_holder_project_unresolvable_no_auto_suffix
  W2-T3 候选碰撞(mock 首四次候选已占用)→ 第五次成功
                                        → test_w2_t3_candidate_collisions_fifth_attempt_succeeds
  W2-T3 五次全撞 → failed(key_conflict) 兜底不挂死
                                        → test_w2_t3_five_collisions_bottom_out_failed
  W2-T3 候选超 KEY 护栏 → fail-fast 直败(不做无效重试)
                                        → test_w2_t3_candidate_over_key_guard_fail_fast
  W2-T4 同任务防双写=机制单测:random_key_taken 撞同任务其他行 reserved_key
        → True;排除自身 → False;资产(含软删)引用 → True
                                        → test_w2_t4_random_key_taken_excludes_same_task_reserved_rows
  W2-T4 守卫兜底单测:行预置 reserved_key(手工 F2b 已预定形态)再遇跨项目
        占用 → 不改写原 reserved_key、failed(key_conflict) 兜底
                                        → test_w2_t4_pre_reserved_row_bottom_out_key_conflict
  W2-T5 二检窗口换 key:传输窗口内出现跨项目占用 → 在途会话作废、按新 key
        从头续跑、complete 到新 key、无孤儿残留
                                        → test_w2_t5_second_check_window_switch_key_no_orphan
  W2-T6 软删占用行口径:跨项目软删占用同样参与判别并触发自动后缀
                                        → test_w2_t6_soft_deleted_cross_project_holder_still_triggers
  W2-T7 带陈旧三元组的 retry 行首检换 key:failed 行携存活会话 → retry 后首检
        命中 → 陈旧会话作废、按新 key 一次落库成功(防「新 key 配旧 upload_id」
        烧穿 attempt 的永久卡死回路)
                                        → test_w2_t7_retry_row_stale_session_switch_key_first_check
  W2-T8 overwrite 行 + 跨项目占用 → 走既有 F2a 清除路径不进自动后缀
                                        → test_w2_t8_overwrite_row_walks_f2a_not_auto_suffix
  W2-T9 守卫写后、重进传输前崩溃 → sweeper 接管 → 行按 reserved_key 一次落库
        成功(注入点=重进传输后的首检查询抛错,直接驱动接管后的导入,勿造假
        进程崩溃)
                                        → test_w2_t9_crash_after_guard_write_sweeper_takeover_lands_reserved_key
"""
from __future__ import annotations

import secrets
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from sqlalchemy import select, update

import app.workers.baidu_backup as wmod
from app.db.tables import Asset, BaiduBackupTaskFile, Folder, Project
from app.services.baidu_backup import random_key_taken, random_suffix_key
from app.services.folder_chain import KEY_MAX_BYTES, KEY_MAX_CHARS
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
    _fga_write,
    _get_file,
    _get_task,
    _h,
    _head,
    _list_parts_sync,
    _mk_file,
    _mk_task,
    _put_object,
    _seed_multipart,
    _sweep_now,
    _task_key,
    _touch_task,
)

# fixture 再输出(赋值形态:from-import 直引会与用例签名同名形参撞 ruff F811,
# 赋值绑定不触发;解析按函数对象身份,与 test_baidu_integration 内定义即同一 fixture)
client = it.client
enable_baidu = it.enable_baidu
mock_baidu = it.mock_baidu
stack = it.stack
world = it.world

MB = 1024 * 1024


# ─── 断言与造数 helper(就地自建,不动存量)─────────────────────────────────────
def _assert_reserved_shape(key: str, folder_prefix: str, stem: str, ext: str) -> None:
    """random_suffix_key 形态:有扩展名 → {stem}.{rand8}.{ext};无扩展名/.hidden →
    {name}.{rand8}。rand = secrets.token_hex(4),恒 8 位 hex(方案 §2 候选生成口径)。"""
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


async def _assets_with_key(bucket: str, key: str) -> list[Asset]:
    async with _db() as db:
        rows = (await db.execute(
            select(Asset).where(Asset.minio_bucket == bucket, Asset.minio_key == key)
        )).scalars().all()
        db.expunge_all()
        return list(rows)


async def _mk_holder_asset(
    world: World, folder: Folder, bucket: str, key: str, filename: str, content: bytes,
    *, deleted: bool = False, bootstrap_tuple: bool = False,
) -> Asset:
    """直插一条占用 asset(真实对象落于指定 bucket/key;软删行不落对象,同既有
    helper 口径)。folder 可属另一项目 —— 跨项目占用 = 4da4b1c1 实战形态:
    两项目同名承接夹同前缀,物理编号不含项目名 → 同桶同 key。
    bootstrap_tuple=True 时补 asset parent tuple(仅 T8 的 F2a 权限复查依赖;
    其余用例不复查占用者权限,免写)。"""
    if not deleted:
        await _put_object(bucket, key, content)
    a = Asset(
        folder_id=folder.id, filename=filename,
        minio_bucket=bucket, minio_key=key,
        size_bytes=len(content), uploader_id=world.member.id,
        deleted_at=datetime.now(UTC) if deleted else None,
    )
    async with _db() as db:
        db.add(a)
        await db.commit()
        await db.refresh(a)
        db.expunge(a)
    if bootstrap_tuple:
        perms = PermissionsService(get_settings())
        try:
            await perms.bootstrap_asset(asset_id=str(a.id), parent_type="folder",
                                        parent_id=str(folder.id))
        finally:
            await perms.close()
    return a


@dataclass
class Sibling:
    """跨项目占用世界:另一 project(共用同物理桶)+ 同前缀承接夹。"""

    project: Project
    folder: Folder


class SiblingFactory:
    """「跨项目同前缀」世界工厂(4da4b1c1 形态)。

    - bucket 直传 world.project.minio_bucket:物理编号不含项目名,两项目共用
      同一物理键空间(冲突的真实前提);project 行的 minio_bucket 列同值落库;
    - prefix 逐字直存(与本项目承接夹同形);admin_purpose=True 时补 FGA
      (folder parent tuple + world.admin 的 project admin 角色),供 T8 的
      F2a 跨项目 purge 权限链;
    - 收尾自清理:assets → projects(folders 随 CASCADE),先于 world 清理执行。
    """

    def __init__(self, w: World) -> None:
        self.w = w
        self.created: list[Sibling] = []

    async def add(self, *, prefix: str, bucket: str, admin_purpose: bool = False) -> Sibling:
        tag = uuid.uuid4().hex[:8]
        async with _db() as db:
            p = Project(
                organization_id=self.w.org.id,
                code=f"itbkw_{tag}",
                name=f"it-bkw-sibling-{tag}",
                minio_bucket=bucket,
                visibility="private",
            )
            db.add(p)
            await db.flush()
            f = Folder(project_id=p.id, name=prefix.rstrip("/") or tag, minio_prefix=prefix)
            db.add(f)
            await db.commit()
            await db.refresh(f)
            fid, pid = f.id, p.id
            db.expunge_all()
        if admin_purpose:
            perms = PermissionsService(get_settings())
            try:
                await perms.bootstrap_folder(folder_id=str(fid), parent_type="project",
                                             parent_id=str(pid))
                await _fga_write(perms, [(f"user:{self.w.admin.id}", "admin",
                                          f"project:{pid}")])
            finally:
                await perms.close()
        sib = Sibling(project=p, folder=f)
        self.created.append(sib)
        return sib

    async def cleanup(self) -> None:
        if not self.created:
            return
        pids = [s.project.id for s in self.created]
        async with _db() as db:
            folder_ids = (await db.execute(
                select(Folder.id).where(Folder.project_id.in_(pids))
            )).scalars().all()
            if folder_ids:
                await db.execute(Asset.__table__.delete().where(Asset.folder_id.in_(folder_ids)))
            await db.execute(Project.__table__.delete().where(Project.id.in_(pids)))
            await db.commit()


@pytest.fixture
async def siblings(world: World):
    """跨项目占用世界工厂(依赖 world;teardown 先于 world 清理)。"""
    factory = SiblingFactory(world)
    yield factory
    await factory.cleanup()


def _script_token_hex(monkeypatch: pytest.MonkeyPatch, rands: list[str]) -> list[str]:
    """脚本化候选随机段(secrets.token_hex(4),候选生成随机源)。

    同时挂 stdlib secrets 模块属性与 worker 模块名(两种 import 形态兜底);
    脚本清单耗尽后回落真实随机(不阻断流程),调用序全量记录作断言载体
    (T3:碰撞次数/护栏 fail-fast 不生成的观测面)。"""
    calls: list[str] = []
    queue = list(rands)

    def fake(_n: int | None = None) -> str:
        r = queue.pop(0) if queue else uuid.uuid4().hex
        calls.append(r)
        return r

    monkeypatch.setattr(secrets, "token_hex", fake)
    if hasattr(wmod, "token_hex"):
        monkeypatch.setattr(wmod, "token_hex", fake)
    return calls


def _script_holders(
    monkeypatch: pytest.MonkeyPatch, *, row_id: uuid.UUID,
    state: dict[str, Any], inject_at: int | None = None,
    crash_at: int | None = None, inject: Any = None,
) -> None:
    """既有锚点 `_key_conflict_holders`(workers 查询层)的脚本化包装:

    - 第 inject_at 次调用前:先记下该行在途会话 upload_id(断言载体),再执行
      inject(异步闭包,向 DB 注入跨项目占用 —— 查询本身透传真实实现,不造假
      返回形态);
    - 第 crash_at 次调用:抛 RuntimeError(守卫写后崩溃注入 —— 落点在重启机制
      已 commit 之后、新 key 传输之前,异常沿 job 边界上抛交 sweeper,勿造假
      进程崩溃);
    - 其余调用全部透传(返回形态随实现走,不耦合)。"""
    real = wmod._key_conflict_holders

    async def scripted(db: Any, *, bucket: str, key: str, exclude_asset_id: Any) -> Any:
        state["calls"] += 1
        if inject_at is not None and state["calls"] == inject_at and inject is not None:
            frow = await _get_file(row_id)
            state["upload_id"] = frow.minio_upload_id
            await inject(key)
        if crash_at is not None and state["calls"] == crash_at:
            raise RuntimeError("W2 守卫写后崩溃(桩注入,交 sweeper 接管)")
        return await real(db, bucket=bucket, key=key, exclude_asset_id=exclude_asset_id)

    monkeypatch.setattr(wmod, "_key_conflict_holders", scripted)


async def _mk_cross_scene(
    world: World, siblings: SiblingFactory, filename: str, *, size: int,
    seed_holder: bool = True,
) -> tuple[Any, Any, Sibling, str]:
    """最小跨项目占用场景:对方项目同前缀夹下一条占用 asset(key=canonical)
    + 本项目 running 任务 + 待导人行。返回 (task, row, sibling, canonical_key)。
    seed_holder=False 时不预置占用(T5/T9 的二检窗口注入由用例自控时点)。"""
    sib = await siblings.add(prefix="target-root/", bucket=world.project.minio_bucket)
    key = _task_key(world.folder, filename)
    if seed_holder:
        await _mk_holder_asset(world, sib.folder, world.project.minio_bucket, key,
                               "est_1.txt", b"holder-bytes")
    task = await _mk_task(world, status="running")
    row = await _mk_file(task, filename, size=size)
    return task, row, sib, key


# ════════════════ W2-T1:跨项目占用 → 自动后缀落库成功(旗舰)══════════════════
async def test_w2_t1_cross_project_holder_auto_suffix_lands_reserved_key(
    world: World, mock_baidu, siblings: SiblingFactory, stack,
) -> None:
    """对方项目占用 canonical key(占用者全跨项目)→ 自动随机后缀落库成功:
    两资产 id/key 独立、占用者(行+对象)不动、任务 completed、行 reserved_key=
    后缀 key(8 位 hex 形态)、成功行 last_error 被守卫 UPDATE 清空、换 key 不烧
    attempt、baidu_file_imported 审计落在新 key。【集成】W2-T1"""
    task, row, _sib, key = await _mk_cross_scene(world, siblings, "1.txt",
                                                 size=len(b"auto-suffix-bytes"))
    content = b"auto-suffix-bytes"           # 与行 source_size 等长
    mock_baidu.add(row.fs_id, content)

    await _dispatch_claim_run(task.id)

    t = await _get_task(task.id)
    assert t.status == "completed", f"自动后缀路径任务必须完成: {t.status}/{t.fail_reason}"
    frow = await _get_file(row.id)
    assert frow.status == "success" and frow.asset_id is not None
    reserved = str(frow.reserved_key)
    folder_prefix = f"{world.folder.minio_prefix.rstrip('/')}/"
    _assert_reserved_shape(reserved, folder_prefix, "1", "txt")
    assert reserved != key, "落库 key 必须漂移出 canonical"
    assert frow.last_error is None, "守卫 UPDATE 须清 last_error(成功行无残留错误文案)"
    assert frow.attempts == 1, "换 key 重试不烧 attempt(预算留给传输重试)"
    # 两资产独立:新资产按 reserved_key 落库,filename 保持网盘原名
    async with _db() as db:
        asset = await db.get(Asset, frow.asset_id)
    assert asset is not None
    assert asset.minio_bucket == world.project.minio_bucket
    assert asset.minio_key == reserved and asset.filename == "1.txt"
    head = await _head(world.project.minio_bucket, reserved)
    assert head is not None and head["ContentLength"] == len(content)
    # 占用者不动:canonical key 上仍是占用者的行与对象
    rows_on_key = await _assets_with_key(world.project.minio_bucket, key)
    assert len(rows_on_key) == 1 and rows_on_key[0].minio_key == key
    head_old = await _head(world.project.minio_bucket, key)
    assert head_old is not None and head_old["ContentLength"] == len(b"holder-bytes")
    # 审计副作用:导入审计落在新 key 上(可观测面)
    assert await _audit_count("baidu_file_imported",
                              target_minio_key=reserved) >= 1, "导入审计须落 reserved_key"


# ════════════════ W2-T2:同项目占用维持现状失败 / 混合占用 / 归属不明 ═════════
async def test_w2_t2_same_project_holder_still_fails_key_conflict(
    world: World, mock_baidu, stack,
) -> None:
    """同项目占用(007 残留形态:占用行 filename≠key)→ 行为与现状逐字一致:
    failed + F1 逐字文案点名占用者、non_retryable=false(可重试,「失败→复活
    覆盖导入」替换流出路保留)、reserved_key 不落、无后缀资产。【集成】W2-T2"""
    key = _task_key(world.folder, "1.txt")
    holder = await _mk_holder_asset(world, world.folder, world.project.minio_bucket,
                                    key, "est_1.txt", b"holder-residual-bytes")
    task = await _mk_task(world, status="running")
    row = await _mk_file(task, "1.txt", size=9)
    mock_baidu.add(row.fs_id, b"incoming9")

    await _dispatch_claim_run(task.id)

    frow = await _get_file(row.id)
    assert frow.status == "failed"
    assert frow.last_error == f"key_conflict: {key} 已被 est_1.txt占用", \
        f"现状 F1 格式必须逐字保留: {frow.last_error!r}"
    assert frow.non_retryable is False, "key_conflict 失败保持可重试(替换流入口)"
    assert frow.reserved_key is None, "同项目占用不得自动后缀"
    assert frow.asset_id is None
    t = await _get_task(task.id)
    assert t.status == "failed" and t.fail_reason == "file_failed"
    # 占用者原样,无任何后缀落库
    async with _db() as db:
        assert await db.get(Asset, holder.id) is not None
    assert len(await _assets_with_key(world.project.minio_bucket, key)) == 1


async def test_w2_t2_mixed_holders_no_auto_suffix(
    world: World, mock_baidu, siblings: SiblingFactory, stack,
) -> None:
    """混合占用(同项目 + 跨项目并存)→ 任一占用者属于本任务项目即不自动后缀:
    failed + F1 文案全列两占用者、reserved_key 不落。【集成】W2-T2"""
    sib = await siblings.add(prefix="target-root/", bucket=world.project.minio_bucket)
    key = _task_key(world.folder, "1.txt")
    bucket = world.project.minio_bucket
    await _mk_holder_asset(world, world.folder, bucket, key, "same_proj.txt", b"h-same")
    await _mk_holder_asset(world, sib.folder, bucket, key, "cross_proj.txt", b"h-cross")
    task = await _mk_task(world, status="running")
    row = await _mk_file(task, "1.txt", size=9)
    mock_baidu.add(row.fs_id, b"incoming9")

    await _dispatch_claim_run(task.id)

    frow = await _get_file(row.id)
    assert frow.status == "failed" and (frow.last_error or "").startswith("key_conflict:")
    err = frow.last_error or ""
    assert "same_proj.txt" in err and "cross_proj.txt" in err, \
        f"F1 多占用者全列: {err!r}"
    assert frow.reserved_key is None, "混合占用不自动后缀(占用者非全跨项目)"
    t = await _get_task(task.id)
    assert t.status == "failed"


async def test_w2_t2_holder_project_unresolvable_no_auto_suffix(
    world: World, mock_baidu, siblings: SiblingFactory, monkeypatch: pytest.MonkeyPatch,
    stack,
) -> None:
    """folder 缺失归属不明(防御分支)→ 按「非跨项目」保守维持现状失败。

    Asset.folder_id 外键 RESTRICT、资产存活期 folder 删不掉,DB seed 无法构造
    (方案 §2 测试功能点注记)——按注记仅 mock 查询层:把既有
    `_key_conflict_holders` 返回的占用者 project_id 一律 mask 为 None(等价
    outerjoin 未命中形态),判别必须落入保守分支。【集成】W2-T2(防御分支)"""
    sib = await siblings.add(prefix="target-root/", bucket=world.project.minio_bucket)
    key = _task_key(world.folder, "1.txt")
    bucket = world.project.minio_bucket
    await _mk_holder_asset(world, sib.folder, bucket, key, "est_1.txt", b"holder-bytes")
    real = wmod._key_conflict_holders

    async def _unresolvable(db: Any, *, bucket: str, key: str,
                            exclude_asset_id: Any) -> Any:
        holders = await real(db, bucket=bucket, key=key, exclude_asset_id=exclude_asset_id)
        return [(asset, None) for asset, _pid in holders]

    monkeypatch.setattr(wmod, "_key_conflict_holders", _unresolvable)

    task = await _mk_task(world, status="running")
    row = await _mk_file(task, "1.txt", size=9)
    mock_baidu.add(row.fs_id, b"incoming9")

    await _dispatch_claim_run(task.id)

    frow = await _get_file(row.id)
    assert frow.status == "failed" and (frow.last_error or "").startswith("key_conflict:"), \
        "归属不明必须保守走现状 key_conflict 失败"
    assert frow.reserved_key is None, "归属不明不得自动后缀"


# ════════════════ W2-T3:后缀候选碰撞 / 护栏 fail-fast ════════════════════════
async def test_w2_t3_candidate_collisions_fifth_attempt_succeeds(
    world: World, mock_baidu, siblings: SiblingFactory, monkeypatch: pytest.MonkeyPatch,
    stack,
) -> None:
    """候选碰撞(脚本化随机源:首四次候选已占用)→ 第五次成功:循环 ≤5 与手工
    路径同款,落库 key=第五候选、四条占用候选的资产原样。【集成】W2-T3"""
    task, row, sib, key = await _mk_cross_scene(world, siblings, "1.txt", size=9)
    bucket = world.project.minio_bucket
    rands = ["aaaa1111", "bbbb2222", "cccc3333", "dddd4444", "eeee5555"]
    cands = [random_suffix_key(key, r) for r in rands]
    for cand, r in zip(cands[:4], rands[:4], strict=True):
        await _mk_holder_asset(world, sib.folder, bucket, cand, f"occ-{r}.bin", b"occ")
    calls = _script_token_hex(monkeypatch, rands)
    content = b"incoming9"
    mock_baidu.add(row.fs_id, content)

    await _dispatch_claim_run(task.id)

    t = await _get_task(task.id)
    assert t.status == "completed"
    frow = await _get_file(row.id)
    assert frow.status == "success" and frow.asset_id is not None
    assert str(frow.reserved_key) == cands[4], \
        f"前四次候选撞占用后必须取第五候选: {frow.reserved_key!r}"
    assert calls == rands, f"随机源恰按脚本消耗 5 次: {calls!r}"
    async with _db() as db:
        asset = await db.get(Asset, frow.asset_id)
    assert asset is not None and asset.minio_key == cands[4]
    # 四条占用候选的资产原样(各自 key 恰 1 行)
    for cand in cands[:4]:
        assert len(await _assets_with_key(bucket, cand)) == 1
    assert await _head(bucket, cands[4]) is not None
    assert (await _head(bucket, cands[4]))["ContentLength"] == len(content)


async def test_w2_t3_five_collisions_bottom_out_failed(
    world: World, mock_baidu, siblings: SiblingFactory, monkeypatch: pytest.MonkeyPatch,
    stack,
) -> None:
    """五次全撞 → 直接 failed(key_conflict) 兜底不挂死:reserved_key 不固化、
    任务终态 failed、随机源恰耗 5 次(循环 ≤5 不无限)。【集成】W2-T3"""
    task, row, sib, key = await _mk_cross_scene(world, siblings, "1.txt", size=9)
    bucket = world.project.minio_bucket
    rands = ["11111111", "22222222", "33333333", "44444444", "55555555"]
    for cand, r in zip([random_suffix_key(key, r) for r in rands], rands, strict=True):
        await _mk_holder_asset(world, sib.folder, bucket, cand, f"occ-{r}.bin", b"occ")
    calls = _script_token_hex(monkeypatch, rands)
    mock_baidu.add(row.fs_id, b"incoming9")

    await _dispatch_claim_run(task.id)

    frow = await _get_file(row.id)
    assert frow.status == "failed" and (frow.last_error or "").startswith("key_conflict:")
    assert frow.reserved_key is None, "候选耗尽走兜底,不得固化 reserved_key"
    assert frow.asset_id is None
    assert len(calls) == 5, f"循环 ≤5 恰耗尽脚本: {calls!r}"
    t = await _get_task(task.id)
    assert t.status == "failed" and t.fail_reason == "file_failed"


async def test_w2_t3_candidate_over_key_guard_fail_fast(
    world: World, mock_baidu, siblings: SiblingFactory, monkeypatch: pytest.MonkeyPatch,
    stack,
) -> None:
    """候选超 KEY 护栏(KEY_MAX_CHARS/KEY_MAX_BYTES)→ fail-fast 直败,不做无效
    重试:canonical key 本身合法(≤1024)而候选(增量恒定 +9 字符)必超 → 不进入
    占用探测循环即兜底。构造:直插长前缀目标夹(护栏常量对齐 key=1021,
    候选=1030>1024)。【集成】W2-T3"""
    sib = await siblings.add(prefix="target-root/", bucket=world.project.minio_bucket)
    # key = target-root/ + d*N + /v.txt;N 取使 key ≤1024 且 key+9 >1024
    n = KEY_MAX_CHARS - len("target-root/") - len("/v.txt") - 3
    prefix = f"target-root/{'d' * n}/"
    key = f"{prefix}v.txt"
    assert len(key) == KEY_MAX_CHARS - 3 and len(key) + 9 > KEY_MAX_CHARS
    assert len(key.encode("utf-8")) <= KEY_MAX_BYTES
    async with _db() as db:
        deep = Folder(project_id=world.project.id, name="deep-tail", minio_prefix=prefix)
        db.add(deep)
        await db.commit()
        await db.refresh(deep)
        deep_id = deep.id
        db.expunge_all()
    perms = PermissionsService(get_settings())
    try:
        await perms.bootstrap_folder(folder_id=str(deep_id), parent_type="project",
                                     parent_id=str(world.project.id))
        await perms.grant_folder_explicit_subject(folder_id=str(deep_id),
                                                  subject=f"user:{world.member.id}",
                                                  kind="explicit_uploader")
    finally:
        await perms.close()
    # 本部署 MinIO 对象名实限 255 字符(>255 抛 XMinioInvalidObjectName):1021 字符
    # key 不能落真实对象 —— 占用行改 DB-only 软删形态(不落对象;_key_conflict_holders
    # 含软删,首检照样命中 → 进候选生成 → 护栏超限 fail-fast,语义不变)
    await _mk_holder_asset(world, sib.folder, world.project.minio_bucket, key,
                           "est_1.txt", b"holder-bytes", deleted=True)
    calls = _script_token_hex(monkeypatch, [])   # 空脚本:若被调用即回落随机,但计数可断
    task = await _mk_task(world, status="running", target=await _folder_by_id(deep_id))
    row = await _mk_file(task, "v.txt", size=9)
    mock_baidu.add(row.fs_id, b"incoming9")

    await _dispatch_claim_run(task.id)

    frow = await _get_file(row.id)
    assert frow.status == "failed" and (frow.last_error or "").startswith("key_conflict:")
    assert frow.reserved_key is None and frow.asset_id is None
    assert len(calls) <= 1, \
        f"护栏超限 fail-fast:一个候选超限即全部超限,至多生成一次即跳出: {calls!r}"
    assert frow.attempts == 1, "fail-fast 不烧传输 attempt"
    t = await _get_task(task.id)
    assert t.status == "failed" and t.fail_reason == "file_failed", "兜底终态,不挂死"


async def _folder_by_id(folder_id: uuid.UUID) -> Folder:
    async with _db() as db:
        f = await db.get(Folder, folder_id)
        assert f is not None
        db.expunge(f)
        return f


# ════════════════ W2-T4:同任务防双写机制单测 + 守卫兜底单测 ══════════════════
async def test_w2_t4_random_key_taken_excludes_same_task_reserved_rows(
    world: World, stack,
) -> None:
    """机制单测(方案 §2-T4:集成侧勿造假同任务同名行 —— uq_baidu_task_file_relpath
    天然不存在,直测既有 `random_key_taken` 探测口径):同任务其他行 reserved_key
    占候选 → True(换下一候选);排除自身 → False;任一 asset(含软删)引用 → True。
    【集成】W2-T4(机制单测)"""
    task = await _mk_task(world, status="running")
    row_a = await _mk_file(task, "a.txt", size=4)
    row_b = await _mk_file(task, "b.txt", size=4)
    bucket = world.project.minio_bucket
    cand = _task_key(world.folder, "cand.bin")

    async with _db() as db:
        assert await random_key_taken(db, bucket=bucket, key=cand, task_id=task.id,
                                      exclude_file_id=row_b.id) is False, \
            "前置:无任何引用时候选空闲"
        await db.execute(update(BaiduBackupTaskFile).where(
            BaiduBackupTaskFile.id == row_a.id).values(reserved_key=cand))
        await db.commit()
    async with _db() as db:
        assert await random_key_taken(db, bucket=bucket, key=cand, task_id=task.id,
                                      exclude_file_id=row_b.id) is True, \
            "同任务其他行已预定同 key → True(候选撞车换下一候选的机制地基)"
        assert await random_key_taken(db, bucket=bucket, key=cand, task_id=task.id,
                                      exclude_file_id=row_a.id) is False, \
            "排除自身:行自己的 reserved_key 不算撞(幂等复用口径)"
    # 资产分支(软删同样计入,与 §6 预检口径一致)
    await _mk_holder_asset(world, world.folder, bucket, cand, "occupied.bin",
                           b"occ", deleted=True)
    async with _db() as db:
        assert await random_key_taken(db, bucket=bucket, key=cand, task_id=task.id,
                                      exclude_file_id=row_a.id) is True


async def test_w2_t4_pre_reserved_row_bottom_out_key_conflict(
    world: World, mock_baidu, siblings: SiblingFactory, stack,
) -> None:
    """守卫兜底单测:行预置 reserved_key(手工 F2b 已预定形态)再遇跨项目占用
    (占用出现在预定 key 上 —— 行导入按 reserved_key 落库,首检对象即预定 key)
    → 守卫谓词 reserved_key IS NULL 不命中 → failed(key_conflict) 兜底、原
    reserved_key 不被改写、两条出路互不干扰。【集成】W2-T4(守卫兜底单测)"""
    sib = await siblings.add(prefix="target-root/", bucket=world.project.minio_bucket)
    bucket = world.project.minio_bucket
    canonical = _task_key(world.folder, "1.txt")
    reserved = random_suffix_key(canonical, "7f3a9b21")
    holder = await _mk_holder_asset(world, sib.folder, bucket, reserved,
                                    "est_1.txt", b"holder-bytes")
    task = await _mk_task(world, status="running")
    row = await _mk_file(task, "1.txt", size=9, reserved_key=reserved)
    mock_baidu.add(row.fs_id, b"incoming9")

    await _dispatch_claim_run(task.id)

    frow = await _get_file(row.id)
    assert frow.status == "failed" and (frow.last_error or "").startswith("key_conflict:"), \
        "守卫未命中必须走现状 key_conflict 兜底"
    assert str(frow.reserved_key) == reserved, \
        f"原 reserved_key(手工 F2b 预定)不得被改写: {frow.reserved_key!r}"
    assert frow.asset_id is None
    async with _db() as db:
        assert await db.get(Asset, holder.id) is not None, "占用者不动"
    assert len(await _assets_with_key(bucket, reserved)) == 1, "无任何后缀落库"


# ════════════════ W2-T5:二检窗口换 key(会话作废 + 从头续跑 + 无孤儿)══════════
async def test_w2_t5_second_check_window_switch_key_no_orphan(
    world: World, mock_baidu, siblings: SiblingFactory, monkeypatch: pytest.MonkeyPatch,
    stack,
) -> None:
    """首检过后、complete 前二检窗口内出现跨项目占用 → 自动后缀:在途 multipart
    会话随旧 key 作废(abort)、按新 key 从头续跑、对象 complete 到新 key、
    canonical key 无对象残留且旧 upload_id 已死(无孤儿)。【集成】W2-T5"""
    task, row, sib, key = await _mk_cross_scene(world, siblings, "1.txt",
                                                size=len(b"second-check-payload"),
                                                seed_holder=False)
    bucket = world.project.minio_bucket
    content = b"second-check-payload"
    mock_baidu.add(row.fs_id, content)
    state: dict[str, Any] = {"calls": 0, "upload_id": None}

    async def _inject(canonical: str) -> None:
        await _mk_holder_asset(world, sib.folder, bucket, canonical,
                               "late_holder.txt", b"late-cross")

    _script_holders(monkeypatch, row_id=row.id, inject_at=2, inject=_inject, state=state)

    res = await _dispatch_claim_run(task.id)
    assert res["status"] == "completed"

    assert state["upload_id"], "前置:二检时刻行上必须有在途会话"
    frow = await _get_file(row.id)
    assert frow.status == "success" and frow.asset_id is not None
    reserved = str(frow.reserved_key)
    folder_prefix = f"{world.folder.minio_prefix.rstrip('/')}/"
    _assert_reserved_shape(reserved, folder_prefix, "1", "txt")
    assert reserved != key
    assert frow.attempts == 1, "二检换 key 不烧 attempt"
    async with _db() as db:
        asset = await db.get(Asset, frow.asset_id)
    assert asset is not None and asset.minio_key == reserved
    # 无孤儿残留:旧会话已死(list_parts → NoSuchUpload);canonical 上恰为二检
    # 注入的 late holder 对象(10 字节)—— 任务内容(20 字节)若有残留即长度不符
    head_old = await _head(bucket, key)
    assert head_old is not None and head_old["ContentLength"] == len(b"late-cross"), \
        "canonical 上恰为注入的 late holder 对象,任务内容无残留"
    assert _list_parts_sync(bucket, key, state["upload_id"]) is None, \
        "在途会话必须已随旧 key 作废(abort)"
    head = await _head(bucket, reserved)
    assert head is not None and head["ContentLength"] == len(content)


# ════════════════ W2-T6:软删占用行口径一致 ═══════════════════════════════════
async def test_w2_t6_soft_deleted_cross_project_holder_still_triggers(
    world: World, mock_baidu, siblings: SiblingFactory, stack,
) -> None:
    """软删跨项目占用(回收站形态)与既有 `_key_conflict_holders` 口径一致:
    同样参与判别并触发自动后缀;软删行原样(deleted_at/filename 不动)、
    canonical key 不落对象。【集成】W2-T6"""
    sib = await siblings.add(prefix="target-root/", bucket=world.project.minio_bucket)
    bucket = world.project.minio_bucket
    key = _task_key(world.folder, "1.txt")
    holder = await _mk_holder_asset(world, sib.folder, bucket, key, "1.txt",
                                    b"trashed-object", deleted=True)
    task = await _mk_task(world, status="running")
    content = b"fresh-incoming!"
    row = await _mk_file(task, "1.txt", size=len(content))
    mock_baidu.add(row.fs_id, content)

    await _dispatch_claim_run(task.id)

    t = await _get_task(task.id)
    assert t.status == "completed"
    frow = await _get_file(row.id)
    assert frow.status == "success" and frow.reserved_key, \
        "软删跨项目占用同口径触发自动后缀(不因软删维持失败)"
    _assert_reserved_shape(str(frow.reserved_key),
                           f"{world.folder.minio_prefix.rstrip('/')}/", "1", "txt")
    async with _db() as db:
        holder_after = await db.get(Asset, holder.id)
    assert holder_after is not None, "软删占用行必须原样保留"
    assert holder_after.deleted_at is not None and holder_after.filename == "1.txt"
    assert len(await _assets_with_key(bucket, key)) == 1, "canonical key 仅软删行引用"
    assert await _head(bucket, key) is None, "canonical key 不得被写出"


# ════════════════ W2-T7:带陈旧三元组的 retry 行首检换 key ════════════════════
async def test_w2_t7_retry_row_stale_session_switch_key_first_check(
    world: World, mock_baidu, siblings: SiblingFactory, client, enable_baidu, stack,
) -> None:
    """failed 行携带存活断点三元组(真实 multipart 会话)+ 跨项目占用出现 →
    retry 复活后**首检**命中 → 陈旧会话被作废、按新 key 一次落库成功
    (防「新 key 配旧 upload_id」烧穿 attempt 的永久卡死回路;attempts 恒 1)。
    【集成】W2-T7"""
    sib = await siblings.add(prefix="target-root/", bucket=world.project.minio_bucket)
    bucket = world.project.minio_bucket
    key = _task_key(world.folder, "1.txt")
    await _mk_holder_asset(world, sib.folder, bucket, key, "est_1.txt", b"holder-bytes")
    stale_upload = await _seed_multipart(bucket, key, 1)   # 真实存活的陈旧会话
    content = b"retry-payload"
    task = await _mk_task(world, status="failed", enum_done=True, fail_reason="file_failed")
    row = await _mk_file(
        task, "1.txt", size=len(content), status="failed", attempts=1,
        last_error=f"key_conflict: {key} 已被 est_1.txt占用",
        minio_bucket=bucket, minio_key=key, minio_upload_id=stale_upload,
        bytes_done=5 * MB,   # 与 seed 的 1 part 等长(断点形态自洽)
    )
    mock_baidu.add(row.fs_id, content)   # 下载流脚本(缺它 complete 0 parts → InvalidRequest)

    r = await client.post(f"{BA}/tasks/{task.id}/retry-failed", headers=_h(world.member.id))
    assert r.status_code == 202, r.text
    frow = await _get_file(row.id)
    assert frow.status == "pending"
    assert frow.minio_upload_id == stale_upload, "retry 保留断点三元组(failed 行语义)"

    res = await _claim_and_run(task.id)
    assert res["status"] == "completed"

    frow = await _get_file(row.id)
    assert frow.status == "success" and frow.asset_id is not None
    reserved = str(frow.reserved_key)
    assert reserved != key
    _assert_reserved_shape(reserved, f"{world.folder.minio_prefix.rstrip('/')}/", "1", "txt")
    assert frow.attempts == 1, "一次落库成功,不烧穿 attempt"
    # 陈旧会话已作废:旧 upload_id 对旧 key NoSuchUpload;canonical key 无对象
    assert _list_parts_sync(bucket, key, stale_upload) is None, \
        "首检换 key 必须先行作废陈旧会话(abort)"
    # canonical 上恰为占用者对象(b"holder-bytes",12 字节);任务内容(13 字节)
    # 不得落 canonical —— 若有残留即长度不符
    head_old = await _head(bucket, key)
    assert head_old is not None and head_old["ContentLength"] == len(b"holder-bytes"), \
        "canonical 上恰为占用者对象,任务内容不得落 canonical(无残留)"
    head = await _head(bucket, reserved)
    assert head is not None and head["ContentLength"] == len(content)
    rows_on_key = await _assets_with_key(bucket, key)
    assert len(rows_on_key) == 1, "canonical key 仅占用者一行,无重复落库"


# ════════════════ W2-T8:overwrite 行走既有 F2a,不进自动后缀 ═════════════════
async def test_w2_t8_overwrite_row_walks_f2a_not_auto_suffix(
    world: World, mock_baidu, siblings: SiblingFactory, stack,
) -> None:
    """overwrite 行 + 跨项目占用 → 走既有 F2a 清除路径(purge 跨项目占用者后按
    canonical key 落库),不进自动后缀(reserved_key 恒 NULL)—— 语义边界
    「不与 overwrite 组合」的回归钉。操作者须对占用资产 can_admin:factory 以
    admin_purpose 补齐跨项目 FGA 链。【集成】W2-T8"""
    sib = await siblings.add(prefix="target-root/",
                             bucket=world.project.minio_bucket, admin_purpose=True)
    bucket = world.project.minio_bucket
    key = _task_key(world.folder, "1.txt")
    holder = await _mk_holder_asset(world, sib.folder, bucket, key, "est_1.txt",
                                    b"holder-bytes", bootstrap_tuple=True)
    new_content = b"overwrite-cross!"
    task = await _mk_task(world, status="running", user_id=world.admin.id)
    row = await _mk_file(task, "1.txt", size=len(new_content), overwrite=True)
    mock_baidu.add(row.fs_id, new_content)

    await _dispatch_claim_run(task.id)

    t = await _get_task(task.id)
    assert t.status == "completed", f"F2a 覆盖路径须完成: {t.status}/{t.fail_reason}"
    frow = await _get_file(row.id)
    assert frow.status == "success" and frow.asset_id is not None
    assert frow.reserved_key is None, "overwrite 行不得进自动后缀(语义边界)"
    async with _db() as db:
        asset = await db.get(Asset, frow.asset_id)
        assert await db.get(Asset, holder.id) is None, "F2a:跨项目占用者被物理清除"
    assert asset is not None and asset.minio_key == key, \
        "落库必须按 canonical key(未漂移 = 未进自动后缀)"
    head = await _head(bucket, key)
    assert head is not None and head["ContentLength"] == len(new_content)
    rows_on_key = await _assets_with_key(bucket, key)
    assert len(rows_on_key) == 1 and rows_on_key[0].id == asset.id


# ════════════════ W2-T9:守卫写后崩溃 → sweeper 接管按 reserved_key 落库 ══════
async def test_w2_t9_crash_after_guard_write_sweeper_takeover_lands_reserved_key(
    world: World, mock_baidu, siblings: SiblingFactory, monkeypatch: pytest.MonkeyPatch,
    stack,
) -> None:
    """守卫写 reserved_key 之后、重进传输之前崩溃 → sweeper 接管 → 行按
    reserved_key 一次落库成功(默认开方案的安全性承重路径)。

    崩溃注入:二检(第 2 次占用查询)注入跨项目占用触发自动后缀重启;重启后
    新 key 的首检(第 3 次)抛 RuntimeError —— 落点在守卫 UPDATE 已 commit
    (重进循环的 checkpoint 心跳提交)之后,异常沿 job 边界上抛交 sweeper,
    不造假进程崩溃。【集成】W2-T9"""
    task, row, sib, key = await _mk_cross_scene(world, siblings, "1.txt",
                                                size=len(b"takeover-payload"),
                                                seed_holder=False)
    bucket = world.project.minio_bucket
    content = b"takeover-payload"
    mock_baidu.add(row.fs_id, content)
    state: dict[str, Any] = {"calls": 0, "upload_id": None}

    async def _inject(canonical: str) -> None:
        await _mk_holder_asset(world, sib.folder, bucket, canonical,
                               "late_holder.txt", b"late-cross")

    _script_holders(monkeypatch, row_id=row.id, inject_at=2, crash_at=3,
                    inject=_inject, state=state)

    res = await _dispatch_claim_run(task.id)
    assert res["status"] == "error", f"注入崩溃须沿 job 边界上抛: {res}"

    # 崩溃后落库态:reserved_key 已固化、断点四元组已清、last_error 已清
    frow = await _get_file(row.id)
    assert frow.status == "importing"
    reserved = str(frow.reserved_key)
    assert reserved and reserved != key
    _assert_reserved_shape(reserved, f"{world.folder.minio_prefix.rstrip('/')}/", "1", "txt")
    assert frow.minio_bucket is None and frow.minio_key is None \
        and frow.minio_upload_id is None and frow.bytes_done == 0, \
        "守卫 UPDATE 必须同事务清断点四元组(防新 key 配旧 upload_id)"
    assert frow.last_error is None
    assert state["upload_id"], "前置:崩溃前存在在途会话"
    assert _list_parts_sync(bucket, key, state["upload_id"]) is None, \
        "重启机制 abort 先行:旧会话已随崩溃前作废"

    # sweeper 接管:租约过期派发(seq+1,importing 复位 pending)→ 新 runner 拾取
    await _touch_task(task.id, lease_until=datetime.now(UTC) - timedelta(seconds=1),
                      dispatched_at=datetime.now(UTC) - timedelta(minutes=11))
    stats = await _sweep_now()
    assert stats["dispatched"] >= 1
    frow = await _get_file(row.id)
    assert frow.status == "pending" and str(frow.reserved_key) == reserved, \
        "接管派发复位在途行,reserved_key 原样保留"

    res = await _claim_and_run(task.id)
    assert res["status"] == "completed"

    t = await _get_task(task.id)
    assert t.status == "completed"
    frow = await _get_file(row.id)
    assert frow.status == "success" and frow.asset_id is not None
    async with _db() as db:
        asset = await db.get(Asset, frow.asset_id)
    assert asset is not None and asset.minio_key == reserved, \
        "接管后按 reserved_key 落库"
    assert str((await _get_file(row.id)).reserved_key) == reserved
    assert len(await _assets_with_key(bucket, reserved)) == 1, "恰一次落库(无双落)"
    # canonical 上恰为接管前注入的 late holder 对象(10 字节)—— 任务内容
    # (16 字节)若有残留即长度不符;「无孤儿」由旧会话 abort + 长度核对共同承载
    head_old = await _head(bucket, key)
    assert head_old is not None and head_old["ContentLength"] == len(b"late-cross"), \
        "canonical 上恰为注入的 late holder 对象,任务内容无残留"
    head = await _head(bucket, reserved)
    assert head is not None and head["ContentLength"] == len(content)
