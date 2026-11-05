"""统一 SMTP 发送(方案 §5.6.1)— send_mail / MailSendError。

设计钉子(方案 §5.6.1 / §12 第 22/28 条):
- 同步 smtplib → asyncio.to_thread;两层超时:socket 层
  ``settings.smtp_timeout_seconds``(15s,单次 socket 操作)+ 外层总预算
  ``settings.smtp_total_timeout_seconds``(20s,asyncio.wait_for 卡总时长,
  < 前端 30s)。
- ``MailSendError.definite`` 区分「确定失败」(邮件未被接受,调用方可安全
  删 token / 覆盖验证码)与「结果未知」(外层 wait_for 超时或 DATA 阶段开始
  后断开 —— 服务器可能已接受,调用方保留 token / 验证码并提示检查邮箱)。
- From / To 一律 ``email.headerregistry.Address`` 构造防头注入;
  **display_name 不能传 None**(CPython 3.12 会 TypeError),未配置时用空串。
- Message-ID / Date 必须自己补(P0 实锤:Gmail 对缺 Message-ID 的邮件直接
  550-5.7.1 拒收,RFC 5322);EmailMessage / smtplib.send_message / QQ 企业邮
  中继都**不会**自动生成。Message-ID 域名取 SMTP_FROM_EMAIL 的 @ 后部分,
  解析失败回退 ``localhost``(防跨邮件系统判重)。
- **send_mail 自己校验收件人**(不信任调用方):含 `, ; < > " / 空白 /
  控制字符 → MailSendError(definite=True)。
- 日志只出现 mask_email 脱敏后的收件人(方案 §10.4 验收硬项)。
"""

from __future__ import annotations

import asyncio
import logging
import smtplib
import time
from email.headerregistry import Address
from email.message import EmailMessage
from email.utils import formatdate, make_msgid

from app.services.email_utils import is_header_safe_addr, mask_email
from app.settings import Settings

log = logging.getLogger(__name__)

# 这些异常出现时邮件一定未被服务器接受(连接 / 认证 / 发件人 / 收件人阶段)
# → definite=True,即使 data_started 已置位(RCPT 拒收发生在 send_message 内部)。
_DEFINITE_SMTP_ERRORS: tuple[type[BaseException], ...] = (
    smtplib.SMTPConnectError,
    smtplib.SMTPHeloError,
    smtplib.SMTPAuthenticationError,
    smtplib.SMTPSenderRefused,
    smtplib.SMTPRecipientsRefused,
)


class MailSendError(RuntimeError):
    """发送失败。

    ``definite=True``  → 确定未发出(连接 / 认证 / RCPT 拒收 / 地址不安全)。
    ``definite=False`` → 结果未知(外层总预算超时 / DATA 阶段开始后断开),
    底层线程可能仍在跑、服务器可能已接受;调用方保留 token / 验证码。
    """

    def __init__(self, message: str, *, definite: bool) -> None:
        super().__init__(message)
        self.definite = definite


class _SendOutcome:
    """线程回传袋:异常存这里而不是从 to_thread 抛出。

    原因:线程内的 socket ``TimeoutError`` 与外层 ``asyncio.wait_for`` 的
    ``TimeoutError`` 同型,直接抛出会让外层 except 无法区分「总预算超时
    (结果未知)」与「连接阶段 socket 超时(确定失败)」。
    """

    __slots__ = ("data_started", "exc")

    def __init__(self) -> None:
        # send_message() 是否已被调用(MAIL/RCPT/DATA 阶段在其内部)
        self.data_started = False
        self.exc: BaseException | None = None


async def send_mail(
    settings: Settings,
    *,
    to: str,
    subject: str,
    body: str,
    timeout: float | None = None,  # noqa: ASYNC109 — 签名钉死于方案 §5.6.1
) -> None:
    """发送一封纯文本邮件;失败抛 MailSendError(日志脱敏收件人)。

    ``timeout`` 覆盖外层总预算(默认 settings.smtp_total_timeout_seconds);
    交互式调用方(验证码 / 重置链接)由外层按方案 §5.6.3 自行 shield + wait_for
    时可直接用默认值。
    """
    if not settings.smtp_enabled:
        raise MailSendError("smtp not configured (SMTP_HOST/SMTP_FROM_EMAIL missing)", definite=True)
    if not is_header_safe_addr(to):
        raise MailSendError("unsafe recipient address rejected", definite=True)
    if not is_header_safe_addr(settings.smtp_from_email):
        raise MailSendError("unsafe SMTP_FROM_EMAIL rejected", definite=True)

    msg = EmailMessage()
    msg["From"] = Address(
        display_name=settings.smtp_from_name or "",
        addr_spec=settings.smtp_from_email,
    )
    msg["To"] = Address(display_name="", addr_spec=to)
    msg["Subject"] = subject
    # RFC 5322 必备头,缺了 Gmail 直接 550-5.7.1 拒收(见模块 docstring 钉子)。
    msg["Message-ID"] = make_msgid(domain=_from_domain(settings))
    msg["Date"] = formatdate(localtime=True)
    msg.set_content(body)

    budget = settings.smtp_total_timeout_seconds if timeout is None else timeout
    outcome = _SendOutcome()
    started = time.monotonic()
    try:
        await asyncio.wait_for(
            asyncio.to_thread(_send_sync, settings, msg, outcome),
            timeout=budget,
        )
    except TimeoutError as exc:
        # 外层总预算超时:wait_for 只取消 future,不会终止底层线程 ——
        # 不能假定未发送(方案 §5.6.1「结果未知」分支)。
        log.error(
            "mail send timeout after %.1fs (result unknown) to=%s subject=%r", budget, mask_email(to), subject
        )
        raise MailSendError(f"mail send timeout after {budget}s (result unknown)", definite=False) from exc

    if outcome.exc is not None:
        # 明确的拒收类异常 → definite;其余(send_message 已开始的任何失败,
        # 如 SMTPServerDisconnected / socket 超时 / OSError)按 data_started 判:
        # DATA 阶段开始后一律「结果未知」。
        definite = isinstance(outcome.exc, _DEFINITE_SMTP_ERRORS) or not outcome.data_started
        log.error(
            "mail send failed (definite=%s) to=%s subject=%r error=%r",
            definite,
            mask_email(to),
            subject,
            outcome.exc,
        )
        raise MailSendError(f"mail send failed: {outcome.exc!r}", definite=definite) from outcome.exc

    log.info("mail sent to=%s subject=%r in %.1fs", mask_email(to), subject, time.monotonic() - started)


def _from_domain(settings: Settings) -> str:
    """Message-ID 的域名:SMTP_FROM_EMAIL ``@`` 后部分;解析失败回退 localhost。

    纯防御分支:无 @ / 空 domain 的 from 地址在 ``Address(addr_spec=...)``
    处就会抛 InvalidHeaderDefect,到不了这里;保留回退以免未来校验口径变化
    时 Message-ID 悄悄变成空域名。
    """
    _, sep, domain = (settings.smtp_from_email or "").rpartition("@")
    return domain if sep and domain else "localhost"


def _send_sync(settings: Settings, msg: EmailMessage, outcome: _SendOutcome) -> None:
    """线程体:同步 smtplib 发送(端口/TLS 逻辑沿用原 notifications 实现)。

    异常全部捕获存 outcome —— 不从 to_thread 抛出,见 _SendOutcome 文档。
    """
    try:
        host = settings.smtp_host or ""
        if settings.smtp_use_ssl:
            with smtplib.SMTP_SSL(host, settings.smtp_port, timeout=settings.smtp_timeout_seconds) as server:
                _login_and_send(server, settings, msg, outcome)
        else:
            with smtplib.SMTP(host, settings.smtp_port, timeout=settings.smtp_timeout_seconds) as server:
                if settings.smtp_use_tls:
                    server.starttls()
                _login_and_send(server, settings, msg, outcome)
    except BaseException as exc:
        outcome.exc = exc


def _login_and_send(
    server: smtplib.SMTP,
    settings: Settings,
    msg: EmailMessage,
    outcome: _SendOutcome,
) -> None:
    if settings.smtp_username:
        server.login(settings.smtp_username, settings.smtp_password or "")
    outcome.data_started = True  # 即将进入 send_message(MAIL/RCPT/DATA)
    server.send_message(msg)
