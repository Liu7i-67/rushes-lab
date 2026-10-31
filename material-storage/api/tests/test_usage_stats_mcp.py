"""usage_stats mcp 渠道桶 集成测试(MCP 素材服务包 A3,D11)。

需求依据:`docs/qdev/2026-10-30-mcp-service.md`(D11、工作包 A7、
测试功能点「usage_stats:UA msmcp/* 归入 mcp 桶」)。覆盖:
  - UA `msmcp/<ver>` 归入 `mcp` 桶(platform 与 platform_class 两层);
  - mcp 分支排在 web_desktop 之前(msmcp UA 不得落到 web_desktop);
  - 对照:桌面浏览器 UA 仍归 web_desktop,不误入 mcp。

预期前置(同 tests/test_usage_stats.py):seed_demo_data 已跑(Evan=system
admin)、OpenFGA 已 push、env=dev(X-User-Id 模拟身份)、迁移 0020 已 upgrade。

造数:直插 audit_events 行(绕过 audit.write)精确控制 UA/actor/event_time;
样本落在 90~200 天前的窄窗口,与 now() 行隔离;每样本独立 actor。

口径注:mcp 桶只反映**审计可见操作**(上传/下载签发等)的渠道占比,search/
thumbnail 零审计会低估 AI 读流量(D11;真实流量以 /admin/mcp-settings 指标为准)。
"""
from __future__ import annotations

import random
import uuid
from datetime import UTC, datetime, timedelta

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import create_app

EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"  # system admin
URL = "/api/v1/admin/usage/stats"
DEDUP_PREFIX = "usage_mcp_test:"

_CHROME = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/126.0.0.0 Safari/537.36"
_MCP_UA = "msmcp/0.1.0"

_TMP_USERS: list[str] = []


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
async def _cleanup(client: AsyncClient):
    _TMP_USERS.clear()
    await _delete_rows()
    try:
        yield
    finally:
        await _delete_rows()
        await _disable_users(client, _TMP_USERS)


def _h(user_id: str) -> dict[str, str]:
    return {"X-User-Id": user_id}


def _iso(dt: datetime) -> str:
    return dt.isoformat()


async def _delete_rows() -> None:
    from sqlalchemy import delete

    from app.db.session import get_sessionmaker
    from app.db.tables import AuditEvent

    async with get_sessionmaker()() as db:
        await db.execute(
            delete(AuditEvent).where(AuditEvent.dedup_key.like(f"{DEDUP_PREFIX}%"))
        )
        await db.commit()


async def _make_actors(client: AsyncClient, n: int) -> list[str]:
    """现建 n 个用户作独立样本 actor(FK 需真实用户;收尾统一禁用)。"""
    actors: list[str] = []
    for i in range(n):
        r = await client.post("/api/v1/admin/directory/users", json={
            "username": f"usage_mcp_{uuid.uuid4().hex[:10]}",
            "name": f"Usage MCP 样本 {i}",
        }, headers=_h(EVAN_ID))
        assert r.status_code == 201, r.text
        actors.append(r.json()["id"])
    _TMP_USERS.extend(actors)
    return actors


async def _disable_users(client: AsyncClient, uids: list[str]) -> None:
    for uid in uids:
        rd = await client.post(f"/api/v1/admin/directory/users/{uid}/disable", headers=_h(EVAN_ID))
        assert rd.status_code in (200, 409), rd.text


async def _seed_rows(rows: list[dict]) -> tuple[datetime, datetime]:
    """直插 audit_events;返回覆盖窗口 [min-120s, max+120s]。"""
    from app.db.session import get_sessionmaker
    from app.db.tables import AuditEvent

    base = datetime.now(UTC).replace(microsecond=0) - timedelta(
        days=random.randint(90, 200), minutes=random.randint(0, 1440),
    )
    for i, r in enumerate(rows):
        r.setdefault("event_type", "upload")
        r.setdefault("t", base + timedelta(seconds=i))
    async with get_sessionmaker()() as db:
        for r in rows:
            db.add(AuditEvent(
                id=uuid.uuid4(), event_type=r["event_type"],
                actor_user_id=uuid.UUID(r["actor"]),
                dedup_key=f"{DEDUP_PREFIX}{uuid.uuid4().hex}",
                request_ip="10.1.2.3", user_agent=r["ua"],
                details={}, event_time=r["t"],
            ))
        await db.commit()
    times = [r["t"] for r in rows]
    return min(times) - timedelta(seconds=120), max(times) + timedelta(seconds=120)


# ─── UA msmcp/* → mcp 桶(platform + platform_class);桌面浏览器不误入 ────────
async def test_msmcp_ua_bucketed_as_mcp(client: AsyncClient) -> None:
    actors = await _make_actors(client, 2)
    lo, hi = await _seed_rows([
        {"ua": _MCP_UA, "actor": actors[0]},
        {"ua": "msmcp/1.2.3", "actor": actors[0]},
        {"ua": _CHROME, "actor": actors[1]},
    ])
    r = await client.get(
        URL, params={"from": _iso(lo), "to": _iso(hi), "daily": "false"},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    body = r.json()

    by_platform = {x["platform"]: (x["users"], x["events"]) for x in body["by_platform"]}
    # 两条 msmcp UA(同 actor)归 mcp 桶;users=1 / events=2
    assert by_platform.get("mcp") == (1, 2), by_platform
    # 桌面浏览器不进 mcp;仍归 web_desktop
    assert by_platform.get("web_desktop") == (1, 1), by_platform

    by_class = {
        x["platform_class"]: (x["users"], x["events"])
        for x in body["by_platform_class"]
    }
    assert by_class.get("mcp") == (1, 2), by_class
    assert by_class.get("web") == (1, 1), by_class

    assert body["totals"] == {"users": 2, "events": 3}, body["totals"]
    assert body["daily"] == [], "daily=false 时必须回 []"
