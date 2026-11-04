"""GET /api/v1/auth/public-config 两态 + Settings.resolve_mail_ready 配置矩阵。

方案 §5.2(公开配置端点)与 §5.10「启动校验与降级」:
- mail_ready=true → email_auth_enabled/password_reset_enabled=true;
  false(默认/配置非法)→ 双 false;password_min_length 恒返回(前端回落 8)。
- 非法配置矩阵:缺 EMAIL_LINK_BASE_URL / 内网 host(生产)/ 非 https(生产)/
  465 忘开 SSL / from 含危险字符 → false + 可读原因;不抛异常。
"""

from __future__ import annotations

from typing import Any

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import create_app
from app.routers import account_security
from app.settings import Settings

PUBLIC_URL = "/api/v1/auth/public-config"

# 一套「功能开启且合法」的基础配置(非生产 env,http/私网均放行)
VALID_BASE: dict[str, Any] = {
    "env": "test",
    "smtp_host": "smtp.example.com",
    "smtp_port": 587,
    "smtp_username": "noreply@example.com",
    "smtp_password": "secret",
    "smtp_from_email": "noreply@example.com",
    "email_auth_enabled": True,
    "email_link_base_url": "https://bucket.example.com/ms-static/web/",
}


def mk_settings(**overrides: Any) -> Settings:
    base: dict[str, Any] = {
        "env": "test",
        "db_url": "postgresql+asyncpg://u:p@localhost/db",
        "redis_url": "redis://localhost:6379/0",
        "minio_endpoint_internal": "http://minio:9000",
        "minio_endpoint_public": "http://localhost:9000",
        "minio_access_key": "k",
        "minio_secret_key": "s",
        "openfga_api_url": "http://openfga:8080",
        "openfga_store_id": "01TEST",
        "web_app_base_url": "http://localhost/ms-static/web/",
        "session_jwt_secret": "test-secret",
    }
    base.update(overrides)
    return Settings(**base)  # type: ignore[arg-type]


# ─── public-config 端点两态(不跑 lifespan,手动挂 app.state.mail_ready)──────
async def test_public_config_mail_ready_true(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    app = create_app()
    app.state.mail_ready = True
    monkeypatch.setattr(
        account_security,
        "get_settings",
        lambda: mk_settings(auth_password_min_length=10),
    )
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        resp = await ac.get(PUBLIC_URL)  # 无任何鉴权头
    assert resp.status_code == 200
    assert resp.json() == {
        "email_auth_enabled": True,
        "password_reset_enabled": True,
        "password_min_length": 10,
    }


async def test_public_config_mail_ready_false(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    app = create_app()
    app.state.mail_ready = False
    monkeypatch.setattr(
        account_security,
        "get_settings",
        lambda: mk_settings(auth_password_min_length=8),
    )
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        resp = await ac.get(PUBLIC_URL)
    assert resp.status_code == 200
    body = resp.json()
    assert body["email_auth_enabled"] is False
    assert body["password_reset_enabled"] is False
    assert body["password_min_length"] == 8  # 密码策略与邮箱开关无关,恒返回


async def test_public_config_mail_ready_missing_degrades_false() -> None:
    """lifespan 未跑(app.state 无 mail_ready)→ 兜底 false,不 500。"""
    app = create_app()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        resp = await ac.get(PUBLIC_URL)
    assert resp.status_code == 200
    assert resp.json()["email_auth_enabled"] is False


# ─── resolve_mail_ready:合法/开关关闭 ────────────────────────────────────────
def test_mail_ready_valid_config() -> None:
    s = mk_settings(**VALID_BASE)
    assert s.resolve_mail_ready() is True
    ok, reason = s.resolve_mail_ready(detail=True)
    assert ok is True and reason == "ok"


def test_mail_ready_disabled_by_default_skips_validation() -> None:
    """EMAIL_AUTH_ENABLED=false → 直接 false;其余配置再烂也不校验(默认态安静)。"""
    s = mk_settings(email_auth_enabled=False, smtp_host=None, email_link_base_url=None)
    assert s.resolve_mail_ready() is False
    ok, reason = s.resolve_mail_ready(detail=True)
    assert ok is False and "EMAIL_AUTH_ENABLED" in reason


def test_mail_ready_valid_dev_http_private_host() -> None:
    """dev/test 环境 http + 私网 host 放行(§9.2 dev 口径)。"""
    s = mk_settings(**{**VALID_BASE, "email_link_base_url": "http://192.168.110.221:8090/ms-static/web/"})
    assert s.resolve_mail_ready() is True


def test_mail_ready_lan_configured_ok() -> None:
    s = mk_settings(**{**VALID_BASE, "email_link_base_url_lan": "http://192.168.110.221:8090/ms-static/web/"})
    assert s.resolve_mail_ready() is True


# ─── resolve_mail_ready:非法配置矩阵(→ false + 原因)────────────────────────
def _assert_invalid(overrides: dict[str, Any], reason_kw: str) -> None:
    s = mk_settings(**{**VALID_BASE, **overrides})
    ok, reason = s.resolve_mail_ready(detail=True)
    assert ok is False, (overrides, reason)
    assert reason_kw in reason, (overrides, reason)


def test_mail_ready_missing_link_base_url() -> None:
    _assert_invalid({"email_link_base_url": None}, "EMAIL_LINK_BASE_URL")


def test_mail_ready_smtp_incomplete() -> None:
    _assert_invalid({"smtp_host": None}, "SMTP")


def test_mail_ready_username_without_password() -> None:
    _assert_invalid({"smtp_password": None}, "SMTP_USERNAME")


def test_mail_ready_ssl_and_tls_both_on() -> None:
    _assert_invalid({"smtp_use_ssl": True, "smtp_use_tls": True}, "互斥")


def test_mail_ready_port_465_without_ssl() -> None:
    _assert_invalid({"smtp_port": 465, "smtp_use_ssl": False, "smtp_use_tls": True}, "465")


def test_mail_ready_port_587_without_tls() -> None:
    _assert_invalid({"smtp_port": 587, "smtp_use_ssl": False, "smtp_use_tls": False}, "587")


def test_mail_ready_from_email_unsafe() -> None:
    _assert_invalid({"smtp_from_email": "素材库 <noreply@example.com>"}, "SMTP_FROM_EMAIL")


def test_mail_ready_from_name_with_crlf() -> None:
    _assert_invalid({"smtp_from_name": "素材库\r\nBcc: x@y.com"}, "SMTP_FROM_NAME")


def test_mail_ready_link_base_url_bad_suffix() -> None:
    _assert_invalid({"email_link_base_url": "https://bucket.example.com/web/"}, "/ms-static/web/")


def test_mail_ready_link_base_url_with_query() -> None:
    _assert_invalid({"email_link_base_url": "https://bucket.example.com/ms-static/web/?next=1"}, "查询串")


def test_mail_ready_link_base_url_with_fragment() -> None:
    _assert_invalid({"email_link_base_url": "https://bucket.example.com/ms-static/web/#token=x"}, "fragment")


def test_mail_ready_link_base_url_not_http() -> None:
    _assert_invalid({"email_link_base_url": "ftp://bucket.example.com/ms-static/web/"}, "http(s)")


def test_mail_ready_lan_invalid() -> None:
    _assert_invalid(
        {"email_link_base_url_lan": "http://192.168.110.221:8090/web/#x"}, "EMAIL_LINK_BASE_URL_LAN"
    )


# ─── 生产专属:非 https / 内网 host / localhost ───────────────────────────────
def test_mail_ready_prod_requires_https() -> None:
    _assert_invalid(
        {"env": "production", "email_link_base_url": "http://bucket.example.com/ms-static/web/"}, "https"
    )


def test_mail_ready_prod_rejects_private_ip() -> None:
    _assert_invalid(
        {"env": "production", "email_link_base_url": "https://192.168.110.221/ms-static/web/"}, "私网"
    )


def test_mail_ready_prod_rejects_loopback_v6() -> None:
    _assert_invalid({"env": "production", "email_link_base_url": "https://[::1]/ms-static/web/"}, "私网")


def test_mail_ready_prod_rejects_localhost() -> None:
    _assert_invalid(
        {"env": "production", "email_link_base_url": "https://localhost/ms-static/web/"}, "公网域名"
    )


def test_mail_ready_prod_rejects_local_suffix() -> None:
    _assert_invalid(
        {"env": "production", "email_link_base_url": "https://intranet.local/ms-static/web/"}, "公网域名"
    )


def test_mail_ready_prod_https_public_host_ok() -> None:
    s = mk_settings(
        **{
            **VALID_BASE,
            "env": "production",
            "email_link_base_url": "https://bucket.taoxiplan.com/ms-static/web/",
        }
    )
    assert s.resolve_mail_ready() is True
