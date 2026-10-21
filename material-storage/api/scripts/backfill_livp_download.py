"""一次性回填存量 livp 资产的下载级解包 job(livp-download-unpack 方案 §7/F8)。

执行(api 容器内,直连 arq Redis):
  docker exec ms-api python -m scripts.backfill_livp_download              # 默认:补既无 zip 也无永久失败 tag 的
  docker exec ms-api python -m scripts.backfill_livp_download --dry-run    # 只对账输出,不入队
  docker exec ms-api python -m scripts.backfill_livp_download --force      # 有 zip / 永久失败 tag 的也重新入队

行为:
  - 扫 filename ILIKE '%.livp' 且未软删的 asset(§7 对账 SQL 同口径),逐个走
    enqueue_livp_download(确定性 _job_id=livpdl:{asset_id} 在途去重 + _expires=3600,
    与上传/自愈派发并发安全)
  - 默认跳过:tags 已有 download_zip_key(已就绪)或 download_zip_failed
    (永久失败:无静态图/超 200MB/解码失败 —— 重派注定同结果)的资产
  - --force:忽略已有 tag 全部重新入队(同 key 覆盖写,重跑幂等)
  - 尾部输出对账口径:livp 总数 vs zip 就绪 / 永久失败 / 本次入队;差额排查看
    worker 日志与 tags.download_zip_video_failed(视频降级不算失败)

顺序:dev 先行验证 → prod;prod 避开百度任务高峰(发版窗口同款判据:活动任务清零)。
失败 / 缺 worker 时 log + 不阻塞(与 backfill_thumbnails 同口径)。
"""
from __future__ import annotations

import asyncio
import logging
import sys

from sqlalchemy import select

from app.db.session import get_sessionmaker
from app.db.tables import Asset
from app.services.arq_pool import create_arq_pool, enqueue_livp_download
from app.settings import get_settings

logging.basicConfig(level=logging.INFO, format="%(levelname)s [%(name)s] %(message)s")
log = logging.getLogger("backfill_livp_download")

_ARGS = set(sys.argv[1:])
DRY_RUN = "--dry-run" in _ARGS
FORCE = "--force" in _ARGS


async def main() -> None:
    settings = get_settings()
    sm = get_sessionmaker()
    async with sm() as db:
        res = await db.execute(
            select(Asset).where(
                Asset.filename.ilike("%.livp"),
                Asset.deleted_at.is_(None),
            )
        )
        assets = list(res.scalars())

    already_ready = 0
    permanently_failed = 0
    to_enqueue: list[str] = []
    for a in assets:
        tags = a.tags or {}
        if not FORCE:
            if tags.get("download_zip_key"):
                already_ready += 1
                continue
            if tags.get("download_zip_failed"):
                permanently_failed += 1
                continue
        to_enqueue.append(str(a.id))

    log.info(
        "livp backfill scan: total=%d already_ready=%d permanently_failed=%d "
        "to_enqueue=%d dry_run=%s force=%s",
        len(assets), already_ready, permanently_failed, len(to_enqueue),
        DRY_RUN, FORCE,
    )
    if DRY_RUN:
        for aid in to_enqueue[:20]:
            log.info("dry-run would enqueue asset=%s%s", aid,
                     " …(+more)" if len(to_enqueue) > 20 else "")
        log.info("dry-run: no job enqueued;对账口径:total vs tags?'download_zip_key',"
                 "差额看 tags.download_zip_failed 与 worker 日志")
        return

    pool = await create_arq_pool(settings)
    enqueued = 0
    for aid in to_enqueue:
        await enqueue_livp_download(pool, aid)
        enqueued += 1
    log.info(
        "livp backfill done: enqueued=%d / total=%d(already_ready=%d "
        "permanently_failed=%d)",
        enqueued, len(assets), already_ready, permanently_failed,
    )


if __name__ == "__main__":
    asyncio.run(main())
