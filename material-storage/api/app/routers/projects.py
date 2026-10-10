"""projects router — CRUD + OpenFGA enforce + audit 落库(iter4)。

行为:
  POST /projects        — 创建项目(无 enforce;假设是 admin 操作,iter5 SSO 后加 admin check)
                          + bootstrap_project(OpenFGA tuple)+ audit
  GET  /projects        — 返回 user 可见的项目:
                          OpenFGA list_objects(user, can_view, project)
                          UNION project.visibility = 'public'
  GET  /projects/{id}   — check can_view + audit
  逻辑删除(F6,深隐藏+可恢复):
  DELETE /projects/{id}        — 守门 require_project_deleter;置 deleted_at/deleted_by
  GET  /projects/deleted       — 已删除项目分页列表(deleted_at 倒序)
  POST /projects/{id}/restore  — 清空 deleted_at/deleted_by(仅已删除者)
  主列表与详情一律过滤 deleted_at 非空(含 system admin,404)。
"""
from __future__ import annotations

import asyncio
import logging
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import func, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.session import get_db
from app.db.tables import Group, Project, User
from app.deps import (
    CurrentUser,
    get_audit,
    get_current_user,
    get_is_system_admin,
    get_permissions,
    get_request_context,
    require_project_creator,
    require_project_deleter,
)
from app.models import ProjectCreateIn, ProjectOut
from app.services.audit import AuditService
from app.services.default_grants import apply_default_template_grants
from app.services.permissions import (
    PermissionsService,
    fmt_subject,
    is_already_exists_error,
    is_not_exists_error,
)
from app.services.subject_names import resolve_subject_names

router = APIRouter()
log = logging.getLogger(__name__)

# initial_grants 条数上限(方案 §3.1;批次三模板 items 上限与同一常量,见 admin.py)
INITIAL_GRANTS_MAX = 50

# 非 admin 创建者的强制 bucket(方案 §2.3):前端 NewProjectModal 固定默认值;
# ProjectCreateIn 对 bucket 无约束,不收口则 project creator 可 API 直调把项目
# 指到任意 bucket,后续 presign 全走它
DEFAULT_MINIO_BUCKET = "ms-dev"


@router.post("", response_model=ProjectOut, status_code=201)
async def create_project(
    payload: ProjectCreateIn,
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    audit: AuditService = Depends(get_audit),
    user: CurrentUser = Depends(require_project_creator),   # 系统 admin 或 组级 project_creator
    is_system_admin: bool = Depends(get_is_system_admin),
    ctx: dict = Depends(get_request_context),
) -> ProjectOut:
    """创建 project — 系统 admin 或 组级 project_creator(方案 §2.3);必须 payload
    明确指派项目 admin(可以指自己,UI 默认填创建者)。

    organization_id 解析顺序:payload > user.organization_id > settings.default_organization_id;
    **非系统 admin 的创建者强制忽略 payload.organization_id 与 minio_bucket**
    (提权口收口,见下方注释)。
    """
    user_id = user.id
    from app.db.tables import Organization, User

    # 提权口收口(方案 §2.3):organization_id 可选且前端从不传,不收口则
    # creator 可 API 直调在任意 org 下建项目并 bootstrap 该 org 关系;bucket 对
    # creator 无约束,可把项目指到任意 bucket 使后续 presign 全走它。
    # 系统 admin 保留两个自由度不动。
    req_org_id = payload.organization_id
    req_bucket = payload.minio_bucket
    if not is_system_admin:
        req_org_id = None
        req_bucket = DEFAULT_MINIO_BUCKET

    # 校验 admin 是真 user(存在 db + active)
    from sqlalchemy import select as _select
    res = await db.execute(_select(User).where(
        User.id == payload.admin_user_id,
        User.is_active.is_(True),
    ))
    admin_user = res.scalar_one_or_none()
    if admin_user is None:
        raise HTTPException(
            400, f"admin user not found:{payload.admin_user_id}(需是已存在的 active user)"
        )

    # 解析 org_id
    org_id = req_org_id
    if org_id is None:
        db_user = await db.get(User, user_id)
        if db_user and db_user.organization_id:
            org_id = db_user.organization_id
        else:
            from app.settings import get_settings
            default = get_settings().default_organization_id
            if default:
                org_id = uuid.UUID(default)
    if org_id is None:
        raise HTTPException(400, "organization_id missing(no payload, no user org, no default)")

    org = await db.get(Organization, org_id)
    if org is None:
        raise HTTPException(400, f"organization {org_id} not found")
    tenant_key = org.feishu_tenant_key or str(org_id)

    # ── initial_grants 前置校验(方案 §3.1:全部在建项目行之前,原子无半吊子)──
    # 顺序:条数(422)→ payload 内 (kind,id) 重复(400)→ 存在性(400);
    # roles 空数组 / 非法值已在 Pydantic 层 422(min_length=1 + Literal)。
    initial_grants = payload.initial_grants or []
    if len(initial_grants) > INITIAL_GRANTS_MAX:
        raise HTTPException(
            422,
            f"initial_grants 条数超上限:最多 {INITIAL_GRANTS_MAX} 条,"
            f"收到 {len(initial_grants)} 条",
        )
    seen_subjects: set[tuple[str, uuid.UUID]] = set()
    for i, g in enumerate(initial_grants, start=1):
        if (g.kind, g.id) in seen_subjects:
            raise HTTPException(
                400, f"initial_grants 第 {i} 条主体重复:{g.kind} {g.id}",
            )
        seen_subjects.add((g.kind, g.id))
    if initial_grants:
        grant_user_ids = {g.id for g in initial_grants if g.kind == "user"}
        grant_group_ids = {g.id for g in initial_grants if g.kind == "group"}
        active_user_ids: set[uuid.UUID] = set()
        if grant_user_ids:
            res_users = await db.execute(select(User).where(User.id.in_(grant_user_ids)))
            active_user_ids = {
                u.id for u in res_users.scalars().all() if u.is_active
            }
        existing_group_ids: set[uuid.UUID] = set()
        if grant_group_ids:
            res_groups = await db.execute(
                select(Group.id).where(Group.id.in_(grant_group_ids))
            )
            existing_group_ids = {row[0] for row in res_groups.all()}
        for i, g in enumerate(initial_grants, start=1):
            if g.kind == "user" and g.id not in active_user_ids:
                raise HTTPException(
                    400, f"initial_grants 第 {i} 条主体不存在或未启用:user {g.id}",
                )
            if g.kind == "group" and g.id not in existing_group_ids:
                raise HTTPException(
                    400, f"initial_grants 第 {i} 条主体不存在:group {g.id}",
                )

    project = Project(
        id=uuid.uuid4(),
        organization_id=org_id,
        code=payload.code,
        name=payload.name,
        description=payload.description,
        minio_bucket=req_bucket,
    )
    db.add(project)
    try:
        await db.commit()
    except IntegrityError as e:
        await db.rollback()
        err = str(e.orig)
        if "projects_code_key" in err:
            raise HTTPException(409, "项目 code 已存在") from e
        if "organization_id" in err:
            raise HTTPException(400, "organization 不存在或无效") from e
        raise HTTPException(400, "项目创建失败,可能存在唯一性冲突") from e

    # bootstrap:org parent + 指派的项目 admin(可与创建者不同)
    await permissions.bootstrap_project(
        project_id=str(project.id),
        organization_tenant_key=tenant_key,
        creator_user_id=str(admin_user.id),
    )

    # initial_grants 直通(方案 §3.1):逐条逐角色写 OpenFGA。重复 tuple 幂等跳过
    # (admin_user_id 与 initial_grants 重复授 admin 是合理输入);跳过分支不写 audit
    # (与 add_project_member 的 continue-before-audit 现状一致)。OpenFGA 中途失败
    # → 500,与 bootstrap 失败同类同治:项目行已提交但授权部分缺失,成员抽屉手动补授。
    for g in initial_grants:
        subject = fmt_subject(g.kind, str(g.id))
        # 去重 + 固定顺序(用 PROJECT_ROLES;Literal 声明顺序与其不同,勿混用)
        roles = [r for r in PROJECT_ROLES if r in set(g.roles)]
        for role in roles:
            try:
                await permissions.add_project_subject(
                    project_id=str(project.id), subject=subject, role=role,
                )
            except Exception as e:
                if not is_already_exists_error(e):
                    raise
                continue
            # 仅真正写入的记一条,单角色 detail 形状与 add_project_member 对齐,
            # 下游按 event_type 过滤的查询不用改
            await audit.write(
                event_type="project_member_added",
                actor_user_id=user_id,
                target_project_id=project.id,
                details={
                    "subject": subject, "role": role, "kind": g.kind,
                    "via": "initial_grants",
                },
                **ctx,
            )

    # 默认模板直通(方案 §3.1):payload 校验与上面的直通写只认 initial_grants,
    # 默认模板授权由共享 helper 在直通写完成后合并(read 差集天然排除 payload
    # 已写条目,幂等;无默认模板 / items 空 = 现行为不变)。helper 异常与
    # initial_grants 直通写同治:500,项目行已提交、授权缺失,正是 §3.2
    # 「刷新默认权限」的补法。
    await apply_default_template_grants(
        db, permissions, audit,
        org_id=org_id, project_id=project.id,
        actor_user_id=user_id, ctx=ctx,
    )

    await audit.write(
        event_type="project_created",
        actor_user_id=user_id,
        target_project_id=project.id,
        details={
            "code": project.code, "name": project.name,
            "visibility": project.visibility,
            "admin_user_id": str(admin_user.id),
            "admin_name": admin_user.name,
            "initial_grants_count": len(initial_grants),
        },
        **ctx,
    )

    await db.refresh(project)
    return ProjectOut.model_validate(project)


async def _fill_project_admins(
    db: AsyncSession,
    permissions: PermissionsService,
    projects: list,
) -> dict[uuid.UUID, list]:
    """对一批 project 批量查 OpenFGA admin 并反查 db name → {project_id: [AdminBrief]}。

    每个 project 一次 OpenFGA list_users(N 次 round-trip,PoC 量级可接受;
    后续可加缓存或一次性 batch)。
    """
    from app.db.tables import User
    from app.models import AdminBrief

    out: dict[uuid.UUID, list] = {}
    all_user_ids: set[str] = set()
    project_to_user_ids: dict[uuid.UUID, list[str]] = {}
    for p in projects:
        ids = await permissions.list_users_with_relation(
            object_type="project", object_id=str(p.id), relation="admin",
        )
        project_to_user_ids[p.id] = ids
        all_user_ids.update(ids)

    name_by_user_id: dict[str, str] = {}
    user_uuids = _parse_uuids(all_user_ids)
    if user_uuids:
        res = await db.execute(
            select(User.id, User.name).where(User.id.in_(user_uuids))
        )
        name_by_user_id = {str(row[0]): row[1] for row in res.all()}

    for pid, ids in project_to_user_ids.items():
        out[pid] = [
            AdminBrief(user_id=uid, name=name_by_user_id.get(uid, uid[:12] + "…"))
            for uid in ids
        ]
    return out


def _parse_uuids(ids: list[str] | set[str]) -> list[uuid.UUID]:
    """subject_id 字符串 → UUID,容错非法值(老 open_id 存量数据)直接跳过。"""
    out: list[uuid.UUID] = []
    for s in ids:
        try:
            out.append(uuid.UUID(s))
        except ValueError:
            continue
    return out


def _is_uuid_str(s: str) -> bool:
    """s 是否为合法 UUID 字符串(入口校验用)。"""
    try:
        uuid.UUID(s)
    except ValueError:
        return False
    return True


@router.get("", response_model=list[ProjectOut])
async def list_projects(
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
    limit: int = 100,
    offset: int = 0,
) -> list[ProjectOut]:
    """返回 user 可见的项目 + 各项目的 admin 列表。

    系统 admin(organization.admin)→ 见全部 active project,无 filter
    普通 user → OpenFGA list_objects(can_view, project) UNION visibility=public
    """
    if is_system_admin:
        stmt = (
            select(Project)
            .where(
                Project.is_archived.is_(False),
                Project.deleted_at.is_(None),   # F6.4:已删除对所有人隐藏
            )
            .order_by(Project.created_at.desc())
            .limit(limit).offset(offset)
        )
    else:
        member_ids = await permissions.list_objects(
            user_subject=user.subject, relation="can_view", object_type="project",
        )
        member_uuids = [uuid.UUID(s) for s in member_ids]
        stmt = (
            select(Project)
            .where(
                or_(
                    Project.id.in_(member_uuids) if member_uuids else False,
                    Project.visibility == "public",
                ),
                Project.is_archived.is_(False),
                Project.deleted_at.is_(None),   # F6.4:已删除对所有人隐藏
            )
            .order_by(Project.created_at.desc())
            .limit(limit).offset(offset)
        )
    res = await db.execute(stmt)
    rows = list(res.scalars().all())

    # batch fill admins + my_roles
    admins_by_pid = await _fill_project_admins(db, permissions, rows)
    my_roles_by_pid = await _fill_my_roles(
        permissions, user.subject, rows, is_system_admin=is_system_admin,
    )
    out: list[ProjectOut] = []
    for r in rows:
        po = ProjectOut.model_validate(r)
        po.admins = admins_by_pid.get(r.id, [])
        po.my_roles = my_roles_by_pid.get(r.id, [])
        out.append(po)
    return out


# ─── 项目逻辑删除(F6,深隐藏+可恢复)─────────────────────────────────────────
# 本期新 schema 一律内联本文件定义(models/__init__ 由并行任务独占,不碰)


class DeletedProjectOut(BaseModel):
    id: uuid.UUID
    code: str
    name: str
    description: str | None = None
    visibility: str
    deleted_at: datetime
    deleted_by: uuid.UUID | None = None
    # deleted_by 反查 users.name(操作人已物理删除时为 None)
    deleted_by_name: str | None = None


class DeletedProjectsPageOut(BaseModel):
    items: list[DeletedProjectOut]
    total: int
    limit: int
    offset: int


@router.get("/deleted", response_model=DeletedProjectsPageOut)
async def list_deleted_projects(
    db: AsyncSession = Depends(get_db),
    user: CurrentUser = Depends(require_project_deleter),
    q: str | None = Query(default=None, description="code/name 不区分大小写子串"),
    limit: int = Query(default=20, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
) -> DeletedProjectsPageOut:
    """已删除项目分页列表(F6.5)— deleted_at 倒序;deleted_by_name 由 users join 取。

    路由顺序敏感:必须声明在 GET /{project_id} 之前,否则字面量 "deleted"
    会被该路由的 str 路径参数吞掉(422)。
    """
    conds = [Project.deleted_at.isnot(None)]
    if q:
        pattern = f"%{q}%"
        conds.append(or_(Project.code.ilike(pattern), Project.name.ilike(pattern)))

    total = await db.scalar(
        select(func.count()).select_from(Project).where(*conds)
    )
    rows = (
        await db.execute(
            select(Project, User.name)
            .outerjoin(User, Project.deleted_by == User.id)
            .where(*conds)
            .order_by(Project.deleted_at.desc())
            .limit(limit)
            .offset(offset)
        )
    ).all()
    items = [
        DeletedProjectOut(
            id=p.id, code=p.code, name=p.name, description=p.description,
            visibility=p.visibility, deleted_at=p.deleted_at,
            deleted_by=p.deleted_by, deleted_by_name=deleter_name,
        )
        for p, deleter_name in rows
    ]
    return DeletedProjectsPageOut(items=items, total=total, limit=limit, offset=offset)


@router.delete("/{project_id}")
async def delete_project(
    project_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
    audit: AuditService = Depends(get_audit),
    user: CurrentUser = Depends(require_project_deleter),   # 不要求目标项目 admin(D2)
    ctx: dict = Depends(get_request_context),
) -> dict:
    """逻辑删除项目(F6.3 / D1 / D10)— 深隐藏+可恢复。

    只置 deleted_at/deleted_by;FGA tuple / minio 桶 / 资产 / 分享链接全不动
    (恢复 = 清空两字段,零成本)。不存在或已删除 → 404(对所有人一致)。
    """
    project = await db.get(Project, project_id)
    if project is None or project.deleted_at is not None:
        raise HTTPException(404, "project not found")
    deleted_at = datetime.now(timezone.utc)
    project.deleted_at = deleted_at
    project.deleted_by = user.id
    await db.commit()
    await audit.write(
        event_type="project_deleted",
        actor_user_id=user.id,
        target_project_id=project_id,
        details={
            "project_id": str(project_id),
            "code": project.code,
            "name": project.name,
            "deleted_by": str(user.id),
        },
        **ctx,
    )
    return {"ok": True, "project_id": str(project_id), "deleted_at": deleted_at}


@router.post("/{project_id}/restore")
async def restore_project(
    project_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
    audit: AuditService = Depends(get_audit),
    user: CurrentUser = Depends(require_project_deleter),
    ctx: dict = Depends(get_request_context),
) -> dict:
    """恢复逻辑删除的项目(F6.6 / D11)— 仅作用于 deleted_at 非空者;否则 404。"""
    project = await db.get(Project, project_id)
    if project is None or project.deleted_at is None:
        raise HTTPException(404, "project not found")
    project.deleted_at = None
    project.deleted_by = None
    await db.commit()
    await audit.write(
        event_type="project_restored",
        actor_user_id=user.id,
        target_project_id=project_id,
        details={
            "project_id": str(project_id),
            "code": project.code,
            "name": project.name,
            "restored_by": str(user.id),
        },
        **ctx,
    )
    return {"ok": True, "project_id": str(project_id)}


_PROJECT_ROLES: tuple[str, ...] = ("admin", "uploader", "downloader", "viewer")


async def _fill_my_roles(
    permissions: PermissionsService,
    user_subject: str,
    projects: list,
    *,
    is_system_admin: bool,
) -> dict[uuid.UUID, list[str]]:
    """每个 project 上 user 的有效 role list。

    系统 admin → 全 admin(超级权限)
    否则:1 次 list_objects/role(4 次总),N 个 project 走集合 lookup
    — O(1) FGA calls,避免 N×4 串行回路。
    """
    out: dict[uuid.UUID, list[str]] = {}
    if is_system_admin:
        for p in projects:
            out[p.id] = ["admin"]
        return out
    if not projects:
        return out

    role_lists = await asyncio.gather(*[
        permissions.list_objects(
            user_subject=user_subject, relation=role, object_type="project",
        )
        for role in _PROJECT_ROLES
    ])
    role_sets = {r: set(ids) for r, ids in zip(_PROJECT_ROLES, role_lists)}

    for p in projects:
        pid = str(p.id)
        out[p.id] = [r for r in _PROJECT_ROLES if pid in role_sets[r]]
    return out


@router.get("/{project_id}", response_model=ProjectOut)
async def get_project(
    project_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    audit: AuditService = Depends(get_audit),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
    ctx: dict = Depends(get_request_context),
) -> ProjectOut:
    user_id = user.id
    project = await db.get(Project, project_id)
    # F6.4:已删除项目对所有人(含 system admin 直访)一律 404(深隐藏)
    if not project or project.deleted_at is not None:
        raise HTTPException(404, "project not found")

    if not is_system_admin and project.visibility != "public":
        allowed = await permissions.check(
            user_subject=user.subject,
            relation="can_view",
            object_type="project",
            object_id=str(project_id),
        )
        if not allowed:
            await audit.write(
                event_type="access_denied",
                actor_user_id=user_id,
                target_project_id=project_id,
                details={"action": "get_project", "reason": "openfga can_view false"},
                **ctx,
            )
            raise HTTPException(403, "no permission to view project")

    po = ProjectOut.model_validate(project)
    admins_by_pid = await _fill_project_admins(db, permissions, [project])
    po.admins = admins_by_pid.get(project.id, [])
    my_roles_by_pid = await _fill_my_roles(
        permissions, user.subject, [project], is_system_admin=is_system_admin,
    )
    po.my_roles = my_roles_by_pid.get(project.id, [])
    return po


# ─── project members CRUD (D iter4) ──────────────────────────────────────────
PROJECT_ROLES = ("admin", "uploader", "downloader", "viewer")


async def _enforce_project_admin(
    permissions: PermissionsService, audit: AuditService,
    user_id: uuid.UUID, user_subject: str, project_id: uuid.UUID, action: str, ctx: dict,
    *, is_system_admin: bool = False,
) -> None:
    if is_system_admin:
        return  # 系统 admin 直通,所有项目都可管理
    ok = await permissions.check(
        user_subject=user_subject, relation="can_admin",
        object_type="project", object_id=str(project_id),
    )
    if not ok:
        await audit.write(
            event_type="access_denied", actor_user_id=user_id,
            target_project_id=project_id,
            details={"action": action, "reason": "openfga can_admin false"},
            **ctx,
        )
        raise HTTPException(403, "no admin permission on this project")


@router.get("/{project_id}/members")
async def list_project_members(
    project_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    audit: AuditService = Depends(get_audit),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
    ctx: dict = Depends(get_request_context),
) -> list[dict]:
    """project 成员列表 — D iter4 前端 ProjectMembersDrawer 用。

    返:[{subject, kind, subject_id, name, roles: [admin|viewer|downloader|uploader, ...]}]
    同一 subject 多 role 聚合。需 can_admin project。
    """
    user_id = user.id
    project = await db.get(Project, project_id)
    if project is None:
        raise HTTPException(404, "project not found")
    await _enforce_project_admin(
        permissions, audit, user_id, user.subject, project_id, "list_members", ctx,
        is_system_admin=is_system_admin,
    )

    # 翻页聚合 read(read_all_tuples,方案 §3.1 封装):OpenFGA read 单页有上限,
    # initial_grants 满额 + 默认模板直通后 50+ tuple 是现实场景,单页 read 会
    # 静默截断(成员列表丢人 / 丢补写角色)
    tuples = await permissions.read_all_tuples(
        object_type="project", object_id=str(project_id),
    )

    by_subject: dict[str, dict] = {}

    for t_user, t_rel, _t_obj in tuples:
        rel = t_rel
        if rel not in PROJECT_ROLES:
            continue
        subject = t_user
        kind, rest = subject.split(":", 1)
        sid = rest.rsplit("#", 1)[0]
        key = subject
        if key not in by_subject:
            by_subject[key] = {
                "subject": subject, "kind": kind, "subject_id": sid,
                "name": None, "roles": [],
            }
        by_subject[key]["roles"].append(rel)

    # 批量解析主体名称(user → users.name,group → groups.name;未命中走 id 兜底)
    names = await resolve_subject_names(db, list(by_subject.keys()))
    for m in by_subject.values():
        m["name"] = names[m["subject"]]["name"]

    members = list(by_subject.values())
    # 排序:admin 优先 → user 优先 → name
    role_rank = {"admin": 0, "uploader": 1, "downloader": 2, "viewer": 3}
    def rank(m: dict) -> tuple:
        top = min((role_rank.get(r, 9) for r in m["roles"]), default=9)
        kind_rank = 0 if m["kind"] == "user" else 1
        return (top, kind_rank, m["name"] or "")
    members.sort(key=rank)
    return members


@router.post("/{project_id}/members", status_code=204)
async def add_project_member(
    project_id: uuid.UUID,
    payload: dict,
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    audit: AuditService = Depends(get_audit),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
    ctx: dict = Depends(get_request_context),
) -> None:
    """加 project 成员。

    body: {
      user_id?: str | group_id?: str,  # 二选一(user_id = users.id UUID;#154:department 轴下线)
      role?: 'admin'|'viewer'|'downloader'|'uploader',   # 旧单角色(仍兼容)
      roles?: ['admin'|'viewer'|'downloader'|'uploader', ...]  # 一次授多角色
    }
    需 can_admin project。
    """
    user_id = user.id
    project = await db.get(Project, project_id)
    if project is None:
        raise HTTPException(404, "project not found")
    await _enforce_project_admin(
        permissions, audit, user_id, user.subject, project_id, "add_member", ctx,
        is_system_admin=is_system_admin,
    )

    # roles(多选,新)优先;旧单 role 字段继续兼容。
    # P2-1:先校验类型 —— 客户端误传字符串("admin")时 for 会按字符迭代,
    # 报出 ['a','d','m','i','n'] 这种费解文案,必须在语义校验前拦下。
    raw_roles = payload.get("roles")
    if raw_roles is not None and not isinstance(raw_roles, list):
        raise HTTPException(400, "roles 必须是数组")
    legacy_role = payload.get("role")
    raw_roles = raw_roles or ([legacy_role] if legacy_role else [])
    bad = [r for r in raw_roles if not isinstance(r, str) or r not in PROJECT_ROLES]
    if bad:
        raise HTTPException(400, f"role must be one of {PROJECT_ROLES}: got {bad}")
    if not raw_roles:
        raise HTTPException(400, "role(或 roles)必填")
    roles = [r for r in PROJECT_ROLES if r in set(raw_roles)]  # 去重 + 固定顺序

    provided = [
        ("user", payload.get("user_id")),
        ("group", payload.get("group_id")),
    ]
    chosen = [(k, v) for k, v in provided if v]
    if len(chosen) != 1:
        raise HTTPException(400, "must specify exactly one of user_id / group_id")
    subject_kind, subject_id = chosen[0]
    # 入口校验:user_id / group_id 必须是 UUID —— 封掉「任意字符串当 group 主体」
    # 的历史入口(存量 grp_editors 等);admin 允许 group(model v4: admin:
    # [user, group#member],fmt_subject('group', id) 天然合法),仅 department 不可达
    if not _is_uuid_str(str(subject_id)):
        raise HTTPException(400, f"{subject_kind}_id 必须是 UUID: got {subject_id!r}")

    # 存在性校验(与 create_project 的 initial_grants 前置校验同款语义):
    # 形状合法的随机 UUID 也会写出幽灵 tuple —— user 须存在且 is_active,
    # group 须存在,否则 400。
    subject_uuid = uuid.UUID(str(subject_id))
    if subject_kind == "user":
        from app.db.tables import User
        u = await db.get(User, subject_uuid)
        if u is None or not u.is_active:
            raise HTTPException(400, f"user_id 不存在或未启用:user {subject_id}")
    else:
        if await db.get(Group, subject_uuid) is None:
            raise HTTPException(400, f"group_id 不存在:group {subject_id}")

    from app.services.permissions import fmt_subject
    subject = fmt_subject(subject_kind, subject_id)  # type: ignore[arg-type]
    # 部分成功语义:重复(已存在)按幂等跳过;真错误中止 —— 此前角色已生效并留有
    # audit,客户端重试可幂等补齐(P2-2)。
    for role in roles:
        try:
            await permissions.add_project_subject(
                project_id=str(project_id), subject=subject, role=role,  # type: ignore[arg-type]
            )
        except Exception as e:
            # OpenFGA 重复 tuple —— 重复邀请 / 多角色部分重叠时终态已是管理员想要的,
            # 按幂等成功跳过;真错误继续抛(→ 500)
            if not is_already_exists_error(e):
                raise
            continue
        # 每个角色一条 audit:保持 project_member_added 单角色 detail 形状,
        # 下游按 event_type 过滤的查询不用改
        await audit.write(
            event_type="project_member_added",
            actor_user_id=user_id, target_project_id=project_id,
            details={"subject": subject, "role": role, "kind": subject_kind},
            **ctx,
        )


@router.delete("/{project_id}/members", status_code=204)
async def remove_project_member(
    project_id: uuid.UUID,
    subject: str = Query(..., description="完整 OpenFGA subject"),
    role: str = Query(..., pattern=r"^(admin|viewer|downloader|uploader)$"),
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    audit: AuditService = Depends(get_audit),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
    ctx: dict = Depends(get_request_context),
) -> None:
    user_id = user.id
    project = await db.get(Project, project_id)
    if project is None:
        raise HTTPException(404, "project not found")
    await _enforce_project_admin(
        permissions, audit, user_id, user.subject, project_id, "remove_member", ctx,
        is_system_admin=is_system_admin,
    )

    # 入口形态校验:subject 必须形如 user:<uuid> 或 group:<uuid>#member。
    # 放行任意串的话,客户端漏 #member 后缀时下面投影匹配不到该 tuple
    # → 204 假成功 + audit 记了 removed 但真实 tuple 残留(§1.2 配套入口校验)
    s_kind, _, s_rest = subject.partition(":")
    if s_kind == "user":
        subject_ok = _is_uuid_str(s_rest)
    elif s_kind == "group":
        subject_ok = s_rest.endswith("#member") and _is_uuid_str(
            s_rest.removesuffix("#member")
        )
    else:
        subject_ok = False
    if not subject_ok:
        raise HTTPException(400, "subject 必须形如 user:<uuid> 或 group:<uuid>#member")

    # admin 不变量(#106):不允许 admin 撤自己的 admin;且撤销后项目必须仍有
    # 幸存 admin —— 按幸存 tuple 的 leaf 投影计数:read 一次项目 admin tuples →
    # 剔除本次要撤的 subject → 幸存 user: tuple 的 id 加上幸存 group:<gid>#member
    # tuple 经组 member tuple 展开的 user 成员 id,幸存集为空才 409。
    # 不用「当前 leaf 集合 - 被撤主体贡献集」减法:组成员同时持有直授 admin(或
    # 另一 admin 组)时,减法会把差集错算成空,把本应 204 的撤销错杀成 409。
    # leaf 数据源一律 FGA tuple,不用 DB group_memberships:用户停用会撤全部
    # FGA tuple 但 DB 组成员行保留,按 DB 展开会计入幽灵 admin。
    if role == "admin":
        if subject == user.subject:
            raise HTTPException(
                409,
                "不允许撤销自己的项目管理员角色;请先邀请其他管理员,再让对方撤销你",
            )
        from openfga_sdk.models import ReadRequestTupleKey
        resp = await permissions._client.read(
            ReadRequestTupleKey(object=f"project:{project_id}")  # type: ignore[no-untyped-call]
        )
        survivor_leafs: set[str] = set()
        for t in resp.tuples:
            if t.key.relation != "admin" or t.key.user == subject:
                continue  # 非 admin relation / 本次要撤的那条 tuple
            s = t.key.user
            if s.startswith("user:"):
                survivor_leafs.add(s.split(":", 1)[1])
            elif s.startswith("group:"):
                gid = s.split(":", 1)[1].rsplit("#", 1)[0]
                # 只展开一层 user: 型 member(嵌套组/department#member 全库无写入路径)
                for member_user, _rel, _obj in await permissions.list_group_member_tuples(gid):
                    survivor_leafs.add(member_user.split(":", 1)[1])
            else:
                # 未知 kind 幸存 tuple(v3 时代/脚本直写残留):不计入幸存集,记 log 排查
                log.warning(
                    "remove_project_member: survivor admin tuple of unknown kind,"
                    " project=%s subject=%s", project_id, s,
                )
        if not survivor_leafs:
            raise HTTPException(
                409,
                "项目至少需要保留 1 个管理员;请先邀请其他管理员,再撤销当前管理员",
            )

    try:
        await permissions.remove_project_subject(
            project_id=str(project_id), subject=subject, role=role,  # type: ignore[arg-type]
        )
    except Exception as e:
        # stale 重复撤销(§1.2):被撤 subject 本就无该角色 tuple → 幂等 no-op,
        # 直接 204,不写 audit(没真删不该记 removed,与 add 侧「仅真正写入的
        # 记 audit」对称);其他异常(网络 / 5xx)照旧上抛 → 500
        if not is_not_exists_error(e):
            raise
        return

    await audit.write(
        event_type="project_member_removed",
        actor_user_id=user_id, target_project_id=project_id,
        details={"subject": subject, "role": role},
        **ctx,
    )


# ─── project 授权总览 + 撤回 (#138) ───────────────────────────────────────────
# 哪些 relation 可从本入口撤回(与 grant_overview 白名单对齐)
_GRANT_REVOKE_RELATIONS: dict[str, set[str]] = {
    "project": {"explicit_downloader"},
    "folder": {"explicit_viewer", "explicit_downloader", "explicit_uploader"},
    "sensitive_folder": {
        "invited_viewer", "invited_downloader",
        "explicit_invited_viewer", "explicit_invited_downloader",
    },
}


@router.get("/{project_id}/grants")
async def list_project_grants_endpoint(
    project_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    audit: AuditService = Depends(get_audit),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
    ctx: dict = Depends(get_request_context),
) -> list[dict]:
    """项目级授权总览(#138)— admin 运维入口。

    聚合 project + 项目下所有 folder / sensitive_folder 的 explicit / invited grant
    (临时带到期时间 + 永久),供 admin 查看"谁有授权"并撤回。
    members section 已显项目直接角色成员,本接口只列通过授权/邀请获得的 grant。
    asset 级临时下载不在此总览(数量级 + 维度)。需 can_admin project。
    返:[{subject, kind, subject_id, name, object_type, object_id, object_name,
         relation, level, permanent, expires_at?}]
    """
    user_id = user.id
    project = await db.get(Project, project_id)
    if project is None:
        raise HTTPException(404, "project not found")
    await _enforce_project_admin(
        permissions, audit, user_id, user.subject, project_id, "list_grants", ctx,
        is_system_admin=is_system_admin,
    )
    from app.services.grant_overview import list_project_grants
    return await list_project_grants(db, permissions, project_id)


@router.delete("/{project_id}/grants", status_code=204)
async def revoke_project_grant(
    project_id: uuid.UUID,
    object_type: str = Query(..., pattern=r"^(project|folder|sensitive_folder)$"),
    object_id: uuid.UUID = Query(..., description="grant 所在 object 的 id"),
    subject: str = Query(..., description="完整 OpenFGA subject"),
    relation: str = Query(..., description="grant relation,须在该 object_type 可撤回白名单内"),
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    audit: AuditService = Depends(get_audit),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
    ctx: dict = Depends(get_request_context),
) -> None:
    """撤回一条授权 grant(#138)。四元组 (object_type, object_id, subject, relation)
    与 list_project_grants 输出对齐;校验 object 属于本 project 防跨项目撤回。"""
    user_id = user.id
    project = await db.get(Project, project_id)
    if project is None:
        raise HTTPException(404, "project not found")
    await _enforce_project_admin(
        permissions, audit, user_id, user.subject, project_id, "revoke_grant", ctx,
        is_system_admin=is_system_admin,
    )

    if relation not in _GRANT_REVOKE_RELATIONS.get(object_type, set()):
        raise HTTPException(400, f"relation {relation!r} 不可对 {object_type} 撤回")

    # object 归属校验:必须属于本 project(防 admin 撤别项目的 grant)
    oid = str(object_id)
    if object_type == "project":
        if object_id != project_id:
            raise HTTPException(400, "object_id 与 project_id 不一致")
    else:
        from app.db.tables import Folder as _Folder
        f = await db.get(_Folder, object_id)
        if f is None or f.project_id != project_id:
            raise HTTPException(404, "folder 不属于本项目")
        if object_type == "sensitive_folder" and not f.is_sensitive:
            raise HTTPException(400, "该 folder 不是 sensitive_folder")
        if object_type == "folder" and f.is_sensitive:
            raise HTTPException(400, "该 folder 是 sensitive_folder")

    # 分发到对应 revoke 方法。陈旧 UI 撤一条已自然过期/已被撤的 grant → 返 404 而非 500
    try:
        if object_type == "project":
            if not subject.startswith("user:"):
                raise HTTPException(400, "project 级授权 subject 只能是 user")
            await permissions.revoke_explicit_download(
                user_id=subject.split(":", 1)[1], object_type="project", object_id=oid,
            )
        elif object_type == "folder":
            await permissions.revoke_folder_explicit_subject(
                folder_id=oid, subject=subject, kind=relation,  # type: ignore[arg-type]
            )
        else:  # sensitive_folder
            level = "downloader" if relation.endswith("downloader") else "viewer"
            permanent = relation.startswith("invited_")
            await permissions.revoke_sensitive_folder_invite(
                sensitive_folder_id=oid, subject=subject,
                level=level, permanent=permanent,  # type: ignore[arg-type]
            )
    except HTTPException:
        raise
    except Exception as e:  # noqa: BLE001
        if "not found" in str(e).lower() or "tuple" in str(e).lower():
            raise HTTPException(404, "该授权不存在或已撤回") from e
        raise

    await audit.write(
        event_type="grant_revoked",
        actor_user_id=user_id, target_project_id=project_id,
        details={
            "object_type": object_type, "object_id": oid,
            "subject": subject, "relation": relation,
        },
        **ctx,
    )
