"""livp(Live Photo)worker 单测 — 纯函数,不依赖 DB / MinIO / ffmpeg。"""
from __future__ import annotations

import io
import zipfile

from app.workers.main import _pick_livp_entries


def _zip_from(entries: dict[str, bytes]) -> zipfile.ZipFile:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        for name, data in entries.items():
            zf.writestr(name, data)
    return zipfile.ZipFile(buf)


def test_pick_standard_livp() -> None:
    """典型 iPhone 导出:IMG_x.JPG.jpeg(静态图)+ IMG_x.JPG.mov(实况)。"""
    zf = _zip_from({
        "IMG_1450.JPG.jpeg": b"j" * 100,
        "IMG_1450.JPG.mov": b"m" * 200,
    })
    still, video = _pick_livp_entries(zf)
    assert still is not None and still.filename == "IMG_1450.JPG.jpeg"
    assert video is not None and video.filename == "IMG_1450.JPG.mov"


def test_pick_heic_still() -> None:
    """「高效」格式 iPhone:静态图是 HEIC。"""
    zf = _zip_from({
        "IMG_1.HEIC": b"h" * 50,
        "IMG_1.mov": b"m" * 10,
    })
    still, video = _pick_livp_entries(zf)
    assert still is not None and still.filename == "IMG_1.HEIC"
    assert video is not None and video.filename == "IMG_1.mov"


def test_pick_largest_when_multiple_candidates() -> None:
    """同目录混入小占位文件 / 多份时取最大者。"""
    zf = _zip_from({
        "small.jpg": b"s",
        "big.jpg": b"b" * 999,
        "a.mov": b"m" * 5,
        "b.mov": b"m" * 500,
    })
    still, video = _pick_livp_entries(zf)
    assert still is not None and still.filename == "big.jpg"
    assert video is not None and video.filename == "b.mov"


def test_pick_photo_only_livp() -> None:
    """只有静态图(无实况)也应能处理,video 返 None。"""
    zf = _zip_from({"IMG_1.jpeg": b"j" * 10})
    still, video = _pick_livp_entries(zf)
    assert still is not None and video is None


def test_pick_empty_zip() -> None:
    zf = _zip_from({})
    still, video = _pick_livp_entries(zf)
    assert still is None and video is None


def test_pick_ignores_dirs_and_unknown_exts() -> None:
    zf = _zip_from({
        "metadata.plist": b"p" * 300,       # 非媒体扩展名,不参与
        "nested/": b"",                      # 目录条目
        "IMG_1.jpg": b"j",
    })
    still, video = _pick_livp_entries(zf)
    assert still is not None and still.filename == "IMG_1.jpg"
    assert video is None
