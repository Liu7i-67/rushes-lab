"""admin router — 内部诊断 / 审计后台 + 项目权限模板(批次三,方案 §4.2)。

  GET  /api/v1/admin/audit?...              — audit 查询(分页 + filter)
  GET  /api/v1/admin/audit/export.csv?...   — audit 流式 CSV 导出
  CRUD /api/v1/admin/grant-templates        — 项目权限模板(前端预填用预设;
                                              读放宽 system admin 或 project creator,§2.3)
  POST /api/v1/admin/grant-templates/apply-default — 存量项目补默认模板授权(§3.2)

#154:飞书诊断 endpoint(/feishu/health、/feishu/test-card)随飞书下线删除(ADR-0007)。
"""
from __future__ import annotations

import csv
import io
import logging
import uuid
from datetime import datetime
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field
from sqlalchemy import delete, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.session import get_db
from app.db.tables import (
    AuditEvent,
    Group,
    Project,
    ProjectGrantTemplate,
    ProjectGrantTemplateItem,
    User,
)
from app.deps import (
    CurrentUser,
    get_audit,
    get_permissions,
    get_request_context,
    require_admin_or_project_creator,
    require_system_admin,
)
from app.routers.projects import INITIAL_GRANTS_MAX
from app.services.audit import AuditService
from app.services.default_grants import apply_default_template_grants
from app.services.org import get_default_organization
from app.services.permissions import PermissionsService, ProjectRole, fmt_subject
from app.services.subject_names import resolve_subject_names

log = logging.getLogger(__name__)
router = APIRouter()


# ─── audit query ─────────────────────────────────────────────────────────────
class AuditOut(BaseModel):
    id: str
    event_type: str
    event_time: datetime
    actor_user_id: str | None
    actor_name: str | None
    actor_open_id: str | None
    target_asset_id: str | None
    target_project_id: str | None
    target_minio_key: str | None
    request_ip: str | None
    details: dict


def _build_audit_query(
    actor_user_id: uuid.UUID | None,
    actor_open_id: str | None,
    event_type: str | None,
    project_id: uuid.UUID | None,
    from_time: datetime | None,
    to_time: datetime | None,
):
    stmt = select(AuditEvent)
    if event_type:
        stmt = stmt.where(AuditEvent.event_type == event_type)
    # #150:actor 过滤改 users.id UUID(UserPicker 语义切换);open_id 过滤保留兼容老调用
    if actor_user_id:
        stmt = stmt.where(AuditEvent.actor_user_id == actor_user_id)
    elif actor_open_id:
        stmt = stmt.where(AuditEvent.actor_open_id_snapshot == actor_open_id)
    if project_id:
        stmt = stmt.where(AuditEvent.target_project_id == project_id)
    if from_time:
        stmt = stmt.where(AuditEvent.event_time >= from_time)
    if to_time:
        stmt = stmt.where(AuditEvent.event_time <= to_time)
    return stmt


@router.get("/audit", response_model=list[AuditOut])
async def list_audit(
    actor_user_id: uuid.UUID | None = Query(None, description="按 actor users.id 过滤(#150)"),
    actor_open_id: str | None = Query(None, description="按 actor open_id 过滤(旧调用方)"),
    event_type: str | None = Query(None, description="精确 event_type 过滤"),
    project_id: uuid.UUID | None = Query(None),
    from_time: datetime | None = Query(None, alias="from"),
    to_time: datetime | None = Query(None, alias="to"),
    limit: int = Query(100, ge=1, le=500),
    offset: int = Query(0, ge=0),
    db: AsyncSession = Depends(get_db),
    user: CurrentUser = Depends(require_system_admin),
) -> list[AuditOut]:
    """audit 查询(分页 + filter)— 仅 system admin。"""
    _ = user.id
    stmt = _build_audit_query(
        actor_user_id, actor_open_id, event_type, project_id, from_time, to_time,
    ).order_by(AuditEvent.event_time.desc()).limit(limit).offset(offset)
    res = await db.execute(stmt)
    return [
        AuditOut(
            id=str(e.id),
            event_type=e.event_type,
            event_time=e.event_time,
            actor_user_id=str(e.actor_user_id) if e.actor_user_id else None,
            actor_name=e.actor_name_snapshot,
            actor_open_id=e.actor_open_id_snapshot,
            target_asset_id=str(e.target_asset_id) if e.target_asset_id else None,
            target_project_id=str(e.target_project_id) if e.target_project_id else None,
            target_minio_key=e.target_minio_key,
            request_ip=e.request_ip,
            details=e.details or {},
        )
        for e in res.scalars().all()
    ]


@router.get("/audit/export.csv")
async def export_audit_csv(
    actor_user_id: uuid.UUID | None = Query(None, description="按 actor users.id 过滤(#150)"),
    actor_open_id: str | None = Query(None, description="按 actor open_id 过滤(旧调用方)"),
    event_type: str | None = Query(None),
    project_id: uuid.UUID | None = Query(None),
    from_time: datetime | None = Query(None, alias="from"),
    to_time: datetime | None = Query(None, alias="to"),
    db: AsyncSession = Depends(get_db),
    user: CurrentUser = Depends(require_system_admin),
) -> StreamingResponse:
    """流式 CSV 导出(同 query filter)— UTF-8 BOM 给 Excel 兼容。"""
    _ = user.id
    stmt = _build_audit_query(
        actor_user_id, actor_open_id, event_type, project_id, from_time, to_time,
    ).order_by(AuditEvent.event_time.desc()).limit(50000)

    async def gen():
        buf = io.StringIO()
        writer = csv.writer(buf)
        # BOM for Excel
        yield "﻿".encode()
        writer.writerow([
            "time", "event_type", "actor_name", "actor_open_id",
            "target_project_id", "target_asset_id", "target_minio_key",
            "request_ip", "details_json",
        ])
        yield buf.getvalue().encode()
        buf.seek(0); buf.truncate()

        import json as _json
        res = await db.execute(stmt)
        for e in res.scalars().all():
            writer.writerow([
                e.event_time.isoformat() if e.event_time else "",
                e.event_type,
                e.actor_name_snapshot or "",
                e.actor_open_id_snapshot or "",
                str(e.target_project_id) if e.target_project_id else "",
                str(e.target_asset_id) if e.target_asset_id else "",
                e.target_minio_key or "",
                e.request_ip or "",
                _json.dumps(e.details or {}, ensure_ascii=False),
            ])
            chunk = buf.getvalue().encode()
            if chunk:
                yield chunk
                buf.seek(0); buf.truncate()

    filename = f"audit-{datetime.now().strftime('%Y%m%d-%H%M%S')}.csv"
    return StreamingResponse(
        gen(),
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


# ─── 项目权限模板(批次三,方案 §4.2)─────────────────────────────────────────
# 落位取舍见方案 §4.2:模板属项目授权域,不进 directory(组织目录域);复用本文件
# 的 require_system_admin 惯例。应用方式:非默认模板 = 前端预填(§4.3);默认模板
# 例外由后端直通(§3.1,POST /projects 完成后调 default_grants 共享 helper)+
# 存量项目按需「刷新默认权限」(§3.2 apply-default)—— 「后端不感知模板」原则仅对
# 默认模板打破,非默认模板仍纯前端预填。


class GrantTemplateItemIn(BaseModel):
    kind: Literal["user", "group"]
    id: uuid.UUID                      # user: users.id(需 active);group: groups.id(需存在)
    roles: list[ProjectRole] = Field(..., min_length=1)


class GrantTemplateCreateIn(BaseModel):
    name: str = Field(..., min_length=1, max_length=128)
    description: str | None = Field(None, max_length=1024)
    is_default: bool = False
    items: list[GrantTemplateItemIn] = Field(..., min_length=1)  # 空模板无意义,UI 已拦,API 层兜底


class GrantTemplateUpdateIn(BaseModel):
    """PATCH 均可选;items 传了即全量替换;is_default 不传 = 不改;
    description 不传 = 不改、显式 null = 清空(model_fields_set 区分)。"""

    name: str | None = Field(None, min_length=1, max_length=128)
    description: str | None = Field(None, max_length=1024)
    is_default: bool | None = None
    items: list[GrantTemplateItemIn] | None = Field(None, min_length=1)  # 空模板无意义,UI 已拦,API 层兜底


class GrantTemplateItemOut(BaseModel):
    kind: str
    id: uuid.UUID
    roles: list[str]
    # resolve_subject_names 解析后的主体名;missing=true 仅当主体已删(found=False;
    # 停用用户 DB 行仍在 → found=True 不标 missing,§4.5)
    name: str
    missing: bool


class GrantTemplateOut(BaseModel):
    id: uuid.UUID
    name: str
    description: str | None
    is_default: bool
    items: list[GrantTemplateItemOut]


async def _validate_template_items(
    db: AsyncSession, items: list[GrantTemplateItemIn],
) -> None:
    """POST / PATCH 共用的 items 校验,顺序同 §3.1:条数(422)→ 重复主体(400)
    → 存在性(400,错误指明第几条 + 主体 id)。kind / roles 形状在 Pydantic 层 422。

    上限与 initial_grants 同一常量(50):模板预填后提交建项目不能被上限卡住。
    """
    if len(items) > INITIAL_GRANTS_MAX:
        raise HTTPException(
            422,
            f"items 条数超上限:最多 {INITIAL_GRANTS_MAX} 条,收到 {len(items)} 条",
        )
    seen: set[tuple[str, uuid.UUID]] = set()
    for i, item in enumerate(items, start=1):
        if (item.kind, item.id) in seen:
            raise HTTPException(400, f"items 第 {i} 条主体重复:{item.kind} {item.id}")
        seen.add((item.kind, item.id))

    item_user_ids = {item.id for item in items if item.kind == "user"}
    item_group_ids = {item.id for item in items if item.kind == "group"}
    active_user_ids: set[uuid.UUID] = set()
    if item_user_ids:
        res = await db.execute(
            select(User.id).where(User.id.in_(item_user_ids), User.is_active.is_(True))
        )
        active_user_ids = {row[0] for row in res.all()}
    existing_group_ids: set[uuid.UUID] = set()
    if item_group_ids:
        res = await db.execute(select(Group.id).where(Group.id.in_(item_group_ids)))
        existing_group_ids = {row[0] for row in res.all()}
    for i, item in enumerate(items, start=1):
        if item.kind == "user" and item.id not in active_user_ids:
            raise HTTPException(
                400, f"items 第 {i} 条主体不存在或未启用:user {item.id}",
            )
        if item.kind == "group" and item.id not in existing_group_ids:
            raise HTTPException(400, f"items 第 {i} 条主体不存在:group {item.id}")


async def _serialize_grant_templates(
    db: AsyncSession, templates: list[ProjectGrantTemplate],
) -> list[GrantTemplateOut]:
    """模板 → 出参:items 一次批量取回(免 N+1),主体名复用 §2 resolve_subject_names
    批量解析;found=False 即主体已删 → item.missing=true(§4.5 边界)。"""
    if not templates:
        return []
    res = await db.execute(
        select(ProjectGrantTemplateItem)
        .where(ProjectGrantTemplateItem.template_id.in_([t.id for t in templates]))
        .order_by(ProjectGrantTemplateItem.created_at, ProjectGrantTemplateItem.id)
    )
    items_by_tid: dict[uuid.UUID, list[ProjectGrantTemplateItem]] = {}
    for it in res.scalars().all():
        items_by_tid.setdefault(it.template_id, []).append(it)

    subjects = [
        fmt_subject(it.subject_kind, str(it.subject_id))  # type: ignore[arg-type]
        for its in items_by_tid.values()
        for it in its
    ]
    names = await resolve_subject_names(db, subjects) if subjects else {}

    out: list[GrantTemplateOut] = []
    for t in templates:
        item_outs: list[GrantTemplateItemOut] = []
        for it in items_by_tid.get(t.id, []):
            info = names[
                fmt_subject(it.subject_kind, str(it.subject_id))  # type: ignore[arg-type]
            ]
            item_outs.append(GrantTemplateItemOut(
                kind=it.subject_kind, id=it.subject_id,
                roles=list(it.roles or []), name=info["name"],
                missing=not info["found"],
            ))
        out.append(GrantTemplateOut(
            id=t.id, name=t.name, description=t.description,
            is_default=t.is_default, items=item_outs,
        ))
    return out


def _integrity_conflict_response(e: IntegrityError, name: str | None) -> HTTPException:
    """并发漏检撞唯一约束的兜底映射(照 projects.py projects_code_key 的写法)。"""
    err = str(e.orig)
    if "uq_pgt_org_name" in err:
        return HTTPException(409, f"模板名已存在:{name}")
    if "uq_pgt_default_per_org" in err:
        return HTTPException(409, "并发设置默认模板冲突,请重试")
    return HTTPException(409, "模板写入失败,存在唯一性冲突")


@router.get("/grant-templates", response_model=list[GrantTemplateOut])
async def list_grant_templates(
    db: AsyncSession = Depends(get_db),  # noqa: B008  FastAPI DI,repo 全量同款
    user: CurrentUser = Depends(require_admin_or_project_creator),  # noqa: B008
) -> list[GrantTemplateOut]:
    """模板列表(含 items + 解析后的主体名称;主体已删的 item 标 missing=true)。

    读守门放宽为 system admin 或 project creator(方案 §2.3 弱门:零项目组长建
    项目表单要拉模板列表);写端点 POST/PATCH/DELETE 保持 require_system_admin。
    """
    _ = user.id
    res = await db.execute(
        select(ProjectGrantTemplate).order_by(
            ProjectGrantTemplate.created_at.desc(), ProjectGrantTemplate.id,
        )
    )
    return await _serialize_grant_templates(db, list(res.scalars().all()))


@router.post("/grant-templates", response_model=GrantTemplateOut, status_code=201)
async def create_grant_template(
    payload: GrantTemplateCreateIn,
    db: AsyncSession = Depends(get_db),  # noqa: B008  FastAPI DI,repo 全量同款
    user: CurrentUser = Depends(require_system_admin),  # noqa: B008
    audit: AuditService = Depends(get_audit),  # noqa: B008
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008
) -> GrantTemplateOut:
    """创建模板。organization_id 不由 body 传入:服务端取 default org(单租户)。"""
    org = await get_default_organization(db)
    if org is None:
        raise HTTPException(400, "默认组织不存在,无法创建权限模板")
    org_id = org[0]

    await _validate_template_items(db, payload.items)

    # 同 org 重名 → 409(预检照 create_directory_group;并发漏检由 IntegrityError 兜底)
    dup = await db.execute(
        select(ProjectGrantTemplate).where(
            ProjectGrantTemplate.organization_id == org_id,
            ProjectGrantTemplate.name == payload.name,
        )
    )
    if dup.scalar_one_or_none() is not None:
        raise HTTPException(409, f"模板名已存在:{payload.name}")

    # is_default=true:同事务先 UPDATE 清旧 default 再 INSERT 新行(勿分两次 commit);
    # UPDATE 必须在 db.add 之前 —— execute(update) 会 autoflush,后 add 会把新行的
    # is_default 一并清掉
    if payload.is_default:
        await db.execute(
            update(ProjectGrantTemplate)
            .where(
                ProjectGrantTemplate.organization_id == org_id,
                ProjectGrantTemplate.is_default.is_(True),
            )
            .values(is_default=False)
        )
    template = ProjectGrantTemplate(
        id=uuid.uuid4(),
        organization_id=org_id,
        name=payload.name,
        description=payload.description,
        is_default=payload.is_default,
    )
    db.add(template)
    for item in payload.items:
        db.add(ProjectGrantTemplateItem(
            id=uuid.uuid4(), template_id=template.id,
            subject_kind=item.kind, subject_id=item.id, roles=list(item.roles),
        ))
    try:
        await db.commit()
    except IntegrityError as e:
        await db.rollback()
        raise _integrity_conflict_response(e, payload.name) from e

    await audit.write(
        event_type="grant_template_changed",
        actor_user_id=user.id,
        details={
            "action": "create", "template_id": str(template.id),
            "name": template.name, "is_default": template.is_default,
            "items_count": len(payload.items),
        },
        request_ip=ctx["request_ip"],
        user_agent=ctx["user_agent"],
    )
    return (await _serialize_grant_templates(db, [template]))[0]


@router.patch("/grant-templates/{template_id}", response_model=GrantTemplateOut)
async def update_grant_template(
    template_id: uuid.UUID,
    payload: GrantTemplateUpdateIn,
    db: AsyncSession = Depends(get_db),  # noqa: B008  FastAPI DI,repo 全量同款
    user: CurrentUser = Depends(require_system_admin),  # noqa: B008
    audit: AuditService = Depends(get_audit),  # noqa: B008
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008
) -> GrantTemplateOut:
    """改模板:改名/描述/设默认(均可选)+ items 全量替换。

    改名撞同 org 已有 name → 409(预检排除自身);items 条数/重复/存在性校验同
    POST;is_default true→false = 直接取消默认(不产生新 default,§4.2 合法输入)。
    """
    template = await db.get(ProjectGrantTemplate, template_id)
    if template is None:
        raise HTTPException(404, f"grant template not found:{template_id}")
    org_id = template.organization_id

    # 校验先于任何写(404/400/422/409 都应在无副作用阶段抛出)
    new_items: list[GrantTemplateItemIn] | None = None
    if payload.items is not None:
        await _validate_template_items(db, payload.items)
        new_items = payload.items
    if payload.name is not None and payload.name != template.name:
        dup = await db.execute(
            select(ProjectGrantTemplate).where(
                ProjectGrantTemplate.organization_id == org_id,
                ProjectGrantTemplate.name == payload.name,
                ProjectGrantTemplate.id != template_id,   # 预检排除自身
            )
        )
        if dup.scalar_one_or_none() is not None:
            raise HTTPException(409, f"模板名已存在:{payload.name}")
        template.name = payload.name
    # 显式传 null = 清空(前端保存空描述时发 null);没传 = 不改 ——
    # `is not None` 会把 null 误当「不改」,清空永远不生效
    if "description" in payload.model_fields_set:
        template.description = payload.description

    if payload.is_default is True and not template.is_default:
        # 同事务清旧 default(排除自身)再设自己;先 UPDATE 后改属性(同 POST 的
        # autoflush 考量,且排除自身双保险)
        await db.execute(
            update(ProjectGrantTemplate)
            .where(
                ProjectGrantTemplate.organization_id == org_id,
                ProjectGrantTemplate.is_default.is_(True),
                ProjectGrantTemplate.id != template_id,
            )
            .values(is_default=False)
        )
        template.is_default = True
    elif payload.is_default is False:
        template.is_default = False

    if new_items is not None:
        # 全量替换:同事务删旧插新(DB 层 uq_pgt_item_subject 由 API 预检前置)
        await db.execute(
            delete(ProjectGrantTemplateItem).where(
                ProjectGrantTemplateItem.template_id == template_id,
            )
        )
        for item in new_items:
            db.add(ProjectGrantTemplateItem(
                id=uuid.uuid4(), template_id=template_id,
                subject_kind=item.kind, subject_id=item.id, roles=list(item.roles),
            ))

    try:
        await db.commit()
    except IntegrityError as e:
        await db.rollback()
        raise _integrity_conflict_response(e, payload.name) from e

    await audit.write(
        event_type="grant_template_changed",
        actor_user_id=user.id,
        details={
            "action": "update", "template_id": str(template_id),
            "name": template.name, "is_default": template.is_default,
        },
        request_ip=ctx["request_ip"],
        user_agent=ctx["user_agent"],
    )
    return (await _serialize_grant_templates(db, [template]))[0]


@router.delete("/grant-templates/{template_id}", status_code=204)
async def delete_grant_template(
    template_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),  # noqa: B008  FastAPI DI,repo 全量同款
    user: CurrentUser = Depends(require_system_admin),  # noqa: B008
    audit: AuditService = Depends(get_audit),  # noqa: B008
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008
) -> None:
    """删模板(items 随 FK ondelete CASCADE 级联删;删 is_default 模板 = org 无默认,
    §4.5 允许)。id 不存在 → 404;重复删 → 404(硬删)。"""
    template = await db.get(ProjectGrantTemplate, template_id)
    if template is None:
        raise HTTPException(404, f"grant template not found:{template_id}")
    name = template.name
    await db.delete(template)
    await db.commit()

    await audit.write(
        event_type="grant_template_changed",
        actor_user_id=user.id,
        details={"action": "delete", "template_id": str(template_id), "name": name},
        request_ip=ctx["request_ip"],
        user_agent=ctx["user_agent"],
    )


# ─── 「刷新默认权限」:存量项目补默认模板授权(方案 §3.2)──────────────────────
class ApplyDefaultIn(BaseModel):
    project_ids: list[uuid.UUID] = Field(..., min_length=1, max_length=100)


class ApplyDefaultResultItem(BaseModel):
    """单项目结果:成功项 = {project_id, applied, skipped_stale};失败项 =
    {project_id, error} —— 两种条目形状勿混用(方案 §3.2),故三字段显式可空。"""

    project_id: uuid.UUID
    applied: int | None = None
    skipped_stale: int | None = None
    error: str | None = None


class ApplyDefaultOut(BaseModel):
    results: list[ApplyDefaultResultItem]
    total_applied: int
    total_skipped: int


@router.post("/grant-templates/apply-default", response_model=ApplyDefaultOut)
async def apply_default_grant_template(
    payload: ApplyDefaultIn,
    db: AsyncSession = Depends(get_db),  # noqa: B008  FastAPI DI,repo 全量同款
    user: CurrentUser = Depends(require_system_admin),  # noqa: B008
    permissions: PermissionsService = Depends(get_permissions),  # noqa: B008
    audit: AuditService = Depends(get_audit),  # noqa: B008
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008
) -> ApplyDefaultOut:
    """存量项目按需补默认模板授权(管理页「刷新默认权限」按钮)。

    语义写死**叠加不删**(§3.2):只补缺失 (subject, role),已存在天然跳过,
    不移除任何授权。project_ids 去重;执行前单条 SELECT 预检全部(不存在 /
    跨 org / is_archived → 400 指明第几个;无默认模板 → 400 —— UI 已 disabled,
    这里是 API 直调兜底);执行期单项目 FGA/DB 失败**继续其余项目**,失败项计入
    results 的 error(部分成功)。满批串行 FGA/DB 往返为分钟级,建议 20-30 项/批
    分次提交。audit 逐条 project_member_added(via: "default_template")在 helper 内。
    """
    # 去重(保持原顺序;前端 Transfer 天然无重复,API 直调兜底)
    seen: set[uuid.UUID] = set()
    project_ids: list[uuid.UUID] = []
    for pid in payload.project_ids:
        if pid not in seen:
            seen.add(pid)
            project_ids.append(pid)

    # 预检:单条 SELECT 拉全部目标项目,逐条校验并指明第几个
    rows = await db.execute(select(Project).where(Project.id.in_(project_ids)))
    projects_by_id = {p.id: p for p in rows.scalars().all()}
    for i, pid in enumerate(project_ids, start=1):
        p = projects_by_id.get(pid)
        if p is None:
            raise HTTPException(400, f"第 {i} 个项目不存在:{pid}")
        if p.is_archived:
            raise HTTPException(400, f"第 {i} 个项目已归档:{pid}")

    org = await get_default_organization(db)
    if org is None:
        raise HTTPException(400, "默认组织不存在,无法刷新默认权限")
    org_id, _tenant_key = org
    for i, pid in enumerate(project_ids, start=1):
        if projects_by_id[pid].organization_id != org_id:
            raise HTTPException(400, f"第 {i} 个项目不属于当前组织:{pid}")

    # 无默认模板 → 400(UI disabled 的 API 兜底;helper 对无默认也回 0/0,
    # 但预检前置才能把「刷了个寂寞」拦在执行前)
    tpl_res = await db.execute(
        select(ProjectGrantTemplate).where(
            ProjectGrantTemplate.organization_id == org_id,
            ProjectGrantTemplate.is_default.is_(True),
        )
    )
    if tpl_res.scalar_one_or_none() is None:
        raise HTTPException(400, "当前组织没有默认模板,无可刷新的默认权限")

    results: list[ApplyDefaultResultItem] = []
    total_applied = 0
    total_skipped = 0
    failed = 0
    for pid in project_ids:
        try:
            out = await apply_default_template_grants(
                db, permissions, audit,
                org_id=org_id, project_id=pid,
                actor_user_id=user.id, ctx=ctx,
            )
        except Exception as e:  # noqa: BLE001
            # 执行期单项目失败继续其余(部分成功);失败项计入 results 的 error。
            # helper 内不会抛 HTTPException —— 形状/预检类错误都已在上方拦下
            failed += 1
            results.append(ApplyDefaultResultItem(
                project_id=pid, error=str(e) or e.__class__.__name__,
            ))
            continue
        total_applied += out["applied"]
        total_skipped += out["skipped_stale"]
        results.append(ApplyDefaultResultItem(
            project_id=pid, applied=out["applied"], skipped_stale=out["skipped_stale"],
        ))
    log.info(
        "apply default template grants by admin=%s projects=%d applied=%d skipped=%d failed=%d",
        user.id, len(project_ids), total_applied, total_skipped, failed,
    )
    return ApplyDefaultOut(
        results=results, total_applied=total_applied, total_skipped=total_skipped,
    )
