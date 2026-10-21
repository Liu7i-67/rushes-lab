"""批量下载单 zip 化 — batch-download-link 端点 + 异步打包 job + 清理 cron 契约测试(F9/F10/F11 + F7 写点)。

对应需求文档(唯一依据):docs/qdev/2026-10-21-livp-download-unpack.md「测试功能点」
权威方案:rushes-spec/material-storage/livp-download-unpack-plan.md §6.2/§6.3/§10。

设施沿用仓库单元测试惯例(test_download_attachment.py 直调 endpoint + stub 依赖;
test_livp.py 纯离线;不连真 DB / OpenFGA / MinIO / Redis / arq)。worker 与 cron
直调 job 函数,boto3/get_sessionmaker/get_settings 以模块属性打桩。

Seam 说明(契约钉死 / 仓库惯例假设):
  - 端点:POST /api/v1/assets/batch-download-link(契约钉死);handler 函数名
    定稿未钉死 —— 经 router 路由表按路径解析,函数名无关;入参模型
    BatchDownloadLinkIn(asset_ids 1..100 / as_attachment / resume_key / retry)
    契约钉死(定稿 §6.2);arq pool/redis 走 request.app.state(上传派发点惯例)
    或同名形参注入,两者都兜住;
  - redis 替身按契约语义实现三段 Lua:两键(keygate+active)NX 原子落 /
    token 匹配续期 / token 匹配 DEL —— eval 参数布局按「batchzip:* 键名 +
    token + TTL」启发式识别,若实现布局不同会在对应用例显式失败(契约闸);
  - worker:app.workers.batch_download.generate_batch_download_zip(
    ctx, user_id, job_token, asset_ids, bucket, key)与 cron cleanup_batch_zips
    契约钉死;模块 `import boto3` / `from app.db.session import get_sessionmaker`
    按仓库惯例(workers/main.py 同款)打桩;
  - presign.head_object:F6 扩展返回 Metadata(dict);缺失以 ClientError 404 模拟;
  - force_zip64 断言为格式级:force_zip64=True 写入的条目 version needed 置 45
    (实测钉死:普通 writestr 小条目为 20),断言全部条目 ≥45 即证明
    `zf.open(zinfo, "w", force_zip64=True)`,免真实 4GB。

测试函数 → 需求文档「测试功能点」映射(PM 验收对照):
  batch 端点(定稿 §10 batch-download-link 组)
    部分无权限 → skipped_no_permission 只含 id(响应无文件名,防侧信道)+
        首次逐条 download_denied 审计(SETNX 去重,轮询不重写)+ enqueue
        epoch _job_id + 入参带 bucket/token
                                    → test_partial_permission_skips_ids_only_and_audits_once
    全无权限 → 403 且不入队          → test_all_denied_403_no_enqueue
    全不存在 → 400                   → test_all_missing_400
    跨桶选集 → 400(同桶断言)      → test_cross_bucket_selection_400
    单个 >10GB → 400 单文件文案     → test_single_file_over_limit_400_single_file_copy
    合计 >10GB → 400 合计文案       → test_aggregate_over_limit_400_batch_copy
    livp x3 折算击穿合计上限(等量非 livp 不击穿)
                                    → test_livp_weighting_x3_trips_limit_and_control_passes
    >100 个 → 422(入参约束;100 边界放行)
                                    → test_over_100_ids_422_and_boundary_100_ok
    异 key 锁占用 → 429 且不入队    → test_cross_key_lock_429_no_enqueue
    同 key 二次 POST(resume)不重入队(锁即去重闸)
                                    → test_same_key_second_post_no_reenqueue
    跨用户同 key 打包期撞 per-key 闸 → packing + retry_after_seconds,不双跑
                                    → test_keygate_cross_user_packing_with_retry_after
    失败标记 → failed 不入队;retry:true 清标记重派
                                    → test_fail_marker_failed_then_retry_redispatches
    canonical:同集不同序同 key      → test_canonical_same_set_any_order_same_key
    canonical:含重复 id 同 key(并入上一条)
    resume ids 不符 → 400            → test_resume_mismatched_ids_400
    跨用户拿别人 key resume → 400    → test_resume_cross_user_400
    带 skipped 项 resume 不 400、不触发全量 FGA 复检、filename/skipped 回放一致
                                    → test_resume_with_skipped_items_ok_and_no_fga_recheck
    ready TTL = min(21600, 21600-age) 收缩 + 单条聚合审计 + packing 不审计
                                    → test_ready_ttl_shrinks_by_object_age
    age ≥ 6h 按 miss 重新生成(epoch _job_id 变化)
                                    → test_object_older_than_6h_treated_as_miss_regenerates
    缓存分 key:权限不同 key 不同   → test_permission_sets_split_keys
    同权限集共享缓存(第二次秒回 ready)+ 重签审计
                                    → test_same_permission_users_share_cache_ready
  打包 job(F10)
    执行开始 Lua 续期两键(值含本 token,先于取流;TTL 重置)
                                    → test_worker_renews_locks_at_start_before_first_fetch
    成功路径:multipart upload_file(非 put_object)+ ExtraArgs
    {ContentType, Metadata{kind, contained-sha256}} + TransferConfig 分片 +
    livp 解包成员入包(非嵌套 zip)+ finally 清锁无失败标记
                                    → test_worker_success_multipart_extraargs_unlock_and_livp_members
    流式写入 force_zip64(全部条目 version needed ≥45)
                                    → test_worker_force_zip64_on_every_local_header
    有效条目 0 → 失败收尾写 batchzip:fail:{key} 且清锁不出包
                                    → test_worker_zero_valid_entries_fails_with_marker
    finally 值匹配才删:中途易主的新 token 锁不被旧 job 误删
                                    → test_worker_finally_does_not_clobber_successor_lock
    注册:max_tries=1 / timeout=1800;cron cleanup_batch_zips 注册
                                    → test_batch_job_and_cron_registration
  清理 cron(F11)
    形态粗筛 + Metadata kind 守卫 + 6h 龄 + 分页 + 不波及
    derivatives/{asset_id}/livp.zip → test_cron_cleanup_shape_metadata_guard_pagination
  tags 写点(F7)
    tags 合并写点(共享 helper _merge_asset_tags,双 writer 共用)= jsonb_set(tags …)
    单条 UPDATE,表达式锚定列本身、路径级合并,对方 job 的 key 不丢
                                    → test_merge_asset_tags_jsonb_set_atomic_no_foreign_key_loss
    同 key 同时 set/remove 显式报错 → test_merge_asset_tags_rejects_same_key_set_and_remove
  遗留缺口补测(2026-10-21,编号对应测试任务清单 A1-A7)
    A1 信号量 acquire 限时超时快速失败(写 fail 标记 / 清锁 / 不打包)
                                    → test_worker_semaphore_wait_timeout_fast_fails_with_marker
    A2 resume 期权限整体回收 → ready 复检全 denied 403(不签 URL 不写签发审计)
                                    → test_resume_ready_recheck_all_denied_403_no_sign_audit
    A3 key 收敛:就绪位翻转致应然 key ≠ resume_key
      新 key head 命中 → 直签 ready + 现算回放补写记录
                                    → test_resume_key_convergence_new_key_head_hit_ready_backfill
      新 key miss → 重新入队(新记录新 key)
                                    → test_resume_key_convergence_new_key_miss_reenqueues
    A4 批量包内同名 Windows 风格 (1) 去重
                                    → test_dedupe_entry_name_windows_style
                                    → test_worker_dedupes_same_name_entries_windows_style
    A5 打包途中软删/行消失跳过;移动后按重查行当前 minio_key 入包
                                    → test_worker_skips_soft_deleted_and_vanished_rows_mid_pack
                                    → test_worker_uses_current_minio_key_of_requeried_row
    A6 audited 去重键契约(按选中集摘要分键,全 denied 常量 key 场景各自首评)
                                    → test_audited_key_shape_is_selection_scoped
                                    → test_all_denied_selections_each_get_first_evaluation
    A7 P3-1 回写契约(Lua 语义)+ ready 响应 actual 优先/静态回落
                                    → test_writeback_livp_raw_count_lua_semantics_merge_keeps_ttl
                                    → test_writeback_livp_raw_count_expired_record_not_revived
                                    → test_writeback_livp_raw_count_redis_error_returns_false
                                    → test_ready_response_prefers_livp_raw_count_actual
"""
from __future__ import annotations

import hashlib
import inspect
import io
import json
import re
import time
import uuid
import zipfile
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace
from typing import Any

import pytest
from botocore.exceptions import ClientError
from fastapi import HTTPException
from pydantic import ValidationError
from starlette.requests import Request

from app.db.tables import Asset, Folder, Project
from app.routers.assets import BatchDownloadLinkIn
from app.routers.assets import router as assets_router
from app.settings import Settings
from app.workers.batch_download import (
    _dedupe_entry_name,
    batch_audited_key,
    batch_job_record_key,
    batch_object_key,
    cleanup_batch_zips,
    compute_batch_key,
    generate_batch_download_zip,
    writeback_livp_raw_count,
)
from app.workers.main import WorkerSettings

# ─── 常量(契约值)─────────────────────────────────────────────────────────────
TTL_FULL = 21600                    # 6h 保留期对应的 URL 满额秒数
KEYGATE_TTL = 2400                  # 两键 TTL(崩溃兜底)
GiB = 1024 ** 3
BATCH_ZIP_PREFIX = "derivatives/batch/"


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


def mk_user(tag: str) -> SimpleNamespace:
    return SimpleNamespace(id=uuid.uuid4(), subject=f"user:{tag}")


def mk_batch_asset(
    filename: str,
    *,
    size: int = 1024,
    bucket: str = "ms-proj",
    tags: dict[str, Any] | None = None,
) -> SimpleNamespace:
    aid = uuid.uuid4()
    return SimpleNamespace(
        id=aid,
        deleted_at=None,
        filename=filename,
        folder_id=uuid.uuid4(),
        minio_bucket=bucket,
        minio_key=f"folder-a/{filename}",
        size_bytes=size,
        content_type="application/octet-stream",
        tags=tags if tags is not None else {},
    )


def fld(obj: Any, name: str) -> Any:
    """响应字段读取(直调端点返回 pydantic 模型或 dict,两种都兜住)。"""
    if isinstance(obj, dict):
        return obj.get(name)
    return getattr(obj, name)


def dump_json(out: Any) -> str:
    if hasattr(out, "model_dump_json"):
        return out.model_dump_json()
    return json.dumps(out, default=str, ensure_ascii=False)


def zip_object_key_candidates(key: str) -> list[str]:
    """response key → 可能的 zip 对象 key 形态(response key 是裸哈希还是带前后缀,
    定稿未钉死;三个候选都喂给 head 替身,断言只依赖 key 本身)。"""
    return [key, f"{BATCH_ZIP_PREFIX}{key}.zip", f"{BATCH_ZIP_PREFIX}{key}"]


# ─── redis / arq pool 替身 ────────────────────────────────────────────────────
class FakeRedis:
    """redis.asyncio.Redis 替身:str 值 + 惰性过期;eval 按契约语义模拟三段 Lua。

    识别规则(keys_and_args 内):
      - 同含 batchzip:keygate:* 与 batchzip:active:* → 两键 NX 原子落:任一已存在
        整体失败返 0;首个非键名 str 视作 token(值拼接 token),首个 int 视作 TTL;
      - 单 batchzip:* 键 + token → 值含 token 才生效;带 int TTL = 续期,否则 = DEL
        (契约:续期重置 TTL;DEL 一律值匹配才删)。
    """

    def __init__(self, ops: list[tuple] | None = None) -> None:
        self.store: dict[str, tuple[str, float]] = {}
        self.ops = ops if ops is not None else []
        self.eval_calls: list[tuple] = []
        self.deleted: list[str] = []

    def seed(self, name: str, value: str, ttl: int = 600) -> None:
        self.store[name] = (str(value), time.time() + ttl)

    def forget(self, *names: str) -> None:
        for n in names:
            self.store.pop(n, None)

    def alive(self, name: str) -> bool:
        item = self.store.get(name)
        return item is not None and item[1] > time.time()

    async def get(self, name: str) -> str | None:
        item = self.store.get(name)
        if item is None:
            return None
        if item[1] <= time.time():
            self.store.pop(name, None)
            return None
        return item[0]

    async def set(
        self, name: str, value: Any, *, ex: int | None = None, nx: bool = False, **kw: Any
    ) -> bool | None:
        self.ops.append(("set", name))
        if nx and self.alive(name):
            return None
        self.store[name] = (str(value), time.time() + (ex or 0))
        return True

    async def setex(self, name: str, ttl: int, value: Any) -> bool:
        self.store[name] = (str(value), time.time() + ttl)
        return True

    async def delete(self, *names: str) -> int:
        n = 0
        for name in names:
            if self.store.pop(name, None) is not None:
                n += 1
                self.deleted.append(name)
        return n

    async def exists(self, *names: str) -> int:
        return sum(1 for n in names if self.alive(n))

    async def ttl(self, name: str) -> int:
        item = self.store.get(name)
        if item is None:
            return -2
        return max(0, int(item[1] - time.time()))

    async def pttl(self, name: str) -> int:
        item = self.store.get(name)
        if item is None:
            return -2
        return max(0, int((item[1] - time.time()) * 1000))

    async def eval(self, script: Any, numkeys: int = 0, *keys_and_args: Any, **kw: Any) -> int:
        self.ops.append(("eval", tuple(str(a) if isinstance(a, str) else a for a in keys_and_args)))
        self.eval_calls.append(tuple(keys_and_args))
        strs = [a for a in keys_and_args if isinstance(a, str)]
        names = [a for a in strs if a.startswith("batchzip:")]
        rest = [a for a in strs if not a.startswith("batchzip:")]
        nums = [int(a) for a in keys_and_args if isinstance(a, int) and not isinstance(a, bool)]
        gate = next((n for n in names if ":keygate:" in n), None)
        active = next((n for n in names if ":active:" in n), None)
        # token 取最后一个非键名 str:兼容 ARGV=(key, token) / (key:token) / (token)
        token = rest[-1] if rest else ""
        ttl = nums[0] if nums else None
        if gate and active:
            g, a = self.store.get(gate), self.store.get(active)
            if g is None or a is None:
                # NX 原子落:任一键已存在(且活着)→ 整体失败
                if self.alive(gate) or self.alive(active):
                    return 0
                stamp = time.time() + (ttl or KEYGATE_TTL)
                value = ":".join(rest)
                self.store[gate] = (value, stamp)
                self.store[active] = (value, stamp)
                return 1
            # 两键已在:按「值含 token 才生效」判 —— 带 TTL = 续期,无 TTL = DEL
            if token and not (token in g[0] and token in a[0]):
                return 0
            if ttl:
                stamp = time.time() + ttl
                self.store[gate] = (g[0], stamp)
                self.store[active] = (a[0], stamp)
            else:
                self.store.pop(gate, None)
                self.store.pop(active, None)
                self.deleted.extend([gate, active])
            return 1
        target = names[0] if names else None
        if target is None:
            return 0
        cur = self.store.get(target)
        if cur is None:
            return 0
        if token and token not in cur[0]:
            return 0
        if ttl:
            self.store[target] = (cur[0], time.time() + ttl)   # 续期:以执行时刻重置
        else:
            self.store.pop(target, None)                        # DEL:值匹配才删
            self.deleted.append(target)
        return 1


class FakeArqPool:
    """arq pool 替身:记录 enqueue_job(function, *args, **kwargs)。"""

    def __init__(self) -> None:
        self.enqueued: list[dict[str, Any]] = []

    async def enqueue_job(self, function: str, *args: Any, **kwargs: Any) -> Any:
        self.enqueued.append({"function": function, "args": args, "kwargs": kwargs})
        return SimpleNamespace(job_id=kwargs.get("_job_id"))


# ─── db / 权限 / 审计 / presign 替身 ──────────────────────────────────────────
class FakeResult:
    def __init__(self, rows: list[Any]) -> None:
        self._rows = list(rows)

    def scalars(self) -> FakeResult:
        return self

    def all(self) -> list[Any]:
        return list(self._rows)

    def first(self) -> Any | None:
        return self._rows[0] if self._rows else None

    def scalar(self) -> Any | None:
        return self._rows[0] if self._rows else None

    def scalar_one_or_none(self) -> Any | None:
        return self._rows[0] if self._rows else None

    def unique(self) -> FakeResult:
        return self


class FakeDB:
    """端点用 db 替身:get 按 Asset/Folder/Project 分派;execute 返回预置资产行
    (「单条 SELECT … WHERE id IN」口径 —— 不在预置集 = 不存在/已软删)。"""

    def __init__(self, assets: list[Any]) -> None:
        self._assets = {a.id: a for a in assets}
        self.executed: list[Any] = []

    async def get(self, model: Any, pk: Any) -> Any | None:
        if model is Asset:
            return self._assets.get(pk)
        if model is Folder:
            return SimpleNamespace(id=pk, project_id=uuid.uuid4())
        if model is Project:
            return SimpleNamespace(id=pk, minio_bucket="ms-proj")
        return None

    async def execute(self, stmt: Any, *a: Any, **kw: Any) -> FakeResult:
        self.executed.append(stmt)
        return FakeResult(list(self._assets.values()))

    async def scalar(self, stmt: Any, *a: Any, **kw: Any) -> Any | None:
        self.executed.append(stmt)
        return FakeResult(list(self._assets.values())).scalar()


class StubPermissions:
    """FGA 替身:拒绝集按 user_subject 区分 —— 世界级共享实例下多用户各自语义正确
    (默认拒绝集兜底,denied_by_subject 覆盖特例,同权限异用户才可能同 key);
    checks 记录每次 check 的 object_id,供「轮询不新增 FGA 复检」断言。"""

    def __init__(
        self,
        denied_ids: Any = (),
        *,
        denied_by_subject: dict[str, Any] | None = None,
    ) -> None:
        self.denied = {str(x) for x in denied_ids}
        self.denied_by_subject: dict[str, set[str]] = {
            str(subj): {str(x) for x in ids}
            for subj, ids in (denied_by_subject or {}).items()
        }
        self.checks: list[str] = []

    def denied_for(self, user_subject: Any) -> set[str]:
        return self.denied_by_subject.get(str(user_subject), self.denied)

    async def check(self, **kw: Any) -> bool:
        oid = str(kw.get("object_id", ""))
        self.checks.append(oid)
        return oid not in self.denied_for(kw.get("user_subject"))


class StubAudit:
    def __init__(self) -> None:
        self.events: list[dict[str, Any]] = []

    async def write(self, **kw: Any) -> None:
        self.events.append({"event_type": kw.get("event_type", "write"), **kw})

    async def signed_url_issued(self, **kw: Any) -> None:
        self.events.append({"event_type": "signed_url_issued", **kw})

    def of_type(self, event_type: str) -> list[dict[str, Any]]:
        return [e for e in self.events if e.get("event_type") == event_type]


class BatchPresign:
    """presign 替身:hits 为 key → LastModified;未命中抛 ClientError(404)= miss。"""

    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []
        self.head_calls: list[tuple[str, str]] = []
        self.hits: dict[str, datetime] = {}

    def hit(self, keys: list[str], *, age_seconds: int) -> None:
        lm = datetime.now(UTC) - timedelta(seconds=age_seconds)
        for k in keys:
            self.hits[k] = lm

    def head_object(self, bucket: str, key: str) -> dict[str, Any]:
        self.head_calls.append((bucket, key))
        lm = self.hits.get(key)
        if lm is None:
            raise ClientError({"Error": {"Code": "404", "Message": "Not Found"}}, "HeadObject")
        return {
            "size_bytes": 1,
            "content_type": "application/zip",
            "etag": "e",
            "version_id": None,
            "last_modified": lm,
            "metadata": {"kind": "batch_download_zip", "contained-sha256": "cafe"},  # F6
        }

    def sign_get_url(
        self,
        bucket: str,
        key: str,
        expires_seconds: int,
        response_content_disposition: str | None = None,
        request_base: str | None = None,
    ) -> str:
        self.calls.append({
            "bucket": bucket,
            "key": key,
            "expires_seconds": expires_seconds,
            "response_content_disposition": response_content_disposition,
            "request_base": request_base,
        })
        return f"https://minio.example/{bucket}/{key}?X-Amz-Signature=fake"


# ─── 端点直调(函数名无关:经路由表解析)───────────────────────────────────────
class BatchCall:
    def __init__(
        self,
        out: Any,
        audit: StubAudit,
        presign: BatchPresign,
        redis: FakeRedis,
        pool: FakeArqPool,
        permissions: StubPermissions,
    ) -> None:
        self.out = out
        self.audit = audit
        self.presign = presign
        self.redis = redis
        self.pool = pool
        self.permissions = permissions


def _batch_endpoint_fn() -> Any:
    for route in assets_router.routes:
        path = getattr(route, "path", "")
        methods = {str(m).upper() for m in (getattr(route, "methods", None) or set())}
        if path.endswith("/batch-download-link") and "POST" in methods:
            return route.endpoint
    raise LookupError(
        "路由 POST /api/v1/assets/batch-download-link 未注册 —— 批量侧端点代码未就位"
    )


def mk_request(pool: FakeArqPool | None, redis: FakeRedis | None) -> Request:
    app_obj = SimpleNamespace(state=SimpleNamespace(arq_pool=pool, redis=redis))
    return Request({
        "type": "http",
        "asgi": {"version": "3.0", "spec_version": "2.3"},
        "http_version": "1.1",
        "method": "POST",
        "scheme": "http",
        "path": "/api/v1/assets/batch-download-link",
        "raw_path": b"/api/v1/assets/batch-download-link",
        "query_string": b"",
        "root_path": "",
        "server": ("testserver", 80),
        "client": ("127.0.0.1", 54321),
        "headers": [],
        "app": app_obj,
    })


async def call_batch(
    monkeypatch: pytest.MonkeyPatch,
    payload: BatchDownloadLinkIn,
    *,
    user: Any,
    assets: list[Any],
    denied_ids: Any = (),
    presign: BatchPresign | None = None,
    redis: FakeRedis | None = None,
    pool: FakeArqPool | None = None,
    audit: StubAudit | None = None,
    permissions: StubPermissions | None = None,
    is_system_admin: bool = False,
) -> BatchCall:
    """直调 batch 端点:按签名形参名/注解填 stub,不认识的必选形参显式报错。"""
    monkeypatch.setattr("app.routers.assets.get_settings", lambda: mk_settings())
    fn = _batch_endpoint_fn()
    try:
        from typing import get_type_hints

        hints: dict[str, Any] = get_type_hints(fn)
    except Exception:
        hints = {}
    permissions = permissions if permissions is not None else StubPermissions(denied_ids)
    presign = presign if presign is not None else BatchPresign()
    audit = audit if audit is not None else StubAudit()
    redis = redis if redis is not None else FakeRedis()
    pool = pool if pool is not None else FakeArqPool()
    kw: dict[str, Any] = {}
    for name, p in inspect.signature(fn).parameters.items():
        ann = hints.get(name, p.annotation)
        if name == "request":
            kw[name] = mk_request(pool, redis)
        elif ann is BatchDownloadLinkIn or name in ("data", "payload", "body"):
            kw[name] = payload
        elif name == "db":
            kw[name] = FakeDB(assets)
        elif name == "permissions":
            kw[name] = permissions
        elif name == "presign":
            kw[name] = presign
        elif name == "audit":
            kw[name] = audit
        elif name == "user":
            kw[name] = user
        elif name == "is_system_admin":
            kw[name] = is_system_admin
        elif name == "ctx":
            kw[name] = {"request_ip": "127.0.0.1", "user_agent": "pytest"}
        elif name in ("arq_pool", "pool"):
            kw[name] = pool
        elif name in ("redis", "redis_client"):
            kw[name] = redis
        elif p.default is inspect.Parameter.empty:
            raise LookupError(f"batch 端点出现无法满足的必选形参 {name!r}(seam 需对齐)")
    out = await fn(**kw)
    return BatchCall(out, audit, presign, redis, pool, permissions)


class BatchWorld:
    """单用例世界:一套 redis/pool/presign/audit/permissions,多次 POST 复用
    (轮询语义;permissions 世界级共享,checks 跨 POST 累积可断言)。"""

    def __init__(
        self,
        monkeypatch: pytest.MonkeyPatch,
        *,
        assets: list[Any],
        denied_ids: Any = (),
    ) -> None:
        self.monkeypatch = monkeypatch
        self.assets = list(assets)
        self.denied_ids = {str(x) for x in denied_ids}
        self.redis = FakeRedis()
        self.pool = FakeArqPool()
        self.presign = BatchPresign()
        self.audit = StubAudit()
        self.permissions = StubPermissions(self.denied_ids)
        self.user = mk_user("a")

    async def post(
        self,
        ids: list[Any],
        *,
        user: Any | None = None,
        resume_key: str | None = None,
        retry: bool = False,
        as_attachment: bool = False,
    ) -> BatchCall:
        payload = BatchDownloadLinkIn(
            asset_ids=list(ids),
            as_attachment=as_attachment,
            resume_key=resume_key,
            retry=retry,
        )
        return await call_batch(
            self.monkeypatch,
            payload,
            user=user or self.user,
            assets=self.assets,
            presign=self.presign,
            redis=self.redis,
            pool=self.pool,
            audit=self.audit,
            permissions=self.permissions,
        )

    def seed_locks(self, key: str, *, user_id: Any | None = None, token: str = "tok-owned") -> None:
        uid = (user_id or self.user).id
        self.redis.seed(f"batchzip:active:{uid}", f"{key}:{token}", KEYGATE_TTL)
        self.redis.seed(f"batchzip:keygate:{key}", f"{key}:{token}", KEYGATE_TTL)

    def clear_locks(self, key: str, *, user_id: Any | None = None) -> None:
        uid = (user_id or self.user).id
        self.redis.forget(f"batchzip:active:{uid}", f"batchzip:keygate:{key}")


def batch_enqueues(pool: FakeArqPool) -> list[dict[str, Any]]:
    return [e for e in pool.enqueued if e["function"] == "generate_batch_download_zip"]


# ─── 端点:权限跳过 / 403 / 400 族 / 422 / 429 ────────────────────────────────
async def test_partial_permission_skips_ids_only_and_audits_once(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """F9:部分无权限 → skipped_no_permission 只含 id(响应全文无文件名,防侧信道)
    + 首次逐条 download_denied 审计;轮询 SETNX 去重不重写;enqueue _job_id 为
    key:epoch 形态且入参带 bucket/job_token/ids。"""
    allowed = mk_batch_asset("a.livp")                       # livp 未就绪 → livp_raw_count=1
    denied = mk_batch_asset("top-secret-机密.livp")
    missing = mk_batch_asset("ghost.jpg")                    # 不入 db 预置集
    w = BatchWorld(monkeypatch, assets=[allowed, denied], denied_ids=[denied.id])

    first = await w.post([allowed.id, denied.id, missing.id])

    assert fld(first.out, "status") == "packing"
    key = fld(first.out, "key")
    assert isinstance(key, str) and len(key) >= 8
    skipped = fld(first.out, "skipped_no_permission")
    assert [str(s) for s in skipped] == [str(denied.id)], "跳过列表只含无权限 id"
    assert fld(first.out, "skipped_missing_count") == 1
    assert fld(first.out, "livp_raw_count") == 1, "未就绪 livp 以原始兜底计数"
    assert "top-secret" not in dump_json(first.out), "响应不得泄漏文件名(防侧信道)"
    # 首次逐条 download_denied 审计
    denied_events = [e for e in first.audit.of_type("download_denied")
                     if str(e.get("target_asset_id")) == str(denied.id)]
    assert len(denied_events) == 1
    # enqueue:epoch _job_id + 契约入参
    enq = batch_enqueues(first.pool)
    assert len(enq) == 1
    job_id = enq[0]["kwargs"].get("_job_id", "")
    assert re.fullmatch(re.escape(key) + r":\d+", str(job_id)), f"epoch 后缀形态: {job_id!r}"
    arg_strs = [str(a) for a in enq[0]["args"]]
    assert "ms-proj" in arg_strs, "入参显式带 bucket(定稿 §6.2 第 5 步)"
    assert key in arg_strs, "入参带 key"
    assert str(allowed.id) in arg_strs, "入参带允许集 ids"
    # 轮询(同 body + resume_key):SETNX 去重 → download_denied 不重写
    w.seed_locks(key)
    second = await w.post([allowed.id, denied.id, missing.id], resume_key=key)
    assert fld(second.out, "status") == "packing"
    denied_events_after = [e for e in second.audit.of_type("download_denied")
                           if str(e.get("target_asset_id")) == str(denied.id)]
    assert len(denied_events_after) == 1, "audited SETNX 去重:轮询不得重写 denied 审计"
    assert len(batch_enqueues(second.pool)) == 1, "同 key 锁在 → 不重入队"


async def test_all_denied_403_no_enqueue(monkeypatch: pytest.MonkeyPatch) -> None:
    """F9:允许集为空(全无权限)→ 403,不 head、不入队。"""
    a = mk_batch_asset("x.jpg")
    b = mk_batch_asset("y.jpg")
    w = BatchWorld(monkeypatch, assets=[a, b], denied_ids=[a.id, b.id])

    with pytest.raises(HTTPException) as ei:
        await w.post([a.id, b.id])

    assert ei.value.status_code == 403
    assert w.presign.head_calls == []
    assert batch_enqueues(w.pool) == []


async def test_all_missing_400(monkeypatch: pytest.MonkeyPatch) -> None:
    """F9:全不存在(无行/已软删)→ 400「无可下载文件」,不入队。"""
    ghost1 = mk_batch_asset("g1.jpg")
    ghost2 = mk_batch_asset("g2.jpg")
    w = BatchWorld(monkeypatch, assets=[])              # 预置集为空 = 全不存在

    with pytest.raises(HTTPException) as ei:
        await w.post([ghost1.id, ghost2.id])

    assert ei.value.status_code == 400
    assert batch_enqueues(w.pool) == []


async def test_cross_bucket_selection_400(monkeypatch: pytest.MonkeyPatch) -> None:
    """F9:跨桶选集 → 400「跨项目批量暂不支持」(同桶断言,防御性)。"""
    a = mk_batch_asset("a.jpg")
    b = mk_batch_asset("b.jpg", bucket="ms-other")
    w = BatchWorld(monkeypatch, assets=[a, b])

    with pytest.raises(HTTPException) as ei:
        await w.post([a.id, b.id])

    assert ei.value.status_code == 400
    assert batch_enqueues(w.pool) == []


async def test_single_file_over_limit_400_single_file_copy(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """F9:单个文件 >10GB(非 livp 原值超限)→ 400,文案必须是「单独下载该文件」
    (单文件物理上无法分批,不得给「请分批」死胡同文案)。"""
    big = mk_batch_asset("huge.mp4", size=11 * GiB)
    w = BatchWorld(monkeypatch, assets=[big])

    with pytest.raises(HTTPException) as ei:
        await w.post([big.id])

    assert ei.value.status_code == 400
    detail = str(ei.value.detail)
    assert "单独下载" in detail, f"单文件超限文案: {detail!r}"
    assert "分批" not in detail, "单文件超限不得出现「请分批」文案"


async def test_aggregate_over_limit_400_batch_copy(monkeypatch: pytest.MonkeyPatch) -> None:
    """F9:合计折算体积 >10GB(单文件均未超)→ 400,文案含「分批下载」。"""
    a = mk_batch_asset("v1.mp4", size=6 * GiB)
    b = mk_batch_asset("v2.mp4", size=6 * GiB)
    w = BatchWorld(monkeypatch, assets=[a, b])

    with pytest.raises(HTTPException) as ei:
        await w.post([a.id, b.id])

    assert ei.value.status_code == 400
    assert "分批" in str(ei.value.detail), f"合计超限文案: {ei.value.detail!r}"


async def test_livp_weighting_x3_trips_limit_and_control_passes(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """F9:livp 折算 x3 计入 —— 2x2GiB livp(折算 12GiB)击穿合计上限;等量
    非 livp(4GiB)正常放行(对照组,证明是折算而非原值击穿)。"""
    l1 = mk_batch_asset("live1.livp", size=2 * GiB)
    l2 = mk_batch_asset("live2.livp", size=2 * GiB)
    w = BatchWorld(monkeypatch, assets=[l1, l2])

    with pytest.raises(HTTPException) as ei:
        await w.post([l1.id, l2.id])

    assert ei.value.status_code == 400, "livp x3 折算后 12GiB > 10GB,必须拒绝"
    assert "分批" in str(ei.value.detail)

    # 对照组:同体积非 livp(4GiB < 10GB)→ 正常 packing 入队
    j1 = mk_batch_asset("j1.jpg", size=2 * GiB)
    j2 = mk_batch_asset("j2.jpg", size=2 * GiB)
    w2 = BatchWorld(monkeypatch, assets=[j1, j2])

    out = await w2.post([j1.id, j2.id])

    assert fld(out.out, "status") == "packing"


def test_over_100_ids_422_and_boundary_100_ok() -> None:
    """F9:>100 个 → 422(入参约束,pydantic 422);恰 100 个放行;空列表也拒。"""
    with pytest.raises(ValidationError) as ei:
        BatchDownloadLinkIn(asset_ids=[uuid.uuid4() for _ in range(101)])
    assert "asset_ids" in str(ei.value)

    with pytest.raises(ValidationError):
        BatchDownloadLinkIn(asset_ids=[])

    ok = BatchDownloadLinkIn(asset_ids=[uuid.uuid4() for _ in range(100)])
    assert len(ok.asset_ids) == 100


async def test_cross_key_lock_429_no_enqueue(monkeypatch: pytest.MonkeyPatch) -> None:
    """F9:per-user 锁存在且 value 前缀 != key(异 key 打包中)→ 429,不入队。"""
    a = mk_batch_asset("a.jpg")
    w = BatchWorld(monkeypatch, assets=[a])
    w.redis.seed(f"batchzip:active:{w.user.id}", "deadbeeff00dface:other-token", KEYGATE_TTL)

    with pytest.raises(HTTPException) as ei:
        await w.post([a.id])

    assert ei.value.status_code == 429, "异 key 锁占用必须 429"
    assert batch_enqueues(w.pool) == []


async def test_same_key_second_post_no_reenqueue(monkeypatch: pytest.MonkeyPatch) -> None:
    """F9:同 key 二次 POST(per-user 锁 value 前缀 == key)→ packing 且不再入队
    (轮询防踩踏靠这把锁,确定性 _job_id 去重已被弃用)。"""
    a = mk_batch_asset("a.jpg")
    w = BatchWorld(monkeypatch, assets=[a])

    first = await w.post([a.id])
    key = fld(first.out, "key")
    assert fld(first.out, "status") == "packing"
    assert len(batch_enqueues(w.pool)) == 1

    w.seed_locks(key)
    second = await w.post([a.id], resume_key=key)

    assert fld(second.out, "status") == "packing"
    assert len(batch_enqueues(w.pool)) == 1, "同 key 锁在位不得重入队"
    assert fld(second.out, "key") == key


async def test_keygate_cross_user_packing_with_retry_after(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """F9:跨用户同 key 打包期点击撞 per-key 在途闸 → packing(不双跑)且带
    retry_after_seconds(闸剩余 TTL)。"""
    a = mk_batch_asset("a.jpg")
    w = BatchWorld(monkeypatch, assets=[a])

    first = await w.post([a.id])
    key = fld(first.out, "key")

    user_b = mk_user("b")
    # B 无本人 active 锁;per-key 闸由 A 的首 POST 落下(此处显式补种,不依赖
    # impl 的 eval 参数布局,闸值含 A 的 token)
    w.redis.seed(f"batchzip:keygate:{key}", f"{key}:tok-first", KEYGATE_TTL)
    second = await w.post([a.id], user=user_b)

    assert fld(second.out, "status") == "packing"
    assert fld(second.out, "key") == key, "同权限同选集同 key(共享缓存前提)"
    rAS = fld(second.out, "retry_after_seconds")
    assert isinstance(rAS, int) and rAS >= 0, f"撞闸须带 retry_after_seconds: {rAS!r}"
    assert len(batch_enqueues(w.pool)) == 1, "per-key 闸去重:不双跑"


async def test_fail_marker_failed_then_retry_redispatches(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """F9:batchzip:fail:{key} 存在 → {status:failed} 且不入队;retry:true →
    清标记 + 重新入队(手动重试不受标记 TTL 拘束)。"""
    a = mk_batch_asset("a.jpg")
    w = BatchWorld(monkeypatch, assets=[a])

    first = await w.post([a.id])
    key = fld(first.out, "key")
    w.clear_locks(key)
    w.redis.seed(f"batchzip:fail:{key}", "RuntimeError", 600)

    failed = await w.post([a.id], resume_key=key)
    assert fld(failed.out, "status") == "failed"
    assert len(batch_enqueues(w.pool)) == 1, "failed 短路:不再入队"

    retried = await w.post([a.id], resume_key=key, retry=True)
    assert fld(retried.out, "status") == "packing"
    assert not w.redis.alive(f"batchzip:fail:{key}"), "retry:true 必须清失败标记"
    assert len(batch_enqueues(w.pool)) == 2, "retry:true 重新入队"


# ─── 端点:canonical / resume / 缓存分 key / TTL ─────────────────────────────
async def test_canonical_same_set_any_order_same_key(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """F9:确定性 key 按canonical(去重+升序)哈希 —— 同集不同序、含重复 id 的
    请求同 key(前端 selectedIds 插入序差异不得生成新包)。"""
    a = mk_batch_asset("a.jpg")
    b = mk_batch_asset("b.jpg")
    c = mk_batch_asset("c.jpg")
    w = BatchWorld(monkeypatch, assets=[a, b, c])

    k1 = fld((await w.post([a.id, b.id, c.id])).out, "key")
    k2 = fld((await w.post([c.id, a.id, b.id])).out, "key")
    k3 = fld((await w.post([a.id, b.id, a.id])).out, "key")   # 含重复 id
    k4 = fld((await w.post([a.id, b.id])).out, "key")          # 去重后等价

    assert k1 == k2, "同集不同序必须同 key(canonical 化)"
    assert k1 == k3, "含重复 id 请求与去重后同 key"
    assert k1 == k4


async def test_resume_mismatched_ids_400(monkeypatch: pytest.MonkeyPatch) -> None:
    """F9:resume_key 校验 canonical(body ids) == 记录 selection_ids,不符 → 400。"""
    a = mk_batch_asset("a.jpg")
    b = mk_batch_asset("b.jpg")
    d = mk_batch_asset("d.jpg")
    w = BatchWorld(monkeypatch, assets=[a, b, d])

    key = fld((await w.post([a.id, b.id])).out, "key")
    w.seed_locks(key)

    with pytest.raises(HTTPException) as ei:
        await w.post([a.id, d.id], resume_key=key)

    assert ei.value.status_code == 400, "换选集 resume 必须 400(记录校验)"


async def test_resume_cross_user_400(monkeypatch: pytest.MonkeyPatch) -> None:
    """F9:跨用户拿别人 key 做 resume → 400(作业记录按用户分存,天然挡住)。"""
    a = mk_batch_asset("a.jpg")
    w = BatchWorld(monkeypatch, assets=[a])

    key = fld((await w.post([a.id])).out, "key")

    user_b = mk_user("b")
    with pytest.raises(HTTPException) as ei:
        await w.post([a.id], user=user_b, resume_key=key)

    assert ei.value.status_code == 400, "跨用户 resume 必须 400(无本人作业记录)"


async def test_resume_with_skipped_items_ok_and_no_fga_recheck(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """F9:带 skipped 项(无权限/缺失)的选集轮询 resume 不 400(基准是
    selection_ids 而非 allowed_ids)、不触发全量 FGA 复检;filename/skipped 从
    记录回放一致。"""
    allowed = mk_batch_asset("ok.jpg")
    denied = mk_batch_asset("denied.jpg")
    missing = mk_batch_asset("gone.jpg")
    w = BatchWorld(monkeypatch, assets=[allowed, denied], denied_ids=[denied.id])

    first = await w.post([allowed.id, denied.id, missing.id])
    key = fld(first.out, "key")
    fname = fld(first.out, "filename")
    checks_after_first = list(w.permissions.checks)
    w.seed_locks(key)

    poll = await w.post([allowed.id, denied.id, missing.id], resume_key=key)

    assert fld(poll.out, "status") == "packing", "带 skipped 项的 resume 不得 400"
    assert w.permissions.checks == checks_after_first, (
        "轮询轻校验不得新增任何 FGA check(防记录误用 allowed_ids 的实现走偏;"
        f"首次 {checks_after_first!r} → 轮询后 {w.permissions.checks!r})"
    )
    assert [str(s) for s in fld(poll.out, "skipped_no_permission")] == [str(denied.id)], (
        "skipped 列表从记录回放"
    )
    assert fld(poll.out, "skipped_missing_count") == 1
    assert fld(poll.out, "filename") == fname, "filename 从记录回放一致"
    assert len(batch_enqueues(w.pool)) == 1


async def test_ready_ttl_shrinks_by_object_age(monkeypatch: pytest.MonkeyPatch) -> None:
    """F9:head 命中 → ready,TTL = min(21600, 21600-age)(造 2h 老化对象断言
    收缩);ready 单条聚合审计(kind=batch_zip + ids);packing 响应不写签发审计。"""
    a = mk_batch_asset("a.jpg")
    w = BatchWorld(monkeypatch, assets=[a])

    first = await w.post([a.id])
    key = fld(first.out, "key")
    assert first.audit.of_type("signed_url_issued") == [], "packing 不得写 signed_url_issued"

    w.presign.hit(zip_object_key_candidates(key), age_seconds=2 * 3600)
    w.clear_locks(key)

    ready = await w.post([a.id], resume_key=key)

    assert fld(ready.out, "status") == "ready"
    assert fld(ready.out, "url"), "ready 必须带 url"
    assert any(key in hk for _, hk in ready.presign.head_calls), "head 探测必须落在该 zip key 上"
    sign = ready.presign.calls[-1]
    expected = TTL_FULL - 2 * 3600
    assert abs(sign["expires_seconds"] - expected) <= 60, (
        f"TTL 须按对象剩余寿命收缩 min(21600, 21600-age): {sign['expires_seconds']}"
    )
    assert fld(ready.out, "expires_in") == sign["expires_seconds"]
    # 单条聚合审计
    issued = ready.audit.of_type("signed_url_issued")
    assert len(issued) == 1, "ready 只写一条聚合签发审计"
    details = issued[0].get("details", {})
    assert details.get("kind") == "batch_zip"
    assert str(a.id) in {str(x) for x in details.get("ids", [])}, "details.ids 覆盖允许集"


async def test_object_older_than_6h_treated_as_miss_regenerates(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """F9:age ≥ 保留期(6h)→ 按 miss 处理重新生成(新 epoch _job_id;剩余寿命
    ≤0 时签 URL 会 botocore 报错,必须走重打包)。"""
    a = mk_batch_asset("a.jpg")
    w = BatchWorld(monkeypatch, assets=[a])

    first = await w.post([a.id])
    key = fld(first.out, "key")
    w.clear_locks(key)
    w.presign.hit(zip_object_key_candidates(key), age_seconds=7 * 3600)

    again = await w.post([a.id], resume_key=key)

    assert fld(again.out, "status") == "packing", "超龄对象按 miss,重新打包"
    enq = batch_enqueues(again.pool)
    assert len(enq) == 2, "miss → 重新入队"
    assert enq[0]["kwargs"]["_job_id"] != enq[1]["kwargs"]["_job_id"], "epoch 后缀必须变化"
    assert again.presign.calls == [], "miss 不得签发 URL"


async def test_permission_sets_split_keys(monkeypatch: pytest.MonkeyPatch) -> None:
    """F9:缓存分 key —— A(缺 X 权限)与 B(全权)同选集 → key 不同(允许集摘要
    在 key 里),各生成各的包,互不投毒不乒乓。"""
    x = mk_batch_asset("x.jpg")
    y = mk_batch_asset("y.jpg")
    w = BatchWorld(monkeypatch, assets=[x, y], denied_ids=[x.id])
    user_b = mk_user("b")
    # 拒绝集按 user_subject 区分:A 走默认拒绝集(缺 x),B 全权 —— 同权限集才
    # 同 key 的前提是允许集真的不同
    w.permissions.denied_by_subject = {str(user_b.subject): set()}

    out_a = await w.post([x.id, y.id])
    out_b = await w.post([x.id, y.id], user=user_b)

    key_a = fld(out_a.out, "key")
    key_b = fld(out_b.out, "key")
    assert fld(out_a.out, "status") == "packing" and fld(out_b.out, "status") == "packing"
    assert key_a != key_b, "权限不同必须分 key(A 的允许集缺 x)"
    assert len(batch_enqueues(w.pool)) == 2, "各生成各的包"


async def test_same_permission_users_share_cache_ready(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """F9:同权限集两用户同 key 共享缓存 —— B 打包期后对象就绪,C 重点击直接
    ready 秒回(不重新打包、不二次入队)。"""
    a = mk_batch_asset("a.jpg")
    w = BatchWorld(monkeypatch, assets=[a])
    user_b = mk_user("b")

    first = await w.post([a.id])
    key = fld(first.out, "key")
    assert len(batch_enqueues(w.pool)) == 1

    w.presign.hit(zip_object_key_candidates(key), age_seconds=60)
    second = await w.post([a.id], user=user_b)   # C/B 全权同集 → 同 key → head 命中

    assert fld(second.out, "status") == "ready"
    assert fld(second.out, "key") == key, "同权限同选集共享缓存 key"
    assert fld(second.out, "url")
    assert len(batch_enqueues(w.pool)) == 1, "缓存命中不得二次入队"
    sign = second.presign.calls[-1]
    assert abs(sign["expires_seconds"] - (TTL_FULL - 60)) <= 60, "命中的新鲜对象签满额 TTL"


# ─── worker:generate_batch_download_zip(F10)─────────────────────────────────
class FakeS3:
    """worker 用 boto3 s3 替身:get_object/download_fileobj 按预置对象供流;
    put_object/upload_file 记录入参;upload_hook 供用例在回传瞬间改 redis 状态。"""

    def __init__(
        self,
        *,
        objects: dict[str, bytes] | None = None,
        ops: list[tuple] | None = None,
    ) -> None:
        self.objects = {k: v for k, v in (objects or {}).items()}
        self.ops = ops if ops is not None else []
        self.put_calls: list[dict[str, Any]] = []
        self.upload_calls: list[dict[str, Any]] = []
        self.upload_hook: Any = None

    def _missing(self, key: str) -> ClientError:
        return ClientError(
            {"Error": {"Code": "NoSuchKey", "Message": "The specified key does not exist."}},
            "GetObject",
        )

    def get_object(self, Bucket: str | None = None, Key: str | None = None, **kw: Any) -> dict:
        assert Key is not None
        self.ops.append(("get_object", Key))
        if Key not in self.objects:
            raise self._missing(Key)
        data = self.objects[Key]
        return {"Body": io.BytesIO(data), "ContentLength": len(data)}

    def download_fileobj(self, Bucket: str, Key: str, Fileobj: Any) -> None:
        self.ops.append(("download_fileobj", Key))
        if Key not in self.objects:
            raise self._missing(Key)
        Fileobj.write(self.objects[Key])

    def put_object(self, Bucket: str | None = None, Key: str | None = None, **kw: Any) -> dict:
        assert Key is not None
        self.ops.append(("put_object", Key))
        self.put_calls.append({"bucket": Bucket, "key": Key, "kwargs": kw})
        return {}

    def upload_file(
        self,
        Filename: str,
        Bucket: str,
        Key: str,
        ExtraArgs: dict | None = None,
        Config: Any = None,
    ) -> None:
        self.ops.append(("upload_file", Key))
        call = {
            "path": Filename, "bucket": Bucket, "key": Key,
            "ExtraArgs": ExtraArgs, "Config": Config,
        }
        self.upload_calls.append(call)
        if self.upload_hook is not None:
            self.upload_hook(call)

    def head_object(self, Bucket: str | None = None, Key: str | None = None, **kw: Any) -> dict:
        assert Key is not None
        self.ops.append(("head_object", Key))
        if Key not in self.objects:
            raise self._missing(Key)
        return {
            "ContentLength": len(self.objects[Key]),
            "ContentType": "application/zip",
            "ETag": '"abc"',
            "LastModified": datetime.now(UTC),
            "Metadata": {"kind": "batch_download_zip"},
        }


class FakeAsyncSession:
    def __init__(self, rows: list[Any], executed: list[Any] | None) -> None:
        self._rows = {r.id: r for r in rows}
        self.executed = executed

    async def get(self, model: Any, pk: Any) -> Any | None:
        if model is Asset:
            return self._rows.get(pk)
        return None

    async def execute(self, stmt: Any, *a: Any, **kw: Any) -> FakeResult:
        if self.executed is not None:
            self.executed.append(stmt)
        return FakeResult([])

    async def commit(self) -> None:
        return None

    async def flush(self) -> None:
        return None


class _SessCtx:
    def __init__(self, sess: FakeAsyncSession) -> None:
        self._s = sess

    async def __aenter__(self) -> FakeAsyncSession:
        return self._s

    async def __aexit__(self, *exc: Any) -> bool:
        return False


class FakeSessionmaker:
    def __init__(self, rows: list[Any], executed: list[Any] | None = None) -> None:
        self._sess = FakeAsyncSession(rows, executed)

    def __call__(self) -> _SessCtx:
        return _SessCtx(self._sess)


def patch_batch_worker(
    monkeypatch: pytest.MonkeyPatch,
    *,
    rows: list[Any],
    s3: FakeS3,
    executed: list[Any] | None = None,
) -> Any:
    """按仓库惯例(workers/main.py:模块级 import boto3 + from app.db.session import
    get_sessionmaker)对 batch_download 模块打桩。"""
    import app.workers.batch_download as bd

    monkeypatch.setattr(bd, "boto3", SimpleNamespace(client=lambda *a, **k: s3), raising=False)
    monkeypatch.setattr(
        bd, "get_sessionmaker", lambda: FakeSessionmaker(rows, executed), raising=False
    )
    monkeypatch.setattr(bd, "get_settings", lambda: mk_settings(), raising=False)
    return bd


def _tiny_jpeg() -> bytes:
    from PIL import Image

    buf = io.BytesIO()
    Image.new("RGB", (4, 4), (180, 60, 60)).save(buf, format="JPEG")
    return buf.getvalue()


def _derivative_zip_bytes(still: bytes, video: bytes) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_STORED) as zf:
        zf.writestr("IMG_0001.JPG.jpeg", still)
        zf.writestr("IMG_0001.JPG.mov", video)
    return buf.getvalue()


def zip64_written_names(path: str) -> set[str]:
    """返回以 ZIP64 格式(version needed ≥45)写入的条目名。

    `zf.open(zinfo, "w", force_zip64=True)` 会把条目的 version needed 置 45
    (实测钉死:普通 writestr 小条目为 20)—— 以此免造真实 4GB 断言流式写入
    参数;条目真超 4GiB 同样会置 45,断言方向「全部条目必须 45」不受影响。
    """
    with zipfile.ZipFile(path) as zf:
        return {i.filename for i in zf.infolist() if i.extract_version >= 45}


async def test_worker_renews_locks_at_start_before_first_fetch(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """F10:job 执行开始 Lua 续期两键(值含本 job_token 才续),且先于第一次取流;
    续期以执行时刻重置 TTL(≈2400s)。"""
    a = mk_batch_asset("a.jpg")
    key = "0123456789abcdef"
    token = "tok-renew"
    user_id = uuid.uuid4()
    ops: list[tuple] = []
    redis = FakeRedis(ops=ops)
    redis.seed(f"batchzip:active:{user_id}", f"{key}:{token}", 60)   # 临近过期,逼出续期
    redis.seed(f"batchzip:keygate:{key}", f"{key}:{token}", 60)
    s3 = FakeS3(objects={a.minio_key: b"\xff\xd8fakejpeg"}, ops=ops)

    ttl_seen: dict[str, float] = {}
    s3.upload_hook = lambda call: ttl_seen.setdefault(
        "active_ttl", redis.store[f"batchzip:active:{user_id}"][1] - time.time()
    )
    patch_batch_worker(monkeypatch, rows=[a], s3=s3)

    await generate_batch_download_zip(
        {"redis": redis}, str(user_id), token, [a.id], "ms-proj", key,
    )

    assert redis.eval_calls, "执行开始必须 Lua 续期两键(F10)"
    first = redis.eval_calls[0]
    strs = [x for x in first if isinstance(x, str)]
    assert f"batchzip:keygate:{key}" in strs and f"batchzip:active:{user_id}" in strs, (
        f"两键都要续期: {first!r}"
    )
    assert token in strs, "续期值必须含本 job_token"
    first_eval = ops.index(("eval", tuple(str(x) if isinstance(x, str) else x for x in first)))
    first_fetch = next(
        i for i, op in enumerate(ops) if op[0] in ("get_object", "download_fileobj")
    )
    assert first_eval < first_fetch, "续期必须先于第一次取流"
    assert ttl_seen.get("active_ttl", 0) > 1200, (
        f"续期应重置 TTL≈2400s: {ttl_seen.get('active_ttl')}"
    )


async def test_worker_success_multipart_extraargs_unlock_and_livp_members(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """F10:成功路径 —— 回传走 upload_file multipart(非 put_object),ExtraArgs 带
    ContentType=application/zip + Metadata{kind=batch_download_zip, contained-sha256},
    TransferConfig 分片阈值 ≥64MB;livp 就绪解开衍生物取成员入包(非嵌套 zip);
    finally 清两键、无失败标记。"""
    normal = mk_batch_asset("photo.jpg")
    livp = mk_batch_asset(
        "IMG_0001.livp",
        tags={"download_zip_key": "placeholder"},
    )
    livp.tags["download_zip_key"] = f"derivatives/{livp.id}/livp.zip"
    key = "0123456789abcdef"
    token = "tok-success"
    user_id = uuid.uuid4()
    ops: list[tuple] = []
    redis = FakeRedis(ops=ops)
    redis.seed(f"batchzip:active:{user_id}", f"{key}:{token}", KEYGATE_TTL)
    redis.seed(f"batchzip:keygate:{key}", f"{key}:{token}", KEYGATE_TTL)
    s3 = FakeS3(
        objects={
            normal.minio_key: b"\xff\xd8fakejpeg",
            livp.minio_key: b"PK\x03\x04forbidden-source",
            f"derivatives/{livp.id}/livp.zip": _derivative_zip_bytes(
                _tiny_jpeg(), b"\x00\x00\x00\x18ftypmp42"
            ),
        },
        ops=ops,
    )
    patch_batch_worker(monkeypatch, rows=[normal, livp], s3=s3)

    await generate_batch_download_zip(
        {"redis": redis}, str(user_id), token, [normal.id, livp.id], "ms-proj", key,
    )

    # 回传方法与参数
    assert len(s3.upload_calls) == 1, "批量包必须走 upload_file(multipart)"
    up = s3.upload_calls[0]
    assert up["bucket"] == "ms-proj" and up["key"].endswith(".zip")
    extra = up["ExtraArgs"] or {}
    assert extra.get("ContentType") == "application/zip"
    meta = extra.get("Metadata") or {}
    assert meta.get("kind") == "batch_download_zip", "kind 同时是清理 cron 的删除守卫"
    assert "contained-sha256" in meta, "允许集摘要作观测字段入 Metadata"
    cfg = up["Config"]
    assert getattr(cfg, "multipart_threshold", 0) >= 64 * 1024 * 1024, "分片阈值 ≥64MB"
    assert all(p["key"] != up["key"] for p in s3.put_calls), "批量包不得走 put_object(5GiB 硬限)"
    # zip 内容:livp 解开取成员(有 jpg 与 mp4 条目,无嵌套 zip)
    with zipfile.ZipFile(up["path"]) as zf:
        entries = zf.namelist()
    assert any(e.lower().endswith((".jpg", ".jpeg")) for e in entries), f"条目: {entries!r}"
    assert any(e.lower().endswith((".mp4", ".mov")) for e in entries), "livp 实况须解出视频成员"
    assert not any(e.lower().endswith(".zip") for e in entries), "不得把 livp.zip 整体塞入"
    # finally:清两键、无失败标记
    assert not redis.alive(f"batchzip:active:{user_id}"), "成功须清 per-user 锁"
    assert not redis.alive(f"batchzip:keygate:{key}"), "成功须清 per-key 闸"
    assert not redis.alive(f"batchzip:fail:{key}"), "成功不得写失败标记"


async def test_worker_force_zip64_on_every_local_header(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """F10:流式写入必须 zf.open(zinfo, "w", force_zip64=True) —— 断言每个条目
    version needed ≥45(仅 force_zip64 写入置位),免真实 4GB。"""
    a = mk_batch_asset("a.jpg")
    b = mk_batch_asset("b.mp4")
    key = "0123456789abcdef"
    token = "tok-z64"
    user_id = uuid.uuid4()
    redis = FakeRedis()
    redis.seed(f"batchzip:active:{user_id}", f"{key}:{token}", KEYGATE_TTL)
    redis.seed(f"batchzip:keygate:{key}", f"{key}:{token}", KEYGATE_TTL)
    s3 = FakeS3(objects={a.minio_key: b"\xff\xd8jpeg", b.minio_key: b"ftypmp4data"})
    patch_batch_worker(monkeypatch, rows=[a, b], s3=s3)

    await generate_batch_download_zip(
        {"redis": redis}, str(user_id), token, [a.id, b.id], "ms-proj", key,
    )

    assert s3.upload_calls, "应有回传产物"
    z64 = zip64_written_names(s3.upload_calls[0]["path"])
    with zipfile.ZipFile(s3.upload_calls[0]["path"]) as zf:
        entries = set(zf.namelist())
    assert entries, "zip 非空"
    assert entries <= z64, (
        f"每个条目都必须以 ZIP64 格式写入(force_zip64=True);缺失: {entries - z64!r}"
    )


async def test_worker_zero_valid_entries_fails_with_marker(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """F10:有效条目 0(全选集打包途中被软删/purge)→ 按失败收尾:不出空 zip、
    写 batchzip:fail:{key}、清两键。"""
    a = mk_batch_asset("a.jpg")
    b = mk_batch_asset("b.jpg")
    key = "0123456789abcdef"
    token = "tok-zero"
    user_id = uuid.uuid4()
    redis = FakeRedis()
    redis.seed(f"batchzip:active:{user_id}", f"{key}:{token}", KEYGATE_TTL)
    redis.seed(f"batchzip:keygate:{key}", f"{key}:{token}", KEYGATE_TTL)
    s3 = FakeS3(objects={})
    patch_batch_worker(monkeypatch, rows=[], s3=s3)   # 行全删:重查无行

    await generate_batch_download_zip(
        {"redis": redis}, str(user_id), token, [a.id, b.id], "ms-proj", key,
    )

    assert s3.upload_calls == [], "不得产出空 zip"
    assert redis.alive(f"batchzip:fail:{key}"), "必须写失败标记衔接端点 failed/retry 通道"
    assert not redis.alive(f"batchzip:active:{user_id}"), "失败也要清 per-user 锁"
    assert not redis.alive(f"batchzip:keygate:{key}"), "失败也要清 per-key 闸"


async def test_worker_finally_does_not_clobber_successor_lock(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """F10:锁 token Lua —— finally 值匹配才删;中途易主的新 token 锁(后继 job
    已落新闸)不得被旧 job 误删。"""
    a = mk_batch_asset("a.jpg")
    key = "0123456789abcdef"
    token = "tok-old"
    user_id = uuid.uuid4()
    redis = FakeRedis()
    redis.seed(f"batchzip:active:{user_id}", f"{key}:{token}", KEYGATE_TTL)
    redis.seed(f"batchzip:keygate:{key}", f"{key}:{token}", KEYGATE_TTL)
    s3 = FakeS3(objects={a.minio_key: b"\xff\xd8jpeg"})

    def usurp(call: dict) -> None:
        """回传瞬间模拟「旧 job 拖尾,后继 job 已落新 token 锁」。"""
        redis.store[f"batchzip:active:{user_id}"] = (f"{key}:tok-successor", time.time() + KEYGATE_TTL)
        redis.store[f"batchzip:keygate:{key}"] = (f"{key}:tok-successor", time.time() + KEYGATE_TTL)

    s3.upload_hook = usurp
    patch_batch_worker(monkeypatch, rows=[a], s3=s3)

    await generate_batch_download_zip(
        {"redis": redis}, str(user_id), token, [a.id], "ms-proj", key,
    )

    cur = redis.store.get(f"batchzip:active:{user_id}")
    assert cur is not None and "tok-successor" in cur[0], (
        "旧 job finally 不得误删后继的新 token 锁(值匹配才删)"
    )
    gate = redis.store.get(f"batchzip:keygate:{key}")
    assert gate is not None and "tok-successor" in gate[0], "per-key 闸同样值匹配才删"
    assert not redis.alive(f"batchzip:fail:{key}"), "易主场景失败语义归 token 持有者,不得误标"


def test_batch_job_and_cron_registration() -> None:
    """F10/F11:注册面 —— generate_batch_download_zip timeout=1800/max_tries=1
    (防自动重试与 retry:true 双跑);cron cleanup_batch_zips 已挂。"""
    fns = {getattr(f, "name", None): f for f in WorkerSettings.functions}
    f = fns.get("generate_batch_download_zip")
    assert f is not None, "WorkerSettings.functions 缺 generate_batch_download_zip"
    assert getattr(f, "max_tries", None) == 1
    assert getattr(f, "timeout_s", None) == 1800

    cron_names = {
        getattr(getattr(c, "coroutine", None), "__name__", None) for c in WorkerSettings.crons
    }
    assert "cleanup_batch_zips" in cron_names, "arq cron 缺 cleanup_batch_zips 注册"


# ─── cron:cleanup_batch_zips(F11)─────────────────────────────────────────────
class CronS3:
    """cron 用 s3 替身:list_objects_v2 真·分页(IsTruncated/ContinuationToken,
    页宽由调用方 MaxKeys 决定,测试用包装层强制);head 返回预置 Metadata;delete
    记录 ops。"""

    def __init__(self, buckets: dict[str, list[tuple[str, datetime, dict]]]) -> None:
        self.buckets = buckets
        self.ops: list[tuple] = []
        self.list_calls: list[dict[str, Any]] = []
        self.head_keys: list[str] = []

    def list_buckets(self) -> dict:
        self.ops.append(("list_buckets",))
        return {"Buckets": [{"Name": b} for b in self.buckets]}

    def list_objects_v2(
        self,
        Bucket: str | None = None,
        Prefix: str = "",
        MaxKeys: int = 1000,
        ContinuationToken: str | None = None,
        **kw: Any,
    ) -> dict:
        assert Bucket is not None
        self.list_calls.append({"bucket": Bucket, "prefix": Prefix})
        entries = sorted(
            (k, lm, md) for k, lm, md in self.buckets.get(Bucket, []) if k.startswith(Prefix)
        )
        start = 0
        if ContinuationToken:
            start = next(i for i, (k, _, _) in enumerate(entries) if k == ContinuationToken) + 1
        page = entries[start:start + MaxKeys]
        truncated = start + MaxKeys < len(entries)
        resp: dict[str, Any] = {
            "Contents": [{"Key": k, "LastModified": lm, "Size": 1} for k, lm, _ in page],
            "KeyCount": len(page),
            "IsTruncated": truncated,
        }
        if truncated:
            resp["NextContinuationToken"] = page[-1][0]
        return resp

    def head_object(self, Bucket: str | None = None, Key: str | None = None, **kw: Any) -> dict:
        assert Bucket is not None and Key is not None
        self.head_keys.append(Key)
        md = next((m for k, _, m in self.buckets.get(Bucket, []) if k == Key), None)
        if md is None:
            raise ClientError({"Error": {"Code": "404", "Message": "Not Found"}}, "HeadObject")
        return {"Metadata": md, "LastModified": datetime.now(UTC)}

    def delete_object(self, Bucket: str | None = None, Key: str | None = None, **kw: Any) -> dict:
        assert Key is not None
        self.ops.append(("delete", Bucket, Key))
        return {}


async def test_cron_cleanup_shape_metadata_guard_pagination(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """F11:cron 只删 derivatives/batch/ 前缀 + LastModified>6h + Metadata
    kind=batch_download_zip 的对象;形态粗筛(非 ^[0-9a-f]{16}\\.zip$ 不 head 不删,
    含大写形态);分页覆盖;derivatives/{asset_id}/livp.zip 永久衍生物绝不波及。"""
    import app.workers.batch_download as bd

    old = datetime.now(UTC) - timedelta(hours=7)
    fresh = datetime.now(UTC) - timedelta(hours=1)
    livp_key = "derivatives/99999999-8888-7777-6666-555555555555/livp.zip"
    s3 = CronS3({
        "ms-a": [
            ("derivatives/batch/0123456789abcdef.zip", old, {"kind": "batch_download_zip"}),
            ("derivatives/batch/ffffffffffffffff.zip", old, {}),                      # 守卫:无 kind
            ("derivatives/batch/user-report.pdf", old, {"kind": "batch_download_zip"}),  # 形态粗筛
            ("derivatives/batch/ABCDEF0123456789.zip", old, {"kind": "batch_download_zip"}),  # 大写不匹配
            ("derivatives/batch/1111111122223333.zip", fresh, {"kind": "batch_download_zip"}),  # 未超龄
            (livp_key, old, {"kind": "livp_download_zip"}),                            # 永久衍生物
        ],
        "ms-b": [
            ("derivatives/batch/aaaaaaaaaaaaaaaa.zip", old, {"kind": "batch_download_zip"}),
        ],
    })
    monkeypatch.setattr(bd, "boto3", SimpleNamespace(client=lambda *a, **k: s3), raising=False)
    monkeypatch.setattr(bd, "get_settings", lambda: mk_settings(), raising=False)

    # 包装层强制页宽 2(走真 IsTruncated/ContinuationToken 路径)—— 与生产是否传/
    # 传多大 MaxKeys 解耦,断言的是分页逻辑本身(全量迭代/续页/末页收敛)
    real_list = s3.list_objects_v2
    paged_calls: list[dict[str, Any]] = []

    def forced_two_per_page(*a: Any, **kw: Any) -> dict:
        kw["MaxKeys"] = 2
        out = real_list(*a, **kw)
        paged_calls.append({
            "bucket": kw.get("Bucket"),
            "token": kw.get("ContinuationToken"),
            "truncated": bool(out.get("IsTruncated")),
        })
        return out

    monkeypatch.setattr(s3, "list_objects_v2", forced_two_per_page)

    await cleanup_batch_zips({"redis": FakeRedis()})

    deleted = [op[2] for op in s3.ops if op[0] == "delete"]
    assert sorted(deleted) == [
        "derivatives/batch/0123456789abcdef.zip",
        "derivatives/batch/aaaaaaaaaaaaaaaa.zip",
    ], f"恰好删两个超龄且 kind 匹配的批量包: {deleted!r}"
    # 形态粗筛:非匹配形态不 head(user-report.pdf / 大写十六进制 / livp.zip / 未超龄)
    assert "derivatives/batch/user-report.pdf" not in s3.head_keys
    assert "derivatives/batch/ABCDEF0123456789.zip" not in s3.head_keys
    assert "derivatives/batch/1111111122223333.zip" not in s3.head_keys
    # Metadata 守卫:无 kind 的命中对象不删但必须 head 过
    assert "derivatives/batch/ffffffffffffffff.zip" in s3.head_keys
    # 永久衍生物不波及
    assert livp_key not in s3.head_keys and livp_key not in deleted, (
        "derivatives/{asset_id}/livp.zip 跟宿主 purge,清理 cron 绝不波及"
    )
    # 迭代全部桶 + 只列 batch 前缀
    listed_buckets = {c["bucket"] for c in s3.list_calls}
    assert listed_buckets == {"ms-a", "ms-b"}, "list_buckets() 迭代全部桶"
    assert all(c["prefix"] == BATCH_ZIP_PREFIX for c in s3.list_calls), "只列 batch 前缀"
    # 分页逻辑本身(页宽 2 由包装层强制,与生产 MaxKeys 参数解耦):
    # ms-a 5 个 batch 对象 → 至少 3 页;续页带 ContinuationToken;末页 IsTruncated 收敛
    ms_a_pages = [c for c in paged_calls if c["bucket"] == "ms-a"]
    assert len(ms_a_pages) >= 3, (
        f"ms-a 5 个命中对象、每页 2 条 → 至少 3 页(全量迭代): {len(ms_a_pages)}"
    )
    assert ms_a_pages[0]["token"] is None and all(c["token"] for c in ms_a_pages[1:]), (
        f"续页必须带 ContinuationToken(IsTruncated/NextContinuationToken 路径): {ms_a_pages!r}"
    )
    assert ms_a_pages[-1]["truncated"] is False, "末页 IsTruncated 必须 False(分页收敛)"


# ─── tags 写点(F7):jsonb_set 单条 UPDATE 原子合并不丢对方 key ────────────────
async def test_merge_asset_tags_jsonb_set_atomic_no_foreign_key_loss() -> None:
    """F7:tags 合并写点(共享 helper `_merge_asset_tags`,livp 下载 job 与三族
    缩略图 job 双 writer 共用)必须是 `UPDATE … SET tags = jsonb_set(tags …)` 单条
    UPDATE —— 表达式首项锚定 tags 列本身(可带 `-` 删除链),合并基于 PG 行内当前值,
    并发对方 job 先落的 thumbnail_key 等不丢;整列回写(ORM tags=dict)会覆丢,本
    用例即闸。"""
    from app.workers.main import _merge_asset_tags

    executed: list[Any] = []
    sm = FakeSessionmaker([], executed)
    aid = uuid.uuid4()

    # livp job 成功路径的真实调用形态(sets 两 key + removes 两个观测/永久标记)
    await _merge_asset_tags(
        sm, aid,
        sets={"download_zip_key": "derivatives/x/livp.zip", "download_zip_size_bytes": 123},
        removes=("download_zip_failed", "thumbnail_failed"),
    )

    assert len(executed) == 1, f"tags 合并必须收敛为单条 UPDATE: {len(executed)} 条"
    stmt = executed[0]
    sql = str(stmt)
    assert re.search(r"tags\s*=\s*jsonb_set\b", sql, re.IGNORECASE), (
        f"tags 列必须以 jsonb_set 表达式赋值(单条 UPDATE): {sql[:220]!r}"
    )
    # 表达式最内层首项锚定 tags 列本身(渲染可带表限定/括号:`(assets.tags - :k)`)
    assert re.search(r"jsonb_set\s*\(\s*\(?\s*(assets\.)?tags\b", sql, re.IGNORECASE), (
        f"jsonb_set 首参必须锚定 tags 列(基于当前值合并): {sql[:220]!r}"
    )
    assert not re.search(r"tags\s*=\s*:\w", sql), (
        "不得整列回写(ORM tags=dict / values(tags=:tags) 都会把并排 job 的 key 覆丢)"
    )
    # 每 key 一个 jsonb_set 嵌套位 + 删除键进参数(路径级合并,非整列)
    assert sql.lower().count("jsonb_set") == 2, "sets 逐 key 嵌套 jsonb_set"
    params = stmt.compile().params
    param_values: set[str] = set()
    for v in params.values():
        if isinstance(v, (list, tuple)):
            param_values.update(str(x) for x in v)
        else:
            param_values.add(str(v))
    assert "download_zip_failed" in param_values and "thumbnail_failed" in param_values, (
        f"removes 键必须以参数进入删除链: {param_values!r}"
    )
    assert "download_zip_key" in param_values, "sets 的 key 路径必须进参数"


async def test_merge_asset_tags_rejects_same_key_set_and_remove() -> None:
    """F7(防御):同 key 同时 set 与 remove 必须显式报错,不得静默二义。"""
    from app.workers.main import _merge_asset_tags

    with pytest.raises(ValueError):
        await _merge_asset_tags(
            FakeSessionmaker([], None), uuid.uuid4(),
            sets={"download_zip_key": "x"}, removes=("download_zip_key",),
        )


# ─── 遗留缺口补测(A1-A7,2026-10-21)─────────────────────────────────────────
async def test_worker_semaphore_wait_timeout_fast_fails_with_marker(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A1:打包信号量(模块级 ≤2)acquire 限时 120s —— 竞争态(2 许可全被在途
    job 持有)超时快速失败:写 batchzip:fail:{key}、清两键、不取流不打包
    (不烧 1800s job 预算)。限时值 monkeypatch 压缩为 50ms,语义不变。"""
    import app.workers.batch_download as bd

    a = mk_batch_asset("a.jpg")
    key = "0123456789abcdef"
    token = "tok-sem"
    user_id = uuid.uuid4()
    redis = FakeRedis()
    redis.seed(f"batchzip:active:{user_id}", f"{key}:{token}", KEYGATE_TTL)
    redis.seed(f"batchzip:keygate:{key}", f"{key}:{token}", KEYGATE_TTL)
    s3 = FakeS3(objects={a.minio_key: b"\xff\xd8jpeg"})
    patch_batch_worker(monkeypatch, rows=[a], s3=s3)
    monkeypatch.setattr(bd, "_SEMAPHORE_WAIT_S", 0.05)

    await bd._PACK_SEMAPHORE.acquire()
    await bd._PACK_SEMAPHORE.acquire()   # 竞争态:许可全部被占
    try:
        out = await generate_batch_download_zip(
            {"redis": redis}, str(user_id), token, [a.id], "ms-proj", key,
        )
    finally:
        bd._PACK_SEMAPHORE.release()
        bd._PACK_SEMAPHORE.release()

    assert out == {"status": "failed", "key": key, "error": "semaphore_wait_timeout"}
    assert redis.alive(f"batchzip:fail:{key}"), "超时快速失败必须写失败标记(衔接 failed/retry)"
    assert redis.store[f"batchzip:fail:{key}"][0] == "TimeoutError", "标记值为异常类型名"
    assert not redis.alive(f"batchzip:active:{user_id}"), "快速失败也要清 per-user 锁"
    assert not redis.alive(f"batchzip:keygate:{key}"), "快速失败也要清 per-key 闸"
    assert s3.ops == [] and s3.upload_calls == [], "未取得信号量不得取流/打包"


async def test_resume_ready_recheck_all_denied_403_no_sign_audit(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A2:resume 轮询期权限整体回收 → head 命中触发 ready 全量复检 → 全 denied
    → 403;不签发 URL、不写 signed_url_issued 审计(仍写 download_denied 首评);
    不得回退到 miss 入队通道。"""
    a = mk_batch_asset("revoked.jpg")
    w = BatchWorld(monkeypatch, assets=[a])

    first = await w.post([a.id])
    key = fld(first.out, "key")
    w.presign.hit(zip_object_key_candidates(key), age_seconds=60)
    w.permissions.denied = {str(a.id)}   # 轮询期权限整体回收

    with pytest.raises(HTTPException) as ei:
        await w.post([a.id], resume_key=key)

    assert ei.value.status_code == 403
    assert w.presign.calls == [], "denied 复检不得签发 URL"
    assert w.audit.of_type("signed_url_issued") == [], "denied 复检不得写 signed_url_issued"
    denied_events = [e for e in w.audit.of_type("download_denied")
                     if str(e.get("target_asset_id")) == str(a.id)]
    assert len(denied_events) == 1, "仍写 download_denied(该选中集首评一次)"
    assert w.redis.alive(batch_audited_key(str(w.user.id), [str(a.id)])), (
        "denied 去重键按选中集摘要落下"
    )
    assert len(batch_enqueues(w.pool)) == 1, "denied 短路不得回退入队(仅首 POST 一条)"


async def test_resume_key_convergence_new_key_head_hit_ready_backfill(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A3(命中支):resume 时就绪位翻转 → 应然 key ≠ resume_key;新 key 的包已
    存在(head 命中)→ 直签 ready,且按当前复检现算回放补写新 key 作业记录
    (前端照常按响应里的新 key 继续轮询)。"""
    lv = mk_batch_asset("IMG_0001.livp")   # 未就绪(tags 空)
    w = BatchWorld(monkeypatch, assets=[lv])

    first = await w.post([lv.id])
    rk = fld(first.out, "key")
    assert rk == compute_batch_key({str(lv.id): False}, [str(lv.id)])
    new_key = compute_batch_key({str(lv.id): True}, [str(lv.id)])
    assert rk != new_key, "就绪位翻转必须改变应然 key(收敛分支的前提)"

    lv.tags["download_zip_key"] = f"derivatives/{lv.id}/livp.zip"   # 打包期就绪位翻转
    w.presign.hit(zip_object_key_candidates(rk), age_seconds=60)
    w.presign.hit(zip_object_key_candidates(new_key), age_seconds=60)
    w.clear_locks(rk)

    out = await w.post([lv.id], resume_key=rk)

    assert fld(out.out, "status") == "ready"
    assert fld(out.out, "key") == new_key, "按新 key 交付"
    assert fld(out.out, "url")
    assert out.presign.calls[-1]["key"] == batch_object_key(new_key), "URL 签在新 key 对象上"
    raw = await w.redis.get(batch_job_record_key(str(w.user.id), new_key))
    assert raw is not None, "必须补写新 key 的作业记录"
    rec = json.loads(raw)
    assert rec["selection_ids"] == [str(lv.id)], "现算回放:selection 原样"
    assert rec["allowed_ids"] == [str(lv.id)]
    assert rec["bucket"] == "ms-proj"
    assert rec["livp_raw_count"] == 0, "现算回放:已就绪 livp 不计原始兜底"
    issued = out.audit.of_type("signed_url_issued")
    assert len(issued) == 1
    assert issued[0]["target_minio_key"] == batch_object_key(new_key)
    assert len(batch_enqueues(w.pool)) == 1, "新 key head 命中免重打包(仅首 POST 一条)"


async def test_resume_key_convergence_new_key_miss_reenqueues(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A3(miss 支):resume 时就绪位翻转且新 key 的包不存在 → 按新批重新入队
    (新 key 新作业记录;_job_id epoch 形态;此后同 key 轮询被锁去重不双跑)。"""
    lv = mk_batch_asset("IMG_0001.livp")
    w = BatchWorld(monkeypatch, assets=[lv])

    first = await w.post([lv.id])
    rk = fld(first.out, "key")
    new_key = compute_batch_key({str(lv.id): True}, [str(lv.id)])

    lv.tags["download_zip_key"] = f"derivatives/{lv.id}/livp.zip"
    w.presign.hit(zip_object_key_candidates(rk), age_seconds=60)   # 只 seed 旧 key:新 key miss
    w.clear_locks(rk)

    out = await w.post([lv.id], resume_key=rk)

    assert fld(out.out, "status") == "packing"
    assert fld(out.out, "key") == new_key, "收敛分支按新 key 继续轮询"
    raw = await w.redis.get(batch_job_record_key(str(w.user.id), new_key))
    assert raw is not None, "新 key 必须落新作业记录"
    rec = json.loads(raw)
    assert rec["selection_ids"] == [str(lv.id)] and rec["allowed_ids"] == [str(lv.id)]
    assert rec["livp_raw_count"] == 0
    enq = batch_enqueues(w.pool)
    assert len(enq) == 2, "新 key miss → 重新入队"
    assert [str(x) for x in enq[1]["args"]][-1] == new_key, "新入队落新 key"
    assert re.fullmatch(re.escape(new_key) + r":\d+", str(enq[1]["kwargs"]["_job_id"])), (
        f"epoch 后缀形态: {enq[1]['kwargs']['_job_id']!r}"
    )
    second = await w.post([lv.id], resume_key=new_key)
    assert fld(second.out, "status") == "packing"
    assert len(batch_enqueues(w.pool)) == 2, "新 key 锁已由本次 dispatch 落下 → 不双跑"


def test_dedupe_entry_name_windows_style() -> None:
    """A4(纯函数):批量包内 Windows 风格 `(1)` 重名去重 —— 不同夹同名文件很常见。"""
    used: set[str] = set()
    assert _dedupe_entry_name("IMG_0001.jpg", used) == "IMG_0001.jpg"
    assert _dedupe_entry_name("IMG_0001.jpg", used) == "IMG_0001 (1).jpg"
    assert _dedupe_entry_name("IMG_0001.jpg", used) == "IMG_0001 (2).jpg"
    assert _dedupe_entry_name("IMG_0001.mp4", used) == "IMG_0001.mp4", "同名不同扩展名互不影响"
    used2: set[str] = {"a.jpg", "a (1).jpg"}
    assert _dedupe_entry_name("a.jpg", used2) == "a (2).jpg", "已被占的编号顺延不撞"


async def test_worker_dedupes_same_name_entries_windows_style(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A4(job 组装路径):两个不同资产同名 → zip 内条目 `x.jpg` / `x (1).jpg`。"""
    a = mk_batch_asset("same.jpg")
    b = mk_batch_asset("same.jpg")
    b.minio_key = "folder-b/same.jpg"
    key = "0123456789abcdef"
    token = "tok-dedup"
    user_id = uuid.uuid4()
    redis = FakeRedis()
    redis.seed(f"batchzip:active:{user_id}", f"{key}:{token}", KEYGATE_TTL)
    redis.seed(f"batchzip:keygate:{key}", f"{key}:{token}", KEYGATE_TTL)
    s3 = FakeS3(objects={a.minio_key: b"AAA", b.minio_key: b"BBB"})
    patch_batch_worker(monkeypatch, rows=[a, b], s3=s3)

    out = await generate_batch_download_zip(
        {"redis": redis}, str(user_id), token, [a.id, b.id], "ms-proj", key,
    )

    assert out["status"] == "ok" and out["entries"] == 2
    up = s3.upload_calls[0]
    with zipfile.ZipFile(up["path"]) as zf:
        entries = sorted(zf.namelist())
    assert entries == ["same (1).jpg", "same.jpg"], f"Windows 风格去重: {entries!r}"


async def test_worker_skips_soft_deleted_and_vanished_rows_mid_pack(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A5a:打包途中部分资产软删/行消失 → 逐资产重查行跳过(zip 缺席该资产不崩
    job),其余照常入包;仍有有效条目 → 正常交付(ok 而非失败收尾)。"""
    keep = mk_batch_asset("keep.jpg")
    softdel = mk_batch_asset("gone.jpg")
    softdel.deleted_at = datetime.now(UTC)          # 打包途中被软删
    ghost = mk_batch_asset("purged.jpg")            # 打包途中行被 purge(重查无行)
    key = "0123456789abcdef"
    token = "tok-skip"
    user_id = uuid.uuid4()
    redis = FakeRedis()
    redis.seed(f"batchzip:active:{user_id}", f"{key}:{token}", KEYGATE_TTL)
    redis.seed(f"batchzip:keygate:{key}", f"{key}:{token}", KEYGATE_TTL)
    s3 = FakeS3(objects={keep.minio_key: b"\xff\xd8jpeg"})
    patch_batch_worker(monkeypatch, rows=[keep, softdel], s3=s3)   # ghost 不在预置集

    out = await generate_batch_download_zip(
        {"redis": redis}, str(user_id), token, [keep.id, softdel.id, ghost.id],
        "ms-proj", key,
    )

    assert out["status"] == "ok" and out["entries"] == 1, "缺席资产跳过,不崩不失败"
    up = s3.upload_calls[0]
    with zipfile.ZipFile(up["path"]) as zf:
        assert zf.namelist() == ["keep.jpg"], "zip 缺席被删资产"
    fetched = [k for op, k in s3.ops if op in ("get_object", "download_fileobj")]
    assert set(fetched) == {keep.minio_key}, "被删资产不得取流"


async def test_worker_uses_current_minio_key_of_requeried_row(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A5b:enqueue 后资产被移动 → 按重查行**当前** minio_key 拉流照常入包;
    旧 key 的陈旧内容不得被取用(job 入参只有 ids,key 以重查行为唯一事实)。"""
    moved = mk_batch_asset("moved.jpg")
    old_key, new_key = moved.minio_key, "folder-b/moved-after-move.jpg"
    moved.minio_key = new_key
    key = "0123456789abcdef"
    token = "tok-move"
    user_id = uuid.uuid4()
    redis = FakeRedis()
    redis.seed(f"batchzip:active:{user_id}", f"{key}:{token}", KEYGATE_TTL)
    redis.seed(f"batchzip:keygate:{key}", f"{key}:{token}", KEYGATE_TTL)
    s3 = FakeS3(objects={old_key: b"stale-bytes", new_key: b"fresh-bytes"})
    patch_batch_worker(monkeypatch, rows=[moved], s3=s3)

    out = await generate_batch_download_zip(
        {"redis": redis}, str(user_id), token, [moved.id], "ms-proj", key,
    )

    assert out["status"] == "ok"
    fetched = [k for op, k in s3.ops if op in ("get_object", "download_fileobj")]
    assert fetched == [new_key], f"必须按重查行当前 minio_key 拉流: {fetched!r}"
    up = s3.upload_calls[0]
    with zipfile.ZipFile(up["path"]) as zf:
        assert zf.read("moved.jpg") == b"fresh-bytes", "入包的是新 key 内容"


def test_audited_key_shape_is_selection_scoped() -> None:
    """A6(纯函数):denied 去重键形态 batchzip:audited:{user}:sel:
    {sha256(canonical(ids))[:16]} —— 同集不同序/含重复同键;不同选集不同键。
    全 denied 场景批量缓存 key 恒为常量(允许集空),去重键按选中集分正是
    「不同选集各自首评」的根基。"""
    uid = str(uuid.uuid4())
    i1, i2, i3 = (str(uuid.uuid4()) for _ in range(3))

    k1 = batch_audited_key(uid, [i1, i2])
    assert k1 == batch_audited_key(uid, [i2, i1]), "同集不同序同键"
    assert k1 == batch_audited_key(uid, [i1, i1, i2]), "canonical 去重后同键"
    expected_digest = hashlib.sha256(",".join(sorted({i1, i2})).encode("utf-8")).hexdigest()
    assert k1 == f"batchzip:audited:{uid}:sel:{expected_digest[:16]}", f"键形态: {k1!r}"
    assert batch_audited_key(uid, [i1, i3]) != k1, "不同选集不同键"

    const_key = compute_batch_key({}, [])          # 全 denied 的批量缓存 key(常量)
    assert const_key == compute_batch_key({}, []), "全 denied 下缓存 key 恒常量"
    assert batch_audited_key(uid, [i1, i2]) != batch_audited_key(uid, [i1, i3]), (
        "常量 key 场景下去重键仍须按选中集区分(否则异选集首评被折叠少记)"
    )


async def test_all_denied_selections_each_get_first_evaluation(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A6(端点):全 denied 场景 —— 同集不同序的二次请求去重(不重写审计),
    不同选集各自首评(各写两条 download_denied;跨选集不互相折叠)。"""
    a, b, c = (mk_batch_asset(f"{n}.jpg") for n in "abc")
    audit = StubAudit()
    redis = FakeRedis()
    pool = FakeArqPool()
    user = mk_user("a")
    # db 预置行与该次请求的 SELECT 匹配(id IN 过滤口径;全 denied 不预置除外项)
    posts: list[tuple[list[Any], list[Any]]] = [
        ([a.id, b.id], [a, b]),
        ([b.id, a.id], [a, b]),   # 同集不同序:去重
        ([a.id, c.id], [a, c]),   # 不同选集:各自首评
    ]
    for ids, preset in posts:
        payload = BatchDownloadLinkIn(asset_ids=list(ids))
        with pytest.raises(HTTPException) as ei:
            await call_batch(
                monkeypatch, payload, user=user, assets=preset,
                denied_ids=[x.id for x in preset],
                audit=audit, redis=redis, pool=pool,
            )
        assert ei.value.status_code == 403

    per_asset: dict[str, int] = {}
    for e in audit.of_type("download_denied"):
        k = str(e.get("target_asset_id"))
        per_asset[k] = per_asset.get(k, 0) + 1
    assert per_asset == {str(a.id): 2, str(b.id): 1, str(c.id): 1}, (
        f"同集轮询去重、异选集首评: {per_asset!r}"
    )
    for sel in ([str(a.id), str(b.id)], [str(a.id), str(c.id)]):
        assert redis.alive(batch_audited_key(str(user.id), sel)), f"去重键未落下: {sel!r}"


class WritebackRedis:
    """writeback Lua 语义等价桩(仓库无 fakeredis 依赖,不新增 pip 包):
    实现 writeback 所用命令子集(GET + JSON 字段级合并 + KEEPTTL);eval 先钉
    实际下发的 Lua 文本(含 GET 门 / KEEPTTL / 字段名,布局变化即显式失败),
    再按脚本等价语义执行:记录存在才改、TTL 截止时刻原样保留、过期不复活。"""

    def __init__(self) -> None:
        self.store: dict[str, tuple[str, float]] = {}
        self.scripts: list[str] = []

    def seed(self, name: str, value: str, ttl: int = 600) -> None:
        self.store[name] = (value, time.time() + ttl)

    async def eval(self, script: Any, numkeys: int = 0, *keys_and_args: Any, **kw: Any) -> int:
        text = str(script)
        self.scripts.append(text)
        assert "GET" in text, "回写 Lua 必须先 GET(记录存在才写,过期不复活)"
        assert "KEEPTTL" in text, "回写 Lua 必须 KEEPTTL(不重置回放窗 TTL)"
        assert "livp_raw_count_actual" in text, "回写 Lua 必须字段级合并实际计数"
        key, count = str(keys_and_args[0]), int(keys_and_args[1])
        item = self.store.get(key)
        if item is None:
            return 0                                   # 记录已过期:跳过
        obj = json.loads(item[0])
        obj["livp_raw_count_actual"] = count
        self.store[key] = (json.dumps(obj), item[1])   # KEEPTTL:截止时刻不动
        return 1


async def test_writeback_livp_raw_count_lua_semantics_merge_keeps_ttl() -> None:
    """A7:回写 Lua 语义 —— 记录存在才写;字段级合并(其余字段原样);已有
    livp_raw_count_actual 被新实际计数覆盖;KEEPTTL 不重置 TTL。"""
    uid, key = str(uuid.uuid4()), "0123456789abcdef"
    name = batch_job_record_key(uid, key)
    r = WritebackRedis()
    r.seed(name, json.dumps({
        "livp_raw_count": 1, "selection_ids": ["x"], "livp_raw_count_actual": 1,
    }), ttl=1000)
    deadline_before = r.store[name][1]

    ok = await writeback_livp_raw_count(r, uid, key, 3)

    assert ok is True
    obj = json.loads(r.store[name][0])
    assert obj["livp_raw_count_actual"] == 3, "新实际计数覆盖旧值"
    assert obj["livp_raw_count"] == 1 and obj["selection_ids"] == ["x"], "其余字段不丢"
    assert r.store[name][1] == deadline_before, "KEEPTTL:回写不得重置 TTL"
    assert len(r.scripts) == 1


async def test_writeback_livp_raw_count_expired_record_not_revived() -> None:
    """A7:记录已过期(打包完成晚于 EX 3600 的常态边缘)→ 返回 False 跳过,
    不得把过期键复活(SET 复活 = 无 TTL 键永久泄漏)。"""
    uid, key = str(uuid.uuid4()), "0123456789abcdef"
    r = WritebackRedis()

    ok = await writeback_livp_raw_count(r, uid, key, 2)

    assert ok is False
    assert batch_job_record_key(uid, key) not in r.store, "过期记录不得被回写复活"


async def test_writeback_livp_raw_count_redis_error_returns_false() -> None:
    """A7:Redis 故障 → 只 log 不上抛,返回 False(非交付路径,响应退回静态判定)。"""

    class BoomRedis:
        async def eval(self, *a: Any, **kw: Any) -> int:
            raise RuntimeError("redis down")

    ok = await writeback_livp_raw_count(BoomRedis(), str(uuid.uuid4()), "0123456789abcdef", 1)

    assert ok is False


async def test_ready_response_prefers_livp_raw_count_actual(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A7:ready 响应 livp_raw_count 以 job 回写的 livp_raw_count_actual 优先
    (§6.2 第 6 步:轮询期就绪位翻转时静态判定与实际包内容有偏差);记录无该
    字段(job 未回写/记录重建)回落 tags 静态判定值。"""
    lv = mk_batch_asset("IMG_0001.livp")   # 未就绪 → 静态判定 livp_raw_count=1
    w = BatchWorld(monkeypatch, assets=[lv])

    first = await w.post([lv.id])
    key = fld(first.out, "key")
    assert fld(first.out, "livp_raw_count") == 1, "首响应按 tags 静态判定"
    rec_name = batch_job_record_key(str(w.user.id), key)
    record = json.loads(await w.redis.get(rec_name))
    w.presign.hit(zip_object_key_candidates(key), age_seconds=60)
    w.clear_locks(key)

    fallback = await w.post([lv.id], resume_key=key)
    assert fld(fallback.out, "status") == "ready"
    assert fld(fallback.out, "livp_raw_count") == 1, "无回写字段 → 回落静态判定"

    record["livp_raw_count_actual"] = 3   # 模拟 job 回写(实际打包计数)
    w.redis.seed(rec_name, json.dumps(record), 3600)

    actual = await w.post([lv.id], resume_key=key)
    assert fld(actual.out, "livp_raw_count") == 3, "回写后 ready 以实际计数为准"
