"""文件上传数量统计端点(数据面)集成测试 — GET /api/v1/admin/stats/uploads(包 C)。

唯一需求依据:docs/qdev/2026-11-06-stats-panel-upload-stats.md
§7.1 分类矩阵 / §7.2 软删与项目活性 / §7.3 窗口与归一 / §7.4 项目过滤
+ §4.1 契约 / §4.2 时间归一 / §4.3 分类判定 / §4.4 SQL 与桶互斥。
权限矩阵 / 零泄露与死角 / 聚合自洽 / 非 admin 静默丢弃在
tests/test_upload_stats_perms.py(同域拆分,两文件合计覆盖 §7 全部);
存量 test_usage_stats.py 的断言在守门放宽后逐字仍成立,按文档 §7 前置说明**不改动**。

⚠️ **跑前须把含 stats_viewer / usage_stats_viewer / upload_stats_viewer 三条新
relation 的 model 重推到测试 store**(api/scripts/openfga_write_model.sh;ms-api
重启自动用 latest,照 test_group_file_deleter.py:12-14 同款 ⚠️)—— 未重推时新
守门撞未知 relation,相关用例必挂。

契约要点(实现由并行包 A 交付,冲突以需求文档为准):
  - GET /api/v1/admin/stats/uploads?project_ids=<uuid 逗号串>&date_from&date_to,
    守门 require_upload_stats_viewer(is_org_admin ∨ (stats_viewer ∧
    upload_stats_viewer),系统 admin 直通);project_ids 单参数逗号串,
    **空串 = 缺省全部**(§4.1);单次上限 200(超限 422);非法 UUID 422;
    不可见/归档/软删/未知 id **静默丢弃**(不 403 防探测,§4.4)
  - date_from/date_to 日粒度必填;后端固定 +08:00 归一半开区间
    [from 00:00+08, to+1d 00:00+08)(§4.2);from>to / 纯日期差>365 天 /
    date_to+1d 溢出(9999-12-31 的 OverflowError 守卫)→ 422
  - 分类单条 CASE,优先级 livp > 口播视频(视频 ∧ filename/minio_key 含
    「口播视频」)> 生活视频 > 图片;livp/图片并入生活图文;.ts/.svg 在夹具
    content_type 为空或 octet-stream 时落「其他」(VIDEO_EXTS/IMAGE_EXTS 刻意
    不含,thumb_exts 单一事实来源,§4.3);桶互斥 → total == 四桶和 == count(*)
  - 计数面:deleted_at IS NULL ∧ 项目活性(is_archived=false ∧ 项目 deleted_at
    IS NULL,admin 分支同样适用不放宽)∧ created_at 窗口;软删恢复后重计(D6)

前置(同 test_usage_stats.py / test_group_file_deleter.py):
  1. seed_demo_data.py 已跑过(Evan = 真 user + org admin/system admin)
  2. OpenFGA store / model 已 push(**含三条新 relation**,见上 ⚠️)
  3. env=dev(允许 X-User-Id header 模拟身份)

造数与隔离:asset 一律 DB 直插(presign PUT 容器内不通,test_usage_stats share
回归同先例),精确控制 content_type / created_at / deleted_at / minio_key(uq
(bucket,key,version) 靠 uuid 片段);**created_at 全部落固定历史日期**(本库其余
资产 created_at≈测试时刻,天然隔离),计数断言只打自建 private 项目行 → 存量
资产零污染。统计计数面走 folder 级 can_view(admin 直通),不触 asset#can_view
→ 直插不补 parent tuple(与 test_group_file_deleter 的差异:那边组员软删走
asset#can_view,必须补);收尾 purge 资产 → 删夹 → 项目软删,容错 404(已删
视为成功)。
"""
from __future__ import annotations

import uuid
from datetime import date, datetime, time, timedelta, timezone

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import create_app

EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"  # seed:system admin(同既有测试)
URL = "/api/v1/admin/stats/uploads"
CN_TZ = timezone(timedelta(hours=8))  # 固定 +08:00(§4.2;同 test_usage_stats.py:33 先例)
D_IN = date(2026, 3, 11)  # 计数用固定历史日期(落入默认窗口 W_FROM~W_TO)
W_FROM, W_TO = "2026-03-10", "2026-03-12"


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


def _project_code() -> str:
    """项目 code 唯一(projects_code_key);pattern 限 ^[a-z0-9][a-z0-9\\-]*$。"""
    return f"ups-{uuid.uuid4().hex[:12]}"


def _dt(d: date, h: int = 0, m: int = 0, s: int = 0) -> datetime:
    """上海时区(固定 +08:00)墙上时刻 → tz-aware datetime(§4.2 归一口径)。"""
    return datetime.combine(d, time(h, m, s), tzinfo=CN_TZ)


def _q(f: str = W_FROM, t: str = W_TO, pids: str | list[str] | None = None) -> dict:
    """查询串构造:project_ids 单参数逗号串(§4.1 契约,勿用重复参数形态)。"""
    p: dict = {"date_from": f, "date_to": t}
    if pids is not None:
        p["project_ids"] = ",".join(pids) if isinstance(pids, list) else pids
    return p


def _row(body: dict, pid: str) -> dict | None:
    return next((r for r in body["rows"] if r["project_id"] == str(pid)), None)


async def _create_project(client: AsyncClient, *, name: str | None = None) -> dict:
    """EVAN 现建 private 项目(ProjectCreateIn 无 visibility 入参,恒 private)。"""
    r = await client.post("/api/v1/projects", json={
        "code": _project_code(), "name": name or _uniq("上传统计项目"),
        "minio_bucket": "ms-dev", "admin_user_id": EVAN_ID,
    }, headers=_h(EVAN_ID))
    assert r.status_code == 201, r.text
    return r.json()


async def _create_folder(client: AsyncClient, project_id: str, name: str) -> dict:
    r = await client.post("/api/v1/folders", json={
        "project_id": project_id, "name": name,
    }, headers=_h(EVAN_ID))
    assert r.status_code == 201, r.text
    return r.json()


async def _insert_asset(
    folder_id: str, filename: str, *, content_type: str | None = None,
    created_at: datetime | None = None, deleted_at: datetime | None = None,
    minio_key: str | None = None,
) -> uuid.UUID:
    """DB 直插 asset 行(模拟已上传);minio_key 默认拼 uuid 片段保唯一(uq 约束)。"""
    from app.db.session import get_sessionmaker
    from app.db.tables import Asset

    async with get_sessionmaker()() as db:
        row = Asset(
            id=uuid.uuid4(), folder_id=uuid.UUID(folder_id), filename=filename,
            minio_bucket="ms-dev",
            minio_key=minio_key or f"zz-upstat/{uuid.uuid4().hex}/{filename}",
            size_bytes=11, content_type=content_type,
            uploader_id=uuid.UUID(EVAN_ID),
            created_at=created_at, deleted_at=deleted_at, tags={},
        )
        db.add(row)
        await db.commit()
        return row.id


async def _cleanup(client: AsyncClient, *, aids=(), folder_ids=(), project_ids=()) -> None:
    """收尾:purge 资产 → 删夹 → 项目软删(已删 404 视为成功;软删项目可能挡子
    操作,资产/夹清理容错不 assert,不掩盖用例内断言)。"""
    for aid in aids:
        await client.delete(f"/api/v1/assets/{aid}", headers=_h(EVAN_ID))
        await client.delete(
            f"/api/v1/assets/{aid}", params={"hard": "true"}, headers=_h(EVAN_ID),
        )
    for fid in folder_ids:
        await client.delete(f"/api/v1/folders/{fid}", headers=_h(EVAN_ID))
    for pid in project_ids:
        await client.delete(f"/api/v1/projects/{pid}", headers=_h(EVAN_ID))


# ─── §7.1 分类矩阵(表驱动,样本独立插入同项目同窗口)+ 契约字段 + 桶互斥 ──────
async def test_classification_matrix_table_driven(client: AsyncClient) -> None:
    """表驱动(样本独立,照 test_usage_stats 惯例):
    - livp 置顶:.livp 即便 content_type=video/* 仍落生活图文(§4.4 CASE 首分支,
      与上传派发优先级 livp>image>video 同构),.livp+空 mime 同样生活图文;
    - 图片:jpg/heic 扩展名兜底(octet-stream)+ png mime;
    - 口播视频只作用于视频:filename 或 minio_key 路径段任一含「口播视频」即口播桶
      (双字段防御性冗余,§4.3);图片名含关键词仍生活图文;
    - 生活视频:mp4 / mov+octet-stream(扩展名兜底)/ mime video 无扩展名;
    - 其他:zip/mp3;**.ts 与 .svg 夹具 content_type 为空或 octet-stream** 落其他
      (§7.1 夹具前提:mime 是 video/* 的 .ts 会按 mime 落生活视频,口径才自洽);
    - 桶互斥(§4.4):content_type=image/png + .mp4 文件名的冲突资产恰落
      「生活视频」一桶 → total == 四桶和 == count(*)。
    顺带钉 §4.1 契约字段与 project_ids 单选交集。"""
    proj = await _create_project(client)
    folder = await _create_folder(client, proj["id"], _uniq("cls_f"))
    cases = [  # (说明, filename, content_type, 期望桶, minio_key 覆盖({u}=uuid 片段))
        ("jpg+octet-stream 扩展名兜底", "photo.jpg", "application/octet-stream", "life_images", None),
        ("heic+octet-stream 扩展名兜底", "IMG_0001.heic", "application/octet-stream", "life_images", None),
        ("png mime", "pic.png", "image/png", "life_images", None),
        ("livp+空 mime", "memo.livp", None, "life_images", None),
        ("livp 置顶:video/* mime 仍生活图文", "memo2.livp", "video/mp4", "life_images", None),
        ("口播视频:filename 含关键词", "口播视频_开场.mp4", "video/mp4", "voice_videos", None),
        ("口播视频:minio_key 路径段含关键词", "take3.mp4", "video/mp4", "voice_videos",
         "zz-upstat/口播视频/{u}/take3.mp4"),
        ("普通 mp4", "a.mp4", "video/mp4", "life_videos", None),
        ("mov+octet-stream 扩展名兜底", "b.mov", "application/octet-stream", "life_videos", None),
        ("mime video 无扩展名", "noext_clip", "video/quicktime", "life_videos", None),
        ("zip", "pack.zip", "application/zip", "others", None),
        ("mp3", "song.mp3", "audio/mpeg", "others", None),
        (".ts 无 mime(VIDEO_EXTS 刻意不含)", "clip.ts", None, "others", None),
        (".ts+octet-stream(非 video/* mime 才落其他)", "clip2.ts", "application/octet-stream", "others", None),
        (".svg+octet-stream(IMAGE_EXTS 刻意不含)", "icon.svg", "application/octet-stream", "others", None),
        ("图片名含关键词仍生活图文(关键词只作用于视频,§4.3)",
         "口播视频_封面.png", "image/png", "life_images", None),
        ("桶互斥:image/png + .mp4 名恰落一桶", "conflict.mp4", "image/png", "life_videos", None),
        ("无 mime 无扩展名", "README", None, "others", None),
    ]
    expect: dict[str, int] = {}
    aids: list[uuid.UUID] = []
    try:
        for _label, fname, ctype, bucket, key_override in cases:
            key = key_override.replace("{u}", uuid.uuid4().hex) if key_override else None
            aids.append(await _insert_asset(
                folder["id"], fname, content_type=ctype,
                created_at=_dt(D_IN, 12), minio_key=key,
            ))
            expect[bucket] = expect.get(bucket, 0) + 1
        r = await client.get(URL, params=_q(pids=[proj["id"]]), headers=_h(EVAN_ID))
        assert r.status_code == 200, r.text
        body = r.json()
        row = _row(body, proj["id"])
        assert row is not None, body
        got = {k: row[k] for k in ("life_images", "voice_videos", "life_videos", "others")}
        assert got == expect, (got, expect)
        # 桶互斥:total == 四桶和 == count(*)(四条独立布尔 FILTER 会双计冲突样本)
        assert row["total"] == sum(expect.values()) == len(cases), row
        # §4.1 契约:行/汇总键面固定
        assert set(row) == {"project_id", "project_code", "project_name", "life_images",
                            "voice_videos", "life_videos", "others", "total"}, set(row)
        assert set(body["summary"]) == {"life_images", "voice_videos", "life_videos",
                                        "others", "total"}, set(body["summary"])
        # project_ids 单选交集:rows 恰一行,summary == 该行逐列和
        assert [x["project_id"] for x in body["rows"]] == [str(proj["id"])], body["rows"]
        assert {k: body["summary"][k] for k in expect} == expect, body["summary"]
    finally:
        await _cleanup(client, aids=aids, folder_ids=[folder["id"]], project_ids=[proj["id"]])


# ─── §7.2 软删不计 / 恢复重计 + 项目活性(行不出现)───────────────────────────
async def test_soft_delete_restore_and_project_liveness(client: AsyncClient) -> None:
    """§7.2/D6:预置软删行(deleted_at 非空)不计;API 软删 → 计数归零(行保留
    零填充);restore → 重新计数。项目活性(D3):归档(is_archived,DB 直改,
    现无归档 API,test_default_template.py 先例)与软删项目(DELETE /projects)
    的资产 **admin 也不计、行不出现**(非零填充,liveness 过滤不因直通放宽)。"""
    proj = await _create_project(client)
    folder = await _create_folder(client, proj["id"], _uniq("soft_f"))
    a_live = await _insert_asset(folder["id"], "live.png", content_type="image/png",
                                 created_at=_dt(D_IN, 12))
    a_pre = await _insert_asset(folder["id"], "presoft.png", content_type="image/png",
                                created_at=_dt(D_IN, 12, 1),
                                deleted_at=datetime.now(CN_TZ))
    p_arch = await _create_project(client)
    f_arch = await _create_folder(client, p_arch["id"], _uniq("arch_f"))
    a_arch = await _insert_asset(f_arch["id"], "arch.png", content_type="image/png",
                                 created_at=_dt(D_IN, 12))
    p_del = await _create_project(client)
    f_del = await _create_folder(client, p_del["id"], _uniq("del_f"))
    a_del = await _insert_asset(f_del["id"], "del.png", content_type="image/png",
                                created_at=_dt(D_IN, 12))
    from sqlalchemy import update

    from app.db.session import get_sessionmaker
    from app.db.tables import Project

    try:
        r = await client.get(URL, params=_q(pids=[proj["id"]]), headers=_h(EVAN_ID))
        assert r.status_code == 200, r.text
        row = _row(r.json(), proj["id"])
        assert row is not None and row["life_images"] == 1 and row["total"] == 1, row

        # API 软删 → 0(行仍在,零填充);restore → 重计 1
        rs = await client.delete(f"/api/v1/assets/{a_live}", headers=_h(EVAN_ID))
        assert rs.status_code == 204, rs.text
        r2 = await client.get(URL, params=_q(pids=[proj["id"]]), headers=_h(EVAN_ID))
        row2 = _row(r2.json(), proj["id"])
        assert row2 is not None and row2["total"] == 0, row2
        rr = await client.post(f"/api/v1/assets/{a_live}/restore", headers=_h(EVAN_ID))
        assert rr.status_code == 204, rr.text
        r3 = await client.get(URL, params=_q(pids=[proj["id"]]), headers=_h(EVAN_ID))
        row3 = _row(r3.json(), proj["id"])
        assert row3 is not None and row3["life_images"] == 1 and row3["total"] == 1, row3

        # 项目活性:归档 + 软删 → 行不出现(admin 同口径);活跃项目行仍现(正控)
        async with get_sessionmaker()() as db:
            await db.execute(
                update(Project).where(Project.id == uuid.UUID(p_arch["id"]))
                .values(is_archived=True)
            )
            await db.commit()
        rd = await client.delete(f"/api/v1/projects/{p_del['id']}", headers=_h(EVAN_ID))
        assert rd.status_code == 200, rd.text
        r4 = await client.get(URL, params=_q(), headers=_h(EVAN_ID))
        assert r4.status_code == 200, r4.text
        body4 = r4.json()
        assert _row(body4, p_arch["id"]) is None, "归档项目行必须不出现"
        assert _row(body4, p_del["id"]) is None, "软删项目行必须不出现"
        assert _row(body4, proj["id"]) is not None, body4
    finally:
        await _cleanup(client, aids=[a_live, a_pre, a_arch, a_del],
                       folder_ids=[folder["id"], f_arch["id"], f_del["id"]],
                       project_ids=[proj["id"], p_arch["id"]])  # p_del 已软删


# ─── §7.3 上海时区日界(半开区间)─────────────────────────────────────────────
async def test_shanghai_day_boundary(client: AsyncClient) -> None:
    """§7.3/D5:后端按固定 +08:00 归一半开区间 [from 00:00+08, to+1d 00:00+08):
    2026-11-01 00:00:00+08 计入 date_from=2026-11-01;前一日 23:59:59+08 不计;
    结束日 23:59:59 计入;次日 00:00:00+08 不计(半开上界)。按 UTC 分桶或闭区间
    实现都会在此挂红。"""
    proj = await _create_project(client)
    folder = await _create_folder(client, proj["id"], _uniq("tz_f"))
    a_start = await _insert_asset(folder["id"], "d1.jpg", content_type="image/png",
                                  created_at=_dt(date(2026, 11, 1), 0, 0, 0))
    a_before = await _insert_asset(folder["id"], "d2.jpg", content_type="image/png",
                                   created_at=_dt(date(2026, 10, 31), 23, 59, 59))
    a_end = await _insert_asset(folder["id"], "d3.jpg", content_type="image/png",
                                created_at=_dt(date(2026, 11, 1), 23, 59, 59))
    a_after = await _insert_asset(folder["id"], "d4.jpg", content_type="image/png",
                                  created_at=_dt(date(2026, 11, 2), 0, 0, 0))
    try:
        r = await client.get(URL, params=_q(f="2026-11-01", t="2026-11-01",
                                            pids=[proj["id"]]), headers=_h(EVAN_ID))
        assert r.status_code == 200, r.text
        row = _row(r.json(), proj["id"])
        assert row is not None and row["life_images"] == 2 and row["total"] == 2, row
    finally:
        await _cleanup(client, aids=[a_start, a_before, a_end, a_after],
                       folder_ids=[folder["id"]], project_ids=[proj["id"]])


# ─── §7.3 参数校验 422 一族 + 边界正例 ────────────────────────────────────────
async def test_window_param_validation_422_and_boundary_200(client: AsyncClient) -> None:
    """§7.3:from>to / 日期差>365 / date_to=9999-12-31(combine 溢出守卫)/ 缺参 /
    非法 UUID / >200 个 id → 422;恰差 365 天(=366 自然日窗口,夹具勿取 9999
    年份)放行;恰 200 个 id 放行(未知 id 静默丢弃 → 交集空 rows==[],§4.4);
    空串 project_ids 视同缺省=全部 → 200。"""
    bad = [
        ({"date_from": "2026-03-12", "date_to": "2026-03-10"}, "from>to"),
        ({"date_from": "2025-12-30", "date_to": "2026-12-31"}, "纯差 366>365"),
        ({"date_from": "9999-01-01", "date_to": "9999-12-31"},
         "差 364≤365 但 date_to+1d 溢出 date.max(OverflowError 守卫)"),
        ({"date_to": "2026-03-12"}, "缺 date_from"),
        ({"date_from": "2026-03-10"}, "缺 date_to"),
        ({}, "双缺"),
        ({"date_from": "2026-03-10", "date_to": "2026-03-12",
          "project_ids": "not-a-uuid"}, "project_ids 非法 UUID"),
        ({"date_from": "2026-03-10", "date_to": "2026-03-12",
          "project_ids": f"{uuid.uuid4()},garbage"}, "混入非法 UUID 亦 422"),
        ({"date_from": "2026-03-10", "date_to": "2026-03-12",
          "project_ids": ",".join(str(uuid.uuid4()) for _ in range(201))}, "201>200 个"),
    ]
    for p, why in bad:
        r = await client.get(URL, params=p, headers=_h(EVAN_ID))
        assert r.status_code == 422, f"{why} 应 422: {r.status_code} {r.text}"

    # 边界正例 1:恰差 365 天(窗口 366 自然日,>365 才 422;§4.2 较 usage 紧一天)
    r365 = await client.get(URL, params={"date_from": "2025-12-31", "date_to": "2026-12-31"},
                            headers=_h(EVAN_ID))
    assert r365.status_code == 200, r365.text
    # 边界正例 2:恰 200 个(未知 id 静默丢弃,交集空 → rows==[];放行不 422)
    ids200 = [str(uuid.uuid4()) for _ in range(200)]
    r200 = await client.get(URL, params=_q(pids=ids200), headers=_h(EVAN_ID))
    assert r200.status_code == 200, r200.text
    assert r200.json()["rows"] == [], r200.json()
    # 空串 = 缺省全部(§4.1:strip 后为空 → None,防第三方调用踩 422)
    r_empty = await client.get(
        URL, params={"date_from": W_FROM, "date_to": W_TO, "project_ids": ""},
        headers=_h(EVAN_ID),
    )
    assert r_empty.status_code == 200, r_empty.text
    assert isinstance(r_empty.json()["rows"], list), r_empty.json()


# ─── §7.4 项目过滤(admin 视角:多选交集 / 未知 id 静默丢弃 / 缺省全部)─────────
async def test_project_ids_filter_and_silent_drop_admin(client: AsyncClient) -> None:
    """§7.4:多选只统计所选(未选项目即便有资产,行也不出现);未知 id 混入静默
    丢弃(不 403 防探测);缺省(无 project_ids)= 全部 in-scope(admin=全部活性
    项目,自建两项目行均现)。非 admin 的不可见/归档/软删静默丢弃在
    test_upload_stats_perms.py 补成员视角。"""
    p1 = await _create_project(client)
    f1 = await _create_folder(client, p1["id"], _uniq("flt_f1"))
    a1 = await _insert_asset(f1["id"], "f1.png", content_type="image/png",
                             created_at=_dt(D_IN, 12))
    a1b = await _insert_asset(f1["id"], "f1b.png", content_type="image/png",
                              created_at=_dt(D_IN, 12, 1))
    p2 = await _create_project(client)
    f2 = await _create_folder(client, p2["id"], _uniq("flt_f2"))
    a2 = await _insert_asset(f2["id"], "f2.png", content_type="image/png",
                             created_at=_dt(D_IN, 12))
    try:
        # 单选 p1:仅 p1 行,计数 2;p2 有资产但未选 → 行不出现
        r = await client.get(URL, params=_q(pids=[p1["id"]]), headers=_h(EVAN_ID))
        assert r.status_code == 200, r.text
        body = r.json()
        assert [x["project_id"] for x in body["rows"]] == [str(p1["id"])], body["rows"]
        assert _row(body, p1["id"])["total"] == 2, body
        # 混入未知 id:静默丢弃,结果与单选一致(不 403)
        r2 = await client.get(URL, params=_q(pids=[p1["id"], str(uuid.uuid4())]),
                              headers=_h(EVAN_ID))
        assert r2.status_code == 200, r2.text
        assert [x["project_id"] for x in r2.json()["rows"]] == [str(p1["id"])], r2.json()
        # 多选 p1+p2:两行均现
        r3 = await client.get(URL, params=_q(pids=[p1["id"], p2["id"]]), headers=_h(EVAN_ID))
        assert r3.status_code == 200, r3.text
        got_ids = {x["project_id"] for x in r3.json()["rows"]}
        assert got_ids == {str(p1["id"]), str(p2["id"])}, r3.json()
        # 缺省=全部 in-scope:两项目行均现(admin 宇宙含全部活性项目)
        r4 = await client.get(URL, params=_q(), headers=_h(EVAN_ID))
        assert r4.status_code == 200, r4.text
        ids4 = {x["project_id"] for x in r4.json()["rows"]}
        assert str(p1["id"]) in ids4 and str(p2["id"]) in ids4, r4.json()
    finally:
        await _cleanup(client, aids=[a1, a1b, a2], folder_ids=[f1["id"], f2["id"]],
                       project_ids=[p1["id"], p2["id"]])
