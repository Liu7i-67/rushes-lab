"""AI 打标/切片业务管线(方案 §8.3/§8.4 逐步实现;ms-ai-worker job 本体)。

run_annotate(§8.3):行认领 → context_path → 健康闸(16sx2 + 版本血缘断言)→ 读缩略图
(minio 分级)→ describe(传输层 x2 + 内容层一次修复重试)→ 汉化 → upsert → done。
run_slice(§8.4):并发闸(闸满自延迟 :d{ts} 不烧 attempts)→ 认领 → presigned GET
(7200s 主桶内部端点)→ ffprobe(decode_failed 分级)→ 场景检测(600s 降级 interval)
→ 关键帧(自适应+封顶)→ 逐帧 describe(内容层帧级容错 / 传输层连续≥2 帧 job failed)
→ 事务落 → done(软预算止损 last_error='partial')。
铁律(§17-16/14):阻塞段一律 to_thread;心跳 try/finally 取消;日志卫生(§8.3-7)
描述/标签/context_path/presigned URL 不落日志。意外异常不写行 → sweeper 35min 接管。"""
from __future__ import annotations

import asyncio
import contextlib
import logging
import math
import pathlib
import re
import shutil
import tempfile
import time
import uuid
from datetime import UTC, datetime
from io import BytesIO
from typing import Any

import boto3
import httpx
from botocore.client import Config
from botocore.exceptions import ClientError
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.db.session import get_sessionmaker
from app.db.tables import Asset, AssetAiAnnotation, AssetVideoSegment
from app.services import ai_ffmpeg, ai_jobs
from app.settings import get_settings
from app.workers import ai_scene

# 词表(包 I 契约;兜底 stub 仅在其未落地时保 import/单测可用,词表以包 I 为正本)
try:
    from app.services.ai_label_map import map_version_suffix, translate_tags
except ImportError:  # pragma: no cover —— 包 I 未落地的兜底(原样返回 / lm0)
    def translate_tags(tags_en: list[str]) -> list[str]:  # type: ignore[misc]
        return list(tags_en)
    def map_version_suffix() -> str:  # type: ignore[misc]
        return "lm0"

from app.services.ai_ml_client import MlContentError, check_health, describe_image

log = logging.getLogger("worker.ai")

# ─── 常量(§8.2/§8.3/§8.4 算术锚点)───────────────────────────────────────────
HEARTBEAT_INTERVAL_S = 300        # 心跳周期(§8.3-1;35min 过期余量充足)
HEALTH_PROBE_TIMEOUT_S = 60       # ≥2x 最坏满载应答(~30s,dev 实测 8 并发下 healthz 排队超 16s 误判;§7.2)
HEALTH_PROBE_COUNT = 2            # 连续 2 次失败才判死(§8.3-3)
SLICE_URL_TTL_S = 7200            # > slice timeout 5400 + 余量(§8.4-2)
MIN_SLICE_VIDEO_S, MAX_SLICE_VIDEO_S = 10.0, 1800.0   # <10s / >30min → interval 兜底
WALL_BUDGET_S = 4300.0            # wall-clock 软预算,超时止损(§8.2)
TRANSPORT_FAIL_LIMIT = 2          # 连续 ≥2 帧传输层失败 → job failed(ml_error)
SEG_TAGS_CAP, OVERALL_TAGS_CAP, OVERALL_DESC_CAP = 8, 16, 1000
_LM_SUFFIX_RE = re.compile(r"\+lm\d+$")

_Sm = async_sessionmaker[AsyncSession]


def write_model_version(settings: Any = None) -> str:
    """写入版本 = ai_model_version(权重@p)+ 词表版本后缀(§6;幂等替换旧后缀)。"""
    settings = settings or get_settings()
    return f"{_LM_SUFFIX_RE.sub('', settings.ai_model_version)}+{map_version_suffix()}"


def _now() -> datetime:
    return datetime.now(UTC)


def _s3_client(settings: Any, internal_endpoint: str) -> Any:
    """S3 client(内部端点;先例 workers/main.py:131/:924)。"""
    return boto3.client(
        "s3", endpoint_url=internal_endpoint,
        aws_access_key_id=settings.minio_access_key,
        aws_secret_access_key=settings.minio_secret_key,
        config=Config(signature_version="s3v4", region_name="us-east-1"),
    )


def _thumb_s3_client(settings: Any) -> Any:
    """缩略图 MinIO(SSD)client;留空回落主实例(ADR-0008 P1,先例 :72)。"""
    return _s3_client(settings, settings.minio_thumbnail_endpoint_internal
                      or settings.minio_endpoint_internal)


def _ensure_bucket(s3: Any, settings: Any) -> None:
    """确保缩略图 bucket 存在(head/create 幂等;先例 _ensure_thumbnail_bucket)。"""
    try:
        s3.head_bucket(Bucket=settings.minio_thumbnail_bucket)
    except ClientError as e:
        if e.response.get("Error", {}).get("Code") not in ("404", "NoSuchBucket"):
            raise
        s3.create_bucket(Bucket=settings.minio_thumbnail_bucket)


async def _heartbeat_loop(sm: _Sm, token: uuid.UUID) -> None:
    """5min 周期刷 heartbeat_at;单拍失败不中断业务(§8.3-1)。"""
    while True:
        await asyncio.sleep(HEARTBEAT_INTERVAL_S)
        try:
            await ai_jobs.heartbeat_ai_job(sm, token)
        except Exception:
            log.warning("ai heartbeat miss token=%s…", str(token)[:8])


async def _ml_alive(settings: Any) -> bool:
    """健康闸(§8.3-3):连续 2 次探测失败判死;版本不一致同样判死(血缘闸)。"""
    for _ in range(HEALTH_PROBE_COUNT):
        ok, version = await check_health(settings.ai_ml_base_url, HEALTH_PROBE_TIMEOUT_S)
        if ok:
            if version != settings.ai_model_version:
                # 醒目 error:api 侧写入版本与 ms-ml 实际权重静默错位必须被看见
                log.error("ml model_version mismatch expected=%s got=%s",
                          settings.ai_model_version, version)
                return False
            return True
    return False


async def _describe_annotate(base_url: str, image_bytes: bytes,
                             timeout_s: float) -> tuple[list[str], str, str | None] | None:
    """annotate 档 describe(§8.3-5):传输层 x2 次;内容层一次修复重试。None=ml_error。"""
    transport_budget, content_budget = 2, 1
    while True:
        try:
            return await describe_image(base_url, image_bytes, timeout_s)
        except MlContentError:
            if content_budget <= 0:
                return None
            content_budget -= 1
        except httpx.TransportError:
            transport_budget -= 1
            if transport_budget <= 0:
                return None


async def _load_thumbnail(thumb_s3: Any, bucket: str,
                          asset_id: uuid.UUID) -> tuple[bytes | None, str | None]:
    """读缩略图(§8.3-4):404/NoSuchKey → minio_missing(永久);其他 → minio_transient。"""
    def _get() -> tuple[bytes | None, str | None]:
        buf = BytesIO()
        try:
            thumb_s3.download_fileobj(bucket, f"thumbnails/{asset_id}.jpg", buf)
            return buf.getvalue(), None
        except ClientError as e:
            code = str(e.response.get("Error", {}).get("Code", ""))
            miss = code in ("404", "NoSuchKey", "NotFound")
            return (None, "minio_missing" if miss else "minio_transient")
        except Exception:  # 网络抖动类瞬时故障
            return (None, "minio_transient")
    return await asyncio.to_thread(_get)


_ANNOTATION_UPDATABLE = ("tier", "context_path", "tags_zh", "tags_en", "description",
                         "description_en", "searchable_text", "meta", "updated_at")


async def _upsert_annotation_db(db: AsyncSession, values: dict[str, Any]) -> None:
    """annotation PK 冲突覆盖(§8.3-6 幂等第二道);updated_at 显式。"""
    values = {**values, "updated_at": _now()}
    ins = ai_jobs.dialect_insert(db, AssetAiAnnotation.__table__)
    if getattr(getattr(db.bind, "dialect", None), "name", "") == "sqlite":
        # 单测形态:delete+insert 等价 PK 覆盖语义
        await db.execute(delete(AssetAiAnnotation).where(
            AssetAiAnnotation.asset_id == values["asset_id"],
            AssetAiAnnotation.model_version == values["model_version"]))
        await db.execute(ins.values(**values))
        return
    stmt = ins.values(**values).on_conflict_do_update(
        index_elements=["asset_id", "model_version"],
        set_={col: values[col] for col in _ANNOTATION_UPDATABLE})
    await db.execute(stmt)


# ─── ai_annotate_asset 业务本体(§8.3)─────────────────────────────────────────


async def run_annotate(asset_id: str | uuid.UUID, *, settings: Any = None,
                       sm: _Sm | None = None) -> dict[str, Any]:
    settings = settings or get_settings()
    sm = sm or get_sessionmaker()
    aid = uuid.UUID(str(asset_id))
    mv = write_model_version(settings)
    await ai_jobs.ensure_ai_job(sm, aid, ai_jobs.KIND_ANNOTATE, mv)
    outcome = await ai_jobs.claim_ai_job(sm, aid, ai_jobs.KIND_ANNOTATE, mv)
    if not outcome.claimed:
        return {"status": outcome.reason, "asset_id": str(aid)}
    token = outcome.claim_token
    assert token is not None
    beat = asyncio.create_task(_heartbeat_loop(sm, token))
    try:
        ctx = await ai_jobs.build_context_path(sm, aid)
        if ctx is None:  # 软删/不存在 → skipped(asset_gone)(§8.3-2)
            await ai_jobs.finish_ai_job(sm, token, "skipped", last_error="asset_gone")
            return {"status": "skipped_asset_gone", "asset_id": str(aid)}
        if not await _ml_alive(settings):
            # 判死置回 pending、attempts 不动(sweeper 稍后重派,§8.3-3)
            await ai_jobs.unclaim_to_pending(sm, token)
            return {"status": "ml_unavailable", "asset_id": str(aid)}
        thumb_s3 = _thumb_s3_client(settings)
        data, err = await _load_thumbnail(thumb_s3, settings.minio_thumbnail_bucket, aid)
        if err is not None:
            # minio_missing → 永久终态;minio_transient → failed +attempts 待重试
            await ai_jobs.finish_ai_job(
                sm, token, "skipped" if err == "minio_missing" else "failed",
                last_error=err, count_attempt=err != "minio_missing")
            return {"status": err, "asset_id": str(aid)}
        result = await _describe_annotate(settings.ai_ml_base_url, data or b"",
                                          settings.ai_ml_timeout_s)
        if result is None:
            st = await ai_jobs.finish_ai_job(sm, token, "failed", last_error="ml_error",
                                             count_attempt=True)
            return {"status": st or "ml_error", "asset_id": str(aid)}
        tags_en, desc_en, desc_zh = result
        tags_zh = translate_tags(tags_en)
        # 呈现描述 = 中文优先(p5 机器翻译;不可用回落英文);searchable 双语
        desc_show = desc_zh or desc_en
        searchable = ai_jobs.build_searchable_text(
            ctx, *tags_zh, *tags_en, desc_zh or "", desc_en)
        async with sm() as db:
            await _upsert_annotation_db(db, {
                "asset_id": aid, "model_version": mv, "tier": "coarse",
                "context_path": ctx, "tags_zh": tags_zh, "tags_en": tags_en,
                "description": desc_show, "description_en": desc_en,
                "searchable_text": searchable, "meta": {}, "created_at": _now()})
            await db.commit()
        await ai_jobs.finish_ai_job(sm, token, "done")
        log.info("ai annotate done asset=%s tags=%d", aid, len(tags_en))
        return {"status": "done", "asset_id": str(aid)}
    finally:
        beat.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await beat


async def _self_defer_async(pool: Any, aid: uuid.UUID, mv: str) -> None:
    """闸满自延迟重排(§8.2):_job_id 带时间戳后缀 d{ts} 单调量,600s 后重投。"""
    if pool is None:
        log.warning("slice gate full but no pool asset=%s", aid)
        return
    try:
        job = await pool.enqueue_job(
            "ai_slice_video", str(aid),
            _job_id=f"ai:slice:{aid}@{mv}:d{int(time.time())}",
            _defer_by=600, _queue_name="ai",
        )
        if job is None:
            log.warning("slice self defer deduped asset=%s", aid)
    except Exception as e:
        log.warning("slice self defer fail asset=%s err=%s", aid, type(e).__name__)


# ─── ai_slice_video 业务本体(§8.4)────────────────────────────────────────────


async def run_slice(asset_id: str | uuid.UUID, *, settings: Any = None,
                    sm: _Sm | None = None, pool: Any = None) -> dict[str, Any]:
    settings = settings or get_settings()
    sm = sm or get_sessionmaker()
    aid = uuid.UUID(str(asset_id))
    mv = write_model_version(settings)
    await ai_jobs.ensure_ai_job(sm, aid, ai_jobs.KIND_SLICE, mv)
    # 并发闸(行认领层,§8.2):闸满自延迟重排 + touch 行,attempts 不前进
    gate = await ai_jobs.count_running_slices(sm) >= settings.ai_slice_max_concurrent
    if gate:
        await ai_jobs.touch_ai_job(sm, aid, ai_jobs.KIND_SLICE, mv)
        await _self_defer_async(pool, aid, mv)
        return {"status": "deferred_gate", "asset_id": str(aid)}
    outcome = await ai_jobs.claim_ai_job(sm, aid, ai_jobs.KIND_SLICE, mv)
    if not outcome.claimed:
        return {"status": outcome.reason, "asset_id": str(aid)}
    token = outcome.claim_token
    assert token is not None
    beat = asyncio.create_task(_heartbeat_loop(sm, token))
    tmpdir = pathlib.Path(tempfile.mkdtemp(prefix=f"aislice-{aid}-"))
    async def _skip_gone() -> dict[str, Any]:
        await ai_jobs.finish_ai_job(sm, token, "skipped", last_error="asset_gone")
        return {"status": "skipped_asset_gone", "asset_id": str(aid)}
    try:
        ctx = await ai_jobs.build_context_path(sm, aid)
        if ctx is None:
            return await _skip_gone()
        if not await _ml_alive(settings):
            # 判死置回 pending、attempts 不动(sweeper 稍后重派,§8.3-3)
            await ai_jobs.unclaim_to_pending(sm, token)
            return {"status": "ml_unavailable", "asset_id": str(aid)}
        async with sm() as db:
            row = (await db.execute(
                select(Asset.minio_bucket, Asset.minio_key).where(Asset.id == aid),
            )).first()
        if row is None:
            return await _skip_gone()
        bucket, src_key = row
        # presigned GET:主桶内部端点 client,7200s > timeout 5400(§8.4-2)
        s3 = _s3_client(settings, settings.minio_endpoint_internal)
        url = await asyncio.to_thread(
            s3.generate_presigned_url, "get_object",
            Params={"Bucket": bucket, "Key": src_key}, ExpiresIn=SLICE_URL_TTL_S)
        dur = await asyncio.to_thread(ai_ffmpeg.ffprobe_duration, url)
        if dur is None:  # 重试一次;仍失败 skipped(decode_failed),§8.4-3
            dur = await asyncio.to_thread(ai_ffmpeg.ffprobe_duration, url)
        if dur is None or dur <= 0:  # 解码永久失败 → 永久终态
            await ai_jobs.finish_ai_job(sm, token, "skipped", last_error="decode_failed")
            return {"status": "skipped_decode_failed", "asset_id": str(aid)}
        max_seg = settings.ai_max_segments
        interval = max(60.0, math.ceil(dur / max_seg))
        segmented_by, segments = "interval", None
        if MIN_SLICE_VIDEO_S <= dur <= MAX_SLICE_VIDEO_S:
            pts = await asyncio.to_thread(
                ai_ffmpeg.scene_detect, url, settings.ai_scene_threshold)
            if pts is not None:
                segments = ai_scene.aggregate_cut_points(pts, dur, max_segments=max_seg)
                segmented_by = "scene"
            else:
                log.warning("scene detect timeout/fail asset=%s", aid)
        if segments is None:  # <10s / >30min / 检测超时 → interval 兜底(§8.4-3)
            segments = ai_scene.plan_interval_segments(dur, interval, max_seg)
        positions = ai_scene.plan_frame_positions(segments, settings.ai_max_frames)
        thumb_s3 = _thumb_s3_client(settings)
        await asyncio.to_thread(_ensure_bucket, thumb_s3, settings)
        return await _slice_frames_and_store(
            settings, sm, token, aid, mv, ctx, url, segments, positions,
            segmented_by, thumb_s3, tmpdir,
        )
    finally:
        beat.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await beat
        await asyncio.to_thread(shutil.rmtree, tmpdir, True)  # 帧已入 MinIO,tmp 中转


def _merge_unique(base: list[str], extra: list[str]) -> list[str]:
    """并集(保序);段 tags = 帧标签并集 / 整体 = 段级并集(§8.4-6)。"""
    out = list(base)
    for t in extra:
        if t not in out:
            out.append(t)
    return out


async def _slice_frames_and_store(
    settings: Any, sm: _Sm, token: uuid.UUID, aid: uuid.UUID, mv: str, ctx: str,
    url: str, segments: list[tuple[float, float]], positions: list[list[float]],
    segmented_by: str, thumb_s3: Any, tmpdir: pathlib.Path,
) -> dict[str, Any]:
    """抽帧 → 逐帧 describe(二级分级 + 软预算)→ 段聚合 → 事务落 → done。"""
    started = time.monotonic()

    def _left() -> bool:
        return (time.monotonic() - started) < WALL_BUDGET_S

    seg_state: list[dict[str, Any]] = [
        {"tags": [], "desc": None, "keys": [], "ok_frames": 0} for _ in segments]
    transport_streak, partial = 0, False
    for i, times in enumerate(positions):
        state, frame_idx = seg_state[i], 0
        for at_s in times:
            if not _left():
                partial = True
                break
            out_path = tmpdir / f"{i}_{frame_idx}.jpg"
            jpg = await asyncio.to_thread(ai_ffmpeg.extract_frame, url, at_s, out_path)
            frame_idx += 1
            if jpg is None:
                continue  # 单帧抽帧失败 → 段内降级用已得帧(§8.4-5)
            key = f"keyframes/{aid}/{i}_{frame_idx - 1}.jpg"
            await asyncio.to_thread(
                thumb_s3.put_object, Bucket=settings.minio_thumbnail_bucket,
                Key=key, Body=jpg, ContentType="image/jpeg",
                Metadata={"source_asset": str(aid), "kind": "ai_keyframe"},
            )
            state["keys"].append(key)
            if not _left():
                partial = True
                break
            try:
                tags_en, desc_en, desc_zh = await describe_image(
                    settings.ai_ml_base_url, jpg, settings.ai_ml_timeout_s)
            except MlContentError:
                continue  # 内容层 → 帧级容错(§8.4-6 ①)
            except httpx.TransportError:
                # 传输层不计帧级容错;连续 ≥2 帧 → job failed +attempts+1,已成功
                # 帧结果丢弃不落库(§8.4-6 ②,防中途宕机误判 done 永不补打)
                transport_streak += 1
                if transport_streak >= TRANSPORT_FAIL_LIMIT:
                    st = await ai_jobs.finish_ai_job(
                        sm, token, "failed", last_error="ml_error", count_attempt=True)
                    return {"status": st or "ml_error", "asset_id": str(aid)}
                continue
            transport_streak = 0
            state["ok_frames"] += 1
            state["tags"] = _merge_unique(state["tags"], tags_en)
            if state["desc"] is None:    # 段 desc = 首个成功帧描述(中文优先)
                state["desc"] = (desc_zh or desc_en)
            if not state.get("desc_en") and desc_en:
                state["desc_en"] = desc_en
        if partial:
            break
    # 段级降级标记统一判定:全段抽帧失败 / 全部帧 describe 失败 / 软预算跳过段
    # (验收 §15-5:每段关键帧对象存在或带 describe_failed/降级标记)
    for state in seg_state:
        state["extract_failed"] = not state["keys"]
        state["describe_failed"] = state["ok_frames"] == 0
    # 段聚合 → 整体 = 段级并集摘要,忽略失败段(§8.4-6)
    overall_tags = _merge_unique([], [t for s in seg_state for t in s["tags"]])
    overall_tags = overall_tags[:OVERALL_TAGS_CAP]
    # 段/整体描述中文优先(帧级 p5 翻译);英文串单列保 searchable 英文命中
    overall_desc = " / ".join(
        s["desc"] for s in seg_state if s["desc"])[:OVERALL_DESC_CAP]
    overall_desc_en = " / ".join(
        s.get("desc_en") or "" for s in seg_state if s["desc"])[:OVERALL_DESC_CAP]
    tags_zh = translate_tags(overall_tags)
    searchable = ai_jobs.build_searchable_text(
        ctx, *tags_zh, *overall_tags, overall_desc, overall_desc_en,
        *(s["desc"] for s in seg_state if s["desc"]))
    now, meta = _now(), {"segmented_by": segmented_by, "segments": len(segments)}
    if partial:
        meta["partial"] = True
    async with sm() as db:
        # 事务落(§8.4-7/§17-4):segments DELETE+INSERT 与 annotation upsert 同事务
        await db.execute(
            delete(AssetVideoSegment).where(AssetVideoSegment.asset_id == aid))
        for i, ((start, end), state) in enumerate(zip(segments, seg_state, strict=True)):
            seg_meta = {"segmented_by": segmented_by}
            if state["describe_failed"]:
                seg_meta["describe_failed"] = True
            if state["extract_failed"]:
                seg_meta["extract_failed"] = True
            db.add(AssetVideoSegment(
                id=uuid.uuid4(), asset_id=aid, idx=i,
                start_ms=int(start * 1000), end_ms=int(end * 1000),
                keyframe_keys=state["keys"],
                tags_en=state["tags"][:SEG_TAGS_CAP],
                tags_zh=translate_tags(state["tags"])[:SEG_TAGS_CAP],
                description=state["desc"], meta=seg_meta, model_version=mv,
                created_at=now,
            ))
        await _upsert_annotation_db(db, {
            "asset_id": aid, "model_version": mv, "tier": "coarse",
            "context_path": ctx, "tags_zh": tags_zh, "tags_en": overall_tags,
            "description": overall_desc, "description_en": overall_desc_en,
            "searchable_text": searchable, "meta": meta, "created_at": now,
        })
        await db.commit()
    last = "partial" if partial else None
    await ai_jobs.finish_ai_job(sm, token, "done", last_error=last)
    log.info("ai slice done asset=%s segments=%d partial=%s", aid, len(segments), partial)
    return {"status": "done", "asset_id": str(aid), "segments": len(segments),
            "partial": partial}
