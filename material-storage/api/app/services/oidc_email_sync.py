"""OIDC 登录同步邮箱后的接线清理(邮箱账号方案 §5.3.5)。

``OIDCService.upsert_user_from_userinfo``(``services/auth.py``)在 service 侧
已清 ``email_verified_at`` 并删未用重置 token;本模块只补接线侧收尾:
DEL 残留验证码 ``email:code:{user_id}`` + 审计 ``email_changed(source=oidc)``。
从 ``routers/auth.py::callback`` 原样抽出(纯搬家):登录主流程已成功,两者
一律 best-effort —— Redis 抖动(§5.3.5)/ 审计失败(§5.9)都不能把登录变 5xx。
"""
from __future__ import annotations

import logging
import uuid
from typing import Any

from app.services.audit import AuditService
from app.services.email_utils import mask_email

log = logging.getLogger(__name__)


async def oidc_email_changed_cleanup(
    redis: Any,
    audit: AuditService,
    *,
    user_id: uuid.UUID,
    old_email: str,
    new_email: str | None,
    request_ip: str | None,
    user_agent: str | None,
) -> None:
    """email_changed 后处理:DEL email:code(残留验证码不能把新地址绑上)+ 审计。

    ``old_email`` 非空由调用方保证(email_changed=True 蕴含快照已取,调用点
    ``assert``);本函数内部两条支路一律吞异常只 log。
    """
    try:
        await redis.delete(f"email:code:{user_id}")
    except Exception:  # best-effort(Redis 抖动不拦登录,§5.3.5)
        log.warning("OIDC email change: del email:code failed user=%s", user_id)
    try:
        await audit.write(
            event_type="email_changed",
            actor_user_id=user_id,
            request_ip=request_ip,
            user_agent=user_agent,
            details={
                "old_masked": mask_email(old_email),
                "new_masked": mask_email(new_email),
                "source": "oidc",
            },
            actor_email_snapshot=mask_email(new_email),
        )
    except Exception:  # best-effort(审计失败不能拦登录,§5.9)
        log.warning("OIDC email change: audit write failed user=%s", user_id)
