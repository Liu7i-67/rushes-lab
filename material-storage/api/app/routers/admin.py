"""admin router — 内部诊断 / 审计后台 + 项目权限模板(批次三,方案 §4.2)。

  GET  /api/v1/admin/audit?...              — audit 查询(分页 + filter)
  GET  /api/v1/admin/audit/export.csv?...   — audit 流式 CSV 导出
  CRUD /api/v1/admin/grant-templates        — 项目权限模板(前端预填用预设;
                                              读放宽 system admin 或 project creator,§2.3)
  POST /api/v1/admin/grant-templates/apply-default — 存量项目补默认模板授权(§3.2)
  CRUD /api/v1/admin/folder-templates       — 目录模板(建项目一键建目录,2026-10-10;
                                              读弱门 org admin 或 creator 或 flag,
                                              写门 org admin 或 flag,方案 §3.3)
  GET  /api/v1/admin/baidu-backup/tasks            — 百度备份任务全系统列表(2026-10-14,
                                              W3 观测面,方案 §3.1①)
  GET  /api/v1/admin/baidu-backup/tasks/{id}    — 任务详情(+调度观测字段/绑定行,§3.1②)
  GET  /api/v1/admin/baidu-backup/tasks/{id}/files — 文件明细(manifest 分页,§3.1③)

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
from sqlalchemy import delete, func, or_, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.sql.elements import ColumnElement

from app.db.session import get_db
from app.db.tables import (
    AuditEvent,
    BaiduBackupTask,
    BaiduBackupTaskFile,
    BaiduBinding,
    Folder,
    Group,
    Project,
    ProjectFolderTemplate,
    ProjectFolderTemplateEntry,
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
    require_folder_template_manager,
    require_folder_templates_reader,
    require_system_admin,
)
from app.models import (
    FolderTemplateEntryIn,
    FolderTemplateEntryOut,
    FolderTemplateIn,
    FolderTemplateOut,
)
from app.routers.projects import INITIAL_GRANTS_MAX
from app.services.audit import AuditService
from app.services.baidu_backup import ACTIVE_STATUSES, FILE_STATUSES, TERMINAL_STATUSES
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


# ─── 目录模板(2026-10-10,方案 §4.1)─────────────────────────────────────────
# 模板 = 一组目录相对路径;建项目时可选用,应用即快照物化为 folders(方案 §1-D2)。
# 落位:模板属项目建夹域,照 grant-templates 先例就近放本文件;读门组合弱门、
# 写门组级 flag(deps.require_folder_templates_reader / require_folder_template_manager)。

# 上限护栏(方案 §1-D8/§4.1 规则 5/7):条数 ≤200 在 Pydantic(max_length),其余
# 在 _validate_entry_paths;深度为本方案新引入口径(folder_chain 仅有总长护栏无
# 深度常量);字节限拦在保存期——600 个 CJK 字符 ≈1800 字节能过字符校验却必在
# 应用期 key_too_long,900B 低于 1024B 留分隔符余量
FOLDER_TEMPLATE_PATH_DEPTH_MAX = 10    # 路径深度 ≤10 段
FOLDER_TEMPLATE_PATH_MAX_BYTES = 900   # 整条 path ≤900 UTF-8 字符校验之外的字节口径
FOLDER_TEMPLATE_NODE_MAX = 400         # 去重后节点总数 ≤400(封顶最坏同步时延)


class FolderTemplateUpdateIn(BaseModel):
    """PATCH 均可选;entries 传了即全量替换(至少 1 条,§11 清空=删模板);
    name 不传 = 不改;description 不传 = 不改、显式 null = 清空(model_fields_set)。"""

    name: str | None = Field(None, min_length=1, max_length=128)
    description: str | None = Field(None, max_length=1024)
    entries: list[FolderTemplateEntryIn] | None = Field(None, min_length=1, max_length=200)


def _utf8_len(s: str) -> int:
    return len(s.encode("utf-8"))


def _validate_entry_paths(entries: list[FolderTemplateEntryIn]) -> list[str]:
    """POST/PATCH 共用的条目路径校验(方案 §4.1 规则 1-7;**不做静默归一化**,
    非法即 422;strip 后的值作为唯一校验与持久化对象)。

    顺序:逐条(1 首尾斜杠 → 2 段结构 → 3 段首尾空白 → 4 段长 → 5 深度/总长)
    → 6 payload 内重复 → 7 全模板去重节点总数;错误信息指明第几条、何因。
    返回 strip 后的路径列表(调用方以此入库,避免二次 strip 口径分叉)。
    """
    paths: list[str] = []
    for i, entry in enumerate(entries, start=1):
        # 规则 1:整条先 strip(仅首尾空白),strip 后的值即入库值;显式拒绝
        # 首尾斜杠(归一化会与唯一键语义打架,`素材/` 与 `素材` 必须判非法而非等价)
        path = entry.path.strip()
        if path.startswith("/") or path.endswith("/"):
            raise HTTPException(
                422, f"entries 第 {i} 条路径非法(不允许以 / 开头或结尾):{entry.path!r}",
            )
        segments = path.split("/")
        for seg in segments:
            # 规则 2:空段(连续 //)/ `.` / `..` / 含反斜杠(check_segment_name 语义)
            if not seg:
                raise HTTPException(422, f"entries 第 {i} 条路径含空段(连续 //):{path!r}")
            if seg in (".", "..") or "\\" in seg:
                raise HTTPException(
                    422, f"entries 第 {i} 条路径含非法段(. / .. / 反斜杠):{path!r}",
                )
            # 规则 3:段首尾含空白(拒绝而非静默 strip,报错可定位)
            if seg != seg.strip():
                raise HTTPException(422, f"entries 第 {i} 条路径段首尾含空白:{path!r}")
            # 规则 4:单段 255 字符 / 255 UTF-8 字节双口径(Folder.name 列限 + MinIO 段硬限)
            if len(seg) > 255 or _utf8_len(seg) > 255:
                raise HTTPException(
                    422, f"entries 第 {i} 条路径单段超长(>255 字符或 255 字节):{path!r}",
                )
        # 规则 5:深度 ≤10 段;总长 600 字符 / 900 UTF-8 字节双口径
        if len(segments) > FOLDER_TEMPLATE_PATH_DEPTH_MAX:
            raise HTTPException(
                422,
                f"entries 第 {i} 条路径深度超限(最多 {FOLDER_TEMPLATE_PATH_DEPTH_MAX} 段,"
                f"实际 {len(segments)} 段):{path!r}",
            )
        if len(path) > 600 or _utf8_len(path) > FOLDER_TEMPLATE_PATH_MAX_BYTES:
            raise HTTPException(
                422,
                f"entries 第 {i} 条路径总长超限(>600 字符或 "
                f"{FOLDER_TEMPLATE_PATH_MAX_BYTES} 字节):{path!r}",
            )
        paths.append(path)

    # 规则 6:payload 内 path 重复(指明重复值)
    seen: set[str] = set()
    for i, path in enumerate(paths, start=1):
        if path in seen:
            raise HTTPException(422, f"entries 第 {i} 条路径重复:{path}")
        seen.add(path)

    # 规则 7:各 path 按段展开去重的节点集 ≤400(单模板口径非跨模板合计;
    # 封顶最坏同步时延:满额 400 节点 ≈400 次串行 commit + FGA 写)
    nodes: set[tuple[str, ...]] = set()
    for path in paths:
        segs = path.split("/")
        for depth in range(1, len(segs) + 1):
            nodes.add(tuple(segs[:depth]))
    if len(nodes) > FOLDER_TEMPLATE_NODE_MAX:
        raise HTTPException(
            422,
            f"entries 去重后目录节点总数超限(最多 {FOLDER_TEMPLATE_NODE_MAX} 个,"
            f"实际 {len(nodes)} 个)",
        )
    return paths


def _folder_template_conflict_response(e: IntegrityError, name: str | None) -> HTTPException:
    """并发漏检撞唯一约束的兜底映射(照 _integrity_conflict_response 先例,按约束名)。"""
    err = str(e.orig)
    if "uq_pft_org_name" in err:
        return HTTPException(409, f"模板名已存在:{name}")
    if "uq_pft_entry_path" in err:
        return HTTPException(409, "模板条目已存在(并发写入冲突),请重试")
    return HTTPException(409, "模板写入失败,存在唯一性冲突")


async def _load_folder_template_entries(
    db: AsyncSession, template_id: uuid.UUID,
) -> list[ProjectFolderTemplateEntry]:
    """单模板条目按 path 排序取回(列表出参与响应序列化共用)。"""
    res = await db.execute(
        select(ProjectFolderTemplateEntry)
        .where(ProjectFolderTemplateEntry.template_id == template_id)
        .order_by(ProjectFolderTemplateEntry.path)
    )
    return list(res.scalars().all())


def _folder_template_out(
    template: ProjectFolderTemplate,
    entries: list[ProjectFolderTemplateEntry],
) -> FolderTemplateOut:
    return FolderTemplateOut(
        id=template.id, name=template.name, description=template.description,
        entry_count=len(entries),
        entries=[FolderTemplateEntryOut(path=e.path) for e in entries],
    )


@router.get("/folder-templates", response_model=list[FolderTemplateOut])
async def list_folder_templates(
    db: AsyncSession = Depends(get_db),  # noqa: B008  FastAPI DI,repo 全量同款
    user: CurrentUser = Depends(require_folder_templates_reader),  # noqa: B008
) -> list[FolderTemplateOut]:
    """模板列表(按 name 排序,带全量 entries 供 NewProjectModal 预览;模板数量少无压力)。

    读守门 = 组合弱门(org admin 或 project_creator 或 folder_template_manager,
    方案 §3.3);organization_id 服务端取 default org 过滤,org 缺失回空列表。
    """
    _ = user.id
    org = await get_default_organization(db)
    if org is None:
        return []
    org_id, _tenant_key = org
    res = await db.execute(
        select(ProjectFolderTemplate)
        .where(ProjectFolderTemplate.organization_id == org_id)
        .order_by(ProjectFolderTemplate.name, ProjectFolderTemplate.id)
    )
    templates = list(res.scalars().all())
    if not templates:
        return []
    # entries 一次批量取回(免 N+1),按 path 排序(与应用期字典序一致)
    res_entries = await db.execute(
        select(ProjectFolderTemplateEntry)
        .where(ProjectFolderTemplateEntry.template_id.in_([t.id for t in templates]))
        .order_by(ProjectFolderTemplateEntry.path)
    )
    entries_by_tid: dict[uuid.UUID, list[ProjectFolderTemplateEntry]] = {}
    for e in res_entries.scalars().all():
        entries_by_tid.setdefault(e.template_id, []).append(e)
    return [
        _folder_template_out(t, entries_by_tid.get(t.id, []))
        for t in templates
    ]


@router.post("/folder-templates", response_model=FolderTemplateOut, status_code=201)
async def create_folder_template(
    payload: FolderTemplateIn,
    db: AsyncSession = Depends(get_db),  # noqa: B008  FastAPI DI,repo 全量同款
    user: CurrentUser = Depends(require_folder_template_manager),  # noqa: B008
    audit: AuditService = Depends(get_audit),  # noqa: B008
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008
) -> FolderTemplateOut:
    """创建模板。organization_id 不由 body 传入:服务端取 default org(单租户)。

    entries 条数(1..200)在 Pydantic 层 422;路径七条规则在 _validate_entry_paths;
    重名 409(预检 + IntegrityError 兜底,照 grant-templates)。
    """
    org = await get_default_organization(db)
    if org is None:
        raise HTTPException(400, "默认组织不存在,无法创建目录模板")
    org_id, _tenant_key = org

    entry_paths = _validate_entry_paths(payload.entries)

    dup = await db.execute(
        select(ProjectFolderTemplate).where(
            ProjectFolderTemplate.organization_id == org_id,
            ProjectFolderTemplate.name == payload.name,
        )
    )
    if dup.scalar_one_or_none() is not None:
        raise HTTPException(409, f"模板名已存在:{payload.name}")

    template = ProjectFolderTemplate(
        id=uuid.uuid4(),
        organization_id=org_id,
        name=payload.name,
        description=payload.description,
    )
    db.add(template)
    for path in entry_paths:
        db.add(ProjectFolderTemplateEntry(
            id=uuid.uuid4(), template_id=template.id, path=path,
        ))
    try:
        await db.commit()
    except IntegrityError as e:
        await db.rollback()
        raise _folder_template_conflict_response(e, payload.name) from e

    await audit.write(
        event_type="folder_template_changed",
        actor_user_id=user.id,
        details={
            "action": "create", "template_id": str(template.id),
            "name": template.name, "entry_count": len(entry_paths),
        },
        request_ip=ctx["request_ip"],
        user_agent=ctx["user_agent"],
    )
    entries = await _load_folder_template_entries(db, template.id)
    return _folder_template_out(template, entries)


@router.patch("/folder-templates/{template_id}", response_model=FolderTemplateOut)
async def update_folder_template(
    template_id: uuid.UUID,
    payload: FolderTemplateUpdateIn,
    db: AsyncSession = Depends(get_db),  # noqa: B008  FastAPI DI,repo 全量同款
    user: CurrentUser = Depends(require_folder_template_manager),  # noqa: B008
    audit: AuditService = Depends(get_audit),  # noqa: B008
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008
) -> FolderTemplateOut:
    """改模板:改名/描述/条目(均可选)。

    entries 未传 = 不改(对齐 grant-templates items=None 不改先例),传则全量替换
    且至少 1 条;description 显式 null = 清空(model_fields_set 先例);改名撞同
    org 已有 name → 409(预检排除自身);entries 校验同 POST。
    """
    template = await db.get(ProjectFolderTemplate, template_id)
    if template is None:
        raise HTTPException(404, f"folder template not found:{template_id}")

    # 校验先于任何写(404/409/422 都应在无副作用阶段抛出)
    entry_paths: list[str] | None = None
    if payload.entries is not None:
        entry_paths = _validate_entry_paths(payload.entries)
    if payload.name is not None and payload.name != template.name:
        dup = await db.execute(
            select(ProjectFolderTemplate).where(
                ProjectFolderTemplate.organization_id == template.organization_id,
                ProjectFolderTemplate.name == payload.name,
                ProjectFolderTemplate.id != template_id,   # 预检排除自身
            )
        )
        if dup.scalar_one_or_none() is not None:
            raise HTTPException(409, f"模板名已存在:{payload.name}")
        template.name = payload.name
    # 显式传 null = 清空(前端保存空描述时发 null);没传 = 不改 ——
    # `is not None` 会把 null 误当「不改」,清空永远不生效
    if "description" in payload.model_fields_set:
        template.description = payload.description

    if entry_paths is not None:
        # 全量替换:同事务删旧插新(DB 层 uq_pft_entry_path 由 API 预检前置)
        await db.execute(
            delete(ProjectFolderTemplateEntry).where(
                ProjectFolderTemplateEntry.template_id == template_id,
            )
        )
        for path in entry_paths:
            db.add(ProjectFolderTemplateEntry(
                id=uuid.uuid4(), template_id=template_id, path=path,
            ))

    try:
        await db.commit()
    except IntegrityError as e:
        await db.rollback()
        raise _folder_template_conflict_response(e, payload.name) from e

    entries = await _load_folder_template_entries(db, template_id)
    await audit.write(
        event_type="folder_template_changed",
        actor_user_id=user.id,
        details={
            "action": "update", "template_id": str(template_id),
            "name": template.name, "entry_count": len(entries),
        },
        request_ip=ctx["request_ip"],
        user_agent=ctx["user_agent"],
    )
    return _folder_template_out(template, entries)


@router.delete("/folder-templates/{template_id}", status_code=204)
async def delete_folder_template(
    template_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),  # noqa: B008  FastAPI DI,repo 全量同款
    user: CurrentUser = Depends(require_folder_template_manager),  # noqa: B008
    audit: AuditService = Depends(get_audit),  # noqa: B008
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008
) -> None:
    """删模板(entries 随 FK ondelete CASCADE 级联删;应用即快照语义,
    不影响任何已建项目,方案 §1-D2)。id 不存在 → 404;重复删 → 404(硬删)。"""
    template = await db.get(ProjectFolderTemplate, template_id)
    if template is None:
        raise HTTPException(404, f"folder template not found:{template_id}")
    name = template.name
    await db.delete(template)
    await db.commit()

    await audit.write(
        event_type="folder_template_changed",
        actor_user_id=user.id,
        details={"action": "delete", "template_id": str(template_id), "name": name},
        request_ip=ctx["request_ip"],
        user_agent=ctx["user_agent"],
    )


# ─── 管理员备份任务视图(2026-10-14,W3,方案 §3.1)────────────────────────────
# 只读观测面:全系统百度备份任务对 system admin 可见(跨用户)。三条**刻意不随
# settings.baidu_backup_enabled 门控**(与用户侧 routers/baidu_backup.py 的
# _ensure_enabled() 语义不同,上游方案 §6 D2):管理观测面看的是存量事实(含
# 功能下线后的遗留任务),不受功能开关影响。只读端点不写审计(对齐本文件
# /audit 只读先例)。无 DB 迁移、无 FGA model 变更(权限复用 require_system_admin
# = OpenFGA organization#admin)。

# 任务状态白名单 = 活动态 + 终态(§3.1①;取值域引用服务层 §4 常量,防拼写漂移)
_BAIDU_TASK_STATUSES = (*ACTIVE_STATUSES, *TERMINAL_STATUSES)


def _trunc_200(s: str | None) -> str | None:
    """fail_reason / last_error 序列化前截 200 字符(§3.1,与 tags 同款脱敏口径)。"""
    if s is None or len(s) <= 200:
        return s
    return s[:200]


class AdminBaiduTaskUserOut(BaseModel):
    """任务所属用户(username 可空:飞书老账号无本地用户名;展示与 q 匹配须容忍)。"""

    id: uuid.UUID
    username: str | None = None
    name: str


class AdminBaiduTaskRefOut(BaseModel):
    """项目 / 目标文件夹引用(target_folder 夹已删 → 整个为 null)。"""

    id: uuid.UUID
    name: str


class AdminBaiduTaskOut(BaseModel):
    """admin 任务条目(§3.1①)。聚合列 enumerating 阶段为 NULL(tables.py:546-550,
    仅 done_bytes NOT NULL)→ 序列化统一 0 兜底;fail_reason 截 200。"""

    id: uuid.UUID
    user: AdminBaiduTaskUserOut
    status: str                                 # enumerating/running/completed/cancelled/failed
    source_dir: str
    project: AdminBaiduTaskRefOut               # 项目行总在(FK RESTRICT)
    target_folder: AdminBaiduTaskRefOut | None = None
    total_files: int = 0
    done_files: int = 0
    failed_files: int = 0
    skipped_files: int = 0
    cancelled_files: int = 0
    total_bytes: int = 0
    done_bytes: int = 0
    created_at: datetime
    updated_at: datetime
    fail_reason: str | None = None              # 截 200 字符
    cancel_requested: bool = False


class AdminBaiduTasksPage(BaseModel):
    """任务分页(排序固定 created_at DESC, id DESC 稳定排序防翻页抖动,§3.1①)。"""

    items: list[AdminBaiduTaskOut]
    total: int


class AdminBaiduTaskBindingOut(BaseModel):
    """任务关联绑定行(baidu_uid 是 BaiduBinding 列名,tables.py:481)。"""

    id: uuid.UUID
    baidu_uid: str
    status: str


class AdminBaiduTaskDetailOut(AdminBaiduTaskOut):
    """admin 任务详情(§3.1②)= 列表条目 + 创建时快照/绑定行/取消原因/调度观测字段。"""

    bound_baidu_uid: str | None = None          # 创建时从 binding 快照,可 null
    binding: AdminBaiduTaskBindingOut | None = None
    cancel_reason: str | None = None            # user_cancel / binding_replaced(§4)
    retry_count: int = 0                        # 复活次数
    enum_done: bool = False                     # 枚举完成标记(复活时复位)
    dispatched_at: datetime | None = None       # 最近派发时刻(NULL=从未派发)
    round_started_at: datetime | None = None    # 轮起点(48h 判停依据)
    lease_until: datetime | None = None         # 租约/心跳(NULL=未认领)
    runner_id: str | None = None


class AdminBaiduTaskFileOut(BaseModel):
    """admin 文件明细条目(§3.1③;last_error 截 200,与 tags 同款脱敏口径)。"""

    id: uuid.UUID
    source_path: str
    rel_path: str
    status: str                                 # pending/skipped_exists/importing/success/failed/cancelled
    bytes_done: int = 0
    attempts: int = 0
    non_retryable: bool = False
    last_error: str | None = None               # 截 200 字符
    asset_id: uuid.UUID | None = None
    updated_at: datetime


class AdminBaiduTaskFilesPage(BaseModel):
    """文件明细分页(排序固定 rel_path, id,对齐用户侧 routers/baidu_backup.py:900)。"""

    items: list[AdminBaiduTaskFileOut]
    total: int


async def _serialize_admin_baidu_tasks(
    db: AsyncSession, tasks: list[BaiduBackupTask],
) -> list[AdminBaiduTaskOut]:
    """任务 → 出参:user / project / target_folder 批量取回(免 N+1,照用户侧
    routers/baidu_backup.py:_build_task_outs 惯例);聚合列 NULL 兜 0、fail_reason
    截 200(§3.1)。project 行总在(FK RESTRICT);target_folder 夹已删 → None
    (FK SET NULL,列即 NULL,不存在的 id 防御性同样回落 None)。"""
    if not tasks:
        return []
    users: dict[uuid.UUID, AdminBaiduTaskUserOut] = {}
    res = await db.execute(
        select(User.id, User.username, User.name)
        .where(User.id.in_({t.user_id for t in tasks}))
    )
    for row in res.all():
        users[row.id] = AdminBaiduTaskUserOut(id=row.id, username=row.username, name=row.name)
    res = await db.execute(
        select(Project.id, Project.name).where(Project.id.in_({t.project_id for t in tasks}))
    )
    project_names: dict[uuid.UUID, str] = {row.id: row.name for row in res}
    folder_names: dict[uuid.UUID, str] = {}
    fids = {t.target_folder_id for t in tasks if t.target_folder_id}
    if fids:
        res = await db.execute(select(Folder.id, Folder.name).where(Folder.id.in_(fids)))
        folder_names = {row.id: row.name for row in res}

    outs: list[AdminBaiduTaskOut] = []
    for t in tasks:
        target_folder: AdminBaiduTaskRefOut | None = None
        if t.target_folder_id is not None and t.target_folder_id in folder_names:
            target_folder = AdminBaiduTaskRefOut(
                id=t.target_folder_id, name=folder_names[t.target_folder_id],
            )
        outs.append(AdminBaiduTaskOut(
            id=t.id,
            user=users[t.user_id],
            status=t.status,
            source_dir=t.source_dir,
            project=AdminBaiduTaskRefOut(id=t.project_id, name=project_names[t.project_id]),
            target_folder=target_folder,
            total_files=t.total_files or 0,
            done_files=t.done_files or 0,
            failed_files=t.failed_files or 0,
            skipped_files=t.skipped_files or 0,
            cancelled_files=t.cancelled_files or 0,
            total_bytes=t.total_bytes or 0,
            done_bytes=t.done_bytes,
            created_at=t.created_at,
            updated_at=t.updated_at,
            fail_reason=_trunc_200(t.fail_reason),
            cancel_requested=t.cancel_requested,
        ))
    return outs


@router.get("/baidu-backup/tasks", response_model=AdminBaiduTasksPage)
async def list_admin_baidu_tasks(
    status: str | None = Query(
        None, description="按任务状态过滤(enumerating/running/completed/cancelled/failed)",
    ),
    user_id: uuid.UUID | None = Query(None, description="按任务所属用户过滤"),  # noqa: B008  FastAPI DI,repo 全量同款
    q: str | None = Query(None, description="模糊匹配用户名/姓名/源目录(ilike)"),
    active_only: bool = Query(False, description="仅活动任务(enumerating/running)"),
    limit: int = Query(20, ge=1, le=100),
    offset: int = Query(0, ge=0),
    db: AsyncSession = Depends(get_db),  # noqa: B008  FastAPI DI,repo 全量同款
    user: CurrentUser = Depends(require_system_admin),  # noqa: B008
) -> AdminBaiduTasksPage:
    """全系统百度备份任务列表(仅 system admin;跨用户可见,§3.1①)。

    排序固定 created_at DESC, id DESC(稳定排序防同秒任务翻页抖动,对齐用户侧
    routers/baidu_backup.py:854);status 非白名单 400(与 ③ files 口径一致);
    users 内连接(FK NOT NULL)同时服务 q 的 username/name 两路模糊。
    """
    _ = user.id
    conditions: list[ColumnElement[bool]] = []
    if status is not None:
        if status not in _BAIDU_TASK_STATUSES:
            raise HTTPException(400, f"status 取值须为 {_BAIDU_TASK_STATUSES}")
        conditions.append(BaiduBackupTask.status == status)
    if active_only:
        conditions.append(BaiduBackupTask.status.in_(ACTIVE_STATUSES))
    if user_id is not None:
        conditions.append(BaiduBackupTask.user_id == user_id)
    term = (q or "").strip()
    if term:
        like = f"%{term}%"  # users.py search_users 同款;不转义通配符属既有口径
        conditions.append(or_(
            User.username.ilike(like),
            User.name.ilike(like),
            BaiduBackupTask.source_dir.ilike(like),
        ))
    total = await db.scalar(
        select(func.count())
        .select_from(BaiduBackupTask)
        .join(User, BaiduBackupTask.user_id == User.id)
        .where(*conditions)
    )
    rows = await db.execute(
        select(BaiduBackupTask)
        .join(User, BaiduBackupTask.user_id == User.id)
        .where(*conditions)
        .order_by(BaiduBackupTask.created_at.desc(), BaiduBackupTask.id.desc())
        .limit(limit)
        .offset(offset)
    )
    items = await _serialize_admin_baidu_tasks(db, list(rows.scalars().all()))
    return AdminBaiduTasksPage(items=items, total=total or 0)


@router.get("/baidu-backup/tasks/{task_id}", response_model=AdminBaiduTaskDetailOut)
async def get_admin_baidu_task(
    task_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),  # noqa: B008  FastAPI DI,repo 全量同款
    user: CurrentUser = Depends(require_system_admin),  # noqa: B008
) -> AdminBaiduTaskDetailOut:
    """任务详情(§3.1②;admin 视角无归属隐藏需求,404 不区分存在性语义)。"""
    _ = user.id
    task = await db.get(BaiduBackupTask, task_id)
    if task is None:
        raise HTTPException(404, f"task not found:{task_id}")
    (base,) = await _serialize_admin_baidu_tasks(db, [task])
    # binding 行总在(FK RESTRICT);防御 None 回落 null(与契约 binding|null 一致)
    binding_out: AdminBaiduTaskBindingOut | None = None
    binding = await db.get(BaiduBinding, task.binding_id)
    if binding is not None:
        binding_out = AdminBaiduTaskBindingOut(
            id=binding.id, baidu_uid=binding.baidu_uid, status=binding.status,
        )
    return AdminBaiduTaskDetailOut(
        **base.model_dump(),
        bound_baidu_uid=task.bound_baidu_uid,
        binding=binding_out,
        cancel_reason=task.cancel_reason,
        retry_count=task.retry_count,
        enum_done=task.enum_done,
        dispatched_at=task.dispatched_at,
        round_started_at=task.round_started_at,
        lease_until=task.lease_until,
        runner_id=task.runner_id,
    )


@router.get("/baidu-backup/tasks/{task_id}/files", response_model=AdminBaiduTaskFilesPage)
async def list_admin_baidu_task_files(
    task_id: uuid.UUID,
    status: str | None = Query(None, description="按行状态筛选(pending/skipped_exists/importing/success/failed/cancelled)"),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    db: AsyncSession = Depends(get_db),  # noqa: B008  FastAPI DI,repo 全量同款
    user: CurrentUser = Depends(require_system_admin),  # noqa: B008
) -> AdminBaiduTaskFilesPage:
    """任务文件明细(manifest 分页,§3.1③;不校验任务归属 —— admin 跨用户观测)。

    status 白名单/文案与排序(rel_path, id)均对齐用户侧
    routers/baidu_backup.py:891-900 口径;last_error 截 200(§3.1)。
    """
    _ = user.id
    task = await db.get(BaiduBackupTask, task_id)
    if task is None:
        raise HTTPException(404, f"task not found:{task_id}")
    conditions = [BaiduBackupTaskFile.task_id == task.id]
    if status is not None:
        if status not in FILE_STATUSES:
            raise HTTPException(400, f"status 取值须为 {FILE_STATUSES}")
        conditions.append(BaiduBackupTaskFile.status == status)
    total = await db.scalar(
        select(func.count()).select_from(BaiduBackupTaskFile).where(*conditions)
    )
    rows = await db.execute(
        select(BaiduBackupTaskFile)
        .where(*conditions)
        .order_by(BaiduBackupTaskFile.rel_path, BaiduBackupTaskFile.id)
        .limit(limit)
        .offset(offset)
    )
    return AdminBaiduTaskFilesPage(
        items=[
            AdminBaiduTaskFileOut(
                id=f.id,
                source_path=f.source_path,
                rel_path=f.rel_path,
                status=f.status,
                bytes_done=f.bytes_done,
                attempts=f.attempts,
                non_retryable=f.non_retryable,
                last_error=_trunc_200(f.last_error),
                asset_id=f.asset_id,
                updated_at=f.updated_at,
            )
            for f in rows.scalars().all()
        ],
        total=total or 0,
    )
