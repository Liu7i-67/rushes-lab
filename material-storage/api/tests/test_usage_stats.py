"""客户端使用统计集成测试 — GET /api/v1/admin/usage/stats(feat/usage-analytics)。

唯一需求依据:docs/qdev/2026-10-27-usage-analytics.md(§2 口径/§4 契约/§6 测试功能点)
+ 方案文档 rushes-spec/material-storage/usage-analytics-plan.md(口径语义冲突时以方案为准)。
跑在容器内(PM 统一执行)。前置同 tests/test_boundary_ext.py:seed_demo_data 已跑
(Evan=system admin、bob=普通 member);env=dev(X-User-Id header 模拟身份)。覆盖 §6 全部 9 组。
造数:样本全部 **直插 audit_events 行**(绕过 audit.write)精确控制 UA/IP/actor/
event_type/event_time(含空 UA、'unknown' IP 哨兵、UA NULL worker 行);dedup_key 固定
前缀+随机 uuid,clean_usage_events fixture 开头残留清扫(usage_t_ 前缀活跃用户兜底
禁用,幂等)、finally 按前缀清理直插行并禁用临时用户(无删除 API)。样本 event_time
落 90~200 天前随机窄窗口,与 now() 行隔离可精确计数;分桶用例每样本行独立 actor
(同 actor 去重 users 恒 1)。空串 UA 直插历史行可达 unknown 兜底(方案 §3 规则 6 优先于初稿)。
"""
from __future__ import annotations

import random
import uuid
from collections import Counter
from datetime import UTC, datetime, timedelta, timezone

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete, select

from app.main import create_app

# seed 契约账号(同既有测试)
EVAN_ID = "3f1b659e-9ef1-4e65-aa03-4407ad7bcfc4"  # system admin
BOB_ID = "00000000-0000-0000-0000-000000000002"  # 普通 member

URL = "/api/v1/admin/usage/stats"
DEDUP_PREFIX = "usage_stats_test:"
SH = timezone(timedelta(hours=8))  # Asia/Shanghai(UTC+8,无夏令时)

_CHROME = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/126.0.0.0 Safari/537.36"
_IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) Mobile/15E148 Safari/604.1"
# Android 平板:含 Android、无 Mobile 标记(规则 4 → web_mobile)
_TABLET = "Mozilla/5.0 (Linux; Android 13; SM-X710) Chrome/126.0.0.0 Safari/537.36"


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


_TMP_USERS: list[str] = []  # _make_actors 建的临时用户(marker=usage_t_),收尾统一禁用


@pytest.fixture
async def clean_usage_events(client):
    """开头残留清扫(usage_t_ 前缀活跃用户兜底禁用);收尾删直插行+禁用临时用户。"""
    await _sweep_residual_users(client)
    _TMP_USERS.clear()
    try:
        yield
    finally:
        await _cleanup_inserted_events()
        await _disable_users(client, _TMP_USERS)


def _h(user_id: str) -> dict[str, str]:
    return {"X-User-Id": user_id}


def _iso(dt: datetime) -> str:
    return dt.isoformat()


async def _cleanup_inserted_events() -> None:
    from app.db.session import get_sessionmaker
    from app.db.tables import AuditEvent

    async with get_sessionmaker()() as db:
        await db.execute(
            delete(AuditEvent).where(AuditEvent.dedup_key.like(f"{DEDUP_PREFIX}%"))
        )
        await db.commit()


async def _seed_events(rows: list[dict]) -> tuple[datetime, datetime]:
    """直插 audit_events 行,返回覆盖窗口 [min-120s, max+120s]。行字段
    event_type(缺省 upload)/ ua / ip / actor(user id 串,可缺省 NULL)/
    t(可缺省;缺省落 90~200 天前随机窄窗口,与 now() 行隔离可精确计数)。"""
    from app.db.session import get_sessionmaker
    from app.db.tables import AuditEvent

    await _cleanup_inserted_events()  # 防上次运行崩溃残留
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
                actor_user_id=uuid.UUID(r["actor"]) if r.get("actor") else None,
                dedup_key=f"{DEDUP_PREFIX}{uuid.uuid4().hex}",
                request_ip=r.get("ip"), user_agent=r.get("ua"),
                details={}, event_time=r["t"],
            ))
        await db.commit()
    times = [r["t"] for r in rows]
    return min(times) - timedelta(seconds=120), max(times) + timedelta(seconds=120)


async def _make_actors(client: AsyncClient, n: int) -> list[str]:
    """建 n 个真实用户作独立样本 actor(FK 需真实用户;登记 _TMP_USERS 收尾统一禁用)。"""
    actors: list[str] = []
    for i in range(n):
        r = await client.post("/api/v1/admin/directory/users", json={
            "username": f"usage_t_{uuid.uuid4().hex[:10]}", "name": f"Usage 样本 {i}",
        }, headers=_h(EVAN_ID))
        assert r.status_code == 201, r.text
        actors.append(r.json()["id"])
    _TMP_USERS.extend(actors)
    return actors


async def _disable_users(client: AsyncClient, uids: list[str]) -> None:
    """逐个禁用临时用户(is_active=false),不留活跃账号污染目录。"""
    for uid in uids:
        rd = await client.post(f"/api/v1/admin/directory/users/{uid}/disable", headers=_h(EVAN_ID))
        assert rd.status_code in (200, 409), rd.text  # 409=重复禁用,幂等容忍


async def _sweep_residual_users(client: AsyncClient) -> None:
    """残留清扫:username 前缀 usage_t_ 的历史活跃用户一律禁用(硬中断遗留兜底,幂等)。"""
    r = await client.get("/api/v1/admin/directory/users", params={
        "q": "usage_t_", "is_active": True, "limit": 200}, headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    stale = [u["id"] for u in r.json()["items"] if u["username"].startswith("usage_t_")]
    await _disable_users(client, stale)


# ─── §6.1 platform 分桶(表驱动;CASE 规则序,方案 §3)─────────────────────────
async def test_platform_bucketing_table_driven(
    client: AsyncClient, clean_usage_events,
) -> None:
    ua_cases: list[tuple[str, str]] = [
        ("msapp/0.1.11 (android)", "android_app"),  # 规则1 msapp+android
        ("msapp/ (android)", "android_app"),  # 规则1 无版本
        ("msapp/0.1.11 (ios)", "ios_app"),  # 规则2
        ("msapp/0.2.0", "app_legacy"),  # 规则3 msapp 漏平台段
        ("msapp/bios", "app_legacy"),  # 规则3 子串陷阱:平台段须带括号(§6.1 新口径)
        ("Dart/3.5 (dart:io)", "app_legacy"),  # 规则3 Dart UA
        (_TABLET, "web_mobile"),  # 规则4 含 Android 无 Mobile 标记
        (_IPHONE, "web_mobile"),  # 规则4 iPhone
        (_CHROME, "web_desktop"),  # 规则5 桌面浏览器
        ("", "unknown"),  # 规则6 空串(直插历史行,方案 §3/§7)
    ]
    actors = await _make_actors(client, len(ua_cases))  # 每样本独立 actor → users 各 1
    lo, hi = await _seed_events([
        {"ua": ua, "ip": "10.1.1.9", "actor": a}
        for (ua, _), a in zip(ua_cases, actors, strict=True)
    ])
    r = await client.get(
        URL, params={"from": _iso(lo), "to": _iso(hi)}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    body = r.json()
    got = {x["platform"]: (x["users"], x["events"]) for x in body["by_platform"]}
    assert got == {k: (v, v) for k, v in Counter(p for _, p in ua_cases).items()}, got
    assert body["totals"] == {"users": len(ua_cases), "events": len(ua_cases)}, body["totals"]


# ─── §6.2 network 分桶(私网正则 ~* 边界 + 哨兵)──────────────────────────────
async def test_network_bucketing(client: AsyncClient, clean_usage_events) -> None:
    ip_cases: list[tuple[str | None, str]] = [
        ("172.15.0.1", "wan"),  # 172 段 16-31 之外
        ("172.32.0.1", "wan"),  # 32 越上界
        ("172.168.0.1", "wan"),  # 第三段不匹配
        ("172.20.0.7", "lan"),  # 172.16-31 命中
        ("10.1.2.3", "lan"),
        ("192.168.1.5", "lan"),
        ("127.0.0.1", "lan"),
        ("::1", "lan"),
        ("FD00::", "lan"),  # 大写 ULA(正则 ~* 大小写不敏感)
        ("fe80::1", "lan"),
        ("::ffff:10.1.2.3", "lan"),  # IPv4-mapped 私网(§6.2 新口径显式覆盖)
        ("::ffff:8.8.8.8", "wan"),  # IPv4-mapped 公网
        ("8.8.8.8", "wan"),  # 公网
        (None, "unknown"),  # NULL
        ("", "unknown"),  # 空串
        ("unknown", "unknown"),  # auth.py:293 哨兵
    ]
    actors = await _make_actors(client, len(ip_cases))  # 每样本独立 actor → users 各 1
    lo, hi = await _seed_events([
        {"ua": _CHROME, "ip": ip, "actor": a}
        for (ip, _), a in zip(ip_cases, actors, strict=True)
    ])
    r = await client.get(
        URL, params={"from": _iso(lo), "to": _iso(hi)}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    got = {x["network"]: (x["users"], x["events"]) for x in r.json()["by_network"]}
    assert got == {k: (v, v) for k, v in Counter(n for _, n in ip_cases).items()}, got


# ─── §6.3 时间参数四分支 + 三类 422 ──────────────────────────────────────────
async def test_time_param_rules(client: AsyncClient) -> None:
    now = datetime.now(UTC)
    # 分支1:双缺省 → 默认 30 天窗口(from/to 差值 ≈30 天)
    r = await client.get(URL, headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    b = r.json()
    span = datetime.fromisoformat(b["to"]) - datetime.fromisoformat(b["from"])
    assert timedelta(days=29.9) < span < timedelta(days=30.1), span
    # 分支2:仅 from → to=now
    frm = now - timedelta(days=3)
    r = await client.get(URL, params={"from": _iso(frm)}, headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    b = r.json()
    assert abs((datetime.fromisoformat(b["from"]) - frm).total_seconds()) < 5, b["from"]
    assert abs((datetime.fromisoformat(b["to"]) - now).total_seconds()) < 600, b["to"]
    # 分支3:仅 to → from=to-30d
    to = now - timedelta(days=40)
    r = await client.get(URL, params={"to": _iso(to)}, headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    b = r.json()
    assert abs((datetime.fromisoformat(b["to"]) - to).total_seconds()) < 5, b["to"]
    got_from = datetime.fromisoformat(b["from"])
    assert abs((got_from - (to - timedelta(days=30))).total_seconds()) < 5, b["from"]
    # 三类 422:乱序(from==to / from>to)、naive(不带时区)、窗口 >366 天
    for bad in (
        {"from": _iso(now), "to": _iso(now)},
        {"from": _iso(now), "to": _iso(now - timedelta(days=1))},
        {"from": "2026-10-01T00:00:00", "to": _iso(now)},
        {"from": _iso(now - timedelta(days=367, seconds=10)), "to": _iso(now)},
    ):
        r = await client.get(URL, params=bad, headers=_h(EVAN_ID))
        assert r.status_code == 422, f"{bad} 应 422: {r.status_code} {r.text}"
    # 边界:恰好 366 天 → 放行(契约「> 366 天」才 422)
    r = await client.get(
        URL, params={"from": _iso(now - timedelta(days=366)), "to": _iso(now)},
        headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text


# ─── §6.4 口径过滤(active_users vs logins)────────────────────────────────────
async def test_metric_filter_active_users_vs_logins(
    client: AsyncClient, clean_usage_events,
) -> None:
    lo, hi = await _seed_events([
        {"ua": _CHROME, "ip": "10.0.0.1", "actor": EVAN_ID},  # 计入
        {"ua": _CHROME, "ip": "10.0.0.1", "actor": BOB_ID},  # 计入
        {"ua": _CHROME, "ip": "10.0.0.1", "actor": EVAN_ID,
         "event_type": "local_login_success"},  # 两口径均计入
        {"ua": _CHROME, "ip": "10.0.0.1", "actor": EVAN_ID,
         "event_type": "local_login_failed"},  # 失败尝试不进 active_users
        {"ua": _CHROME, "ip": "10.0.0.1", "actor": EVAN_ID,
         "event_type": "local_login_locked"},  # 锁定不进 active_users
        {"ua": None, "ip": None, "actor": EVAN_ID,
         "event_type": "asset_purged"},  # worker(UA NULL)两口径均排除
        {"ua": _CHROME, "ip": "10.0.0.1", "actor": None},  # actor NULL 排除
        {"ua": None, "ip": None, "actor": EVAN_ID,
         "event_type": "local_login_success"},  # UA NULL 的登录也不进
    ])
    p = {"from": _iso(lo), "to": _iso(hi)}
    r = await client.get(URL, params=p, headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    b = r.json()
    assert b["metric"] == "active_users"
    assert b["totals"] == {"users": 2, "events": 3}, b["totals"]
    # ↑ EVAN(upload + 登录成功)+ BOB(upload);失败/锁定/无 UA/无 actor 全排除
    r2 = await client.get(URL, params={**p, "metric": "logins"}, headers=_h(EVAN_ID))
    assert r2.status_code == 200, r2.text
    b2 = r2.json()
    assert b2["metric"] == "logins"
    assert b2["totals"] == {"users": 1, "events": 1}, b2["totals"]  # 仅带 UA 的登录成功


# ─── §6.5 对账断言(count DISTINCT 跨组不可加)────────────────────────────────
async def test_reconciliation_users_not_addable_across_groups(
    client: AsyncClient, clean_usage_events,
) -> None:
    """同一用户(Evan)双端(web_desktop+web_mobile)且跨网(lan+wan):
    各分组 users 必须各自独立去重产出,任何行间求和推导都会虚增。"""
    lo, hi = await _seed_events([
        {"ua": _CHROME, "ip": "10.0.0.1", "actor": EVAN_ID},  # web_desktop x lan
        {"ua": _CHROME, "ip": "8.8.8.8", "actor": EVAN_ID},  # web_desktop x wan
        {"ua": _IPHONE, "ip": "10.0.0.2", "actor": EVAN_ID},  # web_mobile x lan
    ])
    r = await client.get(
        URL, params={"from": _iso(lo), "to": _iso(hi)}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    b = r.json()
    plat = {x["platform"]: x["users"] for x in b["by_platform"]}
    assert plat == {"web_desktop": 1, "web_mobile": 1}, plat  # 两行 users 各 1
    cls = {x["platform_class"]: x["users"] for x in b["by_platform_class"]}
    assert cls == {"web": 1}, cls  # 双端样本:by_platform_class.web 单行去重 = 1
    net = {x["network"]: x["users"] for x in b["by_network"]}
    assert net == {"lan": 1, "wan": 1}, net
    assert b["totals"]["users"] == 1, b["totals"]
    # 不等式1:多端用户 → by_platform 两行求和(2)虚增,≠ by_platform_class.web(1)
    assert sum(plat.values()) != cls["web"]
    # 不等式2:跨网用户 → platform 行 users ≠ 该 platform 的 cross 行 users 求和
    cross = b["cross"]
    assert {(x["platform"], x["network"]): x["users"] for x in cross} == {
        ("web_desktop", "lan"): 1,
        ("web_desktop", "wan"): 1,
        ("web_mobile", "lan"): 1,
    }
    wd_cross_sum = sum(x["users"] for x in cross if x["platform"] == "web_desktop")
    assert wd_cross_sum != plat["web_desktop"]
    # 不等式3:多端用户 → totals.users ≠ by_platform 行 users 求和
    assert b["totals"]["users"] != sum(plat.values())


# ─── §6.6 排序(users DESC 再 key 字典序)─────────────────────────────────────
async def test_sorting_users_desc_then_key_asc(
    client: AsyncClient, clean_usage_events,
) -> None:
    third = (await _make_actors(client, 1))[0]  # 独立第三用户(收尾自动禁用)
    lo, hi = await _seed_events([
        {"ua": _CHROME, "ip": "10.0.0.1", "actor": EVAN_ID},  # web_desktop users=3
        {"ua": _CHROME, "ip": "10.0.0.1", "actor": BOB_ID},
        {"ua": _CHROME, "ip": "10.0.0.1", "actor": third},
        {"ua": "msapp/0.1.11 (android)", "ip": "10.0.0.1", "actor": EVAN_ID},  # =2
        {"ua": "msapp/0.1.11 (android)", "ip": "10.0.0.1", "actor": BOB_ID},
        {"ua": _IPHONE, "ip": "10.0.0.1", "actor": EVAN_ID},  # web_mobile users=1
        {"ua": "Dart/3.5 (dart:io)", "ip": "10.0.0.1", "actor": BOB_ID},  # =1
        {"ua": _CHROME, "ip": "8.8.8.8", "actor": BOB_ID},  # wan users=1
    ])
    r = await client.get(
        URL, params={"from": _iso(lo), "to": _iso(hi)}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    b = r.json()
    # by_platform:users DESC,并列再按 platform 字典序(app_legacy < web_mobile)
    assert [(x["platform"], x["users"]) for x in b["by_platform"]] == [
        ("web_desktop", 3), ("android_app", 2), ("app_legacy", 1), ("web_mobile", 1),
    ]
    assert [(x["platform_class"], x["users"]) for x in b["by_platform_class"]] == [
        ("web", 3), ("android_app", 2), ("app_legacy", 1),  # Dart 样本类列自成一桶
    ]
    assert [(x["network"], x["users"]) for x in b["by_network"]] == [
        ("lan", 3), ("wan", 1),
    ]
    # cross:users DESC,并列再按 (platform, network) 字典序
    assert [(x["platform"], x["network"], x["users"]) for x in b["cross"]] == [
        ("web_desktop", "lan", 3),
        ("android_app", "lan", 2),
        ("app_legacy", "lan", 1),
        ("web_desktop", "wan", 1),
        ("web_mobile", "lan", 1),
    ]


# ─── §6.7 权限(未认证 401 / 普通成员 403 / system admin 200)─────────────────
async def test_permissions_unauth_401_member_403_admin_200(client: AsyncClient) -> None:
    r_anon = await client.get(URL)
    assert r_anon.status_code == 401, r_anon.text
    r_bob = await client.get(URL, headers=_h(BOB_ID))
    assert r_bob.status_code == 403, r_bob.text
    r_evan = await client.get(URL, headers=_h(EVAN_ID))
    assert r_evan.status_code == 200, r_evan.text


# ─── §6.8 daily 开关 + Asia/Shanghai 跨天分桶 ────────────────────────────────
async def test_daily_toggle_and_shanghai_bucketing(
    client: AsyncClient, clean_usage_events,
) -> None:
    t_late = datetime(2026, 10, 20, 23, 30, tzinfo=SH)  # 上海 20 日 23:30
    t_early = datetime(2026, 10, 21, 0, 30, tzinfo=SH)  # 上海 21 日 00:30
    # 两行同属 UTC 的 2026-10-20(15:30Z / 16:30Z)——按 UTC 分桶会同日,按上海分桶跨天
    lo, hi = await _seed_events([
        {"ua": _CHROME, "ip": "10.0.0.1", "actor": EVAN_ID, "t": t_late},
        {"ua": _CHROME, "ip": "10.0.0.1", "actor": EVAN_ID, "t": t_early},
    ])
    p = {"from": _iso(lo), "to": _iso(hi)}
    r = await client.get(URL, params=p, headers=_h(EVAN_ID))
    assert r.status_code == 200, r.text
    daily = r.json()["daily"]
    assert [
        (d["date"], d["platform"], d["network"], d["users"], d["events"]) for d in daily
    ] == [
        ("2026-10-20", "web_desktop", "lan", 1, 1),
        ("2026-10-21", "web_desktop", "lan", 1, 1),
    ], daily
    # daily=false → daily 返回 []
    r2 = await client.get(URL, params={**p, "daily": "false"}, headers=_h(EVAN_ID))
    assert r2.status_code == 200, r2.text
    assert r2.json()["daily"] == []


# ─── §6.9 端点契约字段完整性(§4 响应结构)────────────────────────────────────
async def test_response_contract_fields(
    client: AsyncClient, clean_usage_events,
) -> None:
    lo, hi = await _seed_events([{"ua": _CHROME, "ip": "10.0.0.1", "actor": EVAN_ID}])
    r = await client.get(
        URL, params={"from": _iso(lo), "to": _iso(hi)}, headers=_h(EVAN_ID),
    )
    assert r.status_code == 200, r.text
    b = r.json()
    assert set(b) == {
        "metric", "from", "to", "totals", "by_platform",
        "by_platform_class", "by_network", "cross", "daily",
    }, set(b)
    assert b["metric"] == "active_users"  # 默认口径
    assert b["totals"] == {"users": 1, "events": 1}, b["totals"]
    assert set(b["by_platform"][0]) == {"platform", "users", "events"}
    assert set(b["by_platform_class"][0]) == {"platform_class", "users", "events"}
    assert set(b["by_network"][0]) == {"network", "users", "events"}
    assert set(b["cross"][0]) == {"platform", "network", "users", "events"}
    assert set(b["daily"][0]) == {"date", "platform", "network", "users", "events"}
    # from / to 为 tz-aware ISO 回显
    assert datetime.fromisoformat(b["from"]).tzinfo is not None
    assert datetime.fromisoformat(b["to"]).tzinfo is not None
    # metric=logins 显式传参回显
    r2 = await client.get(
        URL, params={"from": _iso(lo), "to": _iso(hi), "metric": "logins"},
        headers=_h(EVAN_ID),
    )
    assert r2.status_code == 200, r2.text
    assert r2.json()["metric"] == "logins"


# ─── 方案 §7 回归:F3 补 ctx 后 share_link_created 进 active_users ────────────
async def test_share_link_created_enters_active_users(client: AsyncClient) -> None:
    """不走直插:经真实 share 端点产生 share_link_created,验证 ctx 补齐后
    审计行 UA 非空、并按 active_users 口径可见(httpx UA → web_desktop)。"""
    from app.db.session import get_sessionmaker
    from app.db.tables import Asset, AuditEvent

    rp = await client.post("/api/v1/projects", json={
        "code": f"usage-{uuid.uuid4().hex[:12]}",
        "name": "使用统计 share 回归项目",
        "minio_bucket": "ms-dev",
        "admin_user_id": EVAN_ID,
    }, headers=_h(EVAN_ID))
    assert rp.status_code == 201, rp.text
    pid = rp.json()["id"]
    try:
        rf = await client.post(
            "/api/v1/folders",
            json={"project_id": pid, "name": "usage-share 文件夹"},
            headers=_h(EVAN_ID),
        )
        assert rf.status_code == 201, rf.text
        aid = uuid.uuid4()
        async with get_sessionmaker()() as db:  # 直插 asset(presign PUT 容器内不通)
            db.add(Asset(
                id=aid,
                folder_id=uuid.UUID(rf.json()["id"]),
                filename="usage_share.txt",
                minio_bucket="ms-dev",
                minio_key=f"usage-test/{aid.hex}",
                size_bytes=1,
                content_type="text/plain",
                uploader_id=uuid.UUID(EVAN_ID),
                deleted_at=None,
                tags={},
            ))
            await db.commit()
        rs = await client.post(
            f"/api/v1/share/assets/{aid}", json={"expires_in_seconds": 3600},
            headers=_h(EVAN_ID),
        )
        assert rs.status_code == 200, rs.text
        async with get_sessionmaker()() as db:
            row = (await db.execute(
                select(AuditEvent).where(
                    AuditEvent.event_type == "share_link_created",
                    AuditEvent.target_asset_id == aid,
                ),
            )).scalars().first()
        assert row is not None and row.user_agent, (
            "share_link_created 审计行 UA 应非空(F3 ctx 补齐)"
        )
        # 该事件按 active_users 口径可见(窗口只圈它前后 1 分钟;仅做包含性断言)
        r = await client.get(URL, params={
            "from": _iso(row.event_time - timedelta(minutes=1)),
            "to": _iso(row.event_time + timedelta(minutes=1)),
        }, headers=_h(EVAN_ID))
        assert r.status_code == 200, r.text
        b = r.json()
        assert b["totals"]["events"] >= 1 and b["totals"]["users"] >= 1, b["totals"]
        assert any(x["platform"] == "web_desktop" for x in b["by_platform"]), (
            b["by_platform"]
        )
    finally:
        rd = await client.delete(f"/api/v1/projects/{pid}", headers=_h(EVAN_ID))
        assert rd.status_code in (200, 404), rd.text  # 收尾:项目逻辑删除
