"""批量下载单 zip 化 — 打包 job / 锁闸 Lua / 清理 cron(livp-download-unpack 方案 §6,F10/F11)。

职责(后端包 B,批量侧;权威方案 rushes-spec/material-storage/livp-download-unpack-plan.md §6):

  - generate_batch_download_zip:arq 打包 job(func timeout=1800 / max_tries=1)——
    执行开始 token 匹配 Lua 续期两键(失主只 log 不写失败标记);模块级打包信号量 ≤2
    (单进程语义,勿横向扩 worker 副本)acquire 限时 120s 快速失败;job 自管 deadline
    (逐资产检查)+ finally shield 宽限 60s 等待在途线程;逐资产重查行按当前 minio_key
    拉流(行删 / NoSuchKey 跳过;有效条目 0 → 失败收尾);livp 就绪解开
    derivatives/{id}/livp.zip 取成员按批量包规则重写内名(衍生物缺失/未就绪 → 原始
    .livp 兜底);打包完成把实际 livp_raw_count(原始兜底计数)Lua 回写作业记录
    `batchzip:job:{user}:{key}` 字段 livp_raw_count_actual(存在才改 + KEEPTTL,
    定稿 §6.2 第 6 步:ready 响应以 job 实际计数为准,缺失回落 tags 静态判定);
    Windows 风格 `(1)` 重名去重;`zf.open(zinfo, "w", force_zip64=True)`
    流式 + ZIP_STORED;multipart `upload_file` 回传(ExtraArgs 带 kind 守卫元数据 +
    TransferConfig 64MB 分片);finally token 匹配 DEL 两键 + 失败 SET
    `batchzip:fail:{key}` EX 600。
  - cleanup_batch_zips:cron 每 10 分钟(per-cron timeout=300)——list_buckets() 迭代
    全部桶 → list_objects_v2(`derivatives/batch/` 前缀,IsTruncated 分页)→ key 形态
    粗筛 `^[0-9a-f]{16}\\.zip$` → LastModified >6h → head 校验
    Metadata.kind == "batch_download_zip" 才删(用户自建 derivatives/batch 夹内原片与
    derivatives/{id}/livp.zip 永久衍生物绝不波及)。
  - 端点侧共用件(assets.py batch-download-link 端点 import):确定性缓存 key、Redis
    键名、三段锁闸 Lua(两键 NX 原子落 / token 匹配续期 / token 匹配 DEL)、临时目录
    延迟清理。

阻塞段(boto3 / zip / 文件 IO)一律丢线程池:arq 的 max_jobs 是单事件循环协程数,
同步阻塞体会冻结整个 worker(asset_purge.py:12 铁律对 worker 同样适用;§6.2)——
冻结期间在跑百度任务的 5s 租约续期停摆会被 sweeper 误判接管。
"""
from __future__ import annotations

import asyncio
import functools
import hashlib
import logging
import os
import re
import shutil
import tempfile
import time
import uuid
import zipfile
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import boto3
from boto3.s3.transfer import TransferConfig
from botocore.client import Config
from botocore.exceptions import ClientError

from app.db.session import get_sessionmaker
from app.db.tables import Asset
from app.settings import get_settings

log = logging.getLogger("worker.batch")

# ─── 常量(契约值,与测试契约/端点共用)─────────────────────────────────────────
KEYGATE_TTL = 2400          # 两键(per-key 闸 + per-user 锁)TTL,崩溃兜底(§6.2 第 5 步)
FAIL_TTL = 600              # 失败标记 batchzip:fail:{key} EX(端点 failed 短路窗)
JOB_RECORD_TTL = 3600       # 作业记录 batchzip:job:{user}:{key} EX(轮询回放窗)
AUDITED_TTL = 1800          # denied 审计去重 batchzip:audited:{user}:{key}(≥ 前端轮询上限 900s)
BATCH_URL_TTL = 21600       # 批量包保留/URL 满额 6h(命中路径按剩余寿命收缩)
_BATCH_RETENTION = timedelta(hours=6)
BATCH_ZIP_PREFIX = "derivatives/batch/"
BATCH_ZIP_KIND = "batch_download_zip"
_BATCH_OBJ_RE = re.compile(r"^[0-9a-f]{16}\.zip$")

_MULTIPART_THRESHOLD = 64 * 1024 * 1024   # upload_file 分片阈值(5GiB 单 PUT 硬限兜底)
_PACK_CONCURRENCY = 2                     # 打包全局并发 ≤2(单进程语义;勿横向扩副本)
_SEMAPHORE_WAIT_S = 120                   # 信号量 acquire 限时,超时快速失败不烧 job 预算
_JOB_TIME_BUDGET_S = 1740                 # 自管 deadline(< arq timeout 1800,留收尾余量)
_GRACE_S = 60                             # finally shield 宽限:等待在途线程收尾
_COPY_CHUNK = 1024 * 1024
_TMP_CLEANUP_DELAY_S = 60.0               # job 返回后延迟清理临时目录(见 _deferred_cleanup)
_TMP_PRUNE_AGE_S = 6 * 3600               # 进程死亡残留的临时目录清扫阈值

# 打包并发信号量:模块级(单进程语义)——部署 checklist 红线:勿横向扩 worker 副本,
# 扩前须改分布式闸(方案 §6.2/§11 ④)
_PACK_SEMAPHORE = asyncio.Semaphore(_PACK_CONCURRENCY)

# 在途线程 Future 集:job 被取消(arq timeout)时 to_thread 线程会继续跑,finally
# 按 shield 宽限等待,避免 rmtree 删在线程脚下(§6.2 超时取消的线程僵尸窗口)
_INFLIGHT: set[asyncio.Future] = set()


def _to_thread(fn: Any, /, *args: Any, **kwargs: Any) -> asyncio.Future:
    """asyncio.to_thread 同款语义,但 Future 进 _INFLIGHT,供 finally 宽限等待。"""
    loop = asyncio.get_running_loop()
    fut = loop.run_in_executor(None, functools.partial(fn, *args, **kwargs))
    _INFLIGHT.add(fut)
    fut.add_done_callback(_INFLIGHT.discard)
    return fut


# ─── Redis 键名(契约:docs/qdev/2026-10-21-livp-download-unpack.md「数据库修改方案」)──
def batch_keygate_key(key: str) -> str:
    """per-key 在途闸(跨用户同 key 打包期去重)。"""
    return f"batchzip:keygate:{key}"


def batch_active_key(user_id: str) -> str:
    """per-user 锁(value = f"{key}:{job_token}",前缀比对放行同 key 轮询)。"""
    return f"batchzip:active:{user_id}"


def batch_fail_key(key: str) -> str:
    """失败标记(job 失败写,端点 failed 短路;retry:true 清)。"""
    return f"batchzip:fail:{key}"


def batch_job_record_key(user_id: str, key: str) -> str:
    """作业记录(按用户分存;selection_ids 与 allowed_ids 分存,轮询轻校验 + 回放)。"""
    return f"batchzip:job:{user_id}:{key}"


def batch_audited_key(user_id: str, key: str) -> str:
    """denied 审计去重(SETNX EX 1800,窗口 ≥ 前端轮询上限)。"""
    return f"batchzip:audited:{user_id}:{key}"


def batch_object_key(key: str) -> str:
    """批量包对象 key(response key 是裸 16 位哈希,对象带前缀与 .zip 后缀)。"""
    return f"{BATCH_ZIP_PREFIX}{key}.zip"


# ─── 确定性缓存 key(允许集摘要 + livp 就绪位;canonical 化去重升序)──────────────
def canonical_ids(ids: Any) -> list[str]:
    """ids 去重 + 升序(resume 校验与 key 哈希共用同一 canonical 函数)。"""
    return sorted({str(x) for x in ids})


def allowed_digest(allowed_ids: Any) -> str:
    """允许集摘要:缓存正确性的根本 —— 权限不同天然分 key,权限相同共享缓存。"""
    joined = ",".join(canonical_ids(allowed_ids))
    return hashlib.sha256(joined.encode("utf-8")).hexdigest()


def compute_batch_key(readiness: dict[str, bool], allowed_ids: Any) -> str:
    """确定性 key = sha256(允许集摘要 + livp 就绪位)[:16]。

    允许集摘要在 key 里 → 权限不同不撞包(无投毒无乒乓);就绪位在 key 里 →
    livp 衍生物就绪翻转后旧包不被钉住。key 是包内容的函数(包内容 = 允许集 +
    就绪位),与请求 id 顺序/重复/缺席项无关(契约测试 k1==k4 钉死内容寻址语义)。
    """
    bits = "|".join(f"{aid}:{1 if ok else 0}" for aid, ok in sorted(readiness.items())) or "-"
    material = f"{allowed_digest(allowed_ids)}|{bits}"
    return hashlib.sha256(material.encode("utf-8")).hexdigest()[:16]


# ─── 锁闸三段 Lua(端点与 job 共用;token 语义见 §6.2 第 5 步)──────────────────
# 两键 NX 原子落:任一已存在整体失败,防「两 SET 之间进程死亡」留假 packing 孤儿窗
_LUA_ACQUIRE = """
local val = ARGV[1] .. ':' .. ARGV[2]
local ttl = tonumber(ARGV[3])
if redis.call('SET', KEYS[1], val, 'NX', 'EX', ttl) then
  if redis.call('SET', KEYS[2], val, 'NX', 'EX', ttl) then
    return 1
  end
  redis.call('DEL', KEYS[1])
end
return 0
"""
# 值含本 token 才续期(以执行时刻重置 TTL);失主返回 0
_LUA_RENEW = """
local ttl = tonumber(ARGV[2])
for i = 1, 2 do
  local v = redis.call('GET', KEYS[i])
  if not v or not string.find(v, ARGV[1], 1, true) then
    return 0
  end
end
redis.call('EXPIRE', KEYS[1], ttl)
redis.call('EXPIRE', KEYS[2], ttl)
return 1
"""
# 值匹配才 DEL:不同批次/重试的 job 不得误删后来者的锁(防僵尸拖尾误删新闸)
_LUA_RELEASE = """
local deleted = 0
for i = 1, 2 do
  local v = redis.call('GET', KEYS[i])
  if v and string.find(v, ARGV[1], 1, true) then
    redis.call('DEL', KEYS[i])
    deleted = deleted + 1
  end
end
return deleted
"""


async def acquire_batch_locks(redis: Any, user_id: str, key: str, token: str) -> int:
    """端点用:两键 NX 原子落(单段 Lua;1=成功,0=被占)。"""
    return int(await redis.eval(
        _LUA_ACQUIRE, 2, batch_keygate_key(key), batch_active_key(user_id),
        key, token, KEYGATE_TTL,
    ))


async def renew_batch_locks(redis: Any, user_id: str, key: str, token: str) -> int:
    """job 执行开始用:值含本 token 才续(以执行时刻重置 TTL);失主返 0。"""
    return int(await redis.eval(
        _LUA_RENEW, 2, batch_keygate_key(key), batch_active_key(user_id),
        token, KEYGATE_TTL,
    ))


async def release_batch_locks(redis: Any, user_id: str, key: str, token: str) -> int:
    """finally 用:值匹配才删(1/2=删了,0=锁已易主)。回滚与释放同一段 Lua。"""
    return int(await redis.eval(
        _LUA_RELEASE, 2, batch_keygate_key(key), batch_active_key(user_id),
        token,
    ))


# ─── livp_raw_count 实际值回写(定稿 §6.2 第 6 步:ready 响应以 job 实际打包计数为准)──
# 单段 Lua 原子「存在才改 + 字段级合并 + KEEPTTL」:记录已过期(GET 为空)跳过不复活
# (SET 会把过期键复活成无 TTL 键 = 永久泄漏);KEEPTTL 保持原 TTL 语义(不重置回放窗)
_LUA_WRITEBACK_LIVP_RAW = """
local cur = redis.call('GET', KEYS[1])
if not cur then
  return 0
end
local obj = cjson.decode(cur)
obj['livp_raw_count_actual'] = tonumber(ARGV[1])
redis.call('SET', KEYS[1], cjson.encode(obj), 'KEEPTTL')
return 1
"""


async def writeback_livp_raw_count(redis: Any, user_id: str, key: str, count: int) -> bool:
    """job 打包完成把实际 livp_raw_count 回写作业记录 `batchzip:job:{user}:{key}`
    (字段 `livp_raw_count_actual`;端点 ready 优先读它,缺失回落 tags 静态判定)。
    记录已过期(打包完成晚于 EX 3600 的常态边缘)→ False 跳过;Redis 故障只 log
    不影响交付(响应数字退回静态判定,非交付路径)。"""
    try:
        wrote = int(await redis.eval(
            _LUA_WRITEBACK_LIVP_RAW, 1, batch_job_record_key(user_id, key), int(count),
        ))
    except Exception as e:
        log.warning("batch zip livp raw writeback error user=%s key=%s err=%s", user_id, key, e)
        return False
    if wrote != 1:
        log.info("batch zip job record expired, livp raw writeback skipped user=%s key=%s",
                 user_id, key)
    return wrote == 1


# ─── 临时目录管理(延迟清理 + 启动清扫)────────────────────────────────────────
def _rmtree_quiet(path: Path) -> None:
    shutil.rmtree(path, ignore_errors=True)


def _deferred_cleanup(tmpdir: Path) -> None:
    """job 返回后延迟清理临时目录。

    不做 finally 立即 rmtree:job 返回后产物文件仍需可读取/观测(上传完成 ≠ 消费方
    立刻用完,测试契约亦在 job 返回后读取产物);60s 后由事件循环删除,磁盘占用仍有界;
    进程死亡(定时器随进程消失)的残留由下次 job 启动时的 _prune_stale_tmp 兜底。
    """
    try:
        asyncio.get_running_loop().call_later(_TMP_CLEANUP_DELAY_S, _rmtree_quiet, tmpdir)
    except RuntimeError:  # 无运行中事件循环(极端):同步清理兜底
        _rmtree_quiet(tmpdir)


def _prune_stale_tmp(max_age_s: float = _TMP_PRUNE_AGE_S) -> None:
    """清扫进程崩溃残留的 batchzip-* 临时目录(mtime 超龄才删,防误删并发在跑目录)。"""
    now = time.time()
    for p in Path(tempfile.gettempdir()).glob("batchzip-*"):
        try:
            if p.is_dir() and now - p.stat().st_mtime > max_age_s:
                _rmtree_quiet(p)
        except OSError:
            continue


async def _await_inflight_grace() -> None:
    """finally shield 宽限:等在途线程收尾(有界 _GRACE_S;残余僵尸为已知限制)。"""
    pending = [f for f in _INFLIGHT if not f.done()]
    if not pending:
        return
    try:
        async with asyncio.timeout(_GRACE_S):
            await asyncio.shield(asyncio.wait(pending))
    except (TimeoutError, asyncio.CancelledError):
        log.warning(
            "batch zip grace expiry, %d in-flight thread(s) abandoned", len(pending),
        )


# ─── zip 条目写入(流式 + force_zip64 + ZIP_STORED + Windows 风格去重)──────────
def _write_zip_entry(zf: zipfile.ZipFile, name: str, src: Any) -> None:
    """单条目流式写入:zf.open(zinfo, "w", force_zip64=True) + copyfileobj。

    force_zip64 必传:流式写入大小未知,单条目 >4GiB(zipfile.ZIP64_LIMIT)不带它
    必炸,而「单文件 >1GB 属常态」下单条 >4GB 的视频原片完全可能(§6.2)。
    """
    zinfo = zipfile.ZipInfo(filename=name, date_time=time.localtime()[:6])
    zinfo.compress_type = zipfile.ZIP_STORED   # 条目全为已压缩媒体,deflate 白烧 CPU
    zinfo.external_attr = 0o644 << 16
    with zf.open(zinfo, "w", force_zip64=True) as dst:
        shutil.copyfileobj(src, dst, _COPY_CHUNK)


def _dedupe_entry_name(name: str, used: set[str]) -> str:
    """Windows 风格重名去重:IMG_0001.jpg → IMG_0001 (1).jpg(不同夹同名文件很常见)。"""
    if name not in used:
        used.add(name)
        return name
    stem, ext = os.path.splitext(name)
    n = 1
    while True:
        candidate = f"{stem} ({n}){ext}"
        if candidate not in used:
            used.add(candidate)
            return candidate
        n += 1


class _BatchZipFailure(RuntimeError):
    """打包 job 的收尾性失败(写 batchzip:fail:{key},衔接端点 failed/retry 通道)。"""


# ─── 打包 job(F10)────────────────────────────────────────────────────────────
async def generate_batch_download_zip(
    ctx: dict,
    user_id: str,
    job_token: str,
    *asset_ids_and_target: Any,
    bucket: str | None = None,
    key: str | None = None,
) -> dict[str, Any]:
    """批量打包 job:逐资产拉流 → 单 zip(ZIP_STORED/force_zip64)→ multipart 回传
    `derivatives/batch/{key}.zip`。锁/闸/失败标记语义见模块 docstring。

    入参双形态归一(直调/测试为 `(…, [ids], bucket, key)`,arq 派发为扁平
    `(…, id1…idN, bucket, key)`):bucket/key 兼容位置尾参与 kw 两种传递,ids 兼容
    单 list 与扁平多参。
    """
    settings = get_settings()
    sm = get_sessionmaker()
    redis = ctx["redis"]
    user_id = str(user_id)
    token = str(job_token)

    tail = list(asset_ids_and_target)
    if bucket is None and key is None:
        if len(tail) < 2:
            raise TypeError(
                "generate_batch_download_zip 需要 (…, [ids], bucket, key) 或 (…, id…, bucket, key)",
            )
        key = str(tail.pop())
        bucket = str(tail.pop())
    asset_ids: list[str] = []
    for item in tail:
        if isinstance(item, (list, tuple)):
            asset_ids.extend(str(x) for x in item)
        else:
            asset_ids.append(str(item))
    if not asset_ids:
        return {"status": "no_ids", "key": key}

    # 1) 执行开始 Lua 续期两键(值含本 job_token 才续,以执行时刻重置 TTL):满载
    #    排队时静态 TTL 撑不住执行期。失主(满载排队期 TTL 过期、同 key 已被后继
    #    job 落新闸)按「锁已易主」快速收尾 —— 只 log 不写失败标记(后继正持锁打包,
    #    失败语义归 token 持有者;写标记会让端点在后继完成前误报 failed)。
    try:
        renewed = await renew_batch_locks(redis, user_id, key, token)
    except Exception as e:
        log.warning("batch zip lock renew error (proceed) user=%s key=%s err=%s",
                    user_id, key, e)
        renewed = 1
    if renewed != 1:
        log.warning("batch zip lock lost at start (successor owns) user=%s key=%s",
                    user_id, key)
        return {"status": "lock_lost", "key": key}

    # 2) 打包并发信号量 ≤2(模块级,单进程语义),acquire 限时 120s 超时快速失败
    #    (写失败标记,不烧 1800s job 预算)
    try:
        async with asyncio.timeout(_SEMAPHORE_WAIT_S):
            await _PACK_SEMAPHORE.acquire()
    except TimeoutError:
        log.warning("batch zip semaphore wait timeout (>=%ss) key=%s", _SEMAPHORE_WAIT_S, key)
        await _finish_failure(redis, user_id, key, token, TimeoutError("semaphore wait"))
        return {"status": "failed", "key": key, "error": "semaphore_wait_timeout"}

    try:
        return await _pack_and_upload(
            redis, sm, settings, user_id, token, asset_ids, str(bucket), str(key),
        )
    finally:
        _PACK_SEMAPHORE.release()


async def _finish_failure(redis: Any, user_id: str, key: str, token: str, err: BaseException) -> None:
    """失败收尾:DEL 两键(值匹配才删)+ SET batchzip:fail:{key} EX 600。

    锁已易主(值不匹配)→ 失败语义归 token 持有者,不写失败标记(端点在后继完成前
    不得误报 failed)。
    """
    lost = False
    try:
        lost = await release_batch_locks(redis, user_id, key, token) == 0
    except Exception as e:
        log.warning("batch zip unlock error on failure key=%s err=%s", key, e)
    if lost:
        log.warning("batch zip fail marker skipped (lock re-owned) user=%s key=%s", user_id, key)
        return
    try:
        await redis.set(batch_fail_key(key), type(err).__name__[:64], ex=FAIL_TTL)
    except Exception as e:
        log.warning("batch zip fail marker write error key=%s err=%s", key, e)


async def _pack_and_upload(
    redis: Any,
    sm: Any,
    settings: Any,
    user_id: str,
    token: str,
    asset_ids: list[str],
    bucket: str,
    key: str,
) -> dict[str, Any]:
    # 懒 import:workers.main 顶部拉 PIL/arq,API 进程 import 本模块(端点共用件)
    # 时不付这份重量;job 进程内为常驻模块,仅首次查找有开销
    from app.workers.main import _livp_download_base_name, _pick_livp_entries

    s3 = boto3.client(
        "s3",
        endpoint_url=settings.minio_endpoint_internal,
        aws_access_key_id=settings.minio_access_key,
        aws_secret_access_key=settings.minio_secret_key,
        config=Config(signature_version="s3v4", region_name="us-east-1"),
    )
    await _to_thread(_prune_stale_tmp)
    tmpdir = Path(tempfile.mkdtemp(prefix=f"batchzip-{key}-"))
    zip_path = tmpdir / f"batch-{key}.zip"
    # job 自管 deadline(逐资产循环检查剩余时间,余量不足自行按失败收尾,不指望外层取消)
    deadline = time.monotonic() + _JOB_TIME_BUDGET_S
    written = 0
    livp_raw = 0
    obj_key = batch_object_key(key)
    try:
        async with sm() as db:
            with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_STORED, allowZip64=True) as zf:
                used: set[str] = set()
                for aid in asset_ids:
                    if time.monotonic() > deadline:
                        raise _BatchZipFailure(
                            f"打包截止时间已到(已入包 {written} 项,余量不足)"
                        )
                    # 逐资产重查行,以重查行的当前 minio_key 为唯一事实拉流(enqueue
                    # 到执行隔数分钟,资产可能被软删/purge/移动);行删 → 跳过不崩 job
                    row = await db.get(Asset, uuid.UUID(aid))
                    if row is None or row.deleted_at is not None:
                        log.info("batch zip skip vanished asset=%s key=%s", aid, key)
                        continue
                    n, raw = await _append_asset(
                        zf, s3, row, tmpdir, used,
                        _livp_download_base_name, _pick_livp_entries,
                    )
                    written += n
                    livp_raw += raw
        if written == 0:
            # 有效条目为 0(全选集在打包途中被软删/purge)→ 不产出空 zip,按失败收尾
            raise _BatchZipFailure("有效条目为 0(选集在打包途中全部被删/不存在)")
        contained = allowed_digest(asset_ids)
        extra: dict[str, Any] = {
            "ContentType": "application/zip",
            # kind 同时是 §6.3 清理 cron 的删除守卫;允许集摘要降为观测字段
            "Metadata": {"kind": BATCH_ZIP_KIND, "contained-sha256": contained},
        }
        config = TransferConfig(multipart_threshold=_MULTIPART_THRESHOLD)
        # boto3 managed transfer 自动分片(Metadata/ContentType 必须经 ExtraArgs 传,
        # 挂 upload_file 顶层是 TypeError;S3/MinIO 单次 put_object 有 5GiB 硬限)
        await _to_thread(
            s3.upload_file, str(zip_path), bucket, obj_key,
            ExtraArgs=extra, Config=config,
        )
    except BaseException as e:
        # 取消(arq timeout)时 to_thread 线程继续跑:先 shield 宽限等在途线程,
        # 再收尾(删在线程脚下的目录 / 僵尸不持信号量击穿临时盘核算,均由宽限缓解)
        await _await_inflight_grace()
        await _finish_failure(redis, user_id, key, token, e)
        _deferred_cleanup(tmpdir)
        if isinstance(e, asyncio.CancelledError):
            raise
        log.exception("batch zip failed key=%s err=%s", key, e)
        return {"status": "failed", "key": key, "error": type(e).__name__, "entries": written}

    # 成功:实际 livp_raw_count 回写作业记录(定稿 §6.2 第 6 步:ready 响应以 job
    # 实际打包计数为准 —— 轮询期 livp 衍生物就绪位翻转时,首响应的 tags 静态判定值
    # 与实际包内容有偏差);记录已过期由回写自身跳过。先于清锁(锁易主也不回滚交付)
    await writeback_livp_raw_count(redis, user_id, key, livp_raw)
    # DEL 两键(值匹配才删;易主只 log,不误删后继的新 token 锁)
    try:
        released = await release_batch_locks(redis, user_id, key, token)
    except Exception as e:
        log.warning("batch zip unlock error key=%s err=%s", key, e)
        released = 1
    if released == 0:
        log.warning("batch zip unlock skipped (lock re-owned) user=%s key=%s", user_id, key)
    _deferred_cleanup(tmpdir)
    log.info("batch zip done key=%s bucket=%s entries=%d livp_raw=%d obj=%s",
             key, bucket, written, livp_raw, obj_key)
    return {"status": "ok", "key": key, "object_key": obj_key, "entries": written}


async def _append_asset(
    zf: zipfile.ZipFile,
    s3: Any,
    row: Any,
    tmpdir: Path,
    used: set[str],
    base_name_fn: Any,
    pick_fn: Any,
) -> tuple[int, int]:
    """单资产入包,返回 (写入条目数, livp 原始兜底位)。livp 就绪 → 解开衍生物取
    成员重写内名;衍生物对象缺失/未就绪 → 原始 .livp 条目兜底(不炸整个 batch job),
    兜底位计 1 —— job 实际 livp_raw_count 的计数源(定稿 §6.2 第 6 步回写用)。"""
    filename = row.filename or ""
    aid = str(row.id)
    tags = row.tags or {}
    if filename.lower().endswith(".livp"):
        dl_key = tags.get("download_zip_key")
        ready = bool(dl_key) and not tags.get("download_zip_failed")
        if ready:
            try:
                return (
                    await _append_livp_members(
                        zf, s3, row, str(dl_key), tmpdir, used, base_name_fn, pick_fn,
                    ),
                    0,
                )
            except Exception as e:
                log.warning(
                    "batch zip livp derivative fallback to raw asset=%s key=%s err=%s",
                    aid, dl_key, e,
                )
        return (
            await _append_stream_entry(zf, s3, row.minio_bucket, row.minio_key,
                                       _dedupe_entry_name(base_name_fn(filename, aid), used)),
            1,
        )
    return (
        await _append_stream_entry(zf, s3, row.minio_bucket, row.minio_key,
                                   _dedupe_entry_name(base_name_fn(filename, aid), used)),
        0,
    )


async def _append_stream_entry(zf: zipfile.ZipFile, s3: Any, bucket: Any, key: Any, name: str) -> int:
    """普通资产(含 >1GB 视频原片):get_object 流式拷入。NoSuchKey(打包途中被
    purge)跳过计 0,其余异常向上(job 失败收尾)。"""

    def _job() -> int:
        resp = s3.get_object(Bucket=bucket, Key=key)
        _write_zip_entry(zf, name, resp["Body"])
        return 1

    try:
        return await _to_thread(_job)
    except ClientError as e:
        code = str(e.response.get("Error", {}).get("Code", ""))
        if code in ("NoSuchKey", "404"):
            log.warning("batch zip object missing, skip bucket=%s key=%s", bucket, key)
            return 0
        raise


async def _append_livp_members(
    zf: zipfile.ZipFile,
    s3: Any,
    row: Any,
    dl_key: str,
    tmpdir: Path,
    used: set[str],
    base_name_fn: Any,
    pick_fn: Any,
) -> int:
    """livp 就绪:解开 derivatives/{id}/livp.zip 取(最大静态图, 最大视频)成员,
    按批量包自己的清洗/去重规则重写内名后写入 —— 不是把 livp.zip 整体塞入(那会把
    「解出来还是 zip 套 zip」的原始问题搬进批量包)。无可用成员 → 抛错由调用方回落
    原始 .livp(此时批量 zip 尚未写入任何条目,无半条目污染)。"""
    dpath = tmpdir / f"deriv-{row.id}.zip"

    def _fetch() -> None:
        with open(dpath, "wb") as f:
            s3.download_fileobj(row.minio_bucket, dl_key, f)

    await _to_thread(_fetch)
    base = base_name_fn(row.filename or "", str(row.id))

    def _write_members() -> int:
        written = 0
        with zipfile.ZipFile(dpath) as zd:
            still, video = pick_fn(zd)
            for info, suffix in ((still, ".jpg"), (video, ".mp4")):
                if info is None:
                    continue
                # used 去重集在本协程 await 期间独占,executor 单线程内变更安全
                name = _dedupe_entry_name(f"{base}{suffix}", used)
                with zd.open(info) as src:
                    _write_zip_entry(zf, name, src)
                written += 1
        return written

    n = await _to_thread(_write_members)
    if n == 0:
        raise _BatchZipFailure("livp 衍生物内无可用成员(jpg/heic/png + mov/mp4)")
    return n


# ─── 清理 cron(F11)───────────────────────────────────────────────────────────
async def cleanup_batch_zips(ctx: dict) -> dict[str, Any]:
    """批量包清理(每 10 分钟;per-cron timeout=300):统一 6h 保留期。

    list_buckets() 迭代全部桶(不用 projects 表 —— 项目逻辑删后其桶会漏)→
    list_objects_v2(prefix="derivatives/batch/")处理 IsTruncated 分页 → key 形态
    粗筛 ^[0-9a-f]{16}\\.zip$(用户自建 derivatives/batch 夹内大量原片免掉 head 放大)
    → LastModified >6h → head 校验 Metadata.kind == batch_download_zip 才删:
    无守卫的「按前缀 + 年龄删」会误删用户原片;derivatives/{asset_id}/livp.zip
    永久衍生物跟宿主 purge,绝不波及。
    """
    settings = get_settings()
    s3 = boto3.client(
        "s3",
        endpoint_url=settings.minio_endpoint_internal,
        aws_access_key_id=settings.minio_access_key,
        aws_secret_access_key=settings.minio_secret_key,
        config=Config(signature_version="s3v4", region_name="us-east-1"),
    )
    now = datetime.now(UTC)
    scanned = 0
    deleted = 0
    try:
        listed = await _to_thread(s3.list_buckets)
    except Exception as e:
        log.warning("cleanup_batch_zips list_buckets fail err=%s", e)
        return {"scanned": 0, "deleted": 0, "error": type(e).__name__}
    for b in listed.get("Buckets", []):
        bname = b.get("Name")
        if not bname:
            continue
        token: str | None = None
        while True:
            # 不传 MaxKeys(boto3/S3 默认 1000);IsTruncated/ContinuationToken
            # 分页循环照常处理,页宽由调用参数/测试侧自行决定
            kw: dict[str, Any] = {"Bucket": bname, "Prefix": BATCH_ZIP_PREFIX}
            if token:
                kw["ContinuationToken"] = token
            resp = await _to_thread(s3.list_objects_v2, **kw)
            token = None
            for obj in resp.get("Contents", []):
                scanned += 1
                okey = obj.get("Key") or ""
                rel = okey[len(BATCH_ZIP_PREFIX):] if okey.startswith(BATCH_ZIP_PREFIX) else okey
                if not _BATCH_OBJ_RE.fullmatch(rel):
                    continue  # 形态粗筛:非批量包形态不 head 不删
                lm = obj.get("LastModified")
                if lm is None or now - lm <= _BATCH_RETENTION:
                    continue  # 未超龄(cron 10 分钟粒度,可能扫到未满 6h 的对象)
                try:
                    head = await _to_thread(s3.head_object, Bucket=bname, Key=okey)
                except Exception as e:
                    log.warning("cleanup_batch_zips head fail bucket=%s key=%s err=%s",
                                bname, okey, e)
                    continue
                if (head.get("Metadata") or {}).get("kind") != BATCH_ZIP_KIND:
                    continue  # 元数据守卫:同前缀同形态的用户对象不删
                try:
                    await _to_thread(s3.delete_object, Bucket=bname, Key=okey)
                    deleted += 1
                except Exception as e:
                    log.warning("cleanup_batch_zips delete fail bucket=%s key=%s err=%s",
                                bname, okey, e)
            if not resp.get("IsTruncated"):
                break
            token = resp.get("NextContinuationToken")
            if not token:
                break
    if deleted:
        log.info("cleanup_batch_zips scanned=%d deleted=%d", scanned, deleted)
    return {"scanned": scanned, "deleted": deleted}
