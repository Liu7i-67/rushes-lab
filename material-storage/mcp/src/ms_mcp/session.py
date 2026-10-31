"""会话 ↔ PAT 绑定(纯内存,进程重启即失效;单副本部署)。

Streamable HTTP 的部分客户端只在 initialize 带一次 Authorization,后续请求不带。
因此 ms-mcp 按 `Mcp-Session-Id` 记住该会话的 PAT:后续无 Authorization 时复用;
带不同 PAT 时 401(不自动换绑);绑定缺失 401。

安全约定:**本模块永不记录 session_id / pat 的任何内容**,异常信息也不带。
"""

from __future__ import annotations

import time
from collections.abc import Callable
from dataclasses import dataclass


@dataclass
class _Binding:
    pat: str
    created_at: float
    last_seen: float


class SessionStore:
    """带空闲 TTL 与容量上限的会话表。

    - 每次访问先清理过期绑定(淘汰即清,不留悬挂 PAT);
    - 超过上限时淘汰最久未使用的绑定(LRU),保证新 initialize 能落地;
    - `clock` 可注入,单测用假时钟验证 TTL。
    """

    def __init__(
        self,
        max_sessions: int,
        ttl_seconds: float,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        if max_sessions <= 0:
            raise ValueError("max_sessions must be > 0")
        if ttl_seconds <= 0:
            raise ValueError("ttl_seconds must be > 0")
        self._max = max_sessions
        self._ttl = ttl_seconds
        self._clock = clock
        self._bindings: dict[str, _Binding] = {}

    def __len__(self) -> int:
        self.purge_expired()
        return len(self._bindings)

    def bind(self, session_id: str, pat: str) -> None:
        if not session_id or not pat:
            raise ValueError("session_id / pat must be non-empty")
        now = self._clock()
        self.purge_expired(now=now)
        while len(self._bindings) >= self._max:
            # LRU:淘汰最久未使用的绑定(TTL 未到的会话被容量挤出,须重新 initialize)
            oldest = min(self._bindings, key=lambda sid: self._bindings[sid].last_seen)
            del self._bindings[oldest]
        self._bindings[session_id] = _Binding(pat=pat, created_at=now, last_seen=now)

    def get(self, session_id: str) -> str | None:
        if not session_id:
            return None
        now = self._clock()
        self.purge_expired(now=now)
        binding = self._bindings.get(session_id)
        if binding is None:
            return None
        binding.last_seen = now
        return binding.pat

    def unbind(self, session_id: str) -> None:
        self._bindings.pop(session_id, None)

    def purge_expired(self, *, now: float | None = None) -> int:
        moment = self._clock() if now is None else now
        expired = [
            sid for sid, b in self._bindings.items() if moment - b.last_seen > self._ttl
        ]
        for sid in expired:
            del self._bindings[sid]
        return len(expired)
