"""C 包审计展开详情补名 — 集成测试(容器内跑,面向契约)。

需求依据:`docs/qdev/2026-10-19-inapp-ux-enrichment.md` C1/C2 + 测试功能点节;
实施细则正本 `rushes-spec/material-storage/inapp-browser-tip-preview-nav-audit-enrichment-plan.md`
§3.2/§3.3。写法仿 tests/test_audit_project_name.py(httpx ASGITransport + Evan=系统
admin、env=dev 走 X-User-Id + module 级 world 造数、teardown 彻底清除)。

契约要点:
  - GET /api/v1/admin/audit 的 AuditOut 增 `user_agent: str|null`(裸列透传)与
    `resolved_names: dict[str,str]`(key=details 白名单键,value=纯显示名)
  - 白名单 9 键:folder_id / target_folder_id / parent_folder_id /
    old_parent_folder_id / new_parent_folder_id / group_id / user_id /
    sharer_user_id / subject;folder 桶→folders.name、user 桶→users.name、
    group 桶→groups.name、subject→subject_names.resolve_subject_names
  - subject 补名是**纯名称**(不拼「(用户)/(用户组)」后缀,类型标注归前端);
    resolve found=False(已删/非 UUID)的键不进 resolved_names
  - details 垃圾值(非 UUID)静默跳过,接口不 500;查不到的键不进 dict
  - AuditService.write 对 user_agent[:512] 截断(收口全部写入路径,C2)
  - CSV 导出不动;分页/过滤行为不变(D-C1 / 回归口径)

造数方式:审计事件经 `AuditService.write` 直写(生产 details 形态逐字段对齐
folders.py:1224 / projects.py:299 / folders.py:498 / baidu_backup.py:822 /
user_provisioning.py:83 / share_service.py:64 / directory.py:348 的既有写入点),
user/group 行 DB 直插(test_project_artist_account.py 惯例),folder 行走 API 建。
被测对象是 list 端点的补名逻辑,与事件触发路径解耦;事件 dedup_key 统一
`zz_cnames:` 前缀,teardown 物理清干净,不污染共享 dev 栈。

前置(同 test_audit_project_name.py):seed_demo_data.py 已跑过(Evan=系统
admin;PROJECT_EVENT public 项目,minio_bucket=ms-dev);env=dev。
"""
from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import Any

import pytest
from httpx import ASGITransport, AsyncClient

from app.db.session import get_sessionmaker
from app.db.tables import AuditEvent, Folder, Group, User
from app.main import create_app
from app.services.audit import AuditService

EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"        # 系统 admin(seed 契约账号)
PROJECT_EVENT = "11111111-1111-1111-1111-111111111103"  # public,bucket=ms-dev

AUDIT_URL = "/api/v1/admin/audit"
DEDUP_PREFIX = "zz_cnames:"  # 本文件造数事件的 dedup_key 前缀(teardown 清理标记)


def _h(uid: str = EVAN_ID) -> dict[str, str]:
    return {"X-User-Id": uid}


@pytest.fixture(scope="session")
async def app_with_lifespan():
    app = create_app()
    async with app.router.lifespan_context(app):  # type: ignore[attr-defined]
        yield app


@pytest.fixture(scope="session")
async def client(app_with_lifespan):
    transport = ASGITransport(app=app_with_lifespan)  # type: ignore[arg-type]
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


# ─── 造数辅助 ──────────────────────────────────────────────────────────────────
async def _make_folder(client: AsyncClient, name: str) -> dict:
    r = await client.post(
        "/api/v1/folders",
        json={"project_id": PROJECT_EVENT, "name": name},
        headers=_h(),
    )
    assert r.status_code == 201, r.text
    return r.json()


async def _write_event(**kw: Any) -> AuditEvent:
    """经 AuditService.write 直写一条审计事件(生产唯一写入收口),
    dedup_key 统一加本文件前缀便于 teardown。返回含 id 的行。"""
    async with get_sessionmaker()() as db:
        svc = AuditService(db)
        return await svc.write(
            dedup_key=f"{DEDUP_PREFIX}{uuid.uuid4().hex}", **kw
        )


async def _physically_delete_folder(folder_id: str) -> None:
    """folder 行物理删(夹内无 asset,无 FK 阻碍;模拟「授权目录已被删」)。"""
    async with get_sessionmaker()() as db:
        await db.execute(
            Folder.__table__.delete().where(Folder.id == uuid.UUID(folder_id))
        )
        await db.commit()


async def _audit_row(client: AsyncClient, *, event_id: str, event_type: str,
                     t0: datetime) -> dict:
    """按 event_type+from 拉列表,用事件 id 精确命中本测试造的那一行。"""
    r = await client.get(
        AUDIT_URL,
        params={"event_type": event_type, "from": t0.isoformat(), "limit": 500},
        headers=_h(),
    )
    assert r.status_code == 200, r.text
    mine = [e for e in r.json() if e["id"] == event_id]
    assert mine, f"应命中本测试写入的 {event_type} 事件 id={event_id}"
    return mine[-1]


@pytest.fixture(scope="module")
async def world(client: AsyncClient) -> Any:
    """module 级造数:4 夹(API)+ 4 用户/2 组(DB 直插)+ 7 类事件(write 直写),
    details 形态逐字段对齐生产写入点;teardown 清事件/夹/用户/组。"""
    tag = uuid.uuid4().hex[:8]

    f_grant = await _make_folder(client, f"zz_cnames_grant_{tag}")
    f_old = await _make_folder(client, f"zz_cnames_old_{tag}")
    f_new = await _make_folder(client, f"zz_cnames_new_{tag}")
    f_target = await _make_folder(client, f"zz_cnames_target_{tag}")

    async with get_sessionmaker()() as db:
        u_subject = User(id=uuid.uuid4(), name=f"主体用户_{tag}")
        u_sharer = User(id=uuid.uuid4(), name=f"分享人_{tag}")
        u_member = User(id=uuid.uuid4(), name=f"组成员_{tag}",
                        username=f"zz_cnames_m_{tag}")
        u_updated = User(id=uuid.uuid4(), name=f"被编辑用户_{tag}")
        g_main = Group(id=uuid.uuid4(), name=f"主体用户组_{tag}")
        g_member = Group(id=uuid.uuid4(), name=f"成员组_{tag}")
        db.add_all([u_subject, u_sharer, u_member, u_updated, g_main, g_member])
        await db.commit()

    # 生产 details 形态参照:folders.py:1224(folder_grant_added)
    ev_grant = await _write_event(
        event_type="folder_grant_added", actor_user_id=uuid.UUID(EVAN_ID),
        target_project_id=uuid.UUID(PROJECT_EVENT),
        details={"folder_id": f_grant["id"],
                 "subject": f"user:{u_subject.id}", "level": "viewer"},
    )
    # projects.py:299(project_member_added,组主体)
    ev_pmemb = await _write_event(
        event_type="project_member_added", actor_user_id=uuid.UUID(EVAN_ID),
        target_project_id=uuid.UUID(PROJECT_EVENT),
        details={"subject": f"group:{g_main.id}#member", "role": "editor",
                 "kind": "member", "via": "initial_grants"},
    )
    # folders.py:498(folder_moved,双父目录键)
    ev_moved = await _write_event(
        event_type="folder_moved", actor_user_id=uuid.UUID(EVAN_ID),
        target_project_id=uuid.UUID(PROJECT_EVENT),
        details={"name": f_grant["name"],
                 "old_parent_folder_id": f_old["id"],
                 "new_parent_folder_id": f_new["id"], "fga_swap": "ok"},
    )
    # baidu_backup.py:822(baidu_task_create,target_folder_id)
    ev_baidu = await _write_event(
        event_type="baidu_task_create", actor_user_id=uuid.UUID(EVAN_ID),
        target_project_id=uuid.UUID(PROJECT_EVENT),
        details={"task_id": str(uuid.uuid4()), "source_dir": f"/zz_cnames/{tag}",
                 "target_folder_id": f_target["id"],
                 "target_auto_created": False, "dispatch_seq": 1},
    )
    # user_provisioning.py:83(group_member_added,行内自带 group_name/username)
    ev_gmemb = await _write_event(
        event_type="group_member_added", actor_user_id=uuid.UUID(EVAN_ID),
        details={"group_id": str(g_member.id), "group_name": g_member.name,
                 "user_id": str(u_member.id), "username": u_member.username},
    )
    # share_service.py:64(share_link_created,sharer_user_id)
    ev_share = await _write_event(
        event_type="share_link_created", actor_user_id=uuid.UUID(EVAN_ID),
        target_project_id=uuid.UUID(PROJECT_EVENT),
        details={"kind": "folder", "target_id": f_target["id"],
                 "token": f"zz_cnames_token_{tag}", "expires_at": "2027-01-01T00:00:00Z",
                 "requires_login": True, "sharer_user_id": str(u_sharer.id)},
    )
    # directory.py:348(user_updated,changes.groups_added 对象数组)
    ev_uupd = await _write_event(
        event_type="user_updated", actor_user_id=uuid.UUID(EVAN_ID),
        details={"user_id": str(u_updated.id), "username": None,
                 "changes": {
                     "name": {"old": f"旧名_{tag}", "new": f"新名_{tag}"},
                     "groups_added": [{"group_id": str(g_member.id),
                                       "group_name": g_member.name}],
                     "groups_removed": [],
                 }},
    )

    w: dict[str, Any] = {
        "tag": tag,
        "folders": {"grant": f_grant, "old": f_old, "new": f_new,
                    "target": f_target},
        "users": {"subject": u_subject, "sharer": u_sharer,
                  "member": u_member, "updated": u_updated},
        "groups": {"main": g_main, "member": g_member},
        "events": {"grant": ev_grant, "pmemb": ev_pmemb, "moved": ev_moved,
                   "baidu": ev_baidu, "gmemb": ev_gmemb, "share": ev_share,
                   "uupd": ev_uupd},
    }
    try:
        yield w
    finally:
        # 清场顺序:事件 → 夹 → 用户/组(事件行先删,避免依赖 SET NULL 行为)
        async with get_sessionmaker()() as db:
            await db.execute(
                AuditEvent.__table__.delete().where(
                    AuditEvent.dedup_key.like(f"{DEDUP_PREFIX}%"))
            )
            await db.commit()
        async with get_sessionmaker()() as db:
            for f in w["folders"].values():
                await db.execute(
                    Folder.__table__.delete().where(Folder.id == uuid.UUID(f["id"]))
                )
            for u in w["users"].values():
                await db.execute(
                    User.__table__.delete().where(User.id == u.id)
                )
            for g in w["groups"].values():
                await db.execute(
                    Group.__table__.delete().where(Group.id == g.id)
                )
            await db.commit()


# ─── §3.3-1 白名单各键补名(7 类事件逐一对账)────────────────────────────────────
@pytest.mark.asyncio
async def test_folder_grant_added_resolves_folder_and_user_subject(
    client: AsyncClient, world: dict,
) -> None:
    """folder_grant_added:folder_id→目录名;subject(user:)<uuid>→用户纯名称,
    不带「(用户)」后缀(类型标注由前端渲染);details 原始串原样保留。"""
    ev = world["events"]["grant"]
    row = await _audit_row(client, event_id=str(ev.id),
                           event_type="folder_grant_added",
                           t0=ev.event_time)
    rn = row["resolved_names"]
    assert rn["folder_id"] == world["folders"]["grant"]["name"], row
    assert rn["subject"] == world["users"]["subject"].name, row
    # 契约:后端补名是纯名称,不拼类型后缀
    assert "(用户)" not in rn["subject"] and "(用户组)" not in rn["subject"], row
    # 原始 subject 串不丢(溯源 + 前端类型标注依赖原始前缀)
    assert row["details"]["subject"] == f"user:{world['users']['subject'].id}", row


@pytest.mark.asyncio
async def test_project_member_added_group_subject_pure_name(
    client: AsyncClient, world: dict,
) -> None:
    """project_member_added:subject(group:<uuid>#member)→组名纯名称,
    #member 后缀被剥掉,不出现「(用户组)」字样。"""
    ev = world["events"]["pmemb"]
    row = await _audit_row(client, event_id=str(ev.id),
                           event_type="project_member_added",
                           t0=ev.event_time)
    rn = row["resolved_names"]
    assert rn["subject"] == world["groups"]["main"].name, row
    assert "(用户组)" not in rn["subject"], row
    assert row["details"]["subject"] == f"group:{world['groups']['main'].id}#member", row


@pytest.mark.asyncio
async def test_folder_moved_resolves_both_parent_keys(
    client: AsyncClient, world: dict,
) -> None:
    """folder_moved:old/new_parent_folder_id 双键均进 folder 桶同一次 IN 补名。"""
    ev = world["events"]["moved"]
    row = await _audit_row(client, event_id=str(ev.id),
                           event_type="folder_moved",
                           t0=ev.event_time)
    rn = row["resolved_names"]
    assert rn["old_parent_folder_id"] == world["folders"]["old"]["name"], row
    assert rn["new_parent_folder_id"] == world["folders"]["new"]["name"], row


@pytest.mark.asyncio
async def test_baidu_task_create_resolves_target_folder(
    client: AsyncClient, world: dict,
) -> None:
    """baidu_task_create:target_folder_id→目录名;task_id 一期不补
    (正本 §3.2 白名单制,有 source_dir 兜底),不进 resolved_names。"""
    ev = world["events"]["baidu"]
    row = await _audit_row(client, event_id=str(ev.id),
                           event_type="baidu_task_create",
                           t0=ev.event_time)
    rn = row["resolved_names"]
    assert rn["target_folder_id"] == world["folders"]["target"]["name"], row
    assert "task_id" not in rn, row  # 一期白名单不含 task_id


@pytest.mark.asyncio
async def test_group_member_added_inline_names_unaffected(
    client: AsyncClient, world: dict,
) -> None:
    """group_member_added:行内已带 group_name/username 的既有行不受影响
    (原样透传),同时 group_id/user_id 照常进 resolved_names。"""
    ev = world["events"]["gmemb"]
    row = await _audit_row(client, event_id=str(ev.id),
                           event_type="group_member_added",
                           t0=ev.event_time)
    rn = row["resolved_names"]
    assert rn["group_id"] == world["groups"]["member"].name, row
    assert rn["user_id"] == world["users"]["member"].name, row
    assert row["details"]["group_name"] == world["groups"]["member"].name, row
    assert row["details"]["username"] == world["users"]["member"].username, row


@pytest.mark.asyncio
async def test_share_link_created_resolves_sharer(
    client: AsyncClient, world: dict,
) -> None:
    """share_link_created:sharer_user_id→用户名(details.token 原样,决策 D-C2)。"""
    ev = world["events"]["share"]
    row = await _audit_row(client, event_id=str(ev.id),
                           event_type="share_link_created",
                           t0=ev.event_time)
    assert row["resolved_names"]["sharer_user_id"] == world["users"]["sharer"].name, row
    assert row["details"]["token"] == f"zz_cnames_token_{world['tag']}", row


@pytest.mark.asyncio
async def test_user_updated_object_array_passthrough(
    client: AsyncClient, world: dict,
) -> None:
    """user_updated:details.changes.groups_added 是对象数组 —— 契约是
    **原样透传不拆不改**(逐字段展开渲染归前端 C4,后端不得打平/串化),
    顶层 user_id 键照常补名。"""
    ev = world["events"]["uupd"]
    row = await _audit_row(client, event_id=str(ev.id),
                           event_type="user_updated",
                           t0=ev.event_time)
    changes = row["details"]["changes"]
    assert changes["groups_added"] == [
        {"group_id": str(world["groups"]["member"].id),
         "group_name": world["groups"]["member"].name},
    ], row
    assert row["resolved_names"]["user_id"] == world["users"]["updated"].name, row


# ─── §3.3-2 已删除对象:键不进 resolved_names,接口不报错 ────────────────────────
@pytest.mark.asyncio
async def test_deleted_folder_key_not_resolved(
    client: AsyncClient, world: dict,
) -> None:
    """grant 的 folder 物理删后:该行 details.folder_id 仍在(JSON 快照),
    但 folders 行已消失 → folder_id 不进 resolved_names,接口 200 不报错。"""
    tag = uuid.uuid4().hex[:8]
    folder = await _make_folder(client, f"zz_cnames_del_{tag}")
    ev = await _write_event(
        event_type="folder_grant_added", actor_user_id=uuid.UUID(EVAN_ID),
        target_project_id=uuid.UUID(PROJECT_EVENT),
        details={"folder_id": folder["id"],
                 "subject": "user:00000000-0000-0000-0000-0000000000c0",
                 "level": "viewer"},
    )
    # 删除前:补名在
    row = await _audit_row(client, event_id=str(ev.id),
                           event_type="folder_grant_added",
                           t0=ev.event_time)
    assert row["resolved_names"].get("folder_id") == folder["name"], row

    await _physically_delete_folder(folder["id"])

    # 删除后:该键回落(不进 dict),接口不报错
    row = await _audit_row(client, event_id=str(ev.id),
                           event_type="folder_grant_added",
                           t0=ev.event_time)
    assert "folder_id" not in row["resolved_names"], row
    assert row["details"]["folder_id"] == folder["id"], row  # 原值仍可溯源
    # subject 指向不存在的用户(found=False)→ 同口径不进
    assert "subject" not in row["resolved_names"], row


# ─── §3.3-3 details 垃圾值:静默跳过,不 500 ────────────────────────────────────
@pytest.mark.asyncio
async def test_garbage_values_skipped_without_500(
    client: AsyncClient, world: dict,
) -> None:
    """details 白名单键塞非 UUID 垃圾值:try-UUID 解析失败静默跳过,
    list 接口 200,垃圾键不进 resolved_names。"""
    ev = await _write_event(
        event_type="folder_grant_added", actor_user_id=uuid.UUID(EVAN_ID),
        details={"folder_id": "not-a-uuid",
                 "subject": "user:also-not-a-uuid", "level": "viewer"},
    )
    row = await _audit_row(client, event_id=str(ev.id),
                           event_type="folder_grant_added",
                           t0=ev.event_time)
    assert "folder_id" not in row["resolved_names"], row
    assert "subject" not in row["resolved_names"], row  # found=False 不进
    assert row["details"]["folder_id"] == "not-a-uuid", row  # 原样透传


# ─── §3.3-5 + C2 user_agent:透传 / 512 截断 / 空值 ─────────────────────────────
@pytest.mark.asyncio
async def test_user_agent_passthrough(
    client: AsyncClient, world: dict,
) -> None:
    """AuditOut 新增 user_agent 裸列透传:写入什么返回什么。"""
    ua = "zz-cnames-ua/1.0 (pytest; inapp-tip) MicroMessenger/8.0.49"
    ev = await _write_event(
        event_type="folder_grant_added", actor_user_id=uuid.UUID(EVAN_ID),
        user_agent=ua,
        details={"level": "viewer"},
    )
    row = await _audit_row(client, event_id=str(ev.id),
                           event_type="folder_grant_added",
                           t0=ev.event_time)
    assert row["user_agent"] == ua, row


@pytest.mark.asyncio
async def test_user_agent_truncated_to_512(
    client: AsyncClient, world: dict,
) -> None:
    """C2:write 收口 user_agent[:512] 截断 —— 超长 UA(directory.py 9 处直读
    header 的写入路径同样经过 write)不炸 insert,列宽 String(512) 对齐。"""
    ev = await _write_event(
        event_type="folder_grant_added", actor_user_id=uuid.UUID(EVAN_ID),
        user_agent="A" * 600,
        details={"level": "viewer"},
    )
    row = await _audit_row(client, event_id=str(ev.id),
                           event_type="folder_grant_added",
                           t0=ev.event_time)
    assert row["user_agent"] == "A" * 512, (
        f"超长 UA 应被截到 512,实际 len={len(row['user_agent'] or '')}")


@pytest.mark.asyncio
async def test_user_agent_none_and_resolved_names_default(
    client: AsyncClient, world: dict,
) -> None:
    """§3.3-4/5 兜底口径:details 无任何白名单键 + user_agent 为 NULL 的行
    → resolved_names 恒为 dict(空 dict 也在位,向后兼容旧调用方),
    user_agent 回 null。"""
    ev = await _write_event(
        event_type="folder_grant_added", actor_user_id=uuid.UUID(EVAN_ID),
        user_agent=None,
        details={"note": "nothing to resolve", "level": "viewer"},
    )
    row = await _audit_row(client, event_id=str(ev.id),
                           event_type="folder_grant_added",
                           t0=ev.event_time)
    assert row["resolved_names"] == {}, row
    assert row["user_agent"] is None, row


# ─── §3.3-6 回归:分页/过滤行为不变,新旧字段共存 ────────────────────────────────
@pytest.mark.asyncio
async def test_list_pagination_and_filter_regression(
    client: AsyncClient, world: dict,
) -> None:
    """event_type 过滤 + limit/offset 分页共存:行为与改动前一致(命中行全匹配
    过滤、数量受 limit 约束),且每行都带 resolved_names / user_agent 新字段。"""
    r = await client.get(
        AUDIT_URL,
        params={"event_type": "folder_grant_added",
                "from": world["events"]["grant"].event_time.isoformat(),
                "limit": 1, "offset": 0},
        headers=_h(),
    )
    assert r.status_code == 200, r.text
    rows = r.json()
    assert len(rows) <= 1, rows
    assert all(e["event_type"] == "folder_grant_added" for e in rows), rows
    for e in rows:
        assert "resolved_names" in e and isinstance(e["resolved_names"], dict), e
        assert "user_agent" in e, e


# ─── CSV 导出不动(D-C1)────────────────────────────────────────────────────────
@pytest.mark.asyncio
async def test_csv_export_unchanged_columns(
    client: AsyncClient, world: dict,
) -> None:
    """CSV 导出端点不动:200 可用且**不含** resolved_names / user_agent 新列
    (details_json 原样 dump;表头拼写锁 W2b 既有列序)。"""
    import csv as _csv
    import io as _io

    r = await client.get(
        "/api/v1/admin/audit/export.csv",
        params={"event_type": "folder_grant_added",
                "from": world["events"]["grant"].event_time.isoformat()},
        headers=_h(),
    )
    assert r.status_code == 200, r.text
    rows = list(_csv.reader(_io.StringIO(r.content.decode("utf-8-sig"))))
    header = rows[0]
    assert "resolved_names" not in header and "user_agent" not in header, header
    assert "details_json" in header, header
