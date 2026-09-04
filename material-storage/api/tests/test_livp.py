"""livp(Live Photo)worker 单测 — 纯函数,不依赖 DB / MinIO / ffmpeg。"""
from __future__ import annotations

import io
import zipfile

import pytest

from app.workers.main import _copy_livp_entry, _pick_livp_entries, _read_livp_entry_capped


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


def test_pick_skips_oversized_entries(monkeypatch: pytest.MonkeyPatch) -> None:
    """zip 炸弹防护:声明大小超上限的条目直接忽略,不参与挑选。"""
    from app.workers import main as w
    monkeypatch.setattr(w, "_LIVP_IMAGE_MAX_BYTES", 10)
    monkeypatch.setattr(w, "_LIVP_VIDEO_MAX_BYTES", 10)
    zf = _zip_from({
        "big.jpg": b"x" * 100,   # 超限静态图 → 跳过
        "big.mov": b"y" * 100,   # 超限视频 → 跳过
        "ok.jpg": b"j",          # 正常静态图 → 选中
    })
    still, video = w._pick_livp_entries(zf)
    assert still is not None and still.filename == "ok.jpg"
    assert video is None


def test_copy_livp_entry_enforces_limit(tmp_path) -> None:  # type: ignore[no-untyped-def]
    """计数拷贝兜底:实际解压量超上限(声明值伪造小)即断,不写满磁盘。"""
    zf = _zip_from({"v.mov": b"a" * 100})
    with zf.open("v.mov") as f:
        with pytest.raises(RuntimeError, match="超上限"):
            _copy_livp_entry(f, tmp_path / "out.bin", 50)

    # 上限内正常落盘
    with zf.open("v.mov") as f:
        _copy_livp_entry(f, tmp_path / "out2.bin", 200)
    assert (tmp_path / "out2.bin").read_bytes() == b"a" * 100


def test_read_livp_entry_capped() -> None:
    """静态图路径的真实流上限(F4):超限即断,上限内原样读出。"""
    zf = _zip_from({"still.jpg": b"j" * 300})
    with zf.open("still.jpg") as f:
        with pytest.raises(RuntimeError, match="超上限"):
            _read_livp_entry_capped(f, 100)
    with zf.open("still.jpg") as f:
        assert _read_livp_entry_capped(f, 500) == b"j" * 300
