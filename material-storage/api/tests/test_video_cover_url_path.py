"""视频封面 URL 直读主路径(功能点4)+ purge 派生对象清理(功能点9)— 契约测试。

需求依据:docs/qdev/2026-10-27-thumb-variant-video-cover.md §6.4 / §6.9。
设施沿用仓库 stub 惯例(monkeypatch subprocess.run / boto3 / get_sessionmaker /
get_settings / _merge_asset_tags;不连真 ffmpeg / MinIO / DB / Redis)。
功能点9(thumbnail_small_key 随 purge 清理)与 small 变体方案配套,随本文件交付。

测试 → 功能点4 映射(§6.4):
  ① ffmpeg 命令逐字契约(-y / -ss 1 / -i <url> / scale=1024:-2 / -f image2)
                                   → test_url_extract_cmd_contains_contract_params
  ② -ss 1 失败后恰一次 -ss 0 重试  → test_url_extract_ss1_failure_retries_ss0
  ③ 两次都失败返回 False           → test_url_extract_both_attempts_fail_returns_false
  ④ URL 主路径段异常(presign 抛错 / ffmpeg TimeoutExpired)→ 回落旧头部路径
     (get_object Range 被调)而非直接 thumbnail_failed
                                   → test_url_path_presign_error_falls_back_to_head_path
                                   → test_url_path_ffmpeg_timeout_falls_back_to_head_path
  ⑤ 失败路径 tags 不含 presigned URL(thumbnail_failed 只存异常类型名 /
     "ffmpeg_timeout" 字面量)
                                   → test_failure_tags_store_only_exception_type_no_url
                                   → test_ffmpeg_timeout_tags_literal_no_url

测试 → 功能点9 映射(§6.9):
  tags 含 thumbnail_key + thumbnail_small_key → purge 缩略图桶通道删两个变体对象
                                   → test_purge_removes_large_and_small_thumbnail_variants
"""
from __future__ import annotations

import io
import os
import pathlib
import subprocess
import uuid
from types import SimpleNamespace
from typing import Any

# 环境桩:import app.workers.main 在 WorkerSettings 类体定义期即调 get_settings
for _k, _v in {
    "DB_URL": "postgresql+asyncpg://u:p@localhost/db",
    "REDIS_URL": "redis://localhost:6379/0",
    "MINIO_ENDPOINT_INTERNAL": "http://minio:9000",
    "MINIO_ENDPOINT_PUBLIC": "http://localhost:9000",
    "MINIO_ACCESS_KEY": "k", "MINIO_SECRET_KEY": "s",
    "OPENFGA_API_URL": "http://openfga:8080", "OPENFGA_STORE_ID": "01TEST",
    "WEB_APP_BASE_URL": "http://localhost/ms-static/web/",
    "SESSION_JWT_SECRET": "test-secret-0123456789abcdef",
}.items():
    os.environ.setdefault(_k, _v)

import pytest  # noqa: E402
from PIL import Image  # noqa: E402

import app.workers.main as wmain  # noqa: E402
from app.services.asset_cleanup import purge_asset_storage  # noqa: E402
from app.settings import Settings  # noqa: E402
from app.workers import thumb_variants  # noqa: E402
from app.workers.main import generate_video_thumbnail  # noqa: E402

URL = "http://minio-internal/fake-object?X-Amz-Signature=SECRET"   # 假 presigned URL


def _tiny_jpeg() -> bytes:
    img, buf = Image.new("RGB", (64, 32), (200, 10, 10)), io.BytesIO()
    img.save(buf, format="JPEG")
    return buf.getvalue()


_TINY_JPEG = _tiny_jpeg()


def mk_settings() -> Settings:
    # minio/openfga/redis 等由本模块顶部环境桩提供
    return Settings(env="test", session_jwt_secret="test-secret",
                    db_url="postgresql+asyncpg://u:p@localhost/db")


def mk_asset(**over: Any) -> SimpleNamespace:
    base: dict[str, Any] = dict(id=uuid.uuid4(), deleted_at=None, filename="v.mp4",
                                content_type="application/octet-stream", size_bytes=1024,
                                minio_bucket="ms-proj", minio_key="f/v.mp4", tags={})
    base.update(over)
    return SimpleNamespace(**base)


class _Body:
    """get_object resp["Body"] 替身:iter_chunks 单块。"""

    def __init__(self, data: bytes) -> None:
        self._data = data

    def iter_chunks(self, chunk_size: int) -> Any:
        yield self._data


class FakeS3:
    """boto3 client 替身:记录调用序列(presign / get_object / put_object)。"""

    def __init__(self, *, presign_error: BaseException | None = None) -> None:
        self.calls: list[tuple[Any, ...]] = []
        self.put_objects: list[dict[str, Any]] = []
        self._presign_error = presign_error

    def head_bucket(self, *a: Any, **kw: Any) -> dict:
        return {}

    def generate_presigned_url(self, operation: str, Params: Any = None,
                               ExpiresIn: int | None = None) -> str:
        self.calls.append(("presign", operation, dict(Params or {}), ExpiresIn))
        if self._presign_error is not None:
            raise self._presign_error
        return URL

    def get_object(self, Bucket: str | None = None, Key: str | None = None,
                   Range: str | None = None) -> dict:
        self.calls.append(("get_object", Bucket, Key, Range))
        return {"Body": _Body(b"\x00" * 16)}

    def download_file(self, bucket: str, key: str, path: Any) -> None:
        self.calls.append(("download_file", bucket, key, str(path)))
        pathlib.Path(path).write_bytes(b"\x00" * 16)

    def put_object(self, Bucket: str | None = None, Key: str | None = None,
                   Body: Any = None, **kw: Any) -> dict:
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

    async def __call__(self, sm: Any, aid: Any, sets: Any = None,
                       removes: tuple[str, ...] = ()) -> None:
        self.merges.append({"aid": aid, "sets": dict(sets or {}), "removes": tuple(removes)})


class SmallRecorder:
    """derive_and_put_small 替身:记录接线,不真派生。"""

    def __init__(self) -> None:
        self.calls: list[tuple[str, bytes]] = []

    async def __call__(self, asset_id: str, source: bytes) -> str:
        self.calls.append((asset_id, source))
        return f"thumbnails/{asset_id}_s.jpg"


def patch_video_job(monkeypatch: pytest.MonkeyPatch, *, asset: Any, s3: FakeS3,
                    merge: TagRecorder, small: SmallRecorder,
                    url_extract: Any = None, head_extract: Any = None) -> None:
    """对 app.workers.main 模块属性打桩(test_batch_download_link 同款)。"""
    monkeypatch.setattr(wmain, "boto3", SimpleNamespace(client=lambda *a, **k: s3))
    monkeypatch.setattr(wmain, "get_sessionmaker", lambda: FakeSM(asset))
    monkeypatch.setattr(wmain, "get_settings", lambda: mk_settings())
    monkeypatch.setattr(wmain, "_merge_asset_tags", merge)
    monkeypatch.setattr(thumb_variants, "derive_and_put_small", small)
    if url_extract is not None:
        monkeypatch.setattr(wmain, "_extract_video_frame_from_url", url_extract)
    if head_extract is not None:
        monkeypatch.setattr(wmain, "_extract_video_frame", head_extract)


def ok_head_extract(recorder: list[str]) -> Any:
    """头部路径抽帧替身:写 out.jpg 并成功(subprocess 不真跑)。"""
    def _extract(in_path: Any, out_path: Any, timeout: int) -> bool:
        recorder.append("head")
        out_path.write_bytes(_TINY_JPEG)
        return True

    return _extract


# ─── 功能点4 ①②③:命令契约 / -ss 0 重试 / 双败返 False ─────────────────────
def _patch_subprocess_run(monkeypatch: pytest.MonkeyPatch,
                          results: list[tuple[int, bool]]) -> list[dict[str, Any]]:
    """subprocess.run 替身:按调用序回放 (returncode, 是否写产物),捕获 cmd。"""
    calls: list[dict[str, Any]] = []

    def fake_run(cmd: list[str], capture_output: bool = False,
                 timeout: int | None = None) -> Any:
        calls.append({"cmd": list(cmd), "capture_output": capture_output, "timeout": timeout})
        rc, write = results[min(len(calls) - 1, len(results) - 1)]
        if write:
            pathlib.Path(cmd[-1]).write_bytes(_TINY_JPEG)
        return SimpleNamespace(returncode=rc)

    monkeypatch.setattr(subprocess, "run", fake_run)
    return calls


def test_url_extract_cmd_contains_contract_params(monkeypatch: pytest.MonkeyPatch,
                                                  tmp_path: pathlib.Path) -> None:
    """功能点4①:命令逐字含 -y / -ss 1 / -i <url> / -frames:v 1 / scale=1024:-2 /
    -q:v 3 / -f image2,capture_output+timeout 透传;-ss 1 成功只调一次。"""
    calls = _patch_subprocess_run(monkeypatch, results=[(0, True)])
    out = tmp_path / "out.jpg"

    ok = wmain._extract_video_frame_from_url(URL, out, 60)

    assert ok is True and len(calls) == 1
    cmd = calls[0]["cmd"]
    assert cmd[:4] == ["ffmpeg", "-hide_banner", "-loglevel", "error"]
    assert cmd[4] == "-y" and cmd[5:7] == ["-ss", "1"] and cmd[7] == "-i" and cmd[8] == URL
    assert cmd[cmd.index("-frames:v") + 1] == "1"
    assert cmd[cmd.index("-vf") + 1] == "scale=1024:-2"
    assert cmd[cmd.index("-q:v") + 1] == "3"
    assert cmd[cmd.index("-f") + 1] == "image2" and cmd[-1] == str(out)
    assert calls[0]["capture_output"] is True and calls[0]["timeout"] == 60


def test_url_extract_ss1_failure_retries_ss0(monkeypatch: pytest.MonkeyPatch,
                                             tmp_path: pathlib.Path) -> None:
    """功能点4②:-ss 1 非零退出(无产物)→ 恰一次 -ss 0 重试,成功返 True。"""
    calls = _patch_subprocess_run(monkeypatch, results=[(1, False), (0, True)])

    ok = wmain._extract_video_frame_from_url(URL, tmp_path / "out.jpg", 60)

    assert ok is True and len(calls) == 2, "-ss 1 失败后恰一次 -ss 0 重试"
    assert [c["cmd"][c["cmd"].index("-ss") + 1] for c in calls] == ["1", "0"]


def test_url_extract_both_attempts_fail_returns_false(monkeypatch: pytest.MonkeyPatch,
                                                      tmp_path: pathlib.Path) -> None:
    """功能点4③:-ss 1 与 -ss 0 都失败 → 返回 False,不再有第三次尝试。"""
    calls = _patch_subprocess_run(monkeypatch, results=[(1, False), (1, False)])

    ok = wmain._extract_video_frame_from_url(URL, tmp_path / "out.jpg", 60)

    assert ok is False and len(calls) == 2


# ─── 功能点4 ④:URL 主路径段异常 → 回落旧头部路径 ────────────────────────────
async def test_url_path_presign_error_falls_back_to_head_path(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """功能点4④:presign 抛错 → 回落 get_object Range(头部 10MB)→ 头部抽帧成功
    → 1024 产物照常落,状态 ok 而非 thumbnail_failed。"""
    aid = uuid.uuid4()
    s3, merge, small = FakeS3(presign_error=RuntimeError("presign boom")), TagRecorder(), SmallRecorder()
    url_calls: list[str] = []
    head_calls: list[str] = []
    patch_video_job(monkeypatch, asset=mk_asset(id=aid), s3=s3, merge=merge, small=small,
                    url_extract=lambda url, out_path, timeout: url_calls.append(url) or False,
                    head_extract=ok_head_extract(head_calls))

    out = await generate_video_thumbnail({}, str(aid))

    assert out["status"] == "ok", f"URL 段异常必须回落而非直接 failed: {out}"
    assert url_calls == [], "presign 已抛错,不应进入 URL 抽帧"
    assert [c[0] for c in s3.calls] == ["presign", "get_object"], "调用序列:presign 败 → 回落头部"
    assert s3.calls[1] == ("get_object", "ms-proj", "f/v.mp4",
                           f"bytes=0-{wmain._VIDEO_HEAD_RANGE - 1}"), "头部 10MB Range 语义"
    assert head_calls == ["head"] and s3.put_objects[0]["key"] == f"thumbnails/{aid}.jpg"
    assert merge.merges[-1]["sets"]["thumbnail_key"] == f"thumbnails/{aid}.jpg"
    assert not [m for m in merge.merges if "thumbnail_failed" in m["sets"]]
    assert small.calls, "成功路径仍接线 small 派生"


async def test_url_path_ffmpeg_timeout_falls_back_to_head_path(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """功能点4④:URL 抽帧抛 subprocess.TimeoutExpired → 同样回落头部路径成功。"""
    aid = uuid.uuid4()
    s3, merge, small = FakeS3(), TagRecorder(), SmallRecorder()
    head_calls: list[str] = []

    def _url_timeout(url: str, out_path: Any, timeout: int) -> bool:
        raise subprocess.TimeoutExpired(cmd="ffmpeg", timeout=timeout)

    patch_video_job(monkeypatch, asset=mk_asset(id=aid), s3=s3, merge=merge, small=small,
                    url_extract=_url_timeout, head_extract=ok_head_extract(head_calls))

    out = await generate_video_thumbnail({}, str(aid))

    assert out["status"] == "ok", f"TimeoutExpired 属 URL 段异常,必须回落: {out}"
    assert [c[0] for c in s3.calls] == ["presign", "get_object"]
    assert s3.calls[1][3] == f"bytes=0-{wmain._VIDEO_HEAD_RANGE - 1}"
    assert head_calls == ["head"], "回落链头部抽帧恰一次"
    assert merge.merges[-1]["sets"]["thumbnail_key"] == f"thumbnails/{aid}.jpg"


# ─── 功能点4 ⑤:失败路径日志卫生(tags 不含 presigned URL)────────────────────
async def test_failure_tags_store_only_exception_type_no_url(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """功能点4⑤:URL 段 False + 头部抽帧失败 + >50MB(跳全量)→ RuntimeError →
    tags['thumbnail_failed'] 只存异常类型名,任何 tags/返回值不含 presigned URL。"""
    aid = uuid.uuid4()
    s3, merge, small = FakeS3(), TagRecorder(), SmallRecorder()
    patch_video_job(monkeypatch, asset=mk_asset(id=aid, size_bytes=60 * 1024 * 1024),
                    s3=s3, merge=merge, small=small,
                    url_extract=lambda url, out_path, timeout: False,
                    head_extract=lambda in_path, out_path, timeout: False)

    out = await generate_video_thumbnail({}, str(aid))

    assert out["status"] == "failed" and s3.put_objects == [] and small.calls == []
    assert merge.merges == [{"aid": aid, "sets": {"thumbnail_failed": "RuntimeError"},
                             "removes": ()}], "thumbnail_failed 只存异常类型名"
    blob = repr(merge.merges) + repr(out)
    assert "X-Amz-Signature" not in blob and "minio-internal" not in blob, \
        "失败路径任何 tags/返回值不得携带 presigned URL"


async def test_ffmpeg_timeout_tags_literal_no_url(monkeypatch: pytest.MonkeyPatch) -> None:
    """功能点4⑤:URL 段 TimeoutExpired + 头部抽帧也 TimeoutExpired → 外层
    subprocess.TimeoutExpired 分支,tags['thumbnail_failed']='ffmpeg_timeout'。"""
    aid = uuid.uuid4()
    s3, merge, small = FakeS3(), TagRecorder(), SmallRecorder()

    def _timeout(*a: Any) -> bool:
        raise subprocess.TimeoutExpired(cmd="ffmpeg", timeout=30)

    patch_video_job(monkeypatch, asset=mk_asset(id=aid), s3=s3, merge=merge, small=small,
                    url_extract=_timeout, head_extract=_timeout)

    out = await generate_video_thumbnail({}, str(aid))

    assert out == {"status": "failed", "asset_id": str(aid), "error": "ffmpeg_timeout"}
    assert merge.merges == [{"aid": aid, "sets": {"thumbnail_failed": "ffmpeg_timeout"},
                             "removes": ()}]
    assert "X-Amz-Signature" not in repr(merge.merges) + repr(out), "URL 不进 tags/返回值"
    assert s3.put_objects == [] and small.calls == []


# ─── 功能点9:purge 清理 thumbnail_small_key(§6.9)───────────────────────────
class _PurgePresign:
    """PresignService 替身:只实现 purge 用到的两个删除通道,记录调用。"""

    def __init__(self) -> None:
        self.main_deletes: list[tuple[str, str]] = []
        self.thumb_deletes: list[str] = []

    def delete_object(self, bucket: str, key: str) -> None:
        self.main_deletes.append((bucket, key))

    def delete_thumbnail_object(self, key: str) -> None:
        self.thumb_deletes.append(key)


def test_purge_removes_large_and_small_thumbnail_variants() -> None:
    """功能点9:tags 含 thumbnail_key + thumbnail_small_key → purge 在缩略图桶
    通道删除两个变体对象;主桶只删原对象;无 small key 的旧行只删 1024 一个;
    单项失败只 log 不阻断其余清理(孤儿无害语义)。"""
    svc = _PurgePresign()
    purge_asset_storage(svc, "ms-proj", "f/a.mov",
                        {"thumbnail_key": "thumbnails/a.jpg",
                         "thumbnail_small_key": "thumbnails/a_s.jpg",
                         "thumbnail_small_size_bytes": 1234})
    assert svc.thumb_deletes == ["thumbnails/a.jpg", "thumbnails/a_s.jpg"], \
        "1024 与 small 两个变体对象均被删"
    assert svc.main_deletes == [("ms-proj", "f/a.mov")], "主桶通道只删原对象"

    svc2 = _PurgePresign()
    purge_asset_storage(svc2, "ms-proj", "f/b.mov", {"thumbnail_key": "thumbnails/b.jpg"})
    assert svc2.thumb_deletes == ["thumbnails/b.jpg"], "无 small key 旧行只删 1024"

    svc3 = _PurgePresign()
    attempted: list[str] = []

    def _boom(key: str) -> None:
        attempted.append(key)
        if key == "thumbnails/c.jpg":
            raise RuntimeError("minio down")

    svc3.delete_thumbnail_object = _boom  # type: ignore[method-assign]
    purge_asset_storage(svc3, "ms-proj", "f/c.mov",
                        {"thumbnail_key": "thumbnails/c.jpg",
                         "thumbnail_small_key": "thumbnails/c_s.jpg"})
    assert attempted == ["thumbnails/c.jpg", "thumbnails/c_s.jpg"], \
        "单项失败只 log 不阻断,small 变体仍被尝试清理"
