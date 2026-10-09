"""活跃 asset 物理删除业务流 — 方案 §5.1(批次 2 抽取,router 与 worker 共用)。

与 routers/assets.py delete_asset 的硬删分支(assets.py:771-823)的差异:
- 硬删端点有"先软删再彻底清除"两步制前置(assets.py:771-773),对活跃 asset 会
  409 —— 覆盖导入(清除-再导入)需要的是**活跃 asset 直接物理删除**,故抽本业务流;
- purge 后 **head_object 断言 NoSuchKey 证实删除**:purge_asset_storage 对
  delete_object 异常仅 log 不抛(asset_cleanup.py:26-30),未证实 → 视为 purge
  失败(PurgeIncompleteError),调用方落 failed('purge_incomplete');
- audit `asset_purged` 不带 target_asset_id(行已删会 FK violation,循
  assets.py:814-822 的 target_minio_key + details.asset_id 口径)。

同步 boto3 一律 asyncio.to_thread 包裹(worker/router 同规则,assets.py:791-794 先例)。
"""
from __future__ import annotations

import asyncio
import logging
import uuid
from typing import Any

from botocore.exceptions import ClientError  # type: ignore[import-untyped]
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.tables import Asset
from app.services.asset_cleanup import purge_asset_storage
from app.services.audit import AuditService
from app.services.permissions import PermissionsService
from app.services.presign import PresignService

log = logging.getLogger(__name__)

# head_object 404 类错误码(MinIO 返回 "404"/"NoSuchKey";部分端点 "NotFound")
_OBJECT_GONE_CODES = frozenset({"404", "NoSuchKey", "NotFound"})


class PurgeIncompleteError(Exception):
    """purge 后 head 仍命中(未证实删除);携带快照供 purge_incomplete 重试直呼。"""

    def __init__(self, *, bucket: str, key: str, message: str | None = None) -> None:
        super().__init__(message or f"purge 未证实(对象仍存在): bucket={bucket} key={key}")
        self.bucket = bucket
        self.key = key


def _error_code(e: ClientError) -> str:
    resp = e.response or {}
    err = resp.get("Error") or {}
    return str(err.get("Code", ""))


async def object_exists(presign: PresignService, *, bucket: str, key: str) -> bool | None:
    """对象存在性探测(to_thread):True=仍在,False=已证实删除,None=探测失败。"""
    def _probe() -> bool | None:
        try:
            presign.head_object(bucket, key)
            return True
        except ClientError as e:
            if _error_code(e) in _OBJECT_GONE_CODES:
                return False
            raise
    try:
        return await asyncio.to_thread(_probe)
    except ClientError as e:
        log.warning("head probe fail bucket=%s key=%s err=%s", bucket, key, e)
        return None


async def purge_object_verified(
    presign: PresignService, *, bucket: str, key: str, tags: dict[str, Any],
) -> None:
    """purge(主对象+缩略图派生对象)→ head 断言 NoSuchKey;未证实抛 PurgeIncompleteError。

    纯对象级操作(无 DB 行)—— purge_incomplete 重试按快照直呼,不依赖已删 asset 行。
    """
    await asyncio.to_thread(purge_asset_storage, presign, bucket, key, tags)
    exists = await object_exists(presign, bucket=bucket, key=key)
    if exists is not False:
        raise PurgeIncompleteError(
            bucket=bucket, key=key,
            message=f"purge 未证实(head {'仍命中' if exists else '探测失败'}): bucket={bucket} key={key}",
        )


async def cleanup_asset_tuples(permissions: PermissionsService, asset_id: uuid.UUID) -> None:
    """OpenFGA asset tuple 清理(assets.py:796-812 同款:逐条 tolerate,失败仅告警)。"""
    from openfga_sdk.client.models import ClientTuple, ClientWriteRequest
    from openfga_sdk.models import ReadRequestTupleKey
    try:
        resp = await permissions._client.read(
            ReadRequestTupleKey(object=f"asset:{asset_id}")  # type: ignore[no-untyped-call]
        )
        for t in resp.tuples:
            try:
                await permissions._client.write(
                    ClientWriteRequest(deletes=[ClientTuple(
                        user=t.key.user, relation=t.key.relation, object=t.key.object,
                    )])
                )
            except Exception:
                log.debug("asset tuple delete tolerate %s %s %s",
                          t.key.user, t.key.relation, t.key.object)
    except Exception as e:
        log.warning("purge asset tuple cleanup fail asset=%s err=%s", asset_id, e)


async def purge_active_asset(
    *,
    db: AsyncSession,
    permissions: PermissionsService,
    presign: PresignService,
    audit: AuditService,
    asset_id: uuid.UUID,
    actor_user_id: uuid.UUID | None = None,
    audit_details: dict[str, Any] | None = None,
) -> dict[str, Any] | None:
    """活跃 asset 物理删除:删行 → purge(线程池)→ head 断言 → FGA 清理 → 审计。

    返回快照 dict(bucket/key/filename);asset 行已不存在(并发删除/purge_incomplete
    重试场景)→ 返回 None(调用方按"旧对象需另行 purge_object_verified 断言"处理);
    purge 未证实抛 PurgeIncompleteError(**行已删且已 commit**,重试走快照路径)。
    """
    asset = await db.get(Asset, asset_id)
    if asset is None:
        return None
    # commit 前快照:delete 后实例属性过期不可读(assets.py:774 同款)
    snapshot: dict[str, Any] = {
        "bucket": asset.minio_bucket,
        "key": asset.minio_key,
        "filename": asset.filename,
        "tags": dict(asset.tags or {}),
    }
    await db.delete(asset)
    await db.commit()

    # ── DB 删除成功之后:清理失败只留无害孤儿 ──(assets.py:788 同序)
    await purge_object_verified(
        presign, bucket=str(snapshot["bucket"]), key=str(snapshot["key"]), tags=snapshot["tags"],
    )
    await cleanup_asset_tuples(permissions, asset_id)
    # audit 不带 target_asset_id(行已删,FK 会 violation;循 assets.py:814-822 口径)
    details = {
        "asset_id": str(asset_id),
        "filename": snapshot["filename"],
        "hard": True,
        "source": "baidu_backup_overwrite",
    }
    if audit_details:
        details.update(audit_details)
    await audit.write(
        event_type="asset_purged",
        actor_user_id=actor_user_id,
        target_minio_key=str(snapshot["key"]),
        details=details,
    )
    log.info("asset purged(baidu overwrite) asset=%s bucket=%s key=%s",
             asset_id, snapshot["bucket"], snapshot["key"])
    return snapshot
