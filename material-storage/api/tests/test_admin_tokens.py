"""GET/DELETE /api/v1/admin/tokens 集成测试(MCP 素材服务包 A3)。

需求依据:`docs/qdev/2026-10-30-mcp-service.md`(接口定义 B、D4/D13、
测试功能点「/admin/tokens 与 /admin/audit+export.csv」、PM 验收 10)。覆盖:
  - GET 全量列表:**裸数组**;每行带 user_id / user_name(users.name)/
    username(可空),**不含 token_hash / 明文**;
  - user_id 过滤 + limit/offset 分页(limit 默认 100,le=500)+ 稳定序
    (created_at DESC, id DESC);
  - DELETE 管理员吊销任意 token → 204(不存在 404;重复吊销幂等 204,且只对
    首次生效的吊销写一条 token_revoked);
  - 审计 details:token_id / token_prefix / reason=admin_revoked / actor=admin
    + 目标 user_id(actor 是操作者);
  - 非系统管理员 → 403。

预期前置(同 tests/test_pat_lifecycle.py):seed_demo_data 已跑(Evan=system
admin)、OpenFGA 已 push、env=dev(X-User-Id 模拟身份)、迁移 0020 已 upgrade。

清理惯例:每用例自建用户 + PAT(用户无删除 API,沿用现状);收尾按 user_id 直删
personal_access_tokens 行并禁用临时用户(audit 行不清理,统计口径无影响)。
"""
from __future__ import annotations

import uuid

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import create_app

EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"  # system admin
BOB_ID = "00000000-0000-0000-0000-000000000002"   # 普通 member
URL = "/api/v1/admin/tokens"

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
async def _cleanup_tokens(client):
    """收尾删掉本用例建的用户之 PAT 行,并禁用临时用户(不留活跃账号)。"""
    start = len(_CREATED_USERS)
    try:
        yield
    finally:
        users = _CREATED_USERS[start:]
        del _CREATED_USERS[start:]
        await _delete_tokens_for_users(users)
        await _disable_users(client, users)


def _h(user_id: str) -> dict[str, str]:
    return {"X-User-Id": user_id}


def _uniq(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:8]}"


async def _create_user(client: AsyncClient, prefix: str = "adm_u") -> dict:
    username = _uniq(prefix)
    r = await client.post(
        "/api/v1/admin/directory/users",
        json={"username": username, "name": f"ADM {username}"},
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


async def _create_pat(client: AsyncClient, user_id: str, name: str | None = None) -> dict:
    r = await client.post(
        "/api/v1/auth/tokens",
        json={"name": name or _uniq("tok"), "expires_in_days": 90},
        headers=_h(user_id),
    )
    assert r.status_code == 201, r.text
    return r.json()


async def _db_token(token_id: str):
    from app.db.session import get_sessionmaker
    from app.db.tables import PersonalAccessToken

    async with get_sessionmaker()() as db:
        return await db.get(PersonalAccessToken, uuid.UUID(token_id))


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


async def _disable_users(client: AsyncClient, user_ids: list[str]) -> None:
    for uid in user_ids:
        rd = await client.post(
            f"/api/v1/admin/directory/users/{uid}/disable", headers=_h(EVAN_ID),
        )
        assert rd.status_code in (200, 409), rd.text


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


# ─── 列表:裸数组 + 用户字段 + 无 token_hash/明文 + user 过滤 ─────────────────
async def test_list_has_user_fields_and_no_hash(client: AsyncClient) -> None:
    alice = await _create_user(client, "adm_alice")
    bob = await _create_user(client, "adm_bob")
    await _clear_forced_change(alice["id"])
    await _clear_forced_change(bob["id"])
    a1 = await _create_pat(client, alice["id"], "alice-1")
    a2 = await _create_pat(client, alice["id"], "alice-2")
    b1 = await _create_pat(client, bob["id"], "bob-1")

    r = await client.get(URL, params={"user_id": alice["id"]}, headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    items = r.json()
    assert isinstance(items, list), "GET /admin/tokens 必须回裸数组"
    assert {i["id"] for i in items} == {a1["id"], a2["id"]}

    for item in items:
        assert item["user_id"] == alice["id"]
        assert item["user_name"] == alice["name"]
        assert item["username"] == alice["username"]
        assert item["token_prefix"] in (a1["token_prefix"], a2["token_prefix"])
        assert item["revoked_at"] is None
        assert item["expired"] is False
        assert "token_hash" not in item
        assert "token" not in item
    # 响应文本不得出现任何 token_hash 形态(列表永不回)
    assert "token_hash" not in r.text

    # created_at DESC 稳定序(同一用户两条;时间不晚于前一条)
    stamps = [i["created_at"] for i in items]
    assert stamps == sorted(stamps, reverse=True), stamps

    # 全量列表(默认 limit 100)同时含 bob 的 token
    all_items = (await client.get(URL, headers=_h(EVAN_ID))).json()
    ids = {i["id"] for i in all_items}
    assert {a1["id"], a2["id"], b1["id"]} <= ids
    assert len(all_items) <= 100


# ─── 分页:limit/offset 稳定序,user 过滤 ────────────────────────────────────
async def test_list_pagination_and_user_filter(client: AsyncClient) -> None:
    alice = await _create_user(client, "adm_page")
    await _clear_forced_change(alice["id"])
    t1 = await _create_pat(client, alice["id"], "page-1")
    t2 = await _create_pat(client, alice["id"], "page-2")

    p1 = (await client.get(
        URL, params={"user_id": alice["id"], "limit": 1}, headers=_h(EVAN_ID),
    )).json()
    p2 = (await client.get(
        URL, params={"user_id": alice["id"], "limit": 1, "offset": 1},
        headers=_h(EVAN_ID),
    )).json()
    assert len(p1) == 1 and len(p2) == 1
    assert p1[0]["id"] != p2[0]["id"]
    assert {p1[0]["id"], p2[0]["id"]} == {t1["id"], t2["id"]}
    # 稳定序:第 1 页的首条 = 全量列表该用户的首条
    full = (await client.get(
        URL, params={"user_id": alice["id"]}, headers=_h(EVAN_ID),
    )).json()
    assert p1[0]["id"] == full[0]["id"]

    # limit 上限 500 → 501 由 Pydantic 422
    r = await client.get(URL, params={"limit": 501}, headers=_h(EVAN_ID))
    assert r.status_code == 422, r.text


# ─── 管理员吊销任意 token:204 + 审计 actor=admin + 幂等 ─────────────────────
async def test_admin_revoke_any_token_and_audit(client: AsyncClient) -> None:
    alice = await _create_user(client, "adm_revoke")
    await _clear_forced_change(alice["id"])
    token = await _create_pat(client, alice["id"], "revoke-me")

    r = await client.delete(f"{URL}/{token['id']}", headers=_h(EVAN_ID))
    assert r.status_code == 204, r.text
    assert r.content == b""

    row = await _db_token(token["id"])
    assert row is not None and row.revoked_at is not None

    audits = await _audits_for_token("token_revoked", token["id"])
    assert len(audits) == 1, audits
    audit = audits[0]
    assert audit["actor"] == "admin"
    assert audit["reason"] == "admin_revoked"
    assert audit["token_prefix"] == token["token_prefix"]
    # 管理员吊销他人令牌:actor 是操作者(Evan),owner 记 details.user_id
    assert audit["user_id"] == alice["id"]

    # 重复吊销:幂等 204,不再写第二条审计
    r2 = await client.delete(f"{URL}/{token['id']}", headers=_h(EVAN_ID))
    assert r2.status_code == 204, r2.text
    assert len(await _audits_for_token("token_revoked", token["id"])) == 1

    # 列表可见已吊销行(revoked_at 非空;expired 仍 False)
    items = (await client.get(
        URL, params={"user_id": alice["id"]}, headers=_h(EVAN_ID),
    )).json()
    by_id = {i["id"]: i for i in items}
    assert by_id[token["id"]]["revoked_at"] is not None
    assert by_id[token["id"]]["expired"] is False


# ─── 404 与 403 ─────────────────────────────────────────────────────────────
async def test_revoke_missing_404_and_non_admin_403(client: AsyncClient) -> None:
    r = await client.delete(f"{URL}/{uuid.uuid4()}", headers=_h(EVAN_ID))
    assert r.status_code == 404, r.text
    assert (await client.get(URL, headers=_h(BOB_ID))).status_code == 403
    r2 = await client.delete(f"{URL}/{uuid.uuid4()}", headers=_h(BOB_ID))
    assert r2.status_code == 403, r2.text
