"""彻底删除(purge)资产时的存储对象清理 — best-effort。

调用时机统一在 **DB 行删除 commit 成功之后**:清理失败只留下孤儿对象
(不可见、无权限含义),不会出现"对象没了行还在"的断链。这与文件夹删除的
tuple 清理放在 commit 后是同一取舍。

清理范围:
  - 主存储原对象(bucket/key)
  - 缩略图 MinIO 上的派生对象:tags['thumbnail_key']、tags['live_video_key']
"""
from __future__ import annotations

import logging
from typing import Any

from app.services.presign import PresignService

log = logging.getLogger(__name__)


def purge_asset_storage(presign: PresignService, bucket: str, key: str, tags: dict[str, Any]) -> None:
    """删主对象 + 缩略图派生对象;单项失败只 log,不抛(孤儿对象无害)。"""
    targets: list[tuple[str, str]] = [(bucket, key)]
    thumb_bucket = presign.thumbnail_bucket
    for tag in ("thumbnail_key", "live_video_key"):
        if tags.get(tag):
            targets.append((thumb_bucket, str(tags[tag])))
    for b, k in targets:
        try:
            presign.delete_object(b, k)
        except Exception as e:  # noqa: BLE001
            log.warning("purge asset object fail bucket=%s key=%s err=%s", b, k, e)
