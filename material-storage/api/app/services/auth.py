"""通用 OIDC RP + JWT session service(#154:飞书 OIDC 抽象为 provider 配置留口)。

流程(标准 authorization_code + userinfo):
  1. /api/v1/auth/login → build_authorize_url → 重定向 IdP
  2. 用户在 IdP 同意 → 回调 /api/v1/auth/callback?code=...&state=...
  3. exchange_code_for_token → 拿 access_token
  4. fetch_userinfo → 拿 sub / name / email(claim 名可配置映射)
  5. upsert_user → 按 users.oidc_sub 找/建 users 行,返 internal user_id
  6. encode_session → 签 JWT
  7. set cookie ms_session + 302 redirect 到 state.next

provider 配置:settings.oidc_provider(dict,默认空 = 纯本地登录,本服务 enabled=False):
  {
    "authorize_endpoint": "...",   # IdP authorize URL
    "token_endpoint": "...",       # IdP token URL
    "userinfo_endpoint": "...",    # IdP userinfo URL
    "client_id": "...",
    "client_secret": "...",
    "redirect_uri": "...",         # 绝对 URL,需在 IdP 后台注册
    "scope": "...",                # 可选,默认 openid profile email
    "claims": {"sub": "sub", "name": "name", "email": "email"}  # 可选 claim 映射
  }
env 注入:OIDC_PROVIDER='{...json...}'(pydantic-settings 自动 JSON 解析)。

⚠️ 留口边界(接真实 IdP 前必须补齐,勿当已就绪):
  - id_token 不校验:只信任 userinfo 的 HTTP 响应(手写 RP,无 authlib)
  - 无 PKCE(code_challenge / code_verifier)
  - state 仅防 CSRF 简化实现(state=nonce),无 id_token_hint / nonce claim 校验
  - 单测覆盖 upsert 的 email 兜底关联分支;网络流(token/userinfo)需在
    容器集成测试里对 mock IdP 验证
"""
from __future__ import annotations

import logging
import secrets
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any
from urllib.parse import urlencode

import httpx
from jose import JWTError, jwt
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.tables import User
from app.settings import Settings

log = logging.getLogger(__name__)

# 从 userinfo 里取值时的默认 claim 名(可被 provider.claims 覆盖)
_DEFAULT_CLAIMS = {"sub": "sub", "name": "name", "email": "email"}
_DEFAULT_SCOPE = "openid profile email"


class OIDCService:
    def __init__(self, settings: Settings):
        self._settings = settings
        self._http = httpx.AsyncClient(timeout=10.0)
        self._cfg: dict[str, Any] = dict(settings.oidc_provider or {})
        self._claims: dict[str, str] = dict(_DEFAULT_CLAIMS)
        self._claims.update(self._cfg.get("claims") or {})

    async def close(self) -> None:
        await self._http.aclose()

    # ─── provider 配置(留口;未配置 = 纯本地登录)─────────────────────────
    @property
    def enabled(self) -> bool:
        """是否配置了可用 provider(纯本地登录时 False)。"""
        return bool(self._cfg.get("authorize_endpoint") and self._cfg.get("token_endpoint")
                    and self._cfg.get("client_id") and self._cfg.get("client_secret"))

    def _claim(self, key: str) -> str:
        return self._claims.get(key, _DEFAULT_CLAIMS[key])

    # ─── OIDC flow ─────────────────────────────────────────────────────────
    def build_authorize_url(self, state: str) -> str:
        """生成 IdP authorize URL(state 是 callback 校验用的随机 nonce)。"""
        params = {
            "client_id": self._cfg["client_id"],
            "response_type": "code",
            "redirect_uri": self._cfg["redirect_uri"],
            "scope": self._cfg.get("scope") or _DEFAULT_SCOPE,
            "state": state,
        }
        return f"{self._cfg['authorize_endpoint']}?{urlencode(params)}"

    @staticmethod
    def generate_state() -> tuple[str, str]:
        """生成 state token(nonce)+ 内部 payload(供 callback 校验)。

        实现:state = random nonce;cookie 'ms_oidc_state' 存 nonce,
        callback 比对 state == nonce。next 走单独 cookie 'ms_oidc_next'。
        """
        nonce = secrets.token_urlsafe(24)
        return nonce, nonce  # 简化:state 即 nonce

    async def exchange_code_for_token(self, code: str) -> dict[str, Any]:
        """code → access_token(标准 OAuth2 authorization_code,凭据 in body)。"""
        resp = await self._http.post(
            self._cfg["token_endpoint"],
            data={
                "grant_type": "authorization_code",
                "client_id": self._cfg["client_id"],
                "client_secret": self._cfg["client_secret"],
                "code": code,
                "redirect_uri": self._cfg["redirect_uri"],
            },
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        resp.raise_for_status()
        data: dict[str, Any] = resp.json()
        if "access_token" not in data:
            raise RuntimeError(f"OIDC token exchange failed: {data}")
        return data

    async def fetch_userinfo(self, access_token: str) -> dict[str, Any]:
        """access_token → user info(sub / name / email / picture)。"""
        resp = await self._http.get(
            self._cfg["userinfo_endpoint"],
            headers={"Authorization": f"Bearer {access_token}"},
        )
        resp.raise_for_status()
        return resp.json()

    async def _find_by_sub(self, db: AsyncSession, sub: str) -> User | None:
        res = await db.execute(select(User).where(User.oidc_sub == sub))
        return res.scalar_one_or_none()

    async def _find_by_email(self, db: AsyncSession, email: str) -> User | None:
        """按 email 找已有本地账号(email 列无唯一约束,理论上可能多命中)。

        多命中时取 created_at 最早的一个(确定性),并告警供排查。
        """
        res = await db.execute(select(User).where(func.lower(User.email) == email))
        matches = list(res.scalars().all())
        if len(matches) > 1:
            log.warning("OIDC email %s 命中 %d 个本地账号,取最早创建的一个", email, len(matches))
            return min(matches, key=lambda u: u.created_at)
        return matches[0] if matches else None

    async def _email_taken_by_other(
        self, db: AsyncSession, email: str, *, exclude_id: uuid.UUID | None = None,
    ) -> bool:
        """lower(email) 占用预检(邮箱账号方案 §5.3.5 OIDC 段,B1 最小守卫)。

        exclude_id 排除本人(同步分支比对自身邮箱不算占用)。命中多条时
        limit(1) 即可 —— 只回答「是否被占」,归属排查走管理后台。
        """
        stmt = select(User.id).where(func.lower(User.email) == email).limit(1)
        if exclude_id is not None:
            stmt = stmt.where(User.id != exclude_id)
        return (await db.execute(stmt)).first() is not None

    async def upsert_user_from_userinfo(
        self, db: AsyncSession, userinfo: dict[str, Any]
    ) -> User:
        """IdP userinfo → upsert users 表,返 ORM User 对象。

        匹配顺序(F16:防 IdP 首登时已有本地账号被重复建号):
          1. oidc_sub(provider 的 sub claim;ADR-0007 起 OIDC 用户的身份匹配键)
          2. email 兜底关联 — sub miss 时,若 userinfo 带 email,先按 email
             找已有本地账号并绑定 oidc_sub;仅当该账号尚未绑定其它 oidc_sub
             才关联(避免把已属于别的 IdP 身份的账号抢过来)。
          两路都 miss → 新建 User。
        """
        sub = userinfo.get(self._claim("sub")) or userinfo.get("sub")
        if not sub:
            raise RuntimeError(f"OIDC userinfo missing sub: {userinfo}")
        email = (userinfo.get(self._claim("email")) or userinfo.get("email") or "").strip().lower()

        user = await self._find_by_sub(db, sub)
        if user is None and email:
            user = await self._find_by_email(db, email)
            if user is not None and user.oidc_sub not in (None, sub):
                log.warning(
                    "OIDC email %s 已被 oidc_sub=%s 占用,不抢占,按新用户建号",
                    email, user.oidc_sub,
                )
                user = None

        if user is None:
            default_org = self._settings.default_organization_id
            org_uuid = uuid.UUID(default_org) if default_org else None
            new_name = userinfo.get(self._claim("name")) or userinfo.get("name") or "unknown"
            # B1 最小写入守卫(方案 §5.3.5 OIDC 段):email 已 lower(见上);被
            # 其他账号占用时跳过写入(建号不带 email),不因唯一索引 500。
            new_email = email or None
            if new_email and await self._email_taken_by_other(db, new_email):
                log.warning("OIDC email occupied by other account, create without email: sub=%s", sub)
                new_email = None
            user = User(
                oidc_sub=sub,
                name=new_name,
                email=new_email,
                is_active=True,
                organization_id=org_uuid,
            )
            db.add(user)
            try:
                await db.commit()
            except IntegrityError:
                # 占用预检与 commit 之间的竞态撞 lower(email) 唯一索引(迁移
                # 0021):回滚后去 email 重建(sub 绑定必须落库)
                await db.rollback()
                log.warning("OIDC create user hit email unique index, retry without email: sub=%s", sub)
                user = User(
                    oidc_sub=sub,
                    name=new_name,
                    email=None,
                    is_active=True,
                    organization_id=org_uuid,
                )
                db.add(user)
                await db.commit()
            await db.refresh(user)
            log.info("created user from OIDC sub=%s name=%s org=%s",
                     sub, user.name, org_uuid)
            return user

        # 命中已有用户:email 兜底关联时补绑 sub;同步可能变化的字段
        changed = False
        if user.oidc_sub != sub:
            user.oidc_sub = sub
            changed = True
        new_name = userinfo.get(self._claim("name")) or userinfo.get("name")
        if new_name and user.name != new_name:
            user.name = new_name
            changed = True
        # B1 最小写入守卫(方案 §5.3.5 OIDC 段):email lower 后比对;被他人
        # 占用(排除本人)→ 跳过写入保留旧邮箱,不 500。
        if email and email != (user.email or "").strip().lower():
            if await self._email_taken_by_other(db, email, exclude_id=user.id):
                log.warning("OIDC email occupied by other account, keep old email: sub=%s user=%s", sub, user.id)
            else:
                user.email = email
                changed = True
        # backfill organization_id(老 user 没绑 org)
        if user.organization_id is None and self._settings.default_organization_id:
            user.organization_id = uuid.UUID(self._settings.default_organization_id)
            changed = True
        if changed:
            try:
                await db.commit()
            except IntegrityError:
                # email 撞唯一索引(与占用预检的竞态窗口):回滚后保留旧邮箱,
                # 重放其余字段同步(sub 绑定不能因邮箱冲突丢失),不 500。
                # ⚠️ rollback 会把实例属性过期:AsyncSession 下直接读属性触发
                # 同步懒加载 → MissingGreenlet,必须先 refresh 回到库内当前态。
                await db.rollback()
                await db.refresh(user)
                log.warning("OIDC sync hit email unique index, keep old email: sub=%s user=%s", sub, user.id)
                if user.oidc_sub != sub:
                    user.oidc_sub = sub
                if new_name and user.name != new_name:
                    user.name = new_name
                if user.organization_id is None and self._settings.default_organization_id:
                    user.organization_id = uuid.UUID(self._settings.default_organization_id)
                await db.commit()
            await db.refresh(user)

        return user

    # ─── session JWT ───────────────────────────────────────────────────────
    def encode_session(self, user: User) -> str:
        now = datetime.now(timezone.utc)
        payload = {
            "sub": str(user.id),
            "name": user.name,
            "iat": int(now.timestamp()),
            "exp": int((now + timedelta(seconds=self._settings.session_jwt_ttl_seconds)).timestamp()),
        }
        return jwt.encode(
            payload,
            self._settings.session_jwt_secret,
            algorithm=self._settings.session_jwt_alg,
        )

    def decode_session(self, token: str) -> dict[str, Any]:
        try:
            return jwt.decode(
                token,
                self._settings.session_jwt_secret,
                algorithms=[self._settings.session_jwt_alg],
            )
        except JWTError as e:
            raise ValueError(f"invalid session token: {e}") from e


async def create_auth_service(settings: Settings) -> OIDCService:
    return OIDCService(settings)
