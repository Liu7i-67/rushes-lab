"""存量资产缩略图/封面/small 变体回补脚本(thumb-variant 方案 §3 A5 / §4 B5;替代旧 82 行版)。

执行(api 容器内,默认 dry-run;--apply 才实派发):
  docker exec ms-api python -m scripts.backfill_thumbnails                          # mode=missing 补缺缩略图
  docker exec ms-api python -m scripts.backfill_thumbnails --force --apply --yes    # 全量重排(切 ms-thumbs 用,需确认)
  docker exec ms-api python -m scripts.backfill_thumbnails --mode missing-covers --apply --window 01:00-07:00 --yes
  docker exec ms-api python -m scripts.backfill_thumbnails --mode derive-small --apply --yes  # small 回补

模式:
  missing       (默认,兼容旧行为)扫 image/%、video/%、%.livp 且 tags 无 thumbnail_key → 按族派发
                (--force 忽略已有 key 全量重排;分族 .livp 后缀 → video/* 前缀 → 其余 image)
  missing-covers 三族盲区回补(§3.8):video/% + image/%(排除 image/svg+xml)+ %.livp + 扩展名命中
                thumb_exts 清单(octet-stream 盲区行);tags 无 thumbnail_key/thumbnail_skipped/
                thumbnail_failed(--include-failed 去掉 failed 条件);图片族 >200MB 不派发不打标仅报告(防 OOM)
  derive-small  有 thumbnail_key 且无 thumbnail_small_key → 按名派发 derive_small_thumbnail

公共行为:
  - 确认闸:交互 TTY 问一次,非交互(docker exec / nohup)必须显式 --yes
  - 派发带 _job_id=thumbbf:{mode}:{asset_id} + _expires=3600 在途去重(livpdl 先例),撞已有 job 返回 None 仅记日志
  - --window HH:MM-HH:MM 一律按 UTC+8 固定偏移解释(容器无 TZ),支持跨日窗口;启动时判定一次 + 每批派发前再判定,越窗优雅停止并打印进度
  - --sleep 2 逐条派发间隔秒数(节流,worker 槽与百度共池)
  - 跑批锁:Redis SET backfill:lock <hostname> NX EX 90,每 60s 续期(短 TTL,kill -9 残留 90s 自愈);
    释放 compare-and-del(GET 校验 value==本机 hostname 再 DEL);拿不到锁直接退出
"""
from __future__ import annotations

import argparse
import asyncio
import contextlib
import logging
import re
import socket
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone
from datetime import time as dt_time

import redis.asyncio as redis_asyncio
from sqlalchemy import and_, or_, select

from app.db.session import get_sessionmaker
from app.db.tables import Asset
from app.services.arq_pool import create_arq_pool
from app.services.thumb_exts import (
    IMAGE_EXTS,
    VIDEO_EXTS,
    is_image_asset,
    is_livp_asset,
    is_video_asset,
)
from app.settings import get_settings
from app.workers.thumb_variants import derive_small_thumbnail

logging.basicConfig(level=logging.INFO, format="%(levelname)s [%(name)s] %(message)s")
log = logging.getLogger("backfill")

LOCK_KEY = "backfill:lock"
LOCK_TTL_S = 90
LOCK_RENEW_S = 60
BATCH_SIZE = 50                     # 每批窗口复判 / 进度日志粒度
IMG_CAP_BYTES = 200 * 1024 * 1024   # 图片族派发上限(§3.8:>200MB 只报告不派发,防 OOM)
JOB_EXPIRES_S = 3600                # 在途去重墓碑盲窗(livpdl 同款)
TZ_CN = timezone(timedelta(hours=8))  # 窗口一律按 UTC+8 解释(容器无 TZ,方案 R11)
# 剥前导点再拼交替组(组内裸 '.' 是通配符,正常文件名永不命中,T1 钉的 P1);re.escape 防御元字符;$+~* 语义不变
_EXT_RE = rf"\.({'|'.join(sorted(re.escape(e.lstrip('.')) for e in VIDEO_EXTS | IMAGE_EXTS))})$"
JOBS = {
    "video": "generate_video_thumbnail",
    "image": "generate_thumbnail",
    "livp": "generate_livp_thumbnail",
    "derive-small": derive_small_thumbnail.__name__,  # 按名派发(WorkerSettings 已注册)
}


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="存量缩略图/封面/small 变体回补(默认 dry-run)")
    p.add_argument("--mode", choices=("missing", "missing-covers", "derive-small"),
                   default="missing", help="missing=补缺(默认) missing-covers=三族盲区 derive-small=小图回补")
    p.add_argument("--apply", action="store_true", help="实际派发(默认 dry-run 只报告)")
    p.add_argument("--force", action="store_true", help="仅 missing:忽略已有 thumbnail_key 全量重排(需确认)")
    p.add_argument("--include-failed", action="store_true",
                   help="missing-covers:把已标 thumbnail_failed 的行也纳入重试")
    p.add_argument("--window", metavar="HH:MM-HH:MM", help="派发窗口(UTC+8 语义,如 01:00-07:00),支持跨日")
    p.add_argument("--sleep", type=float, default=2.0, help="逐条派发间隔秒数(默认 2)")
    p.add_argument("--yes", action="store_true", help="非交互确认放行(docker exec / nohup 必带)")
    return p.parse_args()


def parse_window(s: str) -> tuple[dt_time, dt_time]:
    m = re.fullmatch(r"([01]?\d|2[0-3]):([0-5]\d)-([01]?\d|2[0-3]):([0-5]\d)", s.strip())
    if not m:
        raise SystemExit(f"--window 格式错误:{s!r}(期望 HH:MM-HH:MM,如 01:00-07:00)")
    return dt_time(int(m[1]), int(m[2])), dt_time(int(m[3]), int(m[4]))


def in_window(win: tuple[dt_time, dt_time] | None, now: datetime) -> bool:
    """窗口判定(end <= start 视为跨日窗,如 23:00-01:00)。"""
    if win is None:
        return True
    start, end = win
    t = now.time()
    return start <= t <= end if start <= end else (t >= start or t <= end)


def classify_missing(a: Asset) -> str:
    """missing 模式分族(逐字兼容旧版:.livp 后缀 → video/* 前缀 → 其余 image)。"""
    if (a.filename or "").lower().endswith(".livp"):
        return "livp"
    if (a.content_type or "").startswith("video/"):
        return "video"
    return "image"


def classify_covers(a: Asset) -> str | None:
    """missing-covers 分族:livp 优先级最高(§3.5 同序);svg 命中不了任何族。"""
    fn, ct = a.filename or "", a.content_type
    if is_livp_asset(fn):
        return "livp"
    if is_video_asset(fn, ct):
        return "video"
    if is_image_asset(fn, ct):
        return "image"
    return None


async def fetch_missing(db, force: bool) -> list[Asset]:
    stmt = select(Asset).where(
        or_(
            Asset.content_type.like("image/%"),
            Asset.content_type.like("video/%"),
            # livp 浏览器不识别 content-type(octet-stream),按扩展名捞(旧版同口径)
            Asset.filename.ilike("%.livp"),
        ),
        Asset.deleted_at.is_(None),
    )
    rows = list((await db.execute(stmt)).scalars())
    # 旧版语义:thumbnail_key falsy(含空串)即视为缺
    return [a for a in rows if force or not (a.tags or {}).get("thumbnail_key")]


async def fetch_missing_covers(db, include_failed: bool) -> list[Asset]:
    """§3.8 逐字筛选;扩展名命中段用 thumb_exts 清单派生正则下推 SQL。"""
    conds: list = [
        Asset.deleted_at.is_(None),
        or_(
            Asset.content_type.like("video/%"),
            and_(Asset.content_type.like("image/%"), Asset.content_type != "image/svg+xml"),
            Asset.filename.ilike("%.livp"),
            # 扩展名兜底:octet-stream 盲区行(Firefox .mov/.heic 等),清单与 thumb_exts 同源
            Asset.filename.regexp_match(_EXT_RE, "i"),
        ),
        Asset.tags["thumbnail_key"].astext.is_(None),
        Asset.tags["thumbnail_skipped"].astext.is_(None),
    ]
    if not include_failed:
        conds.append(Asset.tags["thumbnail_failed"].astext.is_(None))
    rows = list((await db.execute(select(Asset).where(*conds))).scalars())
    return [a for a in rows if classify_covers(a) is not None]


async def fetch_derive_small(db) -> list[Asset]:
    stmt = select(Asset).where(
        Asset.deleted_at.is_(None),
        Asset.tags["thumbnail_key"].astext.isnot(None),
        Asset.tags["thumbnail_small_key"].astext.is_(None),
    )
    return list((await db.execute(stmt)).scalars())


def print_report(mode: str, assets: list[Asset], oversized: list[Asset], force: bool) -> None:
    counts = Counter(classify_missing(a) if mode == "missing" else
                     (classify_covers(a) or "other") for a in assets)
    print(f"\n[mode={mode}] 命中 {len(assets)} 条" + ("(--force 全量重排)" if force else ""))
    for fam in ("video", "image", "livp", "other"):
        if counts.get(fam):
            print(f"  {fam}: {counts[fam]}")
    if oversized:
        print(f"  超限图片(>200MB,不派发不打标,人工处置):{len(oversized)} 条,如:"
              + ", ".join(a.filename or "" for a in oversized[:5]))
    if assets:
        print("  样例 5 条:" + " | ".join(a.filename or str(a.id) for a in assets[:5]))


async def main() -> None:
    args = parse_args()
    if args.force and args.mode != "missing":
        raise SystemExit("--force 仅支持 --mode missing(兼容旧语义)")
    if args.sleep < 0:
        raise SystemExit("--sleep 必须 >= 0")
    win = parse_window(args.window) if args.window else None

    sm = get_sessionmaker()
    async with sm() as db:
        if args.mode == "missing":
            assets = await fetch_missing(db, args.force)
        elif args.mode == "missing-covers":
            assets = await fetch_missing_covers(db, args.include_failed)
        else:
            assets = await fetch_derive_small(db)

    # missing-covers 图片族 >200MB:不派发不打标,仅报告(§3.8 防 OOM)
    oversized: list[Asset] = []
    if args.mode == "missing-covers":
        oversized = [a for a in assets
                     if classify_covers(a) == "image" and (a.size_bytes or 0) > IMG_CAP_BYTES]
        if oversized:
            assets = [a for a in assets if id(a) not in {id(b) for b in oversized}]

    print_report(args.mode, assets, oversized, args.force)
    now = datetime.now(TZ_CN)
    print(f"  窗口:{args.window or '(未设)'}(UTC+8 语义)当前北京 {now:%H:%M}"
          f"{'在窗内' if in_window(win, now) else '不在窗内'}")
    if not args.apply:
        print("  dry-run 完成(加 --apply 实派发)")
        return
    if not assets:
        print("  命中 0 条,无事可派")
        return
    if not in_window(win, datetime.now(TZ_CN)):  # 启动时窗口判定(确认闸后取新鲜时刻)
        print(f"  启动时已越窗({args.window},UTC+8),不派发,退出。")
        return
    if not args.yes:  # 确认闸:交互 TTY 问一次,非交互必须显式 --yes
        if not sys.stdin.isatty():
            raise SystemExit("非交互执行必须显式传 --yes 放行(docker exec / nohup 场景)")
        # input 走线程池(ASYNC250:不在事件循环内阻塞等待输入)
        ans = await asyncio.to_thread(
            input, f"将实际派发 {len(assets)} 个 job(mode={args.mode}"
            + (" --force 全量重排" if args.force else "") + "),输入 yes 继续:",
        )
        if ans.strip().lower() != "yes":
            print("已取消。")
            return

    settings = get_settings()
    redis = redis_asyncio.from_url(str(settings.redis_url), decode_responses=True)
    host = socket.gethostname()
    if not await redis.set(LOCK_KEY, host, nx=True, ex=LOCK_TTL_S):  # 跑批锁(防并行重复入队)
        print(f"跑批锁 {LOCK_KEY} 被 {await redis.get(LOCK_KEY)} 持有,另一实例在跑,退出。")
        await redis.aclose()
        return

    async def renew_lock() -> None:  # 短 TTL 续期制:长跑不穿透,kill -9 残留 90s 自愈
        while True:
            await asyncio.sleep(LOCK_RENEW_S)
            with contextlib.suppress(Exception):
                await redis.expire(LOCK_KEY, LOCK_TTL_S)

    pool = None
    enqueued = deduped = other_skipped = 0
    stopped = ""
    try:
        pool = await create_arq_pool(settings)
        renew_task = asyncio.create_task(renew_lock())
        try:
            total = len(assets)
            for idx, a in enumerate(assets):
                if idx % BATCH_SIZE == 0 and idx > 0:
                    if not in_window(win, datetime.now(TZ_CN)):  # 每批派发前复判
                        stopped = "(越窗优雅停止)"
                        log.info("越窗(%s,UTC+8),已派发 %d/%d,优雅停止。",
                                 args.window, enqueued, total)
                        break
                    log.info("进度:%d/%d 已派发", idx, total)
                fam = ("derive-small" if args.mode == "derive-small"
                       else classify_missing(a) if args.mode == "missing"
                       else classify_covers(a))
                if fam is None:
                    other_skipped += 1
                    continue
                job = await pool.enqueue_job(
                    JOBS[fam], str(a.id),
                    _job_id=f"thumbbf:{args.mode}:{a.id}", _expires=JOB_EXPIRES_S,
                )
                if job is None:  # 在途去重:同 job_id 已在队列/执行
                    deduped += 1
                    log.info("在途去重跳过 asset=%s job=%s", a.id, JOBS[fam])
                else:
                    enqueued += 1
                if idx < total - 1 and args.sleep > 0:
                    await asyncio.sleep(args.sleep)
        finally:
            renew_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await renew_task
    finally:
        # compare-and-del:校验锁 value 是本机 hostname 再 DEL,防误删他人锁
        try:
            if await redis.get(LOCK_KEY) == host:
                await redis.delete(LOCK_KEY)
        except Exception as e:
            log.warning("锁释放失败(残留 90s 自愈):%s", e)
        await redis.aclose()
        if pool is not None:
            await pool.aclose()

    log.info("DONE — mode=%s total=%d enqueued=%d deduped=%d other_skipped=%d oversized=%d%s",
             args.mode, len(assets), enqueued, deduped, other_skipped, len(oversized), stopped)


if __name__ == "__main__":
    asyncio.run(main())
