"""assets router — uppy 5-endpoint + list + download + iter4 enforce + audit。

Phase B-2 iter4:每 endpoint 加 OpenFGA check + audit 落库。
"""
from __future__ import annotations

import asyncio
import contextlib
import itertools
import json
import logging
import time
import unicodedata
import uuid
from collections import Counter
from datetime import UTC, datetime, timezone
from typing import Any, Literal, cast
from urllib.parse import quote

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel, Field
from sqlalchemy import ColumnElement, and_, func, literal_column, or_, select, true, update
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
    AssetBatchMoveIn,
    AssetBatchMoveOut,
    AssetBatchMoveSkipOut,
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
from app.services.org import user_is_org_file_deleter
from app.services.permissions import PermissionsService, is_already_exists_error
from app.services.presign import PresignService, request_base_from
from app.services.thumb_exts import is_image_asset, is_video_asset
from app.settings import get_settings
from app.workers.batch_download import (
    AUDITED_TTL,
    BATCH_URL_TTL,
    JOB_RECORD_TTL,
    acquire_batch_locks,
    batch_active_key,
    batch_audited_key,
    batch_fail_key,
    batch_job_record_key,
    batch_keygate_key,
    batch_object_key,
    canonical_ids,
    compute_batch_key,
    release_batch_locks,
)

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

    # 空基名点文件(如 App 相册 title 空串拼出的 '.livp'):web 显示名为空,
    # 且点文件在按扩展名分派的链路(缩略图等)被判无扩展名,create 期一并拦掉
    if not payload.filename.rsplit(".", 1)[0].strip():
        raise HTTPException(400, "filename 不能为空基名点文件(如 .livp,缺少主文件名)")

    # 同夹同名查重(D1-B 前置,决策 14):系统此前靠「一夹一名」的 key 唯一间接
    # 保证同名互斥;目录树重组(D1-B:物理对象不动、DB 重算 prefix)后该不变量
    # 失去物理支撑,上传侧补应用层查重 —— 与百度导入 (folder_id, filename) 查重
    # 同口径(baidu_backup.py,排除软删行,回收站恢复后不误拦)。在 create 期
    # (签 multipart 之前)失败,不产生 MinIO 半成品。
    dup = await db.scalar(
        select(func.count()).select_from(Asset).where(
            Asset.folder_id == payload.folder_id,
            Asset.filename == payload.filename,
            Asset.deleted_at.is_(None),
        )
    )
    if dup:
        raise HTTPException(409, "该文件夹已存在同名文件,请重命名后重新上传")

    key = f"{folder.minio_prefix.rstrip('/')}/{payload.filename}"
    bucket = await _project_bucket(db, folder.project_id)

    upload_id = presign.create_multipart_upload(bucket, key, payload.content_type)
    return UploadMultipartCreateOut(upload_id=upload_id, key=key, bucket=bucket)


@router.get("/uploads/{upload_id}/parts/{part_number}", response_model=UploadPartUrlOut)
async def sign_part(
    upload_id: str,
    part_number: int,
    request: Request,
    bucket: str = Query(...),
    key: str = Query(...),
    presign: PresignService = Depends(get_presign),
    user: CurrentUser = Depends(get_current_user),  # 至少要认证;细粒度上传 check 在 create_upload 已做
) -> UploadPartUrlOut:
    settings = get_settings()
    # 动态签发:分片 PUT URL 的 host 跟随浏览器入口(https 入口否则被混合内容拦)
    url = presign.sign_part_url(
        bucket, key, upload_id, part_number,
        expires_seconds=settings.presigned_normal_ttl_seconds,
        request_base=request_base_from(request),
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
    # .livp(iOS Live Photo,实为 zip)浏览器不识别 content-type,按扩展名分派专属 worker;
    # livp 分支并排多派一个下载级解包 job(livp-download-unpack 方案 §2.1,F2)
    # thumb-variant 方案 §3.5:video/image 判定改 is_video_asset/is_image_asset
    # (content_type 前缀 OR 扩展名兜底,修 Firefox 上传 .mov/.heic 落 octet-stream
    # 的派发盲区;svg 不派发属预期,清单刻意不含);livp 文件名判定维持现状且优先级最高
    ct = asset.content_type or ""
    if asset.filename.lower().endswith(".livp"):
        from app.services.arq_pool import enqueue_livp_download, enqueue_livp_thumbnail
        await enqueue_livp_thumbnail(request.app.state.arq_pool, str(asset.id))
        await enqueue_livp_download(request.app.state.arq_pool, str(asset.id))
    elif is_image_asset(asset.filename, ct):
        from app.services.arq_pool import enqueue_thumbnail
        await enqueue_thumbnail(request.app.state.arq_pool, str(asset.id))
    elif is_video_asset(asset.filename, ct):
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
    locate: uuid.UUID | None = Query(None),
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
    locate_index: int | None = None
    if locate is not None:
        # 单列 scalar:db.scalar 只回首行第一列(多列 select 是 Row,取 .created_at 必炸)
        target_created = await db.scalar(
            select(Asset.created_at).where(
                Asset.id == locate,
                Asset.folder_id == folder_id,
                Asset.deleted_at.is_(None),
            )
        )
        if target_created is not None:
            # 与列表同元组 (created_at DESC, id DESC):严格"更靠前"的行数 = 0 基序号。
            # id tiebreaker 不能省:批量上传 created_at 全并列,只比 created_at 会漂位;
            # target id 就是入参 locate 本身,无需回查。
            newer = await db.scalar(
                select(func.count()).select_from(Asset).where(
                    Asset.folder_id == folder_id,
                    Asset.deleted_at.is_(None),
                    or_(
                        Asset.created_at > target_created,
                        and_(Asset.created_at == target_created, Asset.id > locate),
                    ),
                )
            )
            locate_index = newer or 0
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
        locate_index=locate_index,
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
    """列 folder 内已软删的文件(回收站)。普通 folder 需 can_admin,或组级
    file_deleter 且 can_view(2026-10-16 组删除授权 F5:软删→清空回收站闭环
    对组员放开;授权且可见)。

    **sensitive folder 仅系统 admin**(组织开关分支不穿透 sensitive,现状不变):
    敏感目录 can_view 不含项目 admin(受邀制),
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
        # 组级「删除文件/文件夹」开关分支(F5):授权且可见;短路在 can_admin
        # 失败之后,常规路径不多打 org 解析与 check
        if not allowed and await user_is_org_file_deleter(
            permissions, db, user_id=str(user.id),
        ):
            allowed = await permissions.check(
                user_subject=user.subject,
                relation="can_view",
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
    """恢复软删文件(deleted_at 置回 NULL)。需 asset.can_admin / 系统 admin,
    或组级 file_deleter 且 asset.can_view(2026-10-16 组删除授权 F6,仅非
    sensitive 资产)。

    软删不动 OpenFGA tuple 与 MinIO 对象,恢复即回到删除前的权限/内容状态。
    sensitive 资产仅系统 admin:项目 admin 从父项目继承 can_admin 但无 can_view
    (受邀制),不能对看不见的敏感内容做恢复(F1,与 list_trash 收口同口径);
    组织开关分支同样不穿透 sensitive(F6 红线)。"""
    user_id = user.id
    asset = await db.get(Asset, asset_id)
    if not asset:
        raise HTTPException(404, "asset not found")

    # sensitive 判定与 delete/list_trash 特判同源:随所属 folder.is_sensitive
    folder = await db.get(Folder, asset.folder_id)
    is_sensitive = folder is not None and folder.is_sensitive
    # W2b:审计补 target_project_id(folder 行被并发删的竞速窗口回 None,不炸)
    project_id = folder.project_id if folder is not None else None

    allowed = is_system_admin or await permissions.check(
        user_subject=user.subject, relation="can_admin",
        object_type="asset", object_id=str(asset_id),
    )
    # 组级「删除文件/文件夹」开关分支(F6):授权且可见;短路在 can_admin 失败
    # 之后,常规路径不多打 org 解析与 check(and 短路序同嵌套 if)
    if (
        not allowed
        and not is_sensitive
        and await user_is_org_file_deleter(permissions, db, user_id=str(user_id))
    ):
        allowed = await permissions.check(
            user_subject=user.subject, relation="can_view",
            object_type="asset", object_id=str(asset_id),
        )
    if not allowed:
        await audit.write(
            event_type="access_denied", actor_user_id=user_id,
            target_asset_id=asset_id, target_project_id=project_id,
            target_minio_key=asset.minio_key,
            details={"action": "restore_asset", "reason": "openfga can_admin false"},
            **ctx,
        )
        raise HTTPException(403, "no restore permission")

    # sensitive 门在 can_admin 之后:零权限探测者只见上面的通用 403,不借文案
    # 得知"该资产是否敏感"(分类元数据);到这里的只有项目 admin / 系统 admin
    if is_sensitive and not is_system_admin:
        await audit.write(
            event_type="access_denied", actor_user_id=user_id,
            target_asset_id=asset_id, target_project_id=project_id,
            target_minio_key=asset.minio_key,
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
        target_asset_id=asset_id, target_project_id=project_id,
        target_minio_key=asset.minio_key,
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


# ─── 批量文件名前缀(方案 §1.1;key 同步迁移 §F3)────────────────────────────
class BatchPrefixReasonsOut(BaseModel):
    """跳过原因计数(键固定 ASCII,前端中文映射;deleted = 已删/不存在,不细分)。

    七类:原五类(NFC/谓词/软删语义)+ F3 key 迁移新增两类 —— key_conflict
    (新 key 已被其他资产行引用,含软删)与 key_copy_failed(MinIO copy 失败)。
    """

    too_long: int = 0
    no_match: int = 0
    already_prefixed: int = 0
    empty_result: int = 0
    deleted: int = 0
    key_conflict: int = 0
    key_copy_failed: int = 0


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
    presign: PresignService = Depends(get_presign),  # noqa: B008  # FastAPI DI,repo 全量同款
    audit: AuditService = Depends(get_audit),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
    ctx: dict[str, Any] = Depends(get_request_context),
) -> AssetBatchPrefixOut:
    """批量加 / 去文件名前缀,并同步迁移 MinIO key(F3,根治 filename≠key 残留)。

    语义:add = prefix + filename,已带该前缀跳过(already_prefixed),结果
    >512 跳过(too_long);remove = 恰好以 prefix 开头(大小写敏感)剥离一次,
    否则 no_match,剥离后空串 empty_result。

    **前缀比较两侧 NFC 归一**:存量 filename 多为 macOS 拖入的 NFD 原样落库,
    只归一输入侧会不命中;比较用 NFC(filename).startswith(prefix_nfc);
    remove 余量 = NFC(filename)[len(prefix_nfc):] 落库(NFC 串码点数与原串
    不同,不能按原串长度切);add 结果按 NFC 落库(库内 filename 逐步收敛 NFC)。

    **key 迁移(F3)**:新 filename 确定后按 complete_upload 同规则算新 key
    (`{folder.minio_prefix.rstrip('/')}/{新 filename}`);新 key 被其他资产行
    引用(含软删,与导入侧 `_key_conflict_holders` 同口径)→ 该文件 skip
    (key_conflict,行不动);否则 MinIO copy_object(旧 key→新 key)失败 →
    skip(key_copy_failed,行不动);copy 成功 → UPDATE 行(filename+minio_key,
    etag 用 copy 返回的新值,没有则保留原值;size_bytes/content_type 不变),
    **事务 commit 成功后**再删旧对象 —— 删前重验现值,旧 key 已被其他行重新
    引用(链式改名同批互踩/并发写回)则保留对象防悬挂引用;delete 失败仅
    log.warning 留孤儿(行已指向新 key,孤儿不可见无权限含义,不回滚不抛错)。

    权限:按 folder_id 分组逐组 can_upload check(对齐 update_asset_meta;
    敏感夹按 sensitive_folder 类型 —— 受邀 downloader 亦可改名,与打标同语义),
    系统 admin 直通;任一组无权限 → 403 整批不执行,文案笼统不带 folder 名
    (反探测约定,与 GET /assets 403 同口径)。

    实现五步(单事务):① asset_ids 去重 + SELECT 快照(软删行查不到 → 计
    deleted);② Python 端按语义算新名分桶;③ Core 语句逐 id UPDATE —— 不用
    ORM flush(并发 hard purge 抛 StaleDataError,restore 先例),不用单条
    IN...RETURNING(add 各 id 新名不同,executemany 不累积 RETURNING);add
    谓词 NOT starts_with(normalize(filename, NFC), :prefix) 是二次防线,防
    SELECT 与 UPDATE 之间并发提交的 add 叠出双前缀(remove 侧不加内容谓词,
    字节级谓词与 NFC 口径不对称,对 NFD 存量名会静默不命中);④ rowcount=0
    补查归因,保证 renamed + skipped 与提交数严格对账;⑤ commit 成功后逐个
    删除已迁移行的旧 MinIO 对象(串行 to_thread;删前重验旧 key 无任何行
    现值引用,防链式改名互踩删掉他人现指向的对象;失败留孤儿)。MinIO 的
    copy/delete 是同步 boto3(重试+超时最坏数分钟),一律 asyncio.to_thread
    执行,防 MinIO 抖动时阻塞事件循环(delete_asset hard 分支同款)。
    """
    user_id = user.id
    # prefix 已在 AssetBatchPrefixIn 校验器里 NFC 归一;此处再归一一次是幂等的,
    # 让「两侧 NFC」口径在使用点显式可见
    prefix_nfc = unicodedata.normalize("NFC", payload.prefix)
    reasons = BatchPrefixReasonsOut()

    # ① 去重(dict.fromkeys 保序,防重复 id 被计入 deleted/统计两次)+ 快照
    # (快照含 bucket/key/folder 前缀:F3 逐文件算新 key、跨资产占用预检、
    #  copy/delete 都要用,避免循环内二次查询)
    unique_ids = list(dict.fromkeys(payload.asset_ids))
    rows = (
        await db.execute(
            select(
                Asset.id, Asset.filename, Asset.folder_id,
                Asset.minio_bucket, Asset.minio_key,
                Folder.minio_prefix, Folder.project_id, Folder.is_sensitive,
            )
            .join(Folder, Asset.folder_id == Folder.id)
            .where(Asset.id.in_(unique_ids), Asset.deleted_at.is_(None))
        )
    ).all()
    snap: dict[uuid.UUID, tuple[str, uuid.UUID, bool, str, str, str]] = {}
    # snap 值 = (filename, folder_id, is_sensitive, bucket, old_key, minio_prefix)
    folder_groups: dict[uuid.UUID, bool] = {}  # folder_id -> is_sensitive
    project_ids: set[uuid.UUID] = set()
    for (asset_id, filename, folder_id, bucket, old_key,
         minio_prefix, project_id, is_sensitive) in rows:
        snap[asset_id] = (filename, folder_id, is_sensitive, bucket, old_key, minio_prefix)
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

    # ③ 逐文件 key 迁移 + 单事务 UPDATE(F3)。顺序:跨资产占用预检 → MinIO
    # copy_object(旧 key→新 key)→ UPDATE 行(filename+minio_key)→ 统一 commit
    # 后删旧对象。预检与导入侧 _key_conflict_holders 同口径:含软删行(软删行仍引用
    # 旧对象,写该 key 会覆盖其内容),排除自身。同一批内前序行已写入本事务的
    # 新 key 对后续行的预检可见(读己之写),批内互撞自然落到 key_conflict。
    # copy/delete 是同步 boto3(重试+超时最坏数分钟),一律 asyncio.to_thread
    # 执行(防 MinIO 抖动冻结事件循环,delete_asset hard 分支同款);逐文件串行,
    # 量级 ≤1000 小文件可接受,不并行轰炸 MinIO。
    renamed_ids: list[uuid.UUID] = []
    raced_ids: list[uuid.UUID] = []
    moved_old_objects: list[tuple[str, str]] = []  # (bucket, 旧 key) — commit 成功后删
    for asset_id, new_name in new_names.items():
        _, _, _, bucket, old_key, minio_prefix = snap[asset_id]
        new_key = _new_asset_key(minio_prefix, new_name)
        copy_meta: dict[str, Any] | None = None
        if new_key != old_key:
            # 新 key 已被其他资产行引用(含软删)→ skip,行不动(不偷别人的对象)
            occupied = await db.scalar(
                select(func.count()).select_from(Asset).where(
                    Asset.minio_bucket == bucket,
                    Asset.minio_key == new_key,
                    Asset.id != asset_id,
                )
            )
            if occupied:
                reasons.key_conflict += 1
                continue
            try:
                copy_meta = await asyncio.to_thread(
                    presign.copy_object, bucket, old_key, new_key,
                )
            except Exception as e:  # MinIO 侧任何失败都只 skip 该文件(留 log 供排查)
                log.warning(
                    "batch_prefix copy failed asset=%s bucket=%s %r -> %r err=%s",
                    asset_id, bucket, old_key, new_key, e,
                )
                reasons.key_copy_failed += 1
                continue
        # Core 语句逐 id UPDATE。add 谓词里的 normalize form 参数是不带引号的
        # SQL 关键字 NFC(literal_column —— 写成 'NFC' 字符串是 PG 语法错误);
        # 用 starts_with 不用 LIKE(_ / % 通配符会被误拦,免转义先例
        # _escape_like)。rowcount 由逐条 UPDATE 直接拿,不依赖 ORM flush 校验。
        stmt = update(Asset).where(Asset.id == asset_id, Asset.deleted_at.is_(None))
        if payload.action == "add":
            stmt = stmt.where(
                ~func.starts_with(
                    func.normalize(Asset.filename, literal_column("NFC")), prefix_nfc
                )
            )
        values: dict[str, Any] = {"filename": new_name}
        if copy_meta is not None:
            values["minio_key"] = new_key
            # etag 用 copy 返回的新值,没有则保留原值(不写该键);version_id 同款
            # 口径 —— 无版本化 bucket copy 不返回,行值保持;size_bytes/content_type
            # 语义不变(对象是同一份内容的服务端拷贝)
            if copy_meta.get("etag"):
                values["etag"] = copy_meta["etag"]
            if copy_meta.get("version_id"):
                values["minio_version_id"] = copy_meta["version_id"]
        result = await db.execute(stmt.values(**values))
        # asyncpg DML 实际返回 CursorResult(带 rowcount);基类 Result 的类型
        # 标注未声明该属性,cast 仅为过 mypy strict,运行时行为不变
        if cast("CursorResult[Any]", result).rowcount == 1:
            renamed_ids.append(asset_id)
            if copy_meta is not None:
                moved_old_objects.append((bucket, old_key))
        else:
            # SELECT 与 UPDATE 之间行被并发变更(软删/竞写):该行 UPDATE 未生效,
            # DB 自洽;已做的 copy 成孤儿(不可见、无权限含义)不补偿删除 ——
            # 旧对象仍被该行(若还在)引用,必须保留;新 key 对象也绝不能删
            # (可能已是并发写方的合法对象)
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

    # F3 新增暴露面:UPDATE 现在含 minio_key,预检之后、commit 之前的并发窗口
    # 里他事务插入/改到同一 (bucket, key, version_id) 会撞
    # uq_asset_minio_object_version。PG 约束冲突中止整个事务 → 整批回滚(逐文件
    # UPDATE 同事务,部分成功只在「copy 失败 skip」这一层承诺);已 copy 的对象
    # 成孤儿(不可见、无权限含义),重试的预检按 DB 行计数不会被孤儿挡住。
    # 409 与 complete_upload 的 IntegrityError→409 同语义。
    try:
        await db.commit()
    except IntegrityError as e:
        await db.rollback()
        raise HTTPException(
            409, "部分文件的目标位置被并发修改,请刷新后重试"
        ) from e

    # ⑤ commit 成功后清理旧对象(F3 时序:行已持久指向新 key 才动手删)。
    # 删前重验现值:本事务已提交,重查即全库当前引用 —— 旧 key 若已被任何行的
    # 现值重新引用(链式改名同批互踩:Y 先迁出让出旧 key,同批 X 恰迁入该 key,
    # 其 copy 已落在那里;或并发写回),跳过删除留孤儿。该对象此刻的内容已是
    # 引用方所需,硬删就是悬挂引用(静默数据丢失);孤儿不可见、无权限含义,
    # 与 delete 失败同取舍。复查自身失败同样按不删处理(宁孤儿不悬挂)。
    for old_bucket, old_key in moved_old_objects:
        try:
            still_used = await db.scalar(
                select(func.count()).select_from(Asset).where(
                    Asset.minio_bucket == old_bucket,
                    Asset.minio_key == old_key,
                )
            )
        except Exception as e:  # 复查不了就不删,保引用方安全
            log.warning(
                "batch_prefix old key recheck failed (object kept)"
                " bucket=%s key=%s err=%s",
                old_bucket, old_key, e,
            )
            continue
        if still_used:
            log.info(
                "batch_prefix old key re-referenced, object kept"
                " bucket=%s key=%s refs=%s",
                old_bucket, old_key, still_used,
            )
            continue
        try:
            await asyncio.to_thread(presign.delete_object, old_bucket, old_key)
        except Exception as e:  # delete 失败只留孤儿,绝不向上抛(行已指向新 key)
            log.warning(
                "batch_prefix old object delete failed (orphan kept)"
                " bucket=%s key=%s err=%s",
                old_bucket, old_key, e,
            )

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
            # F3:key 是否发生迁移 + 迁移条数(混合批次下裸布尔不歧义,补计数)
            "key_moved": bool(moved_old_objects),
            "key_moved_count": len(moved_old_objects),
            "sample": sample,
        },
        **ctx,
    )
    return AssetBatchPrefixOut(
        renamed=len(renamed_ids),
        skipped=skipped_total,
        skipped_reasons=reasons,
    )


# ─── 批量移动(W6 一期:项目内移动,方案 §6.2)─────────────────────────────────
# 单次 OpenFGA write 的 tuple 操作余量上限(服务端默认 100/请求,留 10 余量);
# 每资产占 1 写 + N 删(通常 2)→ 约 40-50 资产/批,与方案「约 50 资产/批」对齐
_FGA_MOVE_BATCH_OPS = 90
_FGA_MOVE_ATTEMPTS = 3  # 单批 / 降级单资产的写尝试次数(含首次)


async def _assert_target_not_sensitive_descendant(db: AsyncSession, target: Folder) -> None:
    """目标夹 = sensitive 夹本身允许(门槛 can_admin 在权限段);目标夹是
    「sensitive 后代的普通子夹」(孤儿位,badge 方案 §6.3)一律拒绝 —— 含系统
    admin。沿 parent 链上行判敏感(sensitive 是子树级语义);seen 集合防脏数据
    成环死循环(W4/W5 的防环是写入侧防线,这里是读取侧兜底)。"""
    if target.is_sensitive:
        return
    seen: set[uuid.UUID] = {target.id}
    parent_id = target.parent_folder_id
    while parent_id is not None and parent_id not in seen:
        seen.add(parent_id)
        parent = await db.get(Folder, parent_id)
        if parent is None:
            break  # 父链断(并发删):继续上行无意义,按可判定的部分放行
        if parent.is_sensitive:
            raise HTTPException(400, "目标文件夹位于敏感目录之下,不允许作为移动目标")
        parent_id = parent.parent_folder_id


@router.post("/batch-move", response_model=AssetBatchMoveOut)
async def batch_move_assets(
    payload: AssetBatchMoveIn,
    db: AsyncSession = Depends(get_db),  # noqa: B008  # FastAPI DI,repo 全量同款
    permissions: PermissionsService = Depends(get_permissions),  # noqa: B008  # FastAPI DI,repo 全量同款
    audit: AuditService = Depends(get_audit),  # noqa: B008  # FastAPI DI,repo 全量同款
    user: CurrentUser = Depends(get_current_user),  # noqa: B008  # FastAPI DI,repo 全量同款
    is_system_admin: bool = Depends(get_is_system_admin),
    ctx: dict[str, Any] = Depends(get_request_context),  # noqa: B008  # FastAPI DI,repo 全量同款
) -> AssetBatchMoveOut:
    """项目内批量移动文件(方案 §6.2 一期):object_key 不动,只 UPDATE folder_id
    + OpenFGA parent tuple 删旧写新(每资产一对放同一 WriteRequest 原子交换)。

    校验链:目标夹存在(404);整批恰属一个项目(跨项目混批 400,project_ids
    归集照 batch-prefix 先例);target_folder.project_id == 批次项目(不等 400,
    防止「项目内」端点成为事实跨项目入口);目标夹为 sensitive 后代的普通子夹
    (孤儿位)一律 400。软删行/不存在 → skip=deleted;已在目标夹 →
    skip=duplicate_location;目标夹已有同名未软删资产(或同批先到者)→
    skip=duplicate_filename(决策 15,与百度导入 (folder_id, filename) 查重同
    口径,排除软删)。

    权限(batch-prefix 分组逐组 check 同款):源夹 sensitive → can_admin(
    sensitive 夹 can_upload 实为 downloader 级,删除侧同款理由),普通 →
    can_upload;目标夹 sensitive → can_admin,普通 → can_upload;系统 admin
    直通;任一组无权限 → 403 整批不执行,文案笼统不带 folder 名(反探测)。

    实现四步:① 去重 + SELECT 快照(batch-prefix ① 同款);② Python 端分桶
    (skip 三类 / 可迁);③ Core 语句逐 id UPDATE 单事务(不用 ORM flush,
    StaleDataError 先例;rowcount=0 补查归因保证严格对账),commit 后 ④ FGA:
    逐资产 read 现有 parent tuple 取精确 user 形态(read-then-delete,assets.py
    硬删分支先例 —— 历史导入侧有一律按 folder: 拼的行,按源夹敏感性拼旧形态会
    删空残留第二父),分批写(失败重试 → 降级单资产 → 仍败进 fga_pending,
    DB 已 commit 不以 500 掩盖;is_already_exists 视作成功 —— OpenFGA write
    整请求原子,重试撞 already exists 说明前一次实际已生效)。恒等式:
    moved_count + len(skipped) + len(fga_pending) = 去重后提交数。
    """
    user_id = user.id

    # ① 去重(dict.fromkeys 保序,防重复 id 双计)+ 快照(软删行查不到 → deleted)
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
    snap: dict[uuid.UUID, tuple[str, uuid.UUID]] = {}  # asset_id -> (filename, 源夹)
    folder_groups: dict[uuid.UUID, bool] = {}  # folder_id -> is_sensitive
    project_ids: set[uuid.UUID] = set()
    for asset_id, filename, folder_id, project_id, is_sensitive in rows:
        snap[asset_id] = (filename, folder_id)
        folder_groups.setdefault(folder_id, is_sensitive)
        project_ids.add(project_id)
    batch_project = next(iter(project_ids)) if len(project_ids) == 1 else None

    target = await db.get(Folder, payload.target_folder_id)
    if not target:
        raise HTTPException(404, "target folder not found")
    # 一期项目内硬校验:混批 / 跨项目目标都在写库前拦下(空批=全软删,无源项目,
    # 不走此闸,照常返回全 skip)
    if len(project_ids) > 1:
        raise HTTPException(400, "所选文件属于多个项目,一期仅支持同一项目内批量移动")
    if batch_project is not None and target.project_id != batch_project:
        raise HTTPException(400, "目标文件夹与所选文件不属于同一个项目")
    await _assert_target_not_sensitive_descendant(db, target)

    # ② 权限:源夹逐组 + 目标夹(batch-prefix 同款分组 check;sensitive 一律 can_admin)
    denied_folders: list[uuid.UUID] = []
    for folder_id, is_sensitive in folder_groups.items():
        if is_system_admin:
            continue  # 系统 admin 直通
        allowed = await permissions.check(
            user_subject=user.subject,
            relation="can_admin" if is_sensitive else "can_upload",
            object_type="sensitive_folder" if is_sensitive else "folder",
            object_id=str(folder_id),
        )
        if not allowed:
            denied_folders.append(folder_id)
    target_allowed = True
    if not is_system_admin:
        target_allowed = await permissions.check(
            user_subject=user.subject,
            relation="can_admin" if target.is_sensitive else "can_upload",
            object_type="sensitive_folder" if target.is_sensitive else "folder",
            object_id=str(target.id),
        )
    if denied_folders or not target_allowed:
        # HTTP 文案笼统不带 folder 名(反探测);audit 略详(folder_id)供溯源
        await audit.write(
            event_type="access_denied",
            actor_user_id=user_id,
            target_project_id=batch_project,
            details={
                "action": "batch_move",
                "reason": "openfga check false",
                "denied_folder_ids": [str(f) for f in denied_folders],
                "target_folder_id": str(target.id),
                "target_folder_denied": not target_allowed,
            },
            **ctx,
        )
        raise HTTPException(403, "所选部分或全部文件无操作权限")

    # ②b Python 端分桶:deleted(快照查不到)/ duplicate_location / duplicate_filename
    skipped: list[AssetBatchMoveSkipOut] = []
    for asset_id in unique_ids:
        if asset_id not in snap:
            skipped.append(AssetBatchMoveSkipOut(asset_id=asset_id, reason="deleted"))
    # 目标夹同名未软删占用名(一次 IN 预检,排除软删 —— 与百度导入口径对齐)
    occupied_names: set[str] = set()
    candidate_names = {row[0] for row in snap.values()}
    if candidate_names:
        occupied_rows = await db.execute(
            select(Asset.filename).where(
                Asset.folder_id == target.id,
                Asset.deleted_at.is_(None),
                Asset.filename.in_(candidate_names),
            )
        )
        occupied_names = {r[0] for r in occupied_rows.all()}
    movable: list[uuid.UUID] = []
    seen_names: set[str] = set()  # 批内同名互斥:同批两个同名文件只迁先到者
    for asset_id in unique_ids:
        row = snap.get(asset_id)
        if row is None:
            continue  # 已计 deleted
        filename, folder_id = row
        if folder_id == target.id:
            skipped.append(
                AssetBatchMoveSkipOut(asset_id=asset_id, reason="duplicate_location")
            )
            continue
        if filename in occupied_names or filename in seen_names:
            skipped.append(
                AssetBatchMoveSkipOut(asset_id=asset_id, reason="duplicate_filename")
            )
            continue
        seen_names.add(filename)
        movable.append(asset_id)

    # ③ 逐 id UPDATE(单事务;rowcount=0 = SELECT 与 UPDATE 之间并发软删/hard
    # purge,补查归因保证对账闭合 —— batch-prefix ③/④ 同款)
    moved_ids: list[uuid.UUID] = []
    raced_ids: list[uuid.UUID] = []
    for asset_id in movable:
        result = await db.execute(
            update(Asset)
            .where(Asset.id == asset_id, Asset.deleted_at.is_(None))
            .values(folder_id=payload.target_folder_id)
        )
        # asyncpg DML 实际返回 CursorResult(带 rowcount);基类 Result 的类型
        # 标注未声明该属性,cast 仅为过 mypy strict,运行时行为不变
        if cast("CursorResult[Any]", result).rowcount == 1:
            moved_ids.append(asset_id)
        else:
            raced_ids.append(asset_id)
    for asset_id in raced_ids:
        cur = (
            await db.execute(select(Asset.deleted_at).where(Asset.id == asset_id))
        ).first()
        if cur is None or cur[0] is not None:
            skipped.append(AssetBatchMoveSkipOut(asset_id=asset_id, reason="deleted"))
        else:
            # 理论不可达(UPDATE 谓词只有软删条件);留桶兜底保证对账闭合,不 500
            log.warning(
                "batch_move reconcile fallback asset=%s target_folder=%s",
                asset_id, payload.target_folder_id,
            )
            skipped.append(AssetBatchMoveSkipOut(asset_id=asset_id, reason="deleted"))

    # 目标夹被并发删除的窗口:FK RESTRICT 在 commit 时撞 assets_folder_id_fkey
    # (整批回滚,与 complete_upload / batch-prefix 的 IntegrityError→409 同语义)
    try:
        await db.commit()
    except IntegrityError as e:
        await db.rollback()
        raise HTTPException(409, "目标文件夹已被并发删除,请刷新后重试") from e

    # ④ FGA parent tuple 交换 —— DB commit 成功之后(folders.py 删除先例时序;
    # §8 红线:FGA 改写一律在 DB commit 后)。失败分叉不回滚 DB、不 500:重试
    # → 降级单资产 → 仍败进 fga_pending(该资产 DB 已在新夹、FGA parent 仍指
    # 旧夹,后台幂等巡检兜底属二期增强)。
    fga_pending: list[uuid.UUID] = []
    if moved_ids:
        from openfga_sdk.client.models import ClientTuple, ClientWriteRequest

        new_parent_user = (
            f"sensitive_folder:{target.id}" if target.is_sensitive else f"folder:{target.id}"
        )
        plans: list[tuple[uuid.UUID, list[ClientTuple], list[ClientTuple]]] = []
        for asset_id in moved_ids:
            try:
                tuples = await permissions.read_all_tuples(
                    object_type="asset", object_id=str(asset_id), relation="parent",
                )
            except Exception as e:  # 读不到 = tuple 态未知,只能进 pending
                log.warning(
                    "batch_move parent tuple read fail asset=%s err=%s", asset_id, e,
                )
                fga_pending.append(asset_id)
                continue
            plans.append((
                asset_id,
                [ClientTuple(user=u, relation=r, object=o) for (u, r, o) in tuples],
                [ClientTuple(
                    user=new_parent_user, relation="parent", object=f"asset:{asset_id}",
                )],
            ))

        def _ops_within(ops: int, plan: tuple[Any, list[ClientTuple], list[ClientTuple]]) -> int:
            return ops + len(plan[1]) + len(plan[2])

        # 按 tuple 操作数分批(单请求 ≤_FGA_MOVE_BATCH_OPS;病理单资产独占一批)
        batches: list[list[int]] = []
        cur_batch: list[int] = []
        cur_ops = 0
        for idx, plan in enumerate(plans):
            plan_ops = len(plan[1]) + len(plan[2])
            if plan_ops >= _FGA_MOVE_BATCH_OPS:
                batches.append([idx])
                continue
            if _ops_within(cur_ops, plan) > _FGA_MOVE_BATCH_OPS:
                batches.append(cur_batch)
                cur_batch, cur_ops = [], 0
            cur_batch.append(idx)
            cur_ops = _ops_within(cur_ops, plan)
        if cur_batch:
            batches.append(cur_batch)

        async def _write_tuples(
            writes: list[ClientTuple], deletes: list[ClientTuple],
        ) -> None:
            """单次 OpenFGA write;writes 恒非空(每资产恰 1 写)。is_already_exists
            视作成功:write 整请求原子,重试撞 already exists = 前一次已生效。"""
            try:
                await permissions._client.write(
                    ClientWriteRequest(writes=writes, deletes=deletes or None)
                )
            except Exception as e:
                if is_already_exists_error(e):
                    return
                raise

        for batch in batches:
            writes = [t for idx in batch for t in plans[idx][2]]
            deletes = [t for idx in batch for t in plans[idx][1]]
            batch_ok = False
            for attempt in range(1, _FGA_MOVE_ATTEMPTS + 1):
                try:
                    await _write_tuples(writes, deletes)
                    batch_ok = True
                    break
                except Exception as e:  # 网络/校验类都重试后降级
                    log.warning(
                        "batch_move fga batch write fail attempt=%d assets=%d err=%s",
                        attempt, len(batch), e,
                    )
                    await asyncio.sleep(0.2 * attempt)
            if batch_ok:
                continue
            # 批失败降级逐资产(default_grants 降级先例):一条坏 tuple 会原子
            # 拖垮整批,逐资产隔离后仍败的才进 fga_pending
            for idx in batch:
                asset_id, olds, news = plans[idx]
                asset_ok = False
                for attempt in range(1, _FGA_MOVE_ATTEMPTS + 1):
                    try:
                        await _write_tuples(news, olds)
                        asset_ok = True
                        break
                    except Exception as e:
                        log.warning(
                            "batch_move fga tuple write fail attempt=%d asset=%s err=%s",
                            attempt, asset_id, e,
                        )
                        await asyncio.sleep(0.2 * attempt)
                if not asset_ok:
                    fga_pending.append(asset_id)

        # 对账恒等式(契约 §3.6):成功 + skipped + fga_pending = 提交数,其中
        # 「成功」= DB+FGA 都落定 —— FGA 交换最终失败(重试与单条降级都失败)
        # 的资产从 moved 桶移入 fga_pending 桶,否则双计。入桶路径只有读失败 /
        # 批失败后单条降级两处,来源均 ⊆ moved_ids:集合过滤与 moved 桶互斥
        # 完备,不会卷入 skipped;fga_pending 语义不变(DB 已在新夹、FGA 待同步)。
        if fga_pending:
            pending_set = set(fga_pending)
            moved_ids = [a for a in moved_ids if a not in pending_set]

    skipped_by_reason: dict[str, int] = dict(Counter(s.reason for s in skipped))
    await audit.write(
        event_type="asset_batch_moved",
        actor_user_id=user_id,
        # 批次项目(混批已在前面 400 拦下,这里必为单项目或空批的全 deleted)
        target_project_id=batch_project if batch_project is not None else target.project_id,
        details={
            "from_folder_ids": [str(f) for f in folder_groups],
            "to_folder_id": str(target.id),
            "moved": len(moved_ids),
            "skipped_total": len(skipped),
            "skipped_by_reason": skipped_by_reason,
            "skipped_sample": [
                {"asset_id": str(s.asset_id), "reason": s.reason} for s in skipped[:50]
            ],
            "moved_sample": [str(a) for a in moved_ids[:50]],
            "fga_pending_count": len(fga_pending),
            "fga_pending_sample": [str(a) for a in fga_pending[:50]],
        },
        **ctx,
    )
    return AssetBatchMoveOut(
        moved_count=len(moved_ids),
        skipped=skipped,
        fga_pending=fga_pending,
    )


# ─── download link ────────────────────────────────────────────────────────────
class DownloadLinkIn(BaseModel):
    """download-link 可选请求体(移动端下载直连,方案 §3.5)。

    向后兼容:不传 body / `{}` 均可,as_attachment 默认 False → 行为与旧版
    完全一致(inline 语义,桌面 PDF iframe 预览不受影响)。
    variant(livp-download-unpack 方案 §3,F3):默认 "original" 行为零变化;
    "unpacked" 仅适用 .livp 资产,交付服务端解包 zip(未就绪 404 + 自愈)。
    """

    as_attachment: bool = False
    variant: Literal["original", "unpacked"] = "original"


# livp 解包 404 自愈的 Redis 频控窗口(SETNX EX;防反复点击刷派发,方案 §3)
_LIVP_HEAL_RATE_LIMIT_SEC = 600


async def _heal_livp_download_zip(request: Request, asset_id: uuid.UUID) -> None:
    """unpacked 404 自愈(方案 §3):Redis SETNX EX 600 频控 + fire-and-forget
    enqueue(上传时派发失败/漏派的兜底;enqueue 内部异常吞掉只 log,同
    enqueue_livp_thumbnail 口径)。

    SETNX 连接异常必须 try/except 只 log 后照常 404 —— download-link 现状不依赖
    Redis,不能让 livp 下载从「404 回落原始」退化成 500。
    """
    redis = request.app.state.redis
    try:
        acquired = await redis.set(
            f"livpdl:heal:{asset_id}", "1", nx=True, ex=_LIVP_HEAL_RATE_LIMIT_SEC,
        )
    except Exception as e:  # noqa: BLE001
        log.warning("livp heal rate-limit check fail asset=%s err=%s", asset_id, e)
        return
    if not acquired:
        return  # 频控占用(10 分钟内已重派过),不刷派发
    from app.services.arq_pool import enqueue_livp_download
    await enqueue_livp_download(request.app.state.arq_pool, str(asset_id))


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
    request: Request,
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

    # W2b:审计补 target_project_id(folder 并发删的竞速窗口回 None,不炸)
    folder = await db.get(Folder, asset.folder_id)
    project_id = folder.project_id if folder is not None else None

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
            target_project_id=project_id,
            target_minio_key=asset.minio_key,
            details={"reason": "openfga can_download false"},
            **ctx,
        )
        raise HTTPException(403, "no permission to download(可申请审批)")

    settings = get_settings()
    ttl = settings.presigned_normal_ttl_seconds
    variant = data.variant if data is not None else "original"
    is_livp = (asset.filename or "").lower().endswith(".livp")

    # variant="unpacked"(livp-download-unpack 方案 §3,F3):交付服务端解包 zip
    if variant == "unpacked":
        if not is_livp:
            raise HTTPException(400, "variant unpacked 仅适用 .livp 资产")
        tags = asset.tags or {}
        zip_key = tags.get("download_zip_key")
        ready = False
        if zip_key:
            # 签发前 head 校验衍生物对象存在(同步 boto3 按铁律 asyncio.to_thread
            # 包裹,先例本文件 batch_prefix copy_object):tag 在而对象被外力清除的
            # 孤儿 tag 按「缺失」分支走 404/自愈,不给无 FSA 的移动/火狐路径签出
            # 必 404 的 URL —— JS 捕获不到 anchor 下载失败,兜底必须在服务端
            try:
                await asyncio.to_thread(
                    presign.head_object, asset.minio_bucket, str(zip_key),
                )
                ready = True
            except Exception as e:
                log.warning("livp download zip head fail asset=%s key=%s err=%s",
                            asset_id, zip_key, e)
        if ready:
            from app.workers.main import _livp_download_base_name
            base = _livp_download_base_name(asset.filename or "", str(asset_id))
            # disposition 仅 as_attachment 时给(桌面 FSA 路径不需要,前端
            # suggestedName 决定文件名);基名沿用 job 侧 §2.3 清洗,保证与
            # zip 内条目名同源
            disposition = (
                attachment_content_disposition(f"{base}.zip")
                if data is not None and data.as_attachment
                else None
            )
            url = presign.sign_get_url(
                asset.minio_bucket, str(zip_key), ttl,
                response_content_disposition=disposition,
                request_base=request_base_from(request),
            )
            await audit.signed_url_issued(
                actor_user_id=user_id,
                target_asset_id=asset.id,
                target_project_id=project_id,
                target_minio_key=str(zip_key),
                details={"expires_in_seconds": ttl, "variant": "unpacked"},
                **ctx,
            )
            return DownloadLinkOut(url=url, expires_in=ttl, is_sensitive=False)

        # 缺失:永久失败 tag 有值 → 404 不重派(重派注定同结果);否则 404 + 自愈
        if not tags.get("download_zip_failed"):
            await _heal_livp_download_zip(request, asset_id)
        raise HTTPException(404, "livp 解包版尚未就绪")

    # variant="original"(默认):现行为零变化
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
        request_base=request_base_from(request),
    )

    await audit.signed_url_issued(
        actor_user_id=user.id,
        target_asset_id=asset.id,
        target_project_id=project_id,
        target_minio_key=asset.minio_key,
        # original 审计 details 保持原形(零回归;variant 只加在 unpacked 路径)
        details={"expires_in_seconds": ttl},
        **ctx,
    )

    return DownloadLinkOut(url=url, expires_in=ttl, is_sensitive=False)


# ─── 批量下载单 zip(创建/轮询双职能端点;livp-download-unpack 方案 §6.2,F9)────
class BatchDownloadLinkIn(BaseModel):
    """批量下载入参:创建(不带 resume_key)与轮询(带 resume_key)同形。

    asset_ids 1..100(>100 由 pydantic 入参约束回 422);retry 为 failed 后手动重试
    (清失败标记重新入队,不受标记 TTL 拘束)。
    """

    asset_ids: list[uuid.UUID] = Field(..., min_length=1, max_length=100)
    as_attachment: bool = False
    resume_key: str | None = None
    retry: bool = False


class BatchDownloadLinkOut(BaseModel):
    """三态同形响应:url/expires_in 仅 ready;跳过列表只回 id 不回文件名(防侧信道:
    单文件 403 从不回资产名,本端点不能成为用随机 UUID 探测 sensitive 夹文件名的
    新通道,前端用自己已加载的 Asset 名渲染提示)。"""

    status: Literal["ready", "packing", "failed"]
    key: str
    url: str | None = None
    expires_in: int | None = None
    filename: str
    skipped_no_permission: list[uuid.UUID] = Field(default_factory=list)
    skipped_missing_count: int = 0
    livp_raw_count: int = 0
    retry_after_seconds: int | None = None


# 合计折算体积名义上限 10GB(实际 zip 上界 ~1.3-1.5x,下游临时盘/URL/轮询三处按
# 实际上界留余量,方案 §6.2 第 2 步)
_BATCH_SIZE_LIMIT = 10 * 1024**3
# 折算体积:livp 按 size_bytes x3 计入(解包产物 = 全分辨率 JPEG(HEIC 膨胀 2.5-4x)
# + 转码 MP4,重 HEIC 轻视频条目的极端选集整包膨胀可达 ~3 倍;x2 会击穿校准)
_BATCH_LIVP_WEIGHT = 3
# epoch 后缀的进程内序列号:Windows 计时器量化下 time.time_ns() 可在同一毫秒重复,
# 拼 4 位进程内自增序号保证同 key 两次入队的 _job_id 必不相同(纯数字,守
# `key:\d+` 契约形态)
_batch_epoch_seq = itertools.count()


def _batch_is_livp(row: Any) -> bool:
    return (row.filename or "").lower().endswith(".livp")


def _batch_livp_ready(row: Any) -> bool:
    """livp 解包衍生物就绪位(按当时 tags 静态判定;ready 响应以 job 实际计数为准)。"""
    tags = row.tags or {}
    return bool(tags.get("download_zip_key")) and not tags.get("download_zip_failed")


def _batch_weighted_size(row: Any) -> int:
    size = int(row.size_bytes or 0)
    return size * _BATCH_LIVP_WEIGHT if _batch_is_livp(row) else size


def _batch_filename(count: int) -> str:
    return f"批量下载_{count}个文件_{datetime.now().strftime('%Y%m%d-%H%M')}.zip"


class _BatchFresh:
    """一次全量校验通过程的产物(首次 POST 与 ready 复检共用)。"""

    __slots__ = ("allowed", "allowed_ids", "denied_ids", "missing_count", "readiness", "rows")

    def __init__(
        self,
        rows: list[Any],
        allowed: list[Any],
        denied_ids: list[str],
        missing_count: int,
    ) -> None:
        self.rows = rows
        self.allowed = allowed
        self.allowed_ids = [str(r.id) for r in allowed]
        self.denied_ids = denied_ids
        self.missing_count = missing_count
        self.readiness = {
            str(r.id): _batch_livp_ready(r) for r in allowed if _batch_is_livp(r)
        }


async def _batch_fresh_pass(
    db: AsyncSession,
    permissions: PermissionsService,
    user: CurrentUser,
    is_system_admin: bool,
    selection: list[str],
) -> _BatchFresh:
    """单条 `SELECT … WHERE id IN` 查行(AsyncSession 不允许并发,勿逐资产 db.get)
    + 仅 FGA check 用 asyncio.gather 并发(permissions 走 OpenFGA client 无 DB
    session)。不存在/已软删 → 计入 missing。系统 admin 直通。"""
    rows = list(
        (
            await db.execute(
                select(Asset).where(
                    Asset.id.in_([uuid.UUID(s) for s in selection]),
                    Asset.deleted_at.is_(None),
                )
            )
        ).scalars().all()
    )
    if is_system_admin or not rows:
        checks: list[bool] = [True] * len(rows)
    else:
        checks = list(
            await asyncio.gather(
                *(
                    permissions.check(
                        user_subject=user.subject,
                        relation="can_download",
                        object_type="asset",
                        object_id=str(r.id),
                    )
                    for r in rows
                )
            )
        )
    allowed = [r for r, ok in zip(rows, checks, strict=True) if ok]
    denied = [str(r.id) for r, ok in zip(rows, checks, strict=True) if not ok]
    missing = len(set(selection) - {str(r.id) for r in rows})
    return _BatchFresh(rows, allowed, denied, missing)


def _batch_bucket_of(allowed: list[Any]) -> str:
    """归属桶断言:批量包存选中集所在项目的桶,允许集必须全部同桶(跨桶选集 →
    400「跨项目批量暂不支持」;实际选集恒为单夹,此为防御)。"""
    buckets = {r.minio_bucket for r in allowed}
    if len(buckets) > 1:
        raise HTTPException(400, "跨项目批量暂不支持")
    return str(buckets.pop())


def _batch_check_sizes(allowed: list[Any]) -> None:
    """上限双文案:单个文件超限物理上无法分批,不得给它「请分批」的死胡同文案。"""
    weighted = [_batch_weighted_size(r) for r in allowed]
    if any(w > _BATCH_SIZE_LIMIT for w in weighted):
        raise HTTPException(400, "选集中单个文件超过 10GB 上限,请单独下载该文件")
    if sum(weighted) > _BATCH_SIZE_LIMIT:
        raise HTTPException(400, "合计超出批量打包上限(≤100 个且合计 ≤10GB),请分批下载")


async def _batch_audit_denied(
    redis: Any,
    audit: AuditService,
    user: CurrentUser,
    selection: list[str],
    denied_ids: list[str],
    ctx: dict,
) -> None:
    """denied 首次逐条审计:Redis SETNX EX 1800 去重(窗口 ≥ 前端轮询上限 900s,
    轮询不重写)。去重键用 canonical(请求选中集)摘要而非批量缓存 key —— 全
    denied 时 compute_batch_key 恒返同一常量(允许集为空),按它分键会把同一用户
    30 分钟内不同选集的首评折叠少记;选中集摘要分键后不同选集各自首评、同选集
    轮询仍去重。SETNX 异常只 log 跳过,不让审计故障变 5xx。"""
    if not denied_ids:
        return
    try:
        first = await redis.set(
            batch_audited_key(str(user.id), selection), "1", nx=True, ex=AUDITED_TTL,
        )
    except Exception as e:
        log.warning(
            "batch denied audit dedup fail user=%s selection=%s err=%s",
            user.id, selection, e,
        )
        return
    if not first:
        return
    for rid in denied_ids:
        await audit.write(
            event_type="download_denied",
            actor_user_id=user.id,
            target_asset_id=uuid.UUID(rid),
            details={"reason": "openfga can_download false", "kind": "batch_zip"},
            **ctx,
        )


async def _batch_head(
    presign: PresignService, bucket: str, obj_key: str,
) -> dict[str, Any] | None:
    """head 探测缓存包(同步 boto3 按铁律 asyncio.to_thread;缺失/异常 = miss)。"""
    try:
        return await asyncio.to_thread(presign.head_object, bucket, obj_key)
    except Exception as e:
        log.info("batch zip head miss bucket=%s key=%s err=%s", bucket, obj_key, e)
        return None


def _batch_record(
    selection: list[str], bucket: str, fresh: _BatchFresh, key: str,
) -> dict[str, Any]:
    """作业记录(轮询轻校验与响应回放全靠它;selection_ids=请求 ids 的 canonical 形态
    与 allowed_ids 分存 —— resume 校验若误用 allowed_ids,任何含无权限/缺失项的选集
    轮询会恒 400 → 前端静默全新 POST → 每 3s 一轮全量 FGA 复检)。"""
    return {
        "bucket": bucket,
        "key": key,
        "filename": _batch_filename(len(selection)),
        "selection_ids": list(selection),
        "allowed_ids": fresh.allowed_ids,
        "skipped_no_permission": fresh.denied_ids,
        "skipped_missing_count": fresh.missing_count,
        "livp_raw_count": sum(
            1 for r in fresh.allowed if _batch_is_livp(r) and not _batch_livp_ready(r)
        ),
        "created_at": datetime.now(UTC).isoformat(),
    }


def _batch_out_from_record(
    status: str, key: str, record: dict[str, Any], retry_after: int | None = None,
) -> BatchDownloadLinkOut:
    # livp_raw_count:job 回写的实际计数(livp_raw_count_actual)优先 —— 定稿 §6.2
    # 第 6 步:ready 响应以 job 实际打包计数为准(轮询期就绪位翻转时,首响应按当时
    # tags 静态判定的数字可能与实际包内容有偏差);记录无回写字段(job 未跑/未回写/
    # 记录重建)回落 tags 静态判定值
    actual = record.get("livp_raw_count_actual")
    livp_raw = int(actual) if actual is not None else int(record.get("livp_raw_count") or 0)
    return BatchDownloadLinkOut(
        status=status,  # type: ignore[arg-type]
        key=key,
        filename=str(record.get("filename") or ""),
        skipped_no_permission=[
            uuid.UUID(s) for s in record.get("skipped_no_permission") or []
        ],
        skipped_missing_count=int(record.get("skipped_missing_count") or 0),
        livp_raw_count=livp_raw,
        retry_after_seconds=retry_after,
    )


async def _batch_ready(
    presign: PresignService,
    audit: AuditService,
    request: Request,
    user: CurrentUser,
    ctx: dict,
    bucket: str,
    key: str,
    age_s: float,
    record: dict[str, Any],
    as_attachment: bool,
) -> BatchDownloadLinkOut:
    """缓存命中签发:URL 有效期 = min(21600, 21600-age)(剩余寿命收缩 —— 重签满额
    会造出「URL 还活着、对象已被清」的断流尾窗);审计写单条聚合事件(语义与逐资产
    等价、写放大小一个量级;双 tab/反复重点击不放大审计行数)。"""
    obj_key = batch_object_key(key)
    ttl = max(1, min(BATCH_URL_TTL, BATCH_URL_TTL - int(age_s)))
    filename = str(record.get("filename") or "")
    disposition = attachment_content_disposition(filename) if as_attachment else None
    url = presign.sign_get_url(
        bucket, obj_key, ttl,
        response_content_disposition=disposition,
        request_base=request_base_from(request),
    )
    await audit.signed_url_issued(
        actor_user_id=user.id,
        target_minio_key=obj_key,
        details={
            "expires_in_seconds": ttl,
            "kind": "batch_zip",
            "ids": list(record.get("allowed_ids") or []),
        },
        **ctx,
    )
    out = _batch_out_from_record("ready", key, record)
    out.url = url
    out.expires_in = ttl
    return out


async def _batch_dispatch(
    redis: Any,
    pool: Any,
    user_id: str,
    key: str,
    bucket: str,
    allowed_ids: list[str],
    record: dict[str, Any],
    *,
    retry: bool,
) -> BatchDownloadLinkOut:
    """miss → 入队(锁即去重闸),按序判定:失败标记短路 → per-user 锁前缀比对 →
    两键单段 Lua 原子落 → enqueue(epoch 后缀 _job_id)→ 失败 Lua 回滚。"""

    def _out(status: str, retry_after: int | None = None) -> BatchDownloadLinkOut:
        return _batch_out_from_record(status, key, record, retry_after)

    # ① 失败标记存在 → failed 短路不入队;retry:true → 清标记继续(手动重试不受
    #    标记 TTL 拘束)
    if await redis.get(batch_fail_key(key)):
        if not retry:
            return _out("failed")
        await redis.delete(batch_fail_key(key))

    # ② per-user 锁在:value 前缀 == key(本批 job 在跑)→ packing 不重入队(确定性
    #    _job_id 去重已弃用,轮询防踩踏靠这把锁);前缀 != key(异 key 打包中)→ 429
    active = await redis.get(batch_active_key(user_id))
    if active is not None:
        if active.split(":", 1)[0] == key:
            return _out("packing")
        raise HTTPException(429, "已有打包任务进行中,请稍候")

    # ③ 锁不存在 → per-key 在途闸 + per-user 锁单段 Lua 原子落(单段防「两 SET
    #    之间进程死亡」留 40 分钟假 packing 的孤儿窗;TTL 2400 仅作崩溃兜底,job
    #    执行开始会对两键 Lua 续期)
    token = uuid.uuid4().hex
    if await acquire_batch_locks(redis, user_id, key, token) != 1:
        # 撞闸(跨用户同 key 打包期点击;或 get/eval 之间他请求抢锁):重新判定
        active2 = await redis.get(batch_active_key(user_id))
        if active2 is not None:
            if active2.split(":", 1)[0] == key:
                return _out("packing")
            raise HTTPException(429, "已有打包任务进行中,请稍候")
        gate_ttl = await redis.ttl(batch_keygate_key(key))
        return _out("packing", retry_after=max(int(gate_ttl), 0))

    # ④ enqueue:_job_id 用 epoch 后缀而非确定性 key —— 确定性 id 会与已完成 job 的
    #    墓碑键(崩溃/kill 残留最长 24h)和 keep_result 结果键(300s)相撞,
    #    enqueue_job 静默返 None → 假 packing 空转;head 检查是缓存闸门、同用户踩踏
    #    由锁防、跨用户由 per-key 闸防,arq 层去重并无必要。入参显式带 bucket 与
    #    job_token(finally 的「值匹配才删」无米下锅)。
    try:
        job = await pool.enqueue_job(
            "generate_batch_download_zip",
            user_id, token, *allowed_ids, bucket, key,
            _job_id=f"{key}:{time.time_ns()}{next(_batch_epoch_seq):04d}",
        )
        if job is None:
            raise RuntimeError("enqueue_job 返回 None(队列不可用)")
    except Exception as e:
        log.warning("batch zip enqueue fail key=%s err=%s", key, e)
        # enqueue 抛错/返 None → 按 token Lua 匹配 DEL 刚落的两键回滚,不留锁孤儿
        with contextlib.suppress(Exception):
            await release_batch_locks(redis, user_id, key, token)
        raise HTTPException(503, "打包任务派发失败,请稍后重试") from e
    return _out("packing")


@router.post("/batch-download-link", response_model=BatchDownloadLinkOut)
async def batch_download_link(
    request: Request,
    data: BatchDownloadLinkIn,
    db: AsyncSession = Depends(get_db),  # noqa: B008  # FastAPI DI,repo 全量同款
    permissions: PermissionsService = Depends(get_permissions),  # noqa: B008  # FastAPI DI,repo 全量同款
    presign: PresignService = Depends(get_presign),  # noqa: B008  # FastAPI DI,repo 全量同款
    audit: AuditService = Depends(get_audit),  # noqa: B008  # FastAPI DI,repo 全量同款
    user: CurrentUser = Depends(get_current_user),  # noqa: B008  # FastAPI DI,repo 全量同款
    is_system_admin: bool = Depends(get_is_system_admin),  # noqa: B008  # FastAPI DI,repo 全量同款
    ctx: dict = Depends(get_request_context),  # noqa: B008  # FastAPI DI,repo 全量同款
) -> BatchDownloadLinkOut:
    """批量下载创建/轮询双职能(方案 §6.2 六步):端点职责只有校验 + head 探测 +
    enqueue(亚秒级,不做重活),重活全部在 worker job。

    - 首次 POST 全量校验并落作业记录 `batchzip:job:{user}:{key}`(EX 3600);
    - 轮询(带 resume_key)只做轻校验(canonical(body ids) == 记录 selection_ids,
      不做行存在性/软删检查、不重算权限)—— 安全与内容闸门钉在 URL 签发时刻;
    - ready 时刻才做全量复检 + key 收敛(head 命中且未超龄才触发,轮询不放大 FGA
      成本;key 变化 → 按新批处理,先 head 新 key 命中即签发);
    - miss = 失败标记短路 → 锁闸 → enqueue(epoch 后缀 _job_id)。
    """
    redis = request.app.state.redis
    pool = request.app.state.arq_pool
    user_id = str(user.id)
    selection = canonical_ids(data.asset_ids)

    # ── 轮询(resume)轻校验路径 ──────────────────────────────────────────────
    if data.resume_key:
        rk = data.resume_key
        raw = await redis.get(batch_job_record_key(user_id, rk))
        if raw is None:
            # 记录缺失/过期/跨用户(记录按用户分存,天然挡住拿别人 key 做 resume)
            raise HTTPException(400, "批量下载作业不存在或已过期,请重新发起批量下载")
        record = json.loads(raw)
        if [str(s) for s in record.get("selection_ids") or []] != selection:
            raise HTTPException(400, "选中集与批量下载作业不一致,请重新发起批量下载")
        bucket = str(record.get("bucket") or "")
        head = await _batch_head(presign, bucket, batch_object_key(rk))
        if head is not None:
            age = (datetime.now(UTC) - head["last_modified"]).total_seconds()
            if age < BATCH_URL_TTL:
                # ready 时刻:全量复检 + key 收敛
                fresh = await _batch_fresh_pass(
                    db, permissions, user, is_system_admin, selection,
                )
                if not fresh.rows:
                    raise HTTPException(400, "所选文件不存在或已删除,无可下载文件")
                if not fresh.allowed:
                    await _batch_audit_denied(redis, audit, user, selection, fresh.denied_ids, ctx)
                    raise HTTPException(403, "所选文件均无下载权限(可对单个文件申请下载)")
                cur_key = compute_batch_key(fresh.readiness, fresh.allowed_ids)
                if cur_key == rk:
                    # 权限与就绪位未翻转 → 直接签发(回放走记录)
                    return await _batch_ready(
                        presign, audit, request, user, ctx, bucket, rk, age, record,
                        data.as_attachment,
                    )
                # 权限被回收/就绪位变化 → 按新批处理:先 head 新应然 key,命中缓存
                # 即免一次重打包;该分支本用户可能无作业记录,filename/skipped 按
                # 当前全量复检现算回放并补写记录(权限变化对调用者透明,前端照常按
                # 响应里的新 key 继续轮询)
                new_bucket = _batch_bucket_of(fresh.allowed)
                _batch_check_sizes(fresh.allowed)
                new_record = _batch_record(selection, new_bucket, fresh, cur_key)
                await redis.set(
                    batch_job_record_key(user_id, cur_key),
                    json.dumps(new_record), ex=JOB_RECORD_TTL,
                )
                head2 = await _batch_head(presign, new_bucket, batch_object_key(cur_key))
                if head2 is not None:
                    age2 = (datetime.now(UTC) - head2["last_modified"]).total_seconds()
                    if age2 < BATCH_URL_TTL:
                        return await _batch_ready(
                            presign, audit, request, user, ctx, new_bucket, cur_key,
                            age2, new_record, data.as_attachment,
                        )
                return await _batch_dispatch(
                    redis, pool, user_id, cur_key, new_bucket, fresh.allowed_ids,
                    new_record, retry=data.retry,
                )
            # age ≥ 保留期(6h)→ 按 miss 处理(cron 是 10 分钟粒度可能扫到超龄
            # 对象,剩余寿命 ≤0 时 botocore ExpiresIn 会直接抛错)
            log.info("batch zip object expired by age key=%s age=%.0fs", rk, age)
        # miss → 失败标记短路 → 锁闸 → enqueue(allowed_ids 从记录回放,轻校验
        # 不重算权限)
        return await _batch_dispatch(
            redis, pool, user_id, rk, bucket,
            [str(s) for s in record.get("allowed_ids") or []],
            record, retry=data.retry,
        )

    # ── 首次 POST(创建)全量校验路径 ─────────────────────────────────────────
    fresh = await _batch_fresh_pass(db, permissions, user, is_system_admin, selection)
    if not fresh.rows:
        raise HTTPException(400, "所选文件不存在或已删除,无可下载文件")
    # 确定性缓存 key:允许集摘要 + livp 就绪位入 key(权限不同天然分 key,无投毒
    # 无乒乓;就绪位翻转落新 key,旧包不被钉住)。key 是包内容的函数,与请求 id
    # 顺序/重复项无关 —— 同选中集两次点击(前端 selectedIds 插入序差异)同 key。
    key = compute_batch_key(fresh.readiness, fresh.allowed_ids)
    await _batch_audit_denied(redis, audit, user, selection, fresh.denied_ids, ctx)
    if not fresh.allowed:
        raise HTTPException(403, "所选文件均无下载权限(可对单个文件申请下载)")
    bucket = _batch_bucket_of(fresh.allowed)
    _batch_check_sizes(fresh.allowed)

    record = _batch_record(selection, bucket, fresh, key)
    await redis.set(
        batch_job_record_key(user_id, key), json.dumps(record), ex=JOB_RECORD_TTL,
    )

    head = await _batch_head(presign, bucket, batch_object_key(key))
    if head is not None:
        age = (datetime.now(UTC) - head["last_modified"]).total_seconds()
        if age < BATCH_URL_TTL:
            return await _batch_ready(
                presign, audit, request, user, ctx, bucket, key, age, record,
                data.as_attachment,
            )
        log.info("batch zip object expired by age key=%s age=%.0fs", key, age)
    return await _batch_dispatch(
        redis, pool, user_id, key, bucket, fresh.allowed_ids, record,
        retry=data.retry,
    )


# ─── thumbnail URL — B-4 (轻量,签短 ttl presigned,不走 OpenFGA enforce)──────
@router.get("/{asset_id}/thumbnail-url")
async def get_thumbnail_url(
    asset_id: uuid.UUID,
    request: Request,
    size: Literal["large", "small"] = "large",
    db: AsyncSession = Depends(get_db),
    presign: PresignService = Depends(get_presign),
    user: CurrentUser = Depends(get_current_user),
) -> dict:
    """缩略图 presigned URL — 至少要登录;不再做 per-asset OpenFGA check
    (缩略图 1024px 模糊化,信息密度低,信任组织内可见性)。

    软删(deleted_at 置位)行照常返回 —— 回收站列表(管理员可见)的缩略图
    走同一 endpoint,拒绝会让回收站里每行都打一个 404;彻底删除后行不存
    在才 404。无 thumbnail_key(还没生成 / 非图)→ 404。

    size(thumb-variant 方案 §3.2):small 请求优先签 tags.thumbnail_small_key,
    缺失回落签 thumbnail_key(响应 variant 标实际签发的对象规格,web/app 据此
    短路渐进替换;回落让三端切换与存量回补解耦,small 请求永因缺 small 404);
    large/缺省行为与旧版一致。鉴权/审计/TTL 均不变(认证不鉴权、无审计)。
    """
    _ = user.id  # 至少要认证
    asset = await db.get(Asset, asset_id)
    if asset is None:
        raise HTTPException(404, "asset not found")
    tags = asset.tags or {}
    if size == "small" and tags.get("thumbnail_small_key"):
        thumbnail_key = tags["thumbnail_small_key"]
        variant = "small"
    else:
        thumbnail_key = tags.get("thumbnail_key")
        variant = "large"
    if not thumbnail_key:
        raise HTTPException(404, "no thumbnail yet(可能还在生成 / 非图片)")

    ttl = 1800   # 30 min — 缩略图比原图 ttl 长(让浏览器缓存有效)
    # ADR-0008 P1:缩略图走独立 bucket + 缩略图 MinIO(SSD);endpoint/bucket 由 env 控制。
    # 动态签发:request_base 传入时 host 跟随入口(缩略图与原片同 vhost 同源)
    # cache_control(B4 卫生项):同一签名 URL 的重复 GET 确定性命中浏览器缓存
    url = presign.sign_thumbnail_url(
        thumbnail_key, ttl, request_base=request_base_from(request),
        cache_control="public, max-age=604800",
    )
    return {"url": url, "expires_in": ttl, "variant": variant}


# ─── thumbnail URL 批量签发 — 宫格按页预热(app-thumbnail-storm-fix W3,纯新增)─
class ThumbUrlOut(BaseModel):
    """单条缩略图签名结果(App 按 asset_id 匹配,响应顺序不保证)。

    variant(thumb-variant 方案 §3.2)= 实际签发的对象规格:请求 small 且
    small 变体存在为 "small";large 请求或 small 缺失回落签 1024 主图为 "large"。
    """

    asset_id: uuid.UUID
    url: str
    expires_in: int
    variant: Literal["large", "small"]


class ThumbUrlsIn(BaseModel):
    """批量签收入参:1..100(超限由 pydantic 入参约束回 422,风格对齐
    BatchDownloadLinkIn)。size(thumb-variant 方案 §3.2)逐条 small 优先/
    缺失回落 large,语义与单发端点一致,默认 large(旧客户端零感知)。"""

    asset_ids: list[uuid.UUID] = Field(..., min_length=1, max_length=100)
    size: Literal["large", "small"] = "large"


class ThumbUrlsOut(BaseModel):
    """批量签发响应:urls 只含有 thumbnail_key 的行;missing = 不存在或无
    thumbnail_key(软删行照常签发,与单发端点同拍板口径)。"""

    urls: list[ThumbUrlOut] = Field(default_factory=list)
    missing: list[uuid.UUID] = Field(default_factory=list)  # 不存在或无 thumbnail_key


@router.post("/thumbnail-urls", response_model=ThumbUrlsOut)
async def post_thumbnail_urls(
    payload: ThumbUrlsIn,
    request: Request,
    db: AsyncSession = Depends(get_db),
    presign: PresignService = Depends(get_presign),
    user: CurrentUser = Depends(get_current_user),
) -> ThumbUrlsOut:
    """缩略图 presigned URL 批量签发 — 宫格页按页预热(D3),认证同单发端点
    (get_current_user,不做 per-asset OpenFGA check:1024px 模糊化,信任组织内
    可见性;同账号本可循环单发探测,批量化仅提高枚举效率,信任模型不变)。

    单条 `SELECT … WHERE id IN`(AsyncSession 不允许并发,禁止逐资产 db.get 的
    N+1);内存分流:有 thumbnail_key 逐个 sign_thumbnail_url(本地 HMAC),
    不存在 / 无 key 进 missing;重复 id 以唯一 id 出;软删(deleted_at 置位)行
    照常返回(回收站缩略图与单发同口径);request_base 跟随入口(缩略图与原片
    同 vhost 同源);响应顺序不保证,App 按 asset_id 匹配。size=small 逐条
    优先签 thumbnail_small_key、缺失回落 thumbnail_key(variant 随实签规格)。
    """
    _ = user.id  # 至少要认证
    # 去重保序:重复 id 只查一次、只签一次,响应里以唯一 id 出
    ids = list(dict.fromkeys(payload.asset_ids))
    rows = list(
        (await db.execute(select(Asset).where(Asset.id.in_(ids)))).scalars().all()
    )
    by_id = {row.id: row for row in rows}

    ttl = 1800   # 30 min — 与单发同值(缩略图比原图 ttl 长,让浏览器缓存有效)
    # ADR-0008 P1:缩略图走独立 bucket + 缩略图 MinIO(SSD);endpoint/bucket 由
    # env 控制;host 跟随入口(与单发一致,request_base_from 取 scheme://host)
    request_base = request_base_from(request)
    urls: list[ThumbUrlOut] = []
    missing: list[uuid.UUID] = []
    for i, asset_id in enumerate(ids):
        # 100 条串行签名:本地 HMAC 轻,但底层是同步 botocore 调用 —— 每 20 条
        # 让出一次事件循环,不占死 loop(替代逐条 to_thread,免线程池开销盖过签名)
        if i and i % 20 == 0:
            await asyncio.sleep(0)
        row = by_id.get(asset_id)
        tags = (row.tags or {}) if row is not None else {}
        # small 优先 / 缺失回落 large(与单发端点同拍板,thumb-variant 方案 §3.2)
        if payload.size == "small" and tags.get("thumbnail_small_key"):
            thumbnail_key = tags["thumbnail_small_key"]
            variant = "small"
        else:
            thumbnail_key = tags.get("thumbnail_key")
            variant = "large"
        if not thumbnail_key:
            missing.append(asset_id)
            continue
        urls.append(
            ThumbUrlOut(
                asset_id=asset_id,
                url=presign.sign_thumbnail_url(
                    thumbnail_key, ttl, request_base=request_base,
                    cache_control="public, max-age=604800",
                ),
                expires_in=ttl,
                variant=variant,
            )
        )
    return ThumbUrlsOut(urls=urls, missing=missing)


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
    tuple,不可恢复 —— 须先软删(两步制,防误操作一击穿底)。权限 =
    is_system_admin 或 asset.can_admin 或 (组级 file_deleter 且 asset.can_view 且
    非 sensitive)(软删 F3 / hard F4,2026-10-16 组删除授权;两步制约束不变)。
    **hard 分支对 sensitive 资产仅系统 admin**(F1):项目 admin 继承 can_admin
    但无 can_view,不能对受邀制内容做不可逆销毁(与 list_trash / restore 收口
    同口径);组织开关分支同样不穿透 sensitive(下方统一排除)。
    """
    asset = await db.get(Asset, asset_id)
    if not asset:
        raise HTTPException(404, "asset not found")

    # sensitive 判定与 trash/restore 特判同源:随所属 folder.is_sensitive;
    # 组织开关分支是否适用、hard 敏感门都靠它
    folder = await db.get(Folder, asset.folder_id)
    is_sensitive = folder is not None and folder.is_sensitive
    # W2b:审计补 target_project_id;purge(hard)是物理删,target_project_id
    # 不带 FK、可在删行后照常写入(folder 并发删的竞速窗口回 None,不炸)
    project_id = folder.project_id if folder is not None else None

    allowed = is_system_admin or await permissions.check(
        user_subject=user.subject, relation="can_admin",
        object_type="asset", object_id=str(asset_id),
    )
    # 组级「删除文件/文件夹」开关分支(F3/F4):仅非 sensitive 资产,授权且可见;
    # 短路在 can_admin 失败之后,常规路径不多打 org 解析与 check(and 短路序同嵌套 if)
    if (
        not allowed
        and not is_sensitive
        and await user_is_org_file_deleter(permissions, db, user_id=str(user_id))
    ):
        allowed = await permissions.check(
            user_subject=user.subject, relation="can_view",
            object_type="asset", object_id=str(asset_id),
        )
    if not allowed:
        await audit.write(
            event_type="access_denied", actor_user_id=user_id,
            target_asset_id=asset_id, target_project_id=project_id,
            target_minio_key=asset.minio_key,
            details={"action": "delete_asset", "reason": "openfga can_admin false"},
            **ctx,
        )
        raise HTTPException(403, "no delete permission")

    # sensitive 门在 can_admin 之后(同 restore:零权限者只见通用 403,不借文案
    # 得知资产敏感分类);仅 hard 分支 —— 软删 sensitive 维持 can_admin 现状
    if hard and is_sensitive and not is_system_admin:
        await audit.write(
            event_type="access_denied", actor_user_id=user_id,
            target_asset_id=asset_id, target_project_id=project_id,
            target_minio_key=asset.minio_key,
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
        # 的 FK 会 violations;溯源用 target_minio_key(无 FK)+ details.asset_id;
        # target_project_id 同为无 FK 依赖的独立列,行删后照常带(W2b)
        await audit.write(
            event_type="asset_purged", actor_user_id=user_id,
            target_project_id=project_id,
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
        target_asset_id=asset_id, target_project_id=project_id,
        target_minio_key=asset.minio_key,
        details={"filename": asset.filename, "soft": True},
        **ctx,
    )


# ─── livp 实况视频预览 URL ────────────────────────────────────────────────────
@router.get("/{asset_id}/live-preview-url")
async def get_live_preview_url(
    asset_id: uuid.UUID,
    request: Request,
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

    # W2b:审计补 target_project_id(folder 并发删的竞速窗口回 None,不炸)
    folder = await db.get(Folder, asset.folder_id)
    project_id = folder.project_id if folder is not None else None

    allowed = is_system_admin or await permissions.check(
        user_subject=user.subject,
        relation="can_download",
        object_type="asset",
        object_id=str(asset_id),
    )
    if not allowed:
        await audit.write(
            event_type="download_denied", actor_user_id=user_id,
            target_asset_id=asset_id, target_project_id=project_id,
            target_minio_key=asset.minio_key,
            details={"reason": "openfga can_download false", "kind": "live_preview"},
            **ctx,
        )
        raise HTTPException(403, "no permission to preview(可申请审批)")

    ttl = 1800
    # 实况视频派生对象与缩略图同 bucket(缩略图 MinIO),动态签发同 sign_thumbnail_url:
    # request_base 传入时 host 跟随浏览器入口(接近原片内容,https 入口必须 https)
    url = presign.sign_thumbnail_url(str(live_key), ttl, request_base=request_base_from(request))
    await audit.signed_url_issued(
        actor_user_id=user_id,
        target_asset_id=asset.id,
        target_project_id=project_id,
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


def _new_asset_key(minio_prefix: str, filename: str) -> str:
    """资产 canonical key 规则 —— 与 complete_upload 的拼接规则逐字一致:
    `f"{folder.minio_prefix.rstrip('/')}/{filename}"`(§F3;百度导入侧按同一
    规则落库 —— 三处口径必须一致,这里抽函数供单测钉死,改动需三处同步)。"""
    return f"{minio_prefix.rstrip('/')}/{filename}"


async def _project_bucket(db: AsyncSession, project_id: uuid.UUID) -> str:
    project = await db.get(Project, project_id)
    if not project:
        raise HTTPException(400, "project not found")
    return project.minio_bucket
