"""usage-stats router — 客户端使用统计聚合端点(2026-10-27 usage-analytics 需求 §3.1)。

  GET /api/v1/admin/usage/stats — 三端占比 + 内外网占比;仅 system admin。

独立 router(不堆进 1100+ 行的 admin.py,需求决策 P1);时间参数四分支 +
三类 422(naive / 乱序 / 超窗)按需求 §4 写死。只读端点,无写入副作用。
"""
from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.session import get_db
from app.deps import CurrentUser, require_system_admin
from app.models import UsageStatsOut
from app.services.usage_stats import UsageStatsService

router = APIRouter()

_DEFAULT_WINDOW_DAYS = 30
_MAX_WINDOW_DAYS = 366


@router.get("/stats", response_model=UsageStatsOut)
async def usage_stats(
    from_time: datetime | None = Query(  # noqa: B008
        None, alias="from", description="窗口起点(tz-aware ISO;缺省按时间规则补齐)",
    ),
    to_time: datetime | None = Query(  # noqa: B008
        None, alias="to", description="窗口终点(tz-aware ISO;缺省 = now)",
    ),
    metric: Literal["active_users", "logins"] = Query("active_users"),
    daily: bool = Query(True, description="false 时 daily 返回 []"),
    db: AsyncSession = Depends(get_db),  # noqa: B008  FastAPI DI,repo 全量同款
    user: CurrentUser = Depends(require_system_admin),  # noqa: B008
) -> UsageStatsOut:
    """使用统计聚合(需求 §4):totals / by_platform / by_platform_class /
    by_network / cross / daily;users 各分组独立去重,跨组不可加。"""
    _ = user.id
    now = datetime.now(UTC)
    # 时间规则四分支(需求 §4 写死)。先补 to 再补 from 即覆盖全部分支:
    # 双缺省 → to=now, from=now-30d(等价 from=to-30d);仅缺 to → to=now;
    # 仅缺 from → from=to-30d;双给 → 原值
    if to_time is None:
        to_time = now
    if from_time is None:
        from_time = to_time - timedelta(days=_DEFAULT_WINDOW_DAYS)

    # naive datetime → 422(FastAPI 不拦 naive,端点自判 tzinfo)
    if from_time.tzinfo is None or to_time.tzinfo is None:
        raise HTTPException(422, "from/to 必须是带时区的 tz-aware ISO 时间")
    if from_time >= to_time:
        raise HTTPException(422, "from 必须早于 to")
    if to_time - from_time > timedelta(days=_MAX_WINDOW_DAYS):
        raise HTTPException(422, f"时间窗口不能超过 {_MAX_WINDOW_DAYS} 天")

    data = await UsageStatsService(db).stats(
        from_time=from_time, to_time=to_time, metric=metric, daily=daily,
    )
    return UsageStatsOut(**data)
