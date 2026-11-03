"""ai_assets router — AI 打标/切片读取端点 + 上下文钩子 helper(AI 方案 §12/§8.6)。

端点(契约 docs/qdev/2026-11-03-ai-tagging-slicing.md §2.6):
  GET  /assets/{asset_id}/ai                annotation + segments(active 版本)一次带回
  POST /assets/{asset_id}/ai/keyframe-urls  段关键帧 presigned URL 按需签发(≤10 段/请求)
权限口径(方案 §12 定稿)= 素材列表同口径(list_assets 形态):系统 admin 直通;
public 项目非敏感夹豁免;否则 folder can_view(sensitive 夹走 sensitive_folder
类型);未通过一律 404(与不存在/软删同文案,防探测泄露存在性,亦防「列表可见、
AI 区 403」口径分裂)。钩子 helper(§8.6)全部 fire-and-forget fail-open:
ai_enabled=false 零行为;异常仅 log,不影响宿主端点主流程。出入参模型放本文件。
"""
from __future__ import annotations

import logging
import time
import uuid
from collections.abc import Sequence
from datetime import UTC, datetime
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.session import get_db
from app.db.tables import AiJob, Asset, AssetAiAnnotation, AssetVideoSegment, Folder, Project
from app.deps import (
    CurrentUser,
    get_audit,
    get_current_user,
    get_is_system_admin,
    get_permissions,
    get_presign,
    get_request_context,
)
from app.services.ai_jobs import KIND_ANNOTATE, KIND_SLICE, dialect_insert
from app.services.audit import AuditService
from app.services.permissions import PermissionsService
from app.services.presign import PresignService, request_base_from
from app.settings import get_settings

router = APIRouter()
log = logging.getLogger(__name__)

_KEYFRAME_TTL_S = 1800   # 签发 TTL 沿缩略图口径(get_thumbnail_url 同值)
_REFRESH_CHUNK = 500     # refresh 派发单批上限(>500 分批,防超 job timeout=300)


# ─── Pydantic 出入参(契约 §2.6 形状)─────────────────────────────────────────
class AiAnnotationOut(BaseModel):
    """active 版本 annotation 行(无则整体 null)。"""
    model_config = ConfigDict(from_attributes=True)
    context_path: str
    tags_zh: list[str] = []
    tags_en: list[str] = []
    description: str | None = None
    description_en: str | None = None
    tier: str
    model_version: str
    meta: dict[str, Any] = {}
    updated_at: datetime


class AiSegmentOut(BaseModel):
    """只回 keyframe_count 不回 key 明细(keyframes 经 keyframe-urls 按需签,§12-2)。"""
    idx: int
    start_ms: int
    end_ms: int
    tags_zh: list[str] = []
    tags_en: list[str] = []
    description: str | None = None
    meta: dict[str, Any] = {}
    keyframe_count: int


class AssetAiOut(BaseModel):
    """annotation/segments 均可为 null(无行即空值仍 200 —— 缺席不代表不可见)。"""
    annotation: AiAnnotationOut | None = None
    segments: list[AiSegmentOut] | None = None
    model_version_active: str


class KeyframeUrlsIn(BaseModel):
    """1..10 段/请求(载荷与审计量有界,方案 §12-2)。"""
    segment_idxs: list[int] = Field(..., min_length=1, max_length=10)


class KeyframeUrlsOut(BaseModel):
    """urls 以 str(idx) 为键(JSON object 键恒字符串),只含可签段。"""
    urls: dict[str, list[str]] = Field(default_factory=dict)


async def _load_visible_asset(
    db: AsyncSession, permissions: PermissionsService, user: CurrentUser,
    is_system_admin: bool, asset_id: uuid.UUID,
) -> tuple[Asset, Folder]:
    """AI 端点公共前置:ai_enabled 急停闸 → 不存在/软删 404 → 权限(list_assets 同款
    三分支:admin 直通 / public 项目非敏感夹豁免 / folder|sensitive_folder can_view;
    不通过 404 不泄露存在性)。返回 (asset, folder)。"""
    if not get_settings().ai_enabled:
        raise HTTPException(404, "asset not found")
    asset = await db.get(Asset, asset_id)
    if asset is None or asset.deleted_at is not None:
        raise HTTPException(404, "asset not found")
    folder = await db.get(Folder, asset.folder_id)
    if folder is None:
        raise HTTPException(404, "asset not found")
    allowed = is_system_admin
    if not allowed and not folder.is_sensitive:
        project = await db.get(Project, folder.project_id)
        allowed = project is not None and project.visibility == "public"
    if not allowed:
        allowed = await permissions.check(
            user_subject=user.subject,
            relation="can_view",
            object_type="folder" if not folder.is_sensitive else "sensitive_folder",
            object_id=str(folder.id),
        )
    if not allowed:
        raise HTTPException(404, "asset not found")
    return asset, folder


# ─── GET /assets/{asset_id}/ai(契约 §2.6)────────────────────────────────────
@router.get("/{asset_id}/ai", response_model=AssetAiOut)
async def get_asset_ai(
    asset_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),  # noqa: B008  # FastAPI DI,repo 全量同款
    permissions: PermissionsService = Depends(get_permissions),  # noqa: B008  # FastAPI DI,repo 全量同款
    user: CurrentUser = Depends(get_current_user),  # noqa: B008  # FastAPI DI,repo 全量同款
    is_system_admin: bool = Depends(get_is_system_admin),
) -> AssetAiOut:
    """素材 AI 打标结果 + 视频分段(方案 §12)。

    ai_enabled=false → 404(总开关急停,§13);不存在/软删/无权 → 404;无
    annotation 行也 200(空值)。segments 按 idx 升序,keyframe_count =
    len(keyframe_keys),不回 key 明细。只读 active 版本(settings.ai_active_version,
    进程内,不查库);不写审计(只读打标结果;keyframes 签发才落审计)。"""
    _asset, _folder = await _load_visible_asset(db, permissions, user, is_system_admin, asset_id)
    active = get_settings().ai_active_version
    ann = (await db.execute(
        select(AssetAiAnnotation).where(
            AssetAiAnnotation.asset_id == asset_id,
            AssetAiAnnotation.model_version == active,
        ),
    )).scalar_one_or_none()
    seg_rows = (await db.execute(
        select(AssetVideoSegment)
        .where(AssetVideoSegment.asset_id == asset_id)
        .order_by(AssetVideoSegment.idx),
    )).scalars().all()
    return AssetAiOut(
        annotation=AiAnnotationOut.model_validate(ann) if ann is not None else None,
        segments=[
            AiSegmentOut(
                idx=s.idx, start_ms=s.start_ms, end_ms=s.end_ms,
                tags_zh=list(s.tags_zh or []), tags_en=list(s.tags_en or []),
                description=s.description, meta=dict(s.meta or {}),
                keyframe_count=len(s.keyframe_keys or []),
            )
            for s in seg_rows
        ] or None,
        model_version_active=active,
    )


# ─── POST /assets/{asset_id}/ai/keyframe-urls(契约 §2.6)─────────────────────
@router.post("/{asset_id}/ai/keyframe-urls", response_model=KeyframeUrlsOut)
async def post_keyframe_urls(
    asset_id: uuid.UUID,
    payload: KeyframeUrlsIn,
    request: Request,
    db: AsyncSession = Depends(get_db),  # noqa: B008  # FastAPI DI,repo 全量同款
    permissions: PermissionsService = Depends(get_permissions),  # noqa: B008  # FastAPI DI,repo 全量同款
    presign: PresignService = Depends(get_presign),  # noqa: B008  # FastAPI DI,repo 全量同款
    audit: AuditService = Depends(get_audit),  # noqa: B008  # FastAPI DI,repo 全量同款
    user: CurrentUser = Depends(get_current_user),  # noqa: B008  # FastAPI DI,repo 全量同款
    is_system_admin: bool = Depends(get_is_system_admin),
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008  # FastAPI DI,repo 全量同款
) -> KeyframeUrlsOut:
    """段关键帧 presigned URL 按需批量签发(方案 §12 keyframes 定稿)。

    权限与 GET 同口径;segment_idxs ≤10 段(超限 pydantic 422);无效 idx /
    无 keyframes 的段跳过。签缩略图桶(sign_thumbnail_url 同款,TTL 沿缩略图口径
    1800;keyframes/{asset_id}/ 前缀 512px 派生物 —— 定位中间档:比缩略图档严
    (folder 权限 + 审计),比下载档宽(不要求 can_download))。**每请求写一条**
    signed_url_issued 审计(details 记 count 与对象前缀,不逐帧审计)。"""
    _asset, folder = await _load_visible_asset(db, permissions, user, is_system_admin, asset_id)
    seg_rows = (await db.execute(
        select(AssetVideoSegment).where(
            AssetVideoSegment.asset_id == asset_id,
            AssetVideoSegment.idx.in_(set(payload.segment_idxs)),
        ),
    )).scalars().all()
    by_idx = {s.idx: s for s in seg_rows}

    urls: dict[str, list[str]] = {}
    issued = 0
    for idx in dict.fromkeys(payload.segment_idxs):  # 去重保序
        seg = by_idx.get(idx)
        keys = list(seg.keyframe_keys or []) if seg is not None else []
        if not keys:
            continue  # 无效 idx / 无 keyframes 的段跳过
        urls[str(idx)] = [
            presign.sign_thumbnail_url(key, _KEYFRAME_TTL_S, request_base=request_base_from(request))
            for key in keys
        ]
        issued += len(urls[str(idx)])

    await audit.signed_url_issued(
        actor_user_id=user.id, target_asset_id=asset_id,
        target_project_id=folder.project_id,
        details={"count": issued, "prefix": f"keyframes/{asset_id}/"},
        **ctx,
    )
    return KeyframeUrlsOut(urls=urls)


# ─── 上下文钩子 helper(§8.6;fire-and-forget,ai_enabled=false 零行为)────────
async def enqueue_ai_refresh(
    pool: Any, *, asset_ids: Sequence[uuid.UUID] | None = None,
    folder_id: uuid.UUID | None = None, job_seq: int | None = None,
) -> None:
    """ai_refresh_context 派发(§8.6):改名/移动后重拼 annotation 上下文。

    _job_id=f"ai:refresh:{unix_ts}"(job_seq 非空时追加序号:同秒分批防确定性 id
    被静默去重);入参形态对齐 worker 签名 ai_refresh_context(ctx, asset_ids:
    list[str] | None, folder_id: str | None);异常仅 log(丢失由 backfill
    --refresh-context 对账兜底)。"""
    if not get_settings().ai_enabled or pool is None:
        return
    suffix = f":{job_seq}" if job_seq is not None else ""
    try:
        await pool.enqueue_job(
            "ai_refresh_context",
            asset_ids=[str(a) for a in asset_ids] if asset_ids else None,
            folder_id=str(folder_id) if folder_id is not None else None,
            _queue_name="ai",
            _job_id=f"ai:refresh:{int(time.time())}{suffix}",
            _expires=1800,
        )
    except Exception as e:  # 派发失败仅 log(fire-and-forget,backfill 兜底)
        log.warning("enqueue ai_refresh_context fail err=%s", e)


async def enqueue_ai_refresh_for_assets(pool: Any, asset_ids: Sequence[uuid.UUID]) -> None:
    """资产列表派发:优先 asset_ids 直传;>500 分批(单批 ≤500 与
    refresh_context 内部批语义一致,job timeout=300 不被击穿)。"""
    ids = list(dict.fromkeys(asset_ids))  # 去重保序
    if not ids:
        return
    if len(ids) <= _REFRESH_CHUNK:
        await enqueue_ai_refresh(pool, asset_ids=ids)
        return
    for seq, start in enumerate(range(0, len(ids), _REFRESH_CHUNK)):
        await enqueue_ai_refresh(pool, asset_ids=ids[start:start + _REFRESH_CHUNK], job_seq=seq)


async def restore_restock_ai(db: AsyncSession, pool: Any, asset_id: uuid.UUID) -> None:
    """restore_asset 恢复出口两步(§8.6):① SELECT 后 DELETE ai_jobs WHERE
    asset_id AND status='skipped' AND last_error='asset_gone'(先 SELECT 被删行的
    kind 集合 —— 删了就看不见);② 补行:被删 asset_gone 行的每个原 kind 各补
    INSERT ai_jobs(pending)+ 按 kind 派发(annotate→enqueue_ai_annotate /
    slice→enqueue_ai_slice)—— 视频的 slice 行恢复后重建,分段不丢;此外该资产
    无任何 annotation 行(任意版本)再补 annotate(沿用原口径)。行 model_version
    用 write_model_version(与 pipeline 认领同一写入版本才可被认领)。只 DELETE
    不重派会让 ai_jobs 失去事实源,恢复的资产静默漏标。ai_enabled=false 零行为;
    全程 try/except 仅 log,不影响恢复主流程。"""
    settings = get_settings()
    if not settings.ai_enabled or pool is None:
        return
    try:
        from app.services.ai_pipeline import write_model_version

        gone_where = (
            AiJob.asset_id == asset_id,
            AiJob.status == "skipped",
            AiJob.last_error == "asset_gone",
        )
        gone_kinds = set((await db.execute(
            select(AiJob.kind).where(*gone_where),
        )).scalars().all())
        await db.execute(delete(AiJob).where(*gone_where))
        has_ann = await db.scalar(
            select(func.count()).select_from(AssetAiAnnotation)
            .where(AssetAiAnnotation.asset_id == asset_id),
        )
        # 补行 kind 集 = 被删行原 kind(annotate/slice;asset_gone 只由
        # run_annotate/run_slice 写,其他 kind 防御性排除)+ 无 annotation 补 annotate
        dispatchable = (KIND_ANNOTATE, KIND_SLICE)
        restock = {k for k in gone_kinds if k in dispatchable}
        if not has_ann:
            restock.add(KIND_ANNOTATE)
        inserted: list[str] = []
        if restock:
            now = datetime.now(UTC)
            mv = write_model_version(settings)
            for kind in sorted(restock):
                res = await db.execute(
                    dialect_insert(db, AiJob.__table__).values(
                        id=uuid.uuid4(), asset_id=asset_id, kind=kind,
                        status="pending", attempts=0,
                        model_version=mv,
                        created_at=now, updated_at=now,
                    ).on_conflict_do_nothing(index_elements=["asset_id", "kind", "model_version"])
                )
                if res.rowcount:  # 已有同名行(并发/残留)不重复派发,sweeper 兜底
                    inserted.append(kind)
        await db.commit()
        if inserted:
            from app.services.arq_pool import enqueue_ai_annotate, enqueue_ai_slice

            by_kind = {KIND_ANNOTATE: enqueue_ai_annotate, KIND_SLICE: enqueue_ai_slice}
            for kind in inserted:
                await by_kind[kind](pool, str(asset_id))
    except Exception as e:  # 恢复主流程不受 AI 补行影响(fail-open,§8.6)
        log.warning("restore ai restock fail asset=%s err=%s", asset_id, e)
