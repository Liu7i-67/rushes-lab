"""手机号绑定两端点容器级路由测试(手机绑定/短信找回密码方案 §5.3/§10.1)。

跑在 ms-api 容器内(`docker exec ms-api pytest tests/test_phone_bind_api.py -v`);
本地无 PG/Redis 时自动 skip(照 tests/test_local_auth_integration.py 范式正本)。

覆盖(方案 §10.1 test_phone_bind_api 条目,16 条逐条对应):
  1  send-code 快乐路(200 retry_after/模板/码键/审计 phone_code_sent)
  2  格式错 400 且不消耗任何计数
  3  占用 409 + 冷却键已回滚(同号紧接再发不翻 429)
  4  冷却 429(retry_after>0,FakeSms 仅 1 次)
  5  每用户小时配额 429 + 冷却键已回滚
  6  日配额:409 路径不烧目标号日 key;可绑定号打满 → 429+冷却/日计数回滚
  7  未配置 503「短信服务未配置」(app.state.sms=None 生产形态)
  8  PAT 调 bind 端点一律 403(require_session_auth,D18)
  9  bind 验码错→400/第 5 次 429 作废不带 retry_after/码键 DEL→过期 400
  10 user_id 复核:A 发码 B 提交同码 → 400 过期
  11 未设密码用户(password_hash NULL)可正常绑定 → me 回传 phone
  12 绑定成功:200 {phone}/码键消费/me 回传/审计 phone_bound(old=None)
  13 并发唯一约束 409(IntegrityError 兜底;码键保留,消费在写库成功后)
  14 审计 phone_bound 脱敏规格:前3+****+后4(换绑 old 非 None)
  15 D9 发送失败统一语义:SmsSendError/SmsTransportError(超时/不可解析)
     → 502+retry_after+冷却保留+配额回滚;isv.BUSINESS_LIMIT_CONTROL
     → 502 不带 retry_after;审计 sms_send_failed err_code 分型
  16 归一化:+86/空格/连字符入参 → 落库与返回均为 11 位归一化值

注意:测试在共享容器里跑,fixture 自建用户/手机号(每用例独立)+ teardown
清用户行与 sms:* 相关键,不污染同容器其他测试;审计行不清理(仓库惯例)。
零真实凭证、零真实发送:短信一律走 tests/helpers/fake_sms.FakeSms。
"""
from __future__ import annotations

import secrets
import uuid
from datetime import UTC, datetime
from typing import Any

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete, select, text, update

from app.db.session import get_sessionmaker
from app.db.tables import AuditEvent, User
from app.main import create_app
from app.services.aliyun_sms import SmsSendError, SmsTransportError
from app.services.local_auth import LocalAuthService
from app.services.phone_verification import (
    code_key,
    cooldown_key,
    daily_key,
    hourly_user_key,
    mask_phone,
)
from app.services.tokens import create_token
from app.settings import Settings, get_settings
from tests.helpers.fake_sms import FakeSms

SEND = "/api/v1/account/phone/send-code"
BIND = "/api/v1/account/phone/bind"
ME = "/api/v1/auth/me"
PASS_OK = "passw0rd"

_APP: Any = None  # client fixture 里保存 app(503 用例要动 app.state.sms)
_CLIENT: AsyncClient | None = None  # 逐用例清 cookie(stateless JWT 跨测试会串)
_PHONES: list[str] = []  # 本文件用到的手机号(teardown 清 bind 场景 sms:* 键)
_USERS: list[uuid.UUID] = []  # 本文件建的用户(teardown 清 sms:u:{uid}:* 键)


def _uname(prefix: str) -> str:
    return f"pb_{prefix}_{uuid.uuid4().hex[:8]}"


def _track_phone(p: str) -> str:
    _PHONES.append(p)
    return p


def _phone() -> str:
    """文档号段 138 + 8 位随机数字:每用例独立,防共享容器键/约束冲突。"""
    return _track_phone("138" + "".join(secrets.choice("0123456789") for _ in range(8)))


def make_settings(**overrides: Any) -> Settings:
    """照范式正本:LocalAuthService 产 argon2 哈希用的最小 Settings。"""
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


class _HashOnlyRedis:
    """make_user 里只用来产 argon2 哈希,不碰网络(照范式正本)。"""

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

    def pipeline(self) -> Any:
        return self

    async def execute(self) -> list[Any]:
        return [1, 1, 1, 1]


def _redis():
    """直连测试容器 Redis(断言键状态/清理用)。"""
    from redis.asyncio import from_url

    return from_url(str(get_settings().redis_url), decode_responses=True)


async def _scan_keys(redis: Any, pattern: str) -> list[str]:
    return [k async for k in redis.scan_iter(match=pattern)]


async def _set_user_phone(user_id: uuid.UUID, phone: str) -> None:
    """DB 直写另一用户 phone(模拟占用/并发竞态,照仓库 DB 直改惯例)。"""
    async with get_sessionmaker()() as db:
        await db.execute(update(User).where(User.id == user_id).values(phone=phone))
        await db.commit()


async def _audit_rows(event_type: str, actor: uuid.UUID | None = None) -> list[Any]:
    """按 event_type(+可选 actor)取审计行;用户每用例唯一,过滤即隔离。"""
    async with get_sessionmaker()() as db:
        rows = (
            await db.execute(
                select(AuditEvent)
                .where(AuditEvent.event_type == event_type)
                .order_by(AuditEvent.event_time.desc(), AuditEvent.inserted_at.desc())
                .limit(100)
            )
        ).scalars().all()
    if actor is not None:
        rows = [r for r in rows if r.actor_user_id == actor]
    return list(rows)


async def _login(client: AsyncClient, ident: str, pw: str = PASS_OK) -> None:
    client.cookies.clear()
    r = await client.post("/api/v1/auth/local/login", json={"username": ident, "password": pw})
    assert r.status_code == 200, r.text


# ─── fixtures(范式正本同款:DB 探测 skip / 会话清理 / 自建用户+键清理)────────


@pytest.fixture(scope="session")
async def client():
    """拉起 app(lifespan);DB 不可达时整体 skip。用一次性 engine 探测。"""
    from sqlalchemy.ext.asyncio import create_async_engine

    engine = create_async_engine(str(get_settings().db_url))
    try:
        async with engine.connect() as conn:
            await conn.execute(text("SELECT 1"))
        await engine.dispose()
    except Exception as exc:
        await engine.dispose()
        pytest.skip(f"no reachable DB — integration tests skipped: {exc}")

    global _APP, _CLIENT
    app = create_app()
    async with app.router.lifespan_context(app):  # type: ignore[attr-defined]
        _APP = app
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as ac:
            _CLIENT = ac
            yield ac
            _CLIENT = None
        _APP = None


@pytest.fixture(autouse=True)
def _clear_cookies_after_test():
    """session 级 client 跨测试留 cookie(stateless JWT 不过期)会串用例,逐个清。"""
    yield
    if _CLIENT is not None:
        _CLIENT.cookies.clear()


@pytest.fixture(autouse=True)
def _sms_env(monkeypatch):
    """容器 env 不保证带阿里云凭证:把启用判定三字段打进 settings 单例
    (仓库先例 test_baidu_key_conflict.py:855 同款 monkeypatch),假凭证只进
    FakeSms,零真实发送;测试后由 monkeypatch 还原。"""
    s = get_settings()
    monkeypatch.setattr(s, "aliyun_sms_ak", "test-ak", raising=False)
    monkeypatch.setattr(s, "aliyun_sms_sk", "test-sk", raising=False)
    monkeypatch.setattr(s, "aliyun_sms_sign_name", "test-sign", raising=False)


@pytest.fixture(autouse=True)
async def fake_sms():
    """每用例换新 FakeSms 挂 app.state.sms(调用记录互不串)。

    state.sms 属性可能缺席(未配置形态 lifespan 不保证写入该属性,D17 容器实锤):
    读一律 getattr 兜底,写/还原用 setattr(State 允许 setattr;原缺席时还原成
    None 值即可,无须 del —— 属性语义上 None 与缺席等价(_sms_guard 判 is None),
    后续用例仍由本 fixture 逐个覆盖)。
    """
    sms = FakeSms()
    if _APP is not None:
        old = getattr(_APP.state, "sms", None)
        _APP.state.sms = sms
        yield sms
        _APP.state.sms = old
    else:
        yield sms  # 本地 skip 场景占位


@pytest.fixture(autouse=True)
async def _clean_sms_keys():
    """跑批后清本文件用过的 sms:* 键,不污染同容器其他测试(d2 reset 侧共用 Redis)。"""
    n_phones, n_users = len(_PHONES), len(_USERS)
    yield
    phones, users = _PHONES[n_phones:], _USERS[n_users:]
    try:
        redis = _redis()
        try:
            keys: list[str] = []
            for p in phones:
                keys += [code_key("bind", p), cooldown_key("bind", p)]
                keys += await _scan_keys(redis, f"sms:day:bind:{p}:*")
            for uid in users:
                keys += await _scan_keys(redis, f"sms:u:{uid}:*")
            if keys:
                await redis.delete(*keys)
        finally:
            await redis.aclose()
    except Exception:
        pass  # 本地无 Redis 的 skip 场景/容器抖动不把 skip 变 error


@pytest.fixture
async def make_user():
    """自建本地账号用户(默认已设密码+不强制改密,登录态可用);teardown 删行。

    password=None 模拟存量飞书用户(password_hash NULL,无强制改密态,方案 D1:
    与已设密码用户同权绑定);phone 给定时直接建含手机号的用户。
    """
    created: list[User] = []

    async def _make(
        *,
        username: str | None = None,
        password: str | None = PASS_OK,
        must_change: bool = False,
        phone: str | None = None,
    ) -> tuple[User, str]:
        uname = username or _uname("u")
        svc = LocalAuthService(make_settings(), _HashOnlyRedis())  # type: ignore[arg-type]
        async with get_sessionmaker()() as db:
            u = User(
                feishu_open_id=f"ou_pb_{uuid.uuid4().hex}",
                name=uname,
                username=uname,
                email=f"{uname}@example.com",
                is_active=True,
                must_change_password=must_change,
                password_hash=None if password is None else svc.hash_password(password),
                phone=phone,
            )
            db.add(u)
            await db.commit()
            await db.refresh(u)
        created.append(u)
        _USERS.append(u.id)
        return u, uname

    yield _make

    async def _cleanup() -> None:
        async with get_sessionmaker()() as db:
            for u in created:
                await db.execute(delete(User).where(User.id == u.id))  # PAT 行 CASCADE
            await db.commit()

    await _cleanup()


# ─── 用例(编号对照模块 docstring)────────────────────────────────────────────


@pytest.mark.asyncio
async def test_01_send_code_happy_path(client: AsyncClient, make_user, fake_sms: FakeSms) -> None:
    """1 快乐路:200 {retry_after:120}/正确模板/码键存在/审计 phone_code_sent。"""
    u, uname = await make_user()
    await _login(client, uname)
    p = _phone()
    r = await client.post(SEND, json={"phone": p})
    assert r.status_code == 200, r.text
    assert r.json() == {"retry_after": get_settings().sms_send_cooldown_seconds}
    assert len(fake_sms.calls) == 1
    call = fake_sms.calls[0]
    assert call["phone"] == p
    assert call["template_code"] == "SMS_512538915"
    assert call["kind"] == "ok"
    assert len(call["code"]) == 6
    redis = _redis()
    try:
        stored = await redis.hgetall(code_key("bind", p))
        assert stored.get("user_id") == str(u.id)
        assert stored.get("attempts") == "0"
        assert stored.get("code_hash"), "码键应存 HMAC hash"
    finally:
        await redis.aclose()
    rows = await _audit_rows("phone_code_sent", actor=u.id)
    assert rows, "phone_code_sent 应落库"
    d = rows[0].details
    assert d["scene"] == "bind"
    assert d["phone_masked"] == mask_phone(p)
    assert d["template_code"] == "SMS_512538915"


@pytest.mark.asyncio
async def test_02_invalid_phone_consumes_nothing(
    client: AsyncClient, make_user, fake_sms: FakeSms,
) -> None:
    """2 格式错 400,且码键/冷却键/配额键都不存在、FakeSms 零调用。"""
    u, uname = await make_user()
    await _login(client, uname)
    bad = "12345"
    r = await client.post(SEND, json={"phone": bad})
    assert r.status_code == 400
    assert r.json()["detail"] == "手机号格式不正确"
    assert fake_sms.calls == []
    redis = _redis()
    try:
        assert not await redis.exists(code_key("bind", bad))
        assert not await redis.exists(cooldown_key("bind", bad))
        assert not await _scan_keys(redis, f"sms:day:bind:{bad}:*")
        assert not await _scan_keys(redis, f"sms:u:{u.id}:*"), "纯格式错不得烧小时配额"
    finally:
        await redis.aclose()


@pytest.mark.asyncio
async def test_03_occupied_409_cooldown_rolled_back(
    client: AsyncClient, make_user, fake_sms: FakeSms,
) -> None:
    """3 占用 409(DB 直写另一用户);409 后冷却键已回滚:同号紧接再发不翻 429。"""
    _, uname_a = await make_user()
    b, _ = await make_user()
    p = _phone()
    await _set_user_phone(b.id, p)
    await _login(client, uname_a)
    r1 = await client.post(SEND, json={"phone": p})
    assert r1.status_code == 409
    assert r1.json()["detail"] == "该手机号已绑定其他账号"
    assert fake_sms.calls == []
    r2 = await client.post(SEND, json={"phone": p})  # 冷却若未回滚这里会是 429
    assert r2.status_code == 409, r2.text
    assert r2.json()["detail"] == "该手机号已绑定其他账号"
    assert fake_sms.calls == []
    redis = _redis()
    try:
        assert not await redis.exists(code_key("bind", p))
    finally:
        await redis.aclose()


@pytest.mark.asyncio
async def test_04_cooldown_429(client: AsyncClient, make_user, fake_sms: FakeSms) -> None:
    """4 同号连发第二次 → 429 带 retry_after(>0),FakeSms 仅 1 次调用。"""
    _, uname = await make_user()
    await _login(client, uname)
    p = _phone()
    assert (await client.post(SEND, json={"phone": p})).status_code == 200
    r = await client.post(SEND, json={"phone": p})
    assert r.status_code == 429, r.text
    body = r.json()
    assert body["detail"] == "发送过于频繁,请稍后再试"
    assert 0 < body["retry_after"] <= get_settings().sms_send_cooldown_seconds
    assert len(fake_sms.calls) == 1


@pytest.mark.asyncio
async def test_05_hourly_quota_429_cooldown_rolled_back(
    client: AsyncClient, make_user, fake_sms: FakeSms,
) -> None:
    """5 绕过冷却(直 DEL 冷却键)连发超小时配额 → 429 带 retry_after=冷却配置值,
    且冷却键已回滚(DEL 断言)。"""
    _, uname = await make_user()
    await _login(client, uname)
    p = _phone()
    hourly = get_settings().sms_bind_user_hourly
    redis = _redis()
    try:
        for _ in range(hourly):
            await redis.delete(cooldown_key("bind", p))  # 绕过冷却,专打小时层
            r = await client.post(SEND, json={"phone": p})
            assert r.status_code == 200, r.text
        await redis.delete(cooldown_key("bind", p))
        r = await client.post(SEND, json={"phone": p})
        assert r.status_code == 429, r.text
        assert r.json()["detail"] == "发送过于频繁,请稍后再试"
        assert r.json()["retry_after"] == get_settings().sms_send_cooldown_seconds
        assert not await redis.exists(cooldown_key("bind", p)), "配额 429 后冷却键应已 DEL"
        assert len(fake_sms.calls) == hourly
    finally:
        await redis.aclose()


@pytest.mark.asyncio
async def test_06_daily_quota_not_burned_for_occupied(
    client: AsyncClient, make_user, monkeypatch, fake_sms: FakeSms,
) -> None:
    """6 日配额仅在占用预检通过后才计数:409 路径打满后目标号日 key 不存在;
    可绑定号打满 → 429+冷却键回滚+本次日计数回滚。"""
    _, uname1 = await make_user()
    b, _ = await make_user()
    p_occ = _phone()
    await _set_user_phone(b.id, p_occ)
    await _login(client, uname1)
    for _ in range(get_settings().sms_bind_user_hourly):
        r = await client.post(SEND, json={"phone": p_occ})
        assert r.status_code == 409, r.text
    redis = _redis()
    try:
        assert not await _scan_keys(redis, f"sms:day:bind:{p_occ}:*"), \
            "409 路径不得烧目标号日配额"
        # 临时调大小时配额,避免小时层先拦,专测日配额层(env 可调参数,仓库口径)
        monkeypatch.setattr(get_settings(), "sms_bind_user_hourly", 100, raising=False)
        _, uname2 = await make_user()
        await _login(client, uname2)
        p2 = _phone()
        for _ in range(get_settings().sms_daily_per_phone):
            await redis.delete(cooldown_key("bind", p2))
            assert (await client.post(SEND, json={"phone": p2})).status_code == 200
        await redis.delete(cooldown_key("bind", p2))
        r = await client.post(SEND, json={"phone": p2})
        assert r.status_code == 429, r.text
        assert r.json()["retry_after"] == get_settings().sms_send_cooldown_seconds
        assert not await redis.exists(cooldown_key("bind", p2)), "日配额 429 后冷却键应已 DEL"
        day_keys = await _scan_keys(redis, f"sms:day:bind:{p2}:*")
        assert len(day_keys) == 1
        assert await redis.get(day_keys[0]) == str(get_settings().sms_daily_per_phone), \
            "本次日计数应已回滚"
        assert len(fake_sms.calls) == get_settings().sms_daily_per_phone
    finally:
        await redis.aclose()


@pytest.mark.asyncio
async def test_07_sms_unconfigured_503(
    client: AsyncClient, make_user, monkeypatch, fake_sms: FakeSms,
) -> None:
    """7 未配置 503「短信服务未配置」:app.state.sms=None 即生产未配置形态(D17)。"""
    _, uname = await make_user()
    await _login(client, uname)
    p = _phone()
    # raising=False:属性缺席(未配置 lifespan 不写入)同样合法,undo 时按缺席还原
    monkeypatch.setattr(_APP.state, "sms", None, raising=False)
    r = await client.post(SEND, json={"phone": p})
    assert r.status_code == 503
    assert r.json()["detail"] == "短信服务未配置"
    r2 = await client.post(BIND, json={"phone": p, "code": "ABC234"})
    assert r2.status_code == 503
    assert r2.json()["detail"] == "短信服务未配置"
    assert fake_sms.calls == []


@pytest.mark.asyncio
async def test_08_pat_forbidden_403(client: AsyncClient, make_user, fake_sms: FakeSms) -> None:
    """8 真实 PAT 带 Bearer 调 send-code → 403(require_session_auth,D18)。"""
    u, _ = await make_user()
    async with get_sessionmaker()() as db:
        created = await create_token(db, user_id=u.id, name="pb-pat", expires_in_days=1)
        await db.commit()
    p = _phone()
    client.cookies.clear()
    r = await client.post(
        SEND, json={"phone": p}, headers={"Authorization": f"Bearer {created.token}"},
    )
    assert r.status_code == 403, r.text
    assert r.json()["detail"] == "令牌不允许管理令牌/改密"
    assert fake_sms.calls == []


@pytest.mark.asyncio
async def test_09_bind_wrong_code_lock_and_expired(
    client: AsyncClient, make_user, fake_sms: FakeSms,
) -> None:
    """9 错码 1 次 → 400 验证码错误;第 5 次 → 429 作废不带 retry_after 且码键 DEL;
    过期(码键 DEL 后再提交)→ 400 验证码已过期,请重新获取。"""
    _, uname = await make_user()
    await _login(client, uname)
    p = _phone()
    assert (await client.post(SEND, json={"phone": p})).status_code == 200
    real = fake_sms.calls[-1]["code"]
    wrong = real[:-1] + ("A" if real[-1] != "A" else "B")  # 保证 ≠ 真码
    for _ in range(get_settings().sms_code_max_attempts - 1):
        r = await client.post(BIND, json={"phone": p, "code": wrong})
        assert r.status_code == 400, r.text
        assert r.json()["detail"] == "验证码错误"
    r = await client.post(BIND, json={"phone": p, "code": wrong})
    assert r.status_code == 429, r.text
    body = r.json()
    assert body["detail"] == "错误次数过多,请重新获取"
    assert "retry_after" not in body, "码作废 429 不带 retry_after(§5.2 分型)"
    redis = _redis()
    try:
        assert not await redis.hgetall(code_key("bind", p)), "作废连码键一起 DEL"
    finally:
        await redis.aclose()
    r = await client.post(BIND, json={"phone": p, "code": real})
    assert r.status_code == 400
    assert r.json()["detail"] == "验证码已过期,请重新获取"


@pytest.mark.asyncio
async def test_10_code_owned_by_other_user_rejected(
    client: AsyncClient, make_user, fake_sms: FakeSms,
) -> None:
    """10 user_id 复核:A 发码 → 换 B 会话提交同码 → 400 过期文案(不泄露差异)。"""
    _, uname_a = await make_user()
    _, uname_b = await make_user()
    p = _phone()
    await _login(client, uname_a)
    assert (await client.post(SEND, json={"phone": p})).status_code == 200
    code = fake_sms.calls[-1]["code"]
    await _login(client, uname_b)
    r = await client.post(BIND, json={"phone": p, "code": code})
    assert r.status_code == 400
    assert r.json()["detail"] == "验证码已过期,请重新获取"


@pytest.mark.asyncio
async def test_11_user_without_password_can_bind(
    client: AsyncClient, make_user, fake_sms: FakeSms,
) -> None:
    """11 未设密码用户(password_hash NULL)可正常绑定 → 200,me 回传 phone。"""
    u, _ = await make_user(password=None)  # 无密码 → 无强制改密态(D1 同权绑定)
    p = _phone()
    h = {"X-User-Id": str(u.id)}  # 无密码不能 local/login,走 dev 通道(容器 env=dev)
    r = await client.post(SEND, json={"phone": p}, headers=h)
    assert r.status_code == 200, r.text
    code = fake_sms.calls[-1]["code"]
    r = await client.post(BIND, json={"phone": p, "code": code}, headers=h)
    assert r.status_code == 200, r.text
    me = await client.get(ME, headers=h)
    assert me.status_code == 200
    assert me.json()["phone"] == p


@pytest.mark.asyncio
async def test_12_bind_success_full(
    client: AsyncClient, make_user, fake_sms: FakeSms,
) -> None:
    """12 绑定成功:200 {phone}/码键已消费/me 回传/审计 phone_bound(old=None)。"""
    u, uname = await make_user()
    await _login(client, uname)
    p = _phone()
    assert (await client.post(SEND, json={"phone": p})).status_code == 200
    code = fake_sms.calls[-1]["code"]
    r = await client.post(BIND, json={"phone": p, "code": code})
    assert r.status_code == 200, r.text
    assert r.json() == {"phone": p}
    redis = _redis()
    try:
        assert not await redis.hgetall(code_key("bind", p)), "码键应已消费(DEL)"
    finally:
        await redis.aclose()
    me = await client.get(ME)
    assert me.status_code == 200
    assert me.json()["phone"] == p
    rows = await _audit_rows("phone_bound", actor=u.id)
    assert rows, "phone_bound 应落库"
    d = rows[0].details
    assert d["old_masked"] is None
    assert d["new_masked"] == mask_phone(p)


@pytest.mark.asyncio
async def test_13_bind_unique_conflict_409(
    client: AsyncClient, make_user, fake_sms: FakeSms,
) -> None:
    """13 A 发码后同号被 DB 直写占用(并发模拟)→ bind 409 唯一约束兜底;
    码键处理符合实现(IntegrityError 先于消费,码键保留)。"""
    _, uname_a = await make_user()
    b, _ = await make_user()
    p = _phone()
    await _login(client, uname_a)
    assert (await client.post(SEND, json={"phone": p})).status_code == 200
    code = fake_sms.calls[-1]["code"]
    await _set_user_phone(b.id, p)
    r = await client.post(BIND, json={"phone": p, "code": code})
    assert r.status_code == 409, r.text
    assert r.json()["detail"] == "该手机号已绑定其他账号"
    redis = _redis()
    try:
        assert await redis.hgetall(code_key("bind", p)), "409 路径码键应保留(消费在写库成功后)"
    finally:
        await redis.aclose()


@pytest.mark.asyncio
async def test_14_audit_phone_bound_mask_spec(
    client: AsyncClient, make_user, fake_sms: FakeSms,
) -> None:
    """14 审计 phone_bound 落库且 old/new 脱敏规格=前3+****+后4(换绑 old 非 None)。"""
    u, uname = await make_user()
    await _login(client, uname)
    p1 = _phone()
    assert (await client.post(SEND, json={"phone": p1})).status_code == 200
    assert (await client.post(
        BIND, json={"phone": p1, "code": fake_sms.calls[-1]["code"]},
    )).status_code == 200
    p2 = _phone()
    assert (await client.post(SEND, json={"phone": p2})).status_code == 200
    assert (await client.post(
        BIND, json={"phone": p2, "code": fake_sms.calls[-1]["code"]},
    )).status_code == 200
    rows = await _audit_rows("phone_bound", actor=u.id)
    assert len(rows) >= 2
    latest = rows[0].details
    assert latest["old_masked"] == f"{p1[:3]}****{p1[-4:]}"
    assert latest["new_masked"] == f"{p2[:3]}****{p2[-4:]}"
    first = next(r for r in rows if r.details.get("new_masked") == mask_phone(p1))
    assert first.details["old_masked"] is None


# ─── 15 D9 发送失败统一语义(共用场景 driver)────────────────────────────────


async def _d9_scenario(
    client: AsyncClient,
    sms: FakeSms,
    u: User,
    uname: str,
    p: str,
    exc: Exception,
    *,
    err_code: str,
    body_detail: str,
    has_retry_after: bool,
) -> None:
    """先成功发一码建基线 → DEL 冷却 → 预置失败再发 → 断言 502 语义:
    detail/retry_after 分型、冷却键保留、小时/日配额回滚、审计 err_code。"""
    now = datetime.now(UTC)
    hkey = hourly_user_key(str(u.id), now)
    dkey = daily_key("bind", p, now)
    await _login(client, uname)
    assert (await client.post(SEND, json={"phone": p})).status_code == 200
    redis = _redis()
    try:
        base_h, base_d = await redis.get(hkey), await redis.get(dkey)
        await redis.delete(cooldown_key("bind", p))  # 让第二次走到发送层
        sms.fail_next = exc
        r = await client.post(SEND, json={"phone": p})
        assert r.status_code == 502, r.text
        body = r.json()
        assert body["detail"] == body_detail
        if has_retry_after:
            assert body["retry_after"] == get_settings().sms_send_cooldown_seconds
        else:
            assert "retry_after" not in body
        assert await redis.exists(cooldown_key("bind", p)), "发送失败冷却键应保留"
        assert await redis.get(hkey) == base_h, "小时配额应回滚到发码前"
        assert await redis.get(dkey) == base_d, "日配额应回滚到发码前"
        rows = await _audit_rows("sms_send_failed", actor=u.id)
        assert rows, "sms_send_failed 应落库"
        d = rows[0].details
        assert d["err_code"] == err_code
        assert d["scene"] == "bind"
        assert d["phone_masked"] == mask_phone(p)
    finally:
        await redis.aclose()


@pytest.mark.asyncio
async def test_15a_d9_sms_send_error_502(
    client: AsyncClient, make_user, fake_sms: FakeSms,
) -> None:
    """15a SmsSendError(isv.AMOUNT_NOT_ENOUGH)→ 502+retry_after+冷却保留+配额回滚。"""
    u, uname = await make_user()
    p = _phone()
    await _d9_scenario(
        client, fake_sms, u, uname, p,
        SmsSendError("isv.AMOUNT_NOT_ENOUGH", "余额不足"),
        err_code="isv.AMOUNT_NOT_ENOUGH",
        body_detail="短信发送失败,请稍后重试",
        has_retry_after=True,
    )


@pytest.mark.asyncio
async def test_15b_d9_transport_timeout_502(
    client: AsyncClient, make_user, fake_sms: FakeSms,
) -> None:
    """15b SmsTransportError(kind=transport_timeout)→ 同 15a;审计 err_code=transport_timeout。"""
    u, uname = await make_user()
    p = _phone()
    await _d9_scenario(
        client, fake_sms, u, uname, p,
        SmsTransportError("ReadTimeout(未收到/未能解析阿里云响应,结果未知)", kind="transport_timeout"),
        err_code="transport_timeout",
        body_detail="短信发送失败,请稍后重试",
        has_retry_after=True,
    )


@pytest.mark.asyncio
async def test_15c_d9_transport_unparseable_502(
    client: AsyncClient, make_user, fake_sms: FakeSms,
) -> None:
    """15c SmsTransportError(kind=transport_unparseable,HTTP 响应无可解析 Code)
    → 行为同 15a;审计 err_code=transport_unparseable。"""
    u, uname = await make_user()
    p = _phone()
    await _d9_scenario(
        client, fake_sms, u, uname, p,
        SmsTransportError("HTTP 502(响应体无可解析 Code,结果未知)"),
        err_code="transport_unparseable",
        body_detail="短信发送失败,请稍后重试",
        has_retry_after=True,
    )


@pytest.mark.asyncio
async def test_15d_d9_business_limit_control_502_no_retry_after(
    client: AsyncClient, make_user, fake_sms: FakeSms,
) -> None:
    """15d isv.BUSINESS_LIMIT_CONTROL → 502「操作过于频繁,请一小时后再试」
    响应体不带 retry_after 键;冷却键保留。"""
    u, uname = await make_user()
    p = _phone()
    await _d9_scenario(
        client, fake_sms, u, uname, p,
        SmsSendError("isv.BUSINESS_LIMIT_CONTROL", "触发运营商频控"),
        err_code="isv.BUSINESS_LIMIT_CONTROL",
        body_detail="操作过于频繁,请一小时后再试",
        has_retry_after=False,
    )


@pytest.mark.asyncio
async def test_16_normalization_plus86_and_hyphen(
    client: AsyncClient, make_user, fake_sms: FakeSms,
) -> None:
    """16 归一化:+86/空格发码、连字符绑定 → 落库与返回均为 11 位归一化值。"""
    u, uname = await make_user()
    tail = "".join(secrets.choice("0123456789") for _ in range(8))
    p = _track_phone(f"138{tail}")
    await _login(client, uname)
    r = await client.post(SEND, json={"phone": f"+86 138 {tail[:4]} {tail[4:]}"})
    assert r.status_code == 200, r.text
    assert fake_sms.calls[-1]["phone"] == p, "发送层应已收到归一化号"
    code = fake_sms.calls[-1]["code"]
    r = await client.post(BIND, json={"phone": f"138-{tail[:4]}-{tail[4:]}", "code": code})
    assert r.status_code == 200, r.text
    assert r.json() == {"phone": p}
    async with get_sessionmaker()() as db:
        row = await db.get(User, u.id)
    assert row.phone == p
    me = await client.get(ME)
    assert me.json()["phone"] == p
