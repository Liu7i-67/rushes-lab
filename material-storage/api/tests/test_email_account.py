"""邮箱绑定 / 换绑 / 验证 / 解绑 API 测试(方案 §10.1 邮箱绑定段 + 补充分支段)。

SQLite(aiosqlite 内存库,users + password_reset_tokens,含 uq_users_email_lower
表达式唯一索引)+ FakeRedis(实现本批 Lua 语义:INCR+首次 EXPIRE / HSET+EXPIRE /
HINCRBY+missing)+ FakeMailer(monkeypatch account_security.send_mail)。

隔离钉子(§10.1 测试前置):
- 每个用例独立的 FakeRedis 实例(键隔离;跨用例无 email:* 残留);
- make_user 一律 must_change_password=False(否则 /email/* 先被 403);
- app 级用例 app.state.mail_ready=True 手动置位 + try/finally 由 monkeypatch 恢复;
- B2 三端点(session)用 direct-call 与 httpx app 级两种形态:direct 覆盖业务
  分支,app 级覆盖 PAT 403 / 强制改密 403 / mail_ready 两态 / Retry-After 头。
"""
from __future__ import annotations

import asyncio
import json
import re
import uuid
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace
from typing import Any

import pytest
from fastapi import HTTPException, Request
from fastapi.background import BackgroundTasks
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app import deps as app_deps
from app.db.session import get_db
from app.db.tables import Base, PasswordResetToken, User
from app.deps import CurrentUser
from app.main import create_app
from app.models import (
    EmailCodeConfirmIn,
    EmailCodeIn,
    EmailUnbindIn,
    UserCreateIn,
    UserUpdateIn,
)
from app.routers import account_security
from app.routers.account_security import (
    confirm_email_code,
    request_email_code,
    unbind_email,
)
from app.routers.directory import (
    create_directory_user,
    get_directory_user,
    list_directory_users,
    update_directory_user,
)
from app.services import email_verification as ev
from app.services.audit import AuditService
from app.services.auth import OIDCService
from app.services.email_utils import (
    email_fingerprint,
    has_non_email_login,
    is_email_format_ok,
    mask_email,
    strict_normalize_email,
)
from app.services.local_auth import LocalAuthService
from app.services.passwords import hash_password
from app.services.rate_limit import RateLimitUnavailable, incr_with_ttl
from app.settings import Settings

PASS = "passw0rd"
CODE_RE = re.compile(r"验证码是 (\d{6})")


# ─── 基础设施 ─────────────────────────────────────────────────────────────────


def make_settings(**overrides: Any) -> Settings:
    base: dict[str, Any] = dict(
        env="dev",
        db_url="postgresql+asyncpg://u:p@localhost:5432/x",
        redis_url="redis://localhost:6379/0",
        minio_endpoint_internal="http://minio:9000",
        minio_endpoint_public="http://localhost:9000",
        minio_access_key="ak",
        minio_secret_key="sk",
        openfga_api_url="http://localhost:8080",
        openfga_store_id="store",
        web_app_base_url="http://localhost/ms-static/web/",
        session_jwt_secret="x" * 32,
    )
    base.update(overrides)
    return Settings(**base)


class FakeRedis:
    """实现本批 Lua 语义的 redis.asyncio 子集(FakeRedis 无 eval,§10.1(c))。

    eval 按 account_security/email_verification 的三个脚本分发:INCR+首次
    EXPIRE(不续期)/ HSET 整 hash+EXPIRE / HINCRBY+missing+仅 TTL<0 补 EXPIRE。
    """

    def __init__(self) -> None:
        self._store: dict[str, str] = {}
        self._ttl: dict[str, int] = {}
        self._hashes: dict[str, dict[str, str]] = {}
        self.deleted: list[str] = []

    # 基础键
    async def get(self, key: str) -> str | None:
        return self._store.get(key)

    async def set(
        self, key: str, value: str, ex: int | None = None, nx: bool = False,
    ) -> bool | None:
        if nx and (key in self._store or key in self._hashes):
            return None
        self._store[key] = value
        self._hashes.pop(key, None)
        if ex is not None:
            self._ttl[key] = ex
        return True

    async def delete(self, *keys: str) -> int:
        n = 0
        for k in keys:
            if k in self._store or k in self._hashes:
                n += 1
            self.deleted.append(k)
            self._store.pop(k, None)
            self._hashes.pop(k, None)
            self._ttl.pop(k, None)
        return n

    async def incr(self, key: str) -> int:
        nxt = int(self._store.get(key, 0)) + 1
        self._store[key] = str(nxt)
        return nxt

    async def expire(self, key: str, seconds: int) -> None:
        self._ttl[key] = seconds

    async def ttl(self, key: str) -> int:
        if key not in self._store and key not in self._hashes:
            return -2
        return self._ttl.get(key, -1)

    # hash
    async def hgetall(self, key: str) -> dict[str, str]:
        return dict(self._hashes.get(key, {}))

    # Lua
    def _ttl_of(self, key: str) -> int:
        return self._ttl.get(key, -1)

    async def eval(self, script: str, numkeys: int, *args: Any) -> Any:
        keys = [str(a) for a in args[:numkeys]]
        rest = list(args[numkeys:])
        if "'INCR'" in script and "'HINCRBY'" not in script:
            # rate_limit._INCR_EXPIRE_LUA:INCR + 仅 TTL<0 才 EXPIRE(不续期)
            key, ttl_s = keys[0], int(rest[0])
            count = int(self._store.get(key, 0)) + 1
            self._store[key] = str(count)
            if self._ttl_of(key) < 0:
                self._ttl[key] = ttl_s
            return count
        if "'HSET'" in script and "attempts" in script:
            # email_verification._STORE_CODE_LUA:整 hash 覆盖 + EXPIRE
            key = keys[0]
            self._hashes[key] = {
                "code_hash": str(rest[0]), "email": str(rest[1]),
                "purpose": str(rest[2]), "current_email_hash": str(rest[3]),
                "attempts": "0",
            }
            self._store.pop(key, None)
            self._ttl[key] = int(rest[4])
            return 1
        if "'HINCRBY'" in script:
            # email_verification._ATTEMPT_INCR_LUA:missing / 计数 + 仅 TTL<0 补
            key, ttl_s = keys[0], int(rest[0])
            if key not in self._hashes:
                return "missing"
            h = self._hashes[key]
            n = int(h.get("attempts", 0)) + 1
            h["attempts"] = str(n)
            if self._ttl_of(key) < 0:
                self._ttl[key] = ttl_s
            return n
        raise AssertionError(f"FakeRedis.eval: unhandled script {script[:60]!r}")


class BrokenRedis:
    """任何命令都抛错 —— fail-closed 503 用例。"""

    def __getattr__(self, name: str) -> Any:
        async def _boom(*_a: Any, **_k: Any) -> Any:
            raise ConnectionError("redis down (test)")
        return _boom


class FakeAudit:
    def __init__(self) -> None:
        self.events: list[dict[str, Any]] = []

    async def write(self, *, event_type: str, details: dict[str, Any] | None = None,
                    **kwargs: Any) -> None:
        self.events.append({"event_type": event_type, "details": details or {}, **kwargs})

    def of(self, event_type: str) -> list[dict[str, Any]]:
        return [e for e in self.events if e["event_type"] == event_type]


class MailLog:
    """FakeMailer:monkeypatch account_security.send_mail;error 非空则抛。

    attempted 记录每次构造的邮件(含随后抛错的结果未知/确定失败路径 ——
    超时路径邮件可能已实际送达,验证码必须可用);sent 只记成功。
    """

    def __init__(self) -> None:
        self.sent: list[dict[str, str]] = []
        self.attempted: list[dict[str, str]] = []
        self.error: Exception | None = None

    async def __call__(self, _settings: Any, *, to: str, subject: str, body: str,
                       timeout: float | None = None,  # noqa: ASYNC109  # 对齐 mailer.send_mail 签名
        ) -> None:
        entry = {"to": to, "subject": subject, "body": body}
        self.attempted.append(entry)
        if self.error is not None:
            raise self.error
        self.sent.append(entry)

    def last_code(self) -> str:
        assert self.attempted, "no mail attempted"
        m = CODE_RE.search(self.attempted[-1]["body"])
        assert m, self.attempted[-1]["body"]
        return m.group(1)


class FakePermissions:
    async def add_user_to_organization(self, **kwargs: Any) -> None:
        return None

    async def add_user_to_group(self, **kwargs: Any) -> None:
        return None


class FakeLocalAuth:
    async def users_login_locked(self, users: list[User]) -> dict[uuid.UUID, bool]:
        return {u.id: False for u in users}


class FakeAuditSession:
    """AuditService 单测用:只实现 get/execute/commit。"""

    def __init__(self, user: Any) -> None:
        self._user = user
        self.executed: list[Any] = []

    async def get(self, _cls: Any, _pk: Any) -> Any:
        return self._user

    async def execute(self, stmt: Any) -> None:
        self.executed.append(stmt)

    async def commit(self) -> None:
        return None


@pytest.fixture
async def db_factory():
    """内存 SQLite:users(含 uq_users_email_lower)+ password_reset_tokens;
    Organization/Group/GroupMembership 供管理员建号链路(get_default_organization /
    入组)空表通过。"""
    from app.db.tables import Group, GroupMembership, Organization

    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(
            Base.metadata.create_all,
            tables=[User.__table__, PasswordResetToken.__table__,
                    Organization.__table__, Group.__table__, GroupMembership.__table__],
        )
    factory = async_sessionmaker(engine, expire_on_commit=False)
    yield factory
    await engine.dispose()


_AUTO_USERNAME = object()  # sentinel:不传 username → 自动随机;显式 None → 无登录名


async def make_user(
    db_factory: Any,
    *,
    email: str | None = None,
    username: Any = _AUTO_USERNAME,
    name: str = "测试用户",
    password: str | None = PASS,
    must_change: bool = False,
    email_verified: bool = False,
    oidc_sub: str | None = None,
    is_active: bool = True,
) -> User:
    async with db_factory() as db:
        u = User(
            name=name,
            username=(f"u{uuid.uuid4().hex[:10]}" if username is _AUTO_USERNAME else username),
            email=email,
            password_hash=hash_password(password) if password else None,
            must_change_password=must_change,
            email_verified_at=datetime.now(UTC) if (email_verified and email) else None,
            oidc_sub=oidc_sub,
            is_active=is_active,
        )
        db.add(u)
        await db.commit()
        return u


def _cur(user: User) -> CurrentUser:
    return CurrentUser(id=user.id, name=user.name)


def _fake_request(state: SimpleNamespace) -> SimpleNamespace:
    return SimpleNamespace(
        app=SimpleNamespace(state=state),
        client=SimpleNamespace(host="127.0.0.1"),
        headers={},
    )


class Harness:
    """direct-call 依赖袋:router 三端点 + 管理员编辑,单文件聚合所有注入。"""

    def __init__(
        self, monkeypatch: pytest.MonkeyPatch, db_factory: Any,
        *, mail_ready: bool = True, oidc_enabled: bool = False,
        **settings_overrides: Any,
    ) -> None:
        self.settings = make_settings(**settings_overrides)
        self.redis: Any = FakeRedis()
        self.mail = MailLog()
        self.db_factory = db_factory
        self.audit = FakeAudit()
        monkeypatch.setattr(account_security, "get_settings", lambda: self.settings)
        monkeypatch.setattr(account_security, "send_mail", self.mail)
        # send_mail_quiet(告知邮件)在 email_verification 命名空间引用 send_mail
        from app.services import email_verification as _ev
        monkeypatch.setattr(_ev, "send_mail", self.mail)
        self.state = SimpleNamespace(
            mail_ready=mail_ready,
            mail_semaphore=asyncio.Semaphore(4),
            mail_tasks=set(),
            redis=self.redis,
            auth=SimpleNamespace(enabled=oidc_enabled),
        )
        self.request = _fake_request(self.state)
        self.local_auth = LocalAuthService(self.settings, self.redis)  # type: ignore[arg-type]
        self.ctx: dict[str, str | None] = {"request_ip": "127.0.0.1", "user_agent": "pytest"}

    # ── 三端点直调(每调用独立 db session,贴近 get_db 每请求会话语义)──
    async def code(self, user: User, email: str, password: str = PASS) -> Any:
        async with self.db_factory() as db:
            return await request_email_code(
                self.request, EmailCodeIn(email=email, password=password),
                cur=_cur(user), db=db, local_auth=self.local_auth,
                audit=self.audit, ctx=self.ctx,
            )

    async def confirm(self, user: User, code: str) -> tuple[Any, BackgroundTasks]:
        bg = BackgroundTasks()
        async with self.db_factory() as db:
            resp = await confirm_email_code(
                self.request, EmailCodeConfirmIn(code=code), bg,
                cur=_cur(user), db=db, audit=self.audit, ctx=self.ctx,
            )
        return resp, bg

    async def unbind(self, user: User, password: str = PASS) -> tuple[Any, BackgroundTasks]:
        bg = BackgroundTasks()
        async with self.db_factory() as db:
            resp = await unbind_email(
                self.request, EmailUnbindIn(password=password), bg,
                cur=_cur(user), db=db, local_auth=self.local_auth,
                audit=self.audit, ctx=self.ctx,
            )
        return resp, bg

    # ── 快捷:发码并取回明文码(FakeMailer 正文解析)──
    async def send_code(self, user: User, email: str, password: str = PASS) -> str:
        await self.code(user, email, password)
        return self.mail.last_code()


async def fetch_user(db_factory: Any, user_id: uuid.UUID) -> User:
    async with db_factory() as db:
        u = await db.get(User, user_id)
        assert u is not None
        return u


async def http_exc(coro: Any) -> HTTPException:
    with pytest.raises(HTTPException) as ei:
        await coro
    return ei.value


def status_of(exc: HTTPException) -> int:
    return exc.status_code


# ─── email_utils 单元(§5.3.5)─────────────────────────────────────────────────


def test_strict_normalize_email_valid_and_case() -> None:
    assert strict_normalize_email("  New.Address@Example.COM ") == "new.address@example.com"


@pytest.mark.parametrize("bad", [
    "no-at-sign", "a@b", "a b@x.com", "a<b>@x.com", "a,b@x.com", 'a"b@x.com',
    "a;b@x.com", "bad~addr@example.com", "", "  ",
    "a" * 250 + "@x.com",  # >254
])
def test_strict_normalize_email_rejects(bad: str) -> None:
    with pytest.raises(ValueError, match="email"):
        strict_normalize_email(bad)


def test_is_email_format_ok_for_legacy_stored() -> None:
    assert is_email_format_ok("ok@example.com") is True
    assert is_email_format_ok("legacy~bad@example.com") is False
    assert is_email_format_ok(None) is False
    assert is_email_format_ok("") is False


def test_email_fingerprint_stable_across_case_and_space() -> None:
    assert email_fingerprint(" A@X.com ") == "a@x.com"
    assert email_fingerprint(None) == ""


def test_mask_email_shape_and_255_cap() -> None:
    assert mask_email("alice@example.com") == "a***@example.com"
    assert mask_email(None) is None
    # 254 字符合法邮箱:local 250 + @ + domain 3 → mask 后仍 ≤255(§10.1)
    long_email = ("a" * 250) + "@x.y"
    assert len(long_email) == 254
    assert len(mask_email(long_email) or "") <= 255


def test_has_non_email_login_matrix() -> None:
    def user(username: str | None, oidc_sub: str | None = None) -> User:
        return User(name="n", username=username, oidc_sub=oidc_sub)

    assert has_non_email_login(user("alice"), oidc_enabled=False) is True
    assert has_non_email_login(user(None), oidc_enabled=False) is False
    assert has_non_email_login(user("  "), oidc_enabled=False) is False  # 空串=无
    assert has_non_email_login(user(None, oidc_sub="s"), oidc_enabled=False) is False
    assert has_non_email_login(user(None, oidc_sub="s"), oidc_enabled=True) is True
    assert has_non_email_login(user(None), oidc_enabled=True) is False


# ─── rate_limit 单元(§5.7.2)─────────────────────────────────────────────────


async def test_incr_with_ttl_sets_ttl_once_and_never_renews() -> None:
    r = FakeRedis()
    assert await incr_with_ttl(r, "k", 100) == 1
    assert r._ttl["k"] == 100
    r._ttl["k"] = 42  # 模拟剩余窗口
    assert await incr_with_ttl(r, "k", 100) == 2
    assert r._ttl["k"] == 42, "已有 TTL 不续期(429 重试不滚动窗口)"


async def test_incr_with_ttl_maps_redis_error_to_unavailable() -> None:
    with pytest.raises(RateLimitUnavailable):
        await incr_with_ttl(BrokenRedis(), "k", 100)


# ─── audit actor_email_snapshot 覆盖参数(§5.9)──────────────────────────────


async def test_audit_write_actor_email_snapshot_override() -> None:
    actor = SimpleNamespace(
        feishu_open_id=None, name="甲", email="full@example.com",
    )
    svc = AuditService(FakeAuditSession(actor), request=None)  # type: ignore[arg-type]
    event = await svc.write(
        event_type="email_unbound",
        actor_user_id=uuid.UUID(int=1),
        details={"old_masked": "f***@example.com"},
        actor_email_snapshot="f***@example.com",
    )
    assert event.actor_email_snapshot == "f***@example.com", "覆盖参数生效,完整邮箱不落列"
    assert event.actor_name_snapshot == "甲"  # 其余快照不受影响


# ─── /email/code:主流程与 purpose 三态 ───────────────────────────────────────


async def test_bind_flow_full(db_factory, monkeypatch: pytest.MonkeyPatch) -> None:
    """正常绑定:正确密码 + 正确验证码 → email 小写落库、verified_at 非空、审计 email_verified。"""
    h = Harness(monkeypatch, db_factory)
    user = await make_user(db_factory)

    resp = await h.code(user, "New.Address@Example.com")
    body = json.loads(resp.body)
    assert body == {
        "status": "sent", "masked_email": "n***@example.com", "expires_in": 600,
    }
    assert len(h.mail.sent) == 1
    assert h.mail.sent[0]["to"] == "new.address@example.com"
    assert h.mail.sent[0]["subject"] == "【素材库】邮箱验证码"

    code = h.mail.last_code()
    resp2, _bg = await h.confirm(user, code)
    data = json.loads(resp2.body)
    assert data == {
        "status": "ok", "email": "new.address@example.com",
        "email_verified": True, "action": "bind",
    }
    u = await fetch_user(db_factory, user.id)
    assert u.email == "new.address@example.com"
    assert u.email_verified_at is not None
    events = h.audit.of("email_verified")
    assert len(events) == 1
    assert events[0]["details"] == {"action": "bind", "email_masked": "n***@example.com"}
    assert events[0]["actor_email_snapshot"] == "n***@example.com"
    # 请求/审计快照均为脱敏值,无完整邮箱
    assert all("new.address@example.com" not in str(e) for e in h.audit.events)


async def test_purpose_three_states(db_factory, monkeypatch: pytest.MonkeyPatch) -> None:
    """bind / verify / change 三态:audit purpose 值正确(§10.1)。"""
    h = Harness(monkeypatch, db_factory)

    # bind:当前无邮箱
    u1 = await make_user(db_factory)
    await h.code(u1, "one@example.com")
    assert h.audit.of("email_verification_requested")[-1]["details"]["purpose"] == "bind"

    # verify:目标 == 当前(未验证;清冷却模拟 60s 后)
    u2 = await make_user(db_factory, email="two@example.com", email_verified=False)
    h.redis._store.pop(ev.cooldown_key(u1.id))
    await h.code(u2, "TWO@example.com")
    assert h.audit.of("email_verification_requested")[-1]["details"]["purpose"] == "verify"

    # change:目标 != 当前
    h.redis._store.pop(ev.cooldown_key(u2.id))
    await h.code(u2, "three@example.com")
    assert h.audit.of("email_verification_requested")[-1]["details"]["purpose"] == "change"


async def test_verify_already_verified_400(db_factory, monkeypatch: pytest.MonkeyPatch) -> None:
    h = Harness(monkeypatch, db_factory)
    user = await make_user(db_factory, email="a@example.com", email_verified=True)
    exc = await http_exc(h.code(user, "a@example.com"))
    assert exc.status_code == 400
    assert "已验证" in str(exc.detail)


async def test_verify_legacy_invalid_email_422_at_parse(db_factory) -> None:
    """存量非法格式邮箱:用户原样输入 → Pydantic 422(请求解析期,不消耗预算;
    不做宽松兼容,§10.1)。"""
    from pydantic import ValidationError

    with pytest.raises(ValidationError):
        EmailCodeIn(email="legacy~bad@example.com", password=PASS)


# ─── /email/code:密码失败锁(§5.3.2 第 3-4 步)────────────────────────────────


async def test_password_lock_five_failures_then_429(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    h = Harness(monkeypatch, db_factory)
    user = await make_user(db_factory)

    for i in range(5):
        exc = await http_exc(h.code(user, "a@example.com", password="wrong"))
        assert exc.status_code == 400, i
    # 第 5 次错误已写锁:第 6 次(即使密码正确)429 + Retry-After
    exc = await http_exc(h.code(user, "a@example.com", password=PASS))
    assert exc.status_code == 429
    assert int(exc.headers["Retry-After"]) > 0  # type: ignore[index]
    # wrong_password 审计 5 条(ok=false)
    evs = [e for e in h.audit.of("email_verification_requested")
           if e["details"].get("reason") == "wrong_password"]
    assert len(evs) == 5
    assert len(h.mail.sent) == 0


async def test_password_success_clears_fail_counter(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    h = Harness(monkeypatch, db_factory)
    user = await make_user(db_factory)
    await http_exc(h.code(user, "a@example.com", password="wrong"))  # 计数 1
    assert h.redis._store[ev.password_fail_key(user.id)] == "1"
    await h.code(user, "a@example.com", password=PASS)  # 成功 → 清零
    assert ev.password_fail_key(user.id) not in h.redis._store


async def test_oidc_only_account_cannot_request_code(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """OIDC-only(password_hash NULL):不能自助验证/解绑(§10.1 补充分支)。"""
    h = Harness(monkeypatch, db_factory)
    user = await make_user(db_factory, password=None, oidc_sub="sub-1",
                           email="o@example.com")
    exc = await http_exc(h.code(user, "o@example.com"))
    assert exc.status_code == 400
    assert "尚未设置本地密码" in str(exc.detail)


# ─── /email/code:占用与跨列冲突(§5.3.2 第 7 步)─────────────────────────────


async def test_bind_target_taken_409_with_audit(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """purpose=bind 目标已被他人占用 → 发码阶段 409(不向陌生人发码)+ 审计;
    409 占用尝试也消耗请求预算。"""
    h = Harness(monkeypatch, db_factory)
    await make_user(db_factory, email="shared@example.com")
    user = await make_user(db_factory)

    exc = await http_exc(h.code(user, "SHARED@example.com"))
    assert exc.status_code == 409
    assert "已被其他账号使用" in str(exc.detail)
    assert h.audit.of("email_verification_requested")[-1]["details"]["reason"] == "email_taken"
    assert len(h.mail.sent) == 0
    # 请求预算在密码通过后、占用检查前 INCR(409 也计数,防高速枚举)
    assert h.redis._store[ev.req_budget_key(user.id)] == "1"


async def test_username_cross_conflict_409(db_factory, monkeypatch: pytest.MonkeyPatch) -> None:
    """目标与某账号 lower(username) 相同 → 409 跨列冲突(§10.1)。"""
    h = Harness(monkeypatch, db_factory)
    await make_user(db_factory, username="login@name.com")
    user = await make_user(db_factory)

    exc = await http_exc(h.code(user, "Login@Name.com"))
    assert exc.status_code == 409
    assert "登录名冲突" in str(exc.detail)
    assert h.audit.of("email_verification_requested")[-1]["details"]["reason"] == "username_taken"


async def test_verify_purpose_skips_occupancy_even_if_cross_conflicts(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """purpose=verify 即使与别人 username 冲突也不 409(存量问题由 §4.4 预检处理)。"""
    h = Harness(monkeypatch, db_factory)
    await make_user(db_factory, username="two@example.com")
    user = await make_user(db_factory, email="two@example.com", email_verified=False)

    await h.code(user, "two@example.com")  # 不 409,发码成功
    assert len(h.mail.sent) == 1


# ─── /email/code:配额 / 冷却 / 并发闸 ───────────────────────────────────────


async def test_cooldown_second_request_429_retry_after(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    h = Harness(monkeypatch, db_factory)
    user = await make_user(db_factory)
    await h.code(user, "a@example.com")
    exc = await http_exc(h.code(user, "a@example.com"))
    assert exc.status_code == 429
    assert "发送过于频繁" in str(exc.detail)
    assert int(exc.headers["Retry-After"]) == 60  # type: ignore[index]
    assert len(h.mail.sent) == 1


async def test_daily_quota_429(db_factory, monkeypatch: pytest.MonkeyPatch) -> None:
    """日配额 10:读侧已到上限 → 429(§10.1;先查日配额再占冷却)。"""
    h = Harness(monkeypatch, db_factory)
    user = await make_user(db_factory)
    h.redis._store[ev.daily_quota_key(user.id)] = "10"
    exc = await http_exc(h.code(user, "a@example.com"))
    assert exc.status_code == 429
    assert "今日验证码发送次数已达上限" in str(exc.detail)
    # 冷却未占(日配额在冷却占位之前)
    assert ev.cooldown_key(user.id) not in h.redis._store


async def test_daily_quota_config_driven(db_factory, monkeypatch: pytest.MonkeyPatch) -> None:
    """配置驱动(§5.10):每日上限设为 1 → 首条成功后第 2 条 429(而非 429 on 1st)。"""
    h = Harness(monkeypatch, db_factory, email_code_daily_per_user=1)
    user = await make_user(db_factory)
    await h.code(user, "a@example.com")  # 第 1 条成功(发送后 INCR → quota=1)
    assert h.redis._store[ev.daily_quota_key(user.id)] == "1"
    # 换目标邮箱避开冷却(冷却是 per-user:直接删冷却键模拟 60s 后)
    h.redis._store.pop(ev.cooldown_key(user.id))
    exc = await http_exc(h.code(user, "b@example.com"))
    assert exc.status_code == 429
    assert "今日验证码发送次数已达上限" in str(exc.detail)


async def test_ip_quota_read_blocks_and_incr_only_after_success(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    h = Harness(monkeypatch, db_factory)
    user = await make_user(db_factory)
    ip_key = ev.ip_quota_key("127.0.0.1")
    h.redis._store[ip_key] = "200"
    exc = await http_exc(h.code(user, "a@example.com"))
    assert exc.status_code == 429
    assert "操作过于频繁" in str(exc.detail)
    # 读侧拦截不 INCR
    assert h.redis._store[ip_key] == "200"
    # 成功发送后才 INCR
    h.redis._store.pop(ip_key)
    await h.code(user, "a@example.com")
    assert h.redis._store[ip_key] == "1"


async def test_request_budget_31st_429(db_factory, monkeypatch: pytest.MonkeyPatch) -> None:
    h = Harness(monkeypatch, db_factory)
    user = await make_user(db_factory)
    h.redis._store[ev.req_budget_key(user.id)] = "30"
    exc = await http_exc(h.code(user, "a@example.com"))
    assert exc.status_code == 429
    assert int(exc.headers["Retry-After"]) > 0  # type: ignore[index]


async def test_semaphore_full_rejects_without_sending(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """mail_semaphore 占满 4 槽 → 第 5 个请求 2s 内 429(确定未发送,不占冷却)。"""
    h = Harness(monkeypatch, db_factory)
    user = await make_user(db_factory)
    for _ in range(4):
        await h.state.mail_semaphore.acquire()

    exc = await http_exc(h.code(user, "a@example.com"))
    assert exc.status_code == 429
    assert len(h.mail.sent) == 0
    # 确定未发送:不占冷却(请求预算在拿槽之前已 INCR,属既有语义)
    assert ev.cooldown_key(user.id) not in h.redis._store


# ─── /email/code:SMTP 三态(§5.3.2 第 13 步)─────────────────────────────────


async def test_smtp_definite_failure_keeps_old_code(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """确定失败 → 502、不写新码;用户手里的旧码继续有效(不能先覆盖再发信)。"""
    from app.services.mailer import MailSendError

    h = Harness(monkeypatch, db_factory)
    user = await make_user(db_factory)
    old_code = await h.send_code(user, "a@example.com")
    h.redis._store.pop(ev.cooldown_key(user.id))  # 避开 60s 冷却干扰

    h.mail.error = MailSendError("smtp refused", definite=True)
    exc = await http_exc(h.code(user, "b@example.com"))
    assert exc.status_code == 502
    assert ev.code_key(user.id) in h.redis._hashes, "旧码必须保留(未被失败覆盖)"
    assert h.audit.of("email_verification_requested")[-1]["details"]["reason"] == "smtp_failed"

    h.mail.error = None
    resp, _ = await h.confirm(user, old_code)  # 旧码仍可用(目标仍是 a@example.com)
    assert json.loads(resp.body)["status"] == "ok"


async def test_smtp_timeout_unknown_writes_usable_code(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """结果未知(definite=False)→ 502 但验证码哈希已写入、新码可完成确认(§10.1)。"""
    from app.services.mailer import MailSendError

    h = Harness(monkeypatch, db_factory)
    user = await make_user(db_factory)
    h.mail.error = MailSendError("timeout (result unknown)", definite=False)

    exc = await http_exc(h.code(user, "a@example.com"))
    assert exc.status_code == 502
    assert "结果未知" in str(exc.detail)
    assert h.audit.of("email_verification_requested")[-1]["details"]["reason"] == "smtp_timeout"
    # 邮件可能已送达:新码已写入且可用(attempted 里捕获了正文)
    code = h.mail.last_code()
    resp, _ = await h.confirm(user, code)
    assert json.loads(resp.body)["email"] == "a@example.com"


async def test_store_failure_after_sent_503(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """邮件已发出但 Redis 写码失败 → 503(store_failed),不 200(§10.1)。"""

    class StoreBroken(FakeRedis):
        async def eval(self, script: str, numkeys: int, *args: Any) -> Any:
            if "'HSET'" in script and "attempts" in script:
                raise ConnectionError("store failed (test)")
            return await super().eval(script, numkeys, *args)

    h = Harness(monkeypatch, db_factory)
    user = await make_user(db_factory)
    h.state.redis = StoreBroken()  # 仅 store 脚本炸:冷却/配额照常
    h.state.redis._store = h.redis._store  # type: ignore[attr-defined]
    h.state.redis._ttl = h.redis._ttl  # type: ignore[attr-defined]
    h.state.redis._hashes = h.redis._hashes  # type: ignore[attr-defined]

    exc = await http_exc(h.code(user, "a@example.com"))
    assert exc.status_code == 503
    assert "系统繁忙" in str(exc.detail)
    assert h.audit.of("email_verification_requested")[-1]["details"]["reason"] == "store_failed"


async def test_email_code_redis_failure_503(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """新端点 Redis 故障 → 503(RateLimitUnavailable fail-closed),不是 500。"""
    h = Harness(monkeypatch, db_factory)
    user = await make_user(db_factory)
    h.state.redis = BrokenRedis()
    exc = await http_exc(h.code(user, "a@example.com"))
    assert exc.status_code == 503
    assert "服务暂不可用" in str(exc.detail)


# ─── /email/confirm(§5.3.3)──────────────────────────────────────────────────


async def test_confirm_wrong_code_five_times_then_key_deleted(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """验证码错误 5 次 → key 删除;正确码也 400「请先获取验证码」;重取可继续。"""
    h = Harness(monkeypatch, db_factory)
    user = await make_user(db_factory)
    good = await h.send_code(user, "a@example.com")

    for _ in range(4):  # 第 5 次错误在下面验证
        exc = await http_exc(h.confirm(user, "000000"))
        assert exc.status_code == 400
        assert "验证码错误或已失效" in str(exc.detail)
    # 第 5 次错误达到上限:立即删 key
    exc = await http_exc(h.confirm(user, "000000"))
    assert exc.status_code == 400
    assert ev.code_key(user.id) not in h.redis._hashes
    # 正确码也 400(码已作废,需重新获取)
    exc = await http_exc(h.confirm(user, good))
    assert exc.status_code == 400
    assert "请先获取验证码" in str(exc.detail)
    # 重新获取后可继续
    h.redis._store.pop(ev.cooldown_key(user.id))
    code2 = await h.send_code(user, "a@example.com")
    resp, _ = await h.confirm(user, code2)
    assert json.loads(resp.body)["status"] == "ok"


async def test_confirm_expired_code_400(db_factory, monkeypatch: pytest.MonkeyPatch) -> None:
    """验证码过期(手动删 key)→ 400(§10.1)。"""
    h = Harness(monkeypatch, db_factory)
    user = await make_user(db_factory)
    code = await h.send_code(user, "a@example.com")
    await h.redis.delete(ev.code_key(user.id))
    exc = await http_exc(h.confirm(user, code))
    assert exc.status_code == 400
    assert "请先获取验证码" in str(exc.detail)


async def test_confirm_current_email_changed_400(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """发码后管理员改了邮箱 → current_email_hash 不匹配 → 删 key + 400(§5.3.3 第 5 步)。"""
    h = Harness(monkeypatch, db_factory)
    user = await make_user(db_factory)
    code = await h.send_code(user, "a@example.com")
    # 模拟发码窗口内管理员改邮箱(purpose=bind 时原邮箱为空 → 改成别的)
    async with db_factory() as db:
        u = await db.get(User, user.id)
        assert u is not None
        u.email = "admin-set@example.com"
        await db.commit()
    exc = await http_exc(h.confirm(user, code))
    assert exc.status_code == 400
    assert "邮箱已变更" in str(exc.detail)
    assert ev.code_key(user.id) not in h.redis._hashes


async def test_confirm_bind_deletes_unused_reset_tokens(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """bind/change 且邮箱值变化 → 未用重置 token 作废(§5.3.3 第 6 步,D13)。"""
    h = Harness(monkeypatch, db_factory)
    user = await make_user(db_factory)
    code = await h.send_code(user, "a@example.com")
    async with db_factory() as db:
        db.add(PasswordResetToken(
            user_id=user.id, token_hash="1" * 64,
            expires_at=datetime.now(UTC) + timedelta(minutes=30),
        ))
        await db.commit()
    resp, _ = await h.confirm(user, code)
    assert json.loads(resp.body)["status"] == "ok"
    async with db_factory() as db:
        rows = (await db.execute(select(PasswordResetToken))).scalars().all()
        assert rows == [], "未用 token 应被删除"


async def test_confirm_verify_keeps_reset_tokens(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """purpose=verify 不改邮箱值 → 保留用户手里已有的重置链接(§10.1)。"""
    h = Harness(monkeypatch, db_factory)
    user = await make_user(db_factory, email="a@example.com", email_verified=False)
    async with db_factory() as db:
        db.add(PasswordResetToken(
            user_id=user.id, token_hash="2" * 64,
            expires_at=datetime.now(UTC) + timedelta(minutes=30),
        ))
        await db.commit()
    code = await h.send_code(user, "A@example.com")  # 大小写差异 → 同指纹 → verify
    resp, _ = await h.confirm(user, code)
    data = json.loads(resp.body)
    assert data["action"] == "verify"
    async with db_factory() as db:
        rows = (await db.execute(select(PasswordResetToken))).scalars().all()
        assert len(rows) == 1
        u = await db.get(User, user.id)
        assert u is not None
        assert u.email_verified_at is not None


async def test_change_flow_notify_old_email_and_audit(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """换绑成功:新邮箱已验证、旧邮箱(已验证)收到告知、审计 email_changed。"""
    h = Harness(monkeypatch, db_factory)
    user = await make_user(db_factory, email="old@example.com", email_verified=True)
    async with db_factory() as db:
        db.add(PasswordResetToken(
            user_id=user.id, token_hash="3" * 64,
            expires_at=datetime.now(UTC) + timedelta(minutes=30),
        ))
        await db.commit()

    code = await h.send_code(user, "new@example.com")
    resp, bg = await h.confirm(user, code)
    data = json.loads(resp.body)
    assert data == {
        "status": "ok", "email": "new@example.com",
        "email_verified": True, "action": "change",
    }
    u = await fetch_user(db_factory, user.id)
    assert u.email == "new@example.com" and u.email_verified_at is not None
    async with db_factory() as db:
        assert (await db.execute(select(PasswordResetToken))).scalars().all() == []
    # 告知邮件:BackgroundTasks 注册、指向旧邮箱、正文脱敏
    assert len(bg.tasks) == 1
    await bg()
    assert h.mail.sent[-1]["to"] == "old@example.com"
    assert h.mail.sent[-1]["subject"] == "【素材库】账号邮箱已变更"
    assert "o***@example.com" in h.mail.sent[-1]["body"]
    assert "old@example.com" not in h.mail.sent[-1]["body"]
    events = h.audit.of("email_changed")
    assert len(events) == 1
    assert events[0]["details"] == {
        "old_masked": "o***@example.com", "new_masked": "n***@example.com",
    }
    assert events[0]["actor_email_snapshot"] == "n***@example.com"


async def test_change_from_unverified_old_email_no_notify(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """旧邮箱未验证 → 换绑成功但不发告知(§5.3.1 状态机)。"""
    h = Harness(monkeypatch, db_factory)
    user = await make_user(db_factory, email="old@example.com", email_verified=False)
    code = await h.send_code(user, "new@example.com")
    _resp, bg = await h.confirm(user, code)
    assert len(bg.tasks) == 0
    assert len(h.mail.sent) == 1  # 只有验证码那封


async def test_concurrent_confirm_same_email_one_200_one_409(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """两账号并发 confirm 同一邮箱:自然顺序(预检)与 IntegrityError 兜底都 409。"""
    h = Harness(monkeypatch, db_factory)
    u1 = await make_user(db_factory)
    u2 = await make_user(db_factory)
    c1 = await h.send_code(u1, "shared@example.com")
    c2 = await h.send_code(u2, "shared@example.com")

    resp, _ = await h.confirm(u1, c1)
    assert json.loads(resp.body)["status"] == "ok"
    # 路径 A:第 2 个在步骤 5 复核占用 → 409(并发窗口观测点)+ 审计 email_taken
    exc = await http_exc(h.confirm(u2, c2))
    assert exc.status_code == 409
    assert h.audit.of("email_verification_requested")[-1]["details"]["reason"] == "email_taken"
    u2row = await fetch_user(db_factory, u2.id)
    assert u2row.email is None, "409 不改库"

    # 路径 B:预检被绕过(模拟真正同时写库)→ 唯一索引 + IntegrityError → 409
    # (u3 的码不经 /email/code —— 那会在发码阶段就被 u1 的占用拦下,直接写 Redis)
    u3 = await make_user(db_factory)
    c3 = ev.generate_code()
    await ev.store_code(
        h.redis, ttl_seconds=h.settings.email_code_ttl_seconds, user_id=u3.id,
        code_hash=ev.compute_code_hash(h.settings.session_jwt_secret, u3.id, c3),
        email="shared@example.com", purpose="bind",
        cur_email_hash=ev.current_email_hash(u3.email),
    )

    async def _free(db: Any, email: str, *, exclude_id: Any = None) -> bool:
        return False

    monkeypatch.setattr(ev, "email_taken_by_other", _free)
    monkeypatch.setattr(ev, "username_cross_conflict", _free)
    exc = await http_exc(h.confirm(u3, c3))
    assert exc.status_code == 409
    assert h.audit.of("email_verification_requested")[-1]["details"]["reason"] == "email_taken"
    u3row = await fetch_user(db_factory, u3.id)
    assert u3row.email is None, "IntegrityError 回滚后不改库"


async def test_confirm_redis_failure_503(db_factory, monkeypatch: pytest.MonkeyPatch) -> None:
    h = Harness(monkeypatch, db_factory)
    user = await make_user(db_factory)
    await h.send_code(user, "a@example.com")
    h.state.redis = BrokenRedis()
    exc = await http_exc(h.confirm(user, "123456"))
    assert exc.status_code == 503


# ─── /email/unbind(§5.3.4)───────────────────────────────────────────────────


async def test_unbind_success_full(db_factory, monkeypatch: pytest.MonkeyPatch) -> None:
    """解绑成功:清空 + 删未用 token + DEL email:code + 审计 + 告知(best-effort)。"""
    h = Harness(monkeypatch, db_factory)
    user = await make_user(db_factory, email="bound@example.com", email_verified=True)
    async with db_factory() as db:
        db.add(PasswordResetToken(
            user_id=user.id, token_hash="4" * 64,
            expires_at=datetime.now(UTC) + timedelta(minutes=30),
        ))
        await db.commit()
    # 残留验证码:解绑后必须删(不能靠旧码把邮箱重新绑上)。不经 /email/code
    # 直写 —— 该邮箱已验证,走端点会 400「无需重复验证」
    await ev.store_code(
        h.redis, ttl_seconds=600, user_id=user.id,
        code_hash=ev.compute_code_hash(h.settings.session_jwt_secret, user.id, "123456"),
        email="bound@example.com", purpose="verify",
        cur_email_hash=ev.current_email_hash(user.email),
    )
    assert ev.code_key(user.id) in h.redis._hashes

    resp, bg = await h.unbind(user)
    assert json.loads(resp.body) == {"status": "ok"}
    u = await fetch_user(db_factory, user.id)
    assert u.email is None and u.email_verified_at is None
    async with db_factory() as db:
        assert (await db.execute(select(PasswordResetToken))).scalars().all() == []
    assert ev.code_key(user.id) not in h.redis._hashes
    # 审计:old_masked + actor 快照 = 清空前旧邮箱脱敏
    events = h.audit.of("email_unbound")
    assert len(events) == 1
    assert events[0]["details"] == {"old_masked": "b***@example.com"}
    assert events[0]["actor_email_snapshot"] == "b***@example.com"
    # 告知邮件(旧邮箱已验证才发)
    assert len(bg.tasks) == 1
    await bg()
    assert h.mail.sent[-1]["to"] == "bound@example.com"
    assert h.mail.sent[-1]["subject"] == "【素材库】账号邮箱已解绑"


async def test_unbind_wrong_password_400_counts(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    h = Harness(monkeypatch, db_factory)
    user = await make_user(db_factory, email="a@example.com", email_verified=True)
    exc = await http_exc(h.unbind(user, password="wrong"))
    assert exc.status_code == 400
    assert h.redis._store[ev.password_fail_key(user.id)] == "1"


async def test_unbind_not_bound_400(db_factory, monkeypatch: pytest.MonkeyPatch) -> None:
    h = Harness(monkeypatch, db_factory)
    user = await make_user(db_factory)
    exc = await http_exc(h.unbind(user))
    assert exc.status_code == 400
    assert "当前未绑定邮箱" in str(exc.detail)


async def test_unbind_username_null_rejected(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """username IS NULL 且 OIDC 关闭 → 解绑会把账号锁死 → 400 拒绝(§10.1)。"""
    h = Harness(monkeypatch, db_factory, oidc_enabled=False)
    user = await make_user(db_factory, username=None, email="a@example.com",
                           email_verified=True)
    exc = await http_exc(h.unbind(user))
    assert exc.status_code == 400
    assert "没有独立登录名" in str(exc.detail)
    u = await fetch_user(db_factory, user.id)
    assert u.email == "a@example.com", "拒绝后不改库"


async def test_unbind_oidc_enabled_allows(db_factory, monkeypatch: pytest.MonkeyPatch) -> None:
    """oidc_enabled 且 oidc_sub 非空 → 有 IdP 登录方式,允许解绑。"""
    h = Harness(monkeypatch, db_factory, oidc_enabled=True)
    user = await make_user(db_factory, username=None, oidc_sub="sub-x",
                           email="a@example.com", email_verified=True)
    resp, _ = await h.unbind(user)
    assert json.loads(resp.body) == {"status": "ok"}


async def test_unbind_mail_ready_false_still_works(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """mail_ready=false:解绑不依赖 SMTP,仍 200(§5.3.4 第 1 步)。"""
    h = Harness(monkeypatch, db_factory, mail_ready=False)
    user = await make_user(db_factory, email="a@example.com", email_verified=True)
    resp, bg = await h.unbind(user)
    assert json.loads(resp.body) == {"status": "ok"}
    # 告知 best-effort:bg 任务仍注册;执行时 send_mail 抛 definite 错误被吞
    await bg()
    u = await fetch_user(db_factory, user.id)
    assert u.email is None


async def test_code_confirm_mail_ready_false_503(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """mail_ready=false:/email/code 与 /email/confirm 均 503(§10.1)。"""
    h = Harness(monkeypatch, db_factory, mail_ready=False)
    user = await make_user(db_factory)
    exc = await http_exc(h.code(user, "a@example.com"))
    assert exc.status_code == 503
    assert "邮箱功能未启用" in str(exc.detail)
    exc2 = await http_exc(h.confirm(user, "123456"))
    assert exc2.status_code == 503


async def test_unbind_redis_failure_503(db_factory, monkeypatch: pytest.MonkeyPatch) -> None:
    """unbind 的 Redis 故障仍 503(fail-closed,§5.8 契约表)。"""
    h = Harness(monkeypatch, db_factory)
    user = await make_user(db_factory, email="a@example.com", email_verified=True)
    h.state.redis = BrokenRedis()
    exc = await http_exc(h.unbind(user))
    assert exc.status_code == 503


# ─── 管理员建号/编辑(§5.3.5 管理员段)───────────────────────────────────────


def _admin_request(redis: Any, *, oidc_enabled: bool = False) -> SimpleNamespace:
    return SimpleNamespace(
        client=None, headers={},
        app=SimpleNamespace(state=SimpleNamespace(
            auth=SimpleNamespace(enabled=oidc_enabled), redis=redis,
        )),
    )


async def _admin_ctx(db_factory: Any, h: Harness, *, oidc_enabled: bool = False) -> dict[str, Any]:
    _ = db_factory
    return {
        "request": _admin_request(h.redis, oidc_enabled=oidc_enabled),
        "permissions": FakePermissions(), "audit": h.audit,
        "local_auth": FakeLocalAuth(), "ctx": {"request_ip": "127.0.0.1", "user_agent": "t"},
        "admin": CurrentUser(id=uuid.uuid4(), name="admin"),
    }


async def test_admin_create_email_taken_409(db_factory, monkeypatch: pytest.MonkeyPatch) -> None:
    h = Harness(monkeypatch, db_factory)
    await make_user(db_factory, email="dup@example.com")
    c = await _admin_ctx(db_factory, h)
    with pytest.raises(HTTPException) as ei:
        await create_directory_user(
            UserCreateIn(username="newbie", name="N", email="DUP@example.com"),
            c["request"], db=_session(db_factory), user=c["admin"],
            permissions=c["permissions"], audit=c["audit"],
            local_auth=c["local_auth"], ctx=c["ctx"],
        )
    assert ei.value.status_code == 409
    assert "已被其他账号使用" in str(ei.value.detail)


async def test_admin_create_cross_conflict_409(db_factory, monkeypatch: pytest.MonkeyPatch) -> None:
    """管理员建号:email 与某账号 lower(username) 相同 → 409 跨列冲突。"""
    h = Harness(monkeypatch, db_factory)
    await make_user(db_factory, username="someone@x.com")
    c = await _admin_ctx(db_factory, h)
    with pytest.raises(HTTPException) as ei:
        await create_directory_user(
            UserCreateIn(username="newbie2", name="N", email="SomeOne@X.com"),
            c["request"], db=_session(db_factory), user=c["admin"],
            permissions=c["permissions"], audit=c["audit"],
            local_auth=c["local_auth"], ctx=c["ctx"],
        )
    assert ei.value.status_code == 409
    assert "登录名冲突" in str(ei.value.detail)


def test_admin_create_strict_email_422_at_model() -> None:
    """UserCreateIn 严格校验(无存量值可以严格,§5.3.5):宽松正则放行、严格拒绝。"""
    from pydantic import ValidationError

    with pytest.raises(ValidationError):
        UserCreateIn(username="strict1", name="S", email="bad~addr@example.com")


def _session(db_factory: Any) -> Any:
    return db_factory()


async def test_admin_update_email_change_clears_verification_and_cleans(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """管理员改邮箱:verified 清空、未用重置 token 删除、DEL email:code、
    响应带 email_verified=False(四处构造点之一)。"""
    h = Harness(monkeypatch, db_factory)
    user = await make_user(db_factory, email="old@example.com", email_verified=True)
    async with db_factory() as db:
        db.add(PasswordResetToken(
            user_id=user.id, token_hash="5" * 64,
            expires_at=datetime.now(UTC) + timedelta(minutes=30),
        ))
        await db.commit()
    h.redis._hashes[ev.code_key(user.id)] = {"code_hash": "x"}  # 残留验证码

    c = await _admin_ctx(db_factory, h)
    resp = await update_directory_user(
        user.id, UserUpdateIn(email="New@Example.com"), c["request"],
        db=_session(db_factory), user=c["admin"], permissions=c["permissions"],
        audit=c["audit"], local_auth=c["local_auth"], ctx=c["ctx"],
    )
    assert resp.email == "new@example.com"
    assert resp.email_verified is False
    u = await fetch_user(db_factory, user.id)
    assert u.email == "new@example.com" and u.email_verified_at is None
    async with db_factory() as db:
        assert (await db.execute(select(PasswordResetToken))).scalars().all() == []
    assert ev.code_key(user.id) in h.redis.deleted, "改邮箱后 DEL email:code"


async def test_admin_update_strict_only_for_changed_value(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """严格校验仅对变更值:回显未变更的存量非法地址不 422(键存在但值没变);
    改成另一个非法值(宽松过、严格不过)→ 422。"""
    h = Harness(monkeypatch, db_factory)
    user = await make_user(db_factory, email="legacy~bad@example.com")
    c = await _admin_ctx(db_factory, h)
    # 值未变:原样回显提交 → 不 422、不清理
    resp = await update_directory_user(
        user.id, UserUpdateIn(email="legacy~bad@example.com"), c["request"],
        db=_session(db_factory), user=c["admin"], permissions=c["permissions"],
        audit=c["audit"], local_auth=c["local_auth"], ctx=c["ctx"],
    )
    assert resp.email == "legacy~bad@example.com"
    # 不带 email 键的 PATCH:不触发任何邮箱逻辑(AdminUsersPage 未改邮箱不发键)
    resp2 = await update_directory_user(
        user.id, UserUpdateIn(name="只改名"), c["request"],
        db=_session(db_factory), user=c["admin"], permissions=c["permissions"],
        audit=c["audit"], local_auth=c["local_auth"], ctx=c["ctx"],
    )
    assert resp2.email == "legacy~bad@example.com"
    # 变更为另一个严格不过的值 → 422
    with pytest.raises(HTTPException) as ei:
        await update_directory_user(
            user.id, UserUpdateIn(email="worse~one@example.com"), c["request"],
            db=_session(db_factory), user=c["admin"], permissions=c["permissions"],
            audit=c["audit"], local_auth=c["local_auth"], ctx=c["ctx"],
        )
    assert ei.value.status_code == 422


async def test_admin_update_clear_email_guards(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """清空 email:在职且无独立登录名 → 400;停用账号允许清空(回收邮箱场景)。"""
    h = Harness(monkeypatch, db_factory)
    locked = await make_user(db_factory, username=None, email="a@example.com",
                             email_verified=True)
    c = await _admin_ctx(db_factory, h)
    with pytest.raises(HTTPException) as ei:
        await update_directory_user(
            locked.id, UserUpdateIn(email=None), c["request"],
            db=_session(db_factory), user=c["admin"], permissions=c["permissions"],
            audit=c["audit"], local_auth=c["local_auth"], ctx=c["ctx"],
        )
    assert ei.value.status_code == 400
    assert "独立登录名" in str(ei.value.detail)

    gone = await make_user(db_factory, username=None, email="b@example.com",
                           is_active=False)
    resp = await update_directory_user(
        gone.id, UserUpdateIn(email=None), c["request"],
        db=_session(db_factory), user=c["admin"], permissions=c["permissions"],
        audit=c["audit"], local_auth=c["local_auth"], ctx=c["ctx"],
    )
    assert resp.email is None
    u = await fetch_user(db_factory, gone.id)
    assert u.email is None


async def test_directory_email_verified_four_endpoints(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """四个 DirectoryUserOut 构造点(列表/建号/详情/编辑)逐一断言 email_verified 真值。"""
    h = Harness(monkeypatch, db_factory)
    verified = await make_user(db_factory, email="v@example.com", email_verified=True)
    unverified = await make_user(db_factory, email="u@example.com", email_verified=False)
    c = await _admin_ctx(db_factory, h)

    page = await list_directory_users(
        q="", is_active=None, limit=50, offset=0,
        db=_session(db_factory), user=c["admin"], local_auth=c["local_auth"],
    )
    by_id = {str(item.id): item for item in page.items}
    assert by_id[str(verified.id)].email_verified is True
    assert by_id[str(unverified.id)].email_verified is False

    created = await create_directory_user(
        UserCreateIn(username="fresh1", name="F", email="fresh@example.com"),
        c["request"], db=_session(db_factory), user=c["admin"],
        permissions=c["permissions"], audit=c["audit"],
        local_auth=c["local_auth"], ctx=c["ctx"],
    )
    assert created.email_verified is False, "管理员建号不置已验证"

    detail = await get_directory_user(
        verified.id, db=_session(db_factory), user=c["admin"],
        local_auth=c["local_auth"],
    )
    assert detail.email_verified is True

    edited = await update_directory_user(
        unverified.id, UserUpdateIn(name="改名"), c["request"],
        db=_session(db_factory), user=c["admin"], permissions=c["permissions"],
        audit=c["audit"], local_auth=c["local_auth"], ctx=c["ctx"],
    )
    assert edited.email_verified is False


# ─── app 级:PAT 403 / 强制改密 403 / mail_ready 两态 / /me(§10.1)────────────


def _build_app(
    monkeypatch: pytest.MonkeyPatch, db_factory: Any, settings: Settings,
    redis: Any, audit: FakeAudit,
) -> Any:
    app = create_app()
    app.state.mail_ready = True
    app.state.redis = redis
    app.state.local_auth = LocalAuthService(settings, redis)  # type: ignore[arg-type]
    app.state.auth = OIDCService(settings)
    app.state.mail_semaphore = asyncio.Semaphore(4)
    app.state.mail_tasks = set()
    app.state.permissions = SimpleNamespace()
    monkeypatch.setattr(account_security, "get_settings", lambda: settings)
    monkeypatch.setattr(app_deps, "get_settings", lambda: settings)
    monkeypatch.setattr(app_deps, "get_sessionmaker", lambda: db_factory)

    async def _db() -> Any:
        async with db_factory() as session:
            yield session

    async def _audit() -> Any:
        yield audit

    app.dependency_overrides[get_db] = _db
    app.dependency_overrides[app_deps.get_audit] = _audit
    return app


async def test_pat_identity_403_on_email_endpoints(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """PAT 一律 403(require_session_auth,与改密同口径)。"""
    settings = make_settings()
    audit = FakeAudit()
    redis: Any = FakeRedis()
    app = _build_app(monkeypatch, db_factory, settings, redis, audit)

    async def _pat_identity(request: Request) -> CurrentUser:
        request.state.auth_method = "pat"
        return CurrentUser(id=uuid.uuid4(), name="pat")

    app.dependency_overrides[app_deps.get_current_user] = _pat_identity
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        for path in ("/api/v1/auth/email/code", "/api/v1/auth/email/confirm",
                     "/api/v1/auth/email/unbind"):
            r = await ac.post(path, json={})
            assert r.status_code == 403, (path, r.text)
            assert "令牌不允许" in r.json()["detail"]


async def test_must_change_password_blocks_email_endpoints(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """强制改密期间 /email/* → 403(白名单只有 me/change_password/logout)。"""
    settings = make_settings()
    audit = FakeAudit()
    redis: Any = FakeRedis()
    app = _build_app(monkeypatch, db_factory, settings, redis, audit)
    user = await make_user(db_factory, must_change=True)
    token = app.state.auth.encode_session(user)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        ac.cookies.set(settings.session_cookie_name, token)
        for path in ("/api/v1/auth/email/code", "/api/v1/auth/email/confirm",
                     "/api/v1/auth/email/unbind"):
            r = await ac.post(path, json={})
            assert r.status_code == 403, (path, r.text)


async def test_mail_ready_false_code_503_unbind_200_app_level(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """app 级:mail_ready=false → /email/* 503 且 /email/unbind 仍 200(§10.1)。"""
    settings = make_settings()
    audit = FakeAudit()
    redis: Any = FakeRedis()
    app = _build_app(monkeypatch, db_factory, settings, redis, audit)
    app.state.mail_ready = False
    user = await make_user(db_factory, email="a@example.com", email_verified=True)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        ac.headers["X-User-Id"] = str(user.id)
        r1 = await ac.post("/api/v1/auth/email/code",
                           json={"email": "a@example.com", "password": PASS})
        assert r1.status_code == 503
        r2 = await ac.post("/api/v1/auth/email/unbind", json={"password": PASS})
        assert r2.status_code == 200, r2.text
        u = await fetch_user(db_factory, user.id)
        assert u.email is None


async def test_me_returns_email_verified(db_factory, monkeypatch: pytest.MonkeyPatch) -> None:
    """GET /auth/me 返回 email_verified(= bool(email and verified_at),§5.8)。"""
    settings = make_settings()
    audit = FakeAudit()
    redis: Any = FakeRedis()
    app = _build_app(monkeypatch, db_factory, settings, redis, audit)
    verified = await make_user(db_factory, email="v@example.com", email_verified=True)
    plain = await make_user(db_factory)
    cleared = await make_user(db_factory, email="c@example.com", email_verified=True)
    # 模拟「邮箱已清空但 verified_at 残留」:直接落库不一致态
    async with db_factory() as db:
        row = await db.get(User, cleared.id)
        assert row is not None
        row.email = None
        await db.commit()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        for uid, expected in ((verified, True), (plain, False), (cleared, False)):
            ac.headers["X-User-Id"] = str(uid.id)
            r = await ac.get("/api/v1/auth/me")
            assert r.status_code == 200, r.text
            assert r.json()["email_verified"] is expected


async def test_email_code_429_retry_after_header_app_level(
    db_factory, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """429 响应带 Retry-After 头(§5.7.4;httpx 直断言)。"""
    settings = make_settings()
    audit = FakeAudit()
    redis: Any = FakeRedis()
    app = _build_app(monkeypatch, db_factory, settings, redis, audit)
    user = await make_user(db_factory)
    mail = MailLog()
    monkeypatch.setattr(account_security, "send_mail", mail)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        ac.headers["X-User-Id"] = str(user.id)
        r1 = await ac.post("/api/v1/auth/email/code",
                           json={"email": "a@example.com", "password": PASS})
        assert r1.status_code == 200, r1.text
        r2 = await ac.post("/api/v1/auth/email/code",
                           json={"email": "a@example.com", "password": PASS})
        assert r2.status_code == 429
        assert int(r2.headers["Retry-After"]) > 0
