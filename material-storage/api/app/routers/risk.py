"""risk router — 登录风控:锁列表 + 单独解 IP 锁(2026-10-28 risk-control-module-plan §3)。

  GET  /api/v1/admin/risk/locks                 — 当前全部 user/ip 维度登录锁(只读快照)
  POST /api/v1/admin/risk/locks/ips/{ip}/unlock — 单独解除某个 IP 的登录锁(幂等,写审计)

独立 router(照 usage_stats.py 先例,不堆进 admin.py);两端点均 require_system_admin。
账号维度解锁不在此复刻 —— 复用既有 POST /api/v1/admin/directory/users/{id}/unlock
(连带清近 24h 失败来源 IP 的行为保留不变,§3.3)。
"""
from __future__ import annotations

import logging
from datetime import UTC, datetime, timedelta
from typing import Literal

from fastapi import APIRouter, Depends, Request
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.session import get_db
from app.db.tables import AuditEvent, User
from app.deps import CurrentUser, get_audit, get_local_auth, require_system_admin
from app.models import (
    RiskIpLock,
    RiskIpUnlockOut,
    RiskLocksOut,
    RiskMatchedUser,
    RiskUserLock,
)
from app.services.audit import AuditService
from app.services.local_auth import LocalAuthService

router = APIRouter()

log = logging.getLogger(__name__)


@router.get("/locks", response_model=RiskLocksOut)
async def list_risk_locks(
    db: AsyncSession = Depends(get_db),  # noqa: B008  FastAPI DI,repo 全量同款
    user: CurrentUser = Depends(require_system_admin),  # noqa: B008
    local_auth: LocalAuthService = Depends(get_local_auth),  # noqa: B008
) -> RiskLocksOut:
    """列出当前全部登录锁(§3.1;只读快照,不写审计 —— 照 usage_stats 只读先例 D6)。

    - user 维度:锁 key 的登录名形态(form)经 DB **单条 OR 查询**批量反查账号,
      每 form 按命中行数归类 unique / none / ambiguous(命中 = 该行任一列
      lower 等于 form,同一行命中多列只算一次)。与登录三级匹配同构但**刻意
      保守**:登录是分层短路(find_user_by_username 单 form 三连查,username
      命中即停),批量 OR 下「form 命中 A.username 又命中 B.name」判
      ambiguous(登录语义下是 unique)—— 歧义展示不给解锁入口,防误伤重名
      用户,属已知偏差非 bug(§3.1);
    - ip 维度:近 24h 该 IP 的 local_login_failed 审计反查失败用户名去重集
      (details.username 存**原始输入未 lower**,比对统一 lower 口径,
      directory.py:539-551 先例;NULL 过滤);
    - 两列表均按 lock_ttl_seconds 降序(新触发的在前);unknown 哨兵 IP 如实
      展示不静默过滤(「链路异常」标注归前端)。
    """
    _ = user.id
    forms, ips = await local_auth.scan_locks()
    user_rows, ip_rows = await local_auth.lock_details(forms, ips)

    # user 维度账号反查(单查询;matched[form] 按命中行聚,同行多列只算一次)
    matched: dict[str, list[RiskMatchedUser]] = {form: [] for form in user_rows}
    if user_rows:
        res = await db.execute(
            select(User).where(
                func.lower(User.username).in_(user_rows)
                | func.lower(User.email).in_(user_rows)
                | func.lower(User.name).in_(user_rows)
            )
        )
        for u in res.scalars():
            u_forms = {v.lower() for v in (u.username, u.email, u.name) if v}
            for form, hits in matched.items():
                if form in u_forms:
                    hits.append(
                        RiskMatchedUser(id=u.id, username=u.username, name=u.name))

    # ip 维度富化:近 24h 失败用户名按 IP 分组(details JSONB .astext 后 lower;
    # username 键缺失 / NULL 的行过滤,不进集合)
    recent: dict[str, set[str]] = {ip: set() for ip in ip_rows}
    if ip_rows:
        since = datetime.now(UTC) - timedelta(hours=24)
        ip_res = await db.execute(
            select(
                AuditEvent.request_ip,
                func.lower(AuditEvent.details["username"].astext),
            )
            .where(
                AuditEvent.event_type == "local_login_failed",
                AuditEvent.event_time >= since,
                AuditEvent.request_ip.in_(ip_rows),
            )
            .distinct()
        )
        for arow in ip_res.all():
            row_ip = arow[0]
            uname = arow[1]
            if row_ip is not None and uname:
                recent.setdefault(row_ip, set()).add(uname)

    users_out: list[RiskUserLock] = []
    for form, row in user_rows.items():
        hits = matched[form]
        kind: Literal["unique", "none", "ambiguous"]
        if not hits:
            kind = "none"
        elif len(hits) == 1:
            kind = "unique"
        else:
            kind = "ambiguous"
        users_out.append(RiskUserLock(
            form=form, match=kind, matched_users=hits,
            fail_count=row.fail_count, lock_ttl_seconds=row.lock_ttl_seconds,
        ))
    users_out.sort(key=lambda r: r.lock_ttl_seconds, reverse=True)

    ips_out = [
        RiskIpLock(
            ip=ip, fail_count=row.fail_count,
            lock_ttl_seconds=row.lock_ttl_seconds,
            recent_failed_userforms=sorted(recent.get(ip, set())),
        )
        for ip, row in ip_rows.items()
    ]
    ips_out.sort(key=lambda r: r.lock_ttl_seconds, reverse=True)

    return RiskLocksOut(users=users_out, ips=ips_out)


@router.post("/locks/ips/{ip}/unlock", response_model=RiskIpUnlockOut)
async def unlock_risk_ip(
    ip: str,
    request: Request,
    user: CurrentUser = Depends(require_system_admin),  # noqa: B008
    audit: AuditService = Depends(get_audit),  # noqa: B008
    local_auth: LocalAuthService = Depends(get_local_auth),  # noqa: B008
) -> RiskIpUnlockOut:
    """单独解除某个 IP 的登录锁(§3.2;DEL 不存在的 key 是幂等 no-op)。

    - ``ip`` 路径参数**不做格式校验**(透传 Redis key 组装,校验反而堵「异常
      形态 key」的清理,D3),仅 strip 空白;
    - ``was_locked`` 取严格语义 = 锁 key 曾存在:先 ``ip_lock_exists`` 预判,
      再 ``clear_ip_locks``(后者返回非空只代表「锁或计数任一被清」,残留
      失败计数也会命中,不够准)。已知可接受竞态:预判与 DEL 之间锁自然过期
      时 was_locked=true 但实际未清任何 key(审计落一条「空解锁」)—— 幂等
      无害,details 顺带记 ``clear_ip_locks`` 实际返回清单备查;
    - 审计 ip_login_unlocked(details = ip / was_locked / cleared,调用形态照
      user_login_unlocked);audit.write 自带 commit,勿再 commit。
    """
    ip = ip.strip()
    was_locked = await local_auth.ip_lock_exists(ip)
    cleared = await local_auth.clear_ip_locks([ip])
    await audit.write(
        event_type="ip_login_unlocked",
        actor_user_id=user.id,
        details={"ip": ip, "was_locked": was_locked, "cleared": cleared},
        request_ip=request.client.host if request.client else None,
        user_agent=request.headers.get("user-agent"),
    )
    log.info("ip lock unlocked ip=%s by admin=%s was_locked=%s cleared=%s",
             ip, user.id, was_locked, cleared)
    return RiskIpUnlockOut(ip=ip, was_locked=was_locked)
