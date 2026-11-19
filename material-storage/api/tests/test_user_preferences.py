"""用户级偏好集成测试 — GET/PUT /api/v1/me/preferences(2026-11-19 设置页收拢包)。

唯一需求依据:`docs/qdev/2026-11-19-settings-mcp-collapse-folders.md`
(§6 接口定义 / §9 测试功能点后端 8 条)。覆盖:
  1. 未登录 GET/PUT → 401(无 cookie / 无 PAT / 无 X-User-Id);
  2. 无偏好行用户 GET → 200 且 folder_tree_default_collapsed=false(F11);
  3. PUT {true} → 200 返回 true;再 GET → true(服务端持久化);
  4. PUT 部分更新语义:None 字段跳过,重复 PUT 不丢键 / 不重置默认;
  5. 用户间隔离:A 开 true 不影响 B(每 user 恰一行);
  6. 422:body 非法(非 JSON)/ 字段类型错误;
  7. upsert 幂等:连续 PUT 同值不重复建行(SELECT FOR UPDATE → INSERT/UPDATE);
  8. 迁移文件存在且 revision 链接到当前 head 20261118_0022(静态检查,不连 DB)。

跑在 ms-api 容器内(PM 统一执行);前置同 tests/test_pat_lifecycle.py:
seed_demo_data 已跑(Evan=system admin)、env=dev(X-User-Id header 模拟身份)。
清理惯例:每用例自建用户(无删除 API,沿用现状);收尾按 user_id 直删
user_prefs 行。
"""
from __future__ import annotations

import re
import uuid
from pathlib import Path

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import create_app

# seed 契约账号(同既有测试):Evan = 真 user + system admin
EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"

URL = "/api/v1/me/preferences"
MIGRATION_FILENAME = "2026_11_19_0023_user_prefs.py"
PREV_MIGRATION_FILENAME = "2026_11_18_0022_baidu_vip_parallel.py"

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
async def _cleanup_prefs():
    """收尾删掉本用例建的用户的 user_prefs 行(用户无删除 API,沿用现状)。"""
    start = len(_CREATED_USERS)
    try:
        yield
    finally:
        users = _CREATED_USERS[start:]
        del _CREATED_USERS[start:]
        await _delete_prefs_for_users(users)


def _h(user_id: str) -> dict[str, str]:
    return {"X-User-Id": user_id}


def _uniq(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:8]}"


# ─── 自建用户 + DB 辅助(照 test_pat_lifecycle.py 惯例)──────────────────────
async def _create_user(client: AsyncClient, prefix: str = "pref_u") -> str:
    """经 admin API 现建 active 本地用户 → user id(dev X-User-Id 通道无视强制改密)。"""
    username = _uniq(prefix)
    r = await client.post(
        "/api/v1/admin/directory/users",
        json={"username": username, "name": f"Prefs {username}"},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text
    body = r.json()
    _CREATED_USERS.append(body["id"])
    return body["id"]


async def _delete_prefs_for_users(user_ids: list[str]) -> None:
    from sqlalchemy import delete

    from app.db.session import get_sessionmaker
    from app.db.tables import UserPref

    if not user_ids:
        return
    async with get_sessionmaker()() as db:
        await db.execute(
            delete(UserPref).where(UserPref.user_id.in_([uuid.UUID(u) for u in user_ids]))
        )
        await db.commit()


async def _prefs_row_count(user_id: str) -> int:
    from sqlalchemy import func, select

    from app.db.session import get_sessionmaker
    from app.db.tables import UserPref

    async with get_sessionmaker()() as db:
        return int(
            (
                await db.execute(
                    select(func.count())
                    .select_from(UserPref)
                    .where(UserPref.user_id == uuid.UUID(user_id))
                )
            ).scalar_one()
        )


# ─── §9-1:未登录 GET/PUT → 401 ───────────────────────────────────────────────
@pytest.mark.asyncio
async def test_unauthenticated_get_and_put_401(client: AsyncClient) -> None:
    r_get = await client.get(URL)
    assert r_get.status_code == 401, r_get.text

    r_put = await client.put(URL, json={"folder_tree_default_collapsed": True})
    assert r_put.status_code == 401, r_put.text


# ─── §9-2:无偏好行用户 GET → 200 且 false(F11)─────────────────────────────
@pytest.mark.asyncio
async def test_get_without_row_returns_default_false(client: AsyncClient) -> None:
    user_id = await _create_user(client, "pref_fresh")
    assert await _prefs_row_count(user_id) == 0  # 前置:确实无行

    r = await client.get(URL, headers=_h(user_id))
    assert r.status_code == 200, r.text
    body = r.json()
    assert body == {"folder_tree_default_collapsed": False}, body  # 全集且只含已知键
    assert await _prefs_row_count(user_id) == 0, "GET 不得建行"


# ─── §9-3:PUT true → 200 true;再 GET → true(持久化)───────────────────────
@pytest.mark.asyncio
async def test_put_true_persists(client: AsyncClient) -> None:
    user_id = await _create_user(client, "pref_put")

    r = await client.put(
        URL, json={"folder_tree_default_collapsed": True}, headers=_h(user_id),
    )
    assert r.status_code == 200, r.text
    assert r.json() == {"folder_tree_default_collapsed": True}

    r2 = await client.get(URL, headers=_h(user_id))
    assert r2.status_code == 200, r2.text
    assert r2.json() == {"folder_tree_default_collapsed": True}, "PUT 后再 GET 必须持久"


# ─── §9-4:部分更新语义:None 字段跳过,重复 PUT 不丢键 ────────────────────────
@pytest.mark.asyncio
async def test_partial_update_skips_none_and_keeps_keys(client: AsyncClient) -> None:
    user_id = await _create_user(client, "pref_partial")

    # 先开 true
    r1 = await client.put(
        URL, json={"folder_tree_default_collapsed": True}, headers=_h(user_id),
    )
    assert r1.status_code == 200 and r1.json()["folder_tree_default_collapsed"] is True

    # 空 body(全 None 字段)→ 跳过合并,不重置回默认 false
    r2 = await client.put(URL, json={}, headers=_h(user_id))
    assert r2.status_code == 200, r2.text
    assert r2.json() == {"folder_tree_default_collapsed": True}, "None 字段跳过,不得丢键"

    # 显式传 false → 覆盖生效(部分更新 ≠ 只增不改)
    r3 = await client.put(
        URL, json={"folder_tree_default_collapsed": False}, headers=_h(user_id),
    )
    assert r3.status_code == 200 and r3.json() == {"folder_tree_default_collapsed": False}


# ─── §9-5:用户间隔离:A 开关不影响 B ─────────────────────────────────────────
@pytest.mark.asyncio
async def test_isolation_between_users(client: AsyncClient) -> None:
    alice = await _create_user(client, "pref_alice")
    bob = await _create_user(client, "pref_bob")

    r = await client.put(
        URL, json={"folder_tree_default_collapsed": True}, headers=_h(alice),
    )
    assert r.status_code == 200, r.text

    # B 未写 → 默认 false;B 写 false 不影响 A
    r_bob = await client.get(URL, headers=_h(bob))
    assert r_bob.status_code == 200 and r_bob.json()["folder_tree_default_collapsed"] is False
    await client.put(
        URL, json={"folder_tree_default_collapsed": False}, headers=_h(bob),
    )
    r_bob2 = await client.get(URL, headers=_h(bob))
    assert r_bob2.json() == {"folder_tree_default_collapsed": False}

    # A 的开关仍是 true(B 的写入不外溢)
    r_alice = await client.get(URL, headers=_h(alice))
    assert r_alice.json() == {"folder_tree_default_collapsed": True}


# ─── §9-6:422 —— body 非法 / 字段类型错误 ────────────────────────────────────
@pytest.mark.asyncio
async def test_put_invalid_body_422(client: AsyncClient) -> None:
    user_id = await _create_user(client, "pref_422")

    # 字段类型错误:字符串不是 bool(pydantic → 422,同既有语义)
    r = await client.put(
        URL, json={"folder_tree_default_collapsed": "not-a-bool"}, headers=_h(user_id),
    )
    assert r.status_code == 422, r.text

    # body 非法:非 JSON 文本(Content-Type: application/json)
    r2 = await client.put(
        URL, content="{not json", headers={"Content-Type": "application/json", **_h(user_id)},
    )
    assert r2.status_code == 422, r2.text

    # 422 不得建行 / 改值
    assert await _prefs_row_count(user_id) == 0


# ─── §9-7:upsert 幂等 —— 连续 PUT 同值不重复建行 ─────────────────────────────
@pytest.mark.asyncio
async def test_upsert_idempotent_no_duplicate_rows(client: AsyncClient) -> None:
    user_id = await _create_user(client, "pref_idem")

    for _ in range(3):
        r = await client.put(
            URL, json={"folder_tree_default_collapsed": True}, headers=_h(user_id),
        )
        assert r.status_code == 200, r.text
    assert await _prefs_row_count(user_id) == 1, "连续 PUT 同值必须只建一行"

    # 反向再翻一次:仍是 UPDATE,不新建行
    await client.put(
        URL, json={"folder_tree_default_collapsed": False}, headers=_h(user_id),
    )
    assert await _prefs_row_count(user_id) == 1


# ─── §9-8:迁移文件存在且 revision 链接到当前 head(静态检查,不连 DB)─────────
def test_migration_exists_and_links_to_current_head() -> None:
    versions_dir = Path(__file__).resolve().parents[1] / "app" / "db" / "migrations" / "versions"
    src = (versions_dir / MIGRATION_FILENAME).read_text(encoding="utf-8")
    assert 'revision: str = "20261119_0023"' in src
    assert 'down_revision: str | Sequence[str] | None = "20261118_0022"' in src

    # 前驱确实是 0022 文件声明的 revision id(防前驱改号后链接悬空 / 双 head)
    prev_src = (versions_dir / PREV_MIGRATION_FILENAME).read_text(encoding="utf-8")
    assert 'revision: str = "20261118_0022"' in prev_src
    children = [
        p.name
        for p in versions_dir.glob("*.py")
        if re.search(r'down_revision[^=]*=\s*"20261118_0022"', p.read_text(encoding="utf-8"))
    ]
    assert children == [MIGRATION_FILENAME], f"0022 的子迁移应恰为本文件: {children}"


# ─── 附加:ORM 元数据与迁移列定义一致(schema 静态,照 test_db_schema 惯例)────
def test_user_prefs_schema_metadata() -> None:
    from sqlalchemy.dialects.postgresql import JSONB

    from app.db.tables import Base, UserPref

    assert "user_prefs" in Base.metadata.tables
    cols = UserPref.__table__.c
    assert cols.user_id.primary_key is True
    assert isinstance(cols.prefs.type, JSONB)
    assert cols.prefs.nullable is False
    assert str(cols.prefs.server_default.arg).strip() == "'{}'::jsonb"
    assert cols.updated_at.nullable is False
    fks = {fk.parent.name: fk for fk in UserPref.__table__.foreign_keys}
    assert fks["user_id"].ondelete == "CASCADE"
    assert fks["user_id"].target_fullname == "users.id"
