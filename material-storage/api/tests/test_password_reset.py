"""找回密码(方案 §5.4,§10.1「忘记密码」段)测试。

SQLite(文件库)+ FakeRedis + FakeMailer + FakeAudit,无容器(2026-10-20 立
「本地 docker 禁止」);advisory lock 分支按方言自动跳过(PG-only)。Redis 键
隔离:每用例全新 FakeRedis / 全新 SQLite 文件,**等价于 autouse 清 pwreset:*
/email:*/auth:*(127.0.0.1/testclient/unknown 桶不会跨用例残留)**;真 TTL 过期
行为(锁/冷却到期恢复)留容器集成测试,FakeRedis 只模拟 ttl() 读数。

§5.5 会话版本 + CLI 脚本用例在 tests/test_session_version.py(单文件 500 行
上限拆分;共享 fakes 从本文件 import,先例 tests/test_email_migration_guards.py)。
"""
from __future__ import annotations

import asyncio
import hashlib
import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.db.tables import (
    Base,
    Organization,
    PasswordResetToken,
    PersonalAccessToken,
    User,
)
from app.deps import get_audit
from app.main import create_app
from app.services import password_reset as pr
from app.services import password_reset_flows as prf
from app.services.auth import OIDCService
from app.services.local_auth import LocalAuthService
from app.services.mailer import MailSendError
from app.settings import Settings

PASS = "passw0rd1"
REQ = "/api/v1/auth/password-reset/request"
VER = "/api/v1/auth/password-reset/verify"
CON = "/api/v1/auth/password-reset/confirm"


# ─── fakes(共享:tests/test_session_version.py 复用)─────────────────────────


class FakeRedis:
    """覆盖 password_reset/email_verification/local_auth 用的 redis 接口子集。

    eval 只实现 rate_limit._INCR_EXPIRE_LUA 语义(INCR + 仅 TTL<0 才 EXPIRE);
    不做真实过期(留容器测试),ttl() 返回定档秒数供 Retry-After 断言。
    """

    def __init__(self) -> None:
        self._store: dict[str, str] = {}
        self._ttl: dict[str, int] = {}
        self.broken = False  # 置 True → 全部命令抛错(RateLimitUnavailable→503 用)

    def _check(self) -> None:
        if self.broken:
            raise ConnectionError("fake redis broken")

    def keys_with_prefix(self, prefix: str) -> list[str]:
        return [k for k in self._store if k.startswith(prefix)]

    async def get(self, key: str) -> str | None:
        self._check()
        return self._store.get(key)

    async def set(self, key: str, value: str, ex: int | None = None,
                  nx: bool = False) -> bool | None:
        self._check()
        if nx and key in self._store:
            return None
        self._store[key] = value
        if ex is not None:
            self._ttl[key] = ex
        return True

    async def delete(self, *keys: str) -> int:
        self._check()
        n = 0
        for k in keys:
            if k in self._store:
                del self._store[k]
                self._ttl.pop(k, None)
                n += 1
        return n

    async def incr(self, key: str) -> int:
        self._check()
        nxt = int(self._store.get(key, 0)) + 1
        self._store[key] = str(nxt)
        return nxt

    async def expire(self, key: str, seconds: int) -> bool:
        self._check()
        self._ttl[key] = seconds
        return True

    async def ttl(self, key: str) -> int:
        self._check()
        return self._ttl.get(key, -2)

    async def eval(self, script: str, numkeys: int, *args: Any) -> int:
        self._check()
        assert "INCR" in script  # 只有 rate_limit 的 INCR+EXPIRE Lua 走这里
        key = str(args[0])
        nxt = int(self._store.get(key, 0)) + 1
        self._store[key] = str(nxt)
        if self._ttl.get(key, -2) < 0:
            self._ttl[key] = int(args[1])
        return nxt

    def pipeline(self) -> FakePipe:
        return FakePipe(self)


class FakePipe:
    def __init__(self, redis: FakeRedis) -> None:
        self._r = redis
        self._dels: list[str] = []

    def delete(self, key: str) -> FakePipe:
        self._dels.append(key)
        return self

    async def execute(self) -> list[int]:
        return [int(self._r._store.pop(k, "") != "") for k in self._dels] or [0]


@dataclass
class FakeMailer:
    """可编程发信:mode=ok / definite(确定失败)/ timeout(阻塞触发结果未知)。"""

    mode: str = "ok"
    sent: list[dict[str, str]] = field(default_factory=list)

    async def __call__(self, settings: Settings, *, to: str, subject: str,
                       body: str, timeout: float | None = None,  # noqa: ASYNC109 — 同 send_mail 签名钉死(§5.6.1)
                       ) -> None:
        if self.mode == "definite":
            raise MailSendError("definite fail", definite=True)
        if self.mode == "timeout":
            await asyncio.sleep(0.15)  # 超过 smtp_total_timeout_seconds=0
        self.sent.append({"to": to, "subject": subject, "body": body})


class FakeAudit:
    def __init__(self) -> None:
        self.events: list[dict[str, Any]] = []

    async def write(self, *, event_type: str, details: dict[str, Any] | None = None,
                    **kwargs: Any) -> None:
        self.events.append({"event_type": event_type, "details": details or {}, **kwargs})

    def of(self, event_type: str) -> list[dict[str, Any]]:
        return [e for e in self.events if e["event_type"] == event_type]


def mk_settings(**overrides: Any) -> Settings:
    base: dict[str, Any] = dict(
        env="test",
        db_url="postgresql+asyncpg://u:p@localhost/db",
        redis_url="redis://localhost:6379/0",
        minio_endpoint_internal="http://minio:9000",
        minio_endpoint_public="http://localhost:9000",
        minio_access_key="k",
        minio_secret_key="s",
        openfga_api_url="http://openfga:8080",
        openfga_store_id="01TEST",
        web_app_base_url="http://localhost/ms-static/web/",
        session_jwt_secret="test-secret",
        email_link_base_url="https://bucket.example.com/ms-static/web/",
    )
    base.update(overrides)
    return Settings(**base)  # type: ignore[arg-type]


@dataclass
class Env:
    app: Any
    client: AsyncClient
    redis: FakeRedis
    audit: FakeAudit
    settings: Settings
    factory: async_sessionmaker
    mailer: FakeMailer
    auth: OIDCService


async def build_env(tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
                    **settings_overrides: Any) -> Env:
    """app + SQLite 文件库 + FakeRedis + FakeMailer/Audit(不跑 lifespan)。

    monkeypatch 打桩 get_sessionmaker(deps / db.session)与三处 get_settings;
    每调用一次全新实例 —— 用例间键/数据零残留(等价 autouse 清理)。
    """
    settings = mk_settings(**settings_overrides)
    redis = FakeRedis()
    audit = FakeAudit()
    mailer = FakeMailer()
    app = create_app()
    app.state.mail_ready = True
    app.state.mail_semaphore = asyncio.Semaphore(4)
    app.state.mail_tasks = set()
    app.state.redis = redis
    app.state.local_auth = LocalAuthService(settings, redis)  # type: ignore[arg-type]
    auth = OIDCService(settings)
    app.state.auth = auth
    db_file = (tmp_path / f"{uuid.uuid4().hex}.db").as_posix()
    engine = create_async_engine(f"sqlite+aiosqlite:///{db_file}")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all, tables=[
            User.__table__, Organization.__table__, PasswordResetToken.__table__,
            PersonalAccessToken.__table__,
        ])
    factory = async_sessionmaker(engine, expire_on_commit=False)
    monkeypatch.setattr("app.db.session.get_sessionmaker", lambda: factory)
    monkeypatch.setattr("app.deps.get_sessionmaker", lambda: factory)
    monkeypatch.setattr("app.deps.get_settings", lambda: settings)
    monkeypatch.setattr("app.routers.password_reset.get_settings", lambda: settings)
    monkeypatch.setattr("app.routers.auth.get_settings", lambda: settings)
    monkeypatch.setattr(prf, "send_mail", mailer)  # 流程层经本模块引用 send_mail
    app.dependency_overrides[get_audit] = lambda: audit
    client = AsyncClient(transport=ASGITransport(app=app), base_url="http://test")
    return Env(app, client, redis, audit, settings, factory, mailer, auth)


@pytest.fixture
async def make_env(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    made: list[AsyncClient] = []

    async def _make(**settings_overrides: Any) -> Env:
        env = await build_env(tmp_path, monkeypatch, **settings_overrides)
        made.append(env.client)
        return env

    yield _make
    for client in made:
        await client.aclose()


# ─── helpers ─────────────────────────────────────────────────────────────────


async def seed_user(env: Env, **overrides: Any) -> User:
    base: dict[str, Any] = dict(
        name="重置用户", username=f"u{uuid.uuid4().hex[:8]}",
        email=f"u{uuid.uuid4().hex[:8]}@example.com", is_active=True,
    )
    base.update(overrides)
    async with env.factory() as db:
        u = User(**base)
        db.add(u)
        await db.commit()
        return u


def local_auth(env: Env) -> LocalAuthService:
    return LocalAuthService(env.settings, env.redis)  # type: ignore[arg-type]


async def login_cookie(env: Env, username: str, password: str) -> str:
    r = await env.client.post("/api/v1/auth/local/login",
                              json={"username": username, "password": password})
    assert r.status_code == 200, r.text
    cookie = r.cookies.get(env.settings.session_cookie_name)
    assert cookie
    return cookie


async def add_pat(env: Env, user_id: uuid.UUID) -> uuid.UUID:
    pat_id = uuid.uuid4()
    async with env.factory() as db:
        db.add(PersonalAccessToken(
            id=pat_id, user_id=user_id, name="t",
            token_hash=hashlib.sha256(b"x").hexdigest(), token_prefix="mspat_xxxxxxxx",
            expires_at=datetime.now(UTC) + timedelta(days=1),
        ))
        await db.commit()
    return pat_id


async def add_token_row(env: Env, user: User, raw: str,
                        *, created_at: datetime | None = None,
                        expires_in_minutes: int = 20) -> None:
    async with env.factory() as db:
        db.add(PasswordResetToken(
            user_id=user.id, token_hash=pr.hash_token(raw),
            expires_at=datetime.now(UTC) + timedelta(minutes=expires_in_minutes),
            email_hash=pr.email_hash_of(user.email),
            created_at=created_at or datetime.now(UTC),
        ))
        await db.commit()


async def token_rows(env: Env, user_id: uuid.UUID) -> list[PasswordResetToken]:
    async with env.factory() as db:
        res = await db.execute(
            select(PasswordResetToken).where(PasswordResetToken.user_id == user_id)
        )
        return list(res.scalars().all())


def mail_token(mailer: FakeMailer) -> str:
    body = mailer.sent[-1]["body"]
    marker = "#token="
    return body[body.index(marker) + len(marker):].split()[0]


def details(audit: FakeAudit, event: str, i: int = -1) -> dict[str, Any]:
    return audit.of(event)[i]["details"]


# ─── request(§5.4.2)──────────────────────────────────────────────────────────
async def test_request_success_flow(make_env) -> None:
    env = await make_env()
    user = await seed_user(env)
    r = await env.client.post(REQ, json={"email": user.email})
    assert r.status_code == 200 and r.json() == {"status": "sent"}, r.text
    rows = await token_rows(env, user.id)
    assert len(rows) == 1
    assert len(rows[0].token_hash) == 64 and rows[0].request_ip
    token = mail_token(env.mailer)
    assert len(token) == 43
    assert hashlib.sha256(token.encode()).hexdigest() == rows[0].token_hash
    assert "https://bucket.example.com/ms-static/web/reset-password#token=" \
        in env.mailer.sent[0]["body"]
    events = env.audit.of("password_reset_requested")
    assert len(events) == 1
    assert events[0]["actor_user_id"] is None
    assert events[0]["auth_method"] == "anonymous"
    assert events[0]["details"]["ok"] is True
    assert env.redis._store.get(pr.send_user_key(user.id)) == "1"
    assert not env.redis.keys_with_prefix("pwreset:fail:")  # 成功清零失败链


async def test_mail_ready_false_503_all_three(make_env) -> None:
    env = await make_env()
    env.app.state.mail_ready = False
    assert (await env.client.post(REQ, json={"email": "a@b.com"})).status_code == 503
    assert (await env.client.post(VER, json={"token": "x" * 43})).status_code == 503
    assert (await env.client.post(
        CON, json={"token": "x" * 43, "new_password": PASS})).status_code == 503


async def test_unknown_email_counts_locks_and_login_unaffected(make_env) -> None:
    env = await make_env()
    for _ in range(5):
        r = await env.client.post(REQ, json={"email": "ghost@example.com"})
        assert r.status_code == 400, r.text
    failed = env.audit.of("password_reset_failed")
    assert [e["details"]["reason"] for e in failed[:5]] == ["not_found"] * 5
    assert any(e["details"]["reason"] == "ip_locked" for e in failed)
    r6 = await env.client.post(REQ, json={"email": "ghost@example.com"})
    assert r6.status_code == 429 and "Retry-After" in r6.headers
    # IP 锁只影响 reset 端点:登录是独立命名空间(D14),不被 pwreset 锁连坐
    user = await seed_user(env, password_hash=local_auth(env).hash_password(PASS))
    lr = await env.client.post("/api/v1/auth/local/login",
                               json={"username": user.username, "password": PASS})
    assert lr.status_code == 200, lr.text


async def test_inactive_user_same_message_counts_failure(make_env) -> None:
    env = await make_env()
    user = await seed_user(env, is_active=False)
    r = await env.client.post(REQ, json={"email": user.email})
    assert r.status_code == 400 and r.text == '{"detail":"该邮箱未绑定任何账号"}'
    assert details(env.audit, "password_reset_failed")["reason"] == "inactive"
    assert env.redis.keys_with_prefix("pwreset:fail:")


async def test_fail_counter_cleared_on_success(make_env) -> None:
    env = await make_env()
    user = await seed_user(env)
    for _ in range(2):
        await env.client.post(REQ, json={"email": "ghost@example.com"})
    assert env.redis.keys_with_prefix("pwreset:fail:")
    assert (await env.client.post(REQ, json={"email": user.email})).status_code == 200
    assert not env.redis.keys_with_prefix("pwreset:fail:")


async def test_invalid_email_422_no_counters(make_env) -> None:
    env = await make_env()
    r = await env.client.post(REQ, json={"email": "not-an-email"})
    assert r.status_code == 422
    assert not env.redis.keys_with_prefix("pwreset:")  # 格式错不参与任何计数


async def test_request_budget_exceeded_no_audit_no_db(make_env) -> None:
    env = await make_env(password_reset_hourly_request_per_ip=2)
    for _ in range(2):
        await env.client.post(REQ, json={"email": "ghost@example.com"})  # 两次 400
    before = len(env.audit.events)
    r = await env.client.post(REQ, json={"email": "ghost@example.com"})
    assert r.status_code == 429 and "Retry-After" in r.headers
    assert len(env.audit.events) == before  # 超预算不写审计、不查库
    async with env.factory() as db:
        n = len((await db.execute(select(PasswordResetToken))).scalars().all())
    assert n == 0


async def test_send_quota_user(make_env) -> None:
    env = await make_env(password_reset_hourly_per_user=1)  # IP 配额走默认 60
    u1 = await seed_user(env)
    assert (await env.client.post(REQ, json={"email": u1.email})).status_code == 200
    r = await env.client.post(REQ, json={"email": u1.email})
    assert r.status_code == 429 and "Retry-After" in r.headers
    assert details(env.audit, "password_reset_failed")["reason"] == "send_quota_user"


async def test_send_quota_ip(make_env) -> None:
    env = await make_env(password_reset_hourly_per_ip=1)  # 用户配额走默认 5
    u1, u2 = await seed_user(env), await seed_user(env)
    assert (await env.client.post(REQ, json={"email": u1.email})).status_code == 200
    r = await env.client.post(REQ, json={"email": u2.email})  # 换用户仍撞 IP 配额
    assert r.status_code == 429
    assert details(env.audit, "password_reset_failed")["reason"] == "send_quota_ip"


async def test_cooldown_double_click_single_token(make_env) -> None:
    env = await make_env()
    user = await seed_user(env)
    r1, r2 = await asyncio.gather(
        env.client.post(REQ, json={"email": user.email}),
        env.client.post(REQ, json={"email": user.email}),
    )
    assert sorted([r1.status_code, r2.status_code]) == [200, 429], (r1.text, r2.text)
    throttled = r1 if r1.status_code == 429 else r2
    assert throttled.headers.get("Retry-After")
    assert len(await token_rows(env, user.id)) == 1  # 冷却挡下并发第二支


async def test_smtp_definite_failure_keeps_old_token(make_env) -> None:
    env = await make_env()
    user = await seed_user(env)
    await add_token_row(env, user, "old-token-raw-value-00000000000000")
    env.mailer.mode = "definite"
    r = await env.client.post(REQ, json={"email": user.email})
    assert r.status_code == 502
    rows = await token_rows(env, user.id)
    assert [row.token_hash for row in rows] == [pr.hash_token("old-token-raw-value-00000000000000")]
    assert details(env.audit, "password_reset_requested")["reason"] == "smtp_failed"
    assert env.redis._store.get(pr.send_user_key(user.id)) is None
    r2 = await env.client.post(REQ, json={"email": user.email})  # 冷却已占位,仍 429
    assert r2.status_code == 429


async def test_smtp_timeout_keeps_recent_two(make_env) -> None:
    env = await make_env(smtp_total_timeout_seconds=0)
    user = await seed_user(env)
    now = datetime.now(UTC)
    await add_token_row(env, user, "old0-raw", created_at=now - timedelta(minutes=10))
    await add_token_row(env, user, "old1-raw", created_at=now - timedelta(minutes=5))
    env.mailer.mode = "timeout"
    r = await env.client.post(REQ, json={"email": user.email})
    assert r.status_code == 502 and "结果未知" in r.text
    await asyncio.sleep(0.3)  # 等 shield 的发送线程收尾(槽按 done_callback 释放)
    rows = await token_rows(env, user.id)
    assert len(rows) == 2  # 新行 + 最近一条旧行;更早旧行被删(≤2)
    hashes = {row.token_hash for row in rows}
    assert pr.hash_token("old0-raw") not in hashes
    assert pr.hash_token("old1-raw") in hashes
    assert details(env.audit, "password_reset_requested")["reason"] == "smtp_timeout"


async def test_request_truncates_4kb_user_agent(make_env) -> None:
    env = await make_env()
    user = await seed_user(env)
    r = await env.client.post(REQ, json={"email": user.email},
                              headers={"User-Agent": "A" * 4096})
    assert r.status_code == 200, r.text
    assert len((await token_rows(env, user.id))[0].user_agent) == 512


async def test_email_changed_invalidates_link(make_env) -> None:
    env = await make_env()
    user = await seed_user(env)
    assert (await env.client.post(REQ, json={"email": user.email})).status_code == 200
    token = mail_token(env.mailer)
    async with env.factory() as db:
        await db.execute(update(User).where(User.id == user.id)
                         .values(email="newaddr@example.com"))
        await db.commit()
    rv = await env.client.post(VER, json={"token": token})
    assert rv.status_code == 400 and "邮箱已变更" in rv.text
    rc = await env.client.post(CON, json={"token": token, "new_password": "newpass1x"})
    assert rc.status_code == 400
    assert details(env.audit, "password_reset_failed")["reason"] == "email_changed"


async def test_redis_down_maps_503(make_env) -> None:
    env = await make_env()
    env.redis.broken = True
    assert (await env.client.post(REQ, json={"email": "a@b.com"})).status_code == 503


# ─── verify(§5.4.3)───────────────────────────────────────────────────────────
async def test_verify_ok_and_invalid_variants(make_env) -> None:
    env = await make_env()
    user = await seed_user(env)
    assert (await env.client.post(REQ, json={"email": user.email})).status_code == 200
    token = mail_token(env.mailer)
    ok = await env.client.post(VER, json={"token": token})
    assert ok.status_code == 200, ok.text
    body = ok.json()
    assert body["valid"] is True and body["expires_at"]
    local, _, domain = user.email.partition("@")
    assert body["email_masked"] == f"{local[:1]}***@{domain}"
    bad = await env.client.post(VER, json={"token": "z" * 43})
    assert bad.status_code == 400
    assert details(env.audit, "password_reset_failed")["reason"] == "bad_token"
    async with env.factory() as db:  # 过期
        await db.execute(update(PasswordResetToken)
                         .where(PasswordResetToken.token_hash == pr.hash_token(token))
                         .values(expires_at=datetime.now(UTC) - timedelta(minutes=1)))
        await db.commit()
    assert (await env.client.post(VER, json={"token": token})).status_code == 400
    assert details(env.audit, "password_reset_failed")["reason"] == "expired_token"


async def test_confirm_budget_shared_verify_confirm(make_env) -> None:
    env = await make_env(password_reset_hourly_confirm_per_ip=2)
    user = await seed_user(env)
    await env.client.post(REQ, json={"email": user.email})
    token = mail_token(env.mailer)
    assert (await env.client.post(VER, json={"token": token})).status_code == 200
    assert (await env.client.post(VER, json={"token": token})).status_code == 200
    r = await env.client.post(VER, json={"token": token})  # 第 3 次(>2)→ 429
    assert r.status_code == 429 and "Retry-After" in r.headers
    r2 = await env.client.post(CON, json={"token": token, "new_password": "newpass1x"})
    assert r2.status_code == 429  # verify/confirm 共用计数


# ─── confirm(§5.4.4)──────────────────────────────────────────────────────────
async def test_confirm_success_full_effects(make_env) -> None:
    env = await make_env()
    la = local_auth(env)
    user = await seed_user(env, password_hash=la.hash_password(PASS),
                           must_change_password=True)
    pat_id = await add_pat(env, user.id)
    old_cookie = await login_cookie(env, user.username, PASS)
    assert (await env.client.post(REQ, json={"email": user.email})).status_code == 200
    token = mail_token(env.mailer)
    await add_token_row(env, user, "unused-other-token-0000000000")  # 应被删(D13)
    r = await env.client.post(CON, json={"token": token, "new_password": "newpass1x"})
    assert r.status_code == 200 and r.json() == {"status": "ok"}, r.text
    async with env.factory() as db:
        fresh = await db.get(User, user.id)
        assert fresh is not None
        assert fresh.must_change_password is False
        assert fresh.email_verified_at is not None  # D4:未验证邮箱借此完成验证
        assert fresh.session_version == 1
        assert la.verify_password("newpass1x", fresh.password_hash)
        pat = await db.get(PersonalAccessToken, pat_id)
        assert pat is not None and pat.revoked_at is not None
        left = (await db.execute(
            select(PasswordResetToken).where(PasswordResetToken.user_id == user.id)
        )).scalars().all()
        assert len(left) == 1 and left[0].used_at is not None
    me = await env.client.get("/api/v1/auth/me",
                              cookies={env.settings.session_cookie_name: old_cookie})
    assert me.status_code == 401  # 旧 cookie 失效(会话版本)
    await login_cookie(env, user.username, "newpass1x")  # 新密码可登录
    done = env.audit.of("password_reset_completed")
    assert len(done) == 1 and done[0]["auth_method"] == "anonymous"
    rev = env.audit.of("token_revoked")
    assert len(rev) == 1 and rev[0]["details"]["reason"] == "password_reset"


async def test_confirm_double_spend(make_env) -> None:
    env = await make_env()
    user = await seed_user(env, password_hash=local_auth(env).hash_password(PASS))
    await env.client.post(REQ, json={"email": user.email})
    token = mail_token(env.mailer)
    # 近并发(错峰起跑,SQLite 单写锁下第二个请求看到 used_at 已置位)
    t1 = asyncio.create_task(env.client.post(
        CON, json={"token": token, "new_password": "newpass1x"}))
    await asyncio.sleep(0.05)
    t2 = asyncio.create_task(env.client.post(
        CON, json={"token": token, "new_password": "otherpw2y"}))
    r1, r2 = await asyncio.gather(t1, t2)
    assert sorted([r1.status_code, r2.status_code]) == [200, 400]
    r3 = await env.client.post(CON, json={"token": token, "new_password": "thirdpw3z"})
    assert r3.status_code == 400  # 已用 token 二次 confirm


async def test_confirm_policy_and_same_password_keep_token(make_env) -> None:
    env = await make_env()
    user = await seed_user(env, password_hash=local_auth(env).hash_password(PASS))
    await env.client.post(REQ, json={"email": user.email})
    token = mail_token(env.mailer)
    assert (await env.client.post(
        CON, json={"token": token, "new_password": "123"})).status_code == 400
    assert details(env.audit, "password_reset_failed")["reason"] == "password_policy"
    assert (await env.client.post(
        CON, json={"token": token, "new_password": PASS})).status_code == 400
    assert details(env.audit, "password_reset_failed")["reason"] == "same_password"
    assert (await token_rows(env, user.id))[0].used_at is None  # 未被消费,仍可用
    r = await env.client.post(CON, json={"token": token, "new_password": "newpass1x"})
    assert r.status_code == 200


async def test_confirm_first_password_on_null_hash(make_env) -> None:
    env = await make_env()
    user = await seed_user(env, password_hash=None)  # OIDC-only 账号(D4)
    await env.client.post(REQ, json={"email": user.email})
    token = mail_token(env.mailer)
    r = await env.client.post(CON, json={"token": token, "new_password": "newpass1x"})
    assert r.status_code == 200, r.text
    await login_cookie(env, user.username, "newpass1x")


async def test_confirm_unlocks_only_user_forms(make_env) -> None:
    env = await make_env()
    user = await seed_user(env, password_hash=local_auth(env).hash_password(PASS))
    # 直接摆锁:user 两形态(username/email)+ name 形态 + 登录 IP 锁(区分命名空间)
    env.redis._store.update({
        f"auth:lock:user:{user.username}": "1",
        f"auth:fail:user:{user.username}": "3",
        f"auth:lock:user:{user.email}": "1",
        f"auth:lock:user:{user.name}": "1",  # name 形态同名共享,匿名重置不许清
        "auth:lock:ip:1.2.3.4": "1",
        f"email:chg:fail:user:{user.id}": "2",
        f"email:chg:lock:user:{user.id}": "1",
        f"email:code:{user.id}": "x",
    })
    await env.client.post(REQ, json={"email": user.email})
    token = mail_token(env.mailer)
    assert (await env.client.post(
        CON, json={"token": token, "new_password": "newpass1x"})).status_code == 200
    store = env.redis._store
    assert f"auth:lock:user:{user.username}" not in store
    assert f"auth:lock:user:{user.email}" not in store
    assert f"auth:lock:user:{user.name}" in store  # name 形态保留
    assert "auth:lock:ip:1.2.3.4" in store  # IP 锁绝不清
    assert not env.redis.keys_with_prefix(f"email:code:{user.id}")
    assert not env.redis.keys_with_prefix("email:chg:")
    await login_cookie(env, user.username, "newpass1x")  # 重置即解锁,立即能登
