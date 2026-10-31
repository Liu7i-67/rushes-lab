"""会话 ↔ PAT 绑定表:TTL 淘汰、容量上限、换 PAT 语义的地基。"""

from __future__ import annotations

import pytest

from ms_mcp.session import SessionStore


class FakeClock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


def test_bind_and_get() -> None:
    store = SessionStore(max_sessions=4, ttl_seconds=60)
    store.bind("s1", "mspat_a")
    assert store.get("s1") == "mspat_a"
    assert store.get("s2") is None


def test_unbind() -> None:
    store = SessionStore(max_sessions=4, ttl_seconds=60)
    store.bind("s1", "mspat_a")
    store.unbind("s1")
    assert store.get("s1") is None


def test_idle_ttl_evicts_binding() -> None:
    clock = FakeClock()
    store = SessionStore(max_sessions=4, ttl_seconds=30, clock=clock)
    store.bind("s1", "mspat_a")
    clock.advance(29)
    assert store.get("s1") == "mspat_a"   # 访问续活
    clock.advance(31)
    assert store.get("s1") is None
    assert len(store) == 0


def test_touch_extends_lifetime() -> None:
    clock = FakeClock()
    store = SessionStore(max_sessions=4, ttl_seconds=30, clock=clock)
    store.bind("s1", "mspat_a")
    for _ in range(5):
        clock.advance(20)
        assert store.get("s1") == "mspat_a"


def test_cap_evicts_lru_binding() -> None:
    clock = FakeClock()
    store = SessionStore(max_sessions=2, ttl_seconds=600, clock=clock)
    store.bind("s1", "mspat_a")
    clock.advance(1)
    store.bind("s2", "mspat_b")
    clock.advance(1)
    assert store.get("s1") == "mspat_a"     # s1 变为最近使用
    clock.advance(1)
    store.bind("s3", "mspat_c")             # 容量满 → 淘汰最久未用的 s2
    assert store.get("s2") is None
    assert store.get("s1") == "mspat_a"
    assert store.get("s3") == "mspat_c"
    assert len(store) == 2


def test_len_purges_expired() -> None:
    clock = FakeClock()
    store = SessionStore(max_sessions=4, ttl_seconds=10, clock=clock)
    store.bind("s1", "mspat_a")
    store.bind("s2", "mspat_b")
    clock.advance(11)
    assert len(store) == 0


@pytest.mark.parametrize(("cap", "ttl"), [(0, 10), (1, 0), (1, -1)])
def test_invalid_constructor_args(cap: int, ttl: float) -> None:
    with pytest.raises(ValueError):
        SessionStore(max_sessions=cap, ttl_seconds=ttl)
