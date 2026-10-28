"""风控模块 — 集成测试(容器内跑,面向契约;正本 §7.1)。

唯一需求依据:`rushes-spec/material-storage/risk-control-module-plan.md`
§3.1(GET /locks 契约与反查口径)+ §3.2(解 IP 锁 was_locked 严格语义)+
§7.1(测试计划);拆包纪律见 `docs/qdev/2026-10-28-risk-control-module.md` 包 A。
写法仿 tests/test_admin_unlock.py(httpx ASGITransport + 直插 User 行 +
**直插 Redis key 布置锁** + 逐测试 SCAN 兜底清理惯例)。

覆盖面(§7.1):
  - 列表契约:user 锁三形态(username/email/name)各自 match=unique;typo 形态
    → none;重名两用户 name 形态锁 → ambiguous 且 matched_users 含两行;
    name 形态命中 username=NULL 的老用户 → 200 且该行 username: null
    (回归 §3.1 可空性,声明成 str 会整单 500);fail_count / lock_ttl_seconds
    数值正确(0 ≤ ttl ≤ 900),users / ips 按 ttl 降序
  - IP 富化:近 24h local_login_failed 审计反查,小写去重;24h 外不计;
    username NULL 过滤
  - 哨兵 IP unknown:直接 SET key 布置(ASGI client 下 request_ip 恒存在,
    不会自然产生,见 test_admin_unlock.py:63-65 ASGI_IPS 注释)→ 如实展示
    (「链路异常」标注由前端渲染)→ 解锁成功
  - 解 IP:was_locked=true 且 key 消失;再解 was_locked=false(幂等);审计
    ip_login_unlocked 落库(details = ip / was_locked / cleared);仅残留失败
    计数(无锁 key)时 was_locked=false(严格只认锁 key,§3.2)
  - 权限:非 system admin GET / POST → 403;空态 → 两列表为空
  - 钉子:表驱动用例每样本独立 actor(各自建独立 user / 锁 / 审计数据);
    跑测前 redis-cli FLUSHALL 清限流锁(hh2 dev 容器执行约定)

前置(同 test_admin_unlock.py):seed_demo_data.py 已跑过(Evan = 系统 admin,
X-User-Id dev 通道);ms-db / redis 可达。pytest 禁止本地跑(本地 docker 禁令)。
"""
from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from httpx import ASGITransport, AsyncClient
from redis.asyncio import from_url
from sqlalchemy import delete, select

from app.db.session import get_sessionmaker
from app.db.tables import AuditEvent, User
from app.main import create_app
from app.services.audit import AuditService
from app.services.local_auth import (
    _FAIL_IP_KEY,
    _FAIL_USER_KEY,
    _LOCK_IP_KEY,
    _LOCK_USER_KEY,
    LocalAuthService,
)
from app.settings import Settings, get_settings

EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"        # 系统 admin(seed 契约账号)
OUTSIDER_ID = "00000000-0000-0000-0000-0000000000aa"    # 非系统 admin(seed 契约账号)

LOCKS_URL = "/api/v1/admin/risk/locks"
UNLOCK_IP_URL = "/api/v1/admin/risk/locks/ips/{ip}/unlock"


def _h(uid: str = EVAN_ID) -> dict[str, str]:
    return {"X-User-Id": uid}


def _uname(prefix: str) -> str:
    return f"rk_{prefix}_{uuid.uuid4().hex[:8]}"


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

    本模块直插的锁/计数 key 与审计反查样本不清理会串测试(test_admin_unlock
    同款 autouse 兜底);session 级 client 跨测试留 cookie 一并清。
    """
    yield
    client.cookies.clear()
    await _flush_auth_rate_keys()


async def _flush_auth_rate_keys() -> None:
    redis = from_url(str(get_settings().redis_url), decode_responses=True)
    try:
        for pattern in ("auth:fail:*", "auth:lock:*"):
            async for key in redis.scan_iter(match=pattern):
                await redis.delete(key)
    finally:
        await redis.aclose()


@pytest.fixture
async def make_user():
    """直插一个用户;teardown 删用户行(限流 key 由 autouse flush 兜底)。

    username 默认 None = 老飞书用户形态(tables.py:69 username 列 nullable);
    password_hash 用 _NoopRedis 产 argon2 哈希(test_admin_unlock 同款,不碰网络)。
    """
    created: list[User] = []

    async def _make(
        *,
        name: str | None = None,
        username: str | None = None,
        email: str | None = None,
    ) -> tuple[User, str]:
        uname = _uname("u")
        svc = LocalAuthService(make_settings(), _NoopRedis())  # type: ignore[arg-type]
        async with get_sessionmaker()() as db:
            u = User(
                feishu_open_id=f"ou_rk_{uuid.uuid4().hex}",
                name=name or uname,
                username=username,
                email=email or f"{uname}@example.com",
                is_active=True,
                must_change_password=False,
                password_hash=svc.hash_password("passw0rd"),
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
    """make_user 里只用来产 argon2 哈希,不碰网络(test_admin_unlock 同款)。"""

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


# ─── 布置 / 断言 helpers(直插 Redis key,照 test_admin_unlock 手法)─────────────
async def _place_user_lock(
    form: str, *, fail_count: int | None = None, ex: int = 900,
) -> None:
    """直插 user 维度锁 key;fail_count=None = 不放计数 key(验证 fail_count=0)。"""
    redis = from_url(str(get_settings().redis_url), decode_responses=True)
    try:
        await redis.set(_LOCK_USER_KEY.format(username=form), "1", ex=ex)
        if fail_count is not None:
            await redis.set(_FAIL_USER_KEY.format(username=form), str(fail_count), ex=ex)
    finally:
        await redis.aclose()


async def _place_ip_lock(
    ip: str, *, fail_count: int | None = None, ex: int = 900,
) -> None:
    """直插 IP 维度锁 key;哨兵 unknown 等非真实 IP 也走这里(§7.1)。"""
    redis = from_url(str(get_settings().redis_url), decode_responses=True)
    try:
        await redis.set(_LOCK_IP_KEY.format(ip=ip), "1", ex=ex)
        if fail_count is not None:
            await redis.set(_FAIL_IP_KEY.format(ip=ip), str(fail_count), ex=ex)
    finally:
        await redis.aclose()


async def _auth_key_exists(key: str) -> bool:
    redis = from_url(str(get_settings().redis_url), decode_responses=True)
    try:
        return await redis.get(key) is not None
    finally:
        await redis.aclose()


async def _write_failed_login_audit(
    *, ip: str, details: dict[str, Any], event_time: datetime | None = None,
) -> None:
    """直插 local_login_failed 审计(details.username 存原始输入未 lower,
    大小写差异 / 键缺失样本靠这里制造;AuditService.write 自带 commit)。"""
    async with get_sessionmaker()() as db:
        await AuditService(db).write(
            event_type="local_login_failed",
            details=details,
            request_ip=ip,
            event_time=event_time,
        )


async def _audit_rows(event_type: str, since: datetime) -> list[AuditEvent]:
    stmt = select(AuditEvent).where(
        AuditEvent.event_type == event_type,
        AuditEvent.event_time >= since,
    ).order_by(AuditEvent.event_time.asc())
    async with get_sessionmaker()() as db:
        return list((await db.execute(stmt)).scalars().all())


def _find_user_row(body: dict[str, Any], form: str) -> dict[str, Any] | None:
    return next((r for r in body["users"] if r["form"] == form), None)


def _find_ip_row(body: dict[str, Any], ip: str) -> dict[str, Any] | None:
    return next((r for r in body["ips"] if r["ip"] == ip), None)


# ─── 空态(§7.1)──────────────────────────────────────────────────────────────
@pytest.mark.asyncio
async def test_locks_empty_state(client: AsyncClient) -> None:
    """无任何锁 → 两列表为空(先主动清一遍 auth:* key,防同容器其他模块残留)。"""
    await _flush_auth_rate_keys()
    r = await client.get(LOCKS_URL, headers=_h())
    assert r.status_code == 200, r.text
    assert r.json() == {"users": [], "ips": []}


# ─── 列表契约:user 锁三形态各自 unique(§7.1;每样本独立 actor)─────────────────
@pytest.mark.asyncio
@pytest.mark.parametrize("form_kind", ["username", "email", "name"])
async def test_locks_three_login_forms_match_unique(
    client: AsyncClient, make_user, form_kind: str,
) -> None:
    """user 锁的 username / email / name 三形态各自 match=unique,反查命中
    恰好一行;fail_count / lock_ttl_seconds 数值正确(0 ≤ ttl ≤ 900)。"""
    uname = _uname(form_kind)
    u, _ = await make_user(
        username=uname, name=f"Risk {uname}", email=f"{uname}@example.com",
    )
    form = {
        "username": uname,
        "email": f"{uname}@example.com",
        "name": f"risk {uname}",  # name 形态的 key 落 lower 口径
    }[form_kind]
    await _place_user_lock(form, fail_count=2)

    r = await client.get(LOCKS_URL, headers=_h())
    assert r.status_code == 200, r.text
    row = _find_user_row(r.json(), form)
    assert row is not None, r.text
    assert row["match"] == "unique"
    assert [m["id"] for m in row["matched_users"]] == [str(u.id)]
    assert row["fail_count"] == 2
    assert 0 < row["lock_ttl_seconds"] <= 900, "锁 key 刚布置,ttl 应在锁定期内"


@pytest.mark.asyncio
async def test_locks_typo_form_match_none(client: AsyncClient) -> None:
    """查无此人的 typo / 探测形态 → match=none、matched_users=[](原样展示,
    「想解都没入口」场景;不提供解锁入口由前端按 match 渲染)。"""
    typo = f"rk_typo_{uuid.uuid4().hex[:8]}"
    await _place_user_lock(typo, fail_count=5)
    r = await client.get(LOCKS_URL, headers=_h())
    assert r.status_code == 200, r.text
    row = _find_user_row(r.json(), typo)
    assert row is not None, r.text
    assert row["match"] == "none"
    assert row["matched_users"] == []


@pytest.mark.asyncio
async def test_locks_duplicate_name_ambiguous(
    client: AsyncClient, make_user,
) -> None:
    """重名两用户 + name 形态锁 → match=ambiguous 且 matched_users 含两行。"""
    shared_name = f"Risk Dup {uuid.uuid4().hex[:8]}"
    u1, _ = await make_user(name=shared_name)
    u2, _ = await make_user(name=shared_name)
    form = shared_name.lower()
    await _place_user_lock(form, fail_count=5)

    r = await client.get(LOCKS_URL, headers=_h())
    assert r.status_code == 200, r.text
    row = _find_user_row(r.json(), form)
    assert row is not None, r.text
    assert row["match"] == "ambiguous"
    assert {m["id"] for m in row["matched_users"]} == {str(u1.id), str(u2.id)}


@pytest.mark.asyncio
async def test_locks_name_form_matches_username_null_legacy_user(
    client: AsyncClient, make_user,
) -> None:
    """name 形态锁命中 username=NULL 的老用户(无本地登录名)→ 响应 200 且
    该行 username: null(回归 §3.1 可空性:模型声明成 str 会整单 500)。"""
    legacy_name = f"Legacy {uuid.uuid4().hex[:8]}"
    u, _ = await make_user(name=legacy_name)  # make_user 默认 username=None
    form = legacy_name.lower()
    await _place_user_lock(form)

    r = await client.get(LOCKS_URL, headers=_h())
    assert r.status_code == 200, r.text
    row = _find_user_row(r.json(), form)
    assert row is not None, r.text
    assert row["match"] == "unique"
    assert row["matched_users"][0]["id"] == str(u.id)
    assert row["matched_users"][0]["username"] is None
    assert row["matched_users"][0]["name"] == legacy_name


@pytest.mark.asyncio
async def test_locks_fail_count_ttl_values_and_desc_order(client: AsyncClient) -> None:
    """fail_count / lock_ttl_seconds 数值正确(含无计数 key → 0);users 与 ips
    均按 lock_ttl_seconds 降序(§3.1 排序契约)。"""
    form_a, form_b = _uname("ttla"), _uname("ttlb")
    ip_a, ip_b = "198.51.100.10", "198.51.100.11"
    await _place_user_lock(form_a, fail_count=3, ex=900)
    await _place_user_lock(form_b, ex=100)               # 无计数 key → fail_count=0
    await _place_ip_lock(ip_a, fail_count=5, ex=900)
    await _place_ip_lock(ip_b, ex=100)

    r = await client.get(LOCKS_URL, headers=_h())
    assert r.status_code == 200, r.text
    body = r.json()
    ra, rb = _find_user_row(body, form_a), _find_user_row(body, form_b)
    assert ra is not None and rb is not None, r.text
    assert ra["fail_count"] == 3 and 800 < ra["lock_ttl_seconds"] <= 900
    assert rb["fail_count"] == 0 and 0 < rb["lock_ttl_seconds"] <= 100
    ria, rib = _find_ip_row(body, ip_a), _find_ip_row(body, ip_b)
    assert ria is not None and rib is not None, r.text
    assert ria["fail_count"] == 5 and 800 < ria["lock_ttl_seconds"] <= 900
    assert rib["fail_count"] == 0 and 0 < rib["lock_ttl_seconds"] <= 100
    # 降序:ex=900 的剩余 ttl 必然大于 ex=100 的,排在前
    assert [row["form"] for row in body["users"]][:2] == [form_a, form_b]
    assert [row["ip"] for row in body["ips"]][:2] == [ip_a, ip_b]


# ─── IP 富化:近 24h 失败用户名反查(§7.1)─────────────────────────────────────
@pytest.mark.asyncio
async def test_locks_ip_enrichment_recent_failed_userforms(client: AsyncClient) -> None:
    """recent_failed_userforms:大小写差异 lower 去重;24h 外事件不计;
    username 键缺失(NULL)过滤;非本 IP 的事件不串行。"""
    ip, other_ip = "203.0.113.7", "203.0.113.8"
    await _place_ip_lock(ip, fail_count=5)
    now = datetime.now(UTC)
    await _write_failed_login_audit(ip=ip, details={"username": "ZhangSan"})
    await _write_failed_login_audit(ip=ip, details={"username": "zhangsan"})
    await _write_failed_login_audit(ip=ip, details={"username": "ZhAnSa"})
    await _write_failed_login_audit(ip=ip, details={"no_username": 1})
    await _write_failed_login_audit(
        ip=ip, details={"username": "StaleUser"},
        event_time=now - timedelta(hours=25))
    await _write_failed_login_audit(ip=other_ip, details={"username": "OtherIpUser"})

    r = await client.get(LOCKS_URL, headers=_h())
    assert r.status_code == 200, r.text
    row = _find_ip_row(r.json(), ip)
    assert row is not None, r.text
    assert row["recent_failed_userforms"] == ["zhangsan", "zhansa"]


# ─── 哨兵 IP unknown:如实展示 + 可解(§3.1 / §7.1)────────────────────────────
@pytest.mark.asyncio
async def test_locks_unknown_sentinel_ip_listed_and_unlockable(
    client: AsyncClient,
) -> None:
    """auth:lock:ip:unknown(登录链路 request_ip 缺失回落哨兵):列表如实展示
    不静默过滤(「链路异常」标注由前端渲染),且允许解锁。ASGI client 下
    request_ip 恒存在,该锁只能直接 SET key 布置(test_admin_unlock ASGI_IPS 注释)。"""
    await _place_ip_lock("unknown", fail_count=5)
    r = await client.get(LOCKS_URL, headers=_h())
    assert r.status_code == 200, r.text
    row = _find_ip_row(r.json(), "unknown")
    assert row is not None, "哨兵 IP 应如实展示,不得静默过滤"
    assert row["fail_count"] == 5

    r2 = await client.post(UNLOCK_IP_URL.format(ip="unknown"), headers=_h())
    assert r2.status_code == 200, r2.text
    assert r2.json() == {"ip": "unknown", "was_locked": True}


# ─── 解 IP:幂等 + 审计 + was_locked 严格语义(§3.2 / §7.1)────────────────────
@pytest.mark.asyncio
async def test_unlock_ip_idempotent_and_audit(client: AsyncClient) -> None:
    """锁布置 → unlock → was_locked=true 且锁/计数 key 消失;再次 unlock →
    was_locked=false(幂等);两次各落一条 ip_login_unlocked 审计
    (details = ip / was_locked / cleared)。"""
    ip = "192.0.2.77"
    t0 = datetime.now(UTC)
    await _place_ip_lock(ip, fail_count=4)

    r = await client.post(UNLOCK_IP_URL.format(ip=ip), headers=_h())
    assert r.status_code == 200, r.text
    assert r.json() == {"ip": ip, "was_locked": True}
    assert await _auth_key_exists(_LOCK_IP_KEY.format(ip=ip)) is False
    assert await _auth_key_exists(_FAIL_IP_KEY.format(ip=ip)) is False

    r2 = await client.post(UNLOCK_IP_URL.format(ip=ip), headers=_h())
    assert r2.status_code == 200, r2.text
    assert r2.json()["was_locked"] is False

    unlocked = [e for e in await _audit_rows("ip_login_unlocked", t0)
                if (e.details or {}).get("ip") == ip]
    assert len(unlocked) == 2, "两次 unlock 各落一条审计"
    with_lock = [e for e in unlocked if (e.details or {}).get("was_locked") is True]
    without_lock = [e for e in unlocked if (e.details or {}).get("was_locked") is False]
    assert len(with_lock) == 1 and len(without_lock) == 1
    assert ip in (with_lock[0].details or {}).get("cleared", []), (
        "cleared 应记 clear_ip_locks 实际清到的 IP")


@pytest.mark.asyncio
async def test_unlock_ip_fail_counter_only_was_locked_false(client: AsyncClient) -> None:
    """was_locked 严格语义(§3.2):仅残留失败计数(无锁 key)时,unlock 清掉
    计数(clear_ip_locks 返回非空)但 was_locked=false —— 只认锁 key。"""
    ip = "192.0.2.78"
    redis = from_url(str(get_settings().redis_url), decode_responses=True)
    try:
        await redis.set(_FAIL_IP_KEY.format(ip=ip), "2", ex=900)
    finally:
        await redis.aclose()

    r = await client.post(UNLOCK_IP_URL.format(ip=ip), headers=_h())
    assert r.status_code == 200, r.text
    assert r.json()["was_locked"] is False
    assert await _auth_key_exists(_FAIL_IP_KEY.format(ip=ip)) is False, "计数应被清"


# ─── 权限:非 system admin 403(§7.1)─────────────────────────────────────────
@pytest.mark.asyncio
async def test_risk_endpoints_require_system_admin(client: AsyncClient) -> None:
    """非 system admin(outsider)GET / POST → 403(require_system_admin 守门;
    两样本各自独立请求)。"""
    r = await client.get(LOCKS_URL, headers=_h(OUTSIDER_ID))
    assert r.status_code == 403, r.text
    r2 = await client.post(
        UNLOCK_IP_URL.format(ip="192.0.2.79"), headers=_h(OUTSIDER_ID))
    assert r2.status_code == 403, r2.text
