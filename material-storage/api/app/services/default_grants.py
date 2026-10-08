"""默认授权模板直通 helper(方案 §3.1 / §3.2,共享实现勿写两份)。

语义:最终授权 = payload 的 initial_grants(手选模板预填 + 手动行)+ 当前默认
模板 items,按 (kind, id) 合并、角色取并集、幂等 —— 本 helper 只负责「默认模板」
半边(payload 直通写不在这里):

  1. 读 org 的 is_default 模板(无默认 / items 空 → 返回 0/0,create 侧现行为不变);
  2. stale 主体直查 DB 过滤(user 须 is_active、group 须存在,仿 projects
     create_project 的 initial_grants 前置校验;**不得用 resolve_subject_names
     的 found 代替** —— 它不过滤 is_active,停用用户 found=True 会漏拦);
     过期条目跳过 + log,不阻塞(过期默认模板不能卡死建项目);
  3. read 项目现有 tuples(read_all_tuples 翻页聚合)求差集 —— 天然排除 payload
     已写条目与既有授权,重复调用差集为空、零写入;
  4. 批量写:单次 write ≤100 tuple 分块;块撞 is_already_exists_error 时该块
     **降级为逐条写**(批量 write 原子:块内任一 tuple 已存在则整块失败,直接
     整块跳过会丢块内其余合法 tuple),逐条再撞 already_exists 才按幂等跳过
     (同 add_project_member 口径)—— 刷新场景若一律逐条写会是万次级 HTTP 调用;
  5. 逐条 audit project_member_added,details via: "default_template"(手选仍
     initial_grants);幂等跳过不写。

create 侧(projects.create_project 直通写完成后调用)与刷新侧
(admin.apply-default)共用本实现;叠加不删 —— 只补缺失 (subject, role),
不移除任何授权(FGA tuple 无来源标记,对齐式收回必误伤手动授权,方案 §3.2)。
"""
from __future__ import annotations

import logging
import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.tables import Group, ProjectGrantTemplate, ProjectGrantTemplateItem, User
from app.services.audit import AuditService
from app.services.permissions import (
    PermissionsService,
    fmt_subject,
    is_already_exists_error,
)

log = logging.getLogger(__name__)

# 角色固定顺序(与 routers/projects.py 的 PROJECT_ROLES 一致;ProjectRole Literal
# 声明顺序与其不同,勿混用)。不直接 import 以免 services → routers 反向依赖
# (projects.py 反向 import 本模块)。
_ROLE_ORDER: tuple[str, ...] = ("admin", "uploader", "downloader", "viewer")

# 单次 OpenFGA write 的 tuple 上限(方案 §3.1:批量写 ≤100/次分块)
_WRITE_BATCH = 100


async def apply_default_template_grants(
    db: AsyncSession,
    permissions: PermissionsService,
    audit: AuditService,
    *,
    org_id: uuid.UUID,
    project_id: uuid.UUID,
    actor_user_id: uuid.UUID,
    ctx: dict[str, str | None],
) -> dict[str, int]:
    """把 org 默认模板的授权补写到 project(叠加不删、幂等)。

    返回 {"applied": 真正写入的 tuple 数, "skipped_stale": 跳过的过期主体条目数}。
    无默认模板 / items 空 → {"applied": 0, "skipped_stale": 0}。
    异常原样上抛:调用方决定治理方式(create 侧 500 与直通写同治;
    apply-default 侧逐项目捕获计入 results 的 error,继续其余项目)。
    """
    # 1) 读默认模板(同 org 至多 1 个 default,partial unique index 保证)
    res = await db.execute(
        select(ProjectGrantTemplate).where(
            ProjectGrantTemplate.organization_id == org_id,
            ProjectGrantTemplate.is_default.is_(True),
        )
    )
    template = res.scalar_one_or_none()
    if template is None:
        return {"applied": 0, "skipped_stale": 0}
    items_res = await db.execute(
        select(ProjectGrantTemplateItem)
        .where(ProjectGrantTemplateItem.template_id == template.id)
        .order_by(ProjectGrantTemplateItem.created_at, ProjectGrantTemplateItem.id)
    )
    items = list(items_res.scalars().all())
    if not items:
        return {"applied": 0, "skipped_stale": 0}

    # 2) stale 判定直查 DB(user 须 is_active、group 须存在;方案 §3.1 点名
    #    不得用 resolve_subject_names 的 found 代替 —— 它不过滤 is_active)
    item_user_ids = {it.subject_id for it in items if it.subject_kind == "user"}
    item_group_ids = {it.subject_id for it in items if it.subject_kind == "group"}
    active_user_ids: set[uuid.UUID] = set()
    if item_user_ids:
        res_u = await db.execute(
            select(User.id).where(
                User.id.in_(item_user_ids), User.is_active.is_(True),
            )
        )
        active_user_ids = {row[0] for row in res_u.all()}
    existing_group_ids: set[uuid.UUID] = set()
    if item_group_ids:
        res_g = await db.execute(
            select(Group.id).where(Group.id.in_(item_group_ids))
        )
        existing_group_ids = {row[0] for row in res_g.all()}

    skipped_stale = 0
    wanted: list[tuple[str, str, str]] = []   # (subject, role, kind)
    for it in items:
        if it.subject_kind == "user" and it.subject_id not in active_user_ids:
            skipped_stale += 1
            log.warning(
                "default template stale user skipped template=%s user=%s",
                template.id, it.subject_id,
            )
            continue
        if it.subject_kind == "group" and it.subject_id not in existing_group_ids:
            skipped_stale += 1
            log.warning(
                "default template stale group skipped template=%s group=%s",
                template.id, it.subject_id,
            )
            continue
        subject = fmt_subject(it.subject_kind, str(it.subject_id))  # type: ignore[arg-type]
        # 角色去重 + 固定顺序;非法值防御性丢弃(模板列由 API 校验写入,直调 DB 才会有)
        roles = [r for r in _ROLE_ORDER if r in set(it.roles or [])]
        for role in roles:
            wanted.append((subject, role, it.subject_kind))

    if not wanted:
        return {"applied": 0, "skipped_stale": skipped_stale}

    # 3) read 项目现有 tuples(翻页聚合)求差集;object 恒为 project:<pid>,
    #    差集键用 (subject, relation)。org parent tuple 等 (organization:*, org)
    #    不会与 wanted 的四角色撞键,无需特判
    existing: set[tuple[str, str]] = {
        (t_user, t_rel)
        for t_user, t_rel, _t_obj in await permissions.read_all_tuples(
            object_type="project", object_id=str(project_id),
        )
    }
    todo = [(s, r, k) for (s, r, k) in wanted if (s, r) not in existing]
    if not todo:
        return {"applied": 0, "skipped_stale": skipped_stale}

    # 4) 分块批量写 + 块级降级逐条;逐条 audit(仅真正写入的记,幂等跳过不写)
    applied = 0
    for i in range(0, len(todo), _WRITE_BATCH):
        chunk = todo[i : i + _WRITE_BATCH]
        try:
            await permissions.add_project_subjects_bulk(
                project_id=str(project_id),
                tuples=[(s, r) for s, r, _k in chunk],
            )
            applied += len(chunk)
            await _audit_written(audit, project_id, actor_user_id, chunk, ctx)
            continue
        except Exception as e:
            if not is_already_exists_error(e):
                raise
            # 该块撞 already_exists → 整块原子失败,降级为逐条写(丢写防御)
        for subject, role, kind in chunk:
            try:
                await permissions.add_project_subject(
                    project_id=str(project_id), subject=subject, role=role,  # type: ignore[arg-type]
                )
            except Exception as e:
                if not is_already_exists_error(e):
                    raise
                continue  # 逐条再撞 = 真重复,幂等成功跳过、不写 audit
            applied += 1
            await _audit_written(
                audit, project_id, actor_user_id, [(subject, role, kind)], ctx,
            )

    return {"applied": applied, "skipped_stale": skipped_stale}


async def _audit_written(
    audit: AuditService,
    project_id: uuid.UUID,
    actor_user_id: uuid.UUID,
    tuples: list[tuple[str, str, str]],
    ctx: dict[str, str | None],
) -> None:
    """逐条 audit project_member_added,detail 形状与 add_project_member 对齐
    (单角色一条),来源标 via: "default_template"(方案 §3.1)。"""
    for subject, role, kind in tuples:
        await audit.write(
            event_type="project_member_added",
            actor_user_id=actor_user_id,
            target_project_id=project_id,
            details={"subject": subject, "role": role, "kind": kind,
                     "via": "default_template"},
            request_ip=ctx.get("request_ip"),
            user_agent=ctx.get("user_agent"),
        )
