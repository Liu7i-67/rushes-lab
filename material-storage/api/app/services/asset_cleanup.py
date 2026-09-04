"""彻底删除(purge)资产时的存储对象清理 — best-effort。

调用时机统一在 **DB 行删除 commit 成功之后**:清理失败只留下孤儿对象
(不可见、无权限含义),不会出现"对象没了行还在"的断链。这与文件夹删除的
tuple 清理放在 commit 后是同一取舍。

清理范围(ADR-0008 分层):
  - 主存储原对象(bucket/key,HDD 实例)
  - 缩略图 MinIO(SSD 实例)上的派生对象:tags['thumbnail_key']、tags['live_video_key']
    —— 两个实例 endpoint 不同,必须各走各的 client,删错实例会 NoSuchBucket 被吞
"""
from __future__ import annotations

import logging
from typing import Any

from app.services.presign import PresignService

log = logging.getLogger(__name__)

# 派生对象 tag key → 清理通道(均存缩略图 MinIO)
_DERIVED_TAG_KEYS = ("thumbnail_key", "live_video_key")


def purge_asset_storage(presign: PresignService, bucket: str, key: str, tags: dict[str, Any]) -> None:
    """删主对象 + 缩略图派生对象;单项失败只 log,不抛(孤儿对象无害)。"""
    try:
        presign.delete_object(bucket, key)
    except Exception as e:  # noqa: BLE001
        log.warning("purge asset object fail bucket=%s key=%s err=%s", bucket, key, e)
    for tag in _DERIVED_TAG_KEYS:
        derived = tags.get(tag)
        if not derived:
            continue
        try:
            presign.delete_thumbnail_object(str(derived))
        except Exception as e:  # noqa: BLE001
            log.warning("purge derived object fail key=%s err=%s", derived, e)
