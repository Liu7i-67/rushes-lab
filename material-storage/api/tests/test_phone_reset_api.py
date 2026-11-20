"""忘记密码(短信找回)两端点容器级路由测试 — 方案 §5.2/§5.4/§5.5/§10.1。

范式照 tests/test_local_auth_integration.py:create_app + lifespan + 真实 PG/Redis,
无 DB 自动 skip;本地 docker 禁跑,真正执行在 ms-api 容器阶段。
FakeSms 为 d1 并行包共享替身(tests/helpers/fake_sms.py,接口 PM 钉死)——只
import,未落地时整体 skip,勿自建。真实凭证零出现、零真实发送(发送面全替身)。

覆盖方案 §10.1 test_phone_reset_api 全部 13 条(未知号 400+denied 审计
auth_method NULL / denied 烧 IP / 日配额+冷却回滚 / 同号重复点击不烧 IP /
未配置 503 / D9 失败统一语义四连 / confirm 快乐路新密码登录+must_change /
PAT 全吊销+审计 / 错码 5 次作废 / 并发双 confirm 一次生效 / 归属复核 /
码键消费与 400 文案+confirm 503 / send-code 快乐路)。
"""

from __future__ import annotations

import asyncio
import uuid
from collections.abc import AsyncIterator, Callable
from datetime import UTC, datetime
from typing import Any

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete, select, text

from app.db.session import get_sessionmaker
from app.db.tables import AuditEvent, PersonalAccessToken, User
from app.main import create_app
from app.services import phone_verification as pv
from app.services.aliyun_sms import SmsSendError, SmsTransportError
from app.services.passwords import hash_password, verify_password
from app.services.tokens import create_token, resolve_token
from app.settings import get_settings

# d1 并行包共享替身;未落地时本文件整体 skip(接口 PM 钉死,勿在本文件自建)
try:
    from tests.helpers.fake_sms import FakeSms

    _FAKE_SMS_SKIP: str | None = None
except ImportError as _exc:  # 联跑前置;skip 理由带上原始错误
    FakeSms = None  # type: ignore[assignment,misc]
    _FAKE_SMS_SKIP = f"tests/helpers/fake_sms.py 未落地(d1 并行包): {_exc}"

pytestmark = pytest.mark.skipif(FakeSms is None, reason=_FAKE_SMS_SKIP or "")

RESET_SEND = "/api/v1/auth/phone/reset/send-code"
RESET_CONFIRM = "/api/v1/auth/phone/reset/confirm"
LOCAL_LOGIN = "/api/v1/auth/local/login"
RESET_TEMPLATE = "SMS_512523885"  # 方案 §5.8 默认重置模板(钉子:FakeSms 必收到它)

_CLIENT: AsyncClient | None = None
_APP: Any = None
_PHONE_SEQ = int(uuid.uuid4().hex[:3], 16)  # 每次运行随机起点,降低跨 run 撞历史号


def _phone() -> str:
    """文档号段(13800138xxx)内自增虚构号;跨用例唯一,零真实发送。"""
    global _PHONE_SEQ
    _PHONE_SEQ += 1
    return f"13800138{_PHONE_SEQ % 1000:03d}"


def _uname(prefix: str) -> str:
    return f"pr_{prefix}_{uuid.uuid4().hex[:8]}"


async def _audits(event_type: str, *, phone=None, user_id=None, since=None) -> list[AuditEvent]:
    """按 event_type(+details.phone_masked / actor / 时间窗)过滤审计行。

    since 过滤保证跨 pytest run 复跑时只看本用例产生的行(审计行不清理)。
    """
    stmt = select(AuditEvent).where(AuditEvent.event_type == event_type)
    if since is not None:
        stmt = stmt.where(AuditEvent.event_time >= since)
    async with get_sessionmaker()() as db:
        rows = list((await db.execute(stmt)).scalars().all())
    if phone is not None:
        rows = [r for r in rows if (r.details or {}).get("phone_masked") == pv.mask_phone(phone)]
    if user_id is not None:
        rows = [r for r in rows if r.actor_user_id == user_id]
    return rows


async def _ip_bucket_key(sent_phone: str, since: datetime) -> str:
    """sms:ip:reset 桶键;IP 从已发用例的审计行取真实 request.client(不 hardcode
    httpx ASGITransport 版本差异:新版本 127.0.0.1,旧版本 testclient)。"""
    rows = await _audits("phone_code_sent", phone=sent_phone, since=since)
    assert rows, "发码审计缺失,无法定位 IP 桶键"
    return pv.hourly_reset_ip_key(ip=rows[-1].request_ip or "unknown", now=datetime.now(UTC))


def _pin_sms_disabled(monkeypatch: pytest.MonkeyPatch) -> None:
    """进程级 settings 单例钉成未配置(503 形态,lifespan 同款);monkeypatch 自动还原。"""
    settings = get_settings()
    for f in ("aliyun_sms_ak", "aliyun_sms_sk", "aliyun_sms_sign_name"):
        monkeypatch.setattr(settings, f, None)
    assert settings.aliyun_sms_enabled is False


@pytest.fixture(scope="session")
async def client() -> AsyncIterator[AsyncClient]:
    """拉起 app(lifespan);DB 不可达时整体 skip(范式正本同款)。

    容器 env 未必配短信凭证:端点守卫读的是进程级 settings 单例,这里把
    ak/sk/签名钉成「已启用」形态(会话结束还原),发送面统一注入 FakeSms。
    """
    from sqlalchemy.ext.asyncio import create_async_engine

    settings = get_settings()
    engine = create_async_engine(str(settings.db_url))
    try:
        async with engine.connect() as conn:
            await conn.execute(text("SELECT 1"))
        await engine.dispose()
    except Exception as exc:
        await engine.dispose()
        pytest.skip(f"no reachable DB — integration tests skipped: {exc}")

    pinned = ("aliyun_sms_ak", "aliyun_sms_sk", "aliyun_sms_sign_name")
    orig = {f: getattr(settings, f) for f in pinned}
    settings.aliyun_sms_ak = "test-ak"
    settings.aliyun_sms_sk = "test-sk"
    settings.aliyun_sms_sign_name = "测试签名(测试替身,非真实凭证)"

    global _APP
    app = create_app()
    try:
        async with app.router.lifespan_context(app):  # type: ignore[attr-defined]
            _APP = app
            transport = ASGITransport(app=app)
            async with AsyncClient(transport=transport, base_url="http://test") as ac:
                _CLIENT = ac
                yield ac
                _CLIENT = None
    finally:
        _APP = None
        for f in pinned:
            setattr(settings, f, orig[f])


@pytest.fixture(autouse=True)
def _clear_cookies_after_test():
    """session 级 client 跨测试留 cookie 会串测试,逐个清(范式正本同款)。"""
    yield
    if _CLIENT is not None:
        _CLIENT.cookies.clear()


@pytest.fixture(autouse=True)
async def _flush_reset_keys() -> AsyncIterator[None]:
    """跑后清本文件产生的 Redis 相键(reset 场景四类;bind 侧键 d1 自理,互不越界)。"""
    yield
    from redis.asyncio import from_url

    r = from_url(str(get_settings().redis_url), decode_responses=True)
    try:
        for pattern in ("sms:code:reset:*", "sms:cd:reset:*", "sms:day:reset:*", "sms:ip:reset:*"):
            async for key in r.scan_iter(match=pattern):
                await r.delete(key)
    finally:
        await r.aclose()


@pytest.fixture
async def fake_sms() -> AsyncIterator[Any]:
    """每用例独立 FakeSms,替换 lifespan 构造的服务(app.state.sms);用毕还原。

    state.sms 属性可能缺席(未配置形态 lifespan 不保证写入该属性,D17 容器实锤):
    读走 getattr 兜底,写/还原走 setattr(原缺席时还原成 None 值即可,无须 del ——
    守卫判 is None,None 与缺席等价)。
    """
    assert _APP is not None, "client fixture 未就绪"
    fake = FakeSms()
    prev = getattr(_APP.state, "sms", None)
    _APP.state.sms = fake
    yield fake
    _APP.state.sms = prev


@pytest.fixture
async def rclient() -> AsyncIterator[Any]:
    """测试内直查/直改 Redis 相键(冷却键 DEL 绕冷却、配额计数断言等)。"""
    from redis.asyncio import from_url

    r = from_url(str(get_settings().redis_url), decode_responses=True)
    yield r
    await r.aclose()


@pytest.fixture
async def make_user() -> AsyncIterator[Callable[..., Any]]:
    """建本地账号用户(可携 phone);teardown 删 PAT 行 + 用户行 + 登录限流键。"""
    created: list[User] = []

    async def _make(
        *, username=None, password="passw0rd", must_change=False, is_active=True, phone=None
    ) -> User:
        uname = username or _uname("user")
        async with get_sessionmaker()() as db:
            u = User(
                feishu_open_id=f"ou_pr_{uuid.uuid4().hex}",
                name=uname,
                username=uname,
                email=f"{uname}@example.com",
                is_active=is_active,
                must_change_password=must_change,
                password_hash=None if password is None else hash_password(password),
                phone=phone,
            )
            db.add(u)
            await db.commit()
            await db.refresh(u)
            created.append(u)
            return u

    yield _make

    async with get_sessionmaker()() as db:
        for u in created:
            await db.execute(delete(PersonalAccessToken).where(PersonalAccessToken.user_id == u.id))
        for u in created:
            await db.execute(delete(User).where(User.id == u.id))
        await db.commit()
    from redis.asyncio import from_url

    from app.services.local_auth import (
        _FAIL_IP_KEY,
        _FAIL_USER_KEY,
        _LOCK_IP_KEY,
        _LOCK_USER_KEY,
    )

    r = from_url(str(get_settings().redis_url), decode_responses=True)
    try:
        keys: list[str] = []
        for u in created:
            uname = (u.username or "").lower()
            for ip in ("testclient", "127.0.0.1"):  # 两候选 IP(不同 httpx 版本),no-op 安全
                keys += [
                    _FAIL_IP_KEY.format(ip=ip),
                    _LOCK_IP_KEY.format(ip=ip),
                    _FAIL_USER_KEY.format(username=uname),
                    _LOCK_USER_KEY.format(username=uname),
                ]
        await r.delete(*keys)
    finally:
        await r.aclose()


# ─── send-code ───────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_unknown_phone_denied_400_cooldown_rollback_audit(client, fake_sms, rclient):
    """条目 1:未知号 400「无法发送验证码」+冷却键已回滚+审计 denied(auth_method NULL)。"""
    t0 = datetime.now(UTC)
    phone = _phone()  # 未绑定号
    r = await client.post(RESET_SEND, json={"phone": phone})
    assert r.status_code == 400, r.text
    assert r.json()["detail"] == "无法发送验证码"
    assert fake_sms.calls == []
    # 冷却键已回滚:同号紧接重发不翻 429(仍是 denied 400)
    assert await rclient.get(pv.cooldown_key("reset", phone)) is None
    r2 = await client.post(RESET_SEND, json={"phone": phone})
    assert r2.status_code == 400, r2.text
    assert r2.json()["detail"] == "无法发送验证码"
    # 审计 phone_reset_denied:actor 未认证(None)+ auth_method 显式 NULL(哨兵实证)
    rows = await _audits("phone_reset_denied", phone=phone, since=t0)
    assert len(rows) == 2, "两次 denied 各留痕一条"
    for row in rows:
        assert row.actor_user_id is None
        assert row.auth_method is None, "公开端点审计必须显式 NULL(_UNSET 哨兵改造实证)"


@pytest.mark.asyncio
async def test_denied_burns_ip_quota(client, fake_sms, make_user):
    """条目 2:denied 消耗 IP 配额——对不存在号连打 limit 次,第 limit+1 次连合法号也 429。"""
    u = await make_user(phone=_phone())
    limit = get_settings().sms_reset_ip_hourly  # 默认 20;动态读防 env 覆盖
    for _ in range(limit):
        r = await client.post(RESET_SEND, json={"phone": _phone()})
        assert r.status_code == 400
    # 第 limit+1 次:合法已绑定号也 429(IP 配额在查库之前计数,denied 不回滚)
    r = await client.post(RESET_SEND, json={"phone": u.phone})
    assert r.status_code == 429, r.text
    body = r.json()
    assert body["detail"] == "发送过于频繁,请稍后再试"
    assert body["retry_after"] == get_settings().sms_send_cooldown_seconds
    assert fake_sms.calls == []


@pytest.mark.asyncio
async def test_daily_quota_429_rolls_back_cooldown(client, fake_sms, rclient, make_user):
    """条目 3:同号日配额 429(直 DEL 冷却键绕过连发)→ 429+冷却键已回滚+日计数回滚。"""
    settings = get_settings()
    if settings.sms_reset_ip_hourly <= settings.sms_daily_per_phone:
        pytest.skip("env 的 sms_reset_ip_hourly ≤ sms_daily_per_phone,本用例需 IP 余量")
    phone = _phone()
    await make_user(phone=phone)
    cd = pv.cooldown_key("reset", phone)
    day = pv.daily_key("reset", phone, datetime.now(UTC))
    for _ in range(settings.sms_daily_per_phone):
        r = await client.post(RESET_SEND, json={"phone": phone})
        assert r.status_code == 200, r.text
        await rclient.delete(cd)  # 绕过冷却连发
    r = await client.post(RESET_SEND, json={"phone": phone})
    assert r.status_code == 429, r.text
    assert r.json()["retry_after"] == settings.sms_send_cooldown_seconds
    assert await rclient.get(cd) is None, "配额 429 必须回滚冷却键(D9 通用原则)"
    got = await rclient.get(day)
    assert got is not None and int(got) == settings.sms_daily_per_phone, "超限日计数须回滚"
    assert len(fake_sms.calls) == settings.sms_daily_per_phone


@pytest.mark.asyncio
async def test_repeat_same_phone_hits_cooldown_not_ip(client, fake_sms, rclient, make_user):
    """条目 4:同号重复点击在冷却层被拦且不烧 IP 配额;换号枚举才烧(对照条目 2)。"""
    t0 = datetime.now(UTC)
    phone = _phone()
    await make_user(phone=phone)
    r1 = await client.post(RESET_SEND, json={"phone": phone})
    assert r1.status_code == 200
    ip_key = await _ip_bucket_key(phone, t0)
    assert int(await rclient.get(ip_key) or "0") == 1
    for _ in range(4):
        r = await client.post(RESET_SEND, json={"phone": phone})
        assert r.status_code == 429
        assert "retry_after" in r.json()
    assert len(fake_sms.calls) == 1, "只有第 1 次到 FakeSms"
    assert int(await rclient.get(ip_key) or "0") == 1, "冷却 429 不得消耗 IP 配额"
    # 对照:换一个不存在号 → IP +1(denied 在查库之前计数,枚举才烧 IP)
    r = await client.post(RESET_SEND, json={"phone": _phone()})
    assert r.status_code == 400
    assert int(await rclient.get(ip_key) or "0") == 2


@pytest.mark.asyncio
async def test_send_code_503_when_sms_unconfigured(client, make_user, monkeypatch):
    """条目 5:未配置 503「短信服务未配置」(settings.aliyun_sms_enabled=False 构造)。"""
    _pin_sms_disabled(monkeypatch)
    phone = _phone()
    await make_user(phone=phone)
    # getattr 兜底:属性缺席(未配置形态 lifespan 不写入)时 prev=None,语义等价
    prev = getattr(_APP.state, "sms", None)
    _APP.state.sms = None  # 照 lifespan 未配置形态
    try:
        r = await client.post(RESET_SEND, json={"phone": phone})
        assert r.status_code == 503
        assert r.json()["detail"] == "短信服务未配置"
    finally:
        _APP.state.sms = prev


# D9 四连:(异常, 审计 err_code, 502 文案, 是否带 retry_after)
_D9_CASES = [
    (
        SmsSendError("isv.AMOUNT_NOT_ENOUGH", "余额不足"),
        "isv.AMOUNT_NOT_ENOUGH",
        "短信发送失败,请稍后重试",
        True,
    ),
    (
        SmsTransportError("本地超时", kind="transport_timeout"),
        "transport_timeout",
        "短信发送失败,请稍后重试",
        True,
    ),
    (
        SmsTransportError("HTTP 502 无可解析 Code", kind="transport_unparseable"),
        "transport_unparseable",
        "短信发送失败,请稍后重试",
        True,
    ),
    (
        SmsSendError("isv.BUSINESS_LIMIT_CONTROL", "触发运营商频控"),
        "isv.BUSINESS_LIMIT_CONTROL",
        "操作过于频繁,请一小时后再试",
        False,
    ),
]
_D9_IDS = ["send_error", "transport_timeout", "transport_unparse", "business_limit_control"]


@pytest.mark.parametrize(("exc", "err_code", "detail", "has_retry_after"), _D9_CASES, ids=_D9_IDS)
@pytest.mark.asyncio
async def test_send_failure_d9_semantics(
    client, fake_sms, rclient, make_user, exc, err_code, detail, has_retry_after
):
    """条目 6:D9 失败统一语义四连——502 分型+冷却保留+IP/日配额回滚+审计 err_code。"""
    settings = get_settings()
    t0 = datetime.now(UTC)
    phone = _phone()
    await make_user(phone=phone)
    fake_sms.fail_next = exc
    r = await client.post(RESET_SEND, json={"phone": phone})
    assert r.status_code == 502, r.text
    body = r.json()
    assert body["detail"] == detail
    assert ("retry_after" in body) is has_retry_after
    if has_retry_after:
        assert body["retry_after"] == settings.sms_send_cooldown_seconds
    # 冷却键保留(真实等待窗口由冷却管);本次新增的 IP/日计数已回滚
    assert await rclient.get(pv.cooldown_key("reset", phone)) == "1"
    failed = await _audits("sms_send_failed", phone=phone, since=t0)
    assert len(failed) == 1
    row = failed[0]
    assert row.details["err_code"] == err_code
    assert row.details["scene"] == "reset"
    assert row.auth_method is None
    ip_key = pv.hourly_reset_ip_key(ip=row.request_ip or "unknown", now=datetime.now(UTC))
    day = pv.daily_key("reset", phone, datetime.now(UTC))
    assert int(await rclient.get(ip_key) or "0") == 0, "IP 小时计数须回滚"
    assert int(await rclient.get(day) or "0") == 0, "日配额计数须回滚"
    assert len(fake_sms.calls) == 1, "失败调用也留痕(先记录再 raise,PM 钉死接口)"


@pytest.mark.asyncio
async def test_send_code_happy_path(client, fake_sms, make_user):
    """条目 13:send-code 快乐路——200 {retry_after};模板 SMS_512523885;审计留痕。"""
    t0 = datetime.now(UTC)
    settings = get_settings()
    phone = _phone()
    u = await make_user(phone=phone)
    r = await client.post(RESET_SEND, json={"phone": phone})
    assert r.status_code == 200, r.text
    assert r.json() == {"retry_after": settings.sms_send_cooldown_seconds}
    assert len(fake_sms.calls) == 1
    call = fake_sms.calls[-1]
    assert call["phone"] == phone
    assert call["template_code"] == RESET_TEMPLATE
    assert len(call["code"]) == 6
    rows = await _audits("phone_code_sent", phone=phone, since=t0)
    assert len(rows) == 1
    row = rows[0]
    assert row.actor_user_id == u.id, "reset 侧 actor=归属用户"
    assert row.auth_method is None
    assert row.details["scene"] == "reset"
    assert row.details["template_code"] == RESET_TEMPLATE
    assert row.details["user_id"] == str(u.id)
    assert row.request_ip, "request_ip 走审计独立列"


# ─── confirm ─────────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_confirm_happy_path_new_password_login(client, fake_sms, make_user):
    """条目 7:confirm 快乐路端到端——四元组;新密码可登录且首登强制再改;旧密码失效。"""
    uname = _uname("reset")
    old_pw = "oldPass123"
    u = await make_user(username=uname, password=old_pw, must_change=False, phone=_phone())
    r = await client.post(RESET_SEND, json={"phone": u.phone})
    assert r.status_code == 200
    code = fake_sms.calls[-1]["code"]  # 从替身留痕取明文(后端 strip().upper() 比对)
    r = await client.post(RESET_CONFIRM, json={"phone": u.phone, "code": code})
    assert r.status_code == 200, r.text
    assert r.headers.get("cache-control") == "no-store"
    body = r.json()
    assert set(body) == {"username", "email", "name", "new_password"}
    assert body["username"] == uname
    assert body["name"] == uname
    new_pw = body["new_password"]
    assert new_pw != old_pw
    # 新密码登录成功且 must_change_password=true(D2 首登强制再改)
    r = await client.post(LOCAL_LOGIN, json={"username": uname, "password": new_pw})
    assert r.status_code == 200, r.text
    assert r.json()["must_change_password"] is True
    # 旧密码登录失败
    r = await client.post(LOCAL_LOGIN, json={"username": uname, "password": old_pw})
    assert r.status_code == 401


@pytest.mark.asyncio
async def test_confirm_revokes_all_pats_and_audits(client, fake_sms, make_user):
    """条目 8:PAT 全吊销(tokens 校验路径)+逐令牌 token_revoked+reset 审计无密码材料。"""
    t0 = datetime.now(UTC)
    phone = _phone()
    u = await make_user(phone=phone, must_change=False)
    async with get_sessionmaker()() as db:
        made = []
        for name in ("t1", "t2"):
            ref = await create_token(db, user_id=u.id, name=name, expires_in_days=7)
            made.append(ref)
            await db.commit()
    r = await client.post(RESET_SEND, json={"phone": phone})
    assert r.status_code == 200
    r = await client.post(RESET_CONFIRM, json={"phone": phone, "code": fake_sms.calls[-1]["code"]})
    assert r.status_code == 200, r.text
    # tokens 校验路径(认证链查表步):两 token 均已吊销 → 调用方据此判 401
    async with get_sessionmaker()() as db:
        for ref in made:
            resolved = await resolve_token(db, ref.token)
            assert resolved is not None and resolved.revoked_at is not None, "reset 后 PAT 必须失效"
    # password_reset_via_phone:details 仅 phone_masked(无任何密码材料),auth_method NULL
    rows = await _audits("password_reset_via_phone", user_id=u.id, since=t0)
    assert len(rows) == 1
    assert rows[0].auth_method is None
    assert rows[0].details == {"phone_masked": pv.mask_phone(phone)}
    # 逐令牌 token_revoked(reason=phone_reset),token_id 对得上
    rev = await _audits("token_revoked", user_id=u.id, since=t0)
    assert len(rev) == 2
    assert {r0.details["token_id"] for r0 in rev} == {str(ref.id) for ref in made}
    assert {r0.details["reason"] for r0 in rev} == {"phone_reset"}


@pytest.mark.asyncio
async def test_confirm_five_wrong_attempts_locks_code(client, fake_sms, rclient, make_user):
    """条目 9:连错 5 次 → 第 5 次 429 作废(不带 retry_after);之后正确码也 400 过期。"""
    phone = _phone()
    await make_user(phone=phone)
    r = await client.post(RESET_SEND, json={"phone": phone})
    assert r.status_code == 200
    code = fake_sms.calls[-1]["code"]
    for i, wrong in enumerate(("AAAAAA", "BBBBBB", "CCCCCC", "DDDDDD", "EEEEEE")):
        r = await client.post(RESET_CONFIRM, json={"phone": phone, "code": wrong})
        if i < 4:
            assert r.status_code == 400, r.text
            assert r.json()["detail"] == "验证码错误"
        else:
            assert r.status_code == 429, r.text
            body = r.json()
            assert body["detail"] == "错误次数过多,请重新获取"
            assert "retry_after" not in body, "码作废 429 不带 retry_after(须重新发码)"
    assert await rclient.exists(pv.code_key("reset", phone)) == 0, "达上限连码键一起 DEL"
    # 之后正确码也 400 过期(键缺失不重建)
    r = await client.post(RESET_CONFIRM, json={"phone": phone, "code": code})
    assert r.status_code == 400, r.text
    assert r.json()["detail"] == "验证码已过期,请重新获取"


@pytest.mark.asyncio
async def test_concurrent_double_confirm_single_effect(client, fake_sms, rclient, make_user):
    """条目 10:并发双 confirm 只有一次生效(原子消费验码,读-比-删一原子)。

    注:若 ASGI 传输下 gather 未真并发(退化串行),断言同样成立——第二路
    面对的码键必已 DEL(expired);原子性本体由 phone_verification 单测
    (Lua 语义逐行对照)与实现保证。
    """
    phone = _phone()
    u = await make_user(phone=phone, must_change=False)
    r = await client.post(RESET_SEND, json={"phone": phone})
    assert r.status_code == 200
    code = fake_sms.calls[-1]["code"]
    rs = await asyncio.gather(
        client.post(RESET_CONFIRM, json={"phone": phone, "code": code}),
        client.post(RESET_CONFIRM, json={"phone": phone, "code": code}),
    )
    statuses = sorted(x.status_code for x in rs)
    assert statuses[0] == 200 and statuses[1] in (400, 429), [x.text for x in rs]
    winner = next(x for x in rs if x.status_code == 200)
    new_pw = winner.json()["new_password"]
    async with get_sessionmaker()() as db:
        row = await db.get(User, u.id)
    assert row is not None
    assert verify_password(new_pw, row.password_hash), "生效密码与 200 响应一致(无二次覆盖)"
    assert await rclient.exists(pv.code_key("reset", phone)) == 0


@pytest.mark.asyncio
async def test_confirm_ownership_recheck_after_rebind(client, fake_sms, make_user):
    """条目 11:归属复核——发码后换绑,旧号的码 confirm → 400 过期(不泄露差异)。"""
    x, y = _phone(), _phone()
    a = await make_user(phone=x, must_change=False)
    b = await make_user(must_change=False)  # 无手机;随后接管 x(镜像二次放号)
    r = await client.post(RESET_SEND, json={"phone": x})
    assert r.status_code == 200
    code = fake_sms.calls[-1]["code"]
    # DB 直写等价态:A 换绑到 Y、B 接管 X(唯一约束下换绑=覆盖,与 bind 端点同效),
    # 触发「发码时归属 ≠ 当前归属」复核分支。
    # 顺序钉死、两次独立提交(先 A→Y 释放 X,再 B→X 认领):同事务批量 UPDATE
    # 行序不保证,若 B→X 先落行此刻 073 仍被 A 持有 → 撞 uq_users_phone
    # (dev 容器实锤);两个 phone 写点绝不能合并成一次批量写
    async with get_sessionmaker()() as db:
        ra = await db.get(User, a.id)
        assert ra is not None
        ra.phone = y
        await db.commit()  # A→Y 先落库:X 此刻已释放
        rb = await db.get(User, b.id)
        assert rb is not None
        rb.phone = x
        await db.commit()  # B→X 后落库:认领 X
    r = await client.post(RESET_CONFIRM, json={"phone": x, "code": code})
    assert r.status_code == 400, r.text
    assert r.json()["detail"] == "验证码已过期,请重新获取"


@pytest.mark.asyncio
async def test_confirm_edges_code_deleted_unbound_bad_format(client, fake_sms, rclient, make_user):
    """条目 12(前半):confirm 后码键已 DEL(同码重放 400 过期);未绑定号/错格式文案。"""
    phone = _phone()
    await make_user(phone=phone)
    r = await client.post(RESET_SEND, json={"phone": phone})
    assert r.status_code == 200
    code = fake_sms.calls[-1]["code"]
    r = await client.post(RESET_CONFIRM, json={"phone": phone, "code": code})
    assert r.status_code == 200, r.text
    assert await rclient.exists(pv.code_key("reset", phone)) == 0, "confirm 后码键已 DEL"
    # 同码重放 → 400 过期(键已消费)
    r = await client.post(RESET_CONFIRM, json={"phone": phone, "code": code})
    assert r.status_code == 400
    assert r.json()["detail"] == "验证码已过期,请重新获取"
    # 未绑定号(从未发码)→ 400 过期,不泄露未绑定事实
    r = await client.post(RESET_CONFIRM, json={"phone": _phone(), "code": "ABC234"})
    assert r.status_code == 400
    assert r.json()["detail"] == "验证码已过期,请重新获取"
    # 错格式 → 400 手机号格式不正确(纯格式错不消耗任何计数)
    r = await client.post(RESET_CONFIRM, json={"phone": "12345", "code": "ABC234"})
    assert r.status_code == 400
    assert r.json()["detail"] == "手机号格式不正确"


@pytest.mark.asyncio
async def test_confirm_503_when_sms_unconfigured(client, monkeypatch):
    """条目 12(后半):confirm 的 503 未配置(四端点统一首步守卫)。"""
    _pin_sms_disabled(monkeypatch)
    # getattr 兜底:属性缺席(未配置形态 lifespan 不写入)时 prev=None,语义等价
    prev = getattr(_APP.state, "sms", None)
    _APP.state.sms = None
    try:
        r = await client.post(RESET_CONFIRM, json={"phone": _phone(), "code": "ABC234"})
        assert r.status_code == 503
        assert r.json()["detail"] == "短信服务未配置"
    finally:
        _APP.state.sms = prev
