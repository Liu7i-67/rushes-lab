"""ai_pipeline run_annotate / run_slice 失败分级单测(ai-tagging-slicing 方案 §8.3-5/
§8.4-6;需求 §5 测试功能点 3/5)。

既有测试盲区补齐(2026-11-04 专职测试):此前 tests/test_ai_* 均未触达 ai_pipeline
本体 —— 本文件逐条覆盖:
  健康闸判死 → 置回 pending 且不计 attempts(§8.3-3);
  model_version 血缘断言(healthz 版本 ≠ settings.ai_model_version → 判死);
  minio 二级分级(404 → skipped/minio_missing 永久;其他 → failed/minio_transient +attempts);
  毒丸(ml_error 连续 5 次 → 第 5 次 finish 直写 skipped/poison,§8.3-5);
  slice 并发闸满 → 自延迟重排(:d{ts} 后缀 + _defer_by=600 + ai 队列)不烧 attempts;
  slice 二级分级:内容层帧失败 → 段 meta describe_failed、job 不失败;
  传输层连续 ≥2 帧 → failed(ml_error)+attempts+1 且不落任何行;
  成功路径:segments 落库 + annotation upsert + done。

设施:aiosqlite 内存库跑真查询(test_ai_jobs_service 同款;JSONB/ARRAY 列在 sqlite
以 JSON 渲染,表达式索引 DDL 依赖的 array_to_string 注册为确定性函数);ml 客户端
/ S3 client / ffmpeg 命令全部打桩,不连真服务。日志卫生约束(§8.3-7)不属本文件。
"""
from __future__ import annotations

import json
import os
import re
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta
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

import httpx  # noqa: E402
import pytest  # noqa: E402
from botocore.exceptions import ClientError  # noqa: E402
from sqlalchemy import event, select, text  # noqa: E402
from sqlalchemy.dialects.postgresql import ARRAY, JSONB  # noqa: E402
from sqlalchemy.ext.asyncio import (  # noqa: E402
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.ext.compiler import compiles  # noqa: E402

import app.services.ai_pipeline as pl  # noqa: E402
from app.db.tables import (  # noqa: E402
    AiJob,
    Asset,
    AssetAiAnnotation,
    AssetVideoSegment,
    Base,
    Folder,
    Project,
)
from app.services import ai_jobs  # noqa: E402
from app.services.ai_ml_client import MlContentError  # noqa: E402
from app.services.ai_pipeline import write_model_version  # noqa: E402
from app.settings import Settings  # noqa: E402

_MV = write_model_version()


# ─── sqlite 方言垫片(JSONB/ARRAY/表达式索引函数;只影响 sqlite 方言编译)──────
@compiles(JSONB, "sqlite")
def _jsonb_sqlite(type_: Any, compiler: Any, **kw: Any) -> str:  # type: ignore[no-untyped-def]
    return "JSON"


@compiles(ARRAY, "sqlite")
def _array_sqlite(type_: Any, compiler: Any, **kw: Any) -> str:  # type: ignore[no-untyped-def]
    return "JSON"


_SETTINGS = Settings(
    env="test", session_jwt_secret="test-secret",
    db_url="postgresql+asyncpg://u:p@localhost/db", redis_url="redis://localhost:6379/0",
    minio_endpoint_internal="http://minio:9000", minio_endpoint_public="http://localhost:9000",
    minio_access_key="k", minio_secret_key="s", openfga_api_url="http://openfga:8080",
    openfga_store_id="01TEST", web_app_base_url="http://localhost/ms-static/web/",
    ai_enabled=True, ai_ml_base_url="http://ms-ml:8000", ai_ml_timeout_s=30,
)


# ─── DB 设施(六表真查询)─────────────────────────────────────────────────────
_TABLES = (Project.__table__, Folder.__table__, Asset.__table__, AiJob.__table__,
           AssetAiAnnotation.__table__, AssetVideoSegment.__table__)


@pytest.fixture
async def db_env() -> AsyncIterator[tuple[async_sessionmaker[AsyncSession], Any]]:
    """内存 SQLite:六表建库 + array_to_string 确定性注册(表达式索引 DDL 需要)。"""
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")

    @event.listens_for(engine.sync_engine, "connect")
    def _register(dbapi_conn: Any, _rec: Any) -> None:
        def _a2s(value: Any, sep: str) -> str:
            try:
                return sep.join(json.loads(value) if isinstance(value, str) else [])
            except Exception:
                return ""
        dbapi_conn.create_function("array_to_string", 2, _a2s, deterministic=True)

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all, tables=list(_TABLES))
    sm = async_sessionmaker(engine, expire_on_commit=False)
    yield sm, engine
    await engine.dispose()


async def seed_asset(sm: async_sessionmaker[AsyncSession], engine: Any, *,
                     deleted: bool = False,
                     filename: str = "DJI_001.MP4") -> uuid.UUID:
    """raw SQL 落 project/folder/asset(user_labels 在 sqlite 无 ARRAY 绑定通路,
    恒以 '[]' 字面量落库;id 绑 hex 对齐 ORM Uuid 惯例)。"""
    pid, fid, aid = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    async with engine.begin() as conn:
        await conn.execute(text(
            "INSERT INTO projects (id, organization_id, code, name, minio_bucket,"
            " visibility, is_archived) VALUES (:a,:b,'p1','发布会项目','bkt','private',0)"),
            {"a": pid.hex, "b": uuid.uuid4().hex})
        await conn.execute(text(
            "INSERT INTO folders (id, project_id, name, minio_prefix, is_sensitive)"
            " VALUES (:a,:b,'现场','p/x',0)"), {"a": fid.hex, "b": pid.hex})
        await conn.execute(text(
            "INSERT INTO assets (id, folder_id, filename, minio_bucket, minio_key,"
            " size_bytes, media_metadata, tags, user_labels, deleted_at)"
            " VALUES (:a,:b,:c,'bkt','k',1,'{}','{}','[]',:d)"),
            {"a": aid.hex, "b": fid.hex, "c": filename,
             "d": "2026-01-01 00:00:00+00:00" if deleted else None})
    return aid


async def fetch_job(sm: async_sessionmaker[AsyncSession], asset_id: uuid.UUID,
                    kind: str = "annotate") -> AiJob:
    async with sm() as db:
        return (await db.execute(
            select(AiJob).where(AiJob.asset_id == asset_id, AiJob.kind == kind),
        )).scalar_one()


async def ann_rows(sm: async_sessionmaker[AsyncSession],
                   asset_id: uuid.UUID) -> list[AssetAiAnnotation]:
    async with sm() as db:
        return list((await db.execute(
            select(AssetAiAnnotation).where(AssetAiAnnotation.asset_id == asset_id),
        )).scalars().all())


async def seg_rows(sm: async_sessionmaker[AsyncSession],
                   asset_id: uuid.UUID) -> list[AssetVideoSegment]:
    async with sm() as db:
        return list((await db.execute(
            select(AssetVideoSegment).where(AssetVideoSegment.asset_id == asset_id)
            .order_by(AssetVideoSegment.idx),
        )).scalars().all())


# ─── 替身 ────────────────────────────────────────────────────────────────────
class FakeThumbS3:
    """缩略图桶替身:download_fileobj 可注入异常;put_object 记录。"""

    def __init__(self, err: Exception | None = None, payload: bytes = b"jpg") -> None:
        self.err = err
        self.payload = payload
        self.puts: list[dict[str, Any]] = []

    def download_fileobj(self, bucket: str, key: str, buf: Any) -> None:
        if isinstance(self.err, Exception):
            raise self.err
        buf.write(self.payload)

    def put_object(self, **kw: Any) -> dict[str, Any]:
        self.puts.append(kw)
        return {}

    def head_bucket(self, Bucket: str) -> dict[str, Any]:  # noqa: N803
        return {}


class FakeMainS3:
    def generate_presigned_url(self, op: str, Params: dict[str, Any],  # noqa: N803
                               ExpiresIn: int) -> str:
        return "http://minio/presigned-get"


class FakePool:
    def __init__(self) -> None:
        self.jobs: list[tuple[str, tuple[Any, ...], dict[str, Any]]] = []

    async def enqueue_job(self, name: str, *args: Any, **kw: Any) -> object:
        self.jobs.append((name, args, kw))
        return SimpleNamespace(name=name)


def patch_ml(monkeypatch: pytest.MonkeyPatch, *, healthy: bool = True,
             version: str | None = None,
             describe_results: list[Any] | None = None) -> None:
    if version is None:
        version = _SETTINGS.ai_model_version   # 健康闸比对的是原始 settings 值
    """健康闸与 describe 打桩;describe_results 按次回放,耗尽后持续最后一个。"""
    calls: list[bytes] = []

    async def _health(base_url: str, timeout_s: float,
                      shared: Any = None) -> tuple[bool, str | None]:
        return (healthy, version)

    async def _describe(base_url: str, image_bytes: bytes, timeout_s: float,
                        *, max_tags: int = 8) -> Any:
        calls.append(image_bytes)
        results = describe_results or [(["stage"], "outdoor stage", "户外舞台")]
        idx = min(len(calls) - 1, len(results) - 1)
        item = results[idx]
        if isinstance(item, Exception):
            raise item
        if isinstance(item, tuple) and len(item) == 2:  # 旧式 2 元组桩 → 补 zh=None
            return (*item, None)
        return item

    monkeypatch.setattr(pl, "check_health", _health)
    monkeypatch.setattr(pl, "describe_image", _describe)


# ═══ run_annotate 失败分级(功能点 3)═════════════════════════════════════════


class TestAnnotateGrading:
    async def test_health_gate_dead_resets_pending_without_attempt(
            self, db_env: Any, monkeypatch: pytest.MonkeyPatch) -> None:
        """连续 2 次探测失败判死 → 行置回 pending、attempts 不动、claim 清空。"""
        sm, engine = db_env
        aid = await seed_asset(sm, engine)
        patch_ml(monkeypatch, healthy=False)
        out = await pl.run_annotate(aid, settings=_SETTINGS, sm=sm)
        assert out["status"] == "ml_unavailable", out
        row = await fetch_job(sm, aid)
        assert row.status == "pending" and row.attempts == 0
        assert row.claim_token is None and row.heartbeat_at is None

    async def test_model_version_mismatch_judged_dead(
            self, db_env: Any, monkeypatch: pytest.MonkeyPatch) -> None:
        """血缘闸:healthz ok 但版本 ≠ settings.ai_model_version → 同判死路径。"""
        sm, engine = db_env
        aid = await seed_asset(sm, engine)
        patch_ml(monkeypatch, healthy=True, version="other-model@p9")
        out = await pl.run_annotate(aid, settings=_SETTINGS, sm=sm)
        assert out["status"] == "ml_unavailable", out
        row = await fetch_job(sm, aid)
        assert row.status == "pending" and row.attempts == 0, "版本错位不烧 attempts"

    async def test_asset_gone_skipped(self, db_env: Any,
                                      monkeypatch: pytest.MonkeyPatch) -> None:
        """软删 → skipped(asset_gone) 永久终态,不计 attempts;不触 ml。"""
        sm, engine = db_env
        aid = await seed_asset(sm, engine, deleted=True)
        patch_ml(monkeypatch, describe_results=[(["x"], "y")])
        out = await pl.run_annotate(aid, settings=_SETTINGS, sm=sm)
        assert out["status"] == "skipped_asset_gone", out
        row = await fetch_job(sm, aid)
        assert row.status == "skipped" and row.last_error == "asset_gone"
        assert row.attempts == 0

    async def test_minio_missing_skips_permanent(
            self, db_env: Any, monkeypatch: pytest.MonkeyPatch) -> None:
        """缩略图 404 → skipped(minio_missing) 永久;attempts 不动(非执行失败)。"""
        sm, engine = db_env
        aid = await seed_asset(sm, engine)
        patch_ml(monkeypatch)
        monkeypatch.setattr(pl, "_thumb_s3_client", lambda s: FakeThumbS3(
            err=ClientError({"Error": {"Code": "404"}}, "HeadObject")))
        out = await pl.run_annotate(aid, settings=_SETTINGS, sm=sm)
        assert out["status"] == "minio_missing", out
        row = await fetch_job(sm, aid)
        assert row.status == "skipped" and row.last_error == "minio_missing"
        assert row.attempts == 0

    async def test_minio_transient_fails_and_counts_attempt(
            self, db_env: Any, monkeypatch: pytest.MonkeyPatch) -> None:
        """缩略图非 404 → failed(minio_transient)+attempts+1(可重试)。"""
        sm, engine = db_env
        aid = await seed_asset(sm, engine)
        patch_ml(monkeypatch)
        monkeypatch.setattr(pl, "_thumb_s3_client", lambda s: FakeThumbS3(
            err=ClientError({"Error": {"Code": "500"}}, "HeadObject")))
        out = await pl.run_annotate(aid, settings=_SETTINGS, sm=sm)
        assert out["status"] == "minio_transient", out
        row = await fetch_job(sm, aid)
        assert row.status == "failed" and row.last_error == "minio_transient"
        assert row.attempts == 1

    async def test_ml_error_counts_attempt_poison_at_five(
            self, db_env: Any, monkeypatch: pytest.MonkeyPatch) -> None:
        """ml_error(内容层 x2 重试耗尽)→ failed +attempts;第 5 次直写
        skipped(poison)(§8.3-5 毒丸阈值)。"""
        sm, engine = db_env
        aid = await seed_asset(sm, engine)
        patch_ml(monkeypatch, describe_results=[
            MlContentError("ml describe http 500")])
        monkeypatch.setattr(pl, "_thumb_s3_client", lambda s: FakeThumbS3())
        statuses: list[str | None] = []
        for _ in range(ai_jobs.MAX_ATTEMPTS):
            out = await pl.run_annotate(aid, settings=_SETTINGS, sm=sm)
            statuses.append(out["status"])
        assert statuses[:4] == ["failed"] * 4, statuses
        assert statuses[4] == "skipped", "第 5 次失败应落毒丸终态"
        row = await fetch_job(sm, aid)
        assert row.status == "skipped" and row.last_error == "poison"
        assert row.attempts == ai_jobs.MAX_ATTEMPTS

    async def test_success_done_upserts_annotation(
            self, db_env: Any, monkeypatch: pytest.MonkeyPatch) -> None:
        """成功:annotation 落库(searchable = ctx + 中英标签 + 描述)、job done、
        attempts 恒 0;重跑幂等(done 行不被复活、annotation 行不增)。"""
        sm, engine = db_env
        aid = await seed_asset(sm, engine)
        patch_ml(monkeypatch, describe_results=[
            (["stage", "lightshow"], "outdoor stage night")])
        monkeypatch.setattr(pl, "_thumb_s3_client", lambda s: FakeThumbS3())
        out = await pl.run_annotate(aid, settings=_SETTINGS, sm=sm)
        assert out["status"] == "done", out
        rows = await ann_rows(sm, aid)
        assert len(rows) == 1
        ann = rows[0]
        assert ann.model_version == _MV and ann.tier == "coarse"
        assert ann.tags_zh == ["舞台", "lightshow"], "词表汉化生效,未命中保留原文"
        assert ann.tags_en == ["stage", "lightshow"]
        assert ann.context_path == "发布会项目/现场/DJI_001.MP4"
        assert "发布会项目/现场/DJI_001.MP4" in ann.searchable_text
        assert "舞台" in ann.searchable_text and "stage" in ann.searchable_text
        job = await fetch_job(sm, aid)
        assert job.status == "done" and job.last_error is None and job.attempts == 0
        out2 = await pl.run_annotate(aid, settings=_SETTINGS, sm=sm)
        assert out2["status"] == "terminal_done", out2
        assert len(await ann_rows(sm, aid)) == 1

    async def test_ensure_uses_written_version(
            self, db_env: Any, monkeypatch: pytest.MonkeyPatch) -> None:
        """行 model_version = write_model_version(权重@p + 词表后缀),认领才可命中。"""
        sm, engine = db_env
        aid = await seed_asset(sm, engine)
        patch_ml(monkeypatch, healthy=False)
        await pl.run_annotate(aid, settings=_SETTINGS, sm=sm)
        row = await fetch_job(sm, aid)
        assert row.model_version == write_model_version(_SETTINGS)


# ═══ run_slice(功能点 5 + §8.2 并发闸)════════════════════════════════════════


def _patch_ffmpeg(monkeypatch: pytest.MonkeyPatch, *, duration: float | None = 300.0,
                  cuts: list[float] | None = None,
                  extract_ok: bool = True) -> None:
    """ffmpeg 同步执行段打桩(真函数为同步体,to_thread 语义保持)。"""

    def _probe(url: str) -> float | None:
        return duration

    def _detect(url: str, threshold: float) -> list[float] | None:
        return list(cuts) if cuts is not None else None

    def _extract(url: str, at_s: float, out_path: Any) -> bytes | None:
        if not extract_ok:
            return None
        out_path.write_bytes(b"jpegdata")
        return b"jpegdata"

    monkeypatch.setattr(pl.ai_ffmpeg, "ffprobe_duration", _probe)
    monkeypatch.setattr(pl.ai_ffmpeg, "scene_detect", _detect)
    monkeypatch.setattr(pl.ai_ffmpeg, "extract_frame", _extract)


def _patch_s3(monkeypatch: pytest.MonkeyPatch,
              thumb: FakeThumbS3 | None = None) -> FakeThumbS3:
    thumb = thumb or FakeThumbS3()
    monkeypatch.setattr(pl, "_s3_client", lambda s, ep: FakeMainS3())
    monkeypatch.setattr(pl, "_thumb_s3_client", lambda s: thumb)
    return thumb


class TestSliceGrading:
    async def test_gate_full_defers_without_attempt(
            self, db_env: Any, monkeypatch: pytest.MonkeyPatch) -> None:
        """闸满(2 路新鲜 running slice)→ deferred_gate:行留 pending、attempts 0、
        自延迟重排(:d{ts} 后缀 / _defer_by=600 / ai 队列)。"""
        sm, engine = db_env
        aid = await seed_asset(sm, engine)
        now = datetime.now(UTC)
        async with sm() as db:
            for _ in range(_SETTINGS.ai_slice_max_concurrent):
                db.add(AiJob(id=uuid.uuid4(), asset_id=uuid.uuid4(), kind="slice",
                             status="running", attempts=0, model_version=_MV,
                             claim_token=uuid.uuid4(),
                             heartbeat_at=now - timedelta(seconds=60),
                             created_at=now, updated_at=now))
            await db.commit()
        _patch_ffmpeg(monkeypatch)
        _patch_s3(monkeypatch)
        pool = FakePool()
        out = await pl.run_slice(aid, settings=_SETTINGS, sm=sm, pool=pool)
        assert out["status"] == "deferred_gate", out
        row = await fetch_job(sm, aid, "slice")
        assert row.status == "pending" and row.attempts == 0, "闸满不烧 attempts"
        assert len(pool.jobs) == 1
        name, args, kw = pool.jobs[0]
        assert name == "ai_slice_video" and args == (str(aid),)
        assert kw["_defer_by"] == 600 and kw["_queue_name"] == "ai"
        assert re.fullmatch(rf"ai:slice:{aid}@{re.escape(_MV)}:d\d+",
                            kw["_job_id"]), kw["_job_id"]

    async def test_decode_failed_skips(
            self, db_env: Any, monkeypatch: pytest.MonkeyPatch) -> None:
        """ffprobe 两次均 None → skipped(decode_failed) 永久终态,不计 attempts。"""
        sm, engine = db_env
        aid = await seed_asset(sm, engine)
        patch_ml(monkeypatch, describe_results=[(["x"], "d")])   # 闸先于 ffprobe
        _patch_ffmpeg(monkeypatch, duration=None)
        _patch_s3(monkeypatch)
        out = await pl.run_slice(aid, settings=_SETTINGS, sm=sm, pool=FakePool())
        assert out["status"] == "skipped_decode_failed", out
        row = await fetch_job(sm, aid, "slice")
        assert row.status == "skipped" and row.last_error == "decode_failed"
        assert row.attempts == 0
        assert (await seg_rows(sm, aid)) == [] and (await ann_rows(sm, aid)) == []

    async def test_transport_streak_two_fails_job_no_rows(
            self, db_env: Any, monkeypatch: pytest.MonkeyPatch) -> None:
        """传输层连续 ≥2 帧 → failed(ml_error)+attempts+1;已成功帧结果丢弃,
        segments / annotation 均不落库(防中途宕机误判 done 永不补打)。"""
        sm, engine = db_env
        aid = await seed_asset(sm, engine)
        patch_ml(monkeypatch, describe_results=[
            httpx.ConnectError("boom"), httpx.ConnectError("boom")])
        _patch_ffmpeg(monkeypatch, duration=300.0, cuts=[100.0])
        _patch_s3(monkeypatch)
        out = await pl.run_slice(aid, settings=_SETTINGS, sm=sm, pool=FakePool())
        assert out["status"] == "failed", out
        row = await fetch_job(sm, aid, "slice")
        assert row.status == "failed" and row.last_error == "ml_error"
        assert row.attempts == 1
        assert (await seg_rows(sm, aid)) == [], "传输层失败不落段"
        assert (await ann_rows(sm, aid)) == [], "传输层失败不落 annotation"

    async def test_single_transport_failure_is_frame_tolerated(
            self, db_env: Any, monkeypatch: pytest.MonkeyPatch) -> None:
        """单帧传输层失败不判 job 死(连续 <2):该帧丢、其余帧照常 → done。"""
        sm, engine = db_env
        aid = await seed_asset(sm, engine)
        patch_ml(monkeypatch, describe_results=[
            (["stage"], "seg0 first"),
            httpx.ConnectError("one blip"),
            (["stage"], "seg0 third"),
            (["lightshow"], "seg1 first"),
            (["lightshow"], "seg1 second"),
            (["drone"], "seg1 third"),
        ])
        _patch_ffmpeg(monkeypatch, duration=300.0, cuts=[100.0])
        _patch_s3(monkeypatch)
        out = await pl.run_slice(aid, settings=_SETTINGS, sm=sm, pool=FakePool())
        assert out["status"] == "done", out
        row = await fetch_job(sm, aid, "slice")
        assert row.status == "done" and row.attempts == 0
        assert len(await seg_rows(sm, aid)) == 2

    async def test_content_fail_frames_mark_describe_failed_job_done(
            self, db_env: Any, monkeypatch: pytest.MonkeyPatch) -> None:
        """内容层帧失败全段容错 → job done、段 meta describe_failed=True(验收
        §15-5「每段关键帧对象存在或带降级标记」)。"""
        sm, engine = db_env
        aid = await seed_asset(sm, engine)
        patch_ml(monkeypatch, describe_results=[MlContentError("bad schema")])
        _patch_ffmpeg(monkeypatch, duration=300.0, cuts=[100.0])
        _patch_s3(monkeypatch)
        out = await pl.run_slice(aid, settings=_SETTINGS, sm=sm, pool=FakePool())
        assert out["status"] == "done", out
        row = await fetch_job(sm, aid, "slice")
        assert row.status == "done" and row.last_error is None
        segs = await seg_rows(sm, aid)
        assert len(segs) == 2
        for seg in segs:
            assert seg.meta.get("describe_failed") is True, seg.meta
            assert seg.meta.get("segmented_by") == "scene"
        ann = (await ann_rows(sm, aid))[0]
        assert ann.tags_en == [] and ann.description_en == "", "全帧失败无标签无描述"

    async def test_extract_fail_marks_extract_failed(
            self, db_env: Any, monkeypatch: pytest.MonkeyPatch) -> None:
        """全段抽帧失败 → 段 meta extract_failed=True、job 仍 done、不传对象。"""
        sm, engine = db_env
        aid = await seed_asset(sm, engine)
        patch_ml(monkeypatch, describe_results=[MlContentError("unused")])
        _patch_ffmpeg(monkeypatch, duration=300.0, cuts=[100.0], extract_ok=False)
        thumb = _patch_s3(monkeypatch)
        out = await pl.run_slice(aid, settings=_SETTINGS, sm=sm, pool=FakePool())
        assert out["status"] == "done", out
        segs = await seg_rows(sm, aid)
        assert all(s.meta.get("extract_failed") is True for s in segs), \
            [s.meta for s in segs]
        assert all(s.keyframe_keys == [] for s in segs)
        assert thumb.puts == [], "无帧可传"

    async def test_success_writes_segments_annotation(
            self, db_env: Any, monkeypatch: pytest.MonkeyPatch) -> None:
        """成功:段聚合落库(毫秒边界 / keyframe_keys 前缀 keyframes/{aid}/ /
        整体=段级并集)、annotation upsert、done;段 meta segmented_by=scene。"""
        sm, engine = db_env
        aid = await seed_asset(sm, engine)
        patch_ml(monkeypatch, describe_results=[
            (["stage", "stage"], "seg0 desc"),
            (["lightshow"], "seg0 b"),
            (["stage"], "seg0 c"),
            (["drone", "aerial"], "seg1 desc"),
            (["drone"], "seg1 b"),
            (["aerial"], "seg1 c"),
        ])
        _patch_ffmpeg(monkeypatch, duration=300.0, cuts=[100.0])
        thumb = _patch_s3(monkeypatch)
        out = await pl.run_slice(aid, settings=_SETTINGS, sm=sm, pool=FakePool())
        assert out["status"] == "done" and out["segments"] == 2, out
        segs = await seg_rows(sm, aid)
        assert [(s.start_ms, s.end_ms) for s in segs] == [(0, 100000), (100000, 300000)]
        assert all(s.model_version == _MV for s in segs)
        assert segs[0].keyframe_keys == [f"keyframes/{aid}/0_{i}.jpg" for i in range(3)], \
            "段数 ≤20 → 每段 3 帧"
        assert len(thumb.puts) == 6, "2 段 x3 帧,总帧 ≤ ai_max_frames(60)"
        assert {p["Key"].split("/")[0] for p in thumb.puts} == {"keyframes"}
        ann = (await ann_rows(sm, aid))[0]
        assert ann.tags_en == ["stage", "lightshow", "drone", "aerial"], "并集保序去重"
        assert ann.tags_zh == ["舞台", "lightshow", "航拍"], "汉化 + 同译词去重"
        assert ann.description_en == "seg0 desc / seg1 desc", "整体描述 = 段级摘要拼接"
        assert ann.meta.get("segmented_by") == "scene"
        assert ann.meta.get("segments") == 2
        assert ann.meta.get("partial") is None
        job = await fetch_job(sm, aid, "slice")
        assert job.status == "done" and job.last_error is None

    async def test_interval_fallback_capped_at_max_segments(
            self, db_env: Any, monkeypatch: pytest.MonkeyPatch) -> None:
        """>30min(dur=7200s)→ interval 兜底,段数 ≤ ai_max_segments、帧数 ≤
        ai_max_frames(验收 §15-5「interval 兜底路径同样受限」)。"""
        sm, engine = db_env
        aid = await seed_asset(sm, engine)
        patch_ml(monkeypatch, describe_results=[(["x"], "d")] * 60)
        _patch_ffmpeg(monkeypatch, duration=7200.0, cuts=None)
        _patch_s3(monkeypatch)
        out = await pl.run_slice(aid, settings=_SETTINGS, sm=sm, pool=FakePool())
        assert out["status"] == "done", out
        segs = await seg_rows(sm, aid)
        assert len(segs) <= _SETTINGS.ai_max_segments
        assert (await ann_rows(sm, aid))[0].meta.get("segmented_by") == "interval"
        total_frames = sum(len(s.keyframe_keys) for s in segs)
        assert total_frames <= _SETTINGS.ai_max_frames

    async def test_annotation_upsert_idempotent_on_slice_rerun(
            self, db_env: Any, monkeypatch: pytest.MonkeyPatch) -> None:
        """同 asset 同版本重跑(验收 §15-3):segment 行数不增、annotation 行数不增。"""
        sm, engine = db_env
        aid = await seed_asset(sm, engine)
        patch_ml(monkeypatch, describe_results=[
            (["stage"], "d1"), (["stage"], "d1"), (["stage"], "d1"),
            (["drone"], "d2"), (["drone"], "d2"), (["drone"], "d2"),
            (["stage"], "d1"), (["stage"], "d1"), (["stage"], "d1"),
            (["drone"], "d2"), (["drone"], "d2"), (["drone"], "d2"),
        ])
        _patch_ffmpeg(monkeypatch, duration=300.0, cuts=[100.0])
        _patch_s3(monkeypatch)
        await pl.run_slice(aid, settings=_SETTINGS, sm=sm, pool=FakePool())
        await pl.run_slice(aid, settings=_SETTINGS, sm=sm, pool=FakePool())
        assert len(await seg_rows(sm, aid)) == 2, "segment 行数不增(DELETE+INSERT)"
        assert len(await ann_rows(sm, aid)) == 1, "annotation 行数不增(upsert)"
        row = await fetch_job(sm, aid, "slice")
        assert row.status == "done"

    async def test_slice_health_gate_dead_resets_pending(
            self, db_env: Any, monkeypatch: pytest.MonkeyPatch) -> None:
        """slice 同受健康闸(§8.3-3):判死 → pending 不计 attempts。"""
        sm, engine = db_env
        aid = await seed_asset(sm, engine)
        _patch_ffmpeg(monkeypatch)
        _patch_s3(monkeypatch)

        async def _dead(base_url: str, timeout_s: float,
                        shared: Any = None) -> tuple[bool, str | None]:
            return (False, None)

        monkeypatch.setattr(pl, "check_health", _dead)
        out = await pl.run_slice(aid, settings=_SETTINGS, sm=sm, pool=FakePool())
        assert out["status"] == "ml_unavailable", out
        row = await fetch_job(sm, aid, "slice")
        assert row.status == "pending" and row.attempts == 0


# ═══ write_model_version(词表版本并入)════════════════════════════════════════


def test_write_model_version_appends_lm_suffix() -> None:
    """写入版本 = ai_model_version 剥旧词表后缀 + 当前词表版本;幂等替换。"""
    s = _SETTINGS.model_copy(update={"ai_model_version": "smolvlm2-256m@p1"})
    mv = write_model_version(s)
    assert re.fullmatch(r"smolvlm2-256m@p1\+lm\d+", mv), mv
    s2 = _SETTINGS.model_copy(update={"ai_model_version": mv})   # 已带后缀 → 不双写
    assert write_model_version(s2) == mv
