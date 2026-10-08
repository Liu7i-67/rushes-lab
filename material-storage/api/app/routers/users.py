"""users router — fuzzy search 给前端 UserPicker(a2.5;#150 数据源本地化)。

endpoints:
  GET /api/v1/users?q=&limit=&offset= — admin 或 project creator,fuzzy name/email/username
                                        搜本地 db(方案 §2.3 弱门放宽 + §3.3 offset 分页)
  GET /api/v1/groups?q=&limit=        — admin 或 project creator,本地 groups 表列表
                                        (见 routers/groups.py)

#150 起 UserPicker 的 value 语义 = users.id UUID(不再用飞书 open_id)。
"""
from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.session import get_db
from app.db.tables import User
from app.deps import CurrentUser, require_admin_or_project_creator

log = logging.getLogger(__name__)
router = APIRouter()


class UserBrief(BaseModel):
    id: str
    username: str | None = None
    open_id: str | None = None     # 飞书遗留,本地新用户为 None
    union_id: str | None = None
    name: str
    email: str | None = None


@router.get("", response_model=list[UserBrief])
async def search_users(
    q: str = Query("", description="模糊关键字,匹配 name/email/username;留空 = 返前 N"),
    limit: int = Query(20, ge=1, le=100),
    offset: int = Query(0, ge=0, description="offset 分页(方案 §3.3:前端循环拉全量做 nameById)"),
    db: AsyncSession = Depends(get_db),
    user: CurrentUser = Depends(require_admin_or_project_creator),
) -> list[UserBrief]:
    """fuzzy 搜 user — UserPicker autocomplete 用(value = users.id UUID)。

    弱门放宽(方案 §2.3):并入 project_creator,零项目组员也要能填建项目表单。
    排序补 User.id tiebreaker(方案 §3.3):同名用户仅按 name 排时 offset 翻页
    窗口会漂移(重复/漏行),稳定全序才能配合 offset 分页拉全。
    """
    _ = user.id  # 至少要认证;细粒度 admin 检查 D iter4 后端 enforcement
    stmt = select(User).where(User.is_active.is_(True))
    term = q.strip()
    if term:
        like = f"%{term}%"
        stmt = stmt.where(
            or_(
                User.name.ilike(like),
                User.email.ilike(like),
                User.username.ilike(like),
                User.feishu_open_id.ilike(like),
            )
        )
    stmt = stmt.order_by(User.name, User.id).offset(offset).limit(limit)
    res = await db.execute(stmt)
    return [
        UserBrief(
            id=str(u.id),
            username=u.username,
            open_id=u.feishu_open_id,
            union_id=u.feishu_union_id,
            name=u.name,
            email=u.email,
        )
        for u in res.scalars().all()
    ]


