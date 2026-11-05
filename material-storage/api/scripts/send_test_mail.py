"""SMTP 出口真实发信测试 — 邮箱账号方案 §9.1(出口实测)/ §9.3 第 7 步 / §9.5。

执行(容器内;**代码同步之后**才存在本脚本,同步前用 §9.1 的一次性探活):

    # 交互:回车输入收件人(完整邮箱只经 stdin,不进 shell history)
    docker exec -i ms-api python -m scripts.send_test_mail

    # 管道:收件人从 stdin 读(文档示例一律用占位符)
    echo "<ops@example.com>" | docker exec -i ms-api python -m scripts.send_test_mail

    # --to 仅可选占位(会进 shell history,正式环境优先 stdin)
    docker exec -i ms-api python -m scripts.send_test_mail --to <ops@example.com>

行为:用**当前 settings** 真实发一封纯文本测试邮件(send_mail,脱敏日志);
不要求 mail_ready(EMAIL_AUTH_ENABLED=false 时也可发,§9.3 第 7 步正是此时用),
只要求 smtp_enabled(SMTP_HOST + SMTP_FROM_EMAIL 齐备)。输出会带
resolve_mail_ready 诊断,便于区分「SMTP 通了但邮箱功能仍未开」的预期状态。
"""

from __future__ import annotations

import argparse
import asyncio
import sys
from datetime import UTC, datetime

from app.services.email_utils import mask_email, strict_validate_email
from app.services.mailer import MailSendError, send_mail
from app.settings import get_settings


def _prompt(msg: str) -> str:
    return input(msg)


def _read_stdin_line() -> str:
    return sys.stdin.readline()


def resolve_recipient(arg_to: str | None, *, prompt: bool) -> str:
    """收件人来源:--to > stdin(--to -)/ 交互 input;空值/不合法交调用方处置。

    ``--to -`` 也按 stdin 读(与 mark_email_verified 的 --confirm-email - 同型,
    便于 `echo x | docker exec -i` 管道场景);其余交互场景走 input() 提示。
    """
    if arg_to is not None and arg_to != "-":
        return arg_to.strip()
    if arg_to == "-" or not prompt:
        return _read_stdin_line().strip()
    return _prompt("收件人邮箱(完整地址,回车确认): ").strip()


def build_body() -> str:
    """测试邮件正文:带发件配置摘要与 mail_ready 诊断(便于存档排查)。"""
    s = get_settings()
    mail_ready, reason = s.resolve_mail_ready(detail=True)
    lines = [
        "这是一封素材库 SMTP 出口测试邮件(ops / send_test_mail)。",
        f"时间: {datetime.now(UTC).isoformat(timespec='seconds')}",
        f"SMTP: host={s.smtp_host or '-'} port={s.smtp_port}"
        f" use_ssl={s.smtp_use_ssl} use_tls={s.smtp_use_tls}",
        f"发件人(脱敏): {mask_email(s.smtp_from_email) or '-'}",
        f"mail_ready={mail_ready}({reason})",
        f"EMAIL_LINK_BASE_URL: {s.email_link_base_url or '(未配置)'}",
        "收到本邮件即代表 SMTP 出口可用;本邮件无需回复。",
    ]
    return "\n".join(lines)


async def run(to: str) -> int:
    """校验收件人并真实发信;退出码:0 成功 / 1 发送失败 / 2 参数不合法。"""
    try:
        recipient = strict_validate_email(to)
    except ValueError as exc:
        print(f"ERROR: 收件人不合法({exc});输入值(脱敏): {mask_email(to)}", file=sys.stderr)
        return 2
    settings = get_settings()
    if not settings.smtp_enabled:
        print(
            "ERROR: SMTP 未配置(SMTP_HOST / SMTP_FROM_EMAIL 留空 = smtp_enabled=false);"
            "先按方案 §9.2 填 .env 并 force-recreate",
            file=sys.stderr,
        )
        return 1

    mail_ready, reason = settings.resolve_mail_ready(detail=True)
    print(f"mail_ready={mail_ready}({reason})")  # 信息性:开功能是 §9.3 第 8 步的事
    print(f"正在发送 → {mask_email(recipient)} ...")
    try:
        await send_mail(
            settings,
            to=recipient,
            subject="【素材库】SMTP 出口测试邮件",
            body=build_body(),
        )
    except MailSendError as exc:
        if exc.definite:
            print(f"ERROR: 发送确定失败(邮件未被服务器接受): {exc}", file=sys.stderr)
        else:
            print(
                "ERROR: 发送结果未知(总预算超时/DATA 阶段断开,服务器可能已接受);"
                "请先检查收件箱再决定是否重试",
                file=sys.stderr,
            )
        return 1
    print(f"OK: 测试邮件已发送 → {mask_email(recipient)};请查收(含垃圾邮件夹)。")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="用当前 settings 真实发一封 SMTP 测试邮件(收件人走 stdin/交互;--to 仅可选占位)",
    )
    parser.add_argument(
        "--to", metavar="RECIPIENT",
        help="收件人邮箱;省略 = 交互输入,'-' = 从 stdin 读一行(防进 shell history)",
    )
    args = parser.parse_args(argv)

    recipient = resolve_recipient(args.to, prompt=sys.stdin.isatty())
    if not recipient:
        print("ERROR: 收件人为空(--to 或 stdin 至少给一个)", file=sys.stderr)
        return 2
    return asyncio.run(run(recipient))


if __name__ == "__main__":
    sys.exit(main())
