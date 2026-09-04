"""回收站(软删/恢复/彻底删除)与删夹自动 purge 集成测试 — 容器内跑。

资产入库存走 DB 直插(presign 的 PUT 指向 MinIO 公网 endpoint,容器内不通,
与 seed_demo_data.py 同理由);purge 的 MinIO 对象删除是 best-effort,对不存在的
对象只 log 不报错,不影响断言。
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

import pytest
from httpx import ASGITransport, AsyncClient

from app.db.session import get_sessionmaker
from app.db.tables import Asset
from app.main import create_app

EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"
PROJECT_EVENT = "11111111-1111-1111-1111-111111111103"


def _h() -> dict[str, str]:
    return {"X-User-Id": EVAN_ID}


async def _insert_asset(
    folder_id: str, filename: str, *, deleted: bool = False,
    tags: dict | None = None,
) -> uuid.UUID:
    """直插一条 asset 行(模拟已上传文件;deleted=True 模拟软删后的回收站行)。"""
    async with get_sessionmaker()() as db:
        row = Asset(
            id=uuid.uuid4(),
            folder_id=uuid.UUID(folder_id),
            filename=filename,
            minio_bucket="ms-dev",
            minio_key=f"zz-test/{filename}",
            size_bytes=11,
            content_type="text/plain",
            uploader_id=uuid.UUID(EVAN_ID),
            deleted_at=datetime.now(timezone.utc) if deleted else None,
            tags=tags or {},
        )
        db.add(row)
        await db.commit()
        return row.id


async def _asset_exists(asset_id: uuid.UUID) -> bool:
    async with get_sessionmaker()() as db:
        return await db.get(Asset, asset_id) is not None


@pytest.fixture(scope="session")
async def app_with_lifespan():
    app = create_app()
    async with app.router.lifespan_context(app):  # type: ignore[attr-defined]
        yield app


@pytest.fixture(scope="session")
async def client(app_with_lifespan):
    transport = ASGITransport(app=app_with_lifespan)  # type: ignore[arg-type]
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


@pytest.mark.asyncio
async def test_trash_restore_purge_flow(client: AsyncClient) -> None:
    """软删 → 回收站可见 → 恢复 → 再软删 → 彻底删除(行消失)。"""
    uniq = uuid.uuid4().hex[:8]
    r = await client.post("/api/v1/folders", json={
        "project_id": PROJECT_EVENT, "name": f"zz_trash_{uniq}",
    }, headers=_h())
    assert r.status_code == 201, r.text
    fid = r.json()["id"]
    aid = await _insert_asset(
        fid, f"zz_trash_{uniq}.txt",
        tags={"thumbnail_key": f"thumbnails/{uniq}.jpg"},
    )

    # 软删 → 普通列表消失、回收站出现
    r = await client.delete(f"/api/v1/assets/{aid}", headers=_h())
    assert r.status_code == 204, r.text
    r = await client.get(f"/api/v1/assets?folder_id={fid}", headers=_h())
    assert r.status_code == 200 and len(r.json()) == 0
    r = await client.get(f"/api/v1/assets/trash?folder_id={fid}", headers=_h())
    assert r.status_code == 200, r.text
    trash = r.json()
    assert len(trash) == 1 and trash[0]["id"] == str(aid)
    assert trash[0]["deleted_at"] is not None

    # 回收站缩略图:软删行 thumbnail-url 照常 200(硬删后才 404)
    r = await client.get(f"/api/v1/assets/{aid}/thumbnail-url", headers=_h())
    assert r.status_code == 200, r.text
    assert "url" in r.json()

    # 恢复 → 回到普通列表、回收站清空
    r = await client.post(f"/api/v1/assets/{aid}/restore", headers=_h())
    assert r.status_code == 204, r.text
    r = await client.get(f"/api/v1/assets?folder_id={fid}", headers=_h())
    assert r.status_code == 200 and len(r.json()) == 1
    r = await client.get(f"/api/v1/assets/trash?folder_id={fid}", headers=_h())
    assert r.status_code == 200 and len(r.json()) == 0

    # 未删文件不能直接 hard purge(两步制)
    r = await client.delete(f"/api/v1/assets/{aid}?hard=true", headers=_h())
    assert r.status_code == 409, r.text

    # 再软删 → hard purge → 行消失、回收站清空
    r = await client.delete(f"/api/v1/assets/{aid}", headers=_h())
    assert r.status_code == 204, r.text
    r = await client.delete(f"/api/v1/assets/{aid}?hard=true", headers=_h())
    assert r.status_code == 204, r.text
    assert not await _asset_exists(aid)
    # 行已删 → thumbnail-url 404
    r = await client.get(f"/api/v1/assets/{aid}/thumbnail-url", headers=_h())
    assert r.status_code == 404
    r = await client.get(f"/api/v1/assets/trash?folder_id={fid}", headers=_h())
    assert r.status_code == 200 and len(r.json()) == 0

    # 清理 folder
    r = await client.delete(f"/api/v1/folders/{fid}", headers=_h())
    assert r.status_code == 204, r.text


@pytest.mark.asyncio
async def test_folder_delete_blocked_until_trash_emptied(client: AsyncClient) -> None:
    """回收站非空 → 删夹 409;回收站彻底清空(hard purge)后 → 204。"""
    uniq = uuid.uuid4().hex[:8]
    r = await client.post("/api/v1/folders", json={
        "project_id": PROJECT_EVENT, "name": f"zz_purge_folder_{uniq}",
    }, headers=_h())
    assert r.status_code == 201, r.text
    fid = r.json()["id"]
    aid = await _insert_asset(fid, f"zz_purge_{uniq}.txt", deleted=True)

    # 软删行占位 → 阻断,报错指向回收站
    r = await client.delete(f"/api/v1/folders/{fid}", headers=_h())
    assert r.status_code == 409, r.text
    assert "回收站" in r.json()["detail"]

    # 清空回收站(彻底删除)→ 放行
    r = await client.delete(f"/api/v1/assets/{aid}?hard=true", headers=_h())
    assert r.status_code == 204, r.text
    r = await client.delete(f"/api/v1/folders/{fid}", headers=_h())
    assert r.status_code == 204, r.text
    assert not await _asset_exists(aid)


@pytest.mark.asyncio
async def test_folder_delete_still_blocked_by_live_assets(client: AsyncClient) -> None:
    """活跃文件阻断删夹(409);软删后仍阻断(回收站非空),两档报错文案不同。"""
    uniq = uuid.uuid4().hex[:8]
    r = await client.post("/api/v1/folders", json={
        "project_id": PROJECT_EVENT, "name": f"zz_live_block_{uniq}",
    }, headers=_h())
    assert r.status_code == 201, r.text
    fid = r.json()["id"]
    aid = await _insert_asset(fid, f"zz_live_{uniq}.txt")

    # 活跃文件 → 不为空
    r = await client.delete(f"/api/v1/folders/{fid}", headers=_h())
    assert r.status_code == 409, r.text
    assert "不为空" in r.json()["detail"]

    # 软删 → 回收站非空,仍阻断
    r = await client.delete(f"/api/v1/assets/{aid}", headers=_h())
    assert r.status_code == 204, r.text
    r = await client.delete(f"/api/v1/folders/{fid}", headers=_h())
    assert r.status_code == 409, r.text
    assert "回收站" in r.json()["detail"]

    # 清空回收站 → 放行
    r = await client.delete(f"/api/v1/assets/{aid}?hard=true", headers=_h())
    assert r.status_code == 204, r.text
    r = await client.delete(f"/api/v1/folders/{fid}", headers=_h())
    assert r.status_code == 204, r.text
