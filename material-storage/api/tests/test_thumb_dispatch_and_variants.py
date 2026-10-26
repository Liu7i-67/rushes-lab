"""派发兜底 + worker 受纳/cap/skip 标记 + small(240px) 变体派生 — 契约测试。

需求依据:docs/qdev/2026-10-27-thumb-variant-video-cover.md §3.1/§3.4/§3.5,
「测试功能点」1/2/3/5/6。设施沿用仓库 stub 惯例(patch_batch_worker 同款:按
模块属性打桩 boto3/get_sessionmaker/get_settings/_merge_asset_tags;端点直调;
不连真 DB / MinIO / Redis / arq / ffmpeg)。⚠ import app.workers.main 在
WorkerSettings 类体定义期即调 get_settings,无 conftest 注入点 —— 顶部设环境桩。
测试 ↔ 功能点映射见各测试 docstring(1=派发矩阵;2=受纳;3=cap;5=small 接线+隔离;6=derive job)。
"""
from __future__ import annotations

import io
import os
import uuid
import zipfile
from types import SimpleNamespace
from typing import Any

for _k, _v in {
    "DB_URL": "postgresql+asyncpg://u:p@localhost/db", "REDIS_URL": "redis://localhost:6379/0",
    "MINIO_ENDPOINT_INTERNAL": "http://minio:9000", "MINIO_ENDPOINT_PUBLIC": "http://localhost:9000",
    "MINIO_ACCESS_KEY": "k", "MINIO_SECRET_KEY": "s",
    "OPENFGA_API_URL": "http://openfga:8080", "OPENFGA_STORE_ID": "01TEST",
    "WEB_APP_BASE_URL": "http://localhost/ms-static/web/",
    "SESSION_JWT_SECRET": "test-secret-0123456789abcdef",
}.items():
    os.environ.setdefault(_k, _v)

import pytest  # noqa: E402
from botocore.exceptions import ClientError  # noqa: E402
from PIL import Image  # noqa: E402

import app.routers.assets as ar  # noqa: E402
import app.workers.main as wmain  # noqa: E402
from app.db.tables import Folder, Project  # noqa: E402
from app.models import UploadCompleteIn  # noqa: E402
from app.services import thumb_exts  # noqa: E402
from app.settings import Settings  # noqa: E402
from app.workers import thumb_variants  # noqa: E402
from app.workers.baidu_backup import _enqueue_thumbnail  # noqa: E402
from app.workers.main import (  # noqa: E402
    WorkerSettings,
    generate_livp_thumbnail,
    generate_thumbnail,
    generate_video_thumbnail,
)
from app.workers.thumb_variants import derive_and_put_small, derive_small_thumbnail  # noqa: E402

OTS = "application/octet-stream"   # Firefox 等浏览器上传的 content_type(派发盲区)


def _tiny_jpeg() -> bytes:
    img, buf = Image.new("RGB", (64, 32), (200, 10, 10)), io.BytesIO()
    img.save(buf, format="JPEG")
    return buf.getvalue()


_TINY_JPEG = _tiny_jpeg()   # 视频抽帧产物 / 图片族源图 / livp 静态图 / small 派生源


def mk_settings() -> Settings:
    # minio/openfga/redis 等由本模块顶部环境桩提供
    return Settings(env="test", session_jwt_secret="test-secret",
                    db_url="postgresql+asyncpg://u:p@localhost/db")


def mk_asset(**over: Any) -> SimpleNamespace:
    base: dict[str, Any] = dict(id=uuid.uuid4(), deleted_at=None, filename="clip.mov",
                                content_type=OTS, size_bytes=1024,
                                minio_bucket="ms-proj", minio_key="f/clip.mov", tags={})
    base.update(over)
    return SimpleNamespace(**base)


class FakeS3:
    """boto3 client 替身:三族 job 调用面;未实现的调用显式炸(tripwire)。"""

    def __init__(self) -> None:
        self.calls: list[tuple[Any, ...]] = []
        self.put_objects: list[dict[str, Any]] = []
        self.objects: dict[str, bytes] = {}   # 主桶对象内容(download 用)

    def head_bucket(self, *a: Any, **kw: Any) -> dict:
        return {}

    def generate_presigned_url(self, operation: str, Params: Any = None, ExpiresIn: int | None = None) -> str:
        self.calls.append(("presign", operation, dict(Params or {}), ExpiresIn))
        return "http://minio-internal/fake-object?X-Amz-Signature=fake"

    def download_fileobj(self, bucket: str, key: str, buf: Any) -> None:
        self.calls.append(("download_fileobj", bucket, key))
        buf.write(self.objects[key])

    def download_file(self, bucket: str, key: str, path: Any) -> None:
        self.calls.append(("download_file", bucket, key, str(path)))
        with open(path, "wb") as f:
            f.write(self.objects[key])

    def put_object(self, Bucket: str | None = None, Key: str | None = None, Body: Any = None, **kw: Any) -> dict:
        data = Body.read() if hasattr(Body, "read") else bytes(Body)
        self.put_objects.append({"bucket": Bucket, "key": Key, "body": data, **kw})
        return {}


class FakeSM:
    """db 会话替身:async with sm() as db → db.get(Asset, aid) 返回预置行。"""

    def __init__(self, asset: Any) -> None:
        self._asset = asset

    async def get(self, model: Any, pk: Any) -> Any:
        return self._asset

    def __call__(self) -> Any:
        sm = self

        class _Sess:
            async def __aenter__(self) -> Any:
                return sm

            async def __aexit__(self, *exc: Any) -> bool:
                return False

        return _Sess()


class TagRecorder:
    """_merge_asset_tags 替身:记录 (sets, removes),不触真 DB。"""

    def __init__(self) -> None:
        self.merges: list[dict[str, Any]] = []

    async def __call__(self, sm: Any, aid: Any, sets: Any = None, removes: tuple[str, ...] = ()) -> None:
        self.merges.append({"aid": aid, "sets": dict(sets or {}), "removes": tuple(removes)})


class SmallRecorder:
    """derive_and_put_small 替身:记录接线;可注入异常(失败隔离用例)。"""

    def __init__(self, error: BaseException | None = None) -> None:
        self.calls: list[tuple[str, bytes]] = []
        self._error = error

    async def __call__(self, asset_id: str, source: bytes) -> str:
        self.calls.append((asset_id, source))
        if self._error is not None:
            raise self._error
        return f"thumbnails/{asset_id}_s.jpg"


def patch_worker(monkeypatch: pytest.MonkeyPatch, *, asset: Any, s3: FakeS3,
                 merge: TagRecorder, small: SmallRecorder | None = None) -> None:
    """按仓库惯例对 app.workers.main 模块属性打桩(test_batch_download_link 同款)。"""
    monkeypatch.setattr(wmain, "boto3", SimpleNamespace(client=lambda *a, **k: s3))
    monkeypatch.setattr(wmain, "get_sessionmaker", lambda: FakeSM(asset))
    monkeypatch.setattr(wmain, "get_settings", lambda: mk_settings())
    monkeypatch.setattr(wmain, "_merge_asset_tags", merge)
    if small is not None:
        monkeypatch.setattr(thumb_variants, "derive_and_put_small", small)


def patch_url_extract_ok(monkeypatch: pytest.MonkeyPatch) -> None:
    def fake_extract(url: str, out_path: Any, timeout: int) -> bool:
        out_path.write_bytes(_TINY_JPEG)
        return True

    monkeypatch.setattr(wmain, "_extract_video_frame_from_url", fake_extract)


def _ret(value: Any) -> Any:
    async def _fn(*a: Any, **k: Any) -> Any:
        return value
    return _fn


def _fail(*a: Any, **k: Any) -> None:
    raise AssertionError("受纳通过的用例不应 abort multipart")


def test_thumb_exts_acceptance_matrix() -> None:
    """功能点1(判定函数):octet-stream 盲区命中;.svg/.ts 刻意排除;livp/常量。"""
    is_v, is_i = thumb_exts.is_video_asset, thumb_exts.is_image_asset
    assert is_v("clip.mov", OTS) and is_i("IMG_1.heic", OTS)
    assert not is_v("x.ts", OTS) and not is_i("logo.svg", "image/svg+xml") and not is_i("logo.svg", None)
    assert thumb_exts.is_livp_asset("A.LIVP") and thumb_exts.THUMB_SMALL_MAX_PX == 240
    assert thumb_exts.VIDEO_THUMB_ABSOLUTE_MAX_BYTES == 8 * 1024**3


class _Pool:
    def __init__(self) -> None:
        self.jobs: list[tuple[str, ...]] = []

    async def enqueue_job(self, name: str, *args: Any, **kw: Any) -> Any:
        self.jobs.append((name, *(str(a) for a in args)))
        return SimpleNamespace(name=name)


async def run_complete_upload(monkeypatch: pytest.MonkeyPatch, filename: str,
                              content_type: str | None) -> _Pool:
    """功能点1:直调 complete_upload(依赖全 stub),返回派发点用的 arq pool。"""
    pool = _Pool()
    folder = SimpleNamespace(id=uuid.uuid4(), project_id=uuid.uuid4(),
                             minio_prefix="proj-a/", is_sensitive=False)

    async def _db_get(model: Any, pk: Any) -> Any:
        return {Folder: folder,
                Project: SimpleNamespace(id=folder.project_id,
                                         minio_bucket="ms-proj")}.get(model)

    monkeypatch.setattr(ar, "AssetOut", SimpleNamespace(model_validate=lambda a: a))
    request = SimpleNamespace(app=SimpleNamespace(state=SimpleNamespace(arq_pool=pool)),
                              headers={}, url=SimpleNamespace(scheme="http"))
    payload = UploadCompleteIn(upload_id="up-1", folder_id=folder.id, bucket="ms-proj",
                               key=f"proj-a/{filename}",
                               parts=[{"PartNumber": 1, "ETag": "e"}])
    await ar.complete_upload(
        upload_id="up-1", payload=payload, request=request,
        db=SimpleNamespace(get=_db_get, add=lambda o: None, commit=_ret(None),
                           refresh=_ret(None)),
        permissions=SimpleNamespace(check=_ret(True), bootstrap_asset=_ret(None)),
        presign=SimpleNamespace(
            complete_multipart_upload=lambda *a, **k: {"etag": "e"},
            head_object=lambda bucket, key: {"size_bytes": 10, "content_type": content_type,
                                             "etag": "e", "version_id": None,
                                             "metadata": {}},
            abort_multipart_upload=_fail),
        audit=SimpleNamespace(upload=_ret(None)),
        user=SimpleNamespace(id=uuid.uuid4(), subject="user:t"),
        is_system_admin=True, ctx={},
    )
    return pool


async def test_complete_upload_dispatch_matrix(monkeypatch: pytest.MonkeyPatch) -> None:
    """功能点1:octet-stream + .mov/.heic 盲区行按扩展名派发;.svg/.ts 不派发;
    content_type 前缀兜底;livp 优先并排派下载解包 job(§3.5)。"""
    cases: list[tuple[str, str | None, tuple[str, ...]]] = [
        ("clip.mov", OTS, ("generate_video_thumbnail",)),
        ("IMG_1.heic", OTS, ("generate_thumbnail",)),
        ("x.bin", "video/mp4", ("generate_video_thumbnail",)),
        ("x.bin", "image/png", ("generate_thumbnail",)),
        ("a.livp", OTS, ("generate_livp_thumbnail", "generate_livp_download")),
        ("logo.svg", "image/svg+xml", ()),
        ("logo.svg", OTS, ()),
        ("clip.ts", OTS, ()),
    ]
    for filename, ct, expected in cases:
        pool = await run_complete_upload(monkeypatch, filename, ct)
        # livp 分支两个 job 并排派发,先后顺序非契约
        assert sorted(j[0] for j in pool.jobs) == sorted(expected), \
            f"{filename}/{ct} → {[j[0] for j in pool.jobs]}"
        assert all(len(j) == 2 and j[1] for j in pool.jobs), "job 参数为 asset_id"


async def test_baidu_enqueue_thumbnail_matrix() -> None:
    """功能点1:baidu 导入派发点 _enqueue_thumbnail 与 complete_upload 同口径
    (§3.5);ctx_pool None → 直接返回不派发。"""
    pool = _Pool()
    cases: list[tuple[str, str | None, tuple[str, ...]]] = [
        ("clip.mov", OTS, ("generate_video_thumbnail",)),
        ("IMG_1.heic", OTS, ("generate_thumbnail",)),
        ("a.livp", OTS, ("generate_livp_thumbnail", "generate_livp_download")),
        ("logo.svg", "image/svg+xml", ()),
        ("clip.ts", OTS, ()),
    ]
    for filename, ct, expected in cases:
        pool.jobs.clear()
        await _enqueue_thumbnail(ctx_pool=pool, asset_id=uuid.uuid4(),
                                 filename=filename, content_type=ct)
        # livp 分支两个 job 并排派发,先后顺序非契约(实现先派下载解包)
        assert sorted(j[0] for j in pool.jobs) == sorted(expected), \
            f"{filename}/{ct} 派发不符"
    pool.jobs.clear()
    await _enqueue_thumbnail(ctx_pool=None, asset_id=uuid.uuid4(),
                             filename="clip.mov", content_type=OTS)
    assert pool.jobs == [], "pool 缺失时 fire-and-forget 直接跳过"

async def test_video_job_accepts_octet_stream_mp4_ext(monkeypatch: pytest.MonkeyPatch) -> None:
    """功能点2/5:非视频 content_type + .mp4 扩展名 → 不再 skip_non_video,URL
    主路径走通并产出 1024 产物;skip 标记随成功合并移除;small 派生接线。"""
    aid = uuid.uuid4()
    s3, merge, small = FakeS3(), TagRecorder(), SmallRecorder()
    patch_worker(monkeypatch, asset=mk_asset(id=aid, filename="v.mp4",
                                             minio_key="f/v.mp4"),
                 s3=s3, merge=merge, small=small)
    patch_url_extract_ok(monkeypatch)

    out = await generate_video_thumbnail({}, str(aid))

    assert out["status"] == "ok", f"octet-stream + .mp4 必须受纳: {out}"
    assert [c for c in s3.calls if c[0] == "presign"] == [
        ("presign", "get_object", {"Bucket": "ms-proj", "Key": "f/v.mp4"}, 600),
    ], "URL 主路径:主桶内部端点签 GET(ExpiresIn=600)"
    assert not [m for m in merge.merges if "thumbnail_skipped" in m["sets"]], \
        "受纳行不得写 skip 标记"
    final = merge.merges[-1]
    assert (final["sets"]["thumbnail_key"] == f"thumbnails/{aid}.jpg"
            and set(("thumbnail_failed", "thumbnail_skipped")) <= set(final["removes"])), \
        "1024 tags 落点 + skip/failed 标记随成功合并移除"
    assert s3.put_objects[0]["key"] == f"thumbnails/{aid}.jpg", "1024 主产物落缩略图桶"
    assert small.calls == [(str(aid), _TINY_JPEG)], "small 派生接线:1024 产物字节作源"


async def test_video_job_rejects_non_video_writes_skip_tag(monkeypatch: pytest.MonkeyPatch) -> None:
    """功能点2:非视频输入(text/plain + .txt)→ skip_non_video 且写
    thumbnail_skipped='non_video';不触 boto3、不派 small。"""
    aid = uuid.uuid4()
    s3, merge, small = FakeS3(), TagRecorder(), SmallRecorder()
    patch_worker(monkeypatch, asset=mk_asset(id=aid, filename="a.txt",
                                             content_type="text/plain"),
                 s3=s3, merge=merge, small=small)

    out = await generate_video_thumbnail({}, str(aid))

    assert out["status"] == "skip_non_video"
    assert merge.merges == [{"aid": aid, "sets": {"thumbnail_skipped": "non_video"},
                             "removes": ()}]
    assert s3.calls == [] and s3.put_objects == [] and small.calls == []


async def test_image_job_acceptance_ext_and_prefix(monkeypatch: pytest.MonkeyPatch) -> None:
    """功能点2/5:图片族 content_type 缺失 + .heic 扩展名 → 受纳并接线 small。"""
    aid = uuid.uuid4()
    s3, merge, small = FakeS3(), TagRecorder(), SmallRecorder()
    s3.objects["f/IMG_1.heic"] = _TINY_JPEG
    patch_worker(monkeypatch, asset=mk_asset(id=aid, filename="IMG_1.heic",
                                             content_type=None, minio_key="f/IMG_1.heic"),
                 s3=s3, merge=merge, small=small)

    out = await generate_thumbnail({}, str(aid))
    assert out["status"] == "ok", f"None content_type + .heic 必须受纳: {out}"
    assert merge.merges[-1]["sets"]["thumbnail_key"] == f"thumbnails/{aid}.jpg"
    assert small.calls and small.calls[0][0] == str(aid), "small 派生以 1024 字节为源"

async def test_video_over_8gb_skip_too_large(monkeypatch: pytest.MonkeyPatch) -> None:
    """功能点3:size > 8GB → skip + thumbnail_skipped='too_large',不签 URL 不拉流。"""
    aid = uuid.uuid4()
    cap = thumb_exts.VIDEO_THUMB_ABSOLUTE_MAX_BYTES
    s3, merge, small = FakeS3(), TagRecorder(), SmallRecorder()
    patch_worker(monkeypatch, asset=mk_asset(id=aid, size_bytes=cap + 1),
                 s3=s3, merge=merge, small=small)

    out = await generate_video_thumbnail({}, str(aid))

    assert out["status"] == "skip_too_large" and out["cap"] == cap
    assert merge.merges == [{"aid": aid, "sets": {"thumbnail_skipped": "too_large"},
                             "removes": ()}]
    assert s3.calls == [] and small.calls == []


async def test_video_at_8gb_boundary_proceeds(monkeypatch: pytest.MonkeyPatch) -> None:
    """功能点3:恰 8GB(≤ 边界)不 skip,正常走主路径(D4:防御值只防病态对象)。"""
    aid = uuid.uuid4()
    s3, merge, small = FakeS3(), TagRecorder(), SmallRecorder()
    patch_worker(monkeypatch, asset=mk_asset(
        id=aid, size_bytes=thumb_exts.VIDEO_THUMB_ABSOLUTE_MAX_BYTES),
        s3=s3, merge=merge, small=small)
    patch_url_extract_ok(monkeypatch)

    out = await generate_video_thumbnail({}, str(aid))
    assert out["status"] == "ok", out
    assert not [m for m in merge.merges if "thumbnail_skipped" in m["sets"]]


async def test_livp_over_200mb_too_large(monkeypatch: pytest.MonkeyPatch) -> None:
    """功能点3:livp > 200MB → skip_too_large + 'too_large'(原静默口子补标记)。"""
    aid = uuid.uuid4()
    s3, merge, small = FakeS3(), TagRecorder(), SmallRecorder()
    patch_worker(monkeypatch,
                 asset=mk_asset(id=aid, filename="big.livp", size_bytes=200 * 1024**2 + 1),
                 s3=s3, merge=merge, small=small)

    out = await generate_livp_thumbnail({}, str(aid))
    assert out["status"] == "skip_too_large" and out["size_bytes"] == 200 * 1024**2 + 1
    assert merge.merges == [{"aid": aid, "sets": {"thumbnail_skipped": "too_large"},
                             "removes": ()}]
    assert s3.calls == [] and small.calls == []

def _livp_zip_bytes() -> bytes:
    """最小 livp(iOS Live Photo = zip):仅含静态图条目(无实况,免 ffmpeg)。"""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("IMG_0001.JPG.jpeg", _TINY_JPEG)
    return buf.getvalue()


async def test_livp_job_success_derives_small(monkeypatch: pytest.MonkeyPatch) -> None:
    """功能点5:livp 族成功 → 静态图 1024 产物 + tags + small 派生接线(无实况)。"""
    aid = uuid.uuid4()
    s3, merge, small = FakeS3(), TagRecorder(), SmallRecorder()
    s3.objects["f/a.livp"] = _livp_zip_bytes()
    patch_worker(monkeypatch, asset=mk_asset(id=aid, filename="a.livp",
                                             size_bytes=1024, minio_key="f/a.livp"),
                 s3=s3, merge=merge, small=small)

    out = await generate_livp_thumbnail({}, str(aid))

    assert out["status"] == "ok" and out["live_video"] is False
    assert s3.put_objects[0]["key"] == f"thumbnails/{aid}.jpg"
    assert merge.merges[-1]["sets"]["thumbnail_key"] == f"thumbnails/{aid}.jpg"
    assert small.calls == [(str(aid), s3.put_objects[0]["body"])], \
        "small 源 = 静态图 1024 产物字节"


async def test_small_derive_failure_isolated_from_main_tags(monkeypatch: pytest.MonkeyPatch) -> None:
    """功能点5:small 段抛异常 → 仅隔离,1024 主产物 tags(thumbnail_key)照常
    落,job 仍 ok(失败行由回补 --mode derive-small 兜底)。"""
    aid = uuid.uuid4()
    s3, merge = FakeS3(), TagRecorder()
    small = SmallRecorder(error=RuntimeError("boom"))
    s3.objects["f/a.png"] = _TINY_JPEG
    patch_worker(monkeypatch, asset=mk_asset(id=aid, filename="a.png",
                                             content_type="image/png", minio_key="f/a.png"),
                 s3=s3, merge=merge, small=small)

    out = await generate_thumbnail({}, str(aid))

    assert out["status"] == "ok", "small 段异常不得影响主链路结果"
    assert small.calls, "small 派生确被调用过"
    key_merge = [m for m in merge.merges if "thumbnail_key" in m["sets"]]
    assert key_merge and key_merge[0]["sets"]["thumbnail_key"] == f"thumbnails/{aid}.jpg", \
        "1024 主产物 tags 必须已落"

def test_worker_settings_registration() -> None:
    """功能点6:WorkerSettings.functions 注册 derive_small_thumbnail(timeout=60/
    max_tries=1);视频 timeout=360;三族 max_tries=1(§3.4)。"""
    fns = {f.name: f for f in WorkerSettings.functions if getattr(f, "name", None)}
    f = fns.get("derive_small_thumbnail")
    assert f is not None and f.timeout_s == 60 and f.max_tries == 1, \
        "漏注册/timeout=60/max_tries=1(漏注册 = arq 出队即 JobExecutionFailed)"
    assert fns["generate_video_thumbnail"].timeout_s == 360
    for n in ("generate_thumbnail", "generate_video_thumbnail", "generate_livp_thumbnail"):
        assert fns[n].max_tries == 1, f"{n} 必须 max_tries=1"


async def test_derive_and_put_small_real_path(monkeypatch: pytest.MonkeyPatch) -> None:
    """功能点6:derive_and_put_small 真产物 — Pillow thumbnail(240) LANCZOS →
    put {id}_s.jpg(image/jpeg)+ merge tags(small key + 小图字节数)。"""
    aid = uuid.uuid4()
    merge, s3 = TagRecorder(), FakeS3()
    monkeypatch.setattr(wmain, "_merge_asset_tags", merge)
    monkeypatch.setattr(wmain, "_thumb_s3_client", lambda settings: s3)
    monkeypatch.setattr(thumb_variants, "get_sessionmaker", lambda: None)

    small_key = await derive_and_put_small(str(aid), _TINY_JPEG)

    assert small_key == f"thumbnails/{aid}_s.jpg"
    put = s3.put_objects[0]
    assert put["key"] == small_key and put["ContentType"] == "image/jpeg"
    img = Image.open(io.BytesIO(put["body"]))
    assert max(img.size) <= thumb_exts.THUMB_SMALL_MAX_PX, "small 规格封顶 240px"
    assert merge.merges == [{
        "aid": aid,
        "sets": {"thumbnail_small_key": small_key,
                 "thumbnail_small_size_bytes": len(put["body"])},
        "removes": (),
    }]


async def test_derive_small_thumbnail_source_missing(monkeypatch: pytest.MonkeyPatch) -> None:
    """功能点6:源 1024 缺失(NoSuchKey)→ {"status": "source_missing"},不派生
    不写失败 tag(下次回补自然重试)。"""
    aid = uuid.uuid4()
    s3 = FakeS3()

    def _raise(bucket: str, key: str, buf: Any) -> None:
        raise ClientError({"Error": {"Code": "NoSuchKey", "Message": "gone"}}, "GetObject")

    s3.download_fileobj = _raise  # type: ignore[method-assign]
    small = SmallRecorder()
    monkeypatch.setattr(wmain, "_thumb_s3_client", lambda settings: s3)
    monkeypatch.setattr(thumb_variants, "get_sessionmaker", lambda: None)
    monkeypatch.setattr(thumb_variants, "derive_and_put_small", small)

    assert await derive_small_thumbnail({}, str(aid)) == {
        "status": "source_missing", "asset_id": str(aid)}
    assert small.calls == [], "源缺失不得进入派生"


async def test_derive_small_thumbnail_normal(monkeypatch: pytest.MonkeyPatch) -> None:
    """功能点6:正常路径 — 读缩略图桶 1024 产物 → 派生 small → put + merge tags。"""
    aid = uuid.uuid4()
    s3 = FakeS3()
    s3.objects[f"thumbnails/{aid}.jpg"] = _TINY_JPEG

    def _dl(bucket: str, key: str, buf: Any) -> None:
        buf.write(s3.objects[key])

    s3.download_fileobj = _dl  # type: ignore[method-assign]
    small_key = f"thumbnails/{aid}_s.jpg"
    small = SmallRecorder()
    monkeypatch.setattr(wmain, "_thumb_s3_client", lambda settings: s3)
    monkeypatch.setattr(thumb_variants, "get_sessionmaker", lambda: None)
    monkeypatch.setattr(thumb_variants, "derive_and_put_small", small)

    out = await derive_small_thumbnail({}, str(aid))

    assert out == {"status": "ok", "asset_id": str(aid), "thumbnail_small_key": small_key}
    assert small.calls == [(str(aid), _TINY_JPEG)], "以缩略图桶 1024 产物为派生源"
