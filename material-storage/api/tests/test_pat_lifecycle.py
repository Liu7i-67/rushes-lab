"""PAT 生命周期集成测试(MCP 素材服务包 A1;跑在 ms-api 容器内)。

唯一需求依据:`docs/qdev/2026-10-30-mcp-service.md`(D2/D3/接口 A/
测试功能点「PAT 生命周期」)。覆盖:
  - 创建:明文只在 201 响应回显一次 + `Cache-Control: no-store` + token_prefix 前缀;
  - 上限 5(含 asyncio.gather 并发竞态,事务级 advisory lock 兜底)→ 第 6 个 409;
  - expires_in_days 边界:0 与 366 → 422(1/365 合法);
  - 强制改密态 → 403;
  - 列表:默认只回活跃(未吊销未过期),?include_revoked=1 才含历史行并标注;
  - 吊销:204、重复吊销幂等且不重复写审计、首次生效写一条 token_revoked;
  - 横向越权:用户 B 吊销 A 的 token → 404 且 A 的 token 状态不变。

预期前置(同 tests/test_project_pins.py):seed_demo_data 已跑(Evan=system
admin)、OpenFGA 已 push、env=dev(允许 X-User-Id header 模拟身份)。

**PAT 认证链**(带 Bearer 调用业务端点 → 401 / 过期 401 / 吊销后立即 401 /
强制改密态 403)属包 A2,本文件不写必然失败的用例,末尾保留一个 skip 占位。

清理惯例:每用例自建用户(无删除 API,沿用现状);收尾按 user_id 直删
personal_access_tokens 行(audit 行不清理,统计口径无影响)。
"""
from __future__ import annotations

import asyncio
import uuid

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import create_app

# seed 契约账号(同既有测试):Evan = 真 user + system admin
EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"

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
    """收尾删掉本用例建的用户的全部 PAT 行(用户无删除 API,沿用现状)。"""
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


# ─── 自建用户 + DB 辅助(照 test_project_pins.py / test_usage_stats.py 惯例)──
async def _create_user(client: AsyncClient, prefix: str = "pat_u") -> dict:
    """经 admin API 现建 active 本地用户 → DirectoryUserOut + temporary_password。"""
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
    """清 must_change_password(模拟首登已完成;无对应 API,照 DB 直改惯例)。"""
    from sqlalchemy import update

    from app.db.session import get_sessionmaker
    from app.db.tables import User

    async with get_sessionmaker()() as db:
        await db.execute(
            update(User).where(User.id == uuid.UUID(user_id))
            .values(must_change_password=False)
        )
        await db.commit()


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


async def _create_pat(
    client: AsyncClient, user_id: str, *, name: str | None = None, days: int = 90,
):
    return await client.post(
        "/api/v1/auth/tokens",
        json={"name": name or _uniq("tok"), "expires_in_days": days},
        headers=_h(user_id),
    )


async def _db_token(token_id: str):
    from app.db.session import get_sessionmaker
    from app.db.tables import PersonalAccessToken

    async with get_sessionmaker()() as db:
        return await db.get(PersonalAccessToken, uuid.UUID(token_id))


async def _set_expiry_past(token_id: str) -> None:
    from datetime import UTC, datetime, timedelta

    from sqlalchemy import update

    from app.db.session import get_sessionmaker
    from app.db.tables import PersonalAccessToken

    async with get_sessionmaker()() as db:
        await db.execute(
            update(PersonalAccessToken)
            .where(PersonalAccessToken.id == uuid.UUID(token_id))
            .values(expires_at=datetime.now(UTC) - timedelta(minutes=1))
        )
        await db.commit()


async def _active_token_count(user_id: str) -> int:
    from datetime import UTC, datetime

    from sqlalchemy import func, select

    from app.db.session import get_sessionmaker
    from app.db.tables import PersonalAccessToken

    async with get_sessionmaker()() as db:
        return int(
            (
                await db.execute(
                    select(func.count())
                    .select_from(PersonalAccessToken)
                    .where(
                        PersonalAccessToken.user_id == uuid.UUID(user_id),
                        PersonalAccessToken.revoked_at.is_(None),
                        PersonalAccessToken.expires_at > datetime.now(UTC),
                    )
                )
            ).scalar_one()
        )


async def _audits_for_token(event_type: str, token_id: str) -> list[dict]:
    from sqlalchemy import select

    from app.db.session import get_sessionmaker
    from app.db.tables import AuditEvent

    async with get_sessionmaker()() as db:
        rows = (
            await db.execute(
                select(AuditEvent.details).where(
                    AuditEvent.event_type == event_type,
                    AuditEvent.details["token_id"].astext == token_id,
                )
            )
        ).scalars().all()
        return [dict(r) for r in rows]


# ─── 创建:明文只回显一次 + no-store + 前缀 + token_created 审计 ──────────────
@pytest.mark.asyncio
async def test_create_token_plaintext_once_prefix_and_audit(client: AsyncClient) -> None:
    user = await _create_user(client)
    await _clear_forced_change(user["id"])

    r = await _create_pat(client, user["id"], name="我的 ZCode")
    assert r.status_code == 201, r.text
    body = r.json()
    raw = body["token"]
    assert raw.startswith("mspat_"), raw
    assert len(raw) == len("mspat_") + 43, "token_urlsafe(32) 去 padding 后 43 字符"
    assert body["token_prefix"] == raw[:16]
    assert body["name"] == "我的 ZCode"
    assert body["expires_at"]
    assert r.headers.get("cache-control") == "no-store"
    token_id = body["id"]

    # 列表:无明文(连 raw 子串都不该出现),字段齐全
    lst = await client.get("/api/v1/auth/tokens", headers=_h(user["id"]))
    assert lst.status_code == 200, lst.text
    items = lst.json()
    assert len(items) == 1
    item = items[0]
    assert item["id"] == token_id
    assert raw not in lst.text
    assert "token" not in item, "列表不得回 token 明文字段"
    assert "token_hash" not in item
    assert item["last_used_at"] is None
    assert item["revoked_at"] is None
    assert item["expired"] is False

    # 审计 token_created(details 含 token_id / token_prefix 快照)
    audits = await _audits_for_token("token_created", token_id)
    assert len(audits) == 1
    assert audits[0]["token_prefix"] == body["token_prefix"]


# ─── 上限 5:第 6 个 409;并发双创建 → 恰一个 201 一个 409 ─────────────────────
@pytest.mark.asyncio
async def test_active_limit_five_and_concurrent_race(client: AsyncClient) -> None:
    user = await _create_user(client, "pat_limit")
    await _clear_forced_change(user["id"])

    for i in range(5):
        r = await _create_pat(client, user["id"], name=f"tok-{i}")
        assert r.status_code == 201, f"第 {i + 1} 个应成功: {r.text}"

    r6 = await _create_pat(client, user["id"], name="tok-overflow")
    assert r6.status_code == 409, r6.text
    assert await _active_token_count(user["id"]) == 5

    # 并发竞态:恰 4 个活跃时同时发两个创建,事务级 advisory lock 串行化 →
    # 恰一个 201、一个 409,最终活跃数仍为 5(不超限)
    racer = await _create_user(client, "pat_race")
    await _clear_forced_change(racer["id"])
    for i in range(4):
        r = await _create_pat(client, racer["id"], name=f"race-{i}")
        assert r.status_code == 201, r.text
    r1, r2 = await asyncio.gather(
        _create_pat(client, racer["id"], name="race-a"),
        _create_pat(client, racer["id"], name="race-b"),
    )
    assert sorted([r1.status_code, r2.status_code]) == [201, 409], (
        f"并发创建必须恰一个成功: {r1.status_code} / {r2.status_code}"
    )
    assert await _active_token_count(racer["id"]) == 5


# ─── expires_in_days 边界:0 / 366 → 422;1 / 365 合法 ────────────────────────
@pytest.mark.asyncio
async def test_expires_in_days_bounds(client: AsyncClient) -> None:
    user = await _create_user(client, "pat_days")
    await _clear_forced_change(user["id"])

    assert (await _create_pat(client, user["id"], days=0)).status_code == 422
    assert (await _create_pat(client, user["id"], days=366)).status_code == 422
    assert (await _create_pat(client, user["id"], days=1)).status_code == 201
    assert (await _create_pat(client, user["id"], days=365)).status_code == 201


# ─── 强制改密态 → 403(口径同 /me:must_change_password 且已设密码)─────────────
@pytest.mark.asyncio
async def test_forced_change_password_403(client: AsyncClient) -> None:
    user = await _create_user(client, "pat_forced")
    assert user["must_change_password"] is True  # admin 建号默认强制改密

    r = await _create_pat(client, user["id"])
    assert r.status_code == 403, r.text
    assert await _active_token_count(user["id"]) == 0


# ─── 列表:默认只活跃;include_revoked=1 含历史并标 revoked/expired ───────────
@pytest.mark.asyncio
async def test_list_default_active_only_and_include_revoked(client: AsyncClient) -> None:
    user = await _create_user(client, "pat_list")
    await _clear_forced_change(user["id"])

    keep = (await _create_pat(client, user["id"], name="keep")).json()
    revoked = (await _create_pat(client, user["id"], name="revoked")).json()
    expired = (await _create_pat(client, user["id"], name="expired")).json()

    r = await client.delete(f"/api/v1/auth/tokens/{revoked['id']}", headers=_h(user["id"]))
    assert r.status_code == 204, r.text
    await _set_expiry_past(expired["id"])

    # 默认:只回 keep
    items = (await client.get("/api/v1/auth/tokens", headers=_h(user["id"]))).json()
    assert [i["id"] for i in items] == [keep["id"]]

    # include_revoked:回 3 条,历史行标注 revoked_at / expired
    all_items = (
        await client.get(
            "/api/v1/auth/tokens", params={"include_revoked": 1}, headers=_h(user["id"]),
        )
    ).json()
    by_id = {i["id"]: i for i in all_items}
    assert set(by_id) == {keep["id"], revoked["id"], expired["id"]}
    assert by_id[revoked["id"]]["revoked_at"] is not None
    assert by_id[expired["id"]]["expired"] is True
    assert by_id[keep["id"]]["revoked_at"] is None
    assert by_id[keep["id"]]["expired"] is False


# ─── 吊销:204 幂等 + 首次生效只写一条审计 ──────────────────────────────────
@pytest.mark.asyncio
async def test_revoke_idempotent_and_audit_once(client: AsyncClient) -> None:
    user = await _create_user(client, "pat_revoke")
    await _clear_forced_change(user["id"])
    token = (await _create_pat(client, user["id"])).json()

    r1 = await client.delete(f"/api/v1/auth/tokens/{token['id']}", headers=_h(user["id"]))
    assert r1.status_code == 204, r1.text
    assert r1.content == b""

    row = await _db_token(token["id"])
    assert row is not None and row.revoked_at is not None

    # 重复吊销:幂等 204,且不再写第二条审计
    r2 = await client.delete(f"/api/v1/auth/tokens/{token['id']}", headers=_h(user["id"]))
    assert r2.status_code == 204, r2.text

    audits = await _audits_for_token("token_revoked", token["id"])
    assert len(audits) == 1, f"重复吊销不得重复写审计: {audits}"
    assert audits[0]["reason"] == "self_revoked"
    assert audits[0]["actor"] == "self"
    assert audits[0]["token_prefix"] == token["token_prefix"]

    # 默认列表不再返回已吊销行
    items = (await client.get("/api/v1/auth/tokens", headers=_h(user["id"]))).json()
    assert items == []


# ─── 横向越权:用户 B 吊销 A 的 token → 404 且 A 状态不变 ─────────────────────
@pytest.mark.asyncio
async def test_cross_user_revoke_404_and_state_unchanged(client: AsyncClient) -> None:
    alice = await _create_user(client, "pat_alice")
    bob = await _create_user(client, "pat_bob")
    await _clear_forced_change(alice["id"])
    await _clear_forced_change(bob["id"])
    token = (await _create_pat(client, alice["id"])).json()

    # 他人 token:404(不泄露存在性)
    r = await client.delete(f"/api/v1/auth/tokens/{token['id']}", headers=_h(bob["id"]))
    assert r.status_code == 404, r.text
    # 随机 UUID:同样 404
    r2 = await client.delete(
        f"/api/v1/auth/tokens/{uuid.uuid4()}", headers=_h(bob["id"]),
    )
    assert r2.status_code == 404, r2.text

    # A 的 token 状态不变(仍活跃,且无 token_revoked 审计)
    row = await _db_token(token["id"])
    assert row is not None and row.revoked_at is None
    assert await _audits_for_token("token_revoked", token["id"]) == []
    items = (await client.get("/api/v1/auth/tokens", headers=_h(alice["id"]))).json()
    assert [i["id"] for i in items] == [token["id"]]


# ─── A2 后启用:PAT 认证链语义(过期/已吊销 → 401)────────────────────────────
@pytest.mark.skip(reason="PAT 认证链(get_current_user 的 Bearer 分支)属包 A2;启用后改为真实断言")
@pytest.mark.asyncio
async def test_expired_or_revoked_pat_401(client: AsyncClient) -> None:
    """A2 启用后:过期 / 已吊销 PAT 调 GET /auth/me → 401(方案接口定义 C)。"""
    user = await _create_user(client, "pat_401")
    await _clear_forced_change(user["id"])
    token = (await _create_pat(client, user["id"], days=1)).json()
    await _set_expiry_past(token["id"])
    r = await client.get(
        "/api/v1/auth/me", headers={"Authorization": f"Bearer {token['token']}"},
    )
    assert r.status_code == 401, r.text
