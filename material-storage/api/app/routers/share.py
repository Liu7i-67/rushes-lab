"""share router — 资源分享短链(#154:飞书 IM 推送下线后为纯链接分享)。

endpoints:
  POST /api/v1/share/assets/{asset_id}   — 创建 asset 分享链接;需 can_download
  POST /api/v1/share/folders/{folder_id} — 创建 folder 分享链接;需 can_view
  GET  /api/v1/share/{token}             — 解析短链 → 返资源 metadata + presigned URL

短链 token 存 audit_events.details(iter3 最小版,不引新表);
GET endpoint 必须有 session cookie(短链默认 requires_login=True);
不登录 → 401(前端 SPA 跳本地登录页 + next=当前 URL)。
"""
from __future__ import annotations

import asyncio
import logging
import uuid

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.session import get_db
from app.db.tables import Asset, Folder
from app.deps import (
    get_audit,
    CurrentUser,
    get_current_user,
    get_is_system_admin,
    get_permissions,
    get_presign,
    get_request_context,
)
from app.routers.assets import attachment_content_disposition
from app.services.audit import AuditService
from app.services.permissions import PermissionsService
from app.services.presign import PresignService, request_base_from
from app.services.share_service import create_share, resolve_share
from app.settings import get_settings

log = logging.getLogger(__name__)
router = APIRouter()


# ─── input / output models ────────────────────────────────────────────────────
class ShareCreateIn(BaseModel):
    expires_in_seconds: int = Field(86400, ge=60, le=30 * 86400,
                                     description="链接有效期;60s ~ 30 天")
    requires_login: bool = Field(True, description="True = 访问短链必须登录(默认)")


class ShareCreateOut(BaseModel):
    token: str
    landing_url: str
    expires_at: str


class ShareResolveOut(BaseModel):
    kind: str           # asset / folder
    target_id: uuid.UUID
    sharer_name: str | None
    expires_at: str
    # asset 专属
    asset: dict | None = None
    download_url: str | None = None
    download_expires_in: int | None = None
    # folder 专属
    folder: dict | None = None


# ─── POST share asset ─────────────────────────────────────────────────────────
@router.post("/assets/{asset_id}", response_model=ShareCreateOut)
async def share_asset(
    asset_id: uuid.UUID,
    payload: ShareCreateIn,
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    audit: AuditService = Depends(get_audit),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
    ctx: dict = Depends(get_request_context),
) -> ShareCreateOut:
    user_id = user.id
    asset = await db.get(Asset, asset_id)
    if asset is None or asset.deleted_at is not None:
        raise HTTPException(404, "asset not found")

    # W2b:审计补 target_project_id(folder 并发删的竞速窗口回 None,不炸)
    folder = await db.get(Folder, asset.folder_id)

    # 分享者必须 can_download 该 asset;系统 admin 直通
    allowed = is_system_admin or await permissions.check(
        user_subject=user.subject, relation="can_download",
        object_type="asset", object_id=str(asset_id),
    )
    if not allowed:
        await audit.write(
            event_type="access_denied",
            actor_user_id=user_id, target_asset_id=asset_id,
            target_project_id=folder.project_id if folder is not None else None,
            details={"action": "share_asset", "reason": "openfga can_download false"},
            **ctx,
        )
        raise HTTPException(403, "no permission to share(需 can_download)")

    info = await create_share(
        audit=audit, db=db, kind="asset", target_id=asset_id,
        sharer_user_id=user_id,
        expires_in_seconds=payload.expires_in_seconds,
        requires_login=payload.requires_login,
    )
    settings = get_settings()
    return ShareCreateOut(
        token=info["token"],
        landing_url=_landing_url(settings, info["token"]),
        expires_at=info["expires_at"].isoformat(),
    )


# ─── POST share folder ────────────────────────────────────────────────────────
@router.post("/folders/{folder_id}", response_model=ShareCreateOut)
async def share_folder(
    folder_id: uuid.UUID,
    payload: ShareCreateIn,
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    audit: AuditService = Depends(get_audit),
    user: CurrentUser = Depends(get_current_user),
    is_system_admin: bool = Depends(get_is_system_admin),
    ctx: dict = Depends(get_request_context),
) -> ShareCreateOut:
    user_id = user.id
    folder = await db.get(Folder, folder_id)
    if folder is None:
        raise HTTPException(404, "folder not found")

    object_type = "sensitive_folder" if folder.is_sensitive else "folder"
    # 系统 admin 直通
    allowed = is_system_admin or await permissions.check(
        user_subject=user.subject, relation="can_view",
        object_type=object_type, object_id=str(folder_id),
    )
    if not allowed:
        await audit.write(
            event_type="access_denied",
            actor_user_id=user_id,
            details={"action": "share_folder", "folder_id": str(folder_id),
                     "reason": "openfga can_view false"},
            **ctx,
        )
        raise HTTPException(403, "no permission to share(需 can_view)")

    info = await create_share(
        audit=audit, db=db, kind="folder", target_id=folder_id,
        sharer_user_id=user_id,
        expires_in_seconds=payload.expires_in_seconds,
        requires_login=payload.requires_login,
    )
    settings = get_settings()
    return ShareCreateOut(
        token=info["token"],
        landing_url=_landing_url(settings, info["token"]),
        expires_at=info["expires_at"].isoformat(),
    )


# ─── GET resolve ──────────────────────────────────────────────────────────────
@router.get("/{token}", response_model=ShareResolveOut)
async def resolve(
    token: str,
    request: Request,
    db: AsyncSession = Depends(get_db),
    permissions: PermissionsService = Depends(get_permissions),
    presign: PresignService = Depends(get_presign),
    audit: AuditService = Depends(get_audit),
    user: CurrentUser = Depends(get_current_user),
    ctx: dict = Depends(get_request_context),
) -> ShareResolveOut:
    user_id = user.id
    """解析短链 → 返 metadata + presigned download_url(asset)。

    minimal 版:始终 require login(get_current_user 401 时前端 SPA 引导本地登录)。
    """
    info = await resolve_share(db, token)
    if info is None:
        raise HTTPException(404, "share link expired or not found")

    kind = info["kind"]
    target_id: uuid.UUID = info["target_id"]
    settings = get_settings()

    if kind == "asset":
        asset = await db.get(Asset, target_id)
        if asset is None or asset.deleted_at is not None:
            raise HTTPException(404, "asset deleted")

        # W2b:审计补 target_project_id(folder 并发删的竞速窗口回 None,不炸)
        folder = await db.get(Folder, asset.folder_id)

        # livp 下载级解包交付(livp-download-unpack 方案 §4,F4):livp 且衍生物
        # tag 就绪 → 先 head_object 校验对象存在(孤儿 tag → 回落签原始 livp ——
        # share 页前端零改动无回落 UI,兜底必须在服务端,与 download-link 同原则;
        # 同步 boto3 按铁律 asyncio.to_thread 包裹,先例 assets.py batch_prefix);
        # 未就绪/非 livp → 现行为(原始 livp)。分享受众恰是最不懂电脑的人群,收益最大
        # getattr:真实 Asset 行恒有 tags 列(默认 dict);仅非 ORM 替身(既有
        # test_dynamic_presign_host stub 未带该属性)走缺省
        tags = getattr(asset, "tags", None) or {}
        zip_key = tags.get("download_zip_key")
        livp_unpacked = False
        if (
            (asset.filename or "").lower().endswith(".livp")
            and zip_key
        ):
            try:
                await asyncio.to_thread(
                    presign.head_object, asset.minio_bucket, str(zip_key),
                )
                livp_unpacked = True
            except Exception as e:
                log.warning("share livp derivative head fail asset=%s key=%s err=%s",
                            target_id, zip_key, e)

        # 短链豁免 enforce — share owner 已 verified can_download;
        # 但落 audit 记录每次访问(谁、什么时间)
        await audit.write(
            event_type="share_link_accessed",
            actor_user_id=user_id, target_asset_id=target_id,
            target_project_id=folder.project_id if folder is not None else None,
            details={"token": token[:6] + "…", "kind": "asset",
                     "livp_unpacked": livp_unpacked},
            **ctx,
        )
        ttl = settings.presigned_normal_ttl_seconds
        # 分享下载签发同走 attachment 语义(方案 §3.5「分享下载签发同改」):
        # 该 download_url 在前端只用于「下载」按钮,无内联预览复用,无条件 attachment。
        # 动态签发:分享页可能从任一入口打开,直链 host 跟随请求入口,
        # 否则 https 分享页拿到 http 直链被浏览器混合内容拦截
        if livp_unpacked:
            from app.workers.main import _livp_download_base_name
            base = _livp_download_base_name(asset.filename or "", str(asset.id))
            disposition_name = f"{base}.zip"
            sign_key = str(zip_key)
        else:
            disposition_name = asset.filename
            sign_key = asset.minio_key
        url = presign.sign_get_url(
            asset.minio_bucket, sign_key, ttl,
            response_content_disposition=attachment_content_disposition(disposition_name),
            request_base=request_base_from(request),
        )
        return ShareResolveOut(
            kind="asset", target_id=target_id,
            sharer_name=info["sharer_name"],
            expires_at=info["expires_at"].isoformat(),
            asset={
                "id": str(asset.id), "filename": asset.filename,
                "size_bytes": asset.size_bytes, "content_type": asset.content_type,
            },
            download_url=url, download_expires_in=ttl,
        )

    # folder
    folder = await db.get(Folder, target_id)
    if folder is None:
        raise HTTPException(404, "folder deleted")
    await audit.write(
        event_type="share_link_accessed",
        actor_user_id=user_id,
        # W2b:folder 分支同样补 target_project_id(project_id 就在手边)
        target_project_id=folder.project_id,
        details={"token": token[:6] + "…", "kind": "folder",
                 "folder_id": str(target_id)},
        **ctx,
    )
    return ShareResolveOut(
        kind="folder", target_id=target_id,
        sharer_name=info["sharer_name"],
        expires_at=info["expires_at"].isoformat(),
        folder={
            "id": str(folder.id),
            "project_id": str(folder.project_id),
            "name": folder.name,
            "is_sensitive": folder.is_sensitive,
        },
    )


def _landing_url(settings, token: str) -> str:
    base = settings.web_app_base_url.rstrip("/") + "/"
    return f"{base}s/{token}"
