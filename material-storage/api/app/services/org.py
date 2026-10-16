"""组织(default org)查询 — 原 contact_sync.get_default_organization 迁移而来(#154 删飞书后独立成模块)。

飞书下线(ADR-0007 / #154)后组织轴保留:OpenFGA `organization:<tenant_key>` 仍是
权限体系的根节点;`organizations.feishu_tenant_key` 列保留只读(历史对照)。
"""
from __future__ import annotations

import uuid
from typing import TYPE_CHECKING

from sqlalchemy.ext.asyncio import AsyncSession

from app.db.tables import Organization

if TYPE_CHECKING:
    from app.services.permissions import PermissionsService


async def get_default_organization(db: AsyncSession) -> tuple[uuid.UUID, str] | None:
    """从 settings.default_organization_id 拿 + db 查 tenant_key。"""
    from app.settings import get_settings
    settings = get_settings()
    if not settings.default_organization_id:
        return None
    org_id = uuid.UUID(settings.default_organization_id)
    org = await db.get(Organization, org_id)
    if org is None:
        return None
    tenant_key = org.feishu_tenant_key or str(org_id)
    return org_id, tenant_key


async def user_is_org_file_deleter(
    permissions: PermissionsService,
    db: AsyncSession,
    *,
    user_id: str,
) -> bool:
    """当前 user 是否持有 organization#file_deleter(组开关经 group#member 展开)。

    2026-10-16「删除文件/文件夹权限可授予用户组」:assets(软删/彻底删/回收站/
    恢复)与 folders(删夹/get_folder 下发)守门的组开关半边 —— FGA check 由
    PermissionsService.is_org_file_deleter 承担,本函数只补 default org 解析
    (deps.require_project_deleter 内联同款三步,抽出来给 5 个调用点复用)。

    default org 缺失 → False(开关分支不生效,主守门[系统 admin / 对象级]照旧);
    FGA 异常不上吞(与 require_project_deleter 同惯例:部署顺序保证 model 先 push,
    store.fga.yaml 变更须先跑 scripts/openfga_write_model.sh 重推)。
    """
    org = await get_default_organization(db)
    if org is None:
        return False
    _, tenant_key = org
    return await permissions.is_org_file_deleter(
        user_id=user_id, organization_tenant_key=tenant_key,
    )
