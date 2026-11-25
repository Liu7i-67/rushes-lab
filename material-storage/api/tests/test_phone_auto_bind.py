"""建号自动绑定大陆手机号 — provision_local_user 自动绑定段契约测试。

需求:docs/qdev/2026-11-25-phone-auto-bind-on-create.md(测试点 T1-T7;功能点
F1-F4;决策 D2/D5/D6)。范式:tests/test_bind_user_phones.py —— aiosqlite 内存
库真建 users 表(uq_users_phone 唯一约束真生效,T6 竞态可真撞)+ 审计桩
(AuditService.write 是 PG insert 方言,SQLite 编译失败;本地只断言调用形状
records=[(event_type, details)])+ monkeypatch 桩外部依赖:
  - get_default_organization → None(org=None 时 add_user_to_organization 跳过);
  - PermissionsService → StubPermissions 桩对象直传入参,不连 OpenFGA;
  - hash_password / generate_temp_password 纯函数真跑;ctx 固定 ip/ua None。

实现按需求文档钉死的段结构:归一化判定(normalize_phone 单点,D5)→ 占用/折叠
一条 SQL 预检(`phone=candidate OR replace(replace(username,'-',''),'.','')
=candidate`)→ 单独 UPDATE+commit(撞 uq_users_phone → rollback 跳过,F3;
D2:建号照常,绝不 raise)→ phone_bound 审计(details source="auto_bind",
D6)+ user_created details 增 auto_phone_bound bool(单事件对账)。

测试 ↔ 功能点映射:
  test_t1_plain_phone_username_binds_automatically     T1 F1 F4 D6
  test_t2_separated_username_normalized_then_binds     T2 D5
  test_t3_non_phone_username_not_bound[param]          T3 F1
  test_t4_candidate_phone_taken_skips_bind             T4 F2 D2
  test_t5_folded_username_conflict_skips_bind          T5 F2 D5
  test_t6_race_unique_violation_rolled_back_no_raise   T6 F3 D2
  test_t7_user_created_audit_keys_zero_regression      T7 F4 D6
  test_consecutive_provisions_leave_no_residue         附加:建号主流程无残留副作用
"""

from __future__ import annotations

import uuid
from types import SimpleNamespace
from typing import Any

import pytest
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

import app.services.user_provisioning as up
from app.db.tables import User
from app.services.passwords import verify_password
from app.services.phone_verification import normalize_phone
from app.services.user_provisioning import provision_local_user

# D5 归一化公共样本:138-0013-8000 与 13800138000 折叠同号
CANDIDATE = "13800138000"
CANDIDATE_VARIANT = "138-0013-8000"
MASKED = "138****8000"  # §5.7 脱敏规格:前 3 + **** + 后 4(字面钉死防漂移)


# ─── 基建:内存 SQLite(真 users 表)+ 审计/权限桩 ────────────────────────────
@pytest.fixture
async def factory():
    """内存 SQLite,只建 users 表(groups=[]/org=None 下 provision 只触它);
    uq_users_phone 唯一约束随表生效(T6 竞态真撞靠它)。"""
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(User.metadata.create_all, tables=[User.__table__])
    sm = async_sessionmaker(engine, expire_on_commit=False)
    yield sm
    await engine.dispose()


class FakeAuditService:
    """AuditService 替身:真 write 编 pg_insert PG 方言,SQLite 编译失败;
    本地只记录 (event_type, details) 调用形状。签名兼容 provision 的
    actor_user_id 与 **ctx(request_ip / user_agent)关键字。"""

    def __init__(self) -> None:
        self.records: list[tuple[str, dict[str, Any]]] = []

    async def write(
        self, *, event_type: str, details: dict[str, Any] | None = None, **_kw: Any
    ) -> SimpleNamespace:
        self.records.append((event_type, dict(details or {})))
        return SimpleNamespace(event_type=event_type)


class StubPermissions:
    """PermissionsService 替身:只记录 OpenFGA tuple 写调用,不真连。"""

    def __init__(self) -> None:
        self.org_calls: list[dict[str, str]] = []
        self.group_calls: list[dict[str, str]] = []

    async def add_user_to_organization(self, *, organization_tenant_key: str, user_id: str) -> None:
        self.org_calls.append({"organization_tenant_key": organization_tenant_key, "user_id": user_id})

    async def add_user_to_group(self, *, group_id: str, user_id: str) -> None:
        self.group_calls.append({"group_id": group_id, "user_id": user_id})


@pytest.fixture
def perms() -> StubPermissions:
    return StubPermissions()


@pytest.fixture
def audit() -> FakeAuditService:
    return FakeAuditService()


# ─── 调用 / 断言小工具(每用例独立 actor / 独立内存库,无共享状态)────────────
async def provision(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    perms: StubPermissions,
    audit: FakeAuditService,
    *,
    username: str,
    name: str = "测试用户",
    email: str | None = None,
) -> tuple[User, str, uuid.UUID]:
    """统一入口:get_default_organization 双处打桩 None(被测模块名 + 源模块);
    每用例独立 actor;groups=[] 绕开入组审计;source 与 admin 链路同值。
    返回 (user, temp_pw, actor)。"""

    async def _no_org(_db: Any) -> None:
        return None

    monkeypatch.setattr(up, "get_default_organization", _no_org)
    monkeypatch.setattr("app.services.org.get_default_organization", _no_org)
    actor = uuid.uuid4()
    async with factory() as db:
        user, temp_pw = await provision_local_user(
            db,
            perms,
            audit,
            username=username,
            name=name,
            email=email,
            groups=[],
            actor_user_id=actor,
            ctx={"request_ip": None, "user_agent": None},
            source="admin_create",
        )
    return user, temp_pw, actor


def mk(name: str, username: str | None = None, phone: str | None = None) -> User:
    return User(name=name, username=username, phone=phone)


async def seed(factory: Any, *users: User) -> None:
    async with factory() as db:
        db.add_all(users)
        await db.commit()


async def load_user(factory: Any, user_id: Any) -> User | None:
    """另会话回读(DB 真相,不吃会话内缓存)。"""
    async with factory() as db:
        return await db.get(User, user_id)


async def load_user_by_username(factory: Any, username: str) -> User | None:
    async with factory() as db:
        res = await db.execute(select(User).where(User.username == username))
        return res.scalars().first()


async def users_count(factory: Any) -> int:
    async with factory() as db:
        res = await db.execute(select(func.count()).select_from(User))
        return int(res.scalar_one())


def events_of(audit: FakeAuditService, event_type: str) -> list[dict[str, Any]]:
    return [d for et, d in audit.records if et == event_type]


def one_event(audit: FakeAuditService, event_type: str) -> dict[str, Any]:
    matches = events_of(audit, event_type)
    assert len(matches) == 1, f"期望恰 1 条 {event_type},实得 {len(matches)}:{audit.records}"
    return matches[0]


# ─── T1/F1/F4/D6:纯手机号 username → 建号即绑 + 双审计 ──────────────────────
async def test_t1_plain_phone_username_binds_automatically(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    perms: StubPermissions,
    audit: FakeAuditService,
) -> None:
    user, temp_pw, _ = await provision(monkeypatch, factory, perms, audit, username=CANDIDATE)

    assert user.username == CANDIDATE
    assert user.phone == CANDIDATE, "F1:归一化命中大陆手机号 → 直接落 users.phone"
    assert verify_password(temp_pw, user.password_hash), "临时密码真跑,hash 可验"
    assert perms.org_calls == [], "org=None 时 add_user_to_organization 跳过"
    # D6 单事件对账要求 user_created 携带绑定结果 → 先 phone_bound 后 user_created
    assert [et for et, _ in audit.records] == ["phone_bound", "user_created"]
    bound = one_event(audit, "phone_bound")
    assert bound["source"] == "auto_bind", "D6:与 backfill/cli、用户自主 bind 可区分"
    assert bound["old_masked"] is None and bound["new_masked"] == MASKED
    assert one_event(audit, "user_created")["auto_phone_bound"] is True


# ─── T2/D5:'.'/'-' 变体归一化命中 → 同 T1 ────────────────────────────────────
async def test_t2_separated_username_normalized_then_binds(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    perms: StubPermissions,
    audit: FakeAuditService,
) -> None:
    assert normalize_phone(CANDIDATE_VARIANT) == CANDIDATE, "D5 归一化单点口径自检"
    user, _temp_pw, _ = await provision(monkeypatch, factory, perms, audit, username=CANDIDATE_VARIANT)

    assert user.username == CANDIDATE_VARIANT, "落库 username 原样,归一化只用于判定"
    assert user.phone == CANDIDATE, "变体折叠为纯号后绑定"
    bound = one_event(audit, "phone_bound")
    assert bound["source"] == "auto_bind" and bound["old_masked"] is None
    assert bound["new_masked"] == MASKED
    assert one_event(audit, "user_created")["auto_phone_bound"] is True


# ─── T3/F1:非手机号三形态 → 不绑、无 phone_bound ─────────────────────────────
@pytest.mark.parametrize(
    "username",
    ["zhangsan", "138001380001", "a13800138000"],
    ids=["plain", "eleven_plus_one_digit", "email_like"],
)
async def test_t3_non_phone_username_not_bound(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    perms: StubPermissions,
    audit: FakeAuditService,
    username: str,
) -> None:
    user, _temp_pw, _ = await provision(monkeypatch, factory, perms, audit, username=username)

    assert user.phone is None, "非手机号形态不自动绑"
    assert events_of(audit, "phone_bound") == []
    assert one_event(audit, "user_created")["auto_phone_bound"] is False


# ─── T4/F2/D2:候选号已被他人 phone 持有 → 建号照常,跳过绑定 ─────────────────
async def test_t4_candidate_phone_taken_skips_bind(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    perms: StubPermissions,
    audit: FakeAuditService,
) -> None:
    holder = mk("占用者", username="alice", phone=CANDIDATE)
    await seed(factory, holder)

    user, _temp_pw, _ = await provision(
        monkeypatch, factory, perms, audit, username=CANDIDATE
    )  # D2:照常建号,绝不 raise

    assert user.phone is None
    kept = await load_user(factory, holder.id)
    assert kept is not None and kept.phone == CANDIDATE, "持有者手机号不被覆盖"
    assert await users_count(factory) == 2, "建号照常成功"
    assert events_of(audit, "phone_bound") == []
    assert one_event(audit, "user_created")["auto_phone_bound"] is False


# ─── T5/F2/D5:归一化折叠冲突 → 建号照常,跳过绑定 ────────────────────────────
async def test_t5_folded_username_conflict_skips_bind(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    perms: StubPermissions,
    audit: FakeAuditService,
) -> None:
    """既有 username=13800138000(phone=None),新建 username=138-0013-8000:
    两 username 不撞唯一约束,折叠预检应命中同号 → 不绑、建号照常。"""
    folded = mk("既有同号", username=CANDIDATE)
    await seed(factory, folded)

    user, _temp_pw, _ = await provision(monkeypatch, factory, perms, audit, username=CANDIDATE_VARIANT)

    assert user.username == CANDIDATE_VARIANT and user.phone is None
    assert await users_count(factory) == 2
    kept = await load_user(factory, folded.id)
    assert kept is not None and kept.phone is None, "折叠冲突不回填既有用户"
    assert events_of(audit, "phone_bound") == []
    assert one_event(audit, "user_created")["auto_phone_bound"] is False


# ─── T6/F3/D2:竞态真撞 uq_users_phone → rollback 跳过,不 raise ─────────────
async def test_t6_race_unique_violation_rolled_back_no_raise(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    perms: StubPermissions,
    audit: FakeAuditService,
) -> None:
    """F3:预检通过、绑定 UPDATE 提交前他人并发持有同号 → 撞真唯一约束,
    实现须 rollback 该 UPDATE 视为跳过(D2:不 raise,账号完好,phone NULL)。

    构造(预检后盲区注入,等效真实竞态窗口):monkeypatch db.execute 透传,
    在 D5 形态的预检 SELECT(含 phone + replace 折叠)返回的瞬间,用同一会话
    补插占用行并独立提交 —— 预检已执行完毕看不到它,后续 UPDATE 提交时
    uq_users_phone 真撞。直接 patch 预检 select 结果不可行,此为最近似构造;
    若实现偏离 D5 钉死的 SQL 形态,fired 断言显式失败提示调整,勿造假绿。"""

    async def _no_org(_db: Any) -> None:
        return None

    monkeypatch.setattr(up, "get_default_organization", _no_org)
    monkeypatch.setattr("app.services.org.get_default_organization", _no_org)

    fired = {"precheck_seen": False}
    rollbacks = {"count": 0}
    actor = uuid.uuid4()

    async with factory() as db:
        orig_execute = db.execute
        orig_commit = db.commit
        orig_rollback = db.rollback

        async def racing_execute(statement: Any, *args: Any, **kw: Any) -> Any:
            result = await orig_execute(statement, *args, **kw)
            sql = str(statement)
            if not fired["precheck_seen"] and "select" in sql.lower() and "phone" in sql and "replace" in sql:
                # 竞态窗口:预检已返回(未命中),并发方此刻提交同号占用行
                fired["precheck_seen"] = True
                db.add(User(name="并发占用者", username="rival_late", phone=CANDIDATE))
                await orig_commit()
            return result

        async def counting_rollback() -> Any:
            rollbacks["count"] += 1
            return await orig_rollback()

        db.execute = racing_execute
        db.rollback = counting_rollback

        user, _temp_pw = await provision_local_user(
            db,
            perms,
            audit,
            username=CANDIDATE,
            name="竞态用户",
            email=None,
            groups=[],
            actor_user_id=actor,
            ctx={"request_ip": None, "user_agent": None},
            source="admin_create",
        )

    assert fired["precheck_seen"], (
        "D5 预检 SQL(含 phone+replace 折叠的 SELECT)未被观察到,竞态桩未触发;"
        "若实现预检形态偏离 D5,请同步调整触发条件,勿放松断言"
    )
    assert rollbacks["count"] >= 1, "撞 uq_users_phone 后未见 rollback(F3 要求回滚 UPDATE)"
    assert user.phone is None
    row = await load_user(factory, user.id)
    assert row is not None, "账号完好(D2:建号主操作不得被竞态阻断)"
    assert row.phone is None, "rollback 后 DB 中 phone 保持 NULL"
    rival = await load_user_by_username(factory, "rival_late")
    assert rival is not None and rival.phone == CANDIDATE, "并发占用行不受 rollback 影响"
    assert events_of(audit, "phone_bound") == [], "竞态跳过零 phone_bound 审计"
    assert one_event(audit, "user_created")["auto_phone_bound"] is False
    assert await users_count(factory) == 2


# ─── T7/F4/D6:user_created 审计既有字段零回归 ────────────────────────────────
async def test_t7_user_created_audit_keys_zero_regression(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    perms: StubPermissions,
    audit: FakeAuditService,
) -> None:
    user, _temp_pw, actor = await provision(
        monkeypatch, factory, perms, audit, username=CANDIDATE, name="审计回归用户"
    )

    created = one_event(audit, "user_created")
    assert set(created) == {
        "user_id",
        "username",
        "name",
        "group_ids",
        "source",
        "created_by",
        "auto_phone_bound",  # 本次唯一新增键(D6)
    }
    assert created["user_id"] == str(user.id)
    assert created["username"] == CANDIDATE
    assert created["name"] == "审计回归用户"
    assert created["group_ids"] == [], "groups=[] 时 group_ids 空列表原样"
    assert created["source"] == "admin_create"
    assert created["created_by"] == str(actor)
    assert user.created_by == actor, "落库 created_by 同步零回归"


# ─── 附加:同库连续建两个非手机号账号,主流程无残留副作用 ─────────────────────
async def test_consecutive_provisions_leave_no_residue(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    perms: StubPermissions,
    audit: FakeAuditService,
) -> None:
    u1, _pw1, _ = await provision(monkeypatch, factory, perms, audit, username="zhangsan")
    u2, _pw2, _ = await provision(monkeypatch, factory, perms, audit, username="lisi")

    assert u1.phone is None and u2.phone is None
    assert await users_count(factory) == 2
    assert events_of(audit, "phone_bound") == []
    assert len(audit.records) == 2, "两次各恰一条 user_created,无残留副作用"
