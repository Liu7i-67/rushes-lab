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

EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"        # 系统 admin(org admin)
BOB_ID = "00000000-0000-0000-0000-000000000002"        # 普通 member(非系统 admin;
# 注:alice 在 dev_bootstrap 里被设为 org admin,不能当"非系统 admin"用)
OUTSIDER_ID = "00000000-0000-0000-0000-0000000000aa"    # 无任何角色
PROJECT_EVENT = "11111111-1111-1111-1111-111111111103"  # public
PROJECT_WEDDING = "11111111-1111-1111-1111-111111111101"  # private
SENSITIVE_WEDDING = "2c0b99a0-e8a1-5775-9c18-6e29e7ae2fab"  # 家庭合影(VIP)


def _h(uid: str = EVAN_ID) -> dict[str, str]:
    return {"X-User-Id": uid}


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
    body = r.json()
    assert body["total"] == 1
    assert len(body["items"]) == 1 and body["items"][0]["id"] == str(aid)
    assert body["items"][0]["deleted_at"] is not None

    # 回收站缩略图:软删行 thumbnail-url 照常 200(硬删后才 404)
    r = await client.get(f"/api/v1/assets/{aid}/thumbnail-url", headers=_h())
    assert r.status_code == 200, r.text
    assert "url" in r.json()

    # 软删后原片不可再签下载链接(回收站语义;与 meta / live-preview / share 同口径)
    r = await client.post(f"/api/v1/assets/{aid}/download-link", headers=_h())
    assert r.status_code == 404, r.text

    # 恢复 → 回到普通列表、回收站清空;下载链接恢复可用
    r = await client.post(f"/api/v1/assets/{aid}/restore", headers=_h())
    assert r.status_code == 204, r.text
    r = await client.get(f"/api/v1/assets?folder_id={fid}", headers=_h())
    assert r.status_code == 200 and len(r.json()) == 1
    r = await client.get(f"/api/v1/assets/trash?folder_id={fid}", headers=_h())
    assert r.status_code == 200 and r.json()["total"] == 0
    r = await client.post(f"/api/v1/assets/{aid}/download-link", headers=_h())
    assert r.status_code == 200, r.text

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
    assert r.status_code == 200 and r.json()["total"] == 0

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

    # 软删行占位 → 阻断,报错指向回收站;文案不带计数(删夹门槛 can_upload
    # 低于回收站可见门槛 can_admin,数字会暴露给看不到回收站的 uploader)
    r = await client.delete(f"/api/v1/folders/{fid}", headers=_h())
    assert r.status_code == 409, r.text
    assert "回收站" in r.json()["detail"]
    assert not any(ch.isdigit() for ch in r.json()["detail"]), r.json()["detail"]

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


@pytest.mark.asyncio
async def test_sensitive_trash_visible_only_to_system_admin(client: AsyncClient) -> None:
    """sensitive folder 的回收站仅系统 admin 可见 —— 项目 admin 虽有 can_admin
    (可删/清文件)但不能借回收站窥探文件名/标签/备注(受邀制语义)。

    F1/F2 收口同步覆盖:敏感资产的 restore/hard purge 仅系统 admin;
    删夹 409 对敏感夹不带计数、不区分分支(防内容规模探测)。"""
    # bob 升为 wedding 项目 admin(非系统 admin;finally 撤销)
    r = await client.post(
        f"/api/v1/projects/{PROJECT_WEDDING}/members",
        json={"user_id": BOB_ID, "roles": ["admin"]},
        headers=_h(),
    )
    assert r.status_code == 204, r.text
    # 敏感夹里放一条软删资产(回收站非空,供 F1/F2 断言;测试尾部由系统 admin 清掉)
    sid = await _insert_asset(SENSITIVE_WEDDING, "zz_sensitive_ops.txt", deleted=True)

    # 零权限者对敏感资产只见通用 403 文案 —— sensitive 门在 can_admin 之后,
    # 不向探测者泄露"该资产是否敏感"的分类元数据
    r = await client.post(f"/api/v1/assets/{sid}/restore", headers=_h(OUTSIDER_ID))
    assert r.status_code == 403 and r.json()["detail"] == "no restore permission"
    r = await client.delete(f"/api/v1/assets/{sid}?hard=true", headers=_h(OUTSIDER_ID))
    assert r.status_code == 403 and r.json()["detail"] == "no delete permission"

    try:
        # 列表:项目 admin 403
        r = await client.get(
            f"/api/v1/assets/trash?folder_id={SENSITIVE_WEDDING}",
            headers=_h(BOB_ID),
        )
        assert r.status_code == 403, r.text

        # F1:restore / hard purge 仅系统 admin(项目 admin 继承 can_admin 但无 can_view)
        r = await client.post(f"/api/v1/assets/{sid}/restore", headers=_h(BOB_ID))
        assert r.status_code == 403, r.text
        r = await client.delete(f"/api/v1/assets/{sid}?hard=true", headers=_h(BOB_ID))
        assert r.status_code == 403, r.text

        # F2:删夹 409 报文不区分分支、不含数字(防敏感目录内容规模探测)
        r = await client.delete(f"/api/v1/folders/{SENSITIVE_WEDDING}", headers=_h(BOB_ID))
        assert r.status_code == 409, r.text
        detail = r.json()["detail"]
        assert not any(ch.isdigit() for ch in detail), detail
    finally:
        r = await client.delete(
            f"/api/v1/projects/{PROJECT_WEDDING}/members",
            params={"subject": f"user:{BOB_ID}", "role": "admin"},
            headers=_h(),
        )
        assert r.status_code == 204, r.text

    # 系统 admin:列表可见 / 可恢复 / 可再清掉(F1 反向 + 测试数据清理)
    r = await client.get(
        f"/api/v1/assets/trash?folder_id={SENSITIVE_WEDDING}", headers=_h(),
    )
    assert r.status_code == 200, r.text
    assert r.json()["total"] >= 1
    r = await client.post(f"/api/v1/assets/{sid}/restore", headers=_h())
    assert r.status_code == 204, r.text
    r = await client.delete(f"/api/v1/assets/{sid}", headers=_h())
    assert r.status_code == 204, r.text
    r = await client.delete(f"/api/v1/assets/{sid}?hard=true", headers=_h())
    assert r.status_code == 204, r.text
