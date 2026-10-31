"""个人访问令牌(PAT)纯 DB 服务 — MCP 素材服务(方案 D2/D3/D13)。

本模块只做 DB 读写:**不写审计、不 commit**(事务边界由调用方掌握)。
- 创建/列表/自助吊销:调用方(routers/auth.py)commit 后再写审计;
- 密码变更/禁用吊销:``revoke_user_tokens`` 的 UPDATE 必须与 ``password_hash``
  (或 ``is_active``)写入**同一事务、同一次 commit 之前**完成 —— 若在函数内
  commit,会造出「密码已改而 PAT 未吊销」或反之的静默失效窗口。

对外 API(包 A2/A3 直接按此消费):

    PAT_PREFIX = "mspat_"
    MAX_ACTIVE_TOKENS = 5

    class TokenLimitExceeded(Exception)     # 活跃令牌达上限(路由映射 409)

    @dataclass(frozen=True)
    class TokenRef:                          # 吊销结果的最小引用(审计用)
        id: uuid.UUID
        token_prefix: str

    @dataclass(frozen=True)
    class CreatedToken:                      # 创建结果(明文只出现这一次)
        id: uuid.UUID
        name: str
        token: str
        token_prefix: str
        expires_at: datetime

    @dataclass(frozen=True)
    class ResolvedToken:                     # PAT 认证链查表结果(过期/吊销原样返回)
        id: uuid.UUID
        user_id: uuid.UUID
        token_prefix: str
        expires_at: datetime
        revoked_at: datetime | None

    def hash_token(raw_token: str) -> str            # SHA-256 hex(64)
    async def create_token(db, *, user_id, name, expires_in_days) -> CreatedToken
    async def list_tokens(db, *, user_id, include_revoked=False) -> list[PersonalAccessToken]
    async def get_token(db, *, token_id, user_id) -> PersonalAccessToken | None
    async def revoke_token(db, *, token_id, user_id) -> bool
    async def revoke_user_tokens(db, *, user_id, reason) -> list[TokenRef]
    async def resolve_token(db, raw_token) -> ResolvedToken | None

语义钉死:
- 明文形态 ``mspat_`` + ``secrets.token_urlsafe(32)``(去 padding 后 43 字符);
  落库只有 SHA-256 hex 与 ``token_prefix = raw[:16]``(``mspat_`` + 10);
- 活跃 = ``revoked_at IS NULL AND expires_at > now()``;时间一律 timezone-aware UTC;
- 每 user 活跃上限 5:创建前取**事务级** ``pg_advisory_xact_lock(hashtext(
  'pat:user:<uid>'))``(复用调用方 session,commit/rollback 自动释放,不会像
  session 级锁那样泄漏),再数活跃行,≥5 抛 ``TokenLimitExceeded``;
- ``revoke_user_tokens`` **函数内禁止 audit、禁止 commit**(D13 安全不变量):
  UPDATE ... WHERE revoked_at IS NULL RETURNING id, token_prefix,只返回本次
  真正被吊销的行 —— 审计由调用方在 commit 之后逐条写(无活跃 token 则不写)。

★ 吊销挂钩钉子(D13):``grep -rn "password_hash\\s*=" --include=*.py app scripts``
应命中 5 个生产写点(4 处赋值 + 1 处构造参数):
  app/routers/auth.py(change-password)、app/routers/directory.py(reset-password)、
  scripts/set_password.py、scripts/set_initial_admin.py(以上密码变更)、
  app/routers/directory.py(disable,is_active 路径)。
后续新增密码/禁用写点必须同步调用 ``revoke_user_tokens``。
"""
from __future__ import annotations

import hashlib
import logging
import secrets
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from sqlalchemy import func, select, text, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.tables import PersonalAccessToken

log = logging.getLogger(__name__)

# 令牌明文前缀(方案 D2;D11 UA 是 msmcp/<ver>,与 token 前缀无冲突)
PAT_PREFIX = "mspat_"
# 每用户活跃令牌上限(D2;创建端点内 advisory lock 防并发竞态超限)
MAX_ACTIVE_TOKENS = 5
# token_prefix 取明文前 16 字符 = PAT_PREFIX(6) + 10
TOKEN_PREFIX_LEN = 16
# token_urlsafe(32) 去 padding 后 43 字符 → 明文 49 字符;hash 落库 64 字符
_TOKEN_BYTES = 32


class TokenLimitExceeded(Exception):
    """活跃令牌数已达 ``MAX_ACTIVE_TOKENS``(路由映射 409)。"""


@dataclass(frozen=True)
class TokenRef:
    """被吊销令牌的最小引用(id + 前缀快照;审计 details 用)。"""

    id: uuid.UUID
    token_prefix: str


@dataclass(frozen=True)
class CreatedToken:
    """创建结果;``token`` 是明文,**只在创建响应回显这一次**。"""

    id: uuid.UUID
    name: str
    token: str
    token_prefix: str
    expires_at: datetime


@dataclass(frozen=True)
class ResolvedToken:
    """PAT 认证链查表结果(A2 消费):过期/吊销状态原样返回,由调用方判定 401。"""

    id: uuid.UUID
    user_id: uuid.UUID
    token_prefix: str
    expires_at: datetime
    revoked_at: datetime | None


def hash_token(raw_token: str) -> str:
    """明文 → SHA-256 hex(落库与查表同口径,64 字符)。"""
    return hashlib.sha256(raw_token.encode("utf-8")).hexdigest()


def generate_raw_token() -> str:
    """生成新令牌明文:``mspat_`` + ``secrets.token_urlsafe(32)``。"""
    return PAT_PREFIX + secrets.token_urlsafe(_TOKEN_BYTES)


def token_prefix_of(raw_token: str) -> str:
    """列表识别前缀:明文前 16 字符(``mspat_`` + 10)。"""
    return raw_token[:TOKEN_PREFIX_LEN]


def _now() -> datetime:
    return datetime.now(UTC)


async def _active_token_count(db: AsyncSession, user_id: uuid.UUID) -> int:
    stmt = (
        select(func.count())
        .select_from(PersonalAccessToken)
        .where(
            PersonalAccessToken.user_id == user_id,
            PersonalAccessToken.revoked_at.is_(None),
            PersonalAccessToken.expires_at > _now(),
        )
    )
    return int((await db.execute(stmt)).scalar_one())


async def create_token(
    db: AsyncSession,
    *,
    user_id: uuid.UUID,
    name: str,
    expires_in_days: int,
) -> CreatedToken:
    """创建令牌(不 commit)。

    ``pg_advisory_xact_lock`` 串行化同一用户的并发创建(事务级锁,随调用方的
    commit/rollback 释放);数活跃行 ≥ ``MAX_ACTIVE_TOKENS`` → ``TokenLimitExceeded``。
    返回明文只在本次结果中,调用方序列化后即丢弃。
    """
    # 事务级 advisory lock:同 user 的创建串行;hashtext 单参数进 bigint 重载
    await db.execute(
        text("SELECT pg_advisory_xact_lock(hashtext(:lock_key))"),
        {"lock_key": f"pat:user:{user_id}"},
    )
    if await _active_token_count(db, user_id) >= MAX_ACTIVE_TOKENS:
        raise TokenLimitExceeded(
            f"活跃令牌已达上限 {MAX_ACTIVE_TOKENS} 个,请先吊销不再使用的令牌"
        )

    raw = generate_raw_token()
    row = PersonalAccessToken(
        user_id=user_id,
        name=name,
        token_hash=hash_token(raw),
        token_prefix=token_prefix_of(raw),
        expires_at=_now() + timedelta(days=expires_in_days),
    )
    db.add(row)
    await db.flush()
    return CreatedToken(
        id=row.id,
        name=row.name,
        token=raw,
        token_prefix=row.token_prefix,
        expires_at=row.expires_at,
    )


async def list_tokens(
    db: AsyncSession,
    *,
    user_id: uuid.UUID,
    include_revoked: bool = False,
) -> list[PersonalAccessToken]:
    """本人令牌列表(排序 ``created_at DESC, id DESC``,稳定序)。

    默认只回活跃行(未吊销未过期);``include_revoked=True`` 回全部历史行
    (含已过期/已吊销,由响应模型标注)。永不返回 token_hash 之外的明文(无明文列)。
    """
    stmt = select(PersonalAccessToken).where(PersonalAccessToken.user_id == user_id)
    if not include_revoked:
        stmt = stmt.where(
            PersonalAccessToken.revoked_at.is_(None),
            PersonalAccessToken.expires_at > _now(),
        )
    stmt = stmt.order_by(
        PersonalAccessToken.created_at.desc(), PersonalAccessToken.id.desc(),
    )
    return list((await db.execute(stmt)).scalars().all())


async def get_token(
    db: AsyncSession,
    *,
    token_id: uuid.UUID,
    user_id: uuid.UUID,
) -> PersonalAccessToken | None:
    """按 id + 归属取行(仅本人;不存在/非本人/已吊销均返回行本身)。不 commit。"""
    stmt = select(PersonalAccessToken).where(
        PersonalAccessToken.id == token_id,
        PersonalAccessToken.user_id == user_id,
    )
    return (await db.execute(stmt)).scalars().first()


async def revoke_token(
    db: AsyncSession,
    *,
    token_id: uuid.UUID,
    user_id: uuid.UUID,
) -> bool:
    """自助吊销(仅本人);返回**本次是否首次生效**。不 commit。

    已吊销 / 不存在 / 非本人均返回 False(路由侧「非本人/不存在 → 404」由
    ``get_token`` 先行判定;重复吊销走幂等 204 且不重复写审计)。
    """
    stmt = (
        update(PersonalAccessToken)
        .where(
            PersonalAccessToken.id == token_id,
            PersonalAccessToken.user_id == user_id,
            PersonalAccessToken.revoked_at.is_(None),
        )
        .values(revoked_at=_now())
        .returning(PersonalAccessToken.id)
        .execution_options(synchronize_session=False)
    )
    return (await db.execute(stmt)).first() is not None


async def revoke_user_tokens(
    db: AsyncSession,
    *,
    user_id: uuid.UUID,
    reason: str,
) -> list[TokenRef]:
    """吊销该 user 全部**活跃**(revoked_at IS NULL)令牌;返回本次被吊销的行。

    ★ 函数内禁止 audit、禁止 commit(D13 安全不变量):UPDATE 必须与调用方的
    密码/状态写入同事务、同一次 commit;审计由调用方在 commit 之后逐条写。
    只返回真正被改写的行(``RETURNING``),已吊销行不会重复计入 —— 无活跃
    令牌时返回空列表,调用方据此跳过审计。
    """
    stmt = (
        update(PersonalAccessToken)
        .where(
            PersonalAccessToken.user_id == user_id,
            PersonalAccessToken.revoked_at.is_(None),
        )
        .values(revoked_at=_now())
        .returning(PersonalAccessToken.id, PersonalAccessToken.token_prefix)
        .execution_options(synchronize_session=False)
    )
    rows = (await db.execute(stmt)).all()
    refs = [TokenRef(id=row[0], token_prefix=row[1]) for row in rows]
    if refs:
        log.info(
            "revoked %d personal access token(s) user=%s reason=%s",
            len(refs), user_id, reason,
        )
    return refs


async def resolve_token(db: AsyncSession, raw_token: str) -> ResolvedToken | None:
    """按 SHA-256 hash 查令牌(A2 认证链消费;只读,不 commit)。

    返回 None = hash 未命中(调用方 401「令牌无效或已过期」);命中的行把
    ``expires_at`` / ``revoked_at`` 原样带出,过期/吊销判定留给调用方(与用户态
    校验同层,语义集中在认证链)。**调用方应使用独立短 session**(不得写进
    端点请求事务,方案 C.3)。
    """
    stmt = select(
        PersonalAccessToken.id,
        PersonalAccessToken.user_id,
        PersonalAccessToken.token_prefix,
        PersonalAccessToken.expires_at,
        PersonalAccessToken.revoked_at,
    ).where(PersonalAccessToken.token_hash == hash_token(raw_token))
    row = (await db.execute(stmt)).first()
    if row is None:
        return None
    return ResolvedToken(
        id=row[0],
        user_id=row[1],
        token_prefix=row[2],
        expires_at=row[3],
        revoked_at=row[4],
    )
