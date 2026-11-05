"""mailer 单测(方案 §5.6.1 / §10.1「邮件」段)— Fake SMTP + monkeypatch,不连真 SMTP。

覆盖:
- From/To 经 email.headerregistry.Address 构造(显示名 / 中文主题 / 头注入面)
- send_mail 自校验收件人与 SMTP_FROM_EMAIL(`, ; < > " / 空白 / 控制字符 → definite=True)
- TLS / SSL / login 三分支(自 notifications._smtp_send_sync 迁移;socket timeout 从 settings 传入)
- 「确定失败」vs「结果未知」:连接拒绝 / 连接超时 / 认证失败 / RCPT 拒收 →
  definite=True;DATA 阶段断开 / 外层 wait_for 总预算超时 → definite=False
- 外层总预算默认取 settings.smtp_total_timeout_seconds
- Message-ID / Date 头显式补齐(Gmail 550-5.7.1):域名 = from 域名,无 @ 回退 localhost
- 日志只出现 mask_email 脱敏收件人
- email_utils 基础部分:normalize_email / mask_email / is_header_safe_addr
"""

from __future__ import annotations

import email.utils
import logging
import re
import smtplib
import time
from typing import Any, ClassVar

import pytest

from app.services import mailer
from app.services.email_utils import (
    is_header_safe_addr,
    mask_email,
    normalize_email,
)
from app.services.mailer import MailSendError, send_mail
from app.settings import Settings


# ─── helpers ──────────────────────────────────────────────────────────────────
def mk_settings(**overrides: Any) -> Settings:
    base: dict[str, Any] = {
        "env": "test",
        "db_url": "postgresql+asyncpg://u:p@localhost/db",
        "redis_url": "redis://localhost:6379/0",
        "minio_endpoint_internal": "http://minio:9000",
        "minio_endpoint_public": "http://localhost:9000",
        "minio_access_key": "k",
        "minio_secret_key": "s",
        "openfga_api_url": "http://openfga:8080",
        "openfga_store_id": "01TEST",
        "web_app_base_url": "http://localhost/ms-static/web/",
        "session_jwt_secret": "test-secret",
        "smtp_host": "smtp.example.com",
        "smtp_port": 587,
        "smtp_from_email": "noreply@example.com",
    }
    base.update(overrides)
    return Settings(**base)  # type: ignore[arg-type]


class _Shared:
    """Fake SMTP 的共享记录袋;reset(**inject) 可注入阶段异常。"""

    calls: ClassVar[dict[str, Any]] = {}

    @classmethod
    def reset(cls, **inject: Any) -> dict[str, Any]:
        cls.calls = dict(inject)
        return cls.calls


class FakeSMTP:
    """记录 ctor/starttls/login/send_message;按 inject 键在对应阶段抛异常。"""

    def __init__(self, host: str, port: int, timeout: float | None = None) -> None:
        _Shared.calls["ctor"] = (host, port, timeout)
        _Shared.calls["class"] = type(self).__name__
        exc = _Shared.calls.get("ctor_exc")
        if exc is not None:
            raise exc

    def __enter__(self) -> FakeSMTP:
        return self

    def __exit__(self, *a: object) -> bool:
        return False

    def starttls(self) -> None:
        _Shared.calls["starttls"] = True

    def login(self, u: str, p: str) -> None:
        _Shared.calls["login"] = (u, p)
        exc = _Shared.calls.get("login_exc")
        if exc is not None:
            raise exc

    def send_message(self, msg: Any) -> None:
        _Shared.calls["msg"] = msg
        exc = _Shared.calls.get("send_exc")
        if exc is not None:
            raise exc


class FakeSMTPSSL(FakeSMTP):
    pass


@pytest.fixture()
def smtp_calls(monkeypatch: pytest.MonkeyPatch) -> dict[str, Any]:
    """装上 Fake SMTP 并清空记录;返回 calls 供断言。"""
    _Shared.reset()
    monkeypatch.setattr(smtplib, "SMTP", FakeSMTP)
    monkeypatch.setattr(smtplib, "SMTP_SSL", FakeSMTPSSL)
    return _Shared.calls


# ─── 头构造:Address / 中文主题 ───────────────────────────────────────────────
async def test_headers_via_address_with_display_name(smtp_calls: dict[str, Any]) -> None:
    settings = mk_settings(smtp_from_name="素材库", smtp_username="u", smtp_password="p")
    await send_mail(
        settings, to="alice@example.com", subject="【素材库】邮箱验证码", body="你的验证码是 123456"
    )
    msg = smtp_calls["msg"]
    assert str(msg["From"]) == "素材库 <noreply@example.com>"
    assert str(msg["To"]) == "alice@example.com"
    assert str(msg["Subject"]) == "【素材库】邮箱验证码"
    assert "123456" in msg.get_content()


async def test_headers_empty_display_name_uses_plain_addr(smtp_calls: dict[str, Any]) -> None:
    """smtp_from_name 未配置 → display_name 传空串(传 None 会 TypeError,§5.6.1)。"""
    await send_mail(mk_settings(), to="alice@example.com", subject="s", body="b")
    assert str(smtp_calls["msg"]["From"]) == "noreply@example.com"


# ─── Message-ID / Date 头(Gmail 550-5.7.1 修复)──────────────────────────────
async def test_message_id_and_date_headers_present(smtp_calls: dict[str, Any]) -> None:
    """发出的消息必须自带合法 Message-ID(域名 = from 域名)与 Date 头。

    P0 实锤:EmailMessage / smtplib.send_message / QQ 企业邮中继都不会自动补,
    Gmail 对缺 Message-ID 的邮件直接 550-5.7.1 拒收(RFC 5322)。
    """
    settings = mk_settings(smtp_from_email="noreply@taoxiplan.com")
    await send_mail(settings, to="alice@gmail.com", subject="s", body="b")
    msg = smtp_calls["msg"]

    # Message-ID 形如 <...@taoxiplan.com>:尖括号包裹、无空白、域名 = from 域名
    msg_id = str(msg["Message-ID"])
    assert re.fullmatch(r"<[^<>\s]+@taoxiplan\.com>", msg_id) is not None, msg_id

    # Date 存在且可按 RFC 5322 解析
    date_hdr = msg["Date"]
    assert date_hdr is not None
    assert email.utils.parsedate_to_datetime(str(date_hdr)) is not None


def test_from_domain_fallback_localhost() -> None:
    """from 地址无 @ / 空 domain → Message-ID 域名回退 localhost(防御分支)。"""
    assert mailer._from_domain(mk_settings(smtp_from_email="noreply@taoxiplan.com")) == "taoxiplan.com"
    assert mailer._from_domain(mk_settings(smtp_from_email="no-at-sign")) == "localhost"
    assert mailer._from_domain(mk_settings(smtp_from_email=None)) == "localhost"


# ─── 收件人 / 发件人安全校验(不信任调用方)───────────────────────────────────
async def test_unsafe_recipient_rejected_definite_without_smtp(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def _boom(*a: object, **kw: object) -> None:
        raise AssertionError("SMTP must not be touched for unsafe recipient")

    monkeypatch.setattr(smtplib, "SMTP", _boom)  # type: ignore[arg-type]
    monkeypatch.setattr(smtplib, "SMTP_SSL", _boom)  # type: ignore[arg-type]
    settings = mk_settings()
    unsafe = [
        "a,b@example.com",
        "a;b@example.com",
        "a<b@example.com",
        'a"b@example.com',
        "a b@example.com",
        "a\tb@example.com",
        "a\nBcc: x@example.com",
        "a@example.com\r\nBcc: x@example.com",
        "a\x00@example.com",
        "",
    ]
    for addr in unsafe:
        with pytest.raises(MailSendError) as ei:
            await send_mail(settings, to=addr, subject="s", body="b")
        assert ei.value.definite is True, addr


async def test_unsafe_from_email_rejected(smtp_calls: dict[str, Any]) -> None:
    """SMTP_FROM_EMAIL 含危险字符(如 "Name <a@x.com>")→ 拒绝发送。"""
    settings = mk_settings(smtp_from_email="素材库 <noreply@example.com>")
    with pytest.raises(MailSendError) as ei:
        await send_mail(settings, to="alice@example.com", subject="s", body="b")
    assert ei.value.definite is True
    assert "ctor" not in smtp_calls


async def test_smtp_not_configured_definite(smtp_calls: dict[str, Any]) -> None:
    settings = mk_settings(smtp_host=None)
    with pytest.raises(MailSendError) as ei:
        await send_mail(settings, to="alice@example.com", subject="s", body="b")
    assert ei.value.definite is True
    assert "ctor" not in smtp_calls


# ─── TLS / SSL / login 三分支(自 notifications._smtp_send_sync 迁移)────────
async def test_tls_branch_with_login(smtp_calls: dict[str, Any]) -> None:
    settings = mk_settings(smtp_username="u", smtp_password="p", smtp_use_tls=True, smtp_use_ssl=False)
    await send_mail(settings, to="to@example.com", subject="subject", body="body")

    assert smtp_calls["class"] == "FakeSMTP"
    assert smtp_calls["ctor"] == ("smtp.example.com", 587, 15)
    assert smtp_calls["starttls"] is True
    assert smtp_calls["login"] == ("u", "p")
    assert str(smtp_calls["msg"]["To"]) == "to@example.com"


async def test_ssl_branch_anonymous(smtp_calls: dict[str, Any]) -> None:
    settings = mk_settings(smtp_port=465, smtp_use_tls=False, smtp_use_ssl=True, smtp_timeout_seconds=7)
    await send_mail(settings, to="to@example.com", subject="s", body="b")

    assert smtp_calls["class"] == "FakeSMTPSSL"
    assert smtp_calls["ctor"] == ("smtp.example.com", 465, 7)
    assert "login" not in smtp_calls  # 未配 username → 匿名发送


# ─── 确定失败 vs 结果未知 ─────────────────────────────────────────────────────
async def test_connect_refused_definite(smtp_calls: dict[str, Any]) -> None:
    _Shared.reset(ctor_exc=ConnectionRefusedError("refused"))
    with pytest.raises(MailSendError) as ei:
        await send_mail(mk_settings(), to="alice@example.com", subject="s", body="b")
    assert ei.value.definite is True


async def test_socket_connect_timeout_definite(smtp_calls: dict[str, Any]) -> None:
    """连接阶段 socket 超时(线程内 TimeoutError,DATA 未开始)→ definite=True。"""
    _Shared.reset(ctor_exc=TimeoutError("connect timeout"))
    with pytest.raises(MailSendError) as ei:
        await send_mail(mk_settings(), to="alice@example.com", subject="s", body="b")
    assert ei.value.definite is True


async def test_auth_failure_definite(smtp_calls: dict[str, Any]) -> None:
    _Shared.reset(login_exc=smtplib.SMTPAuthenticationError(535, b"auth failed"))
    settings = mk_settings(smtp_username="u", smtp_password="p")
    with pytest.raises(MailSendError) as ei:
        await send_mail(settings, to="alice@example.com", subject="s", body="b")
    assert ei.value.definite is True


async def test_recipients_refused_definite_even_after_data_flag(
    smtp_calls: dict[str, Any],
) -> None:
    """RCPT 全拒收:send_message 内部抛 SMTPRecipientsRefused → definite=True。"""
    _Shared.reset(
        send_exc=smtplib.SMTPRecipientsRefused({"alice@example.com": (550, b"no")}),
    )
    with pytest.raises(MailSendError) as ei:
        await send_mail(mk_settings(), to="alice@example.com", subject="s", body="b")
    assert ei.value.definite is True


async def test_data_stage_disconnect_unknown(smtp_calls: dict[str, Any]) -> None:
    """DATA 阶段开始后服务器断开 → 结果未知(definite=False)。"""
    _Shared.reset(send_exc=smtplib.SMTPServerDisconnected("dropped mid-DATA"))
    with pytest.raises(MailSendError) as ei:
        await send_mail(mk_settings(), to="alice@example.com", subject="s", body="b")
    assert ei.value.definite is False


async def test_outer_budget_timeout_unknown(monkeypatch: pytest.MonkeyPatch) -> None:
    """外层 wait_for 总预算超时:底层线程仍在跑 → definite=False(§5.6.1)。"""

    def slow_send(settings: Settings, msg: Any, outcome: mailer._SendOutcome) -> None:
        time.sleep(0.4)
        outcome.data_started = True

    monkeypatch.setattr(mailer, "_send_sync", slow_send)
    with pytest.raises(MailSendError) as ei:
        await send_mail(mk_settings(), to="alice@example.com", subject="s", body="b", timeout=0.05)
    assert ei.value.definite is False


async def test_default_budget_from_settings(
    smtp_calls: dict[str, Any],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """未显式传 timeout 时外层预算取 settings.smtp_total_timeout_seconds。"""
    captured: list[object] = []
    orig_wait_for = mailer.asyncio.wait_for

    async def traced_wait_for(fut: object, **kwargs: Any) -> object:
        captured.append(kwargs.get("timeout"))
        return await orig_wait_for(fut, **kwargs)

    monkeypatch.setattr(mailer.asyncio, "wait_for", traced_wait_for)
    settings = mk_settings(smtp_total_timeout_seconds=20)
    await send_mail(settings, to="a@example.com", subject="s", body="b")
    assert captured == [20]


# ─── 日志脱敏 ─────────────────────────────────────────────────────────────────
async def test_success_log_masks_recipient(
    smtp_calls: dict[str, Any],
    caplog: pytest.LogCaptureFixture,
) -> None:
    caplog.set_level(logging.INFO, logger="app.services.mailer")
    await send_mail(mk_settings(), to="recipient@example.com", subject="s", body="b")
    text = "\n".join(r.getMessage() for r in caplog.records if r.name == "app.services.mailer")
    assert "recipient@example.com" not in text
    assert "r***@example.com" in text


async def test_failure_log_masks_recipient(
    smtp_calls: dict[str, Any],
    caplog: pytest.LogCaptureFixture,
) -> None:
    caplog.set_level(logging.INFO, logger="app.services.mailer")
    _Shared.reset(send_exc=smtplib.SMTPServerDisconnected("bye"))
    with pytest.raises(MailSendError):
        await send_mail(mk_settings(), to="recipient@example.com", subject="s", body="b")
    text = "\n".join(r.getMessage() for r in caplog.records if r.name == "app.services.mailer")
    assert "recipient@example.com" not in text
    assert "r***@example.com" in text


# ─── email_utils 基础部分 ─────────────────────────────────────────────────────
def test_normalize_email() -> None:
    assert normalize_email("  Alice@Example.COM ") == "alice@example.com"
    assert normalize_email(None) is None
    assert normalize_email("") is None
    assert normalize_email("   ") is None
    assert normalize_email("MiXeD@Example.com") == "mixed@example.com"


def test_mask_email() -> None:
    assert mask_email("alice@example.com") == "a***@example.com"
    assert mask_email("  alice@example.com ") == "a***@example.com"
    assert mask_email(None) is None
    assert mask_email("") is None
    # 首字符 + 域名;254 字符合法邮箱不溢出 255(§10.1 补充分支)
    long_local = "a" * (254 - len("@example.com"))
    assert len(mask_email(f"{long_local}@example.com")) <= 255
    # 异常值(无 @)兜底:首字符 + ***
    assert mask_email("not-an-email") == "n***"


def test_is_header_safe_addr() -> None:
    assert is_header_safe_addr("alice@example.com") is True
    assert is_header_safe_addr(None) is False
    assert is_header_safe_addr("") is False
    for bad in [
        "a,b@x.com",
        "a;b@x.com",
        "a<b@x.com",
        'a"b@x.com',
        "a b@x.com",
        "a\nb@x.com",
        "a\x00@x.com",
        "a@x.com\x1b",
    ]:
        assert is_header_safe_addr(bad) is False, bad
