"""PAT 认证链(``app/deps.py::get_current_user`` 的 PAT 分支)— 单元/Redis 集成测试。

需求:`docs/qdev/2026-10-30-mcp-service.md` 接口 C + 测试功能点「PAT 分支」/
「四段闸(通道闸/IP 桶/RPM)」/「Redis 故障注入三场景」。
运行:dev 容器(需 **ms-redis**;DB/MinIO/OpenFGA 不需要 —— 查表与用户态被
monkeypatch);直接调 ``get_current_user``,假 Request,不经 HTTP。
"""
from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace
from typing import Any

import pytest
import redis.asyncio as redis_asyncio
from fastapi import HTTPException, Request

from app import deps as deps_mod
from app.deps import CurrentUser, get_current_user
from app.services import mcp_auth as mcp_auth_mod
from app.services.mcp_limiter import ip_bucket_key, token_rpm_key
from app.services.mcp_settings import McpSettings, McpSettingsUnavailable
from app.services.tokens import ResolvedToken, hash_token
from app.settings import get_settings

RAW_TOKEN = "mspat_" + "A" * 43
OTHER_TOKEN = "mspat_" + "B" * 43
# autouse fixture 会把 mcp_auth.touch_last_used 换成 no-op;节流用例需原始实现
_REAL_TOUCH_LAST_USED = mcp_auth_mod.touch_last_used

def _flag(**overrides: Any) -> McpSettings:
    base: dict[str, Any] = {
        "enabled": True, "max_concurrency": 8, "per_token_concurrency": 4,
        "per_token_rpm": 120, "per_ip_rpm": 600,
    }
    base.update(overrides)
    return McpSettings(**base)


class FakeRedis:
    def __init__(self, *, fail_get: bool = False, fail_eval: bool = False) -> None:
        self.counters: dict[str, int] = {}
        self.kv: dict[str, str] = {}
        self.fail_get = fail_get
        self.fail_eval = fail_eval

    async def get(self, key: str) -> str | None:
        if self.fail_get:
            raise ConnectionError("redis down(get)")
        return self.kv.get(key)

    async def eval(self, script: str, numkeys: int, *args: Any) -> int:
        if self.fail_eval:
            raise ConnectionError("redis down(eval)")
        key = str(args[0])
        self.counters[key] = self.counters.get(key, 0) + 1
        return self.counters[key]

    async def set(self, key: str, value: str, nx: bool = False, ex: int | None = None) -> Any:
        if nx and key in self.kv:
            return None
        self.kv[key] = value
        return True


class FakeSettingsService:
    def __init__(self, value: McpSettings | Exception) -> None:
        self.value = value
        self.reads = 0

    async def read(self) -> McpSettings:
        self.reads += 1
        if isinstance(self.value, Exception):
            raise self.value
        return self.value


class FakeAuthService:
    def __init__(self, *, sub: str | None = None) -> None:
        self.sub = sub

    def decode_session(self, token: str) -> dict[str, str]:
        if self.sub is None:
            raise ValueError("bad signature")
        return {"sub": self.sub}

def make_request(
    *,
    bearer: str | None = None,
    cookie: str | None = None,
    client_ip: str = "10.9.0.1",
    app_state: SimpleNamespace | None = None,
) -> Request:
    headers: list[tuple[bytes, bytes]] = []
    if bearer is not None:
        headers.append((b"authorization", bearer.encode("latin-1")))
    if cookie is not None:
        headers.append((b"cookie", f"ms_session={cookie}".encode("latin-1")))
    app = SimpleNamespace(state=app_state if app_state is not None else SimpleNamespace())
    return Request({
        "type": "http", "http_version": "1.1", "method": "GET", "scheme": "http",
        "path": "/api/v1/projects", "raw_path": b"/api/v1/projects",
        "query_string": b"", "root_path": "", "headers": headers,
        "client": (client_ip, 52000), "server": ("test", 80), "app": app, "state": {},
    })

def make_state(*, settings_service: Any, redis: Any, auth: Any = None) -> SimpleNamespace:
    return SimpleNamespace(mcp_settings=settings_service, redis=redis, auth=auth)

def make_resolved(
    *, user_id: uuid.UUID | None = None, token_id: uuid.UUID | None = None,
    expired: bool = False, revoked: bool = False,
) -> ResolvedToken:
    now = datetime.now(UTC)
    return ResolvedToken(
        id=token_id or uuid.uuid4(),
        user_id=user_id or uuid.uuid4(),
        token_prefix=RAW_TOKEN[:16],
        expires_at=now - timedelta(seconds=1) if expired else now + timedelta(days=30),
        revoked_at=now if revoked else None,
    )

def patch_token(
    monkeypatch: pytest.MonkeyPatch,
    *,
    resolved: ResolvedToken | None = None,
    forced_change: bool = False,
    lookup_calls: dict[str, int] | None = None,
) -> None:
    async def _lookup(raw: str) -> ResolvedToken | None:
        if lookup_calls is not None:
            lookup_calls["n"] = lookup_calls.get("n", 0) + 1
        return resolved

    async def _load(uid: uuid.UUID, *, expected_session_version: int | None = None) -> tuple[CurrentUser, bool]:
        return CurrentUser(id=uid, name="alice"), forced_change

    monkeypatch.setattr(mcp_auth_mod, "lookup_token", _lookup)
    monkeypatch.setattr(deps_mod, "load_active_user", _load)

@pytest.fixture(scope="session")
async def redis_client():
    settings = get_settings()
    client = redis_asyncio.from_url(str(settings.redis_url), decode_responses=True)
    try:
        await client.ping()
    except Exception:  # 无 Redis 直接 skip(dev 容器应有)
        pytest.skip("Redis 不可达:本文件需 ms-redis(dev 容器内跑)")
    yield client
    await client.aclose()

@pytest.fixture(autouse=True)
def _isolate(monkeypatch: pytest.MonkeyPatch):
    """负缓存/contextvar/节流复位 + 生产 env(decode 失败不回落 X-User-Id)。"""
    mcp_auth_mod.negative_token_cache.clear()

    async def _noop_touch(redis: Any, token_id: uuid.UUID) -> None:
        return None

    monkeypatch.setattr(mcp_auth_mod, "touch_last_used", _noop_touch)
    monkeypatch.setattr(
        deps_mod, "get_settings",
        lambda: SimpleNamespace(env="production", session_cookie_name="ms_session"),
    )
    yield
    mcp_auth_mod.negative_token_cache.clear()


# ─── 1) 有效 PAT = 用户本人 ────────────────────────────────────────────────
async def test_valid_pat_returns_owner_with_state(
    redis_client: Any, monkeypatch: pytest.MonkeyPatch,
) -> None:
    uid = uuid.uuid4()
    resolved = make_resolved(user_id=uid)
    flag = _flag()
    request = make_request(
        bearer=f"Bearer {RAW_TOKEN}", client_ip="10.9.1.1",
        app_state=make_state(settings_service=FakeSettingsService(flag), redis=redis_client),
    )
    patch_token(monkeypatch, resolved=resolved)
    user = await get_current_user(request)
    assert user.id == uid
    assert request.state.auth_method == "pat"
    assert request.state.auth_token_id == resolved.id
    assert request.state.mcp_flag is flag
    assert getattr(request.state, "mcp_reject_reason", None) is None
    await redis_client.delete(ip_bucket_key("10.9.1.1"), token_rpm_key(resolved.id))

@pytest.mark.parametrize("scheme", ["Bearer", "bearer", "BEARER", "bEaReR"])
async def test_bearer_scheme_is_case_insensitive(
    redis_client: Any, monkeypatch: pytest.MonkeyPatch, scheme: str,
) -> None:
    resolved = make_resolved()
    request = make_request(
        bearer=f"{scheme} {RAW_TOKEN}", client_ip="10.9.1.2",
        app_state=make_state(settings_service=FakeSettingsService(_flag()), redis=redis_client),
    )
    patch_token(monkeypatch, resolved=resolved)
    user = await get_current_user(request)
    assert user.id == resolved.user_id
    await redis_client.delete(ip_bucket_key("10.9.1.2"), token_rpm_key(resolved.id))

async def test_non_mspat_bearer_is_401() -> None:
    request = make_request(
        bearer="Bearer not-a-pat-token", client_ip="10.9.1.3",
        app_state=make_state(settings_service=FakeSettingsService(_flag()), redis=FakeRedis()),
    )
    with pytest.raises(HTTPException) as exc:
        await get_current_user(request)
    assert exc.value.status_code == 401
    assert exc.value.detail == mcp_auth_mod.PAT_INVALID_DETAIL


# ─── 2) cookie 回落边界 ────────────────────────────────────────────────────
async def test_cookie_decode_failure_falls_back_to_pat(
    redis_client: Any, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """生产不再直接 401:僵尸 cookie 不能挡死 ms-mcp 转发的 PAT 请求。"""
    resolved = make_resolved()
    request = make_request(
        cookie="stale-jwt", bearer=f"Bearer {RAW_TOKEN}", client_ip="10.9.2.1",
        app_state=make_state(
            settings_service=FakeSettingsService(_flag()), redis=redis_client,
            auth=FakeAuthService(sub=None),
        ),
    )
    patch_token(monkeypatch, resolved=resolved)
    user = await get_current_user(request)
    assert user.id == resolved.user_id
    assert request.state.auth_method == "pat"
    await redis_client.delete(ip_bucket_key("10.9.2.1"), token_rpm_key(resolved.id))

async def test_cookie_decode_ok_but_user_disabled_raises_without_fallback(
    redis_client: Any, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """F5:decode 成功但用户态 401(禁用/删除)→ 直接抛,**不回落** PAT。"""
    cookie_uid = uuid.uuid4()
    request = make_request(
        cookie="valid-jwt", bearer=f"Bearer {RAW_TOKEN}", client_ip="10.9.2.2",
        app_state=make_state(
            settings_service=FakeSettingsService(_flag()), redis=redis_client,
            auth=FakeAuthService(sub=str(cookie_uid)),
        ),
    )
    calls: dict[str, int] = {}
    patch_token(monkeypatch, resolved=make_resolved(), lookup_calls=calls)

    async def _load_disabled(uid: uuid.UUID, *, expected_session_version: int | None = None) -> tuple[CurrentUser, bool]:
        raise HTTPException(401, "账号已停用,请联系管理员")

    monkeypatch.setattr(deps_mod, "load_active_user", _load_disabled)
    with pytest.raises(HTTPException) as exc:
        await get_current_user(request)
    assert exc.value.status_code == 401
    assert exc.value.detail == "账号已停用,请联系管理员"
    assert calls.get("n", 0) == 0, "禁用用户不得回落 PAT(F5 立即下线)"

async def test_cookie_wins_over_bearer(redis_client: Any, monkeypatch: pytest.MonkeyPatch) -> None:
    """cookie 与 Bearer 同发 → cookie 优先(现状语义不变)。"""
    cookie_uid = uuid.uuid4()
    request = make_request(
        cookie="valid-jwt", bearer=f"Bearer {RAW_TOKEN}", client_ip="10.9.2.3",
        app_state=make_state(
            settings_service=FakeSettingsService(_flag()), redis=redis_client,
            auth=FakeAuthService(sub=str(cookie_uid)),
        ),
    )
    calls: dict[str, int] = {}
    patch_token(monkeypatch, resolved=make_resolved(), lookup_calls=calls)
    user = await get_current_user(request)
    assert user.id == cookie_uid
    assert request.state.auth_method == "session"
    assert calls.get("n", 0) == 0


# ─── 3) 通道闸(第一步)─────────────────────────────────────────────────────
async def test_channel_closed_403_without_any_redis_count() -> None:
    """enabled=false → 403 文案钉死 + reason=channel_closed;零 Redis 计数。"""
    request = make_request(
        bearer=f"Bearer {RAW_TOKEN}", client_ip="10.9.3.1",
        app_state=make_state(
            settings_service=FakeSettingsService(_flag(enabled=False)),
            redis=FakeRedis(fail_eval=True),
        ),
    )
    with pytest.raises(HTTPException) as exc:
        await get_current_user(request)
    assert exc.value.status_code == 403
    assert exc.value.detail == mcp_auth_mod.MCP_CHANNEL_CLOSED_DETAIL
    assert request.state.mcp_reject_reason == "channel_closed"

async def test_channel_unavailable_403(redis_client: Any) -> None:
    """配置读不到(Redis+DB 双挂)→ 403 channel_unavailable(非 503)。"""
    request = make_request(
        bearer=f"Bearer {RAW_TOKEN}", client_ip="10.9.3.2",
        app_state=make_state(
            settings_service=FakeSettingsService(McpSettingsUnavailable("both down")),
            redis=redis_client,
        ),
    )
    with pytest.raises(HTTPException) as exc:
        await get_current_user(request)
    assert exc.value.status_code == 403
    assert exc.value.detail == mcp_auth_mod.MCP_CHANNEL_UNAVAILABLE_DETAIL
    assert request.state.mcp_reject_reason == "channel_unavailable"


# ─── 4) IP 桶 / RPM ───────────────────────────────────────────────────────
async def test_ip_bucket_429_with_retry_after(redis_client: Any) -> None:
    state = make_state(settings_service=FakeSettingsService(_flag(per_ip_rpm=1)), redis=redis_client)
    first = make_request(bearer=f"Bearer {RAW_TOKEN}", client_ip="10.9.4.1", app_state=state)
    with pytest.raises(HTTPException) as exc:
        await get_current_user(first)  # 第 1 次消耗 IP 桶 → 令牌无效 401
    assert exc.value.status_code == 401

    second = make_request(bearer=f"Bearer {OTHER_TOKEN}", client_ip="10.9.4.1", app_state=state)
    with pytest.raises(HTTPException) as exc2:
        await get_current_user(second)
    assert exc2.value.status_code == 429
    assert exc2.value.detail == mcp_auth_mod.MCP_RATE_LIMITED_DETAIL
    assert (exc2.value.headers or {}).get("Retry-After") is not None
    assert second.state.mcp_reject_reason == "quota_ip"
    await redis_client.delete(ip_bucket_key("10.9.4.1"))

async def test_ip_bucket_accumulates_across_tokens(
    redis_client: Any, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """IP 桶 = 「总请求/IP」:不同 token 同 IP 同一分钟累计(非单令牌配额)。"""
    state = make_state(settings_service=FakeSettingsService(_flag(per_ip_rpm=3)), redis=redis_client)
    patch_token(monkeypatch, resolved=make_resolved())
    for _ in range(3):
        request = make_request(bearer=f"Bearer {RAW_TOKEN}", client_ip="10.9.4.2", app_state=state)
        await get_current_user(request)
    assert int(await redis_client.get(ip_bucket_key("10.9.4.2")) or 0) == 3
    await redis_client.delete(ip_bucket_key("10.9.4.2"))

async def test_per_token_rpm_429(redis_client: Any, monkeypatch: pytest.MonkeyPatch) -> None:
    resolved = make_resolved()
    state = make_state(settings_service=FakeSettingsService(_flag(per_token_rpm=1)), redis=redis_client)
    patch_token(monkeypatch, resolved=resolved)
    await get_current_user(make_request(bearer=f"Bearer {RAW_TOKEN}", client_ip="10.9.4.3", app_state=state))

    second = make_request(bearer=f"Bearer {RAW_TOKEN}", client_ip="10.9.4.3", app_state=state)
    with pytest.raises(HTTPException) as exc:
        await get_current_user(second)
    assert exc.value.status_code == 429
    assert second.state.mcp_reject_reason == "quota_rpm"
    assert (exc.value.headers or {}).get("Retry-After") is not None
    await redis_client.delete(ip_bucket_key("10.9.4.3"), token_rpm_key(resolved.id))


# ─── 5) Redis / DB 故障 ───────────────────────────────────────────────────
async def test_redis_down_after_flag_from_db_503() -> None:
    """flag 已取到(DB 可用)、Redis 挂 → 503 fail-closed(reason=redis_down)。"""
    request = make_request(
        bearer=f"Bearer {RAW_TOKEN}", client_ip="10.9.5.1",
        app_state=make_state(
            settings_service=FakeSettingsService(_flag()), redis=FakeRedis(fail_eval=True),
        ),
    )
    with pytest.raises(HTTPException) as exc:
        await get_current_user(request)
    assert exc.value.status_code == 503
    assert request.state.mcp_reject_reason == "redis_down"

async def test_flag_miss_falls_back_to_db_then_redis_down_at_ip_bucket(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Redis get 挂 → 配置服务回源 DB(enabled=true)→ IP 桶 Redis 故障 → 503
    (证明 DB 回源生效:否则是 403 channel_unavailable)。"""
    from app.services.mcp_settings import McpSettingsService

    service = McpSettingsService(redis=FakeRedis(fail_get=True, fail_eval=True))

    async def _read_db() -> McpSettings:
        return _flag()

    monkeypatch.setattr(service, "_read_db", _read_db)
    request = make_request(
        bearer=f"Bearer {RAW_TOKEN}", client_ip="10.9.5.2",
        app_state=make_state(settings_service=service, redis=FakeRedis(fail_eval=True)),
    )
    with pytest.raises(HTTPException) as exc:
        await get_current_user(request)
    assert exc.value.status_code == 503
    assert request.state.mcp_reject_reason == "redis_down"


# ─── 6) 令牌状态 / 强制改密 / 负缓存 ──────────────────────────────────────
@pytest.mark.parametrize("state_kwargs", [{"revoked": True}, {"expired": True}])
async def test_revoked_or_expired_token_is_401(
    redis_client: Any, monkeypatch: pytest.MonkeyPatch, state_kwargs: dict[str, bool],
) -> None:
    resolved = make_resolved(**state_kwargs)
    request = make_request(
        bearer=f"Bearer {RAW_TOKEN}", client_ip="10.9.6.1",
        app_state=make_state(settings_service=FakeSettingsService(_flag()), redis=redis_client),
    )
    patch_token(monkeypatch, resolved=resolved)
    with pytest.raises(HTTPException) as exc:
        await get_current_user(request)
    assert exc.value.status_code == 401
    assert exc.value.detail == mcp_auth_mod.PAT_INVALID_DETAIL
    assert getattr(request.state, "mcp_reject_reason", None) is None  # 401 不计拒绝桶
    await redis_client.delete(ip_bucket_key("10.9.6.1"), token_rpm_key(resolved.id))

async def test_forced_change_password_403(
    redis_client: Any, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """D13:PAT 无 F15 豁免清单 —— 强制改密态一律 403。"""
    resolved = make_resolved()
    request = make_request(
        bearer=f"Bearer {RAW_TOKEN}", client_ip="10.9.6.2",
        app_state=make_state(settings_service=FakeSettingsService(_flag()), redis=redis_client),
    )
    patch_token(monkeypatch, resolved=resolved, forced_change=True)
    with pytest.raises(HTTPException) as exc:
        await get_current_user(request)
    assert exc.value.status_code == 403
    assert exc.value.detail == mcp_auth_mod.PAT_FORCED_CHANGE_DETAIL
    assert request.state.mcp_reject_reason == "forced_change"
    await redis_client.delete(ip_bucket_key("10.9.6.2"), token_rpm_key(resolved.id))

async def test_negative_cache_prevents_repeat_lookup(
    redis_client: Any, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """未命中负缓存:同一伪 token 只查一次 DB(不承担洪水防护)。"""
    calls: dict[str, int] = {}
    patch_token(monkeypatch, resolved=None, lookup_calls=calls)
    state = make_state(settings_service=FakeSettingsService(_flag()), redis=redis_client)
    for _ in range(3):
        request = make_request(bearer=f"Bearer {RAW_TOKEN}", client_ip="10.9.6.3", app_state=state)
        with pytest.raises(HTTPException):
            await get_current_user(request)
    assert calls.get("n", 0) == 1
    assert mcp_auth_mod.negative_token_cache.seen(hash_token(RAW_TOKEN))
    await redis_client.delete(ip_bucket_key("10.9.6.3"))


# ─── 7) last_used_at 节流 ─────────────────────────────────────────────────
async def test_last_used_throttle_skips_db_when_nx_fails(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """``SET NX`` 未成功 → 不写 DB(300s 节流)。"""
    touched = {"n": 0}

    def _sessionmaker_boom() -> Any:
        touched["n"] += 1
        raise AssertionError("节流内不应触碰 DB session")

    monkeypatch.setattr(mcp_auth_mod, "get_sessionmaker", _sessionmaker_boom)
    fake_redis = FakeRedis()
    token_id = uuid.uuid4()
    fake_redis.kv[f"mcp:lastused:{token_id}"] = "1"  # 预置 → NX 必失败
    await _REAL_TOUCH_LAST_USED(fake_redis, token_id)
    assert touched["n"] == 0

async def test_last_used_throttle_writes_db_when_first(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """首次(``SET NX`` 成功)→ UPDATE last_used_at(独立短 session)。"""
    executed: list[str] = []

    class _FakeSession:
        async def execute(self, stmt: Any) -> None:
            executed.append(str(stmt))

        async def commit(self) -> None:
            executed.append("commit")

        async def __aenter__(self) -> _FakeSession:
            return self

        async def __aexit__(self, *exc: object) -> None:
            return None

    monkeypatch.setattr(mcp_auth_mod, "get_sessionmaker", lambda: _FakeSession)
    await _REAL_TOUCH_LAST_USED(FakeRedis(), uuid.uuid4())
    assert executed and executed[-1] == "commit"


# ─── 8) 无凭据 ────────────────────────────────────────────────────────────
async def test_no_credential_is_401() -> None:
    request = make_request(
        client_ip="10.9.7.1", app_state=SimpleNamespace(auth=FakeAuthService(sub=None)),
    )
    with pytest.raises(HTTPException) as exc:
        await get_current_user(request)
    assert exc.value.status_code == 401

async def test_stale_cookie_without_pat_keeps_expired_session_message() -> None:
    """无 PAT 时,decode 失败的会话仍回原来的 401 文案(浏览器体验不变)。"""
    state = SimpleNamespace(auth=FakeAuthService(sub=None))
    request = make_request(cookie="stale", client_ip="10.9.7.2", app_state=state)
    with pytest.raises(HTTPException) as exc:
        await get_current_user(request)
    assert exc.value.status_code == 401
    assert exc.value.detail == "会话已过期或无效,请重新登录"
