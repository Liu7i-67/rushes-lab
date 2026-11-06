"""upload-stats router — 文件上传数量统计端点(2026-11-06 stats-panel-upload-stats §4)。

  GET /api/v1/admin/stats/uploads — 按项目分行的四分类计数(生活图文/口播视频/
  生活视频/其他)+ 全选项目汇总;守门 require_upload_stats_viewer
  (is_org_admin ∨ (stats_viewer ∧ upload_stats_viewer),deps 由同需求包 A 交付)。

独立 router(不堆进 1100+ 行的 admin.py,usage_stats 先例 P1);date_from/date_to
必填日粒度,服务端 Asia/Shanghai 归一(§4.2);project_ids 单参数逗号串契约
(§4.1)。只读端点,无写入副作用。
"""
from __future__ import annotations

from datetime import date

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.session import get_db
from app.deps import (
    CurrentUser,
    get_is_system_admin,
    get_permissions,
    require_upload_stats_viewer,
)
from app.models import UploadStatsOut
from app.services.permissions import PermissionsService
from app.services.upload_stats import (
    UploadStatsService,
    normalize_window,
    parse_project_ids,
)

router = APIRouter()


@router.get("/uploads", response_model=UploadStatsOut)
async def upload_stats(
    project_ids: str | None = Query(  # noqa: B008
        None,
        description="逗号分隔项目 id(单参数契约);空串/缺省 = 全部 in-scope 项目;"
        "不可见/归档/已删 id 静默丢弃;上限 200",
    ),
    date_from: date = Query(  # noqa: B008
        ..., description="起始日(含),按 Asia/Shanghai 归一为当日 00:00:00",
    ),
    date_to: date = Query(  # noqa: B008
        ..., description="结束日(含),归一至次日 00:00 半开区间右端",
    ),
    db: AsyncSession = Depends(get_db),  # noqa: B008  FastAPI DI,repo 全量同款
    permissions: PermissionsService = Depends(get_permissions),  # noqa: B008
    user: CurrentUser = Depends(require_upload_stats_viewer),  # noqa: B008
    is_admin: bool = Depends(get_is_system_admin),  # noqa: B008  决定 folder_filter 直通
) -> UploadStatsOut:
    """文件上传数量统计(需求 §4.1):rows 按项目零填充 + summary 汇总。

    分类优先级 livp > 口播视频 > 生活视频 > 图片(livp/图片并入「生活图文」);
    软删资产与归档/软删项目不计数;数据权限 = 盲搜同款 folder 级零泄露
    (系统 admin 直通);排序 total desc → project_name asc。
    """
    from_dt, to_dt = normalize_window(date_from, date_to)
    selected_ids = parse_project_ids(project_ids)
    data = await UploadStatsService(db).stats(
        from_dt=from_dt,
        to_dt=to_dt,
        project_ids=selected_ids,
        user_subject=user.subject,
        is_admin=is_admin,
        permissions=permissions,
    )
    return UploadStatsOut(**data)
