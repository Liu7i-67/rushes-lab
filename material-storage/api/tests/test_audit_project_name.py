"""W2b 审计项目名补全 — 集成测试(容器内跑,面向契约)。

唯一需求依据:`docs/qdev/2026-10-17-six-optimizations.md` §3.3(W2b 审计项目名)+
§5(测试功能点 W2b 行);上游方案
`rushes-spec/material-storage/admin-audit-folder-mobile-optimization-plan.md` §3
(根因三层/实施方案/验收标准)。写法仿 tests/test_admin_baidu_tasks.py(httpx
ASGITransport + Evan=系统 admin、env=dev 走 X-User-Id)+ test_trash_and_purge.py
(资产 DB 直插,MinIO purge best-effort 不需要真实对象)。

契约要点(后端包2并行开发中,冲突以需求文档 §3.3 为准):
  - GET /api/v1/admin/audit 的 AuditOut 增 `target_asset_filename: str|null`、
    `target_project_name: str|null`(页内 target_asset_id 集合一次批量反查,
    purge 后回 null 不报错)
  - GET /api/v1/admin/audit/export.csv 同口径补名
  - 写入面补全 target_project_id(§3.1 清单全量):本文件覆盖
    download_denied / signed_url_issued(下载)/ asset_deleted / asset_restored /
    asset_purged / share_link_accessed(folder 形态)/ approval_submitted;
    project_id 过滤(后端既有参数)命中新写入事件
  - 不加新 event_type

前置(同 test_trash_and_purge.py):seed_demo_data.py 已跑过
(Evan = 系统 admin;outsider = 零权限契约账号;PROJECT_EVENT public 项目,
minio_bucket=ms-dev);OpenFGA store/model 已 push;env=dev。

数据:module 级建 1 个普通夹 + 4 条直插资产(alpha 供下载/审批事件、beta 供
删/恢复、gamma 供 purge、delta 供 CSV),teardown 彻底清除 + 删夹。
"""
from __future__ import annotations

import contextlib
import csv
import io
import uuid
from datetime import UTC, datetime
from typing import Any

import pytest
from httpx import ASGITransport, AsyncClient

from app.db.session import get_sessionmaker
from app.db.tables import Asset, Folder, Project
from app.main import create_app

EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"        # 系统 admin(seed 契约账号)
OUTSIDER_ID = "00000000-0000-0000-0000-0000000000aa"    # 零权限(seed 契约账号)
PROJECT_EVENT = "11111111-1111-1111-1111-111111111103"  # public,bucket=ms-dev

AUDIT_URL = "/api/v1/admin/audit"
CSV_URL = "/api/v1/admin/audit/export.csv"


def _h(uid: str = EVAN_ID) -> dict[str, str]:
    return {"X-User-Id": uid}


def _uniq(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:8]}"


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


async def _insert_asset(folder_id: str, filename: str, *,
                        deleted: bool = False) -> uuid.UUID:
    """直插一条 asset 行(模拟已上传文件;deleted=True 模拟回收站行)。"""
    async with get_sessionmaker()() as db:
        row = Asset(
            id=uuid.uuid4(),
            folder_id=uuid.UUID(folder_id),
            filename=filename,
            minio_bucket="ms-dev",
            minio_key=f"zz-w2b/{filename}",
            size_bytes=11,
            content_type="text/plain",
            uploader_id=uuid.UUID(EVAN_ID),
            deleted_at=datetime.now(UTC) if deleted else None,
        )
        db.add(row)
        await db.commit()
        return row.id


async def _purge_if_exists(client: AsyncClient, asset_id: uuid.UUID) -> None:
    """清场:软删 + 彻底删除(MinIO 对象不存在,purge 内部 best-effort 吞掉)。"""
    r = await client.delete(f"/api/v1/assets/{asset_id}", headers=_h())
    assert r.status_code in (204, 404), r.text
    r = await client.delete(f"/api/v1/assets/{asset_id}?hard=true", headers=_h())
    assert r.status_code in (204, 404), r.text


@pytest.fixture(scope="module")
async def world(client: AsyncClient) -> Any:
    """module 级:1 夹 + 4 资产 + 项目名;teardown 清资产与夹。"""
    tag = uuid.uuid4().hex[:8]
    r = await client.post(
        "/api/v1/folders",
        json={"project_id": PROJECT_EVENT, "name": f"zz_w2b_{tag}"},
        headers=_h(),
    )
    assert r.status_code == 201, r.text
    folder = r.json()

    a_alpha = await _insert_asset(folder["id"], f"w2b_alpha_{tag}.txt")
    a_beta = await _insert_asset(folder["id"], f"w2b_beta_{tag}.txt")
    a_gamma = await _insert_asset(folder["id"], f"w2b_gamma_{tag}.txt")
    a_delta = await _insert_asset(folder["id"], f"w2b_delta_{tag}.txt")

    async with get_sessionmaker()() as db:
        project = await db.get(Project, uuid.UUID(PROJECT_EVENT))
        assert project is not None
        project_name = project.name

    w: dict[str, Any] = {
        "tag": tag,
        "folder": folder,
        "alpha": a_alpha,
        "beta": a_beta,
        "gamma": a_gamma,
        "delta": a_delta,
        "project_name": project_name,
    }
    try:
        yield w
    finally:
        for aid in (a_alpha, a_beta, a_gamma, a_delta):
            with contextlib.suppress(AssertionError):
                # 清场尽力而为,不掩盖本体失败
                await _purge_if_exists(client, aid)
        r = await client.delete(f"/api/v1/folders/{folder['id']}", headers=_h())
        if r.status_code != 204:
            # 夹内仍有软删行(前面 purge 失败)→ 兜底直接 DB 清(仅测试自建数据)
            async with get_sessionmaker()() as db:
                await db.execute(
                    Asset.__table__.delete().where(
                        Asset.folder_id == uuid.UUID(folder["id"])))
                await db.execute(
                    Folder.__table__.delete().where(
                        Folder.id == uuid.UUID(folder["id"])))
                await db.commit()


async def _audit_list(client: AsyncClient, *, event_type: str,
                      t0: datetime, **params: Any) -> list[dict]:
    """admin audit 列表(from=t0 之后),返回 JSON 行列表。"""
    q: dict[str, Any] = {
        "event_type": event_type,
        "from": t0.isoformat(),
        "limit": 500,
    }
    q.update(params)
    r = await client.get(AUDIT_URL, params=q, headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    return r.json()


# ─── 列表补名:target_asset_filename / target_project_name ─────────────────────
@pytest.mark.asyncio
async def test_list_backfills_asset_filename_and_project_name(
    client: AsyncClient, world: dict,
) -> None:
    """有 asset 行时:列表行回 target_asset_filename(资产文件名)与
    target_project_name(所属项目名)—— LEFT JOIN/差集回填口径,主查询无 JOIN
    属实现细节,行为断言为准。"""
    t0 = datetime.now(UTC)
    # EVAN(系统 admin 直通)给 alpha 签下载链接 → signed_url_issued 事件
    r = await client.post(f"/api/v1/assets/{world['alpha']}/download-link",
                          headers=_h())
    assert r.status_code == 200, r.text

    rows = await _audit_list(client, event_type="signed_url_issued", t0=t0)
    mine = [e for e in rows if e["target_asset_id"] == str(world["alpha"])]
    assert mine, f"应能按 target_asset_id 命中刚触发的 signed_url_issued:{rows[:3]}"
    row = mine[-1]
    # 契约:AuditOut 增两个补名字段(有 asset 行时非 null)
    assert "target_asset_filename" in row and "target_project_name" in row, row
    assert row["target_asset_filename"] == f"w2b_alpha_{world['tag']}.txt", row
    assert row["target_project_name"] == world["project_name"], row


# ─── 写入面补全:新事件带 target_project_id(§3.3 验收:全量对账口径,此处覆盖
#     下载拒/签发/软删/恢复/分享 folder 形态/审批/purge 七个代表写入点)────────────
@pytest.mark.asyncio
async def test_new_events_carry_target_project_id(
    client: AsyncClient, world: dict,
) -> None:
    t0 = datetime.now(UTC)
    folder_id = world["folder"]["id"]

    # ① download_denied:零权限 outsider 请求下载 → 403 + 审计
    r = await client.post(f"/api/v1/assets/{world['alpha']}/download-link",
                          headers=_h(OUTSIDER_ID))
    assert r.status_code == 403, r.text

    # ② signed_url_issued:EVAN 签发成功
    r = await client.post(f"/api/v1/assets/{world['alpha']}/download-link",
                          headers=_h())
    assert r.status_code == 200, r.text

    # ③ asset_deleted + ④ asset_restored:软删再恢复
    r = await client.delete(f"/api/v1/assets/{world['beta']}", headers=_h())
    assert r.status_code == 204, r.text
    r = await client.post(f"/api/v1/assets/{world['beta']}/restore", headers=_h())
    assert r.status_code == 204, r.text

    # ⑤ share_link_accessed(folder 形态):建夹分享 + 访问短链
    r = await client.post(f"/api/v1/share/folders/{folder_id}", json={},
                          headers=_h())
    assert r.status_code == 200, r.text
    token = r.json()["token"]
    r = await client.get(f"/api/v1/share/{token}", headers=_h())
    assert r.status_code == 200, r.text
    assert r.json()["kind"] == "folder", r.text

    # ⑥ approval_submitted:outsider 对 alpha 发起下载申请
    r = await client.post(
        "/api/v1/approvals",
        json={"target_type": "asset", "target_id": str(world["alpha"]),
              "action": "download", "duration_seconds": 3600,
              "reason": "w2b 审计项目名集成测试申请"},
        headers=_h(OUTSIDER_ID),
    )
    assert r.status_code == 201, r.text

    pid = PROJECT_EVENT

    # download_denied / signed_url_issued / asset_deleted / asset_restored /
    # approval_submitted:按 target_asset_id 命中本测试触发的行
    for event_type, asset_id in (
        ("download_denied", world["alpha"]),
        ("signed_url_issued", world["alpha"]),
        ("asset_deleted", world["beta"]),
        ("asset_restored", world["beta"]),
        ("approval_submitted", world["alpha"]),
    ):
        rows = await _audit_list(client, event_type=event_type, t0=t0)
        mine = [e for e in rows if e.get("target_asset_id") == str(asset_id)]
        assert mine, f"{event_type} 应有本测试触发的行"
        assert all(e.get("target_project_id") == pid for e in mine), (
            f"{event_type} 应带 target_project_id:{mine[-1]}")

    # share_link_accessed(folder 形态):无 target_asset_id,按 details.folder_id 命中
    rows = await _audit_list(client, event_type="share_link_accessed", t0=t0)
    mine = [e for e in rows
            if (e.get("details") or {}).get("kind") == "folder"
            and (e.get("details") or {}).get("folder_id") == folder_id]
    assert mine, f"folder 形态 share_link_accessed 应有本测试触发的行:{rows[-3:]}"
    assert all(e.get("target_project_id") == pid for e in mine), (
        f"share_link_accessed(folder) 应带 target_project_id:{mine[-1]}")


# ─── project_id 过滤命中新写入事件 ──────────────────────────────────────────────
@pytest.mark.asyncio
async def test_project_filter_hits_new_events(
    client: AsyncClient, world: dict,
) -> None:
    """GET /admin/audit?project_id= 只回写入时带了 target_project_id 的行 ——
    本测试新触发的事件必须被命中(历史无值行按 null 容错,不过滤断言)。"""
    t0 = datetime.now(UTC)
    r = await client.delete(f"/api/v1/assets/{world['beta']}", headers=_h())
    assert r.status_code == 204, r.text
    r = await client.post(f"/api/v1/assets/{world['beta']}/restore", headers=_h())
    assert r.status_code == 204, r.text

    rows = await _audit_list(client, event_type="asset_restored", t0=t0,
                             project_id=PROJECT_EVENT)
    mine = {e["id"] for e in rows
            if e.get("target_asset_id") == str(world["beta"])}
    assert mine, "project_id 筛选应命中刚写入的 asset_restored 事件"
    assert all(e.get("target_project_id") == PROJECT_EVENT for e in rows), rows


# ─── CSV 导出同口径补名 ─────────────────────────────────────────────────────────
@pytest.mark.asyncio
async def test_csv_export_same_enrichment(
    client: AsyncClient, world: dict,
) -> None:
    """export.csv 与列表同口径:目标事件行内可见项目名与文件名(列名/列序由
    实现定,契约只钉「同口径补名」—— 按值断言,不锁表头拼写)。"""
    t0 = datetime.now(UTC)
    r = await client.delete(f"/api/v1/assets/{world['delta']}", headers=_h())
    assert r.status_code == 204, r.text

    r = await client.get(
        CSV_URL,
        params={"event_type": "asset_deleted", "from": t0.isoformat()},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    text = r.content.decode("utf-8-sig")
    rows = list(csv.reader(io.StringIO(text)))
    assert len(rows) >= 2, "CSV 应含表头 + 数据行"

    def _row_of(asset_id: str) -> list[str] | None:
        for cells in rows[1:]:
            if asset_id in cells:
                return cells
        return None

    cells = _row_of(str(world["delta"]))
    assert cells is not None, f"CSV 应含本测试触发的 asset_deleted 行:{rows[:3]}"
    joined = "\x00".join(cells)
    assert world["project_name"] in joined, (
        f"CSV 行应补项目名:{cells}")
    assert f"w2b_delta_{world['tag']}.txt" in joined, f"CSV 行应补文件名:{cells}"


# ─── purge 后回落 null 不报错 + asset_purged 带项目 ─────────────────────────────
@pytest.mark.asyncio
async def test_purged_asset_rows_fall_back_to_null(
    client: AsyncClient, world: dict,
) -> None:
    """软删事件先落库(带 target_asset_id)→ 彻底删除后 asset 行消失,
    audit_events.target_asset_id FK SET NULL → 列表该行补名回落 null 且 200
    不报错(前端回落显示 key 的数据面基础)。asset_purged 行本身(无
    target_asset_id,FK 语义)应带 target_project_id。"""
    t0 = datetime.now(UTC)
    # 软删 → 捕获 asset_deleted 事件 id
    r = await client.delete(f"/api/v1/assets/{world['gamma']}", headers=_h())
    assert r.status_code == 204, r.text
    rows = await _audit_list(client, event_type="asset_deleted", t0=t0)
    mine = [e for e in rows if e.get("target_asset_id") == str(world["gamma"])]
    assert mine, "软删事件应先落库"
    event_id = mine[-1]["id"]
    # 软删事件此刻有补名(资产行还在)
    assert mine[-1]["target_asset_filename"] == f"w2b_gamma_{world['tag']}.txt"
    assert mine[-1]["target_project_name"] == world["project_name"]

    # 彻底删除 → 资产行消失,历史事件 target_asset_id 被 SET NULL
    r = await client.delete(
        f"/api/v1/assets/{world['gamma']}?hard=true", headers=_h())
    assert r.status_code == 204, r.text

    # 按 id 直取该事件:200、补名字段回落 null,不报错
    r = await client.get(
        AUDIT_URL, params={"event_type": "asset_deleted",
                           "from": t0.isoformat(), "limit": 500},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    row = next(e for e in r.json() if e["id"] == event_id)
    assert row["target_asset_id"] is None, row
    assert row["target_asset_filename"] is None, row
    assert row["target_project_name"] is None, row

    # asset_purged 事件:写审计前先取好的 target_project_id 在(purge 行无
    # target_asset_id,溯源靠 target_minio_key + details.asset_id)
    rows = await _audit_list(client, event_type="asset_purged", t0=t0)
    mine = [e for e in rows
            if (e.get("details") or {}).get("asset_id") == str(world["gamma"])]
    assert mine, "purge 应写 asset_purged 审计"
    assert mine[-1].get("target_project_id") == PROJECT_EVENT, mine[-1]
