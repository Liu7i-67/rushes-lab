"""存量资产 AI 打标/切片全量回填脚本(ai-tagging-slicing 方案 §8.7;仿 backfill_thumbnails)。

执行(api 容器内;默认实派发,--dry-run 只预览统计):
  docker exec ms-api python -m scripts.backfill_ai --kind annotate --dry-run  # 预览命中
  docker exec ms-api python -m scripts.backfill_ai --kind annotate            # 图片/livp 全量打标
  docker exec ms-api python -m scripts.backfill_ai --kind slice               # 视频全量切片(夜间)
  docker exec ms-api python -m scripts.backfill_ai --kind annotate --force    # 全量重跑(含 done)
  docker exec ms-api python -m scripts.backfill_ai --kind annotate --reset-skipped
  docker exec ms-api python -m scripts.backfill_ai --kind annotate --refresh-context  # 只重拼上下文

扫描口径(§8.7):
  annotate  is_image_asset OR filename like %.livp,且 tags.thumbnail_key 就绪
            (缩略图链先行,AI 打标只跑有缩略图的资产)
  slice     is_video_asset 全量 —— 含 thumbnail_failed(链式挂载使缩略图失败的视频
            零 AI 覆盖;slice 自带独立 decode_failed 分级,backfill 是其唯一补打通道)

派发语义(§8.1/§8.5/§8.7):
  - 每行 ensure_ai_job 落行(INSERT ON CONFLICT DO NOTHING);--force 先 reset_ai_job
    (置 pending/attempts=0/claim_token=NULL,含 done —— 否则行认领见 done 即 return,
    §15-3 幂等验收空洞通过);--reset-skipped 同款复位 skipped 终态行,asset_gone
    一律排除(简化:资产已恢复由 restore 钩子删行+补派,此处不逐一判资产存活性;
    确需强制时走 --force)
  - 非 --force 的 pending/failed/running 行重派后 touch updated_at(与 sweeper/闸满
    自延迟同款保鲜,防下一拍 sweeper 臂③ 视为陈旧再派;条目重复有界)
  - _job_id = ai:{kind}:{asset}@{v}:b{unix_ts}(唯一时间戳后缀:kill -9 残留的
    arq:job:{id} 在 _expires 盲窗内同 id 重派静默 None,§8.5),_queue_name="ai",
    _expires annotate=1800 / slice=86400(§8.1)

批大小口径(§8.7):
  annotate 按「10min 内可排空」折算:默认 100 行/批、批间 2s,聚合 ~1.5-3 图/s
  (§7.3),一批数分钟排空 << 10min,仍在排队的批不会被 sweeper 臂③ 视为陈旧重派;
  slice 不限批(闸=2 x 单条 8-15min,排队超 10min 是常态;闸满自延迟与 sweeper 重派
  均 touch 行保鲜,不会重复堆积)—— slice 批间不休眠,仅按批打印进度。

--refresh-context:不走 job 派发,直接调 ai_jobs.refresh_context 对全部未软删资产
  全量对账重拼 context_path/searchable_text(§8.6;无 annotation 行的资产自动跳过),
  分批 ≤ --batch-size。此时 --kind 仅占位。
"""
from __future__ import annotations

import argparse
import asyncio
import re
import time
from collections import Counter
from uuid import UUID

from sqlalchemy import or_, select

from app.db.session import get_sessionmaker
from app.db.tables import AiJob, Asset
from app.services.ai_jobs import (
    KIND_ANNOTATE,
    KIND_SLICE,
    ensure_ai_job,
    refresh_context,
    reset_ai_job,
    touch_ai_job,
)
from app.services.arq_pool import create_arq_pool
from app.services.thumb_exts import (
    IMAGE_EXTS,
    VIDEO_EXTS,
    is_image_asset,
    is_livp_asset,
    is_video_asset,
)
from app.settings import get_settings

BATCH_SIZE = 100                                        # annotate 批大小(口径见模块头)
SLEEP_S = 2.0                                           # annotate 批间休眠秒数
JOB_FN = {KIND_ANNOTATE: "ai_annotate_asset", KIND_SLICE: "ai_slice_video"}
JOB_EXPIRES = {KIND_ANNOTATE: 1800, KIND_SLICE: 86400}  # §8.1 按类区分
# 扩展名正则(剥前导点 + re.escape,与 backfill_thumbnails._EXT_RE 同款构造)
_IMG_EXT_RE = rf"\.({'|'.join(sorted(re.escape(e.lstrip('.')) for e in IMAGE_EXTS))})$"
_VID_EXT_RE = rf"\.({'|'.join(sorted(re.escape(e.lstrip('.')) for e in VIDEO_EXTS))})$"
# 动作裁决值:dispatch_* = 派发(reset/ensure/touch 差异见 run_dispatch),skip_* = 跳过计数
DISPATCH_NEW, DISPATCH_RESET, DISPATCH_RETRY = (
    "dispatch_new", "dispatch_reset", "dispatch_retry")
SKIP_DONE, SKIP_SKIPPED, SKIP_ASSET_GONE = (
    "skip_done", "skip_skipped", "skip_asset_gone")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="存量资产 AI 打标/切片全量回填(方案 §8.7;默认实派发,--dry-run 只预览)")
    p.add_argument("--kind", choices=(KIND_ANNOTATE, KIND_SLICE), required=True,
                   help="annotate=图片/livp 打标;slice=视频切片(--refresh-context 时仅占位)")
    p.add_argument("--model-version", default=None,
                   help="写入版本(默认 write_model_version(settings),与行写入/派发键同源)")
    p.add_argument("--force", action="store_true",
                   help="目标行全部 reset 重跑(置 pending/attempts=0,含 done,§8.7)")
    p.add_argument("--reset-skipped", action="store_true",
                   help="重置 skipped 终态行(asset_gone 排除;恢复场景走 restore 钩子或 --force)")
    p.add_argument("--refresh-context", action="store_true",
                   help="不派发 job;全量重拼 context_path/searchable_text(§8.6)")
    p.add_argument("--batch-size", type=int, default=BATCH_SIZE,
                   help=f"每批行数(默认 {BATCH_SIZE};annotate 按 10min 内可排空折算)")
    p.add_argument("--sleep-s", type=float, default=SLEEP_S,
                   help=f"annotate 批间休眠秒数(默认 {SLEEP_S};slice 不限批,忽略本项)")
    p.add_argument("--dry-run", action="store_true",
                   help="只统计与预览,不落行不派发不重拼")
    return p.parse_args()


async def fetch_annotate_targets(db) -> list[Asset]:
    """annotate 扫描(§8.7):is_image_asset OR %.livp 且 tags.thumbnail_key 就绪。

    SQL 粗筛下推(content_type 前缀 + IMAGE_EXTS 扩展名正则 + %.livp + thumbnail_key
    非空),Python 侧 is_image_asset/is_livp_asset 终筛(svg 不受纳;清单与
    thumb_exts 同源)。
    """
    stmt = select(Asset).where(
        Asset.deleted_at.is_(None),
        or_(
            Asset.content_type.like("image/%"),
            Asset.filename.regexp_match(_IMG_EXT_RE, "i"),
            Asset.filename.ilike("%.livp"),
        ),
        Asset.tags["thumbnail_key"].astext.isnot(None),
    )
    rows = list((await db.execute(stmt)).scalars())
    return [a for a in rows
            if is_image_asset(a.filename, a.content_type) or is_livp_asset(a.filename)]


async def fetch_slice_targets(db) -> list[Asset]:
    """slice 扫描(§8.7):is_video_asset 全量,含 thumbnail_failed —— backfill 是
    缩略图失败视频的唯一 AI 补打通道;无 tags 前置条件。"""
    stmt = select(Asset).where(
        Asset.deleted_at.is_(None),
        or_(
            Asset.content_type.like("video/%"),
            Asset.filename.regexp_match(_VID_EXT_RE, "i"),
        ),
    )
    rows = list((await db.execute(stmt)).scalars())
    return [a for a in rows if is_video_asset(a.filename, a.content_type)]


async def fetch_all_asset_ids(db) -> list[UUID]:
    """--refresh-context 对账范围:全部未软删 asset id(无 annotation 行的自动跳过)。"""
    rows = await db.execute(select(Asset.id).where(Asset.deleted_at.is_(None)))
    return [r[0] for r in rows.all()]


async def fetch_job_statuses(sm, asset_ids: list[UUID], kind: str,
                             model_version: str) -> dict[UUID, tuple[str, str | None]]:
    """批量取 ai_jobs 行状态(asset_id → (status, last_error));缺行 = 不在 dict。"""
    async with sm() as db:
        rows = (await db.execute(
            select(AiJob.asset_id, AiJob.status, AiJob.last_error).where(
                AiJob.asset_id.in_(asset_ids), AiJob.kind == kind,
                AiJob.model_version == model_version,
            ),
        )).all()
    return {r[0]: (r[1], r[2]) for r in rows}


def decide(st: tuple[str, str | None] | None, *, force: bool,
           reset_skipped: bool) -> str:
    """单行动作裁决(纯函数,便于单测):派发三态 + 跳过三态。

    --force 压倒一切(done/skipped/asset_gone 全复位 —— 扫描集内资产必未软删,残留
    asset_gone 行按「资产已恢复」处理);done 未 --force 跳过(行认领见 done 即
    return,派了也白派);skipped 仅 --reset-skipped 复位且 asset_gone 恒排除;
    pending/failed/running 重派 + touch 保鲜(防 sweeper 臂③ 陈旧重派,§8.5)。
    """
    if force:
        return DISPATCH_RESET
    if st is None:
        return DISPATCH_NEW
    status, last_error = st
    if status == "done":
        return SKIP_DONE
    if status == "skipped":
        if last_error == "asset_gone":
            return SKIP_ASSET_GONE
        return DISPATCH_RESET if reset_skipped else SKIP_SKIPPED
    return DISPATCH_RETRY


async def run_dispatch(pool, sm, assets: list[Asset], kind: str, mv: str,
                       args: argparse.Namespace) -> Counter:
    """分批裁决 + 派发(dry-run 只裁决计数,不触达任何写路径,pool 不建为 None)。"""
    fn, expires = JOB_FN[kind], JOB_EXPIRES[kind]
    suffix = f":b{int(time.time())}"  # 每次运行一个唯一后缀(§8.5:防 kill -9 残留吞同 id)
    counts: Counter = Counter()
    total = len(assets)
    for start in range(0, total, args.batch_size):
        batch = assets[start:start + args.batch_size]
        statuses = await fetch_job_statuses(sm, [a.id for a in batch], kind, mv)
        batch_counts: Counter = Counter()
        enq = dedup = 0
        for a in batch:
            action = decide(statuses.get(a.id), force=args.force,
                            reset_skipped=args.reset_skipped)
            batch_counts[action] += 1
            if args.dry_run or not action.startswith("dispatch"):
                continue
            if action == DISPATCH_RESET:
                await reset_ai_job(sm, a.id, kind, mv)  # §8.7:含 done 重置
            if action in (DISPATCH_RESET, DISPATCH_NEW):
                await ensure_ai_job(sm, a.id, kind, mv)  # 行先行(§8.1);无行补插 pending
            job = await pool.enqueue_job(
                fn, str(a.id),
                _job_id=f"ai:{kind}:{a.id}@{mv}{suffix}",
                _expires=expires, _queue_name="ai",
            )
            if job is None:  # 撞在途墓碑盲窗,静默去重仅计数
                dedup += 1
                continue
            enq += 1
            if action == DISPATCH_RETRY:
                await touch_ai_job(sm, a.id, kind, mv)  # 保鲜防 sweeper 臂③ 陈旧重派
        counts.update(batch_counts)
        counts["enqueued"] += enq
        counts["deduped"] += dedup
        done = min(start + args.batch_size, total)
        print(f"  batch {start // args.batch_size + 1}(行 {start + 1}-{done}):"
              f" enqueued={enq} skip_done={batch_counts[SKIP_DONE]}"
              f" skip_skipped={batch_counts[SKIP_SKIPPED]}"
              f" skip_asset_gone={batch_counts[SKIP_ASSET_GONE]} deduped={dedup}")
        if kind == KIND_ANNOTATE and done < total and args.sleep_s > 0:
            # annotate 批间休眠(批大小按 10min 内可排空折算,见模块头);slice 不限批不眠
            await asyncio.sleep(args.sleep_s)
    if args.dry_run:
        counts["enqueued"] = (counts[DISPATCH_NEW] + counts[DISPATCH_RESET]
                              + counts[DISPATCH_RETRY])
    return counts


def print_summary(kind: str, total: int, counts: Counter, *, dry_run: bool) -> None:
    tag = "would_enqueue" if dry_run else "enqueued"
    print(f"DONE{' (dry-run)' if dry_run else ''} kind={kind} scanned={total}"
          f" {tag}={counts['enqueued']} reset={counts[DISPATCH_RESET]}"
          f" skip_done={counts[SKIP_DONE]} skip_skipped={counts[SKIP_SKIPPED]}"
          f" skip_asset_gone={counts[SKIP_ASSET_GONE]} deduped={counts['deduped']}")


async def main() -> None:
    args = parse_args()
    if args.batch_size < 1:
        raise SystemExit("--batch-size 必须 >= 1")
    if args.sleep_s < 0:
        raise SystemExit("--sleep-s 必须 >= 0")
    settings = get_settings()
    # 写入版本单一来源 = ai_pipeline.write_model_version(含词表后缀,与链式/
    # sweeper 派发键一致;函数体内 import 防环,P2-1)。裸 ai_model_version 字面量
    # 不含词表后缀,会让回填行永不可被认领。
    from app.services.ai_pipeline import write_model_version

    mv = args.model_version or write_model_version(settings)
    sm = get_sessionmaker()

    if args.refresh_context:
        async with sm() as db:
            ids = await fetch_all_asset_ids(db)
        print(f"[refresh-context] 未软删资产 {len(ids)} 条 model_version={mv}"
              f" 分批 ≤{args.batch_size}(--kind={args.kind} 仅占位)")
        if args.dry_run:
            print("  dry-run 完成(不重拼)")
            return
        updated = await refresh_context(sm, asset_ids=ids, batch_size=args.batch_size)
        print(f"DONE refresh-context scanned={len(ids)} updated={updated}")
        return

    async with sm() as db:
        assets = await (fetch_annotate_targets(db) if args.kind == KIND_ANNOTATE
                        else fetch_slice_targets(db))
    print(f"[kind={args.kind}] 命中 {len(assets)} 条 model_version={mv}"
          + (" --force 全量重置(含 done)" if args.force else "")
          + (" --reset-skipped 复位 skipped(排除 asset_gone)" if args.reset_skipped else "")
          + ("(dry-run 预览)" if args.dry_run else ""))
    if assets:
        print("  样例 5 条:" + " | ".join(a.filename or str(a.id) for a in assets[:5]))
    if not assets:
        print("  命中 0 条,无事可做。")
        return
    pool = None if args.dry_run else await create_arq_pool(settings)
    try:
        counts = await run_dispatch(pool, sm, assets, args.kind, mv, args)
    finally:
        if pool is not None:
            await pool.aclose()
    print_summary(args.kind, len(assets), counts, dry_run=args.dry_run)


if __name__ == "__main__":
    asyncio.run(main())
