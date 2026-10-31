"""密码变更 / 禁用 ⇒ 吊销全部活跃 PAT(方案 D13 五处挂钩)集成测试。

需求依据:`docs/qdev/2026-10-30-mcp-service.md`(D13 / 测试功能点
「密码变更后全部 PAT 立即 401(四路径)」/「禁用吊销」)。覆盖五处挂钩:
  1. 自助改密 `POST /auth/change-password`(actor=self, reason=password_changed)
  2. 管理后台重置 `POST /admin/directory/users/{id}/reset-password`(actor=admin)
  3. `scripts/set_password.py`(actor=cli)
  4. `scripts/set_initial_admin.py`(actor=cli)
  5. `POST /admin/directory/users/{id}/disable`(actor=admin, reason=user_disabled)
语义钉死:只有「本次真正被吊销」的 token 逐条写 token_revoked;无活跃 token 不写。
另含事务回滚用例:commit 前抛错 → 密码与 PAT 状态均不变(吊销 UPDATE 与密码
写入同事务的安全不变量)。

跑在 ms-api 容器内(env=dev、seed_demo_data 已跑、OpenFGA 已 push)。
自建用户无删除 API(沿用现状);收尾直删其 PAT 行,被禁用的用户重新启用。
"""
from __future__ import annotations

import sys
import uuid

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import create_app

EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"  # system admin
_CREATED_USERS: list[str] = []


@pytest.fixture(scope="session")
async def app_with_lifespan():
    app = create_app()
    async with app.router.lifespan_context(app):  # type: ignore[attr-defined]
        yield app


@pytest.fixture(scope="session")
async def client(app_with_lifespan):
    transport = ASGITransport(app=app_with_lifespan)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


@pytest.fixture(autouse=True)
async def _cleanup_tokens():
    start = len(_CREATED_USERS)
    try:
        yield
    finally:
        users = _CREATED_USERS[start:]
        del _CREATED_USERS[start:]
        await _delete_tokens_for_users(users)


def _h(user_id: str) -> dict[str, str]:
    return {"X-User-Id": user_id}


def _uniq(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:8]}"


async def _create_user(client: AsyncClient, prefix: str = "pat_pw") -> dict:
    username = _uniq(prefix)
    r = await client.post(
        "/api/v1/admin/directory/users",
        json={"username": username, "name": f"PAT {username}"},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text
    body = r.json()
    _CREATED_USERS.append(body["id"])
    return body


async def _clear_forced_change(user_id: str) -> None:
    from sqlalchemy import update

    from app.db.session import get_sessionmaker
    from app.db.tables import User

    async with get_sessionmaker()() as db:
        await db.execute(
            update(User).where(User.id == uuid.UUID(user_id))
            .values(must_change_password=False)
        )
        await db.commit()


async def _create_pat(client: AsyncClient, user_id: str) -> dict:
    r = await client.post(
        "/api/v1/auth/tokens",
        json={"name": _uniq("tok"), "expires_in_days": 90},
        headers=_h(user_id),
    )
    assert r.status_code == 201, r.text
    return r.json()


async def _delete_tokens_for_users(user_ids: list[str]) -> None:
    from sqlalchemy import delete

    from app.db.session import get_sessionmaker
    from app.db.tables import PersonalAccessToken

    if not user_ids:
        return
    async with get_sessionmaker()() as db:
        await db.execute(
            delete(PersonalAccessToken).where(
                PersonalAccessToken.user_id.in_([uuid.UUID(u) for u in user_ids])
            )
        )
        await db.commit()


async def _token_row(token_id: str):
    from app.db.session import get_sessionmaker
    from app.db.tables import PersonalAccessToken

    async with get_sessionmaker()() as db:
        return await db.get(PersonalAccessToken, uuid.UUID(token_id))


async def _password_hash(user_id: str) -> str | None:
    from sqlalchemy import select

    from app.db.session import get_sessionmaker
    from app.db.tables import User

    async with get_sessionmaker()() as db:
        return (
            await db.execute(
                select(User.password_hash).where(User.id == uuid.UUID(user_id))
            )
        ).scalar_one()


async def _token_revoked_audits(user_id: str) -> list[dict]:
    """某用户的 token_revoked 审计(details.user_id 维度;五处挂钩都写此键)。"""
    from sqlalchemy import select

    from app.db.session import get_sessionmaker
    from app.db.tables import AuditEvent

    async with get_sessionmaker()() as db:
        rows = (
            await db.execute(
                select(AuditEvent.details).where(
                    AuditEvent.event_type == "token_revoked",
                    AuditEvent.details["user_id"].astext == user_id,
                )
            )
        ).scalars().all()
        return [dict(r) for r in rows]


# ─── 1. 自助改密:全部吊销 + actor=self ──────────────────────────────────────
@pytest.mark.asyncio
async def test_self_change_password_revokes_all_tokens(client: AsyncClient) -> None:
    user = await _create_user(client, "pat_self")
    await _clear_forced_change(user["id"])
    t1 = await _create_pat(client, user["id"])
    t2 = await _create_pat(client, user["id"])

    r = await client.post(
        "/api/v1/auth/change-password",
        json={"old_password": user["temporary_password"], "new_password": "newpass123"},
        headers=_h(user["id"]),
    )
    assert r.status_code == 200, r.text

    for t in (t1, t2):
        row = await _token_row(t["id"])
        assert row is not None and row.revoked_at is not None, "改密后 PAT 必须立即吊销"
    audits = await _token_revoked_audits(user["id"])
    assert len(audits) == 2, audits
    assert {a["reason"] for a in audits} == {"password_changed"}
    assert {a["actor"] for a in audits} == {"self"}
    assert {a["token_id"] for a in audits} == {t1["id"], t2["id"]}


@pytest.mark.asyncio
async def test_change_password_without_tokens_writes_no_revoke_audit(
    client: AsyncClient,
) -> None:
    """无活跃 PAT 时:密码照常变更,但不写任何 token_revoked 审计。"""
    user = await _create_user(client, "pat_none")
    await _clear_forced_change(user["id"])

    r = await client.post(
        "/api/v1/auth/change-password",
        json={"old_password": user["temporary_password"], "new_password": "newpass123"},
        headers=_h(user["id"]),
    )
    assert r.status_code == 200, r.text
    assert await _token_revoked_audits(user["id"]) == []


# ─── 2. 管理后台 reset-password:全部吊销 + actor=admin ──────────────────────
@pytest.mark.asyncio
async def test_directory_reset_password_revokes_tokens(client: AsyncClient) -> None:
    user = await _create_user(client, "pat_reset")
    await _clear_forced_change(user["id"])
    token = await _create_pat(client, user["id"])

    r = await client.post(
        f"/api/v1/admin/directory/users/{user['id']}/reset-password",
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    assert r.json()["temporary_password"], "重置密码必须回显新临时密码"

    row = await _token_row(token["id"])
    assert row is not None and row.revoked_at is not None
    audits = await _token_revoked_audits(user["id"])
    assert len(audits) == 1, audits
    assert audits[0]["actor"] == "admin"
    assert audits[0]["reason"] == "password_changed"
    assert audits[0]["token_id"] == token["id"]
    assert audits[0]["token_prefix"] == token["token_prefix"]


# ─── 3. scripts/set_password.py:actor=cli ──────────────────────────────────
@pytest.mark.asyncio
async def test_set_password_script_revokes_tokens(client: AsyncClient) -> None:
    from scripts.set_password import set_password

    user = await _create_user(client, "pat_cli")
    await _clear_forced_change(user["id"])
    token = await _create_pat(client, user["id"])

    await set_password(user["id"], "newpass123", None, False)

    row = await _token_row(token["id"])
    assert row is not None and row.revoked_at is not None
    audits = await _token_revoked_audits(user["id"])
    assert len(audits) == 1, audits
    assert audits[0]["actor"] == "cli"
    assert audits[0]["reason"] == "password_changed"


# ─── 4. scripts/set_initial_admin.py:actor=cli ─────────────────────────────
@pytest.mark.asyncio
async def test_set_initial_admin_script_revokes_tokens(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    from scripts import set_initial_admin

    user = await _create_user(client, "pat_init")
    await _clear_forced_change(user["id"])
    token = await _create_pat(client, user["id"])

    monkeypatch.setattr(
        sys, "argv",
        ["set_initial_admin", user["username"], "--password", "newpass123",
         "--no-force-change"],
    )
    rc = await set_initial_admin.main()
    assert rc == 0

    row = await _token_row(token["id"])
    assert row is not None and row.revoked_at is not None
    audits = await _token_revoked_audits(user["id"])
    assert len(audits) == 1, audits
    assert audits[0]["actor"] == "cli"
    assert audits[0]["reason"] == "password_changed"


# ─── 5. 禁用:全部吊销 + actor=admin;重新启用后旧 PAT 仍吊销(不复活)────────
@pytest.mark.asyncio
async def test_disable_user_revokes_tokens_and_no_revival(client: AsyncClient) -> None:
    user = await _create_user(client, "pat_disable")
    await _clear_forced_change(user["id"])
    token = await _create_pat(client, user["id"])

    try:
        r = await client.post(
            f"/api/v1/admin/directory/users/{user['id']}/disable", headers=_h(EVAN_ID),
        )
        assert r.status_code == 200, r.text

        row = await _token_row(token["id"])
        assert row is not None and row.revoked_at is not None
        audits = await _token_revoked_audits(user["id"])
        assert len(audits) == 1, audits
        assert audits[0]["actor"] == "admin"
        assert audits[0]["reason"] == "user_disabled"

        # 重新启用:旧 PAT 仍是已吊销(不复活;禁用吊销是永久动作)
        re = await client.post(
            f"/api/v1/admin/directory/users/{user['id']}/enable", headers=_h(EVAN_ID),
        )
        assert re.status_code == 200, re.text
        row2 = await _token_row(token["id"])
        assert row2 is not None and row2.revoked_at is not None
    finally:
        # 兜底:即使断言失败也尝试恢复启用状态(失败吞掉,不掩盖原断言)
        import contextlib

        with contextlib.suppress(Exception):
            await client.post(
                f"/api/v1/admin/directory/users/{user['id']}/enable", headers=_h(EVAN_ID),
            )


# ─── 事务回滚:commit 前抛错 → 密码与 PAT 状态均不变 ────────────────────────
@pytest.mark.asyncio
async def test_change_password_rollback_keeps_password_and_token(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """吊销 UPDATE 已执行、commit 之前抛错 → 事务整体回滚(密码与 PAT 都不变)。"""
    import app.routers.auth as auth_module

    user = await _create_user(client, "pat_rb_auth")
    await _clear_forced_change(user["id"])
    token = await _create_pat(client, user["id"])
    hash_before = await _password_hash(user["id"])

    original = auth_module.revoke_user_tokens

    async def _boom(db, *, user_id, reason):  # type: ignore[no-untyped-def]
        await original(db, user_id=user_id, reason=reason)
        raise RuntimeError("boom-before-commit")

    monkeypatch.setattr(auth_module, "revoke_user_tokens", _boom)

    with pytest.raises(RuntimeError):
        await client.post(
            "/api/v1/auth/change-password",
            json={"old_password": user["temporary_password"], "new_password": "newpass123"},
            headers=_h(user["id"]),
        )

    assert await _password_hash(user["id"]) == hash_before, "回滚后密码不得变更"
    row = await _token_row(token["id"])
    assert row is not None and row.revoked_at is None, "回滚后 PAT 不得被吊销"
    assert await _token_revoked_audits(user["id"]) == []


@pytest.mark.asyncio
async def test_directory_reset_rollback_keeps_password_and_token(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    import app.routers.directory as directory_module

    user = await _create_user(client, "pat_rb_dir")
    await _clear_forced_change(user["id"])
    token = await _create_pat(client, user["id"])
    hash_before = await _password_hash(user["id"])

    original = directory_module.revoke_user_tokens

    async def _boom(db, *, user_id, reason):  # type: ignore[no-untyped-def]
        await original(db, user_id=user_id, reason=reason)
        raise RuntimeError("boom-before-commit")

    monkeypatch.setattr(directory_module, "revoke_user_tokens", _boom)

    with pytest.raises(RuntimeError):
        await client.post(
            f"/api/v1/admin/directory/users/{user['id']}/reset-password",
            headers=_h(EVAN_ID),
        )

    assert await _password_hash(user["id"]) == hash_before
    row = await _token_row(token["id"])
    assert row is not None and row.revoked_at is None
    assert await _token_revoked_audits(user["id"]) == []


@pytest.mark.asyncio
async def test_set_password_script_rollback_keeps_password_and_token(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    import scripts.set_password as script_module

    user = await _create_user(client, "pat_rb_cli")
    await _clear_forced_change(user["id"])
    token = await _create_pat(client, user["id"])
    hash_before = await _password_hash(user["id"])

    original = script_module.revoke_user_tokens

    async def _boom(db, *, user_id, reason):  # type: ignore[no-untyped-def]
        await original(db, user_id=user_id, reason=reason)
        raise RuntimeError("boom-before-commit")

    monkeypatch.setattr(script_module, "revoke_user_tokens", _boom)

    with pytest.raises(RuntimeError):
        await script_module.set_password(user["id"], "newpass123", None, False)

    assert await _password_hash(user["id"]) == hash_before
    row = await _token_row(token["id"])
    assert row is not None and row.revoked_at is None
