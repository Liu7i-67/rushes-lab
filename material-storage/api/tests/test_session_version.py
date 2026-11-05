"""会话版本(方案 §5.5)+ 密码写点联动 + CLI 脚本测试(§10.1「会话版本」段)。

找回密码主链路用例在 tests/test_password_reset.py;本文件覆盖:
- 旧 JWT(无 ver / ver=null)迁移后仍可用;dev X-User-Id 通道不受版本影响
- change-password / 管理员重置 / disable ⇒ session_version+1 + 删未用重置
  token + DEL email:code + 清 email:chg:fail/lock;旧 cookie 401
- scripts/set_password.py(自增 + --username-only 不动密码/PAT/版本)与
  scripts/set_initial_admin.py(自增 + 删 token + commit 后清理回调)
共享 fakes 从 test_password_reset import(单文件 500 行上限拆分)。
"""
from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import select, update

from app.db.tables import PasswordResetToken, PersonalAccessToken, User
from app.deps import CurrentUser
from app.routers import directory
from app.services import password_reset as pr
from tests.test_password_reset import (
    PASS,
    Env,
    add_pat,
    add_token_row,
    build_env,
    local_auth,
    login_cookie,
    seed_user,
    token_rows,
)


@pytest.fixture
async def make_env(tmp_path: Any, monkeypatch: pytest.MonkeyPatch):
    made: list[AsyncClient] = []

    async def _make(**settings_overrides: Any) -> Env:
        env = await build_env(tmp_path, monkeypatch, **settings_overrides)
        made.append(env.client)
        return env

    yield _make
    for client in made:
        await client.aclose()


async def get_user(env: Env, user_id: uuid.UUID) -> User:
    async with env.factory() as db:
        user = await db.get(User, user_id)
        assert user is not None
        return user


async def user_tokens(env: Env, user_id: uuid.UUID) -> list[PasswordResetToken]:
    async with env.factory() as db:
        rows = (await db.execute(
            select(PasswordResetToken).where(PasswordResetToken.user_id == user_id)
        )).scalars().all()
    return list(rows)


# ─── 兼容:旧 JWT 无 ver / ver=null → 按 0 ───────────────────────────────────
async def test_legacy_jwt_without_or_null_ver_still_valid(make_env) -> None:
    env = await make_env()
    user = await seed_user(env, password_hash=local_auth(env).hash_password(PASS))
    from jose import jwt as jose_jwt

    secret, alg = env.settings.session_jwt_secret, env.settings.session_jwt_alg
    now = int(datetime.now(UTC).timestamp())
    claims = {"sub": str(user.id), "name": user.name, "iat": now, "exp": now + 600}
    for extra in ({}, {"ver": None}):
        token = jose_jwt.encode({**claims, **extra}, secret, algorithm=alg)
        me = await env.client.get(
            "/api/v1/auth/me", cookies={env.settings.session_cookie_name: token})
        assert me.status_code == 200, (extra, me.text)


async def test_encode_session_transient_user_writes_ver_zero(make_env) -> None:
    """transient User(session_version=None)签 JWT 不写出 ver:null(§5.5.1 第 1 步)。"""
    env = await make_env()
    transient = User(id=uuid.uuid4(), name="Ghost")
    payload = env.auth.decode_session(env.auth.encode_session(transient))
    assert payload["ver"] == 0


# ─── change-password(§5.5 自增点 1)──────────────────────────────────────────
async def test_change_password_bumps_version_and_cleans(make_env) -> None:
    env = await make_env()
    user = await seed_user(env, password_hash=local_auth(env).hash_password(PASS),
                           must_change_password=False)
    old_cookie = await login_cookie(env, user.username, PASS)
    await add_token_row(env, user, "reset-pending-token-000000000")
    env.redis._store.update({
        f"email:code:{user.id}": "x",
        f"email:chg:fail:user:{user.id}": "2",
        f"email:chg:lock:user:{user.id}": "1",
    })
    r = await env.client.post(
        "/api/v1/auth/change-password",
        cookies={env.settings.session_cookie_name: old_cookie},
        json={"old_password": PASS, "new_password": "newpass1x"})
    assert r.status_code == 200, r.text
    me = await env.client.get(
        "/api/v1/auth/me", cookies={env.settings.session_cookie_name: old_cookie})
    assert me.status_code == 401  # 改密后旧 cookie 失效
    assert (await get_user(env, user.id)).session_version == 1
    assert not await token_rows(env, user.id)  # 未用重置 token 被删
    assert not env.redis.keys_with_prefix(f"email:code:{user.id}")
    assert not env.redis.keys_with_prefix("email:chg:")
    await login_cookie(env, user.username, "newpass1x")


# ─── 管理员重置 / 禁用(§5.5 自增点 2 + 第 7 步)──────────────────────────────
class _FakePerms:
    async def revoke_user_completely(self, _s: str) -> int:
        return 0


def _req_stub(env: Env) -> Any:
    return type("R", (), {"app": env.app, "client": None, "headers": {}})()


async def test_admin_reset_bumps_and_cleans(make_env) -> None:
    env = await make_env()
    user = await seed_user(env, password_hash=local_auth(env).hash_password(PASS))
    await add_token_row(env, user, "admin-reset-tok-0000000000000")
    env.redis._store[f"email:code:{user.id}"] = "x"
    old_jwt = env.auth.encode_session(user)
    admin = CurrentUser(id=uuid.uuid4(), name="admin")
    async with env.factory() as db:
        out = await directory.reset_directory_user_password(
            user.id, _req_stub(env), db, admin, env.audit,
            env.app.state.local_auth)
    assert out.temporary_password
    assert (await get_user(env, user.id)).session_version == 1
    assert not await user_tokens(env, user.id)
    assert not env.redis.keys_with_prefix(f"email:code:{user.id}")
    await login_cookie(env, user.username, out.temporary_password)  # 临时密码可登录
    me = await env.client.get(
        "/api/v1/auth/me", cookies={env.settings.session_cookie_name: old_jwt})
    assert me.status_code == 401  # 管理员重置后目标旧 cookie 401


async def test_disable_bumps_and_cleans(make_env) -> None:
    env = await make_env()
    user = await seed_user(env, password_hash=local_auth(env).hash_password(PASS))
    await add_token_row(env, user, "disable-tok-00000000000000000")
    env.redis._store[f"email:code:{user.id}"] = "x"
    old_jwt = env.auth.encode_session(user)
    me_before = await env.client.get(
        "/api/v1/auth/me", cookies={env.settings.session_cookie_name: old_jwt})
    assert me_before.status_code == 200  # 启用态 cookie 可用(基线)
    admin = CurrentUser(id=uuid.uuid4(), name="admin")
    async with env.factory() as db:
        await directory.disable_directory_user(
            user.id, _req_stub(env), db, admin, _FakePerms(), env.audit)
    assert (await get_user(env, user.id)).session_version == 1
    assert not await user_tokens(env, user.id)
    assert not env.redis.keys_with_prefix(f"email:code:{user.id}")
    me = await env.client.get(
        "/api/v1/auth/me", cookies={env.settings.session_cookie_name: old_jwt})
    assert me.status_code == 401  # 禁用后旧 JWT 401(重新启用也不复活)


# ─── dev X-User-Id 通道不受版本影响 ─────────────────────────────────────────
async def test_dev_header_channel_ignores_version(make_env) -> None:
    env = await make_env(env="dev")
    user = await seed_user(env, password_hash=local_auth(env).hash_password(PASS))
    # 版本自增后,dev X-User-Id 通道不受影响(不校验 expected_session_version)
    async with env.factory() as db:
        await db.execute(
            update(User).where(User.id == user.id).values(session_version=5))
        await db.commit()
    me = await env.client.get("/api/v1/auth/me", headers={"X-User-Id": str(user.id)})
    assert me.status_code == 200, me.text


# ─── CLI:scripts/set_password.py(自增点 3)─────────────────────────────────
async def test_cli_set_password_bumps_and_username_only(
    make_env, monkeypatch: pytest.MonkeyPatch,
) -> None:
    from scripts import set_password as sp

    env = await make_env()
    user = await seed_user(env, password_hash=local_auth(env).hash_password(PASS),
                           must_change_password=False)
    pat_id = await add_pat(env, user.id)
    await add_token_row(env, user, "cli-reset-tok-000000000000000")
    cleaned: list[uuid.UUID] = []

    async def _fake_cleanup(uid: uuid.UUID | str) -> None:
        cleaned.append(uuid.UUID(str(uid)))
        await pr.post_password_change_cleanup(env.redis, uid)

    monkeypatch.setattr(sp, "get_sessionmaker", lambda: env.factory)
    monkeypatch.setattr(sp, "_cleanup_redis_shortlived", _fake_cleanup)
    # CLI 的 token_revoked 审计走真 AuditService(pg_insert 在 SQLite 编不了)→ 换 fake
    monkeypatch.setattr(sp, "AuditService", lambda _session: env.audit)
    await sp.set_password(str(user.id), "clipass99", None, must_change=False)
    assert cleaned == [user.id]  # commit 后 best-effort 清理被调用
    assert (await get_user(env, user.id)).session_version == 1
    assert not await user_tokens(env, user.id)  # 未用重置 token 被删
    async with env.factory() as db:
        pat = await db.get(PersonalAccessToken, pat_id)
        assert pat is not None and pat.revoked_at is not None  # D13 PAT 吊销
    await login_cookie(env, user.username, "clipass99")

    # --username-only:只改登录名,不动密码/PAT/must_change/session_version
    other = await seed_user(env, email="victim@example.com")
    with pytest.raises(SystemExit):  # 与他人邮箱跨列冲突 → 拒绝
        await sp.set_username_only(str(user.id), other.email)
    with pytest.raises(SystemExit):  # 禁 @
        await sp.set_username_only(str(user.id), "bad@name")
    with pytest.raises(SystemExit):  # 超长
        await sp.set_username_only(str(user.id), "a" * 65)
    await sp.set_username_only(str(user.id), "renamed.user-1")
    fresh = await get_user(env, user.id)
    assert fresh.username == "renamed.user-1"
    assert fresh.session_version == 1  # 未再自增
    assert fresh.must_change_password is False  # 未动
    assert local_auth(env).verify_password("clipass99", fresh.password_hash)
    async with env.factory() as db:
        pat = await db.get(PersonalAccessToken, pat_id)
        assert pat is not None and pat.revoked_at is not None  # 不重复吊销/不复活
    await login_cookie(env, "renamed.user-1", "clipass99")  # 密码未动


# ─── CLI:scripts/set_initial_admin.py(自增点 4)────────────────────────────
async def test_cli_set_initial_admin_bumps_and_cleans(
    make_env, monkeypatch: pytest.MonkeyPatch,
) -> None:
    from scripts import set_initial_admin as sia

    env = await make_env()
    user = await seed_user(env)
    await add_token_row(env, user, "init-admin-tok-00000000000000")
    env.redis._store[f"email:code:{user.id}"] = "x"
    cleaned: list[str] = []

    async def _capture(redis: Any, uid: str) -> None:
        cleaned.append(str(uid))
        await pr.post_password_change_cleanup(env.redis, uid)

    monkeypatch.setattr(sia, "get_sessionmaker", lambda: env.factory)
    monkeypatch.setattr(sia, "post_password_change_cleanup", _capture)
    monkeypatch.setattr(sia, "get_settings", lambda: env.settings)
    monkeypatch.setattr(sia, "AuditService", lambda _session: env.audit)
    monkeypatch.setattr(
        "sys.argv", ["set_initial_admin", user.username,
                     "--password", "bootpass7", "--no-force-change"])
    assert await sia.main() == 0
    assert cleaned == [str(user.id)]
    fresh = await get_user(env, user.id)
    assert fresh.session_version == 1  # transient (or 0)+1 不裸 += 1
    assert fresh.must_change_password is False
    assert not await user_tokens(env, user.id)
    assert not env.redis.keys_with_prefix(f"email:code:{user.id}")
    await login_cookie(env, user.username, "bootpass7")


# ─── 会话版本比对细节 ────────────────────────────────────────────────────────
async def test_version_mismatch_message_and_recovery(make_env) -> None:
    env = await make_env()
    user = await seed_user(env, password_hash=local_auth(env).hash_password(PASS))
    cookie = await login_cookie(env, user.username, PASS)
    async with env.factory() as db:
        await db.execute(
            update(User).where(User.id == user.id).values(session_version=1))
        await db.commit()
    me = await env.client.get(
        "/api/v1/auth/me", cookies={env.settings.session_cookie_name: cookie})
    assert me.status_code == 401
    assert "会话已失效" in me.text
    # 重新登录签出 ver=1 的新 JWT → 恢复
    await login_cookie(env, user.username, PASS)
    me2 = await env.client.get("/api/v1/auth/me")
    assert me2.status_code == 200, me2.text
