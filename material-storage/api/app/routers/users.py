"""users router — fuzzy search 给前端 UserPicker(a2.5;#150 数据源本地化)。

endpoints:
  GET /api/v1/users?q=&limit=&offset= — admin 或 project creator,fuzzy name/email/username
                                        搜本地 db(方案 §2.3 弱门放宽 + §3.3 offset 分页)
  GET /api/v1/users/username-available — 内嵌建号登录名占用预检(艺人账号内嵌方案 §4.2,
                                        守门 require_inline_artist_creator 组合弱门)
  GET /api/v1/groups?q=&limit=        — admin 或 project creator,本地 groups 表列表
                                        (见 routers/groups.py)

#150 起 UserPicker 的 value 语义 = users.id UUID(不再用飞书 open_id)。
"""
from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel
from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.session import get_db
from app.db.tables import User
from app.deps import CurrentUser, require_admin_or_project_creator, require_inline_artist_creator

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


@router.get("/username-available")
async def username_available(
    username: str = Query(
        ...,
        min_length=2,
        max_length=64,
        pattern=r"^[a-zA-Z0-9._-]+$",
        description="登录名:约束与 UserCreateIn 同款(2-64 + 字符集,不合 422)",
    ),
    db: AsyncSession = Depends(get_db),  # noqa: B008  FastAPI DI,repo 全量同款
    user: CurrentUser = Depends(require_inline_artist_creator),  # noqa: B008  同款
) -> dict[str, bool]:
    """登录名占用预检(艺人账号内嵌方案 §4.2):前端输入停顿后调用,把 409 挡在提交前。

    守门 = require_inline_artist_creator 组合弱门(与内嵌建号真实能力同构:
    is_org_admin,或 is_org_project_creator 与 is_org_artist_account_creator 同时
    满足 —— 合取堵住「仅有 artist flag、无 project_creator」持有者把它当纯账号
    存在性 oracle 用)。返回 {available: bool},available=false 即已占用,不返回
    占用者信息;查询用 func.lower 与登录口径/建号预检一致。读操作不写 audit
    (403 亦然,deps 惯例)。
    """
    _ = user.id  # 至少要认证 + 组合弱门已在上游 deps 判定
    res = await db.execute(
        select(User).where(func.lower(User.username) == username.lower()).limit(1)
    )
    return {"available": res.first() is None}


