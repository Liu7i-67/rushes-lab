"""百度备份任务【创建同名文件夹】开关 — DB 容器集成层(需求 §5 工作包 E)。

对应需求文档(唯一依据):docs/qdev/2026-11-18-baidu-backup-same-name-folder.md,
本文件承接其 §10 测试功能点 1-12(13 归 tests/test_db_schema.py 列断言、14 归迁移
downgrade 可逆用例,均不在本文件)。【集成】用例须跑容器栈(真实 PG/Redis/MinIO +
OpenFGA),门控与 tests/test_baidu_integration.py 同款:任一栈不可达 → 整模块 skip。
运行方式:`docker exec ms-api pytest tests/test_baidu_same_name_folder.py -v`。

脚手架全量复用 tests/test_baidu_integration.py(world/client/enable_baidu/mock_baidu/
mock_oauth/stack fixture 与 _mk_task/_mk_file/_dispatch_claim_run 等 helper;跨文件
import 复用先例 tests/test_baidu_folder_browse.py)。开关位按契约属性名
create_same_name_folder 直注:worker 侧用例经 _mk_task(**overrides) 落任务行,
路由侧用例走 POST /backup/tasks 请求体。「同源第二项目」工厂(W1 前缀造数面)仿
tests/test_baidu_key_conflict_ux_w1.py 收窄形态,收尾自清理。

admin 出参(§10-8)不走路由:admin 三端点受 require_system_admin 守门(默认 org 的
organization#admin,seed 数据语义,不在 world 世界内),故直呼
app.routers.admin._serialize_admin_baidu_tasks 拍回传契约;AdminBaiduTaskDetailOut
继承 AdminBaiduTaskOut,详情序列化同列覆盖。

测试函数 → 需求 §10「测试功能点」映射(PM 验收对照):
  1. 开关关 + 显式 B → 文件落 B(回归,现状不变)
                                        → test_s1_switch_off_explicit_b_lands_flat
  2. 开关开 + 显式 B → 落 B/<末段>;子目录链保留 B/<末段>/<子目录链>/文件(F2)
                                → test_s2_switch_on_lands_b_leaf_with_subdir_chain
  3. 开关开 + B 下已有同名非敏感夹 → 复用既有夹,不新建(F3)
                                        → test_s3_reuses_existing_same_name_folder
  4. 开关开 + 项目根模式 → 归一 false,落 项目/<末段> 承接夹(F4)
                                        → test_s4_root_mode_normalizes_false
  5. 开关开 + 末段名 >255 → 400(开关关不校验 = 现状不变)(F5)
                                → test_s5_leaf_over_255_400_only_when_switch_on
  6. 开关开 + B 下同名夹 sensitive → 400 文案不含「敏感」;非敏感同名不拦(F5/F3)
                                → test_s6_sensitive_same_name_child_400_no_wording_leak
  7. 开关开 + B sensitive/祖先 sensitive → 既有 403 回归不变
                                → test_s7_sensitive_target_regression_with_switch_on
  8. 任务出参回传布尔:用户侧创建响应/详情/列表 + admin 序列化(F6)
                                → test_s8_task_out_echoes_boolean_user_and_admin
  9. files target_path:未落位行回退 task_base 插末段段;已落位行真实 prefix(F7)
                                → test_s9_files_target_path_leaf_insertion_rules
  10. W1 重叠判定按 B/<末段> 前缀(裸 B 前缀不误报)(F8)
                                        → test_s10_w1_overlap_by_b_leaf_prefix
  11. 行复位重导(单文件 retry)仍落 B/<末段>(F9)
                                        → test_s11_row_retry_rerun_still_lands_b_leaf
  12. 开关开 + B 被删(FK SET NULL)→ 行 failed('target_deleted')回归不变
                                → test_s12_target_deleted_set_null_row_failed
"""
from __future__ import annotations

import uuid
from typing import Any

import pytest
from sqlalchemy import delete, select

from app.db.tables import Asset, Folder, Project
from app.routers.admin import _serialize_admin_baidu_tasks
from app.services.baidu_client import CATEGORY_RATE_LIMITED, BaiduApiError
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
    _mk_file,
    _mk_task,
    _seed_listing,
    _zero_backoff,
    random_fsid,
)

# fixture 再输出(赋值形态:from-import 直引会与用例签名同名形参撞 ruff F811,
# 赋值绑定不触发;解析按函数对象身份,与 test_baidu_integration 内定义即同一 fixture)
client = it.client
enable_baidu = it.enable_baidu
mock_baidu = it.mock_baidu
mock_oauth = it.mock_oauth
stack = it.stack
world = it.world


# ─── 本文件专用 helper(夹/资产断言 + B 子夹造数 + 建任务请求)──────────────────
async def _folder_by_prefix(project_id: uuid.UUID, prefix: str) -> Folder | None:
    """项目内按 minio_prefix 查夹(落点链断言用;expunge 防跨会话 DetachedError)。"""
    async with _db() as db:
        f = (await db.execute(select(Folder).where(
            Folder.project_id == project_id, Folder.minio_prefix == prefix,
        ))).scalar_one_or_none()
        if f is not None:
            db.expunge(f)
        return f


async def _folder_ids_named(project_id: uuid.UUID, parent_id: uuid.UUID | None,
                            name: str) -> list[uuid.UUID]:
    """指定父夹(None=项目根)下同名子夹 id 列表(复用断言:恰 1 条 = 不新建)。"""
    parent_cond = (Folder.parent_folder_id.is_(None) if parent_id is None
                   else Folder.parent_folder_id == parent_id)
    async with _db() as db:
        rows = await db.execute(select(Folder.id).where(
            Folder.project_id == project_id, parent_cond, Folder.name == name,
        ))
        return list(rows.scalars().all())


async def _asset_key_exists(bucket: str, key: str) -> bool:
    """资产 key 是否已落库(物理落点旁证,行级 target_folder_id 之外的硬证据)。"""
    async with _db() as db:
        a = (await db.execute(select(Asset.id).where(
            Asset.minio_bucket == bucket, Asset.minio_key == key,
        ))).scalar_one_or_none()
        return a is not None


async def _add_child_folder(world: World, parent: Folder, name: str, *,
                            sensitive: bool = False) -> Folder:
    """B 的直接子夹(DB 直插,world fixture 造数口径);FGA parent tuple 由
    ensure_folder_chain 的复用/创建分支幂等 ensure,无需手写。"""
    prefix = f"{parent.minio_prefix.rstrip('/')}/{name}/"
    async with _db() as db:
        f = Folder(project_id=world.project.id, parent_folder_id=parent.id,
                   name=name, minio_prefix=prefix, is_sensitive=sensitive)
        db.add(f)
        await db.commit()
        await db.refresh(f)
        db.expunge(f)
        return f


async def _post_create(world: World, client: Any, *, source_dir: str,
                       target_folder_id: str | None = None,
                       create_same_name_folder: bool | None = None) -> Any:
    """world.member 建任务(权限:project uploader + folder explicit_uploader 双保险
    就位);create_same_name_folder=None = 不送字段(F1 默认关)。断言 201 返回 JSON。"""
    payload: dict[str, Any] = {"source_dir": source_dir,
                               "project_id": str(world.project.id)}
    if target_folder_id is not None:
        payload["target_folder_id"] = target_folder_id
    if create_same_name_folder is not None:
        payload["create_same_name_folder"] = create_same_name_folder
    r = await client.post(f"{BA}/tasks", json=payload, headers=_h(world.member.id))
    assert r.status_code == 201, r.text
    return r.json()


# ─── 同源第二项目工厂(W1 前缀造数面;仿 tests/test_baidu_key_conflict_ux_w1.py 收窄)
class SiblingProjects:
    """world.org 下建「另一项目 + 指定 minio_prefix 根夹」(跨项目承接夹前缀逐字
    相同的实战形态),收尾自清理(W1 只比对前缀行,无资产/任务写入)。"""

    def __init__(self, w: World) -> None:
        self.w = w
        self.projects: list[Project] = []

    async def add(self, prefix: str) -> Project:
        tag = uuid.uuid4().hex[:8]
        async with _db() as db:
            p = Project(organization_id=self.w.org.id, code=f"itsnf_{tag}",
                        name=f"it-snf-sibling-{tag}", minio_bucket=f"it-snf-{tag}",
                        visibility="private")
            db.add(p)
            await db.flush()
            db.add(Folder(project_id=p.id, name=prefix.rstrip("/") or tag,
                          minio_prefix=prefix))
            await db.commit()
            await db.refresh(p)
            db.expunge(p)
        self.projects.append(p)
        return p

    async def cleanup(self) -> None:
        if not self.projects:
            return
        async with _db() as db:
            await db.execute(delete(Project).where(
                Project.id.in_([p.id for p in self.projects])))
            await db.commit()


@pytest.fixture
async def siblings(world: World):
    """同源第二项目工厂(teardown 先于 world 清理;folders 随 project 行 CASCADE)。"""
    factory = SiblingProjects(world)
    yield factory
    await factory.cleanup()


# ─── §10-1:开关关 + 显式 B → 文件落 B(回归,现状不变)─────────────────────────
async def test_s1_switch_off_explicit_b_lands_flat(
    world: World, mock_baidu, stack,
) -> None:
    """开关关(默认,不送字段)= 现状逐字节不变:文件平铺落 B,不得冒出同名夹。【集成】§10-1"""
    task = await _mk_task(world, status="running", source_dir="/leafy")
    fs = random_fsid()
    mock_baidu.add(fs, b"flat-bytes")
    row = await _mk_file(task, "top.mp4", size=10, fs_id=fs)

    await _dispatch_claim_run(task.id)

    row = await _get_file(row.id)
    assert row.status == "success" and row.target_folder_id == world.folder.id
    bucket = world.project.minio_bucket
    assert await _asset_key_exists(bucket, "target-root/top.mp4"), "现状落点 = B 根平铺"
    assert await _folder_by_prefix(world.project.id, "target-root/leafy/") is None, \
        "开关关不得建出同名夹(现状不变)"


# ─── §10-2:开关开 + 显式 B → 落 B/<末段>;子目录链保留(F2)─────────────────────
async def test_s2_switch_on_lands_b_leaf_with_subdir_chain(
    world: World, mock_baidu, stack,
) -> None:
    """开关开 + 显式 B:平铺文件落 B/<末段>/,带子目录的行落 B/<末段>/<子目录链>/,
    行级 target_folder_id 写回真实落位夹;B 根不得再有平铺产物。【集成】§10-2"""
    task = await _mk_task(world, status="running", source_dir="/leafy",
                          create_same_name_folder=True)
    fs_top, fs_sub = random_fsid(), random_fsid()
    mock_baidu.add(fs_top, b"top-bytes")
    mock_baidu.add(fs_sub, b"nested-bytes")
    row_top = await _mk_file(task, "top.mp4", size=9, fs_id=fs_top)
    row_sub = await _mk_file(task, "sub/nested.mp4", size=len(b"nested-bytes"), fs_id=fs_sub)

    await _dispatch_claim_run(task.id)

    leafy = await _folder_by_prefix(world.project.id, "target-root/leafy/")
    assert leafy is not None and leafy.parent_folder_id == world.folder.id, "落点链 B/<末段>"
    sub = await _folder_by_prefix(world.project.id, "target-root/leafy/sub/")
    assert sub is not None and sub.parent_folder_id == leafy.id, "网盘子目录链保留"
    row_top, row_sub = await _get_file(row_top.id), await _get_file(row_sub.id)
    assert row_top.status == "success" and row_top.target_folder_id == leafy.id
    assert row_sub.status == "success" and row_sub.target_folder_id == sub.id
    bucket = world.project.minio_bucket
    assert await _asset_key_exists(bucket, "target-root/leafy/top.mp4")
    assert await _asset_key_exists(bucket, "target-root/leafy/sub/nested.mp4")
    assert not await _asset_key_exists(bucket, "target-root/top.mp4"), "B 根不得平铺"


# ─── §10-3:开关开 + B 下已有同名非敏感夹 → 复用既有夹,不新建(F3)──────────────
async def test_s3_reuses_existing_same_name_folder(
    world: World, mock_baidu, stack,
) -> None:
    """B 下已存在同名夹(非敏感)→ ensure_folder_chain 复用语义:不报错不新建,
    行落既有夹 id,资产继续导入同一处。【集成】§10-3"""
    existing = await _add_child_folder(world, world.folder, "leafy")
    task = await _mk_task(world, status="running", source_dir="/leafy",
                          create_same_name_folder=True)
    fs = random_fsid()
    mock_baidu.add(fs, b"reuse-bytes")
    row = await _mk_file(task, "top.mp4", size=11, fs_id=fs)

    await _dispatch_claim_run(task.id)

    ids = await _folder_ids_named(world.project.id, world.folder.id, "leafy")
    assert ids == [existing.id], "同名夹复用不新建(恰 1 条且为既有 id)"
    row = await _get_file(row.id)
    assert row.status == "success" and row.target_folder_id == existing.id, "行落既有夹"
    assert await _asset_key_exists(world.project.minio_bucket,
                                   "target-root/leafy/top.mp4")


# ─── §10-4:开关开 + 项目根模式 → 静默归一 false,落 项目/<末段> 承接夹(F4)───────
async def test_s4_root_mode_normalizes_false(
    world: World, client, enable_baidu, mock_baidu, mock_oauth, stack,
) -> None:
    """target_folder_id 不传 + 开关开 → 后端静默归一 false(不报错),行为与现状
    完全一致:承接夹名 = source 末段,不与同名夹语义叠加。【集成】§10-4"""
    _seed_listing(mock_baidu, "/leafy", {"top.mp4": b"root-mode-bytes"})
    body = await _post_create(world, client, source_dir="/leafy",
                              create_same_name_folder=True)
    assert body["create_same_name_folder"] is False, "F4:项目根模式必须归一 false"
    assert body["target_auto_created"] is True, "项目根模式 = 自动承接夹分支"
    task_id = uuid.UUID(body["id"])

    await _claim_and_run(task_id)

    holder_ids = await _folder_ids_named(world.project.id, None, "leafy")
    assert len(holder_ids) == 1, "承接夹(项目根级,名=末段)恰 1 条"
    t = await _get_task(task_id)
    assert t.target_folder_id == holder_ids[0], "落 项目/<末段> 承接夹"
    assert await _asset_key_exists(world.project.minio_bucket, "leafy/top.mp4")


# ─── §10-5:开关开 + 末段名 >255 → 400;开关关不校验(现状不变)(F5)──────────────
async def test_s5_leaf_over_255_400_only_when_switch_on(
    world: World, client, enable_baidu, mock_oauth, stack,
) -> None:
    """开关开 + 显式 B:末段名 >255 无法作为 B 的子夹名 → 400「网盘目录名过长」;
    开关关 + 显式 B 维持现状(显式 target 分支无承接夹名守卫,照常 201)。【集成】§10-5"""
    long_src = "/dir/" + "长" * 256
    r_on = await client.post(f"{BA}/tasks", json={
        "source_dir": long_src, "project_id": str(world.project.id),
        "target_folder_id": str(world.folder.id), "create_same_name_folder": True,
    }, headers=_h(world.member.id))
    assert r_on.status_code == 400, r_on.text
    assert "网盘目录名过长" in r_on.text, "错误文案与 auto 分支同口径"

    r_off = await client.post(f"{BA}/tasks", json={
        "source_dir": long_src, "project_id": str(world.project.id),
        "target_folder_id": str(world.folder.id),
    }, headers=_h(world.member.id))
    assert r_off.status_code == 201, f"开关关不校验名字(现状不变): {r_off.text}"


# ─── §10-6:开关开 + B 下同名夹 sensitive → 400 文案不含「敏感」;非敏感不拦 ──────
async def test_s6_sensitive_same_name_child_400_no_wording_leak(
    world: World, client, enable_baidu, mock_oauth, stack,
) -> None:
    """B 直接子夹已有同名敏感夹 → 400「目标文件夹名不可用,请改名或另选目标」,
    文案不含「敏感」(防探测,与 auto 分支同口径);非敏感同名夹不拦(F3 创建面)。【集成】§10-6"""
    await _add_child_folder(world, world.folder, "plain")
    await _add_child_folder(world, world.folder, "vault", sensitive=True)

    r_plain = await _post_create(world, client, source_dir="/plain",
                                 target_folder_id=str(world.folder.id),
                                 create_same_name_folder=True)
    assert r_plain["create_same_name_folder"] is True, "非敏感同名夹不拦(F3)"

    r = await client.post(f"{BA}/tasks", json={
        "source_dir": "/vault", "project_id": str(world.project.id),
        "target_folder_id": str(world.folder.id), "create_same_name_folder": True,
    }, headers=_h(world.member.id))
    assert r.status_code == 400, r.text
    assert "目标文件夹名不可用" in r.text, "错误码口径与 auto 分支一致"
    assert "敏感" not in r.text, "错误文案不得泄露 sensitive 字样"


# ─── §10-7:开关开 + B sensitive/祖先 sensitive → 既有 403 回归不变 ─────────────
async def test_s7_sensitive_target_regression_with_switch_on(
    world: World, client, enable_baidu, mock_oauth, stack,
) -> None:
    """开关不得改变敏感目标链的既有快败:显式选 sensitive 夹 → 403;挂在 sensitive
    下的子夹(沿 parent 链核查)→ 403;均落 access_denied 审计。【集成】§10-7"""
    r_b = await client.post(f"{BA}/tasks", json={
        "source_dir": "/any", "project_id": str(world.project.id),
        "target_folder_id": str(world.sensitive.id), "create_same_name_folder": True,
    }, headers=_h(world.member.id))
    assert r_b.status_code == 403, r_b.text
    assert "敏感" not in r_b.text

    inner = await _add_child_folder(world, world.sensitive, "inner")
    r_a = await client.post(f"{BA}/tasks", json={
        "source_dir": "/any2", "project_id": str(world.project.id),
        "target_folder_id": str(inner.id), "create_same_name_folder": True,
    }, headers=_h(world.member.id))
    assert r_a.status_code == 403, f"敏感祖先链核查在创建期快败: {r_a.text}"
    assert await _audit_count("access_denied", actor_user_id=world.member.id) >= 2


# ─── §10-8:任务出参回传布尔(用户侧创建/详情/列表 + admin 序列化)(F6)───────────
async def test_s8_task_out_echoes_boolean_user_and_admin(
    world: World, client, enable_baidu, mock_oauth, stack,
) -> None:
    """BaiduTaskOut/AdminBaiduTaskOut 回传归一后的生效值:用户侧创建响应/详情/列表
    一致;admin 侧直拍序列化器(admin 路由守门在 world 世界外,见文件头)。【集成】§10-8"""
    body = await _post_create(world, client, source_dir="/leafy",
                              target_folder_id=str(world.folder.id),
                              create_same_name_folder=True)
    assert body["create_same_name_folder"] is True, "开启 + 显式 B → true"
    d = await client.get(f"{BA}/tasks/{body['id']}", headers=_h(world.member.id))
    assert d.status_code == 200 and d.json()["create_same_name_folder"] is True, "详情回传"
    lst = await client.get(f"{BA}/tasks", headers=_h(world.member.id))
    item = next(i for i in lst.json()["items"] if i["id"] == body["id"])
    assert item["create_same_name_folder"] is True, "列表条目回传"

    body_off = await _post_create(world, client, source_dir="/plain",
                                  target_folder_id=str(world.folder.id))
    assert body_off["create_same_name_folder"] is False, "F1:缺省 = false(现状不变)"

    t_on = await _mk_task(world, status="completed", source_dir="/leafy",
                          create_same_name_folder=True)
    t_off = await _mk_task(world, status="completed", source_dir="/off")
    async with _db() as db:
        outs = await _serialize_admin_baidu_tasks(db, [t_on, t_off])
    assert [o.create_same_name_folder for o in outs] == [True, False], \
        "admin 列表/详情(继承 AdminBaiduTaskOut)回传行值"


# ─── §10-9:files target_path —— 未落位行插末段段,已落位行真实 prefix(F7)──────
async def test_s9_files_target_path_leaf_insertion_rules(
    world: World, mock_baidu, client, enable_baidu, stack,
) -> None:
    """开关开任务:已落位行 target_path = 行级真实 prefix(天然恰含一次末段);
    未落位行回退 task_base 时插末段段(<task_base>/<末段>/<rel_path>);开关关
    任务的回退路径无末段段(条件性插入钉死)。【集成】§10-9"""
    task = await _mk_task(world, status="running", source_dir="/leafy",
                          create_same_name_folder=True)
    fs = random_fsid()
    mock_baidu.add(fs, b"path-bytes")
    await _mk_file(task, "ok.mp4", size=10, fs_id=fs)
    await _dispatch_claim_run(task.id)
    await _mk_file(task, "late.mp4", size=5, status="pending")   # 未落位(folder NULL)

    r = await client.get(f"{BA}/tasks/{task.id}/files", headers=_h(world.member.id))
    assert r.status_code == 200, r.text
    by = {i["rel_path"]: i["target_path"] for i in r.json()["items"]}
    base = world.folder.minio_prefix.rstrip("/")
    assert by["ok.mp4"] == f"{base}/leafy/ok.mp4", "已落位行:真实 prefix 恰含一次末段"
    assert by["late.mp4"] == f"{base}/leafy/late.mp4", "未落位行:task_base + 末段段"

    task_off = await _mk_task(world, status="running", source_dir="/leafy")
    await _mk_file(task_off, "late.mp4", size=5, status="pending")
    r2 = await client.get(f"{BA}/tasks/{task_off.id}/files", headers=_h(world.member.id))
    assert r2.status_code == 200, r2.text
    by2 = {i["rel_path"]: i["target_path"] for i in r2.json()["items"]}
    assert by2["late.mp4"] == f"{base}/late.mp4", "开关关回退路径无末段段(现状不变)"


# ─── §10-10:W1 重叠判定按 B/<末段> 前缀(F8)────────────────────────────────────
async def test_s10_w1_overlap_by_b_leaf_prefix(
    world: World, client, enable_baidu, mock_oauth,
    siblings: SiblingProjects, stack,
) -> None:
    """开关开时 W1 比较前缀取实际落点 B/<末段>:对方项目有 B/<末段> 前缀夹 → 命中;
    仅有裸 B 前缀夹 → 不得按裸前缀误报。【集成】§10-10"""
    hit = await siblings.add(prefix="target-root/leafy/")     # 恰为 B/<末段> → 应命中
    miss = await siblings.add(prefix="target-root/")          # 裸 B 前缀 → 不应命中
    body = await _post_create(world, client, source_dir="/leafy",
                              target_folder_id=str(world.folder.id),
                              create_same_name_folder=True)

    assert body["cross_project_prefix_overlap"] is True, "按实际落点前缀命中"
    names = body["overlap_project_names"] or []
    assert hit.name in names, f"names 须含 B/<末段> 前缀的对方项目: {names!r}"
    assert miss.name not in names, "裸 B 前缀不得误报(比较前缀已含末段段)"


# ─── §10-11:行复位重导(单文件 retry)仍落 B/<末段>(F9)───────────────────────
async def test_s11_row_retry_rerun_still_lands_b_leaf(
    world: World, mock_baidu, client, enable_baidu, monkeypatch, stack,
) -> None:
    """落点由任务行 create_same_name_folder 驱动,无额外状态:行退避耗尽 failed →
    retry 复位重导,新轮建链仍落 B/<末段>(首轮已建的末段夹被复用)。【集成】§10-11"""
    _zero_backoff(monkeypatch)
    content = b"retry-bytes"
    task = await _mk_task(world, status="running", source_dir="/leafy",
                          create_same_name_folder=True)
    fs = random_fsid()
    mock_baidu.add(fs, content)
    mock_baidu.fail_first[fs] = [BaiduApiError(CATEGORY_RATE_LIMITED, "rl", http_status=503)
                                 for _ in range(5)]
    row = await _mk_file(task, "r.mp4", size=len(content), fs_id=fs)

    await _dispatch_claim_run(task.id)
    row = await _get_file(row.id)
    assert row.status == "failed" and "rate_limited" in (row.last_error or "")

    r = await client.post(f"{BA}/tasks/{task.id}/files/{row.id}/retry",
                          headers=_h(world.member.id))
    assert r.status_code == 202, r.text
    mock_baidu.fail_first[fs] = []
    await _claim_and_run(task.id)

    leafy = await _folder_by_prefix(world.project.id, "target-root/leafy/")
    assert leafy is not None, "重导落点仍为 B/<末段>"
    row = await _get_file(row.id)
    assert row.status == "success" and row.target_folder_id == leafy.id
    assert await _asset_key_exists(world.project.minio_bucket,
                                   "target-root/leafy/r.mp4")


# ─── §10-12:开关开 + B 被删(FK SET NULL)→ 行 failed('target_deleted')回归不变 ──
async def test_s12_target_deleted_set_null_row_failed(
    world: World, mock_baidu, stack,
) -> None:
    """显式 B 在途被删(target_folder_id SET NULL)→ 行显式 failed('target_deleted'),
    不得静默换位;开关开启不改变该语义。【集成】§10-12"""
    task = await _mk_task(world, status="running", source_dir="/leafy",
                          create_same_name_folder=True)
    fs = random_fsid()
    mock_baidu.add(fs, b"gone-bytes")
    row = await _mk_file(task, "gone.mp4", size=10, fs_id=fs)

    async with _db() as db:
        await db.execute(delete(Folder).where(Folder.id == world.folder.id))
        await db.commit()
    t = await _get_task(task.id)
    assert t.target_folder_id is None, "前置:FK SET NULL 已生效"

    await _dispatch_claim_run(task.id)

    row = await _get_file(row.id)
    assert row.status == "failed" and "target_deleted" in (row.last_error or ""), \
        "显式目标被删必须显式失败(与 auto 重建不对称属刻意取舍)"
