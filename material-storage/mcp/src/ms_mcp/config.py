"""ms-mcp 配置解析与 Host 白名单 / XFP 归一语义。

本模块只做纯函数与不可变数据,不建连接、不读全局单例 —— 便于单测直接构造。
"""

from __future__ import annotations

import logging
import os
from collections.abc import Mapping
from dataclasses import dataclass
from urllib.parse import urlsplit

log = logging.getLogger(__name__)

VALID_SCHEMES = ("http", "https")

# 会话数上限 = 编译常量(方案:仅测试构建可注入;运行期不读 env 调大)。
# 200 足够一队 agent 共用,失控客户端最多把表撑到这里。
SESSION_CAP = 200

# 按工具调用粒度(非连接粒度)的进程内并发信号量上限(纵深防御;正本闸在 api)。
# 取 32:略高于 api 侧默认全局 8,只兜「ms-mcp 自身被单客户端打满」的极端形态,
# 不替代 api 的绝对配额。
TOOL_CONCURRENCY = 32

DEFAULT_SESSION_TTL_SECONDS = 1800.0

# 未配置时只放行本机调试 —— 生产漏配 = 全量 403(安全默认),而非放行任意 Host。
FALLBACK_ALLOWLIST = "localhost=http,127.0.0.1=http"

# 方案「当前有效值」:白名单条目 ≤14,去重 scheme://host 全集 ≤16。
# ms-mcp 只能看到自己这一份,并集检查(含 web/app 的入口)在部署 checklist 里。
MAX_ALLOWLIST_ENTRIES = 14
MAX_UNIQUE_SCHEME_HOSTS = 16

DEFAULT_API_BASE_URL = "http://ms-api:8000"


class ConfigError(RuntimeError):
    """启动期配置非法(非法即拒绝启动,避免带着坏白名单静默全量 403)。"""


@dataclass(frozen=True)
class AllowEntry:
    """白名单条目:一个真实可用入口的 Host(含端口拼法)+ 该入口的 scheme。"""

    host: str      # 一律 lower();比较时请求 Host 也 lower()
    scheme: str    # http / https —— XFP 归一与默认值取这里


@dataclass(frozen=True)
class Settings:
    api_base_url: str
    internal_base_url: str
    internal_host: str          # Host 头取值(netloc,含显式端口),已 lower()
    internal_scheme: str        # XFP 取值
    allowlist: dict[str, AllowEntry]
    session_ttl: float = DEFAULT_SESSION_TTL_SECONDS
    verify_tls: bool = True
    ca_bundle: str | None = None
    session_cap: int = SESSION_CAP
    tool_concurrency: int = TOOL_CONCURRENCY

    def entry_for_host(self, host: str | None) -> AllowEntry | None:
        """Host 守门:host 与白名单均 lower() 后精确比较(保留端口)。"""
        if not host:
            return None
        return self.allowlist.get(host.strip().lower())

    def normalized_xfp(self, entry: AllowEntry, raw: str | None) -> str:
        """XFP 归一(方案 D12)。

        - 客户端自报值与命中条目的 scheme 一致且合法 → 透传;
        - 冲突 / 缺失 / 非法(含 wss、逗号多值)→ 一律用条目 scheme,不采信客户端。
        """
        value = (raw or "").strip().lower()
        if value in VALID_SCHEMES and value == entry.scheme:
            return value
        return entry.scheme


def parse_allowlist(raw: str) -> dict[str, AllowEntry]:
    """解析 `host=scheme,host=scheme` 形式的入口白名单。

    - 条目内 host 与 scheme 都 lower();
    - 同一 host 重复出现且 scheme 一致 → 去重;scheme 冲突 → ConfigError
      (一个 Host 只能对应一个 scheme,否则 XFP 归一没有唯一答案);
    - 非法 scheme / 空 host / 含 `/` 或空格的 host → ConfigError。
    """
    entries: dict[str, AllowEntry] = {}
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        if item.count("=") != 1:
            raise ConfigError(f"白名单条目格式应为 host=scheme:{item!r}")
        host_part, scheme_part = item.split("=", 1)
        host = host_part.strip().lower()
        scheme = scheme_part.strip().lower()
        if not host:
            raise ConfigError(f"白名单条目 host 为空:{item!r}")
        if "/" in host or any(ch.isspace() for ch in host):
            raise ConfigError(f"白名单条目 host 非法:{item!r}")
        if scheme not in VALID_SCHEMES:
            raise ConfigError(f"白名单条目 scheme 只支持 http/https:{item!r}")
        existing = entries.get(host)
        if existing is not None:
            if existing.scheme != scheme:
                raise ConfigError(
                    f"白名单 host {host!r} 同时配了 {existing.scheme} 与 {scheme},请按环境裁剪"
                )
            continue
        entries[host] = AllowEntry(host=host, scheme=scheme)

    if not entries:
        raise ConfigError("MS_MCP_ENTRY_ALLOWLIST 为空")
    if len(entries) > MAX_ALLOWLIST_ENTRIES:
        log.warning(
            "MS_MCP_ENTRY_ALLOWLIST 有 %d 条(建议 ≤%d):条目越多,动态 signer 缓存越易被打满",
            len(entries), MAX_ALLOWLIST_ENTRIES,
        )
    unique = {f"{e.scheme}://{e.host}" for e in entries.values()}
    if len(unique) > MAX_UNIQUE_SCHEME_HOSTS:
        log.warning(
            "MS_MCP_ENTRY_ALLOWLIST 去重 scheme://host = %d(硬约束 ≤%d,需与 web/app 入口并集核对)",
            len(unique), MAX_UNIQUE_SCHEME_HOSTS,
        )
    return entries


def _parse_bool(raw: str, *, name: str) -> bool:
    value = raw.strip().lower()
    if value in ("1", "true", "yes", "on"):
        return True
    if value in ("0", "false", "no", "off"):
        return False
    raise ConfigError(f"{name} 只接受 true/false,收到 {raw!r}")


def _split_base_url(url: str, *, name: str) -> tuple[str, str]:
    parts = urlsplit(url.strip())
    if parts.scheme not in VALID_SCHEMES:
        raise ConfigError(f"{name} 必须带 http/https scheme:{url!r}")
    if not parts.netloc:
        raise ConfigError(f"{name} 缺少主机:{url!r}")
    return parts.scheme, parts.netloc.lower()


def _build_internal(settings_allowlist: dict[str, AllowEntry], url: str) -> tuple[str, str]:
    scheme, host = _split_base_url(url, name="MS_MCP_INTERNAL_BASE_URL")
    entry = settings_allowlist.get(host)
    if entry is None:
        raise ConfigError(
            f"MS_MCP_INTERNAL_BASE_URL 的 Host {host!r} 不在 MS_MCP_ENTRY_ALLOWLIST 内"
            "(取缩略图字节必须能签出该入口的 URL)"
        )
    if entry.scheme != scheme:
        raise ConfigError(
            f"MS_MCP_INTERNAL_BASE_URL 的 scheme={scheme} 与白名单条目 {entry.scheme} 不一致"
        )
    return host, scheme


def settings_from_env(env: Mapping[str, str] | None = None) -> Settings:
    """从环境变量构造配置。缺省值与 compose 的 `${VAR:-default}` 保持一致。"""
    env = os.environ if env is None else env

    api_base_url = (env.get("MS_API_BASE_URL") or DEFAULT_API_BASE_URL).strip().rstrip("/")
    _split_base_url(api_base_url, name="MS_API_BASE_URL")

    raw_allowlist = env.get("MS_MCP_ENTRY_ALLOWLIST")
    if not raw_allowlist or not raw_allowlist.strip():
        log.warning("MS_MCP_ENTRY_ALLOWLIST 未配置,回落到仅本机调试白名单(%s)", FALLBACK_ALLOWLIST)
        raw_allowlist = FALLBACK_ALLOWLIST
    allowlist = parse_allowlist(raw_allowlist)

    internal_base_url = (env.get("MS_MCP_INTERNAL_BASE_URL") or "").strip().rstrip("/")
    if not internal_base_url:
        raise ConfigError(
            "MS_MCP_INTERNAL_BASE_URL 未配置(取缩略图字节的固定内网入口,如 http://192.168.110.221)"
        )
    internal_host, internal_scheme = _build_internal(allowlist, internal_base_url)

    ttl_raw = (env.get("MS_MCP_SESSION_TTL") or "").strip()
    try:
        session_ttl = float(ttl_raw) if ttl_raw else DEFAULT_SESSION_TTL_SECONDS
    except ValueError as exc:
        raise ConfigError(f"MS_MCP_SESSION_TTL 必须是秒数,收到 {ttl_raw!r}") from exc
    if session_ttl <= 0:
        raise ConfigError("MS_MCP_SESSION_TTL 必须 > 0")

    verify_raw = (env.get("MS_MCP_VERIFY_TLS") or "true").strip()
    verify_tls = _parse_bool(verify_raw, name="MS_MCP_VERIFY_TLS")

    ca_bundle = (env.get("MS_MCP_CA_BUNDLE") or "").strip() or None
    if ca_bundle is not None and not os.path.isfile(ca_bundle):
        raise ConfigError(f"MS_MCP_CA_BUNDLE 指向的文件不存在:{ca_bundle}")

    return Settings(
        api_base_url=api_base_url,
        internal_base_url=internal_base_url,
        internal_host=internal_host,
        internal_scheme=internal_scheme,
        allowlist=allowlist,
        session_ttl=session_ttl,
        verify_tls=verify_tls,
        ca_bundle=ca_bundle,
    )
