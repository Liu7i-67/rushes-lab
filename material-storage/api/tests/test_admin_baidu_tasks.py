"""管理员备份任务视图(admin baidu-backup 只读三端点)— 集成测试,跑在 ms-api 容器里。

对应需求:`docs/qdev/2026-10-14-baidu-admin-observability.md`「测试功能点」T1-T9 与
「接口定义」①②③;上游方案 rushes-spec/material-storage/prod-observability-fix-plan.md
§3.1(端点契约)/§3.3(测试清单)。写法仿 tests/test_grant_templates.py
(httpx ASGITransport + AsyncClient 直打 app、Evan=org admin、env=dev 走 X-User-Id);
任务数据构造仿 tests/test_baidu_integration.py 的直插 DB 模式。

契约要点(require_system_admin,非 org admin 403;**不随** baidu_backup_enabled 门控):
  - GET /api/v1/admin/baidu-backup/tasks            → {items: TaskItem[], total}
    Query: status(白名单 5 值,非法 400)/ user_id / q(username|name|source_dir ilike)/
    active_only(status IN (enumerating,running))/ limit=20(1..100)/ offset(>=0);
    排序固定 created_at DESC, id DESC;fail_reason 截 200;聚合列 NULL 序列化 0
  - GET /api/v1/admin/baidu-backup/tasks/{id}       → TaskItem + bound_baidu_uid +
    binding{id,baidu_uid,status} + cancel_reason + retry_count/enum_done/
    dispatched_at/round_started_at/lease_until/runner_id;不存在 404
  - GET /api/v1/admin/baidu-backup/tasks/{id}/files → {items: FileItem[], total}
    Query: status(白名单 6 值,非法 400)/ limit=50(1..200)/ offset;排序 rel_path, id;
    last_error 截 200

预期前置(同 test_grant_templates.py):
  1. seed_demo_data.py 已跑过(Evan = 真 user + org admin;outsider = 无权限契约账号)
  2. OpenFGA store / model 已 push;env=dev(X-User-Id header 模拟身份)
  3. ms-db 可达(本模块直插 BaiduBackupTask / BaiduBackupTaskFile 行,见 world fixture)

数据构造(module 级一次建好、收尾清理;tag=8 位随机 hex 保证与容器既有数据零串扰):
  独立 org + 2 用户(u1 带 username、u2 username=NULL 验证透传)+ project + 目标夹 +
  每用户 1 条 binding,共 7 条任务:
    u1: running(base+60s,聚合齐,挂 5 条文件行)/ failed(base+50s,聚合全 NULL +
        fail_reason 300 字符 + target_folder_id=NULL)/ completed(base+40s)
    u2: completed x 2(同 created_at=base+15s,验 id DESC 稳定排序)/
        enumerating(base+10s,活动任务)/ cancelled(base+5s,cancel 语义)
  同绑定活动任务受 running-only 唯一兜底(uq_baidu_task_running 部分唯一索引)
  与软上限(baidu_max_active_tasks_per_binding,并发方案 §2.5)约束 → u1 唯一
  running、u2 唯一 enumerating,均在约束内。
  「跨用户可见」按需求口径为**全系统**(不限默认 org):任务挂在独立 org 的用户名下,
  恰好验证 admin 视角无 org 侬据(若实现错误地按默认 org 过滤,本模块会失败暴露)。

T1-T9 ↔ 测试函数(每条 T 恰一个函数):
  T1 → test_t1_non_admin_403_on_all_three_endpoints
  T2 → test_t2_admin_list_cross_user_and_item_shape
  T3 → test_t3_pagination_and_created_at_desc_id_desc_ordering
  T4 → test_t4_status_whitelist_filter_and_active_only
  T5 → test_t5_user_id_and_q_three_way_filters
  T6 → test_t6_missing_task_404_on_detail_and_files
  T7 → test_t7_files_status_filter_whitelist_pagination_ordering
  T8 → test_t8_truncation_null_aggregates_username_null_and_detail_extras
  T9 → test_t9_not_gated_by_baidu_backup_enabled_flag
"""
from __future__ import annotations

import os
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

# 须先于下方 app.* 导入置位:pytest 按字母序收集,本文件(test_admin_*)早于
# test_baidu_integration.py 被导入,若不在此 setdefault,settings 单例会被固化为
# baidu_backup_enabled=False,连带全量回归失败(惯例对齐 test_baidu_integration.py 顶部)。
os.environ.setdefault("BAIDU_BACKUP_ENABLED", "true")

from app.db.session import get_sessionmaker
from app.db.tables import (
    BaiduBackupTask,
    BaiduBackupTaskFile,
    BaiduBinding,
    Folder,
    Organization,
    Project,
    User,
)
from app.main import create_app
from app.settings import get_settings

# seed 写死的真 user / fake outsider(同 test_grant_templates.py)
EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"
OUTSIDER_ID = "00000000-0000-0000-0000-0000000000aa"

LIST_URL = "/api/v1/admin/baidu-backup/tasks"

TASK_STATUSES = ("enumerating", "running", "completed", "cancelled", "failed")
FILE_STATUSES = ("pending", "skipped_exists", "importing", "success", "failed", "cancelled")


@pytest.fixture(scope="session")
async def app_with_lifespan():
    app = create_app()
    async with app.router.lifespan_context(app):  # type: ignore[attr-defined]
        yield app


@pytest.fixture(scope="session")
async def client(app_with_lifespan):
    transport = ASGITransport(app=app_with_lifespan)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


def _h(user_id: str) -> dict[str, str]:
    return {"X-User-Id": user_id}


def _detail_url(task_id: uuid.UUID | str) -> str:
    return f"{LIST_URL}/{task_id}"


def _files_url(task_id: uuid.UUID | str) -> str:
    return f"{LIST_URL}/{task_id}/files"


# ─── 数据世界(仿 test_baidu_integration 的 world 直插模式,module 级共享)────────
@dataclass
class BaiduAdminWorld:
    tag: str
    u1_id: uuid.UUID          # 带 username 的任务属主
    u1_username: str
    u2_id: uuid.UUID          # username=NULL 的任务属主(序列化透传 null)
    u2_name: str
    project_id: uuid.UUID
    project_name: str
    folder_id: uuid.UUID
    folder_name: str
    b1_id: uuid.UUID          # u1 的 binding(baidu_uid=200)
    b2_id: uuid.UUID          # u2 的 binding(baidu_uid=201)
    t_run: BaiduBackupTask        # u1 running(唯一活动;挂 5 条文件行)
    t_fail: BaiduBackupTask       # u1 failed(NULL 聚合 + fail_reason 300 + 无目标夹)
    t_u1_done: BaiduBackupTask    # u1 completed
    t_u2_done_a: BaiduBackupTask  # u2 completed(与 b 同 created_at,验 id DESC)
    t_u2_done_b: BaiduBackupTask
    t_enum: BaiduBackupTask       # u2 enumerating(唯一活动)
    t_cancel: BaiduBackupTask     # u2 cancelled(cancel 语义)
    expected_order: list[uuid.UUID]  # 全 7 条按 created_at DESC, id DESC 的期望序


def _mk_file(db: Any, task: BaiduBackupTask, rel_path: str, *, size: int = 1024,
             status: str = "pending", **overrides: Any) -> None:
    """往 session 挂一条 manifest 行(同 test_baidu_integration._mk_file 的列口径)。"""
    f = BaiduBackupTaskFile(
        task_id=task.id,
        fs_id=int(uuid.uuid4().int % 10**15),
        source_path=f"{task.source_dir}/{rel_path}",
        source_size=size,
        rel_path=rel_path,
        status=status,
        bytes_done=0,
    )
    for k, v in overrides.items():
        setattr(f, k, v)
    db.add(f)


@pytest.fixture(scope="module")
async def world() -> Any:
    """建 2 用户 + 7 任务 + 5 文件行;收尾按 FK 逆序清理(files→tasks→bindings→
    folders→project→users→org)。tag 随机,断言一律经 q=tag / user_id 隔离本模块数据。"""
    tag = uuid.uuid4().hex[:8]
    base = datetime.now(UTC) - timedelta(minutes=10)
    long_fail_reason = "F" * 300
    long_last_error = "E" * 300
    created: dict[str, Any] = {}
    w: BaiduAdminWorld | None = None
    try:
        async with get_sessionmaker()() as db:
            org = Organization(name=f"it-admin-baidu-{tag}",
                               feishu_tenant_key=f"it_admin_baidu_{tag}")
            db.add(org)
            await db.flush()
            u1 = User(name=f"itabt-user1-{tag}", username=f"itabt_u1_{tag}",
                      email=f"itabt-u1-{tag}@example.com", organization_id=org.id)
            u2 = User(name=f"itabt-user2-{tag}", username=None,
                      email=f"itabt-u2-{tag}@example.com", organization_id=org.id)
            db.add_all([u1, u2])
            project = Project(organization_id=org.id, code=f"itabt_{tag}",
                              name=f"it-admin-baidu-tasks-{tag}",
                              minio_bucket=f"itabt-{tag}", visibility="private")
            db.add(project)
            await db.flush()
            folder = Folder(project_id=project.id, name="itabt-target",
                            minio_prefix="itabt-target/")
            db.add(folder)
            await db.flush()

            def _binding(user_id: uuid.UUID, baidu_uid: str) -> BaiduBinding:
                return BaiduBinding(
                    user_id=user_id,
                    access_token_enc=f"itabt-access-{tag}",
                    refresh_token_enc=f"itabt-refresh-{tag}",
                    baidu_uid=baidu_uid,
                    nickname=f"itabt-binding-{baidu_uid}",
                    access_token_expires_at=base + timedelta(days=30),
                    status="active",
                    last_authorized_at=base,
                    token_rotated_at=base,
                )

            b1, b2 = _binding(u1.id, "200"), _binding(u2.id, "201")
            db.add_all([b1, b2])
            await db.flush()

            def _task(user: User, binding: BaiduBinding, baidu_uid: str, status: str,
                      created_at: datetime, source_dir: str, **extra: Any) -> BaiduBackupTask:
                return BaiduBackupTask(
                    user_id=user.id,
                    binding_id=binding.id,
                    bound_baidu_uid=baidu_uid,
                    source_dir=source_dir,
                    project_id=project.id,
                    target_folder_id=extra.pop("target_folder_id", folder.id),
                    status=status,
                    created_at=created_at,
                    **extra,
                )

            t_run = _task(
                u1, b1, "200", "running", base + timedelta(seconds=60),
                f"/itabt-{tag}/src-running",
                enum_done=True,
                total_files=100, done_files=80, failed_files=3, skipped_files=1,
                cancelled_files=0, total_bytes=10000, done_bytes=8000,
                runner_id="itabt-runner", dispatched_at=base + timedelta(seconds=61),
                round_started_at=base + timedelta(seconds=62),
                lease_until=base + timedelta(seconds=600),
            )
            t_fail = _task(
                u1, b1, "200", "failed", base + timedelta(seconds=50),
                f"/itabt-{tag}/src-failed",
                target_folder_id=None,  # 目标夹已删形态(SET NULL)→ target_folder 序列化 null
                fail_reason=long_fail_reason,  # 300 字符 → 端点截 200
                retry_count=2,
                # 聚合列全部留 NULL(表列可空,enumerating 阶段形态)→ 序列化 0 兜底
            )
            t_u1_done = _task(
                u1, b1, "200", "completed", base + timedelta(seconds=40),
                f"/itabt-{tag}/src-u1done",
                total_files=10, done_files=10, failed_files=0, skipped_files=0,
                cancelled_files=0, total_bytes=5000, done_bytes=5000,
            )
            t_u2_done_a = _task(
                u2, b2, "201", "completed", base + timedelta(seconds=15),
                f"/itabt-{tag}/src-u2a",
                total_files=3, done_files=2, failed_files=1, skipped_files=0,
                cancelled_files=0, total_bytes=300, done_bytes=200,
            )
            t_u2_done_b = _task(
                u2, b2, "201", "completed", base + timedelta(seconds=15),
                f"/itabt-{tag}/src-u2b",
                total_files=0, done_files=0, failed_files=0, skipped_files=0,
                cancelled_files=0, total_bytes=0, done_bytes=0,
            )
            t_enum = _task(
                u2, b2, "201", "enumerating", base + timedelta(seconds=10),
                f"/itabt-{tag}/src-enum",
                # 聚合 NULL + enum_done=False:枚举未完成形态
            )
            t_cancel = _task(
                u2, b2, "201", "cancelled", base + timedelta(seconds=5),
                f"/itabt-{tag}/src-cancel",
                total_files=4, done_files=0, failed_files=0, skipped_files=0,
                cancelled_files=4, total_bytes=400, done_bytes=0,
                cancel_requested=True, cancel_reason="user_cancel",
            )
            db.add_all([t_run, t_fail, t_u1_done, t_u2_done_a, t_u2_done_b,
                        t_enum, t_cancel])
            await db.flush()

            # 5 条文件行挂在 t_run;插入顺序刻意打乱(c,a,e,b,d),服务端须按 rel_path 排
            _mk_file(db, t_run, "c.txt", status="success", attempts=1)
            _mk_file(db, t_run, "a.txt", status="success", attempts=1, bytes_done=100)
            _mk_file(db, t_run, "e.txt", status="pending", attempts=0)
            _mk_file(db, t_run, "b.txt", status="failed", attempts=2,
                     bytes_done=999, last_error="boom")
            _mk_file(db, t_run, "d.txt", status="failed", attempts=3,
                     non_retryable=True, last_error=long_last_error)

            await db.commit()
            created.update(org_id=org.id, project_id=project.id,
                           u1_id=u1.id, u2_id=u2.id)
            # 同 created_at 对按 id DESC 的期望序(uuid4 不可预知,插入后回读排序)
            tie = sorted([t_u2_done_a.id, t_u2_done_b.id], reverse=True)
            w = BaiduAdminWorld(
                tag=tag, u1_id=u1.id, u1_username=str(u1.username), u2_id=u2.id,
                u2_name=str(u2.name), project_id=project.id,
                project_name=str(project.name), folder_id=folder.id,
                folder_name=str(folder.name), b1_id=b1.id, b2_id=b2.id,
                t_run=t_run, t_fail=t_fail, t_u1_done=t_u1_done,
                t_u2_done_a=t_u2_done_a, t_u2_done_b=t_u2_done_b,
                t_enum=t_enum, t_cancel=t_cancel,
                expected_order=[t_run.id, t_fail.id, t_u1_done.id,
                                tie[0], tie[1], t_enum.id, t_cancel.id],
            )
        yield w
    finally:
        if "org_id" in created:
            async with get_sessionmaker()() as db:
                if "project_id" in created:
                    pid = created["project_id"]
                    task_ids = select(BaiduBackupTask.id).where(
                        BaiduBackupTask.project_id == pid)
                    await db.execute(BaiduBackupTaskFile.__table__.delete().where(
                        BaiduBackupTaskFile.task_id.in_(task_ids)))
                    await db.execute(BaiduBackupTask.__table__.delete().where(
                        BaiduBackupTask.project_id == pid))
                    await db.execute(Folder.__table__.delete().where(
                        Folder.project_id == pid))
                    await db.execute(Project.__table__.delete().where(Project.id == pid))
                oid = created["org_id"]
                user_ids = select(User.id).where(User.organization_id == oid)
                await db.execute(BaiduBinding.__table__.delete().where(
                    BaiduBinding.user_id.in_(user_ids)))
                await db.execute(User.__table__.delete().where(
                    User.organization_id == oid))
                await db.execute(Organization.__table__.delete().where(
                    Organization.id == oid))
                await db.commit()


# ─── T1 非 org admin(outsider X-User-Id)访问三端点 → 403 ────────────────────
@pytest.mark.asyncio
async def test_t1_non_admin_403_on_all_three_endpoints(
    client: AsyncClient, world: BaiduAdminWorld,
) -> None:
    ghost = uuid.uuid4()
    r_list = await client.get(LIST_URL, headers=_h(OUTSIDER_ID))
    assert r_list.status_code == 403, r_list.text

    r_detail = await client.get(_detail_url(ghost), headers=_h(OUTSIDER_ID))
    assert r_detail.status_code == 403, r_detail.text

    r_files = await client.get(_files_url(ghost), headers=_h(OUTSIDER_ID))
    assert r_files.status_code == 403, r_files.text


# ─── T2 org admin 列表 200,跨用户可见 + TaskItem 形状 ─────────────────────────
@pytest.mark.asyncio
async def test_t2_admin_list_cross_user_and_item_shape(
    client: AsyncClient, world: BaiduAdminWorld,
) -> None:
    r = await client.get(LIST_URL, params={"q": world.tag, "limit": 100},
                         headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["total"] == 7
    items = {i["id"]: i for i in body["items"]}

    # 跨用户可见:两个用户(u1 带 username / u2 username=NULL)的任务都在
    owner_ids = {i["user"]["id"] for i in items.values()}
    assert owner_ids == {str(world.u1_id), str(world.u2_id)}
    assert sum(1 for i in items.values() if i["user"]["id"] == str(world.u1_id)) == 3
    assert sum(1 for i in items.values() if i["user"]["id"] == str(world.u2_id)) == 4

    # TaskItem 形状(接口定义①):user{id,username,name} / project{id,name} /
    # target_folder{id,name} / 聚合列 / fail_reason / cancel_requested / 时间戳
    run = items[str(world.t_run.id)]
    assert run["user"] == {"id": str(world.u1_id), "username": world.u1_username,
                           "name": f"itabt-user1-{world.tag}"}
    assert run["status"] == "running"
    assert run["source_dir"] == f"/itabt-{world.tag}/src-running"
    assert run["project"] == {"id": str(world.project_id), "name": world.project_name}
    assert run["target_folder"] == {"id": str(world.folder_id), "name": world.folder_name}
    assert run["total_files"] == 100 and run["done_files"] == 80
    assert run["failed_files"] == 3 and run["skipped_files"] == 1
    assert run["cancelled_files"] == 0
    assert run["total_bytes"] == 10000 and run["done_bytes"] == 8000
    assert run["fail_reason"] is None
    assert run["cancel_requested"] is False
    assert run["created_at"] and run["updated_at"]

    # username=NULL 的属主透传 null(接口定义①:user.username 可空)
    assert items[str(world.t_u2_done_a.id)]["user"]["username"] is None
    assert items[str(world.t_u2_done_a.id)]["user"]["name"] == world.u2_name


# ─── T3 列表分页 / 排序(created_at DESC, id DESC;limit 1..100)───────────────
@pytest.mark.asyncio
async def test_t3_pagination_and_created_at_desc_id_desc_ordering(
    client: AsyncClient, world: BaiduAdminWorld,
) -> None:
    expected = [str(t) for t in world.expected_order]

    # 全量(q=tag 隔离本模块 7 条):顺序 = created_at DESC,同秒对 id DESC
    r_all = await client.get(LIST_URL, params={"q": world.tag, "limit": 100},
                             headers=_h(EVAN_ID))
    assert r_all.status_code == 200, r_all.text
    body = r_all.json()
    assert body["total"] == 7
    assert [i["id"] for i in body["items"]] == expected

    # 默认 limit=20(7 条全回,顺序不变)
    r_default = await client.get(LIST_URL, params={"q": world.tag}, headers=_h(EVAN_ID))
    assert r_default.status_code == 200
    assert [i["id"] for i in r_default.json()["items"]] == expected

    # limit=2 逐页(offset 0/2/4/6)拼接 = 全量顺序;每页 total 恒 7;末页余 1 条
    got: list[str] = []
    for offset in (0, 2, 4, 6):
        r = await client.get(LIST_URL, params={"q": world.tag, "limit": 2, "offset": offset},
                             headers=_h(EVAN_ID))
        assert r.status_code == 200, r.text
        page = r.json()
        assert page["total"] == 7
        got.extend(i["id"] for i in page["items"])
    assert got == expected

    # limit 越上界(>100)→ 422(接口定义①:limit 1..100)
    r_over = await client.get(LIST_URL, params={"q": world.tag, "limit": 101},
                              headers=_h(EVAN_ID))
    assert r_over.status_code == 422, r_over.text


# ─── T4 status 白名单 400 / 合法过滤生效 / active_only 只回活动任务 ────────────
@pytest.mark.asyncio
async def test_t4_status_whitelist_filter_and_active_only(
    client: AsyncClient, world: BaiduAdminWorld,
) -> None:
    # 非法 status → 400(白名单;大小写敏感,大写不在白名单)
    for bad in ("nope", "RUNNING"):
        r_bad = await client.get(LIST_URL, params={"q": world.tag, "status": bad},
                                 headers=_h(EVAN_ID))
        assert r_bad.status_code == 400, f"status={bad}: {r_bad.text}"

    # 白名单 5 个合法值逐一被接受(200,不误拒)
    for status in TASK_STATUSES:
        r_ok = await client.get(LIST_URL, params={"q": world.tag, "status": status},
                                headers=_h(EVAN_ID))
        assert r_ok.status_code == 200, f"status={status}: {r_ok.text}"

    # 合法 status 过滤:completed 恰 3 条(u1_done + u2 两 completed)
    r_done = await client.get(LIST_URL, params={"q": world.tag, "status": "completed"},
                              headers=_h(EVAN_ID))
    assert r_done.status_code == 200, r_done.text
    done = r_done.json()
    assert done["total"] == 3
    assert {i["id"] for i in done["items"]} == {
        str(world.t_u1_done.id), str(world.t_u2_done_a.id), str(world.t_u2_done_b.id)}
    assert all(i["status"] == "completed" for i in done["items"])

    # running 恰 1 条(u1 活动任务);enumerating 恰 1 条(u2 活动任务)
    for status, task in (("running", world.t_run), ("enumerating", world.t_enum)):
        r_one = await client.get(LIST_URL, params={"q": world.tag, "status": status},
                                 headers=_h(EVAN_ID))
        assert r_one.status_code == 200
        one = r_one.json()
        assert one["total"] == 1, one
        assert one["items"][0]["id"] == str(task.id)

    # active_only=true → 只回 enumerating/running(u1_running + u2_enumerating)
    r_active = await client.get(LIST_URL, params={"q": world.tag, "active_only": "true"},
                                headers=_h(EVAN_ID))
    assert r_active.status_code == 200, r_active.text
    active = r_active.json()
    assert active["total"] == 2
    assert {i["id"] for i in active["items"]} == {
        str(world.t_run.id), str(world.t_enum.id)}
    assert all(i["status"] in ("enumerating", "running") for i in active["items"])


# ─── T5 user_id / q(username、name、source_dir 三路模糊)过滤 ──────────────────
@pytest.mark.asyncio
async def test_t5_user_id_and_q_three_way_filters(
    client: AsyncClient, world: BaiduAdminWorld,
) -> None:
    # user_id 过滤:u1 恰 3 条、u2 恰 4 条,且条目属主正确
    for uid, task_ids in ((world.u1_id, [world.t_run.id, world.t_fail.id, world.t_u1_done.id]),
                          (world.u2_id, [world.t_u2_done_a.id, world.t_u2_done_b.id,
                                         world.t_enum.id, world.t_cancel.id])):
        r = await client.get(LIST_URL, params={"user_id": str(uid), "limit": 100},
                             headers=_h(EVAN_ID))
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["total"] == len(task_ids)
        assert {i["id"] for i in body["items"]} == {str(t) for t in task_ids}
        assert all(i["user"]["id"] == str(uid) for i in body["items"])

    # q 按 username 匹配(u1 的 username,仅 username 命中)
    r_un = await client.get(LIST_URL, params={"q": f"itabt_u1_{world.tag}"},
                            headers=_h(EVAN_ID))
    assert r_un.status_code == 200, r_un.text
    un = r_un.json()
    assert un["total"] == 3
    assert {i["user"]["id"] for i in un["items"]} == {str(world.u1_id)}

    # q 按 name 匹配(u2 username=NULL,name 命中 → 证明 name 路独立生效)
    r_name = await client.get(LIST_URL, params={"q": world.u2_name}, headers=_h(EVAN_ID))
    assert r_name.status_code == 200, r_name.text
    name_body = r_name.json()
    assert name_body["total"] == 4
    assert {i["user"]["id"] for i in name_body["items"]} == {str(world.u2_id)}

    # q 按 source_dir 匹配:src-failed 片段只出现在 t_fail 的 source_dir
    # (source_dir 实为 f"/itabt-{tag}/src-failed",q 片段须落在该串内才会命中)
    r_dir = await client.get(LIST_URL, params={"q": f"itabt-{world.tag}/src-failed"},
                             headers=_h(EVAN_ID))
    assert r_dir.status_code == 200, r_dir.text
    dir_body = r_dir.json()
    assert dir_body["total"] == 1
    assert dir_body["items"][0]["id"] == str(world.t_fail.id)

    # q 无命中 → total=0 / items=[]
    r_none = await client.get(LIST_URL, params={"q": f"no-hit-{world.tag}-xyz"},
                              headers=_h(EVAN_ID))
    assert r_none.status_code == 200
    assert r_none.json() == {"items": [], "total": 0}


# ─── T6 不存在 task_id → 404(详情 / 文件明细两形态)───────────────────────────
@pytest.mark.asyncio
async def test_t6_missing_task_404_on_detail_and_files(
    client: AsyncClient, world: BaiduAdminWorld,
) -> None:
    ghost = uuid.uuid4()
    r_detail = await client.get(_detail_url(ghost), headers=_h(EVAN_ID))
    assert r_detail.status_code == 404, r_detail.text

    r_files = await client.get(_files_url(ghost), headers=_h(EVAN_ID))
    assert r_files.status_code == 404, r_files.text


# ─── T7 files:status 过滤 + 白名单 400 + 分页 + rel_path 排序 ─────────────────
@pytest.mark.asyncio
async def test_t7_files_status_filter_whitelist_pagination_ordering(
    client: AsyncClient, world: BaiduAdminWorld,
) -> None:
    url = _files_url(world.t_run.id)

    # 全量:插入顺序打乱(c,a,e,b,d),服务端须按 rel_path, id 排序回 a..e
    r_all = await client.get(url, params={"limit": 100}, headers=_h(EVAN_ID))
    assert r_all.status_code == 200, r_all.text
    body = r_all.json()
    assert body["total"] == 5
    rel_paths = [i["rel_path"] for i in body["items"]]
    assert rel_paths == ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"]

    # FileItem 形状(接口定义③)
    by_path = {i["rel_path"]: i for i in body["items"]}
    a = by_path["a.txt"]
    assert set(a) >= {"id", "source_path", "rel_path", "status", "bytes_done",
                      "attempts", "non_retryable", "last_error", "asset_id", "updated_at"}
    assert a["source_path"] == f"{world.t_run.source_dir}/a.txt"
    assert a["bytes_done"] == 100 and a["asset_id"] is None
    assert by_path["b.txt"]["last_error"] == "boom"
    assert by_path["d.txt"]["non_retryable"] is True

    # status 过滤:failed 恰 2 条;success / pending / cancelled 各命中预期数量
    r_failed = await client.get(url, params={"status": "failed"}, headers=_h(EVAN_ID))
    assert r_failed.status_code == 200
    failed = r_failed.json()
    assert failed["total"] == 2
    assert {i["rel_path"] for i in failed["items"]} == {"b.txt", "d.txt"}
    assert all(i["status"] == "failed" for i in failed["items"])

    for status, total in (("success", 2), ("pending", 1), ("cancelled", 0)):
        r_s = await client.get(url, params={"status": status}, headers=_h(EVAN_ID))
        assert r_s.status_code == 200
        assert r_s.json()["total"] == total, f"status={status}: {r_s.text}"

    # 非法 status → 400(白名单 pending/skipped_exists/importing/success/failed/cancelled)
    r_bad = await client.get(url, params={"status": "done"}, headers=_h(EVAN_ID))
    assert r_bad.status_code == 400, r_bad.text

    # 白名单 6 个合法值逐一被接受(200;skipped_exists/importing 无数据 → total 0)
    for status in FILE_STATUSES:
        r_ok = await client.get(url, params={"status": status}, headers=_h(EVAN_ID))
        assert r_ok.status_code == 200, f"status={status}: {r_ok.text}"

    # 分页 limit=2(offset 0/2/4)拼接 = 全量 rel_path 顺序;limit=0 → 422(1..200)
    got: list[str] = []
    for offset in (0, 2, 4):
        r = await client.get(url, params={"limit": 2, "offset": offset},
                             headers=_h(EVAN_ID))
        assert r.status_code == 200
        page = r.json()
        assert page["total"] == 5
        got.extend(i["rel_path"] for i in page["items"])
    assert got == ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"]

    r_zero = await client.get(url, params={"limit": 0}, headers=_h(EVAN_ID))
    assert r_zero.status_code == 422, r_zero.text


# ─── T8 fail_reason / last_error 截 200;聚合 NULL 序列化 0;username null 透传;
#     详情端点(②)扩展字段(binding / cancel_reason / 调度观测)──────────────────
@pytest.mark.asyncio
async def test_t8_truncation_null_aggregates_username_null_and_detail_extras(
    client: AsyncClient, world: BaiduAdminWorld,
) -> None:
    # failed 任务:fail_reason 300 → 200;聚合列 NULL → 0;target_folder 已删 → null
    r_fail = await client.get(_detail_url(world.t_fail.id), headers=_h(EVAN_ID))
    assert r_fail.status_code == 200, r_fail.text
    fail = r_fail.json()
    assert fail["fail_reason"] == "F" * 200
    assert fail["total_files"] == 0 and fail["done_files"] == 0
    assert fail["failed_files"] == 0 and fail["skipped_files"] == 0
    assert fail["cancelled_files"] == 0
    assert fail["total_bytes"] == 0 and fail["done_bytes"] == 0
    assert fail["target_folder"] is None
    assert fail["cancel_requested"] is False and fail["cancel_reason"] is None
    assert fail["retry_count"] == 2

    # username=NULL 属主在详情同样透传 null
    r_a = await client.get(_detail_url(world.t_u2_done_a.id), headers=_h(EVAN_ID))
    assert r_a.status_code == 200, r_a.text
    assert r_a.json()["user"] == {"id": str(world.u2_id), "username": None,
                                  "name": world.u2_name}

    # running 任务详情:bound_baidu_uid 快照 + binding{id,baidu_uid,status} + 调度观测字段
    r_run = await client.get(_detail_url(world.t_run.id), headers=_h(EVAN_ID))
    assert r_run.status_code == 200, r_run.text
    run = r_run.json()
    assert run["bound_baidu_uid"] == "200"
    assert run["binding"] == {"id": str(world.b1_id), "baidu_uid": "200",
                              "status": "active"}
    assert run["enum_done"] is True
    assert run["runner_id"] == "itabt-runner"
    assert run["dispatched_at"] is not None
    assert run["round_started_at"] is not None
    assert run["lease_until"] is not None
    assert run["retry_count"] == 0

    # cancelled 任务详情:cancel_requested / cancel_reason 透传
    r_cancel = await client.get(_detail_url(world.t_cancel.id), headers=_h(EVAN_ID))
    assert r_cancel.status_code == 200, r_cancel.text
    cancel = r_cancel.json()
    assert cancel["cancel_requested"] is True
    assert cancel["cancel_reason"] == "user_cancel"

    # 文件行 last_error 300 → 200(b.txt 短文案原样)
    r_err = await client.get(_files_url(world.t_run.id), params={"status": "failed"},
                             headers=_h(EVAN_ID))
    assert r_err.status_code == 200, r_err.text
    errs = {i["rel_path"]: i["last_error"] for i in r_err.json()["items"]}
    assert errs["d.txt"] == "E" * 200
    assert errs["b.txt"] == "boom"


# ─── T9 端点不随 baidu_backup_enabled=False 404(与用户侧 router 语义区分)──────
@pytest.mark.asyncio
async def test_t9_not_gated_by_baidu_backup_enabled_flag(
    client: AsyncClient, world: BaiduAdminWorld, monkeypatch: pytest.MonkeyPatch,
) -> None:
    # 用户侧 router 的 _ensure_enabled() 在开关关时统一 404;admin 观测面不门控
    # (上游方案 D2:管理观测面看存量事实)。仿 test_baidu_integration._set_feature_flag
    # 对 get_settings() 单例打补丁,函数级自动还原。
    monkeypatch.setattr(get_settings(), "baidu_backup_enabled", False, raising=False)

    r_list = await client.get(LIST_URL, params={"q": world.tag}, headers=_h(EVAN_ID))
    assert r_list.status_code == 200, r_list.text
    assert r_list.json()["total"] == 7

    r_detail = await client.get(_detail_url(world.t_run.id), headers=_h(EVAN_ID))
    assert r_detail.status_code == 200, r_detail.text

    r_files = await client.get(_files_url(world.t_run.id), headers=_h(EVAN_ID))
    assert r_files.status_code == 200, r_files.text
