"""B1b 邮箱账号数据层与最小写入守卫测试(方案 §4 / §5.3.5 / §10.1 Schema 段)。

SQLite 内存库(aiosqlite)+ Base.metadata.create_all:SQLite 支持表达式索引
(uq_users_email_lower 建得起来)但**忽略 postgresql_where** —— 空串会被纳入
唯一索引,所以所有写入路径必须把空串归 NULL(§10.1 口径)。lower(email) 唯一
性、管理员建号/编辑 IntegrityError→409(含大小写变体)、OIDC 占用跳过全部在
真实唯一索引上验证,不依赖 PG 容器(本地 docker 禁止,2026-10-20 立;
迁移 0021 的 PG 实测/btrim 检测留容器集成测试,方案 §10.1 补充分支末两条)。
"""
from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace
from typing import Any

import pytest
from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.db.tables import Base, PasswordResetToken, User
from app.models import UserUpdateIn
from app.routers.directory import update_directory_user
from app.services import user_provisioning
from app.services.auth import OIDCService
from app.services.user_provisioning import provision_local_user
from tests.test_oidc_service import SUB, make_settings

# ─── fakes(管理员链路直调所需的最小依赖面)──────────────────────────────────


class FakeAudit:
    def __init__(self) -> None:
        self.events: list[dict[str, Any]] = []

    async def write(
        self, *, event_type: str, details: dict[str, Any] | None = None, **kwargs: Any
    ) -> None:
        self.events.append({"event_type": event_type, "details": details or {}, **kwargs})


class FakePermissions:
    async def add_user_to_organization(self, **kwargs: Any) -> None:
        return None

    async def add_user_to_group(self, **kwargs: Any) -> None:
        return None


class FakeLocalAuth:
    async def users_login_locked(self, users: list[User]) -> dict[uuid.UUID, bool]:
        return {u.id: False for u in users}


@pytest.fixture
async def db_factory():
    """内存 SQLite,只建 users 表(含 uq_users_email_lower 表达式唯一索引)。"""
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all, tables=[User.__table__])
    factory = async_sessionmaker(engine, expire_on_commit=False)
    yield factory
    await engine.dispose()


def _fake_request() -> SimpleNamespace:
    # update_directory_user 只读 request.client / request.headers(审计 ctx)
    return SimpleNamespace(client=None, headers={})


async def _seed(db_factory, **overrides: Any) -> User:
    base: dict[str, Any] = dict(name="种子", username=f"u{uuid.uuid4().hex[:8]}", is_active=True)
    base.update(overrides)
    async with db_factory() as db:
        u = User(**base)
        db.add(u)
        await db.commit()
        return u


# ─── Schema 段(§10.1:SQLite 建表 / 空串必须归 NULL / 不插两条 email='')─────


async def test_sqlite_builds_lower_email_unique_index(db_factory) -> None:
    """表达式索引在 SQLite 可建;lower(email) 真实拦截大小写重复。"""
    async with db_factory() as db:
        db.add(User(name="A", username="aa", email="alice@example.com"))
        await db.commit()
    async with db_factory() as db:
        db.add(User(name="B", username="bb", email="ALICE@example.com"))
        with pytest.raises(IntegrityError):
            await db.commit()
        await db.rollback()


async def test_two_null_emails_do_not_conflict(db_factory) -> None:
    """NULL 不占唯一索引(允许大量未绑定邮箱账号;谓词排除 NULL 的 PG 同语义)。"""
    await _seed(db_factory, email=None)
    await _seed(db_factory, email=None, name="种子2")
    async with db_factory() as db:
        assert (await db.execute(select(User).where(User.email.is_(None)))).scalars().all()


async def test_two_empty_string_emails_conflict_on_sqlite(db_factory) -> None:
    """SQLite 忽略 postgresql_where → 空串纳入唯一索引:第二条 '' 必须被拒。

    这就是「空串一律归 NULL」的原因(PG 谓词虽排除空串,但写入侧归 NULL 是
    统一口径,方案 §5.3.5 normalize_email 语义)。
    """
    await _seed(db_factory, email="")
    async with db_factory() as db:
        db.add(User(name="B", username="bb", email=""))
        with pytest.raises(IntegrityError):
            await db.commit()
        await db.rollback()


async def test_password_reset_tokens_roundtrip_on_sqlite() -> None:
    """新表在 SQLite 可建可写;token_hash 唯一约束真实生效(供 B3 依赖)。"""
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(
            Base.metadata.create_all,
            tables=[User.__table__, PasswordResetToken.__table__],
        )
    factory = async_sessionmaker(engine, expire_on_commit=False)
    owner = User(name="U", username="uu", is_active=True)
    async with factory() as db:
        db.add(owner)
        await db.commit()
    async with factory() as db:
        db.add(PasswordResetToken(
            user_id=owner.id,
            token_hash="a" * 64,
            expires_at=datetime.now(UTC).replace(microsecond=0) + timedelta(minutes=30),
            email_hash="b" * 64,
            request_ip="127.0.0.1",
            user_agent="x" * 600,  # 服务层写库前应截断 [:512];列宽 512 兜底
        ))
        await db.commit()
    async with factory() as db:
        db.add(PasswordResetToken(
            user_id=owner.id,
            token_hash="a" * 64,  # 重复
            expires_at=datetime.now(UTC),
        ))
        with pytest.raises(IntegrityError):
            await db.commit()
        await db.rollback()
    await engine.dispose()


# ─── 管理员建号:provision_local_user(B1 最小守卫)────────────────────────────


@pytest.fixture
def no_default_org(monkeypatch: pytest.MonkeyPatch) -> None:
    """org 绑定不在本测范围:屏蔽 get_default_organization(避免 Settings 环境依赖)。"""

    async def _none(db: Any) -> None:
        return None

    monkeypatch.setattr(user_provisioning, "get_default_organization", _none)


async def test_provision_normalizes_email(db_factory, no_default_org) -> None:
    """email 写入前 strip().lower();空白串归 NULL。"""
    async with db_factory() as db:
        u1, _pw = await provision_local_user(
            db, FakePermissions(), FakeAudit(),
            username="dave", name="Dave", email="  Dave@Example.COM  ", groups=[],
            actor_user_id=uuid.uuid4(), ctx={}, source="admin_create",
        )
        assert u1.email == "dave@example.com"
    async with db_factory() as db:
        u2, _pw = await provision_local_user(
            db, FakePermissions(), FakeAudit(),
            username="erin", name="Erin", email="   ", groups=[],
            actor_user_id=uuid.uuid4(), ctx={}, source="admin_create",
        )
        assert u2.email is None


async def test_provision_duplicate_email_409_not_500(db_factory, no_default_org) -> None:
    """重复邮箱(含大小写变体)→ 409;不是 500;未落库。"""
    await _seed(db_factory, username="alice1", email="alice@example.com")
    async with db_factory() as db:
        with pytest.raises(HTTPException) as ei:
            await provision_local_user(
                db, FakePermissions(), FakeAudit(),
                username="alice2", name="Alice2", email="ALICE@example.com", groups=[],
                actor_user_id=uuid.uuid4(), ctx={}, source="admin_create",
            )
        assert ei.value.status_code == 409
        assert "该邮箱已被其他账号使用" in str(ei.value.detail)
    async with db_factory() as db:
        n = len((await db.execute(select(User))).scalars().all())
        assert n == 1, "冲突请求不应落库"


# ─── 管理员编辑:update_directory_user(B1 最小守卫)───────────────────────────


async def test_update_duplicate_email_409_case_insensitive(db_factory) -> None:
    """编辑撞他人邮箱(大小写变体)→ 409;目标用户邮箱不变。"""
    admin = await _seed(db_factory, username="admin", email=None)
    await _seed(db_factory, username="bob", email="bob@example.com")
    target = await _seed(db_factory, username="carol", email=None)
    async with db_factory() as db:
        with pytest.raises(HTTPException) as ei:
            await update_directory_user(
                target.id, UserUpdateIn(email="BOB@example.com"), _fake_request(),
                db=db, user=admin, permissions=FakePermissions(),
                audit=FakeAudit(), local_auth=FakeLocalAuth(), ctx={},
            )
        assert ei.value.status_code == 409
        assert "该邮箱已被其他账号使用" in str(ei.value.detail)
        await db.rollback()
    async with db_factory() as db:
        t = await db.get(User, target.id)
        assert t is not None and t.email is None


async def test_update_email_case_only_is_noop(db_factory) -> None:
    """大小写-only 归一化不算变化:不写库、changes 不记 email(方案 §5.3.5)。"""
    admin = await _seed(db_factory, username="admin")
    target = await _seed(db_factory, username="carol", email="carol@example.com")
    audit = FakeAudit()
    async with db_factory() as db:
        resp = await update_directory_user(
            target.id, UserUpdateIn(email="CAROL@example.com"), _fake_request(),
            db=db, user=admin, permissions=FakePermissions(),
            audit=audit, local_auth=FakeLocalAuth(), ctx={},
        )
        assert resp.email == "carol@example.com"
    updated = next(e for e in audit.events if e["event_type"] == "user_updated")
    assert "email" not in updated["details"]["changes"]


async def test_update_email_normalize_and_clear(db_factory) -> None:
    """新值带空白/大写 → 落库前归一;显式 null=清空。"""
    admin = await _seed(db_factory, username="admin")
    target = await _seed(db_factory, username="carol", email=None)
    async with db_factory() as db:
        resp = await update_directory_user(
            target.id, UserUpdateIn(email="Carol@Example.com "), _fake_request(),
            db=db, user=admin, permissions=FakePermissions(),
            audit=FakeAudit(), local_auth=FakeLocalAuth(), ctx={},
        )
        assert resp.email == "carol@example.com"
    async with db_factory() as db:
        resp2 = await update_directory_user(
            target.id, UserUpdateIn(email=None), _fake_request(),
            db=db, user=admin, permissions=FakePermissions(),
            audit=FakeAudit(), local_auth=FakeLocalAuth(), ctx={},
        )
        assert resp2.email is None


# ─── OIDC:upsert_user_from_userinfo 占用跳过(B1 最小守卫,§5.3.5)───────────


def _svc() -> OIDCService:
    return OIDCService(make_settings())


async def test_oidc_new_user_email_occupied_creates_without_email(db_factory) -> None:
    """新建分支:目标邮箱已被他人占用 → 建号不带 email,不 500。"""
    await _seed(db_factory, username="chen", email="chen@example.com",
                oidc_sub="oidc-sub-other")
    svc = _svc()
    try:
        async with db_factory() as db:
            user = await svc.upsert_user_from_userinfo(
                db, {"sub": SUB, "name": "新用户", "email": "CHEN@example.com"},
            )
    finally:
        await svc.close()
    assert user.oidc_sub == SUB
    assert user.email is None


async def test_oidc_sync_keeps_old_email_when_occupied(db_factory) -> None:
    """同步分支:IdP 新邮箱被他人占用 → 保留旧邮箱,其余字段照常同步。"""
    await _seed(db_factory, username="occ", email="new@example.com")
    target = await _seed(db_factory, username="t1", email="old@example.com", oidc_sub=SUB)
    svc = _svc()
    try:
        async with db_factory() as db:
            user = await svc.upsert_user_from_userinfo(
                db, {"sub": SUB, "name": "改名", "email": "new@example.com"},
            )
    finally:
        await svc.close()
    assert user.id == target.id
    assert user.email == "old@example.com"
    assert user.name == "改名"


async def test_oidc_sync_updates_email_when_free(db_factory) -> None:
    """同步分支正路径:新邮箱无人占用 → lower 后写入。"""
    target = await _seed(db_factory, username="t1", email="old@example.com", oidc_sub=SUB)
    svc = _svc()
    try:
        async with db_factory() as db:
            user = await svc.upsert_user_from_userinfo(
                db, {"sub": SUB, "name": "T", "email": "New@Example.com"},
            )
    finally:
        await svc.close()
    assert user.email == "new@example.com"
    async with db_factory() as db:
        t = await db.get(User, target.id)
        assert t is not None and t.email == "new@example.com"


async def test_oidc_new_user_integrity_error_falls_back_to_no_email(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """竞态兜底:占用预检放行但 commit 撞唯一索引 → 去 email 重建,不 500。"""
    await _seed(db_factory, username="occ", email="race@example.com",
                oidc_sub="oidc-sub-other")

    async def _not_taken(db: Any, email: str, **kw: Any) -> bool:
        return False

    svc = _svc()
    monkeypatch.setattr(svc, "_email_taken_by_other", _not_taken)
    try:
        async with db_factory() as db:
            user = await svc.upsert_user_from_userinfo(
                db, {"sub": "sub-race", "name": "R", "email": "race@example.com"},
            )
    finally:
        await svc.close()
    assert user.oidc_sub == "sub-race"
    assert user.email is None


async def test_oidc_sync_integrity_error_keeps_old_email(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """竞态兜底:同步 commit 撞唯一索引 → 回滚保留旧邮箱,sub 绑定/改名不丢。"""
    await _seed(db_factory, username="occ", email="race@example.com")
    target = await _seed(db_factory, username="t1", email="old@example.com", oidc_sub=SUB)

    async def _not_taken(db: Any, email: str, **kw: Any) -> bool:
        return False

    svc = _svc()
    monkeypatch.setattr(svc, "_email_taken_by_other", _not_taken)
    try:
        async with db_factory() as db:
            user = await svc.upsert_user_from_userinfo(
                db, {"sub": SUB, "name": "改名了", "email": "race@example.com"},
            )
    finally:
        await svc.close()
    assert user.email == "old@example.com"
    assert user.name == "改名了"
    async with db_factory() as db:
        t = await db.get(User, target.id)
        assert t is not None
        assert t.email == "old@example.com"
        assert t.oidc_sub == SUB and t.name == "改名了"


# ─── 迁移 0021 链条与纯 SQL 约束(§4.3/§4.4;PG 行为留容器集成测试)──────────


def test_migration_0021_chains_on_0020_and_avoids_orm_import() -> None:
    """revision 链正确;迁移不 import ORM 模型(§4.4:新模型 SELECT 新列撞旧 schema)。"""
    import pathlib

    from alembic.config import Config
    from alembic.script import ScriptDirectory

    api_root = pathlib.Path(__file__).resolve().parents[1]
    script = ScriptDirectory.from_config(Config(str(api_root / "alembic.ini")))
    rev = script.get_revision("20261031_0021")
    assert rev.down_revision == "20261031_0020"
    assert rev.revision == "20261031_0021"

    src = (
        api_root / "app/db/migrations/versions"
        / "2026_10_31_0021_email_account_reset.py"
    ).read_text(encoding="utf-8")
    assert "from app.db" not in src, "迁移必须用 text() 显式 SQL,不 import app.db"
    # 检测 SQL 只输出用户 id,不打印邮箱(§4.3 第 3 步)
    assert "array_agg(id::text)" in src
    assert "lower(btrim(a.username" in src
