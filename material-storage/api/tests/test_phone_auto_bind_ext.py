"""建号自动绑定 — 专职测试补充用例(边界 / 审计 actor / 响应 schema)。

承接 tests/test_phone_auto_bind.py(T1-T7)未覆盖的缺口,范式与其一致:
内存 SQLite 真建 users 表(uq_users_phone 生效)+ 审计/权限桩 + monkeypatch
打桩 get_default_organization。新增检查点:

  - 边界:11 位但第二位=2(12 开头)不命中;点号变体 138.0013.8000 归一化命中;
    86 前缀 13 位串按既有归一化口径剥前缀命中(表征测试);直调传带空格
    username 的表征行为(normalize_phone 剥空格 → 命中;UserCreateIn/
    ArtistAccountIn pattern 拒空格,两 API 链路不可达,仅直调可见);
    username=None 直调在重名预检 .lower() 即 AttributeError,零落库零审计。
  - 冲突(P2-2):折叠预检 IN 等值双形态(11 位裸号 / 13 位 86 前缀),他人
    username 折叠后与候选号任一形态等值即跳过(正反两向);新建者自己是 86
    形态且无冲突仍绑,由 86 前缀表征用例回归保护。
  - 审计:phone_bound / user_created 的 actor_user_id 恰为建号人入参
    (既有 FakeAuditService 用 **_kw 吞掉了 actor,从未断言过);user_created
    的 auto_phone_bound 两态在新边界用例下再验一遍。
  - 构造点:DirectoryUserOut.phone 字段存在性 / 类型 / 默认值 / Detail 继承 /
    Page.items 元素 / model_validate 缺省与赋值两态序列化(Pydantic 断言,
    路由四处构造点传参已由静态 diff 核查覆盖,见测试报告)。

测试 ↔ 补充点映射:
  test_ext_12_prefix_eleven_digits_not_hit            边界:12 开头不命中
  test_ext_dot_variant_username_binds                 边界:点号变体命中
  test_ext_86_prefix_username_binds                   边界:86 前缀命中(表征)
  test_ext_holder_86_prefix_username_blocks_new_bind  冲突:他人持 86 形态(P2-2)
  test_ext_reverse_86_form_new_user_skips_on_folded_conflict
                                                      冲突:反向 86 形态新建(P2-2)
  test_ext_whitespace_username_direct_call_characterization
                                                      边界:直调带空格(表征)
  test_ext_username_none_raises_before_any_write      边界:None 直调零副作用
  test_ext_phone_bound_actor_is_provision_actor       审计:actor=建号人
  test_ext_auto_phone_bound_two_states_on_boundaries  审计:两态再验
  test_ext_duplicate_409_precedes_auto_bind           回归:409 先于绑定段
  test_ext_directory_user_out_phone_schema            构造点:schema 断言
"""

from __future__ import annotations

import logging
import uuid
from typing import Any

import pytest
from fastapi import HTTPException
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

import app.services.user_provisioning as up
from app.db.tables import User
from app.models import DirectoryUserDetailOut, DirectoryUserOut, DirectoryUsersPageOut
from app.services.user_provisioning import provision_local_user

CANDIDATE = "13800138000"
MASKED = "138****8000"


# ─── 基建(与 test_phone_auto_bind.py 同款;审计桩额外记录 actor)─────────────
@pytest.fixture
async def factory():
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(User.metadata.create_all, tables=[User.__table__])
    sm = async_sessionmaker(engine, expire_on_commit=False)
    yield sm
    await engine.dispose()


class RecordingAuditService:
    """FakeAuditService 强化版:除 (event_type, details) 外还记录 actor_user_id,
    专补「phone_bound actor=建号人」这条既有用例从未断言的链路。"""

    def __init__(self) -> None:
        self.records: list[dict[str, Any]] = []

    async def write(
        self, *, event_type: str, actor_user_id: Any = None,
        details: dict[str, Any] | None = None, **_kw: Any,
    ) -> Any:
        self.records.append({
            "event_type": event_type,
            "actor_user_id": actor_user_id,
            "details": dict(details or {}),
        })
        return {"event_type": event_type}


class StubPermissions:
    def __init__(self) -> None:
        self.org_calls: list[dict[str, str]] = []

    async def add_user_to_organization(
        self, *, organization_tenant_key: str, user_id: str
    ) -> None:
        self.org_calls.append({
            "organization_tenant_key": organization_tenant_key, "user_id": user_id,
        })


@pytest.fixture
def perms() -> StubPermissions:
    return StubPermissions()


@pytest.fixture
def audit() -> RecordingAuditService:
    return RecordingAuditService()


async def provision(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    perms: StubPermissions,
    audit: RecordingAuditService,
    *,
    username: Any,
) -> tuple[User, str, uuid.UUID]:
    async def _no_org(_db: Any) -> None:
        return None

    monkeypatch.setattr(up, "get_default_organization", _no_org)
    monkeypatch.setattr("app.services.org.get_default_organization", _no_org)
    actor = uuid.uuid4()
    async with factory() as db:
        user, temp_pw = await provision_local_user(
            db, perms, audit,
            username=username,
            name="边界用户",
            email=None,
            groups=[],
            actor_user_id=actor,
            ctx={"request_ip": None, "user_agent": None},
            source="admin_create",
        )
    return user, temp_pw, actor


async def users_count(factory: Any) -> int:
    async with factory() as db:
        res = await db.execute(select(func.count()).select_from(User))
        return int(res.scalar_one())


def events_of(audit: RecordingAuditService, event_type: str) -> list[dict[str, Any]]:
    return [r for r in audit.records if r["event_type"] == event_type]


def one(audit: RecordingAuditService, event_type: str) -> dict[str, Any]:
    matches = events_of(audit, event_type)
    assert len(matches) == 1, f"期望恰 1 条 {event_type},实得 {len(matches)}:{audit.records}"
    return matches[0]


# ─── 边界:11 位但第二位=2(12 开头)→ 不命中 ─────────────────────────────────
async def test_ext_12_prefix_eleven_digits_not_hit(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    perms: StubPermissions,
    audit: RecordingAuditService,
) -> None:
    """12800138000 恰 11 位、纯数字(UserCreateIn pattern 可过,API 可达),
    但第二位 2 ∉ [3-9] → normalize 不命中 → 不绑、零 phone_bound。"""
    user, _pw, _ = await provision(
        monkeypatch, factory, perms, audit, username="12800138000"
    )

    assert user.phone is None
    assert events_of(audit, "phone_bound") == []
    assert one(audit, "user_created")["details"]["auto_phone_bound"] is False


# ─── 边界:点号变体 138.0013.8000 → 归一化命中 ────────────────────────────────
async def test_ext_dot_variant_username_binds(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    perms: StubPermissions,
    audit: RecordingAuditService,
) -> None:
    """点号与连字符同属 D5 折叠字符;pattern 允许 '.',API 可达 → 绑归一化号。"""
    user, _pw, _ = await provision(
        monkeypatch, factory, perms, audit, username="138.0013.8000"
    )

    assert user.username == "138.0013.8000", "落库 username 原样"
    assert user.phone == CANDIDATE, "点号变体归一化后命中 → 绑定"
    bound = one(audit, "phone_bound")
    assert bound["details"]["source"] == "auto_bind"
    assert bound["details"]["old_masked"] is None
    assert bound["details"]["new_masked"] == MASKED
    assert one(audit, "user_created")["details"]["auto_phone_bound"] is True


# ─── 边界:86 前缀 13 位串 → 归一化剥前缀命中(表征测试)──────────────────────
async def test_ext_86_prefix_username_binds(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    perms: StubPermissions,
    audit: RecordingAuditService,
) -> None:
    """8613800138000 共 13 位,但 normalize_phone 既有口径(D5 单点,绑定端点/
    批量脚本同款)剥 86 前缀后命中 → 绑定。非 11 位 ≠ 不命中,判据是归一化产物。"""
    user, _pw, _ = await provision(
        monkeypatch, factory, perms, audit, username="8613800138000"
    )

    assert user.username == "8613800138000"
    assert user.phone == CANDIDATE
    assert one(audit, "phone_bound")["details"]["new_masked"] == MASKED
    assert one(audit, "user_created")["details"]["auto_phone_bound"] is True


# ─── P2-2 冲突:他人 username=86 前缀形态(phone=NULL)→ 新建裸号跳过 ──────────
async def test_ext_holder_86_prefix_username_blocks_new_bind(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    perms: StubPermissions,
    audit: RecordingAuditService,
) -> None:
    """P2-2 主场景(修复前折叠预检只比 11 位裸号 → 误绑 → 两账号「同号」并存):
    存量 username=8613800138000(phone=NULL),新建 username=13800138000 → 候选
    13800138000,他人折叠后 8613800138000 ∈ {candidate, 86+candidate} → 命中
    跳过:照常建号、phone=None、无 phone_bound。与 test_ext_86_prefix_username_binds
    (新建者自己是 86 形态、无冲突仍绑)互补,彼用例即「无冲突仍绑」的回归保护。"""
    holder = User(name="86 形态持有者", username="8613800138000", phone=None)
    async with factory() as db:
        db.add(holder)
        await db.commit()

    user, _pw, _ = await provision(
        monkeypatch, factory, perms, audit, username=CANDIDATE
    )

    assert user.username == CANDIDATE
    assert user.phone is None, "他人持 86 前缀折叠同号 → 跳过绑定(P2-2)"
    assert await users_count(factory) == 2, "冲突跳过但建号照常成功"
    async with factory() as db:
        kept = await db.get(User, holder.id)
    assert kept is not None and kept.phone is None, "冲突不回填既有持有者"
    assert events_of(audit, "phone_bound") == []
    assert one(audit, "user_created")["details"]["auto_phone_bound"] is False


# ─── P2-2 反向:存量 username=裸号,新建 username=86 前缀形态 → 折叠命中跳过 ───
async def test_ext_reverse_86_form_new_user_skips_on_folded_conflict(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    perms: StubPermissions,
    audit: RecordingAuditService,
) -> None:
    """反向:存量 username=13800138000(phone=NULL),新建 username=
    8613800138000 → 新建者候选剥 86 前缀后 13800138000,他人折叠结果(裸号
    本身)∈ IN 双形态 → 命中跳过:照常建号、phone=None、无 phone_bound。"""
    holder = User(name="裸号持有者", username=CANDIDATE, phone=None)
    async with factory() as db:
        db.add(holder)
        await db.commit()

    user, _pw, _ = await provision(
        monkeypatch, factory, perms, audit, username="8613800138000"
    )

    assert user.username == "8613800138000"
    assert user.phone is None, "他人折叠裸号与候选同号 → 跳过绑定"
    assert await users_count(factory) == 2, "冲突跳过但建号照常成功"
    async with factory() as db:
        kept = await db.get(User, holder.id)
    assert kept is not None and kept.phone is None
    assert events_of(audit, "phone_bound") == []
    assert one(audit, "user_created")["details"]["auto_phone_bound"] is False


# ─── 边界:直调传带空格 username(表征;两 API 链路不可达)────────────────────
async def test_ext_whitespace_username_direct_call_characterization(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    perms: StubPermissions,
    audit: RecordingAuditService,
) -> None:
    """表征测试:provision 自身不 strip username,但 normalize_phone 的 D5 口径
    本就剥空白 → 直调带空格 username 仍按归一化号绑定,username 原样带空格落库。
    可达性:UserCreateIn / ArtistAccountIn pattern ^[a-zA-Z0-9._-]+$ 拒空格,
    两 API 链路均不可达,仅服务层直调可见;行为与 F1「归一化后命中」字面一致。"""
    user, _pw, _ = await provision(
        monkeypatch, factory, perms, audit, username=" 13800138000 "
    )

    assert user.username == " 13800138000 ", "provision 不 strip username 本体"
    assert user.phone == CANDIDATE, "normalize 口径剥空白后命中 → 绑定归一化号"


# ─── 边界:username=None 直调 → 预检即崩,零落库零审计 ────────────────────────
async def test_ext_username_none_raises_before_any_write(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    perms: StubPermissions,
    audit: RecordingAuditService,
) -> None:
    """表征测试:username=None 违反签名约束(username: str);当前实现在重名
    预检 username.lower() 即 AttributeError —— 该预检是函数首个 DB 操作、先于
    一切写入,故零落库、零审计、无 phone 残留。可达性:两条 API 链路的 Pydantic
    模型均必填且带 pattern,None 不可达,仅服务层直调可见。"""
    async def _no_org(_db: Any) -> None:
        return None

    monkeypatch.setattr(up, "get_default_organization", _no_org)
    monkeypatch.setattr("app.services.org.get_default_organization", _no_org)
    actor = uuid.uuid4()
    async with factory() as db:
        with pytest.raises(AttributeError):
            await provision_local_user(
                db, perms, audit,
                username=None,  # type: ignore[arg-type]
                name="None 用户",
                email=None,
                groups=[],
                actor_user_id=actor,
                ctx={"request_ip": None, "user_agent": None},
                source="admin_create",
            )

    assert await users_count(factory) == 0, "崩溃发生在任何写入之前,零落库"
    assert audit.records == [], "零审计残留"


# ─── 审计:phone_bound / user_created 的 actor 恰为建号人入参 ─────────────────
async def test_ext_phone_bound_actor_is_provision_actor(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    perms: StubPermissions,
    audit: RecordingAuditService,
) -> None:
    """F4/D6:phone_bound 的 actor_user_id 必须是 provision 的建号人入参
    (与既有 backfill cli / 用户自主 bind 链路区分的第三要素,前两个是
    details.source 与调用路径);user_created 同人。既有桩 **_kw 吞 actor
    从未验过,此用例补上。"""
    user, _pw, actor = await provision(
        monkeypatch, factory, perms, audit, username=CANDIDATE
    )

    bound = one(audit, "phone_bound")
    created = one(audit, "user_created")
    assert bound["actor_user_id"] == actor, "phone_bound actor=建号人入参"
    assert created["actor_user_id"] == actor, "user_created actor=建号人入参"
    assert created["details"]["created_by"] == str(actor)
    assert created["details"]["user_id"] == str(user.id)
    assert isinstance(actor, uuid.UUID) and actor != uuid.UUID(int=0)


# ─── 审计:auto_phone_bound 两态在边界用例下齐备 ──────────────────────────────
async def test_ext_auto_phone_bound_two_states_on_boundaries(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    perms: StubPermissions,
    audit: RecordingAuditService,
) -> None:
    """同一 audit 流水内:命中(点号变体)与不命中(12 开头)各产生恰一条
    user_created,auto_phone_bound 分别 true / false(单事件对账 D6)。"""
    async def _no_org(_db: Any) -> None:
        return None

    monkeypatch.setattr(up, "get_default_organization", _no_org)
    monkeypatch.setattr("app.services.org.get_default_organization", _no_org)
    actor = uuid.uuid4()
    async with factory() as db:
        await provision_local_user(
            db, perms, audit, username="138.0013.8000", name="命中者", email=None,
            groups=[], actor_user_id=actor,
            ctx={"request_ip": None, "user_agent": None}, source="admin_create",
        )
        await provision_local_user(
            db, perms, audit, username="12800138000", name="不命中者", email=None,
            groups=[], actor_user_id=actor,
            ctx={"request_ip": None, "user_agent": None}, source="admin_create",
        )

    created = [r for r in audit.records if r["event_type"] == "user_created"]
    assert len(created) == 2
    flags = sorted(r["details"]["auto_phone_bound"] for r in created)
    assert flags == [False, True], f"两态齐备,实得 {flags}"
    assert len(events_of(audit, "phone_bound")) == 1, "命中侧恰一条 phone_bound"


# ─── 回归:重名 409 预检先于自动绑定段 ────────────────────────────────────────
async def test_ext_duplicate_409_precedes_auto_bind(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    perms: StubPermissions,
    audit: RecordingAuditService,
) -> None:
    """既有 username=13800138000(已绑 phone)再建同 username → 409 在绑定段
    之前抛出:不新增行、无 phone_bound/user_created 审计、持有者 phone 不动。"""
    holder = User(name="既有", username=CANDIDATE, phone=CANDIDATE)
    async with factory() as db:
        db.add(holder)
        await db.commit()

    async def _no_org(_db: Any) -> None:
        return None

    monkeypatch.setattr(up, "get_default_organization", _no_org)
    monkeypatch.setattr("app.services.org.get_default_organization", _no_org)
    actor = uuid.uuid4()
    async with factory() as db:
        with pytest.raises(HTTPException) as ei:
            await provision_local_user(
                db, perms, audit, username=CANDIDATE, name="重名者", email=None,
                groups=[], actor_user_id=actor,
                ctx={"request_ip": None, "user_agent": None}, source="admin_create",
            )
    assert ei.value.status_code == 409
    assert "登录名已存在" in str(ei.value.detail)
    assert await users_count(factory) == 1, "重名不建新行"
    assert audit.records == [], "409 路径零审计(绑定段未触达)"
    async with factory() as db:
        kept = await db.get(User, holder.id)
    assert kept is not None and kept.phone == CANDIDATE


# ─── F2/F1 日志:跳过/成功原因进 ops 日志,且只出现脱敏号 ─────────────────────
async def test_ext_skip_and_bind_logs_masked(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    perms: StubPermissions,
    audit: RecordingAuditService,
    caplog: pytest.LogCaptureFixture,
) -> None:
    """F2 要求跳过原因进 ops 日志;顺带核 PII:日志一律 mask_phone(138****8000),
    完整号不得出现在任何日志行(与审计 new_masked 同口径)。"""
    holder = User(name="占用者", username="alice", phone=CANDIDATE)
    async with factory() as db:
        db.add(holder)
        await db.commit()

    async def _no_org(_db: Any) -> None:
        return None

    monkeypatch.setattr(up, "get_default_organization", _no_org)
    monkeypatch.setattr("app.services.org.get_default_organization", _no_org)
    actor = uuid.uuid4()
    with caplog.at_level(logging.INFO, logger="app.services.user_provisioning"):
        async with factory() as db:
            await provision_local_user(
                db, perms, audit, username=CANDIDATE, name="被跳过者", email=None,
                groups=[], actor_user_id=actor,
                ctx={"request_ip": None, "user_agent": None}, source="admin_create",
            )
            await provision_local_user(
                db, perms, audit, username="13900139000", name="命中者", email=None,
                groups=[], actor_user_id=actor,
                ctx={"request_ip": None, "user_agent": None}, source="admin_create",
            )

    text = caplog.text
    assert "phone auto bind skip occupied" in text, "F2:占用跳过原因进日志"
    assert "phone auto bound" in text, "F1:绑定成功进日志"
    # 本次新增的绑定/跳过日志行必须只带脱敏号;存量 user_created 行裸打 username
    # 属基线既有 ops 口径(非本次 diff 引入),不在本用例断言范围(报告已记 P2 观察)
    bind_lines = [
        r.getMessage() for r in caplog.records
        if r.getMessage().startswith(("phone auto bound", "phone auto bind skip"))
    ]
    assert len(bind_lines) == 2, f"期望两条绑定段日志,实得 {bind_lines}"
    for line in bind_lines:
        assert MASKED in line or "139****9000" in line, f"日志须脱敏:{line}"
        assert CANDIDATE not in line and "13900139000" not in line, \
            f"绑定段日志不得含完整手机号:{line}"


# ─── 构造点:DirectoryUserOut.phone schema 断言(路由传参由静态 diff 核查)────
async def test_ext_directory_user_out_phone_schema() -> None:
    """F5/D3:phone 挂 DirectoryUserOut 基类 → Detail 继承、Page.items 元素继承;
    类型 str|None、默认 None(缺省键序列化为 null,旧调用方不破)。"""
    assert "phone" in DirectoryUserOut.model_fields
    field = DirectoryUserOut.model_fields["phone"]
    assert field.is_required() is False, "phone 必须带默认值,旧构造点漏传不炸"
    args = getattr(field.annotation, "__args__", None)
    assert args is not None and set(args) == {str, type(None)}, \
        f"phone 类型须 str | None,实得 {field.annotation}"

    assert issubclass(DirectoryUserDetailOut, DirectoryUserOut)
    assert "phone" in DirectoryUserDetailOut.model_fields
    assert DirectoryUsersPageOut.model_fields["items"].annotation is not None
    item_arg = DirectoryUsersPageOut.model_fields["items"].annotation.__args__[0]
    assert item_arg is DirectoryUserOut, "Page.items 元素须 DirectoryUserOut(带 phone)"

    # 缺省键 → 序列化 null;赋值 → 原样透传(完整号,不脱敏,D1)
    base = {
        "id": uuid.uuid4(), "username": "zhangsan", "name": "张三", "email": None,
        "is_active": True, "must_change_password": True,
        "created_at": "2026-11-25T00:00:00Z", "resigned_at": None, "login_locked": False,
    }
    out_none = DirectoryUserOut.model_validate(base)
    assert out_none.phone is None
    assert out_none.model_dump()["phone"] is None

    out_bound = DirectoryUserOut.model_validate({**base, "phone": CANDIDATE})
    assert out_bound.phone == CANDIDATE
    assert out_bound.model_dump(mode="json")["phone"] == CANDIDATE
