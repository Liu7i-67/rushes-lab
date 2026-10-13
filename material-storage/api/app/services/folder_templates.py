"""目录模板应用服务 apply_folder_template — 方案 §5-B7(2026-10-10 目录模板)。

把模板条目物化为项目 folders 行(建项目流程内同步执行,位于 initial_grants 与
默认模板直通之后、project_created audit 之前,方案 §1-D3)。

**签名只收纯值**(template_id / template_name / entry_paths,不收 template /
entry ORM 对象):逐条容错的 rollback 会无条件过期 identity_map 中全部持久态
对象(session.py `expire_on_commit=False` 只豁免 commit 不豁免 rollback),
循环与 audit 全程只摸纯值、不持任何同 session 的 ORM 对象;调用侧(projects.
create_project)已先行物化 audit 所需六项 ORM 属性,同款机理(方案 §1-D3/§4.2)。

容错语义(方案 §5-B7 五项细节):
  ① 条目按 path 字典序排序(父路径天然在前);根夹按首段去重,同首段只调一次
     ensure_root_folder_at_project,结果仅在其**正常返回后**入轮内 memo
     (正常返回 = 行 + parent tuple 已就位);首段失败不入 memo,同首段后续
     条目各自重试 ensure(自愈语义)并各自进 failed,不做连坐跳过
  ② 余段用 ensure_folder_chain(根夹为 root,rel_dir_parts=余段),memo 每条目
     **独立新建**——folder_chain 是先写 memo 后补 tuple(folder_chain.py:271-278),
     「失败续跑」语义下跨条目共享会在 folder_tuple_error 后留下「memo 声称就位
     但 tuple 缺失」的脏命中;条目独立 memo 则失败即随本条目作废(百度导入的
     跨轮共享前提是「异常即整轮作废」,与本案语义不同)
  ③ 单条任意异常捕获 → 先 `await db.rollback()` 再记 failed 继续(rollback 必须做:
     session 处于 pending-rollback 态时后续条目连环 PendingRollbackError);
     failed.code:FolderChainError 取其 .code,其余记 "error"
  ④ created_folder_count = 应用前后 `count(folders where project_id=…)` 差值
     (ensure 返回 ChainNode 不区分新建/复用,直接计数会误计;差值 = 实际净增
     夹数,含失败条目已建成的浅层父夹,不含被回滚的未提交写入);**应用执行完毕
     即记一条 audit `folder_template_applied`,无论 failed 是否为空**(全失败也记,
     凭 audit 才能手工补建);批量操作记汇总,不逐夹记 folder_created
  ⑤ 深层条目失败时其已建成的浅层父夹有意保留(逐夹独立 commit,便于手工补建,
     验收时不视为脏数据);若 failed 含 folder_tuple_error,手工补建应**整模板
     重跑**(ensure 幂等),不能只补 failed 路径——tuple 缺失不总在 failed 条目自身
"""
from __future__ import annotations

import uuid
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.tables import Folder
from app.services.audit import AuditService
from app.services.folder_chain import (
    ChainNode,
    FolderChainError,
    ensure_folder_chain,
    ensure_root_folder_at_project,
)
from app.services.permissions import PermissionsService


async def _count_project_folders(db: AsyncSession, project_id: uuid.UUID) -> int:
    count = await db.scalar(
        select(func.count()).select_from(Folder).where(Folder.project_id == project_id)
    )
    return int(count or 0)


async def apply_folder_template(
    db: AsyncSession,
    permissions: PermissionsService,
    audit: AuditService,
    *,
    project_id: uuid.UUID,
    template_id: uuid.UUID,
    template_name: str,
    entry_paths: list[str],
    actor_user_id: uuid.UUID,
    ctx: dict[str, str | None],
) -> dict[str, Any]:
    """把模板条目物化为项目 folders(逐条容错;audit 显式入参,照
    apply_default_template_grants 先例)。

    返回 {"created_folder_count": 净增夹数, "failed": [{path, code}, …]}
    (failed 全量;调用侧并入 project_created details 时自行截前 10 条)。
    """
    before = await _count_project_folders(db, project_id)

    # ① 字典序排序:父路径天然排在前(前缀串 < 更长串),保证建链时父夹先物化
    paths = sorted(entry_paths)

    failed: list[dict[str, str]] = []
    # 根夹轮内 memo:首段 → 根节点(ChainNode 是纯值 dataclass,rollback 无关);
    # 仅在 ensure_root_folder_at_project 正常返回后写入(①)
    root_memo: dict[str, ChainNode] = {}
    for path in paths:
        segments = path.split("/")
        root_name, rest = segments[0], segments[1:]
        try:
            root_node = root_memo.get(root_name)
            if root_node is None:
                # 同首段只调一次 ensure;首段失败不入 memo,同首段后续条目
                # 各自重试(自愈)并各自进 failed,不连坐跳过(①)
                root_node = await ensure_root_folder_at_project(
                    db, permissions, project_id=project_id, name=root_name,
                )
                root_memo[root_name] = root_node
            if rest:
                # ② 余段建链,memo 每条目独立新建(勿跨条目共享,见模块 docstring ②)
                await ensure_folder_chain(
                    db, permissions,
                    project_id=project_id,
                    root_folder_id=root_node.folder_id,
                    rel_dir_parts=list(rest),
                    memo={},
                )
        except Exception as e:
            # ③ 先 rollback 再记 failed 继续:pending-rollback 态下后续条目会连环
            # PendingRollbackError;rollback 会过期 identity_map 全部对象,故全程
            # 只摸纯值(调用侧与函数入口均已物化,方案 §1-D3)
            await db.rollback()
            code = e.code if isinstance(e, FolderChainError) else "error"
            failed.append({"path": path, "code": code})

    after = await _count_project_folders(db, project_id)
    created_folder_count = after - before

    # ④ 无论 failed 是否为空都记一条(全失败也记,凭 audit 才能手工补建);
    # 不逐夹记 folder_created(批量操作记汇总,与百度导入同风格)
    await audit.write(
        event_type="folder_template_applied",
        actor_user_id=actor_user_id,
        target_project_id=project_id,
        details={
            "template_id": str(template_id),
            "template_name": template_name,
            "created_folder_count": created_folder_count,
            "failed": failed,
        },
        request_ip=ctx.get("request_ip"),
        user_agent=ctx.get("user_agent"),
    )
    return {"created_folder_count": created_folder_count, "failed": failed}
