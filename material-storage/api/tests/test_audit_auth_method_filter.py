"""审计 auth_method 筛选 + CSV 列 集成测试(MCP 素材服务包 A3,D4)。

需求依据:`docs/qdev/2026-10-30-mcp-service.md`(D4、接口定义 B 的既有端点改造、
测试功能点「/admin/tokens 与 /admin/audit+export.csv」、PM 验收 12);邮箱账号
方案 §5.9 增补 `anonymous`(邮箱找回密码链路全部未认证,审计显式写 anonymous)。
覆盖:
  - `GET /admin/audit?auth_method=pat` 只回 pat 行;`session` 归并 NULL
    (NULL = 存量行 / worker / CLI,口径「非令牌操作」);`all` 全量;
  - `anonymous` 只回 anonymous 行;`session` **不含** anonymous(只改类型不
    加分支会让筛选返回全量,§5.9);
  - `AuditOut` 带 auth_method / auth_token_id 字段(NULL 行 auth_method=null);
  - `GET /admin/audit/export.csv` 与列表**同参**,表头末尾追加 auth_method 列,
    NULL 一律写 `session`(不写空串);既有列位不变;anonymous 原样输出;
  - 非法取值(非 all/session/pat/anonymous)→ 422。

预期前置(同 tests/test_usage_stats.py):seed_demo_data 已跑(Evan=system
admin)、OpenFGA 已 push、env=dev(X-User-Id 模拟身份)、迁移 0020 已 upgrade。

造数:直插 audit_events 行(绕过 audit.write)精确控制 auth_method;事件类型
每个用例唯一,查询都带 event_type 过滤,与其他用例/存量数据隔离。
"""
from __future__ import annotations

import csv
import io
import uuid
from datetime import UTC, datetime, timedelta

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import create_app

EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"  # system admin
URL = "/api/v1/admin/audit"
CSV_URL = "/api/v1/admin/audit/export.csv"
DEDUP_PREFIX = "audit_am_test:"
EVENT = f"audit_am_test_event_{uuid.uuid4().hex[:8]}"

# 既有 CSV 表头(新增列必须只追加在末尾,不破坏既有消费方)
_LEGACY_HEADER = [
    "time", "event_type", "actor_name", "actor_open_id",
    "target_project_id", "target_project_name",
    "target_asset_id", "target_asset_filename", "target_minio_key",
    "request_ip", "details_json",
]


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
async def _cleanup_rows():
    await _delete_rows()
    try:
        yield
    finally:
        await _delete_rows()


def _h(user_id: str) -> dict[str, str]:
    return {"X-User-Id": user_id}


async def _delete_rows() -> None:
    from sqlalchemy import delete

    from app.db.session import get_sessionmaker
    from app.db.tables import AuditEvent

    async with get_sessionmaker()() as db:
        await db.execute(
            delete(AuditEvent).where(AuditEvent.dedup_key.like(f"{DEDUP_PREFIX}%"))
        )
        await db.commit()


async def _seed(auth_methods: list[str | None]) -> None:
    """按给定 auth_method 序列直插行(NULL / 'session' / 'pat')。"""
    from app.db.session import get_sessionmaker
    from app.db.tables import AuditEvent

    base = datetime.now(UTC) - timedelta(minutes=5)
    async with get_sessionmaker()() as db:
        for i, method in enumerate(auth_methods):
            db.add(AuditEvent(
                id=uuid.uuid4(),
                event_type=EVENT,
                actor_user_id=uuid.UUID(EVAN_ID),
                dedup_key=f"{DEDUP_PREFIX}{uuid.uuid4().hex}",
                details={},
                request_ip="10.0.0.9",
                user_agent="pytest",
                event_time=base + timedelta(seconds=i),
                auth_method=method,
                auth_token_id=None,
            ))
        await db.commit()


async def _list(client: AsyncClient, **params: object) -> list[dict]:
    r = await client.get(
        URL, params={"event_type": EVENT, **params}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    return r.json()


# ─── 列表筛选四态:all / session(NULL 归并)/ pat / anonymous ────────────────
async def test_list_filter_all_session_pat(client: AsyncClient) -> None:
    await _seed([None, "session", "pat", "pat", "anonymous"])

    all_rows = await _list(client)  # 缺省 auth_method=all
    assert len(all_rows) == 5, all_rows
    all_explicit = await _list(client, auth_method="all")
    assert {r["id"] for r in all_explicit} == {r["id"] for r in all_rows}

    session_rows = await _list(client, auth_method="session")
    assert len(session_rows) == 2, "session 必须归并 NULL 行"
    assert {r["auth_method"] for r in session_rows} == {None, "session"}

    pat_rows = await _list(client, auth_method="pat")
    assert len(pat_rows) == 2
    assert {r["auth_method"] for r in pat_rows} == {"pat"}

    # §5.9:anonymous(邮箱找回密码)只回 anonymous;session 不含 anonymous
    anon_rows = await _list(client, auth_method="anonymous")
    assert len(anon_rows) == 1
    assert {r["auth_method"] for r in anon_rows} == {"anonymous"}
    assert "anonymous" not in {r["auth_method"] for r in session_rows}

    # AuditOut 新字段:pat 行 auth_token_id 存在(本造数恒 null);NULL 行原样 null
    for row in all_rows:
        assert "auth_token_id" in row, row
        assert row["auth_token_id"] is None
    assert all("auth_method" in r for r in all_rows)


# ─── CSV 与列表同参;NULL 写 session;表头只追加 ──────────────────────────────
def _parse_csv(text: str) -> tuple[list[str], list[dict[str, str]]]:
    reader = csv.DictReader(io.StringIO(text))
    rows = list(reader)
    return list(reader.fieldnames or []), rows


async def test_csv_same_filter_and_null_as_session(client: AsyncClient) -> None:
    await _seed([None, "session", "pat", "pat", "anonymous"])

    r = await client.get(
        CSV_URL,
        params={"event_type": EVENT, "auth_method": "session"},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    header, rows = _parse_csv(r.content.decode("utf-8-sig"))
    assert header[: len(_LEGACY_HEADER)] == _LEGACY_HEADER, header
    assert header[-1] == "auth_method", "auth_method 列必须追加在末尾"
    assert len(rows) == 2, rows
    # NULL 一律写 session(不写空串),与列表筛选口径一致
    assert {row["auth_method"] for row in rows} == {"session"}, rows

    r_pat = await client.get(
        CSV_URL, params={"event_type": EVENT, "auth_method": "pat"}, headers=_h(EVAN_ID),
    )
    header_pat, rows_pat = _parse_csv(r_pat.content.decode("utf-8-sig"))
    assert header_pat[-1] == "auth_method"
    assert len(rows_pat) == 2
    assert {row["auth_method"] for row in rows_pat} == {"pat"}

    # anonymous 原样输出(CSV 不归并;§10.1 审计段)
    r_anon = await client.get(
        CSV_URL, params={"event_type": EVENT, "auth_method": "anonymous"},
        headers=_h(EVAN_ID),
    )
    _header_anon, rows_anon = _parse_csv(r_anon.content.decode("utf-8-sig"))
    assert len(rows_anon) == 1
    assert {row["auth_method"] for row in rows_anon} == {"anonymous"}

    # all = 5 行(pat 行原样 pat,session/NULL 行 session,anonymous 原样)
    r_all = await client.get(
        CSV_URL, params={"event_type": EVENT, "auth_method": "all"}, headers=_h(EVAN_ID),
    )
    _header_all, rows_all = _parse_csv(r_all.content.decode("utf-8-sig"))
    assert len(rows_all) == 5
    assert [row["auth_method"] for row in rows_all].count("pat") == 2
    assert [row["auth_method"] for row in rows_all].count("session") == 2
    assert [row["auth_method"] for row in rows_all].count("anonymous") == 1


# ─── 非法取值 → 422(列表与 CSV 同类型)────────────────────────────────────
async def test_invalid_auth_method_422(client: AsyncClient) -> None:
    for url in (URL, CSV_URL):
        r = await client.get(
            url, params={"event_type": EVENT, "auth_method": "cookie"},
            headers=_h(EVAN_ID),
        )
        assert r.status_code == 422, (url, r.text)
