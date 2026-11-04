"""邮箱工具(基础部分)— 规范化 / 脱敏 / 头部安全校验。

方案:rushes-spec/material-storage/email-account-and-password-reset-plan.md
§5.1(模块划分)与 §5.3.5(邮箱规范化与校验)。

B1a 只含三个纯函数:normalize_email / mask_email / is_header_safe_addr
(头部安全字符集,mailer 与 Settings.resolve_mail_ready 共用同一口径);
strict_validate_email / strict_normalize_email / email_fingerprint /
is_email_format_ok 由 B2(邮箱绑定)补齐并复核本文件。

本模块不得 import app.* 下任何模块(settings/mailer 依赖它,反向会成环)。
"""

from __future__ import annotations

import re

# 邮件头注入面:地址中出现这些字符一律拒绝(方案 §5.6.1 / §5.10)
# `, ; < > "`、任意空白(含 CR/LF/Tab)。控制字符另走 ord 检查。
_UNSAFE_ADDR_CHARS = re.compile(r'[,;<>"\s]')


def normalize_email(value: str | None) -> str | None:
    """统一入口:strip + lower + 空串→None(避免 '' / 空白写进 users.email)。

    OIDC 同步、seed、管理员建号/编辑等全部写入点都走它(方案 §5.3.5)。
    只做归一化,不做格式校验(严格校验是 strict_validate_email 的事,B2)。
    """
    if value is None:
        return None
    v = value.strip().lower()
    return v or None


def mask_email(value: str | None) -> str | None:
    """审计 / 日志脱敏:alice@example.com → a***@example.com。

    - None / 空白 → None(调用方拿 None 判「无邮箱」)。
    - 无 "@" 的异常值按「首字符 + ***」兜底(只用于日志,不用于判定)。
    - 结果截断到 255:254 字符的合法邮箱加 *** 会溢出 String(255) 的
      actor_email_snapshot 列宽(方案 §5.3.5)。
    """
    if value is None:
        return None
    v = value.strip()
    if not v:
        return None
    if "@" in v:
        local, _, domain = v.rpartition("@")
        masked = f"{local[:1]}***@{domain}"
    else:
        masked = f"{v[:1]}***"
    return masked[:255]


def is_header_safe_addr(value: str | None) -> bool:
    """地址能否安全进邮件头:非空、不含 `, ; < > "` / 空白 / 控制字符。

    send_mail 收件人与 SMTP_FROM_EMAIL 启动校验共用同一口径(方案 §5.6.1:
    send_mail 不能信任调用方;§5.10:from 头部安全)。
    """
    if not value:
        return False
    if _UNSAFE_ADDR_CHARS.search(value):
        return False
    return not any(0x00 <= ord(ch) <= 0x1F or ord(ch) == 0x7F for ch in value)
