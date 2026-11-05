"""运维逐条标记邮箱已验证 — 邮箱账号方案 D16 / §5.3.5 / §9.3 第 10 步 / §9.5。

执行(容器内;每次只处理一个账号,确认邮箱走 stdin/交互防进 shell history):

    docker exec -i ms-api python -m scripts.mark_email_verified --username <登录名>
    # 执行后在 stdin 输入该账号库中的完整邮箱确认(§9.3 第 10 步)

    echo "<alice@example.com>" | docker exec -i ms-api python \
        -m scripts.mark_email_verified --user-id <uuid> --confirm-email -

硬规则(方案 §9.5):
  - ``--username`` / ``--user-id`` **二选一**;
  - 确认输入与库中当前 email 按 ``strip().lower()`` **完全一致**才执行;
  - 执行前先过 ``strict_validate_email``,存量地址不合法 → 拒绝并提示先换绑
    (否则置了已验证也过不了找回密码的 Pydantic 422,白标);
  - 写审计 ``email_verified``(details: source=ops / verified_by / email_masked;
    actor_email_snapshot 同为脱敏值,完整邮箱不落审计/终端);
  - **无批量 / 日期范围档**(D16):批量兑现「管理员录错邮箱」的全部风险,
    只保留逐账号显式确认。
"""

from __future__ import annotations

import argparse
import asyncio
import getpass
import sys
import uuid
from datetime import UTC, datetime
from typing import Any

from sqlalchemy import func, select

from app.db.session import get_sessionmaker
from app.db.tables import User
from app.services.audit import AuditService
from app.services.email_utils import mask_email, strict_validate_email


def _prompt(msg: str) -> str:
    return input(msg)


def _read_stdin_line() -> str:
    return sys.stdin.readline()


def read_confirmation(confirm_email: str | None, masked: str) -> str:
    """确认输入三通道:--confirm-email 值 / '-' 读 stdin / 缺省交互提示。"""
    if confirm_email is not None and confirm_email != "-":
        return confirm_email
    if confirm_email == "-":
        return _read_stdin_line()
    return _prompt(f"请输入该账号当前完整邮箱以确认(库中值形如 {masked}): ")


def default_verified_by() -> str:
    try:
        return getpass.getuser() or "ops"
    except Exception:
        return "ops"


async def _find_user(
    db: Any, *, username: str | None, user_id: uuid.UUID | None
) -> User | None:
    """username(lower,多命中拒绝)/ user-id 直查二选一。"""
    if user_id is not None:
        return await db.get(User, user_id)
    res = await db.execute(
        select(User).where(func.lower(User.username) == (username or "").lower()).limit(2)
    )
    users = list(res.scalars())
    if len(users) > 1:
        raise LookupError(f"username '{username}' 命中 {len(users)} 个账号,请改用 --user-id")
    return users[0] if users else None


async def mark_verified(
    *,
    username: str | None,
    user_id: uuid.UUID | None,
    confirm_email: str | None,
    verified_by: str,
) -> int:
    sm = get_sessionmaker()
    async with sm() as session:
        try:
            user = await _find_user(session, username=username, user_id=user_id)
        except LookupError as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            return 2
        if user is None:
            print("ERROR: 找不到指定账号(核对 --username/--user-id)", file=sys.stderr)
            return 2
        stored = (user.email or "").strip()
        if not stored:
            print("ERROR: 该账号未绑定邮箱,无需标记", file=sys.stderr)
            return 2

        # 先严格校验存量(§9.5:不合法直接报错提示先换绑;fail-fast,不浪费确认输入)
        try:
            strict_validate_email(stored)
        except ValueError as exc:
            print(
                f"ERROR: 存量邮箱不合法({exc}),标记已验证也无法用于找回密码;"
                "请先由用户自助或管理员换绑为合法地址后再标记。"
                f"当前值(脱敏): {mask_email(stored)}",
                file=sys.stderr,
            )
            return 2

        masked = mask_email(stored) or "?"
        given = read_confirmation(confirm_email, masked).strip()
        # 口径按 §9.5:与库中当前值 strip().lower() 完全一致才执行
        if given.lower() != stored.lower():
            print(
                "ERROR: 确认输入与库中当前邮箱不一致,未执行任何改动"
                f"(输入脱敏: {mask_email(given) or '(空)'};库中脱敏: {masked})",
                file=sys.stderr,
            )
            return 2

        user.email_verified_at = datetime.now(UTC)
        target_id = user.id
        await session.commit()

    # commit 之后用新 session 写审计(与 set_password 同款;audit.write 自带 commit;
    # actor=被标记用户本人,auth_method 走 CLI 默认(无 request/contextvar → NULL))
    async with sm() as audit_session:
        await AuditService(audit_session).write(
            event_type="email_verified",
            actor_user_id=target_id,
            details={
                "source": "ops",
                "verified_by": verified_by,
                "email_masked": masked,
            },
            actor_email_snapshot=masked,
        )

    print("---MARK_EMAIL_VERIFIED RESULT---")
    print(f"user_id={target_id}")
    print(f"email_masked={masked}")
    print(f"email_verified_at={datetime.now(UTC).isoformat(timespec='seconds')}")
    print(f"verified_by={verified_by}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="逐条标记账号邮箱已验证(D16:无批量档;完整邮箱走 stdin/交互确认)",
    )
    selector = parser.add_mutually_exclusive_group(required=True)
    selector.add_argument("--username", help="按登录名定位(lower 匹配;多命中拒绝)")
    selector.add_argument("--user-id", help="按 users.id(UUID) 直查")
    parser.add_argument(
        "--confirm-email", metavar="EMAIL",
        help="确认输入;传 '-' 从 stdin 读一行(防完整邮箱进 shell history);"
             "省略 = 交互提示输入",
    )
    parser.add_argument(
        "--verified-by", default=None,
        help="审计 verified_by 标识(默认取当前操作系统用户名)",
    )
    args = parser.parse_args(argv)

    user_id: uuid.UUID | None = None
    if args.user_id is not None:
        try:
            user_id = uuid.UUID(args.user_id)
        except ValueError:
            parser.error("--user-id 必须是合法 UUID")

    return asyncio.run(
        mark_verified(
            username=args.username,
            user_id=user_id,
            confirm_email=args.confirm_email,
            verified_by=args.verified_by or default_verified_by(),
        )
    )


if __name__ == "__main__":
    sys.exit(main())
