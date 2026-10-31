"""PAT 排除清单精确性 + batch-move 上限 + hard 真值同源解析 — 测试。

需求:`docs/qdev/2026-10-30-mcp-service.md` C.6(**七项排除**、``hard`` 与 Pydantic
同源、多值 400、解析失败放行、batch-move 封顶 200)+ 测试功能点「PAT 排除清单
精确性」。

策略:真实 app + ``dependency_overrides[get_current_user]`` 造 PAT 身份
(**不碰 DB/OpenFGA**)。被排除的路由断言 **403 + 文案**;未被排除的路由断言
**不是闸的 403**(后续因缺 state 报 500 属本测试的预期 —— 用
``raise_app_exceptions=False`` 只看状态码)。session 回归(真 200)见文件末尾,
需 DB/seed(dev 容器)。
"""
from __future__ import annotations

import uuid
from types import SimpleNamespace
from typing import Any

import pytest
import redis.asyncio as redis_asyncio
from fastapi import Request
from httpx import ASGITransport, AsyncClient
from sqlalchemy import text

from app.deps import CurrentUser, get_current_user
from app.main import create_app
from app.services.mcp_gate import PAT_FORBIDDEN_DETAIL
from app.services.mcp_settings import McpSettings
from app.settings import get_settings


@pytest.fixture(scope="session")
async def redis_client():
    settings = get_settings()
    client = redis_asyncio.from_url(str(settings.redis_url), decode_responses=True)
    try:
        await client.ping()
    except Exception:
        pytest.skip("Redis 不可达:本文件需 ms-redis(dev 容器内跑)")
    yield client
    await client.aclose()


PAT_USER_ID = uuid.uuid4()
PAT_TOKEN_ID = uuid.uuid4()


@pytest.fixture
async def pat_client(redis_client: Any):
    app = create_app()
    app.state.redis = redis_client
    app.state.mcp_settings = SimpleNamespace()

    async def _pat_user(request: Request) -> CurrentUser:
        request.state.auth_method = "pat"
        request.state.auth_token_id = PAT_TOKEN_ID
        request.state.mcp_flag = McpSettings(True, 8, 4, 120, 600)
        return CurrentUser(id=PAT_USER_ID, name="pat-user")

    app.dependency_overrides[get_current_user] = _pat_user
    transport = ASGITransport(app=app, raise_app_exceptions=False)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac
    app.dependency_overrides.clear()


def _gate_detail(resp: Any) -> str:
    try:
        return str(resp.json().get("detail") or "")
    except Exception:
        return ""


# ─── 1) 七项排除:一律 403 + 文案 ───────────────────────────────────────────
@pytest.mark.parametrize(
    ("method", "url", "kwargs"),
    [
        ("POST", "/api/v1/assets/batch-prefix", {"json": {"asset_ids": []}}),
        ("GET", "/api/v1/admin/audit/export.csv", {}),
        ("POST", "/api/v1/admin/grant-templates/apply-default", {"json": {}}),
        ("POST", "/api/v1/admin/directory/users/{uid}/disable", {}),
        ("GET", "/api/v1/admin/usage/stats", {}),
        ("DELETE", "/api/v1/folders/{fid}", {}),
    ],
)
async def test_excluded_routes_are_403_with_detail(
    pat_client: AsyncClient, method: str, url: str, kwargs: dict[str, Any],
) -> None:
    target = url.format(uid=uuid.uuid4(), fid=uuid.uuid4())
    resp = await pat_client.request(method, target, **kwargs)
    assert resp.status_code == 403
    assert _gate_detail(resp) == PAT_FORBIDDEN_DETAIL


@pytest.mark.parametrize("hard", ["true", "1", "t", "y", "on", "TRUE", "Yes", "ON"])
async def test_delete_asset_hard_truthy_is_403(pat_client: AsyncClient, hard: str) -> None:
    """``?hard`` 用 TypeAdapter(bool) 同源解析:1/t/y/on/TRUE/Yes 一律 403。"""
    resp = await pat_client.delete(f"/api/v1/assets/{uuid.uuid4()}?hard={hard}")
    assert resp.status_code == 403
    assert _gate_detail(resp) == PAT_FORBIDDEN_DETAIL


@pytest.mark.parametrize("hard", ["false", "0", "f", "n", "off", "FALSE"])
async def test_delete_asset_hard_falsy_passes_gate(
    pat_client: AsyncClient, hard: str,
) -> None:
    """软删分支 PAT 正常可用(不得误伤)。"""
    resp = await pat_client.delete(f"/api/v1/assets/{uuid.uuid4()}?hard={hard}")
    assert resp.status_code != 403 or _gate_detail(resp) != PAT_FORBIDDEN_DETAIL


async def test_delete_asset_without_hard_passes_gate(pat_client: AsyncClient) -> None:
    resp = await pat_client.delete(f"/api/v1/assets/{uuid.uuid4()}")
    assert _gate_detail(resp) != PAT_FORBIDDEN_DETAIL


async def test_delete_asset_hard_multi_value_is_400(pat_client: AsyncClient) -> None:
    """多值(`?hard=false&hard=true`)一律 400(防 gate 与端点取值不一致被绕过)。"""
    resp = await pat_client.delete(f"/api/v1/assets/{uuid.uuid4()}?hard=false&hard=true")
    assert resp.status_code == 400
    assert "hard" in _gate_detail(resp)


async def test_delete_asset_hard_unparseable_passes_to_endpoint(pat_client: AsyncClient) -> None:
    """解析失败(`?hard=maybe`)→ 放行给端点 422,gate 不得自行 403/500。"""
    resp = await pat_client.delete(f"/api/v1/assets/{uuid.uuid4()}?hard=maybe")
    assert _gate_detail(resp) != PAT_FORBIDDEN_DETAIL
    assert resp.status_code != 403


# ─── 2) 按 method 判定:GET/PATCH 文件夹不被误伤 ────────────────────────────
@pytest.mark.parametrize("method", ["GET", "PATCH"])
async def test_folder_read_and_rename_not_excluded(
    pat_client: AsyncClient, method: str,
) -> None:
    resp = await pat_client.request(method, f"/api/v1/folders/{uuid.uuid4()}", json={})
    assert _gate_detail(resp) != PAT_FORBIDDEN_DETAIL


# ─── 3) batch-move:≤200 放行,>200 403 ─────────────────────────────────────
def _batch_move_body(count: int) -> dict[str, Any]:
    return {
        "asset_ids": [str(uuid.uuid4()) for _ in range(count)],
        "target_folder_id": str(uuid.uuid4()),
    }


async def test_batch_move_at_limit_passes_gate(pat_client: AsyncClient) -> None:
    resp = await pat_client.post("/api/v1/assets/batch-move", json=_batch_move_body(200))
    assert _gate_detail(resp) != PAT_FORBIDDEN_DETAIL


@pytest.mark.parametrize("count", [201, 1000])
async def test_batch_move_over_limit_is_403(pat_client: AsyncClient, count: int) -> None:
    resp = await pat_client.post("/api/v1/assets/batch-move", json=_batch_move_body(count))
    assert resp.status_code == 403
    assert "200" in _gate_detail(resp)


async def test_batch_move_malformed_body_passes_gate(pat_client: AsyncClient) -> None:
    """解析失败放行(由端点返回 422),gate 不得 500。"""
    resp = await pat_client.post(
        "/api/v1/assets/batch-move", content=b"not-json",
        headers={"content-type": "application/json"},
    )
    assert _gate_detail(resp) != PAT_FORBIDDEN_DETAIL


# ─── 4) session 回归(需 DB + seed;dev 容器)────────────────────────────────
@pytest.fixture(scope="session")
async def live_client():
    """带 lifespan 的真实 app(DB/OpenFGA/Redis 全接线;缺任一前置则 skip)。"""
    from app.db.session import get_sessionmaker

    try:
        async with get_sessionmaker()() as db:
            await db.execute(text("SELECT 1"))
    except Exception:
        pytest.skip("DB 不可达:session 回归用例需 dev 容器(ms-db + seed)")

    app = create_app()
    try:
        async with app.router.lifespan_context(app):  # type: ignore[attr-defined]
            transport = ASGITransport(app=app)
            async with AsyncClient(transport=transport, base_url="http://test") as ac:
                yield ac
    except Exception:
        pytest.skip("lifespan 启动失败(OpenFGA/MinIO/Redis 不可达)")


EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"  # 系统 admin(seed 契约账号)


async def _first_folder_and_project() -> tuple[uuid.UUID, uuid.UUID]:
    from sqlalchemy import select

    from app.db.session import get_sessionmaker
    from app.db.tables import Folder, Project

    async with get_sessionmaker()() as db:
        # folders 表**没有** deleted_at(软删只在 projects):取任意未被软删项目下的
        # 目录即可,过滤列必须是真实存在的(否则 pytest 直接 AttributeError)。
        row = (await db.execute(
            select(Folder.id, Folder.project_id)
            .join(Project, Project.id == Folder.project_id)
            .where(Project.deleted_at.is_(None))
            .limit(1)
        )).first()
    if row is None:
        pytest.skip("seed 数据缺失(test_folder)")
    return row[0], row[1]


async def test_session_requests_survive_gate(live_client: AsyncClient) -> None:
    """★ 挂上 mcp_gate 后 session 请求仍 200(证明闸未污染 body/query 校验)。"""
    folder_id, project_id = await _first_folder_and_project()
    headers = {"X-User-Id": EVAN_ID}
    for url in (
        f"/api/v1/assets?folder_id={folder_id}",
        f"/api/v1/folders?project_id={project_id}",
        f"/api/v1/folders/{folder_id}",
    ):
        resp = await live_client.get(url, headers=headers)
        assert resp.status_code == 200, f"{url} -> {resp.status_code} {resp.text[:200]}"
