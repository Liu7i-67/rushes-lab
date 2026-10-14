"""组长建项目内嵌创建艺人账号(artist account inline)— 集成测试,跑在 api 容器里。

对应权威技术方案:`rushes-spec/material-storage/project-artist-account-plan.md`
§7(测试功能点,本文件用例按其五组分节)+ §1(D1-D13)/§4(接口契约)。

契约要点(实现并行开发中,本文件按契约编写,两处冲突以方案为准):
  - POST /api/v1/projects 增可选 `artist_account: {username, name}` → 201 响应
    为 ProjectCreatedOut(= ProjectOut + `artist_account.{user_id, username,
    name, temporary_password}`;不传时该键恒为 null);执行顺序 = 能力校验(403
    零审计)→ 用户名 lower 预检(409 {code,username} 零审计)→ 建项目 → ensure
    「艺人」组 → provision → 逐角色授 uploader/downloader/viewer;竞态 409
    detail 结构化 {code:"username_taken", username, project_id}
  - GET /api/v1/users/username-available(守门 require_inline_artist_creator
    = is_org_admin,或 (is_org_project_creator 且 is_org_artist_account_creator))
  - 组管理第 4 flag `can_create_artist_account`(POST 置位 / PATCH tri-state /
    POST 与列表两态回显 / 删组顺手清 tuple);/me 增 is_artist_account_creator
  - 管理后台建号薄壳化:user_created details 增 source="admin_create";重名
    预检改 lower 匹配(case 变体从 201 变 409,有意变更);入组审计 source
    保持 "user_create" 原值不变

预期前置(同 test_project_creator.py):
  1. seed_demo_data.py 已跑过(Evan = 真 user + org admin,username="evan";
     outsider = fake 零权限)
  2. 本地隔离栈已带新 FGA model:`bash api/scripts/local_up.sh --refresh-model`
     (含 organization#artist_account_creator relation;⚠ 勿跑
     openfga_write_model.sh —— 那是远端 hh2 部署脚本,不是本地栈用的)
  3. env=dev(允许 X-User-Id header 模拟身份)

运行方式(容器内;host 上跑无 DB/FGA 必挂):
  docker exec <api容器> pytest tests/test_project_artist_account.py -v
  (feat-ms 隔离栈容器 recreate 后 pip 层丢失须先重装依赖;拷测试进容器用
   docker cp,Git Bash 传容器路径加 MSYS_NO_PATHCONV=1)

跨 run 卫生:「艺人」组在共享 feat-ms 栈上持久,若不清理,「首次自动建组」
类断言(group_created audit / description)第二轮必挂 —— 相关用例 setup 先
DELETE 同名组并容忍 404(首轮栈上组不存在),见 _cleanup_artist_group。
"""
from __future__ import annotations

import re
import uuid

import pytest
from fastapi import HTTPException
from httpx import ASGITransport, AsyncClient
from sqlalchemy.exc import IntegrityError

from app.main import create_app

# seed 写死的真 user / fake outsider(同 test_project_creator.py;与 seed_demo_data 同源)
EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"      # username="evan",org admin
OUTSIDER_ID = "00000000-0000-0000-0000-0000000000aa"  # 零权限

# ── 契约常量(方案 §1/§4/§7;实现漂移在此响亮失败,勿为迁就实现改这里)────────
INLINE_SOURCE = "project_artist_inline"   # 内嵌链路三类审计统一 source(方案 D7)
ADMIN_SOURCE = "admin_create"             # 管理后台 user_created source(方案 D7)
USER_CREATE_SOURCE = "user_create"        # admin 入组审计 source 原值不变(方案 D7)
VIA_ARTIST_INLINE = "artist_inline"       # project_member_added 的 via(方案 D8)
USERNAME_TAKEN_CODE = "username_taken"    # 结构化 409 detail.code(方案 §4.1)
ARTIST_GROUP_NAME = "艺人"                # ensure 按名 get-or-create(方案 D5)
# 方案 §1-D5 的组描述字面量(全角冒号);实现换文案 = 契约变更,须回改方案
ARTIST_GROUP_DESCRIPTION = "系统自动创建：新建项目时内嵌开通的艺人账号默认归入此组"  # noqa: RUF001
ADMIN_DUP_409_PREFIX = "登录名已存在:"    # admin 链路重名 409 文案(方案 §7:文案不变)
INLINE_403_COPY = "无内嵌创建艺人账号权限"  # 端点内 artist 能力校验 403 文案(§4.1 阶段 2)
# PG unique 冲突真实文案形状(方案 §7 竞态②):收窄判据即此串含 "uq_users_username",
# 实现判据写错(如抄 projects 的自动命名机制)则竞态路径变 500 死代码,本文件钉住
UQ_USERS_USERNAME_MSG = 'duplicate key value violates unique constraint "uq_users_username"'
# 组级 4 个 org flag relation(方案 D5 零权限论点 =「艺人」组四 relation 全无)
ORG_FLAG_RELATIONS = (
    "project_creator", "project_deleter", "folder_template_manager",
    "artist_account_creator",
)
# 临时密码形状:12 位,去易混淆字符(app/services/passwords.py:大写去 I/O、
# 小写去 l/o、数字去 0/1,无符号)—— 12 位全字符集断言,非空 + 长度 + 字符集一起钉
TEMP_PASSWORD_RE = re.compile(r"^[A-HJ-NP-Za-km-np-z2-9]{12}$")


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


def _uniq(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:8]}"


def _project_code() -> str:
    """项目 code 唯一(projects_code_key);pattern 限 ^[a-z0-9][a-z0-9\\-]*$。"""
    return f"paa-{uuid.uuid4().hex[:12]}"


def _project_body(
    code: str, name: str, admin_uid: str, *,
    artist: dict | None = None, initial_grants: list | None = None,
) -> dict:
    """POST /projects body 构造(minio_bucket 按前端固定值 ms-dev)。"""
    body: dict = {
        "code": code, "name": name, "minio_bucket": "ms-dev", "admin_user_id": admin_uid,
    }
    if artist is not None:
        body["artist_account"] = artist
    if initial_grants is not None:
        body["initial_grants"] = initial_grants
    return body


# ─── 测试内现建辅助(seed 不写 groups 表数据,组一律测试内现建:真实 UUID+name)──
async def _create_group(
    client: AsyncClient, *, prefix: str = "paa_grp",
    can_create_project: bool = False, can_create_artist_account: bool = False,
) -> tuple[str, str]:
    """现建目录组(照 test_directory.py 写法),可携带组级 flag → (gid, name)。

    name 一并返回:组列表回显断言(_list_group_echo 按 name 定向查)必须用
    **真实组名**,不能另造一套随机名 —— 名字不一致时 q 查无此组,echo 断言
    以 None 失败(首跑回归教训)。
    """
    name = _uniq(prefix)
    body: dict = {"name": name, "description": "artist_account 测试组"}
    if can_create_project:
        body["can_create_project"] = True
    if can_create_artist_account:
        body["can_create_artist_account"] = True
    r = await client.post("/api/v1/admin/directory/groups", json=body, headers=_h(EVAN_ID))
    assert r.status_code == 201, r.text
    return r.json()["id"], name


async def _create_user(client: AsyncClient, prefix: str = "paa_user") -> str:
    """现建 active 本地用户 → users.id。"""
    uname = _uniq(prefix)
    r = await client.post(
        "/api/v1/admin/directory/users",
        json={"username": uname, "name": f"PAA {prefix}"},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text
    return r.json()["id"]


async def _add_group_member(client: AsyncClient, gid: str, uid: str) -> None:
    r = await client.post(
        f"/api/v1/admin/directory/groups/{gid}/members",
        json={"user_id": uid}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text


async def _remove_group_member(client: AsyncClient, gid: str, uid: str) -> None:
    r = await client.delete(
        f"/api/v1/admin/directory/groups/{gid}/members/{uid}", headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text


async def _delete_group(client: AsyncClient, gid: str) -> None:
    r = await client.delete(f"/api/v1/admin/directory/groups/{gid}", headers=_h(EVAN_ID))
    assert r.status_code in (200, 404), r.text


async def _both_flag_leader(client: AsyncClient, prefix: str = "paa_lead") -> tuple[str, str]:
    """双 flag 组长(内嵌建号前置):建组(can_create_project + can_create_artist_account
    双 true)+ 建用户 + 入组 → (gid, uid)。"""
    gid, _leader_gname = await _create_group(
        client, prefix=prefix, can_create_project=True, can_create_artist_account=True,
    )
    uid = await _create_user(client, f"{prefix}_u")
    await _add_group_member(client, gid, uid)
    return gid, uid


async def _archive_project(pid: str) -> None:
    """归档自建项目(收尾专用):项目无删除 API,is_archived=True 后不再进
    GET /projects 列表,防多轮全量累积把 seed 项目挤出第一页。DB 直写照
    test_project_creator._archive_project 惯例;失败吞掉 + warning,不掩盖原断言。"""
    import warnings

    from sqlalchemy import update

    from app.db.session import get_sessionmaker
    from app.db.tables import Project

    try:
        async with get_sessionmaker()() as db:
            await db.execute(
                update(Project)
                .where(Project.id == uuid.UUID(pid))
                .values(is_archived=True)
            )
            await db.commit()
    except Exception as e:
        warnings.warn(f"archive project {pid} failed: {e}; 残留活跃项目", stacklevel=2)


async def _default_org() -> tuple[str, str]:
    """default org 的 (org_id, tenant_key) —— OpenFGA organization object 用 tenant_key。"""
    from app.db.session import get_sessionmaker
    from app.services.org import get_default_organization

    async with get_sessionmaker()() as db:
        org = await get_default_organization(db)
    assert org is not None, "测试前置:settings.default_organization_id 未配置"
    return str(org[0]), org[1]


# ─── DB 直读/直写辅助(get_sessionmaker 惯例,照 _archive_project)─────────────
async def _row_count(model) -> int:
    """表行数(零副作用断言用)。"""
    from sqlalchemy import func, select

    from app.db.session import get_sessionmaker

    async with get_sessionmaker()() as db:
        return (await db.execute(select(func.count()).select_from(model))).scalar_one()


async def _project_row_exists(code: str) -> bool:
    from sqlalchemy import select

    from app.db.session import get_sessionmaker
    from app.db.tables import Project

    async with get_sessionmaker()() as db:
        row = (await db.execute(select(Project.id).where(Project.code == code))).first()
    return row is not None


async def _project_id_by_code(code: str) -> str:
    """按 code 反查项目 id(竞态 500 路径响应无 project_id,收尾归档用)。"""
    from sqlalchemy import select

    from app.db.session import get_sessionmaker
    from app.db.tables import Project

    async with get_sessionmaker()() as db:
        row = (await db.execute(select(Project.id).where(Project.code == code))).first()
    assert row is not None, f"项目行应存在: {code}"
    return str(row[0])


async def _get_user_by_username(username: str):
    from sqlalchemy import select

    from app.db.session import get_sessionmaker
    from app.db.tables import User

    async with get_sessionmaker()() as db:
        res = await db.execute(select(User).where(User.username == username))
        return res.scalar_one_or_none()


async def _get_group_by_name(name: str):
    from sqlalchemy import select

    from app.db.session import get_sessionmaker
    from app.db.tables import Group

    async with get_sessionmaker()() as db:
        res = await db.execute(select(Group).where(Group.name == name))
        return res.scalar_one_or_none()


async def _artist_group_count() -> int:
    """名为「艺人」的组行数(复用断言:二次走流程计数不增)。"""
    from sqlalchemy import func, select

    from app.db.session import get_sessionmaker
    from app.db.tables import Group

    async with get_sessionmaker()() as db:
        return (await db.execute(
            select(func.count()).select_from(Group).where(Group.name == ARTIST_GROUP_NAME),
        )).scalar_one()


async def _membership_exists(gid: str, uid: str) -> bool:
    from sqlalchemy import select

    from app.db.session import get_sessionmaker
    from app.db.tables import GroupMembership

    async with get_sessionmaker()() as db:
        row = (await db.execute(
            select(GroupMembership).where(
                GroupMembership.group_id == uuid.UUID(gid),
                GroupMembership.user_id == uuid.UUID(uid),
            )
        )).first()
    return row is not None


async def _audit_count() -> int:
    """audit_events 全库行数(「守门/预检不写审计」的窗口前后计数用)。"""
    from sqlalchemy import func, select

    from app.db.session import get_sessionmaker
    from app.db.tables import AuditEvent

    async with get_sessionmaker()() as db:
        return (await db.execute(select(func.count()).select_from(AuditEvent))).scalar_one()


async def _audit_event_types_containing(needle: str) -> list[str]:
    """全库扫 audit_events.details(JSONB)文本是否含 needle → 命中的 event_type 列表。

    一次性密码语义(方案 §7):details 是审计事件唯一自由文本载体,cast 成
    VARCHAR 做 LIKE 全库扫描;密码字符集为纯字母数字,无 LIKE 通配符转义问题。
    """
    from sqlalchemy import String, cast, select

    from app.db.session import get_sessionmaker
    from app.db.tables import AuditEvent

    async with get_sessionmaker()() as db:
        res = await db.execute(
            select(AuditEvent.event_type)
            .where(cast(AuditEvent.details, String).like(f"%{needle}%"))
        )
        return [row[0] for row in res.all()]


async def _insert_user_raw(username: str, name: str) -> str:
    """DB 直插用户(绕过 API 与预检)→ users.id。

    为何绕 API(方案 §7 存量共存对):lower 预检上线后,管理后台/内嵌链路都
    造不出「evan/Evan」大小写共存对(API 路径 409),而该共存对正是钉住
    「limit(1)+first 消费语义,防 scalar_one_or_none 的 MultipleResultsFound
    500」的必要构造。直写照 _archive_project 的 get_sessionmaker 惯例。
    勿「顺手」改成走 API —— API 路径已造不出共存对,改掉即测试失效。
    """
    from app.db.session import get_sessionmaker
    from app.db.tables import User

    async with get_sessionmaker()() as db:
        u = User(username=username, name=name)
        db.add(u)
        await db.commit()
        await db.refresh(u)
        return str(u.id)


async def _delete_user_rows_by_username(username: str) -> int:
    """按 username 物理删 users 行(共存对直插行的收尾;group_memberships 级联、
    audit actor SET NULL,无残留)。返回删除行数。"""
    from sqlalchemy import delete

    from app.db.session import get_sessionmaker
    from app.db.tables import User

    async with get_sessionmaker()() as db:
        res = await db.execute(delete(User).where(User.username == username))
        await db.commit()
        return res.rowcount


# ─── audit API / FGA 读辅助 ───────────────────────────────────────────────────
async def _cleanup_artist_group(client: AsyncClient) -> None:
    """跨 run 卫生(方案 §7):删除遗留的「艺人」组,容忍 404(首轮栈上组不存在)。

    「艺人」组在共享 feat-ms 栈上持久;不清理则「首次自动建组」断言第二轮必挂。
    DELETE /admin/directory/groups/{id} 连带清成员关系与组主体 tuple
    (directory.py 删组流程)。
    """
    r = await client.get(
        "/api/v1/admin/directory/groups",
        params={"q": ARTIST_GROUP_NAME, "limit": 200}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    for g in r.json():
        if g["name"] != ARTIST_GROUP_NAME:
            continue
        rd = await client.delete(
            f"/api/v1/admin/directory/groups/{g['id']}", headers=_h(EVAN_ID),
        )
        assert rd.status_code in (200, 404), rd.text


async def _audit_events(
    client: AsyncClient, event_type: str, *,
    actor_user_id: str | None = None, project_id: str | None = None,
) -> list[dict]:
    """按 event_type(+actor/project)拉 audit 原始条目(details 在 "details" 键)。"""
    params: dict[str, object] = {"event_type": event_type, "limit": 500}
    if actor_user_id is not None:
        params["actor_user_id"] = actor_user_id
    if project_id is not None:
        params["project_id"] = project_id
    r = await client.get("/api/v1/admin/audit", params=params, headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    return r.json()


async def _group_audit_details_list(
    client: AsyncClient, event_type: str, gid: str, actor_user_id: str = EVAN_ID,
) -> list[dict]:
    """按 event_type + actor 拉 audit,返回 details.group_id == gid 的全部条目。"""
    events = await _audit_events(client, event_type, actor_user_id=actor_user_id)
    return [
        e.get("details") or {} for e in events
        if (e.get("details") or {}).get("group_id") == gid
    ]


async def _list_group_echo(client: AsyncClient, gid: str, name: str) -> dict | None:
    """组列表按唯一 name 取回(回显真实 tuple 态;无组详情路由,编辑数据源即列表)。"""
    r = await client.get(
        "/api/v1/admin/directory/groups", params={"q": name}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    hits = [g for g in r.json() if g["id"] == gid]
    return hits[0] if hits else None


async def _artist_flag_on(perms, gid: str, tenant_key: str) -> bool:
    """组主体是否持有 organization#artist_account_creator(组主体直查,check 自动展开)。"""
    return await perms.check(
        user_subject=f"group:{gid}#member", relation="artist_account_creator",
        object_type="organization", object_id=tenant_key,
    )


async def _read_org_tuple_exact(perms, gid: str, tenant_key: str, relation: str) -> list:
    """全键 read 精确匹配组主体 tuple(user=group:<gid>#member)。

    check 只能回答「有/无」,无法证明 tuple 的 user 恰为组主体;部分键 read
    该 SDK/服务端不支持(test_directory.py 已有结论),故用全键 read
    (照 test_project_creator._read_creator_tuple_exact;SDK tuple 字段在 .key 下)。
    """
    from openfga_sdk.models import ReadRequestTupleKey

    resp = await perms._client.read(ReadRequestTupleKey(  # type: ignore[attr-defined]
        user=f"group:{gid}#member", relation=relation,
        object=f"organization:{tenant_key}",
    ))
    return list(resp.tuples)


# ══════════════════════════════════════════════════════════════════════════════
# 第一组:组开关与 /me(方案 §7「组开关与 /me」)
# ══════════════════════════════════════════════════════════════════════════════
@pytest.mark.asyncio
async def test_group_artist_flag_create_echoes_tuple_and_audit(
    client: AsyncClient, app_with_lifespan,
) -> None:
    """建组 can_create_artist_account=true → POST 响应与组列表两态均回显 true
    (钉住 §4.3 三处消费点之 POST 响应与列表定向 read);organization#
    artist_account_creator 有组主体 tuple(全键 read 精确匹配);group_created
    audit details 带 can_create_project=True。"""
    perms = app_with_lifespan.state.permissions
    _, tenant_key = await _default_org()

    gname = _uniq("paa_flag")
    r = await client.post(
        "/api/v1/admin/directory/groups",
        json={"name": gname, "can_create_artist_account": True},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text
    body = r.json()
    gid = body["id"]
    try:
        # POST 响应按入参回显(§4.3:漏掉该消费点则建组置 true 的响应谎报 false)
        assert body["can_create_artist_account"] is True, body

        # tuple 就位:组主体 check 命中 + 全键 read 精确匹配
        assert await _artist_flag_on(perms, gid, tenant_key) is True
        tuples = await _read_org_tuple_exact(perms, gid, tenant_key, "artist_account_creator")
        assert len(tuples) == 1, tuples
        assert tuples[0].key.user == f"group:{gid}#member"
        assert tuples[0].key.relation == "artist_account_creator"
        assert tuples[0].key.object == f"organization:{tenant_key}"

        # 组列表回显真实态(定向 read;另一处消费点)
        echo = await _list_group_echo(client, gid, gname)
        assert echo is not None, f"组列表应能按 name 找到: {gname}"
        assert echo["can_create_artist_account"] is True, echo

        # group_created audit details 带该键
        events = await _group_audit_details_list(client, "group_created", gid)
        assert len(events) == 1, events
        assert events[0]["can_create_artist_account"] is True, events
    finally:
        await _delete_group(client, gid)


@pytest.mark.asyncio
async def test_group_artist_flag_patch_tri_state_and_audit(
    client: AsyncClient, app_with_lifespan,
) -> None:
    """PATCH tri-state:不传字段(仅改名)→ tuple 不动(防静默撤权);true → 写
    tuple + 双回显;false → tuple 删 + 回显 false 且组成员失去 /me 能力;audit
    group_updated details 含 {old,new}(照 test_project_soft_delete.py:258-306 范式)。"""
    perms = app_with_lifespan.state.permissions
    _, tenant_key = await _default_org()
    gid, gname = await _create_group(client, prefix="paa_flag")
    uid = await _create_user(client, "paa_flag_u")
    await _add_group_member(client, gid, uid)
    try:
        # PATCH true → tuple 写 + PATCH 响应/列表双回显 + 组成员 /me 翻 true
        r = await client.patch(
            f"/api/v1/admin/directory/groups/{gid}",
            json={"can_create_artist_account": True}, headers=_h(EVAN_ID),
        )
        assert r.status_code == 200, r.text
        assert r.json()["can_create_artist_account"] is True, r.text
        assert await _artist_flag_on(perms, gid, tenant_key) is True
        echo = await _list_group_echo(client, gid, gname)
        assert echo is not None and echo["can_create_artist_account"] is True, echo
        me = (await client.get("/api/v1/auth/me", headers=_h(uid))).json()
        assert me["is_artist_account_creator"] is True, me

        # 仅改名、PATCH body 不带 can_create_artist_account 字段 → tuple 必须原样
        new_name = _uniq("paa_flag_renamed")
        rn = await client.patch(
            f"/api/v1/admin/directory/groups/{gid}",
            json={"name": new_name}, headers=_h(EVAN_ID),
        )
        assert rn.status_code == 200, rn.text
        assert await _artist_flag_on(perms, gid, tenant_key) is True, (
            "仅改名的不带字段 PATCH 不得撤 tuple(GroupUpdateIn 必须 tri-state)"
        )
        me_still = (await client.get("/api/v1/auth/me", headers=_h(uid))).json()
        assert me_still["is_artist_account_creator"] is True, me_still

        # PATCH false → tuple 删 + 回显 False + 组成员立即失去能力
        r2 = await client.patch(
            f"/api/v1/admin/directory/groups/{gid}",
            json={"can_create_artist_account": False}, headers=_h(EVAN_ID),
        )
        assert r2.status_code == 200, r2.text
        assert r2.json()["can_create_artist_account"] is False, r2.text
        assert await _artist_flag_on(perms, gid, tenant_key) is False
        echo2 = await _list_group_echo(client, gid, new_name)
        assert echo2 is not None and echo2["can_create_artist_account"] is False, echo2
        me_off = (await client.get("/api/v1/auth/me", headers=_h(uid))).json()
        assert me_off["is_artist_account_creator"] is False, me_off

        # audit:group_updated details 含 {old,new} 两个方向(soft-delete 范式)
        events = await _group_audit_details_list(client, "group_updated", gid)
        on = [e for e in events if (e.get("can_create_artist_account") or {}).get("new") is True]
        assert on, f"应有 can_create_artist_account new=True 的 group_updated: {events}"
        assert on[0]["can_create_artist_account"]["old"] is False, on[0]
        off = [e for e in events if (e.get("can_create_artist_account") or {}).get("new") is False]
        assert off, f"应有 can_create_artist_account new=False 的 group_updated: {events}"
        assert off[0]["can_create_artist_account"]["old"] is True, off[0]
    finally:
        await _delete_group(client, gid)


@pytest.mark.asyncio
async def test_me_is_artist_account_creator(client: AsyncClient) -> None:
    """/me:组成员(artist flag)is_artist_account_creator=true;移出组后 false;
    EVAN(org admin)直通 true;OUTSIDER false(方案 §4.4 口径 = bool(is_system_admin)
    或组 flag check)。"""
    gid, _gname = await _create_group(client, can_create_artist_account=True)
    uid = await _create_user(client, "paa_me_u")
    await _add_group_member(client, gid, uid)
    try:
        me = (await client.get("/api/v1/auth/me", headers=_h(uid))).json()
        assert me["is_artist_account_creator"] is True, me

        await _remove_group_member(client, gid, uid)
        me2 = (await client.get("/api/v1/auth/me", headers=_h(uid))).json()
        assert me2["is_artist_account_creator"] is False, me2

        me_admin = (await client.get("/api/v1/auth/me", headers=_h(EVAN_ID))).json()
        assert me_admin["is_artist_account_creator"] is True, me_admin

        me_out = (await client.get("/api/v1/auth/me", headers=_h(OUTSIDER_ID))).json()
        assert me_out["is_artist_account_creator"] is False, me_out
    finally:
        await _delete_group(client, gid)


@pytest.mark.asyncio
async def test_group_delete_clears_artist_flag_tuple(
    client: AsyncClient, app_with_lifespan,
) -> None:
    """删组 → organization#artist_account_creator 的组主体 tuple 不残留
    (§4.3:删组清理循环加第 4 个 relation;照既有删组测试形态)。"""
    perms = app_with_lifespan.state.permissions
    _, tenant_key = await _default_org()
    gid, _gname = await _create_group(client, can_create_artist_account=True)
    assert await _artist_flag_on(perms, gid, tenant_key) is True

    await _delete_group(client, gid)
    left = await _read_org_tuple_exact(perms, gid, tenant_key, "artist_account_creator")
    assert left == [], f"组删除应顺手删 artist_account_creator tuple,不得残留: {left}"


# ══════════════════════════════════════════════════════════════════════════════
# 第二组:组合流 201 全链(方案 §7「组合流」)
# ══════════════════════════════════════════════════════════════════════════════
@pytest.mark.asyncio
async def test_inline_artist_full_chain_201(
    client: AsyncClient, app_with_lifespan,
) -> None:
    """双 flag 组长带 artist_account 建项目 → 201 全链断言:
    users 新行(must_change_password/argon2/organization_id=default org);
    「艺人」组首次自动创建(description 如 D5)+ group_created source;
    GroupMembership 就位;FGA 项目三 relation(uploader/downloader/viewer,无 admin);
    「艺人」组零 org flag(四 relation 全无,D5 零权限论点);
    audit 形状逐条(user_created/group_member_added/project_member_added 3 条/project_created);
    temporary_password 12 位去易混淆字符且全库 audit_events 无该密码串;
    既有链路不回归(initial_grants 直通 + project_created details 原形状)。"""
    perms = app_with_lifespan.state.permissions
    org_id, tenant_key = await _default_org()
    await _cleanup_artist_group(client)   # 跨 run 卫生:清掉遗留「艺人」组(容忍 404)
    gid, uid = await _both_flag_leader(client)
    helper_uid = await _create_user(client, "paa_helper")
    artist_username = _uniq("paa_artist")
    code = _project_code()
    pid = ""
    try:
        r = await client.post(
            "/api/v1/projects",
            json=_project_body(
                code, _uniq("内嵌艺人项目"), uid,
                artist={"username": artist_username, "name": "艺人甲"},
                initial_grants=[{"kind": "user", "id": helper_uid, "roles": ["viewer"]}],
            ),
            headers=_h(uid),
        )
        assert r.status_code == 201, r.text
        body = r.json()
        pid = body["id"]

        # ── 响应体 artist_account 形状(一次性回显,键集合不多不少)─────────────
        aa = body["artist_account"]
        assert aa is not None, body
        assert set(aa.keys()) == {"user_id", "username", "name", "temporary_password"}, aa
        assert aa["username"] == artist_username
        assert aa["name"] == "艺人甲"
        temp_pw = aa["temporary_password"]
        assert TEMP_PASSWORD_RE.fullmatch(temp_pw), (
            f"临时密码应 12 位且去易混淆字符(大写去 I/O、小写去 l/o、数字去 0/1): {temp_pw!r}"
        )

        # ── users 表新行(位置/形状逐条)──────────────────────────────────────
        new_user = await _get_user_by_username(artist_username)
        assert new_user is not None, "艺人用户应已落库"
        artist_uid = str(new_user.id)
        assert aa["user_id"] == artist_uid, aa
        assert new_user.name == "艺人甲"
        assert new_user.must_change_password is True, "首登强制改密"
        assert (new_user.password_hash or "").startswith("$argon2id$"), "应为 argon2id hash"
        assert str(new_user.organization_id) == org_id, "应绑 default org"

        # ── 「艺人」组首次自动创建(D5)──────────────────────────────────────
        artist_group = await _get_group_by_name(ARTIST_GROUP_NAME)
        assert artist_group is not None, "「艺人」组应首次自动创建"
        artist_gid = str(artist_group.id)
        assert artist_group.description == ARTIST_GROUP_DESCRIPTION, (
            f"description 应如方案 D5: {artist_group.description!r}"
        )
        # GroupMembership(艺人组, 新用户)就位
        assert await _membership_exists(artist_gid, artist_uid), (
            "艺人用户应在「艺人」组中(group_memberships 行)"
        )

        # ── FGA:项目三 relation;「艺人」组零 org flag(D5)──────────────────
        tuples = await perms.read_all_tuples(object_type="project", object_id=pid)
        artist_rels = {rel for t_user, rel, _obj in tuples if t_user == f"user:{artist_uid}"}
        assert artist_rels == {"uploader", "downloader", "viewer"}, (
            f"艺人应恰有上传/下载/查看三 relation(D8 固定面,无 admin): {artist_rels}"
        )
        helper_rels = {rel for t_user, rel, _obj in tuples if t_user == f"user:{helper_uid}"}
        assert "viewer" in helper_rels, f"initial_grants 的 viewer 应就位: {helper_rels}"
        for relation in ORG_FLAG_RELATIONS:
            left = await _read_org_tuple_exact(perms, artist_gid, tenant_key, relation)
            assert left == [], (
                f"「艺人」组不得持有任何 org 级 flag tuple(四 relation 全无,D5): "
                f"{relation} → {left}"
            )

        # ── audit 形状逐条(方案 §7)─────────────────────────────────────────
        # user_created:actor=组长,group_ids=[艺人组],source=project_artist_inline
        uc = await _audit_events(client, "user_created", actor_user_id=uid)
        uc_hit = [e for e in uc if (e.get("details") or {}).get("user_id") == artist_uid]
        assert len(uc_hit) == 1, uc_hit
        uc_details = uc_hit[0]["details"]
        assert uc_details["username"] == artist_username, uc_details
        assert uc_details["name"] == "艺人甲", uc_details
        assert uc_details["group_ids"] == [artist_gid], uc_details
        assert uc_details["source"] == INLINE_SOURCE, uc_details
        # group_created:仅实际新建组时写,source=project_artist_inline
        gc = await _audit_events(client, "group_created", actor_user_id=uid)
        gc_hit = [e for e in gc if (e.get("details") or {}).get("group_id") == artist_gid]
        assert len(gc_hit) == 1, gc_hit
        assert gc_hit[0]["details"]["name"] == ARTIST_GROUP_NAME, gc_hit[0]
        assert gc_hit[0]["details"]["source"] == INLINE_SOURCE, gc_hit[0]
        # group_member_added:source=project_artist_inline
        gma = await _audit_events(client, "group_member_added", actor_user_id=uid)
        gma_hit = [
            e for e in gma
            if (e.get("details") or {}).get("group_id") == artist_gid
            and (e.get("details") or {}).get("user_id") == artist_uid
        ]
        assert len(gma_hit) == 1, gma_hit
        assert gma_hit[0]["details"]["source"] == INLINE_SOURCE, gma_hit[0]
        # project_member_added:恰 3 条 via=artist_inline(uploader/downloader/viewer)
        pma = await _audit_events(client, "project_member_added", project_id=pid)
        inline_hits = [e for e in pma if (e.get("details") or {}).get("via") == VIA_ARTIST_INLINE]
        assert len(inline_hits) == 3, pma
        assert {
            e["details"]["role"] for e in inline_hits
        } == {"uploader", "downloader", "viewer"}, inline_hits
        for e in inline_hits:
            d = e["details"]
            assert d["subject"] == f"user:{artist_uid}", e
            assert d["kind"] == "user", e
            assert e["actor_user_id"] == uid, e
        # project_created(既有,不因艺人段变化):actor=组长,details 原形状
        pc = await _audit_events(client, "project_created", project_id=pid)
        pc_hit = [e for e in pc if e.get("actor_user_id") == uid]
        assert len(pc_hit) == 1, pc
        assert pc_hit[0]["details"]["code"] == code, pc_hit[0]
        assert pc_hit[0]["details"]["initial_grants_count"] == 1, pc_hit[0]
        # 既有链路不回归:initial_grants 直通审计(via=initial_grants)仍在
        ig_hits = [
            e for e in pma if (e.get("details") or {}).get("via") == "initial_grants"
        ]
        assert any(
            e["details"]["subject"] == f"user:{helper_uid}" and e["details"]["role"] == "viewer"
            for e in ig_hits
        ), f"initial_grants 的 project_member_added 不应被艺人段破坏: {pma}"

        # ── 一次性密码语义:全库 audit_events 无该密码串 ─────────────────────
        leak = await _audit_event_types_containing(temp_pw)
        assert leak == [], f"临时密码不得落任何 audit 事件: {leak}"
    finally:
        if pid:
            await _archive_project(pid)
        await _delete_group(client, gid)


@pytest.mark.asyncio
async def test_inline_artist_group_reused_second_flow(client: AsyncClient) -> None:
    """第二次走内嵌流程 → 复用同一「艺人」组(groups 计数不增;命中既有组不写
    group_created);跨 run 卫生:setup 先删同名组(容忍 404)。"""
    await _cleanup_artist_group(client)
    gid, uid = await _both_flag_leader(client, "paa_reuse")
    username1 = _uniq("paa_artist1")
    username2 = _uniq("paa_artist2")
    code1, code2 = _project_code(), _project_code()
    pids: list[str] = []
    try:
        r1 = await client.post(
            "/api/v1/projects",
            json=_project_body(code1, _uniq("复用流程一"), uid,
                               artist={"username": username1, "name": "艺人一"}),
            headers=_h(uid),
        )
        assert r1.status_code == 201, r1.text
        pids.append(r1.json()["id"])
        g1 = await _get_group_by_name(ARTIST_GROUP_NAME)
        assert g1 is not None, "首次流程应自动建「艺人」组"
        gid1 = str(g1.id)
        assert await _artist_group_count() == 1, "「艺人」组应恰有一个"

        r2 = await client.post(
            "/api/v1/projects",
            json=_project_body(code2, _uniq("复用流程二"), uid,
                               artist={"username": username2, "name": "艺人二"}),
            headers=_h(uid),
        )
        assert r2.status_code == 201, r2.text
        pids.append(r2.json()["id"])
        g2 = await _get_group_by_name(ARTIST_GROUP_NAME)
        assert g2 is not None and str(g2.id) == gid1, (
            f"第二次应复用同一「艺人」组: {gid1} vs {g2 and g2.id}"
        )
        assert await _artist_group_count() == 1, "复用不得新增组行"

        u2 = await _get_user_by_username(username2)
        assert u2 is not None
        assert await _membership_exists(gid1, str(u2.id)), "第二位艺人应入同一组"

        # 命中既有组不写 group_created(仅实际新建组才写,D5)
        gc = await _audit_events(client, "group_created", actor_user_id=uid)
        gc_hit = [e for e in gc if (e.get("details") or {}).get("group_id") == gid1]
        assert len(gc_hit) == 1, f"复用路径不得再写 group_created: {gc_hit}"
        assert gc_hit[0]["details"]["source"] == INLINE_SOURCE, gc_hit[0]
    finally:
        for p in pids:
            await _archive_project(p)
        await _delete_group(client, gid)


@pytest.mark.asyncio
async def test_org_admin_inline_artist_direct_pass(client: AsyncClient) -> None:
    """org admin(EVAN)带 artist_account 建项目 → 201 直通(无组 flag 依赖);
    响应 artist_account 填充、用户落库。"""
    await _cleanup_artist_group(client)
    artist_username = _uniq("paa_adminart")
    code = _project_code()
    pid = ""
    try:
        r = await client.post(
            "/api/v1/projects",
            json=_project_body(code, _uniq("admin直通项目"), EVAN_ID,
                               artist={"username": artist_username, "name": "直通艺人"}),
            headers=_h(EVAN_ID),
        )
        assert r.status_code == 201, r.text
        body = r.json()
        pid = body["id"]
        aa = body["artist_account"]
        assert aa is not None and aa["username"] == artist_username, body
        assert TEMP_PASSWORD_RE.fullmatch(aa["temporary_password"]), aa
        new_user = await _get_user_by_username(artist_username)
        assert new_user is not None and str(new_user.id) == aa["user_id"]
    finally:
        if pid:
            await _archive_project(pid)


# ══════════════════════════════════════════════════════════════════════════════
# 第三组:权限与失败路径(方案 §7「权限与失败路径」)
# ══════════════════════════════════════════════════════════════════════════════
@pytest.mark.asyncio
async def test_creator_without_artist_flag_403_zero_side_effects(client: AsyncClient) -> None:
    """仅 can_create_project(无 artist flag)组长带 artist_account → 403
    (detail 含「无内嵌创建艺人账号权限」),且零副作用:projects/users/groups
    三表无新行、audit 计数不变(守门不写审计,deps 惯例)。"""
    from app.db.tables import Group, Project, User

    gid, _gname = await _create_group(client, can_create_project=True)
    uid = await _create_user(client, "paa_noflag_u")
    await _add_group_member(client, gid, uid)
    code = _project_code()
    before = (
        await _row_count(Project), await _row_count(User), await _row_count(Group),
        await _audit_count(),
    )
    try:
        r = await client.post(
            "/api/v1/projects",
            json=_project_body(code, _uniq("无权限项目"), uid,
                               artist={"username": _uniq("paa_no"), "name": "不应存在"}),
            headers=_h(uid),
        )
        assert r.status_code == 403, r.text
        assert INLINE_403_COPY in str(r.json().get("detail")), (
            f"403 文案应含「{INLINE_403_COPY}」(与 require_project_creator 的 403 可区分): {r.text}"
        )
        after = (
            await _row_count(Project), await _row_count(User), await _row_count(Group),
            await _audit_count(),
        )
        assert after == before, f"403 必须零副作用(三表 + audit 计数不变): {before} → {after}"
    finally:
        await _delete_group(client, gid)


@pytest.mark.asyncio
async def test_username_conflict_precheck_409_project_not_created(client: AsyncClient) -> None:
    """username 冲突(预建同名用户)→ 预检 409 detail={code:username_taken,
    username}(无 project_id —— 前端 F3 按 project_id 有无路由文案),项目未建,
    audit 计数不变(预检不写审计)。"""
    conflict = _uniq("paa_conf")
    r0 = await client.post(
        "/api/v1/admin/directory/users",
        json={"username": conflict, "name": "已占用"}, headers=_h(EVAN_ID),
    )
    assert r0.status_code == 201, r0.text
    gid, uid = await _both_flag_leader(client, "paa_pre")
    code = _project_code()
    before_a = await _audit_count()
    try:
        r = await client.post(
            "/api/v1/projects",
            json=_project_body(code, _uniq("冲突项目"), uid,
                               artist={"username": conflict, "name": "撞名艺人"}),
            headers=_h(uid),
        )
        assert r.status_code == 409, r.text
        detail = r.json().get("detail")
        assert isinstance(detail, dict), f"内嵌链路 409 应为结构化 detail: {r.text}"
        assert detail["code"] == USERNAME_TAKEN_CODE, detail
        assert detail["username"] == conflict, detail
        assert "project_id" not in detail, (
            f"预检阶段 409 不得带 project_id(项目未建;前端按其有无分支): {detail}"
        )
        assert not await _project_row_exists(code), "预检 409 必须零副作用:项目不得已建"
        assert await _audit_count() == before_a, "预检 409 不写审计"
    finally:
        await _delete_group(client, gid)


@pytest.mark.asyncio
async def test_username_case_variant_409(client: AsyncClient) -> None:
    """大小写变体(seed 已有 username=evan,提交 Evan)→ 同样 409(钉住 lower
    匹配口径,防「case 变体建号成功 → 两账号登录互锁」回归);项目未建。"""
    assert await _get_user_by_username("evan") is not None, "前置:seed 的 evan 必须存在"
    gid, uid = await _both_flag_leader(client, "paa_case")
    code = _project_code()
    try:
        r = await client.post(
            "/api/v1/projects",
            json=_project_body(code, _uniq("变体项目"), uid,
                               artist={"username": "Evan", "name": "大小写变体"}),
            headers=_h(uid),
        )
        assert r.status_code == 409, r.text
        detail = r.json().get("detail")
        assert isinstance(detail, dict) and detail["code"] == USERNAME_TAKEN_CODE, r.text
        assert detail["username"] == "Evan", detail
        assert not await _project_row_exists(code), "变体 409 必须零副作用:项目不得已建"
    finally:
        await _delete_group(client, gid)


@pytest.mark.asyncio
async def test_username_coexistence_pair_409_not_500(client: AsyncClient) -> None:
    """存量共存对(库内 evan + 直插 EVAN 两行,提交 EVAN)→ 409 而非 500
    (钉住预检 limit(1)+first 消费语义,防 scalar_one_or_none 的
    MultipleResultsFound 500)。直插用 get_sessionmaker 绕 API —— lower 预检
    上线后 API 路径造不出共存对,注释见 _insert_user_raw,防后人顺手改掉。"""
    from app.db.session import get_sessionmaker
    from app.db.tables import User

    assert await _get_user_by_username("evan") is not None, "前置:seed 的 evan 必须存在"
    # setup 防御:清掉上次中断残留的 EVAN 行,保证恰两行 lower 命中
    await _delete_user_rows_by_username("EVAN")
    async with get_sessionmaker()() as db:
        db.add(User(username="EVAN", name="共存对直插 EVAN"))
        await db.commit()
    gid, uid = await _both_flag_leader(client, "paa_pair")
    code = _project_code()
    try:
        r = await client.post(
            "/api/v1/projects",
            json=_project_body(code, _uniq("共存对项目"), uid,
                               artist={"username": "EVAN", "name": "第三种变体"}),
            headers=_h(uid),
        )
        assert r.status_code == 409, (
            f"多行 lower 命中必须视为已占用 409(limit(1)+first),不得 500: {r.text}"
        )
        detail = r.json().get("detail")
        assert isinstance(detail, dict) and detail["code"] == USERNAME_TAKEN_CODE, r.text
        assert detail["username"] == "EVAN", detail
        assert not await _project_row_exists(code), "共存对 409 必须零副作用:项目不得已建"
    finally:
        # 收尾必须清掉直插行:两行 lower 同名会让 seed evan 的登录口径(local_auth
        # 多行命中拒绝)永久锁死,污染共享栈
        await _delete_user_rows_by_username("EVAN")
        await _delete_group(client, gid)


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("username", "name"),
    [
        pytest.param("a", "艺人甲", id="username_too_short"),
        pytest.param("a" * 65, "艺人甲", id="username_too_long_65"),
        pytest.param("bad name", "艺人甲", id="username_space_hits_regex"),
        pytest.param("艺名", "艺人甲", id="username_non_ascii_hits_regex"),
        pytest.param("ok_name", "", id="name_empty"),
        pytest.param("ok_name", "   ", id="name_all_whitespace"),
        pytest.param("ok_name", "字" * 129, id="name_too_long_129"),
    ],
)
async def test_artist_account_in_validation_422(
    client: AsyncClient, username: str, name: str,
) -> None:
    """ArtistAccountIn 非法 → 422(Pydantic 阶段,零副作用):username 撞正则/
    长度边界;name 空 / 全空白(钉住 _validate_name_format 复用)/ 129 字符。"""
    from app.db.tables import User

    gid, uid = await _both_flag_leader(client, "paa_422")
    code = _project_code()
    before_u = await _row_count(User)
    try:
        r = await client.post(
            "/api/v1/projects",
            json=_project_body(code, _uniq("422项目"), uid,
                               artist={"username": username, "name": name}),
            headers=_h(uid),
        )
        assert r.status_code == 422, r.text
        assert await _row_count(User) == before_u, "422 必须零副作用"
    finally:
        await _delete_group(client, gid)


@pytest.mark.asyncio
async def test_no_artist_account_zero_regression(client: AsyncClient) -> None:
    """两项全空(不传 artist_account 字段)→ 与现状一致(零回归锚点,语义断言):
    项目建成、无新用户、响应含恒为 null 的 artist_account 键(结构兼容,
    勿 exclude_none 把既有可空键一并剥掉)。"""
    from app.db.tables import User

    gid, uid = await _both_flag_leader(client, "paa_plain")
    code = _project_code()
    before_u = await _row_count(User)
    pid = ""
    try:
        r = await client.post(
            "/api/v1/projects",
            json=_project_body(code, _uniq("纯项目创建"), uid),
            headers=_h(uid),
        )
        assert r.status_code == 201, r.text
        body = r.json()
        pid = body["id"]
        assert "artist_account" in body, (
            f"创建响应恒含 artist_account 键(不传时为 null): {list(body.keys())}"
        )
        assert body["artist_account"] is None, body
        assert await _row_count(User) == before_u, "不传 artist_account 不得新建用户"
    finally:
        if pid:
            await _archive_project(pid)
        await _delete_group(client, gid)


@pytest.mark.asyncio
async def test_username_available_gate_and_results(client: AsyncClient) -> None:
    """GET /users/username-available(方案 §4.2):flag 组长查未占用名 →
    {available:true};查 EVAN(小写 evan 已占用,大写查询)→ false(钉住 lower
    查询口径);OUTSIDER → 403;仅有 artist flag、无 project_creator → 403
    (钉住合取守门 require_inline_artist_creator);非法 username → 422。"""
    gid, uid = await _both_flag_leader(client, "paa_avail")
    gid2, _gname2 = await _create_group(client, can_create_artist_account=True)   # 仅有 artist flag
    uid2 = await _create_user(client, "paa_avail_only")
    await _add_group_member(client, gid2, uid2)
    fresh = _uniq("paa_fresh")
    try:
        r = await client.get(
            "/api/v1/users/username-available",
            params={"username": fresh}, headers=_h(uid),
        )
        assert r.status_code == 200, r.text
        assert r.json() == {"available": True}, r.text

        # 大写查询 seed 占用名 → false(lower 匹配与登录/预检口径一致)
        r2 = await client.get(
            "/api/v1/users/username-available",
            params={"username": "EVAN"}, headers=_h(uid),
        )
        assert r2.status_code == 200, r2.text
        assert r2.json() == {"available": False}, r2.text

        # OUTSIDER → 403
        r3 = await client.get(
            "/api/v1/users/username-available",
            params={"username": fresh}, headers=_h(OUTSIDER_ID),
        )
        assert r3.status_code == 403, r3.text

        # 仅有 artist flag、无 project_creator → 403(合取守门;此类用户提交
        # POST /projects 会在 require_project_creator 先 403,预检对其是严格增量信息)
        r4 = await client.get(
            "/api/v1/users/username-available",
            params={"username": fresh}, headers=_h(uid2),
        )
        assert r4.status_code == 403, (
            f"仅有 artist flag 的用户必须被合取守门挡下: {r4.text}"
        )

        # 非法 username → 422(Query 约束与 UserCreateIn 同款:2-64 + 正则)
        r5 = await client.get(
            "/api/v1/users/username-available",
            params={"username": "a"}, headers=_h(uid),
        )
        assert r5.status_code == 422, r5.text
        r6 = await client.get(
            "/api/v1/users/username-available",
            params={"username": "bad name!"}, headers=_h(uid),
        )
        assert r6.status_code == 422, r6.text
    finally:
        await _delete_group(client, gid)
        await _delete_group(client, gid2)


# ══════════════════════════════════════════════════════════════════════════════
# 第四组:竞态形状两层单测(方案 §7「竞态阶段 409」;黑盒并发不做,monkeypatch 构造)
# ══════════════════════════════════════════════════════════════════════════════
@pytest.mark.asyncio
async def test_race_provision_409_reraised_structured_with_project_id(
    client: AsyncClient, app_with_lifespan, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """竞态层 ①(HTTPException 形状):monkeypatch provision_local_user 抛
    「登录名已存在」409(照 provision 内部预检的纯文本 detail 形状)→ 端点捕获
    并统一重抛 409 detail={code:username_taken, username, project_id},且
    detail.project_id 非空(证明项目段已提交、非预检 409)。

    patch 目标写死 = app.routers.projects 命名空间内的符号:B6 为 from-import
    形态(from app.services.user_provisioning import provision_local_user),
    patch services 模块无效;符号不存在(B6 未实现/改名)时此处响亮
    AttributeError,而非假绿。该结构化 409 形状是前端 F3-③ 分支路由的唯一依据。
    """
    artist_username = _uniq("paa_race")
    code = _project_code()

    async def _boom(db, permissions, audit, **kwargs):
        # 签名照实现侧调用形态:3 个位置参数(db, permissions, audit)+ 关键字参数
        # (首跑回归:裸 **kwargs 会在调用点 TypeError 而非走到本桩);顺带钉住
        # 竞态阶段 source/membership_source 两参均已带 project_artist_inline(D7)
        assert kwargs.get("source") == INLINE_SOURCE, kwargs
        assert kwargs.get("membership_source") == INLINE_SOURCE, kwargs
        raise HTTPException(409, f"登录名已存在:{artist_username}")

    monkeypatch.setattr("app.routers.projects.provision_local_user", _boom)
    r = await client.post(
        "/api/v1/projects",
        json=_project_body(code, _uniq("竞态项目"), EVAN_ID,
                           artist={"username": artist_username, "name": "竞态艺人"}),
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 409, r.text
    detail = r.json().get("detail")
    assert isinstance(detail, dict), f"竞态 409 应为结构化 detail: {r.text}"
    assert detail["code"] == USERNAME_TAKEN_CODE, detail
    assert detail["username"] == artist_username, detail
    assert detail["project_id"], f"竞态 409 必须带非空 project_id(项目已建): {detail}"
    uuid.UUID(detail["project_id"])   # 形状必须是可解析 UUID
    assert await _project_row_exists(code), "竞态 409 语义:项目段已提交(项目在、艺人未建)"
    await _archive_project(detail["project_id"])


@pytest.mark.asyncio
async def test_race_integrity_error_uq_users_username_classified(
    client: AsyncClient, app_with_lifespan, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """竞态层 ①+②(IntegrityError 形状):用真实 PG 文案形状构造 IntegrityError
    (duplicate key value violates unique constraint "uq_users_username")→ 端点
    按约束名收窄归类 → 重抛结构化 409 带 project_id。判据常量写错(如抄
    projects 的自动命名机制)则本用例变 500,竞态路径成死代码 —— 本用例即钉住
    判据常量本身。"""
    artist_username = _uniq("paa_raceuq")
    code = _project_code()

    async def _boom(db, permissions, audit, **kwargs):
        # 签名照实现侧调用形态(3 位置参数 + 关键字参数),否则 TypeError 假绿/假红
        assert kwargs.get("source") == INLINE_SOURCE, kwargs
        raise IntegrityError(
            "INSERT INTO users (username, name) VALUES (...)", None,
            Exception(UQ_USERS_USERNAME_MSG),
        )

    monkeypatch.setattr("app.routers.projects.provision_local_user", _boom)
    r = await client.post(
        "/api/v1/projects",
        json=_project_body(code, _uniq("竞态UQ项目"), EVAN_ID,
                           artist={"username": artist_username, "name": "竞态艺人"}),
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 409, (
        f"uq_users_username 冲突必须被收窄归类为 username_taken 409(不得 500): {r.text}"
    )
    detail = r.json().get("detail")
    assert isinstance(detail, dict), r.text
    assert detail["code"] == USERNAME_TAKEN_CODE, detail
    assert detail["username"] == artist_username, detail
    assert detail["project_id"], detail
    assert await _project_row_exists(code)
    await _archive_project(detail["project_id"])


@pytest.mark.asyncio
async def test_race_integrity_error_other_constraint_not_swallowed(
    client: AsyncClient, app_with_lifespan, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """竞态收窄的对偶钉住:其他唯一约束的 IntegrityError(如 email key)不得被
    误报成「登录名占用」→ 原样上抛 500(provision 多次 commit,不收窄会把其他
    唯一冲突吞进 username_taken 语义)。"""
    artist_username = _uniq("paa_raceother")
    code = _project_code()

    async def _boom(db, permissions, audit, **kwargs):
        # 签名照实现侧调用形态(3 位置参数 + 关键字参数)—— 本用例首跑曾因裸
        # **kwargs 的 TypeError 恰好撞上断言的 500 而假绿,签名修正后才是真验证
        raise IntegrityError(
            "INSERT INTO users (username, name) VALUES (...)", None,
            Exception('duplicate key value violates unique constraint "users_email_key"'),
        )

    monkeypatch.setattr("app.routers.projects.provision_local_user", _boom)
    # raise_app_exceptions=False:ServerErrorMiddleware 已发 500 响应,transport
    # 不把未处理异常重抛给测试,而是返回该 500
    transport = ASGITransport(app=app_with_lifespan, raise_app_exceptions=False)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        r = await ac.post(
            "/api/v1/projects",
            json=_project_body(code, _uniq("竞态其他约束"), EVAN_ID,
                               artist={"username": artist_username, "name": "其他约束"}),
            headers=_h(EVAN_ID),
        )
    assert r.status_code == 500, (
        f"非 uq_users_username 的唯一冲突不得归类为 username_taken(应上抛 500): {r.text}"
    )
    assert await _project_row_exists(code), "竞态 500 语义:项目段已提交"
    await _archive_project(await _project_id_by_code(code))


# ══════════════════════════════════════════════════════════════════════════════
# 第五组:服务薄壳化回归(方案 §7「服务薄壳化回归」)
# ══════════════════════════════════════════════════════════════════════════════
@pytest.mark.asyncio
async def test_admin_create_user_source_admin_create(client: AsyncClient) -> None:
    """POST /admin/directory/users(管理后台建号原路径):201 + temporary_password
    回显 + user_created details 含 source="admin_create"(D7 additive 键);
    密码形状照旧(12 位去易混淆字符)。"""
    uname = _uniq("paa_admin")
    r = await client.post(
        "/api/v1/admin/directory/users",
        json={"username": uname, "name": "Admin 建号"}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["username"] == uname
    assert body["must_change_password"] is True
    assert TEMP_PASSWORD_RE.fullmatch(body["temporary_password"]), body

    events = await _audit_events(client, "user_created", actor_user_id=EVAN_ID)
    hit = [e for e in events if (e.get("details") or {}).get("user_id") == body["id"]]
    assert len(hit) == 1, events
    details = hit[0]["details"]
    assert details["username"] == uname, details
    assert details["group_ids"] == [], details
    assert details["source"] == ADMIN_SOURCE, (
        f"admin 链路 user_created 必须带 source=admin_create: {details}"
    )
    # 一次性密码语义照旧:临时密码不落任何 audit
    leak = await _audit_event_types_containing(body["temporary_password"])
    assert leak == [], f"admin 链路临时密码同样不得落 audit: {leak}"


@pytest.mark.asyncio
async def test_admin_create_duplicate_copy_unchanged_and_lower_prefetch(
    client: AsyncClient,
) -> None:
    """重名 409 文案不变(纯文本「登录名已存在:{username}」);admin 链路 lower
    预检有意变更钉住:预建 evan(seed)后经管理后台提交 Evan → 409 —— 防后人
    「顺手改回 exact 匹配」而无回归保护(旧行为是 201,随后两账号登录互锁)。"""
    uname = _uniq("paa_dup")
    r = await client.post(
        "/api/v1/admin/directory/users",
        json={"username": uname, "name": "Dup One"}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text
    # 精确重名 → 409 文案逐字不变
    r2 = await client.post(
        "/api/v1/admin/directory/users",
        json={"username": uname, "name": "Dup Two"}, headers=_h(EVAN_ID),
    )
    assert r2.status_code == 409, r2.text
    assert r2.json().get("detail") == f"{ADMIN_DUP_409_PREFIX}{uname}", (
        f"admin 重名 409 文案不得变(纯文本,非结构化): {r2.text}"
    )
    # 大小写变体 → 409(lower 预检;旧 exact 口径此处 201)
    r3 = await client.post(
        "/api/v1/admin/directory/users",
        json={"username": "Evan", "name": "Case Variant"}, headers=_h(EVAN_ID),
    )
    assert r3.status_code == 409, (
        f"admin 链路必须 lower 预检:seed evan 已占用,提交 Evan 应 409: {r3.text}"
    )
    assert str(r3.json().get("detail")).startswith(ADMIN_DUP_409_PREFIX), r3.text


@pytest.mark.asyncio
async def test_admin_create_with_group_ids_and_membership_call_points(
    client: AsyncClient,
) -> None:
    """带 group_ids 建号入组照旧(group_member_added source="user_create" 原值);
    directory 三处 add_user_to_group_audited 迁移点 source 语义不变:
    建号入组(原 :252)带 user_create;组加成员端点(原 :976)与改用户组
    (原 :354)不传 source(审计无该键)。"""
    gid, _gname = await _create_group(client, prefix="paa_gid")
    gid2, _gname2 = await _create_group(client, prefix="paa_gid2")
    uname = _uniq("paa_giduser")
    r = await client.post(
        "/api/v1/admin/directory/users",
        json={"username": uname, "name": "入组建号", "group_ids": [gid]},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text
    uid_a = r.json()["id"]

    # 调用点:组加成员端点(原 :976)
    uid_b = await _create_user(client, "paa_gmuser")
    r3 = await client.post(
        f"/api/v1/admin/directory/groups/{gid}/members",
        json={"user_id": uid_b}, headers=_h(EVAN_ID),
    )
    assert r3.status_code == 201, r3.text

    # 调用点:改用户组(原 :354,group_ids 全量同步 added 侧)
    r4 = await client.patch(
        f"/api/v1/admin/directory/users/{uid_b}",
        json={"group_ids": [gid2]}, headers=_h(EVAN_ID),
    )
    assert r4.status_code == 200, r4.text

    # 成员就位断言(组列表)
    r2 = await client.get(
        f"/api/v1/admin/directory/groups/{gid}/members", headers=_h(EVAN_ID),
    )
    assert r2.status_code == 200, r2.text
    members_b = {m["user_id"] for m in r2.json()}
    assert uid_a in members_b, r2.text   # 建号入组的成员仍在原组
    assert uid_b not in members_b, "uid_b 已被 PATCH 同步出 gid"

    # 三处迁移点的审计形状:一次拉取,分别匹配
    gma = await _audit_events(client, "group_member_added", actor_user_id=EVAN_ID)

    def _hits(events: list[dict], gid_: str, uid_: str) -> list[dict]:
        return [
            e.get("details") or {} for e in events
            if (e.get("details") or {}).get("group_id") == gid_
            and (e.get("details") or {}).get("user_id") == uid_
        ]

    # ① 建号入组:source=user_create(原值不变,薄壳化不得静默改掉)
    hit_a = _hits(gma, gid, uid_a)
    assert len(hit_a) == 1, gma
    assert hit_a[0].get("source") == USER_CREATE_SOURCE, (
        f"建号入组的 group_member_added source 应保持 user_create 原值: {hit_a[0]}"
    )
    # ② 组加成员端点:审计无 source 键(行为不变)
    hit_b = _hits(gma, gid, uid_b)
    assert len(hit_b) == 1, gma
    assert "source" not in hit_b[0], (
        f"组加成员端点的审计不得新增 source 键(行为不变): {hit_b[0]}"
    )
    # ③ 改用户组 added 侧:审计无 source 键(行为不变)
    hit_c = _hits(gma, gid2, uid_b)
    assert len(hit_c) == 1, gma
    assert "source" not in hit_c[0], (
        f"改用户组 added 侧的审计不得新增 source 键(行为不变): {hit_c[0]}"
    )
