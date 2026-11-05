"""邮箱工具 — 规范化 / 严格校验 / 指纹 / 脱敏 / 头部安全校验。

方案:rushes-spec/material-storage/email-account-and-password-reset-plan.md
§5.1(模块划分)与 §5.3.5(邮箱规范化与校验)。

本模块不得 import app.* 下任何模块(settings/mailer 依赖它,反向会成环);
User 类型仅 TYPE_CHECKING 引用(解绑登录方式判定 has_non_email_login 用)。
"""

from __future__ import annotations

import re
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from app.db.tables import User

# 邮件头注入面:地址中出现这些字符一律拒绝(方案 §5.6.1 / §5.10)
# `, ; < > "`、任意空白(含 CR/LF/Tab)。控制字符另走 ord 检查。
_UNSAFE_ADDR_CHARS = re.compile(r'[,;<>"\s]')

# 严格邮箱正则(方案 §5.3.5):比 models 的宽松规则更严,禁止 `< , ; " 引号、
# 空白与一切非白名单字符 —— 杜绝邮件头注入,也兜住「过不了就大概率收不到信」
# 的存量脏地址(那类地址应走「更换邮箱」改成合法值,§13.12)。
STRICT_EMAIL_RE = re.compile(r"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$")

# RFC 5321 forward-path 上限(方案 §5.3.5:长度 ≤ 254)
EMAIL_MAX_LENGTH = 254


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


# ─── 严格校验(§5.3.5,B2 补齐)──────────────────────────────────────────────


def strict_validate_email(value: str) -> str:
    """严格校验并归一(strip + lower);不合法抛 ValueError(Pydantic 422 用)。

    口径(§5.3.5):长度 ≤ 254;``strip()`` 后非空;命中严格正则
    ``^[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}$``。
    返回值为归一化结果(小写)—— 调用方直接落库,勿再二次归一。
    """
    v = value.strip()
    if not v:
        raise ValueError("email 不能为空")
    if len(v) > EMAIL_MAX_LENGTH:
        raise ValueError(f"email 长度不能超过 {EMAIL_MAX_LENGTH} 字符")
    if not STRICT_EMAIL_RE.fullmatch(v):
        raise ValueError("email 格式不正确(仅支持标准邮箱地址)")
    return v.lower()


def strict_normalize_email(value: str) -> str:
    """Pydantic ``field_validator`` 入口:严格校验 + 归一,不合法 → 422。

    请求解析期执行(先于路由流程),格式错 422 不消耗请求预算(§5.3.2 第 5 步);
    不做宽松地址兼容分支(§13.12)。
    """
    return strict_validate_email(value)


def is_email_format_ok(value: str | None) -> bool:
    """存库历史邮箱能否过严格校验(不抛异常的探测口径)。

    用途:「验证当前邮箱」(purpose=verify)目标就是本人存量地址,过不了
    严格正则的应引导「更换邮箱」,而不是拒绝时 500 / 走宽松兼容(§5.3.5)。
    """
    if not value:
        return False
    try:
        strict_validate_email(value)
    except ValueError:
        return False
    return True


def email_fingerprint(value: str | None) -> str:
    """唯一哈希口径:``(value or "").strip().lower()``。

    重置 token 的 ``email_hash``、验证码的 ``current_email_hash`` 全部先过
    本函数再 sha256 —— 大小写/空白差异不得产生不同指纹(方案 §5.3.5)。
    """
    return (value or "").strip().lower()


def has_non_email_login(user: User, oidc_enabled: bool) -> bool:
    """解绑前的「还有没有可用登录方式」判定(方案 §5.3.4 第 4 步)。

    - ``username`` 非空(空串与 NULL 同等对待)→ True;
    - ``oidc_enabled`` 且 ``user.oidc_sub`` 非空 → True。

    ⚠️ ``oidc_enabled`` 必须由 router 注入 ``request.app.state.auth.enabled``
    (OIDCService 构造时缓存的四字段判定),不要在调用侧从 settings 重算一份
    —— 会出现第三份 OIDC 判定逻辑。``oidc_sub`` 非空 ≠ 能登录(生产纯本地
    登录时存量飞书用户只有 IdP sub 也不能走 IdP 登录,§5.3.4);本判定只回答
    「当前配置下解绑邮箱会不会锁死账号」。
    """
    if user.username is not None and user.username.strip():
        return True
    return bool(oidc_enabled and user.oidc_sub)
