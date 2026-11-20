"""阿里云短信服务单元测试 — 纯单元零网络(httpx.MockTransport 假传输)。

覆盖(方案 §5.6;签名构造逐行对照全局技能实测脚本移植的回归防线):
  - 纯函数:RFC3986 编码 / canonical query 按 key 排序 / TemplateParam JSON 串 /
    x-acs-* 头构造 / Authorization 串格式与确定性
  - send() 请求构造(wire query 串 = 签名 canonical 串;TemplateParam 落线为 JSON 串)
  - 两类异常分类(D9):Code 可解析且非 OK → SmsSendError(确定失败,含
    isv.AMOUNT_NOT_ENOUGH 用例);HTTP 502 空体 / JSON 无 Code / 超时 / 连接异常
    → SmsTransportError(结果未知)
  - 铁律:AK/SK/验证码明文/完整手机号永不落日志(caplog 全量断言)
真实发送与送达回执(QuerySendDetails)在 dev 部署后按技能手工验证,不在单测。
"""

from __future__ import annotations

import contextlib
import hashlib
import hmac
import json
import logging
from typing import Any

import httpx
import pytest

from app.services.aliyun_sms import (
    HOST,
    AliyunSmsService,
    SmsSendError,
    SmsTransportError,
    build_authorization,
    build_canonical_query,
    build_signed_headers,
    enc,
    serialize_params,
)
from app.settings import Settings

PHONE = "13800138000"
CODE = "A3B9XZ"  # 字母数字组合(D3 口径,含字母)
TEMPLATE = "SMS_512538915"
SIGN_NAME = "成都讨喜未来文化传媒"


# ─── helpers ─────────────────────────────────────────────────────────────────
def make_settings(**overrides: Any) -> Settings:
    base: dict[str, Any] = dict(
        db_url="postgresql+asyncpg://u:p@localhost:5432/x",
        redis_url="redis://localhost:6379/0",
        minio_endpoint_internal="http://minio:9000",
        minio_endpoint_public="http://localhost:9000",
        minio_access_key="minio-ak",
        minio_secret_key="minio-sk",
        openfga_api_url="http://localhost:8080",
        openfga_store_id="store",
        web_app_base_url="http://localhost/ms-static/web/",
        session_jwt_secret="x" * 32,
        aliyun_sms_ak="test-ak",
        aliyun_sms_sk="test-sk",
        aliyun_sms_sign_name=SIGN_NAME,
    )
    base.update(overrides)
    return Settings(**base)


def make_service(handler: Any) -> AliyunSmsService:
    """MockTransport 注入的服务实例(零真实网络;用毕 aclose)。"""
    service = AliyunSmsService(make_settings())
    # 单测注入假传输(替换 __init__ 里的真 client;AC 原实例未建连,GC 回收即可)
    service._http = httpx.AsyncClient(
        transport=httpx.MockTransport(handler), timeout=httpx.Timeout(5.0, connect=5.0)
    )
    return service


# ─── 纯函数:签名构造 ─────────────────────────────────────────────────────────


def test_enc_rfc3986() -> None:
    """空格=%20(不是 +);`-_.~` 不编码;保留字符与中文按 UTF-8 百分号编码。"""
    assert enc("a b") == "a%20b"
    assert enc("a-b.c_d~e") == "a-b.c_d~e"
    assert enc("a&b=c?d/e") == "a%26b%3Dc%3Fd%2Fe"
    assert enc("+86") == "%2B86"
    assert enc("成都") == "%E6%88%90%E9%83%BD"


def test_serialize_params_template_param_json_string() -> None:
    """接口钉子:TemplateParam 必须是 JSON **串**(dict 直接传会被拒)。"""
    flat = serialize_params({"TemplateParam": {"code": "AB3"}, "PageSize": 10})
    assert flat["TemplateParam"] == '{"code": "AB3"}'
    assert flat["PageSize"] == "10"
    # ensure_ascii=False:中文不转 \\uXXXX 转义(与技能脚本一致)
    assert serialize_params({"k": {"名": "值"}})["k"] == '{"名": "值"}'


def test_build_canonical_query_sorted_and_encoded() -> None:
    """输入乱序,输出仍按 key 排序 + RFC3986 编码后 & 连接(技能脚本同款)。"""
    q = build_canonical_query(
        {
            "TemplateParam": {"code": "AB3"},
            "Version": "2017-05-25",
            "Action": "SendSms",
            "SignName": "签名 X",
            "PhoneNumbers": "+8613800138000",
        }
    )
    assert q == (
        "Action=SendSms"
        "&PhoneNumbers=%2B8613800138000"
        "&SignName=%E7%AD%BE%E5%90%8D%20X"
        "&TemplateParam=%7B%22code%22%3A%20%22AB3%22%7D"
        "&Version=2017-05-25"
    )


def test_build_signed_headers_exact_fields() -> None:
    headers = build_signed_headers(
        action="SendSms",
        date="2026-11-20T00:00:00Z",
        nonce="nonce-1",
        payload_hash=hashlib.sha256(b"").hexdigest(),
    )
    assert headers == {
        "x-acs-action": "SendSms",
        "x-acs-version": "2017-05-25",
        "x-acs-date": "2026-11-20T00:00:00Z",
        "x-acs-signature-nonce": "nonce-1",
        "x-acs-content-sha256": hashlib.sha256(b"").hexdigest(),
    }


def test_build_authorization_format_and_determinism() -> None:
    kw: dict[str, Any] = dict(
        action="SendSms",
        canonical_query="Action=SendSms&Version=2017-05-25",
        date="2026-11-20T00:00:00Z",
        nonce="nonce-1",
        payload_hash=hashlib.sha256(b"").hexdigest(),
    )
    auth = build_authorization("AKTEST", "SKTEST", **kw)
    prefix = (
        "ACS3-HMAC-SHA256 Credential=AKTEST,"
        "SignedHeaders=host;x-acs-action;x-acs-content-sha256;x-acs-date;"
        "x-acs-signature-nonce;x-acs-version,Signature="
    )
    assert auth.startswith(prefix)
    signature = auth[len(prefix) :]
    assert len(signature) == 64 and all(c in "0123456789abcdef" for c in signature)
    # 确定性:同输入同签名;SK / action 任一变化签名必变
    assert auth == build_authorization("AKTEST", "SKTEST", **kw)
    assert auth != build_authorization("AKTEST", "SKOTHER", **kw)
    assert auth != build_authorization("AKTEST", "SKTEST", **{**kw, "action": "QuerySendDetails"})


def test_build_authorization_matches_skill_script_formula() -> None:
    """独立按技能脚本公式复算一遍签名(捕获移植笔误;技能脚本为唯一权威正本)。"""
    ak, sk = "AKTEST", "SKTEST"
    canonical_query = "Action=SendSms&Version=2017-05-25"
    date, nonce = "2026-11-20T00:00:00Z", "nonce-1"
    payload_hash = hashlib.sha256(b"").hexdigest()
    headers = {
        "host": HOST,
        "x-acs-action": "SendSms",
        "x-acs-version": "2017-05-25",
        "x-acs-date": date,
        "x-acs-signature-nonce": nonce,
        "x-acs-content-sha256": payload_hash,
    }
    names = sorted(headers)
    canonical_headers = "".join(f"{n}:{headers[n]}\n" for n in names)
    canonical_request = "\n".join(
        ["POST", "/", canonical_query, canonical_headers, ";".join(names), payload_hash]
    )
    string_to_sign = "ACS3-HMAC-SHA256\n" + hashlib.sha256(canonical_request.encode("utf-8")).hexdigest()
    expected = hmac.new(sk.encode("utf-8"), string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
    auth = build_authorization(
        ak,
        sk,
        action="SendSms",
        canonical_query=canonical_query,
        date=date,
        nonce=nonce,
        payload_hash=payload_hash,
    )
    assert auth.endswith(f"Signature={expected}")


# ─── send():请求构造(MockTransport 捕获真实出线请求)────────────────────────


async def test_send_request_construction() -> None:
    captured: dict[str, Any] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["method"] = request.method
        captured["host"] = request.url.host
        captured["path"] = request.url.path
        captured["raw_query"] = request.url.query.decode("ascii")
        captured["params"] = dict(request.url.params)
        captured["headers"] = dict(request.headers)
        captured["body"] = request.read()
        return httpx.Response(200, json={"Code": "OK", "BizId": "744611395060321845^0"})

    service = make_service(handler)
    try:
        biz_id = await service.send(PHONE, TEMPLATE, CODE)
    finally:
        await service.aclose()

    assert biz_id == "744611395060321845^0"  # BizId 带 ^0 后缀原样返回(技能钉子)
    assert captured["method"] == "POST"  # RPC 风格:POST + query string + 空 body
    assert captured["host"] == HOST
    assert captured["path"] == "/"
    assert captured["body"] == b""
    # query 串只含业务参数(技能脚本实测口径):Action/Version 不进 query,只走头
    params = captured["params"]
    assert params == {
        "PhoneNumbers": PHONE,
        "SignName": SIGN_NAME,
        "TemplateCode": TEMPLATE,
        # TemplateParam 落线必须是 JSON 串
        "TemplateParam": json.dumps({"code": CODE}, ensure_ascii=False),
    }
    headers = captured["headers"]
    assert headers["x-acs-action"] == "SendSms"
    assert headers["x-acs-version"] == "2017-05-25"
    assert headers["x-acs-content-sha256"] == hashlib.sha256(b"").hexdigest()
    assert headers["authorization"].startswith("ACS3-HMAC-SHA256 Credential=test-ak,")
    # wire query 串 = 签名 canonical 串(key 排序 + RFC3986),服务端校签必然一致
    canonical = build_canonical_query(
        {
            "PhoneNumbers": PHONE,
            "SignName": SIGN_NAME,
            "TemplateCode": TEMPLATE,
            "TemplateParam": {"code": CODE},
        }
    )
    assert captured["raw_query"] == canonical


# ─── send():两类异常分类(D9)────────────────────────────────────────────────


async def test_send_business_error_raises_sms_send_error() -> None:
    """Code 可解析且非 OK = 确定失败(余额不足;HTTP 400 同样按 Code 判定)。"""

    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(400, json={"Code": "isv.AMOUNT_NOT_ENOUGH", "Message": "余额不足"})

    service = make_service(handler)
    try:
        with pytest.raises(SmsSendError) as exc_info:
            await service.send(PHONE, TEMPLATE, CODE)
    finally:
        await service.aclose()
    assert exc_info.value.code == "isv.AMOUNT_NOT_ENOUGH"
    assert exc_info.value.message == "余额不足"


async def test_send_http_502_empty_body_raises_transport_error() -> None:
    """网关空 502:无可解析 Code = 结果未知(请求可能已被受理,禁止自动重试)。"""

    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(502)

    service = make_service(handler)
    try:
        with pytest.raises(SmsTransportError):
            await service.send(PHONE, TEMPLATE, CODE)
    finally:
        await service.aclose()


async def test_send_json_without_code_raises_transport_error() -> None:
    """HTTP 200 但 JSON 无 Code 字段(非阿里云直返)= 结果未知。"""

    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"Message": "gateway proxy response"})

    service = make_service(handler)
    try:
        with pytest.raises(SmsTransportError) as exc_info:
            await service.send(PHONE, TEMPLATE, CODE)
    finally:
        await service.aclose()
    assert "HTTP 200" in str(exc_info.value)


async def test_send_timeout_and_connect_error_raise_transport_error() -> None:
    """本地超时 / 连接异常 = 结果未知;异常串不含 URL(内含验证码材料)。"""

    async def run(handler: Any) -> str:
        service = make_service(handler)
        try:
            with pytest.raises(SmsTransportError) as exc_info:
                await service.send(PHONE, TEMPLATE, CODE)
        finally:
            await service.aclose()
        return str(exc_info.value)

    def timeout_handler(_request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectTimeout("timed out")

    def connect_handler(_request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused")

    msg_timeout = await run(timeout_handler)
    msg_connect = await run(connect_handler)
    assert "ConnectTimeout" in msg_timeout
    assert "ConnectError" in msg_connect
    # URL 的 query 串内含验证码材料:异常摘要不得携带 URL
    assert "https://" not in msg_timeout and "https://" not in msg_connect


async def test_transport_error_kind_sentinel() -> None:
    """kind 哨兵(2026-11-20 手机绑定方案 §5.7):审计 sms_send_failed 的 err_code 用。

    超时/连接类 → "transport_timeout";HTTP 响应无可解析 Code → 默认
    "transport_unparseable"(transport 类无阿里云原文,err_code 落哨兵值)。
    """

    def timeout_handler(_request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectTimeout("timed out")

    def unparseable_handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(502)

    service = make_service(timeout_handler)
    try:
        with pytest.raises(SmsTransportError) as exc_info:
            await service.send(PHONE, TEMPLATE, CODE)
    finally:
        await service.aclose()
    assert exc_info.value.kind == "transport_timeout"

    service = make_service(unparseable_handler)
    try:
        with pytest.raises(SmsTransportError) as exc_info:
            await service.send(PHONE, TEMPLATE, CODE)
    finally:
        await service.aclose()
    assert exc_info.value.kind == "transport_unparseable"


async def test_send_never_logs_secrets_or_plain_code(caplog: pytest.LogCaptureFixture) -> None:
    """铁律:AK/SK/验证码明文/完整手机号永不落日志(成功/业务失败/传输失败三路全查)。"""

    def ok_handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"Code": "OK", "BizId": "biz^0"})

    def fail_handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(400, json={"Code": "isv.BUSINESS_LIMIT_CONTROL", "Message": "触发频控"})

    def timeout_handler(_request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("timed out")

    with caplog.at_level(logging.DEBUG):
        for handler in (ok_handler, fail_handler, timeout_handler):
            service = make_service(handler)
            try:
                with contextlib.suppress(SmsSendError, SmsTransportError):
                    await service.send(PHONE, TEMPLATE, CODE)
            finally:
                await service.aclose()

    text = caplog.text
    assert CODE not in text, "验证码明文落入日志"
    assert "test-ak" not in text and "test-sk" not in text, "AK/SK 落入日志"
    assert "13800138000" not in text, "完整手机号落入日志"
    assert "138****8000" in text, "phone 必须以掩码出现"
    # httpx 库自身 INFO 级「HTTP Request: POST <完整 URL>」已压掉(服务 __init__ 内)
    assert "HTTP Request" not in text
