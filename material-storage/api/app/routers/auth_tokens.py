"""个人访问令牌(PAT)自助管理三端点 — MCP 素材服务(方案 D2/D3/D15)。

由 ``app/routers/auth.py`` 以 ``router.include_router(tokens_router, prefix="/tokens")``
挂载,最终 URL 与拆分前完全一致:
  POST   /api/v1/auth/tokens          → 创建(明文只回显一次;Cache-Control: no-store)
  GET    /api/v1/auth/tokens          → 本人列表(无明文;?include_revoked=1 含历史)
  DELETE /api/v1/auth/tokens/{id}     → 吊销本人令牌(幂等 204;非本人/不存在 404)

三端点均为 **session-only** 认证(D13b:持 PAT 者调本组端点一律 403
「令牌不允许管理令牌/改密」—— 否则可用旧 PAT 自我续期,吊销失去意义)。
守卫 = ``app.deps.require_session_auth`` **逐路由**挂(勿给整个 auth router 挂,
``/auth/local/login`` 会被挡死);审计经 ``get_audit``(独立 session)。
"""
from __future__ import annotations

import logging
import uuid
from datetime import UTC, datetime

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.session import get_db
from app.db.tables import User
from app.deps import (
    CurrentUser,
    get_audit,
    get_request_context,
    require_session_auth,
)
from app.models import TokenCreatedOut, TokenCreateIn, TokenOut
from app.services.audit import AuditService
from app.services.tokens import (
    TokenLimitExceeded,
    create_token,
    get_token,
    list_tokens,
    revoke_token,
)

log = logging.getLogger(__name__)
router = APIRouter()


@router.post("", status_code=201, response_model=TokenCreatedOut)
async def create_personal_token(
    body: TokenCreateIn,
    response: Response,
    cur: CurrentUser = Depends(require_session_auth),  # noqa: B008  # session-only(D13b)
    db: AsyncSession = Depends(get_db),  # noqa: B008
    audit: AuditService = Depends(get_audit),  # noqa: B008
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008
) -> TokenCreatedOut:
    """创建 PAT(明文 ``token`` 只在此响应回显一次;``Cache-Control: no-store``)。

    - 强制改密态(must_change_password 且已设密码)→ 403(口径同 /me);
    - 每用户活跃令牌上限 5(service 内事务级 advisory lock 防并发竞态)→ 409;
    - 审计 ``token_created``(details: token_id + token_prefix 快照)。
    """
    user = await db.get(User, cur.id)
    if user is None:
        raise HTTPException(401, "session user not found")
    if user.must_change_password and user.password_hash is not None:
        raise HTTPException(403, "首次登录请先设置新密码,再创建访问令牌")

    try:
        created = await create_token(
            db,
            user_id=user.id,
            name=body.name,
            expires_in_days=body.expires_in_days,
        )
    except TokenLimitExceeded as e:
        raise HTTPException(409, str(e)) from e
    await db.commit()

    await audit.write(
        event_type="token_created",
        actor_user_id=user.id,
        request_ip=ctx.get("request_ip"),
        user_agent=ctx.get("user_agent"),
        details={"token_id": str(created.id), "token_prefix": created.token_prefix},
    )
    response.headers["Cache-Control"] = "no-store"
    log.info("personal access token created user_id=%s token_id=%s", user.id, created.id)
    return TokenCreatedOut(
        id=created.id,
        name=created.name,
        token=created.token,
        token_prefix=created.token_prefix,
        expires_at=created.expires_at,
    )


@router.get("", response_model=list[TokenOut])
async def list_personal_tokens(
    include_revoked: bool = Query(False, description="含已吊销/已过期历史行"),
    cur: CurrentUser = Depends(require_session_auth),  # noqa: B008  # session-only(D13b)
    db: AsyncSession = Depends(get_db),  # noqa: B008
) -> list[TokenOut]:
    """本人令牌列表(永不含明文/token_hash);默认只回活跃(未吊销未过期)。

    ``?include_revoked=1`` 回全部历史行,并以 ``revoked_at`` / ``expired`` 标注。
    """
    rows = await list_tokens(db, user_id=cur.id, include_revoked=include_revoked)
    now = datetime.now(UTC)
    return [
        TokenOut(
            id=r.id,
            name=r.name,
            token_prefix=r.token_prefix,
            created_at=r.created_at,
            last_used_at=r.last_used_at,
            expires_at=r.expires_at,
            revoked_at=r.revoked_at,
            expired=r.expires_at <= now,
        )
        for r in rows
    ]


@router.delete("/{token_id}", status_code=204)
async def revoke_personal_token(
    token_id: uuid.UUID,
    cur: CurrentUser = Depends(require_session_auth),  # noqa: B008  # session-only(D13b)
    db: AsyncSession = Depends(get_db),  # noqa: B008
    audit: AuditService = Depends(get_audit),  # noqa: B008
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008
) -> Response:
    """吊销本人令牌 → 204。

    归属契约:非本人 / 不存在一律 **404**(不泄露存在性);重复吊销幂等 204,
    且**不再写审计**(只对首次生效的吊销写一条 ``token_revoked``,
    details: token_id / token_prefix / reason=self_revoked / actor=self)。
    """
    row = await get_token(db, token_id=token_id, user_id=cur.id)
    if row is None:
        raise HTTPException(404, "令牌不存在")
    newly_revoked = await revoke_token(db, token_id=token_id, user_id=cur.id)
    await db.commit()
    if newly_revoked:
        await audit.write(
            event_type="token_revoked",
            actor_user_id=cur.id,
            request_ip=ctx.get("request_ip"),
            user_agent=ctx.get("user_agent"),
            details={
                "token_id": str(token_id),
                "token_prefix": row.token_prefix,
                "reason": "self_revoked",
                "actor": "self",
            },
        )
        log.info("personal access token revoked user_id=%s token_id=%s", cur.id, token_id)
    return Response(status_code=204)
