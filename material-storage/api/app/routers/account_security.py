"""账号安全 router — 邮箱绑定/换绑/解绑 + 找回密码(方案 §5.2/§5.3/§5.4)。

统一挂 /api/v1/auth 前缀(main.py)。B1a 只含公开配置端点;B2(邮箱验证码
三端点)/ B3(找回密码三端点)后续按下方分区追加,不另开 router。

分区规划(B2/B3 落点,别挪):
  # ─── 公开端点(无需鉴权)── GET /public-config(本文件,B1a)
  # ─── B2:邮箱验证码(session-only)── POST /email/code|/email/confirm|/email/unbind
  # ─── B3:找回密码(公开)── POST /password-reset/request|verify|confirm
"""

from __future__ import annotations

from fastapi import APIRouter, Request
from pydantic import BaseModel

from app.settings import get_settings

router = APIRouter()


class PublicAuthConfigOut(BaseModel):
    """登录页「忘记密码」/ 设置页邮箱区的显隐依据(方案 §5.2);无秘密,可公开。

    email_auth_enabled = password_reset_enabled = mail_ready
    (lifespan 启动时经 resolve_mail_ready 算好挂 app.state,配置不合法降级 false)。
    """

    email_auth_enabled: bool
    password_reset_enabled: bool
    password_min_length: int


# ─── 公开端点(无需鉴权;高频轮询,不写审计)─────────────────────────────────
@router.get("/public-config", response_model=PublicAuthConfigOut)
async def public_config(request: Request) -> PublicAuthConfigOut:
    # getattr 兜底:lifespan 未跑(如部分单测/降级启动)时按 false 处理,
    # 公开配置宁可隐藏入口也不能 500
    mail_ready = getattr(request.app.state, "mail_ready", False)
    settings = get_settings()
    return PublicAuthConfigOut(
        email_auth_enabled=mail_ready,
        password_reset_enabled=mail_ready,
        password_min_length=settings.auth_password_min_length,
    )


# ─── B2:邮箱验证码(session-only;POST /email/code|/email/confirm|/email/unbind)──


# ─── B3:找回密码(公开;POST /password-reset/request|verify|confirm)──
