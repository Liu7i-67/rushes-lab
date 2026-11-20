"""短信四端点共享流程 helper(bind + reset 两 router 的公共骨架)— 方案 §5.3/§5.4/§5.7。

account_security.py(登录态 bind 两端点)与 password_reset.py(公开 reset 两端点)
的镜像 helper 原各持一份(~58 行,仅 scene 与审计 auth_method 显式性两点差异),
收敛到本模块,公开行为(响应形状/文案/状态码/审计内容)逐字节不变:
  - sms_guard:503 守卫(四端点统一首步,D17)
  - send_failure_502:发送失败统一处理(方案 §5.3 步骤 8 / §5.4 步骤 7 / D9),
    差异作参数 —— scene("bind"/"reset")、auth_method(登录态不传 → audit
    默认推导;公开端点显式 None 强制落 NULL,方案 §5.7)

本模块只依赖 phone_verification / audit / settings,不 import 任何 router。
"""

from __future__ import annotations

import uuid
from typing import Any

from fastapi import HTTPException, Request
from fastapi.responses import JSONResponse

from app.services.audit import AuditService
from app.services.phone_verification import Scene, rollback_quota
from app.settings import get_settings

# auth_method 显式性哨兵(语义与 audit.write 的默认哨兵同款):不传 → write 内部
# 默认推导(登录态 bind 端点即 session);显式 None → 强制落 NULL(公开 reset
# 端点从未执行 get_current_user,不显式传 None 会被推导误标 session,方案 §5.7)。
AUTH_METHOD_UNSET: Any = object()


def sms_guard(request: Request) -> Any:
    """503 守卫(四端点统一首步,方案 §5.3/§5.4/D17):未配置时 app.state.sms=None,
    必须先于任何计数/查库拒绝,防 AttributeError 500。返回已构造的发送服务。"""
    settings = get_settings()
    sms = request.app.state.sms
    if not settings.aliyun_sms_enabled or sms is None:
        raise HTTPException(503, "短信服务未配置")
    return sms


async def send_failure_502(
    audit: AuditService,
    redis: Any,
    *,
    scene: Scene,
    actor_user_id: uuid.UUID,
    ip: str,
    user_agent: str | None,
    phone_masked: str,
    err_code: str,
    err_message: str,
    quota_keys: tuple[str, ...],
    cooldown_seconds: int,
    auth_method: str | object | None = AUTH_METHOD_UNSET,
) -> JSONResponse:
    """发送失败统一处理(D9):审计 sms_send_failed → 保留冷却键 → 回滚本次新增
    配额计数 → 502。bind/reset 两侧同口径,差异见模块 docstring。

    - 冷却键保留:SendSms 无幂等,超时 ≠ 未受理,立即放行重发可能双条短信
    - 配额回滚:码没发成不扣配额(bind 侧小时+日 / reset 侧 IP 小时+日)
    - ``isv.BUSINESS_LIMIT_CONTROL``(运营商 ~1h 同号频控,钉子 7):502 不带
      retry_after(回填冷却值只会放行后再吃一次 502),文案钉死
    - 审计 err_code:SmsSendError.code 为阿里云原文;transport 类无原文,用
      SmsTransportError.kind 哨兵(transport_timeout / transport_unparseable),
      err_message 落本地异常摘要(不含 URL / 明文码)
    """
    auth_kwargs: dict[str, Any] = (
        {} if auth_method is AUTH_METHOD_UNSET else {"auth_method": auth_method}
    )
    await audit.write(
        event_type="sms_send_failed",
        actor_user_id=actor_user_id,
        request_ip=ip,
        user_agent=user_agent,
        **auth_kwargs,
        details={
            "scene": scene,
            "phone_masked": phone_masked,
            "err_code": err_code,
            "err_message": err_message,
        },
    )
    if quota_keys:
        await rollback_quota(redis, *quota_keys)
    if err_code == "isv.BUSINESS_LIMIT_CONTROL":
        return JSONResponse(
            status_code=502,
            content={"detail": "操作过于频繁,请一小时后再试"},
        )
    return JSONResponse(
        status_code=502,
        content={"detail": "短信发送失败,请稍后重试", "retry_after": cooldown_seconds},
    )
