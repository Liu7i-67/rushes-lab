"""缩略图管线共享常量与受纳判定(thumb-variant 方案 §3.1;BE1 落地,各包只 import)。

判定口径:content_type 前缀 OR 扩展名兜底 —— Firefox 等浏览器上传 .mov/.heic 落
octet-stream 的派发盲区(方案 §3 A2)。两份扩展名清单的刻意留空:
  - VIDEO_EXTS 不含 .ts:与 TypeScript 源码撞扩展名,素材库误派发成本高于
    MPEG-TS 素材的稀缺收益;
  - IMAGE_EXTS 不含 .svg:Pillow 无栅格化能力,派发必败(方案 §13 留痕)。
"""
from __future__ import annotations

from pathlib import Path

VIDEO_EXTS = {
    ".mp4", ".mov", ".webm", ".m4v", ".avi", ".mkv", ".3gp",
    ".mts", ".m2ts", ".wmv", ".mpg", ".mpeg",
}
IMAGE_EXTS = {
    ".jpg", ".jpeg", ".png", ".webp", ".gif", ".heic", ".heif",
    ".bmp", ".tiff", ".tif",
}

# small 变体规格(方案 §4 B1;D1 拍板 240px)与视频 URL 主路径防御上限(D4)
THUMB_SMALL_MAX_PX = 240
VIDEO_THUMB_ABSOLUTE_MAX_BYTES = 8 * 1024**3


def is_video_asset(filename: str, content_type: str | None) -> bool:
    """视频受纳判定:content_type video/* 前缀 OR 扩展名命中 VIDEO_EXTS。"""
    if content_type and content_type.startswith("video/"):
        return True
    return Path(filename).suffix.lower() in VIDEO_EXTS


def is_image_asset(filename: str, content_type: str | None) -> bool:
    """图片受纳判定:content_type image/* 前缀(排除 image/svg+xml)OR 扩展名命中。"""
    if content_type and content_type.startswith("image/") and content_type != "image/svg+xml":
        return True
    return Path(filename).suffix.lower() in IMAGE_EXTS


def is_livp_asset(filename: str) -> bool:
    """livp 受纳判定:.livp 扩展名(大小写不敏感)。"""
    return Path(filename).suffix.lower() == ".livp"
