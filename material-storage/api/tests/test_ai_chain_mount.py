"""缩略图成功收尾 → AI 链式挂载(annotate/slice)契约测试。

需求依据:docs/qdev/2026-11-03-ai-tagging-slicing.md §1 功能点 5(链式挂载)/
rushes-spec/material-storage/ai-tagging-slicing-plan.md §8.1。设施沿用
test_thumb_dispatch_and_variants 的 stub 惯例(按模块属性打桩 boto3/
get_sessionmaker/get_settings/_merge_asset_tags;ensure_ai_job / enqueue 用
recorder 替身;不连真 DB / MinIO / Redis / arq / ffmpeg)。⚠ import app.workers.main
在 WorkerSettings 类体定义期即调 get_settings,无 conftest 注入点 —— 顶部设环境桩。
测试 ↔ 断言映射(docstring 编号):
  1=三族成功点各触发一次(ai_enabled on,行先行 + ai 队列派发参数);
  2=off 零调用(急停语义);3=failed/skip 路径不触发;4=链式异常隔离(主链路
  返回值不受影响);5=挂载点纪律(三族各恰一处,漏一处 = 该族永不打标)。
"""
from __future__ import annotations

import inspect
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

import app.services.ai_jobs as ai_jobs_mod  # noqa: E402
import app.workers.main as wmain  # noqa: E402
from app.services.ai_pipeline import write_model_version  # noqa: E402
from app.settings import Settings  # noqa: E402
from app.workers.main import (  # noqa: E402
    generate_livp_thumbnail,
    generate_thumbnail,
    generate_video_thumbnail,
)
from tests.test_thumb_dispatch_and_variants import (  # noqa: E402  纯 helper 复用(仓库惯例)
    _TINY_JPEG,
    FakeS3,
    SmallRecorder,
    TagRecorder,
    mk_asset,
    patch_url_extract_ok,
    patch_worker,
)


def mk_ai_settings(ai_enabled: bool) -> Settings:
    # minio/openfga/redis 等由本模块顶部环境桩提供
    return Settings(env="test", session_jwt_secret="test-secret",
                    db_url="postgresql+asyncpg://u:p@localhost/db",
                    ai_enabled=ai_enabled)


def _expected_mv() -> str:
    """链式写入版本 = write_model_version(与 pipeline 认领 / sweeper 重派同源)。"""
    return write_model_version(mk_ai_settings(True))


def _still_only_livp() -> bytes:
    """仅含静态图条目的最小 livp(免 ffmpeg)。"""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("IMG_0001.JPG.jpeg", _TINY_JPEG)
    return buf.getvalue()


def _livp_with_video_bytes() -> bytes:
    """含静态图 + 实况条目的 livp(视频字节任意 —— 转码被 stub,不触 ffmpeg)。"""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("IMG_0001.JPG.jpeg", _TINY_JPEG)
        zf.writestr("IMG_0001.mov", b"\x00" * 64)
    return buf.getvalue()


class EnsureRecorder:
    """ai_jobs.ensure_ai_job 替身:记录 (sm, asset_id, kind, model_version);
    可注入异常(隔离用例)/ 共享事件序表(挂载先于转码用例)。"""

    def __init__(self, error: BaseException | None = None,
                 events: list[str] | None = None) -> None:
        self.calls: list[tuple[Any, str, str, str]] = []
        self._error = error
        self._events = events

    async def __call__(self, sm: Any, asset_id: Any, kind: str, model_version: str) -> bool:
        self.calls.append((sm, str(asset_id), kind, model_version))
        if self._events is not None:
            self._events.append("ensure")
        if self._error is not None:
            raise self._error
        return True


class ChainPool:
    """ctx["redis"](ArqRedis)替身:记录 enqueue_job(name, args, kwargs);可注入异常。"""

    def __init__(self, error: BaseException | None = None) -> None:
        self.jobs: list[tuple[str, tuple[Any, ...], dict[str, Any]]] = []
        self._error = error

    async def enqueue_job(self, name: str, *args: Any, **kw: Any) -> Any:
        self.jobs.append((name, args, kw))
        if self._error is not None:
            raise self._error
        return SimpleNamespace(name=name)


def patch_chain(monkeypatch: pytest.MonkeyPatch, *, asset: Any, s3: FakeS3,
                merge: TagRecorder, ai_enabled: bool, ensure: EnsureRecorder,
                pool: ChainPool | None) -> dict[str, Any]:
    """三族 job 依赖全 stub(patch_worker 同款)+ AI 链 recorder 打桩;返回 ctx
    (pool None → ctx 无 redis 键,行先行语义下派发缺口留给 sweeper)。"""
    patch_worker(monkeypatch, asset=asset, s3=s3, merge=merge, small=SmallRecorder())
    monkeypatch.setattr(wmain, "get_settings", lambda: mk_ai_settings(ai_enabled))
    monkeypatch.setattr(ai_jobs_mod, "ensure_ai_job", ensure)
    return {"redis": pool} if pool is not None else {}


def _assert_chained(pool: ChainPool, ensure: EnsureRecorder, aid: uuid.UUID,
                    kind: str) -> None:
    """断言:恰一次行写入(annotate/slice,写入版本)+ 恰一次 ai 队列派发
    (确定性 _job_id + _expires 按类 1800/86400 + _queue_name="ai")。"""
    mv = _expected_mv()
    fn, expires = (("ai_annotate_asset", 1800) if kind == "annotate"
                   else ("ai_slice_video", 86400))
    assert [(c[1], c[2], c[3]) for c in ensure.calls] == [(str(aid), kind, mv)], \
        f"行先行恰一次({kind}):{ensure.calls}"
    assert len(pool.jobs) == 1, f"派发恰一次:{pool.jobs}"
    name, args, kw = pool.jobs[0]
    assert name == fn and args == (str(aid),), f"job 名/参数不符:{pool.jobs}"
    assert kw == {"_job_id": f"ai:{kind}:{aid}@{mv}", "_expires": expires,
                  "_queue_name": "ai"}, f"派发参数不符(arq_pool.enqueue_ai_* 同款):{kw}"


# ─── 三族成功路径驱动(ai on/off 共用)────────────────────────────────────────


async def _run_image_success(monkeypatch: pytest.MonkeyPatch, *, ai_enabled: bool,
                             ensure: EnsureRecorder, pool: ChainPool | None,
                             ) -> tuple[dict[str, Any], TagRecorder, uuid.UUID]:
    aid = uuid.uuid4()
    s3, merge = FakeS3(), TagRecorder()
    s3.objects["f/IMG_1.heic"] = _TINY_JPEG
    ctx = patch_chain(monkeypatch, asset=mk_asset(id=aid, filename="IMG_1.heic",
                                                  content_type=None,
                                                  minio_key="f/IMG_1.heic"),
                      s3=s3, merge=merge, ai_enabled=ai_enabled,
                      ensure=ensure, pool=pool)
    out = await generate_thumbnail(ctx, str(aid))
    return out, merge, aid


async def _run_livp_success(monkeypatch: pytest.MonkeyPatch, *, ai_enabled: bool,
                            ensure: EnsureRecorder, pool: ChainPool | None,
                            zip_bytes: bytes,
                            ) -> tuple[dict[str, Any], TagRecorder, uuid.UUID]:
    aid = uuid.uuid4()
    s3, merge = FakeS3(), TagRecorder()
    s3.objects["f/a.livp"] = zip_bytes
    ctx = patch_chain(monkeypatch, asset=mk_asset(id=aid, filename="a.livp",
                                                  minio_key="f/a.livp"),
                      s3=s3, merge=merge, ai_enabled=ai_enabled,
                      ensure=ensure, pool=pool)
    out = await generate_livp_thumbnail(ctx, str(aid))
    return out, merge, aid


async def _run_video_success(monkeypatch: pytest.MonkeyPatch, *, ai_enabled: bool,
                             ensure: EnsureRecorder, pool: ChainPool | None,
                             ) -> tuple[dict[str, Any], TagRecorder, uuid.UUID]:
    aid = uuid.uuid4()
    s3, merge = FakeS3(), TagRecorder()
    ctx = patch_chain(monkeypatch, asset=mk_asset(id=aid), s3=s3, merge=merge,
                      ai_enabled=ai_enabled, ensure=ensure, pool=pool)
    patch_url_extract_ok(monkeypatch)
    out = await generate_video_thumbnail(ctx, str(aid))
    return out, merge, aid


# ─── 断言 1:三族成功点各触发一次(ai_enabled on)──────────────────────────────


async def test_image_success_chains_annotate(monkeypatch: pytest.MonkeyPatch) -> None:
    """断言1(图片族):ai on + 成功 → 行先行(annotate)+ ai 队列派发恰一次,
    参数与 arq_pool.enqueue_ai_annotate 同款;主链路 tags 照常落。"""
    ensure, pool = EnsureRecorder(), ChainPool()
    out, merge, aid = await _run_image_success(monkeypatch, ai_enabled=True,
                                               ensure=ensure, pool=pool)

    assert out["status"] == "ok", out
    assert merge.merges[-1]["sets"]["thumbnail_key"] == f"thumbnails/{aid}.jpg", \
        "主链路 thumbnail_key tags 不受链式挂载影响"
    _assert_chained(pool, ensure, aid, "annotate")


async def test_livp_static_chains_annotate_before_transcode(
        monkeypatch: pytest.MonkeyPatch) -> None:
    """断言1(livp 族):静态图落库即触发 annotate —— 挂载点在实况短片转码之前
    (events 序:ensure 先于 transcode),转码失败(live 跳过)不影响链式派发。"""
    events: list[str] = []
    ensure = EnsureRecorder(events=events)
    pool = ChainPool()

    def _transcode_fail(*a: Any, **k: Any) -> bool:   # 真函数是同步(线程池内调用)
        events.append("transcode")
        return False

    monkeypatch.setattr(wmain, "_transcode_live_video", _transcode_fail)
    out, merge, aid = await _run_livp_success(monkeypatch, ai_enabled=True,
                                              ensure=ensure, pool=pool,
                                              zip_bytes=_livp_with_video_bytes())

    assert out["status"] == "ok", out
    assert merge.merges[-1]["sets"]["thumbnail_key"] == f"thumbnails/{aid}.jpg"
    assert events == ["ensure", "transcode"], \
        f"静态图落库即挂载(先于实况转码):{events}"
    _assert_chained(pool, ensure, aid, "annotate")


async def test_video_success_chains_slice(monkeypatch: pytest.MonkeyPatch) -> None:
    """断言1(视频族):ai on + 成功 → 行先行(slice)+ ai 队列派发恰一次
    (_expires=86400,ai_slice_video)。"""
    ensure, pool = EnsureRecorder(), ChainPool()
    out, merge, aid = await _run_video_success(monkeypatch, ai_enabled=True,
                                               ensure=ensure, pool=pool)

    assert out["status"] == "ok", out
    assert merge.merges[-1]["sets"]["thumbnail_key"] == f"thumbnails/{aid}.jpg"
    _assert_chained(pool, ensure, aid, "slice")


# ─── 断言 2:ai_enabled=false 零行为(急停语义,§13)──────────────────────────


async def test_ai_disabled_zero_writes_zero_dispatch(
        monkeypatch: pytest.MonkeyPatch) -> None:
    """断言2:ai off → 三族成功路径均零写行零派发;缩略图主链路照常 ok
    (与 baidu_backup_enabled 同款急停语义)。"""
    for run, label in ((_run_image_success, "image"),
                       (_run_livp_success, "livp"),
                       (_run_video_success, "video")):
        ensure, pool = EnsureRecorder(), ChainPool()
        kw: dict[str, Any] = {"zip_bytes": _still_only_livp()} if label == "livp" else {}
        out, _, _ = await run(monkeypatch, ai_enabled=False, ensure=ensure,
                              pool=pool, **kw)
        assert out["status"] == "ok", f"{label} 主链路不受急停影响:{out}"
        assert ensure.calls == [] and pool.jobs == [], \
            f"{label}:off 态零写行零派发"


# ─── 断言 3:failed / skip 路径不触发(方案 §8.1:天然不进 AI)────────────────


async def test_failed_and_skip_paths_not_chained(monkeypatch: pytest.MonkeyPatch) -> None:
    """断言3:图片族 failed(源对象缺失)+ 视频族 skip(non_video)+ livp 族
    skip(not_livp)→ 均零写行零派发。"""
    # 图片族 failed:objects 空 → download_fileobj 抛错 → thumbnail_failed
    aid = uuid.uuid4()
    ensure, pool = EnsureRecorder(), ChainPool()
    ctx = patch_chain(monkeypatch, asset=mk_asset(id=aid, filename="IMG_1.jpg",
                                                  content_type="image/jpeg",
                                                  minio_key="f/gone.jpg"),
                      s3=FakeS3(), merge=TagRecorder(), ai_enabled=True,
                      ensure=ensure, pool=pool)
    out = await generate_thumbnail(ctx, str(aid))
    assert out["status"] == "failed", out
    assert ensure.calls == [] and pool.jobs == [], "失败路径不进 AI 链"

    # 视频族 skip:非视频输入(text/plain + .txt)
    aid = uuid.uuid4()
    ensure, pool = EnsureRecorder(), ChainPool()
    ctx = patch_chain(monkeypatch, asset=mk_asset(id=aid, filename="a.txt",
                                                  content_type="text/plain"),
                      s3=FakeS3(), merge=TagRecorder(), ai_enabled=True,
                      ensure=ensure, pool=pool)
    out = await generate_video_thumbnail(ctx, str(aid))
    assert out["status"] == "skip_non_video", out
    assert ensure.calls == [] and pool.jobs == []

    # livp 族 skip:非 livp 文件名
    aid = uuid.uuid4()
    ensure, pool = EnsureRecorder(), ChainPool()
    ctx = patch_chain(monkeypatch, asset=mk_asset(id=aid, filename="a.jpg"),
                      s3=FakeS3(), merge=TagRecorder(), ai_enabled=True,
                      ensure=ensure, pool=pool)
    out = await generate_livp_thumbnail(ctx, str(aid))
    assert out["status"] == "skip_not_livp", out
    assert ensure.calls == [] and pool.jobs == []


# ─── 断言 4:链式异常隔离(主链路返回值不受影响)────────────────────────────


async def test_chain_failure_isolated_from_main_path(
        monkeypatch: pytest.MonkeyPatch) -> None:
    """断言4:行写入 / enqueue 抛异常、ctx 无 redis → 仅 log,主链路仍 ok 且
    thumbnail_key tags 照常落(fire-and-forget 口径,§8.1)。"""
    # enqueue 抛异常(Redis 抖动):行已先行,主链路 ok
    ensure, pool = EnsureRecorder(), ChainPool(error=RuntimeError("redis down"))
    out, merge, _ = await _run_image_success(monkeypatch, ai_enabled=True,
                                             ensure=ensure, pool=pool)
    assert out["status"] == "ok", out
    assert len(ensure.calls) == 1 and len(pool.jobs) == 1, "行先行先于派发,两者均已尝试"
    assert merge.merges[-1]["sets"]["thumbnail_key"].startswith("thumbnails/")

    # 行写入抛异常(DB 抖动):主链路 ok,不再继续派发
    ensure, pool = EnsureRecorder(error=RuntimeError("db down")), ChainPool()
    out, merge, _ = await _run_image_success(monkeypatch, ai_enabled=True,
                                             ensure=ensure, pool=pool)
    assert out["status"] == "ok", out
    assert pool.jobs == [], "行写入失败不得继续派发"
    assert merge.merges[-1]["sets"]["thumbnail_key"].startswith("thumbnails/")

    # ctx 无 redis:行已先行(sweeper 补派),主链路 ok
    ensure, pool = EnsureRecorder(), ChainPool()
    out, _, aid = await _run_image_success(monkeypatch, ai_enabled=True,
                                           ensure=ensure, pool=None)
    assert out["status"] == "ok", out
    assert [(c[1], c[2]) for c in ensure.calls] == [(str(aid), "annotate")], \
        "redis 缺失只丢派发,行已落(ai_jobs 事实源)"
    assert pool.jobs == []


# ─── 断言 5:挂载点纪律(三族各恰一处)────────────────────────────────────────


def test_chain_mount_exactly_one_per_family() -> None:
    """断言5:三族缩略图函数收尾各恰一处 _chain_ai 调用,全模块恰 3 处 ——
    漏一处 = 该族资产永不打标,多一处 = 同资产双派发噪音(行幂等但派发浪费)。"""
    for fn in (generate_thumbnail, generate_livp_thumbnail, generate_video_thumbnail):
        assert inspect.getsource(fn).count("await _chain_ai(ctx") == 1, \
            f"{fn.__name__} 挂载点数量异常(漏/重)"
    assert inspect.getsource(wmain).count("await _chain_ai(ctx") == 3, \
        "全模块 _chain_ai 调用应恰 3(三族各一)"
