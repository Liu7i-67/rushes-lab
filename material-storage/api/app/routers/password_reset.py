"""忘记密码(短信找回)router — 公开两端点(手机绑定/短信找回密码方案 §5.4)。

endpoints(公开,无鉴权依赖,照 maintenance.py 公开声明先例;main.py 挂 /api/v1/auth
前缀,与 auth router 同域):
  POST /api/v1/auth/phone/reset/send-code → 校验号已绑定且启用后发重置验证码
      → 200 {retry_after}
  POST /api/v1/auth/phone/reset/confirm   → 原子消费验码 → 系统重置随机密码
      → 200 {username, email, name, new_password}(一次性,Cache-Control: no-store)

钉子:
  - 步骤顺序钉死方案 §5.4(send-code 1-8 / confirm 1-6),不得调序
  - 公开端点审计写入一律显式 auth_method=None(方案 §5.7:端点从未执行
    get_current_user,write() 默认推导会把无认证事件误标 session)
  - 枚举面 = 需求拍板接受(R2b/§8.1):未绑定号明确报「无法发送验证码」,
    denied 留审计 phone_reset_denied;IP 配额在查库之前计数,denied 不回滚
  - D9 失败统一处理:保留冷却键 + 回滚本次新增配额(含 IP 小时计数)
  - 重置后吊销全部 PAT(对齐 change-password,D8)、不踢旧 session(D8/§13);
    must_change_password=true 首登强制再改(D2)
  - 机密纪律:新密码 / 验证码明文不进日志、不进审计 details、不进异常文本
"""

from __future__ import annotations

import logging
from datetime import UTC, datetime

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.session import get_db
from app.db.tables import User
from app.deps import get_audit, get_request_context
from app.services.aliyun_sms import SmsSendError, SmsTransportError
from app.services.audit import AuditService
from app.services.passwords import generate_temp_password, hash_password
from app.services.phone_verification import (
    InvalidPhone,
    acquire_cooldown,
    consume_code,
    cooldown_key,
    daily_key,
    hourly_reset_ip_key,
    incr_daily,
    incr_hourly,
    issue_code,
    mask_phone,
    normalize_phone,
    rollback_quota,
)
from app.services.sms_flow import send_failure_502, sms_guard
from app.services.tokens import revoke_user_tokens
from app.settings import get_settings

log = logging.getLogger(__name__)
router = APIRouter()


# ─── 入参(服务端统一 D5 归一化,先宽后严)────────────────────────────────────


class PhoneResetSendIn(BaseModel):
    """发送重置验证码入参;手机号格式校验在 normalize_phone(格式错 400)。"""

    phone: str = Field(..., min_length=1, max_length=32)


class PhoneResetConfirmIn(BaseModel):
    """重置确认入参;code 服务端统一 strip().upper() 再比对(D3 字母表全大写)。"""

    phone: str = Field(..., min_length=1, max_length=32)
    code: str = Field(..., min_length=1, max_length=16)


# ─── POST /api/v1/auth/phone/reset/send-code(方案 §5.4 send-code 步骤 1-8)───


@router.post("/phone/reset/send-code")
async def send_reset_code(
    body: PhoneResetSendIn,
    request: Request,
    db: AsyncSession = Depends(get_db),  # noqa: B008  FastAPI DI,repo 全量同款
    audit: AuditService = Depends(get_audit),  # noqa: B008
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008
) -> JSONResponse:
    settings = get_settings()
    redis = request.app.state.redis
    ip = ctx.get("request_ip") or "unknown"
    sms = sms_guard(request)  # 步骤 1:503 守卫
    try:
        phone = normalize_phone(body.phone)
    except InvalidPhone:
        # 纯格式错不消耗任何计数(方案 §5.4 步骤 1)
        raise HTTPException(400, "手机号格式不正确") from None
    phone_masked = mask_phone(phone)
    # 步骤 2:同号冷却(**先冷却后 IP 计数**:同一号码重复点击在冷却层就被拦,
    # 不烧 IP 配额,方案 §5.4)
    remaining = await acquire_cooldown(
        redis,
        scene="reset",
        phone=phone,
        cooldown_seconds=settings.sms_send_cooldown_seconds,
    )
    if remaining is not None:
        return JSONResponse(
            status_code=429,
            content={"detail": "发送过于频繁,请稍后再试", "retry_after": remaining},
        )
    now = datetime.now(UTC)
    cooldown_key_str = cooldown_key(scene="reset", phone=phone)
    # 步骤 3:IP 每小时配额(**在查库之前计数**:换不存在号码打库同样烧配额,
    # denied 不回滚 IP 计数,枚举防护保留,方案 §5.4;内网同出口 IP 取 20/h 宽松值)
    ip_bucket_key = hourly_reset_ip_key(ip=ip, now=now)
    ip_count = await incr_hourly(redis, ip_bucket_key)
    if ip_count > settings.sms_reset_ip_hourly:
        await redis.delete(cooldown_key_str)
        return JSONResponse(
            status_code=429,
            content={
                "detail": "发送过于频繁,请稍后再试",
                "retry_after": settings.sms_send_cooldown_seconds,
            },
        )
    # 步骤 4:查库(phone 唯一约束保证至多一行;须已绑定且启用);未命中 →
    # 400「无法发送验证码」(R2b 原文文案)+ DEL 冷却键 + 审计 denied
    target_id = (
        await db.execute(select(User.id).where(User.phone == phone, User.is_active.is_(True)).limit(1))
    ).scalar_one_or_none()
    if target_id is None:
        await redis.delete(cooldown_key_str)
        await audit.write(
            event_type="phone_reset_denied",
            actor_user_id=None,
            request_ip=ip,
            user_agent=ctx.get("user_agent"),
            auth_method=None,  # 公开端点显式 NULL(方案 §5.7)
            details={"phone_masked": phone_masked},
        )
        raise HTTPException(400, "无法发送验证码")
    # 步骤 5:每号每日配额 → 超 429 + DEL 冷却键 + 回滚本次日计数
    day_key = daily_key(scene="reset", phone=phone, now=now)
    daily_count = await incr_daily(redis, scene="reset", phone=phone, now=now)
    if daily_count > settings.sms_daily_per_phone:
        await redis.delete(cooldown_key_str)
        await rollback_quota(redis, day_key)
        return JSONResponse(
            status_code=429,
            content={
                "detail": "发送过于频繁,请稍后再试",
                "retry_after": settings.sms_send_cooldown_seconds,
            },
        )
    # 步骤 6:生成 6 位码(首位定字母,D3;issue_code 内部生成并返回明文,HMAC
    # 覆盖写,scene=reset,hash 记发码时归属 user_id,confirm 归属复核用)→ 发送
    code = await issue_code(
        redis,
        scene="reset",
        phone=phone,
        user_id=str(target_id),
        ttl_seconds=settings.sms_code_ttl_seconds,
        secret=settings.session_jwt_secret,
    )
    try:
        biz_id = await sms.send(phone, settings.aliyun_sms_template_reset, code)
    except SmsSendError as e:
        # 步骤 7(D9 统一,同 bind 侧):审计 → 保留冷却键 → 回滚第 3/5 步 → 502
        return await send_failure_502(
            audit,
            redis,
            scene="reset",
            auth_method=None,  # 公开端点显式 NULL(方案 §5.7)
            actor_user_id=target_id,
            ip=ip,
            user_agent=ctx.get("user_agent"),
            phone_masked=phone_masked,
            err_code=e.code,
            err_message=e.message,
            quota_keys=(ip_bucket_key, day_key),
            cooldown_seconds=settings.sms_send_cooldown_seconds,
        )
    except SmsTransportError as e:
        return await send_failure_502(
            audit,
            redis,
            scene="reset",
            auth_method=None,  # 公开端点显式 NULL(方案 §5.7)
            actor_user_id=target_id,
            ip=ip,
            user_agent=ctx.get("user_agent"),
            phone_masked=phone_masked,
            err_code=e.kind,
            err_message=str(e),
            quota_keys=(ip_bucket_key, day_key),
            cooldown_seconds=settings.sms_send_cooldown_seconds,
        )
    # 步骤 8:审计 phone_code_sent(actor=命中用户;details 冗余 user_id)→ 200
    await audit.write(
        event_type="phone_code_sent",
        actor_user_id=target_id,
        request_ip=ip,
        user_agent=ctx.get("user_agent"),
        auth_method=None,  # 公开端点显式 NULL(方案 §5.7)
        details={
            "scene": "reset",
            "phone_masked": phone_masked,
            "biz_id": biz_id,
            "template_code": settings.aliyun_sms_template_reset,
            "user_id": str(target_id),
        },
    )
    return JSONResponse({"retry_after": settings.sms_send_cooldown_seconds})


# ─── POST /api/v1/auth/phone/reset/confirm(方案 §5.4 confirm 步骤 1-6)───────


@router.post("/phone/reset/confirm")
async def reset_confirm(
    body: PhoneResetConfirmIn,
    request: Request,
    db: AsyncSession = Depends(get_db),  # noqa: B008  FastAPI DI,repo 全量同款
    audit: AuditService = Depends(get_audit),  # noqa: B008
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008
) -> JSONResponse:
    settings = get_settings()
    redis = request.app.state.redis
    ip = ctx.get("request_ip") or "unknown"
    sms_guard(request)  # 步骤 1:503 守卫(confirm 不发短信也统一首步守卫,§5.4)
    try:
        phone = normalize_phone(body.phone)
    except InvalidPhone:
        raise HTTPException(400, "手机号格式不正确") from None
    submitted = body.code.strip().upper()  # D3:手输小写/带空格不烧 attempts
    # 步骤 1(续):原子消费式验码 —— 服务端算 digest 传入 Lua,读-比-删一原子;
    # 验码通过即消费,并发双提交只有一次能走到改密(防两个随机密码先后覆盖,§5.4)
    check = await consume_code(
        redis,
        scene="reset",
        phone=phone,
        submitted=submitted,
        secret=settings.session_jwt_secret,
        max_attempts=settings.sms_code_max_attempts,
    )
    if check.status == "expired":
        raise HTTPException(400, "验证码已过期,请重新获取")
    if check.status == "locked":
        # 码作废 429 不带 retry_after(方案 §5.2 分型)
        raise HTTPException(429, "错误次数过多,请重新获取")
    if check.status == "wrong":
        raise HTTPException(400, "验证码错误")
    # 步骤 2:归属复核(phone → active user 未命中,或发码时归属 ≠ 当前归属
    # —— 15 分钟窗口内换绑/二次放号的镜像场景)→ 同一文案,不泄露差异
    user = (
        (await db.execute(select(User).where(User.phone == phone, User.is_active.is_(True)).limit(1)))
        .scalars()
        .first()
    )
    if user is None or str(user.id) != str(check.user_id):
        raise HTTPException(400, "验证码已过期,请重新获取")
    phone_masked = mask_phone(phone)
    # 步骤 3:12 位临时密码(复用 passwords.py 三类保底;只回显一次,不入日志/审计)
    new_password = generate_temp_password(12)
    # 步骤 4:单事务(改密 + must_change_password=true,D2 首登强制再改)+ 吊销
    # 该用户全部 PAT(照 change-password 同款,D8;吊销与改密同事务同次 commit)
    user.password_hash = hash_password(new_password)
    user.must_change_password = True
    revoked_tokens = await revoke_user_tokens(db, user_id=user.id, reason="phone_reset")
    await db.commit()
    # 步骤 5:审计(绝不落密码材料;公开端点显式 auth_method=None,request_ip
    # 走审计独立列)→ commit 后对每个被吊销 PAT 逐令牌写既有 token_revoked
    await audit.write(
        event_type="password_reset_via_phone",
        actor_user_id=user.id,
        request_ip=ip,
        user_agent=ctx.get("user_agent"),
        auth_method=None,
        details={"phone_masked": phone_masked},
    )
    for ref in revoked_tokens:
        await audit.write(
            event_type="token_revoked",
            actor_user_id=user.id,
            request_ip=ip,
            user_agent=ctx.get("user_agent"),
            auth_method=None,
            details={
                "user_id": str(user.id),
                "token_id": str(ref.id),
                "token_prefix": ref.token_prefix,
                "reason": "phone_reset",
                "actor": "self",
            },
        )
    log.info(
        "password reset via phone user_id=%s tokens_revoked=%d",
        user.id,
        len(revoked_tokens),
    )
    # 步骤 6:一次性返回(不存明文、不进日志);no-store 防中间层缓存凭据
    return JSONResponse(
        {
            "username": user.username,
            "email": user.email,
            "name": user.name,
            "new_password": new_password,
        },
        headers={"Cache-Control": "no-store"},
    )
