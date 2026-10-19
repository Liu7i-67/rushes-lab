"""任务C 边界补充测试(仅容器内跑,不动仓库)。

覆盖面:
  C1 PATCH 目录 no-op(同值)不写审计
  C2 PATCH 同请求合并 name+parent / 显式同值 parent + 改名 → 审计事件形态
  C3 reparent 后子树资产权限随新位置 FGA 图推导实际生效(非 admin 视角, 私有项目)
  C4 batch-move 后原夹/新夹 subtree_file_count 变化
  C5 create_upload 同名 409 与软删恢复交互
  C6 audit 用户列表 login_locked 与真实 Redis 状态一致性(三形态)
  C7 batch-move 重复 asset_ids 去重对账
  C8 unlock 对 name 形态共享 key 的副作用(同名显示名用户)
  C9 改名不动 parent tuple(FGA 原子交换只应出现在移动)
"""
from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import Any

import pytest
from httpx import ASGITransport, AsyncClient
from redis.asyncio import from_url

from app.db.session import get_sessionmaker
from app.db.tables import Asset, AuditEvent, Folder
from app.main import create_app
from app.services.local_auth import (
    _FAIL_IP_KEY,
    _LOCK_IP_KEY,
    _LOCK_USER_KEY,
    LocalAuthService,
)
from app.settings import Settings, get_settings

EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"
OUTSIDER_ID = "00000000-0000-0000-0000-0000000000aa"
PROJECT_EVENT = "11111111-1111-1111-1111-111111111103"  # public
PROJECT_WEDDING = "11111111-1111-1111-1111-111111111101"  # private
PASS_OK = "passw0rd"
PASS_WRONG = "wrong1x"
ASGI_IPS = ("127.0.0.1", "testclient")


def _h(uid: str = EVAN_ID) -> dict[str, str]:
    return {"X-User-Id": uid}


def _uniq(p: str) -> str:
    return f"bc_{p}_{uuid.uuid4().hex[:8]}"


@pytest.fixture(scope="session")
async def app_with_lifespan():
    app = create_app()
    async with app.router.lifespan_context(app):
        yield app


@pytest.fixture(scope="session")
async def client(app_with_lifespan):
    transport = ASGITransport(app=app_with_lifespan)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


@pytest.fixture(autouse=True)
async def _flush_auth_keys(client: AsyncClient):
    yield
    client.cookies.clear()
    try:
        redis = from_url(str(get_settings().redis_url), decode_responses=True)
        try:
            for pattern in ("auth:fail:*", "auth:lock:*"):
                async for key in redis.scan_iter(match=pattern):
                    await redis.delete(key)
        finally:
            await redis.aclose()
    except Exception:
        pass


async def _mkfolder(client: AsyncClient, name: str, *, project: str = PROJECT_EVENT,
                    parent: str | None = None, sensitive: bool = False) -> dict:
    r = await client.post(
        "/api/v1/folders",
        json={"project_id": project, "name": name,
              "parent_folder_id": parent, "is_sensitive": sensitive},
        headers=_h(),
    )
    assert r.status_code == 201, r.text
    return r.json()


async def _insert_asset(folder_id: str, filename: str, *,
                        deleted: bool = False,
                        project: str = PROJECT_EVENT) -> uuid.UUID:
    async with get_sessionmaker()() as db:
        f = await db.get(Folder, uuid.UUID(folder_id))
        assert f is not None
        row = Asset(
            id=uuid.uuid4(), folder_id=f.id, filename=filename,
            minio_bucket="ms-dev",
            minio_key=f"{f.minio_prefix}{filename}",
            size_bytes=11, content_type="text/plain",
            uploader_id=uuid.UUID(EVAN_ID),
            deleted_at=datetime.now(UTC) if deleted else None,
        )
        db.add(row)
        await db.commit()
        return row.id


async def _purge(client: AsyncClient, asset_id: uuid.UUID) -> None:
    r = await client.delete(f"/api/v1/assets/{asset_id}", headers=_h())
    assert r.status_code in (204, 404), r.text
    r = await client.delete(f"/api/v1/assets/{asset_id}?hard=true", headers=_h())
    assert r.status_code in (204, 404), r.text


async def _audit_count(event_type: str, folder_id: str, since: datetime) -> int:
    async with get_sessionmaker()() as db:
        rows = list((await db.execute(
            AuditEvent.__table__.select().where(
                AuditEvent.event_type == event_type,
                AuditEvent.event_time >= since,
            ))).mappings())
    return sum(1 for r in rows
               if json_dumps_contains(r["details"], folder_id))


def json_dumps_contains(details: Any, needle: str) -> bool:
    import json
    return json.dumps(details or {}, ensure_ascii=False).find(needle) >= 0


async def _subtree_counts(client: AsyncClient, project: str) -> dict[str, int]:
    r = await client.get("/api/v1/folders", params={"project_id": project},
                         headers=_h())
    assert r.status_code == 200, r.text
    return {f["id"]: f["subtree_file_count"] for f in r.json()}


async def _cleanup_folders(client: AsyncClient, ids: list[str]) -> None:
    import warnings
    for fid in reversed(ids):
        r = await client.delete(f"/api/v1/folders/{fid}", headers=_h())
        if r.status_code != 204:
            warnings.warn(f"folder cleanup failed {fid}: {r.status_code} {r.text}",
                          stacklevel=2)


# ─── C1: PATCH no-op(同值)不写审计 ────────────────────────────────────────────
async def test_c1_patch_noop_same_value_no_audit(client: AsyncClient) -> None:
    f = await _mkfolder(client, _uniq("noop"))
    try:
        t0 = datetime.now(UTC)
        r = await client.patch(f"/api/v1/folders/{f['id']}",
                               json={"name": f["name"]}, headers=_h())
        assert r.status_code == 200, r.text
        r = await client.patch(f"/api/v1/folders/{f['id']}",
                               json={"parent_folder_id": None}, headers=_h())
        assert r.status_code == 200, r.text
        r = await client.patch(f"/api/v1/folders/{f['id']}",
                               json={"name": f["name"], "parent_folder_id": None},
                               headers=_h())
        assert r.status_code == 200, r.text
        assert await _audit_count("folder_renamed", f["id"], t0) == 0, \
            "no-op 改名不应写 folder_renamed 审计"
        assert await _audit_count("folder_moved", f["id"], t0) == 0, \
            "no-op 移动不应写 folder_moved 审计"
    finally:
        await _cleanup_folders(client, [f["id"]])


# ─── C2: 同请求合并 name+parent;显式同值 parent + 改名 ─────────────────────────
async def test_c2_patch_combined_name_and_parent(client: AsyncClient) -> None:
    s = await _mkfolder(client, _uniq("comb"))
    t = await _mkfolder(client, _uniq("tgt"))
    s2 = await _mkfolder(client, _uniq("samep"))
    try:
        new_name = _uniq("comb2")
        t0 = datetime.now(UTC)
        r = await client.patch(f"/api/v1/folders/{s['id']}",
                               json={"name": new_name,
                                     "parent_folder_id": t["id"]},
                               headers=_h())
        assert r.status_code == 200, r.text
        async with get_sessionmaker()() as db:
            row = await db.get(Folder, uuid.UUID(s["id"]))
            assert row is not None and row.name == new_name
            assert str(row.parent_folder_id) == t["id"]
            assert row.minio_prefix == f"{t['minio_prefix']}{new_name}/"
        renamed = await _audit_count("folder_renamed", s["id"], t0)
        moved = await _audit_count("folder_moved", s["id"], t0)
        assert renamed >= 1 and moved >= 1, (
            f"合并操作应记两类审计:renamed={renamed} moved={moved}")

        # 显式同值 parent + 改名 → 只有 renamed,无 moved
        t1 = datetime.now(UTC)
        r = await client.patch(f"/api/v1/folders/{s2['id']}",
                               json={"name": s2["name"],
                                     "parent_folder_id": None},
                               headers=_h())
        assert r.status_code == 200, r.text
        assert await _audit_count("folder_moved", s2["id"], t1) == 0, \
            "同值 parent 不算移动"
    finally:
        await _cleanup_folders(client, [t["id"], s["id"], s2["id"]])


# ─── C3: reparent 后子树资产权限随新位置 FGA 图推导(非 admin, 私有项目)────────
# MVP 规则(决策 10):带 explicit grant 的一级夹禁 reparent —— 故从「目标夹授权者
# 视角」验证图推导:目标夹 Y 有 uploader grant 的用户,移动后应经 folder:X parent
# folder:Y 图链获得 X 子树资产可见性;移回一级后收回(验证原子交换的删+写两侧)。
async def test_c3_reparent_subtree_permission_via_fga_graph(
    client: AsyncClient, app_with_lifespan,
) -> None:
    perms = app_with_lifespan.state.permissions
    x = await _mkfolder(client, _uniq("gx"), project=PROJECT_WEDDING)
    y = await _mkfolder(client, _uniq("gy"), project=PROJECT_WEDDING)
    aid = await _insert_asset(x["id"], "c3_perm.txt", project=PROJECT_WEDDING)
    await perms.bootstrap_asset(asset_id=str(aid), parent_type="folder",
                                parent_id=x["id"])
    r = await client.post(
        f"/api/v1/folders/{y['id']}/grants",
        json={"user_id": OUTSIDER_ID, "level": "uploader"}, headers=_h())
    assert r.status_code == 204, r.text
    try:
        # 前置:私有项目下 outsider 对 Y(有 grant)可见、对 X(无 grant)不可见
        r = await client.get("/api/v1/assets",
                             params={"folder_id": y["id"]}, headers=_h(OUTSIDER_ID))
        assert r.status_code == 200, r.text
        r = await client.get("/api/v1/assets",
                             params={"folder_id": x["id"]}, headers=_h(OUTSIDER_ID))
        assert r.status_code == 403, f"移动前 outsider 对 X 应 403:{r.text}"
        ok = await perms.check(user_subject=f"user:{OUTSIDER_ID}",
                               relation="can_view", object_type="asset",
                               object_id=str(aid))
        assert ok is False, "移动前 X 子树资产对 outsider 不可见"

        # 移动:X(无 grant,允许)挂到 Y 下
        r = await client.patch(f"/api/v1/folders/{x['id']}",
                               json={"parent_folder_id": y["id"]}, headers=_h())
        assert r.status_code == 200, r.text

        # parent tuple 已换形(X 不再挂 project,改挂 folder:Y)
        tuples = await perms.read_all_tuples(object_type="folder",
                                             object_id=x["id"], relation="parent")
        assert {u for u, _, _ in tuples} == {f"folder:{y['id']}"}, tuples

        # 关键断言:outsider 经 Y 的 grant + 图推导获得 X 子树资产可见性
        r = await client.get("/api/v1/assets",
                             params={"folder_id": x["id"]}, headers=_h(OUTSIDER_ID))
        assert r.status_code == 200, f"移动后应经图链可见:{r.text}"
        assert any(a["id"] == str(aid) for a in r.json()["items"]), r.text
        ok = await perms.check(user_subject=f"user:{OUTSIDER_ID}",
                               relation="can_view", object_type="asset",
                               object_id=str(aid))
        assert ok is True, "移动后资产 can_view 图推导应成立"

        # 反向:移回一级 → 旧 tuple 删掉,可见性收回(验证交换的删除侧真生效)
        r = await client.patch(f"/api/v1/folders/{x['id']}",
                               json={"parent_folder_id": None}, headers=_h())
        assert r.status_code == 200, r.text
        r = await client.get("/api/v1/assets",
                             params={"folder_id": x["id"]}, headers=_h(OUTSIDER_ID))
        assert r.status_code == 403, f"移回一级后可见性应收回:{r.text}"
        ok = await perms.check(user_subject=f"user:{OUTSIDER_ID}",
                               relation="can_view", object_type="asset",
                               object_id=str(aid))
        assert ok is False, "移回一级后资产 can_view 应回落 False"
    finally:
        import warnings
        r = await client.delete(
            f"/api/v1/folders/{y['id']}/grants",
            params={"subject": f"user:{OUTSIDER_ID}", "level": "uploader"},
            headers=_h())
        if r.status_code != 204:
            warnings.warn(f"grant revoke failed: {r.status_code} {r.text}",
                          stacklevel=2)
        await _purge(client, aid)
        await _cleanup_folders(client, [y["id"], x["id"]])


# ─── C4: batch-move 后两夹 subtree_file_count 变化 ─────────────────────────────
async def test_c4_batch_move_updates_subtree_counts(client: AsyncClient) -> None:
    src = await _mkfolder(client, _uniq("src"))
    tgt = await _mkfolder(client, _uniq("tgt"))
    a1 = await _insert_asset(src["id"], "c4_a.txt")
    a2 = await _insert_asset(src["id"], "c4_b.txt")
    a3 = await _insert_asset(src["id"], "c4_dead.txt", deleted=True)
    try:
        before = await _subtree_counts(client, PROJECT_EVENT)
        assert before[src["id"]] == 2, before
        assert before[tgt["id"]] == 0, before

        r = await client.post(
            "/api/v1/assets/batch-move",
            json={"asset_ids": [str(a1), str(a3)],
                  "target_folder_id": tgt["id"]},
            headers=_h())
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["moved_count"] == 1, body
        assert [e["reason"] for e in body["skipped"]] == ["deleted"], body

        after = await _subtree_counts(client, PROJECT_EVENT)
        assert after[src["id"]] == 1, f"原夹计数应 -1:{after}"
        assert after[tgt["id"]] == 1, f"新夹计数应 +1:{after}"
    finally:
        await _purge(client, a1)
        await _purge(client, a2)
        await _purge(client, a3)
        await _cleanup_folders(client, [src["id"], tgt["id"]])


# ─── C5: create_upload 同名 409 与软删恢复交互 ─────────────────────────────────
async def test_c5_create_upload_duplicate_vs_restore(client: AsyncClient) -> None:
    import boto3

    from app.settings import get_settings as gs
    s = gs()
    c = boto3.client("s3", endpoint_url=s.minio_endpoint_internal,
                     aws_access_key_id=s.minio_access_key,
                     aws_secret_access_key=s.minio_secret_key,
                     region_name="us-east-1")
    try:
        c.head_bucket(Bucket="ms-dev")
    except c.exceptions.ClientError:
        c.create_bucket(Bucket="ms-dev")

    f1 = await _mkfolder(client, _uniq("u1"))
    f2 = await _mkfolder(client, _uniq("u2"))
    a_dead = await _insert_asset(f1["id"], "c5_dup.txt", deleted=True)
    try:
        # ① 只有软删同名行 → 上传放行(查重排除软删),随即 abort
        r = await client.post("/api/v1/assets/uploads",
                              json={"folder_id": f1["id"], "filename": "c5_dup.txt",
                                    "size_bytes": 1}, headers=_h())
        assert r.status_code == 200, f"软删不应拦上传:{r.text}"
        r = await client.delete(
            f"/api/v1/assets/uploads/{r.json()['upload_id']}",
            params={"bucket": r.json()["bucket"], "key": r.json()["key"]},
            headers=_h())
        assert r.status_code == 204, r.text

        # ② 恢复软删行 → 活行出现 → 同夹同名上传 409
        r = await client.post(f"/api/v1/assets/{a_dead}/restore", headers=_h())
        assert r.status_code == 204, r.text
        r = await client.post("/api/v1/assets/uploads",
                              json={"folder_id": f1["id"], "filename": "c5_dup.txt",
                                    "size_bytes": 1}, headers=_h())
        assert r.status_code == 409, f"恢复后同夹同名应 409:{r.text}"

        # ③ 其他夹同名不受影响(查重 scope = folder)
        r = await client.post("/api/v1/assets/uploads",
                              json={"folder_id": f2["id"], "filename": "c5_dup.txt",
                                    "size_bytes": 1}, headers=_h())
        assert r.status_code == 200, r.text
        r = await client.delete(
            f"/api/v1/assets/uploads/{r.json()['upload_id']}",
            params={"bucket": r.json()["bucket"], "key": r.json()["key"]},
            headers=_h())
        assert r.status_code == 204, r.text
    finally:
        await _purge(client, a_dead)
        await _cleanup_folders(client, [f1["id"], f2["id"]])


# ─── C6: 列表 login_locked 与真实 Redis 状态一致性(三形态 MGET)─────────────────
async def test_c6_login_locked_consistent_with_redis(
    client: AsyncClient,
) -> None:
    from app.main import create_app as _ca  # noqa: F401  (保持 import 形态一致)
    svc = LocalAuthService.__new__(LocalAuthService)  # 只用 user_key_forms 静态方法
    uname = _uniq("lu")
    import uuid as _u

    from app.db.session import get_sessionmaker
    from app.db.tables import User
    uid = None
    redis = from_url(str(get_settings().redis_url), decode_responses=True)
    try:
        async with get_sessionmaker()() as db:
            u = User(feishu_open_id=f"ou_bc_{_u.uuid4().hex}",
                     name=f"BC Lock {uname}", username=uname,
                     email=f"{uname}@example.com", is_active=True,
                     must_change_password=False,
                     password_hash=None)
            db.add(u)
            await db.commit()
            uid = u.id
        # email 形态连错 5 次 → 锁落 email lower key(且 IP 也锁)
        for _ in range(5):
            r = await client.post("/api/v1/auth/local/login",
                                  json={"username": f"{uname}@example.com",
                                        "password": PASS_WRONG})
            assert r.status_code == 401, r.text
        lock_key = _LOCK_USER_KEY.format(username=f"{uname}@example.com")
        assert await redis.get(lock_key) is not None, "email 形态锁 key 应在位"

        r = await client.get("/api/v1/admin/directory/users",
                             params={"q": uname, "limit": 50}, headers=_h())
        items = r.json()["items"]
        assert items and items[0]["login_locked"] is True, r.text

        # 真实 Redis DEL 锁 key → 列表立即回落 False(一致性:镜像非缓存)
        await redis.delete(lock_key)
        r = await client.get("/api/v1/admin/directory/users",
                             params={"q": uname, "limit": 50}, headers=_h())
        assert r.json()["items"][0]["login_locked"] is False, r.text

        # name 形态落锁 → 列表同样能看见(MGET 三形态)
        name_form = f"bc lock {uname}"
        await redis.set(_LOCK_USER_KEY.format(username=name_form), "1", ex=300)
        r = await client.get("/api/v1/admin/directory/users",
                             params={"q": uname, "limit": 50}, headers=_h())
        assert r.json()["items"][0]["login_locked"] is True, \
            "name 形态锁应被列表 MGET 捕捉"
    finally:
        try:
            for form in (uname, f"{uname}@example.com", name_form):
                await redis.delete(_LOCK_USER_KEY.format(username=form),
                                   _LOCK_USER_KEY.format(username=form.lower()))
            for ip in ASGI_IPS:
                await redis.delete(_FAIL_IP_KEY.format(ip=ip),
                                   _LOCK_IP_KEY.format(ip=ip))
        except Exception:
            pass
        await redis.aclose()
        if uid is not None:
            async with get_sessionmaker()() as db:
                from sqlalchemy import delete as _del
                await db.execute(_del(User).where(User.id == uid))
                await db.commit()
    _ = svc


# ─── C7: batch-move 重复 asset_ids 去重对账 ────────────────────────────────────
async def test_c7_batch_move_duplicate_ids_dedup(client: AsyncClient) -> None:
    src = await _mkfolder(client, _uniq("src"))
    tgt = await _mkfolder(client, _uniq("tgt"))
    a = await _insert_asset(src["id"], "c7_a.txt")
    try:
        r = await client.post(
            "/api/v1/assets/batch-move",
            json={"asset_ids": [str(a), str(a)], "target_folder_id": tgt["id"]},
            headers=_h())
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["moved_count"] == 1, body
        assert body["skipped"] == [] and body["fga_pending"] == [], body
        total = body["moved_count"] + len(body["skipped"]) + len(body["fga_pending"])
        assert total == 1, f"去重后对账应 =1:{body}"
    finally:
        await _purge(client, a)
        await _cleanup_folders(client, [src["id"], tgt["id"]])


# ─── C8: unlock 对 name 形态共享 key 的副作用(同名显示名用户)───────────────────
async def test_c8_unlock_shared_display_name_key_side_effect(
    client: AsyncClient,
) -> None:
    from app.db.session import get_sessionmaker
    from app.db.tables import User
    tag = _uniq("shn")
    shared_name = f"BC Shared {tag}"
    ids: list[Any] = []
    redis = from_url(str(get_settings().redis_url), decode_responses=True)
    svc_hash = None
    try:
        async with get_sessionmaker()() as db:
            import asyncio
            hash_holder: dict[str, str] = {}

            class _NR:
                async def get(self, k): return None
                async def set(self, k, v, ex=None): pass
                async def delete(self, *k): pass
                async def incr(self, k): return 1
                async def expire(self, k, s): pass
                def pipeline(self):
                    class _P:
                        async def execute(self): return [1, 1, 1, 1]
                    return _P()
            from app.services.local_auth import LocalAuthService as _LACLS
            class _NR2:
                async def get(self, k): return None
                async def set(self, k, v, ex=None): pass
                async def delete(self, *k): pass
                async def incr(self, k): return 1
                async def expire(self, k, s): pass
                def pipeline(self):
                    class _P2:
                        async def execute(self): return [1, 1, 1, 1]
                    return _P2()
            _st = Settings(
                db_url="postgresql+asyncpg://u:p@localhost:5432/x",
                redis_url="redis://localhost:6379/0",
                minio_endpoint_internal="http://minio:9000",
                minio_endpoint_public="http://localhost:9000",
                minio_access_key="ak", minio_secret_key="sk",
                openfga_api_url="http://localhost:8080",
                openfga_store_id="store",
                web_app_base_url="http://localhost/ms-static/web/",
                session_jwt_secret="x" * 32,
            )
            las = _LACLS(_st, _NR2())
            hash_holder["h"] = las.hash_password(PASS_OK)
            for i in range(2):
                u = User(feishu_open_id=f"ou_bc_{uuid.uuid4().hex}",
                         name=shared_name, username=f"{tag}_u{i}",
                         email=f"{tag}_u{i}@example.com", is_active=True,
                         must_change_password=False,
                         password_hash=hash_holder["h"])
                db.add(u)
                ids.append(u)
            await db.commit()
            for u in ids:
                await db.refresh(u)
        uid_a, _uid_b = str(ids[0].id), str(ids[1].id)

        # 用共享 name 形态连错 5 次 → 共享 name key 上锁
        for _ in range(5):
            r = await client.post("/api/v1/auth/local/login",
                                  json={"username": shared_name,
                                        "password": PASS_WRONG})
            assert r.status_code == 401, r.text
        name_key = _LOCK_USER_KEY.format(username=shared_name.lower())
        assert await redis.get(name_key) is not None

        # 只解锁用户 A(同名)→ 共享 name key 一并被清,B 的锁随之消失(副作用)
        r = await client.post(f"/api/v1/admin/directory/users/{uid_a}/unlock",
                              headers=_h())
        assert r.status_code == 200, r.text
        body = r.json()
        assert shared_name.lower() in [f.lower() for f in
                                       body["cleared_user_forms"]], body
        assert await redis.get(name_key) is None, "共享 name key 应被 unlock 清掉"

        # 清掉 IP 维度后:B 未被显式 unlock 也能登录(user 维度锁已被 A 的 unlock 顺带清)
        for ip in ASGI_IPS:
            await redis.delete(_FAIL_IP_KEY.format(ip=ip),
                               _LOCK_IP_KEY.format(ip=ip))
        r = await client.post("/api/v1/auth/local/login",
                              json={"username": f"{tag}_u1",
                                    "password": PASS_OK})
        assert r.status_code == 200, \
            f"同名共享 key 副作用:B 应随 A 的解锁恢复登录:{r.text}"
        client.cookies.clear()
        _ = svc_hash, asyncio
    finally:
        try:
            for ip in ASGI_IPS:
                await redis.delete(_FAIL_IP_KEY.format(ip=ip),
                                   _LOCK_IP_KEY.format(ip=ip))
            await redis.delete(name_key)
            await redis.aclose()
        except Exception:
            pass
        if ids:
            async with get_sessionmaker()() as db:
                from sqlalchemy import delete as _del
                for u in ids:
                    await db.execute(_del(User).where(User.id == u.id))
                await db.commit()


# ─── C9: 改名不动 parent tuple ─────────────────────────────────────────────────
async def test_c9_rename_keeps_parent_tuple(
    client: AsyncClient, app_with_lifespan,
) -> None:
    perms = app_with_lifespan.state.permissions
    x = await _mkfolder(client, _uniq("rnt"))
    try:
        before = await perms.read_all_tuples(object_type="folder",
                                             object_id=x["id"], relation="parent")
        new_name = _uniq("rnt2")
        r = await client.patch(f"/api/v1/folders/{x['id']}",
                               json={"name": new_name}, headers=_h())
        assert r.status_code == 200, r.text
        after = await perms.read_all_tuples(object_type="folder",
                                            object_id=x["id"], relation="parent")
        assert {u for u, _, _ in before} == {u for u, _, _ in after} == {
            f"project:{PROJECT_EVENT}"}, (before, after)
    finally:
        await _cleanup_folders(client, [x["id"]])
