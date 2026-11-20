"""验证码状态机单元测试(方案 §10.1 本地纯单元)— FakeRedis 注入 + FakeClock 固定钟。

范式照 tests/test_local_auth.py:无外部基础设施,服务函数直调。
真 Redis 走 phone_verification.LUA_SCRIPTS 的真 Lua;本文件以**脚本原文**为键
注册 Python 回调(逐行对照 Lua 语义实现),行为断言全部经由 wrapper(redis.eval)
跑通——真 Lua 与回调两侧同一语义(方案 §10.1 注入路径)。
容器级 API 测试见 test_phone_bind_api.py / test_phone_reset_api.py(B2b,另包)。
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta, timezone

import pytest

from app.services import phone_verification as pv
from app.services.phone_verification import (
    InvalidPhone,
    code_digest,
    code_key,
    cooldown_key,
    daily_key,
    hourly_reset_ip_key,
    hourly_user_key,
)
from tests.helpers.fake_redis import FakeClock, FakeRedis, LuaHandler

SECRET = "unit-test-secret"
PHONE = "13800138000"
UID = "u-1"
UID2 = "u-2"
CODE_TTL = 900
MAX_ATTEMPTS = 5
COOLDOWN = 120


# ─── Lua 同语义回调(逐行对照 phone_verification.LUA_SCRIPTS 实现)─────────────
async def lua_attempt_incr(fake: FakeRedis, keys: list[str], args: list[str]) -> list[object]:
    """对照 attempt_incr:EXISTS 守卫 → HINCRBY → ≥max 连键 DEL → 仅 TTL<0 补 EXPIRE。"""
    key = keys[0]
    max_attempts, fallback_ttl = int(args[0]), int(args[1])
    if not await fake.exists(key):
        return [0, 0]  # 键已缺失:不重建,wrapper 按 expired
    attempts = await fake.hincrby(key, "attempts", 1)
    if attempts >= max_attempts:
        await fake.delete(key)
        return [attempts, 2]  # locked
    if await fake.ttl(key) < 0:
        await fake.expire(key, fallback_ttl)  # 防御补漏,不续期
    return [attempts, 1]  # wrong


async def lua_consume_code(fake: FakeRedis, keys: list[str], args: list[str]) -> list[str]:
    """对照 consume_code:读-比-删一原子;缺失直接 expired(不 HINCRBY 不重建)。"""
    key = keys[0]
    digest, max_attempts, fallback_ttl = args[0], int(args[1]), int(args[2])
    if not await fake.exists(key):
        return ["expired"]
    stored = await fake.hget(key, "code_hash")
    user_id = await fake.hget(key, "user_id") or ""
    if stored is not None and len(stored) == len(digest) and stored == digest:  # 等长短路比较
        await fake.delete(key)
        return ["ok", user_id]
    attempts = await fake.hincrby(key, "attempts", 1)
    if attempts >= max_attempts:
        await fake.delete(key)
        return ["locked", str(attempts)]
    if await fake.ttl(key) < 0:
        await fake.expire(key, fallback_ttl)
    return ["wrong", str(attempts)]


async def lua_rollback_quota(fake: FakeRedis, keys: list[str], args: list[str]) -> str:
    """对照 rollback_quota:GET→判→DECRBY 一原子,不为负。"""
    key = keys[0]
    if int(await fake.get(key) or 0) > 0:
        await fake.decr(key)
    return str(int(await fake.get(key) or 0))


LUA_HANDLERS: dict[str, LuaHandler] = {
    pv.LUA_SCRIPTS["attempt_incr"]: lua_attempt_incr,
    pv.LUA_SCRIPTS["consume_code"]: lua_consume_code,
    pv.LUA_SCRIPTS["rollback_quota"]: lua_rollback_quota,
}


def make_fake() -> tuple[FakeRedis, FakeClock]:
    clock = FakeClock(1_000_000.0)
    return FakeRedis(clock=clock, lua_handlers=dict(LUA_HANDLERS)), clock


# ─── D5 归一化 ─────────────────────────────────────────────────────────────────
class TestNormalizePhone:
    def test_valid_plain(self) -> None:
        assert pv.normalize_phone("13800138000") == "13800138000"

    def test_strips_spaces(self) -> None:
        assert pv.normalize_phone("  138 0013 8000 ") == "13800138000"

    def test_strips_hyphens_and_dots(self) -> None:
        assert pv.normalize_phone("138-0013-8000") == "13800138000"
        assert pv.normalize_phone("138.0013.8000") == "13800138000"
        assert pv.normalize_phone("138-0013.8000") == "13800138000"

    def test_plus86_prefix_with_separators(self) -> None:
        assert pv.normalize_phone("+86 138-0013-8000") == "13800138000"

    def test_86_prefix(self) -> None:
        assert pv.normalize_phone("8613800138000") == "13800138000"

    def test_second_digit_valid_range(self) -> None:
        for second in "3456789":
            assert pv.normalize_phone(f"1{second}012345678")[:2] == f"1{second}"

    def test_invalid_empty(self) -> None:
        with pytest.raises(InvalidPhone):
            pv.normalize_phone("   ")

    def test_invalid_wrong_length(self) -> None:
        for raw in ("1380013800", "138001380001", "+861380013800"):
            with pytest.raises(InvalidPhone):
                pv.normalize_phone(raw)

    def test_invalid_leading_digit(self) -> None:
        for raw in ("23800138000", "10000138000", "12345678901"):
            with pytest.raises(InvalidPhone):
                pv.normalize_phone(raw)

    def test_invalid_non_digit_after_strip(self) -> None:
        with pytest.raises(InvalidPhone):
            pv.normalize_phone("138-abc-8000")

    def test_invalid_phone_is_value_error(self) -> None:
        assert issubclass(InvalidPhone, ValueError)


# ─── 脱敏 ──────────────────────────────────────────────────────────────────────
class TestMaskPhone:
    def test_spec_format(self) -> None:
        assert pv.mask_phone("13800138000") == "138****8000"

    def test_another_number(self) -> None:
        assert pv.mask_phone("19912345678") == "199****5678"


# ─── D3 码生成 ─────────────────────────────────────────────────────────────────
class TestGenerateCode:
    def test_length_and_charset(self) -> None:
        letters = "ABCDEFGHJKMNPQRSTUVWXYZ"
        full = letters + "23456789"
        for _ in range(1000):
            code = pv.generate_code()
            assert len(code) == 6
            assert set(code) <= set(full), "出现字母表外字符"
            assert code[0] in letters, "首位必须是字母子集"
            assert not any(ch in "ILO01" for ch in code), "混入易混淆字符"

    def test_1000_samples_none_all_digit(self) -> None:
        """首位定字母保底:纯数字(会被阿里云模板校验拒,钉子 6)根除。"""
        assert not any(pv.generate_code().isdigit() for _ in range(1000))


# ─── D3 HMAC ──────────────────────────────────────────────────────────────────
class TestCodeDigest:
    def test_deterministic(self) -> None:
        assert code_digest("AB23CD", SECRET) == code_digest("AB23CD", SECRET)

    def test_differs_by_secret(self) -> None:
        assert code_digest("AB23CD", SECRET) != code_digest("AB23CD", "other-secret")

    def test_differs_by_code(self) -> None:
        assert code_digest("AB23CD", SECRET) != code_digest("AB23CE", SECRET)

    def test_sha256_hex_len(self) -> None:
        digest = code_digest("AB23CD", SECRET)
        assert len(digest) == 64
        int(digest, 16)  # 合法 hex


# ─── 码 hash 存取 ──────────────────────────────────────────────────────────────
class TestIssueAndRead:
    async def test_roundtrip(self) -> None:
        fake, _ = make_fake()
        code = await pv.issue_code(
            fake,
            scene="bind",
            phone=PHONE,
            user_id=UID,
            ttl_seconds=CODE_TTL,
            secret=SECRET,
        )
        stored = await pv.read_code(fake, scene="bind", phone=PHONE)
        assert stored is not None
        assert stored["code_hash"] == code_digest(code, SECRET)
        assert stored["attempts"] == "0"
        assert stored["user_id"] == UID
        assert await fake.ttl(code_key("bind", PHONE)) == CODE_TTL

    async def test_read_missing_returns_none(self) -> None:
        fake, _ = make_fake()
        assert await pv.read_code(fake, scene="reset", phone=PHONE) is None

    async def test_overwrite_replaces_old_hash(self) -> None:
        """覆盖写:旧 hash(含错误计数)整体被替换,旧码提交按 wrong 计。"""
        fake, _ = make_fake()
        old = await pv.issue_code(
            fake,
            scene="bind",
            phone=PHONE,
            user_id=UID,
            ttl_seconds=CODE_TTL,
            secret=SECRET,
        )
        assert (
            await pv.verify_code(
                fake,
                scene="bind",
                phone=PHONE,
                submitted="XXXXXX",
                secret=SECRET,
                max_attempts=MAX_ATTEMPTS,
            )
        ).status == "wrong"  # attempts=1
        new = await pv.issue_code(
            fake,
            scene="bind",
            phone=PHONE,
            user_id=UID2,
            ttl_seconds=CODE_TTL,
            secret=SECRET,
        )
        stored = await pv.read_code(fake, scene="bind", phone=PHONE)
        assert stored is not None
        assert stored["code_hash"] == code_digest(new, SECRET)
        assert stored["attempts"] == "0", "覆盖写重置错误计数"
        assert stored["user_id"] == UID2
        assert old != new
        assert (
            await pv.verify_code(
                fake,
                scene="bind",
                phone=PHONE,
                submitted=old,
                secret=SECRET,
                max_attempts=MAX_ATTEMPTS,
            )
        ).status == "wrong", "旧码已失效"
        assert (
            await pv.verify_code(
                fake,
                scene="bind",
                phone=PHONE,
                submitted=new,
                secret=SECRET,
                max_attempts=MAX_ATTEMPTS,
            )
        ).status == "ok"


# ─── bind 口径 verify_code(§5.3 步骤2)─────────────────────────────────────────
class TestVerifyCode:
    async def _issue(self, fake: FakeRedis) -> str:
        return await pv.issue_code(
            fake,
            scene="bind",
            phone=PHONE,
            user_id=UID,
            ttl_seconds=CODE_TTL,
            secret=SECRET,
        )

    async def test_ok_keeps_key(self) -> None:
        """命中返回 ok + stored user_id,且**不删码键**(bind 写库成功后 router 消费)。"""
        fake, _ = make_fake()
        code = await self._issue(fake)
        result = await pv.verify_code(
            fake,
            scene="bind",
            phone=PHONE,
            submitted=code,
            secret=SECRET,
            max_attempts=MAX_ATTEMPTS,
        )
        assert result.status == "ok"
        assert result.user_id == UID
        assert await pv.read_code(fake, scene="bind", phone=PHONE) is not None

    async def test_ok_tolerates_lowercase_and_spaces(self) -> None:
        """服务端统一 strip().upper() 再比对:手输小写/带空格不烧 attempts。"""
        fake, _ = make_fake()
        code = await self._issue(fake)
        result = await pv.verify_code(
            fake,
            scene="bind",
            phone=PHONE,
            submitted=f" {code.lower()} ",
            secret=SECRET,
            max_attempts=MAX_ATTEMPTS,
        )
        assert result.status == "ok"

    async def test_expired_when_missing(self) -> None:
        fake, _ = make_fake()
        result = await pv.verify_code(
            fake,
            scene="bind",
            phone=PHONE,
            submitted="AB23CD",
            secret=SECRET,
            max_attempts=MAX_ATTEMPTS,
        )
        assert result.status == "expired"

    async def test_wrong_increments_attempts(self) -> None:
        fake, _ = make_fake()
        await self._issue(fake)
        first = await pv.verify_code(
            fake,
            scene="bind",
            phone=PHONE,
            submitted="XXXXXX",
            secret=SECRET,
            max_attempts=MAX_ATTEMPTS,
        )
        second = await pv.verify_code(
            fake,
            scene="bind",
            phone=PHONE,
            submitted="YYYYYY",
            secret=SECRET,
            max_attempts=MAX_ATTEMPTS,
        )
        assert first.status == "wrong" and first.attempts == 1
        assert second.status == "wrong" and second.attempts == 2

    async def test_fifth_wrong_locks_and_deletes_key(self) -> None:
        fake, _ = make_fake()
        await self._issue(fake)
        statuses = [
            (
                await pv.verify_code(
                    fake,
                    scene="bind",
                    phone=PHONE,
                    submitted=f"WRONG{i}",
                    secret=SECRET,
                    max_attempts=MAX_ATTEMPTS,
                )
            ).status
            for i in range(5)
        ]
        assert statuses == ["wrong", "wrong", "wrong", "wrong", "locked"]
        assert await pv.read_code(fake, scene="bind", phone=PHONE) is None, "locked 连码键一起 DEL"

    async def test_mid_expiry_race_returns_expired_without_rebuild(self) -> None:
        """比对与计数之间键过期:EXISTS 守卫按 missing→expired,不重建键。"""
        fake, clock = make_fake()
        code = await self._issue(fake)
        clock.advance(CODE_TTL + 1)
        result = await pv.verify_code(
            fake,
            scene="bind",
            phone=PHONE,
            submitted=code,
            secret=SECRET,
            max_attempts=MAX_ATTEMPTS,
        )
        assert result.status == "expired"
        assert await fake.exists(code_key("bind", PHONE)) == 0, "不重建"

    async def test_wrong_does_not_renew_ttl(self) -> None:
        """TTL 不续期口径:错误多次后码键 TTL 不被刷新(条件 EXPIRE 仅 TTL<0)。"""
        fake, clock = make_fake()
        await self._issue(fake)
        clock.advance(400)
        for i in range(2):
            await pv.verify_code(
                fake,
                scene="bind",
                phone=PHONE,
                submitted=f"WRONG{i}",
                secret=SECRET,
                max_attempts=MAX_ATTEMPTS,
            )
        assert await fake.pttl(code_key("bind", PHONE)) == 500_000, "TTL 漂移 = 续期漏洞"
        assert await fake.ttl(code_key("bind", PHONE)) == 500

    async def test_conditional_expire_fills_missing_ttl(self) -> None:
        """防御分支:键无 TTL(TTL<0)时补 EXPIRE 兜底(正常路径不出现)。"""
        fake, _ = make_fake()
        await fake.hset(
            code_key("bind", PHONE),
            mapping={
                "code_hash": code_digest("AB23CD", SECRET),
                "attempts": "0",
                "user_id": UID,
            },
        )
        result = await pv.verify_code(
            fake,
            scene="bind",
            phone=PHONE,
            submitted="XXXXXX",
            secret=SECRET,
            max_attempts=MAX_ATTEMPTS,
        )
        assert result.status == "wrong"
        assert await fake.ttl(code_key("bind", PHONE)) == pv._CODE_TTL_FALLBACK_SECONDS


# ─── reset 口径 consume_code(§5.4 步骤1,原子消费)────────────────────────────
class TestConsumeCode:
    async def _issue(self, fake: FakeRedis) -> str:
        return await pv.issue_code(
            fake,
            scene="reset",
            phone=PHONE,
            user_id=UID,
            ttl_seconds=CODE_TTL,
            secret=SECRET,
        )

    async def test_ok_consumes_atomically(self) -> None:
        """命中即消费:连 user_id 一起返回,码键已删(并发双 confirm 只有一次生效)。"""
        fake, _ = make_fake()
        code = await self._issue(fake)
        result = await pv.consume_code(
            fake,
            scene="reset",
            phone=PHONE,
            submitted=code,
            secret=SECRET,
            max_attempts=MAX_ATTEMPTS,
        )
        assert result.status == "ok"
        assert result.user_id == UID
        assert await pv.read_code(fake, scene="reset", phone=PHONE) is None
        assert await fake.exists(code_key("reset", PHONE)) == 0

    async def test_ok_tolerates_lowercase(self) -> None:
        fake, _ = make_fake()
        code = await self._issue(fake)
        result = await pv.consume_code(
            fake,
            scene="reset",
            phone=PHONE,
            submitted=code.lower(),
            secret=SECRET,
            max_attempts=MAX_ATTEMPTS,
        )
        assert result.status == "ok"

    async def test_expired_when_missing(self) -> None:
        fake, _ = make_fake()
        result = await pv.consume_code(
            fake,
            scene="reset",
            phone=PHONE,
            submitted="AB23CD",
            secret=SECRET,
            max_attempts=MAX_ATTEMPTS,
        )
        assert result.status == "expired"

    async def test_wrong_keeps_key_usable(self) -> None:
        fake, _ = make_fake()
        code = await self._issue(fake)
        result = await pv.consume_code(
            fake,
            scene="reset",
            phone=PHONE,
            submitted="XXXXXX",
            secret=SECRET,
            max_attempts=MAX_ATTEMPTS,
        )
        assert result.status == "wrong"
        assert result.attempts == 1
        assert await pv.read_code(fake, scene="reset", phone=PHONE) is not None, "wrong 不删键"
        assert (
            await pv.consume_code(
                fake,
                scene="reset",
                phone=PHONE,
                submitted=code,
                secret=SECRET,
                max_attempts=MAX_ATTEMPTS,
            )
        ).status == "ok", "错一次后正确码仍可用"

    async def test_fifth_wrong_locks_and_deletes_key(self) -> None:
        fake, _ = make_fake()
        await self._issue(fake)
        statuses = [
            (
                await pv.consume_code(
                    fake,
                    scene="reset",
                    phone=PHONE,
                    submitted=f"WRONG{i}",
                    secret=SECRET,
                    max_attempts=MAX_ATTEMPTS,
                )
            ).status
            for i in range(5)
        ]
        assert statuses == ["wrong", "wrong", "wrong", "wrong", "locked"]
        assert await pv.read_code(fake, scene="reset", phone=PHONE) is None

    async def test_expiry_race_returns_expired(self) -> None:
        """过期竞态:键不存在直接 expired,不做 HINCRBY 不重建。"""
        fake, clock = make_fake()
        code = await self._issue(fake)
        clock.advance(CODE_TTL + 1)
        result = await pv.consume_code(
            fake,
            scene="reset",
            phone=PHONE,
            submitted=code,
            secret=SECRET,
            max_attempts=MAX_ATTEMPTS,
        )
        assert result.status == "expired"
        assert await fake.exists(code_key("reset", PHONE)) == 0


# ─── 冷却(SET NX EX + PTTL 上取整)─────────────────────────────────────────────
class TestCooldown:
    async def test_acquire_returns_none_and_sets_key(self) -> None:
        fake, _ = make_fake()
        assert (
            await pv.acquire_cooldown(
                fake,
                scene="bind",
                phone=PHONE,
                cooldown_seconds=COOLDOWN,
            )
            is None
        )
        assert await fake.ttl(cooldown_key("bind", PHONE)) == COOLDOWN

    async def test_second_acquire_returns_remaining(self) -> None:
        fake, _ = make_fake()
        await pv.acquire_cooldown(fake, scene="bind", phone=PHONE, cooldown_seconds=COOLDOWN)
        assert (
            await pv.acquire_cooldown(
                fake,
                scene="bind",
                phone=PHONE,
                cooldown_seconds=COOLDOWN,
            )
            == COOLDOWN
        )

    async def test_pttl_ceil_rounding(self) -> None:
        """PTTL 毫秒上取整:剩 89.5s → 90(漏换算先例见 local_auth.py)。"""
        fake, clock = make_fake()
        await pv.acquire_cooldown(fake, scene="bind", phone=PHONE, cooldown_seconds=COOLDOWN)
        clock.advance(30.5)
        assert await fake.pttl(cooldown_key("bind", PHONE)) == 89_500
        assert (
            await pv.acquire_cooldown(
                fake,
                scene="bind",
                phone=PHONE,
                cooldown_seconds=COOLDOWN,
            )
            == 90
        )

    async def test_acquire_again_after_expiry(self) -> None:
        fake, clock = make_fake()
        await pv.acquire_cooldown(fake, scene="bind", phone=PHONE, cooldown_seconds=COOLDOWN)
        clock.advance(COOLDOWN + 1)
        assert (
            await pv.acquire_cooldown(
                fake,
                scene="bind",
                phone=PHONE,
                cooldown_seconds=COOLDOWN,
            )
            is None
        ), "冷却过期后可再抢"

    async def test_pttl_negative_falls_back_to_full_window(self) -> None:
        """PTTL<0(竞态过期 -2 / 无过期 -1)回退整段冷却,不放行再吃一次拒绝。"""
        fake, _ = make_fake()
        await fake.set(cooldown_key("bind", PHONE), "1")  # 无 TTL(PTTL=-1)
        assert (
            await pv.acquire_cooldown(
                fake,
                scene="bind",
                phone=PHONE,
                cooldown_seconds=COOLDOWN,
            )
            == COOLDOWN
        )


# ─── 三层配额(日界 UTC+8 固定偏移 / 小时桶 / D9 回滚)──────────────────────────
class TestQuotas:
    def test_daily_key_utc8_fixed_offset(self) -> None:
        utc8 = timezone(timedelta(hours=8))
        at_2330 = datetime(2026, 11, 20, 23, 30, tzinfo=utc8)
        assert pv.daily_key("bind", PHONE, at_2330) == f"sms:day:bind:{PHONE}:20261120"
        # 同一瞬间按 UTC 是 16:30,UTC+8 已是次日(固定偏移,不用 ZoneInfo)
        same_instant_utc = datetime(2026, 11, 20, 16, 30, tzinfo=UTC)
        assert pv.daily_key("reset", PHONE, same_instant_utc) == f"sms:day:reset:{PHONE}:20261121"
        # naive datetime 按 UTC 处理(调用方约定)
        assert pv.daily_key("bind", PHONE, datetime(2026, 11, 20, 16, 30)) == (
            f"sms:day:bind:{PHONE}:20261121"
        )

    def test_hourly_bucket_keys(self) -> None:
        two_days_three_hours = datetime(1970, 1, 2, 3, 0, tzinfo=UTC)
        assert pv.hourly_user_key(UID, two_days_three_hours) == f"sms:u:{UID}:27"
        assert pv.hourly_reset_ip_key("10.0.0.1", two_days_three_hours) == "sms:ip:reset:10.0.0.1:27"

    async def test_incr_daily_counts_and_window(self) -> None:
        fake, _ = make_fake()
        now = datetime(2026, 11, 20, 23, 30, tzinfo=timezone(timedelta(hours=8)))
        assert await pv.incr_daily(fake, scene="bind", phone=PHONE, now=now) == 1
        assert await pv.incr_daily(fake, scene="bind", phone=PHONE, now=now) == 2
        assert await fake.ttl(daily_key("bind", PHONE, now)) == 1800, "EXPIRE 到 UTC+8 当日 24:00"
        midnight = datetime(2026, 11, 21, 0, 0, tzinfo=timezone(timedelta(hours=8)))
        fresh = FakeRedis(clock=FakeClock())
        await pv.incr_daily(fresh, scene="bind", phone=PHONE, now=midnight)
        assert await fresh.ttl(daily_key("bind", PHONE, midnight)) == 24 * 3600

    async def test_incr_hourly_counts_and_window(self) -> None:
        fake, _ = make_fake()
        bucket = hourly_user_key(UID, datetime(2026, 11, 20, tzinfo=UTC))
        assert await pv.incr_hourly(fake, bucket) == 1
        assert await pv.incr_hourly(fake, bucket) == 2
        assert await fake.ttl(bucket) == 3600

    async def test_rollback_quota_never_negative(self) -> None:
        fake, _ = make_fake()
        bucket = hourly_reset_ip_key("10.0.0.1", datetime(2026, 11, 20, tzinfo=UTC))
        for _ in range(3):
            await pv.incr_hourly(fake, bucket)
        await pv.rollback_quota(fake, bucket)
        assert await fake.get(bucket) == "2"
        await pv.rollback_quota(fake, bucket)
        await pv.rollback_quota(fake, bucket)
        assert await fake.get(bucket) == "0", "回滚到底"
        await pv.rollback_quota(fake, bucket)  # 多滚不减他人计数、不穿负
        assert await fake.get(bucket) == "0"

    async def test_rollback_multiple_keys_and_missing(self) -> None:
        fake, _ = make_fake()
        b1 = hourly_user_key(UID, datetime(2026, 11, 20, tzinfo=UTC))
        b2 = hourly_reset_ip_key("10.0.0.1", datetime(2026, 11, 20, tzinfo=UTC))
        await pv.incr_hourly(fake, b1)
        await pv.incr_hourly(fake, b2)
        await pv.incr_hourly(fake, b2)
        await pv.rollback_quota(fake, b1, b2)
        assert await fake.get(b1) == "0"
        assert await fake.get(b2) == "1", "只滚本次新增,不动他人计数"
        await pv.rollback_quota(fake, "sms:day:bind:missing-key:20261120")  # 缺键 no-op 不报错


# ─── Lua 注册表与注入路径一致性(§10.1)─────────────────────────────────────────
class TestLuaRegistry:
    def test_scripts_complete_and_callable_backed(self) -> None:
        assert set(pv.LUA_SCRIPTS) == {"attempt_incr", "consume_code", "rollback_quota"}
        assert all("redis.call" in src for src in pv.LUA_SCRIPTS.values()), "须是真 Lua 源文本"
        assert set(LUA_HANDLERS) == set(pv.LUA_SCRIPTS.values()), "每条脚本都有同语义回调"

    async def test_eval_unknown_script_raises_clear_error(self) -> None:
        fake = FakeRedis()  # 未注册任何 handler
        with pytest.raises(RuntimeError, match="未注册"):
            await fake.eval("return 1", 0)

    async def test_eval_dispatches_by_exact_script_text(self) -> None:
        """eval 按脚本原文精确匹配分派(§10.1):numkeys 切分 keys/args 后进回调。"""
        fake, _ = make_fake()
        key = code_key("bind", PHONE)
        await fake.hset(key, mapping={"code_hash": "x" * 64, "attempts": "0", "user_id": UID})
        await fake.expire(key, CODE_TTL)
        out = await fake.eval(
            pv.LUA_SCRIPTS["attempt_incr"],
            1,
            key,
            str(MAX_ATTEMPTS),
            str(pv._CODE_TTL_FALLBACK_SECONDS),
        )
        assert out == [1, 1], "回调返回形状与 Lua 一致(attempts, flag)"

    async def test_wrapper_flows_run_through_eval(self) -> None:
        """verify/consume/rollback 的行为断言全部经由 redis.eval 分派(上方各类已覆盖):
        此处断言换用未注册的同源变体文本必须报错,确保不会错配到别的实现。"""
        fake, _ = make_fake()
        tampered = pv.LUA_SCRIPTS["rollback_quota"] + "\n-- tampered"
        with pytest.raises(RuntimeError, match="未注册"):
            await fake.eval(tampered, 1, "any-key")
