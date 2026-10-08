"""assets router — uppy 5-endpoint + list + download + iter4 enforce + audit。

Phase B-2 iter4:每 endpoint 加 OpenFGA check + audit 落库。
"""
from __future__ import annotations

import asyncio
import logging
import unicodedata
import uuid
from datetime import datetime, timezone
from typing import Any, cast
from urllib.parse import quote

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel
from sqlalchemy import ColumnElement, func, literal_column, or_, select, true, update
from sqlalchemy.engine import CursorResult
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm.exc import StaleDataError

from app.db.session import get_db
from app.db.tables import Asset, Folder, Project
from app.deps import (
    CurrentUser,
    get_audit,
    get_current_user,
    get_is_system_admin,
    get_permissions,
    get_presign,
    get_request_context,
)
from app.models import (
    AssetBatchPrefixIn,
    AssetListOut,
    AssetMetaUpdateIn,
    AssetOut,
    DownloadLinkOut,
    SearchResultOut,
    TrashOut,
    UploadCompleteIn,
    UploadMultipartCreateOut,
    UploadPartUrlOut,
    UploadUrlRequest,
)
from app.services.asset_cleanup import purge_asset_storage
from app.services.audit import AuditService, mint_trace_id
from app.services.permissions import PermissionsService
from app.services.presign import PresignService
from app.settings import get_settings

router = APIRouter()
log = logging.getLogger(__name__)


# ─── multipart upload(uppy AwsS3 plugin)─────────────────────────────────────
@router.post("/uploads", response_model=UploadMultipartCreateOut)
async def create_upload(
    payload: UploadUrlRequest,
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    presign: PresignService = Depends(get_presign),
    audit: AuditService = Depends(get_audit),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
    ctx: dict = Depends(get_request_context),
) -> UploadMultipartCreateOut:
    user_id = user.id
    folder = await db.get(Folder, payload.folder_id)
    if not folder:
        raise HTTPException(404, "folder not found")

    # check can_upload folder(v4:uploader 隐含上传 + 创建 sub folder);系统 admin 直通
    allowed = is_system_admin or await permissions.check(
        user_subject=user.subject,
        relation="can_upload",
        object_type="folder" if not folder.is_sensitive else "sensitive_folder",
        object_id=str(folder.id),
    )
    if not allowed:
        await audit.write(
            event_type="access_denied",
            actor_user_id=user_id,
            target_project_id=folder.project_id,
            details={"action": "create_upload", "folder_id": str(folder.id),
                     "filename": payload.filename, "reason": "openfga can_edit false"},
            **ctx,
        )
        raise HTTPException(403, "no permission to upload to this folder")

    # filename 带 "/" 会把 key 拼到 folder 前缀之外(complete 的前缀校验必 400),create 期拦掉
    if "/" in payload.filename:
        raise HTTPException(400, "filename 不能包含路径分隔符")
    key = f"{folder.minio_prefix.rstrip('/')}/{payload.filename}"
    bucket = await _project_bucket(db, folder.project_id)

    upload_id = presign.create_multipart_upload(bucket, key, payload.content_type)
    return UploadMultipartCreateOut(upload_id=upload_id, key=key, bucket=bucket)


@router.get("/uploads/{upload_id}/parts/{part_number}", response_model=UploadPartUrlOut)
async def sign_part(
    upload_id: str,
    part_number: int,
    bucket: str = Query(...),
    key: str = Query(...),
    presign: PresignService = Depends(get_presign),
    user: CurrentUser = Depends(get_current_user),  # 至少要认证;细粒度上传 check 在 create_upload 已做
) -> UploadPartUrlOut:
    settings = get_settings()
    url = presign.sign_part_url(
        bucket, key, upload_id, part_number,
        expires_seconds=settings.presigned_normal_ttl_seconds,
    )
    return UploadPartUrlOut(url=url, expires_in=settings.presigned_normal_ttl_seconds)


@router.post("/uploads/{upload_id}/complete", response_model=AssetOut)
async def complete_upload(
    upload_id: str,
    payload: UploadCompleteIn,
    request: Request,
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    presign: PresignService = Depends(get_presign),
    audit: AuditService = Depends(get_audit),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
    ctx: dict = Depends(get_request_context),
) -> AssetOut:
    user_id = user.id
    folder = await db.get(Folder, payload.folder_id)
    if not folder:
        raise HTTPException(404, "folder not found")

    # key 必须落在该 folder 的 minio_prefix 下:create_upload 按
    # f"{minio_prefix.rstrip('/')}/{filename}" 拼 key,这里按同一规则反推校验
    # (folder_id 由契约显式携带 —— 按 key 前缀反查在跨 project 同名目录树
    # 下会多行命中,已退役)
    key_prefix = payload.key.rsplit("/", 1)[0] + "/" if "/" in payload.key else ""
    if key_prefix != f"{folder.minio_prefix.rstrip('/')}/":
        raise HTTPException(400, "key 与 folder 不匹配,请重新上传")
    # bucket 是客户端回传值,可能与 folder 所属项目的 bucket 不一致(多项目共用/多 bucket 部署)
    if payload.bucket != await _project_bucket(db, folder.project_id):
        raise HTTPException(400, "bucket 与 folder 所属项目不匹配")

    # 再次 check(防 user create_upload 后被 revoke);系统 admin 直通
    allowed = is_system_admin or await permissions.check(
        user_subject=user.subject,
        relation="can_upload",
        object_type="folder" if not folder.is_sensitive else "sensitive_folder",
        object_id=str(folder.id),
    )
    if not allowed:
        # 撤销半成品 multipart
        presign.abort_multipart_upload(payload.bucket, payload.key, upload_id)
        raise HTTPException(403, "no permission to complete upload(可能权限被撤销)")

    result = presign.complete_multipart_upload(
        payload.bucket, payload.key, upload_id, payload.parts  # type: ignore[arg-type]
    )

    # head_object 拿真实 size + content-type(complete 返回不含)
    head = presign.head_object(payload.bucket, payload.key)

    asset = Asset(
        id=uuid.uuid4(),
        folder_id=payload.folder_id,
        filename=payload.key.rsplit("/", 1)[-1],
        minio_bucket=payload.bucket,
        minio_key=payload.key,
        etag=head.get("etag") or result.get("etag"),
        minio_version_id=head.get("version_id") or result.get("version_id"),
        size_bytes=head.get("size_bytes") or 0,
        content_type=head.get("content_type"),
        uploader_id=user_id,
    )
    db.add(asset)
    try:
        await db.commit()
    except IntegrityError as e:
        # #177 同款并发窗口的 insert 侧:multipart 已在 MinIO complete 后,
        # folder 被并发删除 → INSERT 撞 assets_folder_id_fkey。对象成为
        # 孤儿(无法 abort 已完结的 multipart),记日志留给清理通道;
        # rollback 后重查区分「folder 没了」与「其他唯一约束(重复提交)」
        await db.rollback()
        still_there = await db.get(Folder, payload.folder_id)
        if still_there is None:
            log.warning(
                "orphan minio object (folder deleted mid-upload): bucket=%s key=%s",
                payload.bucket, payload.key,
            )
            raise HTTPException(
                409, "文件夹已被删除,上传无法完成(文件未入库,请选择其他文件夹重新上传)"
            ) from e
        raise HTTPException(409, "上传写入失败(可能重复提交),请刷新后重试") from e
    await db.refresh(asset)

    await permissions.bootstrap_asset(
        asset_id=str(asset.id),
        parent_type="sensitive_folder" if folder.is_sensitive else "folder",
        parent_id=str(folder.id),
    )

    trace_id = mint_trace_id()
    await audit.upload(
        actor_user_id=user_id,
        target_asset_id=asset.id,
        target_project_id=folder.project_id,
        target_minio_key=payload.key,
        dedup_key=f"upload:{asset.id}",
        trace_id=trace_id,
        details={
            "size_bytes": asset.size_bytes,
            "etag": asset.etag,
            "version_id": asset.minio_version_id,
            "parts": len(payload.parts),
        },
        **ctx,
    )

    # B-4:enqueue thumbnail 生成 — image 走 Pillow worker;video 走 ffmpeg worker (B-4 iter2 #101)
    # .livp(iOS Live Photo,实为 zip)浏览器不识别 content-type,按扩展名分派专属 worker
    ct = asset.content_type or ""
    if asset.filename.lower().endswith(".livp"):
        from app.services.arq_pool import enqueue_livp_thumbnail
        await enqueue_livp_thumbnail(request.app.state.arq_pool, str(asset.id))
    elif ct.startswith("image/"):
        from app.services.arq_pool import enqueue_thumbnail
        await enqueue_thumbnail(request.app.state.arq_pool, str(asset.id))
    elif ct.startswith("video/"):
        from app.services.arq_pool import enqueue_video_thumbnail
        await enqueue_video_thumbnail(request.app.state.arq_pool, str(asset.id))

    return AssetOut.model_validate(asset)


@router.delete("/uploads/{upload_id}", status_code=204)
async def abort_upload(
    upload_id: str,
    bucket: str = Query(...),
    key: str = Query(...),
    presign: PresignService = Depends(get_presign),
    user: CurrentUser = Depends(get_current_user),
) -> None:
    """主动 abort multipart;凡是认证 user 都可 abort 自己 upload。"""
    presign.abort_multipart_upload(bucket, key, upload_id)


# ─── list assets ──────────────────────────────────────────────────────────────
@router.get("", response_model=AssetListOut)
async def list_assets(
    folder_id: uuid.UUID = Query(...),
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
    limit: int = Query(100, ge=1, le=500),
    offset: int = Query(0, ge=0),
) -> AssetListOut:
    folder = await db.get(Folder, folder_id)
    if not folder:
        raise HTTPException(404, "folder not found")

    # check can_view folder;系统 admin 直通;public 项目非敏感 folder 对组织内
    # 可浏览(「公开」语义,与 thumbnail-url 的"信任组织内可见性"一致;
    # 下载/上传/删除仍各自 enforce)
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
        # 不暴露 folder 存在性,403 不写 audit(避免攻击者通过 audit 推断结构)
        raise HTTPException(403, "no permission")

    where = (Asset.folder_id == folder_id, Asset.deleted_at.is_(None))
    total = await db.scalar(select(func.count()).select_from(Asset).where(*where))
    stmt = (
        select(Asset)
        .where(*where)
        # id 唯一 tiebreaker:同一事务批量入夹的资产 created_at 全并列,只按
        # created_at 排序在 PG 里窗口切片不稳定(翻页重复/漏行)
        .order_by(Asset.created_at.desc(), Asset.id.desc())
        .limit(limit)
        .offset(offset)
    )
    res = await db.execute(stmt)
    return AssetListOut(
        items=[AssetOut.model_validate(r) for r in res.scalars().all()],
        total=total or 0,
    )


# ─── 回收站(软删列表 / 恢复 / 彻底删除)─────────────────────────────────────
@router.get("/trash", response_model=TrashOut)
async def list_trash(
    folder_id: uuid.UUID = Query(...),
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
    limit: int = Query(500, ge=1, le=500),
    offset: int = Query(0, ge=0),
) -> TrashOut:
    """列 folder 内已软删的文件(回收站)。普通 folder 需 can_admin。

    **sensitive folder 仅系统 admin**:敏感目录 can_view 不含项目 admin(受邀制),
    项目 admin 虽有 can_admin(可删/清文件)但不能把回收站当成窥探文件名/标签/
    备注的侧信道(「活的看不见、删掉的反而看得见」);sensitive 回收站的恢复/
    彻底清空同理由系统 admin 兜底。

    items 为分页窗口(上限 500),total 为全量计数 —— 角标与「清空回收站」的
    规模提示不被截断误导;超 500 时前端提示分批清空。
    """
    folder = await db.get(Folder, folder_id)
    if not folder:
        raise HTTPException(404, "folder not found")

    if folder.is_sensitive:
        allowed = is_system_admin
    else:
        allowed = is_system_admin or await permissions.check(
            user_subject=user.subject,
            relation="can_admin",
            object_type="folder",
            object_id=str(folder.id),
        )
    if not allowed:
        raise HTTPException(403, "no admin permission on this folder")

    where = (Asset.folder_id == folder_id, Asset.deleted_at.is_not(None))
    total = await db.scalar(select(func.count()).select_from(Asset).where(*where))
    stmt = (
        select(Asset)
        .where(*where)
        .order_by(Asset.deleted_at.desc())
        .limit(limit)
        .offset(offset)
    )
    res = await db.execute(stmt)
    return TrashOut(
        items=[AssetOut.model_validate(r) for r in res.scalars().all()],
        total=total or 0,
    )


@router.post("/{asset_id}/restore", status_code=204)
async def restore_asset(
    asset_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    audit: AuditService = Depends(get_audit),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
    ctx: dict = Depends(get_request_context),
) -> None:
    """恢复软删文件(deleted_at 置回 NULL)。需 asset.can_admin / 系统 admin。

    软删不动 OpenFGA tuple 与 MinIO 对象,恢复即回到删除前的权限/内容状态。
    sensitive 资产仅系统 admin:项目 admin 从父项目继承 can_admin 但无 can_view
    (受邀制),不能对看不见的敏感内容做恢复(F1,与 list_trash 收口同口径)。"""
    user_id = user.id
    asset = await db.get(Asset, asset_id)
    if not asset:
        raise HTTPException(404, "asset not found")

    allowed = is_system_admin or await permissions.check(
        user_subject=user.subject, relation="can_admin",
        object_type="asset", object_id=str(asset_id),
    )
    if not allowed:
        await audit.write(
            event_type="access_denied", actor_user_id=user_id,
            target_asset_id=asset_id, target_minio_key=asset.minio_key,
            details={"action": "restore_asset", "reason": "openfga can_admin false"},
            **ctx,
        )
        raise HTTPException(403, "no restore permission")

    # sensitive 门在 can_admin 之后:零权限探测者只见上面的通用 403,不借文案
    # 得知"该资产是否敏感"(分类元数据);到这里的只有项目 admin / 系统 admin
    folder = await db.get(Folder, asset.folder_id)
    if folder is not None and folder.is_sensitive and not is_system_admin:
        await audit.write(
            event_type="access_denied", actor_user_id=user_id,
            target_asset_id=asset_id, target_minio_key=asset.minio_key,
            details={"action": "restore_asset", "reason": "sensitive non-system-admin"},
            **ctx,
        )
        raise HTTPException(403, "sensitive 资产的恢复仅系统 admin 可操作")

    if asset.deleted_at is None:
        raise HTTPException(409, "文件未被删除(或已恢复)")

    asset.deleted_at = None
    try:
        await db.commit()
    except StaleDataError as e:
        # 并发 hard purge 竞速:asyncpg 方言对 0 行 UPDATE 同样校验 rowcount 抛
        # StaleDataError(与 DELETE 同款,容器内已实测)—— 行已不在,幂等 404
        await db.rollback()
        raise HTTPException(404, "文件已被彻底删除,无法恢复") from e

    await audit.write(
        event_type="asset_restored", actor_user_id=user_id,
        target_asset_id=asset_id, target_minio_key=asset.minio_key,
        details={"filename": asset.filename},
        **ctx,
    )


# ─── 盲搜(标签 + 跨 folder,#151)────────────────────────────────────────────
@router.get("/search", response_model=list[SearchResultOut])
async def search_assets(
    q: str = Query(..., min_length=1, max_length=200),
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
) -> list[SearchResultOut]:
    """跨 folder 盲搜:匹配文件名 / user_labels / notes。

    权限边界(本 endpoint 的硬约束):
    - 普通 user:先 `list_objects(can_view)` 取可达 folder(folder + sensitive_folder 两型),
      SQL 只查这些 folder 内的 asset —— sensitive 素材的存在性(名称/计数)零泄露。
    - 系统 admin 直通(SQL 全量,不查 OpenFGA)。
    - 注:asset 级 explicit_downloader(单文件临时 grant)不在此 folder 集合内,这类
      资产不会出现在搜索结果 —— 方向是保守(宁漏勿泄),可接受。

    搜索实现:PG ILIKE + pg_trgm 起步(百万行量级够用):
    - filename / notes 走 GIN trgm 索引(模糊子串)。
    - user_labels:整数组拼串后 ILIKE,走 `ms_labels_text()` 的 GIN trgm 表达式索引
      (migration 0011 建函数 + 索引)。取代原先 unnest EXISTS(不可索引,且
      SQLAlchemy 渲染出的列名 PG 不认 → 每次 500,review F1/F8)。
      ⚠️ 这里必须用 `func.ms_labels_text(...)` 而不是裸 `array_to_string(...)`:
      后者是 STABLE 函数进不了索引表达式,两边表达式不一致索引也不会命中。
      拼串匹配是精确元素匹配的超集(标签是拼串的子串),所以不再单独留
      `q = ANY(user_labels)` 分支 —— 它既冗余又不走 GIN array_ops,留着只会
      让 planner 对整个 OR 放弃索引。
    """
    q = q.strip()
    if not q:
        raise HTTPException(400, "q 不能为空")
    pattern = f"%{_escape_like(q)}%"

    # ColumnElement[bool]:系统 admin 直通 = 恒 true;否则 folder_id IN 可达集合
    folder_filter: ColumnElement[bool] = true()
    if not is_system_admin:
        folder_ids: list[uuid.UUID] = []
        for obj_type in ("folder", "sensitive_folder"):
            ids_str = await permissions.list_objects(
                user_subject=user.subject, relation="can_view", object_type=obj_type,
            )
            folder_ids.extend(uuid.UUID(s) for s in ids_str)
        # public 项目非敏感 folder 对组织内可浏览(与 GET /assets、GET /folders/{id}
        # 同语义,PR #176 review P1-2):否则公开项目内容「列表看得到、盲搜搜不到」。
        # sensitive folder 不在此列 —— 仍只走 list_objects(can_view),零泄露语义不变。
        public_rows = await db.execute(
            select(Folder.id)
            .join(Project, Folder.project_id == Project.id)
            .where(
                Project.visibility == "public",
                Folder.is_sensitive.is_(False),
            )
        )
        folder_ids.extend(public_rows.scalars().all())
        folder_ids = list({*folder_ids})  # 去重
        if not folder_ids:
            return []  # 无可达 folder → 结果必为空,不跑 SQL
        folder_filter = Asset.folder_id.in_(folder_ids)

    # user_labels 匹配:整数组拼串后 ILIKE,命中 ix_asset_user_labels_str_trgm
    # (ms_labels_text 是 migration 0011 建的 IMMUTABLE 包装,见 docstring)
    label_match = func.ms_labels_text(Asset.user_labels).ilike(pattern, escape="\\")

    stmt = (
        select(Asset, Folder.name, Project.id, Project.name)
        .join(Folder, Asset.folder_id == Folder.id)
        .join(Project, Folder.project_id == Project.id)
        .where(
            Asset.deleted_at.is_(None),
            folder_filter,
            or_(
                Asset.filename.ilike(pattern, escape="\\"),
                Asset.notes.ilike(pattern, escape="\\"),
                label_match,
            ),
        )
        .order_by(Asset.created_at.desc())
        .limit(limit)
        .offset(offset)
    )
    res = await db.execute(stmt)
    out: list[SearchResultOut] = []
    for asset, folder_name, project_id, project_name in res.all():
        data = AssetOut.model_validate(asset).model_dump()
        data.update(
            folder_name=folder_name,
            project_id=project_id,
            project_name=project_name,
        )
        out.append(SearchResultOut(**data))
    return out


# ─── 打标 / 改标(#151)────────────────────────────────────────────────────────
@router.patch("/{asset_id}/meta", response_model=AssetOut)
async def update_asset_meta(
    asset_id: uuid.UUID,
    payload: AssetMetaUpdateIn,
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    audit: AuditService = Depends(get_audit),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
    ctx: dict[str, Any] = Depends(get_request_context),
) -> AssetOut:
    """写 user_labels / notes(audit `asset.tag_updated`)。

    权限:can_upload 于父 folder(uploader 隐含编辑),或系统 admin 直通。
    """
    user_id = user.id
    asset = await db.get(Asset, asset_id)
    if not asset or asset.deleted_at is not None:
        raise HTTPException(404, "asset not found")
    folder = await db.get(Folder, asset.folder_id)
    if not folder:
        raise HTTPException(500, "asset folder lookup race")

    allowed = is_system_admin or await permissions.check(
        user_subject=user.subject,
        relation="can_upload",
        object_type="sensitive_folder" if folder.is_sensitive else "folder",
        object_id=str(folder.id),
    )
    if not allowed:
        await audit.write(
            event_type="access_denied",
            actor_user_id=user_id,
            target_asset_id=asset_id,
            target_project_id=folder.project_id,
            target_minio_key=asset.minio_key,
            details={"action": "update_asset_meta", "reason": "openfga can_upload false"},
            **ctx,
        )
        raise HTTPException(403, "no permission to edit this asset")

    if payload.user_labels is not None:
        if payload.labels_mode == "merge":
            # merge(方案 §1.1):与 DB 现值取并集,顺序写死 —— DB 现值在前、
            # 新标签追加在后;并集仍统一走 _normalize_labels(去重 + 50 条上限,
            # DB 已占满 50 时新标签被静默截断,已知行为)。批量跨页打标依赖
            # merge,未加载行的旧标签不被整条替换清掉。
            merged = list(asset.user_labels) + payload.user_labels
            asset.user_labels = _normalize_labels(merged)
        else:
            # replace(默认):现行为完全不变
            asset.user_labels = _normalize_labels(payload.user_labels)
    if payload.notes is not None:
        asset.notes = payload.notes[:2000] if payload.notes else ""
    try:
        await db.commit()
    except StaleDataError as e:
        # 打标与并发 hard purge 竞速(0 行 UPDATE 同抛 StaleDataError,
        # 容器内已实证)→ 幂等 404,与 restore / 软删分支同款
        await db.rollback()
        raise HTTPException(404, "asset not found") from e
    await db.refresh(asset)

    await audit.write(
        event_type="asset.tag_updated",
        actor_user_id=user_id,
        target_asset_id=asset_id,
        target_project_id=folder.project_id,
        target_minio_key=asset.minio_key,
        details={"user_labels": asset.user_labels, "notes": asset.notes},
        **ctx,
    )
    return AssetOut.model_validate(asset)


# ─── 批量文件名前缀(方案 §1.1)───────────────────────────────────────────────
class BatchPrefixReasonsOut(BaseModel):
    """五类跳过原因计数(键固定 ASCII,前端中文映射;deleted = 已删/不存在,不细分)。"""

    too_long: int = 0
    no_match: int = 0
    already_prefixed: int = 0
    empty_result: int = 0
    deleted: int = 0


class AssetBatchPrefixOut(BaseModel):
    """尽力而为 + 结果报告:renamed + skipped 与提交 id 数严格对账。"""

    renamed: int
    skipped: int
    skipped_reasons: BatchPrefixReasonsOut


@router.post("/batch-prefix", response_model=AssetBatchPrefixOut)
async def batch_prefix(
    payload: AssetBatchPrefixIn,
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    audit: AuditService = Depends(get_audit),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
    ctx: dict[str, Any] = Depends(get_request_context),
) -> AssetBatchPrefixOut:
    """批量加 / 去文件名前缀(纯 DB 改名,MinIO key 不动 —— 下载文件名由
    filename 动态生成 Content-Disposition)。

    语义:add = prefix + filename,已带该前缀跳过(already_prefixed),结果
    >512 跳过(too_long);remove = 恰好以 prefix 开头(大小写敏感)剥离一次,
    否则 no_match,剥离后空串 empty_result。

    **前缀比较两侧 NFC 归一**:存量 filename 多为 macOS 拖入的 NFD 原样落库,
    只归一输入侧会不命中;比较用 NFC(filename).startswith(prefix_nfc);
    remove 余量 = NFC(filename)[len(prefix_nfc):] 落库(NFC 串码点数与原串
    不同,不能按原串长度切);add 结果按 NFC 落库(库内 filename 逐步收敛 NFC)。

    权限:按 folder_id 分组逐组 can_upload check(对齐 update_asset_meta;
    敏感夹按 sensitive_folder 类型 —— 受邀 downloader 亦可改名,与打标同语义),
    系统 admin 直通;任一组无权限 → 403 整批不执行,文案笼统不带 folder 名
    (反探测约定,与 GET /assets 403 同口径)。

    实现四步(单事务):① asset_ids 去重 + SELECT 快照(软删行查不到 → 计
    deleted);② Python 端按语义算新名分桶;③ Core 语句逐 id UPDATE —— 不用
    ORM flush(并发 hard purge 抛 StaleDataError,restore 先例),不用单条
    IN...RETURNING(add 各 id 新名不同,executemany 不累积 RETURNING);add
    谓词 NOT starts_with(normalize(filename, NFC), :prefix) 是二次防线,防
    SELECT 与 UPDATE 之间并发提交的 add 叠出双前缀(remove 侧不加内容谓词,
    字节级谓词与 NFC 口径不对称,对 NFD 存量名会静默不命中);④ rowcount=0
    补查归因,保证 renamed + skipped 与提交数严格对账。
    """
    user_id = user.id
    # prefix 已在 AssetBatchPrefixIn 校验器里 NFC 归一;此处再归一一次是幂等的,
    # 让「两侧 NFC」口径在使用点显式可见
    prefix_nfc = unicodedata.normalize("NFC", payload.prefix)
    reasons = BatchPrefixReasonsOut()

    # ① 去重(dict.fromkeys 保序,防重复 id 被计入 deleted/统计两次)+ 快照
    unique_ids = list(dict.fromkeys(payload.asset_ids))
    rows = (
        await db.execute(
            select(
                Asset.id, Asset.filename, Asset.folder_id,
                Folder.project_id, Folder.is_sensitive,
            )
            .join(Folder, Asset.folder_id == Folder.id)
            .where(Asset.id.in_(unique_ids), Asset.deleted_at.is_(None))
        )
    ).all()
    snap: dict[uuid.UUID, tuple[str, uuid.UUID, bool]] = {}
    folder_groups: dict[uuid.UUID, bool] = {}  # folder_id -> is_sensitive
    project_ids: set[uuid.UUID] = set()
    for asset_id, filename, folder_id, project_id, is_sensitive in rows:
        snap[asset_id] = (filename, folder_id, is_sensitive)
        folder_groups.setdefault(folder_id, is_sensitive)
        project_ids.add(project_id)
    # 全批恰属一个项目时 audit 带 target_project_id(对齐单资产端点写法),跨项目留空
    target_project_id = next(iter(project_ids)) if len(project_ids) == 1 else None

    # 权限:逐 folder 组 can_upload check(对齐 update_asset_meta 的 check 模式);
    # 任一组无权限 → 403 整批不执行
    denied_folders: list[uuid.UUID] = []
    for folder_id, is_sensitive in folder_groups.items():
        if is_system_admin:
            continue  # 系统 admin 直通
        allowed = await permissions.check(
            user_subject=user.subject,
            relation="can_upload",
            object_type="sensitive_folder" if is_sensitive else "folder",
            object_id=str(folder_id),
        )
        if not allowed:
            denied_folders.append(folder_id)
    if denied_folders:
        # HTTP 文案笼统不带 folder 名(反探测);audit 略详(folder_id)供溯源
        await audit.write(
            event_type="access_denied",
            actor_user_id=user_id,
            target_project_id=target_project_id,
            details={
                "action": "batch_prefix",
                "reason": "openfga can_upload false",
                "denied_folder_ids": [str(f) for f in denied_folders],
            },
            **ctx,
        )
        raise HTTPException(403, "所选部分或全部文件无操作权限")

    # ② Python 端按语义算新名(两侧 NFC),分「应改 / 各原因跳过」
    new_names: dict[uuid.UUID, str] = {}
    for asset_id in unique_ids:
        row = snap.get(asset_id)
        if row is None:
            # SELECT 查不到 = 已软删(回收站)或不存在,天然跳过
            reasons.deleted += 1
            continue
        old_nfc = unicodedata.normalize("NFC", row[0])
        if payload.action == "add":
            if old_nfc.startswith(prefix_nfc):
                reasons.already_prefixed += 1
                continue
            new_nfc = unicodedata.normalize("NFC", prefix_nfc + old_nfc)
            if len(new_nfc) > 512:  # 与 tables.assets.filename String(512) 对齐
                reasons.too_long += 1
                continue
            new_names[asset_id] = new_nfc
        else:
            if not old_nfc.startswith(prefix_nfc):
                reasons.no_match += 1
                continue
            rest = old_nfc[len(prefix_nfc):]  # 按码点切,NFC 串长度 ≠ 原串长度
            if not rest:
                reasons.empty_result += 1
                continue
            new_names[asset_id] = rest

    # ③ Core 语句单事务逐 id UPDATE。add 谓词里的 normalize form 参数是不带
    # 引号的 SQL 关键字 NFC(literal_column —— 写成 'NFC' 字符串是 PG 语法
    # 错误);用 starts_with 不用 LIKE(_ / % 通配符会被误拦,免转义先例
    # _escape_like)。rowcount 由逐条 UPDATE 直接拿,不依赖 ORM flush 校验。
    renamed_ids: list[uuid.UUID] = []
    raced_ids: list[uuid.UUID] = []
    for asset_id, new_name in new_names.items():
        stmt = update(Asset).where(Asset.id == asset_id, Asset.deleted_at.is_(None))
        if payload.action == "add":
            stmt = stmt.where(
                ~func.starts_with(
                    func.normalize(Asset.filename, literal_column("NFC")), prefix_nfc
                )
            )
        result = await db.execute(stmt.values(filename=new_name))
        # asyncpg DML 实际返回 CursorResult(带 rowcount);基类 Result 的类型
        # 标注未声明该属性,cast 仅为过 mypy strict,运行时行为不变
        if cast("CursorResult[Any]", result).rowcount == 1:
            renamed_ids.append(asset_id)
        else:
            raced_ids.append(asset_id)

    # ④ 对账:rowcount=0 = SELECT 与 UPDATE 之间有并发变更,补查归因,
    # 保证 renamed + skipped 与提交数严格对账(每 id 恰落一桶)
    for asset_id in raced_ids:
        cur = (
            await db.execute(
                select(Asset.deleted_at, Asset.filename).where(Asset.id == asset_id)
            )
        ).first()
        if cur is None or cur[0] is not None:
            reasons.deleted += 1  # 并发软删 / hard purge
        elif unicodedata.normalize("NFC", cur[1]).startswith(prefix_nfc):
            reasons.already_prefixed += 1  # 并发 add 已叠上前缀(NFC 口径)
        elif cur[1].startswith(payload.prefix):
            # 兜底原始字节命中:PG 与 Python 的 Unicode 版本差会让两者 NFC 结果
            # 不一致,谓词与归因口径可能错位 —— 按已带前缀归因
            reasons.already_prefixed += 1
        else:
            # 理论不可达(谓词与归因口径一致);留桶兜底保证对账闭合,不 500
            log.warning(
                "batch_prefix reconcile fallback asset=%s action=%s prefix=%r",
                asset_id, payload.action, prefix_nfc,
            )
            reasons.deleted += 1

    await db.commit()

    # 聚合 audit:采样前 50 条 {id, old, new},超出只以 renamed/skipped 计数
    skipped_total = sum(reasons.model_dump().values())
    sample: list[dict[str, str]] = [
        {"id": str(asset_id), "old": snap[asset_id][0], "new": new_names[asset_id]}
        for asset_id in renamed_ids[:50]
    ]
    await audit.write(
        event_type="asset.batch_renamed",
        actor_user_id=user_id,
        target_project_id=target_project_id,
        details={
            "action": payload.action,
            "prefix": prefix_nfc,
            "renamed": len(renamed_ids),
            "skipped": skipped_total,
            "sample": sample,
        },
        **ctx,
    )
    return AssetBatchPrefixOut(
        renamed=len(renamed_ids),
        skipped=skipped_total,
        skipped_reasons=reasons,
    )


# ─── download link ────────────────────────────────────────────────────────────
class DownloadLinkIn(BaseModel):
    """download-link 可选请求体(移动端下载直连,方案 §3.5)。

    向后兼容:不传 body / `{}` 均可,as_attachment 默认 False → 行为与旧版
    完全一致(inline 语义,桌面 PDF iframe 预览不受影响)。
    """

    as_attachment: bool = False


def rfc5987_encode(filename: str) -> str:
    """RFC 5987 ext-value 的 pct-encoded 部分:UTF-8 百分号编码(safe="" 全量转义)。"""
    return quote(filename, safe="", encoding="utf-8")


def _quoted_string(value: str) -> str:
    """RFC 6266 quoted-string:转义反斜杠与双引号。"""
    return value.replace("\\", "\\\\").replace('"', '\\"')


def _ascii_fallback(filename: str) -> str:
    """quoted-string 里的 ASCII 兜底:非 ASCII / 控制字符替换为 `_`(保扩展名)。

    全部被替换导致空串时回落 "download"(中文名对不识别 RFC 5987 的老客户端
    至少给个合法值)。
    """
    out = "".join(ch if ch.isascii() and ch.isprintable() else "_" for ch in filename)
    return out.strip() or "download"


def attachment_content_disposition(filename: str) -> str:
    """构造 attachment 语义的 Content-Disposition 值(RFC 6266 + RFC 5987)。

    - 纯 ASCII 文件名:`attachment; filename="<引号转义后的原名>"`。
    - 含非 ASCII:quoted-string 放 ASCII 兜底,原文名走
      `filename*=UTF-8''<RFC 5987 百分号编码>`(移动端中文素材落盘文件名正确)。
    """
    if filename.isascii():
        return f'attachment; filename="{_quoted_string(filename)}"'
    fallback = _quoted_string(_ascii_fallback(filename))
    return (
        f'attachment; filename="{fallback}"; '
        f"filename*=UTF-8''{rfc5987_encode(filename)}"
    )


@router.post("/{asset_id}/download-link", response_model=DownloadLinkOut)
async def get_download_link(
    asset_id: uuid.UUID,
    data: DownloadLinkIn | None = None,
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    presign: PresignService = Depends(get_presign),
    audit: AuditService = Depends(get_audit),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
    ctx: dict = Depends(get_request_context),
) -> DownloadLinkOut:
    user_id = user.id
    """签 presigned GET URL;check can_download asset + audit signed_url_issued。
    系统 admin 直通(audit 仍记)。软删行 404 —— 回收站语义:要取回先 restore
    (与 meta / live-preview / share 同口径,唯本 endpoint 此前漏查)。"""
    asset = await db.get(Asset, asset_id)
    if not asset or asset.deleted_at is not None:
        raise HTTPException(404, "asset not found")

    allowed = is_system_admin or await permissions.check(
        user_subject=user.subject,
        relation="can_download",
        object_type="asset",
        object_id=str(asset_id),
    )
    if not allowed:
        await audit.write(
            event_type="download_denied",
            actor_user_id=user_id,
            target_asset_id=asset_id,
            target_minio_key=asset.minio_key,
            details={"reason": "openfga can_download false"},
            **ctx,
        )
        raise HTTPException(403, "no permission to download(可申请审批)")

    settings = get_settings()
    ttl = settings.presigned_normal_ttl_seconds
    # as_attachment=true → attachment 语义(移动端系统下载器直连,方案 §3.5);
    # 默认 None 不带 ResponseContentDisposition,预览路径(inline)零变化
    disposition = (
        attachment_content_disposition(asset.filename)
        if data is not None and data.as_attachment
        else None
    )
    url = presign.sign_get_url(
        asset.minio_bucket, asset.minio_key, ttl,
        response_content_disposition=disposition,
    )

    await audit.signed_url_issued(
        actor_user_id=user_id,
        target_asset_id=asset.id,
        target_minio_key=asset.minio_key,
        details={"expires_in_seconds": ttl},
        **ctx,
    )

    return DownloadLinkOut(url=url, expires_in=ttl, is_sensitive=False)


# ─── thumbnail URL — B-4 (轻量,签短 ttl presigned,不走 OpenFGA enforce)──────
@router.get("/{asset_id}/thumbnail-url")
async def get_thumbnail_url(
    asset_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
    presign: PresignService = Depends(get_presign),
    user: CurrentUser = Depends(get_current_user),
) -> dict:
    """缩略图 presigned URL — 至少要登录;不再做 per-asset OpenFGA check
    (缩略图 1024px 模糊化,信息密度低,信任组织内可见性)。

    软删(deleted_at 置位)行照常返回 —— 回收站列表(管理员可见)的缩略图
    走同一 endpoint,拒绝会让回收站里每行都打一个 404;彻底删除后行不存
    在才 404。无 thumbnail_key(还没生成 / 非图)→ 404。
    """
    _ = user.id  # 至少要认证
    asset = await db.get(Asset, asset_id)
    if asset is None:
        raise HTTPException(404, "asset not found")
    thumbnail_key = (asset.tags or {}).get("thumbnail_key")
    if not thumbnail_key:
        raise HTTPException(404, "no thumbnail yet(可能还在生成 / 非图片)")

    ttl = 1800   # 30 min — 缩略图比原图 ttl 长(让浏览器缓存有效)
    # ADR-0008 P1:缩略图走独立 bucket + 缩略图 MinIO(SSD);endpoint/bucket 由 env 控制
    url = presign.sign_thumbnail_url(thumbnail_key, ttl)
    return {"url": url, "expires_in": ttl}


# ─── delete(soft / hard)───────────────────────────────────────────────────
@router.delete("/{asset_id}", status_code=204)
async def delete_asset(
    asset_id: uuid.UUID,
    hard: bool = Query(False, description="true=彻底删除(仅对已软删的文件)"),
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    presign: PresignService = Depends(get_presign),
    audit: AuditService = Depends(get_audit),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
    ctx: dict = Depends(get_request_context),
) -> None:
    user_id = user.id
    """删除文件。默认软删:置 deleted_at,MinIO 对象保留,可在回收站恢复。

    hard=true 为彻底删除:删 DB 行 + MinIO 原对象 + 缩略图派生对象 + OpenFGA
    tuple,不可恢复 —— 须先软删(两步制,防误操作一击穿底)。权限均为
    asset.can_admin;系统 admin 直通。**hard 分支对 sensitive 资产仅系统 admin**
    (F1):项目 admin 继承 can_admin 但无 can_view,不能对受邀制内容做不可逆
    销毁(与 list_trash / restore 收口同口径;软删为存量能力,维持不变)。
    """
    asset = await db.get(Asset, asset_id)
    if not asset:
        raise HTTPException(404, "asset not found")

    allowed = is_system_admin or await permissions.check(
        user_subject=user.subject, relation="can_admin",
        object_type="asset", object_id=str(asset_id),
    )
    if not allowed:
        await audit.write(
            event_type="access_denied", actor_user_id=user_id,
            target_asset_id=asset_id, target_minio_key=asset.minio_key,
            details={"action": "delete_asset", "reason": "openfga can_admin false"},
            **ctx,
        )
        raise HTTPException(403, "no delete permission")

    # sensitive 门在 can_admin 之后(同 restore:零权限者只见通用 403,不借文案
    # 得知资产敏感分类);仅 hard 分支 —— 软删为存量语义维持不变
    if hard:
        folder = await db.get(Folder, asset.folder_id)
        if folder is not None and folder.is_sensitive and not is_system_admin:
            await audit.write(
                event_type="access_denied", actor_user_id=user_id,
                target_asset_id=asset_id, target_minio_key=asset.minio_key,
                details={"action": "delete_asset",
                         "reason": "sensitive non-system-admin (hard)"},
                **ctx,
            )
            raise HTTPException(403, "sensitive 资产的彻底删除仅系统 admin 可操作")

    if hard:
        if asset.deleted_at is None:
            raise HTTPException(409, "请先删除(软删)后再彻底清除")
        # commit 前快照:delete 后实例属性过期不可读
        snapshot = {
            "bucket": asset.minio_bucket, "key": asset.minio_key,
            "tags": dict(asset.tags or {}), "filename": asset.filename,
        }
        try:
            await db.delete(asset)
            await db.commit()
        except StaleDataError as e:
            # 并发 hard purge 竞速:另一请求已删行(ORM 校验 DELETE rowcount 报
            # StaleDataError)—— 幂等处理为 404,不裸 500 误导重试
            await db.rollback()
            raise HTTPException(404, "文件已被彻底删除") from e

        # ── DB 删除成功之后:清理失败只留无害孤儿 ──
        # MinIO 删除是同步 boto3(重试+超时最坏数分钟),丢线程池执行,
        # 防止 MinIO 抖动时阻塞事件循环冻结整个 API
        await asyncio.to_thread(
            purge_asset_storage,
            presign, snapshot["bucket"], snapshot["key"], snapshot["tags"],
        )
        try:
            from openfga_sdk.client.models import ClientTuple, ClientWriteRequest
            from openfga_sdk.models import ReadRequestTupleKey
            resp = await permissions._client.read(  # type: ignore[attr-defined]
                ReadRequestTupleKey(object=f"asset:{asset_id}")
            )
            for t in resp.tuples:
                try:
                    await permissions._client.write(  # type: ignore[attr-defined]
                        ClientWriteRequest(deletes=[ClientTuple(
                            user=t.key.user, relation=t.key.relation, object=t.key.object,
                        )])
                    )
                except Exception:
                    log.debug("asset tuple delete tolerate %s %s %s",
                              t.key.user, t.key.relation, t.key.object)
        except Exception as e:
            log.warning("purge asset tuple cleanup fail asset=%s err=%s", asset_id, e)

        # audit 落库:不能带 target_asset_id —— 行已删,audit_events.target_asset_id
        # 的 FK 会 violations;溯源用 target_minio_key(无 FK)+ details.asset_id
        await audit.write(
            event_type="asset_purged", actor_user_id=user_id,
            target_minio_key=snapshot["key"],
            details={"asset_id": str(asset_id), "filename": snapshot["filename"],
                     "hard": True},
            **ctx,
        )
        return

    if asset.deleted_at is not None:
        return  # idempotent

    asset.deleted_at = datetime.now(timezone.utc)
    try:
        await db.commit()
    except StaleDataError as e:
        # 软删与并发 hard purge 竞速(0 行 UPDATE 同样抛 StaleDataError)→ 幂等 404
        await db.rollback()
        raise HTTPException(404, "文件已被彻底删除") from e

    await audit.write(
        event_type="asset_deleted", actor_user_id=user_id,
        target_asset_id=asset_id, target_minio_key=asset.minio_key,
        details={"filename": asset.filename, "soft": True},
        **ctx,
    )


# ─── livp 实况视频预览 URL ────────────────────────────────────────────────────
@router.get("/{asset_id}/live-preview-url")
async def get_live_preview_url(
    asset_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    presign: PresignService = Depends(get_presign),
    audit: AuditService = Depends(get_audit),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
    ctx: dict = Depends(get_request_context),
) -> dict:
    """livp 实况视频(ffmpeg 转码的 H.264 短片)presigned URL。

    与缩略图不同:实况视频是接近原片的内容,不走「缩略图不过 enforce」的豁免,
    按 can_download 强制 + audit(与 download-link 同门槛;预览弹窗本就先过
    download-link,权限语义一致)。无 live_video_key(非 livp / 转码失败)→ 404。
    """
    user_id = user.id
    asset = await db.get(Asset, asset_id)
    if asset is None or asset.deleted_at is not None:
        raise HTTPException(404, "asset not found")
    live_key = (asset.tags or {}).get("live_video_key")
    if not live_key:
        raise HTTPException(404, "no live preview(非 livp 或实况转码未生成)")

    allowed = is_system_admin or await permissions.check(
        user_subject=user.subject,
        relation="can_download",
        object_type="asset",
        object_id=str(asset_id),
    )
    if not allowed:
        await audit.write(
            event_type="download_denied", actor_user_id=user_id,
            target_asset_id=asset_id, target_minio_key=asset.minio_key,
            details={"reason": "openfga can_download false", "kind": "live_preview"},
            **ctx,
        )
        raise HTTPException(403, "no permission to preview(可申请审批)")

    ttl = 1800
    url = presign.sign_thumbnail_url(str(live_key), ttl)
    await audit.signed_url_issued(
        actor_user_id=user_id,
        target_asset_id=asset.id,
        target_minio_key=asset.minio_key,
        details={"kind": "live_preview", "expires_in_seconds": ttl},
        **ctx,
    )
    return {"url": url, "expires_in": ttl}


# ─── helpers ──────────────────────────────────────────────────────────────────
_MAX_LABELS = 50
_MAX_LABEL_LEN = 64  # 与 tables.assets.user_labels ARRAY(String(64)) 对齐


def _escape_like(q: str) -> str:
    """转义 ILIKE 通配符(%, _, 反斜杠),让 q 按字面匹配。"""
    return q.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def _normalize_labels(labels: list[str]) -> list[str]:
    """trim + 去空 + 截断超长 + 去重,上限 _MAX_LABELS 个(防止滥用撑爆 token 预算)。"""
    out: list[str] = []
    seen: set[str] = set()
    for raw in labels:
        label = raw.strip()
        if not label:
            continue
        if len(label) > _MAX_LABEL_LEN:
            label = label[:_MAX_LABEL_LEN]
        if label in seen:
            continue
        seen.add(label)
        out.append(label)
        if len(out) >= _MAX_LABELS:
            break
    return out


async def _project_bucket(db: AsyncSession, project_id: uuid.UUID) -> str:
    project = await db.get(Project, project_id)
    if not project:
        raise HTTPException(400, "project not found")
    return project.minio_bucket
