"""livp 下载级解包 job 本体 — generate_livp_download 失败分级直测(方案 §2.2 第 7 步)。

独立成文件的说明:tests/test_livp.py 按仓库惯例是纯函数钉子(不 mock、不碰 IO);
job 本体直测需对 app.workers.main 的模块属性(boto3 / get_sessionmaker /
get_settings / _merge_asset_tags / _transcode_livp_video_download)打桩 —— 属
tests/test_batch_download_link.py 的 stub 风格,与纯函数钉子分文件存放。

Seam 说明(契约钉死 / 仓库惯例假设):
  - job:app.workers.main.generate_livp_download(ctx, asset_id) 契约钉死;
  - boto3 / get_sessionmaker / get_settings 按 workers/main.py 模块级 import 打桩
    (与 test_batch_download_link.py 的 patch_batch_worker 同款);
  - _merge_asset_tags 以记录器替身替换(断言 tags 落点与失败分级,不触真 DB);
  - 视频转码失败以 monkeypatch _transcode_livp_video_download=False 模拟(不依赖
    真 ffmpeg);瞬时失败以 download_file 抛 ConnectionError 模拟;静态图用 .jpg
    原字节透传路径(免 HEIC 解码依赖)。

测试 → 失败分级映射(§2.2 第 7 步,任务清单 B8):
  超 200MB 防御上限 → download_zip_failed="oversize" 永久 tag,正常 return
  (arq 不重试;§3 404 自愈按 tag 有值不重派),不触 MinIO
                                    → test_oversize_livp_permanent_tag_and_skips_storage
  无静态图条目 → 永久 tag(_LivpDownloadPermanentError 类型名),正常 return,
  不上传产物
                                    → test_no_still_image_permanent_tag_no_upload
  瞬时异常(MinIO 网络错)→ re-raise 不落 tag(arq 按 max_tries=2 重试;
  落了就把资产挡在自愈回路外)
                                    → test_transient_minio_error_reraises_without_tag
  视频转码失败 → 非 job 失败:降级「仅 jpg 的 zip」+ download_zip_video_failed
  时间戳(只清 download_zip_failed,不清降级观测标记)
                                    → test_video_transcode_failure_degrades_to_jpg_only_zip
"""
from __future__ import annotations

import io
import uuid
import zipfile
from datetime import datetime
from types import SimpleNamespace
from typing import Any

import pytest

import app.workers.main as livp_main
from app.db.tables import Asset
from app.settings import Settings
from app.workers.main import _LIVP_MAX_BYTES, generate_livp_download


# ─── 通用替身(stub 风格沿用 tests/test_batch_download_link.py)─────────────────
def mk_settings(**overrides: object) -> Settings:
    base: dict[str, object] = {
        "env": "test",
        "db_url": "postgresql+asyncpg://u:p@localhost/db",
        "redis_url": "redis://localhost:6379/0",
        "minio_endpoint_internal": "http://minio:9000",
        "minio_endpoint_public": "http://localhost:9000",
        "minio_access_key": "k",
        "minio_secret_key": "s",
        "openfga_api_url": "http://openfga:8080",
        "openfga_store_id": "01TEST",
        "web_app_base_url": "http://localhost/ms-static/web/",
        "session_jwt_secret": "test-secret",
    }
    base.update(overrides)
    return Settings(**base)  # type: ignore[arg-type]


def mk_livp_asset(**overrides: Any) -> SimpleNamespace:
    aid = uuid.uuid4()
    row = SimpleNamespace(
        id=aid,
        deleted_at=None,
        filename="IMG_0001.livp",
        folder_id=uuid.uuid4(),
        minio_bucket="ms-proj",
        minio_key="folder-a/IMG_0001.livp",
        size_bytes=1024,
        content_type="application/octet-stream",
        tags={},
    )
    for k, v in overrides.items():
        setattr(row, k, v)
    return row


class LivpS3:
    """job 用 s3 替身:download_file 把预置 zip 源字节落盘(可注入瞬时异常);
    put_object 记录入参(Body 读成 bytes 供产物断言)。"""

    def __init__(self, source: bytes, *, raise_on_download: Exception | None = None) -> None:
        self._source = source
        self._raise = raise_on_download
        self.download_calls: list[tuple[str, str]] = []
        self.put_calls: list[dict[str, Any]] = []

    def download_file(self, Bucket: str, Key: str, Filename: str) -> None:
        self.download_calls.append((Bucket, Key))
        if self._raise is not None:
            raise self._raise
        with open(Filename, "wb") as f:
            f.write(self._source)

    def put_object(
        self, Bucket: str | None = None, Key: str | None = None, Body: Any = None, **kw: Any
    ) -> dict:
        self.put_calls.append({
            "bucket": Bucket,
            "key": Key,
            "body": Body.read() if hasattr(Body, "read") else Body,
            "kwargs": kw,
        })
        return {}


class LivpDB:
    def __init__(self, rows: list[Any]) -> None:
        self._rows = {r.id: r for r in rows}

    async def get(self, model: Any, pk: Any) -> Any | None:
        return self._rows.get(pk) if model is Asset else None


class _LivpSessCtx:
    def __init__(self, db: LivpDB) -> None:
        self._db = db

    async def __aenter__(self) -> LivpDB:
        return self._db

    async def __aexit__(self, *exc: Any) -> bool:
        return False


class LivpSessionmaker:
    def __init__(self, rows: list[Any]) -> None:
        self._db = LivpDB(rows)

    def __call__(self) -> _LivpSessCtx:
        return _LivpSessCtx(self._db)


class TagRecorder:
    """_merge_asset_tags 替身:记录 (sets, removes) 落点,断言失败分级写点。"""

    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []

    async def __call__(self, sm: Any, aid: Any, sets: Any = None, removes: Any = ()) -> None:
        self.calls.append({
            "aid": aid,
            "sets": dict(sets or {}),
            "removes": tuple(removes),
        })

    def only(self) -> dict[str, Any]:
        assert len(self.calls) == 1, f"应恰一次 tags 合并写点: {self.calls!r}"
        return self.calls[0]


def patch_livp_worker(
    monkeypatch: pytest.MonkeyPatch,
    *,
    rows: list[Any],
    s3: LivpS3,
    tags: TagRecorder,
) -> None:
    """按仓库惯例(workers/main.py:模块级 import boto3 + get_sessionmaker)打桩。"""
    monkeypatch.setattr(
        livp_main, "boto3", SimpleNamespace(client=lambda *a, **k: s3), raising=False,
    )
    monkeypatch.setattr(
        livp_main, "get_sessionmaker", lambda: LivpSessionmaker(rows), raising=False,
    )
    monkeypatch.setattr(livp_main, "get_settings", lambda: mk_settings(), raising=False)
    monkeypatch.setattr(livp_main, "_merge_asset_tags", tags, raising=False)


def zip_bytes(entries: dict[str, bytes]) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        for name, data in entries.items():
            zf.writestr(name, data)
    return buf.getvalue()


# ─── 失败分级(§2.2 第 7 步)───────────────────────────────────────────────────
async def test_oversize_livp_permanent_tag_and_skips_storage(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """B8:超 200MB 防御上限 = 永久失败(重派注定同结果)→ download_zip_failed
    = "oversize" 落 tag 后正常 return(arq 不重试);不触 MinIO、不写成功 key。"""
    asset = mk_livp_asset(size_bytes=_LIVP_MAX_BYTES + 1)
    s3 = LivpS3(b"PK\x03\x04never-fetched")
    tags = TagRecorder()
    patch_livp_worker(monkeypatch, rows=[asset], s3=s3, tags=tags)

    out = await generate_livp_download({}, str(asset.id))

    assert out["status"] == "skip_too_large"
    assert out["size_bytes"] == _LIVP_MAX_BYTES + 1
    call = tags.only()
    assert call["sets"] == {"download_zip_failed": "oversize"}, (
        f"永久失败 tag 值: {call['sets']!r}"
    )
    assert call["removes"] == (), "不得误清失败观测键"
    assert s3.download_calls == [] and s3.put_calls == [], "超限短路不触 MinIO"


async def test_no_still_image_permanent_tag_no_upload(monkeypatch: pytest.MonkeyPatch) -> None:
    """B8:livp 内无静态图条目(jpg/heic/png)= 永久失败 → 落
    download_zip_failed(tag 值 = 异常类型名,与 _thumb_fail_token 同口径)后正常
    return(arq 不重试);不上传产物。"""
    asset = mk_livp_asset()
    src = zip_bytes({"IMG_0001.JPG.mov": b"\x00\x00\x00\x18ftypmp42"})   # 只有视频
    s3 = LivpS3(src)
    tags = TagRecorder()
    patch_livp_worker(monkeypatch, rows=[asset], s3=s3, tags=tags)

    out = await generate_livp_download({}, str(asset.id))

    assert out["status"] == "failed_permanent"
    call = tags.only()
    assert call["sets"] == {"download_zip_failed": "_LivpDownloadPermanentError"}, (
        f"永久 tag = 异常类型名: {call['sets']!r}"
    )
    assert s3.download_calls == [(asset.minio_bucket, asset.minio_key)], "拉源已发生(败在解包段)"
    assert s3.put_calls == [], "永久失败不得上传产物"


async def test_transient_minio_error_reraises_without_tag(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """B8:瞬时失败(MinIO 网络错)→ 不落 download_zip_failed(落了就把资产挡在
    404 自愈回路外),re-raise 交给 arq 按 max_tries=2 重试。"""
    asset = mk_livp_asset()
    s3 = LivpS3(b"", raise_on_download=ConnectionError("minio down"))
    tags = TagRecorder()
    patch_livp_worker(monkeypatch, rows=[asset], s3=s3, tags=tags)

    with pytest.raises(ConnectionError, match="minio down"):
        await generate_livp_download({}, str(asset.id))

    assert tags.calls == [], "瞬时失败不落任何 tag"
    assert s3.put_calls == [], "未产出产物不得上传"
    assert s3.download_calls == [(asset.minio_bucket, asset.minio_key)]


async def test_video_transcode_failure_degrades_to_jpg_only_zip(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """B8:视频转码失败不是 job 失败 —— 降级「仅 jpg 的 zip」交付,落
    download_zip_video_failed 时间戳(观测),tags 只清 download_zip_failed
    (不清降级标记本身);上传产物仅 {基名}.jpg 无 mp4 条目。"""
    asset = mk_livp_asset()
    src = zip_bytes({
        "IMG_0001.JPG.jpeg": b"\xff\xd8fakejpeg",
        "IMG_0001.JPG.mov": b"\x00\x00\x00\x18ftypmp42",
    })
    s3 = LivpS3(src)
    tags = TagRecorder()
    patch_livp_worker(monkeypatch, rows=[asset], s3=s3, tags=tags)
    monkeypatch.setattr(livp_main, "_transcode_livp_video_download", lambda *a, **k: False)

    out = await generate_livp_download({}, str(asset.id))

    assert out["status"] == "ok"
    assert out["video_degraded"] is True
    dl_key = f"derivatives/{asset.id}/livp.zip"
    assert out["download_zip_key"] == dl_key
    call = tags.only()
    sets = call["sets"]
    assert sets["download_zip_key"] == dl_key
    assert sets["download_zip_size_bytes"] == out["size_bytes"] > 0
    # 降级标记必须是可解析的 ISO 时间戳(观测口径)
    datetime.fromisoformat(str(sets["download_zip_video_failed"]))
    assert call["removes"] == ("download_zip_failed",), "降级不是失败:只清失败标记"
    up = s3.put_calls[0]
    assert (up["bucket"], up["key"]) == (asset.minio_bucket, dl_key)
    body = up["body"]
    assert sets["download_zip_size_bytes"] == len(body)
    with zipfile.ZipFile(io.BytesIO(body)) as zf:
        assert zf.namelist() == ["IMG_0001.jpg"], f"降级仅 jpg: {zf.namelist()!r}"
