"""给指定 user 设本地登录密码 / 登录名 — dev 与生产运维两用(runbook §8.2)。

执行(容器内,与其它 seed 同款):
  docker compose exec ms-api python -m scripts.set_password <用户名|邮箱|显示名|UUID> \
      [--password <明文>] [--username <登录名>] [--must-change] [--list]
      [--username-only <登录名>]

行为:
  - identifier 按 local_login 同款优先级匹配:username → email(含 @)→ name → UUID
  - 设 users.password_hash(argon2id),默认同时清 must_change_password
    (seed 出来的账号直接可登录;--must-change 则保留强制改密,用于测首登流程)
  - --username 给老账号(如 dev_bootstrap 的 alice/bob,username 为 NULL)补登录名;
    格式与 UserCreateIn.username 同口径(2-64 位、仅字母/数字/._-,禁 @)并做
    username/email 跨列占用检查(邮箱账号方案 §5.3.5)
  - --username-only 只改登录名:不写 password_hash、不清 must_change_password、
    不吊销 PAT、不自增 session_version(存量冲突/解绑前置专用;普通 --username
    会无条件重置密码并踢会话,不能当「只改登录名」用)
  - 省略 --password 时生成一次性临时密码并回显一次(与管理后台同款策略)
  - 改密同时 session_version+1(§5.5,目标旧 JWT 全部失效)+ 删未用重置 token
    (D13)+ commit 后 best-effort 清 email:code / email:chg:fail/lock
    (短连接 redis.asyncio.from_url + aclose,不裸调未连接 Redis())
  - --list 列出全部用户及 password_set / must_change 状态,方便核对测试账号

场景:
  - local_up.sh 收尾时给 alice/bob/evan/outsider 设固定 dev 密码,浏览器走
    /login 账号密码登录测角色(与生产同链路,不再依赖 X-User-Id dev 通道)
  - 生产:管理员重置某用户密码(结果只打印到 stdout,自行线下传递)
"""
from __future__ import annotations

import argparse
import asyncio
import contextlib
import logging
import re
import uuid
from typing import Any

import redis.asyncio as redis_asyncio
from redis.asyncio import Redis
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.session import get_sessionmaker
from app.db.tables import User
from app.services.audit import AuditService
from app.services.local_auth import LocalAuthService
from app.services.password_reset import (
    delete_unused_tokens,
    post_password_change_cleanup,
)
from app.services.passwords import generate_temp_password
from app.services.tokens import revoke_user_tokens
from app.settings import get_settings

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s — %(message)s")
log = logging.getLogger("set_password")

# 与 UserCreateIn.username 同口径(§5.3.5:登录名与邮箱两个命名空间,禁 @)
_USERNAME_RE = re.compile(r"^[a-zA-Z0-9._-]+$")


async def find_user(db: AsyncSession, identifier: str) -> User | None:
    """与 LocalAuthService.find_user_by_username 同优先级,外加 UUID 直查。"""
    try:
        uid = uuid.UUID(identifier)
        return await db.get(User, uid)
    except ValueError:
        pass
    lowered = identifier.lower()
    for column in (User.username, User.email, User.name):
        if column is User.email and "@" not in lowered:
            continue
        res = await db.execute(
            select(User).where(func.lower(column) == lowered).limit(2)
        )
        users = list(res.scalars())
        if len(users) == 1:
            return users[0]
        if len(users) > 1:
            raise SystemExit(f"ERROR: identifier '{identifier}' 命中多条 {column.key},请改用 UUID")
    return None


async def list_users() -> None:
    sm = get_sessionmaker()
    async with sm() as session:
        res = await session.execute(select(User).order_by(User.name))
        rows = list(res.scalars())
    print(f"{'id':<38} {'username':<12} {'name':<20} pw  must_change")
    for u in rows:
        print(
            f"{u.id!s:<38} {u.username or '-':<12} {u.name:<20} "
            f"{'✓' if u.password_hash else '·'}   {'⚠' if u.must_change_password else '·'}"
        )


def _validate_username(new_username: str) -> str:
    """登录名格式(与 UserCreateIn.username 同口径,§5.3.5):2-64 位、仅
    字母/数字/._-(正则本身即禁 @);不合法直接退出,不写入。"""
    u = new_username.strip()
    if not (2 <= len(u) <= 64) or not _USERNAME_RE.fullmatch(u):
        raise SystemExit(
            "ERROR: 登录名需 2-64 位,仅限字母/数字/._-(不能包含 @ 或其它字符)"
        )
    return u


async def _check_username_free(session: AsyncSession, user_id: uuid.UUID,
                               new_username: str) -> None:
    """username 本列占用 + 与他人 email 的跨列占用(登录匹配 username 优先)。"""
    dup = await session.execute(
        select(User).where(func.lower(User.username) == new_username.lower())
        .where(User.id != user_id).limit(1)
    )
    if dup.scalars().first() is not None:
        raise SystemExit(f"ERROR: username '{new_username}' 已被占用")
    cross = await session.execute(
        select(User).where(func.lower(User.email) == new_username.lower())
        .where(User.id != user_id).limit(1)
    )
    if cross.scalars().first() is not None:
        raise SystemExit(
            f"ERROR: username '{new_username}' 与其他账号的邮箱冲突(登录匹配会命中对方)"
        )


async def _cleanup_redis_shortlived(user_id: uuid.UUID) -> None:
    """commit 后 best-effort:DEL email:code + 清 email:chg:fail/lock(§5.5.1)。

    CLI 没有常驻 Redis:短连接 from_url + aclose;连接失败只 log(验证码 600s
    TTL 自然过期兜底),不裸调未连接的 Redis()。"""
    redis = None
    try:
        redis = redis_asyncio.from_url(
            str(get_settings().redis_url), decode_responses=True,
        )
    except Exception as exc:
        log.warning("redis 连接失败,跳过 email:code/chg 清理: %r", exc)
        return
    try:
        await post_password_change_cleanup(redis, user_id)
    finally:
        with contextlib.suppress(Exception):
            await redis.aclose()


async def set_username_only(identifier: str, new_username: str) -> None:
    """--username-only:只改登录名,不动密码/PAT/must_change/session_version。"""
    u = _validate_username(new_username)
    sm = get_sessionmaker()
    async with sm() as session:
        user = await find_user(session, identifier)
        if user is None:
            raise SystemExit(f"ERROR: 找不到用户 '{identifier}'(--list 查看全部)")
        await _check_username_free(session, user.id, u)
        old = user.username
        user.username = u
        await session.commit()
    print("---SET_USERNAME ONLY RESULT---")
    print(f"user_id={user.id}")
    print(f"username: {old or '-'} -> {u}")
    print("password/must_change_password/PAT/session_version: 未改动")


async def set_password(identifier: str, password: str | None, new_username: str | None,
                       must_change: bool) -> None:
    settings = get_settings()
    # hash / verify / policy 不碰 redis;构造未连接客户端仅满足签名
    local_auth = LocalAuthService(settings, Redis())

    if password is not None:
        policy_error = local_auth.validate_password_policy(password)
        if policy_error:
            raise SystemExit(f"ERROR: {policy_error}")
    sm = get_sessionmaker()
    async with sm() as session:
        user = await find_user(session, identifier)
        if user is None:
            raise SystemExit(f"ERROR: 找不到用户 '{identifier}'(--list 查看全部)")

        if new_username:
            u = _validate_username(new_username)
            await _check_username_free(session, user.id, u)
            user.username = u

        final_password = password or generate_temp_password()
        user.password_hash = local_auth.hash_password(final_password)
        user.must_change_password = must_change
        # 邮箱账号方案 §5.5.1:CLI 改密 ⇒ session_version+1(目标旧 JWT 全部
        # 失效)+ 删未用重置 token(旧重置链接不能再改密)
        user.session_version = (user.session_version or 0) + 1
        await delete_unused_tokens(session, user.id)
        # D13 第三处挂钩(CLI 应急重置):吊销该用户全部活跃 PAT —— 必须与
        # password_hash 写入同事务、同一次 commit 之前(D13 安全不变量)。
        revoked_tokens = await revoke_user_tokens(
            session, user_id=user.id, reason="password_changed",
        )
        await session.commit()
        user_id = user.id

        # commit 之后用**新 session** 的 AuditService 逐条写 token_revoked
        # (actor=cli;只写本次真正被吊销的行,无活跃令牌则不写)
        if revoked_tokens:
            async with sm() as audit_session:
                audit = AuditService(audit_session)
                for ref in revoked_tokens:
                    await audit.write(
                        event_type="token_revoked",
                        details={
                            "user_id": str(user_id),
                            "token_id": str(ref.id),
                            "token_prefix": ref.token_prefix,
                            "reason": "password_changed",
                            "actor": "cli",
                        },
                    )

    await _cleanup_redis_shortlived(user_id)

    print("---SET_PASSWORD RESULT---")
    print(f"user_id={user_id}")
    print(f"username={user.username or '-'}")
    print(f"name={user.name}")
    print(f"must_change_password={user.must_change_password}")
    if password is None:
        print(f"temp_password={final_password}   # 只显示这一次,请立即保存")
    print(f"登录:http://localhost:5173/ms-static/web/login(用户名 {user.username or user.name})")


def main() -> None:
    parser = argparse.ArgumentParser(description="设本地登录密码 / 登录名")
    parser.add_argument("identifier", nargs="?", help="username / email / 显示名 / UUID")
    parser.add_argument("--password", help="明文密码;省略则生成一次性临时密码")
    parser.add_argument("--username", help="补设/改本地登录名(如给 seed 账号设 alice;会重置密码)")
    parser.add_argument(
        "--username-only", metavar="USERNAME",
        help="只改登录名:不动密码/PAT/must_change_password/session_version",
    )
    parser.add_argument("--must-change", action="store_true",
                        help="保留 must_change_password(测首登强制改密);默认清除")
    parser.add_argument("--list", action="store_true", help="列出全部用户及密码状态")
    args: argparse.Namespace = parser.parse_args()

    if args.list:
        asyncio.run(list_users())
        return
    if not args.identifier:
        parser.error("需要 identifier(或 --list)")
    if args.username_only:
        if args.username or args.password or args.must_change:
            parser.error("--username-only 不能与 --username/--password/--must-change 同用")
        asyncio.run(set_username_only(args.identifier, args.username_only))
        return
    kw: dict[str, Any] = {
        "password": args.password,
        "new_username": args.username,
        "must_change": args.must_change,
    }
    asyncio.run(set_password(args.identifier, **kw))


if __name__ == "__main__":
    main()
