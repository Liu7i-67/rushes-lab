"""百度网盘备份导入 — 纯逻辑单测层(无外部基础设施;mock Settings/外部服务)。

对应方案(最高权威):rushes-spec/material-storage/baidu-netdisk-backup-plan.md
§10 批次 5「纯逻辑单测」清单。本文件已对齐 2026-10-08 落地实现:预写名按文末
「预写名 ↔ 实现名对照」逐一改名/改签名,断言语义与方案一致(仅观察口径随实现
调整为「断言发出的 UPDATE 落点」—— 行级处置函数不再就地改写 ORM 对象)。
集成层用例见同目录 test_baidu_integration.py。

■ 方案批次 5 单测清单项 ↔ 测试映射
| 方案清单项                                                | 测试 |
|-----------------------------------------------------------|------|
| 错误映射(六类分类)                                       | TestErrorClassification |
| 403 先解析 errno(权限类 errno 不进退避)                  | TestErrorClassification::test_403_*、TestRowErrorHandling::test_permission_denied_* |
| 31045 先 refresh 回退 link_expired                        | TestRowErrorHandling::test_31045_* |
| -9 双重复核才落 non_retryable                             | TestRowErrorHandling::test_not_found_* |
| 403 先甄别 dlink_fetched_at 早于 token_rotated_at 先重取  | TestDlinkStaleness |
| 退避封顶 20s / 5 次耗尽转 failed                          | TestBackoffPolicy、TestRowErrorHandling::test_rate_limited_exhausts_five_attempts_then_row_failed |
| token 刷新单飞时序(§5.3,含吊销兜底/3 次失败置 expired)  | TestRefreshSingleFlight |
| 加密解密 / 派生密钥 warning / 密文不含明文                | TestTokenCrypto |
| 长度护栏(path/name 叶子段 UTF-8>255B/key 字节字符双口径/file_too_large/承接夹名>255→400) | TestLengthGuardrails |
| URL 脱敏(构造含 access_token 的 URL,断言输出无 token)    | TestUrlSanitization |
| 重定向宿主白名单拒绝(非 *.pcs.baidu.com/*.baidupcs.com)  | TestRedirectHostWhitelist |
| dedup_key 规则字符串(r/a 维度)                           | TestAuditDedupKey |
| netdisk folders 的 60s 缓存 key 口径                      | TestNetdiskFoldersCache |

■ 预写名 ↔ 实现名对照(2026-10-08 对齐落地实现)
- app.services.baidu_client:BaiduNetdiskClient(预写 BaiduClient)、
  classify_baidu_failure(*, http_status, errno=None)(预写 classify_baidu_error)、
  strip_url_query(预写 sanitize_url)、host_allowed(预写 is_allowed_redirect_host)、
  sanitize_message(自由文本兜底脱敏);BaiduApiError(category, message, errno=None,
  http_status=None),message 由构造方脱敏;stream_download(access_token, dlink, *,
  range_header=...)(预写 download_stream(dlink, range))。
  无 RATE_LIMIT_ERRNOS / needs_refresh_first / is_permission_errno /
  backoff_delay_s / BAIDU_BACKOFF_MAX_S / BAIDU_MAX_ATTEMPTS:403+errno∉权限集
  一律 rate_limited;31045 归类 link_expired,refresh-first 两步回退由 worker
  _handle_baidu_error 的 31045 分支承担(见 TestRowErrorHandling);退避公式内联
  于 worker(见 TestBackoffPolicy)。
- app.services.token_crypto:TokenCryptoService(settings).encrypt/.decrypt +
  derive_fernet_key(secret: str) / encrypt_str / decrypt_str / TokenDecryptError
  (预写 encrypt_token(plaintext, settings) / decrypt_token(ciphertext, settings))。
- app.services.folder_chain(长度护栏落地处):guard_rel_path(target_prefix,
  rel_path) 覆盖预写 is_rel_path_too_long / filename_failure(name, target_prefix) /
  key_failure(key)(检查顺序:path → 段名 → 叶子名 255B/512C → key 1024B/C);
  guard_file_size(source_size, part_size_bytes)(预写 size_failure);
  check_segment_name(目录/文件段 >255 判定;承接夹名创建期 400 为 router 内联
  len(name)>255 校验,app/routers/baidu_backup.py:703-705 同口径)。
- app.workers.baidu_backup(行级处置落地处):_handle_baidu_error(db, runner,
  row, e)(预写 handle_baidu_error(db, task, row, err, *, client, binding));
  _maybe_invalidate_stale_dlink(db, runner, row)(预写 should_refetch_dlink);
  MAX_FILE_ATTEMPTS / FILE_BACKOFF_CAP_S;AUDIT_DEDUP_FMT(ref=file_id,预写
  baidu_audit_dedup_key;实现仅文件级事件落 dedup_key,无 :all: 变体);
  Runner(owned_row_predicate / 会话缓存 / consecutive_auth_expired)。
- app.services.baidu_backup:ensure_fresh_access_token(db, binding, *, crypto,
  client)(预写 refresh_binding_token_singleflight(db, binding, client));
  validate_source_dir(违规抛 BaiduTaskError,合法返回 rstrip 归一路径);
  source_dir_leaf_name;ENUM_BACKOFF_MAX_ATTEMPTS / ENUM_BACKOFF_CAP_S。
- app.routers.baidu_backup:_FOLDERS_CACHE_KEY("baidu:netdisk:folders:{user_id}:
  {path_hash}",path_hash=sha256(path)[:32]) / _FOLDERS_CACHE_TTL_S=60(预写
  netdisk_folders_cache_key(user_id, path) / BAIDU_FOLDERS_CACHE_TTL_S)。

■ 已知实现与方案语义差异(2026-10-08 已全部修复,历史 xfail(strict) 已转正)
1. host_allowed 现规范化 DNS 尾点("d.pcs.baidu.com." 剥尾点后放行,§5.1)。
2. 31045 refresh-first 已落在 worker _handle_baidu_error 的 31045 分支:先按
   auth_expired 强制试一次 refresh,成功重取 dlink 续跑;失败回落 link_expired
   (重取 dlink 重试,不误杀绑定、不 non_retryable)。
3. -9 复核协议已对齐方案「两次均 -9」:复核成功返回空列表、或复核再次抛 -9
   (not_found 类),均计为第二次确认;复核其他错误保持可重试。
"""
from __future__ import annotations

import asyncio
import hashlib
import logging
import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

import httpx
import pytest
from sqlalchemy import Select, Update

import app.services.baidu_backup as baidu_backup_service
import app.workers.baidu_backup as worker
from app.db.tables import BaiduBackupTask, BaiduBinding, Folder, Project
from app.routers.baidu_backup import _FOLDERS_CACHE_KEY, _FOLDERS_CACHE_TTL_S
from app.services.baidu_backup import (
    ENUM_BACKOFF_CAP_S,
    ENUM_BACKOFF_MAX_ATTEMPTS,
    BaiduTaskError,
    ensure_fresh_access_token,
    source_dir_leaf_name,
    validate_source_dir,
)
from app.services.baidu_client import (
    BaiduApiError,
    BaiduNetdiskClient,
    BaiduTokenPair,
    classify_baidu_failure,
    host_allowed,
    sanitize_message,
    strip_url_query,
)
from app.services.folder_chain import (
    FolderChainError,
    check_segment_name,
    guard_file_size,
    guard_rel_path,
)
from app.services.token_crypto import (
    TokenCryptoService,
    TokenDecryptError,
    derive_fernet_key,
)
from app.settings import Settings
from app.workers.baidu_backup import (
    AUDIT_DEDUP_FMT,
    FILE_BACKOFF_CAP_S,
    MAX_FILE_ATTEMPTS,
    Runner,
    _handle_baidu_error,
    _maybe_invalidate_stale_dlink,
)

NOW = datetime.now(UTC)
_TOKEN_URL = "https://d.pcs.baidu.com/rest/2.0/xpan/file?method=download&access_token=SECRET.TOKEN&path=/a"
_TASK_FILE_TABLE = "baidu_backup_task_files"


# ─── helpers ─────────────────────────────────────────────────────────────────
def make_settings(**overrides: Any) -> Settings:
    base: dict[str, Any] = dict(
        db_url="postgresql+asyncpg://u:p@localhost:5432/x",
        redis_url="redis://localhost:6379/0",
        minio_endpoint_internal="http://minio:9000",
        minio_endpoint_public="http://localhost:9000",
        minio_access_key="ak",
        minio_secret_key="sk",
        openfga_api_url="http://localhost:8080",
        openfga_store_id="store",
        web_app_base_url="http://localhost/ms-static/web/",
        session_jwt_secret="x" * 32,
        baidu_token_enc_key=None,
        baidu_app_key="test-app-key",
        baidu_app_secret="test-app-secret",
    )
    base.update(overrides)
    return Settings(**base)  # type: ignore[call-arg]


_CRYPTO = TokenCryptoService(make_settings())


def make_err(http_status: int | None = None, errno: int | None = None,
             url: str = _TOKEN_URL) -> BaiduApiError:
    """按客户端 _xpan_get_json 同款口径构造统一错误对象(message 已剥 URL query)。"""
    parts = "百度接口"
    if http_status is not None:
        parts += f" HTTP {http_status}"
    if errno is not None:
        parts += f" errno={errno}"
    parts += f" url={strip_url_query(url)}"
    return BaiduApiError(
        classify_baidu_failure(http_status=http_status, errno=errno),
        parts, errno=errno, http_status=http_status,
    )


class FakeRow:
    """manifest 行替身:行级处置函数只读其属性、UPDATE 落点由 FakeDb 记录。"""

    def __init__(self, **overrides: Any) -> None:
        self.id = uuid.uuid4()
        self.fs_id = 10086
        self.status = "importing"
        self.attempts = 0
        self.non_retryable = False
        self.last_error: str | None = None
        self.dlink = _TOKEN_URL
        self.dlink_fetched_at: datetime | None = NOW - timedelta(hours=1)
        self.dlink_expires_at: datetime | None = NOW + timedelta(hours=7)
        self.overwrite = False
        self.reserved_key: str | None = None
        self.bytes_done = 0
        self.minio_upload_id: str | None = "upload-1"
        self.source_size = 1024
        self.rel_path = "b.mp4"
        self.target_folder_id: uuid.UUID | None = None
        for k, v in overrides.items():
            setattr(self, k, v)


class FakeTask:
    def __init__(self, **overrides: Any) -> None:
        self.id = uuid.uuid4()
        self.user_id = uuid.uuid4()
        self.project_id = uuid.uuid4()
        self.target_folder_id: uuid.UUID | None = None
        self.target_auto_created = False
        self.bound_baidu_uid = "100"          # 创建时快照
        self.status = "running"
        self.fail_reason: str | None = None
        self.retry_count = 0
        for k, v in overrides.items():
            setattr(self, k, v)


class FakeBinding:
    """绑定替身:token 双列为真实 Fernet 密文(refresh 单飞走真 crypto)。"""

    def __init__(self, **overrides: Any) -> None:
        self.id = uuid.uuid4()
        self.baidu_uid = "100"
        self.status = "active"
        self.access_token = "at-old"          # 明文镜像(断言用)
        self.refresh_token = "rt-old"
        self.access_token_enc = _CRYPTO.encrypt("at-old")
        self.refresh_token_enc = _CRYPTO.encrypt("rt-old")
        self.access_token_expires_at = NOW + timedelta(days=30)   # 未到期
        self.token_rotated_at: datetime | None = NOW - timedelta(days=1)
        for k, v in overrides.items():
            setattr(self, k, v)


class FakeFolder:
    def __init__(self, **overrides: Any) -> None:
        self.id = uuid.uuid4()
        self.name = "p"
        self.is_sensitive = False
        self.minio_prefix = "p/"
        self.minio_bucket = "bk-unit"
        for k, v in overrides.items():
            setattr(self, k, v)


class FakePermissions:
    async def check(self, **_kwargs: Any) -> bool:
        return True


class FakeClient:
    """BaiduNetdiskClient 替身:脚本化 refresh/filemetas,统计调用次数。"""

    def __init__(self, *, refresh_ok: bool = True,
                 recheck_metas: list[dict[str, Any]] | None = None) -> None:
        self.refresh_calls = 0
        self.filemetas_calls = 0
        self.refresh_ok = refresh_ok
        # 复核口径(实现协议):空列表 = 文件确认不存在;非空 = 文件仍在
        self.recheck_metas = (
            [{"fs_id": 10086, "dlink": "https://d.pcs.baidu.com/new?access_token=NEW"}]
            if recheck_metas is None else recheck_metas
        )

    async def refresh_token(self, refresh_token: str) -> BaiduTokenPair:
        self.refresh_calls += 1
        if not self.refresh_ok:
            raise make_err(http_status=401, errno=111)
        return BaiduTokenPair(access_token="at-new", refresh_token="rt-new",
                              expires_in=30 * 24 * 3600)

    async def filemetas_batch(self, access_token: str, fsids: list[int], *,
                              dlink: bool = True) -> list[dict[str, Any]]:
        self.filemetas_calls += 1
        return list(self.recheck_metas)


class FakeResult:
    """脚本化 Result:rowcount / .all() / .scalars().all() / .scalar_one_or_none()。"""

    def __init__(self, *, rowcount: int = 1, rows: list[Any] | None = None,
                 scalar_row: Any = None) -> None:
        self.rowcount = rowcount
        self._rows = list(rows or [])
        self._scalar_row = scalar_row

    def all(self) -> list[Any]:
        return list(self._rows)

    def scalars(self) -> FakeResult:
        return self

    def first(self) -> Any:
        return self._rows[0] if self._rows else None

    def scalar_one_or_none(self) -> Any:
        return self._scalar_row

    def scalar_one(self) -> Any:
        return self._scalar_row


class FakeDb:
    """假 DB 会话:记录 UPDATE 落点 (table, values) 供断言;SELECT 返回脚本化结果
    (sticky:同一结果服务全部 SELECT —— with_for_update 每次重拿锁复查都要拿到行)。"""

    def __init__(self, *, select_result: FakeResult | None = None,
                 group_rows: list[Any] | None = None, importing_bytes: int = 0,
                 get_map: dict[tuple[type, Any], Any] | None = None) -> None:
        self.updates: list[tuple[str, dict[str, Any]]] = []
        self.commits = 0
        self.rollbacks = 0
        self._select_result = select_result
        self._group_rows = list(group_rows or [])
        self._importing_bytes = importing_bytes
        self._get_map = dict(get_map or {})

    async def execute(self, stmt: Any) -> FakeResult:
        if isinstance(stmt, Update):
            self.updates.append((stmt.table.name, dict(stmt.compile().params)))
            return FakeResult()
        if isinstance(stmt, Select):
            if self._select_result is not None:
                return self._select_result
            return FakeResult(rows=self._group_rows, scalar_row=self._importing_bytes)
        return FakeResult()

    async def scalar(self, _stmt: Any) -> int:
        return self._importing_bytes

    async def get(self, model: Any, pk: Any) -> Any:
        return self._get_map.get((model, pk))

    async def commit(self) -> None:
        self.commits += 1

    async def rollback(self) -> None:
        self.rollbacks += 1

    def last_update(self, table_name: str) -> dict[str, Any]:
        ups = [v for t, v in self.updates if t == table_name]
        assert ups, f"expected an UPDATE on {table_name}, recorded: {self.updates}"
        return ups[-1]


class LockedFakeDb(FakeDb):
    """模拟 SELECT ... FOR UPDATE 行锁:execute 拿锁、commit/rollback 放锁。"""

    def __init__(self, lock: asyncio.Lock, binding: FakeBinding) -> None:
        super().__init__(
            select_result=FakeResult(scalar_row=binding),
            get_map={(BaiduBinding, binding.id): binding},
        )
        self._lock = lock

    async def execute(self, stmt: Any) -> FakeResult:
        await self._lock.acquire()                  # 模拟行锁获取
        try:
            return await super().execute(stmt)
        except BaseException:
            self._lock.release()
            raise

    async def commit(self) -> None:
        self._lock.release()                        # 事务提交 → 行锁释放
        await super().commit()

    async def rollback(self) -> None:
        if self._lock.locked():
            self._lock.release()
        await super().rollback()


def make_runner(*, client: FakeClient | None = None,
                binding_id: uuid.UUID | None = None,
                task_id: uuid.UUID | None = None) -> Runner:
    return Runner(
        task_id=task_id or uuid.uuid4(),
        expected_seq=1,
        runner_id="runner-unit",
        store=None,                      # type: ignore[arg-type]
        permissions=FakePermissions(),   # type: ignore[arg-type]
        presign=None,                    # type: ignore[arg-type]
        crypto=_CRYPTO,
        client=client or FakeClient(),   # type: ignore[arg-type]
        settings=make_settings(),
        binding_id=binding_id,
        user_id=uuid.uuid4(),
    )


# ─── URL 脱敏 ─────────────────────────────────────────────────────────────────
class TestUrlSanitization:
    def test_sanitize_url_strips_access_token(self) -> None:
        """§5.1:统一剥除 query 后再输出 —— access_token 不得残留。"""
        out = strip_url_query(_TOKEN_URL)
        assert "SECRET.TOKEN" not in out
        assert "access_token" not in out

    def test_sanitize_url_keeps_scheme_and_path(self) -> None:
        out = strip_url_query(_TOKEN_URL)
        assert out.startswith("https://d.pcs.baidu.com/rest/2.0/xpan/file")

    def test_sanitize_message_strips_embedded_url_token(self) -> None:
        """§5.1:自由文本兜底脱敏(httpx 异常 str 可能混入原始 URL)。"""
        out = sanitize_message(f"下载网络错误:{_TOKEN_URL} 连接超时")
        assert "SECRET.TOKEN" not in out
        assert "access_token=" not in out

    def test_error_object_message_contains_no_token(self) -> None:
        """§5.3:错误对象进入 last_error/日志前必须脱敏(message 构造方剥 query)。"""
        err = make_err(http_status=500, errno=None)
        assert "SECRET.TOKEN" not in err.message
        assert "SECRET.TOKEN" not in str(err)

    def test_error_object_str_has_no_token(self) -> None:
        assert "SECRET.TOKEN" not in str(make_err(http_status=403, errno=-7))


# ─── 重定向宿主白名单 ─────────────────────────────────────────────────────────
class TestRedirectHostWhitelist:
    @pytest.mark.parametrize("host", [
        "d.pcs.baidu.com",
        "f.pcs.baidu.com",
        "nx.baidupcs.com",
    ])
    def test_baidu_hosts_allowed(self, host: str) -> None:
        assert host_allowed(host) is True

    def test_trailing_dot_host_normalized_allowed(self) -> None:
        """结尾点(FQDN 根标记)规范化后放行 —— host_allowed 先剥尾点再比较(§5.1)。"""
        assert host_allowed("d.pcs.baidu.com.") is True

    @pytest.mark.parametrize("host", [
        "evil.example.com",
        "baidu.com",                      # 裸主域不是下载 CDN
        "baidupcs.com.evil.com",          # 后缀欺骗
        "pcs.baidu.com.evil.com",
        "fakesite.pcs.baidu.com.attacker.io",
        "",                               # 空 host 一律拒绝
        "169.254.169.254",                # 云元数据地址(SSRF 目标)
    ])
    def test_foreign_hosts_rejected(self, host: str) -> None:
        assert host_allowed(host) is False

    async def test_download_stream_refuses_disallowed_redirect(self) -> None:
        """§5.1:非白名单 Location 拒绝跟随(一行代码量级的 SSRF 防御)。"""
        captured: dict[str, str] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            captured["url"] = str(request.url)
            if request.url.host == "d.pcs.baidu.com":
                return httpx.Response(302, headers={
                    "Location": "https://evil.example.com/payload?access_token=LEAK"})
            return httpx.Response(500)

        client = BaiduNetdiskClient(make_settings())
        # 注入 mock transport(实现内部 httpx.AsyncClient 字段名 _http)
        client._http = httpx.AsyncClient(transport=httpx.MockTransport(handler))  # type: ignore[attr-defined]
        try:
            with pytest.raises(BaiduApiError):
                async for _chunk in client.stream_download("ACCESS.TOKEN", _TOKEN_URL):
                    pass
        finally:
            await client.close()
        # 拒绝跟随:请求不得打到 evil host(若跟随了,handler 的 captured 会被覆盖)
        assert captured.get("url", "").startswith("https://d.pcs.baidu.com"), captured


# ─── 错误映射(六类分类)──────────────────────────────────────────────────────
class TestErrorClassification:
    def test_http_401_is_auth_expired(self) -> None:
        assert classify_baidu_failure(http_status=401) == "auth_expired"

    def test_errno_minus6_is_auth_expired(self) -> None:
        assert classify_baidu_failure(http_status=None, errno=-6) == "auth_expired"

    def test_errno_111_is_auth_expired(self) -> None:
        assert classify_baidu_failure(http_status=None, errno=111) == "auth_expired"

    @pytest.mark.parametrize("status", [500, 502, 503, 504])
    def test_5xx_is_rate_limited(self, status: int) -> None:
        """§5.3:5xx → rate_limited(指数退避自动重试)。"""
        assert classify_baidu_failure(http_status=status) == "rate_limited"

    def test_403_permission_errno_is_baidu_permission_denied(self) -> None:
        """§5.3 核心:403 必须先解析 errno —— 权限/路径类(-7 等)不进退避。"""
        assert classify_baidu_failure(http_status=403, errno=-7) == "baidu_permission_denied"
        # is_permission_errno(-7) is True 的实现口径:含/不含 HTTP 状态都归权限类
        assert classify_baidu_failure(http_status=None, errno=-7) == "baidu_permission_denied"

    def test_403_non_permission_errno_is_rate_limited(self) -> None:
        """403 + errno∉权限集 → rate_limited(实现无 RATE_LIMIT_ERRNOS 常量,
        频控特征 errno 不单独设集,见实现 classify_baidu_failure 403 分支)。"""
        assert classify_baidu_failure(http_status=403, errno=2) == "rate_limited"
        assert classify_baidu_failure(http_status=403, errno=None) == "rate_limited"
        assert classify_baidu_failure(http_status=None, errno=2) != "baidu_permission_denied", \
            "频控特征不得误入权限类"

    def test_errno_31360_is_link_expired(self) -> None:
        assert classify_baidu_failure(http_status=None, errno=31360) == "link_expired"

    def test_errno_minus9_is_not_found(self) -> None:
        assert classify_baidu_failure(http_status=None, errno=-9) == "not_found"

    def test_errno_31064_is_not_found(self) -> None:
        assert classify_baidu_failure(http_status=None, errno=31064) == "not_found"

    def test_errno_31045_falls_back_to_link_expired_with_errno_preserved(self) -> None:
        """§5.3:31045 语义待定 —— 实现归类 link_expired(回落口径),错误对象保留
        原始 errno 供调用方 refresh-first 甄别(refresh-first 行为见 TestRowErrorHandling)。"""
        err = make_err(None, 31045)
        assert err.category == "link_expired"
        assert err.errno == 31045

    def test_other_is_unknown(self) -> None:
        assert classify_baidu_failure(http_status=418, errno=99999) == "unknown"

    def test_permission_denied_never_routed_to_backoff(self) -> None:
        """§5.3:「不进退避」—— 分类为 baidu_permission_denied 时退避策略不得介入。"""
        assert classify_baidu_failure(http_status=403, errno=-7) != "rate_limited"


# ─── 403 先甄别:dlink_fetched_at vs token_rotated_at ─────────────────────────
class TestDlinkStaleness:
    async def test_dlink_older_than_token_rotation_is_invalidated(self) -> None:
        """换绑/refresh 后旧账号 dlink 配新 token 常 403 —— 先重取一次 filemetas 再归类。"""
        binding = FakeBinding(token_rotated_at=NOW - timedelta(hours=1))
        row = FakeRow(dlink_fetched_at=NOW - timedelta(hours=2))
        db = FakeDb(get_map={(BaiduBinding, binding.id): binding})
        await _maybe_invalidate_stale_dlink(db, make_runner(binding_id=binding.id), row)
        assert row.dlink is None, "陈旧 dlink 必须先失效(交调用方重取 filemetas)"
        assert db.last_update(_TASK_FILE_TABLE)["dlink"] is None

    async def test_dlink_fresh_after_rotation_kept(self) -> None:
        binding = FakeBinding(token_rotated_at=NOW - timedelta(hours=1))
        row = FakeRow(dlink_fetched_at=NOW - timedelta(minutes=1))
        db = FakeDb(get_map={(BaiduBinding, binding.id): binding})
        await _maybe_invalidate_stale_dlink(db, make_runner(binding_id=binding.id), row)
        assert row.dlink == _TOKEN_URL, "rotation 之后取的 dlink 不得失效"
        assert not db.updates

    async def test_no_rotation_record_kept(self) -> None:
        binding = FakeBinding(token_rotated_at=None)
        row = FakeRow(dlink_fetched_at=NOW - timedelta(hours=2))
        db = FakeDb(get_map={(BaiduBinding, binding.id): binding})
        await _maybe_invalidate_stale_dlink(db, make_runner(binding_id=binding.id), row)
        assert row.dlink == _TOKEN_URL
        assert not db.updates


# ─── 行级错误处置(§5.3 表格「行为」列;落地于 workers/baidu_backup.py)────────
class TestRowErrorHandling:
    async def test_permission_denied_fails_row_non_retryable_without_backoff(self) -> None:
        """403+-7 → 行 failed 置 non_retryable,last_error 直译 errno,不烧退避。"""
        db, row = FakeDb(), FakeRow()
        client = FakeClient()
        disposition = await _handle_baidu_error(
            db, make_runner(client=client), row, make_err(403, -7))
        upd = db.last_update(_TASK_FILE_TABLE)
        assert upd["status"] == "failed"
        assert upd["non_retryable"] is True
        assert "-7" in str(upd["last_error"]) or "403" in str(upd["last_error"])
        assert "SECRET.TOKEN" not in str(upd["last_error"] or ""), "last_error 必须脱敏 URL"
        assert client.refresh_calls == 0 and client.filemetas_calls == 0, "权限类不重取不刷新"
        assert disposition not in (None, "retry"), "权限类必须就地落失败,不交退避循环"

    async def test_31045_tries_refresh_then_refetches_dlink(self) -> None:
        """31045 → 先 refresh(auth_expired 尝试),成功后重取 dlink 按 link_expired 续跑。"""
        db, row, binding = FakeDb(), FakeRow(), FakeBinding()
        client = FakeClient(refresh_ok=True)
        await _handle_baidu_error(
            db, make_runner(client=client, binding_id=binding.id), row, make_err(None, 31045))
        assert client.refresh_calls == 1, "31045 必须先试一次 refresh"
        assert client.filemetas_calls == 1, "refresh 后须重取 filemetas 换新 dlink"
        assert row.dlink == "https://d.pcs.baidu.com/new?access_token=NEW"
        assert not db.updates, "31045 不得落 non_retryable"

    async def test_31045_refresh_failure_falls_back_to_link_expired(self) -> None:
        """31045 → refresh 失败 → 回落 link_expired 语义(重取 dlink),不误杀绑定。"""
        db, row, binding = FakeDb(), FakeRow(), FakeBinding()
        client = FakeClient(refresh_ok=False)
        await _handle_baidu_error(
            db, make_runner(client=client, binding_id=binding.id), row, make_err(None, 31045))
        assert client.refresh_calls == 1
        assert client.filemetas_calls == 1, "回落 link_expired → 重取 dlink"
        assert binding.status == "active", "refresh 失败按可重试处理,不得直接置 expired"
        assert not db.updates

    async def test_errno_31360_pure_link_expired_no_refresh(self) -> None:
        """31360(纯 dlink 过期)不走 refresh-first:归类 link_expired → 处置函数不落
        失败、不 refresh(交调用方重试循环重取 dlink 续跑),绑定不受影响、行不得
        non_retryable;refresh-first 仅限 errno=31045(见 test_31045_*)。"""
        db, row, binding = FakeDb(), FakeRow(), FakeBinding()
        client = FakeClient()
        disposition = await _handle_baidu_error(
            db, make_runner(client=client, binding_id=binding.id), row, make_err(None, 31360))
        assert disposition is None, "link_expired 交调用方重试循环(重取 dlink),不就地处置"
        assert not db.updates, "不得置 failed/non_retryable"
        assert binding.status == "active"
        assert client.refresh_calls == 0 and client.filemetas_calls == 0

    async def test_not_found_first_occurrence_stays_retryable(self) -> None:
        """§5.3:-9 首次以全新 filemetas 复核;复核未确认不可逆置 non_retryable。"""
        row, binding = FakeRow(), FakeBinding()
        db = FakeDb(get_map={(BaiduBinding, binding.id): binding})   # 复核经 _current_token 取 token
        client = FakeClient(recheck_metas=[{"fs_id": 10086, "dlink": "x"}])   # 复核:文件仍在
        disposition = await _handle_baidu_error(
            db, make_runner(client=client, binding_id=binding.id), row, make_err(None, -9))
        assert client.filemetas_calls == 1, "-9 必须触发一次全新 filemetas 复核"
        assert disposition is None and not db.updates, "复核未确认 -9 不得置 non_retryable"

    async def test_not_found_confirmed_by_empty_recheck_fails_row(self) -> None:
        """复核确认文件不在(复核成功返回空列表、或复核再次抛 -9,均计第二次确认)
        → failed 置 non_retryable(retry-failed 排除、单文件 retry 409)。"""
        row, binding = FakeRow(), FakeBinding()
        db = FakeDb(get_map={(BaiduBinding, binding.id): binding})
        client = FakeClient(recheck_metas=[])    # 复核:文件确认不存在
        disposition = await _handle_baidu_error(
            db, make_runner(client=client, binding_id=binding.id), row, make_err(None, -9))
        upd = db.last_update(_TASK_FILE_TABLE)
        assert disposition not in (None, "retry")
        assert upd["status"] == "failed"
        assert upd["non_retryable"] is True

    async def test_not_found_after_rebind_mentions_account_replaced(self) -> None:
        """换绑后 not_found 文案甄别:快照 uid ≠ 当前 uid → 提示删除任务重建。"""
        row = FakeRow()
        task = FakeTask(bound_baidu_uid="100")
        binding = FakeBinding(baidu_uid="200")      # 已换绑
        db = FakeDb(get_map={
            (BaiduBackupTask, task.id): task,
            (BaiduBinding, binding.id): binding,
        })
        client = FakeClient(recheck_metas=[])       # 复核:文件确认不存在
        await _handle_baidu_error(
            db, make_runner(client=client, binding_id=binding.id, task_id=task.id), row,
            make_err(None, -9))
        last_error = str(db.last_update(_TASK_FILE_TABLE)["last_error"])
        assert "已更换" in last_error or "删除任务重建" in last_error, \
            f"换绑文案甄别缺失: {last_error}"
        assert "文件不存在" not in last_error, "直译「文件不存在」会误导"

    async def test_rate_limited_exhausts_five_attempts_then_row_failed(
        self, monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """§5.3:指数退避单文件上限 5 次,耗尽 → failed('rate_limited') 交手动重试。"""
        folder_id = uuid.uuid4()
        task = FakeTask(target_folder_id=folder_id)
        folder = FakeFolder(id=folder_id)
        row = FakeRow(target_folder_id=folder_id)
        db = FakeDb(
            select_result=FakeResult(rows=[], scalar_row=0),   # asset 预检空 + 聚合 SELECT 标量 0
            get_map={
                (BaiduBackupTask, task.id): task,
                (Project, task.project_id): FakeFolder(id=task.project_id, minio_prefix="p/"),
                (Folder, folder_id): folder,
            },
        )
        runner = make_runner(client=FakeClient(), task_id=task.id)

        calls: list[int] = []

        async def _always_rate_limited(_db: Any, _runner: Any, _row: Any) -> str:
            calls.append(1)
            raise make_err(503, None)

        async def _no_checkpoint(_db: Any, _runner: Any) -> None:
            return None

        monkeypatch.setattr(worker, "checkpoint", _no_checkpoint)
        monkeypatch.setattr(worker, "_ensure_dlink", _always_rate_limited)
        await worker._import_one_file(db, runner, row)

        assert len(calls) == MAX_FILE_ATTEMPTS == 5, "必须按 5 次上限耗尽"
        upd = db.last_update(_TASK_FILE_TABLE)
        assert upd["status"] == "failed"
        assert upd["non_retryable"] is False, "频控耗尽是可复活失败,不置 non_retryable"
        assert "限速" in str(upd["last_error"]) or "rate_limited" in str(upd["last_error"])

    async def test_row_error_last_error_never_contains_token(self) -> None:
        """last_error 落库前统一脱敏(§5.1)。"""
        db, row = FakeDb(), FakeRow()
        await _handle_baidu_error(
            db, make_runner(), row, make_err(403, -7, url=_TOKEN_URL))
        assert "SECRET.TOKEN" not in str(db.last_update(_TASK_FILE_TABLE)["last_error"] or "")


# ─── 退避策略(worker 内联实现;纯函数 backoff_delay_s 未单独落地)─────────────
class TestBackoffPolicy:
    def test_cap_constant_is_20s(self) -> None:
        """§5.3:单次退避封顶 ≤20s(≤ 租约 60s/3,防跨租约触发 sweeper 接管振荡)。"""
        assert FILE_BACKOFF_CAP_S <= 20
        assert ENUM_BACKOFF_CAP_S <= 20

    def test_max_attempts_is_5(self) -> None:
        assert MAX_FILE_ATTEMPTS == 5
        assert ENUM_BACKOFF_MAX_ATTEMPTS == 5

    def test_file_backoff_grows_exponentially_and_cap(self) -> None:
        """文件级公式(workers/baidu_backup.py:893):min(2.0**attempt, 封顶)。"""
        delays = [min(2.0 ** attempt, FILE_BACKOFF_CAP_S)
                  for attempt in range(1, MAX_FILE_ATTEMPTS + 1)]
        assert all(0 < d <= FILE_BACKOFF_CAP_S for d in delays), delays
        assert all(delays[i] <= delays[i + 1] for i in range(len(delays) - 1)), \
            "封顶前须非递减(指数增长)"
        assert min(2.0 ** 99, FILE_BACKOFF_CAP_S) == FILE_BACKOFF_CAP_S, \
            "超封顶 attempt 不得突破 20s"

    def test_enum_backoff_doubling_capped(self) -> None:
        """枚举级公式(workers/baidu_backup.py:477-497):1s 起倍增,封顶 20s。"""
        backoff = 1.0
        delays: list[float] = []
        for _ in range(ENUM_BACKOFF_MAX_ATTEMPTS):
            delays.append(backoff)
            backoff = min(backoff * 2, ENUM_BACKOFF_CAP_S)
        assert all(0 < d <= ENUM_BACKOFF_CAP_S for d in delays), delays
        assert all(delays[i] <= delays[i + 1] for i in range(len(delays) - 1))


# ─── token_crypto ─────────────────────────────────────────────────────────────
class TestTokenCrypto:
    def test_roundtrip(self) -> None:
        svc = TokenCryptoService(make_settings())
        ct = svc.encrypt("access-token-abc")
        assert svc.decrypt(ct) == "access-token-abc"

    def test_ciphertext_does_not_contain_plaintext(self) -> None:
        svc = TokenCryptoService(make_settings())
        ct = svc.encrypt("SUPER-SECRET-ACCESS-TOKEN")
        assert "SUPER-SECRET-ACCESS-TOKEN" not in ct

    def test_same_plaintext_produces_different_ciphertexts(self) -> None:
        """Fernet 随机 IV —— 同明文两密文不同,防库内比对推断。"""
        svc = TokenCryptoService(make_settings())
        assert svc.encrypt("same") != svc.encrypt("same")

    def test_derived_key_when_enc_key_unset_logs_warning(self, caplog: pytest.LogCaptureFixture) -> None:
        """§5.1/§11:BAIDU_TOKEN_ENC_KEY 未配置 → 由 session_jwt_secret sha256 派生 + warning。"""
        s = make_settings(baidu_token_enc_key=None)
        with caplog.at_level(logging.WARNING, logger="app.services.token_crypto"):
            key = derive_fernet_key(s.session_jwt_secret)
            svc = TokenCryptoService(s)
            ct = svc.encrypt("payload")
        assert isinstance(key, bytes) and len(key) == 44, "Fernet key(base64 32B)形状"
        assert svc.decrypt(ct) == "payload"
        warnings = [r for r in caplog.records if r.levelno == logging.WARNING]
        assert warnings, "派生密钥回退必须打 warning(运维感知 §11)"

    def test_explicit_enc_key_no_derivation_warning(self, caplog: pytest.LogCaptureFixture) -> None:
        with caplog.at_level(logging.WARNING, logger="app.services.token_crypto"):
            TokenCryptoService(make_settings(baidu_token_enc_key="a" * 32)).encrypt("payload")
        assert not [r for r in caplog.records if r.levelno == logging.WARNING]

    def test_key_rotation_breaks_old_ciphertext(self) -> None:
        """§5.1 轮换影响:更改派生源(JWT 密钥)后旧密文解密失败 → 按 expired 重新授权。"""
        from cryptography.fernet import InvalidToken

        old = TokenCryptoService(make_settings(session_jwt_secret="old-secret-0123456789abcdef"))
        new = TokenCryptoService(make_settings(session_jwt_secret="new-secret-0123456789abcdef"))
        ct = old.encrypt("payload")
        with pytest.raises(TokenDecryptError) as excinfo:
            new.decrypt(ct)
        assert isinstance(excinfo.value.__cause__, InvalidToken), "底层必须是 InvalidToken"


# ─── 长度护栏(§4,枚举时静态校验;结构性失败一律 non_retryable)───────────────
class TestLengthGuardrails:
    # ── path:rel_path ≤600 字符(guard_rel_path 第一道)─────────────────────────
    def test_rel_path_600_ok(self) -> None:
        assert guard_rel_path("", "a" * 250 + "/" + "a" * 250 + "/" + "a" * 98) is None

    def test_rel_path_601_flagged(self) -> None:
        assert guard_rel_path("", "a" * 250 + "/" + "a" * 250 + "/" + "a" * 99) == "path_too_long"

    def test_source_dir_must_be_absolute_not_root_within_600(self) -> None:
        """实现口径:合法返回 rstrip('/') 归一路径;违规抛 BaiduTaskError(400)。"""
        assert validate_source_dir("/media/照片") == "/media/照片"      # 合法
        assert validate_source_dir("/media/照片/") == "/media/照片"     # 尾斜杠归一
        for bad in ("/", "media/照片", "C:\\media", "/" + "a" * 600):
            with pytest.raises(BaiduTaskError):
                validate_source_dir(bad)

    # ── name:叶子段 UTF-8 >255 字节(MinIO 段限)或超 Asset.filename 512 字符 ──
    def test_filename_255_bytes_ok(self) -> None:
        name = "汉" * 85                              # 85x3 = 255B
        assert guard_rel_path("p/", name) is None

    def test_filename_256_bytes_leaf_segment_flagged(self) -> None:
        """§4:文件名叶子段 UTF-8 >255 字节 → name_too_long(86 汉字 = 258B)。"""
        name = "汉" * 86
        assert guard_rel_path("p/", name) == "name_too_long"

    def test_filename_ascii_boundary(self) -> None:
        assert guard_rel_path("p/", "a" * 255) is None
        assert guard_rel_path("p/", "a" * 256) == "name_too_long"

    def test_filename_over_512_chars_flagged(self) -> None:
        """Asset.filename String(512) 字符上限。"""
        assert guard_rel_path("", "x" * 513) == "name_too_long"

    # ── key:≤1024 字符(列定义)且 UTF-8 ≤1024 字节(S3/MinIO 硬限)──────────
    def test_key_1024_chars_ok_1025_flagged(self) -> None:
        """key = prefix + '/' + rel_path;前缀承担主体长度时叶子名仍须合法(≤255B)。"""
        assert guard_rel_path("a" * 798, "b" * 225) is None            # 798+1+225 = 1024
        assert guard_rel_path("a" * 798, "b" * 226) == "key_too_long"  # 1025

    def test_key_bytes_tighter_than_chars_for_multibyte(self) -> None:
        """字节口径先触发:叶子段须 ≤255B,故用多段 85 汉字(255B/段)拼长 key。
        4 段 x 85 汉 = 1020B + 3 个 '/' + 前导 '/' = key 恰 1024B(放行);
        再加一段即 1028B 超 key 字节限,而字符数(348)远小于 1024。"""
        rel_ok = "/".join(["汉" * 85] * 4)
        assert guard_rel_path("", rel_ok) is None
        rel_over = rel_ok + "/汉"
        assert len(rel_over) + 1 < 1024, "字符口径远未触发,证明是字节口径先到"
        assert guard_rel_path("", rel_over) == "key_too_long"

    def test_key_over_1024_chars_flagged(self) -> None:
        assert guard_rel_path("a" * 800, "b" * 225) == "key_too_long"  # 1026 字符

    def test_prefix_consuming_reduces_filename_budget(self) -> None:
        """§4:prefix 占用越多、文件名字节配额越小 —— 同一合法叶子名在深 prefix 下
        突破 key 字节限(浅 prefix 放行)。"""
        name = "汉" * 85                                 # 255B 合法叶子
        shallow = guard_rel_path("a" * 100, name)
        deep = guard_rel_path("a" * 800, name)
        assert shallow is None
        assert deep == "key_too_long"

    # ── 单文件上限 160GB = 10,000 parts x 16MB ────────────────────────────────
    def test_file_size_at_160gb_ok_beyond_flagged(self) -> None:
        part = 16 * 1024 * 1024
        assert guard_file_size(10_000 * part, part) is None
        assert guard_file_size(10_000 * part + 1, part) == "file_too_large"

    def test_file_size_boundary_follows_part_size(self) -> None:
        part = 5 * 1024 * 1024                        # 方案 §6:下限 5MiB
        assert guard_file_size(10_000 * part, part) is None
        assert guard_file_size(10_000 * part + 1, part) == "file_too_large"

    def test_zero_byte_ok(self) -> None:
        """§6:size=0 空文件走 put_object 直传,不触发护栏。"""
        assert guard_file_size(0, 16 * 1024 * 1024) is None

    # ── 承接夹名(source_dir rstrip('/') 后末段,≤255 字符;超长 → 创建 400)────
    def test_leaf_name_rstrips_trailing_slash_first(self) -> None:
        """§4:先 rstrip('/') 再取末段,防尾斜杠取出空名。"""
        assert source_dir_leaf_name("/media/照片备份/") == "照片备份"
        assert source_dir_leaf_name("/media/照片备份") == "照片备份"

    def test_auto_folder_name_over_255_flagged(self) -> None:
        """承接夹名 >255 字符 → 创建 400「网盘目录名过长」;实现为段名护栏
        check_segment_name(router 创建期内联 len(name)>255 同口径,详见对照注释)。"""
        assert check_segment_name("x" * 255) is None
        with pytest.raises(FolderChainError):
            check_segment_name("x" * 256)

    def test_leaf_name_of_root_is_empty_rejected_by_validate(self) -> None:
        assert source_dir_leaf_name("/") == ""        # 空名 → validate_source_dir 拒绝
        with pytest.raises(BaiduTaskError):
            validate_source_dir("/")


# ─── audit dedup_key 规则(§8;落地为 AUDIT_DEDUP_FMT 模板,ref=file_id)───────
class TestAuditDedupKey:
    def test_format_matches_spec(self) -> None:
        tid, fid = uuid.uuid4(), uuid.uuid4()
        key = AUDIT_DEDUP_FMT.format(task_id=tid, event="baidu_file_imported",
                                     ref=fid, retry=0, attempts=0)
        assert key == f"baidu_task:{tid}:baidu_file_imported:{fid}:r0:a0"

    def test_attempts_dimension_distinct(self) -> None:
        """§8:无 attempt 序号会吞同文件多次事件(ON CONFLICT DO NOTHING)。"""
        tid, fid = uuid.uuid4(), uuid.uuid4()
        a1 = AUDIT_DEDUP_FMT.format(task_id=tid, event="baidu_file_imported",
                                    ref=fid, retry=0, attempts=0)
        a2 = AUDIT_DEDUP_FMT.format(task_id=tid, event="baidu_file_imported",
                                    ref=fid, retry=0, attempts=1)
        assert a1 != a2
        assert a1.endswith("r0:a0") and a2.endswith("r0:a1")

    def test_retry_round_dimension_distinct(self) -> None:
        """§8:手动复活 attempts 归零而 task_id 不变 —— 无轮次维度则第二轮事件被吞。"""
        tid, fid = uuid.uuid4(), uuid.uuid4()
        r1 = AUDIT_DEDUP_FMT.format(task_id=tid, event="baidu_file_imported",
                                    ref=fid, retry=0, attempts=0)
        r2 = AUDIT_DEDUP_FMT.format(task_id=tid, event="baidu_file_imported",
                                    ref=fid, retry=1, attempts=0)
        assert r1 != r2
        assert r2.endswith("r1:a0")

    def test_ref_dimension_distinct(self) -> None:
        """ref 维度 = file_id(实现仅文件级事件落 dedup_key,无 :all: 任务级变体)。"""
        tid = uuid.uuid4()
        k1 = AUDIT_DEDUP_FMT.format(task_id=tid, event="baidu_file_imported",
                                    ref=uuid.uuid4(), retry=0, attempts=0)
        k2 = AUDIT_DEDUP_FMT.format(task_id=tid, event="baidu_file_imported",
                                    ref=uuid.uuid4(), retry=0, attempts=0)
        assert k1 != k2


# ─── netdisk folders 60s 缓存 key 口径(§9:60s (user_id,path) Redis 缓存)──────
class TestNetdiskFoldersCache:
    @staticmethod
    def _cache_key(user_id: uuid.UUID, path: str) -> str:
        """router 内联口径:routers/baidu_backup.py:498-500(path_hash=sha256[:32])。"""
        return _FOLDERS_CACHE_KEY.format(
            user_id=user_id,
            path_hash=hashlib.sha256(path.encode("utf-8")).hexdigest()[:32],
        )

    def test_ttl_is_60s(self) -> None:
        assert _FOLDERS_CACHE_TTL_S == 60

    def test_key_contains_user_and_path_hash(self) -> None:
        uid = uuid.uuid4()
        key = self._cache_key(uid, "/media")
        assert str(uid) in key
        assert hashlib.sha256(b"/media").hexdigest()[:32] in key, "path 以 sha256 口径进 key"

    def test_different_user_or_path_different_key(self) -> None:
        uid = uuid.uuid4()
        assert self._cache_key(uid, "/a") != self._cache_key(uid, "/b")
        assert self._cache_key(uid, "/a") != self._cache_key(uuid.uuid4(), "/a")

    def test_root_path_distinguished_from_child(self) -> None:
        uid = uuid.uuid4()
        assert self._cache_key(uid, "/") != self._cache_key(uid, "/apps")


# ─── token 刷新单飞(§5.3;落地于 services/baidu_backup.ensure_fresh_access_token)
class TestRefreshSingleFlight:
    async def test_unexpired_token_reused_without_http(self) -> None:
        """行锁内复查 expires_at(提前 60s 余量):未到期直接复用现存 token。"""
        binding = FakeBinding(access_token_expires_at=NOW + timedelta(minutes=30))
        client = FakeClient()
        token = await ensure_fresh_access_token(
            FakeDb(), binding, crypto=_CRYPTO, client=client)
        assert token == "at-old"
        assert client.refresh_calls == 0, "未到期不得打百度(白耗单次有效的 refresh_token)"

    async def test_expired_token_refreshed_and_atomically_overwritten(self) -> None:
        binding = FakeBinding(access_token_expires_at=NOW - timedelta(seconds=120))
        db = FakeDb(select_result=FakeResult(scalar_row=binding))
        client = FakeClient()
        token = await ensure_fresh_access_token(db, binding, crypto=_CRYPTO, client=client)
        assert token == "at-new"
        assert client.refresh_calls == 1
        assert _CRYPTO.decrypt(binding.access_token_enc) == "at-new"
        assert _CRYPTO.decrypt(binding.refresh_token_enc) == "rt-new"
        assert binding.access_token_expires_at > NOW, "过期时间原子覆盖"
        assert binding.token_rotated_at is not None, "任何 token 覆盖写入都刷新(§4 甄别锚点)"
        assert db.commits >= 1

    async def test_expiring_within_60s_margin_counts_as_expired(self) -> None:
        """提前 60s 余量判过期,防时钟偏差。"""
        binding = FakeBinding(access_token_expires_at=NOW + timedelta(seconds=30))
        db = FakeDb(select_result=FakeResult(scalar_row=binding))
        client = FakeClient()
        await ensure_fresh_access_token(db, binding, crypto=_CRYPTO, client=client)
        assert client.refresh_calls == 1

    async def test_concurrent_refresh_single_flight(self) -> None:
        """并发刷新须单飞:10 个并发调用只打一次百度 HTTP。"""
        client = FakeClient()
        lock = asyncio.Lock()      # 模拟 FOR UPDATE 串行化
        binding = FakeBinding(access_token_expires_at=NOW - timedelta(seconds=1))

        async def one() -> str:
            db = LockedFakeDb(lock, binding)   # 同一绑定行(同一把行锁)
            return await ensure_fresh_access_token(db, binding, crypto=_CRYPTO, client=client)

        tokens = await asyncio.gather(*(one() for _ in range(10)))
        assert all(t == "at-new" for t in tokens)
        assert client.refresh_calls == 1, f"单飞失效:刷新了 {client.refresh_calls} 次"

    async def test_refresh_http_failure_retry_three_times_then_expired(
        self, monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """§5.3:refresh 失败先按可重试处理(退避在行锁外,每次重试重新拿锁复查
        access_token_expires_at),连续 3 次失败才置 binding=expired
        (防单次网络抖动误杀绑定、白白消耗单次有效的 refresh_token)。"""
        monkeypatch.setattr(baidu_backup_service, "REFRESH_RETRY_BACKOFF_S", 0)
        client = FakeClient(refresh_ok=False)
        binding = FakeBinding(access_token_expires_at=NOW - timedelta(seconds=1))
        db = FakeDb(
            select_result=FakeResult(scalar_row=binding),
            get_map={(BaiduBinding, binding.id): binding},
        )
        with pytest.raises(BaiduTaskError):
            await ensure_fresh_access_token(db, binding, crypto=_CRYPTO, client=client)
        assert client.refresh_calls == 3, "3 次失败内不得放弃重试"
        assert binding.status == "expired", "连续 3 次失败 → binding=expired(收敛到重新授权)"
        assert _CRYPTO.decrypt(binding.access_token_enc) == "at-old", \
            "失败路径不得写入半个新 token"
