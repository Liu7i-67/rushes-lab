"""账号安全 router — 手机号绑定/换绑两端点(手机绑定/短信找回密码方案 §5.3)。

endpoints(登录态;require_session_auth = PAT 一律 403,方案 D18,与 change-password
同口径;main.py 以 /api/v1/account 前缀挂载):
  POST /api/v1/account/phone/send-code → 发绑定验证码 → 200 {retry_after}
  POST /api/v1/account/phone/bind      → 验证码通过后写 users.phone → 200 {phone}

钉子:
  - 步骤顺序钉死方案 §5.3(send-code 1-9 / bind 1-5),不得调序
  - 强制改密用户被既有 403 白名单机制拦下(deps._FORCED_CHANGE_OK_ROUTES 不含
    本 router 路由名,方案钉子 8,设计内:先改密再绑号)
  - 不吊销 PAT、不动 session(D16);换绑即覆盖旧值(D16,短信只发新号)
  - 冷却键通用原则(D9):未走到「调阿里云发送」的拒绝路径一律 DEL 冷却键;
    发送失败一律保留冷却键并回滚本次新增配额计数
  - 审计(方案 §5.7):本 router 登录态,write() 默认推导即 session,
    不传 auth_method(password_reset.py 公开端点侧才显式传 None)
"""

from __future__ import annotations

import logging
from datetime import UTC, datetime

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.session import get_db
from app.db.tables import User
from app.deps import (
    CurrentUser,
    get_audit,
    get_request_context,
    require_session_auth,
)
from app.services.aliyun_sms import SmsSendError, SmsTransportError
from app.services.audit import AuditService
from app.services.phone_verification import (
    InvalidPhone,
    acquire_cooldown,
    cooldown_key,
    daily_key,
    delete_code,
    hourly_user_key,
    incr_daily,
    incr_hourly,
    issue_code,
    mask_phone,
    normalize_phone,
    read_code,
    rollback_quota,
    verify_code,
)
from app.services.sms_flow import send_failure_502, sms_guard
from app.settings import get_settings

log = logging.getLogger(__name__)
router = APIRouter()


# ─── 入参(服务端统一 D5 归一化,先宽后严)────────────────────────────────────


class PhoneCodeSendIn(BaseModel):
    """发送绑定验证码入参;手机号格式校验在 normalize_phone(格式错 400)。"""

    phone: str = Field(..., min_length=1, max_length=32)


class PhoneBindIn(BaseModel):
    """绑定/换绑入参;code 服务端统一 strip().upper() 再比对(D3 字母表全大写)。"""

    phone: str = Field(..., min_length=1, max_length=32)
    code: str = Field(..., min_length=1, max_length=16)


# ─── POST /api/v1/account/phone/send-code(方案 §5.3 send-code 步骤 1-9)──────


@router.post("/phone/send-code")
async def send_bind_code(
    body: PhoneCodeSendIn,
    request: Request,
    cur: CurrentUser = Depends(require_session_auth),  # noqa: B008  FastAPI DI,repo 全量同款
    db: AsyncSession = Depends(get_db),  # noqa: B008
    audit: AuditService = Depends(get_audit),  # noqa: B008
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008
) -> JSONResponse:
    settings = get_settings()
    redis = request.app.state.redis
    ip = ctx.get("request_ip") or "unknown"
    sms = sms_guard(request)  # 步骤 1:503 守卫
    # 步骤 2:规范化 + 格式校验(D5);纯格式错不消耗任何计数
    try:
        phone = normalize_phone(body.phone)
    except InvalidPhone:
        raise HTTPException(400, "手机号格式不正确") from None
    phone_masked = mask_phone(phone)
    # 步骤 3:同号同场景冷却(SET NX 抢占;未抢到 → 429 带剩余秒,PTTL 上取整)
    remaining = await acquire_cooldown(
        redis,
        scene="bind",
        phone=phone,
        cooldown_seconds=settings.sms_send_cooldown_seconds,
    )
    if remaining is not None:
        return JSONResponse(
            status_code=429,
            content={"detail": "发送过于频繁,请稍后再试", "retry_after": remaining},
        )
    now = datetime.now(UTC)
    cooldown_key_str = cooldown_key(scene="bind", phone=phone)
    # 步骤 4:每用户每小时配额(**先于占用预检**:409 探测同样消耗探测者小时配额,
    # 登录态枚举「该号是否已绑定」被 10/h 兜住,方案 §5.3/§8.1)
    bucket_key = hourly_user_key(user_id=str(cur.id), now=now)
    hourly_count = await incr_hourly(redis, bucket_key)
    if hourly_count > settings.sms_bind_user_hourly:
        await redis.delete(cooldown_key_str)
        return JSONResponse(
            status_code=429,
            content={
                "detail": "发送过于频繁,请稍后再试",
                "retry_after": settings.sms_send_cooldown_seconds,
            },
        )
    # 步骤 5:占用预检(不过滤 is_active,§8.5 已接受面);命中 → 409 + DEL 冷却键
    # (未产生发送不占冷却,D9 通用原则;不回滚第 4 步小时计数)
    occupied_id = (
        await db.execute(select(User.id).where(User.phone == phone, User.id != cur.id).limit(1))
    ).scalar_one_or_none()
    if occupied_id is not None:
        await redis.delete(cooldown_key_str)
        raise HTTPException(409, "该手机号已绑定其他账号")
    # 步骤 6:每号每日配额(**后置于占用预检**:探测已占用号不会烧目标号日配额);
    # 超 → 429 + DEL 冷却键 + 回滚本次日计数
    day_key = daily_key(scene="bind", phone=phone, now=now)
    daily_count = await incr_daily(redis, scene="bind", phone=phone, now=now)
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
    # 步骤 7:生成 6 位码(首位定字母,D3;issue_code 内部生成并返回明文,HMAC
    # 覆盖写,旧码自然失效,user_id 记发码时归属,bind 侧归属复核用)→ 发送
    code = await issue_code(
        redis,
        scene="bind",
        phone=phone,
        user_id=str(cur.id),
        ttl_seconds=settings.sms_code_ttl_seconds,
        secret=settings.session_jwt_secret,
    )
    try:
        biz_id = await sms.send(phone, settings.aliyun_sms_template_bind, code)
    except SmsSendError as e:
        # 步骤 8(D9 统一):审计 → 保留冷却键 → 回滚第 4/6 步计数 → 502
        return await send_failure_502(
            audit,
            redis,
            scene="bind",
            actor_user_id=cur.id,
            ip=ip,
            user_agent=ctx.get("user_agent"),
            phone_masked=phone_masked,
            err_code=e.code,
            err_message=e.message,
            quota_keys=(bucket_key, day_key),
            cooldown_seconds=settings.sms_send_cooldown_seconds,
        )
    except SmsTransportError as e:
        return await send_failure_502(
            audit,
            redis,
            scene="bind",
            actor_user_id=cur.id,
            ip=ip,
            user_agent=ctx.get("user_agent"),
            phone_masked=phone_masked,
            err_code=e.kind,
            err_message=str(e),
            quota_keys=(bucket_key, day_key),
            cooldown_seconds=settings.sms_send_cooldown_seconds,
        )
    # 步骤 9:审计 phone_code_sent → 200(retry_after=冷却配置值,前端倒计时初值)
    await audit.write(
        event_type="phone_code_sent",
        actor_user_id=cur.id,
        request_ip=ip,
        user_agent=ctx.get("user_agent"),
        details={
            "scene": "bind",
            "phone_masked": phone_masked,
            "biz_id": biz_id,
            "template_code": settings.aliyun_sms_template_bind,
        },
    )
    return JSONResponse({"retry_after": settings.sms_send_cooldown_seconds})


# ─── POST /api/v1/account/phone/bind(方案 §5.3 bind 步骤 1-5)────────────────


@router.post("/phone/bind")
async def bind_phone(
    body: PhoneBindIn,
    request: Request,
    cur: CurrentUser = Depends(require_session_auth),  # noqa: B008  FastAPI DI,repo 全量同款
    db: AsyncSession = Depends(get_db),  # noqa: B008
    audit: AuditService = Depends(get_audit),  # noqa: B008
    ctx: dict[str, str | None] = Depends(get_request_context),  # noqa: B008
) -> JSONResponse:
    settings = get_settings()
    redis = request.app.state.redis
    ip = ctx.get("request_ip") or "unknown"
    sms_guard(request)  # 步骤 1:503 守卫(bind 不发短信也统一首步守卫,§5.3)
    try:
        phone = normalize_phone(body.phone)
    except InvalidPhone:
        raise HTTPException(400, "手机号格式不正确") from None
    phone_masked = mask_phone(phone)
    submitted = body.code.strip().upper()  # D3:手输小写/带空格不烧 attempts
    # 步骤 1(续):取码 hash;缺失或归属非当前用户(发码与提交之间换账号登录的
    # 边角)→ 同一文案,不泄露差异
    stored = await read_code(redis, scene="bind", phone=phone)
    if stored is None or stored.get("user_id") != str(cur.id):
        raise HTTPException(400, "验证码已过期,请重新获取")
    # 步骤 2:比对 + 原子尝试计数(Lua 单脚本 EXISTS+HINCRBY+条件 EXPIRE,§5.5);
    # ok 不删码键 —— 写库成功后才消费(重放窗口内二次提交同值幂等,§5.3)
    check = await verify_code(
        redis,
        scene="bind",
        phone=phone,
        submitted=submitted,
        secret=settings.session_jwt_secret,
        max_attempts=settings.sms_code_max_attempts,
    )
    if check.status == "expired":
        raise HTTPException(400, "验证码已过期,请重新获取")
    if check.status == "locked":
        # 码作废 429 不带 retry_after(须重新发码、受冷却管,方案 §5.2 分型)
        raise HTTPException(429, "错误次数过多,请重新获取")
    if check.status == "wrong":
        raise HTTPException(400, "验证码错误")
    # 步骤 3:单事务写库;并发窗口由 uq_users_phone 唯一约束兜底 → 409
    user = await db.get(User, cur.id)
    if user is None:
        raise HTTPException(401, "session user not found")
    old_masked = mask_phone(user.phone) if user.phone else None
    user.phone = phone
    try:
        await db.commit()
    except IntegrityError:
        await db.rollback()
        raise HTTPException(409, "该手机号已绑定其他账号") from None
    await delete_code(redis, scene="bind", phone=phone)  # 写库成功后消费码键(§5.3)
    # 步骤 4:审计 phone_bound(old/new 前 3 + **** + 后 4;首次绑定 old 为 null)
    await audit.write(
        event_type="phone_bound",
        actor_user_id=cur.id,
        request_ip=ip,
        user_agent=ctx.get("user_agent"),
        details={"old_masked": old_masked, "new_masked": phone_masked},
    )
    log.info(
        "phone bound user_id=%s old=%s new=%s",
        cur.id,
        old_masked,
        phone_masked,
    )
    # 步骤 5:换绑即覆盖(D16);不吊销 PAT、不动 session(D16)
    return JSONResponse({"phone": phone})
