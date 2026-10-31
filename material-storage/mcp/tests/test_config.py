"""配置解析 / Host 白名单 / XFP 归一单测。"""

from __future__ import annotations

import pytest

from ms_mcp.config import (
    AllowEntry,
    ConfigError,
    Settings,
    parse_allowlist,
    settings_from_env,
)

BASE_ENV = {
    "MS_API_BASE_URL": "http://ms-api:8000",
    "MS_MCP_ENTRY_ALLOWLIST": "ms.local=http,47.108.196.211:18080=http,192.168.110.221=http",
    "MS_MCP_INTERNAL_BASE_URL": "http://192.168.110.221",
}


def test_parse_allowlist_lowercases_and_dedupes() -> None:
    entries = parse_allowlist("MS.LOCAL=http, ms.local=http,ms.local:8090=HTTP")
    assert set(entries) == {"ms.local", "ms.local:8090"}
    assert entries["ms.local"].scheme == "http"
    assert entries["ms.local:8090"].scheme == "http"


def test_parse_allowlist_rejects_conflicting_scheme() -> None:
    with pytest.raises(ConfigError):
        parse_allowlist("ms.local=http,ms.local=https")


@pytest.mark.parametrize("raw", ["", "  ", "ms.local", "ms.local=ftp", "=http", "a b=http"])
def test_parse_allowlist_rejects_invalid(raw: str) -> None:
    with pytest.raises(ConfigError):
        parse_allowlist(raw)


def test_settings_from_env_ok() -> None:
    settings = settings_from_env(BASE_ENV)
    assert settings.api_base_url == "http://ms-api:8000"
    assert settings.internal_host == "192.168.110.221"
    assert settings.internal_scheme == "http"
    assert settings.session_ttl == 1800.0
    assert settings.session_cap == 200
    assert settings.entry_for_host("MS.LOCAL") is settings.entry_for_host("ms.local")


def test_settings_from_env_requires_internal_base() -> None:
    env = dict(BASE_ENV)
    env.pop("MS_MCP_INTERNAL_BASE_URL")
    with pytest.raises(ConfigError):
        settings_from_env(env)


def test_settings_from_env_internal_host_must_be_allowlisted() -> None:
    env = dict(BASE_ENV)
    env["MS_MCP_INTERNAL_BASE_URL"] = "http://10.0.0.9"
    with pytest.raises(ConfigError):
        settings_from_env(env)


def test_settings_from_env_internal_scheme_must_match_entry() -> None:
    env = dict(BASE_ENV)
    env["MS_MCP_INTERNAL_BASE_URL"] = "https://192.168.110.221"
    with pytest.raises(ConfigError):
        settings_from_env(env)


def test_settings_from_env_allowlist_fallback_is_localhost_only() -> None:
    env = dict(BASE_ENV)
    env.pop("MS_MCP_ENTRY_ALLOWLIST")
    env["MS_MCP_INTERNAL_BASE_URL"] = "http://127.0.0.1"
    settings = settings_from_env(env)
    assert set(settings.allowlist) == {"localhost", "127.0.0.1"}


def test_settings_from_env_ttl_and_tls() -> None:
    env = dict(BASE_ENV)
    env["MS_MCP_SESSION_TTL"] = "45"
    env["MS_MCP_VERIFY_TLS"] = "false"
    settings = settings_from_env(env)
    assert settings.session_ttl == 45.0
    assert settings.verify_tls is False


def test_settings_from_env_rejects_bad_ttl_and_bool() -> None:
    env = dict(BASE_ENV)
    env["MS_MCP_SESSION_TTL"] = "abc"
    with pytest.raises(ConfigError):
        settings_from_env(env)
    env = dict(BASE_ENV)
    env["MS_MCP_VERIFY_TLS"] = "maybe"
    with pytest.raises(ConfigError):
        settings_from_env(env)


def test_zero_ttl_rejected() -> None:
    env = dict(BASE_ENV)
    env["MS_MCP_SESSION_TTL"] = "0"
    with pytest.raises(ConfigError):
        settings_from_env(env)


def _settings() -> Settings:
    return Settings(
        api_base_url="http://ms-api:8000",
        internal_base_url="http://192.168.110.221",
        internal_host="192.168.110.221",
        internal_scheme="http",
        allowlist=parse_allowlist("ms.local=http,47.108.196.211:18080=http,bucket.taoxiplan.com=https"),
    )


def test_entry_for_host_is_case_insensitive_and_port_sensitive() -> None:
    settings = _settings()
    assert settings.entry_for_host("MS.LOCAL") is not None
    assert settings.entry_for_host("ms.local:8090") is None
    assert settings.entry_for_host("47.108.196.211:18080") is not None
    assert settings.entry_for_host("47.108.196.211") is None


@pytest.mark.parametrize(
    ("entry", "raw", "expected"),
    [
        (AllowEntry("ms.local", "http"), "http", "http"),
        (AllowEntry("ms.local", "http"), "HTTPS", "http"),      # 冲突 → 以条目为准
        (AllowEntry("ms.local", "http"), None, "http"),           # 缺失 → 条目默认
        (AllowEntry("ms.local", "http"), "", "http"),
        (AllowEntry("ms.local", "http"), "wss", "http"),          # 非法 → 条目
        (AllowEntry("bucket.taoxiplan.com", "https"), "https", "https"),
        (AllowEntry("bucket.taoxiplan.com", "https"), "http", "https"),
        (AllowEntry("bucket.taoxiplan.com", "https"), "http,https", "https"),
    ],
)
def test_normalized_xfp(entry: AllowEntry, raw: str | None, expected: str) -> None:
    assert _settings().normalized_xfp(entry, raw) == expected
