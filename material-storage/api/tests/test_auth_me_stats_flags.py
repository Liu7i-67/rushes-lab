"""/me 统计三 flag 回显测试 — GET /api/v1/auth/me(包 C,2026-11-06 统计面板方案)。

唯一需求依据:docs/qdev/2026-11-06-stats-panel-upload-stats.md §3.2 / §7 末条
(/me 三字段:admin true / 持权组员 true / 无关用户 false / FGA 抖动 False)。

口径(§3.2,写死不许漂移 —— 与同名 require_* 完全一致,合取判定为 deps.py 层
单一 helper,/me 与 get_is_* 共用):
  is_stats_viewer        = is_org_admin ∨ check(organization#stats_viewer)
  is_usage_stats_viewer  = is_org_admin ∨ (stats_viewer ∧ usage_stats_viewer)
  is_upload_stats_viewer = is_org_admin ∨ (stats_viewer ∧ upload_stats_viewer)
「仅子开父关」不一致 tuple 下 /me 必须回 False —— 否则前端显卡片而 API 403
(§3.2 加合取的动机);非 admin 才补查;FGA 异常 try/except 回 False,不致
/me 500(auth.py 现状惯例)。

前置(同 test_group_file_deleter.py):
  1. seed_demo_data.py 已跑过(Evan = 真 user + org admin;outsider = fake 零权限)
  2. OpenFGA store / model 已 push(**含 stats_viewer / usage_stats_viewer /
     upload_stats_viewer 三条新 relation**,照 api/scripts/openfga_write_model.sh
     先推 model 再上代码,否则 check 撞未知 relation,组开关用例必挂)
  3. env=dev(允许 X-User-Id header 模拟身份)

文件去向说明:grep 全仓无独立 /me flag 测试文件(既有 /me 断言散在各功能域
文件,如 test_group_file_deleter.py T7/T8 的 is_file_deleter),按任务白名单
新建本文件;清理惯例:组在 finally 删,用户无删除 API 靠唯一 marker 圈定。
"""
from __future__ import annotations

import uuid

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import create_app

# seed 写死的真 user / fake outsider(同 test_directory.py)
EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"
OUTSIDER_ID = "00000000-0000-0000-0000-0000000000aa"
ME_URL = "/api/v1/auth/me"
FLAGS = ("is_stats_viewer", "is_usage_stats_viewer", "is_upload_stats_viewer")


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


def _h(user_id: str) -> dict[str, str]:
    return {"X-User-Id": user_id}


def _uniq(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:8]}"


async def _create_user(client: AsyncClient, prefix: str) -> str:
    r = await client.post(
        "/api/v1/admin/directory/users",
        json={"username": _uniq(prefix), "name": f"MEF {prefix}"},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text
    return r.json()["id"]


async def _flag_group(
    client: AsyncClient, *, stats: bool, usage: bool, upload: bool,
) -> str:
    """POST 创建即置位三 flag(§3.3 GroupCreateIn 全量形态)→ gid。"""
    r = await client.post("/api/v1/admin/directory/groups", json={
        "name": _uniq("mef_grp"), "description": "/me 统计 flag 测试组",
        "can_view_stats": stats, "can_view_usage_stats": usage,
        "can_view_upload_stats": upload,
    }, headers=_h(EVAN_ID))
    assert r.status_code == 201, r.text
    return r.json()["id"]


async def _add_member(client: AsyncClient, gid: str, uid: str) -> None:
    r = await client.post(
        f"/api/v1/admin/directory/groups/{gid}/members",
        json={"user_id": uid}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 201, r.text


async def _delete_group(client: AsyncClient, gid: str) -> None:
    r = await client.delete(f"/api/v1/admin/directory/groups/{gid}", headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text


# ─── admin true / 无关用户 false ─────────────────────────────────────────────
async def test_me_stats_flags_admin_true_and_unrelated_false(client: AsyncClient) -> None:
    """系统 admin(EVAN = organization#admin)三字段恒 true(§3.2 口径第一支直通,
    不依赖任何组 tuple);无组普通用户与零权限 outsider 三字段 false。"""
    me_admin = (await client.get(ME_URL, headers=_h(EVAN_ID))).json()
    for f in FLAGS:
        assert me_admin[f] is True, f"admin 的 {f} 应恒 true: {me_admin}"

    plain = await _create_user(client, "plain")
    me_plain = (await client.get(ME_URL, headers=_h(plain))).json()
    for f in FLAGS:
        assert me_plain[f] is False, f"无组用户 {f} 应 false: {me_plain}"

    me_out = (await client.get(ME_URL, headers=_h(OUTSIDER_ID))).json()
    for f in FLAGS:
        assert me_out[f] is False, f"outsider {f} 应 false: {me_out}"


# ─── 持权组员真值表(合取口径,防「子开父关」误报 true)────────────────────────
async def test_me_stats_flags_member_truth_table(client: AsyncClient) -> None:
    """组 flag 组合 → /me 三字段(§3.2 合取口径逐格钉死):
    - 仅父:is_stats_viewer true、两子 false(父只控入口,不单独授子模块);
    - 父∧子(upload):is_upload_stats_viewer true、另一子 false;
    - 父∧子(usage):is_usage_stats_viewer true、另一子 false;
    - **仅子无父**:三字段全 false(合取防不一致 tuple 的 /me 可观测面 —— 若
      实现漏合取只 check 子 relation,此格挂红)。"""
    cases = [  # ((stats, usage, upload), 期望三字段)
        ((True, False, False),
         {"is_stats_viewer": True, "is_usage_stats_viewer": False,
          "is_upload_stats_viewer": False}),
        ((True, False, True),
         {"is_stats_viewer": True, "is_usage_stats_viewer": False,
          "is_upload_stats_viewer": True}),
        ((True, True, False),
         {"is_stats_viewer": True, "is_usage_stats_viewer": True,
          "is_upload_stats_viewer": False}),
        ((False, False, True),  # 仅子无父 → 全 false(合取)
         {"is_stats_viewer": False, "is_usage_stats_viewer": False,
          "is_upload_stats_viewer": False}),
    ]
    for (stats, usage, upload), expect in cases:
        gid = await _flag_group(client, stats=stats, usage=usage, upload=upload)
        uid = await _create_user(client, "member")
        try:
            await _add_member(client, gid, uid)
            r = await client.get(ME_URL, headers=_h(uid))
            assert r.status_code == 200, r.text
            got = {f: r.json()[f] for f in FLAGS}
            assert got == expect, f"组 flag={(stats, usage, upload)}: {got} != {expect}"
        finally:
            await _delete_group(client, gid)


# ─── FGA 抖动 → False 且不 500 ───────────────────────────────────────────────
async def test_me_stats_flags_fga_jitter_returns_false(
    client: AsyncClient, app_with_lifespan, monkeypatch,
) -> None:
    """FGA 异常(model 未 push / 抖动)→ /me 仍 200,三字段一律 False(§3.2:
    FGA 异常回 False 现状惯例)。patch PermissionsService.check 原语 —— is_org_*
    半边与 deps 合取 helper 全部经由它,对实现形状(内联 / helper)无关;
    is_org_admin 同样经 check → admin 判定一并走 except 分支,恰覆盖非 admin
    补查路径的容错。"""
    gid = await _flag_group(client, stats=True, usage=False, upload=True)
    uid = await _create_user(client, "jitter")
    await _add_member(client, gid, uid)
    perms = app_with_lifespan.state.permissions

    async def _boom(**_kwargs):  # 形状无关(调用方全 kwargs)
        raise RuntimeError("fga jitter(模拟 model 未 push / 服务抖动)")

    monkeypatch.setattr(perms, "check", _boom)
    try:
        r = await client.get(ME_URL, headers=_h(uid))
        assert r.status_code == 200, f"FGA 抖动不得致 /me 500: {r.status_code} {r.text}"
        for f in FLAGS:
            assert r.json()[f] is False, f"FGA 抖动时 {f} 应回 False: {r.json()}"
    finally:
        monkeypatch.undo()  # 先恢复 FGA,再清理组(删组要写 tuple)
        await _delete_group(client, gid)
