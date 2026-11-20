"""短信验证码状态机(手机绑定 bind + 找回密码 reset)— 方案 §5.3/§5.4/§5.5。

方案:rushes-spec/material-storage/phone-bind-and-sms-password-reset-plan.md
职责(无状态模块函数;router 直接以 app.state.redis + settings.* 传参调用):
  - D5 手机号归一化(normalize_phone,绑定端点与 B5 批量脚本共用同一规格)/脱敏(mask_phone)
  - D3 码生成(首位从字母子集抽取保底 ≥1 字母,全表去除易混淆字符 I/L/O/0/1)
    + HKDF-SHA256(info=b"sms-code")派生 key 的 HMAC-SHA256 存取(哈希入库,明文不落 Redis)
  - 验码两条口径(§5.3 步骤2 / §5.4 步骤1):
      verify_code — bind 用:比对不符走原子计数 Lua;命中返回 ok 且**不删码键**
        (bind 写库成功后由 router 调 delete_code 消费,重放窗口内二次提交同值幂等);
      consume_code — reset 用:**读-比-删一原子**(Lua 内 DEL),杜绝并发双 confirm
        生成两个随机密码先后覆盖、用户拿到的展示密码与生效密码不一致。
  - 三层频控计数:冷却 SET NX EX / 日配额 EXPIRE 到 UTC+8 当日 24:00 / 小时桶 EXPIRE 3600;
    D9 发送失败回滚(rollback_quota,只减本次新增且不为负)。

Redis key 总表(§5.5):
  sms:code:{scene}:{phone}           hash {code_hash, attempts, user_id} EX 900
  sms:cd:{scene}:{phone}             string EX 120(SET NX)
  sms:day:{scene}:{phone}:{yyyymmdd} int EX 至 UTC+8 当日 24:00
  sms:u:{user_id}:{epoch_hour}       int EX 3600(bind 场景每用户)
  sms:ip:reset:{ip}:{epoch_hour}     int EX 3600(reset 场景每 IP)

Lua 注入路径(§10.1 钉死):真 Redis 一律 redis.eval(LUA_SCRIPTS[name], numkeys, *keys, *args);
单测在 FakeRedis 以**脚本原文**注册同语义 Python 回调(tests/test_phone_verification.py,
逐行对照 Lua 实现),真 Lua 与回调两侧同一语义。pipeline 只是批量发送不保证原子,
验码/计数路径一律不用(方案 §5.3 步骤2 明示,勿改)。
"""

from __future__ import annotations

import hashlib
import hmac
import math
import re
import secrets
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta, timezone
from typing import Literal

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from redis.asyncio import Redis

Scene = Literal["bind", "reset"]


class InvalidPhone(ValueError):
    r"""D5:归一化后不满足 ^1[3-9]\d{9}$(router 转 400「手机号格式不正确」)。"""


# ─── 常量 ──────────────────────────────────────────────────────────────────────
# D3 码字母表(去除易混淆 I/L/O/0/1);首位定字母保底 ≥1 字母,纯随机有 (8/31)^6≈0.03%
# 概率全数字被阿里云 isv.SMS_TEMPLATE_ILLEGAL 拒(钉子 6),首置定字母根除
_CODE_FIRST = "ABCDEFGHJKMNPQRSTUVWXYZ"  # 首位:23 个字母子集
_CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"  # 其余 5 位:全表 31 字符
_CODE_LENGTH = 6

# 防御性兜底 TTL:attempt/consume Lua 仅在键无 TTL(TTL<0,issue_code 正常路径不会出现)
# 时补 EXPIRE,**不续期是硬口径**(§5.5 防有效期漂移);取需求 TTL 900s 作兜底值
_CODE_TTL_FALLBACK_SECONDS = 900

# UTC+8 固定偏移(slim 镜像无 tzdata,不用 ZoneInfo,§5.5 已知坑)
_UTC_PLUS_8 = timezone(timedelta(hours=8))
_HOURLY_WINDOW_SECONDS = 3600

_PHONE_RE = re.compile(r"^1[3-9]\d{9}$")
_SEPARATORS_RE = re.compile(r"[\s\-.]")  # D5:空格(含全角空白)/连字符/点号


# ─── D5 归一化 / 脱敏 ──────────────────────────────────────────────────────────
def normalize_phone(raw: str) -> str:
    r"""D5 归一化:去空格/连字符/点号 → 去 +86/86 前缀 → 校验 ^1[3-9]\d{9}$。

    通过返回 11 位数字串;失败 raise InvalidPhone。绑定端点与批量脚本(B5)共用。
    """
    cleaned = _SEPARATORS_RE.sub("", raw)
    if cleaned.startswith("+86"):
        cleaned = cleaned[3:]
    elif cleaned.startswith("86"):
        cleaned = cleaned[2:]
    if not _PHONE_RE.match(cleaned):
        raise InvalidPhone(f"手机号格式不正确: {raw!r}")
    return cleaned


def mask_phone(phone: str) -> str:
    """脱敏规格(§5.7 全文统一):前 3 + **** + 后 4,如 138****8000。审计/日志/文案共用。"""
    return f"{phone[:3]}****{phone[-4:]}"


# ─── D3 码生成 / HMAC 存取 ─────────────────────────────────────────────────────
def generate_code() -> str:
    """D3:6 位码。首位从字母子集抽取(保证 ≥1 字母),其余 5 位从全表抽。"""
    first = secrets.choice(_CODE_FIRST)
    rest = "".join(secrets.choice(_CODE_ALPHABET) for _ in range(_CODE_LENGTH - 1))
    return first + rest


def code_digest(code: str, secret: str) -> str:
    """D3:HMAC-SHA256(code) hexdigest,key 由 HKDF-SHA256(secret, info=b"sms-code") 派生。

    纯函数不做归一化;调用方(verify_code/consume_code)负责 strip().upper() 后传入,
    手输小写/带空格不烧 attempts。
    """
    key = HKDF(
        algorithm=hashes.SHA256(),
        length=32,
        salt=None,  # RFC 5869:盐缺省 = 哈希长度零串
        info=b"sms-code",
    ).derive(secret.encode("utf-8"))
    return hmac.new(key, code.encode("utf-8"), hashlib.sha256).hexdigest()


# ─── Redis key 构造(§5.5 总表;key 拼写收敛在本模块,勿外泄)──────────────────
def cooldown_key(scene: Scene, phone: str) -> str:
    """sms:cd:{scene}:{phone} — 同号同场景发送冷却(SET NX)。"""
    return f"sms:cd:{scene}:{phone}"


def code_key(scene: Scene, phone: str) -> str:
    """sms:code:{scene}:{phone} — 当前验证码 hash(D12 场景隔离,不跨场景使用)。"""
    return f"sms:code:{scene}:{phone}"


def daily_key(scene: Scene, phone: str, now: datetime) -> str:
    """sms:day:{scene}:{phone}:{yyyymmdd} — UTC+8 固定偏移的当日(不用 ZoneInfo)。"""
    return f"sms:day:{scene}:{phone}:{_to_utc8(now).strftime('%Y%m%d')}"


def hourly_user_key(user_id: str, now: datetime) -> str:
    """sms:u:{user_id}:{epoch_hour} — bind 场景每用户小时桶(1970 起 UTC 小时序号)。"""
    return f"sms:u:{user_id}:{_epoch_hour(now)}"


def hourly_reset_ip_key(ip: str, now: datetime) -> str:
    """sms:ip:reset:{ip}:{epoch_hour} — reset 场景每 IP 小时桶。"""
    return f"sms:ip:reset:{ip}:{_epoch_hour(now)}"


def _to_utc8(now: datetime) -> datetime:
    """统一换到 UTC+8;naive datetime 按 UTC 处理(调用方约定传 aware)。"""
    n = now if now.tzinfo is not None else now.replace(tzinfo=UTC)
    return n.astimezone(_UTC_PLUS_8)


def _epoch_hour(now: datetime) -> int:
    n = now if now.tzinfo is not None else now.replace(tzinfo=UTC)
    return int(n.timestamp() // 3600)


# ─── Lua 脚本(§5.5/§10.1;真 Redis 走 eval,测试按原文注册同语义回调)──────────
# 单脚本原子完成:EXISTS 守卫(键过期竞态按 missing→expired 不重建)+ HINCRBY
# + 仅 TTL<0 补 EXPIRE 不续期。返回 {attempts_after, flag}:flag 0=键已缺失
# (调用方按 expired)1=wrong 2=locked(已连码键 DEL)
_LUA_ATTEMPT_INCR = """-- 尝试计数(bind verify_code;方案 §5.3 步骤2/§5.5)
-- KEYS[1]=码键 hash;ARGV[1]=max_attempts;ARGV[2]=防御补 EXPIRE 秒数(仅键无 TTL 时兜底)
if redis.call('EXISTS', KEYS[1]) == 0 then
  return {0, 0}
end
local attempts = redis.call('HINCRBY', KEYS[1], 'attempts', 1)
if attempts >= tonumber(ARGV[1]) then
  redis.call('DEL', KEYS[1])
  return {attempts, 2}
end
if redis.call('TTL', KEYS[1]) < 0 then
  redis.call('EXPIRE', KEYS[1], tonumber(ARGV[2]))
end
return {attempts, 1}"""

# 原子消费式验码(reset confirm;方案 §5.4 步骤1:读-比-删一原子)。Python 侧算好
# 提交码 digest 作 ARGV 传入;key 不存在直接 expired(不做 HINCRBY 不重建);
# 等长短路比较;命中 DEL 返回 stored user_id;未命中 HINCRBY(≥max 连键 DEL)
_LUA_CONSUME_CODE = """-- 原子消费式验码(reset confirm;§5.4 步骤1)
-- KEYS[1]=码键 hash;ARGV[1]=提交码 HMAC digest;ARGV[2]=max_attempts;ARGV[3]=防御补 EXPIRE 秒
if redis.call('EXISTS', KEYS[1]) == 0 then
  return {'expired'}
end
local stored = redis.call('HGET', KEYS[1], 'code_hash')
local user_id = redis.call('HGET', KEYS[1], 'user_id') or ''
if #stored == #ARGV[1] and stored == ARGV[1] then
  redis.call('DEL', KEYS[1])
  return {'ok', user_id}
end
local attempts = redis.call('HINCRBY', KEYS[1], 'attempts', 1)
if attempts >= tonumber(ARGV[2]) then
  redis.call('DEL', KEYS[1])
  return {'locked', tostring(attempts)}
end
if redis.call('TTL', KEYS[1]) < 0 then
  redis.call('EXPIRE', KEYS[1], tonumber(ARGV[3]))
end
return {'wrong', tostring(attempts)}"""

# D9 发送失败回滚:计数减 1 且不为负(只减本次新增,不动他人计数)。
# GET→判→DECRBY 单脚本原子,防并发回滚把计数穿负。返回回滚后计数(字符串)
_LUA_ROLLBACK_QUOTA = """-- D9 发送失败回滚(rollback_quota)
-- KEYS[1]=配额计数键
local current = tonumber(redis.call('GET', KEYS[1]) or '0')
if current > 0 then
  redis.call('DECRBY', KEYS[1], 1)
end
return redis.call('GET', KEYS[1]) or '0'"""

# 稳定脚本名 → 完整 Lua 源文本(§10.1:真 Redis eval 用;测试以脚本原文为键注册回调)
LUA_SCRIPTS: dict[str, str] = {
    "attempt_incr": _LUA_ATTEMPT_INCR,
    "consume_code": _LUA_CONSUME_CODE,
    "rollback_quota": _LUA_ROLLBACK_QUOTA,
}


# ─── 验码结果契约 ──────────────────────────────────────────────────────────────
@dataclass
class CodeCheckResult:
    """verify_code / consume_code 统一返回。

    - status:ok(命中)/ expired(键缺失或已过期)/ wrong(码不符)/ locked(达上限作废)
    - user_id:发码时归属(码 hash 里的 user_id),ok 时带回供 router 复核归属
    - attempts:wrong/locked 为本次 HINCRBY 后计数;ok/expired 恒 0
    """

    status: Literal["ok", "expired", "wrong", "locked"]
    user_id: str | None = None
    attempts: int = 0


# ─── 码 hash 存取(§5.3 步骤 7 / §5.4 步骤 6)──────────────────────────────────
async def issue_code(
    redis: Redis,  # type: ignore[type-arg]
    *,
    scene: Scene,
    phone: str,
    user_id: str,
    ttl_seconds: int,
    secret: str,
) -> str:
    """生成码并把 {code_hash, attempts:0, user_id} 覆盖写码键(EX TTL 秒)。

    **返回生成的明文码**——仅供 router 调 app.state.sms.send(phone, template, code)
    发送短信;Redis 只存 HMAC 哈希(明文不落 Redis/日志)。覆盖旧码 = 旧码自然失效
    (写库成功前的 verify 只认新码;旧码提交按 wrong 计)。
    """
    code = generate_code()
    key = code_key(scene, phone)
    pipe = redis.pipeline()
    pipe.hset(
        key,
        mapping={
            "code_hash": code_digest(code, secret),
            "attempts": "0",
            "user_id": user_id,
        },
    )
    pipe.expire(key, ttl_seconds)  # 覆盖写重置 TTL(此前错误次数一并清零)
    await pipe.execute()
    return code


async def read_code(
    redis: Redis,  # type: ignore[type-arg]
    *,
    scene: Scene,
    phone: str,
) -> dict[str, str] | None:
    """读码 hash(bind router 先取 user_id 复核发码归属用);缺失/空返回 None。"""
    data = await redis.hgetall(code_key(scene, phone))
    return dict(data) if data else None


async def delete_code(
    redis: Redis,  # type: ignore[type-arg]
    *,
    scene: Scene,
    phone: str,
) -> None:
    """DEL 码键(bind 写库成功后消费码;reset 走 consume_code 原子消费,不走这里)。"""
    await redis.delete(code_key(scene, phone))


# ─── 验码两条口径 ──────────────────────────────────────────────────────────────
async def verify_code(
    redis: Redis,  # type: ignore[type-arg]
    *,
    scene: Scene,
    phone: str,
    submitted: str,
    secret: str,
    max_attempts: int,
) -> CodeCheckResult:
    """bind 口径(§5.3 步骤2):比对不符走原子计数 Lua;**命中不删码键**。

    - 码 hash 缺失/已过期 → expired(不重建);
    - digest 相符(compare_digest)→ ok(带回 stored user_id),码键留给 router
      在 bind 写库成功后 delete_code 消费;
    - 不符 → Lua(EXISTS 守卫+HINCRBY+仅 TTL<0 补 EXPIRE 不续期;键过期竞态按
      missing→expired 不重建)→ ≥max_attempts 连码键 DEL 返回 locked,否则 wrong。
    """
    stored = await read_code(redis, scene=scene, phone=phone)
    if stored is None:
        return CodeCheckResult(status="expired")
    digest = code_digest(submitted.strip().upper(), secret)
    if hmac.compare_digest(stored.get("code_hash", ""), digest):
        return CodeCheckResult(status="ok", user_id=stored.get("user_id") or None)
    result = await redis.eval(  # type: ignore[no-untyped-call]  # stub eval 参数未标类型
        LUA_SCRIPTS["attempt_incr"],
        1,
        code_key(scene, phone),
        str(max_attempts),
        str(_CODE_TTL_FALLBACK_SECONDS),
    )
    attempts, flag = int(result[0]), int(result[1])
    if flag == 0:  # 比对与计数之间键已过期(missing)→ expired,不重建
        return CodeCheckResult(status="expired")
    if flag == 2:  # 达上限:连码键一起 DEL(须重新发码,受冷却管)
        return CodeCheckResult(status="locked", attempts=attempts)
    return CodeCheckResult(status="wrong", attempts=attempts)


async def consume_code(
    redis: Redis,  # type: ignore[type-arg]
    *,
    scene: Scene,
    phone: str,
    submitted: str,
    secret: str,
    max_attempts: int,
) -> CodeCheckResult:
    """reset confirm 口径(§5.4 步骤1):**原子消费式验码**,读-比-删一原子。

    Python 侧算 submitted 的 HMAC digest 作 ARGV 传入 Lua:键缺失直接 expired
    (不 HINCRBY 不重建);等长比较命中 DEL 码键返回 ok + stored user_id;
    未命中 HINCRBY(≥max 连键 DEL)返回 wrong/locked。并发双 confirm 只有
    一次能命中改密。
    """
    digest = code_digest(submitted.strip().upper(), secret)
    result = await redis.eval(  # type: ignore[no-untyped-call]  # 同上
        LUA_SCRIPTS["consume_code"],
        1,
        code_key(scene, phone),
        digest,
        str(max_attempts),
        str(_CODE_TTL_FALLBACK_SECONDS),
    )
    tag = str(result[0])
    if tag == "expired":
        return CodeCheckResult(status="expired")
    if tag == "ok":
        uid = str(result[1]) if len(result) > 1 and result[1] else None
        return CodeCheckResult(status="ok", user_id=uid)
    attempts = int(result[1])
    if tag == "locked":
        return CodeCheckResult(status="locked", attempts=attempts)
    return CodeCheckResult(status="wrong", attempts=attempts)


# ─── 冷却(SET NX EX;参照 local_auth.py 的 PTTL 毫秒上取整先例)────────────────
async def acquire_cooldown(
    redis: Redis,  # type: ignore[type-arg]
    *,
    scene: Scene,
    phone: str,
    cooldown_seconds: int,
) -> int | None:
    """抢冷却:SET NX EX。抢到 → None(调用方继续发码流程);未抢到 → 剩余秒。

    剩余秒 = 冷却键 PTTL 毫秒**上取整**(漏换算会把 2 分钟显示成 120000 秒,
    local_auth.py:293-310 先例);PTTL<0(竞态过期 -2 / 无过期 -1 等异常)回退整段
    cooldown_seconds(宁可多等,不放行后立刻再吃一次拒绝)。
    """
    key = cooldown_key(scene, phone)
    acquired = await redis.set(key, "1", nx=True, ex=cooldown_seconds)
    if acquired:
        return None
    pttl = int(await redis.pttl(key))
    if pttl < 0:
        return cooldown_seconds
    return max(1, math.ceil(pttl / 1000))


# ─── 三层配额计数(§5.5)────────────────────────────────────────────────────────
async def incr_daily(
    redis: Redis,  # type: ignore[type-arg]
    *,
    scene: Scene,
    phone: str,
    now: datetime,
) -> int:
    """INCR 日配额键 + EXPIRE 到 UTC+8 当日 24:00;返回 incr 后计数。"""
    key = daily_key(scene, phone, now)
    n = _to_utc8(now)
    midnight = n.replace(hour=0, minute=0, second=0, microsecond=0) + timedelta(days=1)
    window = max(1, int((midnight - n).total_seconds()))
    pipe = redis.pipeline()
    pipe.incr(key)
    pipe.expire(key, window)
    results = await pipe.execute()
    return int(results[0])


async def incr_hourly(
    redis: Redis,  # type: ignore[type-arg]
    bucket_key: str,
) -> int:
    """INCR 小时桶键 + EXPIRE 3600;返回 incr 后计数。bucket_key 由
    hourly_user_key / hourly_reset_ip_key 构造。"""
    pipe = redis.pipeline()
    pipe.incr(bucket_key)
    pipe.expire(bucket_key, _HOURLY_WINDOW_SECONDS)
    results = await pipe.execute()
    return int(results[0])


async def rollback_quota(
    redis: Redis,  # type: ignore[type-arg]
    *keys: str,
) -> None:
    """D9 发送失败回滚:每个键计数减 1 且不为负(只减本次新增,不动他人计数)。"""
    for key in keys:
        await redis.eval(LUA_SCRIPTS["rollback_quota"], 1, key)  # type: ignore[no-untyped-call]  # 同上
