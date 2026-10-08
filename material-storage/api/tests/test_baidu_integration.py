"""百度网盘备份导入 — DB 容器集成层(真实 PG/Redis/MinIO + 进程级故障注入)。

对应方案(最高权威):rushes-spec/material-storage/baidu-netdisk-backup-plan.md
§10 批次 5「DB 容器集成」清单,**逐条落成测试函数**(每条标注【集成】与 P0/P1 档)。
运行方式:`docker exec ms-api pytest tests/test_baidu_integration.py -v`;
PG/Redis/MinIO 任一不可达 → 模块级 skip;进程级故障注入类(SIGTERM/kill -9/双 runner
竞速)另需批次 5 前置交付物(可 spawn 的 arq worker + 百度 HTTP 桩),不就绪时单独 skip。

被测实现已于 2026-10-08 对齐落地 —— 预写名经本文件顶部「实现名适配层」包装,
collection 必须通过;真实 PG/Redis/MinIO 的执行留待下一阶段(任一不可达 → 模块级
skip;进程级故障注入类另需 Settings 级百度端点注入,未就绪时单独 skip)。

记号说明:方案 §10 的集成层标注(方案中用一对龟甲括号包围「集成」二字)在本仓
统一写作「【集成】」——原括号字符触发 ruff RUF002 ambiguous-unicode,语义等同。

■ P0 档(方案钦定四类必过:租约 CAS / 接管续跑 / 回摆并发 / kill -9 恢复)
| 方案清单项                                   | 测试 |
|----------------------------------------------|------|
| 派发后 job 真正启动认领(expected_seq)【集成】 | test_p0_job_claim_expected_seq_cas |
| 旧 runner 被接管后续期 CAS 失败即中止(不得再写 part)【集成】 | test_p0_old_runner_stops_after_takeover_no_part_write |
| kill -9 后租约过期接管续跑(importing 行复位 pending 续跑至 success)【集成】 | test_p0_kill9_lease_expiry_takeover_resume_to_success |
| overwrite 回摆与 DELETE 并发:仅一侧生效(DELETE 终态 CAS)【集成】 | test_p0_delete_terminal_cas_vs_overwrite_swingback_concurrent |

■ P1 档(其余清单项,随批次摊入)
| 方案清单项                                                    | 测试 |
|---------------------------------------------------------------|------|
| 绑定流(code 换 token 加密落库 + uinfo NOT NULL + audit)      | test_binding_flow_roundtrip_encrypted_at_rest |
| 重新授权同 uid → 跳过断点作废(仅清 dlink 缓存)              | test_binding_reauthorize_same_uid_skips_breakpoint_invalidation |
| 权限 403(创建校验 can_upload + access_denied 审计)           | test_create_task_without_can_upload_403_access_denied_audit |
| sensitive 禁选 403(文案不含"敏感"字样)                      | test_create_task_explicit_sensitive_target_403_no_sensitive_wording |
| 敏感祖先 403(沿 parent 链向上核查,创建期快败)               | test_create_task_sensitive_ancestor_403_fast_fail |
| source_dir 护栏(/ 拒绝/相对路径/≤600/承接夹名>255→400/target 归属) | test_create_task_source_dir_guards_400 |
| netdisk folders 绑定非 active 409(binding_inactive)         | test_binding_inactive_409_on_netdisk_folders |
| 枚举重跑 ON CONFLICT 幂等(不重置已有行状态)【集成】          | test_enum_on_conflict_idempotent_preserves_row_states |
| 枚举频控耗尽失败 → 复活后重枚举补全 manifest(enum_done=false) | test_enum_rate_limited_revival_reenumerates_completes_manifest |
| manifest_too_large 复活后再次失败而非全量导入                | test_manifest_too_large_revival_fails_again_without_full_import |
| 空目录 → 直接 completed(0 行 manifest)                      | test_empty_source_dir_completes_marked_empty |
| rel_path 带子目录的同名文件命中 skipped_exists(承接夹同名不误判)【集成】 | test_rel_path_subdir_same_name_skipped_exists_no_wrong_skip |
| manifest 状态机 skip/retry/overwrite/cancel                   | test_manifest_status_transitions_skip_retry_overwrite_cancel |
| 终态判定(failed_files>0→failed / cancelled 优先 / 否则 completed) | test_final_state_matrix_failed_cancelled_completed |
| 部分文件退避耗尽 → 任务 failed、失败行可复活(终态判定规则)  | test_rate_limit_exhausted_task_failed_rows_revivable |
| completed 任务 overwrite 回摆 completed(计数迁移 skipped-1/success+1/done 不变) | test_overwrite_swingback_completed_count_migration |
| 回摆期间该行再次失败 → 任务按通用终态判定转 failed            | test_swingback_row_refail_task_failed |
| completed 任务带残留 cancel_requested → overwrite 复活 → completed(取消位复位)【集成】 | test_completed_with_stale_cancel_requested_overwrite_recovers |
| 复活统一前置复位(fail_reason/cancel 位/attempts=0/retry_count+1) | test_manual_revival_resets_attempts_and_flags |
| 复活型接口统一前置 409 矩阵(expired/活动互斥/目标夹删/换绑 uid) | test_revival_conflict_409_matrix |
| cancelled 任务 retry/overwrite 返回 409(用户终态不得复活)    | test_cancelled_task_retry_and_overwrite_409 |
| 单文件 retry 不触碰其他 failed 行                             | test_single_file_retry_touches_only_target_row |
| 覆盖导入走物理 purge(旧 asset 删行+对象删除+asset_purged 审计;断言并入回摆计数用例) | test_overwrite_swingback_completed_count_migration |
| overwrite 无 can_admin → failed('overwrite_forbidden')(清 overwrite 标志) | test_overwrite_forbidden_without_can_admin_clears_flag |
| overwrite(防御性)sensitive 目标 → failed('overwrite_forbidden') | test_overwrite_defensive_sensitive_target_failed |
| overwrite 同夹同名多行 → failed('overwrite_ambiguous')       | test_overwrite_ambiguous_same_folder_duplicate_rows |
| 跨资产 key 引用预检(含软删行)→ failed('overwrite_ambiguous') | test_overwrite_cross_asset_key_reference_ambiguous |
| purge 未证实 → failed('purge_incomplete')可重试、覆盖行禁用 head 快捷路径 | test_overwrite_purge_incomplete_retry_no_head_shortcut |
| 换绑(不同 uid)后名下残留 minio_upload_id 全部作废(abort+清零) | test_rebind_different_uid_invalidates_leftover_breakpoints |
| 软解绑:行保留 + 断点作废 + 活动任务取消(binding_replaced)   | test_unbind_soft_deletes_and_invalidates_breakpoints |
| 换绑后 retry 不复用旧 multipart(从 0 重传)                  | test_retry_after_rebind_does_not_reuse_old_multipart |
| 绑定切换时在途 runner ≤一个检查点周期停止【集成】            | test_binding_replaced_stops_runner_within_checkpoint |
| 创建后未派发(dispatched_at=NULL)→ sweeper 接管【集成】      | test_sweeper_takeover_never_dispatched |
| 入队失败/Redis 队列丢失 → sweeper 下一轮必须接管【集成】     | test_enqueue_failure_queue_loss_sweeper_takeover_next_round |
| 入队返回 None 分支(不重试派发步,交 sweeper)【集成】         | test_enqueue_returns_none_branch |
| sweeper 对 cancel_requested+无租约直接终态化【集成】          | test_sweeper_cancel_requested_direct_finalize |
| 同任务并发互斥(partial index + 应用层检查双层)【集成】       | test_concurrent_active_mutex_partial_index_and_app_layer |
| ≥3 排队任务同轮派发:确定性准入恰 2 运行、其余可最终认领【集成】 | test_admission_three_queued_top2_deterministic |
| multipart 断点续传真实恢复(bytes_done 偏移续传)【集成】      | test_multipart_breakpoint_real_resume_from_bytes_done |
| 死会话(NoSuchUpload)自动清零重传【集成】                     | test_dead_session_no_such_upload_resets_retransmit |
| complete 后崩溃(upload_id 已死)→ 接管后 head 命中直接落库【集成】 | test_crash_after_complete_head_hit_finalizes_asset |
| head 命中路径含同夹同名软删行占位 → failed('overwrite_ambiguous')【集成】 | test_head_hit_with_soft_deleted_same_name_ambiguous |
| 零字节文件 put_object 直传【集成】                            | test_zero_byte_file_put_object_direct |
| size 不符 → failed('size_mismatch')拦截(断点错位不落库)【集成】 | test_size_mismatch_row_failed_intercepted |
| >1000 parts 死会话接管续传不回退(直 seed 1001x5MiB + mock 下载流)【集成】 | test_seed_1001_parts_takeover_resume_no_rollback |
| 55min 接力:单 job 超时不中断任务(新 job 认领续跑)【集成】   | test_relay_checkpoint_hands_off_new_job_continues |
| 单文件下载中途 55min 接力,importing 行复位后从断点续传至 success【集成】 | test_relay_mid_file_importing_row_reset_resume_to_success |
| cancel_requested 与 48h 超时同帧命中 → cancelled(检查点优先级)【集成】 | test_checkpoint_priority_cancel_beats_timeout_and_relay |
| 健康接力链跨 48h 被 runner 检查点自终态化 failed('timeout')(主路径判停)【集成】 | test_round_timeout_runner_self_finalize_on_healthy_relay_chain |
| 超时任务不被 sweeper 无限复活(故障路径兜底)【集成】          | test_timed_out_task_not_infinitely_revived_by_sweeper |
| 排队期豁免:门控退出任务不被判超时(round_started_at 已复位)【集成】 | test_gate_exit_exemption_round_started_reset_not_timeout |
| retry 复活后 round_started_at 归零、排队期能正常认领续跑【集成】 | test_retry_revival_resets_round_started_then_claims_and_runs |
| 部署重启(SIGTERM cancel)在途任务不误标 timeout、sweeper 接管续跑【集成】 | test_sigterm_restart_no_false_timeout_sweeper_takeover |
| 急停 failed('feature_disabled'):断点保留、重开后 retry-failed 断点续传【集成】 | test_kill_switch_feature_disabled_preserves_breakpoints_then_resumes |
| cancel CAS 快路径 {finalized:true} / 活跃租约回落 {finalized:false} | test_cancel_fast_path_finalized_and_fallback_flag_path |
| cancel 已终态 409(防回落路径留脏 cancel_requested)          | test_cancel_terminal_409 |
| DELETE 终态 CAS(running 一律 409;终态 204)                  | test_delete_running_409_terminal_204 |
| 数百 failed 行任务 DELETE 不超时、清理行为符合 budget 分支(≤20/​>20) | test_delete_budget_branches_inline_abort_small_and_large |
| 非 admin 创建者对导入产物有可见性(建链写了 parent tuple)【集成】 | test_non_admin_creator_visibility_after_nested_import |
| 直删 tuple 后重试可自愈(复用分支 ensure tuple)【集成】       | test_deleted_parent_tuple_self_heal_on_retry |
| 显式目标夹被删 → failed('target_deleted');auto_created → 在途重建【集成】 | test_explicit_target_deleted_row_failed_vs_autocreated_rebuild |
| worker 每文件权限复查被撤 → failed('target_permission_denied')可重试 | test_worker_per_file_permission_revoke_row_failed_target_permission_denied |

■ 预写命名约定(实现落地若命名不同,PM 验收阶段统一调整 import)
- app.db.tables:BaiduBinding / BaiduBackupTask / BaiduBackupTaskFile(§4 三表,列名同方案)
- app.services.baidu_backup(§5.1 任务域服务):
    dispatch_baidu_task(db, task_id, *, sweeper=False, revive=False) -> bool   # §6 派发步 CAS
    claim_baidu_task(db, task_id, expected_seq, runner_id) -> bool             # §6 认领 CAS
    renew_baidu_lease(db, task_id, expected_seq, runner_id) -> bool            # §6 续期 CAS
    ensure_folder_chain(db, permissions, project_id, root_folder_id, rel_path_parts)
    abort_leftover_sessions(rows, budget=20)                                   # §5.2 统一口径 helper
- app.services.baidu_client.BaiduNetdiskClient(settings):list_dir/filemetas_batch/
  stream_download/refresh_token/exchange_code/uinfo(listall 未实现,枚举走 list_dir BFS)
- app.services.asset_purge.purge_active_asset(db, permissions, presign, audit, ...)  # §5.1 活跃 asset 物理删除
- app.workers.baidu_backup:baidu_backup_run(ctx, task_id, expected_seq) /
  sweep_stalled_baidu_tasks(ctx)(注册进 workers/main.WorkerSettings.functions)
- app.routers.baidu_backup 挂 /api/v1/baidu,受 settings.baidu_backup_enabled 门控
- settings 时延常量(§10 批次 3):baidu_lease_s / baidu_sweep_throttle_s /
  baidu_relay_after_s / baidu_round_timeout_s(集成注入秒级值,否则接力/48h 不可执行)

■ 预写名 ↔ 实现名对照(2026-10-08 对齐落地实现;调用点保持预写形态,由本文件
  顶部「适配层」包装)
- app.services.baidu_backup:dispatch_and_enqueue(db, pool, *, task_id, mode=
  "create"/"revive"/"sweep", now, throttle_s)(预写 dispatch_baidu_task(db, id,
  sweeper=))、claim_task(db, *, task_id, expected_seq, runner_id, now, lease_s)
  (预写 claim_baidu_task)、renew_lease(...)-> RenewState | None(预写
  renew_baidu_lease -> bool);适配层补 now/lease_s/throttle_s 与 arq pool 注入。
- app.services.baidu_client:BaiduNetdiskClient(预写 BaiduClient)、
  classify_baidu_failure(*, http_status, errno)、strip_url_query(即 sanitize_url)、
  host_allowed(即 is_allowed_redirect_host);BaiduApiError(category, message,
  errno=None, http_status=None);stream_download(access_token, dlink, *,
  range_header=...)(预写 download_stream);listall 未实现 → 枚举走 list_dir
  (返回 BaiduListResult);无 RATE_LIMIT_ERRNOS 常量。
- app.services.token_crypto:TokenCryptoService(settings).encrypt/.decrypt +
  derive_fernet_key / encrypt_str / decrypt_str / TokenDecryptError(预写
  encrypt_token(plaintext, settings) / decrypt_token(ct, settings);适配层提供
  同名单参函数)。
- app.services.folder_chain:ensure_folder_chain(db, permissions, *, project_id,
  root_folder_id, rel_dir_parts, leaf_name=None, memo=None)(预写 rel_path_parts
  位置参)、ensure_root_folder_at_project、guard_rel_path / guard_file_size。
- app.services.baidu_storage:AsyncObjectStore(worker 侧 aioboto3 封装);
  app.services.asset_purge:purge_active_asset(db, *, permissions, presign, audit,
  asset_id, actor_user_id, audit_details)+ PurgeIncompleteError。
- app.routers.baidu_backup:挂 /api/v1/baidu;14 条路由与本文件预写路径一致;
  settings 字段一致(baidu_backup_enabled/baidu_lease_s/baidu_relay_after_s/
  baidu_round_timeout_s/baidu_sweep_throttle_s/baidu_part_size_bytes/
  baidu_token_enc_key/baidu_app_key/baidu_app_secret)。
- 进程级故障注入基建:baidu_openapi_base_url / baidu_pan_base_url 未收进 Settings
  → _require_fault_infra 命中即 skip(§10 批次 5 前置交付物,留给下一阶段)。
"""
from __future__ import annotations

import asyncio
import contextlib
import os
import subprocess
import sys
import threading
import time
import uuid
from collections.abc import AsyncIterator, Callable
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import pytest

from app.db.session import get_sessionmaker
from app.db.tables import (
    Asset,
    AuditEvent,
    BaiduBackupTask,
    BaiduBackupTaskFile,
    BaiduBinding,
    Folder,
    Organization,
    Project,
    User,
)
from app.main import create_app
from app.services import baidu_client as baidu_client_module
from app.services.baidu_backup import (
    claim_task,
    dispatch_and_enqueue,
    renew_lease,
)
from app.services.baidu_client import (
    CATEGORY_RATE_LIMITED,
    BaiduApiError,
    BaiduListResult,
    BaiduTokenPair,
    BaiduUserInfo,
)
from app.services.permissions import PermissionsService
from app.services.token_crypto import TokenCryptoService
from app.settings import get_settings
from app.workers.baidu_backup import baidu_backup_run, sweep_stalled_baidu_tasks

API_DIR = Path(__file__).resolve().parents[1]
NOW = datetime.now(UTC)
MB = 1024 * 1024


# ─── 实现名适配层(预写调用点形态不变;补 now/lease_s/加密服务/arq pool)────────
_CRYPTO_SERVICE: TokenCryptoService | None = None
_ARQ_POOL: Any = None


def _crypto() -> TokenCryptoService:
    global _CRYPTO_SERVICE
    if _CRYPTO_SERVICE is None:
        _CRYPTO_SERVICE = TokenCryptoService(get_settings())
    return _CRYPTO_SERVICE


def encrypt_token(plaintext: str) -> str:
    """预写 encrypt_token(plaintext, settings) 的对齐形态(TokenCryptoService)。"""
    return _crypto().encrypt(plaintext)


def decrypt_token(ciphertext: str) -> str:
    """预写 decrypt_token(ciphertext, settings) 的对齐形态(TokenCryptoService)。"""
    return _crypto().decrypt(ciphertext)


async def _arq_pool() -> Any:
    """惰性创建共享 ArqRedis(派发入队 / sweeper ctx.redis;stack 门控后调用)。"""
    global _ARQ_POOL
    if _ARQ_POOL is None:
        from arq import create_pool
        from arq.connections import RedisSettings

        _ARQ_POOL = await create_pool(RedisSettings.from_dsn(str(get_settings().redis_url)))
    return _ARQ_POOL


async def dispatch_baidu_task(db: Any, task_id: uuid.UUID, *, sweeper: bool = False,
                              revive: bool = False) -> bool:
    """§6 派发步 CAS + 入队(预写 dispatch_baidu_task 的对齐形态)。"""
    mode = "sweep" if sweeper else ("revive" if revive else "create")
    s = get_settings()
    outcome = await dispatch_and_enqueue(
        db, await _arq_pool(), task_id=task_id, mode=mode,
        now=datetime.now(UTC), throttle_s=s.baidu_sweep_throttle_s,
    )
    return outcome.seq is not None


async def claim_baidu_task(db: Any, task_id: uuid.UUID, expected_seq: int,
                           runner_id: str) -> bool:
    """§6 认领 CAS(预写 claim_baidu_task 的对齐形态)。"""
    s = get_settings()
    return await claim_task(
        db, task_id=task_id, expected_seq=expected_seq, runner_id=runner_id,
        now=datetime.now(UTC), lease_s=s.baidu_lease_s,
    )


async def renew_baidu_lease(db: Any, task_id: uuid.UUID, expected_seq: int,
                            runner_id: str) -> bool:
    """§6 续期 CAS(预写 renew_baidu_lease 的对齐形态;None → False)。"""
    s = get_settings()
    state = await renew_lease(
        db, task_id=task_id, expected_seq=expected_seq, runner_id=runner_id,
        now=datetime.now(UTC), lease_s=s.baidu_lease_s,
    )
    return state is not None


async def _sweep_now() -> dict[str, int]:
    """sweeper 需 ctx.redis 才会入队(缺池时只派发不入队);统一注入共享池。"""
    return await sweep_stalled_baidu_tasks({"redis": await _arq_pool()})


# ════════════════════════════ 门控与基础设施 ═══════════════════════════════════
@pytest.fixture(scope="session")
async def stack():
    """PG+Redis+MinIO 三栈探测;任一不可达 → 整个模块 skip(门控与仓库既有集成测试同款)。"""
    from sqlalchemy import text

    engine = _make_engine()
    try:
        async with engine.connect() as conn:
            await conn.execute(text("SELECT 1"))
        await engine.dispose()
    except Exception as exc:
        await engine.dispose()
        pytest.skip(f"no reachable PG — baidu integration tests skipped: {exc}")

    try:
        import redis.asyncio as aioredis

        r = aioredis.from_url(str(get_settings().redis_url), decode_responses=True)
        try:
            await r.ping()
        finally:
            await r.aclose()
    except Exception as exc:
        pytest.skip(f"no reachable Redis — baidu integration tests skipped: {exc}")

    try:
        await asyncio.to_thread(_minio_list_buckets)
    except Exception as exc:
        pytest.skip(f"no reachable MinIO — baidu integration tests skipped: {exc}")
    yield


def _make_engine():
    from sqlalchemy.ext.asyncio import create_async_engine

    return create_async_engine(str(get_settings().db_url))


def _minio_list_buckets() -> list[str]:
    import boto3

    s = get_settings()
    c = boto3.client(
        "s3",
        endpoint_url=s.minio_endpoint_internal,
        aws_access_key_id=s.minio_access_key,
        aws_secret_access_key=s.minio_secret_key,
        region_name="us-east-1",
    )
    return [b["Name"] for b in c.list_buckets().get("Buckets", [])]


def _minio_client():
    import boto3

    s = get_settings()
    return boto3.client(
        "s3",
        endpoint_url=s.minio_endpoint_internal,
        aws_access_key_id=s.minio_access_key,
        aws_secret_access_key=s.minio_secret_key,
        region_name="us-east-1",
    )


@asynccontextmanager
async def _db():
    """独立短会话(避免跨 fixture 共享 session 的未提交可见性问题)。"""
    async with get_sessionmaker()() as s:
        yield s


async def _eventually(pred: Callable[[], Any], timeout: float = 15.0, interval: float = 0.1) -> bool:  # noqa: ASYNC109
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if await pred():
            return True
        await asyncio.sleep(interval)
    return False


def _inject_delay(monkeypatch: pytest.MonkeyPatch, settings_key: str, const_name: str, value: float) -> None:
    """时延注入:优先 settings 属性(批次 3 落地形态),回落 worker 模块常量。"""
    s = get_settings()
    if hasattr(s, settings_key):
        monkeypatch.setattr(s, settings_key, value, raising=False)
    mod = sys.modules.get("app.workers.baidu_backup")
    if mod is not None and hasattr(mod, const_name):
        monkeypatch.setattr(mod, const_name, value)


def _set_feature_flag(monkeypatch: pytest.MonkeyPatch, enabled: bool) -> None:
    s = get_settings()
    if hasattr(s, "baidu_backup_enabled"):
        monkeypatch.setattr(s, "baidu_backup_enabled", enabled, raising=False)
    mod = sys.modules.get("app.workers.baidu_backup")
    for const in ("BAIDU_BACKUP_ENABLED", "FEATURE_ENABLED"):
        if mod is not None and hasattr(mod, const):
            monkeypatch.setattr(mod, const, enabled)


@pytest.fixture(autouse=True)
def _fast_baidu_delays(monkeypatch: pytest.MonkeyPatch):
    """默认注入秒级时延(方案 §10 批次 3:生产默认 3300/172800/60/600,集成注入秒级)。"""
    _inject_delay(monkeypatch, "baidu_lease_s", "BAIDU_LEASE_S", 5)
    _inject_delay(monkeypatch, "baidu_sweep_throttle_s", "BAIDU_SWEEP_THROTTLE_S", 1)
    _inject_delay(monkeypatch, "baidu_relay_after_s", "BAIDU_RELAY_AFTER_S", 3600)
    _inject_delay(monkeypatch, "baidu_round_timeout_s", "BAIDU_ROUND_TIMEOUT_S", 172800)
    yield


# ════════════════════════════ 世界脚手架 ═══════════════════════════════════════
@dataclass
class World:
    org: Organization
    admin: User            # 项目 admin(覆盖 can_admin 路径)
    member: User           # 项目 uploader(普通创建者)
    outsider: User         # 无任何 grant(403 用)
    project: Project
    folder: Folder         # 项目根下普通目录(默认导入目标)
    sensitive: Folder      # sensitive 目录(禁选)
    binding: BaiduBinding
    _fga_user_ids: list[str] = field(default_factory=list)


async def _fga_write(perms: PermissionsService, tuples: list[tuple[str, str, str]]) -> None:
    from openfga_sdk.models import ClientTuple, ClientWriteRequest

    await perms._client.write(ClientWriteRequest(writes=[ClientTuple(user=u, relation=r, object=o) for u, r, o in tuples]))


@pytest.fixture
async def world(stack):
    """org + 3 用户 + project + 根目录 + sensitive 目录 + active binding(逐测试清理)。"""
    tag = uuid.uuid4().hex[:8]
    perms = PermissionsService(get_settings())
    created: dict[str, Any] = {}
    fga_user_ids: list[str] = []
    try:
        async with _db() as db:
            org = Organization(name=f"it-baidu-{tag}", feishu_tenant_key=f"it_baidu_{tag}")
            db.add(org)
            await db.flush()
            users = {
                kind: User(
                    name=f"it-baidu-{kind}-{tag}",
                    email=f"it-baidu-{kind}-{tag}@example.com",
                    organization_id=org.id,
                )
                for kind in ("admin", "member", "outsider")
            }
            db.add_all(users.values())
            project = Project(
                organization_id=org.id,
                code=f"itbaidu_{tag}",
                name=f"it-baidu-project-{tag}",
                minio_bucket=f"it-baidu-{tag}",
                visibility="private",
            )
            db.add(project)
            await db.flush()
            folder = Folder(project_id=project.id, name="target-root", minio_prefix="target-root/")
            sensitive = Folder(project_id=project.id, name="secret", minio_prefix="secret/", is_sensitive=True)
            db.add_all([folder, sensitive])
            await db.flush()
            binding = BaiduBinding(
                user_id=users["member"].id,
                access_token_enc=encrypt_token("it-access-token"),
                refresh_token_enc=encrypt_token("it-refresh-token"),
                baidu_uid="100",
                nickname="it-binding",
                access_token_expires_at=NOW + timedelta(days=30),
                status="active",
                last_authorized_at=NOW,
                token_rotated_at=NOW,
            )
            db.add(binding)
            await db.commit()
            created.update(org=org, project=project, folder=folder,
                           sensitive=sensitive, binding=binding, users=users)
            fga_user_ids = [str(u.id) for u in users.values()]

        # MinIO bucket(直接建,DB 直插的 project 无建桶流程)
        s3 = _minio_client()
        try:
            s3.head_bucket(Bucket=project.minio_bucket)
        except Exception:
            s3.create_bucket(Bucket=project.minio_bucket)

        # FGA:project→org/创建者 admin、folder parent、成员 uploader、admin 角色
        await _fga_write(perms, [
            (f"organization:{org.feishu_tenant_key}", "org", f"project:{project.id}"),
            (f"user:{users['admin'].id}", "admin", f"project:{project.id}"),
            (f"project:{project.id}", "parent", f"folder:{folder.id}"),
            (f"project:{project.id}", "parent", f"sensitive_folder:{sensitive.id}"),
        ])
        await perms.add_project_subject(project_id=str(project.id), subject=f"user:{users['member'].id}", role="uploader")
        await perms.grant_folder_explicit_subject(folder_id=str(folder.id), subject=f"user:{users['member'].id}", kind="explicit_uploader")
        w = World(org=org, admin=users["admin"], member=users["member"], outsider=users["outsider"],
                  project=project, folder=folder, sensitive=sensitive, binding=binding)
        w._fga_user_ids = fga_user_ids
        yield w
    finally:
        # FGA 清理(用户维 tuple;project/folder 级 tuple 随 DB 删除残留于 dev store,无害)
        for uid in fga_user_ids:
            with contextlib.suppress(Exception):
                await perms.revoke_user_completely(uid)
        await perms.close()
        # DB 清理顺序:assets(RESTRICT folder) → task_files → tasks → bindings → folders
        #   → project → users → org(均按本测试创建的范围,不碰共享容器其他数据)
        if created:
            from sqlalchemy import select

            async with _db() as db:
                folder_ids = (await db.execute(
                    select(Folder.id).where(Folder.project_id == created["project"].id)
                )).scalars().all()
                await db.execute(Asset.__table__.delete().where(Asset.folder_id.in_(folder_ids)))
                task_ids = (await db.execute(
                    select(BaiduBackupTask.id).where(BaiduBackupTask.project_id == created["project"].id)
                )).scalars().all()
                if task_ids:
                    await db.execute(BaiduBackupTaskFile.__table__.delete().where(
                        BaiduBackupTaskFile.task_id.in_(task_ids)))
                await db.execute(BaiduBackupTask.__table__.delete().where(
                    BaiduBackupTask.project_id == created["project"].id))
                await db.execute(BaiduBinding.__table__.delete().where(
                    BaiduBinding.id == created["binding"].id))
                await db.execute(Folder.__table__.delete().where(Folder.project_id == created["project"].id))
                await db.execute(Project.__table__.delete().where(Project.id == created["project"].id))
                await db.execute(User.__table__.delete().where(User.id.in_([u.id for u in created["users"].values()])))
                await db.execute(Organization.__table__.delete().where(Organization.id == created["org"].id))
                await db.commit()


# ─── 任务/文件行构造 ───────────────────────────────────────────────────────────
async def _mk_task(world: World, *, status: str = "running", enum_done: bool = True,
                   auto_created: bool = False, source_dir: str = "/it-src",
                   target: Folder | None = None, uid_snapshot: str = "100",
                   lease_seq: int = 0, **overrides: Any) -> BaiduBackupTask:
    if target is None:
        target = world.folder
    t = BaiduBackupTask(
        user_id=world.member.id,
        binding_id=world.binding.id,
        bound_baidu_uid=uid_snapshot,
        source_dir=source_dir,
        project_id=world.project.id,
        target_folder_id=target.id,
        target_auto_created=auto_created,
        status=status,
        lease_seq=lease_seq,
        total_files=0, done_files=0, failed_files=0, skipped_files=0, cancelled_files=0,
        total_bytes=0, done_bytes=0, speed_bps=0, speed_anchor_bytes=0,
    )
    for k, v in overrides.items():
        setattr(t, k, v)
    async with _db() as db:
        db.add(t)
        await db.commit()
        await db.refresh(t)
    return t


async def _mk_file(task: BaiduBackupTask, rel_path: str, *, size: int = 1024,
                   status: str = "pending", **overrides: Any) -> BaiduBackupTaskFile:
    f = BaiduBackupTaskFile(
        task_id=task.id,
        fs_id=random_fsid(),
        source_path=f"{task.source_dir}/{rel_path}",
        source_size=size,
        rel_path=rel_path,
        status=status,
        bytes_done=0,
    )
    for k, v in overrides.items():
        setattr(f, k, v)
    async with _db() as db:
        db.add(f)
        await db.commit()
        await db.refresh(f)
    return f


def random_fsid() -> int:
    return int(uuid.uuid4().int % 10**15)


async def _get_task(task_id: uuid.UUID) -> BaiduBackupTask | None:
    async with _db() as db:
        return await db.get(BaiduBackupTask, task_id)


async def _get_file(fid: uuid.UUID) -> BaiduBackupTaskFile | None:
    async with _db() as db:
        return await db.get(BaiduBackupTaskFile, fid)


async def _files_of(task_id: uuid.UUID) -> list[BaiduBackupTaskFile]:
    from sqlalchemy import select

    async with _db() as db:
        rows = (await db.execute(
            select(BaiduBackupTaskFile).where(BaiduBackupTaskFile.task_id == task_id)
        )).scalars().all()
        db.expunge_all()
        return list(rows)


async def _touch_task(task_id: uuid.UUID, **values: Any) -> None:
    from sqlalchemy import update

    async with _db() as db:
        await db.execute(update(BaiduBackupTask).where(BaiduBackupTask.id == task_id).values(**values))
        await db.commit()


async def _run_job(task_id: uuid.UUID, expected_seq: int) -> None:
    """进程内直呼 job(不经 arq;进程级故障注入类用例走 _spawn_worker)。"""
    await baidu_backup_run({}, str(task_id), expected_seq)


# ─── 百度客户端 mock(进程内,monkeypatch 类方法)───────────────────────────────
class BaiduScript:
    """脚本化网盘交互:内容按 fs_id 存取;下载可注入错误/慢速;记录 Range。

    以 BaiduNetdiskClient 的真实方法签名挂类替换:stream_download(access_token,
    dlink, *, range_header=...)/filemetas_batch(access_token, fsids, *, dlink)/
    list_dir(access_token, dir_path, *, folders_only=False, max_pages=10)。
    """

    def __init__(self) -> None:
        self.bodies: dict[int, bytes] = {}
        self.tail_only: dict[int, tuple[int, bytes]] = {}   # fs_id → (total_size, tail_bytes)
        self.fail_first: dict[int, list[Exception]] = {}   # fs_id → 前置错误队列
        self.download_calls: list[tuple[int, int | None]] = []  # (fs_id, range_start)
        self.filemetas_calls = 0
        self.listing: list[dict[str, Any]] = []            # list_dir 输出(fs_id/path/size/isdir)
        self.chunk_delay = 0.0
        self.list_error: Exception | None = None

    def add(self, fs_id: int, content: bytes) -> None:
        self.bodies[fs_id] = content

    async def stream_download(self, _self: Any, _access_token: str, dlink: str, *,
                              range_header: str | None = None,
                              **_kwargs: Any) -> AsyncIterator[bytes]:
        fs_id = int(dlink.rstrip("/").rsplit("/", 1)[-1])
        start = 0
        if range_header:
            start = int(str(range_header).split("-")[0].lstrip("bytes=").split("=")[-1] or 0)
        self.download_calls.append((fs_id, start))
        if self.fail_first.get(fs_id):
            raise self.fail_first[fs_id].pop(0)
        if fs_id in self.tail_only:
            total, tail = self.tail_only[fs_id]
            if start != total - len(tail):
                raise AssertionError(f"断点回退: range start={start}, 期望 {total - len(tail)}(不回退口径)")
            yield tail
            return
        body = self.bodies.get(fs_id, b"")
        chunk = 64 * 1024
        for off in range(start, len(body), chunk):
            if self.chunk_delay:
                await asyncio.sleep(self.chunk_delay)
            yield body[off:off + chunk]

    async def filemetas_batch(self, _self: Any, _access_token: str, fsids: list[int], *,
                              dlink: bool = True, **_kwargs: Any) -> list[dict[str, Any]]:
        self.filemetas_calls += 1
        return [{"fs_id": f, "dlink": f"https://stub.dl/{f}",
                 "size": len(self.bodies.get(f, b"")), "md5": None} for f in fsids]

    async def list_dir(self, _self: Any, _access_token: str, _path: str, *,
                       folders_only: bool = False,
                       **_kwargs: Any) -> BaiduListResult:
        if self.list_error:
            err, self.list_error = self.list_error, None
            raise err
        items = [dict(e, dir_path=None) for e in self.listing
                 if not folders_only or e.get("isdir")]
        return BaiduListResult(items=items, truncated=False)


@pytest.fixture
def mock_baidu(monkeypatch: pytest.MonkeyPatch) -> BaiduScript:
    """进程内替换 BaiduNetdiskClient 网盘交互(list_dir/filemetas/download);OAuth 不触网。"""
    script = BaiduScript()
    monkeypatch.setattr(baidu_client_module.BaiduNetdiskClient, "stream_download", script.stream_download)
    monkeypatch.setattr(baidu_client_module.BaiduNetdiskClient, "filemetas_batch", script.filemetas_batch)
    monkeypatch.setattr(baidu_client_module.BaiduNetdiskClient, "list_dir", script.list_dir)
    return script


@pytest.fixture
def mock_oauth(monkeypatch: pytest.MonkeyPatch) -> dict[str, Any]:
    """进程内替换 OAuth/uinfo(绑定流路由测试);返回可调的剧本 dict。"""
    script: dict[str, Any] = {
        "token": {"access_token": "at-1", "refresh_token": "rt-1", "expires_in": 30 * 24 * 3600},
        "uid": "100",
        "nickname": "it-nickname",
        "exchange_calls": 0,
    }

    async def fake_exchange(self: Any, code: str, *_a: Any, **_k: Any) -> BaiduTokenPair:
        script["exchange_calls"] += 1
        token = dict(script["token"])
        return BaiduTokenPair(access_token=str(token["access_token"]),
                              refresh_token=str(token["refresh_token"]),
                              expires_in=int(token["expires_in"]))

    async def fake_uinfo(self: Any, *_a: Any, **_k: Any) -> BaiduUserInfo:
        return BaiduUserInfo(uid=str(script["uid"]), nickname=str(script["nickname"]))

    monkeypatch.setattr(baidu_client_module.BaiduNetdiskClient, "exchange_code", fake_exchange)
    monkeypatch.setattr(baidu_client_module.BaiduNetdiskClient, "uinfo", fake_uinfo)
    return script


# ─── MinIO seed 工具 ──────────────────────────────────────────────────────────
def _seed_multipart_sync(bucket: str, key: str, n_parts: int, part_size: int = 5 * MB) -> str:
    s3 = _minio_client()
    up = s3.create_multipart_upload(Bucket=bucket, Key=key)
    zero = b"\x00" * part_size
    for i in range(1, n_parts + 1):
        s3.upload_part(Bucket=bucket, Key=key, PartNumber=i, UploadId=up["UploadId"], Body=zero)
    return str(up["UploadId"])


async def _seed_multipart(bucket: str, key: str, n_parts: int, part_size: int = 5 * MB) -> str:
    return await asyncio.to_thread(_seed_multipart_sync, bucket, key, n_parts, part_size)


def _put_object_sync(bucket: str, key: str, body: bytes) -> None:
    _minio_client().put_object(Bucket=bucket, Key=key, Body=body, ContentLength=len(body))


async def _put_object(bucket: str, key: str, body: bytes) -> None:
    await asyncio.to_thread(_put_object_sync, bucket, key, body)


def _head_sync(bucket: str, key: str) -> dict[str, Any] | None:
    try:
        return _minio_client().head_object(Bucket=bucket, Key=key)
    except Exception:
        return None


async def _head(bucket: str, key: str) -> dict[str, Any] | None:
    return await asyncio.to_thread(_head_sync, bucket, key)


def _list_parts_sync(bucket: str, key: str, upload_id: str) -> list[dict[str, Any]] | None:
    """None = NoSuchUpload(死会话)。"""
    try:
        resp = _minio_client().list_parts(Bucket=bucket, Key=key, UploadId=upload_id)
        return list(resp.get("Parts", []))
    except Exception:
        return None


def _abort_sync(bucket: str, key: str, upload_id: str) -> None:
    with contextlib.suppress(Exception):
        _minio_client().abort_multipart_upload(Bucket=bucket, Key=key, UploadId=upload_id)


def _task_key(folder: Folder, rel_path: str) -> str:
    return f"{folder.minio_prefix.rstrip('/')}/{rel_path}"


# ─── 路由层 client(仅 router 级用例使用)──────────────────────────────────────
_CLIENT: Any = None


@pytest.fixture(scope="session")
async def client(stack):
    """ASGI client(lifespan);与仓库既有集成测试同款 session 级门控。"""
    global _CLIENT
    from httpx import ASGITransport, AsyncClient

    app = create_app()
    async with (
        app.router.lifespan_context(app),  # type: ignore[attr-defined]
        AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac,
    ):
        _CLIENT = ac
        yield ac
        _CLIENT = None


def _h(user_id: uuid.UUID) -> dict[str, str]:
    return {"X-User-Id": str(user_id)}       # dev 通道(env=dev)


BA = "/api/v1/baidu/backup"


@pytest.fixture
def enable_baidu(monkeypatch: pytest.MonkeyPatch):
    _set_feature_flag(monkeypatch, True)
    yield


async def _audit_count(event_type: str, **filters: Any) -> int:
    from sqlalchemy import func, select

    async with _db() as db:
        stmt = select(func.count()).select_from(AuditEvent).where(AuditEvent.event_type == event_type)
        for col, val in filters.items():
            stmt = stmt.where(getattr(AuditEvent, col) == val)
        n = (await db.execute(stmt)).scalar_one()
        return int(n)


# ════════════════════════════ 集成用例 ═════════════════════════════════════════
# 分组:P0 四类必过 → 绑定与创建护栏 → 枚举/manifest/终态 → 复活与覆盖 → 断点/接管/
#   超时接力/急停 → cancel/DELETE → 可见性/建链

# ─── 百度 HTTP 桩 + arq worker 子进程(§10 批次 5 前置交付物:进程级故障注入基建)───
def _require_fault_infra() -> None:
    """进程级故障注入用例的基建闸门:可注入的百度 base URL + 秒级时延 Settings。"""
    s = get_settings()
    missing = [k for k in ("baidu_openapi_base_url", "baidu_pan_base_url",
                           "baidu_lease_s", "baidu_sweep_throttle_s") if not hasattr(s, k)]
    if missing:
        pytest.skip(f"批次 5 故障注入基建未就绪(Settings 缺 {missing};方案 §10/§11)")


class BaiduStubState:
    """最小百度网盘 HTTP 桩:OAuth token / list / filemetas / download(Range 206)。"""

    def __init__(self) -> None:
        self.token_payloads: list[dict[str, Any]] = []
        self.token_calls = 0
        self.bodies: dict[int, bytes] = {}
        self.chunk_delay = 0.2
        self.download_log: list[tuple[int, int]] = []   # (fs_id, range_start)
        self.openapi = ""
        self.pan = ""


@pytest.fixture(scope="session")
def baidu_stub():
    _require_fault_infra()
    import uvicorn
    from fastapi import FastAPI, Request
    from fastapi.responses import StreamingResponse

    state = BaiduStubState()
    app = FastAPI()

    @app.post("/oauth/2.0/token")
    async def _token(request: Request) -> dict[str, Any]:
        state.token_calls += 1
        if state.token_payloads:
            return state.token_payloads.pop(0)
        return {"error": "invalid_grant", "errno": 111}

    @app.get("/rest/2.0/xpan/file")
    async def _list(method: str = "list", dir: str = "/", page: int = 1, num: int = 1000) -> dict[str, Any]:
        return {"errno": 0, "list": []}

    @app.get("/rest/2.0/xpan/multimedia")
    async def _filemetas(method: str = "filemetas", fsids: str = "", dlink: int = 1) -> dict[str, Any]:
        out = [{"fs_id": int(f), "dlink": f"{state.pan}/download/{int(f)}",
                "size": len(state.bodies.get(int(f), b"")), "md5": None}
               for f in fsids.split(",") if f]
        return {"errno": 0, "list": out}

    @app.get("/download/{fs_id}")
    async def _download(fs_id: int, access_token: str = "", range: str | None = None) -> StreamingResponse:
        body = state.bodies.get(fs_id, b"")
        start = 0
        status_code = 200
        headers: dict[str, str] = {}
        if range:
            start = int(range.split("=")[-1].split("-")[0])
            status_code = 206
            headers["Content-Range"] = f"bytes {start}-{max(len(body) - 1, 0)}/{len(body)}"
        state.download_log.append((fs_id, start))

        async def _gen() -> AsyncIterator[bytes]:
            chunk = 16 * 1024
            for off in range(start, len(body), chunk):
                if state.chunk_delay:
                    await asyncio.sleep(state.chunk_delay)
                yield body[off:off + chunk]

        return StreamingResponse(_gen(), status_code=status_code, headers=headers)

    config = uvicorn.Config(app, host="127.0.0.1", port=0, log_level="error")
    server = uvicorn.Server(config)
    th = threading.Thread(target=server.run, daemon=True)
    th.start()
    for _ in range(200):
        if getattr(server, "started", False):
            break
        time.sleep(0.05)
    port = server.servers[0].sockets[0].getsockname()[1]
    state.openapi = f"http://127.0.0.1:{port}/oauth/2.0/token"
    state.pan = f"http://127.0.0.1:{port}"
    yield state
    server.should_exit = True
    th.join(timeout=5)


def _spawn_worker(baidu_stub: BaiduStubState, extra_env: dict[str, str] | None = None) -> subprocess.Popen:
    """spawn 真 arq worker 子进程(百度端点指向桩;时延秒级注入)。"""
    env = {
        **os.environ,
        "BAIDU_BACKUP_ENABLED": "true",
        "BAIDU_OPENAPI_BASE_URL": baidu_stub.openapi,
        "BAIDU_PAN_BASE_URL": baidu_stub.pan,
        "BAIDU_APP_KEY": os.environ.get("BAIDU_APP_KEY", "it-key"),
        "BAIDU_APP_SECRET": os.environ.get("BAIDU_APP_SECRET", "it-secret"),
        "BAIDU_LEASE_S": "2",
        "BAIDU_SWEEP_THROTTLE_S": "2",
        "BAIDU_RELAY_AFTER_S": "3300",
        "BAIDU_ROUND_TIMEOUT_S": "172800",
    }
    env.update(extra_env or {})
    return subprocess.Popen(
        [sys.executable, "-m", "arq", "app.workers.main.WorkerSettings"],
        cwd=str(API_DIR), env=env,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


async def _task_status(task_id: uuid.UUID) -> str | None:
    t = await _get_task(task_id)
    return t.status if t else None


async def _any_importing(task_id: uuid.UUID) -> bool:
    return any(r.status == "importing" for r in await _files_of(task_id))


async def _job_queued(task_id: uuid.UUID, seq: int) -> bool:
    """arq 队列里是否存在该 job(best-effort;Redis 异常时不阻塞断言)。"""
    try:
        import redis.asyncio as aioredis

        r = aioredis.from_url(str(get_settings().redis_url), decode_responses=True)
        try:
            return await r.zscore("arq:queue", f"baidu_backup_run:{task_id}:{seq}") is not None
        finally:
            await r.aclose()
    except Exception:
        return False


async def _queue_zrem(job_id: str) -> None:
    import redis.asyncio as aioredis

    r = aioredis.from_url(str(get_settings().redis_url), decode_responses=True)
    try:
        await r.zrem("arq:queue", job_id)
    finally:
        await r.aclose()


def _zero_backoff(monkeypatch: pytest.MonkeyPatch) -> None:
    """退避注入 0s(耗尽类用例不真等 20s)。"""
    async def _zero(_attempt: int) -> float:
        return 0.0

    monkeypatch.setattr(baidu_client_module, "backoff_delay_s", _zero, raising=False)
    mod = sys.modules.get("app.workers.baidu_backup")
    if mod is not None and hasattr(mod, "backoff_delay_s"):
        monkeypatch.setattr(mod, "backoff_delay_s", _zero, raising=False)
    import app.services.baidu_backup as svc_mod
    if hasattr(svc_mod, "backoff_delay_s"):
        monkeypatch.setattr(svc_mod, "backoff_delay_s", _zero, raising=False)


# ─── P0 档:租约 CAS / 接管续跑 / kill -9 恢复 / 回摆并发(四类必过)──────────────
async def test_p0_job_claim_expected_seq_cas(world: World, stack) -> None:
    """派发/认领/续期全链 CAS:expected_seq 与 runner_id 是互斥唯一凭证。【集成】P0"""
    task = await _mk_task(world, status="running", lease_seq=0)

    # 派发步(sweeper 形态):seq+1、清 runner、不写未来租约、刷新 dispatched_at
    async with _db() as db:
        assert await dispatch_baidu_task(db, task.id, sweeper=True) is True
    t = await _get_task(task.id)
    assert t.lease_seq == 1
    assert t.runner_id is None and t.lease_until is None, "派发不写未来租约(§6)"
    assert t.dispatched_at is not None
    assert await _job_queued(task.id, 1), "派发步成功后必须入队(§6)"

    # job 启动认领:expected_seq 命中且 runner IS NULL → 成功;租约/轮起点/锚点就位
    async with _db() as db:
        assert await claim_baidu_task(db, task.id, 1, "runner-A") is True
    t = await _get_task(task.id)
    assert t.runner_id == "runner-A" and t.lease_until is not None
    assert t.round_started_at is not None, "认领 COALESCE 写入轮起点"
    assert t.speed_bps == 0 and t.speed_anchor_bytes == 0 and t.speed_anchor_at is None

    # 二次认领同 seq:runner 已占 → 0 行
    async with _db() as db:
        assert await claim_baidu_task(db, task.id, 1, "runner-B") is False

    # 更高 seq 取代:sweeper 过期接管 → 旧 seq 认领必须失败(被取代安静退出)
    await _touch_task(task.id, lease_until=NOW - timedelta(seconds=1),
                      dispatched_at=NOW - timedelta(minutes=11))
    async with _db() as db:
        assert await dispatch_baidu_task(db, task.id, sweeper=True) is True
    async with _db() as db:
        assert await claim_baidu_task(db, task.id, 1, "runner-C") is False, "旧 seq 不得认领"
    async with _db() as db:
        assert await claim_baidu_task(db, task.id, 2, "runner-C") is True

    # 续期 CAS:(seq, runner) 双匹配才续;终态后立即失去所有权(§6 含 status 条件)
    async with _db() as db:
        assert await renew_baidu_lease(db, task.id, 2, "runner-C") is True
    await _touch_task(task.id, status="completed")
    async with _db() as db:
        assert await renew_baidu_lease(db, task.id, 2, "runner-C") is False, "终态后续期必须失败"


async def test_p0_old_runner_stops_after_takeover_no_part_write(world: World, mock_baidu, stack) -> None:
    """旧 runner 被接管后续期 CAS 失败即中止:不得再写 part、不得双落 asset。【集成】P0"""
    content = os.urandom(256 * 1024)
    task = await _mk_task(world, status="running", lease_seq=1)
    row = await _mk_file(task, "big.mp4", size=len(content))
    mock_baidu.add(row.fs_id, content)
    mock_baidu.chunk_delay = 0.05          # 慢速下载,给接管留窗口

    async with _db() as db:
        assert await claim_baidu_task(db, task.id, 1, "runner-A") is True
    job_a = asyncio.create_task(_run_job(task.id, 1))

    async def _a_mid_file() -> bool:
        r = await _get_file(row.id)
        return r.status == "importing" and 0 < r.bytes_done < len(content)

    assert await _eventually(_a_mid_file, timeout=60), "A 未进入 importing 中段"

    # sweeper 接管:租约过期 + 节流放行 → seq+1 清 runner;B 认领续跑
    await _touch_task(task.id, lease_until=NOW - timedelta(seconds=1),
                      dispatched_at=NOW - timedelta(minutes=11))
    async with _db() as db:
        assert await dispatch_baidu_task(db, task.id, sweeper=True) is True
        assert await claim_baidu_task(db, task.id, 2, "runner-B") is True

    # 互斥核心断言:A 的续期 CAS 必须失败(租约是唯一凭证)
    async with _db() as db:
        assert await renew_baidu_lease(db, task.id, 1, "runner-A") is False

    bytes_at_takeover = (await _get_file(row.id)).bytes_done
    assert await _eventually(lambda: _task_status(task.id) == "completed", timeout=180), "B 未续跑至完成"
    await asyncio.wait_for(job_a, timeout=60)   # A 必须安静退出,不得抛未处理异常

    rows = await _files_of(task.id)
    assert [r.status for r in rows] == ["success"]
    final = await _get_file(row.id)
    assert final.bytes_done == len(content) >= bytes_at_takeover, "接管后不得回退/双写"
    # 对象完整性:恰好一份内容(无 A/B 交错损坏)
    key = _task_key(world.folder, "big.mp4")
    head = await _head(world.project.minio_bucket, key)
    assert head is not None and head["ContentLength"] == len(content)
    from sqlalchemy import select
    async with _db() as db:
        assets = (await db.execute(
            select(Asset).where(Asset.minio_bucket == world.project.minio_bucket,
                                Asset.minio_key == key))).scalars().all()
    assert len(assets) == 1, "双 runner 互踩会双落 asset"


async def test_p0_kill9_lease_expiry_takeover_resume_to_success(world: World, baidu_stub, stack) -> None:
    """kill -9 后租约过期接管续跑:importing 行复位 pending、断点保留、续跑至 success。【集成】P0"""
    f1_content = os.urandom(64 * 1024)
    f2_content = os.urandom(64 * 1024)
    task = await _mk_task(world, status="running")
    f1 = await _mk_file(task, "a.mp4", size=len(f1_content))
    f2 = await _mk_file(task, "b.mp4", size=len(f2_content))
    baidu_stub.bodies = {f1.fs_id: f1_content, f2.fs_id: f2_content}
    baidu_stub.chunk_delay = 0.2                       # 慢速,确保 kill 时在途

    proc = _spawn_worker(baidu_stub)
    try:
        assert await _eventually(lambda: _any_importing(task.id), timeout=90), \
            "worker 未在窗口内进入 importing(桩/租约基建未就绪?)"
        proc.kill()                                     # kill -9:无任何清理路径
        proc.wait(timeout=15)
    finally:
        if proc.poll() is None:
            proc.kill()

    t = await _get_task(task.id)
    assert t.status == "running", "硬杀不得落终态"
    rows = await _files_of(task.id)
    importing = [r for r in rows if r.status == "importing"]
    assert len(importing) == 1, "单 runner 下至多 1 行 importing"
    stale_upload_id = importing[0].minio_upload_id

    # 租约过期 + 节流窗口过后 → sweeper 接管派发:importing 复位 pending、断点字段保留
    seq_before = (await _get_task(task.id)).lease_seq
    await _touch_task(task.id, lease_until=NOW - timedelta(seconds=1),
                      dispatched_at=NOW - timedelta(minutes=11))
    await _sweep_now()
    t = await _get_task(task.id)
    assert t.lease_seq == seq_before + 1, "sweeper 接管必须走派发步(seq+1)"
    row = await _get_file(importing[0].id)
    assert row.status == "pending", "接管派发步必须复位在途行(§6)"
    assert row.bytes_done > 0 and row.minio_upload_id == stale_upload_id, "断点字段必须保留"
    assert t.runner_id is None and t.lease_until is None

    # 新 worker(快档)拾取新 seq job → 从断点 Range 续跑至 success
    baidu_stub.chunk_delay = 0.0
    proc2 = _spawn_worker(baidu_stub)
    try:
        assert await _eventually(lambda: _task_status(task.id) == "completed", timeout=180), \
            "接管后续跑未完成"
    finally:
        proc2.terminate()
        proc2.wait(timeout=15)

    t = await _get_task(task.id)
    assert t.status == "completed" and t.fail_reason is None
    rows = await _files_of(task.id)
    assert sorted(r.status for r in rows) == ["success", "success"]
    # 断点真实生效:接管后的下载从非 0 偏移发起(不整文件重传)
    resumes = [start for fs, start in baidu_stub.download_log if fs == row.fs_id and start > 0]
    assert resumes, f"接管后未见断点续传下载: {baidu_stub.download_log}"
    # 产物完整:对象 size 与源一致
    for r in rows:
        head = await _head(world.project.minio_bucket, _task_key(world.folder, r.rel_path))
        assert head is not None and head["ContentLength"] == r.source_size


async def test_p0_delete_terminal_cas_vs_overwrite_swingback_concurrent(
    world: World, client, enable_baidu, stack,
) -> None:
    """overwrite 回摆(completed→running)与 DELETE 并发:DELETE 终态 CAS 保证仅一侧生效。【集成】P0"""

    task = await _mk_task(world, status="completed", user_id=world.admin.id,
                          total_files=1, done_files=1, skipped_files=1)
    old_content = b"old-object-bytes"
    key = _task_key(world.folder, "swing.mp4")
    await _put_object(world.project.minio_bucket, key, old_content)
    old_asset = Asset(
        folder_id=world.folder.id, filename="swing.mp4",
        minio_bucket=world.project.minio_bucket, minio_key=key,
        size_bytes=len(old_content), uploader_id=world.admin.id,
    )
    async with _db() as db:
        db.add(old_asset)
        await db.commit()
        await db.refresh(old_asset)
    await _mk_file(task, "swing.mp4", size=len(old_content), status="skipped_exists",
                   asset_id=old_asset.id)

    # 并发:overwrite(回摆 completed→running) vs DELETE(仅终态可删),两个请求同时发
    async def _overwrite() -> Any:
        from sqlalchemy import select as _s
        async with _db() as db:
            frow = (await db.execute(_s(BaiduBackupTaskFile).where(
                BaiduBackupTaskFile.task_id == task.id))).scalars().first()
        return await client.post(f"{BA}/tasks/{task.id}/files/{frow.id}/overwrite",
                                 headers=_h(world.admin.id))

    async def _delete() -> Any:
        return await client.delete(f"{BA}/tasks/{task.id}", headers=_h(world.admin.id))

    ov_r, del_r = await asyncio.gather(_overwrite(), _delete())

    ov_won = ov_r.status_code == 202
    del_won = del_r.status_code == 204
    assert ov_won != del_won, f"必须仅一侧生效: overwrite={ov_r.status_code} delete={del_r.status_code}"
    async with _db() as db:
        gone = await db.get(BaiduBackupTask, task.id)
    if del_won:
        assert gone is None, "DELETE 赢时任务必须已删"
        assert ov_r.status_code in (404, 409), "输方必须明确拒绝"
    else:
        assert gone is not None and gone.status == "running", "回摆必须重新占用活动名额"
        assert del_r.status_code == 409, "DELETE 终态 CAS:对 running 任务必须 409"


# ─── 绑定流与创建护栏 ─────────────────────────────────────────────────────────
async def test_binding_flow_roundtrip_encrypted_at_rest(
    world: World, client, enable_baidu, mock_oauth, stack,
) -> None:
    """绑定流:authorize-url(oob)→ code 换 token 加密落库 + uinfo NOT NULL + audit。【集成】P1"""
    from sqlalchemy import select

    r = await client.post(f"{BA}/binding/authorize-url", headers=_h(world.member.id))
    assert r.status_code == 200, r.text
    url = r.json()["url"]
    assert "oob" in url, "授权链接必须走 oob 复制码模式(§3.2)"

    # code 换 token(10 分钟单次)→ 加密落库
    r2 = await client.post(f"{BA}/binding", json={"code": "it-code"}, headers=_h(world.member.id))
    assert r2.status_code in (200, 201), r2.text
    assert r2.json().get("bound") is True
    async with _db() as db:
        rows = (await db.execute(select(BaiduBinding).where(
            BaiduBinding.user_id == world.member.id))).scalars().all()
    assert len(rows) == 1, "同一 user 只有一行绑定(unique user_id)"
    b = rows[0]
    assert b.baidu_uid == "100", "uinfo 身份必须落库且 NOT NULL(防 NULL==NULL 误判换绑)"
    assert b.status == "active"
    # 密文形态:不含明文、可解密回原文
    assert "at-1" not in b.access_token_enc and "rt-1" not in b.refresh_token_enc
    assert decrypt_token(b.access_token_enc) == "at-1"
    assert decrypt_token(b.refresh_token_enc) == "rt-1"
    assert await _audit_count("baidu_bind", actor_user_id=world.member.id) >= 1

    # GET binding 状态
    r3 = await client.get(f"{BA}/binding", headers=_h(world.member.id))
    assert r3.status_code == 200
    body = r3.json()
    assert body["bound"] is True and body["status"] == "active"
    assert body.get("expires_at") is not None

    # 重新授权 = 覆盖同一行(原子覆盖两 token + uinfo)
    mock_oauth["token"] = {"access_token": "at-2", "refresh_token": "rt-2", "expires_in": 30 * 24 * 3600}
    r4 = await client.post(f"{BA}/binding", json={"code": "it-code-2"}, headers=_h(world.member.id))
    assert r4.status_code in (200, 201)
    async with _db() as db:
        rows2 = (await db.execute(select(BaiduBinding).where(
            BaiduBinding.user_id == world.member.id))).scalars().all()
    assert len(rows2) == 1 and decrypt_token(rows2[0].access_token_enc) == "at-2"


async def test_binding_reauthorize_same_uid_skips_breakpoint_invalidation(
    world: World, client, enable_baidu, mock_oauth, stack,
) -> None:
    """重授权同 uid → 跳过断点作废①②(会话在自家 MinIO,同账号续传无损),仅清 dlink 缓存。【集成】P1"""
    task = await _mk_task(world, status="failed")
    upload_id = await _seed_multipart(world.project.minio_bucket, "reauth/same.mp4", 1)
    await _mk_file(task, "same.mp4", status="failed", minio_upload_id=upload_id,
                   minio_bucket=world.project.minio_bucket, minio_key="reauth/same.mp4",
                   bytes_done=5 * MB, dlink="https://old.dlink/x")
    rotated_before = world.binding.token_rotated_at

    r = await client.post(f"{BA}/binding", json={"code": "it-code"}, headers=_h(world.member.id))
    assert r.status_code in (200, 201), r.text

    row = (await _files_of(task.id))[0]
    assert row.minio_upload_id == upload_id, "同账号重授权不得作废断点"
    assert row.bytes_done == 5 * MB
    assert row.dlink is None and row.dlink_fetched_at is None, "必须清全部 dlink 缓存(§5.2③)"
    async with _db() as db:
        b = await db.get(BaiduBinding, world.binding.id)
    assert b.token_rotated_at is not None and b.token_rotated_at >= rotated_before
    assert b.last_authorized_at is not None
    assert await _list_parts_sync(world.project.minio_bucket, "reauth/same.mp4", upload_id) is not None, \
        "同账号重授权:multipart 会话必须仍可用"


async def test_create_task_without_can_upload_403_access_denied_audit(
    world: World, client, enable_baidu, stack,
) -> None:
    """无 can_upload 的用户创建任务 → 403 + access_denied 审计(仓库惯例 403 才落审计)。【集成】P1"""
    r = await client.post(f"{BA}/tasks", json={
        "source_dir": "/it-src", "project_id": str(world.project.id),
        "target_folder_id": str(world.folder.id),
    }, headers=_h(world.outsider.id))
    assert r.status_code == 403, r.text
    assert await _audit_count("access_denied", actor_user_id=world.outsider.id) >= 1


async def test_create_task_explicit_sensitive_target_403_no_sensitive_wording(
    world: World, client, enable_baidu, stack,
) -> None:
    """显式选 sensitive 目标 → 403 + access_denied;文案不含「敏感」字样(防探测)。【集成】P1"""
    r = await client.post(f"{BA}/tasks", json={
        "source_dir": "/it-src", "project_id": str(world.project.id),
        "target_folder_id": str(world.sensitive.id),
    }, headers=_h(world.member.id))
    assert r.status_code == 403, r.text
    assert "敏感" not in r.text, "错误文案不得泄露 sensitive 字样"
    assert await _audit_count("access_denied", actor_user_id=world.member.id) >= 1


async def test_create_task_sensitive_ancestor_403_fast_fail(
    world: World, client, enable_baidu, stack,
) -> None:
    """普通子夹挂在 sensitive 夹下是被允许的形态;选它作目标 → 沿 parent 链向上核查 → 创建期 403 快败。【集成】P1"""
    async with _db() as db:
        child = Folder(project_id=world.project.id, parent_folder_id=world.sensitive.id,
                       name="inner", minio_prefix="secret/inner/")
        db.add(child)
        await db.commit()
        await db.refresh(child)
    perms = PermissionsService(get_settings())
    from openfga_sdk.models import ClientTuple, ClientWriteRequest
    await perms._client.write(ClientWriteRequest(writes=[
        ClientTuple(user=f"sensitive_folder:{world.sensitive.id}", relation="parent",
                    object=f"folder:{child.id}")]))

    r = await client.post(f"{BA}/tasks", json={
        "source_dir": "/it-src", "project_id": str(world.project.id),
        "target_folder_id": str(child.id),
    }, headers=_h(world.member.id))
    assert r.status_code == 403, f"敏感祖先必须在创建期 403 快败,勿留到导入期: {r.text}"
    assert await _audit_count("access_denied", actor_user_id=world.member.id) >= 1


async def test_create_task_source_dir_guards_400(
    world: World, client, enable_baidu, stack,
) -> None:
    """source_dir 护栏:根 / 拒绝、相对路径拒绝、>600 拒绝、承接夹名>255 → 400(§5.2)。【集成】P1"""
    base = {"project_id": str(world.project.id), "target_folder_id": str(world.folder.id)}

    r = await client.post(f"{BA}/tasks", json={**base, "source_dir": "/"}, headers=_h(world.member.id))
    assert r.status_code == 400, "根目录不允许(承接夹无名)"
    r = await client.post(f"{BA}/tasks", json={**base, "source_dir": "relative/path"},
                          headers=_h(world.member.id))
    assert r.status_code == 400, "相对路径在创建期 400,勿留到枚举期"
    r = await client.post(f"{BA}/tasks", json={**base, "source_dir": "/" + "a" * 600},
                          headers=_h(world.member.id))
    assert r.status_code == 400, "source_dir ≤600 字符"
    r = await client.post(f"{BA}/tasks", json={**base, "source_dir": "/dir/" + "长" * 256},
                          headers=_h(world.member.id))
    assert r.status_code == 400, "承接夹名(末段)>255 字符 → 400「网盘目录名过长」"
    assert "网盘目录名过长" in r.text or "过长" in r.text
    r = await client.post(f"{BA}/tasks", json={
        "source_dir": "/it-src", "project_id": str(world.project.id),
        "target_folder_id": str(uuid.uuid4()),      # 不属于该 project / 不存在
    }, headers=_h(world.member.id))
    assert r.status_code == 400, "target_folder_id 必须归属 project(folders.py:64-66 先例)"


async def test_binding_inactive_409_on_netdisk_folders(
    world: World, client, enable_baidu, mock_baidu, monkeypatch, stack,
) -> None:
    """netdisk folders:60s (user_id,path) 缓存生效 + 绑定非 active → 409 binding_inactive。【集成】P1"""
    calls: list[str] = []
    orig_list_dir = baidu_client_module.BaiduNetdiskClient.list_dir

    async def _counting(self: Any, access_token: str, path: str, *a: Any, **k: Any) -> Any:
        calls.append(path)
        return await orig_list_dir(self, access_token, path, *a, **k)

    monkeypatch.setattr(baidu_client_module.BaiduNetdiskClient, "list_dir", _counting)

    # 同 (user, path) 60s 内两次请求 → 只打一次百度(§9 频控缓解)
    r1 = await client.get(f"{BA}/netdisk/folders", params={"path": "/docs"},
                          headers=_h(world.member.id))
    assert r1.status_code == 200, r1.text
    r2 = await client.get(f"{BA}/netdisk/folders", params={"path": "/docs"},
                          headers=_h(world.member.id))
    assert r2.status_code == 200
    assert calls == ["/docs"], f"60s 缓存未生效: {calls}"
    # 不同 path → 新请求
    r3 = await client.get(f"{BA}/netdisk/folders", params={"path": "/other"},
                          headers=_h(world.member.id))
    assert r3.status_code == 200
    assert sorted(calls) == ["/docs", "/other"]

    # 绑定非 active → 409(错误码 binding_inactive,与创建/复活接口同码同义)
    await _touch_binding(world.binding.id, status="unbound")
    r4 = await client.get(f"{BA}/netdisk/folders", params={"path": "/"},
                          headers=_h(world.member.id))
    assert r4.status_code == 409, r4.text
    assert "binding_inactive" in r4.text


async def _touch_binding(binding_id: uuid.UUID, **values: Any) -> None:
    from sqlalchemy import update

    async with _db() as db:
        await db.execute(update(BaiduBinding).where(BaiduBinding.id == binding_id).values(**values))
        await db.commit()


# ─── 任务运行脚手架(派发 → 认领 → 进程内跑 job)────────────────────────────────
async def _claim_and_run(task_id: uuid.UUID, runner: str = "runner-it") -> None:
    t = await _get_task(task_id)
    async with _db() as db:
        assert await claim_baidu_task(db, task_id, t.lease_seq, runner), \
            f"认领失败 seq={t.lease_seq}(任务须处于活动态且 runner IS NULL)"
    await _run_job(task_id, t.lease_seq)


async def _dispatch_claim_run(task_id: uuid.UUID, runner: str = "runner-it") -> None:
    async with _db() as db:
        assert await dispatch_baidu_task(db, task_id, sweeper=True)
    await _claim_and_run(task_id, runner)


def _seed_listing(script: BaiduScript, source_dir: str, files: dict[str, bytes]) -> dict[str, int]:
    """list_dir 输出脚本化(枚举 BFS 数据源):返回 name → fs_id。"""
    out: dict[str, int] = {}
    entries: list[dict[str, Any]] = []
    for name, content in files.items():
        fs_id = random_fsid()
        script.add(fs_id, content)
        out[name] = fs_id
        entries.append({"fs_id": fs_id, "path": f"{source_dir.rstrip('/')}/{name}",
                        "size": len(content), "isdir": False})
    script.listing = entries
    return out


def _patch_manifest_limit(monkeypatch: pytest.MonkeyPatch, value: int) -> None:
    s = get_settings()
    if hasattr(s, "baidu_manifest_max_files"):
        monkeypatch.setattr(s, "baidu_manifest_max_files", value, raising=False)
    mod = sys.modules.get("app.workers.baidu_backup")
    if mod is not None:
        for const in ("MANIFEST_MAX_FILES", "BAIDU_MANIFEST_MAX_FILES"):
            if hasattr(mod, const):
                monkeypatch.setattr(mod, const, value)


async def _mk_asset(world: World, folder: Folder, filename: str, content: bytes,
                    *, uploader: User | None = None, deleted: bool = False) -> Asset:
    key = f"{folder.minio_prefix.rstrip('/')}/{filename}"
    if not deleted:
        await _put_object(world.project.minio_bucket, key, content)
    a = Asset(
        folder_id=folder.id, filename=filename,
        minio_bucket=world.project.minio_bucket, minio_key=key,
        size_bytes=len(content), uploader_id=(uploader or world.member).id,
        deleted_at=NOW if deleted else None,
    )
    async with _db() as db:
        db.add(a)
        await db.commit()
        await db.refresh(a)
    return a


# ─── 枚举 / manifest 状态机 / 终态判定 ────────────────────────────────────────
async def test_enum_on_conflict_idempotent_preserves_row_states(
    world: World, mock_baidu, stack,
) -> None:
    """枚举重跑 ON CONFLICT(task_id, rel_path) DO NOTHING 幂等:不重置已有行状态。【集成】P1"""
    task = await _mk_task(world, status="enumerating", enum_done=False)
    content = b"idem-bytes"
    fs_a, fs_b, fs_c = random_fsid(), random_fsid(), random_fsid()
    for fs in (fs_a, fs_b, fs_c):
        mock_baidu.add(fs, content)
    await _mk_file(task, "done.mp4", size=len(content), status="success", fs_id=fs_a, asset_id=None)
    await _mk_file(task, "skip.mp4", size=len(content), status="skipped_exists", fs_id=fs_b)
    await _mk_file(task, "bad.mp4", size=len(content), status="failed", fs_id=fs_c, attempts=2)
    _seed_listing(mock_baidu, task.source_dir,
                  {"done.mp4": content, "skip.mp4": content, "bad.mp4": content})

    await _dispatch_claim_run(task.id)

    rows = {r.rel_path: r for r in await _files_of(task.id)}
    assert len(rows) == 3, "重枚举不得产生重复行"
    assert rows["done.mp4"].status == "success", "重枚举不得重置 success"
    assert rows["skip.mp4"].status == "skipped_exists", "重枚举不得重置 skipped"
    assert rows["bad.mp4"].status == "failed" and rows["bad.mp4"].attempts == 2, \
        "重枚举不得重置 failed/attempts(防超护栏任务被全量导入)"
    t = await _get_task(task.id)
    assert t.enum_done is True, "枚举完成置 running 时同事务置位(§4)"


async def test_enum_rate_limited_revival_reenumerates_completes_manifest(
    world: World, mock_baidu, client, enable_baidu, stack,
) -> None:
    """枚举频控耗尽失败 → 复活按 enum_done=false 走重枚举 → 补全 manifest 至完成。【集成】P1"""
    task = await _mk_task(world, status="failed", enum_done=False, fail_reason="enum_rate_limited")
    c_a, c_b = b"A-bytes", b"B-bytes"
    fs_a, fs_b = random_fsid(), random_fsid()
    mock_baidu.add(fs_a, c_a)
    mock_baidu.add(fs_b, c_b)
    await _mk_file(task, "a.mp4", size=len(c_a), status="success", fs_id=fs_a)
    await _mk_file(task, "b.mp4", size=len(c_b), status="pending", fs_id=fs_b)
    _seed_listing(mock_baidu, task.source_dir,
                  {"a.mp4": c_a, "b.mp4": c_b, "c.mp4": b"C-bytes", "d.mp4": b"D-bytes"})

    r = await client.post(f"{BA}/tasks/{task.id}/retry-failed", headers=_h(world.member.id))
    assert r.status_code == 202, r.text
    t = await _get_task(task.id)
    assert t.status == "enumerating" and t.enum_done is False, "复活按 enum_done=false 重枚举(§4)"
    assert t.fail_reason is None, "复活派发步复位 fail_reason"

    await _claim_and_run(task.id)

    rows = await _files_of(task.id)
    assert len(rows) == 4, "重枚举补全 manifest(残缺部分补齐)"
    by = {x.rel_path: x for x in rows}
    assert by["a.mp4"].status == "success", "ON CONFLICT 保留已成功行"
    assert all(by[n].status == "success" for n in ("b.mp4", "c.mp4", "d.mp4"))
    t = await _get_task(task.id)
    assert t.status == "completed" and t.total_files == 4


async def test_manifest_too_large_revival_fails_again_without_full_import(
    world: World, mock_baidu, client, enable_baidu, monkeypatch, stack,
) -> None:
    """manifest_too_large 复活后再次失败而非全量导入(enum_done=false 重枚举的自洽性)。【集成】P1"""
    _patch_manifest_limit(monkeypatch, 50)
    task = await _mk_task(world, status="enumerating", enum_done=False)
    mock_baidu.listing = [
        {"fs_id": 10_000 + i, "path": f"{task.source_dir}/f{i:03d}.mp4", "size": 8, "isdir": False}
        for i in range(60)
    ]

    await _dispatch_claim_run(task.id)
    t = await _get_task(task.id)
    assert t.status == "failed" and t.fail_reason == "manifest_too_large"
    rows = await _files_of(task.id)
    assert len(rows) <= 50, "护栏必须截断在 20,000 上限内(测试注入 50)"
    assert all(r.status == "pending" for r in rows), "枚举期失败不产生任何导入"

    # 复活 → 重枚举 → 仍超限 → 再次 failed,而非把残缺 manifest 全量导入
    r = await client.post(f"{BA}/tasks/{task.id}/retry-failed", headers=_h(world.member.id))
    assert r.status_code == 202
    await _claim_and_run(task.id)
    t = await _get_task(task.id)
    assert t.status == "failed" and t.fail_reason == "manifest_too_large"
    rows = await _files_of(task.id)
    assert all(r.status == "pending" for r in rows), "复活后仍不得全量导入"
    heads = await _head(world.project.minio_bucket, _task_key(world.folder, rows[0].rel_path))
    assert heads is None, "MinIO 不得产生对象"


async def test_empty_source_dir_completes_marked_empty(
    world: World, mock_baidu, stack,
) -> None:
    """枚举结果为空(0 行)→ 任务直接 completed(列表文案「源目录为空」由接口层标注)。【集成】P1"""
    task = await _mk_task(world, status="enumerating", enum_done=False)
    mock_baidu.listing = []
    await _dispatch_claim_run(task.id)
    t = await _get_task(task.id)
    assert t.status == "completed", "空目录直接 completed,不进导入循环"
    assert (t.total_files or 0) == 0 and t.enum_done is True


async def test_rel_path_subdir_same_name_skipped_exists_no_wrong_skip(
    world: World, mock_baidu, stack,
) -> None:
    """rel_path 带子目录的同名文件按各自落位目录判 skip;承接夹同名不得误判。【集成】P1"""
    content = b"nested-clip"
    # 干扰项:承接夹根下同名 asset(clip.mp4)
    await _mk_asset(world, world.folder, "clip.mp4", b"root-distractor")
    # 子目录 a 已有同名 asset(应命中 skip)
    async with _db() as db:
        folder_a = Folder(project_id=world.project.id, parent_folder_id=world.folder.id,
                          name="a", minio_prefix="target-root/a/")
        db.add(folder_a)
        await db.commit()
        await db.refresh(folder_a)
    perms = PermissionsService(get_settings())
    from openfga_sdk.models import ClientTuple, ClientWriteRequest
    await perms._client.write(ClientWriteRequest(writes=[
        ClientTuple(user=f"folder:{world.folder.id}", relation="parent", object=f"folder:{folder_a.id}")]))
    await _mk_asset(world, folder_a, "clip.mp4", b"a-old")

    task = await _mk_task(world, status="running")
    fs_a, fs_b = random_fsid(), random_fsid()
    mock_baidu.add(fs_a, content)
    mock_baidu.add(fs_b, content)
    await _mk_file(task, "a/clip.mp4", size=len(content), fs_id=fs_a)
    await _mk_file(task, "b/clip.mp4", size=len(content), fs_id=fs_b)

    await _dispatch_claim_run(task.id)

    by = {r.rel_path: r for r in await _files_of(task.id)}
    assert by["a/clip.mp4"].status == "skipped_exists", "落位目录 a 下同名 → skip"
    assert by["b/clip.mp4"].status == "success", "承接夹根同名不得误判 b 子目录(§6 步骤 2 对象口径)"
    assert by["b/clip.mp4"].asset_id is not None


async def test_manifest_status_transitions_skip_retry_overwrite_cancel(
    world: World, mock_baidu, monkeypatch, client, enable_baidu, stack,
) -> None:
    """manifest 行状态机一次走全:pending→success/skipped_exists/failed;retry 复位;cancel 归位。【集成】P1"""
    _zero_backoff(monkeypatch)
    ok_c, bad_c = b"ok-bytes", b"bad-bytes"
    task = await _mk_task(world, status="running")
    fs_ok, fs_bad, fs_dup = random_fsid(), random_fsid(), random_fsid()
    mock_baidu.add(fs_ok, ok_c)
    mock_baidu.add(fs_bad, bad_c)
    mock_baidu.add(fs_dup, b"dup-bytes")
    mock_baidu.fail_first[fs_bad] = [BaiduApiError(CATEGORY_RATE_LIMITED, "rl", http_status=503)
                                     for _ in range(5)]
    await _mk_file(task, "ok.mp4", size=len(ok_c), fs_id=fs_ok)
    await _mk_file(task, "bad.mp4", size=len(bad_c), fs_id=fs_bad)
    await _mk_file(task, "dup.mp4", size=9, fs_id=fs_dup)
    await _mk_asset(world, world.folder, "dup.mp4", b"dup-bytes")   # 已存在 → skip

    await _dispatch_claim_run(task.id)

    by = {r.rel_path: r for r in await _files_of(task.id)}
    assert by["ok.mp4"].status == "success"
    assert by["dup.mp4"].status == "skipped_exists"
    assert by["bad.mp4"].status == "failed" and by["bad.mp4"].attempts == 5
    t = await _get_task(task.id)
    assert t.status == "failed" and t.fail_reason == "file_failed", "有失败行 → 任务 failed 终态"
    assert t.failed_files == 1 and t.skipped_files == 1
    assert t.done_files == 2, "done = success + skipped(§6 聚合口径)"

    # 单文件 retry:bad 行复位 pending → success → 任务回 completed
    r = await client.post(f"{BA}/tasks/{task.id}/files/{by['bad.mp4'].id}/retry",
                          headers=_h(world.member.id))
    assert r.status_code == 202, r.text
    mock_baidu.fail_first[fs_bad] = []
    await _claim_and_run(task.id)
    t = await _get_task(task.id)
    assert t.status == "completed"
    by = {r.rel_path: r for r in await _files_of(task.id)}
    assert by["bad.mp4"].status == "success" and by["dup.mp4"].status == "skipped_exists"

    # cancel:行归位 cancelled(pending 行)
    task2 = await _mk_task(world, status="running")
    await _mk_file(task2, "never.mp4", size=10)
    r2 = await client.post(f"{BA}/tasks/{task2.id}/cancel", headers=_h(world.member.id))
    assert r2.status_code == 202 and r2.json()["finalized"] is True
    t2 = await _get_task(task2.id)
    assert t2.status == "cancelled" and t2.cancelled_files >= 1, \
        "取消路径恒 cancelled(优先于聚合判定)"
    assert (await _files_of(task2.id))[0].status == "cancelled"


async def test_final_state_matrix_failed_cancelled_completed(
    world: World, mock_baidu, monkeypatch, client, enable_baidu, stack,
) -> None:
    """终态判定三分支:failed_files>0→failed / 取消恒 cancelled / 否则 completed;字节含 skipped。【集成】P1"""
    _zero_backoff(monkeypatch)
    # (a) 全成功 → completed;字节 = Σsuccess
    c1 = b"one" * 100
    t_a = await _mk_task(world, status="running")
    fs1 = random_fsid()
    mock_baidu.add(fs1, c1)
    await _mk_file(t_a, "one.mp4", size=len(c1), fs_id=fs1)
    await _dispatch_claim_run(t_a.id)
    t_a = await _get_task(t_a.id)
    assert t_a.status == "completed"
    assert t_a.done_files == 1 and t_a.done_bytes == len(c1)

    # (b) 1 success + 1 skipped → completed;done 与字节把 skipped 计入(§6 口径)
    c2 = b"two" * 100
    t_b = await _mk_task(world, status="running")
    fs2 = random_fsid()
    mock_baidu.add(fs2, c2)
    await _mk_file(t_b, "two.mp4", size=len(c2), fs_id=fs2)
    await _mk_file(t_b, "been.mp4", size=5)
    await _mk_asset(world, world.folder, "been.mp4", b"12345")
    await _dispatch_claim_run(t_b.id)
    t_b = await _get_task(t_b.id)
    assert t_b.status == "completed"
    assert t_b.done_files == 2, "done = success + skipped"
    assert t_b.done_bytes == len(c2) + 5, "skipped 行字节同样已消化(进度可满格)"

    # (c) 取消(无租约快路径)→ cancelled 且行归位(取消优先于聚合判定)
    c3 = b"three" * 100
    t_c = await _mk_task(world, status="running")
    fs3 = random_fsid()
    mock_baidu.add(fs3, c3)
    await _mk_file(t_c, "three.mp4", size=len(c3), fs_id=fs3)
    await _mk_file(t_c, "gone.mp4", size=1)
    r = await client.post(f"{BA}/tasks/{t_c.id}/cancel", headers=_h(world.member.id))
    assert r.status_code == 202 and r.json()["finalized"] is True
    t_c = await _get_task(t_c.id)
    assert t_c.status == "cancelled" and t_c.cancelled_files == 2


async def test_rate_limit_exhausted_task_failed_rows_revivable(
    world: World, mock_baidu, monkeypatch, client, enable_baidu, stack,
) -> None:
    """部分文件退避 5 次耗尽 → 行 failed('rate_limited')可复活、任务按终态判定落 failed。【集成】P1"""
    _zero_backoff(monkeypatch)
    content = b"rl-bytes"
    task = await _mk_task(world, status="running")
    fs = random_fsid()
    mock_baidu.add(fs, content)
    mock_baidu.fail_first[fs] = [BaiduApiError(CATEGORY_RATE_LIMITED, "rl", http_status=503)
                                 for _ in range(5)]
    row = await _mk_file(task, "rl.mp4", size=len(content), fs_id=fs)

    await _dispatch_claim_run(task.id)

    row = await _get_file(row.id)
    assert row.status == "failed" and row.attempts == 5, "退避单文件上限 5 次"
    assert "rate_limited" in (row.last_error or "")
    assert row.non_retryable is False, "频控耗尽可复活,不置 non_retryable"
    t = await _get_task(task.id)
    assert t.status == "failed" and t.fail_reason == "file_failed", "终态判定:failed_files>0 → failed"

    # 手动复活:attempts 归零重计 → 成功 → completed
    r = await client.post(f"{BA}/tasks/{task.id}/retry-failed", headers=_h(world.member.id))
    assert r.status_code == 202
    row = await _get_file(row.id)
    assert row.status == "pending" and row.attempts == 0
    await _claim_and_run(task.id)
    assert await _task_status(task.id) == "completed"


# ─── 覆盖导入(清除-再导入)与回摆 ─────────────────────────────────────────────
async def _mk_completed_with_skipped(world: World, *, old: bytes = b"old-bytes",
                                     user: User | None = None) -> tuple[BaiduBackupTask, BaiduBackupTaskFile, Asset, str]:
    """completed 任务 + 1 skipped 行(持旧 asset 与真实对象);返回 (task, row, old_asset, key)。"""
    key = _task_key(world.folder, "swing.mp4")
    task = await _mk_task(world, status="completed", user_id=(user or world.admin).id,
                          total_files=2, done_files=2, skipped_files=1,
                          total_bytes=10 + len(old), done_bytes=10 + len(old))
    old_asset = await _mk_asset(world, world.folder, "swing.mp4", old,
                                uploader=user or world.admin)
    row = await _mk_file(task, "swing.mp4", size=len(old), status="skipped_exists",
                         asset_id=old_asset.id)
    return task, row, old_asset, key


async def test_overwrite_swingback_completed_count_migration(
    world: World, mock_baidu, client, enable_baidu, stack,
) -> None:
    """completed 任务 overwrite 回摆:completed→running→completed;skipped-1/success+1/done 不变。【集成】P1"""
    old_content = b"old-object-bytes"
    task, row, old_asset, key = await _mk_completed_with_skipped(world, old=old_content)
    new_content = b"brand-new-content!!"

    r = await client.post(f"{BA}/tasks/{task.id}/files/{row.id}/overwrite",
                          headers=_h(world.admin.id))
    assert r.status_code == 202, r.text
    t = await _get_task(task.id)
    assert t.status == "running", "回摆必须重新占用活动名额(暂停删除)"

    mock_baidu.add((await _get_file(row.id)).fs_id, new_content)
    await _claim_and_run(task.id)

    t = await _get_task(task.id)
    assert t.status == "completed", "回摆完成回 completed"
    assert t.skipped_files == 0 and t.done_files == 2, "skipped-1、success+1、done 不变(集合内迁移)"
    assert t.done_bytes == 10 + len(new_content)
    from sqlalchemy import select
    async with _db() as db:
        assert await db.get(Asset, old_asset.id) is None, "旧 asset 行物理删除(非软删)"
        new_assets = (await db.execute(select(Asset).where(
            Asset.minio_bucket == world.project.minio_bucket, Asset.minio_key == key))).scalars().all()
    assert len(new_assets) == 1 and new_assets[0].size_bytes == len(new_content)
    head = await _head(world.project.minio_bucket, key)
    assert head is not None and head["ContentLength"] == len(new_content)
    # 审计:asset_purged 带 target_minio_key + details.asset_id,不带 target_asset_id(§5.1)
    async with _db() as db:
        purged = (await db.execute(select(AuditEvent).where(
            AuditEvent.event_type == "asset_purged"))).scalars().all()
    assert any((p.details or {}).get("asset_id") == str(old_asset.id) for p in purged), \
        f"asset_purged 审计缺失或快照不含旧 asset: {[p.details for p in purged]}"
    assert all(p.target_asset_id is None for p in purged), "行已删,不得带 target_asset_id(FK violation)"
    assert await _audit_count("baidu_file_imported") >= 1


async def test_swingback_row_refail_task_failed(
    world: World, mock_baidu, monkeypatch, client, enable_baidu, stack,
) -> None:
    """回摆期间该行再次失败 → 任务按通用终态判定转 failed(failed_files>0)。【集成】P1"""
    _zero_backoff(monkeypatch)
    task, row, old_asset, _key = await _mk_completed_with_skipped(world)
    r = await client.post(f"{BA}/tasks/{task.id}/files/{row.id}/overwrite",
                          headers=_h(world.admin.id))
    assert r.status_code == 202
    frow = await _get_file(row.id)
    mock_baidu.fail_first[frow.fs_id] = [BaiduApiError(CATEGORY_RATE_LIMITED, "rl", http_status=503)
                                         for _ in range(5)]
    await _claim_and_run(task.id)

    t = await _get_task(task.id)
    assert t.status == "failed" and t.fail_reason == "file_failed"
    frow = await _get_file(row.id)
    assert frow.status == "failed" and frow.overwrite is True
    assert "原文件已被删除" in (frow.last_error or ""), \
        "离开 importing 且 overwrite=true 的行必须在 last_error 补注(§6 统一规则)"
    async with _db() as db:
        assert await db.get(Asset, old_asset.id) is None, "清除已发生,旧 asset 不复活"


async def test_completed_with_stale_cancel_requested_overwrite_recovers(
    world: World, mock_baidu, client, enable_baidu, stack,
) -> None:
    """completed 任务带残留 cancel_requested → overwrite 复活必须复位取消位,正常跑完回 completed。【集成】P1"""
    task, row, _old_asset, _key = await _mk_completed_with_skipped(world)
    await _touch_task(task.id, cancel_requested=True, cancel_reason="user_cancel")

    r = await client.post(f"{BA}/tasks/{task.id}/files/{row.id}/overwrite",
                          headers=_h(world.admin.id))
    assert r.status_code == 202, r.text
    t = await _get_task(task.id)
    assert t.cancel_requested is False and t.cancel_reason is None, \
        "复活必须复位 cancel 位(防上一轮残留把复活任务秒取消,§5.2)"
    mock_baidu.add((await _get_file(row.id)).fs_id, b"fresh-bytes")
    await _claim_and_run(task.id)
    t = await _get_task(task.id)
    assert t.status == "completed", "复位后必须正常跑完,而非 cancelled"


async def test_overwrite_forbidden_without_can_admin_clears_flag(
    world: World, mock_baidu, client, enable_baidu, stack,
) -> None:
    """overwrite 无 can_admin → failed('overwrite_forbidden') 可重试,并清 overwrite 标志(防循环)。【集成】P1"""
    task, row, old_asset, key = await _mk_completed_with_skipped(world, user=world.member)
    perms = PermissionsService(get_settings())
    if await perms.check(user_subject=f"user:{world.member.id}", relation="can_admin",
                         object_type="folder", object_id=str(world.folder.id)):
        pytest.skip("member 意外持有 can_admin,用例前提不成立")

    r = await client.post(f"{BA}/tasks/{task.id}/files/{row.id}/overwrite",
                          headers=_h(world.member.id))
    assert r.status_code == 202
    mock_baidu.add((await _get_file(row.id)).fs_id, b"should-not-land")
    await _claim_and_run(task.id)

    frow = await _get_file(row.id)
    assert frow.status == "failed" and "overwrite_forbidden" in (frow.last_error or "")
    assert frow.overwrite is False, "权限复查未通过 → 清 overwrite 标志(§6,防 retry 循环)"
    async with _db() as db:
        assert await db.get(Asset, old_asset.id) is not None, "旧 asset 必须原样保留"
    assert await _head(world.project.minio_bucket, key) is not None


async def test_overwrite_defensive_sensitive_target_failed(
    world: World, mock_baidu, client, enable_baidu, stack,
) -> None:
    """防御断言:sensitive 目标命中一律拒绝,不做 org admin 豁免(直改 DB 构造)。【集成】P1"""
    task, row, old_asset, _key = await _mk_completed_with_skipped(world, user=world.admin)
    await _touch_folder_sensitive(world.folder.id, True)   # 直改 DB 构造 sensitive 目标

    r = await client.post(f"{BA}/tasks/{task.id}/files/{row.id}/overwrite",
                          headers=_h(world.admin.id))
    assert r.status_code == 202
    mock_baidu.add((await _get_file(row.id)).fs_id, b"nope")
    await _claim_and_run(task.id)

    frow = await _get_file(row.id)
    assert frow.status == "failed" and "overwrite_forbidden" in (frow.last_error or ""), \
        "org admin 也不得豁免 sensitive 防御断言(§6 步骤 2)"
    async with _db() as db:
        assert await db.get(Asset, old_asset.id) is not None


async def _touch_folder_sensitive(folder_id: uuid.UUID, value: bool) -> None:
    from sqlalchemy import update

    async with _db() as db:
        await db.execute(update(Folder).where(Folder.id == folder_id).values(is_sensitive=value))
        await db.commit()


async def test_overwrite_ambiguous_same_folder_duplicate_rows(
    world: World, mock_baidu, client, enable_baidu, stack,
) -> None:
    """同夹同名多行活跃 → failed('overwrite_ambiguous')(逐行人肉消歧不做)。【集成】P1"""
    task, row, old_asset, _key = await _mk_completed_with_skipped(world, user=world.admin)
    await _mk_asset(world, world.folder, "swing.mp4", b"dup-content",
                    uploader=world.admin)   # 同夹同名第二行

    r = await client.post(f"{BA}/tasks/{task.id}/files/{row.id}/overwrite",
                          headers=_h(world.admin.id))
    assert r.status_code == 202
    mock_baidu.add((await _get_file(row.id)).fs_id, b"x")
    await _claim_and_run(task.id)

    frow = await _get_file(row.id)
    assert frow.status == "failed" and "overwrite_ambiguous" in (frow.last_error or "")
    async with _db() as db:
        assert await db.get(Asset, old_asset.id) is not None, "歧义时不得清除任何一方"


async def test_overwrite_cross_asset_key_reference_ambiguous(
    world: World, mock_baidu, client, enable_baidu, stack,
) -> None:
    """跨资产 key 引用预检(含其他 folder 活跃行共享同 key)→ failed('overwrite_ambiguous')。【集成】P1"""
    task, row, _old_asset, key = await _mk_completed_with_skipped(world, user=world.admin)
    # 另一 folder 的活跃 asset 与旧 asset 共享 (bucket,key) —— 软删/跨项目共享均计数(§6 不区分软删)
    async with _db() as db:
        other_folder = Folder(project_id=world.project.id, name="other", minio_prefix="other/")
        db.add(other_folder)
        await db.commit()
        await db.refresh(other_folder)
    twin = Asset(folder_id=other_folder.id, filename="swing.mp4",
                 minio_bucket=world.project.minio_bucket, minio_key=key,
                 size_bytes=16, uploader_id=world.admin.id)
    async with _db() as db:
        db.add(twin)
        await db.commit()

    r = await client.post(f"{BA}/tasks/{task.id}/files/{row.id}/overwrite",
                          headers=_h(world.admin.id))
    assert r.status_code == 202
    mock_baidu.add((await _get_file(row.id)).fs_id, b"x")
    await _claim_and_run(task.id)

    frow = await _get_file(row.id)
    assert frow.status == "failed" and "overwrite_ambiguous" in (frow.last_error or ""), \
        "purge+重写会让共享方得到新内容的假资产行,必须拦截"


async def test_overwrite_purge_incomplete_retry_no_head_shortcut(
    world: World, mock_baidu, monkeypatch, client, enable_baidu, stack,
) -> None:
    """purge 未证实(head 仍命中)→ failed('purge_incomplete') 可重试;覆盖行重试禁用 head 快捷路径。【集成】P1"""
    old_content = b"stale-old-object"
    task, row, _old_asset, key = await _mk_completed_with_skipped(world, old=old_content)
    new_content = b"post-purge-new-bytes"

    # 第一轮:delete_object 抛错(purge best-effort 未证实)
    from app.services.presign import PresignService

    async def _boom(*a: Any, **k: Any) -> None:
        raise RuntimeError("minio delete failed")

    monkeypatch.setattr(PresignService, "delete_object", _boom)
    r = await client.post(f"{BA}/tasks/{task.id}/files/{row.id}/overwrite",
                          headers=_h(world.admin.id))
    assert r.status_code == 202
    fs = (await _get_file(row.id)).fs_id
    mock_baidu.add(fs, new_content)
    await _claim_and_run(task.id)
    frow = await _get_file(row.id)
    assert frow.status == "failed" and "purge_incomplete" in (frow.last_error or ""), \
        "head 仍命中旧对象 → 不得当新导入落库"
    assert key in (frow.last_error or "") and world.project.minio_bucket in (frow.last_error or ""), \
        "last_error 须附结构化 bucket/key 快照(重试按快照直 purge)"

    # 第二轮(重试):purge 恢复;覆盖行禁用 head 快捷路径(旧对象同 size 在位也不能跳过下载)
    r2 = await client.post(f"{BA}/tasks/{task.id}/files/{frow.id}/retry",
                           headers=_h(world.admin.id))
    assert r2.status_code == 202
    await _claim_and_run(task.id)
    frow = await _get_file(row.id)
    assert frow.status == "success"
    assert any(fs == fid and start == 0 for fid, start in mock_baidu.download_calls), \
        "覆盖行必须真实重传(head 快捷路径禁用直至 success)"
    head = await _head(world.project.minio_bucket, key)
    assert head is not None and head["ContentLength"] == len(new_content)
    t = await _get_task(task.id)
    assert t.status == "completed"


# ─── 复活型接口前置与互斥 ─────────────────────────────────────────────────────
async def test_revival_conflict_409_matrix(
    world: World, client, enable_baidu, stack,
) -> None:
    """复活统一前置 409 矩阵:绑定失效/同绑定活动互斥/目标夹删/跨账号换绑。【集成】P1"""
    # 前置 (a):binding expired
    t1 = await _mk_task(world, status="failed", fail_reason="timeout")
    await _mk_file(t1, "x.mp4", status="failed", attempts=1)
    await _touch_binding(world.binding.id, status="expired")
    r = await client.post(f"{BA}/tasks/{t1.id}/retry-failed", headers=_h(world.member.id))
    assert r.status_code == 409 and "binding_inactive" in r.text
    await _touch_binding(world.binding.id, status="active")

    # 前置 (b):同绑定已有其他活动中任务(partial unique 之外的应用层检查)
    t2 = await _mk_task(world, status="failed", fail_reason="timeout")
    await _mk_file(t2, "x.mp4", status="failed", attempts=1)
    await _mk_task(world, status="running")     # 另一个活动任务(同 binding)
    r = await client.post(f"{BA}/tasks/{t2.id}/retry-failed", headers=_h(world.member.id))
    assert r.status_code == 409

    # 前置 (c):目标夹已删(target_folder_id NULL)
    t3 = await _mk_task(world, status="failed", fail_reason="timeout")
    await _mk_file(t3, "x.mp4", status="failed", attempts=1)
    await _touch_task(t3.id, target_folder_id=None)
    r = await client.post(f"{BA}/tasks/{t3.id}/retry-failed", headers=_h(world.member.id))
    assert r.status_code == 409, "目标夹已删 → 409 提示删除任务重建"

    # 前置 (d):跨账号换绑(bound_baidu_uid 快照 ≠ 当前 binding.baidu_uid)
    t4 = await _mk_task(world, status="failed", fail_reason="timeout", uid_snapshot="999")
    await _mk_file(t4, "x.mp4", status="failed", attempts=1)
    r = await client.post(f"{BA}/tasks/{t4.id}/retry-failed", headers=_h(world.member.id))
    assert r.status_code == 409
    assert "已更换" in r.text or "删除任务重建" in r.text, "换绑文案必须引导重建"


async def test_cancelled_task_retry_and_overwrite_409(
    world: World, client, enable_baidu, stack,
) -> None:
    """cancelled 是用户终态不得复活:retry-failed / overwrite 均 409。【集成】P1"""
    task = await _mk_task(world, status="cancelled", cancel_reason="user_cancel")
    row = await _mk_file(task, "x.mp4", status="skipped_exists")
    r = await client.post(f"{BA}/tasks/{task.id}/retry-failed", headers=_h(world.member.id))
    assert r.status_code == 409
    r2 = await client.post(f"{BA}/tasks/{task.id}/files/{row.id}/overwrite",
                           headers=_h(world.member.id))
    assert r2.status_code == 409


async def test_single_file_retry_touches_only_target_row(
    world: World, mock_baidu, client, enable_baidu, stack,
) -> None:
    """单文件 retry:仅目标行复位,其他 failed 行原样;non_retryable 行单文件 retry 409。【集成】P1"""
    task = await _mk_task(world, status="failed", fail_reason="file_failed", enum_done=True)
    f1 = await _mk_file(task, "f1.mp4", status="failed", attempts=3, last_error="e1", bytes_done=123)
    f2 = await _mk_file(task, "f2.mp4", status="failed", attempts=5, last_error="e2")

    r = await client.post(f"{BA}/tasks/{task.id}/files/{f2.id}/retry", headers=_h(world.member.id))
    assert r.status_code == 202, r.text

    f1_after = await _get_file(f1.id)
    assert f1_after.status == "failed" and f1_after.attempts == 3 and f1_after.last_error == "e1" \
        and f1_after.bytes_done == 123, "单文件 retry 不得触碰其他 failed 行"
    f2_after = await _get_file(f2.id)
    assert f2_after.status == "pending" and f2_after.attempts == 0
    t = await _get_task(task.id)
    assert t.status == "running", "复活后任务回 running(重新占用活动名额)"

    # non_retryable 行(not_found 类):单文件 retry 409
    task2 = await _mk_task(world, status="failed", fail_reason="file_failed", enum_done=True)
    nf = await _mk_file(task2, "gone.mp4", status="failed", non_retryable=True, attempts=5)
    r2 = await client.post(f"{BA}/tasks/{task2.id}/files/{nf.id}/retry", headers=_h(world.member.id))
    assert r2.status_code == 409, "not_found 终态行不得单文件 retry(§4)"


async def test_manual_revival_resets_attempts_and_flags(
    world: World, client, enable_baidu, stack,
) -> None:
    """复活统一前置的复位集:attempts=0、retry_count+1、fail_reason/cancel 位清零、importing→pending。【集成】P1"""
    task = await _mk_task(world, status="failed", fail_reason="file_failed", enum_done=True,
                          retry_count=1, cancel_requested=True, cancel_reason="user_cancel")
    row = await _mk_file(task, "a.mp4", status="failed", attempts=3)
    imp = await _mk_file(task, "b.mp4", status="importing", bytes_done=5 * MB)

    r = await client.post(f"{BA}/tasks/{task.id}/retry-failed", headers=_h(world.member.id))
    assert r.status_code == 202, r.text

    t = await _get_task(task.id)
    assert t.retry_count == 2 and t.fail_reason is None
    assert t.cancel_requested is False and t.cancel_reason is None
    assert t.status == "running", "enum_done=true 的复活直接进导入循环(§4)"
    row_after = await _get_file(row.id)
    assert row_after.status == "pending" and row_after.attempts == 0, "含 attempts=0 重置(§5.2)"
    imp_after = await _get_file(imp.id)
    assert imp_after.status == "pending", "importing 行复位 pending(断点字段保留)"
    assert imp_after.bytes_done == 5 * MB


# ─── 换绑 / 解绑 / 断点作废 ───────────────────────────────────────────────────
async def test_rebind_different_uid_invalidates_leftover_breakpoints(
    world: World, client, enable_baidu, mock_oauth, stack,
) -> None:
    """换绑(不同 uid)→ 名下全部残留 minio_upload_id 作废;>20 行分支只 abort importing 行。【集成】P1"""
    task = await _mk_task(world, status="failed", fail_reason="file_failed")
    key_imp, key_failed = "rb/imp.mp4", "rb/failed.mp4"
    up_imp = await _seed_multipart(world.project.minio_bucket, key_imp, 1)
    up_failed = await _seed_multipart(world.project.minio_bucket, key_failed, 1)
    row_imp = await _mk_file(task, "imp.mp4", status="importing", minio_upload_id=up_imp,
                             minio_bucket=world.project.minio_bucket, minio_key=key_imp,
                             bytes_done=5 * MB, dlink="https://old/x1")
    await _mk_file(task, "failed.mp4", status="failed", minio_upload_id=up_failed,
                   minio_bucket=world.project.minio_bucket, minio_key=key_failed,
                   bytes_done=5 * MB, dlink="https://old/x2")
    for i in range(23):    # 共 25 行 > 20 → 高存量分支
        await _mk_file(task, f"filler{i:02d}.mp4", status="failed",
                       minio_upload_id=f"ghost-{i}", bytes_done=1, dlink="https://old/x")

    mock_oauth["uid"] = "200"     # 换绑到不同百度账号
    r = await client.post(f"{BA}/binding", json={"code": "it-code"}, headers=_h(world.member.id))
    assert r.status_code in (200, 201), r.text

    row_imp = await _get_file(row_imp.id)
    assert row_imp.minio_upload_id is None and row_imp.bytes_done == 0, \
        "importing 行会话必须 abort+清列(防旧偏移续到新账号产出静默损坏)"
    assert await _list_parts_sync(world.project.minio_bucket, key_imp, up_imp) is None
    failed_row = next(x for x in await _files_of(task.id) if x.rel_path == "failed.mp4")
    assert failed_row.minio_upload_id == up_failed, \
        ">20 行分支:failed 行交 sweeper 孤儿通道/bucket lifecycle,内联不拖垮请求"
    assert await _list_parts_sync(world.project.minio_bucket, key_failed, up_failed) is not None
    rows = await _files_of(task.id)
    assert all(x.dlink is None for x in rows), "清全部 dlink 缓存(旧 dlink 配新 token 常表现 403)"
    async with _db() as db:
        b = await db.get(BaiduBinding, world.binding.id)
    assert b.baidu_uid == "200"
    assert await _audit_count("baidu_bind", actor_user_id=world.member.id) >= 1


async def test_unbind_soft_deletes_and_invalidates_breakpoints(
    world: World, client, enable_baidu, mock_oauth, stack,
) -> None:
    """软解绑:行保留供历史引用、密文清空;≤20 行内联全量 abort;活动任务取消(binding_replaced)。【集成】P1"""
    task = await _mk_task(world, status="running")
    key = "ub/imp.mp4"
    up = await _seed_multipart(world.project.minio_bucket, key, 1)
    await _mk_file(task, "imp.mp4", status="importing", minio_upload_id=up,
                   minio_bucket=world.project.minio_bucket, minio_key=key, bytes_done=5 * MB)

    r = await client.delete(f"{BA}/binding", headers=_h(world.member.id))
    assert r.status_code == 204, r.text

    async with _db() as db:
        b = await db.get(BaiduBinding, world.binding.id)
    assert b is not None, "软解绑:行保留(历史任务 FK 仍引用)"
    assert b.status == "unbound"
    assert not b.access_token_enc and not b.refresh_token_enc, "两列 token 密文必须清空"
    t = await _get_task(task.id)
    assert t.status == "cancelled" and t.cancel_reason == "binding_replaced"
    row = (await _files_of(task.id))[0]
    assert row.minio_upload_id is None and row.bytes_done == 0
    assert await _list_parts_sync(world.project.minio_bucket, key, up) is None
    assert await _audit_count("baidu_unbind", actor_user_id=world.member.id) >= 1


async def test_retry_after_rebind_does_not_reuse_old_multipart(
    world: World, mock_baidu, client, enable_baidu, mock_oauth, stack,
) -> None:
    """换绑后 retry 不复用旧 multipart:从 0 重传、新会话(§5.2②作废的正确性)。【集成】P1"""
    task = await _mk_task(world, status="failed", fail_reason="file_failed")
    key = "rr/one.mp4"
    old_up = await _seed_multipart(world.project.minio_bucket, key, 1)
    row = await _mk_file(task, "one.mp4", status="failed", attempts=1, minio_upload_id=old_up,
                         minio_bucket=world.project.minio_bucket, minio_key=key, bytes_done=5 * MB)
    mock_oauth["uid"] = "200"
    r = await client.post(f"{BA}/binding", json={"code": "it-code"}, headers=_h(world.member.id))
    assert r.status_code in (200, 201)

    content = b"after-rebind-bytes"
    mock_baidu.add(row.fs_id, content)
    r2 = await client.post(f"{BA}/tasks/{task.id}/retry-failed", headers=_h(world.member.id))
    assert r2.status_code == 202
    await _claim_and_run(task.id)

    row = await _get_file(row.id)
    assert row.status == "success"
    assert row.minio_upload_id != old_up, "必须创建全新 multipart 会话"
    starts = [start for fid, start in mock_baidu.download_calls if fid == row.fs_id]
    assert starts == [0], f"换绑后必须从 0 重传: {starts}"
    head = await _head(world.project.minio_bucket, key)
    assert head is not None and head["ContentLength"] == len(content)


async def test_binding_replaced_stops_runner_within_checkpoint(
    world: World, mock_baidu, client, enable_baidu, stack,
) -> None:
    """绑定切换:在途 runner ≤一个检查点周期停止;取消路径归位 + overwrite 行加注。【集成】P1"""
    content = os.urandom(256 * 1024)
    task = await _mk_task(world, status="running")
    fs = random_fsid()
    mock_baidu.add(fs, content)
    mock_baidu.chunk_delay = 0.1
    row = await _mk_file(task, "slow.mp4", size=len(content), overwrite=True)

    job = asyncio.create_task(_dispatch_claim_run(task.id, runner="runner-A"))
    async def _mid() -> bool:
        r = await _get_file(row.id)
        return r.status == "importing" and 0 < r.bytes_done < len(content)
    assert await _eventually(_mid, timeout=60)

    # 换绑处置:置 cancel_requested + cancel_reason='binding_replaced'(§5.2①)
    stop_at = time.monotonic()
    await _touch_task(task.id, cancel_requested=True, cancel_reason="binding_replaced")

    await asyncio.wait_for(job, timeout=30)
    elapsed = time.monotonic() - stop_at
    assert elapsed <= 15, f"在途 runner 必须在 ≤一个检查点周期量级停止,实际 {elapsed:.1f}s"
    t = await _get_task(task.id)
    assert t.status == "cancelled" and t.cancel_reason == "binding_replaced"
    row = await _get_file(row.id)
    assert row.status == "cancelled"
    assert "原文件已被删除" in (row.last_error or ""), \
        "overwrite=true 的取消行必须加注(旧对象已清而新对象未落库,cancelled 无重试入口)"
    assert row.minio_upload_id is None, "取消路径 abort+清列(§6 归位表)"


# ─── 派发 / sweeper / 并发互斥 / 准入 ─────────────────────────────────────────
async def test_sweeper_takeover_never_dispatched(world: World, stack) -> None:
    """创建后未派发(dispatched_at=NULL)→ sweeper 必须接管(NULL 显式分支,§4 谓词)。【集成】P1"""
    task = await _mk_task(world, status="running", lease_seq=0)
    await _sweep_now()
    t = await _get_task(task.id)
    assert t.dispatched_at is not None, "从未派发的任务必须被 sweeper 接管"
    assert t.lease_seq == 1 and t.runner_id is None and t.lease_until is None
    assert t.round_started_at is None, "接管派发不复位/写入轮起点(48h 跨接管累计口径)"
    assert await _job_queued(task.id, 1), "接管后必须入队"


async def test_enqueue_failure_queue_loss_sweeper_takeover_next_round(
    world: World, stack,
) -> None:
    """入队失败/Redis 队列丢失 → sweeper 下一轮必须接管(节流窗口过后重新派发)。【集成】P1"""
    task = await _mk_task(world, status="running", lease_seq=0)
    await _sweep_now()
    t = await _get_task(task.id)
    assert t.lease_seq == 1
    await _queue_zrem(f"baidu_backup_run:{task.id}:1")   # 模拟队列丢失

    await _touch_task(task.id, dispatched_at=NOW - timedelta(minutes=11))
    await _sweep_now()
    t = await _get_task(task.id)
    assert t.lease_seq == 2, "队列丢失后 sweeper 必须用新 seq 重新派发"
    assert await _job_queued(task.id, 2)


async def test_enqueue_returns_none_branch(world: World, monkeypatch, stack) -> None:
    """入队返回 None 分支:派发步不重试不抛,DB 侧照常落,交 sweeper 兜底(§6 接力变体语义)。【集成】P1"""
    import arq

    async def _none_enqueue(self: Any, name: str, *a: Any, **k: Any) -> None:
        return None

    monkeypatch.setattr(arq.Redis, "enqueue_job", _none_enqueue)
    task = await _mk_task(world, status="running", lease_seq=0)
    await _sweep_now()
    t = await _get_task(task.id)
    assert t.lease_seq == 1 and t.dispatched_at is not None, "入队 None 不得让派发步失败"
    assert not await _job_queued(task.id, 1), "None = 未入队(后续由 sweeper 重新派发)"


async def test_sweeper_cancel_requested_direct_finalize(world: World, stack) -> None:
    """sweeper 对 cancel_requested+无租约直接终态化 cancelled,不再入队(白省一次派发)。【集成】P1"""
    task = await _mk_task(world, status="running", runner_id="stale-runner",
                          cancel_requested=True, cancel_reason="user_cancel", lease_seq=3)
    key = "sw/imp.mp4"
    up = await _seed_multipart(world.project.minio_bucket, key, 1)
    row = await _mk_file(task, "imp.mp4", status="importing", minio_upload_id=up,
                         minio_bucket=world.project.minio_bucket, minio_key=key, bytes_done=5 * MB)
    await _mk_file(task, "wait.mp4", status="pending")

    await _touch_task(task.id, dispatched_at=NOW - timedelta(minutes=11),
                      lease_until=NOW - timedelta(seconds=1))
    await _sweep_now()

    t = await _get_task(task.id)
    assert t.status == "cancelled", "cancel_requested 分支直接终态化"
    assert t.runner_id is None and t.lease_until is None, "终态化必须同步清 runner(§5.2 cancel)"
    assert t.lease_seq == 3, "直接终态化不再入队派发"
    row = await _get_file(row.id)
    assert row.status == "cancelled" and row.minio_upload_id is None
    assert await _list_parts_sync(world.project.minio_bucket, key, up) is None


async def test_concurrent_active_mutex_partial_index_and_app_layer(
    world: World, client, enable_baidu, stack,
) -> None:
    """同绑定并发互斥双层:应用层 409 + partial unique index 硬兜底。【集成】P1"""
    from sqlalchemy.exc import IntegrityError

    await _mk_task(world, status="running")
    r = await client.post(f"{BA}/tasks", json={
        "source_dir": "/it-src-2", "project_id": str(world.project.id),
        "target_folder_id": str(world.folder.id),
    }, headers=_h(world.member.id))
    assert r.status_code == 409, "应用层活动互斥检查 → 409"

    # 硬兜底:绕过应用层直插第二条活动任务 → 撞 uq_baidu_task_active
    t2 = BaiduBackupTask(
        user_id=world.member.id, binding_id=world.binding.id, bound_baidu_uid="100",
        source_dir="/it-src-3", project_id=world.project.id,
        target_folder_id=world.folder.id, status="running",
        lease_seq=0, total_files=0, done_files=0, failed_files=0, skipped_files=0,
        cancelled_files=0, total_bytes=0, done_bytes=0, speed_bps=0, speed_anchor_bytes=0,
    )
    with pytest.raises(IntegrityError):
        async with _db() as db:
            db.add(t2)
            await db.commit()


async def test_admission_three_queued_top2_deterministic(
    world: World, mock_baidu, stack,
) -> None:
    """≥3 排队任务同轮派发:确定性准入恰 2 运行(创建序),其余门控退出后可最终认领。【集成】P1"""
    perms = PermissionsService(get_settings())
    await perms.add_project_subject(project_id=str(world.project.id),
                                    subject=f"user:{world.outsider.id}", role="uploader")
    async with _db() as db:
        b2 = BaiduBinding(user_id=world.admin.id, access_token_enc="e2", refresh_token_enc="r2",
                          baidu_uid="200", access_token_expires_at=NOW + timedelta(days=30),
                          status="active", token_rotated_at=NOW)
        b3 = BaiduBinding(user_id=world.outsider.id, access_token_enc="e3", refresh_token_enc="r3",
                          baidu_uid="300", access_token_expires_at=NOW + timedelta(days=30),
                          status="active", token_rotated_at=NOW)
        db.add_all([b2, b3])
        await db.commit()
        await db.refresh(b2)
        await db.refresh(b3)

    triples = [(world.member, world.binding), (world.admin, b2), (world.outsider, b3)]
    tasks: list[BaiduBackupTask] = []
    for i, (user, binding) in enumerate(triples):
        t = await _mk_task(world, status="running", user_id=user.id, binding_id=binding.id,
                           uid_snapshot=binding.baidu_uid, source_dir=f"/admit-{i}")
        fs = random_fsid()
        mock_baidu.add(fs, b"admit-bytes")
        await _mk_file(t, f"f{i}.mp4", size=11, fs_id=fs)
        tasks.append(t)
    for t in tasks:
        async with _db() as db:
            assert await dispatch_baidu_task(db, t.id, sweeper=True)

    # 最新任务先被拾取 → 排名第 3 → 门控退出:runner/lease 清空、round_started_at 复位 NULL
    seq3 = (await _get_task(tasks[2].id)).lease_seq
    await _touch_task(tasks[2].id, round_started_at=NOW)   # 模拟曾运行过;门控退出必须复位
    await _run_job(tasks[2].id, seq3)
    t3 = await _get_task(tasks[2].id)
    assert t3.status == "running", "门控退出不落终态,回队列等待"
    assert t3.runner_id is None and t3.lease_until is None and t3.round_started_at is None, \
        "门控退出必须复位轮起点并清租约(不留半租约干扰计数与接管判定)"
    assert t3.lease_seq == seq3, "门控退出不得自派发(job 侧禁自旋,§6)"

    # 前两名按创建序依次认领并完成;随后 t3 重新拾取 → 排名 ≤2 → 准入认领续跑
    await _run_job(tasks[0].id, (await _get_task(tasks[0].id)).lease_seq)
    assert await _task_status(tasks[0].id) == "completed"
    await _run_job(tasks[1].id, (await _get_task(tasks[1].id)).lease_seq)
    assert await _task_status(tasks[1].id) == "completed"
    await _run_job(tasks[2].id, (await _get_task(tasks[2].id)).lease_seq)
    t3 = await _get_task(tasks[2].id)
    assert t3.status == "completed", "排队任务最终必须获得认领(确定性准入防瞬时全退饥饿)"


# ─── 断点续传 / 死会话 / head 快捷路径 / 落库防线 ─────────────────────────────
async def test_multipart_breakpoint_real_resume_from_bytes_done(
    world: World, mock_baidu, stack,
) -> None:
    """multipart 断点续传真实恢复:从已完成 parts 字节偏移 Range 续传至 complete。【集成】P1"""
    part = 16 * MB
    tail = os.urandom(4 * MB)
    total = part + len(tail)
    task = await _mk_task(world, status="running")
    key = _task_key(world.folder, "resume.mp4")
    upload_id = await _seed_multipart(world.project.minio_bucket, key, 1, part)
    fs = random_fsid()
    row = await _mk_file(task, "resume.mp4", size=total, status="pending",
                         fs_id=fs, bytes_done=part, minio_upload_id=upload_id,
                         minio_bucket=world.project.minio_bucket, minio_key=key)
    mock_baidu.tail_only[fs] = (total, tail)

    await _dispatch_claim_run(task.id)

    row = await _get_file(row.id)
    assert row.status == "success" and row.asset_id is not None
    assert mock_baidu.download_calls and mock_baidu.download_calls[-1] == (fs, part), \
        f"必须从已完成偏移 {part} 续传: {mock_baidu.download_calls}"
    assert row.minio_upload_id is None, "complete 成功后同事务清空 upload_id(§6)"
    head = await _head(world.project.minio_bucket, key)
    assert head is not None and head["ContentLength"] == total
    assert await _list_parts_sync(world.project.minio_bucket, key, upload_id) is None, \
        "complete 后会话已死"


async def test_dead_session_no_such_upload_resets_retransmit(
    world: World, mock_baidu, stack,
) -> None:
    """死会话(NoSuchUpload)自动清零重传:清 upload_id/bytes_done,重新 create 从 0。【集成】P1"""
    part = 16 * MB
    tail = os.urandom(4 * MB)
    total = part + len(tail)
    task = await _mk_task(world, status="running")
    key = _task_key(world.folder, "dead.mp4")
    dead_id = await _seed_multipart(world.project.minio_bucket, key, 1, part)
    await asyncio.to_thread(_abort_sync, world.project.minio_bucket, key, dead_id)
    fs = random_fsid()
    row = await _mk_file(task, "dead.mp4", size=total, status="pending",
                         fs_id=fs, bytes_done=part, minio_upload_id=dead_id,
                         minio_bucket=world.project.minio_bucket, minio_key=key)
    mock_baidu.add(fs, b"\x00" * part + tail)

    await _dispatch_claim_run(task.id)

    row = await _get_file(row.id)
    assert row.status == "success"
    assert mock_baidu.download_calls[-1][1] == 0, "死会话必须从 0 重传"
    assert row.minio_upload_id is None, "complete 后同事务清空 upload_id"
    head = await _head(world.project.minio_bucket, key)
    assert head is not None and head["ContentLength"] == total


async def test_crash_after_complete_head_hit_finalizes_asset(
    world: World, mock_baidu, stack,
) -> None:
    """complete 后崩溃(upload_id 已死)→ 接管后 head 命中(size 一致)直接落库,multipart ETag 不做 md5 比对。【集成】P1"""
    content = os.urandom(48 * 1024)
    task = await _mk_task(world, status="running")
    key = _task_key(world.folder, "crashed.mp4")
    await _put_object(world.project.minio_bucket, key, content)   # 对象已在(前次 complete 产物)
    dead = await _seed_multipart(world.project.minio_bucket, key + ".dead", 1)
    await asyncio.to_thread(_abort_sync, world.project.minio_bucket, key + ".dead", dead)
    fs = random_fsid()
    row = await _mk_file(task, "crashed.mp4", size=len(content), status="importing",
                         fs_id=fs, bytes_done=len(content), minio_upload_id=dead,
                         minio_bucket=world.project.minio_bucket, minio_key=key)

    await _dispatch_claim_run(task.id)   # 接管派发复位 importing → pending → head 命中落库

    row = await _get_file(row.id)
    assert row.status == "success" and row.asset_id is not None
    assert not any(fid == fs for fid, _ in mock_baidu.download_calls), \
        "head 命中(size 一致+预检通过)不得重新下载"
    head = await _head(world.project.minio_bucket, key)
    assert head is not None and head["ContentLength"] == len(content)
    t = await _get_task(task.id)
    assert t.status == "completed"


async def test_head_hit_with_soft_deleted_same_name_ambiguous(
    world: World, mock_baidu, stack,
) -> None:
    """head 命中路径含同夹同名软删行占位 → failed('overwrite_ambiguous') 而非落库共享对象。【集成】P1"""
    content = os.urandom(1024)
    task = await _mk_task(world, status="running")
    key = _task_key(world.folder, "ghost.mp4")
    await _put_object(world.project.minio_bucket, key, content)
    await _mk_asset(world, world.folder, "ghost.mp4", content, deleted=True)  # 软删占位
    fs = random_fsid()
    row = await _mk_file(task, "ghost.mp4", size=len(content), status="pending", fs_id=fs)
    mock_baidu.add(fs, content)

    await _dispatch_claim_run(task.id)

    row = await _get_file(row.id)
    assert row.status == "failed" and "overwrite_ambiguous" in (row.last_error or ""), \
        "同夹同名软删行不触发 skip、其对象仍在,直接落库即共享物理对象(§6 步骤 5)"
    assert row.asset_id is None
    head = await _head(world.project.minio_bucket, key)
    assert head is not None and head["ContentLength"] == len(content)


async def test_zero_byte_file_put_object_direct(world: World, mock_baidu, stack) -> None:
    """size=0 空文件走 put_object 直传(multipart 无法 complete 0 parts)。【集成】P1"""
    task = await _mk_task(world, status="running")
    fs = random_fsid()
    row = await _mk_file(task, "empty.bin", size=0, status="pending", fs_id=fs)

    await _dispatch_claim_run(task.id)

    row = await _get_file(row.id)
    assert row.status == "success" and row.asset_id is not None
    assert row.minio_upload_id is None, "零字节不建 multipart 会话"
    key = _task_key(world.folder, "empty.bin")
    head = await _head(world.project.minio_bucket, key)
    assert head is not None and head["ContentLength"] == 0


async def test_size_mismatch_row_failed_intercepted(world: World, mock_baidu, stack) -> None:
    """head size 与 source_size 不符 → failed('size_mismatch') 拦截(断点错位不落库)。【集成】P1"""
    task = await _mk_task(world, status="running")
    fs = random_fsid()
    row = await _mk_file(task, "broken.mp4", size=1000, status="pending", fs_id=fs)
    mock_baidu.add(fs, b"short!")   # 实际只有 6 字节

    await _dispatch_claim_run(task.id)

    row = await _get_file(row.id)
    assert row.status == "failed" and "size_mismatch" in (row.last_error or "")
    assert row.asset_id is None, "size 不符不得落库(防静默损坏文件)"
    assert await _task_status(task.id) == "failed"


async def test_seed_1001_parts_takeover_resume_no_rollback(
    world: World, mock_baidu, stack,
) -> None:
    """>1000 parts 死会话接管续传不回退:直 seed 1001x5MiB parts + mock 下载尾段(≈5.3GB,不做真实下载)。【集成】P1"""
    part = 5 * MB
    tail = os.urandom(3 * MB)
    total = 1001 * part + len(tail)
    task = await _mk_task(world, status="running")
    key = _task_key(world.folder, "huge.bin")
    upload_id = await _seed_multipart(world.project.minio_bucket, key, 1001, part)
    fs = random_fsid()
    row = await _mk_file(task, "huge.bin", size=total, status="pending", fs_id=fs,
                         bytes_done=1001 * part, minio_upload_id=upload_id,
                         minio_bucket=world.project.minio_bucket, minio_key=key)
    mock_baidu.tail_only[fs] = (total, tail)

    await _dispatch_claim_run(task.id)

    row = await _get_file(row.id)
    assert row.status == "success", f"接管续传失败: {row.last_error}"
    assert mock_baidu.download_calls and mock_baidu.download_calls[-1] == (fs, 1001 * part), \
        "必须从 1001 parts 偏移续传(单页 10000 上限内取全,不回退重传)"
    head = await _head(world.project.minio_bucket, key)
    assert head is not None and head["ContentLength"] == total


# ─── 55min 接力 / 48h 判停 / 检查点优先级 / 排队豁免 ─────────────────────────
async def test_relay_checkpoint_hands_off_new_job_continues(
    world: World, mock_baidu, monkeypatch, stack,
) -> None:
    """55min 接力(注入 1s):单 job 到点派发接力变体后 return,新 job 认领续跑,任务不中断。【集成】P1"""
    _inject_delay(monkeypatch, "baidu_relay_after_s", "BAIDU_RELAY_AFTER_S", 1)
    content = os.urandom(512 * 1024)
    task = await _mk_task(world, status="running")
    fs = random_fsid()
    mock_baidu.add(fs, content)
    mock_baidu.chunk_delay = 0.5
    row = await _mk_file(task, "relay.mp4", size=len(content), fs_id=fs)

    await _dispatch_claim_run(task.id, runner="runner-J1")

    t = await _get_task(task.id)
    assert t.status == "running", "接力不是终态,任务不得中断"
    assert t.runner_id is None and t.lease_until is None, "接力派发变体清 runner/租约"
    assert t.lease_seq >= 2, "接力派发自增 lease_seq"
    row = await _get_file(row.id)
    assert row.status == "pending", "接力必须同事务复位在途 importing 行(§6)"
    assert row.bytes_done > 0 and row.minio_upload_id is not None, "断点字段保留(无缝接力)"
    assert await _job_queued(task.id, t.lease_seq), "接力成功后必须入队新 job"

    # 新 job 认领续跑至完成
    await _claim_and_run(task.id, runner="runner-J2")
    t = await _get_task(task.id)
    assert t.status == "completed"
    assert (await _get_file(row.id)).status == "success"
    starts = [start for fid, start in mock_baidu.download_calls if fid == fs]
    assert len(starts) >= 2 and starts[1] > 0, f"接力后必须从断点续传: {starts}"


async def test_relay_mid_file_importing_row_reset_resume_to_success(
    world: World, mock_baidu, monkeypatch, stack,
) -> None:
    """单文件下载中途 55min 接力:importing 行复位 pending,新 job 从断点续传该行至 success。【集成】P1"""
    _inject_delay(monkeypatch, "baidu_relay_after_s", "BAIDU_RELAY_AFTER_S", 1)
    content = os.urandom(1024 * 1024)
    task = await _mk_task(world, status="running")
    fs = random_fsid()
    mock_baidu.add(fs, content)
    mock_baidu.chunk_delay = 0.5
    row = await _mk_file(task, "midfile.mp4", size=len(content), fs_id=fs)

    job = asyncio.create_task(_dispatch_claim_run(task.id, runner="runner-M1"))
    async def _importing() -> bool:
        r = await _get_file(row.id)
        return r.status == "importing" and r.bytes_done > 0
    assert await _eventually(_importing, timeout=30)
    bytes_at_relay = (await _get_file(row.id)).bytes_done

    await asyncio.wait_for(job, timeout=60)
    row = await _get_file(row.id)
    assert row.status == "pending" and row.bytes_done >= bytes_at_relay, "接力复位且断点单调"
    await _claim_and_run(task.id, runner="runner-M2")
    row = await _get_file(row.id)
    assert row.status == "success"
    resumes = [s for fid, s in mock_baidu.download_calls if fid == row.fs_id and s > 0]
    assert resumes and resumes[0] == bytes_at_relay, f"新 job 必须从断点 {bytes_at_relay} 续传"


async def test_checkpoint_priority_cancel_beats_timeout_and_relay(
    world: World, mock_baidu, monkeypatch, stack,
) -> None:
    """检查点固定优先级:cancel_requested → 急停 flag → 48h 超时 → 接力;取消意图恒最高。【集成】P1"""
    _inject_delay(monkeypatch, "baidu_relay_after_s", "BAIDU_RELAY_AFTER_S", 1)
    _inject_delay(monkeypatch, "baidu_round_timeout_s", "BAIDU_ROUND_TIMEOUT_S", 1)
    content = os.urandom(512 * 1024)
    task = await _mk_task(world, status="running", cancel_requested=True, cancel_reason="user_cancel")
    fs = random_fsid()
    mock_baidu.add(fs, content)
    mock_baidu.chunk_delay = 0.5
    row = await _mk_file(task, "prio.mp4", size=len(content), fs_id=fs)

    seq = (await _get_task(task.id)).lease_seq
    await _claim_and_run(task.id, runner="runner-P")

    t = await _get_task(task.id)
    assert t.status == "cancelled", "同帧命中必须落 cancelled(而非 timeout/接力)"
    assert t.fail_reason is None
    assert t.lease_seq == seq, "取消路径不派发接力(seq 不变)"
    row = await _get_file(row.id)
    assert row.status == "cancelled"


async def test_round_timeout_runner_self_finalize_on_healthy_relay_chain(
    world: World, mock_baidu, monkeypatch, stack,
) -> None:
    """健康接力链跨 48h(注入 2.5s)→ runner 检查点自终态化 failed('timeout'),multipart 保留。【集成】P1"""
    _inject_delay(monkeypatch, "baidu_relay_after_s", "BAIDU_RELAY_AFTER_S", 1)
    _inject_delay(monkeypatch, "baidu_round_timeout_s", "BAIDU_ROUND_TIMEOUT_S", 2.5)
    content = os.urandom(1024 * 1024)
    task = await _mk_task(world, status="running")
    fs = random_fsid()
    mock_baidu.add(fs, content)
    mock_baidu.chunk_delay = 0.5
    row = await _mk_file(task, "slowpoke.mp4", size=len(content), fs_id=fs)

    await _dispatch_claim_run(task.id, runner="runner-T1")

    t = await _get_task(task.id)
    assert t.status == "failed" and t.fail_reason == "timeout", \
        f"主路径判停必须由 runner 完成,实际 status={t.status} reason={t.fail_reason}"
    row = await _get_file(row.id)
    assert row.status == "failed" and "task_timeout" in (row.last_error or "")
    assert row.minio_upload_id is not None, "timeout 分支保留 multipart 供下轮续传(§6 归位表)"


async def test_timed_out_task_not_infinitely_revived_by_sweeper(
    world: World, mock_baidu, stack,
) -> None:
    """超时任务不被 sweeper 无限复活(故障路径兜底;从未认领 round_started_at NULL 豁免不受影响)。【集成】P1"""
    task = await _mk_task(world, status="running", round_started_at=NOW - timedelta(hours=49))
    key = "tt/imp.mp4"
    up = await _seed_multipart(world.project.minio_bucket, key, 1)
    row = await _mk_file(task, "imp.mp4", status="importing", minio_upload_id=up,
                         minio_bucket=world.project.minio_bucket, minio_key=key, bytes_done=5 * MB)

    await _touch_task(task.id, dispatched_at=NOW - timedelta(minutes=11),
                      lease_until=NOW - timedelta(seconds=1))
    seq_before = (await _get_task(task.id)).lease_seq
    await _sweep_now()

    t = await _get_task(task.id)
    assert t.status == "failed" and t.fail_reason == "timeout", "sweeper 兜底判停"
    row = await _get_file(row.id)
    assert row.status == "failed" and "task_timeout" in (row.last_error or "")
    assert row.minio_upload_id == up, "判停保留断点(可 retry-failed 续轮)"
    assert t.lease_seq == seq_before, "判停后不得再派发"
    await _sweep_now()
    t = await _get_task(task.id)
    assert t.status == "failed", "第二轮 sweeper 不得复活已判停任务"


async def test_gate_exit_exemption_round_started_reset_not_timeout(
    world: World, stack,
) -> None:
    """排队期豁免:门控退出复位 round_started_at → 48h 判停不误伤排队任务(活跃运行时间口径)。【集成】P1"""
    task = await _mk_task(world, status="running", round_started_at=None)
    await _mk_file(task, "queued.mp4", size=10)
    await _touch_task(task.id, created_at=NOW - timedelta(days=3),
                      dispatched_at=NOW - timedelta(minutes=11),
                      lease_until=NOW - timedelta(seconds=1))
    seq_before = (await _get_task(task.id)).lease_seq

    await _sweep_now()

    t = await _get_task(task.id)
    assert t.status == "running" and t.fail_reason is None, \
        "round_started_at NULL(排队中)必须豁免 48h 判停"
    assert t.lease_seq == seq_before + 1, "豁免路径正常派发(排队 47h 只跑几分钟不被判超时)"


async def test_retry_revival_resets_round_started_then_claims_and_runs(
    world: World, mock_baidu, client, enable_baidu, stack,
) -> None:
    """retry 复活:round_started_at 归零(retry=新一轮),排队期满后认领续跑。【集成】P1"""
    aged = NOW - timedelta(hours=49)
    task = await _mk_task(world, status="failed", fail_reason="file_failed",
                          enum_done=True, round_started_at=aged)
    fs = random_fsid()
    content = b"revive-bytes"
    mock_baidu.add(fs, content)
    await _mk_file(task, "r.mp4", status="failed", attempts=1, size=len(content), fs_id=fs)

    r = await client.post(f"{BA}/tasks/{task.id}/retry-failed", headers=_h(world.member.id))
    assert r.status_code == 202
    t = await _get_task(task.id)
    assert t.round_started_at is None, "复活型派发步必须复位轮起点(§6;仅复活复位)"

    before = datetime.now(UTC)
    await _claim_and_run(task.id)
    t = await _get_task(task.id)
    assert t.status == "completed"
    assert t.round_started_at is not None and t.round_started_at >= before - timedelta(seconds=5), \
        "认领 COALESCE 以 now() 重置轮起点(而非沿用 49h 前旧值)"


# ─── 部署重启 / 急停 ──────────────────────────────────────────────────────────
async def test_sigterm_restart_no_false_timeout_sweeper_takeover(
    world: World, baidu_stub, stack,
) -> None:
    """部署重启(SIGTERM→CancelledError)在途任务不误标 timeout;租约过期后 sweeper 接管续跑。【集成】P1"""
    f1_content = os.urandom(64 * 1024)
    task = await _mk_task(world, status="running")
    f1 = await _mk_file(task, "sig.mp4", size=len(f1_content))
    baidu_stub.bodies = {f1.fs_id: f1_content}
    baidu_stub.chunk_delay = 0.2

    proc = _spawn_worker(baidu_stub)
    try:
        assert await _eventually(lambda: _any_importing(task.id), timeout=90)
        proc.terminate()            # SIGTERM:优雅取消(协程内不可区分的 CancelledError)
        proc.wait(timeout=30)
    finally:
        if proc.poll() is None:
            proc.kill()

    t = await _get_task(task.id)
    assert t.status == "running", "优雅重启不落终态(不误标 timeout)"
    assert t.fail_reason is None

    await _touch_task(task.id, lease_until=NOW - timedelta(seconds=1),
                      dispatched_at=NOW - timedelta(minutes=11))
    await _sweep_now()

    baidu_stub.chunk_delay = 0.0
    proc2 = _spawn_worker(baidu_stub)
    try:
        assert await _eventually(lambda: _task_status(task.id) == "completed", timeout=180)
    finally:
        proc2.terminate()
        proc2.wait(timeout=15)
    t = await _get_task(task.id)
    assert t.status == "completed" and t.fail_reason is None, "接管续跑无损"


async def test_kill_switch_feature_disabled_preserves_breakpoints_then_resumes(
    world: World, mock_baidu, monkeypatch, client, enable_baidu, stack,
) -> None:
    """急停 failed('feature_disabled') 断点保留;重开开关后 retry-failed 断点续传成功。【集成】P1"""
    part = 5 * MB
    total = part + 2 * MB
    task = await _mk_task(world, status="running")
    key = _task_key(world.folder, "ks.mp4")
    up = await _seed_multipart(world.project.minio_bucket, key, 1, part)
    fs = random_fsid()
    row = await _mk_file(task, "ks.mp4", size=total, status="importing", fs_id=fs,
                         bytes_done=part, minio_upload_id=up,
                         minio_bucket=world.project.minio_bucket, minio_key=key)
    mock_baidu.tail_only[fs] = (total, os.urandom(2 * MB))

    _set_feature_flag(monkeypatch, False)     # 回滚急停
    await _dispatch_claim_run(task.id, runner="runner-K")

    t = await _get_task(task.id)
    assert t.status == "failed" and t.fail_reason == "feature_disabled", \
        f"急停必须终态化 feature_disabled,实际 {t.status}/{t.fail_reason}"
    row = await _get_file(row.id)
    assert row.status == "failed" and row.minio_upload_id == up and row.bytes_done == part, \
        "急停保留 multipart 断点(重开功能后可 retry-failed 续传,不走不可逆 cancelled)"
    assert await _list_parts_sync(world.project.minio_bucket, key, up) is not None

    _set_feature_flag(monkeypatch, True)
    r = await client.post(f"{BA}/tasks/{task.id}/retry-failed", headers=_h(world.member.id))
    assert r.status_code == 202
    await _claim_and_run(task.id, runner="runner-K2")
    row = await _get_file(row.id)
    assert row.status == "success"
    resumes = [s for fid, s in mock_baidu.download_calls if fid == fs and s > 0]
    assert resumes and resumes[0] == part, f"重开后必须从断点 {part} 续传"
    t = await _get_task(task.id)
    assert t.status == "completed" and t.fail_reason is None


# ─── cancel / DELETE ─────────────────────────────────────────────────────────
async def test_cancel_fast_path_finalized_and_fallback_flag_path(
    world: World, client, enable_baidu, stack,
) -> None:
    """cancel CAS:无租约快路径直终态化 {finalized:true};活跃租约回落仅置 cancel_requested。【集成】P1"""
    # 快路径:pending/importing 按归位表复位 + abort 清 runner + multipart 放弃
    task = await _mk_task(world, status="running")
    key = "cf/imp.mp4"
    up = await _seed_multipart(world.project.minio_bucket, key, 1)
    await _mk_file(task, "done.mp4", status="success")
    await _mk_file(task, "wait.mp4", status="pending")
    await _mk_file(task, "imp.mp4", status="importing", minio_upload_id=up,
                   minio_bucket=world.project.minio_bucket, minio_key=key, bytes_done=5 * MB)

    r = await client.post(f"{BA}/tasks/{task.id}/cancel", headers=_h(world.member.id))
    assert r.status_code == 202 and r.json()["finalized"] is True, r.text
    t = await _get_task(task.id)
    assert t.status == "cancelled" and t.cancel_reason == "user_cancel"
    assert t.runner_id is None and t.lease_until is None, "直终态化 UPDATE 必须同步清 runner(§5.2)"
    by = {x.rel_path: x for x in await _files_of(task.id)}
    assert by["done.mp4"].status == "success", "已成功行保留"
    assert by["wait.mp4"].status == "cancelled" and by["imp.mp4"].status == "cancelled"
    assert by["imp.mp4"].minio_upload_id is None, "cancelled 分支 abort+清列(放弃进度)"
    assert await _list_parts_sync(world.project.minio_bucket, key, up) is None

    # 回落路径:活跃租约 → 仅置标志交 worker 消费
    task2 = await _mk_task(world, status="running", runner_id="runner-live",
                           lease_until=NOW + timedelta(seconds=60), lease_seq=1)
    r2 = await client.post(f"{BA}/tasks/{task2.id}/cancel", headers=_h(world.member.id))
    assert r2.status_code == 202 and r2.json()["finalized"] is False
    t2 = await _get_task(task2.id)
    assert t2.status == "running", "回落路径不终态化(等 runner 检查点消费)"
    assert t2.cancel_requested is True and t2.cancel_reason == "user_cancel"

    # 回落 UPDATE 带 AND status IN('enumerating','running'):终态任务二连 cancel → 409
    r3 = await client.post(f"{BA}/tasks/{task.id}/cancel", headers=_h(world.member.id))
    assert r3.status_code == 409, "已终态任务不得再 cancel(防脏 cancel_requested)"


async def test_cancel_terminal_409(world: World, client, enable_baidu, stack) -> None:
    """前置:仅活动中任务可取消,已终态 409。【集成】P1"""
    for status in ("completed", "cancelled", "failed"):
        t = await _mk_task(world, status=status)
        r = await client.post(f"{BA}/tasks/{t.id}/cancel", headers=_h(world.member.id))
        assert r.status_code == 409, f"status={status} 必须 409"
        after = await _get_task(t.id)
        assert after.cancel_requested is False, "409 路径不得留脏标志"


async def test_delete_running_409_terminal_204(world: World, client, enable_baidu, stack) -> None:
    """DELETE:running 一律 409(status='running' 不经 CAS 回落);终态 204 且级联删行。【集成】P1"""
    t_run = await _mk_task(world, status="running")
    r = await client.delete(f"{BA}/tasks/{t_run.id}", headers=_h(world.member.id))
    assert r.status_code == 409
    assert await _get_task(t_run.id) is not None

    t_done = await _mk_task(world, status="completed")
    await _mk_file(t_done, "kept.mp4", status="success")
    r2 = await client.delete(f"{BA}/tasks/{t_done.id}", headers=_h(world.member.id))
    assert r2.status_code == 204, r2.text
    assert await _get_task(t_done.id) is None
    assert await _files_of(t_done.id) == [], "task_files 级联删除"
    r3 = await client.delete(f"{BA}/tasks/{t_done.id}", headers=_h(world.member.id))
    assert r3.status_code in (404, 409), "重复删除必须拒绝"


async def test_delete_budget_branches_inline_abort_small_and_large(
    world: World, client, enable_baidu, stack,
) -> None:
    """DELETE budget 分支:≤20 行内联全量 abort;>20 行仅 abort importing 行(数百行不超时)。【集成】P1"""
    import time as _time

    async def _scenario(n_failed: int) -> None:
        task = await _mk_task(world, status="failed", fail_reason="file_failed")
        key_imp = f"bd{n_failed}/imp.mp4"
        key_f1 = f"bd{n_failed}/f1.mp4"
        key_f2 = f"bd{n_failed}/f2.mp4"
        up_imp = await _seed_multipart(world.project.minio_bucket, key_imp, 1)
        up_f1 = await _seed_multipart(world.project.minio_bucket, key_f1, 1)
        up_f2 = await _seed_multipart(world.project.minio_bucket, key_f2, 1)
        await _mk_file(task, "imp.mp4", status="importing", minio_upload_id=up_imp,
                       minio_bucket=world.project.minio_bucket, minio_key=key_imp, bytes_done=5 * MB)
        await _mk_file(task, "f1.mp4", status="failed", minio_upload_id=up_f1,
                       minio_bucket=world.project.minio_bucket, minio_key=key_f1, bytes_done=5 * MB)
        await _mk_file(task, "f2.mp4", status="failed", minio_upload_id=up_f2,
                       minio_bucket=world.project.minio_bucket, minio_key=key_f2, bytes_done=5 * MB)
        for i in range(n_failed - 3):
            await _mk_file(task, f"filler{i:03d}.mp4", status="failed",
                           minio_upload_id=f"ghost-{i}", bytes_done=1)

        started = _time.monotonic()
        r = await client.delete(f"{BA}/tasks/{task.id}", headers=_h(world.member.id))
        elapsed = _time.monotonic() - started
        assert r.status_code == 204, r.text
        assert elapsed < 30, f"DELETE 不得因逐行 abort 拖垮请求: {elapsed:.1f}s"
        assert await _get_task(task.id) is None and await _files_of(task.id) == []
        if n_failed <= 20:
            # ≤20:全量内联分批 abort(10 行/批)
            assert await _list_parts_sync(world.project.minio_bucket, key_imp, up_imp) is None
            assert await _list_parts_sync(world.project.minio_bucket, key_f1, up_f1) is None
            assert await _list_parts_sync(world.project.minio_bucket, key_f2, up_f2) is None
        else:
            # >20:仅 importing 行 abort;failed 行会话保留,交 sweeper 孤儿通道 + bucket 30d lifecycle
            assert await _list_parts_sync(world.project.minio_bucket, key_imp, up_imp) is None, \
                "importing 行(至多 1 行持活跃会话)必须内联 abort"
            assert await _list_parts_sync(world.project.minio_bucket, key_f1, up_f1) is not None, \
                "failed 行会话不在内联 budget 内(存量可达数百,全量会拖垮请求)"
            assert await _list_parts_sync(world.project.minio_bucket, key_f2, up_f2) is not None

    await _scenario(5)
    await _scenario(300)


# ─── 可见性 / 建链 / 行级权限复查 ─────────────────────────────────────────────
async def test_non_admin_creator_visibility_after_nested_import(
    world: World, mock_baidu, stack,
) -> None:
    """非 admin 创建者对导入产物可见:建链同事务写 parent tuple(漏写则全员不可见且 admin 验收测不出)。【集成】P1"""
    content = b"visible-bytes"
    task = await _mk_task(world, status="running")     # 创建者 = member(仅 uploader)
    fs = random_fsid()
    mock_baidu.add(fs, content)
    await _mk_file(task, "season01/ep01/clip.mp4", size=len(content), fs_id=fs)

    await _dispatch_claim_run(task.id)

    from sqlalchemy import select
    perms = PermissionsService(get_settings())
    async with _db() as db:
        folders = (await db.execute(select(Folder).where(
            Folder.project_id == world.project.id, Folder.name == "ep01"))).scalars().all()
        rows = (await db.execute(select(BaiduBackupTaskFile).where(
            BaiduBackupTaskFile.task_id == task.id))).scalars().all()
    assert len(folders) == 1, "目录链必须建出(season01/ep01)"
    leaf = folders[0]
    assert leaf.minio_prefix == "target-root/season01/ep01/", \
        f"minio_prefix 口径: {leaf.minio_prefix}"
    row = rows[0]
    assert row.status == "success" and row.target_folder_id == leaf.id, "链结果写回行级 target_folder_id"
    assert await perms.check(user_subject=f"user:{world.member.id}", relation="can_view",
                             object_type="folder", object_id=str(leaf.id)), \
        "建链必须写 parent tuple,否则非 admin 全员不可见"
    assert await perms.check(user_subject=f"user:{world.member.id}", relation="can_view",
                             object_type="asset", object_id=str(row.asset_id)), \
        "bootstrap_asset tuple 缺失会让导入产物不可见"
    await perms.close()


async def test_deleted_parent_tuple_self_heal_on_retry(
    world: World, mock_baidu, client, enable_baidu, stack,
) -> None:
    """直删 tuple 后重试自愈:复用分支同样幂等 ensure parent tuple(permissions.py:79-89 先例)。【集成】P1"""
    content = b"selfheal-bytes"
    task = await _mk_task(world, status="running")
    fs = random_fsid()
    mock_baidu.add(fs, content)
    row = await _mk_file(task, "heal/clip.mp4", size=len(content), fs_id=fs)
    await _dispatch_claim_run(task.id)
    row = await _get_file(row.id)
    assert row.status == "success"

    perms = PermissionsService(get_settings())
    from openfga_sdk.models import ClientTuple, ClientWriteRequest
    leaf_id = row.target_folder_id
    assert await perms.check(user_subject=f"user:{world.member.id}", relation="can_view",
                             object_type="folder", object_id=str(leaf_id))
    # 破坏:直删叶子夹的 parent tuple(模拟崩溃窗口留下的无 tuple 夹)
    await perms._client.write(ClientWriteRequest(deletes=[
        ClientTuple(user=f"folder:{world.folder.id}", relation="parent", object=f"folder:{leaf_id}")]))
    assert not await perms.check(user_subject=f"user:{world.member.id}", relation="can_view",
                                 object_type="folder", object_id=str(leaf_id))

    # 自愈:行级 target_folder_id 清空 + 单文件 retry → ensure_folder_chain 复用分支补 tuple
    from sqlalchemy import update
    async with _db() as db:
        await db.execute(update(BaiduBackupTaskFile).where(BaiduBackupTaskFile.id == row.id)
                         .values(status="failed", target_folder_id=None, attempts=0))
        await db.commit()
    await _touch_task(task.id, status="failed", fail_reason="file_failed")
    r = await client.post(f"{BA}/tasks/{task.id}/files/{row.id}/retry", headers=_h(world.member.id))
    assert r.status_code == 202
    await _claim_and_run(task.id)

    row = await _get_file(row.id)
    assert row.status == "success", f"重试必须自愈成功: {row.last_error}"
    assert await perms.check(user_subject=f"user:{world.member.id}", relation="can_view",
                             object_type="folder", object_id=str(leaf_id)), \
        "复用分支必须幂等 ensure tuple(否则权限复查永败形成无自愈循环)"
    await perms.close()


async def test_explicit_target_deleted_row_failed_vs_autocreated_rebuild(
    world: World, mock_baidu, stack,
) -> None:
    """显式目标夹被删 → 行 failed('target_deleted');auto_created 目标 → 在途重建写回。【集成】P1"""
    from sqlalchemy import delete as _del
    from sqlalchemy import select

    # (a) auto_created:删除承接夹 → runner 从 project 根重建同名夹写回 tasks.target_folder_id
    async with _db() as db:
        ac = Folder(project_id=world.project.id, name="auto-rebuild",
                    minio_prefix="auto-rebuild/")
        db.add(ac)
        await db.commit()
        await db.refresh(ac)
    t_auto = await _mk_task(world, status="running", auto_created=True, target=ac,
                            source_dir="/auto-rebuild-src")
    fs1 = random_fsid()
    content = b"rebuild-bytes"
    mock_baidu.add(fs1, content)
    row1 = await _mk_file(t_auto, "inner.mp4", size=len(content), fs_id=fs1)
    async with _db() as db:
        await db.execute(_del(Folder).where(Folder.id == ac.id))
        await db.commit()

    await _dispatch_claim_run(t_auto.id)

    t_auto = await _get_task(t_auto.id)
    assert t_auto.status == "completed"
    async with _db() as db:
        rebuilt = (await db.execute(select(Folder).where(
            Folder.project_id == world.project.id, Folder.minio_prefix == "auto-rebuild/"))).scalars().all()
    assert len(rebuilt) == 1, "承接夹必须在途重建"
    assert t_auto.target_folder_id == rebuilt[0].id, "新夹 id 写回 tasks.target_folder_id"
    row1 = await _get_file(row1.id)
    assert row1.status == "success"

    # (b) 显式目标夹被删(非 auto_created)→ 行 failed('target_deleted') 不静默换位
    t_exp = await _mk_task(world, status="running", target=world.folder)
    fs2 = random_fsid()
    mock_baidu.add(fs2, b"exp-bytes")
    row2 = await _mk_file(t_exp, "exp.mp4", size=9, fs_id=fs2)
    async with _db() as db:
        await db.execute(_del(Folder).where(Folder.id == world.folder.id))
        await db.commit()

    await _dispatch_claim_run(t_exp.id)

    row2 = await _get_file(row2.id)
    assert row2.status == "failed" and "target_deleted" in (row2.last_error or ""), \
        "显式目标被删必须显式失败(与 auto 重建不对称属刻意取舍,§6 步骤 1)"


async def test_worker_per_file_permission_revoke_row_failed_target_permission_denied(
    world: World, mock_baidu, stack,
) -> None:
    """创建者权限中途被撤 → 每文件 can_upload 复查逐行 failed('target_permission_denied') 可重试。【集成】P1"""
    perms = PermissionsService(get_settings())
    task = await _mk_task(world, status="running")
    fs1, fs2 = random_fsid(), random_fsid()
    mock_baidu.add(fs1, b"a" * 1024)
    mock_baidu.add(fs2, b"b" * 1024)
    await _mk_file(task, "p1.mp4", size=1024, fs_id=fs1)
    await _mk_file(task, "p2.mp4", size=1024, fs_id=fs2)

    # 撤销 member 的上传权限(project uploader + folder explicit)
    await perms.remove_project_subject(project_id=str(world.project.id),
                                       subject=f"user:{world.member.id}", role="uploader")
    await perms.revoke_folder_explicit_subject(folder_id=str(world.folder.id),
                                               subject=f"user:{world.member.id}",
                                               kind="explicit_uploader")

    await _dispatch_claim_run(task.id)

    rows = await _files_of(task.id)
    assert all(r.status == "failed" and "target_permission_denied" in (r.last_error or "")
               for r in rows), "权限中途被撤 → 逐文件复查自然收敛(§9)"
    assert all(r.non_retryable is False for r in rows), "权限类失败可重试(权限恢复后 retry 即可)"
    t = await _get_task(task.id)
    assert t.status == "failed" and t.fail_reason == "file_failed"
    await perms.close()

