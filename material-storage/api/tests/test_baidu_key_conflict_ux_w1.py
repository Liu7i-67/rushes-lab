"""百度备份 key 冲突体验优化 W1 —— 创建时跨项目路径预警(非阻塞)— API 层。

对应需求文档(唯一依据):docs/qdev/2026-10-20-baidu-key-conflict-ux.md
权威方案:rushes-spec/material-storage/baidu-key-conflict-ux-plan.md §1「测试功能点」
(W1-T1 / W1-T2)。本文件承接 W1-T1(API 层);W1-T2 为前端 warning toast
(BaiduNewTaskModal.tsx 组件测试或手测清单,方案钦定口径,不在本 pytest 范围 ——
映射表尾注)。
【集成】用例须跑容器栈(真实 PG/Redis/MinIO + OpenFGA),门控与
tests/test_baidu_integration.py 同款:任一栈不可达 → 整模块 skip。
运行方式:`docker exec ms-api pytest tests/test_baidu_key_conflict_ux_w1.py -v`。

脚手架全量复用 tests/test_baidu_integration.py(world/client/stack fixture 与
helper;fixture 按「被装饰函数对象」解析,跨模块同名导入即同一 fixture,
session 级 stack/client 同进程共享,不重复建 app)。本文件仅新增「同源第二项目」
工厂:org 复用 world.org,另一 project + 指定前缀根夹(4da4b1c1 实战形态:
两项目同名承接夹 minio_prefix 逐字相同),支持直定 deleted_at/is_archived
(预警查询不过滤口径的造数面),收尾自清理(先于 world 清理执行)。

断言契约:创建响应的 `cross_project_prefix_overlap` / `overlap_project_names`
两字段为 additive 契约(方案 §1 改动点 2);后端实现已在本 worktree 落地
(routers/baidu_backup.py 目标解析后查询 + 对 outs[0] 后赋值,models 两字段带
默认值),本文件按落地实现断言。

测试函数 → 方案 §1「测试功能点」映射(PM 验收对照):
  W1-T1 跨项目同名承接夹(auto-create 分支)→ overlap=true、names 含对方项目名
        (只断言包含,不断言顺序 —— LIMIT 3 无 ORDER BY);详情侧不回填保持默认
        (W1-F3 口径顺带钉死)   → test_w1_t1_cross_project_same_prefix_overlap_true
  W1-T1 显式 target_folder_id 分支(prefix 取自 folder.minio_prefix,与
        auto-create 来源不同)+ rtrim 归一(裸前缀/带斜杠同形互命中)+
        不过滤软删/归档项目         → test_w1_t1_explicit_target_rtrim_and_soft_deleted_project
  W1-T1 同项目同名不置位(同项目裸形等值前缀夹 —— 若查询漏 project_id 过滤
        会自命中;嵌套同名全前缀不等亦不置位)
                                        → test_w1_t1_same_project_and_nested_no_overlap
  W1-T1 无冲突 → false/null(列表/详情均默认值)
                                        → test_w1_t1_no_conflict_false_and_null
  W1-T1 LIMIT 3:4 个同名项目命中 → names ≤3 且 ⊆ seed 集合(无序不过断)
                                        → test_w1_t1_overlap_names_capped_at_three
  W1-T2 前端 toast —— BaiduNewTaskModal.tsx 组件测试或手测清单,方案 §1 注记,
        不落本 pytest 文件(web 侧无 pytest 基建)。
"""
from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import Any

import pytest
from sqlalchemy import select

from app.db.tables import Asset, Folder, Project
from app.services.permissions import PermissionsService
from app.settings import get_settings
from tests import test_baidu_integration as it
from tests.test_baidu_integration import (  # 纯 helper 复用(与用例形参无同名冲突)
    BA,
    World,
    _db,
    _h,
)

# fixture 再输出(赋值形态:from-import 直引会与用例签名同名形参撞 ruff F811,
# 赋值绑定不触发;解析按函数对象身份,与 test_baidu_integration 内定义即同一 fixture)
client = it.client
enable_baidu = it.enable_baidu
mock_oauth = it.mock_oauth
stack = it.stack
world = it.world


# ─── 同源第二项目工厂(4da4b1c1 形态:另一项目 + 同前缀承接夹)──────────────────
class SiblingProjectFactory:
    """在 world.org 下建「另一项目 + 指定 minio_prefix 根夹」,收尾自清理。

    - prefix 逐字直存(允许裸形无尾斜杠 —— rtrim 归一口径的造数面;
      uq_folder_project_prefix 按 (project_id, 原值) 唯一,跨项目/裸形均不撞);
    - deleted/archived 直定:预警查询**不过滤** is_archived/deleted_at(方案 §1
      改动点 1 —— 项目逻辑删除后物理 key 占用仍在,过滤会让预警失效);
    - W1 无资产写入,清理按 project 行删除即可(folders FK CASCADE;仍按资产
      在先的保守序,防后续形态复用踩 RESTRICT)。
    """

    def __init__(self, w: World) -> None:
        self.w = w
        self.projects: list[Project] = []

    async def add(self, *, prefix: str, deleted: bool = False,
                  archived: bool = False) -> Project:
        tag = uuid.uuid4().hex[:8]
        async with _db() as db:
            p = Project(
                organization_id=self.w.org.id,
                code=f"itbkx_{tag}",
                name=f"it-bkx-sibling-{tag}",
                minio_bucket=f"it-bkx-{tag}",   # W1 不落对象,桶名仅占位
                visibility="private",
                is_archived=archived,
                deleted_at=datetime.now(UTC) if deleted else None,
            )
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
        pids = [p.id for p in self.projects]
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
    """同源第二项目工厂(依赖 world;teardown 先于 world 清理)。"""
    factory = SiblingProjectFactory(world)
    yield factory
    await factory.cleanup()


async def _create_task(world: World, client: Any, *, source_dir: str,
                       target_folder_id: str | None = None) -> Any:
    """以 world.member 创建任务(member:project uploader + world.folder
    explicit_uploader,两分支权限均就位),返回响应 JSON。"""
    payload: dict[str, Any] = {"source_dir": source_dir,
                               "project_id": str(world.project.id)}
    if target_folder_id is not None:
        payload["target_folder_id"] = target_folder_id
    r = await client.post(f"{BA}/tasks", json=payload, headers=_h(world.member.id))
    assert r.status_code == 201, r.text
    return r.json()


async def _grant_folder_uploader(folder_id: uuid.UUID, project_id: uuid.UUID,
                                 user_id: uuid.UUID) -> None:
    """自建目标夹的用例前提(world.folder 同款双保险):folder parent tuple +
    explicit_uploader 授权。"""
    perms = PermissionsService(get_settings())
    try:
        await perms.bootstrap_folder(folder_id=str(folder_id), parent_type="project",
                                     parent_id=str(project_id))
        await perms.grant_folder_explicit_subject(
            folder_id=str(folder_id), subject=f"user:{user_id}", kind="explicit_uploader",
        )
    finally:
        await perms.close()


# ─── W1-T1:跨项目同名承接夹(auto-create 分支)→ overlap=true + 对方项目名 ────
async def test_w1_t1_cross_project_same_prefix_overlap_true(
    world: World, client, enable_baidu, mock_oauth, siblings: SiblingProjectFactory, stack,
) -> None:
    """对方项目已有同前缀根夹 → POST /backup/tasks(auto-create 承接夹分支)
    响应 cross_project_prefix_overlap=true 且 overlap_project_names 含对方
    **项目名**(方案 §1:取回的是项目名,勿把夹名当项目名;只断言包含,不断言
    顺序 —— LIMIT 3 无 ORDER BY)。非阻塞:201 照常。【集成】W1-T1"""
    sib = await siblings.add(prefix="dup-root/")
    body = await _create_task(world, client, source_dir="/dup-root")

    assert body["status"] == "enumerating", "预警非阻塞:创建照常入队(§1 改动点 3)"
    assert body["cross_project_prefix_overlap"] is True, \
        f"跨项目同前缀必须置位: {body.get('cross_project_prefix_overlap')!r}"
    names = body["overlap_project_names"]
    assert names, "命中时 overlap_project_names 不得为 null"
    assert sib.name in names, f"names 须含对方项目名(非夹名): {names!r} vs {sib.name!r}"

    # W1-F3:列表/详情侧不回填(后置),保持默认值 —— 创建时刻的 overlap 只在
    # 创建响应上(handler 对 outs[0] 后赋值),详情从持久化行派生恒默认
    d = await client.get(f"{BA}/tasks/{body['id']}", headers=_h(world.member.id))
    assert d.status_code == 200, d.text
    dbody = d.json()
    assert dbody["cross_project_prefix_overlap"] is False, "详情侧不回填(默认 false)"
    assert dbody["overlap_project_names"] is None, "详情侧不回填(默认 null)"


# ─── W1-T1:显式 target 分支 + rtrim 归一 + 不过滤软删/归档项目 ────────────────
async def test_w1_t1_explicit_target_rtrim_and_soft_deleted_project(
    world: World, client, enable_baidu, mock_oauth, siblings: SiblingProjectFactory, stack,
) -> None:
    """显式 target_folder_id 目标同样覆盖(prefix 取自 folder.minio_prefix,与
    auto-create 分支来源不同);rtrim('/') 归一:对方裸前缀 `target-root` 与本方
    `target-root/` 逐字不等也须命中(裸等值比较会漏报的形态);软删+归档项目
    不过滤(逻辑删除后物理 key 占用仍在)。【集成】W1-T1"""
    live = await siblings.add(prefix="target-root")                        # 裸形(无尾斜杠)
    gone = await siblings.add(prefix="target-root/", deleted=True, archived=True)
    body = await _create_task(world, client, source_dir="/whatever",
                              target_folder_id=str(world.folder.id))

    assert body["cross_project_prefix_overlap"] is True, \
        "显式目标 + rtrim 归一必须命中(裸前缀 vs 带斜杠)"
    names = body["overlap_project_names"] or []
    assert live.name in names, f"活跃对方项目须在列: {names!r}"
    assert gone.name in names, f"软删/归档项目不过滤,仍须在列: {names!r}"


# ─── W1-T1:同项目同名不置位(含裸形等值前缀夹);嵌套同名不置位 ─────────────────
async def test_w1_t1_same_project_and_nested_no_overlap(
    world: World, client, enable_baidu, mock_oauth, siblings: SiblingProjectFactory, stack,
) -> None:
    """判据是跨项目(f.project_id != this_project):同项目存在 rtrim 等形前缀夹
    (裸形绕开 uq_folder_project_prefix 的直插形态)不置位 —— 若查询漏掉项目
    过滤,该行会让 target-root 任务自命中;嵌套同名(本方 `target-root/nest/` vs
    对方根夹 `nest/`)全前缀逐字不等,亦不置位。【集成】W1-T1"""
    # 同项目裸形等值前缀夹(仅 DB 行,不选作目标)
    async with _db() as db:
        db.add(Folder(project_id=world.project.id, name="target-root-raw",
                      minio_prefix="target-root"))
        await db.commit()
    body = await _create_task(world, client, source_dir="/whatever",
                              target_folder_id=str(world.folder.id))
    assert body["cross_project_prefix_overlap"] is False, \
        "同项目等形前缀不得置位(查询必须过滤本项目)"
    assert body["overlap_project_names"] is None

    # 嵌套同名:对方项目根夹 nest/ vs 本方嵌套子夹 target-root/nest/ —— 全前缀不等
    sib = await siblings.add(prefix="nest/")
    async with _db() as db:
        child = Folder(project_id=world.project.id, parent_folder_id=world.folder.id,
                       name="nest", minio_prefix="target-root/nest/")
        db.add(child)
        await db.commit()
        await db.refresh(child)
        child_id = child.id
        db.expunge_all()
    await _grant_folder_uploader(child_id, world.project.id, world.member.id)
    body2 = await _create_task(world, client, source_dir="/nested-case",
                               target_folder_id=str(child_id))
    assert body2["cross_project_prefix_overlap"] is False, \
        "嵌套同名(全前缀不等)不置位: 预警按全前缀逐字比较,不按末段夹名"
    assert body2["overlap_project_names"] is None, \
        f"对方项目 {sib.name} 前缀不等,不得入列"


# ─── W1-T1:无冲突 → false / null ─────────────────────────────────────────────
async def test_w1_t1_no_conflict_false_and_null(
    world: World, client, enable_baidu, mock_oauth, stack,
) -> None:
    """无任何跨项目同前缀 → 两字段默认值 false / null(创建与详情一致)。【集成】W1-T1"""
    body = await _create_task(world, client, source_dir=f"/solo-{uuid.uuid4().hex[:8]}")
    assert body["cross_project_prefix_overlap"] is False
    assert body["overlap_project_names"] is None
    d = await client.get(f"{BA}/tasks/{body['id']}", headers=_h(world.member.id))
    assert d.status_code == 200
    dbody = d.json()
    assert dbody["cross_project_prefix_overlap"] is False
    assert dbody["overlap_project_names"] is None


# ─── W1-T1:LIMIT 3 —— 命中项目数超 3 时 names 截断为至多 3 个 ─────────────────
async def test_w1_t1_overlap_names_capped_at_three(
    world: World, client, enable_baidu, mock_oauth, siblings: SiblingProjectFactory, stack,
) -> None:
    """4 个对方项目同前缀 → overlap=true 且 names ≤3(LIMIT 3,无 ORDER BY ——
    只断言长度上限与集合包含,不断言具体是哪 3 个/顺序)。【集成】W1-T1"""
    seeded = [await siblings.add(prefix="cap-root/") for _ in range(4)]
    expect = {p.name for p in seeded}
    body = await _create_task(world, client, source_dir="/cap-root")

    assert body["cross_project_prefix_overlap"] is True
    names = body["overlap_project_names"]
    assert names is not None and len(names) <= 3, \
        f"LIMIT 3:names 至多 3 个: {names!r}"
    assert set(names) <= expect, f"names 必须来自 seed 的项目名集合: {names!r}"


# W1-T2(前端 warning toast):BaiduNewTaskModal.tsx 组件测试或手测清单承接,
# 方案 §1「测试功能点」注记口径;web 侧无 pytest 基建,不落本文件。
