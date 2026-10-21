"""livp(Live Photo)worker 单测 — 纯函数,不依赖 DB / MinIO / ffmpeg。

下载级解包(livp-download-unpack 方案 §2.3/§10)新增三组纯函数钉子:
  - _livp_download_base_name:zip 内名清洗(Windows 非法字符 / 尾部点空格 /
    保留设备名 / 空基名回落 / .LIVP 大小写 / 中文保留)
  - _build_livp_download_zip:组包(内名 / ZIP_STORED / 转码失败降级仅 jpg)
  - _encode_livp_still_jpeg:EXIF orientation 剥除 + 像素转正(防 Windows 查看器
    二次旋转,钉 Pillow 各版本行为差异)、RGBA 白底、ICC 保留
"""
from __future__ import annotations

import io
import zipfile

import pytest
from PIL import Image

from app.workers.main import (
    _build_livp_download_zip,
    _copy_livp_entry,
    _encode_livp_still_jpeg,
    _livp_download_base_name,
    _pick_livp_entries,
    _read_livp_entry_capped,
)


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


def test_pick_dotfile_entries() -> None:
    """空基名点文件条目('.jpg'/'.mov',App 端相册 title 空串的打包产物):
    Path.suffix 视点文件为无扩展名,须按 endswith 判类(2026-10-20 真机实锤,
    prod 上送 '.jpg'+'.mov' 导致「未找到静态图条目」缩略图失败)。"""
    zf = _zip_from({".jpg": b"j" * 100, ".mov": b"m" * 200})
    still, video = _pick_livp_entries(zf)
    assert still is not None and still.filename == ".jpg"
    assert video is not None and video.filename == ".mov"


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


# ─── zip 内名清洗(§2.3,下载级解包)──────────────────────────────────────────
def test_base_name_strips_livp_suffix_case_insensitive() -> None:
    assert _livp_download_base_name("IMG_1450.livp", "3f1b659e-ab") == "IMG_1450"
    assert _livp_download_base_name("IMG_1450.LIVP", "3f1b659e-ab") == "IMG_1450"
    assert _livp_download_base_name("IMG_1450.LivP", "3f1b659e-ab") == "IMG_1450"


def test_base_name_replaces_windows_illegal_chars() -> None:
    # <>:"/\|?* 与控制字符逐个换 _
    assert (
        _livp_download_base_name('a<b>c:"d/e\\f|g?h*i.livp', "x")
        == "a_b_c__d_e_f_g_h_i"
    )
    assert _livp_download_base_name("a\x01b.livp", "x") == "a_b"


def test_base_name_strips_trailing_dots_and_spaces() -> None:
    # 「名字.」「名字 」在资源管理器解压同样出错(§2.3)
    assert _livp_download_base_name("名字.livp", "x") == "名字"
    assert _livp_download_base_name("名字..livp", "x") == "名字"
    assert _livp_download_base_name("名字 .livp", "x") == "名字"
    assert _livp_download_base_name("名字 . ..livp", "x") == "名字"


def test_base_name_reserved_device_names() -> None:
    # 保留设备名加 _ 后缀;含带扩展名形态(Windows 判首个点之前的首段)
    assert _livp_download_base_name("CON.livp", "x") == "CON_"
    assert _livp_download_base_name("con.livp", "x") == "con_"
    assert _livp_download_base_name("CON.jpg.livp", "x") == "CON_.jpg"
    assert _livp_download_base_name("COM1.livp", "x") == "COM1_"
    assert _livp_download_base_name("LPT9.livp", "x") == "LPT9_"
    assert _livp_download_base_name("NUL.livp", "x") == "NUL_"
    # 非保留名不受影响
    assert _livp_download_base_name("CONCERT.livp", "x") == "CONCERT"


def test_base_name_empty_falls_back_to_asset_id() -> None:
    # 空基名(纯点的名字被 rstrip 清空)回落 asset_{id 前 8 位}
    assert _livp_download_base_name(".livp", "3f1b659e-abcd-4") == "asset_3f1b659e"
    assert _livp_download_base_name("... .livp", "01234567-89ab") == "asset_01234567"


def test_base_name_keeps_non_ascii() -> None:
    # 中文保留:zipfile 对非 ASCII 条目名自动打 UTF-8 flag,Win10+ 正确解出
    assert _livp_download_base_name("会议白板 2026.livp", "x") == "会议白板 2026"


# ─── 组包(§2.2 第 5 步)──────────────────────────────────────────────────────
def test_build_download_zip_photo_only(tmp_path) -> None:  # type: ignore[no-untyped-def]
    """photo-only(含视频转码失败降级「仅 jpg 的 zip」形态):video_path=None。"""
    photo = tmp_path / "p.jpg"
    photo.write_bytes(b"JPGDATA")
    out = tmp_path / "out.zip"
    size = _build_livp_download_zip(out, photo, None, "IMG_1")
    with zipfile.ZipFile(out) as zf:
        assert zf.namelist() == ["IMG_1.jpg"]
        assert zf.read("IMG_1.jpg") == b"JPGDATA"
        # ZIP_STORED:jpg/mp4 均已压缩,deflate 白烧 CPU(§2.2 第 5 步)
        assert zf.getinfo("IMG_1.jpg").compress_type == zipfile.ZIP_STORED
    assert size == out.stat().st_size


def test_build_download_zip_photo_plus_video(tmp_path) -> None:  # type: ignore[no-untyped-def]
    photo = tmp_path / "p.jpg"
    photo.write_bytes(b"JPGDATA")
    video = tmp_path / "v.mp4"
    video.write_bytes(b"MP4DATA")
    out = tmp_path / "out.zip"
    _build_livp_download_zip(out, photo, video, "IMG_1")
    with zipfile.ZipFile(out) as zf:
        assert zf.namelist() == ["IMG_1.jpg", "IMG_1.mp4"]
        assert zf.read("IMG_1.mp4") == b"MP4DATA"
        assert zf.getinfo("IMG_1.mp4").compress_type == zipfile.ZIP_STORED


def test_build_download_zip_chinese_base_name(tmp_path) -> None:  # type: ignore[no-untyped-def]
    """非 ASCII 内名:zipfile 自动打 UTF-8 flag(flag_bits & 0x800)。"""
    photo = tmp_path / "p.jpg"
    photo.write_bytes(b"J")
    out = tmp_path / "out.zip"
    _build_livp_download_zip(out, photo, None, "会议白板")
    with zipfile.ZipFile(out) as zf:
        assert zf.namelist() == ["会议白板.jpg"]
        assert zf.getinfo("会议白板.jpg").flag_bits & 0x800


# ─── 静态图转 JPEG(§2.2 第 3 步)────────────────────────────────────────────
def _jpeg_with_orientation(orientation: int, size: tuple[int, int] = (4, 2)) -> bytes:
    img = Image.new("RGB", size, (255, 0, 0))
    exif = Image.Exif()
    exif[0x0112] = orientation
    buf = io.BytesIO()
    img.save(buf, format="JPEG", exif=exif.tobytes())
    return buf.getvalue()


def test_encode_still_strips_orientation_and_transposes_pixels() -> None:
    """EXIF orientation 钉子(§10):转出 JPEG 后 orientation 必须已剥除**且**像素
    已转正 —— 缺一 Windows 查看器都会二次旋转(带原 orientation 落盘 + transpose
    像素 = 双重旋转;只剥标签不转像素 = 不旋转)。Pillow 各版本 transpose 对标签
    剥除行为有差异,以本测试钉住 pillow==12.3.0 的行为。"""
    src = _jpeg_with_orientation(6)  # Rotate 90 CW:显示宽高对调
    src_img = Image.open(io.BytesIO(src))
    assert src_img.getexif().get(0x0112) == 6

    out = _encode_livp_still_jpeg(src)
    out_img = Image.open(io.BytesIO(out))
    assert out_img.format == "JPEG"
    # 像素已转正:(4, 2) 源转出 (2, 4)
    assert out_img.size == (2, 4)
    # EXIF orientation 已剥除(transpose 返回对象自带的 exif 已无该标签)
    assert out_img.getexif().get(0x0112) is None


def test_encode_still_keeps_exif_and_icc() -> None:
    """只传 ICC 不传 EXIF 会丢拍摄时间等元数据;「高效」iPhone 恰是主场景(§2.2):
    非 orientation 的 EXIF(这里用软件标记 0x0131)与 ICC 均应保留。"""
    img = Image.new("RGB", (2, 2), (0, 128, 255))
    exif = Image.Exif()
    exif[0x0131] = "TestSoft"  # Software 标签(非 orientation)
    buf = io.BytesIO()
    img.save(buf, format="JPEG", exif=exif.tobytes(), icc_profile=b"FAKE-ICC")
    out = _encode_livp_still_jpeg(buf.getvalue())
    out_img = Image.open(io.BytesIO(out))
    assert out_img.info.get("icc_profile") == b"FAKE-ICC"
    out_exif = out_img.getexif()
    assert out_exif.get(0x0112) is None          # orientation 仍无
    assert out_exif.get(0x0131) == "TestSoft"    # 其余 EXIF 保留


def test_encode_still_rgba_white_background() -> None:
    """RGBA 透明区贴白底合成:裸 convert("RGB") 会把 alpha 丢成黑底(§2.2 第 3 步)。"""
    img = Image.new("RGBA", (2, 2), (255, 0, 0, 0))  # 全透明红
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    out = _encode_livp_still_jpeg(buf.getvalue())
    out_img = Image.open(io.BytesIO(out))
    assert out_img.mode == "RGB"
    assert out_img.getpixel((0, 0)) == (255, 255, 255)  # 白底而非黑底


def test_encode_still_rgb_passthrough_dims() -> None:
    """无 EXIF 的普通 JPEG 源:像素与尺寸原样,不误转。"""
    img = Image.new("RGB", (3, 5), (10, 20, 30))
    buf = io.BytesIO()
    img.save(buf, format="JPEG")
    out_img = Image.open(io.BytesIO(_encode_livp_still_jpeg(buf.getvalue())))
    assert out_img.size == (3, 5)
    assert out_img.getpixel((0, 0)) == (10, 20, 30)


def test_encode_still_restores_decompression_bomb_cap() -> None:
    """DecompressionBomb 守卫只在解码段内抬高、退出恢复(不放大预览链路口径)。"""
    from app.workers import main as w

    default_cap = Image.MAX_IMAGE_PIXELS
    src = _jpeg_with_orientation(6)
    _encode_livp_still_jpeg(src)
    assert default_cap == Image.MAX_IMAGE_PIXELS
    # 抬高值须大于 Pillow 默认(合法超大全景图放行,§2.2 第 3 步)
    assert default_cap < w._LIVP_DL_MAX_IMAGE_PIXELS
