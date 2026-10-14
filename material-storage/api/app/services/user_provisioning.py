"""本地用户开通共享服务(艺人账号内嵌方案 B4/D6)。

建号/入组/审计这段逻辑抽成单一实现,防 admin 建号与组长内嵌建号两处漂移
(密码策略改一处漏一处):

  - provision_local_user(...)      — 重名预检 → 临时密码 → 哈希 → User 落库 →
                                     org member tuple(尽力而为)→ 逐组入组 →
                                     user_created 审计 → ops 日志
  - add_user_to_group_audited(...) — 原 directory.py 私有 _add_membership 平移为
                                     公共函数,逻辑逐行不变(ip/ua 取法由
                                     request: Request 改 ctx: dict)

**services 层首例 HTTPException**:现状 app/services/ 无抛 HTTPException 先例,
provision_local_user 的重名预检 409 有意在此引入(平移保行为的最低成本路径,
优于「领域异常 + 路由转换」的双层样板)。

audit source 双参数语义(方案 D7,防实现把单值直通造成 admin 链路 source 静默
从 user_create 漂移):
  - source            — 落 user_created details.source(admin 链路 "admin_create" /
                        内嵌链路 "project_artist_inline")
  - membership_source — 落逐组 group_member_added details.source;admin 链路保持
                        既有 "user_create" 原值(默认),内嵌链路传
                        "project_artist_inline"(内嵌三类审计统一常量)
"""
from __future__ import annotations

import logging
import uuid

from fastapi import HTTPException
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.tables import Group, GroupMembership, User
from app.services.audit import AuditService
from app.services.org import get_default_organization
from app.services.passwords import generate_temp_password, hash_password
from app.services.permissions import PermissionsService

log = logging.getLogger(__name__)

# 艺人组名单点定义(方案 B6):projects.py 就地 import,勿二处定义漂移;
# ensure get-or-create 逻辑本身在 projects.py,常量归属只论单点
ARTIST_GROUP_NAME = "艺人"

# 内嵌链路三类审计(user_created / group_created / group_member_added)统一 source
# 常量(方案 D7);运维过滤口径:按 source 拉三类事件 + 按 via=artist_inline 另拉
# project_member_added
SOURCE_ARTIST_INLINE = "project_artist_inline"


async def add_user_to_group_audited(
    *,
    db: AsyncSession,
    permissions: PermissionsService,
    audit: AuditService,
    actor_user_id: uuid.UUID,
    group: Group,
    user: User,
    # ctx 形参照 projects.py ctx: dict 惯例(**ctx 直传 audit)
    ctx: dict,  # type: ignore[type-arg]
    source: str | None = None,
) -> None:
    """加成员双写 + 审计:先 DB group_memberships 行提交,再 group#member tuple。

    原 directory.py `_add_membership` 平移为公共函数(方案 B4),逻辑逐行不变;
    ip/ua 取法由 `request: Request` 参数改为 `ctx: dict`(audit.write(**ctx) 形态,
    对齐 projects.py 惯例)。**remove 侧未平移**:directory.py `_remove_membership`
    保持 request: Request 形态原地不动,勿对称统一(防顺手改动引入无测试覆盖的变更)。
    source 非空时审计 details 增 source;三调用点中改用户组与组加成员现状不传
    (审计无该键),迁移后照旧不传,仅建号链路传(user_create / project_artist_inline)。
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
        **ctx,
    )


async def provision_local_user(
    db: AsyncSession,
    permissions: PermissionsService,
    audit: AuditService,
    *,
    username: str,
    name: str,
    email: str | None,
    groups: list[Group],
    actor_user_id: uuid.UUID,
    # ctx 形参照 projects.py ctx: dict 惯例(**ctx 直传 audit)
    ctx: dict,  # type: ignore[type-arg]
    source: str,
    membership_source: str = "user_create",
) -> tuple[User, str]:
    """开通本地用户:重名预检 → 临时密码 → 哈希落库 → org member → 逐组入组 → 审计。

    原 directory.py create_directory_user 的建号段平移(方案 B4/D6);admin 建号与
    组长内嵌建号(POST /projects 带 artist_account)共用本实现。组加载
    (_load_groups_for_ids 校验 >50 / 不存在 → 422)留在路由层:调用方先加载再传
    groups。

    - 重名预检:`func.lower(User.username) == username.lower()` + limit(1) + .first()
      —— 多行命中一律视为已占用 409(**勿 scalar_one_or_none**:存量 evan/Evan
      大小写共存对会 MultipleResultsFound 500);lower 匹配与登录口径对齐
      (local_auth.find_user_by_username),防「case 变体建号成功 → 两账号登录互锁」。
      命中 → 409 `登录名已存在:{username}`(services 层首例 HTTPException,见模块
      docstring);作为竞态兜底,admin 链路壳内另有前置预检(双查无害)。
    - source 落 user_created details.source;membership_source 落逐组
      group_member_added details.source(语义见模块 docstring)。
    - commit 后 db.refresh(new_user) 保留:created_at 依赖 server_default 回填,
      漏掉则调用方构造响应即 ValidationError 500。

    返回 (new_user, temp_password);临时密码只回显一次,不落 audit / log。
    """
    dup = (
        await db.execute(
            select(User)
            .where(func.lower(User.username) == username.lower())
            .limit(1)
        )
    ).first()
    if dup is not None:
        raise HTTPException(409, f"登录名已存在:{username}")

    # 新用户绑默认组织(老飞书用户 organization_id 的等价物;多租户启用时如有
    # 项目 org ≠ default org 的场景再议,方案 §4.1 org 备注)
    org = await get_default_organization(db)
    org_id = org[0] if org else None

    temp_pw = generate_temp_password()
    new_user = User(
        username=username,
        name=name,
        email=email or None,
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

    # 逐组入组(按入参顺序;每组各自审计 group_member_added,source=membership_source)
    for group in groups:
        await add_user_to_group_audited(
            db=db, permissions=permissions, audit=audit,
            actor_user_id=actor_user_id, group=group, user=new_user,
            ctx=ctx, source=membership_source,
        )

    await audit.write(
        event_type="user_created",
        actor_user_id=actor_user_id,
        details={"user_id": str(new_user.id), "username": username,
                 "name": name, "group_ids": [str(g.id) for g in groups],
                 "source": source},
        **ctx,
    )
    log.info("user created id=%s username=%s by admin=%s groups=%d",
             new_user.id, username, actor_user_id, len(groups))
    return new_user, temp_pw
