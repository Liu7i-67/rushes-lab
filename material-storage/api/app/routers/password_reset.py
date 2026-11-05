"""找回密码公开三端点(方案 §5.4)— B3。

account_security.py(B2/B3 共享文件)已到单文件行数上限,按环境约束
「router 端点多就拆子模块」把本包端点独立成文件,由 account_security.router
include(与 auth.py ← auth_tokens.py 同款拆法);最终 URL 不变:
``/api/v1/auth/password-reset/request|verify|confirm``。

§5.4.2(申请 14 步)/ §5.4.3(verify)/ §5.4.4(confirm 9 步)的完整流程在
``services/password_reset.py``;本文件只做 mail_ready 开关(503)、
``RateLimitUnavailable`` → 503 的 fail-closed 收口与入参解析(422 在 Pydantic
解析期,先于一切计数)。
"""
from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import JSONResponse
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.session import get_db
from app.deps import get_audit, get_local_auth, get_request_context
from app.models import (
    PasswordResetConfirmIn,
    PasswordResetRequestIn,
    PasswordResetTokenIn,
)
from app.services import password_reset_flows as pr
from app.services.audit import AuditService
from app.services.local_auth import LocalAuthService
from app.services.rate_limit import RateLimitUnavailable
from app.settings import get_settings

log = logging.getLogger(__name__)
router = APIRouter()


def _require_mail_ready(request: Request) -> None:
    """有效开关(§5.4.2 第 1 步);关闭后存量链接也一并失效(回滚彻底)。"""
    if not getattr(request.app.state, "mail_ready", False):
        raise HTTPException(503, "邮箱功能未启用,请联系管理员")


@router.post("/password-reset/request")
async def password_reset_request(
    request: Request,
    body: PasswordResetRequestIn,
    db: AsyncSession = Depends(get_db),  # noqa: B008  FastAPI DI,repo 全量同款
    audit: AuditService = Depends(get_audit),  # noqa: B008
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008
) -> JSONResponse:
    """申请重置邮件(公开;流程/顺序即安全 → services.password_reset.request_reset)。"""
    _require_mail_ready(request)
    try:
        result = await pr.request_reset(
            request=request, db=db, redis=request.app.state.redis,
            settings=get_settings(), audit=audit, email=body.email,
            ip=ctx.get("request_ip") or "unknown",
            user_agent=ctx.get("user_agent"),
        )
    except RateLimitUnavailable:
        log.warning("pwreset request redis unavailable")
        raise HTTPException(503, "服务暂不可用,请稍后再试") from None
    return JSONResponse(result)


@router.post("/password-reset/verify")
async def password_reset_verify(
    request: Request,
    body: PasswordResetTokenIn,
    db: AsyncSession = Depends(get_db),  # noqa: B008
    audit: AuditService = Depends(get_audit),  # noqa: B008
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008
) -> JSONResponse:
    """校验 token(公开,只读不消费):重置页先行展示脱敏邮箱(§5.4.3)。"""
    _require_mail_ready(request)
    try:
        result = await pr.verify_reset(
            db=db, redis=request.app.state.redis, settings=get_settings(),
            audit=audit, token=body.token,
            ip=ctx.get("request_ip") or "unknown",
            user_agent=ctx.get("user_agent"),
        )
    except RateLimitUnavailable:
        log.warning("pwreset verify redis unavailable")
        raise HTTPException(503, "服务暂不可用,请稍后再试") from None
    return JSONResponse(result)


@router.post("/password-reset/confirm")
async def password_reset_confirm(
    request: Request,
    body: PasswordResetConfirmIn,
    db: AsyncSession = Depends(get_db),  # noqa: B008
    local_auth: LocalAuthService = Depends(get_local_auth),  # noqa: B008
    audit: AuditService = Depends(get_audit),  # noqa: B008
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008
) -> JSONResponse:
    """确认重置(公开;§5.4.4 的 9 步 → services.password_reset.confirm_reset)。"""
    _require_mail_ready(request)
    try:
        result = await pr.confirm_reset(
            db=db, redis=request.app.state.redis, settings=get_settings(),
            local_auth=local_auth, audit=audit, token=body.token,
            new_password=body.new_password,
            ip=ctx.get("request_ip") or "unknown",
            user_agent=ctx.get("user_agent"),
        )
    except RateLimitUnavailable:
        log.warning("pwreset confirm redis unavailable")
        raise HTTPException(503, "服务暂不可用,请稍后再试") from None
    return JSONResponse(result)
