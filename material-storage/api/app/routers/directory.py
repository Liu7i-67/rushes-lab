"""directory router — 本地用户/组管理后台(ADR-0007 / issue #150)。

仅 system admin(require_system_admin)。成员变更复用 permissions.add_user_to_group /
remove_user_from_group 直接同步 OpenFGA tuple(不再经过飞书通讯录)。

endpoints:
  GET    /api/v1/admin/directory/users                      — 用户列表(分页 {items,total,limit,offset};+ q / is_active)
  POST   /api/v1/admin/directory/users                      — 创建用户(临时密码 + 可选 group_ids 同时入组)
  GET    /api/v1/admin/directory/users/{id}                 — 用户详情(基础字段 + 所属组 ids/names 同序)
  PATCH  /api/v1/admin/directory/users/{id}                 — 编辑用户(name/email/group_ids 全量同步,D3)
  POST   /api/v1/admin/directory/users/{id}/disable         — 禁用 = revoke_user_completely + is_active=false + audit
  POST   /api/v1/admin/directory/users/{id}/enable          — 启用(恢复 org 成员 tuple)
  POST   /api/v1/admin/directory/users/{id}/reset-password  — admin 重置密码(新临时密码)
  GET    /api/v1/admin/directory/groups                     — 组列表(+ q / limit / offset;creator/deleter flag 读回)
  POST   /api/v1/admin/directory/groups                     — 创建组(可置 can_create_project / can_delete_project)
  PATCH  /api/v1/admin/directory/groups/{id}                — 改组名 / 描述 / can_create_project / can_delete_project(tri-state)
  DELETE /api/v1/admin/directory/groups/{id}                — 删组(成员关系一并清)
  GET    /api/v1/admin/directory/groups/{id}/members        — 组内成员列表
  POST   /api/v1/admin/directory/groups/{id}/members        — 加成员(写 group_memberships + group#member tuple)
  DELETE /api/v1/admin/directory/groups/{id}/members/{user_id} — 移除成员
"""
from __future__ import annotations

import logging
import uuid
from datetime import UTC, datetime

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from openfga_sdk.client.models import ClientTuple, ClientWriteRequest
from pydantic import BaseModel, Field
from sqlalchemy import delete, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.session import get_db
from app.db.tables import Group, GroupMembership, User
from app.deps import CurrentUser, get_audit, get_permissions, require_system_admin
from app.models import (
    DirectoryUserDetailOut,
    DirectoryUserOut,
    DirectoryUsersPageOut,
    UserCreateIn,
    UserUpdateIn,
)
from app.services.audit import AuditService
from app.services.org import get_default_organization
from app.services.passwords import generate_temp_password, hash_password
from app.services.permissions import (
    PermissionsService,
    fmt_subject,
    is_already_exists_error,
)

log = logging.getLogger(__name__)
router = APIRouter()


# ─── users ────────────────────────────────────────────────────────────────────
# DirectoryUserOut / UserCreateIn / UserUpdateIn / DirectoryUserDetailOut /
# DirectoryUsersPageOut 集中定义在 app/models(B2);这里只留路由私有包装。
class UserCreateOut(DirectoryUserOut):
    temporary_password: str  # 只回显这一次,不落 audit / log


class UserResetPasswordOut(BaseModel):
    temporary_password: str


# ─── 组成员双写共享助手(F3 建用户入组 / F4 编辑用户同步,与组员接口完全一致)──────
async def _add_membership(
    *,
    db: AsyncSession,
    permissions: PermissionsService,
    audit: AuditService,
    request: Request,
    actor_user_id: uuid.UUID,
    group: Group,
    user: User,
    source: str | None = None,
) -> None:
    """加成员双写 + 审计:先 DB group_memberships 行提交,再 group#member tuple。

    与 POST groups/{id}/members 的写入段完全一致(tuple 失败随异常上抛);
    source 非空时审计 details 增 source(如 user_create)。
    """
    db.add(GroupMembership(group_id=group.id, user_id=user.id))
    await db.commit()
    await permissions.add_user_to_group(group_id=str(group.id), user_id=str(user.id))
    details: dict[str, object] = {
        "group_id": str(group.id), "group_name": group.name,
        "user_id": str(user.id), "username": user.username,
    }
    if source:
        details["source"] = source
    await audit.write(
        event_type="group_member_added",
        actor_user_id=actor_user_id,
        details=details,
        request_ip=request.client.host if request.client else None,
        user_agent=request.headers.get("user-agent"),
    )


async def _remove_membership(
    *,
    db: AsyncSession,
    permissions: PermissionsService,
    audit: AuditService,
    request: Request,
    actor_user_id: uuid.UUID,
    group: Group,
    user: User,
) -> None:
    """移除成员双写 + 审计:删 group_memberships 行提交,再删 group#member tuple。

    与 DELETE groups/{id}/members/{user_id} 的写入段完全一致。
    """
    await db.execute(
        delete(GroupMembership).where(
            GroupMembership.group_id == group.id,
            GroupMembership.user_id == user.id,
        )
    )
    await db.commit()
    await permissions.remove_user_from_group(group_id=str(group.id), user_id=str(user.id))
    await audit.write(
        event_type="group_member_removed",
        actor_user_id=actor_user_id,
        details={"group_id": str(group.id), "group_name": group.name,
                 "user_id": str(user.id), "username": user.username},
        request_ip=request.client.host if request.client else None,
        user_agent=request.headers.get("user-agent"),
    )


async def _load_groups_for_ids(
    db: AsyncSession, group_ids: list[uuid.UUID],
) -> tuple[list[uuid.UUID], dict[uuid.UUID, Group]]:
    """去重保序展开组 id;超 50(D9)或任一不存在 → 422 invalid_group_ids。

    F3.3/F4.3 原子性前置:调用方必须在任何落库前先走本校验。条数上限放
    路由层而非 Pydantic max_length —— 契约要求超限 422 detail 含
    invalid_group_ids,Pydantic 校验错误文案不带该标识。
    """
    want_ids = list(dict.fromkeys(group_ids))
    if len(want_ids) > 50:
        raise HTTPException(
            422, f"invalid_group_ids:group_ids 超上限 50(实际 {len(want_ids)})",
        )
    res = await db.execute(select(Group).where(Group.id.in_(want_ids)))
    found = {g.id: g for g in res.scalars().all()}
    invalid = [gid for gid in want_ids if gid not in found]
    if invalid:
        raise HTTPException(422, f"invalid_group_ids:{','.join(str(g) for g in invalid)}")
    return want_ids, found


@router.get("/users", response_model=DirectoryUsersPageOut)
async def list_directory_users(
    q: str = Query("", description="username / name / email 模糊"),
    is_active: bool | None = Query(None),
    limit: int = Query(20, ge=1, le=200),
    offset: int = Query(0, ge=0),
    db: AsyncSession = Depends(get_db),
    user: CurrentUser = Depends(require_system_admin),
) -> DirectoryUsersPageOut:
    """用户列表分页(F5/D4/D5):total=同条件(q/is_active)count,不含 limit/offset。"""
    _ = user.id
    term = q.strip()
    conds = []
    if term:
        like = f"%{term}%"
        conds.append(or_(
            User.username.ilike(like),
            User.name.ilike(like),
            User.email.ilike(like),
        ))
    if is_active is not None:
        conds.append(User.is_active.is_(is_active))
    count_stmt = select(func.count()).select_from(User)
    stmt = select(User)
    if conds:
        count_stmt = count_stmt.where(*conds)
        stmt = stmt.where(*conds)
    total = (await db.execute(count_stmt)).scalar_one()
    stmt = stmt.order_by(User.created_at.desc()).limit(limit).offset(offset)
    res = await db.execute(stmt)
    return DirectoryUsersPageOut(
        items=[
            DirectoryUserOut(
                id=u.id, username=u.username, name=u.name, email=u.email,
                is_active=u.is_active, must_change_password=u.must_change_password,
                created_at=u.created_at, resigned_at=u.resigned_at,
            )
            for u in res.scalars().all()
        ],
        total=total, limit=limit, offset=offset,
    )


@router.post("/users", response_model=UserCreateOut, status_code=201)
async def create_directory_user(
    payload: UserCreateIn,
    request: Request,
    db: AsyncSession = Depends(get_db),
    user: CurrentUser = Depends(require_system_admin),
    permissions: PermissionsService = Depends(get_permissions),
    audit: AuditService = Depends(get_audit),
) -> UserCreateOut:
    """创建本地用户:生成临时密码 + must_change_password=true(P1 首登强制改密)。

    临时密码只在响应里回显一次,不写 audit / log。
    F3:group_ids 先全量校验(任一无效 422,用户不创建,F3.3 原子),创建成功后
    逐组走与 POST groups/{id}/members 完全一致的双写 + 审计(source=user_create)。
    """
    _ = request, user.id
    dup = await db.execute(select(User).where(User.username == payload.username))
    if dup.scalar_one_or_none() is not None:
        raise HTTPException(409, f"登录名已存在:{payload.username}")

    # F3.3 原子性:用户落库前先全量校验组存在
    want_ids, groups = await _load_groups_for_ids(db, payload.group_ids)

    # 新用户绑默认组织(老飞书用户 organization_id 的等价物)
    org = await get_default_organization(db)
    org_id = org[0] if org else None

    temp_pw = generate_temp_password()
    new_user = User(
        username=payload.username,
        name=payload.name,
        email=payload.email or None,
        password_hash=hash_password(temp_pw),
        must_change_password=True,
        is_active=True,
        organization_id=org_id,
    )
    db.add(new_user)
    await db.commit()
    await db.refresh(new_user)

    if org:
        _, tenant_key = org
        try:
            await permissions.add_user_to_organization(
                organization_tenant_key=tenant_key, user_id=str(new_user.id),
            )
        except Exception as e:
            log.warning("create user org member tuple fail user=%s err=%s", new_user.id, e)

    # F3:逐组入组(按入参顺序;每组各自审计 group_member_added)
    for gid in want_ids:
        await _add_membership(
            db=db, permissions=permissions, audit=audit, request=request,
            actor_user_id=user.id, group=groups[gid], user=new_user,
            source="user_create",
        )

    await audit.write(
        event_type="user_created",
        actor_user_id=user.id,
        details={"user_id": str(new_user.id), "username": payload.username,
                 "name": payload.name, "group_ids": [str(g) for g in want_ids]},
        request_ip=request.client.host if request.client else None,
        user_agent=request.headers.get("user-agent"),
    )
    log.info("user created id=%s username=%s by admin=%s groups=%d",
             new_user.id, payload.username, user.id, len(want_ids))
    return UserCreateOut(
        id=new_user.id, username=new_user.username, name=new_user.name,
        email=new_user.email, is_active=True, must_change_password=True,
        created_at=new_user.created_at, resigned_at=None,
        temporary_password=temp_pw,
    )


@router.get("/users/{user_id}", response_model=DirectoryUserDetailOut)
async def get_directory_user(
    user_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
    user: CurrentUser = Depends(require_system_admin),
) -> DirectoryUserDetailOut:
    """用户详情(§2):基础字段 + 所属组(group_names 与 group_ids 同序,按组名排序)。"""
    _ = user.id
    target = await db.get(User, user_id)
    if target is None:
        raise HTTPException(404, f"user_not_found:{user_id}")
    res = await db.execute(
        select(GroupMembership, Group)
        .join(Group, Group.id == GroupMembership.group_id)
        .where(GroupMembership.user_id == user_id)
        .order_by(Group.name)
    )
    rows = res.all()
    return DirectoryUserDetailOut(
        id=target.id, username=target.username, name=target.name,
        email=target.email, is_active=target.is_active,
        must_change_password=target.must_change_password,
        created_at=target.created_at, resigned_at=target.resigned_at,
        group_ids=[g.id for _gm, g in rows],
        group_names=[g.name for _gm, g in rows],
    )


@router.patch("/users/{user_id}", response_model=DirectoryUserOut)
async def update_directory_user(
    user_id: uuid.UUID,
    payload: UserUpdateIn,
    request: Request,
    db: AsyncSession = Depends(get_db),
    user: CurrentUser = Depends(require_system_admin),
    permissions: PermissionsService = Depends(get_permissions),
    audit: AuditService = Depends(get_audit),
) -> DirectoryUserOut:
    """编辑用户(§3/D3):name / email 原值更新 + group_ids 全量同步 diff。

    先校验(用户存在 / 组 id 全存在,任一无效 422 且不变更)→ name/email 落库
    → 组 diff:added 走加成员双写、removed 走移成员双写(各记成员审计);
    总审计 user_updated(details.changes 含 old/new)。
    """
    target = await db.get(User, user_id)
    if target is None:
        raise HTTPException(404, f"user_not_found:{user_id}")

    # F4.3 原子性:组 id 全量预校验,任一无效 → 422,不做任何变更
    want_ids: list[uuid.UUID] | None = None
    groups: dict[uuid.UUID, Group] = {}
    if payload.group_ids is not None:
        want_ids, groups = await _load_groups_for_ids(db, payload.group_ids)

    # name / email:email 显式 null=清空(D6),以 model_fields_set 区分「未传」
    changes: dict[str, object] = {}
    if payload.name is not None and payload.name != target.name:
        changes["name"] = {"old": target.name, "new": payload.name}
        target.name = payload.name
    if "email" in payload.model_fields_set and payload.email != target.email:
        changes["email"] = {"old": target.email, "new": payload.email}
        target.email = payload.email
    await db.commit()

    # D3 全量同步:以 group_memberships 现状为基线 diff(added 按入参序)
    groups_added: list[dict[str, str]] = []
    groups_removed: list[dict[str, str]] = []
    if want_ids is not None:
        res = await db.execute(
            select(GroupMembership, Group)
            .join(Group, Group.id == GroupMembership.group_id)
            .where(GroupMembership.user_id == user_id)
        )
        current: dict[uuid.UUID, Group] = {gm.group_id: g for gm, g in res.all()}
        want_set = set(want_ids)
        for gid in want_ids:
            if gid in current:
                continue
            await _add_membership(
                db=db, permissions=permissions, audit=audit, request=request,
                actor_user_id=user.id, group=groups[gid], user=target,
            )
            groups_added.append({"group_id": str(gid), "group_name": groups[gid].name})
        for gid, g in current.items():
            if gid in want_set:
                continue
            await _remove_membership(
                db=db, permissions=permissions, audit=audit, request=request,
                actor_user_id=user.id, group=g, user=target,
            )
            groups_removed.append({"group_id": str(gid), "group_name": g.name})

    changes["groups_added"] = groups_added
    changes["groups_removed"] = groups_removed
    await audit.write(
        event_type="user_updated",
        actor_user_id=user.id,
        details={"user_id": str(user_id), "username": target.username, "changes": changes},
        request_ip=request.client.host if request.client else None,
        user_agent=request.headers.get("user-agent"),
    )
    log.info("user updated id=%s by admin=%s added=%d removed=%d",
             user_id, user.id, len(groups_added), len(groups_removed))
    return DirectoryUserOut(
        id=target.id, username=target.username, name=target.name,
        email=target.email, is_active=target.is_active,
        must_change_password=target.must_change_password,
        created_at=target.created_at, resigned_at=target.resigned_at,
    )


async def _get_active_user(db: AsyncSession, user_id: uuid.UUID, what: str) -> User:
    u = await db.get(User, user_id)
    if u is None:
        raise HTTPException(404, f"user not found:{user_id}")
    if not u.is_active and what != "enable":
        raise HTTPException(409, "用户已禁用,先启用再操作")
    return u


@router.post("/users/{user_id}/disable")
async def disable_directory_user(
    user_id: uuid.UUID,
    request: Request,
    db: AsyncSession = Depends(get_db),
    user: CurrentUser = Depends(require_system_admin),
    permissions: PermissionsService = Depends(get_permissions),
    audit: AuditService = Depends(get_audit),
) -> dict[str, object]:
    """禁用(离职=手动禁用):revoke_user_completely 撤全部 tuple + is_active=false + audit。"""
    target = await db.get(User, user_id)
    if target is None:
        raise HTTPException(404, f"user not found:{user_id}")
    if not target.is_active:
        raise HTTPException(409, "用户已处于禁用状态")

    n = await permissions.revoke_user_completely(str(user_id))
    target.is_active = False
    target.resigned_at = datetime.now(UTC)
    await db.commit()

    await audit.write(
        event_type="user_disabled",
        actor_user_id=user.id,
        details={"user_id": str(user_id), "username": target.username,
                 "name": target.name, "tuples_revoked": n},
        request_ip=request.client.host if request.client else None,
        user_agent=request.headers.get("user-agent"),
    )
    log.info("user disabled id=%s by admin=%s tuples_revoked=%d", user_id, user.id, n)
    return {"ok": True, "user_id": str(user_id), "tuples_revoked": n}


@router.post("/users/{user_id}/enable")
async def enable_directory_user(
    user_id: uuid.UUID,
    request: Request,
    db: AsyncSession = Depends(get_db),
    user: CurrentUser = Depends(require_system_admin),
    permissions: PermissionsService = Depends(get_permissions),
    audit: AuditService = Depends(get_audit),
) -> dict[str, object]:
    """启用:is_active=true + 恢复组织成员 tuple + 按 group_memberships 重建组 tuple(F6)。

    禁用时 revoke_user_completely 撤掉了全部 tuple(含 group#member),但
    group_memberships 表行保留 —— 启用必须逐条重建,否则 UI 显示还在组里、
    OpenFGA 里没有 tuple,组带来的项目权限静默失效。
    """
    target = await db.get(User, user_id)
    if target is None:
        raise HTTPException(404, f"user not found:{user_id}")
    if target.is_active:
        raise HTTPException(409, "用户已是启用状态")

    target.is_active = True
    target.resigned_at = None
    await db.commit()

    org = await get_default_organization(db)
    if org:
        _, tenant_key = org
        try:
            await permissions.add_user_to_organization(
                organization_tenant_key=tenant_key, user_id=str(user_id),
            )
        except Exception as e:
            log.warning("enable user org member tuple fail user=%s err=%s", user_id, e)

    # 重建组内成员 tuple(F6:disable 时被撤,DB 行保留)
    gm_res = await db.execute(
        select(GroupMembership).where(GroupMembership.user_id == user_id)
    )
    groups_restored = 0
    for gm in gm_res.scalars().all():
        try:
            await permissions.add_user_to_group(
                group_id=str(gm.group_id), user_id=str(user_id),
            )
            groups_restored += 1
        except Exception as e:
            log.warning(
                "enable user group tuple fail user=%s group=%s err=%s",
                user_id, gm.group_id, e,
            )

    await audit.write(
        event_type="user_enabled",
        actor_user_id=user.id,
        details={
            "user_id": str(user_id), "username": target.username, "name": target.name,
            "groups_restored": groups_restored,
        },
        request_ip=request.client.host if request.client else None,
        user_agent=request.headers.get("user-agent"),
    )
    log.info("user enabled id=%s by admin=%s groups_restored=%d",
             user_id, user.id, groups_restored)
    return {"ok": True, "user_id": str(user_id), "groups_restored": groups_restored}


@router.post("/users/{user_id}/reset-password", response_model=UserResetPasswordOut)
async def reset_directory_user_password(
    user_id: uuid.UUID,
    request: Request,
    db: AsyncSession = Depends(get_db),
    user: CurrentUser = Depends(require_system_admin),
    audit: AuditService = Depends(get_audit),
) -> UserResetPasswordOut:
    """admin 重置密码:新临时密码 + must_change_password=true(不留改密能力给普通流程)。"""
    target = await _get_active_user(db, user_id, "reset")
    temp_pw = generate_temp_password()
    target.password_hash = hash_password(temp_pw)
    target.must_change_password = True
    await db.commit()

    await audit.write(
        event_type="user_password_reset",
        actor_user_id=user.id,
        details={"user_id": str(user_id), "username": target.username, "name": target.name},
        request_ip=request.client.host if request.client else None,
        user_agent=request.headers.get("user-agent"),
    )
    log.info("password reset user=%s by admin=%s", user_id, user.id)
    return UserResetPasswordOut(temporary_password=temp_pw)


# ─── groups ───────────────────────────────────────────────────────────────────
class DirectoryGroupOut(BaseModel):
    id: uuid.UUID
    name: str
    description: str | None
    member_count: int
    created_at: datetime
    # 组级「新建项目」权限(方案 §2.2):读接口按 FGA tuple 真实态回显;
    # create/update 响应按入参 flag 回填(真实态以列表刷新为准)
    can_create_project: bool = False
    # F6.2:组级「删除项目」开关,语义与 can_create_project 完全一致
    can_delete_project: bool = False


class GroupCreateIn(BaseModel):
    name: str = Field(..., min_length=1, max_length=128)
    description: str | None = Field(None, max_length=1024)
    # 置位 = 写 organization#project_creator 的 group:<gid>#member tuple
    can_create_project: bool = False
    # F6.2:置位 = 写 organization#project_deleter 的 group:<gid>#member tuple
    can_delete_project: bool = False


class GroupUpdateIn(BaseModel):
    # tri-state(方案 §2.2):None(缺省)= 不动 —— PATCH 惯例是省略即不动,
    # 非 Optional 布尔会让仅改名的不带字段 PATCH 解析成 False **静默撤权**;
    # true = 写 tuple / false = 删 tuple
    name: str | None = Field(None, min_length=1, max_length=128)
    description: str | None = Field(None, max_length=1024)
    can_create_project: bool | None = None
    # F6.2:tri-state 同 can_create_project(None=不动 / true=写 / false=删)
    can_delete_project: bool | None = None


class GroupMemberOut(BaseModel):
    user_id: uuid.UUID
    username: str | None
    name: str
    email: str | None
    is_active: bool


class GroupMemberAddIn(BaseModel):
    user_id: uuid.UUID


# ─── 组级「新建/删除项目」flag ↔ FGA tuple(方案 §2.2 / F6.2)──────────────────
async def _read_flag_group_ids(
    permissions: PermissionsService,
    db: AsyncSession,
    relation: str,
) -> set[uuid.UUID]:
    """定向 read default org 上指定 relation(project_creator / project_deleter)置位组 id 集合。

    **必须带 relation 过滤**:不带 relation 的全量 read 撞 OpenFGA read 单页上限
    (organization 上每个启用用户一条 #member tuple,百人级单页必漏);
    置位组量小单页即回。FGA 异常尽力而为 → 空集 + log,组列表照常返回
    (管理员见「开着却显示关」重试 PATCH 即补写)。
    """
    org = await get_default_organization(db)
    if org is None:
        log.warning("read %s tuples skipped:no default org", relation)
        return set()
    _, tenant_key = org
    try:
        tuples = await permissions.read_all_tuples(
            object_type="organization", object_id=tenant_key, relation=relation,
        )
    except Exception as e:  # noqa: BLE001
        log.warning("read %s tuples fail err=%s", relation, e)
        return set()
    out: set[uuid.UUID] = set()
    for t_user, _t_rel, _t_obj in tuples:
        # UI 只写组主体;user 直授留口(方案 §6)本期无写入路径,防御性跳过
        if not t_user.startswith("group:"):
            continue
        gid = t_user.split(":", 1)[1].rsplit("#", 1)[0]
        try:
            out.add(uuid.UUID(gid))
        except ValueError:
            continue
    return out


async def _sync_group_org_flag(
    permissions: PermissionsService,
    db: AsyncSession,
    group_id: uuid.UUID,
    *,
    relation: str,
    enable: bool,
) -> None:
    """组 flag → organization:<tenant> 上 group:<gid>#member tuple 写/删(泛化版)。

    relation=project_creator(§2.2)/ project_deleter(F6.2;FGA 模型里的
    deleter relation 由并行任务在 store.fga.yaml 添加,本路由只按既有 tuple
    格式写入/删除)。尽力而为,不 500(先例 create_directory_user 的 org
    member tuple):flag 读回展示的是真实 tuple 状态,写失败仅 log.warning,
    管理员重试 PATCH 即补写。tuple 读写一律走 PermissionsService 小方法,
    路由不摸 _client。
    """
    org = await get_default_organization(db)
    if org is None:
        log.warning("group %s sync skipped:no default org group=%s", relation, group_id)
        return
    _, tenant_key = org
    subject = fmt_subject("group", str(group_id))
    try:
        if enable:
            await permissions.add_org_relation(
                organization_tenant_key=tenant_key,
                subject=subject,
                relation=relation,
            )
        else:
            # remove_org_relation 内部吞 is_not_exists_error:重复清除幂等
            await permissions.remove_org_relation(
                organization_tenant_key=tenant_key,
                subject=subject,
                relation=relation,
            )
    except Exception as e:  # noqa: BLE001
        if enable and is_already_exists_error(e):
            return  # 重复置位(如 true→true 的 PATCH),幂等成功
        log.warning(
            "group %s tuple sync fail group=%s enable=%s err=%s",
            relation, group_id, enable, e,
        )


@router.get("/groups", response_model=list[DirectoryGroupOut])
async def list_directory_groups(
    q: str = Query("", description="name / description 模糊"),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    db: AsyncSession = Depends(get_db),
    user: CurrentUser = Depends(require_system_admin),
    permissions: PermissionsService = Depends(get_permissions),
) -> list[DirectoryGroupOut]:
    """组列表(带成员数)+ creator/deleter flag 读回(定向 read,§2.2/F6.2)。

    编辑弹窗数据来自列表行(无组详情路由),flag 按 FGA tuple 真实态回显;
    read 异常时尽力而为回 False,不阻塞列表。
    """
    _ = user.id
    term = q.strip()
    where = None
    if term:
        like = f"%{term}%"
        where = (func.lower(Group.name).like(func.lower(like))
                 | func.lower(func.coalesce(Group.description, "")).like(func.lower(like)))
    count = func.count(GroupMembership.user_id)
    stmt = (
        select(Group, count)
        .outerjoin(GroupMembership, GroupMembership.group_id == Group.id)
        .group_by(Group.id)
        .order_by(Group.created_at.desc())
        .limit(limit).offset(offset)
    )
    if where is not None:
        stmt = stmt.where(where)
    res = await db.execute(stmt)
    rows = list(res.all())
    creator_ids = await _read_flag_group_ids(permissions, db, "project_creator")
    deleter_ids = await _read_flag_group_ids(permissions, db, "project_deleter")
    return [
        DirectoryGroupOut(
            id=g.id, name=g.name, description=g.description,
            member_count=cnt, created_at=g.created_at,
            can_create_project=g.id in creator_ids,
            can_delete_project=g.id in deleter_ids,
        )
        for g, cnt in rows
    ]


@router.post("/groups", response_model=DirectoryGroupOut, status_code=201)
async def create_directory_group(
    payload: GroupCreateIn,
    request: Request,
    db: AsyncSession = Depends(get_db),
    user: CurrentUser = Depends(require_system_admin),
    permissions: PermissionsService = Depends(get_permissions),
    audit: AuditService = Depends(get_audit),
) -> DirectoryGroupOut:
    """创建本地组(name unique);置位 flag 时写对应 org tuple(尽力而为,§2.2/F6.2)。"""
    dup = await db.execute(select(Group).where(Group.name == payload.name))
    if dup.scalar_one_or_none() is not None:
        raise HTTPException(409, f"组名已存在:{payload.name}")
    g = Group(name=payload.name, description=payload.description or None)
    db.add(g)
    await db.commit()
    await db.refresh(g)
    # tuple 写在 DB 提交后,尽力而为不 500(方案 §2.2;响应按入参 flag 回填,
    # 真实态以列表刷新为准)
    if payload.can_create_project:
        await _sync_group_org_flag(
            permissions, db, g.id, relation="project_creator", enable=True,
        )
    if payload.can_delete_project:
        await _sync_group_org_flag(
            permissions, db, g.id, relation="project_deleter", enable=True,
        )
    await audit.write(
        event_type="group_created",
        actor_user_id=user.id,
        details={"group_id": str(g.id), "name": g.name,
                 "can_create_project": payload.can_create_project,
                 "can_delete_project": payload.can_delete_project},
        request_ip=request.client.host if request.client else None,
        user_agent=request.headers.get("user-agent"),
    )
    log.info("group created id=%s name=%s by admin=%s creator=%s deleter=%s",
             g.id, g.name, user.id, payload.can_create_project,
             payload.can_delete_project)
    return DirectoryGroupOut(
        id=g.id, name=g.name, description=g.description,
        member_count=0, created_at=g.created_at,
        can_create_project=payload.can_create_project,
        can_delete_project=payload.can_delete_project,
    )


@router.patch("/groups/{group_id}", response_model=DirectoryGroupOut)
async def update_directory_group(
    group_id: uuid.UUID,
    payload: GroupUpdateIn,
    request: Request,
    db: AsyncSession = Depends(get_db),
    user: CurrentUser = Depends(require_system_admin),
    permissions: PermissionsService = Depends(get_permissions),
    audit: AuditService = Depends(get_audit),
) -> DirectoryGroupOut:
    """改组名 / 描述;can_create_project / can_delete_project tri-state(None=不动 / true=写 / false=删)。"""
    g = await db.get(Group, group_id)
    if g is None:
        raise HTTPException(404, f"group not found:{group_id}")
    if payload.name is not None and payload.name != g.name:
        dup = await db.execute(select(Group).where(Group.name == payload.name))
        if dup.scalar_one_or_none() is not None:
            raise HTTPException(409, f"组名已存在:{payload.name}")
        g.name = payload.name
    if payload.description is not None:
        g.description = payload.description or None
    await db.commit()
    await db.refresh(g)
    # tri-state:仅改名的不带字段 PATCH(None)→ tuple 不动,防静默撤权(§2.2)
    if payload.can_create_project is not None:
        await _sync_group_org_flag(
            permissions, db, group_id, relation="project_creator",
            enable=payload.can_create_project,
        )
    # F6.2:deleter 同款 tri-state;审计要 {old,new},先读写前真实态
    deleter_old: bool | None = None
    if payload.can_delete_project is not None:
        deleter_old = group_id in await _read_flag_group_ids(permissions, db, "project_deleter")
        await _sync_group_org_flag(
            permissions, db, group_id, relation="project_deleter",
            enable=payload.can_delete_project,
        )
    details: dict[str, object] = {"group_id": str(group_id), "name": g.name}
    if payload.can_create_project is not None:
        details["can_create_project"] = payload.can_create_project
    if payload.can_delete_project is not None and payload.can_delete_project != deleter_old:
        details["can_delete_project"] = {"old": deleter_old,
                                         "new": payload.can_delete_project}
    await audit.write(
        event_type="group_updated",
        actor_user_id=user.id,
        details=details,
        request_ip=request.client.host if request.client else None,
        user_agent=request.headers.get("user-agent"),
    )
    # 响应 flag:入参带了按入参回填;没带(None = 不动)定向 read 真实态,
    # 免得仅改名 PATCH 的响应把已置位 flag 谎报成 False
    if payload.can_create_project is not None:
        out_creator = payload.can_create_project
    else:
        out_creator = group_id in await _read_flag_group_ids(permissions, db, "project_creator")
    if payload.can_delete_project is not None:
        out_deleter = payload.can_delete_project
    else:
        out_deleter = group_id in await _read_flag_group_ids(permissions, db, "project_deleter")
    cnt = (await db.execute(
        select(func.count()).select_from(GroupMembership)
        .where(GroupMembership.group_id == group_id)
    )).scalar_one()
    return DirectoryGroupOut(
        id=g.id, name=g.name, description=g.description,
        member_count=cnt, created_at=g.created_at,
        can_create_project=out_creator,
        can_delete_project=out_deleter,
    )


@router.delete("/groups/{group_id}")
async def delete_directory_group(
    group_id: uuid.UUID,
    request: Request,
    db: AsyncSession = Depends(get_db),
    user: CurrentUser = Depends(require_system_admin),
    permissions: PermissionsService = Depends(get_permissions),
    audit: AuditService = Depends(get_audit),
) -> dict[str, object]:
    """删组:清 group_memberships + group#member tuple。

    组作为 subject 出现在 project/folder 上的引用(group:<id>#member)按
    department 处理惯例(ADR-0007:存量 tuple 保留原样)不回收。
    """
    g = await db.get(Group, group_id)
    if g is None:
        raise HTTPException(404, f"group not found:{group_id}")
    name = g.name

    # 顺手删 organization 上组级 flag tuple(project_creator / project_deleter,
    # §2.2/F6.2;尽力而为,remove_org_relation 幂等吞 not_exists,组本就未置位
    # 时静默 no-op)
    try:
        org = await get_default_organization(db)
        if org:
            _, tenant_key = org
            subject = fmt_subject("group", str(group_id))
            for relation in ("project_creator", "project_deleter"):
                await permissions.remove_org_relation(
                    organization_tenant_key=tenant_key,
                    subject=subject,
                    relation=relation,
                )
    except Exception as e:  # noqa: BLE001
        log.warning("delete group org flag tuple fail group=%s err=%s", group_id, e)

    # OpenFGA member tuples(尽力而为,不阻塞 DB 删除)
    try:
        tuples = await permissions.list_group_member_tuples(str(group_id))
        for t_user, t_rel, t_obj in tuples:
            try:
                await permissions._client.write(
                    ClientWriteRequest(
                        deletes=[ClientTuple(user=t_user, relation=t_rel, object=t_obj)]
                    )
                )
            except Exception:
                log.debug("group tuple delete tolerate %s %s %s", t_user, t_rel, t_obj)
    except Exception as e:
        log.warning("delete group tuple cleanup fail group=%s err=%s", group_id, e)

    await db.execute(delete(GroupMembership).where(GroupMembership.group_id == group_id))
    await db.delete(g)
    await db.commit()
    await audit.write(
        event_type="group_deleted",
        actor_user_id=user.id,
        details={"group_id": str(group_id), "name": name},
        request_ip=request.client.host if request.client else None,
        user_agent=request.headers.get("user-agent"),
    )
    log.info("group deleted id=%s name=%s by admin=%s", group_id, name, user.id)
    return {"ok": True, "group_id": str(group_id)}


@router.get("/groups/{group_id}/members", response_model=list[GroupMemberOut])
async def list_group_members(
    group_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
    user: CurrentUser = Depends(require_system_admin),
) -> list[GroupMemberOut]:
    """组内成员列表。"""
    _ = user.id
    g = await db.get(Group, group_id)
    if g is None:
        raise HTTPException(404, f"group not found:{group_id}")
    stmt = (
        select(User)
        .join(GroupMembership, GroupMembership.user_id == User.id)
        .where(GroupMembership.group_id == group_id)
        .order_by(User.name)
    )
    res = await db.execute(stmt)
    return [
        GroupMemberOut(
            user_id=u.id, username=u.username, name=u.name,
            email=u.email, is_active=u.is_active,
        )
        for u in res.scalars().all()
    ]


@router.post("/groups/{group_id}/members", response_model=GroupMemberOut, status_code=201)
async def add_group_member(
    group_id: uuid.UUID,
    payload: GroupMemberAddIn,
    request: Request,
    db: AsyncSession = Depends(get_db),
    user: CurrentUser = Depends(require_system_admin),
    permissions: PermissionsService = Depends(get_permissions),
    audit: AuditService = Depends(get_audit),
) -> GroupMemberOut:
    """加成员:写 group_memberships 行 + group:<id>#member tuple(立即生效)。"""
    g = await db.get(Group, group_id)
    if g is None:
        raise HTTPException(404, f"group not found:{group_id}")
    target = await db.get(User, payload.user_id)
    if target is None:
        raise HTTPException(404, f"user not found:{payload.user_id}")
    if not target.is_active:
        raise HTTPException(400, "用户已禁用,不能加入组")

    exists = await db.execute(
        select(GroupMembership).where(
            GroupMembership.group_id == group_id,
            GroupMembership.user_id == payload.user_id,
        )
    )
    if exists.scalar_one_or_none() is not None:
        raise HTTPException(409, "用户已在组中")

    await _add_membership(
        db=db, permissions=permissions, audit=audit, request=request,
        actor_user_id=user.id, group=g, user=target,
    )
    log.info("group member added group=%s user=%s by admin=%s",
             group_id, payload.user_id, user.id)
    return GroupMemberOut(
        user_id=target.id, username=target.username, name=target.name,
        email=target.email, is_active=target.is_active,
    )


@router.delete("/groups/{group_id}/members/{user_id}")
async def remove_group_member(
    group_id: uuid.UUID,
    user_id: uuid.UUID,
    request: Request,
    db: AsyncSession = Depends(get_db),
    user: CurrentUser = Depends(require_system_admin),
    permissions: PermissionsService = Depends(get_permissions),
    audit: AuditService = Depends(get_audit),
) -> dict[str, object]:
    """移除成员:删 group_memberships 行 + group:<id>#member tuple。"""
    g = await db.get(Group, group_id)
    if g is None:
        raise HTTPException(404, f"group not found:{group_id}")
    exists = await db.execute(
        select(GroupMembership).where(
            GroupMembership.group_id == group_id,
            GroupMembership.user_id == user_id,
        )
    )
    if exists.scalar_one_or_none() is None:
        raise HTTPException(404, "用户不在组中")

    target = await db.get(User, user_id)
    await _remove_membership(
        db=db, permissions=permissions, audit=audit, request=request,
        actor_user_id=user.id, group=g, user=target,
    )
    log.info("group member removed group=%s user=%s by admin=%s",
             group_id, user_id, user.id)
    return {"ok": True, "group_id": str(group_id), "user_id": str(user_id)}
