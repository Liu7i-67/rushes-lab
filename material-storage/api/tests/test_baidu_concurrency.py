"""百度备份并发改造(多任务排队 + VIP 分道)— 容器集成测试(真 PG/Redis/MinIO)。

唯一需求依据:rushes-spec/material-storage/baidu-backup-multi-task-concurrency-plan.md
§4 T1-T18(qplan 定稿;断言口径与构造方式逐字取自方案,含 T5a 与各条目内子断言)。
会员同绑定 3 路并发增补依据(设计正本):docs/qdev/2026-11-18-baidu-vip-parallel-backup.md
§5 R1-R13 矩阵(T4 重做为 R11、T18 断言翻转;断言口径逐条取自正本)。
运行方式与门控同 test_baidu_integration.py:PG/Redis/MinIO 任一不可达 → 模块级 skip
(经复用的 stack fixture);**本阶段只写不跑**,验收由 PM 在隔离栈执行(需求 §7/§8)。

基建完全复用 tests/test_baidu_integration.py 既有惯例(world/stack/client fixture、
_mk_task/_touch_task/_run_job/_sweep_now 等 helper、真实 DB 会话,不用 mock 替换 DB);
本文件仅新增两类观测面:
- baidu_spy:BaiduScript 子类,补 list_dir 调用计数与下载 token 记录(T4/T5a/T8/T16
  的「零 list 重放」「刷新后主会话回写可见」断言载体);
- lanes:在 world 之上补建「用户 + 绑定」对(分道用例需要 >3 个绑定;收尾自清理,
  先于 world 清理执行)。

准入级断言依赖 tasks 表内无外来活动行:pytest 按文件名字母序收集,本文件先于
test_baidu_integration.py 执行时,先行的 test_admin_baidu_tasks 已做 module 级
收尾清理;本模块内各用例经 world/lanes fixture 逐测试清理 —— 与原
test_admission_three_queued_top2_deterministic 的隐含前提一致。

■ 方案 §4 测试功能点 ↔ 测试函数映射(每条 T 至少一个函数;子断言见各 docstring)
| T1   | test_t1_same_binding_second_task_201_and_sixth_soft_cap_409          |
| T2   | test_t2_admission_dedup_per_binding_and_running_representative       |
| T3   | test_t3_slots_full_dormant_not_admitted_gate_exit                    |
| T4   | test_r11_same_binding_parallel_running_no_belt_churn(T4 重做为 R11) |
| T5   | test_t5_first_terminal_then_sibling_admitted                         |
| T5a  | test_t5a_gate_exit_degrades_running_then_short_circuit_recover       |
| T6   | test_t6_revival_queues_under_soft_cap                                |
| T7   | tests/test_db_schema.py(模型元数据断言,本文件不重复)               |
| T8   | test_t8_refresh_locked_once_force_param_bypasses_freshness_shortcut  |
| T8   | test_t8_force_refresh_exactly_one_real_refresh                       |
| T8   | test_t8_concurrent_force_serialized_on_row_lock_no_kickout           |
| T8   | test_t8_exhaustion_without_expire_keeps_binding                      |
| T8   | test_t8_exhaustion_default_still_expires_binding                     |
| T8   | test_t8_31045_single_flight_session_isolation_and_main_session_writeback |
| T9   | test_t9_settings_defaults_and_red_lines(离线)                       |
| T9   | test_t9_worker_max_jobs_reads_settings                               |
| T9   | test_t9_admission_limit_param_effective                              |
| T9   | test_t9_nonvip_limit_param_effective_in_sql_and_worker_gate          |
| T9   | test_t9_soft_cap_param_effective_on_create                           |
| T10  | test_t10_rebind_cancels_multiple_active_tasks(跨绑定并发/审计聚合    |
|      | 隔离回归由既有用例承接;互斥与准入旧测试在 test_baidu_integration 重写)|
| T11  | test_t11_lane_preservation_third_nonvip_excluded_vip_admitted        |
| T12  | test_t12_total_cap_four_vip_running_block_all                        |
| T12  | test_t12_mixed_four_full_then_cross_lane_displacement_converge_to_four|
| T12  | test_t12_hard_upper_bound_six_fifth_vip_rejected                     |
| T13  | test_t13_unknown_vip_treated_as_nonvip                               |
| T14  | test_t14_vip_type_refresh_on_create_and_revive_best_effort           |
| T14  | test_t14_vip_refresh_expired_token_failure_does_not_block_create_and_revive |
| T14  | test_t14_vip_refresh_expired_token_success_rotates_and_backfills     |
| T15  | test_t15_lane_fifo_ordering                                          |
| T15  | test_t15_slow_lane_full_vip_jumps_queue_head                         |
| T15  | test_t15_stale_overlimit_active_rows_gate_exit_no_real_overrun       |
| T16  | test_t16_revive_funnel_zero_list_and_target_folder_precheck          |
| T17  | test_t17_sweeper_representative_dedup_crash_beats_dormant_reverse    |
| T17  | test_t17_sweep_batch_boundary_crash_row_latest_created_still_taken   |
| T17  | test_t17_cancel_branch_not_deduped_non_representative_finalized      |
| T18  | test_t18_migration_smoke_legacy_rows_untouched                       |

■ 会员同绑定 3 路并发 ↔ 测试函数映射(设计正本 2026-11-18-baidu-vip-parallel-backup.md
§5 R1-R13;断言口径逐条对齐正本)
| R1   | test_r1_vip_binding_five_tasks_picked_oldest_three                   |
| R2   | test_r2_two_vip_bindings_three_plus_one_total_four                   |
| R3   | test_r3_vip_three_reps_nonvip_two_bindings_tightened_to_one          |
| R4   | test_r4_nonvip_binding_five_tasks_picked_oldest_one                  |
| R5   | test_r5_vip_par_one_aligns_with_distinct_on_legacy_semantics         |
| R6   | test_r6_same_binding_four_vip_reps_plus_second_vip_binding           |
| R7   | test_r7_nonvip_multiple_bindings_still_capped_at_two                 |
| R8   | test_r8_sweeper_dispatch_budget_vip_three_nonvip_one                 |
| R9   | test_r9_budget_exhausted_cancel_requested_row_still_finalized        |
| R10  | test_r10_settings_vip_parallel_red_lines(离线)                      |
| R11  | test_r11_same_binding_parallel_running_no_belt_churn(原 T4 重做)    |
| R12  | tests/test_db_schema.py(模型元数据)+ 本文件 T18(实库 pg_indexes)   |
|      | 双口径联动,不另设函数                                               |
| R13  | test_r13_worker_gate_reads_vip_parallel_settings_rollback_lever      |
"""
from __future__ import annotations

import asyncio
import contextlib
import re
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import pytest
from sqlalchemy import delete, select, text

import app.services.baidu_backup as baidu_svc
from app.db.tables import BaiduBackupTask, BaiduBackupTaskFile, BaiduBinding, Folder, User
from app.services import baidu_client as baidu_client_module
from app.services.baidu_backup import (
    BaiduTaskError,
    _refresh_locked_once,
    admission_top_task_ids,
    ensure_fresh_access_token,
    force_refresh_access_token,
)
from app.services.baidu_client import (
    CATEGORY_LINK_EXPIRED,
    CATEGORY_UNKNOWN,
    BaiduApiError,
    BaiduTokenPair,
)
from app.services.permissions import PermissionsService
from app.settings import get_settings
from app.workers.main import WorkerSettings
from tests.test_baidu_integration import (  # 既有集成基建(helper 与被测惯例同源)
    BaiduScript,
    World,
    _claim_and_run,
    _crypto,
    _db,
    _dispatch_claim_run,
    _files_of,
    _get_file,
    _get_task,
    _h,
    _job_queued,
    _mk_file,
    _mk_task,
    _seed_listing,
    _sweep_now,
    _task_status,
    _touch_binding,
    _touch_task,
    decrypt_token,
    dispatch_baidu_task,
    encrypt_token,
    random_fsid,
)
from tests.test_baidu_integration import (
    _fast_baidu_delays as _baidu_it_fast_delays,  # noqa: F401  (autouse 随名注册即生效)
)
from tests.test_baidu_integration import (
    client as _baidu_it_client,  # noqa: F401
)
from tests.test_baidu_integration import (
    enable_baidu as _baidu_it_enable_baidu,  # noqa: F401
)
from tests.test_baidu_integration import (
    mock_oauth as _baidu_it_mock_oauth,  # noqa: F401
)
from tests.test_baidu_integration import (
    stack as _baidu_it_stack,  # noqa: F401
)
from tests.test_baidu_integration import (
    world as _baidu_it_world,  # noqa: F401
)
from tests.test_baidu_unit import make_settings

BA = "/api/v1/baidu/backup"
NOW = datetime.now(UTC)
API_DIR = Path(__file__).resolve().parents[1]

# ─── 集成层 fixture 重导出(经 getfixturevalue 委托:避免「用例形参与本模块
# 导入的 fixture 同名」触发 ruff F811;被委托对象仅作名字注册)─────────────────────
@pytest.fixture(scope="session")
def stack(request: pytest.FixtureRequest):
    """委托集成层三栈探测(session 级;任一不可达 → 模块级 skip)。"""
    return request.getfixturevalue("_baidu_it_stack")


@pytest.fixture
def world(request: pytest.FixtureRequest):
    """委托集成层世界脚手架(org/用户/project/夹/binding,逐测试清理)。"""
    return request.getfixturevalue("_baidu_it_world")


@pytest.fixture(scope="session")
def client(request: pytest.FixtureRequest):
    """委托集成层 ASGI client(lifespan)。"""
    return request.getfixturevalue("_baidu_it_client")


@pytest.fixture
def enable_baidu(request: pytest.FixtureRequest):
    """委托集成层功能开关 + 凭证注入。"""
    return request.getfixturevalue("_baidu_it_enable_baidu")


@pytest.fixture
def mock_oauth(request: pytest.FixtureRequest):
    """委托集成层 OAuth/uinfo 剧本(剧本 dict 可按用例改写,含 "vip_type" 键)。"""
    return request.getfixturevalue("_baidu_it_mock_oauth")


# ─── 观测面:list 调用计数 + 下载 token 记录(T4/T5a/T8/T16 断言载体)──────────
class _CountingBaiduScript(BaiduScript):
    """在集成层 BaiduScript 上加两个观测面(行为与父类完全一致):

    - list_calls:百度 list API 调用次数(T4/T5a/T16「重派零 list 重放」断言);
    - download_tokens:每次 stream_download 收到的 access_token(T8 31045 刷新
      成功后「主会话 binding 回写可见,后续文件用新 token」断言)。
    """

    def __init__(self) -> None:
        super().__init__()
        self.list_calls = 0
        self.download_tokens: list[str] = []

    async def list_dir(self, access_token: str, dir_path: str, *,
                       folders_only: bool = False, **_kwargs: Any):
        self.list_calls += 1
        return await super().list_dir(access_token, dir_path,
                                      folders_only=folders_only, **_kwargs)

    async def stream_download(self, access_token: str, dlink: str, *,
                              range_header: str | None = None, **_kwargs: Any):
        self.download_tokens.append(access_token)
        async for chunk in super().stream_download(access_token, dlink,
                                                   range_header=range_header, **_kwargs):
            yield chunk


@pytest.fixture
def baidu_spy(monkeypatch: pytest.MonkeyPatch) -> _CountingBaiduScript:
    """进程内替换百度网盘交互(同集成层 mock_baidu,换用带计数的子类)。"""
    script = _CountingBaiduScript()
    monkeypatch.setattr(baidu_client_module.BaiduNetdiskClient,
                        "stream_download", script.stream_download)
    monkeypatch.setattr(baidu_client_module.BaiduNetdiskClient,
                        "filemetas_batch", script.filemetas_batch)
    monkeypatch.setattr(baidu_client_module.BaiduNetdiskClient,
                        "list_dir", script.list_dir)
    return script


# ─── 分道世界:world 仅 3 用户,分道用例需要任意多「用户 + 绑定」对 ────────────
@dataclass
class Lane:
    user: User
    binding: BaiduBinding


class LaneFactory:
    """补建用户 + active 绑定对(vip_type 直定);收尾自清理(先于 world 清理)。"""

    def __init__(self, w: World) -> None:
        self.w = w
        self.created: list[Lane] = []
        self._fga_user_ids: list[str] = []   # 获项目授权的 lane 用户(FGA tuple 收尾撤销)

    async def grant_project_uploader(self, lane: Lane) -> None:
        """给 lane 用户授 project-level uploader(worker 每文件 can_upload 复查
        需要;world.member 由 world fixture 授权、lane 用户默认无 —— 真实导入
        用例 R11/R13 的前置,同 integration 准入用例给 outsider 授权的先例)。
        FGA tuple 由 cleanup 撤销(对齐 world fixture 收尾口径,防残留污染)。"""
        perms = PermissionsService(get_settings())
        await perms.add_project_subject(project_id=str(self.w.project.id),
                                        subject=f"user:{lane.user.id}", role="uploader")
        await perms.close()
        self._fga_user_ids.append(str(lane.user.id))

    async def add(self, *, vip_type: int | None = None) -> Lane:
        tag = uuid.uuid4().hex[:8]
        async with _db() as db:
            u = User(name=f"it-lane-{tag}",
                     email=f"it-lane-{tag}@example.com",
                     organization_id=self.w.org.id)
            db.add(u)
            await db.flush()
            b = BaiduBinding(
                user_id=u.id,
                access_token_enc=encrypt_token(f"it-lane-access-{tag}"),
                refresh_token_enc=encrypt_token(f"it-lane-refresh-{tag}"),
                baidu_uid=str(1000 + len(self.created)),
                nickname=f"it-lane-{tag}",
                access_token_expires_at=NOW + timedelta(days=30),
                status="active",
                last_authorized_at=NOW,
                token_rotated_at=NOW,
                vip_type=vip_type,
            )
            db.add(b)
            await db.commit()
            await db.refresh(b)
            db.expunge_all()
        lane = Lane(user=u, binding=b)
        self.created.append(lane)
        return lane

    async def cleanup(self) -> None:
        """tasks(binding FK RESTRICT)→ files → tasks → bindings → users;被授权
        lane 用户的 FGA tuple 随后撤销(用户行删除后 tuple 残留防污染,同 world)。"""
        if self._fga_user_ids:
            perms = PermissionsService(get_settings())
            for uid in self._fga_user_ids:
                with contextlib.suppress(Exception):
                    await perms.revoke_user_completely(uid)
            await perms.close()
        if not self.created:
            return
        binding_ids = [ln.binding.id for ln in self.created]
        user_ids = [ln.user.id for ln in self.created]
        async with _db() as db:
            task_ids = (await db.execute(select(BaiduBackupTask.id).where(
                BaiduBackupTask.binding_id.in_(binding_ids)))).scalars().all()
            if task_ids:
                await db.execute(delete(BaiduBackupTaskFile).where(
                    BaiduBackupTaskFile.task_id.in_(task_ids)))
                await db.execute(delete(BaiduBackupTask).where(
                    BaiduBackupTask.binding_id.in_(binding_ids)))
            await db.execute(delete(BaiduBinding).where(BaiduBinding.user_id.in_(user_ids)))
            await db.execute(delete(User).where(User.id.in_(user_ids)))
            await db.commit()


@pytest.fixture
async def lanes(world: World):
    """分道用例的「用户 + 绑定」工厂(依赖 world;teardown 先于 world 清理)。"""
    factory = LaneFactory(world)
    yield factory
    await factory.cleanup()


async def _admission(limit: int = 4, nonvip: int = 2, vip_par: int = 3) -> list[uuid.UUID]:
    """直呼分道准入(默认参数 = Settings 默认 4/2/3;vip_par 必选透传,会员道
    rn ≤ vip_par —— 会员同绑定 3 路并发契约;独立短会话)。"""
    async with _db() as db:
        return await admission_top_task_ids(db, limit=limit, nonvip_limit=nonvip,
                                            vip_par=vip_par)


async def _running_ids() -> set[uuid.UUID]:
    async with _db() as db:
        rows = (await db.execute(select(BaiduBackupTask.id).where(
            BaiduBackupTask.status == "running"))).scalars().all()
        return set(rows)


async def _seed_running_rep(world: World, lane: Lane, *,
                            created_min_ago: float = 5.0) -> BaiduBackupTask:
    """某分道上一条「已认领运行」代表(round 非空 → 恒为该绑定代表,§2.3)。"""
    return await _mk_task(
        world, status="running", enum_done=True,
        user_id=lane.user.id, binding_id=lane.binding.id,
        round_started_at=NOW - timedelta(minutes=1),
        created_at=NOW - timedelta(minutes=created_min_ago),
    )


# ════════════════════════════ T1:创建放行 + 软上限 ═════════════════════════════
async def test_t1_same_binding_second_task_201_and_sixth_soft_cap_409(
    world: World, client, enable_baidu, mock_oauth, stack,
) -> None:
    """T1(§2.5):同绑定第 2 个任务 201 + enumerating(dormant);第 6 个撞软上限
    409「该绑定排队任务已达上限」(默认 baidu_max_active_tasks_per_binding=5)。"""
    created_ids: list[uuid.UUID] = []
    for i in range(5):
        r = await client.post(f"{BA}/tasks", json={
            "source_dir": f"/it-src-{i}", "project_id": str(world.project.id),
            "target_folder_id": str(world.folder.id),
        }, headers=_h(world.member.id))
        assert r.status_code == 201, f"第 {i + 1} 个任务必须可创建: {r.text}"
        body = r.json()
        assert body["status"] == "enumerating", "创建即 enumerating(排队语义,§2.5)"
        created_ids.append(uuid.UUID(body["id"]))
    binding_ids = set()
    for tid in created_ids:
        binding_ids.add((await _get_task(tid)).binding_id)
    assert len(binding_ids) == 1, "五个任务同绑定(多活动行合法,§2.2 第 1 条)"

    r6 = await client.post(f"{BA}/tasks", json={
        "source_dir": "/it-src-5", "project_id": str(world.project.id),
        "target_folder_id": str(world.folder.id),
    }, headers=_h(world.member.id))
    assert r6.status_code == 409, f"第 6 个任务必须撞软上限: {r6.text}"
    assert "排队任务已达上限" in r6.text, "409 文案必须为「该绑定排队任务已达上限」(§2.5)"


# ════════════════════════════ T2:准入按绑定去重 ════════════════════════════════
async def test_t2_admission_dedup_per_binding_and_running_representative(
    world: World, lanes: LaneFactory, stack,
) -> None:
    """T2(§2.3 性质钉死):同绑定两条活跃只取最老代表;跨绑定两条都取;
    running(round 非空)恒为该绑定代表 → picked 按代表序排序。"""
    lane = await lanes.add(vip_type=None)
    await _mk_task(world, status="enumerating", enum_done=False,
                   created_at=NOW - timedelta(minutes=3))   # 更早的 dormant 兄弟
    running = await _mk_task(world, status="running", enum_done=True,
                             round_started_at=NOW - timedelta(minutes=1),
                             created_at=NOW - timedelta(minutes=1))
    cross = await _mk_task(world, status="enumerating", enum_done=False,
                           user_id=lane.user.id, binding_id=lane.binding.id,
                           created_at=NOW - timedelta(minutes=2))

    picked = await _admission()
    assert set(picked) == {running.id, cross.id}, (
        "每绑定只推一条代表(同绑定多任务只占一个并发坑,§2.3);"
        "running(round 非空)压过更早创建的 dormant 兄弟成为代表"
    )
    assert picked[0] == running.id, "picked 整体按代表序(round NULLS LAST, created_at, id)"


# ════════════════════════════ T3:槽满 dormant 不进前 N ════════════════════════
async def test_t3_slots_full_dormant_not_admitted_gate_exit(
    world: World, lanes: LaneFactory, enable_baidu, stack,
) -> None:
    """T3(§2.3):槽满(前 N 全 running)时 dormant 不进前 N;认领后门控安静退出
    路径不回归(不落终态、清租约/轮钟)。"""
    slots = []
    for _ in range(4):
        lane = await lanes.add(vip_type=1)
        slots.append(await _seed_running_rep(world, lane, created_min_ago=5.0))
    dorm_lane = await lanes.add(vip_type=1)
    dormant = await _mk_task(world, status="enumerating", enum_done=False,
                             user_id=dorm_lane.user.id, binding_id=dorm_lane.binding.id,
                             created_at=NOW)

    picked = await _admission()
    assert set(picked) == {t.id for t in slots}, "槽满时 dormant 不进前 N(§2.3 性质三)"

    async with _db() as db:
        assert await dispatch_baidu_task(db, dormant.id, sweeper=True)
    res = await _claim_and_run(dormant.id)
    assert res["status"] == "queued", f"门控退出必须安静回队: {res}"
    t = await _get_task(dormant.id)
    assert t.status == "enumerating" and t.fail_reason is None, "门控退出不落终态"
    assert t.runner_id is None and t.lease_until is None and t.round_started_at is None, \
        "门控退出必须复位轮起点并清租约(不留半租约干扰计数与接管判定)"


# ══════════ R11:T4 重做 —— 同绑定 2/3 任务并发达 running(§5 R11)════════════
async def test_r11_same_binding_parallel_running_no_belt_churn(
    world: World, lanes: LaneFactory, baidu_spy, enable_baidu, stack,
) -> None:
    """R11(设计正本 §5,原 T4 重做:uq_baidu_task_running 已随迁移 0022 删除,
    DB belt 回排队行为不复存在):① 同绑定会员 3 个任务逐一驱动,全部通过枚举
    收尾进入导入循环直至终态,全程无一返回 queued(无 belt churn、无 list 重放);
    ② 并发形态定格仿 T12 DB seed:seed 2 条 running + 驱动第 3 条过枚举收尾
    (原 belt 撞索引回排队点),定格后 _running_ids() 含 3 条 —— 同绑定 running
    数上限的唯一防线 = 参数化准入门控(D8)。"""
    lane = await lanes.add(vip_type=1)
    await lanes.grant_project_uploader(lane)   # worker 每文件 can_upload 复查的前置

    # ① 3 个会员任务(同绑定)逐一驱动:枚举 → 收尾置 running → 导入循环 → 终态
    tasks: list[BaiduBackupTask] = []
    for i in range(3):
        tasks.append(await _mk_task(
            world, status="enumerating", enum_done=False,
            user_id=lane.user.id, binding_id=lane.binding.id,
            created_at=NOW - timedelta(minutes=3 - i),
            source_dir=f"/it-r11-{i}",
        ))
    for i, t in enumerate(tasks):
        _seed_listing(baidu_spy, t.source_dir, {f"r11-{i}.mp4": f"r11-bytes-{i}".encode()})
        async with _db() as db:
            assert await dispatch_baidu_task(db, t.id, sweeper=True)
        res = await _claim_and_run(t.id)
        t_after = await _get_task(t.id)
        assert res["status"] == "completed" and t_after.status == "completed", \
            f"同绑定第 {i + 1} 个任务必须经枚举收尾直达终态(无 belt 回排队): {res} " \
            f"fail_reason={t_after.fail_reason}"
        rows = await _files_of(t.id)
        assert len(rows) == 1 and rows[0].status == "success", \
            f"导入循环真实走完: row={rows[0].status} last_error={rows[0].last_error}"
    assert baidu_spy.list_calls == 3, \
        "3 任务各真实枚举恰 1 次 list(全程零 belt churn 重放,原 T4 的重派重放已无)"

    # ② 并发形态定格仿 T12 DB seed:2 条 running(原索引下第 2 条连直插都会
    # IntegrityError)+ 第 3 条过枚举收尾 —— 原 belt 在收尾 UPDATE 处必回排队
    r1 = await _seed_running_rep(world, lane, created_min_ago=6.0)
    r2 = await _seed_running_rep(world, lane, created_min_ago=5.0)
    third = await _mk_task(world, status="enumerating", enum_done=False,
                           user_id=lane.user.id, binding_id=lane.binding.id,
                           created_at=NOW - timedelta(minutes=1),
                           source_dir="/it-r11-third")
    _seed_listing(baidu_spy, third.source_dir, {"r11-third.mp4": b"r11-third-bytes"})
    async with _db() as db:
        assert await dispatch_baidu_task(db, third.id, sweeper=True)
    res = await _claim_and_run(third.id)
    third_after = await _get_task(third.id)
    assert res["status"] == "completed" and third_after.status == "completed", (
        "2 条同绑定 running 在场时,第 3 条必须照常过枚举收尾进导入循环 "
        f"(原 uq_baidu_task_running 下此处必为 queued): {res} "
        f"fail_reason={third_after.fail_reason}"
    )
    assert baidu_spy.list_calls == 4, "第 3 条真实枚举恰 1 次(总计 3+1,零重放)"

    # 定格(T12 置换窗同款 _touch_task 口径):回拨 running 钉死「同绑定 3 条
    # running 并存」形态 —— DB 层不再拦,唯一防线=准入门控(§3.2 残余风险记录)
    await _touch_task(third.id, status="running",
                      round_started_at=NOW - timedelta(seconds=30))
    assert await _running_ids() == {r1.id, r2.id, third.id}, \
        "同绑定 3 条 running 并存(迁移 0022 后 DB 无 belt;D8)"


# ════════════════════════════ T5:首任务终态后接力准入 ═════════════════════════
async def test_t5_first_terminal_then_sibling_admitted(
    world: World, baidu_spy, enable_baidu, stack,
) -> None:
    """T5:同绑定一跑一排队 —— 首任务终态后,第二任务被准入并执行
    (直调 admission 断言排序切换,不等 sweeper 实时)。"""
    t1 = await _mk_task(world, status="running", enum_done=True,
                        round_started_at=NOW - timedelta(minutes=1),
                        created_at=NOW - timedelta(minutes=2))
    fs1 = random_fsid()
    baidu_spy.add(fs1, b"t5-one")
    await _mk_file(t1, "one.mp4", size=6, fs_id=fs1)
    t2 = await _mk_task(world, status="enumerating", enum_done=False,
                        created_at=NOW - timedelta(minutes=1), source_dir="/it-t5-2")
    _seed_listing(baidu_spy, "/it-t5-2", {"two.mp4": b"t5-two"})

    assert await _admission() == [t1.id], "同绑定仅最老代表进 picked(dormant 不占坑)"
    await _dispatch_claim_run(t1.id)
    assert await _task_status(t1.id) == "completed"

    assert await _admission() == [t2.id], "首任务终态后同绑定第二任务被准入"
    await _dispatch_claim_run(t2.id)
    assert await _task_status(t2.id) == "completed"


# ════════════════════════════ T5a:门控退出降级(§2.3)═════════════════════════
async def test_t5a_gate_exit_degrades_running_then_short_circuit_recover(
    world: World, lanes: LaneFactory, baidu_spy, enable_baidu, stack,
) -> None:
    """T5a(§2.3 门控退出统一降级):running 任务认领后门控退出 → status 同步降为
    enumerating、enum_done 保留、轮钟/租约清空;槽位腾出后再次认领经 enum_done
    短路路径恢复导入循环(零 list 重放)。构造:2 非会员 + 2 会员满载,较年轻的
    非会员 running 代表(受害者)不在 picked。"""
    blockers = []
    for vip in (0, 0, 1, 1):
        lane = await lanes.add(vip_type=vip)
        blockers.append(await _seed_running_rep(world, lane, created_min_ago=5.0))
    victim = await _mk_task(world, status="running", enum_done=True,
                            round_started_at=NOW - timedelta(minutes=1),
                            created_at=NOW - timedelta(minutes=1))
    fs = random_fsid()
    baidu_spy.add(fs, b"victim-bytes")
    row = await _mk_file(victim, "v.mp4", size=12, fs_id=fs)

    picked = await _admission()
    assert victim.id not in picked, "非会员道满(2),较年轻非会员代表被挤出 picked"

    async with _db() as db:
        assert await dispatch_baidu_task(db, victim.id, sweeper=True)
    res = await _claim_and_run(victim.id)
    assert res["status"] == "queued"
    t = await _get_task(victim.id)
    assert t.status == "enumerating", \
        "门控退出统一降级:status='running' 的行同步降为 enumerating(§2.3 修复绑定级活锁)"
    assert t.enum_done is True, "降级保留 enum_done(短路恢复的前提)"
    assert t.round_started_at is None and t.runner_id is None and t.lease_until is None, \
        "降级同步清轮钟/租约(无租约 running 行就此消灭)"

    # 清空槽位 → 重派 → enum_done 短路恢复导入循环
    for b in blockers:
        await _touch_task(b.id, status="completed")
    await _touch_task(victim.id, dispatched_at=NOW - timedelta(minutes=11))
    async with _db() as db:
        assert await dispatch_baidu_task(db, victim.id, sweeper=True)
    res = await _claim_and_run(victim.id)
    assert res["status"] == "completed"
    assert baidu_spy.list_calls == 0, "enum_done=true 短路:全程零 list API 调用(§2.5)"
    assert (await _get_file(row.id)).status == "success"


# ════════════════════════════ T6:复活排队语义 + 软上限 ════════════════════════
async def test_t6_revival_queues_under_soft_cap(
    world: World, client, enable_baidu, mock_oauth, stack,
) -> None:
    """T6(§2.5):复活在有活动任务时入队放行(202 + enumerating,非 409);
    同绑定活动任务达软上限(5)后,复活同口径被拒(409「该绑定排队任务已达上限」)。"""
    active = await _mk_task(world, status="running", enum_done=True,
                            round_started_at=NOW - timedelta(minutes=1))
    failed = await _mk_task(world, status="failed", enum_done=True,
                            fail_reason="file_failed", source_dir="/it-t6-failed")
    await _mk_file(failed, "f.mp4", status="failed", attempts=1)

    r = await client.post(f"{BA}/tasks/{failed.id}/retry-failed", headers=_h(world.member.id))
    assert r.status_code == 202, f"复活在有活动任务时必须入队放行: {r.text}"
    assert r.json()["status"] == "enumerating", "复活统一入队漏斗:返回恒 enumerating(§2.5/D11)"
    t = await _get_task(failed.id)
    assert t.status == "enumerating" and t.enum_done is True, \
        "复活落 enumerating 排队,enum_done 原样保留(worker 短路恢复)"
    assert (await _get_task(active.id)).status == "running", "前序 running 任务不受复活影响"

    # 补满软上限:当前活动 2(running + 刚复活的 enumerating),再补 3 条 → 5 = 上限
    for i in range(3):
        await _mk_task(world, status="enumerating", enum_done=False,
                       source_dir=f"/it-t6-fill-{i}")
    failed2 = await _mk_task(world, status="failed", enum_done=True,
                             fail_reason="file_failed", source_dir="/it-t6-failed2")
    await _mk_file(failed2, "g.mp4", status="failed", attempts=1)
    r2 = await client.post(f"{BA}/tasks/{failed2.id}/retry-failed", headers=_h(world.member.id))
    assert r2.status_code == 409, "达软上限后复活同口径受约束(§2.5)"
    assert "排队任务已达上限" in r2.text


# ════════════════════════════ T8:31045 单飞四断言(§2.6)══════════════════════
class _RotatingRefreshClient:
    """client 替身:refresh_token 轮换双 token 并记录入参(单飞断言用)。"""

    def __init__(self) -> None:
        self.calls: list[str] = []
        self.fail_with: Exception | None = None

    async def refresh_token(self, refresh_token: str) -> BaiduTokenPair:
        self.calls.append(refresh_token)   # record-then-raise:失败也是一次真实尝试,
        if self.fail_with is not None:     # 必须计数(耗尽口径 ≤3 次的断言载体)
            raise self.fail_with
        n = len(self.calls)
        return BaiduTokenPair(access_token=f"at-new-{n}",
                              refresh_token=f"rt-new-{n + 1}", expires_in=25 * 3600)


async def test_t8_refresh_locked_once_force_param_bypasses_freshness_shortcut(
    world: World, stack,
) -> None:
    """T8(§2.6.1):_refresh_locked_once 的 force 参数直测 —— force=False 保持
    新鲜度短路(自然过期路径的单飞去重机制,0 次真实刷新);force=True 跳过短路
    恰 1 次真实刷新(31045 场景「百度侧拒绝但本地未到期」,不旁路则复用坏 token)。"""
    fake = _RotatingRefreshClient()
    now = datetime.now(UTC)
    async with _db() as db:
        out = await _refresh_locked_once(db, world.binding.id, crypto=_crypto(),
                                         client=fake, now=now, force=False)
        assert out == "it-access-token"
        assert fake.calls == [], "force=False:token 未临期短路复用现存 token(0 次真实刷新)"
    async with _db() as db:
        out = await _refresh_locked_once(db, world.binding.id, crypto=_crypto(),
                                         client=fake, now=now, force=True)
        assert out == "at-new-1"
        assert fake.calls == ["it-refresh-token"], "force=True 旁路生效:恰 1 次真实刷新"


async def test_t8_force_refresh_exactly_one_real_refresh(
    world: World, stack,
) -> None:
    """T8 断言一(§2.6.1 force 旁路经包装入口):token 本地未临期时单次 force 恰
    1 次真实 refresh_token —— 对照组 ensure(自然过期路径)同 token 下 0 次调用,
    防「短路零调用也绿」。"""
    fake = _RotatingRefreshClient()
    async with _db() as db:
        binding = await db.get(BaiduBinding, world.binding.id)
        token = await ensure_fresh_access_token(db, binding, crypto=_crypto(), client=fake)
        assert token == "it-access-token"
        assert fake.calls == [], "对照:token 未临期时自然路径短路复用(0 次真实刷新)"

    async with _db() as db:
        out = await force_refresh_access_token(db, world.binding.id,
                                               crypto=_crypto(), client=fake)
    assert out == "at-new-1"
    assert fake.calls == ["it-refresh-token"], \
        "force 旁路生效:未临期也恰 1 次真实刷新(不复用现存坏 token)"
    async with _db() as db:
        b = await db.get(BaiduBinding, world.binding.id)
        assert decrypt_token(b.refresh_token_enc) == "rt-new-2", "轮换后 refresh_token 落库"
        assert b.token_rotated_at is not None


async def test_t8_concurrent_force_serialized_on_row_lock_no_kickout(
    world: World, stack,
) -> None:
    """T8 断言二(§2.6.1 语义要点):并发两次 force → 行锁串行化、各 1 次真实刷新
    (共 2 次,force 刻意不去重),第二次锁内复读到轮换后的 refresh_token、刷新
    成功不互踢;绑定终态为第二次轮换产物且仍 active。"""
    fake = _RotatingRefreshClient()

    async def _one() -> str:
        async with _db() as db:
            return await force_refresh_access_token(db, world.binding.id,
                                                    crypto=_crypto(), client=fake)

    r1, r2 = await asyncio.gather(_one(), _one())
    assert fake.calls == ["it-refresh-token", "rt-new-2"], (
        "行锁串行化:第二次 FOR UPDATE 阻塞至第一次提交,锁内复读到已轮换的新 "
        "refresh_token(若读到旧 rt-1 即互踢形态,必红)"
    )
    assert {r1, r2} == {"at-new-1", "at-new-2"}, "各做一次真实刷新且都拿到本轮新 access_token"
    async with _db() as db:
        b = await db.get(BaiduBinding, world.binding.id)
        assert b.status == "active", "并发 force 不误伤绑定(不互踢)"
        assert decrypt_token(b.refresh_token_enc) == "rt-new-3"


async def test_t8_exhaustion_without_expire_keeps_binding(
    world: World, monkeypatch: pytest.MonkeyPatch, stack,
) -> None:
    """T8 断言三(§2.6.3):expire_binding_on_exhaustion=False 时耗尽只抛
    BaiduTaskError、绑定不置 expired(31045 调用点回落 link_expired 的前提);
    真实调用次数 ≤ REFRESH_MAX_ATTEMPTS(3)。

    注:会话隔离(§2.6.2)是 31045 **调用点**的职责(独立 session 包装),
    `_refresh_locked_once` 失败路径本就会 rollback 调用方传入的 session ——
    隔离断言由下方 31045 端到端用例承接(job 全程不崩 = 主会话未被 expire)。"""
    monkeypatch.setattr(baidu_svc, "REFRESH_RETRY_BACKOFF_S", 0)   # 不吃真退避
    fake = _RotatingRefreshClient()
    fake.fail_with = RuntimeError("baidu token endpoint 5xx(桩注入)")

    async with _db() as db:
        with pytest.raises(BaiduTaskError):
            await force_refresh_access_token(db, world.binding.id, crypto=_crypto(),
                                             client=fake, expire_binding_on_exhaustion=False)
        assert len(fake.calls) == 3, "失败路径真实调用次数 ≤3(T8 刻意接受的口径变化)"

    async with _db() as db:
        assert (await db.get(BaiduBinding, world.binding.id)).status == "active", \
            "expire_binding_on_exhaustion=False:耗尽不置 expired(防「先置 expired 再抛」时序陷阱)"


async def test_t8_exhaustion_default_still_expires_binding(
    world: World, monkeypatch: pytest.MonkeyPatch, stack,
) -> None:
    """T8 断言三对照:默认 expire_binding_on_exhaustion=True 语义不变(既有调用方
    —— 枚举 _current_token force 路径等 —— 不受 31045 改造影响)。"""
    monkeypatch.setattr(baidu_svc, "REFRESH_RETRY_BACKOFF_S", 0)
    fake = _RotatingRefreshClient()
    fake.fail_with = RuntimeError("baidu token endpoint 5xx(桩注入)")
    async with _db() as db:
        with pytest.raises(BaiduTaskError):
            await force_refresh_access_token(db, world.binding.id, crypto=_crypto(), client=fake)
    async with _db() as db:
        assert (await db.get(BaiduBinding, world.binding.id)).status == "expired", \
            "默认路径保持「耗尽置 expired」既有语义"


async def test_t8_31045_single_flight_session_isolation_and_main_session_writeback(
    world: World, baidu_spy, enable_baidu, monkeypatch: pytest.MonkeyPatch, stack,
) -> None:
    """T8 断言四(§2.6.2 + 回写配套,31045 调用点端到端):31045 注入 **filemetas 腿**
    (dlink 懒取首取即失败;下载流层有 link_expired 流级拦截器转 _LinkRefreshNeeded,
    注在流上到不了 _handle_errno_31045)→ 恰 1 次真实 refresh_token(单飞);刷新放
    独立 session(job 不崩 = 主会话对象未被 rollback expire);成功后主会话 binding
    已回写新值 —— dlink 重取与后续文件均携带新 token(若缺 db.refresh 回写,身份
    映射还是旧 token,此处必红)。"""
    refresh_calls: list[str] = []

    async def fake_refresh(self: Any, rt: str, *_a: Any, **_k: Any) -> BaiduTokenPair:
        refresh_calls.append(rt)
        n = len(refresh_calls)
        return BaiduTokenPair(access_token=f"at-new-{n}",
                              refresh_token=f"rt-new-{n + 1}", expires_in=25 * 3600)

    monkeypatch.setattr(baidu_client_module.BaiduNetdiskClient, "refresh_token", fake_refresh)

    # filemetas 腿注入:仅首次调用抛 31045(link_expired),其后透传 baidu_spy 桩
    # (fixture 已把 spy 实例的绑定方法挂到类上,透传不必再传 self)
    spy_filemetas = baidu_client_module.BaiduNetdiskClient.filemetas_batch
    filemetas_tokens: list[str] = []

    async def _first_call_31045(self: Any, access_token: str, fsids: list[int], *,
                                dlink: bool = True, **_k: Any) -> list[dict[str, Any]]:
        filemetas_tokens.append(access_token)
        if len(filemetas_tokens) == 1:
            raise BaiduApiError(CATEGORY_LINK_EXPIRED,
                                "31045(token 校验未通过,桩注入)", errno=31045)
        return await spy_filemetas(access_token, fsids, dlink=dlink, **_k)

    monkeypatch.setattr(baidu_client_module.BaiduNetdiskClient,
                        "filemetas_batch", _first_call_31045)

    task = await _mk_task(world, status="running", enum_done=True,
                          round_started_at=NOW - timedelta(minutes=1))
    fs1, fs2 = random_fsid(), random_fsid()
    baidu_spy.add(fs1, b"31045-first")
    baidu_spy.add(fs2, b"31045-second")
    row1 = await _mk_file(task, "first.mp4", size=11, fs_id=fs1)
    await _mk_file(task, "second.mp4", size=12, fs_id=fs2)

    await _dispatch_claim_run(task.id)

    assert refresh_calls == ["it-refresh-token"], \
        "恰 1 次真实 refresh_token(单飞;主会话回写缺失会让后续每个文件重踩 31045 各刷一次)"
    assert filemetas_tokens == ["it-access-token", "at-new-1", "at-new-1"], (
        "dlink 首取(现存旧 token)31045 → _handle_errno_31045 强刷后以 prefer_token"
        "新 token 重取;第二行 dlink 亦用回写后的新 token(_current_token 读到新密文)"
    )
    assert (await _get_file(row1.id)).status == "success"
    assert await _task_status(task.id) == "completed"
    assert baidu_spy.download_tokens == ["at-new-1", "at-new-1"], (
        "dlink 首取即失败,不存在「首次旧 token 下载」:重试下载与后续文件必须携带"
        "刷新后的新 token(主会话 binding 回写生效)"
    )
    async with _db() as db:
        b = await db.get(BaiduBinding, world.binding.id)
        assert b.status == "active" and decrypt_token(b.refresh_token_enc) == "rt-new-2"


# ════════════════════════════ T9:Settings 参数生效(§3.2)═════════════════════
def test_t9_settings_defaults_and_red_lines() -> None:
    """T9(离线):四参数默认 4/2/8/5;校验红线三向违例启动报错 +
    边界值(nonvip=limit-2、3/1)通过。"""
    s = make_settings()
    assert s.baidu_admission_limit == 4
    assert s.baidu_nonvip_admission_limit == 2
    assert s.worker_max_jobs == 8
    assert s.baidu_max_active_tasks_per_binding == 5
    s.validate_baidu_settings()   # 默认配置必须通过

    make_settings(baidu_admission_limit=4, baidu_nonvip_admission_limit=2).validate_baidu_settings()
    # ADMISSION=3 组合:会员并发新增红线 vip_par ≤ limit-1(默认 3 会 3≤2 假),
    # 显式带兼容值 2(该红线的专项覆盖归 R10,此处不削弱既有三向红线断言)
    make_settings(baidu_admission_limit=3, baidu_nonvip_admission_limit=1,
                  baidu_vip_parallel_per_binding=2).validate_baidu_settings()

    with pytest.raises(AssertionError):
        make_settings(baidu_nonvip_admission_limit=0).validate_baidu_settings()
    # ↑ 下限红线:nonvip=0 把非会员道清零饿死(§3.2)
    with pytest.raises(AssertionError):
        make_settings(baidu_nonvip_admission_limit=3).validate_baidu_settings()
    # ↑ 上限红线:nonvip>limit-2 清零「会员恒有 ≥2 槽」承诺(§3.2)
    with pytest.raises(AssertionError):
        make_settings(baidu_admission_limit=3,
                      baidu_nonvip_admission_limit=2).validate_baidu_settings()
    with pytest.raises(AssertionError):
        make_settings(baidu_max_active_tasks_per_binding=0).validate_baidu_settings()
    # ↑ 软上限=0 会静默砖死创建与复活、恒 409 且无启动报错(§3.2)


def test_t9_worker_max_jobs_reads_settings() -> None:
    """T9(§3.2/§3.3):WorkerSettings.max_jobs 改读 Settings.worker_max_jobs
    (默认 8 = 4 百度槽 + ≥4 缩略图/cron 槽)。"""
    assert WorkerSettings.max_jobs == get_settings().worker_max_jobs
    assert get_settings().worker_max_jobs == 8, "默认 8(隔离栈未注 env 时)"


async def test_t9_admission_limit_param_effective(
    world: World, lanes: LaneFactory, stack,
) -> None:
    """T9(§3.2):baidu_admission_limit 参数生效 —— 同一批 3 条会员代表,总限 2 只
    放 2、总限 4 全放。"""
    reps = []
    for i in range(3):
        lane = await lanes.add(vip_type=1)
        reps.append(await _mk_task(
            world, status="running", enum_done=True,
            user_id=lane.user.id, binding_id=lane.binding.id,
            round_started_at=NOW - timedelta(minutes=1),
            created_at=NOW - timedelta(minutes=10 - i),
        ))
    assert set(await _admission(limit=2, nonvip=2)) == {reps[0].id, reps[1].id}
    assert set(await _admission(limit=4, nonvip=2)) == {t.id for t in reps}, \
        "总限参数生效:4 槽全放(会员道非约束方向)"


async def test_t9_nonvip_limit_param_effective_in_sql_and_worker_gate(
    world: World, lanes: LaneFactory, monkeypatch: pytest.MonkeyPatch, baidu_spy,
    enable_baidu, stack,
) -> None:
    """T9 nonvip 生效专项(§3.2):调 1 → 准入 SQL 与 worker 认领后 gate 双侧行为
    随之变(第 2 个非会员即使总槽未满也被拒/gate 退出)。"""
    nv1_lane = await lanes.add(vip_type=0)
    nv2_lane = await lanes.add(vip_type=0)
    nv1 = await _seed_running_rep(world, nv1_lane, created_min_ago=5.0)
    nv2 = await _mk_task(world, status="enumerating", enum_done=False,
                         user_id=nv2_lane.user.id, binding_id=nv2_lane.binding.id,
                         created_at=NOW - timedelta(minutes=1))

    monkeypatch.setattr(get_settings(), "baidu_nonvip_admission_limit", 1, raising=False)
    assert await _admission(limit=4, nonvip=1) == [nv1.id], "准入 SQL 读 nonvip 参数"

    async with _db() as db:
        assert await dispatch_baidu_task(db, nv2.id, sweeper=True)
    res = await _claim_and_run(nv2.id)
    assert res["status"] == "queued", "worker gate 接线读 Settings(接线声明,§3.1)"
    t = await _get_task(nv2.id)
    assert t.status == "enumerating" and t.round_started_at is None


async def test_t9_soft_cap_param_effective_on_create(
    world: World, client, enable_baidu, mock_oauth, monkeypatch: pytest.MonkeyPatch, stack,
) -> None:
    """T9(§3.2):baidu_max_active_tasks_per_binding 调 2 → 第 3 个创建即 409。"""
    monkeypatch.setattr(get_settings(), "baidu_max_active_tasks_per_binding", 2, raising=False)
    for i in range(2):
        r = await client.post(f"{BA}/tasks", json={
            "source_dir": f"/it-t9-cap-{i}", "project_id": str(world.project.id),
            "target_folder_id": str(world.folder.id),
        }, headers=_h(world.member.id))
        assert r.status_code == 201, r.text
    r3 = await client.post(f"{BA}/tasks", json={
        "source_dir": "/it-t9-cap-2", "project_id": str(world.project.id),
        "target_folder_id": str(world.folder.id),
    }, headers=_h(world.member.id))
    assert r3.status_code == 409 and "排队任务已达上限" in r3.text


# ════════════════════════════ T10:回归(换绑循环取消多任务)═══════════════════
async def test_t10_rebind_cancels_multiple_active_tasks(
    world: World, client, enable_baidu, mock_oauth, stack,
) -> None:
    """T10 回归(§1 锚点:routers:217-249 换绑取消循环):换绑不同 uid 时
    _cancel_active_tasks_of_binding 必须覆盖同绑定**全部**活动任务(多任务排队
    语义下不再只有一条);跨绑定并发照旧/审计与聚合 task 级隔离由既有用例与
    test_baidu_integration 重写项承接。"""
    t1 = await _mk_task(world, status="enumerating", enum_done=False,
                        created_at=NOW - timedelta(minutes=2))
    t2 = await _mk_task(world, status="enumerating", enum_done=False)
    # 第三条:带活跃租约的在途任务(回落路径)—— 同绑定仅此一条 running
    # (非会员绑定准入门控恒 1 路;uq_baidu_task_running 唯一兜底已随迁移 0022
    # 删除,同绑定 running 上限由准入门控约束);租约必须取测试执行时刻的未来值
    # (模块级 NOW 全量跑时已陈旧数分钟,NOW+60s 会成过期租约被无租约快路径直
    # 终态化假红,同 test_cancel_fast_path 注释口径)
    t3 = await _mk_task(world, status="running", enum_done=True,
                        round_started_at=NOW - timedelta(minutes=1),
                        runner_id="runner-live",
                        lease_until=datetime.now(UTC) + timedelta(seconds=60),
                        lease_seq=1)
    mock_oauth["uid"] = "200"   # 换绑到不同百度账号
    r = await client.post(f"{BA}/binding", json={"code": "it-code"}, headers=_h(world.member.id))
    assert r.status_code in (200, 201), r.text
    for t in (t1, t2):
        tt = await _get_task(t.id)
        assert tt.status == "cancelled", \
            "换绑循环取消必须覆盖同绑定全部活动任务(多任务排队不回归);无租约行走 " \
            "finalize_task_terminal 直终态化快路径,该路径本就不写 cancel_reason" \
            "(既有文档化口径,见 test_cancel_fast_path 注释)"
    t3_after = await _get_task(t3.id)
    assert t3_after.status == "running", \
        "带活跃租约的任务不得被 API 直终态化(交在途 runner 于检查点消费,≤一个检查点周期)"
    assert t3_after.cancel_requested is True and t3_after.cancel_reason == "binding_replaced", \
        "回落路径必须置取消意图位(cancel_requested + reason='binding_replaced')交 runner 归位"


# ════════════════════════════ T11:分道保留(gate 接线必测)════════════════════
async def test_t11_lane_preservation_third_nonvip_excluded_vip_admitted(
    world: World, lanes: LaneFactory, baidu_spy, enable_baidu, stack,
) -> None:
    """T11(§3.1 接线声明,防 gate 接错线的必测项):2 非会员 running → 第 3 个
    非会员任务(总槽未满)不被准入、认领后 gate 退出;会员任务同时可进第 3 槽。
    若 gate 误接无分道 top-N,「全局代表 3 ≤ 4」会放行第 3 条 → 击穿不变量②。"""
    nv1_lane = await lanes.add(vip_type=0)
    nv2_lane = await lanes.add(vip_type=0)
    nv3_lane = await lanes.add(vip_type=0)
    vip_lane = await lanes.add(vip_type=1)
    nv1 = await _seed_running_rep(world, nv1_lane, created_min_ago=6.0)
    nv2 = await _seed_running_rep(world, nv2_lane, created_min_ago=5.0)
    nv3 = await _mk_task(world, status="enumerating", enum_done=False,
                         user_id=nv3_lane.user.id, binding_id=nv3_lane.binding.id,
                         created_at=NOW - timedelta(minutes=4))
    vip_task = await _mk_task(world, status="enumerating", enum_done=False,
                              user_id=vip_lane.user.id, binding_id=vip_lane.binding.id,
                              created_at=NOW - timedelta(minutes=3))

    picked = await _admission()
    assert set(picked) == {nv1.id, nv2.id, vip_task.id}, \
        "第 3 个非会员不被准入(非会员道 ≤2),会员可进第 3 槽(总槽 4 未满)"

    async with _db() as db:
        assert await dispatch_baidu_task(db, nv3.id, sweeper=True)
    res = await _claim_and_run(nv3.id)
    assert res["status"] == "queued", "gate 判定集合必须就是 picked 集合(接线声明)"
    assert (await _get_task(nv3.id)).status == "enumerating"

    async with _db() as db:
        assert await dispatch_baidu_task(db, vip_task.id, sweeper=True)
    res = await _claim_and_run(vip_task.id)
    assert res["status"] == "completed_empty", "会员任务经第 3 槽真实准入并执行(空目录完成)"


# ════════════════════════════ T12:总数上限 / 跨道置换 / 6 上界 ════════════════
async def test_t12_total_cap_four_vip_running_block_all(
    world: World, lanes: LaneFactory, stack,
) -> None:
    """T12(§3.1 性质):4 会员 running → 全池满,任何后续任务不进 picked。"""
    slots = []
    for _ in range(4):
        lane = await lanes.add(vip_type=1)
        slots.append(await _seed_running_rep(world, lane, created_min_ago=5.0))
    extra_lane = await lanes.add(vip_type=1)
    extra = await _mk_task(world, status="enumerating", enum_done=False,
                           user_id=extra_lane.user.id, binding_id=extra_lane.binding.id,
                           created_at=NOW)
    picked = await _admission()
    assert set(picked) == {t.id for t in slots}, "4 会员 running = 总限 4 满"
    assert extra.id not in picked


async def test_t12_mixed_four_full_then_cross_lane_displacement_converge_to_four(
    world: World, lanes: LaneFactory, baidu_spy, enable_baidu, stack,
) -> None:
    """T12(§3.1 性质②(b) 跨道置换窗):2 非会员 + 2 会员 = 4 满(对同道到达成立)
    → 新会员认领被准入(vip 臂可容纳),nrm_pick 余量收紧把较年轻的非会员代表挤出
    picked —— 但 gate 不驱逐已执行者(仍 running,总执行瞬时至多 limit+nonvip=6)
    → 被挤者接力复核(此处直呼重认领)经门控退出+降级回队,最终收敛回 4。"""
    nv1_lane = await lanes.add(vip_type=0)
    nv2_lane = await lanes.add(vip_type=0)
    vip1_lane = await lanes.add(vip_type=1)
    vip2_lane = await lanes.add(vip_type=1)
    vip3_lane = await lanes.add(vip_type=1)
    nv1 = await _seed_running_rep(world, nv1_lane, created_min_ago=7.0)
    nv2 = await _seed_running_rep(world, nv2_lane, created_min_ago=6.0)
    vip1 = await _seed_running_rep(world, vip1_lane, created_min_ago=5.0)
    vip2 = await _seed_running_rep(world, vip2_lane, created_min_ago=4.0)

    picked = await _admission()
    assert set(picked) == {nv1.id, nv2.id, vip1.id, vip2.id}, \
        "2 非会员 + 2 会员 = 4 满(对同道到达成立)"

    # 新会员(第 3 个 vip)认领 → 被准入(插队语义,刻意行为;空目录即完成)
    new_vip = await _mk_task(world, status="enumerating", enum_done=False,
                             user_id=vip3_lane.user.id, binding_id=vip3_lane.binding.id,
                             created_at=NOW - timedelta(minutes=1))
    async with _db() as db:
        assert await dispatch_baidu_task(db, new_vip.id, sweeper=True)
    res = await _claim_and_run(new_vip.id)
    assert res["status"] == "completed_empty", "满载时新会员认领必须被准入(跨道置换窗)"

    # 置换窗定格(§3.1 性质②(b)):new_vip 被准入的瞬间它是第 3 条 vip 代表
    # (总执行 5),其空目录即完成会让窗口即时闭合 —— 瞬态窗不可经黑盒 job 确定性
    # 观察(plan 明令勿依赖竞态构造),故按 T4/T12-hard/T15-stale 同款「DB 直 seed
    # 定格」口径把窗内形态(新 vip 仍 running)钉回来,钉死以下两个后果断言。
    await _touch_task(new_vip.id, status="running",
                      round_started_at=NOW - timedelta(seconds=30))

    picked = await _admission()
    assert new_vip.id in picked and nv1.id in picked and nv2.id not in picked, \
        "nrm_pick 余量收紧(4-3=1),较年轻的非会员代表被挤出 picked"
    assert (await _get_task(nv2.id)).status == "running", \
        "gate 只在认领时判定一次,不驱逐已执行者(瞬态总执行 5,§3.1 性质②(b))"

    # 被挤者接力复核(直呼重认领)→ 门控退出 + 降级回队 → 收敛回 4
    await _touch_task(nv2.id, dispatched_at=NOW - timedelta(minutes=11))
    async with _db() as db:
        assert await dispatch_baidu_task(db, nv2.id, sweeper=True)
    res = await _claim_and_run(nv2.id)
    assert res["status"] == "queued", "被挤出的 running 行在复核认领时门控退出"
    t = await _get_task(nv2.id)
    assert t.status == "enumerating" and t.enum_done is True, "门控退出降级 + enum_done 保留"
    assert await _running_ids() == {nv1.id, vip1.id, vip2.id, new_vip.id}, \
        "跨道置换窗收敛:总执行回到 4"


async def test_t12_hard_upper_bound_six_fifth_vip_rejected(
    world: World, lanes: LaneFactory, baidu_spy, enable_baidu, stack,
) -> None:
    """T12(§3.1 性质② 6 上界钉死):满载 6(2 非会员 + 4 会员瞬态)后第 5 个 vip
    认领必须被 gate 拒 —— 把瞬态上界从论证升级为回归项。"""
    lanes_added = []
    for vip in (0, 0, 1, 1, 1, 1):
        lanes_added.append(await lanes.add(vip_type=vip))
    fifth_vip_lane = await lanes.add(vip_type=1)
    running = []
    for i, ln in enumerate(lanes_added):
        running.append(await _mk_task(
            world, status="running", enum_done=True,
            user_id=ln.user.id, binding_id=ln.binding.id,
            round_started_at=NOW - timedelta(minutes=1),
            created_at=NOW - timedelta(minutes=10 - i),
        ))
    vips = running[2:]

    picked = await _admission()
    assert set(picked) == {t.id for t in vips}, \
        "vip 臂截前 4,nrm_pick 余量 GREATEST(4-4,0)=0:非会员全被挤出 picked(瞬态 6 态)"

    fifth_vip = await _mk_task(world, status="enumerating", enum_done=False,
                               user_id=fifth_vip_lane.user.id,
                               binding_id=fifth_vip_lane.binding.id,
                               created_at=NOW)
    async with _db() as db:
        assert await dispatch_baidu_task(db, fifth_vip.id, sweeper=True)
    res = await _claim_and_run(fifth_vip.id)
    assert res["status"] == "queued", "满载 6 后第 5 个 vip 认领必须被 gate 拒(6 上界钉死)"
    t = await _get_task(fifth_vip.id)
    assert t.status == "enumerating" and t.round_started_at is None, "gate 拒后降级回队"


# ════════════════════════════ T13:vip_type 未知语义(§3.1/D9)═════════════════
async def test_t13_unknown_vip_treated_as_nonvip(
    world: World, client, enable_baidu, mock_oauth, lanes: LaneFactory, stack,
) -> None:
    """T13:binding.vip_type NULL(含 uinfo 响应缺 vip_type → 解析 None → 落 NULL)
    均按非会员道(保守归类保护会员槽位)。"""
    # uinfo 响应缺 vip_type(mock_oauth 剧本默认无该键)→ 绑定落 NULL
    r = await client.post(f"{BA}/binding", json={"code": "it-code"}, headers=_h(world.member.id))
    assert r.status_code in (200, 201), r.text
    async with _db() as db:
        b = await db.get(BaiduBinding, world.binding.id)
        assert b.vip_type is None, "uinfo 响应缺 vip_type → 落 NULL(未知)"

    reps = []
    for i in range(3):
        ln = await lanes.add(vip_type=None)
        reps.append(await _mk_task(
            world, status="running", enum_done=True,
            user_id=ln.user.id, binding_id=ln.binding.id,
            round_started_at=NOW - timedelta(minutes=1),
            created_at=NOW - timedelta(minutes=10 - i),
        ))
    picked = await _admission()
    assert set(picked) == {reps[0].id, reps[1].id}, \
        "vip_type NULL 的绑定按非会员道:3 条 NULL 代表只放 2(nonvip_limit=2)"


# ════════════════════════════ T14:vip_type 保鲜(§3.1)════════════════════════
async def test_t14_vip_type_refresh_on_create_and_revive_best_effort(
    world: World, client, enable_baidu, mock_oauth, monkeypatch: pytest.MonkeyPatch, stack,
) -> None:
    """T14:任务创建/复活时 best-effort 调 uinfo 刷新 binding.vip_type;uinfo 失败
    静默沿用旧值且**绝不阻塞**创建/复活。"""
    # 创建保鲜:NULL → uinfo vip_type=1
    mock_oauth["vip_type"] = 1
    r = await client.post(f"{BA}/tasks", json={
        "source_dir": "/it-t14-a", "project_id": str(world.project.id),
        "target_folder_id": str(world.folder.id),
    }, headers=_h(world.member.id))
    assert r.status_code == 201, r.text
    async with _db() as db:
        assert (await db.get(BaiduBinding, world.binding.id)).vip_type == 1, \
            "创建时 uinfo 保鲜回填 vip_type(§3.1)"

    # 复活保鲜:0 → uinfo vip_type=2
    await _touch_binding(world.binding.id, vip_type=0)
    failed = await _mk_task(world, status="failed", enum_done=True,
                            fail_reason="file_failed", source_dir="/it-t14-b")
    await _mk_file(failed, "x.mp4", status="failed", attempts=1)
    mock_oauth["vip_type"] = 2
    r2 = await client.post(f"{BA}/tasks/{failed.id}/retry-failed", headers=_h(world.member.id))
    assert r2.status_code == 202, r2.text
    async with _db() as db:
        assert (await db.get(BaiduBinding, world.binding.id)).vip_type == 2, \
            "复活时同口径保鲜(§3.1:复活四路由同样触发)"

    # uinfo 失败:静默沿用旧值,创建不阻塞
    async def _uinfo_boom(self: Any, *_a: Any, **_k: Any) -> Any:
        raise BaiduApiError(CATEGORY_UNKNOWN, "uinfo down(桩注入)")

    monkeypatch.setattr(baidu_client_module.BaiduNetdiskClient, "uinfo", _uinfo_boom)
    r3 = await client.post(f"{BA}/tasks", json={
        "source_dir": "/it-t14-c", "project_id": str(world.project.id),
        "target_folder_id": str(world.folder.id),
    }, headers=_h(world.member.id))
    assert r3.status_code == 201, "uinfo 失败绝不阻塞创建(best-effort,§3.1)"
    async with _db() as db:
        assert (await db.get(BaiduBinding, world.binding.id)).vip_type == 2, \
            "uinfo 失败沿用旧值"


async def test_t14_vip_refresh_expired_token_failure_does_not_block_create_and_revive(
    world: World, client, enable_baidu, mock_oauth,
    monkeypatch: pytest.MonkeyPatch, stack,
) -> None:
    """T14 P2-2 钉子(vip 保鲜独立 session 化修复回归):binding token 过期 +
    refresh_token 端点故障 → 创建/复活的保鲜链路(含自然过期路径 token 刷新,
    3 次耗尽)在独立 session 内进行,失败回滚**不得污染 API 会话** —— 历史缺陷:
    刷新曾在 API 会话内直调,ensure_fresh 失败回滚 expire 会话内全部 ORM 实例,
    返回后读 binding.baidu_uid / task.id 触发 MissingGreenlet → 500。钉:创建
    201(不 500)、复活 202、vip_type 静默沿用旧值。"""
    await _touch_binding(world.binding.id, vip_type=0,
                         access_token_expires_at=NOW - timedelta(hours=1))
    failed = await _mk_task(world, status="failed", enum_done=True,
                            fail_reason="file_failed", source_dir="/it-t14-expired")
    await _mk_file(failed, "expired.mp4", status="failed", attempts=1)

    async def _refresh_boom(self: Any, rt: str, *_a: Any, **_k: Any) -> Any:
        raise RuntimeError("token endpoint down(桩注入)")

    monkeypatch.setattr(baidu_client_module.BaiduNetdiskClient, "refresh_token", _refresh_boom)
    monkeypatch.setattr(baidu_svc, "REFRESH_RETRY_BACKOFF_S", 0)   # 不吃真退避

    # 创建腿:vip 保鲜刷新耗尽 → best-effort 静默,绝不 500
    r = await client.post(f"{BA}/tasks", json={
        "source_dir": "/it-t14-expired", "project_id": str(world.project.id),
        "target_folder_id": str(world.folder.id),
    }, headers=_h(world.member.id))
    assert r.status_code == 201, \
        f"token 刷新失败绝不阻塞创建(独立 session 化,失败回滚不污染 API 会话)," \
        f"实际 {r.status_code}: {r.text}"
    async with _db() as db:
        b = await db.get(BaiduBinding, world.binding.id)
        assert b.vip_type == 0, "刷新失败 vip_type 静默沿用旧值(§3.1 best-effort)"
        assert decrypt_token(b.refresh_token_enc) == "it-refresh-token", \
            "失败路径不得写入半个新 token(§5.3)"

    # 复活腿:同场景 retry-failed 202(回写点在 reset_failed_rows 读 task.id 之前,
    # 验证 rollback-expire 修复后同会话后续访问不炸)。注:创建腿的自然过期刷新
    # 耗尽已按 §5.3 把 binding 置 expired(产品语义非缺陷),复活前置守卫要求
    # active,故重置后续跑复活腿、聚焦复活链自身的回归
    await _touch_binding(world.binding.id, status="active",
                         access_token_expires_at=NOW - timedelta(hours=1))
    r2 = await client.post(f"{BA}/tasks/{failed.id}/retry-failed",
                           headers=_h(world.member.id))
    assert r2.status_code == 202, \
        f"复活 vip 保鲜失败必须静默不阻塞(202 而非 500),实际 {r2.status_code}: {r2.text}"
    assert r2.json()["status"] == "enumerating", \
        "复活统一入队漏斗:恒落 enumerating(§2.5/D11)"
    async with _db() as db:
        assert (await db.get(BaiduBinding, world.binding.id)).vip_type == 0, \
            "复活腿刷新失败同口径静默沿用旧值"


async def test_t14_vip_refresh_expired_token_success_rotates_and_backfills(
    world: World, client, enable_baidu, mock_oauth,
    monkeypatch: pytest.MonkeyPatch, stack,
) -> None:
    """T14 P2-2 变体(独立 session 化成功路径,E2c 形态;T14 既有用例 token 未
    过期、不涉轮换,不重复):过期 token + 刷新成功 → 创建 201、vip_type 回填
    uinfo 剧本值、轮换双 token 经 db.refresh 回写主会话身份映射(§2.6.2 配套)。"""
    await _touch_binding(world.binding.id, vip_type=0,
                         access_token_expires_at=NOW - timedelta(hours=1))
    mock_oauth["vip_type"] = 1

    async def _refresh_ok(self: Any, rt: str, *_a: Any, **_k: Any) -> BaiduTokenPair:
        assert rt == "it-refresh-token", "刷新必须用现存 refresh_token"
        return BaiduTokenPair(access_token="at-t14-new",
                              refresh_token="rt-t14-new", expires_in=25 * 3600)

    monkeypatch.setattr(baidu_client_module.BaiduNetdiskClient, "refresh_token", _refresh_ok)

    r = await client.post(f"{BA}/tasks", json={
        "source_dir": "/it-t14-rot", "project_id": str(world.project.id),
        "target_folder_id": str(world.folder.id),
    }, headers=_h(world.member.id))
    assert r.status_code == 201, r.text
    async with _db() as db:
        b = await db.get(BaiduBinding, world.binding.id)
        assert b.vip_type == 1, "uinfo 剧本 vip_type=1 回填(§3.1 保鲜)"
        assert b.status == "active"
        assert decrypt_token(b.refresh_token_enc) == "rt-t14-new", \
            "自然过期路径刷新后轮换 refresh_token 落库(§5.3)"
        assert b.access_token_expires_at > NOW, "过期时间原子覆盖"


# ════════════════════════════ T15:排序与残留行门控(§3.1)═════════════════════
async def test_t15_lane_fifo_ordering(world: World, lanes: LaneFactory, stack) -> None:
    """T15(§3.1 性质):道内 FIFO —— 同道代表按代表序(round NULLS LAST,
    created_at, id)进出 picked。"""
    reps = []
    for i in range(3):
        lane = await lanes.add(vip_type=1)
        reps.append(await _mk_task(
            world, status="enumerating", enum_done=False,
            user_id=lane.user.id, binding_id=lane.binding.id,
            created_at=NOW - timedelta(minutes=30 - 10 * i),
        ))
    picked = await _admission()
    assert picked == [reps[0].id, reps[1].id, reps[2].id], \
        "道内 FIFO: picked 依 (round NULLS LAST, created_at, id) 稳定有序"


async def test_t15_slow_lane_full_vip_jumps_queue_head(
    world: World, lanes: LaneFactory, stack,
) -> None:
    """T15(§3.1 性质,刻意行为):慢道满时会员跨道插队 —— 更早的非会员队头被跳过
    (队头阻塞根治;代价是跨道不再全局 FIFO,UI 无感知)。"""
    nv_head_lane = await lanes.add(vip_type=0)
    nv1_lane = await lanes.add(vip_type=0)
    nv2_lane = await lanes.add(vip_type=0)
    vip_lane = await lanes.add(vip_type=1)
    nv_head = await _mk_task(world, status="enumerating", enum_done=False,
                             user_id=nv_head_lane.user.id, binding_id=nv_head_lane.binding.id,
                             created_at=NOW - timedelta(minutes=30))
    nv1 = await _seed_running_rep(world, nv1_lane, created_min_ago=6.0)
    nv2 = await _seed_running_rep(world, nv2_lane, created_min_ago=5.0)
    vip_task = await _mk_task(world, status="enumerating", enum_done=False,
                              user_id=vip_lane.user.id, binding_id=vip_lane.binding.id,
                              created_at=NOW - timedelta(minutes=1))
    picked = await _admission()
    assert vip_task.id in picked and nv_head.id not in picked, \
        "非会员道满(2 running),更早的队头 dormant 被跳过、会员插入(§3.1)"
    assert set(picked) == {nv1.id, nv2.id, vip_task.id}


async def test_t15_stale_overlimit_active_rows_gate_exit_no_real_overrun(
    world: World, lanes: LaneFactory, baidu_spy, enable_baidu, stack,
) -> None:
    """T15(§3.1 性质③ + 残留行门控):DB 直 seed 超限残留活动行(模拟崩溃/
    历史脏数据)→ 新认领者门控退出,不产生真实并发超限(执行集保持 4)。"""
    nv1_lane = await lanes.add(vip_type=0)
    nv2_lane = await lanes.add(vip_type=0)
    stale_lane = await lanes.add(vip_type=0)
    vip1_lane = await lanes.add(vip_type=1)
    vip2_lane = await lanes.add(vip_type=1)
    nv1 = await _seed_running_rep(world, nv1_lane, created_min_ago=8.0)
    nv2 = await _seed_running_rep(world, nv2_lane, created_min_ago=7.0)
    vip1 = await _seed_running_rep(world, vip1_lane, created_min_ago=6.0)
    vip2 = await _seed_running_rep(world, vip2_lane, created_min_ago=5.0)
    # 残留行:status='running' 且 round NULL(崩溃/历史脏数据形态;同绑定唯一活动)
    stale = await _mk_task(world, status="running", enum_done=True,
                           user_id=stale_lane.user.id, binding_id=stale_lane.binding.id,
                           round_started_at=None, runner_id=None, lease_until=None,
                           created_at=NOW - timedelta(minutes=1))

    picked = await _admission()
    assert set(picked) == {nv1.id, nv2.id, vip1.id, vip2.id}, \
        "超限残留行不在 picked(非会员道已满),执行集保持 4"

    await _touch_task(stale.id, dispatched_at=NOW - timedelta(minutes=11))
    async with _db() as db:
        assert await dispatch_baidu_task(db, stale.id, sweeper=True)
    res = await _claim_and_run(stale.id)
    assert res["status"] == "queued", "残留行认领后门控退出"
    t = await _get_task(stale.id)
    assert t.status == "enumerating" and t.round_started_at is None, "降级回队"
    assert await _running_ids() == {nv1.id, nv2.id, vip1.id, vip2.id}, \
        "不产生真实并发超限(§3.1 性质③:status 级超限行由 gate 收容)"


# ════════════════════════════ T16:复活入队漏斗(§2.5/D11)═════════════════════
async def test_t16_revive_funnel_zero_list_and_target_folder_precheck(
    world: World, client, enable_baidu, mock_oauth, baidu_spy, stack,
) -> None:
    """T16(§2.5 复活统一入队漏斗):同绑定 A running 时对 enum_done=true 失败任务
    B 走 retry-failed → 202(非 409/500)、B 落 enumerating 排队;A 终态后 B 被认领
    零 list 调用(跳过重枚举)经收尾 UPDATE 置 running 进导入循环。子用例:B/C
    排队期间目标夹被删 —— auto_created 走预检重建承接夹写回;显式删 → 任务级
    enum_failed,不得漂移为逐行 target_deleted。"""
    # A:running(enum_done=true,manifest 已备,认领后直接进导入循环)
    task_a = await _mk_task(world, status="running", enum_done=True,
                            round_started_at=NOW - timedelta(minutes=1),
                            created_at=NOW - timedelta(minutes=10))
    fs_a = random_fsid()
    baidu_spy.add(fs_a, b"funnel-a")
    row_a = await _mk_file(task_a, "a.mp4", size=8, fs_id=fs_a)

    # B:enum_done=true 失败任务(有可重试行)
    task_b = await _mk_task(world, status="failed", enum_done=True,
                            fail_reason="file_failed", created_at=NOW - timedelta(minutes=9),
                            source_dir="/it-funnel-b")
    fs_b = random_fsid()
    baidu_spy.add(fs_b, b"funnel-b")
    row_b = await _mk_file(task_b, "b.mp4", status="failed", attempts=1,
                           size=8, fs_id=fs_b)

    r = await client.post(f"{BA}/tasks/{task_b.id}/retry-failed", headers=_h(world.member.id))
    assert r.status_code == 202, f"A running 时 B 复活必须 202(非 409/500): {r.text}"
    assert r.json()["status"] == "enumerating"
    b_after = await _get_task(task_b.id)
    assert b_after.status == "enumerating" and b_after.enum_done is True, \
        "B 落 enumerating 排队(enum_done 保留,运行由准入门控约束;uq_baidu_task_running 已删)"

    # C_auto / C_exp:排队期间目标夹被删的两个子用例(先入队、后删夹)
    task_c_auto = await _mk_task(world, status="failed", enum_done=True,
                                 fail_reason="file_failed",
                                 created_at=NOW - timedelta(minutes=8),
                                 source_dir="/it-funnel-c-auto",
                                 target_auto_created=True)
    fs_ca = random_fsid()
    baidu_spy.add(fs_ca, b"funnel-ca")
    row_ca = await _mk_file(task_c_auto, "ca.mp4", status="failed", attempts=1,
                            size=9, fs_id=fs_ca)
    r2 = await client.post(f"{BA}/tasks/{task_c_auto.id}/retry-failed",
                           headers=_h(world.member.id))
    assert r2.status_code == 202
    await _touch_task(task_c_auto.id, target_folder_id=None)   # FK SET NULL 模拟排队期被删

    task_c_exp = await _mk_task(world, status="failed", enum_done=True,
                                fail_reason="file_failed",
                                created_at=NOW - timedelta(minutes=7),
                                source_dir="/it-funnel-c-exp",
                                target_auto_created=False)
    row_ce = await _mk_file(task_c_exp, "ce.mp4", status="failed", attempts=1, size=8)
    r3 = await client.post(f"{BA}/tasks/{task_c_exp.id}/retry-failed",
                           headers=_h(world.member.id))
    assert r3.status_code == 202
    await _touch_task(task_c_exp.id, target_folder_id=None)

    # A 完成(认领 → 导入循环;running 任务不枚举)
    await _dispatch_claim_run(task_a.id)
    assert await _task_status(task_a.id) == "completed"
    assert (await _get_file(row_a.id)).status == "success"

    # B 被认领(创建序最早的活动代表)→ 零 list 短路 → 收尾 UPDATE → 导入完成
    res = await _claim_and_run(task_b.id)
    assert res["status"] == "completed"
    assert (await _get_file(row_b.id)).status == "success"

    # C_auto:预检重建承接夹写回 → 照常导入完成
    res = await _claim_and_run(task_c_auto.id)
    assert res["status"] == "completed", "auto_created:预检重建承接夹,任务照常完成"
    async with _db() as db:
        rebuilt = (await db.execute(select(Folder).where(
            Folder.project_id == world.project.id,
            Folder.minio_prefix == "it-funnel-c-auto/"))).scalars().all()
    assert len(rebuilt) == 1, "承接夹按 source_dir 末段重建(与 _enumerate 前置同款)"
    t_ca = await _get_task(task_c_auto.id)
    assert t_ca.target_folder_id == rebuilt[0].id, "新夹 id 写回 target_folder_id"
    assert (await _get_file(row_ca.id)).status == "success"

    # C_exp:预检 → 任务级失败,不得漂移为逐行 target_deleted
    res = await _claim_and_run(task_c_exp.id)
    assert res["status"] == "failed:enum_failed", "显式目标删 → 任务级 enum_failed(§2.5.2)"
    t_ce = await _get_task(task_c_exp.id)
    assert t_ce.status == "failed" and t_ce.fail_reason == "enum_failed"
    ce_row = await _get_file(row_ce.id)
    assert ce_row.status == "pending" and ce_row.last_error is None, \
        "失败口径不得漂移为逐行 target_deleted(pending 行原样保留,§6 归位表)"

    # 全程零 list:B/C 均经 enum_done 短路,A 原本就在导入循环
    assert baidu_spy.list_calls == 0, "复活入队漏斗:重派全程零 list API 调用(§2.5.2)"


# ════════════════════════════ T17:sweeper 代表去重(§2.3/D12)═════════════════
async def test_t17_sweeper_representative_dedup_crash_beats_dormant_reverse(
    world: World, lanes: LaneFactory, enable_baidu, stack,
) -> None:
    """T17(反序用例):同绑定「2 休眠(dormant)创建在前 + 1 崩溃 running 创建在
    最晚」→ 每拍仅派每绑定代表,且崩溃行(round 非空)按代表序压过更早创建的休眠
    行被优先接管;非代表行顺延一拍。"""
    lane = await lanes.add(vip_type=None)
    d1 = await _mk_task(world, status="enumerating", enum_done=False,
                        user_id=lane.user.id, binding_id=lane.binding.id,
                        created_at=NOW - timedelta(minutes=30))
    d2 = await _mk_task(world, status="enumerating", enum_done=False,
                        user_id=lane.user.id, binding_id=lane.binding.id,
                        created_at=NOW - timedelta(minutes=20))
    crash = await _mk_task(world, status="running", enum_done=True,
                           user_id=lane.user.id, binding_id=lane.binding.id,
                           round_started_at=NOW - timedelta(minutes=5),
                           created_at=NOW - timedelta(minutes=10))

    stats = await _sweep_now()
    assert stats["dispatched"] == 1, "每绑定每拍恰派代表 1 条(§2.3 收益①)"
    c_after = await _get_task(crash.id)
    assert c_after.lease_seq == 1, "崩溃行(round 非空)按代表序被优先接管"
    assert await _job_queued(crash.id, 1)
    assert (await _get_task(d1.id)).lease_seq == 0 and (await _get_task(d2.id)).lease_seq == 0, \
        "非代表休眠行不被派发(顺延一拍,语义无损)"


async def test_t17_sweep_batch_boundary_crash_row_latest_created_still_taken(
    world: World, lanes: LaneFactory, enable_baidu, stack,
) -> None:
    """T17(批量边界):>SWEEP_BATCH(50) 条候选且崩溃行创建最晚 → 批量查询换序
    (round NULLS LAST 前)后崩溃行仍被带回头部、接管不被挤掉;多绑定互不挤占
    SWEEP_BATCH(两绑定代表同拍各派 1)。旧排序(created_at 截批)下崩溃行排第
    52 位必被截掉、接管被休眠行无限推迟 —— 本用例即防回归。"""
    other = await lanes.add(vip_type=None)
    crash = await _mk_task(world, status="running", enum_done=True,
                           round_started_at=NOW - timedelta(minutes=2),
                           created_at=NOW)   # 创建最晚(旧排序必被截掉)
    for _ in range(51):   # 51 条休眠候选(>SWEEP_BATCH)全部创建在崩溃行之前
        await _mk_task(world, status="enumerating", enum_done=False,
                       user_id=other.user.id, binding_id=other.binding.id,
                       created_at=NOW - timedelta(minutes=30))

    stats = await _sweep_now()
    assert stats["candidates"] == 50, "批量上限 50 生效;换序后崩溃行在批内头部"
    crash_after = await _get_task(crash.id)
    assert crash_after.lease_seq == 1, \
        "创建最晚的崩溃 running 行仍被接管(换序生效;旧排序此处必红)"
    assert await _job_queued(crash.id, 1)
    assert stats["dispatched"] == 2, "多绑定互不挤占:两绑定代表同拍各派 1(去重后)"


async def test_t17_cancel_branch_not_deduped_non_representative_finalized(
    world: World, lanes: LaneFactory, enable_baidu, stack,
) -> None:
    """T17 子断言(D12):去重只加派发分支 —— seed 非代表休眠行 + 置
    cancel_requested → 下拍被 sweeper cancel 支直接终态化(不被去重搁置;
    否则用户会看到「点了取消却一直排队」)。"""
    lane = await lanes.add(vip_type=None)
    rep = await _mk_task(world, status="enumerating", enum_done=False,
                         user_id=lane.user.id, binding_id=lane.binding.id,
                         created_at=NOW - timedelta(minutes=10))
    non_rep = await _mk_task(world, status="enumerating", enum_done=False,
                             user_id=lane.user.id, binding_id=lane.binding.id,
                             created_at=NOW - timedelta(minutes=5),
                             cancel_requested=True, cancel_reason="user_cancel")

    stats = await _sweep_now()
    assert stats["cancelled"] >= 1, "cancel 支不参与去重:非代表行下拍即被终态化"
    nr = await _get_task(non_rep.id)
    assert nr.status == "cancelled" and nr.cancel_reason == "user_cancel"
    rp = await _get_task(rep.id)
    assert rp.status == "enumerating" and rp.lease_seq == 1, \
        "同拍代表照常派发(两支互不干扰)"


# ════════════════════════════ T18:迁移兼容冒烟(§2.2/§5.4)════════════════════
def _pg_index_predicate(indexdef: str) -> str:
    """pg indexdef 的 WHERE 谓词规范化:剥类型修饰(::text / ::character varying /
    ::text[] 等)与空白/括号,得到跨 pg 呈现形态稳定的比较式(如 status='running')。

    pg 对表达式部分索引谓词的呈现带版本相关的 cast/括号噪音,例如
    `WHERE ((status)::text = 'running'::text)`、`WHERE ((status)::text = ANY
    ((ARRAY['enumerating'::character varying, ...])::text[]))` —— 子串匹配
    `status = 'running'` 会假红,故断言一律走本规范化口径。"""
    pred = indexdef.split(" WHERE ", 1)[1] if " WHERE " in indexdef else ""
    pred = re.sub(r"::[a-zA-Z_ ]+(?:\[\])?", "", pred)   # ::text / ::character varying / ::text[]
    return re.sub(r"[\s()]+", "", pred)


def _alembic_upgrade_head() -> None:
    from alembic import command
    from alembic.config import Config

    cfg = Config(str(API_DIR / "alembic.ini"))
    cfg.set_main_option("script_location", str(API_DIR / "app" / "db" / "migrations"))
    command.upgrade(cfg, "head")


async def test_t18_migration_smoke_legacy_rows_untouched(
    world: World, lanes: LaneFactory, stack,
) -> None:
    """T18:对存量形态,`alembic upgrade head` 重入幂等且不动数据;DB 内索引/列
    形态与会员 3 路并发契约一致(uq_baidu_task_running 已随迁移 0022 删除;
    模型元数据口径归 T7/R12;downgrade 重建唯一索引的失败路径不自动化,按 §3.2
    runbook 人工把关)。"""
    lane = await lanes.add(vip_type=None)
    legacy_running = await _mk_task(world, status="running", enum_done=True,
                                    round_started_at=NOW - timedelta(minutes=1))
    legacy_enum = await _mk_task(world, status="enumerating", enum_done=False,
                                 user_id=lane.user.id, binding_id=lane.binding.id)

    def _snapshot() -> list[tuple[Any, ...]]:
        return [(t.id, t.status, t.enum_done, t.round_started_at, t.lease_seq)
                for t in (legacy_running, legacy_enum)]

    before = _snapshot()
    await asyncio.to_thread(_alembic_upgrade_head)   # 已在 head → no-op 幂等
    assert _snapshot() == before, "upgrade 重入不动存量数据(§2.2:无数据迁移)"

    async with _db() as db:
        idx_rows = (await db.execute(text(
            "SELECT indexname, indexdef FROM pg_indexes "
            "WHERE tablename = 'baidu_backup_tasks'",
        ))).all()
        col_rows = (await db.execute(text(
            "SELECT data_type, is_nullable FROM information_schema.columns "
            "WHERE table_name = 'baidu_bindings' AND column_name = 'vip_type'",
        ))).all()
    by_name = {name: definition for name, definition in idx_rows}
    assert "uq_baidu_task_active" not in by_name, "旧全活动唯一索引已删(§2.2 第 1 条)"
    assert "uq_baidu_task_running" not in by_name, \
        "running-only 唯一兜底已随迁移 0022 删除(会员同绑定 3 路并发,§3.2;" \
        "同绑定 running 上限唯一防线 = 参数化准入门控)"
    active_binding_def = by_name.get("idx_baidu_task_active_binding", "")
    active_binding_pred = _pg_index_predicate(active_binding_def)
    assert "idx_baidu_task_active_binding" in by_name \
        and "UNIQUE" not in active_binding_def \
        and "status=ANY" in active_binding_pred \
        and "'enumerating'" in active_binding_pred and "'running'" in active_binding_pred, \
        "准入查询非唯一 partial 索引在 DB 内真实存在(§2.2 第 3 条;谓词按规范化口径断言)"
    assert col_rows and col_rows[0][0] == "smallint" and col_rows[0][1] == "YES", \
        "vip_type smallint NULL 列在 DB 内真实存在(§2.2 第 4 条)"


# ══════ 会员同绑定 3 路并发 R1-R13(设计正本 §5 矩阵;R11 见前/R12 见 schema)══════
async def test_r1_vip_binding_five_tasks_picked_oldest_three(
    world: World, lanes: LaneFactory, stack,
) -> None:
    """R1(I4 边界):会员绑定 5 个活动任务 → picked 恰含该绑定最老 3 个
    (rn 序 = round NULLS LAST, created_at, id;本组全 round NULL → 纯创建序),
    其余 2 个不在 picked —— 同绑定并行路数上限 vip_par=3。"""
    lane = await lanes.add(vip_type=1)
    tasks = []
    for i in range(5):
        tasks.append(await _mk_task(
            world, status="enumerating", enum_done=False,
            user_id=lane.user.id, binding_id=lane.binding.id,
            created_at=NOW - timedelta(minutes=50 - 10 * i),
        ))

    picked = await _admission()
    assert len(picked) == 3, f"I4:会员绑定至多 vip_par=3 个代表,实际 {len(picked)}"
    assert picked == [tasks[0].id, tasks[1].id, tasks[2].id], \
        "picked 恰为该绑定最老 3 个(rn 序),更年轻的 2 个不在 picked"


async def test_r2_two_vip_bindings_three_plus_one_total_four(
    world: World, lanes: LaneFactory, stack,
) -> None:
    """R2(I1/I4):会员绑定 3 rep + 另一会员绑定 1 任务 → 总 picked=4(恰满槽),
    两绑定都入选、按代表序终排。"""
    lane_a = await lanes.add(vip_type=1)
    lane_b = await lanes.add(vip_type=1)
    a = []
    for i in range(3):
        a.append(await _mk_task(
            world, status="enumerating", enum_done=False,
            user_id=lane_a.user.id, binding_id=lane_a.binding.id,
            created_at=NOW - timedelta(minutes=30 - 10 * i),
        ))
    b = await _mk_task(world, status="enumerating", enum_done=False,
                       user_id=lane_b.user.id, binding_id=lane_b.binding.id,
                       created_at=NOW - timedelta(minutes=5))

    picked = await _admission()
    assert len(picked) == 4, "I1:总 picked ≤ limit=4(3+1 恰满)"
    assert picked == [a[0].id, a[1].id, a[2].id, b.id], \
        "两会员绑定都入选(本绑定 3 + 他绑定 1),picked 按代表序终排"


async def test_r3_vip_three_reps_nonvip_two_bindings_tightened_to_one(
    world: World, lanes: LaneFactory, stack,
) -> None:
    """R3(二次收紧 + I2/I5):会员绑定 3 rep + 非会员 2 绑定各 1 → vip_count=3
    把非会员道二次收紧到 GREATEST(4-3,0)=1,总 picked=4;仅最老的非会员代表
    入选(同 T12-mixed 口径);非会员道配额本身仍 ≤ nonvip_limit=2(I2),
    会员恒有 ≥2 槽可用(I5)语义保持。"""
    vip_lane = await lanes.add(vip_type=1)
    nv1_lane = await lanes.add(vip_type=0)
    nv2_lane = await lanes.add(vip_type=0)
    vip = []
    for i in range(3):
        vip.append(await _mk_task(
            world, status="enumerating", enum_done=False,
            user_id=vip_lane.user.id, binding_id=vip_lane.binding.id,
            created_at=NOW - timedelta(minutes=40 - 10 * i),
        ))
    nv1 = await _mk_task(world, status="enumerating", enum_done=False,
                         user_id=nv1_lane.user.id, binding_id=nv1_lane.binding.id,
                         created_at=NOW - timedelta(minutes=10))
    nv2 = await _mk_task(world, status="enumerating", enum_done=False,
                         user_id=nv2_lane.user.id, binding_id=nv2_lane.binding.id,
                         created_at=NOW - timedelta(minutes=5))

    picked = await _admission()
    assert len(picked) == 4, "总 picked 恰 4(I1)"
    assert {t.id for t in vip} <= set(picked), "会员绑定 3 rep 全部入选"
    assert set(picked) - {t.id for t in vip} == {nv1.id}, \
        "非会员道收紧到 1:两绑定代表仅最老者入选(非会员 ≤ nonvip_limit,I2;" \
        "会员占 3 槽后非会员仍有 1 槽,I5)"
    assert nv2.id not in picked, "较年轻的非会员代表被二次收紧挤出 picked"


async def test_r4_nonvip_binding_five_tasks_picked_oldest_one(
    world: World, lanes: LaneFactory, stack,
) -> None:
    """R4(I3 原语义回归):非会员绑定 5 个活动任务 → picked 恰含 1 个最老代表
    (rn ≤ 1 硬编码,非会员并行度恒 1,与改造前逐位等价)。"""
    lane = await lanes.add(vip_type=None)   # NULL = 未知按非会员道(保守归类)
    tasks = []
    for i in range(5):
        tasks.append(await _mk_task(
            world, status="enumerating", enum_done=False,
            user_id=lane.user.id, binding_id=lane.binding.id,
            created_at=NOW - timedelta(minutes=50 - 10 * i),
        ))

    picked = await _admission()
    assert picked == [tasks[0].id], \
        "非会员绑定恰 1 个最老代表(原语义回归,I3:每绑定 ≤1)"


async def test_r5_vip_par_one_aligns_with_distinct_on_legacy_semantics(
    world: World, lanes: LaneFactory, stack,
) -> None:
    """R5(vip_par=1 回归网):与 DISTINCT ON 旧实现输出逐一对齐 —— 测试内以
    纯 Python 等价计算作参照(每绑定最老代表 = DISTINCT ON;vip 道截前 limit、
    非会员道截前 nonvip_limit 再 GREATEST(limit-vip_count,0) 收紧;并集按代表序
    终排),多绑定多任务矩阵两轮抽样比对。env=1 回滚杆语义 = 完全恢复现状。"""
    def _rep_key(t: BaiduBackupTask) -> tuple[Any, ...]:
        # 代表序:round_started_at nulls_last(升序 NULL 恒最后), created_at, id
        return (t.round_started_at is None,
                t.round_started_at or NOW + timedelta(days=365),
                t.created_at, t.id)

    def _legacy_picked(groups: list[tuple[bool, list[BaiduBackupTask]]]) -> list[uuid.UUID]:
        """旧实现(DISTINCT ON 每绑定 1 代表)参照:纯 Python 等价计算。"""
        reps = [min(ts, key=_rep_key) for _, ts in groups]
        vip = sorted((r for (is_vip, _), r in zip(groups, reps, strict=True) if is_vip),
                     key=_rep_key)[:4]
        nv = sorted((r for (is_vip, _), r in zip(groups, reps, strict=True) if not is_vip),
                    key=_rep_key)[:2]
        picked = vip + nv[:max(4 - len(vip), 0)]
        return [t.id for t in sorted(picked, key=_rep_key)]

    # 矩阵一轮:2 会员绑定(3+1 任务)+ 3 非会员绑定(3+2+1 任务)→ vip_count=2,
    # 非会员收紧到 2;期望 = 两会员最老代表 + 两非会员最老代表(共 4)
    v1, v2 = await lanes.add(vip_type=1), await lanes.add(vip_type=1)
    n1, n2, n3 = (await lanes.add(vip_type=0), await lanes.add(vip_type=0),
                  await lanes.add(vip_type=0))
    groups_r1: list[tuple[bool, list[BaiduBackupTask]]] = []
    for is_vip, lane, counts, base in (
        (True, v1, 3, 40), (True, v2, 1, 30),
        (False, n1, 3, 25), (False, n2, 2, 20), (False, n3, 1, 10),
    ):
        ts = [await _mk_task(
            world, status="enumerating", enum_done=False,
            user_id=lane.user.id, binding_id=lane.binding.id,
            created_at=NOW - timedelta(minutes=base - j),
        ) for j in range(counts)]
        groups_r1.append((is_vip, ts))

    assert await _admission(vip_par=1) == _legacy_picked(groups_r1), \
        "vip_par=1 与 DISTINCT ON 旧实现逐一对齐(矩阵一轮)"

    # 清场一轮(终态化,不参与下一矩阵),二轮补「round 非空代表恒压前」与
    # vip 臂截 limit、GREATEST=0 两个方向
    for _, ts in groups_r1:
        for t in ts:
            await _touch_task(t.id, status="completed")

    v3, v4, v5 = (await lanes.add(vip_type=1), await lanes.add(vip_type=1),
                  await lanes.add(vip_type=1))
    n4, n5 = await lanes.add(vip_type=0), await lanes.add(vip_type=0)
    running_v3 = await _mk_task(
        world, status="running", enum_done=True,
        user_id=v3.user.id, binding_id=v3.binding.id,
        round_started_at=NOW - timedelta(minutes=1),
        created_at=NOW - timedelta(minutes=8),
    )
    v3_dormant = await _mk_task(
        world, status="enumerating", enum_done=False,
        user_id=v3.user.id, binding_id=v3.binding.id,
        created_at=NOW - timedelta(minutes=7),
    )
    v4_t = await _mk_task(world, status="enumerating", enum_done=False,
                          user_id=v4.user.id, binding_id=v4.binding.id,
                          created_at=NOW - timedelta(minutes=6))
    v5_t = await _mk_task(world, status="enumerating", enum_done=False,
                          user_id=v5.user.id, binding_id=v5.binding.id,
                          created_at=NOW - timedelta(minutes=5))
    n4_ts = [await _mk_task(world, status="enumerating", enum_done=False,
                            user_id=n4.user.id, binding_id=n4.binding.id,
                            created_at=NOW - timedelta(minutes=4 - j))
             for j in range(2)]
    n5_t = await _mk_task(world, status="enumerating", enum_done=False,
                          user_id=n5.user.id, binding_id=n5.binding.id,
                          created_at=NOW - timedelta(minutes=2))

    groups_r2: list[tuple[bool, list[BaiduBackupTask]]] = [
        (True, [running_v3, v3_dormant]), (True, [v4_t]), (True, [v5_t]),
        (False, n4_ts), (False, [n5_t]),
    ]
    assert await _admission(vip_par=1) == _legacy_picked(groups_r2), \
        "vip_par=1 与 DISTINCT ON 旧实现逐一对齐(矩阵二轮:round 非空代表 + " \
        "vip 臂 3 < limit + GREATEST(4-3,0)=1)"


async def test_r6_same_binding_four_vip_reps_plus_second_vip_binding(
    world: World, lanes: LaneFactory, stack,
) -> None:
    """R6(I4+I1 边界):同绑定 4 个会员任务 + 第二会员绑定 1 任务 → 本绑定恰取
    最老 3 个(rn ≤ vip_par 截断第 4 个)+ 他绑定 1 个,总 picked=4。"""
    lane_a = await lanes.add(vip_type=1)
    lane_b = await lanes.add(vip_type=1)
    a = []
    for i in range(4):
        a.append(await _mk_task(
            world, status="enumerating", enum_done=False,
            user_id=lane_a.user.id, binding_id=lane_a.binding.id,
            created_at=NOW - timedelta(minutes=40 - 10 * i),
        ))
    b = await _mk_task(world, status="enumerating", enum_done=False,
                       user_id=lane_b.user.id, binding_id=lane_b.binding.id,
                       created_at=NOW - timedelta(minutes=5))

    picked = await _admission()
    assert len(picked) == 4, "I1:总 picked ≤ 4(本绑定 3 + 他绑定 1)"
    assert picked == [a[0].id, a[1].id, a[2].id, b.id], \
        "本绑定恰最老 3(rn ≤ vip_par 截断第 4 个)+ 他绑定 1"
    assert a[3].id not in picked, "第 4 个同绑定任务不在 picked(I4 上界)"


async def test_r7_nonvip_multiple_bindings_still_capped_at_two(
    world: World, lanes: LaneFactory, stack,
) -> None:
    """R7(I2 既有不变量回归):非会员多绑定(≥3 个)各有任务 → picked 仍 ≤ 2
    (道内上限不动,取最老两绑定代表),vip_par 改造不放大非会员道。"""
    lanes_nv = [await lanes.add(vip_type=0) for _ in range(3)]
    reps = []
    for i, ln in enumerate(lanes_nv):
        for j in range(2):   # 每绑定 2 任务:非会员道 rn ≤ 1 只取最老代表
            t = await _mk_task(
                world, status="enumerating", enum_done=False,
                user_id=ln.user.id, binding_id=ln.binding.id,
                created_at=NOW - timedelta(minutes=30 - 10 * i - j),
            )
            if j == 0:
                reps.append(t)   # 各绑定最老代表(创建序递减 → 前 2 个入选)

    picked = await _admission()
    assert len(picked) == 2, f"I2:非会员道 ≤ nonvip_limit=2,实际 {len(picked)}"
    assert set(picked) == {reps[0].id, reps[1].id}, \
        "恰取最老两绑定代表;第 3 绑定代表顺延(I2 收紧后按代表序截流)"


async def test_r8_sweeper_dispatch_budget_vip_three_nonvip_one(
    world: World, lanes: LaneFactory, enable_baidu, stack,
) -> None:
    """R8(设计正本 §3.4):sweeper 派发预算参数化 —— 会员绑定每拍预算
    = vip_par(3)、非会员绑定每拍 = 1(seen_bindings 去重改预算 Counter);
    预算耗尽的非代表行照旧顺延一拍(语义无损)。"""
    # 会员道:5 候选 → 恰派 3(代表序最老 3),其余 2 条顺延
    vip_lane = await lanes.add(vip_type=1)
    vip_tasks = []
    for i in range(5):
        vip_tasks.append(await _mk_task(
            world, status="enumerating", enum_done=False,
            user_id=vip_lane.user.id, binding_id=vip_lane.binding.id,
            created_at=NOW - timedelta(minutes=50 - 10 * i),
        ))
    stats = await _sweep_now()
    assert stats["candidates"] == 5
    assert stats["dispatched"] == 3, f"会员绑定预算 vip_par=3:每拍恰派 3 条,实际 {stats}"
    for i, t in enumerate(vip_tasks):
        if i < 3:
            assert (await _get_task(t.id)).lease_seq == 1, "派发行 seq+1"
            assert await _job_queued(t.id, 1), "派发行必须真实入队"
        else:
            assert (await _get_task(t.id)).lease_seq == 0, \
                "预算耗尽:第 4/5 候选顺延一拍(语义无损,§3.4)"
            assert not await _job_queued(t.id, 1), "顺延行不入队"

    # 终态化会员行(离开候选池),再验非会员道
    for t in vip_tasks:
        await _touch_task(t.id, status="completed")

    # 非会员道:3 候选 → 恰派 1(原语义逐位等价,预算=1)
    nv_lane = await lanes.add(vip_type=0)
    nv_tasks = []
    for i in range(3):
        nv_tasks.append(await _mk_task(
            world, status="enumerating", enum_done=False,
            user_id=nv_lane.user.id, binding_id=nv_lane.binding.id,
            created_at=NOW - timedelta(minutes=30 - 10 * i),
        ))
    stats = await _sweep_now()
    assert stats["candidates"] == 3
    assert stats["dispatched"] == 1, f"非会员绑定预算恒 1:每拍恰派 1 条,实际 {stats}"
    assert (await _get_task(nv_tasks[0].id)).lease_seq == 1, "最老代表被派发"
    assert await _job_queued(nv_tasks[0].id, 1)
    for t in nv_tasks[1:]:
        assert (await _get_task(t.id)).lease_seq == 0, \
            "非会员预算耗尽:非代表行顺延一拍(T17 每绑定每拍 ≤1 原语义)"


async def test_r9_budget_exhausted_cancel_requested_row_still_finalized(
    world: World, lanes: LaneFactory, enable_baidu, stack,
) -> None:
    """R9(设计正本 §3.4 终态化支不受预算压制):会员绑定 4 条普通候选恰派 3
    (预算耗尽,第 4 条顺延),同拍第 5 条带 cancel_requested 的候选仍被 cancel
    支立即终态化 —— 取消位行不占预算、不参与去重(T17-cancel 语义在预算化后
    保持,「点了取消却一直排队」不回归)。"""
    lane = await lanes.add(vip_type=1)
    fillers = []
    for i in range(4):
        fillers.append(await _mk_task(
            world, status="enumerating", enum_done=False,
            user_id=lane.user.id, binding_id=lane.binding.id,
            created_at=NOW - timedelta(minutes=50 - 10 * i),
        ))
    cancel_row = await _mk_task(
        world, status="enumerating", enum_done=False,
        user_id=lane.user.id, binding_id=lane.binding.id,
        created_at=NOW - timedelta(minutes=1),
        cancel_requested=True, cancel_reason="user_cancel",
    )

    stats = await _sweep_now()
    assert stats["candidates"] == 5
    assert stats["dispatched"] == 3, f"预算恰 3:最老 3 条派发,实际 {stats}"
    assert stats["cancelled"] >= 1, "cancel 支不受预算压制:取消位行同拍立即终态化"
    c = await _get_task(cancel_row.id)
    assert c.status == "cancelled" and c.cancel_reason == "user_cancel"
    assert c.lease_seq == 0, "取消位行直接终态化、不被派发(不入队)"
    assert (await _get_task(fillers[0].id)).lease_seq == 1, "普通候选按预算照常派发"
    assert (await _get_task(fillers[3].id)).lease_seq == 0, \
        "第 4 条普通候选因预算耗尽顺延(取消支不影响派发支预算)"


def test_r10_settings_vip_parallel_red_lines() -> None:
    """R10(设计正本 §3.1):baidu_vip_parallel_per_binding 校验红线 —— 默认 3;
    回滚杆 1 与恰上界 limit-1 合法;0/负/恰 limit(4)/limit+1(5) 启动断言报错
    (覆盖 ≤ limit-1 的两个边界方向;启动校验面 = ms-api + ms-worker 双容器)。"""
    s = make_settings()
    assert s.baidu_vip_parallel_per_binding == 3, "默认 3(不设 env 时生效)"
    s.validate_baidu_settings()   # 默认配置必须通过

    make_settings(baidu_vip_parallel_per_binding=1).validate_baidu_settings()
    # ↑ 回滚杆 env=1:完全恢复原行为(合法下界)
    make_settings(baidu_admission_limit=6,
                  baidu_vip_parallel_per_binding=5).validate_baidu_settings()
    # ↑ 恰上界 limit-1=5 合法(与 limit 联动)

    with pytest.raises(AssertionError):
        make_settings(baidu_vip_parallel_per_binding=0).validate_baidu_settings()
    # ↑ 下限红线:0 会静默砖死会员准入
    with pytest.raises(AssertionError):
        make_settings(baidu_vip_parallel_per_binding=-1).validate_baidu_settings()
    # ↑ 负值同方向
    with pytest.raises(AssertionError):
        make_settings(baidu_vip_parallel_per_binding=4).validate_baidu_settings()
    # ↑ 恰 = limit(默认 4):配满会把 GREATEST(limit-vip_count,0) 配置性清零、
    #   饿死全部非会员道且无启动报错(与 nonvip ≤ limit-2 红线同精神,方向相反)
    with pytest.raises(AssertionError):
        make_settings(baidu_vip_parallel_per_binding=5).validate_baidu_settings()
    # ↑ limit+1:越界同侧再取一例


async def test_r13_worker_gate_reads_vip_parallel_settings_rollback_lever(
    world: World, lanes: LaneFactory, baidu_spy, enable_baidu,
    monkeypatch: pytest.MonkeyPatch, stack,
) -> None:
    """R13(设计正本 §5 R13):worker 接线端到端 —— settings 单例置
    baidu_vip_parallel_per_binding=1(= 回滚杆 env 语义),会员绑定下仅 1 个任务
    过认领后门控,其余 queue out。钉住 worker 调用点真读 settings(接线声明 I6),
    兼作回滚杆验收回归网:env=1 时行为与改造前逐位等价。

    构造(仿 T12 占坑法;法证:认领置 round_started_at=now,窗口序 round 非空恒
    排前 → 刚认领者必然 rn=1 自我准入,休眠兄弟不占坑压不住它 —— 生产回滚杆
    语义正确靠 sweeper 预算=1 每拍只派最老候选,门控兜「同拍多派」):预置 1 条
    round 更早的 running 占坑任务 → vip_par=1 下 dispatch+claim 后到候选
    (round 更晚 → rn=2 > 1)必 queue out;清掉占坑任务后最老候选过门控直达终态。"""
    monkeypatch.setattr(get_settings(), "baidu_vip_parallel_per_binding", 1, raising=False)
    lane = await lanes.add(vip_type=1)
    await lanes.grant_project_uploader(lane)   # tasks[0] 真实导入的 can_upload 前置
    tasks = []
    for i in range(3):
        tasks.append(await _mk_task(
            world, status="enumerating", enum_done=False,
            user_id=lane.user.id, binding_id=lane.binding.id,
            created_at=NOW - timedelta(minutes=30 - 10 * i),
            source_dir=f"/it-r13-{i}",
        ))
    pit = await _seed_running_rep(world, lane, created_min_ago=5.0)   # round 更早,占坑

    # 占坑在场:后到候选认领(round=now 晚于 pit)→ rn=2 > vip_par=1 → queue out
    for i in (1, 2):
        async with _db() as db:
            assert await dispatch_baidu_task(db, tasks[i].id, sweeper=True)
        res = await _claim_and_run(tasks[i].id)
        assert res["status"] == "queued", \
            f"vip_par=1 + 占坑在场,同绑定第 {i + 1} 候选必须 queue out(worker 真读 settings): {res}"
        t = await _get_task(tasks[i].id)
        assert t.status == "enumerating" and t.round_started_at is None, \
            "门控退出安静回队:不落终态、复位轮起点"
    assert baidu_spy.list_calls == 0, "queue out 发生在枚举前:零 list API 调用"

    # 清占坑 → 最老候选成唯一 round 非空行 → rn=1 ≤ vip_par 过门控:真实枚举
    # 进导入循环直至终态(回滚杆语义 = 每绑定 1 路)
    await _touch_task(pit.id, status="completed")
    _seed_listing(baidu_spy, tasks[0].source_dir, {"r13.mp4": b"r13-bytes"})
    async with _db() as db:
        assert await dispatch_baidu_task(db, tasks[0].id, sweeper=True)
    res = await _claim_and_run(tasks[0].id)
    t0 = await _get_task(tasks[0].id)
    assert res["status"] == "completed" and t0.status == "completed", \
        f"回滚杆 vip_par=1 下最老候选照常准入并执行至终态: {res} fail_reason={t0.fail_reason}"
    assert baidu_spy.list_calls == 1, "仅过门控的最老候选真实枚举 1 次"
