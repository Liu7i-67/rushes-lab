"""阿里云短信发送服务(手机绑定/短信找回密码,方案 §5.6)。

签名实现**逐行对照**全局技能已实测脚本移植(2026-11-19/20 三运营商真实发送
闭环验证通过),不凭记忆重写;改动前先对照正本:
  C:\\Users\\Administrator\\.agents\\skills\\aliyun-sms-integration\\scripts\\sms_api.py

接口钉子(技能 §3 / 方案 §2.4,违反必踩):
  - HTTP 200 ≠ 业务成功,判定成败只看响应 JSON 的 Code(送达另按技能手工查
    QuerySendDetails,其 SendDate 必须 yyyyMMdd;本服务不做常驻回执)
  - TemplateParam 必须 JSON **串**(dict 值经 serialize_params 自动序列化;
    直接传 dict 会被 isv.SMS_TEMPLATE_ILLEGAL 拒)
  - BizId 实际返回带 `^0` 后缀,调用方落库原样存
  - SendSms **无幂等** → 本服务禁止任何自动重试(D9):超时 ≠ 未受理,
    立即重发可能让用户收到两条码

异常两类(D9;router 层统一 502 文案,分类仅进审计/日志):
  - SmsSendError(code, message):响应体可解析出阿里云 Code 且非 OK = **确定失败**
    (isv.BUSINESS_LIMIT_CONTROL 频控 / isv.AMOUNT_NOT_ENOUGH 余额 / 模板拒 / 凭证错)
  - SmsTransportError:超时 / 连接异常 / 无响应,或 HTTP 响应体无可解析 Code
    (如网关空 502)= **结果未知**,请求可能已被受理

服务实例挂 app.state.sms(main.py lifespan 构造;未配置凭证时为 None,D17),
禁止模块级单例。结构化日志只落 phone 掩码 / Code / BizId / TemplateCode,
AK/SK/验证码明文永不落日志。
"""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import uuid
from datetime import UTC, datetime
from typing import Any
from urllib.parse import quote

import httpx

# 脱敏单一正本(方案 §5.7 全文共用;phone_verification 不 import 本模块,无环)
from app.services.phone_verification import mask_phone
from app.settings import Settings

log = logging.getLogger(__name__)

# RPC 风格端点(POST + query string + 空 body;短信 API 版本固定)
HOST = "dysmsapi.aliyuncs.com"
_ACTION_SEND_SMS = "SendSms"
_API_VERSION = "2017-05-25"


# ─── 签名构造纯函数(tests/test_aliyun_sms.py 直测,零网络)───────────────────


def enc(s: str) -> str:
    """RFC3986 percent-encoding(空格=%20 而非 +;`-_.~` 不编码),UTF-8;中文签名直接编码即可。"""
    return quote(str(s), safe="-_.~")


def serialize_params(params: dict[str, Any]) -> dict[str, str]:
    """dict/list 值序列化为 JSON 串(TemplateParam 等参数的接口要求),其余值转 str。"""
    return {
        k: json.dumps(v, ensure_ascii=False) if isinstance(v, (dict, list)) else str(v)
        for k, v in params.items()
    }


def build_canonical_query(params: dict[str, Any]) -> str:
    """canonical query:序列化后按 key 排序,RFC3986 编码,`k=v` 用 & 连接(技能脚本同款)。"""
    flat = serialize_params(params)
    return "&".join(f"{enc(k)}={enc(v)}" for k, v in sorted(flat.items()))


def build_signed_headers(*, action: str, date: str, nonce: str, payload_hash: str) -> dict[str, str]:
    """x-acs-* 请求头(直接挂到 HTTP 请求;host 由 httpx 按目标 URL 自动携带)。"""
    return {
        "x-acs-action": action,
        "x-acs-version": _API_VERSION,
        "x-acs-date": date,
        "x-acs-signature-nonce": nonce,
        "x-acs-content-sha256": payload_hash,
    }


def build_authorization(
    ak: str,
    sk: str,
    *,
    action: str,
    canonical_query: str,
    date: str,
    nonce: str,
    payload_hash: str,
) -> str:
    """V3 `ACS3-HMAC-SHA256` Authorization 串(逐行对照技能脚本)。

    canonical request 五段(\\n 连接):
      POST / <canonical_query> <排序后 canonical headers(含 host,逐行 \\n 结尾)>
      <signed_headers 分号串> <空 body sha256>
    string-to-sign = ACS3-HMAC-SHA256\\n<sha256(canonical_request)>
    signature      = HMAC-SHA256(SK, string_to_sign) 十六进制
    """
    headers = {
        "host": HOST,
        **build_signed_headers(action=action, date=date, nonce=nonce, payload_hash=payload_hash),
    }
    names = sorted(headers)
    canonical_headers = "".join(f"{n}:{headers[n]}\n" for n in names)
    signed_headers = ";".join(names)

    canonical_request = "\n".join(
        ["POST", "/", canonical_query, canonical_headers, signed_headers, payload_hash]
    )
    string_to_sign = "ACS3-HMAC-SHA256\n" + hashlib.sha256(canonical_request.encode("utf-8")).hexdigest()
    signature = hmac.new(sk.encode("utf-8"), string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
    return f"ACS3-HMAC-SHA256 Credential={ak},SignedHeaders={signed_headers},Signature={signature}"


# ─── 异常(D9 两类)───────────────────────────────────────────────────────────


class SmsSendError(Exception):
    """确定失败:响应体可解析出阿里云 Code 且非 OK(频控/余额/模板拒/凭证错等)。"""

    def __init__(self, code: str, message: str) -> None:
        self.code = code
        self.message = message
        super().__init__(f"{code}: {message}")


class SmsTransportError(Exception):
    """结果未知:超时/连接异常/无响应,或 HTTP 响应体无可解析 Code(请求可能已被受理)。

    message 只含本地异常类型名 / HTTP 状态摘要,不含请求 URL —— SendSms 的 URL
    query 串内含验证码材料,原文不落日志/审计(原始异常经 __cause__ 保留)。

    kind(B2 router 侧扩展,审计 sms_send_failed 的 err_code 哨兵,方案 §5.7;
    transport 类无阿里云原文,err_code 落此哨兵值、err_message 落 message 摘要):
      - "transport_timeout":本地超时 / 连接类失败(请求可能已受理的最强信号)
      - "transport_unparseable"(默认):响应不可解析 / 无可解析 Code 等其余结果未知
    """

    def __init__(self, message: str, *, kind: str = "transport_unparseable") -> None:
        self.kind = kind
        super().__init__(message)


class AliyunSmsService:
    """阿里云 SendSms 发送(httpx.AsyncClient 挂实例内;SendSms 无幂等,零自动重试)。"""

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        # httpx 库自身会在 INFO 级打「HTTP Request: POST <完整 URL>」—— SendSms 的
        # query 串内含 TemplateParam(验证码材料),压到 WARNING 只吞 INFO 请求行
        # (WARNING+ 的传输错误照常出),验证码明文才真正不落日志
        logging.getLogger("httpx").setLevel(logging.WARNING)
        # timeout connect/read 各 5s(write/pool 同 5s;SendSms 正常响应 1s 量级)
        self._http = httpx.AsyncClient(timeout=httpx.Timeout(5.0, connect=5.0))

    async def aclose(self) -> None:
        """释放底层连接池(main.py lifespan shutdown 调;None 守卫在调用侧)。"""
        await self._http.aclose()

    async def send(self, phone: str, template_code: str, code: str) -> str:
        """发送验证码短信,成功返回 BizId(带 `^0` 后缀,调用方原样落库)。

        失败抛 SmsSendError(确定失败)/ SmsTransportError(结果未知);
        **不重试**(SendSms 无幂等,重发可能双条短信;重试节奏由 B2 冷却键管)。
        """
        action = _ACTION_SEND_SMS
        # query 串只含业务参数(技能脚本实测口径):Action/Version 只走
        # x-acs-action / x-acs-version 头,勿凭通用 RPC 文档记忆塞进 query
        params: dict[str, Any] = {
            "PhoneNumbers": phone,
            "SignName": self._settings.aliyun_sms_sign_name or "",
            "TemplateCode": template_code,
            # 接口要求 JSON 串(dict 值由 build_canonical_query 自动序列化)
            "TemplateParam": {"code": code},
        }
        canonical_query = build_canonical_query(params)
        # ISO8601 UTC(技能脚本 datetime.now(timezone.utc) 的 UP017 等价别名)
        date = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
        nonce = uuid.uuid4().hex
        payload_hash = hashlib.sha256(b"").hexdigest()
        headers = {
            **build_signed_headers(
                action=action,
                date=date,
                nonce=nonce,
                payload_hash=payload_hash,
            ),
            "Authorization": build_authorization(
                self._settings.aliyun_sms_ak or "",
                self._settings.aliyun_sms_sk or "",
                action=action,
                canonical_query=canonical_query,
                date=date,
                nonce=nonce,
                payload_hash=payload_hash,
            ),
            "Accept": "application/json",
        }
        # canonical query 直接拼进 URL:线上 wire 串 = 签名串,服务端 canonicalization 必然一致
        url = f"https://{HOST}/?{canonical_query}"

        log.info(
            "sms send: phone=%s template=%s action=%s",
            mask_phone(phone),
            template_code,
            action,
        )
        try:
            resp = await self._http.post(url, headers=headers, content=b"")
            body: Any = resp.json()  # 读流+解码一并纳入:中断/坏 JSON 都归「结果未知」
        except (httpx.HTTPError, ValueError) as e:
            # 摘要只落类型名(URL 含验证码材料,异常原文不落日志/审计)
            summary = f"{type(e).__name__}(未收到/未能解析阿里云响应,结果未知)"
            log.warning("sms send transport failure: phone=%s err=%s", mask_phone(phone), summary)
            # kind 哨兵(方案 §5.7):超时/连接类 → transport_timeout(请求可能
            # 已受理的最强信号);其余(坏 JSON / 中断等)→ 默认 unparseable
            kind = (
                "transport_timeout"
                if isinstance(e, (httpx.TimeoutException, httpx.ConnectError))
                else "transport_unparseable"
            )
            raise SmsTransportError(summary, kind=kind) from e

        # HTTP 200 ≠ 业务成功:判定成败只看响应 JSON 的 Code(技能钉子)
        if not isinstance(body, dict) or "Code" not in body:
            # 无可解析 Code(如网关空 502 / HTML 错误页)= 结果未知
            summary = f"HTTP {resp.status_code}(响应体无可解析 Code,结果未知)"
            log.warning("sms send unparseable response: phone=%s %s", mask_phone(phone), summary)
            raise SmsTransportError(summary) from None
        resp_code = str(body["Code"])

        if resp_code != "OK":
            message = str(body.get("Message", ""))
            log.warning(
                "sms send rejected: phone=%s template=%s code=%s message=%s",
                mask_phone(phone),
                template_code,
                resp_code,
                message,
            )
            raise SmsSendError(resp_code, message)

        biz_id = str(body.get("BizId") or "")
        log.info(
            "sms send accepted: phone=%s template=%s code=OK biz_id=%s",
            mask_phone(phone),
            template_code,
            biz_id,
        )
        return biz_id
