"""FakeRedis — redis.asyncio 命令面子集的内存替身(纯单元测试注入用)。

与 tests/test_local_auth.py 的内联 fake 并存(那个只服务旧用例,勿迁移);本实现
面向 phone_verification(方案 §10.1 FakeRedis 注入路径)扩建命令面:
  SET NX EX / SETEX / HSET / HGET / HGETALL / HINCRBY / PTTL / TTL / 条件 EXPIRE
  / INCR / DECR / EXISTS / EVAL(Lua 回调分派)+ Pipeline 同步排队回放。

TTL 语义按注入时钟惰性过期(任何读写前清掉到期键),键中途过期竞态、PTTL
毫秒上取整、冷却窗口推进均可测;时钟由 FakeClock 手拨,不依赖真实时间。

Lua 注入路径(方案 §10.1 钉死):真 Redis 走 redis.eval(LUA_SCRIPTS[name], ...);
测试以 lua_handlers={**脚本原文**: 回调} 注册,eval 按脚本原文精确匹配分派,
回调语义逐行对照 Lua 实现——两侧同一语义;未注册的脚本 eval 报清晰错误。
"""

from __future__ import annotations

import math
from collections.abc import Awaitable, Callable
from typing import Any

# handler(fake, keys, args) -> Redis 返回形状(与 decode_responses=True 对齐:
# 数字返回 int,Lua 字符串返回 str)
LuaHandler = Callable[["FakeRedis", list[str], list[str]], Awaitable[Any]]


class FakeClock:
    """可手拨的固定钟(浮点 epoch 秒);测试用它驱动 TTL 过期与冷却窗口。"""

    def __init__(self, start: float = 1_000_000.0) -> None:
        self.now = start

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        """拨钟前进(可传小数,PTTL 上取整口径靠它验证)。"""
        self.now += seconds


class FakeRedis:
    """redis.asyncio 接口子集;TTL 惰性过期,decode_responses=True 形状(str)。"""

    def __init__(
        self,
        clock: Callable[[], float] | None = None,
        lua_handlers: dict[str, LuaHandler] | None = None,
    ) -> None:
        self._store: dict[str, str] = {}
        self._hashes: dict[str, dict[str, str]] = {}
        self._expire_at: dict[str, float] = {}
        self._clock = clock or (lambda: 0.0)
        self.lua_handlers: dict[str, LuaHandler] = dict(lua_handlers or {})

    # ─── 内部:惰性过期(任何读写前先清掉到期键,模拟 Redis 键到期即失)─────
    def _live(self, key: str) -> bool:
        deadline = self._expire_at.get(key)
        if deadline is not None and self._clock() >= deadline:
            self._store.pop(key, None)
            self._hashes.pop(key, None)
            self._expire_at.pop(key, None)
        return key in self._store or key in self._hashes

    # ─── string ────────────────────────────────────────────────────────────
    async def get(self, key: str) -> str | None:
        return self._store.get(key) if self._live(key) else None

    async def set(
        self,
        key: str,
        value: str,
        ex: int | None = None,
        nx: bool = False,
    ) -> bool | None:
        """对齐 redis-py:NX 撞键返回 None,成功返回 True;不带 ex 的覆盖写清 TTL。"""
        if nx and self._live(key):
            return None
        self._store[key] = value
        self._hashes.pop(key, None)
        if ex is not None:
            self._expire_at[key] = self._clock() + ex
        else:
            self._expire_at.pop(key, None)
        return True

    async def setex(self, key: str, seconds: int, value: str) -> bool:
        self._store[key] = value
        self._hashes.pop(key, None)
        self._expire_at[key] = self._clock() + seconds
        return True

    async def delete(self, *keys: str) -> int:
        n = 0
        for key in keys:
            if self._live(key):
                self._store.pop(key, None)
                self._hashes.pop(key, None)
                self._expire_at.pop(key, None)
                n += 1
        return n

    async def exists(self, *keys: str) -> int:
        return sum(1 for key in keys if self._live(key))

    async def incr(self, key: str) -> int:
        self._live(key)
        nxt = int(self._store.get(key, "0")) + 1
        self._store[key] = str(nxt)
        self._hashes.pop(key, None)
        return nxt  # 新键无 TTL;活键 TTL 保持(Redis 语义)

    async def decr(self, key: str) -> int:
        self._live(key)
        nxt = int(self._store.get(key, "0")) - 1
        self._store[key] = str(nxt)
        self._hashes.pop(key, None)
        return nxt

    async def expire(self, key: str, seconds: int) -> bool:
        """刷新 TTL(Redis 语义:键不存在返回 False,存在则重设 deadline)。"""
        if not self._live(key):
            return False
        self._expire_at[key] = self._clock() + seconds
        return True

    async def ttl(self, key: str) -> int:
        """剩余秒(Redis 口径:-2 缺失 / -1 无过期 / 正数向上取整)。"""
        if not self._live(key):
            return -2
        deadline = self._expire_at.get(key)
        if deadline is None:
            return -1
        return max(1, math.ceil(deadline - self._clock()))

    async def pttl(self, key: str) -> int:
        """剩余毫秒(Redis 口径:-2 缺失 / -1 无过期);供 PTTL 上取整换算测试。"""
        if not self._live(key):
            return -2
        deadline = self._expire_at.get(key)
        if deadline is None:
            return -1
        return int((deadline - self._clock()) * 1000)

    # ─── hash ──────────────────────────────────────────────────────────────
    async def hset(
        self,
        key: str,
        field: str | None = None,
        value: str | None = None,
        mapping: dict[str, str] | None = None,
    ) -> int:
        """返回新增字段数(Redis 语义:更新既有字段不计)。"""
        self._live(key)
        items = {field: value} if field is not None and value is not None else dict(mapping or {})
        if not items:
            raise ValueError("FakeRedis.hset 需要 (field, value) 或 mapping")
        target = self._store.pop(key, None)  # string/hash 同键空间,互斥
        if target is not None:
            self._expire_at.pop(key, None)
        current = self._hashes.setdefault(key, {})
        added = sum(1 for f in items if f not in current)
        current.update(items)
        return added

    async def hget(self, key: str, field: str) -> str | None:
        if not self._live(key):
            return None
        return self._hashes.get(key, {}).get(field)

    async def hgetall(self, key: str) -> dict[str, str]:
        if not self._live(key):
            return {}
        return dict(self._hashes.get(key, {}))

    async def hincrby(self, key: str, field: str, amount: int = 1) -> int:
        """活键 TTL 保持;缺失键新建 hash(无 TTL)——与 Redis 一致。"""
        self._live(key)
        self._store.pop(key, None)
        current = self._hashes.setdefault(key, {})
        nxt = int(current.get(field, "0")) + amount
        current[field] = str(nxt)
        return nxt

    # ─── Lua 注入路径(方案 §10.1)───────────────────────────────────────────
    async def eval(self, script: str, numkeys: int, *keys_and_args: object) -> Any:
        """按脚本原文精确匹配 lua_handlers 分派;未注册报清晰错误(勿静默)。"""
        handler = self.lua_handlers.get(script)
        if handler is None:
            raise RuntimeError(
                "FakeRedis.eval: 未注册该 Lua 脚本的回调 "
                f"(script[:60]={script[:60]!r});测试须以 phone_verification.LUA_SCRIPTS"
                " 的脚本原文为键注册 lua_handlers(方案 §10.1 注入路径)"
            )
        keys = [str(k) for k in keys_and_args[:numkeys]]
        args = [str(a) for a in keys_and_args[numkeys:]]
        return await handler(self, keys, args)

    # ─── pipeline(同步排队,execute 一次回放;顺序即返回顺序)─────────────────
    def pipeline(self) -> FakePipeline:
        return FakePipeline(self)


class FakePipeline:
    """命令同步排队、execute() 顺序回放到宿主 FakeRedis(对齐 redis-py Pipeline)。"""

    def __init__(self, redis: FakeRedis) -> None:
        self._redis = redis
        self._ops: list[tuple[str, tuple[Any, ...], dict[str, Any]]] = []

    def _queue(self, name: str, *args: Any, **kwargs: Any) -> FakePipeline:
        self._ops.append((name, args, kwargs))
        return self

    def get(self, key: str) -> FakePipeline:
        return self._queue("get", key)

    def set(self, key: str, value: str, ex: int | None = None, nx: bool = False) -> FakePipeline:
        return self._queue("set", key, value, ex=ex, nx=nx)

    def setex(self, key: str, seconds: int, value: str) -> FakePipeline:
        return self._queue("setex", key, seconds, value)

    def delete(self, *keys: str) -> FakePipeline:
        return self._queue("delete", *keys)

    def exists(self, *keys: str) -> FakePipeline:
        return self._queue("exists", *keys)

    def incr(self, key: str) -> FakePipeline:
        return self._queue("incr", key)

    def decr(self, key: str) -> FakePipeline:
        return self._queue("decr", key)

    def expire(self, key: str, seconds: int) -> FakePipeline:
        return self._queue("expire", key, seconds)

    def ttl(self, key: str) -> FakePipeline:
        return self._queue("ttl", key)

    def pttl(self, key: str) -> FakePipeline:
        return self._queue("pttl", key)

    def hset(
        self,
        key: str,
        field: str | None = None,
        value: str | None = None,
        mapping: dict[str, str] | None = None,
    ) -> FakePipeline:
        return self._queue("hset", key, field=field, value=value, mapping=mapping)

    def hget(self, key: str, field: str) -> FakePipeline:
        return self._queue("hget", key, field)

    def hgetall(self, key: str) -> FakePipeline:
        return self._queue("hgetall", key)

    def hincrby(self, key: str, field: str, amount: int = 1) -> FakePipeline:
        return self._queue("hincrby", key, field, amount)

    async def execute(self) -> list[Any]:
        out: list[Any] = []
        for name, args, kwargs in self._ops:
            out.append(await getattr(self._redis, name)(*args, **kwargs))
        self._ops.clear()
        return out
