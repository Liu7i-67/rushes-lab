"""W1 管理员重置登录锁定 — 集成测试(容器内跑,面向契约)。

唯一需求依据:`docs/qdev/2026-10-17-six-optimizations.md` §3.1(W1 解锁接口契约)+
§4(事件命名 user_login_unlocked / local_login_locked)+ §5(测试功能点 W1 行);
上游方案 `rushes-spec/material-storage/admin-audit-folder-mobile-optimization-plan.md`
§1(现状机制/实施方案/验收标准)。写法仿 tests/test_local_auth_integration.py
(httpx ASGITransport + 直插 User 行 + Redis key 清理惯例)。

契约要点(后端包1并行开发中,冲突以需求文档 §3.1 为准):
  - POST /api/v1/admin/directory/users/{user_id}/unlock,守门 require_system_admin
    → 200 `{"cleared_user_forms": [...], "cleared_ips": [...], "was_locked": bool}`
    行为:DEL auth:lock:user/fail:user:{u},u ∈ {username, email, name} 非空去重 lower();
    IP 连带清 = 审计反查近 24h local_login_failed(details-username 按 lower 比对)的
    request_ip 去重集 → DEL auth:lock:ip/fail:ip:{ip};404 用户不存在;
    审计 user_login_unlocked(details 记形态与 IP 集)
  - DirectoryUserOut 增 login_locked: bool(列表端点批量 MGET 三形态 user 锁 key;
    只反映 user 维度,IP 维度锁不在内)
  - reset-password 顺带清三形态 user 维度锁与失败计数(与 unlock 共用
    clear_locks;IP 维度不在此连带清,由 unlock 连带清或等 TTL)
  - 第 5 次失败触发锁时补写审计 local_login_locked(details: username/维度)
  - 一切 key 必须 lower()

前置(同 test_local_auth_integration.py):seed_demo_data.py 已跑过
(Evan = 系统 admin,X-User-Id dev 通道);ms-db / redis 可达。

清理惯例:用户行 teardown 删;auth:fail:*/auth:lock:* 逐测试 SCAN 兜底清
(共享容器 + 共享 127.0.0.1 IP 桶,不 flush 会污染同批其他登录用例)。
"""
from __future__ import annotations

import json
import uuid
from datetime import UTC, datetime
from typing import Any

import pytest
from httpx import ASGITransport, AsyncClient
from redis.asyncio import from_url
from sqlalchemy import delete, select

from app.db.session import get_sessionmaker
from app.db.tables import AuditEvent, User
from app.main import create_app
from app.services.local_auth import (
    _FAIL_IP_KEY,
    _LOCK_IP_KEY,
    _LOCK_USER_KEY,
    LocalAuthService,
)
from app.settings import Settings, get_settings

PASS_OK = "passw0rd"
PASS_WRONG = "wrong1x"

EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"        # 系统 admin(seed 契约账号)
OUTSIDER_ID = "00000000-0000-0000-0000-0000000000aa"    # 非系统 admin(seed 契约账号)

UNLOCK_URL = "/api/v1/admin/directory/users/{user_id}/unlock"
RESET_URL = "/api/v1/admin/directory/users/{user_id}/reset-password"
LOGIN_URL = "/api/v1/auth/local/login"
USERS_URL = "/api/v1/admin/directory/users"

# ASGI transport 下 request.client.host 的两个历史形态(见 test_local_auth_integration
# 的清理注释):审计反查到的 request_ip 两者必居其一
ASGI_IPS = ("127.0.0.1", "testclient")


def _h(uid: str = EVAN_ID) -> dict[str, str]:
    return {"X-User-Id": uid}


def _uname(prefix: str) -> str:
    return f"ul_{prefix}_{uuid.uuid4().hex[:8]}"


def make_settings(**overrides: Any) -> Settings:
    base: dict[str, Any] = dict(
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


@pytest.fixture(autouse=True)
async def _cleanup_auth_state_after_test(client: AsyncClient):
    """每测试后:清 client cookie + SCAN 清 auth:fail:*/auth:lock:* 全部键。

    本模块所有用例都在制造登录失败计数/锁,而 ASGI client 的请求恒来自同一 IP
    (127.0.0.1),ghost username 的 key 也不在 make_user 的定向清理范围内 ——
    逐测试 SCAN 兜底清(与 test_local_auth_integration._flush_auth_rate_keys
    同款,从"逐测试 try/finally"提为 autouse,防新增用例漏清)。
    session 级 client 跨测试留 cookie(stateless JWT 不过期)会串测试,一并清。
    """
    yield
    client.cookies.clear()
    try:
        redis = from_url(str(get_settings().redis_url), decode_responses=True)
        try:
            for pattern in ("auth:fail:*", "auth:lock:*"):
                async for key in redis.scan_iter(match=pattern):
                    await redis.delete(key)
        finally:
            await redis.aclose()
    except Exception:
        pass


@pytest.fixture
async def make_user():
    """直插一个带本地密码的用户;teardown 删用户行(限流 key 由 autouse flush 兜底)。

    返回 (User, login_key):login_key = username(给了的话)或 name 兜底,
    与 test_local_auth_integration.make_user 同口径。
    """
    created: list[User] = []

    async def _make(
        *,
        name: str | None = None,
        username: str | None = None,
        email: str | None = None,
        password: str | None = PASS_OK,
    ) -> tuple[User, str]:
        uname = _uname("u")
        svc = LocalAuthService(make_settings(), _NoopRedis())  # type: ignore[arg-type]
        async with get_sessionmaker()() as db:
            u = User(
                feishu_open_id=f"ou_ul_{uuid.uuid4().hex}",
                name=name or uname,
                username=username,
                email=email or f"{uname}@example.com",
                is_active=True,
                must_change_password=False,
                password_hash=None if password is None else svc.hash_password(password),
            )
            db.add(u)
            await db.commit()
            await db.refresh(u)
            created.append(u)
            return u, username or uname

    yield _make

    async with get_sessionmaker()() as db:
        for u in created:
            await db.execute(delete(User).where(User.id == u.id))
        await db.commit()


class _NoopRedis:
    """make_user 里只用来产 argon2 哈希,不碰网络(test_local_auth_integration 同款)。"""

    async def get(self, key: str) -> str | None:
        return None

    async def set(self, key: str, value: str, ex: int | None = None) -> None:
        pass

    async def delete(self, *keys: str) -> None:
        pass

    async def incr(self, key: str) -> int:
        return 1

    async def expire(self, key: str, seconds: int) -> None:
        pass

    def pipeline(self) -> _NoopPipeline:
        return _NoopPipeline()


class _NoopPipeline:
    async def execute(self) -> list[Any]:
        return [1, 1, 1, 1]


async def _fail_n_times(client: AsyncClient, login_name: str, n: int = 5) -> None:
    """对同一登录形态连错 n 次(每次 401)。"""
    for _ in range(n):
        r = await client.post(
            LOGIN_URL, json={"username": login_name, "password": PASS_WRONG})
        assert r.status_code == 401, r.text


async def _redis_lock_key_exists(username_form: str) -> bool:
    redis = from_url(str(get_settings().redis_url), decode_responses=True)
    try:
        return await redis.get(
            _LOCK_USER_KEY.format(username=username_form.lower())) is not None
    finally:
        await redis.aclose()


async def _audit_rows(event_type: str, since: datetime) -> list[AuditEvent]:
    stmt = select(AuditEvent).where(
        AuditEvent.event_type == event_type,
        AuditEvent.event_time >= since,
    ).order_by(AuditEvent.event_time.asc())
    async with get_sessionmaker()() as db:
        return list((await db.execute(stmt)).scalars().all())


# ─── 锁触发与 local_login_locked 审计(§3.1 record_failure 返回触发 + router 补写)──
@pytest.mark.asyncio
async def test_five_failures_lock_and_local_login_locked_audit(
    client: AsyncClient, make_user,
) -> None:
    """连错 5 次 → 第 6 次即使密码正确也 429;第 5 次失败写入 user 维度锁 key,
    并补写审计 local_login_locked(details 含 username)—— 消除锁定期间零审计盲区。"""
    _u, uname = await make_user()
    t0 = datetime.now(UTC)
    await _fail_n_times(client, uname, 5)

    # 第 5 次失败触发锁:user 维度 lock key 在位(lower 形态)
    assert await _redis_lock_key_exists(uname) is True, "第 5 次失败应写 auth:lock:user key"

    # 锁定期间:正确密码也 429
    r = await client.post(LOGIN_URL, json={"username": uname, "password": PASS_OK})
    assert r.status_code == 429, r.text

    # local_login_failed 恰 5 条(锁定分支不写失败审计,不虚增)
    failed = [e for e in await _audit_rows("local_login_failed", t0)
              if (e.details or {}).get("username", "").lower() == uname.lower()]
    assert len(failed) == 5, f"应恰 5 条 local_login_failed,实际 {len(failed)}"

    # 补写 local_login_locked 审计(§4 事件命名;details 记 username/维度)
    locked = [e for e in await _audit_rows("local_login_locked", t0)
              if json.dumps(e.details or {}, ensure_ascii=False).lower()
              .find(uname.lower()) >= 0]
    assert locked, "第 5 次失败触发锁时应补写 local_login_locked 审计"


# ─── unlock 守门:非系统 admin 403 / 用户不存在 404 ─────────────────────────────
@pytest.mark.asyncio
async def test_unlock_requires_system_admin(client: AsyncClient, make_user) -> None:
    """非 system admin(outsider)调 unlock → 403(require_system_admin 守门)。"""
    u, _ = await make_user()
    r = await client.post(UNLOCK_URL.format(user_id=u.id), headers=_h(OUTSIDER_ID))
    assert r.status_code == 403, r.text


@pytest.mark.asyncio
async def test_unlock_unknown_user_404(client: AsyncClient) -> None:
    """unlock 不存在的用户 → 404。"""
    r = await client.post(
        UNLOCK_URL.format(user_id=uuid.uuid4()), headers=_h(EVAN_ID))
    assert r.status_code == 404, r.text


# ─── unlock 后正确密码立即可登录(方案 §1.4 验收主链路)─────────────────────────
@pytest.mark.asyncio
async def test_unlock_then_correct_password_login_200(
    client: AsyncClient, make_user,
) -> None:
    """连错 5 次(IP + user 双维度同时锁)→ unlock 200 → 正确密码立即 200。

    本用例同时锁住两个维度(同一 ASGI IP 连错),unlock 若只清 user 维度不清
    IP 连带,正确密码仍会被 IP 锁 429 —— 恰好验证「IP 连带清」契约。"""
    u, uname = await make_user()
    t0 = datetime.now(UTC)
    await _fail_n_times(client, uname, 5)
    r = await client.post(LOGIN_URL, json={"username": uname, "password": PASS_OK})
    assert r.status_code == 429, r.text

    r = await client.post(UNLOCK_URL.format(user_id=u.id), headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    body = r.json()
    # 契约响应形状:cleared_user_forms / cleared_ips / was_locked
    assert set(body) >= {"cleared_user_forms", "cleared_ips", "was_locked"}, body
    assert body["was_locked"] is True
    # 清除的 user 形态含本次登录输入的 lower 形态;一切 key 必须 lower()
    forms = [f.lower() for f in body["cleared_user_forms"]]
    assert uname.lower() in forms, body
    # IP 连带清:审计反查到的 ASGI 请求 IP 应在清单里
    assert any(ip in body["cleared_ips"] for ip in ASGI_IPS), body
    # user 维度锁 key 已 DEL
    assert await _redis_lock_key_exists(uname) is False

    # 解锁后正确密码立即 200(不再 429)—— 方案 §1.4 验收核心
    r2 = await client.post(LOGIN_URL, json={"username": uname, "password": PASS_OK})
    assert r2.status_code == 200, r2.text
    assert r2.json()["status"] == "ok"

    # 审计 user_login_unlocked:details 记清除的形态与 IP 集(§3.1/§4)
    unlocked = [e for e in await _audit_rows("user_login_unlocked", t0)
                if json.dumps(e.details or {}, ensure_ascii=False).lower()
                .find(uname.lower()) >= 0]
    assert unlocked, "unlock 应写 user_login_unlocked 审计"
    blob = json.dumps(unlocked[-1].details or {}, ensure_ascii=False).lower()
    assert any(ip in blob for ip in ASGI_IPS), "details 应记录清除的 IP 集"


@pytest.mark.asyncio
async def test_unlock_clears_all_three_login_forms(
    client: AsyncClient, make_user,
) -> None:
    """三形态 key 清理:用 email 形态连错 5 次(计数/锁落在 email lower key 上),
    unlock 后 email 形态入 cleared_user_forms,且三形态锁/计数 key 全部不在位
    (DEL 全覆盖,漏形态 = 静默清空)、username / name 形态登录立即可用、
    失败计数也归零(再错一次是 401 非 429)。

    清单口径:cleared_user_forms 记「实际清到 key 的形态」,本就无 key 的
    形态不入清单 —— 三形态全覆盖以 Redis 终态为准做行为断言。"""
    uname = _uname("tri")
    u, _ = await make_user(username=uname, name=f"Tri User {uname}",
                           email=f"{uname}@example.com")
    await _fail_n_times(client, f"{uname}@example.com", 5)
    # email 形态已被锁(user + IP 双维度)
    r = await client.post(
        LOGIN_URL, json={"username": f"{uname}@example.com", "password": PASS_OK})
    assert r.status_code == 429, r.text

    r = await client.post(UNLOCK_URL.format(user_id=u.id), headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    forms = {f.lower() for f in r.json()["cleared_user_forms"]}
    # 本次失败落在 email 形态 → 该形态必须入清单
    assert f"{uname}@example.com" in forms, r.text
    # 行为断言:三形态锁 key 全部清空(DEL 覆盖 username/email/name)
    for form in (uname.lower(), f"{uname}@example.com", f"tri user {uname}"):
        assert await _redis_lock_key_exists(form) is False, (
            f"form={form!r} 的锁 key 应被清")

    # 其余形态立即能登(锁与计数全清;IP 维度也已被连带清,否则这里 429)
    for login_name in (uname, f"tri user {uname}"):
        r2 = await client.post(
            LOGIN_URL, json={"username": login_name, "password": PASS_OK})
        assert r2.status_code == 200, f"login={login_name}: {r2.text}"

    # 失败计数已归零:再错一次是 401(而非第 6 次直接 429)
    r3 = await client.post(
        LOGIN_URL, json={"username": f"{uname}@example.com", "password": PASS_WRONG})
    assert r3.status_code == 401, r3.text


@pytest.mark.asyncio
async def test_unlock_not_locked_user_still_200(client: AsyncClient, make_user) -> None:
    """未锁定的用户调 unlock:200 幂等语义(DEL 不存在的 key 不报错),
    was_locked=False。"""
    u, _ = await make_user()
    r = await client.post(UNLOCK_URL.format(user_id=u.id), headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    assert r.json()["was_locked"] is False


# ─── reset-password 顺带解锁(决策 2:清三形态 user 维度,IP 维度不连带)─────────
@pytest.mark.asyncio
async def test_reset_password_clears_lock(client: AsyncClient, make_user) -> None:
    """连错 5 次 → 429;admin reset-password 后,临时密码立即能登录(顺带解锁)。

    契约口径:reset-password 只清三形态 user 维度锁与失败计数(IP 维度不在
    连带清范围,由 unlock 端点连带清或等 TTL)—— 故本用例在 reset 后、登录
    断言前自行清掉 ASGI 同源 IP 锁,隔离出 user 维度的解锁行为。"""
    u, uname = await make_user()
    await _fail_n_times(client, uname, 5)
    r = await client.post(LOGIN_URL, json={"username": uname, "password": PASS_OK})
    assert r.status_code == 429, r.text

    r = await client.post(RESET_URL.format(user_id=u.id), headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    temp_pw = r.json()["temporary_password"]

    # user 维度锁/计数已随 reset 清除
    assert await _redis_lock_key_exists(uname) is False
    # 测试侧清掉同源 IP 维度(不在契约断言面内),隔离 user 维度行为
    redis = from_url(str(get_settings().redis_url), decode_responses=True)
    try:
        await redis.delete(*[
            k.format(ip=ip) for ip in ASGI_IPS
            for k in (_FAIL_IP_KEY, _LOCK_IP_KEY)
        ])
    finally:
        await redis.aclose()

    r2 = await client.post(LOGIN_URL, json={"username": uname, "password": temp_pw})
    assert r2.status_code == 200, f"reset-password 应顺带解锁:{r2.text}"
    client.cookies.clear()


# ─── 用户列表 login_locked:只反映 user 维度(§3.1 DirectoryUserOut)────────────
@pytest.mark.asyncio
async def test_users_list_login_locked_reflects_user_dimension_only(
    client: AsyncClient, make_user,
) -> None:
    """列表端点 login_locked:锁定后 True、unlock 后 False;IP 维度锁不体现在
    pill 上(用户 C 从未失败,但同 IP 被 ghost username 连错锁住 —— 该用户
    login_locked 仍为 False,尽管此刻登录会 429)。"""
    ua, uname_a = await make_user()
    _uc, uname_c = await make_user()

    # ① 用户 A 连错 5 次 → 列表 login_locked=True
    await _fail_n_times(client, uname_a, 5)
    r = await client.get(
        USERS_URL, params={"q": uname_a, "limit": 50}, headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    items = {i["id"]: i for i in r.json()["items"]}
    assert items[str(ua.id)]["login_locked"] is True, r.text

    # ② unlock → 列表回落 False
    r = await client.post(UNLOCK_URL.format(user_id=ua.id), headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    r = await client.get(
        USERS_URL, params={"q": uname_a, "limit": 50}, headers=_h(EVAN_ID))
    assert r.json()["items"][0]["login_locked"] is False, r.text

    # ③ IP 维度锁:5 个不同 ghost username 连错(同 IP)→ IP 锁在位,
    #    从未失败的 C 列表 login_locked=False(只反映 user 维度),但登录仍 429
    for i in range(5):
        r = await client.post(
            LOGIN_URL,
            json={"username": f"ul_ghost_{i}_{uuid.uuid4().hex[:8]}",
                  "password": PASS_WRONG})
        assert r.status_code == 401, r.text
    r = await client.post(LOGIN_URL,
                          json={"username": uname_c, "password": PASS_OK})
    assert r.status_code == 429, "IP 维度锁应拦住从未失败的用户 C"

    r = await client.get(
        USERS_URL, params={"q": uname_c, "limit": 50}, headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    assert r.json()["items"][0]["login_locked"] is False, (
        "login_locked 只反映 user 维度,IP 维度锁不应计")
