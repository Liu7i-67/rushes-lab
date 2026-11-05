"""Audit service — Phase B-2。

写 audit_events 表;ADR-0005 §11.2 Gap 10 / PR #30 修订版。

约定:
- dedup_key 跨系统幂等;格式 <source>:<source_event_id>[:<status>]
  自产事件用 internal:<uuid>(stub key)
- actor snapshot 列冗余记(user 删后审计仍可读)
- trace_id 跨 sidecar 链统一(MinIO event → ffmpeg → dataset B → AI)

认证方式标注(MCP 素材服务 D4/D11;迁移 0020 新增 ``auth_method`` /
``auth_token_id`` 两列):
- ``get_audit`` 把 ``Request`` 传给 ``AuditService``,``write()`` 内**延迟读取**
  ``request.state.auth_method`` / ``auth_token_id`` 作默认值 —— 依赖顺序会随挂载
  方式/端点参数顺序变化(create_upload 的 ``audit`` 排在 ``user`` 之前),统一在
  write() 读,避免隐式顺序耦合把 PAT 上传/下载签发误标成 session;
- **有 request 且非 PAT → 写 ``"session"``(新行不留 NULL)**;**无 request
  (worker/CLI/后台任务)→ 用 contextvar**(``bind_auth_context`` 在
  ``get_current_user`` 成功时绑定;FastAPI BackgroundTasks 与请求同 task 执行,
  context 可继承)→ contextvar 无值 → NULL;
- ``write()`` 的可选 ``auth_method`` / ``auth_token_id`` 参数**仅作显式覆盖**。
"""
from __future__ import annotations

import logging
import urllib.parse
import uuid as uuid_lib
from contextvars import ContextVar
from datetime import UTC, datetime
from typing import Any

from fastapi import Request
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.tables import AuditEvent, User

log = logging.getLogger(__name__)

# 当前请求/任务的认证上下文(method, token_id);deps.get_current_user 成功时绑定。
# 只在**无 request 上下文**的 AuditService 实例(worker / 后台任务 / CLI)生效。
_auth_context: ContextVar[tuple[str, uuid_lib.UUID | None] | None] = ContextVar(
    "audit_auth_context", default=None,
)


def bind_auth_context(method: str, token_id: uuid_lib.UUID | None = None) -> None:
    """绑定当前 task 的认证方式(``"session"`` / ``"pat"``)+ 令牌 id(测试可直调)。"""
    _auth_context.set((method, token_id))


def clear_auth_context() -> None:
    """清除当前 task 的认证上下文(测试钩子;arq worker 任务间不共享 context)。"""
    _auth_context.set(None)


def current_auth_context() -> tuple[str, uuid_lib.UUID | None] | None:
    """读当前 task 的认证上下文(未绑定 = None → 审计写 NULL)。"""
    return _auth_context.get()


class AuditService:
    def __init__(self, session: AsyncSession, request: Request | None = None):
        self._session = session
        self._request = request

    def _default_auth(self) -> tuple[str | None, uuid_lib.UUID | None]:
        """认证列默认值(**每次 write 延迟读**,不缓存:state 可能在构造后才写)。

        - 有 request:``auth_method == "pat"`` → ("pat", token_id);其余
          (含 session/dev)→ ("session", None) —— 新行不留 NULL
        - 无 request:contextvar(worker 保持无值 → NULL)
        """
        if self._request is not None:
            state = self._request.scope.get("state") or {}
            if state.get("auth_method") == "pat":
                token_id = state.get("auth_token_id")
                return "pat", token_id if isinstance(token_id, uuid_lib.UUID) else None
            return "session", None
        ctx = _auth_context.get()
        if ctx is None:
            return None, None
        return ctx[0], ctx[1]

    async def _resolve_actor_snapshot(self, actor_user_id: uuid_lib.UUID | None) -> dict[str, Any]:
        if not actor_user_id:
            return {}
        user = await self._session.get(User, actor_user_id)
        if not user:
            return {}
        return {
            "actor_open_id_snapshot": user.feishu_open_id,
            "actor_name_snapshot": user.name,
            "actor_email_snapshot": user.email,
        }

    async def write(
        self,
        *,
        event_type: str,
        actor_user_id: uuid_lib.UUID | None = None,
        target_asset_id: uuid_lib.UUID | None = None,
        target_project_id: uuid_lib.UUID | None = None,
        target_minio_key: str | None = None,
        dedup_key: str | None = None,
        trace_id: uuid_lib.UUID | None = None,
        request_ip: str | None = None,
        user_agent: str | None = None,
        details: dict[str, Any] | None = None,
        event_time: datetime | None = None,
        auth_method: str | None = None,
        auth_token_id: uuid_lib.UUID | None = None,
        actor_email_snapshot: str | None = None,
    ) -> AuditEvent:
        """写一条审计事件(dedup_key 幂等,独立 commit)。

        ``actor_email_snapshot``(邮箱账号方案 §5.9)是**脱敏覆盖参数**:
        邮箱事件传 ``mask_email(...)`` 值,避免新事件把完整邮箱写进快照列
        (``_resolve_actor_snapshot`` 默认无条件取 ``user.email``)。默认 None
        = 不覆盖,保持既有行为;调用方传 None 与「用户无邮箱」语义等价
        (resolved 快照也是 None)。
        """
        actor_snapshot = await self._resolve_actor_snapshot(actor_user_id)
        if actor_email_snapshot is not None:
            actor_snapshot["actor_email_snapshot"] = actor_email_snapshot
        default_method, default_token_id = self._default_auth()
        record = {
            "id": uuid_lib.uuid4(),
            "event_type": event_type,
            "actor_user_id": actor_user_id,
            **actor_snapshot,
            "target_asset_id": target_asset_id,
            "target_project_id": target_project_id,
            "target_minio_key": target_minio_key,
            "dedup_key": dedup_key or f"internal:{uuid_lib.uuid4()}",
            "trace_id": trace_id,
            "request_ip": request_ip,
            # D4:认证方式两列 —— 显式参数仅作覆盖,默认走 request/contextvar
            "auth_method": auth_method if auth_method is not None else default_method,
            "auth_token_id": (
                auth_token_id if auth_token_id is not None else default_token_id
            ),
            # C2:列宽 String(512) 对齐截断 —— write 是全部审计写入的唯一必经收口
            # (directory.py 有 9 处绕过 ctx 直读 header 的写入路径,只改 deps.py 修
            # 不干净),超长 UA 不截会 insert 失败丢整条审计事件
            "user_agent": user_agent[:512] if user_agent else None,
            "details": details or {},
            "event_time": event_time or datetime.now(UTC),
        }
        # ON CONFLICT(dedup_key)DO NOTHING — 重投幂等
        stmt = pg_insert(AuditEvent).values(**record).on_conflict_do_nothing(
            index_elements=["dedup_key"]
        )
        await self._session.execute(stmt)
        # audit 是 fire-and-forget:get_audit 给我们独立 session,这里独立 commit
        # 否则 session.close() 时事务回滚,event 丢失(历史 systemic bug, iter3 修)
        await self._session.commit()
        return AuditEvent(**record)

    async def upload(self, **kwargs: Any) -> AuditEvent:
        return await self.write(event_type="upload", **kwargs)

    async def download(self, **kwargs: Any) -> AuditEvent:
        return await self.write(event_type="download", **kwargs)

    async def signed_url_issued(self, **kwargs: Any) -> AuditEvent:
        return await self.write(event_type="signed_url_issued", **kwargs)

    async def proxy_download(self, **kwargs: Any) -> AuditEvent:
        return await self.write(event_type="proxy_download", **kwargs)


def decode_minio_event_key(key: str) -> str:
    """MinIO bucket notification key URL-encoded(`/` → `%2F`),P-11。"""
    return urllib.parse.unquote(key)


def mint_trace_id() -> uuid_lib.UUID:
    return uuid_lib.uuid4()
