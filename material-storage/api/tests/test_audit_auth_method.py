"""审计写侧认证标注(D4 / D11)— 延迟读 state / contextvar / 列落库 / search 零审计。

需求:`docs/qdev/2026-10-30-mcp-service.md` C.9(``AuditService`` 持 request,
``write()`` 内延迟读 state;无 request 走 contextvar;worker 保持 NULL)+ 测试
功能点「审计:PAT 路径写 auth_method=pat+token_id;session 路径恒 session;
PAT 连续 100 次 search → 审计表零新增行」。

运行:
- 第一部分(默认延迟读口径)无需外部依赖;
- 后两部分需 **DB**(迁移 0020)+ Redis/OpenFGA(100 次 search 集成用例);
  前置缺失时 ``pytest.skip``。
"""
from __future__ import annotations

import uuid
from typing import Any

import pytest
from fastapi import Request
from sqlalchemy import delete, func, select, text

from app import deps as deps_mod
from app.db.session import get_sessionmaker
from app.services.audit import (
    AuditService,
    bind_auth_context,
    clear_auth_context,
    current_auth_context,
)


def make_request(*, auth_method: str | None = None, token_id: uuid.UUID | None = None) -> Request:
    request = Request({
        "type": "http",
        "http_version": "1.1",
        "method": "GET",
        "scheme": "http",
        "path": "/api/v1/assets/search",
        "raw_path": b"/api/v1/assets/search",
        "query_string": b"",
        "root_path": "",
        "headers": [],
        "client": ("10.9.8.1", 5000),
        "server": ("test", 80),
        "state": {},
    })
    if auth_method is not None:
        request.state.auth_method = auth_method
    if token_id is not None:
        request.state.auth_token_id = token_id
    return request


@pytest.fixture(autouse=True)
def _reset_context() -> Any:
    clear_auth_context()
    yield
    clear_auth_context()


# ─── 1) 默认延迟读口径(无依赖)────────────────────────────────────────────
def test_request_pat_state_wins() -> None:
    token_id = uuid.uuid4()
    svc = AuditService.__new__(AuditService)  # 只测判定,不碰 session
    svc._session = None  # type: ignore[assignment]
    svc._request = make_request(auth_method="pat", token_id=token_id)
    assert svc._default_auth() == ("pat", token_id)


def test_request_session_is_written_as_session_not_null() -> None:
    svc = AuditService.__new__(AuditService)
    svc._session = None  # type: ignore[assignment]
    svc._request = make_request(auth_method="session")
    assert svc._default_auth() == ("session", None)


def test_request_without_auth_method_falls_back_to_session() -> None:
    """有 request 且非 PAT → 写 "session"(新行不留 NULL)。"""
    svc = AuditService.__new__(AuditService)
    svc._session = None  # type: ignore[assignment]
    svc._request = make_request()
    assert svc._default_auth() == ("session", None)


def test_no_request_uses_contextvar() -> None:
    token_id = uuid.uuid4()
    bind_auth_context("pat", token_id)
    assert current_auth_context() == ("pat", token_id)
    svc = AuditService.__new__(AuditService)
    svc._session = None  # type: ignore[assignment]
    svc._request = None
    assert svc._default_auth() == ("pat", token_id)


def test_no_request_no_context_is_null() -> None:
    svc = AuditService.__new__(AuditService)
    svc._session = None  # type: ignore[assignment]
    svc._request = None
    assert svc._default_auth() == (None, None)


async def test_get_audit_passes_request() -> None:
    """``get_audit`` 必须把 request 传进 AuditService(D4 延迟读 state 的前提)。"""
    request = make_request(auth_method="pat", token_id=uuid.uuid4())
    agen = deps_mod.get_audit(request)
    svc = await agen.__anext__()
    try:
        assert svc._request is request
        assert svc._default_auth()[0] == "pat"
    finally:
        await agen.aclose()


# ─── 2) DB 落库(需迁移 0020)──────────────────────────────────────────────
async def _db_ready() -> bool:
    try:
        async with get_sessionmaker()() as db:
            await db.execute(text("SELECT auth_method FROM audit_events LIMIT 1"))
        return True
    except Exception:
        return False


@pytest.fixture
async def db_ready() -> None:
    if not await _db_ready():
        pytest.skip("audit_events.auth_method 不可读(DB 不可达或迁移 0020 未跑)")


async def _read_row(dedup_key: str) -> tuple[str | None, uuid.UUID | None] | None:
    from app.db.tables import AuditEvent

    async with get_sessionmaker()() as db:
        row = (await db.execute(
            select(AuditEvent.auth_method, AuditEvent.auth_token_id).where(
                AuditEvent.dedup_key == dedup_key
            )
        )).first()
    return None if row is None else (row[0], row[1])


async def _cleanup(dedup_keys: list[str]) -> None:
    from app.db.tables import AuditEvent

    async with get_sessionmaker()() as db:
        await db.execute(delete(AuditEvent).where(AuditEvent.dedup_key.in_(dedup_keys)))
        await db.commit()


@pytest.mark.parametrize(
    ("auth_method", "expect_method"),
    [("pat", "pat"), ("session", "session")],
)
async def test_write_persists_auth_method(
    db_ready: None, auth_method: str, expect_method: str,
) -> None:
    token_id = uuid.uuid4()
    dedup_key = f"test:audit-auth:{uuid.uuid4()}"
    request = make_request(
        auth_method=auth_method, token_id=token_id if auth_method == "pat" else None,
    )
    try:
        async with get_sessionmaker()() as session:
            await AuditService(session, request).write(
                event_type="test_audit_auth_method", dedup_key=dedup_key,
            )
        row = await _read_row(dedup_key)
        assert row is not None
        assert row[0] == expect_method
        assert row[1] == (token_id if auth_method == "pat" else None)
    finally:
        await _cleanup([dedup_key])


async def test_write_without_request_uses_contextvar(db_ready: None) -> None:
    token_id = uuid.uuid4()
    dedup_key = f"test:audit-auth:{uuid.uuid4()}"
    bind_auth_context("pat", token_id)
    try:
        # 模拟 notifications.py 形态:自建 AuditService(db)(无 request)
        async with get_sessionmaker()() as session:
            await AuditService(session).write(
                event_type="test_audit_auth_method", dedup_key=dedup_key,
            )
        assert await _read_row(dedup_key) == ("pat", token_id)
    finally:
        await _cleanup([dedup_key])


async def test_write_worker_without_context_is_null(db_ready: None) -> None:
    dedup_key = f"test:audit-auth:{uuid.uuid4()}"
    try:
        async with get_sessionmaker()() as session:
            await AuditService(session).write(
                event_type="test_audit_auth_method", dedup_key=dedup_key,
            )
        assert await _read_row(dedup_key) == (None, None)
    finally:
        await _cleanup([dedup_key])


# ─── 3) PAT 100 次 search → 审计表零新增(需 DB + Redis + OpenFGA)────────────
async def _count_audit() -> int:
    from app.db.tables import AuditEvent

    async with get_sessionmaker()() as db:
        return int((await db.execute(
            select(func.count()).select_from(AuditEvent)
        )).scalar_one())


async def test_pat_search_adds_no_audit_rows() -> None:
    """search/thumbnail 本就零审计:AI 高频读操作不得淹没审计表。"""
    if not await _db_ready():
        pytest.skip("DB / 迁移 0020 不可用")

    from httpx import ASGITransport, AsyncClient

    from app.db.tables import PersonalAccessToken, User
    from app.main import create_app
    from app.services.mcp_settings import McpSettings, McpSettingsService
    from app.services.tokens import create_token

    app = create_app()
    user_id = uuid.uuid4()
    token_row_id: uuid.UUID | None = None
    raw_token = ""
    settings_service: McpSettingsService | None = None
    previous_flag: McpSettings | None = None
    try:
        async with app.router.lifespan_context(app):  # type: ignore[attr-defined]
            settings_service = app.state.mcp_settings
            assert isinstance(settings_service, McpSettingsService)
            async with get_sessionmaker()() as db:
                db.add(User(
                    id=user_id, name=f"pat-search-{user_id.hex[:8]}",
                    email=None, is_active=True,
                    must_change_password=False, password_hash=None,
                ))
                await db.flush()
                created = await create_token(
                    db, user_id=user_id, name="search-test", expires_in_days=1,
                )
                await db.commit()
                token_row_id = created.id
                raw_token = created.token
                # 通道开启(默认全关;用例结束恢复原值)
                try:
                    previous_flag = await settings_service.read()
                except Exception:
                    previous_flag = None
                await settings_service.write(
                    db, McpSettings(True, 8, 4, 450, 900),
                )

            before = await _count_audit()
            transport = ASGITransport(app=app, raise_app_exceptions=False)
            async with AsyncClient(transport=transport, base_url="http://test") as ac:
                for _ in range(100):
                    resp = await ac.get(
                        "/api/v1/assets/search",
                        params={"q": "zzz-no-such-asset"},
                        headers={"Authorization": f"Bearer {raw_token}"},
                    )
                    assert resp.status_code == 200, resp.text[:200]
            after = await _count_audit()
            assert after == before, f"PAT search 不得写审计(新增 {after - before} 行)"
    finally:
        try:
            async with get_sessionmaker()() as db:
                # 恢复通道默认关闭(或原值);删临时 token / user
                if settings_service is not None:
                    await settings_service.write(
                        db, previous_flag or McpSettings(False, 8, 4, 120, 600),
                    )
                if token_row_id is not None:
                    await db.execute(delete(PersonalAccessToken).where(
                        PersonalAccessToken.id == token_row_id
                    ))
                await db.execute(delete(User).where(User.id == user_id))
                await db.commit()
        except Exception:  # 清理失败不影响断言结论
            pass
