"""Usage stats service — 客户端使用统计聚合(2026-10-27 usage-analytics 方案 §4.2)。

依托 audit_events 既有列(actor_user_id / user_agent / request_ip / event_time)
做只读聚合,不新建埋点;回答「三端占比 + 内外网占比」两问。

约定(需求 docs/qdev/2026-10-27-usage-analytics.md §2/§4):
- 维度解析只在 SQL 实现(单点,无 Python 双实现,方案 D5):platform / network
  的 CASE 规则序与正则逐字按需求 §2,本模块顶部三个 SQL 常量即正本
- 一条 GROUPING SETS 查询多粒度并出(raw text() + 绑定参数;SQLAlchemy ORM
  的生成式 group_by() 不支持 GROUPING SETS)
- 核心不变量:count(DISTINCT) 跨组不可加 —— totals / by_platform /
  by_platform_class / by_network / cross 的 users 由各自分组集独立产出,
  严禁任何行间求和推导(方案 §4.2)
- 日分桶时区固定 Asia/Shanghai(方案 D8);daily 只出 (date, platform, network)
  完整三元组行,不做日粒度部分合计
"""
from __future__ import annotations

from datetime import datetime
from typing import Any

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

# ─── SQL CASE 常量(需求 §2 规则序,逐字遵守;自上而下首中即归)────────────────
# platform:user_agent 解析。App 标记优先于浏览器 Mobile 标记;一律 ILIKE 免
# casing 依赖。规则 5「非空」显式排除空串(历史直插的 '' 行落 ELSE unknown
# 兜底分支,方案 §3.1);规则 6 即 ELSE 兜底(write 侧已把空串归一 None,
# 新数据不可达,枚举不设、仅 SQL 兜底保留)。
_PLATFORM_CASE = """CASE
    WHEN user_agent ILIKE '%msapp%' AND user_agent ILIKE '%(android)%' THEN 'android_app'
    WHEN user_agent ILIKE '%msapp%' AND user_agent ILIKE '%(ios)%' THEN 'ios_app'
    WHEN user_agent ILIKE '%msapp%' OR user_agent ILIKE '%Dart%' THEN 'app_legacy'
    WHEN user_agent ILIKE '%Android%' OR user_agent ILIKE '%iPhone%'
         OR user_agent ILIKE '%iPad%' OR user_agent ILIKE '%iPod%' THEN 'web_mobile'
    WHEN user_agent IS NOT NULL AND user_agent <> '' THEN 'web_desktop'
    ELSE 'unknown'
END"""

# platform_class:粗粒度三端 —— web_desktop/web_mobile 归并 web,其余原值
# (需求 §2)。「web 端去重人数」以本行/by_platform_class.web 为准,不是
# by_platform 两行求和(同一用户 PC + 手机双用会在 by_platform 各计 1)。
_PLATFORM_CLASS_CASE = (
    f"CASE WHEN ({_PLATFORM_CASE}) IN ('web_desktop', 'web_mobile') "
    f"THEN 'web' ELSE ({_PLATFORM_CASE}) END"
)

# network:request_ip 解析。~* 大小写不敏感正则(逐字按需求 §2,覆盖
# RFC1918 + loopback + link-local + IPv6 ULA + IPv4-mapped 私网
# `::ffff:` 前缀形态显式覆盖,`::ffff:8.8.8.8` 仍落 wan;172.15/172.32
# 等非 /12 段不得误配);NULL / 空串 / 'unknown' 哨兵(routers/auth.py
# ctx 缺 IP 时写的就是该字符串)→ unknown。
_NETWORK_CASE = r"""CASE
    WHEN request_ip IS NULL OR request_ip = '' OR request_ip = 'unknown' THEN 'unknown'
    WHEN request_ip ~* '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|127\.|169\.254\.|::1$|::ffff:(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)|f[cd][0-9a-f]{2}:|fe80:)' THEN 'lan'
    ELSE 'wan'
END"""

# ─── 口径过滤(需求 §2):两口径统一保留 actor/UA 非空 ─────────────────────────
# active_users(默认):显式排除带 actor 的失败登录/锁定 —— 尝试不算使用,
# 爆破流量更不该计入人数(routers/auth.py 密码错时 actor 非空)。
_ACTIVE_USERS_PREDICATE = "event_type NOT IN ('local_login_failed', 'local_login_locked')"
# logins(辅口径):只计本地登录成功;actor/UA 非空过滤同上保留。
_LOGINS_PREDICATE = "event_type = 'local_login_success'"


def _main_sql(metric_predicate: str) -> str:
    """GROUPING SETS 主查询:五粒度(总计/按端/粗三端/内外网/交叉)一条并出。

    GROUP BY 里完整重复 CASE 表达式(与 SELECT 项逐字一致)而非输出别名 ——
    表达式结构匹配是 SQL 标准保证,别名进 GROUPING SETS 依赖方言行为,不赌。
    """
    return f"""
SELECT {_PLATFORM_CASE} AS platform,
       {_PLATFORM_CLASS_CASE} AS platform_class,
       {_NETWORK_CASE} AS network,
       count(DISTINCT actor_user_id) AS users,
       count(*) AS events
FROM audit_events
WHERE event_time >= :from_time
  AND event_time < :to_time
  AND actor_user_id IS NOT NULL
  AND user_agent IS NOT NULL
  AND {metric_predicate}
GROUP BY GROUPING SETS (
    (),
    ({_PLATFORM_CASE}),
    ({_PLATFORM_CLASS_CASE}),
    ({_NETWORK_CASE}),
    ({_PLATFORM_CASE}, {_NETWORK_CASE})
)
"""


def _daily_sql(metric_predicate: str) -> str:
    """daily 查询:(日, platform, network) 完整三元组行,无部分合计行。

    日分桶 date_trunc 固定 Asia/Shanghai(方案 D8);to_char 出 'YYYY-MM-DD',
    与 SELECT 项逐字一致地按位置 GROUP BY(避免别名/结构匹配歧义)。
    """
    return f"""
SELECT to_char(date_trunc('day', event_time AT TIME ZONE 'Asia/Shanghai'), 'YYYY-MM-DD') AS day,
       {_PLATFORM_CASE} AS platform,
       {_NETWORK_CASE} AS network,
       count(DISTINCT actor_user_id) AS users,
       count(*) AS events
FROM audit_events
WHERE event_time >= :from_time
  AND event_time < :to_time
  AND actor_user_id IS NOT NULL
  AND user_agent IS NOT NULL
  AND {metric_predicate}
GROUP BY 1, 2, 3
"""


class UsageStatsService:
    """使用统计聚合(只读,无写入副作用);对外仅 stats() 一个入口。"""

    def __init__(self, session: AsyncSession):
        self._session = session

    async def stats(
        self,
        *,
        from_time: datetime,
        to_time: datetime,
        metric: str,
        daily: bool,
    ) -> dict[str, Any]:
        """聚合统计(需求 §4 响应契约;排序亦在此单点实现)。

        metric 分支:active_users(默认)排除失败登录/锁定;logins 只计
        local_login_success。daily=False 时跳过日查询直接回 []。
        """
        params: dict[str, datetime] = {"from_time": from_time, "to_time": to_time}
        predicate = _LOGINS_PREDICATE if metric == "logins" else _ACTIVE_USERS_PREDICATE

        rows = (await self._session.execute(text(_main_sql(predicate)), params)).mappings().all()

        # 逐行按 NULL 模式分流:CASE 恒非 NULL(每条规则都有确定值),故分组集
        # 产出的行以「哪些维度列为 NULL」唯一区分;每个 users 都来自其分组集内
        # 独立去重(核心不变量)
        totals = {"users": 0, "events": 0}
        by_platform: list[dict[str, Any]] = []
        by_platform_class: list[dict[str, Any]] = []
        by_network: list[dict[str, Any]] = []
        cross: list[dict[str, Any]] = []
        for row in rows:
            if (
                row["platform"] is None
                and row["platform_class"] is None
                and row["network"] is None
            ):  # () 分组集:全窗口一行,totals 用它,不归并任何分项行
                totals = {"users": int(row["users"]), "events": int(row["events"])}
            elif row["platform"] is not None and row["network"] is not None:
                cross.append({
                    "platform": str(row["platform"]),
                    "network": str(row["network"]),
                    "users": int(row["users"]),
                    "events": int(row["events"]),
                })
            elif row["platform"] is not None:
                by_platform.append({
                    "platform": str(row["platform"]),
                    "users": int(row["users"]),
                    "events": int(row["events"]),
                })
            elif row["platform_class"] is not None:
                by_platform_class.append({
                    "platform_class": str(row["platform_class"]),
                    "users": int(row["users"]),
                    "events": int(row["events"]),
                })
            else:
                by_network.append({
                    "network": str(row["network"]),
                    "users": int(row["users"]),
                    "events": int(row["events"]),
                })

        # 排序单点实现(需求 §4 定死):by_* 按 users DESC 再 key 字典序;
        # cross 按 users DESC 再 (platform, network);daily 按 date ASC 再维度序
        by_platform.sort(key=lambda r: (-int(r["users"]), str(r["platform"])))
        by_platform_class.sort(key=lambda r: (-int(r["users"]), str(r["platform_class"])))
        by_network.sort(key=lambda r: (-int(r["users"]), str(r["network"])))
        cross.sort(key=lambda r: (-int(r["users"]), str(r["platform"]), str(r["network"])))

        daily_rows: list[dict[str, Any]] = []
        if daily:
            d_rows = (
                await self._session.execute(text(_daily_sql(predicate)), params)
            ).mappings().all()
            daily_rows = [
                {
                    "date": str(r["day"]),
                    "platform": str(r["platform"]),
                    "network": str(r["network"]),
                    "users": int(r["users"]),
                    "events": int(r["events"]),
                }
                for r in d_rows
            ]
            daily_rows.sort(
                key=lambda r: (str(r["date"]), str(r["platform"]), str(r["network"]))
            )

        return {
            "metric": metric,
            "from": from_time,
            "to": to_time,
            "totals": totals,
            "by_platform": by_platform,
            "by_platform_class": by_platform_class,
            "by_network": by_network,
            "cross": cross,
            "daily": daily_rows,
        }
