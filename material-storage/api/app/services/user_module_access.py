"""用户模块访问判定(user-delegation,2026-11-15)— 唯一访问判定入口。

把「谁可以用管理后台用户模块」收敛为单一实现,防 directory.py 四端点
(GET /users、POST /users、GET /users/{id}、POST /users/{id}/reset-password)
各自手写口径漂移:

  - 系统 admin:default org 解析 + perms.is_org_admin(照 deps.require_system_admin
    的口径)→ 直通,allowed_group_ids 恒为空集(不限制);
  - 非 admin:一条 SQL join group_memberships 查 user_create_grants 目标组集合
    ——集合非空 = 被授权(granted),新建用户时 group_ids 必须 ⊆ 该集合(F7)。

不抛 HTTPException:granted 判定返回数据,403/422 的文案与错误码由路由层决定
(与 deps.require_* 守门在 dep 层抛 403 的惯例不同,本服务供「守门 + 数据过滤」
两用,调用方还要拿 allowed_group_ids 做列表过滤/建号校验)。
"""
from __future__ import annotations

import uuid
from dataclasses import dataclass

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.tables import GroupMembership, UserCreateGrant
from app.services.org import get_default_organization
from app.services.permissions import PermissionsService


@dataclass(frozen=True)
class UserModuleAccess:
    """resolve 结果:admin 直通(集合空但 granted);非 admin 按目标组集合判定。"""

    is_system_admin: bool
    # 非 admin = 授权目标组集合(新建用户 group_ids 的允许域);admin 恒为空集(不限制)
    allowed_group_ids: frozenset[uuid.UUID]

    @property
    def granted(self) -> bool:
        """是否开放用户模块:admin 直通;非 admin = 目标组集合非空(方案 D1)。"""
        return self.is_system_admin or bool(self.allowed_group_ids)


async def resolve_user_module_access(
    db: AsyncSession,
    permissions: PermissionsService,
    user_id: uuid.UUID,
) -> UserModuleAccess:
    """解析 user 的用户模块访问态(见模块 docstring;判定唯一入口,勿在路由复写)。"""
    org = await get_default_organization(db)
    if org is not None:
        _org_id, tenant_key = org
        if await permissions.is_org_admin(
            user_id=str(user_id), organization_tenant_key=tenant_key,
        ):
            return UserModuleAccess(is_system_admin=True, allowed_group_ids=frozenset())
    # 非 admin:一条 SQL 出目标组集合(B 组成员 ∩ 授权行;目标组被删由 FK CASCADE
    # 保证无孤儿行,无须再验存在)
    res = await db.execute(
        select(UserCreateGrant.target_group_id)
        .join(GroupMembership, GroupMembership.group_id == UserCreateGrant.group_id)
        .where(GroupMembership.user_id == user_id)
        .distinct()
    )
    allowed: frozenset[uuid.UUID] = frozenset(res.scalars().all())
    return UserModuleAccess(is_system_admin=False, allowed_group_ids=allowed)
