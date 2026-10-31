"""日志脱敏单测:presigned URL 的查询串 / Session-Id / PAT 不落日志。"""

from __future__ import annotations

import logging

import pytest

from ms_mcp.logging_utils import SessionIdRedactionFilter, install_log_redaction

SIGNATURE = "b6f4c1a9" * 8
CREDENTIAL = "AKIAEXAMPLE/20261031/ap-east-1/s3/aws4_request"
SECURITY_TOKEN = "FwoGZXIvYXdzEXAMPLE"
SESSION_ID = "0123456789abcdef0123456789abcdef"
URL_PATH = "http://192.168.110.221/ms-thumbs/p/f/thumb-x.png"
SIGNED_URL = (
    f"{URL_PATH}?X-Amz-Algorithm=AWS4-HMAC-SHA256"
    f"&X-Amz-Credential={CREDENTIAL}"
    f"&X-Amz-Security-Token={SECURITY_TOKEN}"
    f"&X-Amz-Signature={SIGNATURE}"
)


def _redact(message: str, *args: object) -> str:
    record = logging.LogRecord(
        "ms_mcp.test", logging.INFO, __file__, 1, message, args, None
    )
    assert SessionIdRedactionFilter().filter(record) is True
    return record.getMessage()


def test_presigned_url_query_is_redacted() -> None:
    out = _redact("HTTP Request: GET %s", SIGNED_URL)
    # scheme/host/path 保留,查询串整体抹掉
    assert out == f"HTTP Request: GET {URL_PATH}?<redacted>"
    assert "X-Amz-Signature" not in out
    assert SIGNATURE not in out
    assert CREDENTIAL not in out
    assert SECURITY_TOKEN not in out


def test_session_id_and_url_query_redacted_together() -> None:
    out = _redact("session=%s GET %s", SESSION_ID, SIGNED_URL)
    assert SESSION_ID not in out
    assert "<session-id-redacted>" in out
    assert SIGNATURE not in out
    assert URL_PATH + "?<redacted>" in out


def test_signed_query_without_scheme_is_redacted() -> None:
    out = _redact("GET /ms-thumbs/p/f/x.png?X-Amz-Signature=%s", SIGNATURE)
    assert out == "GET /ms-thumbs/p/f/x.png?<redacted>"
    assert SIGNATURE not in out


def test_httpx_logger_is_filtered(caplog: pytest.LogCaptureFixture) -> None:
    install_log_redaction()
    # install 必须把过滤器挂在 httpx logger 自身(不能只挂根 handler)
    http_logger = logging.getLogger("httpx")
    assert any(isinstance(f, SessionIdRedactionFilter) for f in http_logger.filters)

    with caplog.at_level(logging.INFO):
        http_logger.info(
            'HTTP Request: %s %s "%s %d %s"',
            "GET", SIGNED_URL, "HTTP/1.1", 200, "OK",
        )
    assert "X-Amz-Signature" not in caplog.text
    assert SIGNATURE not in caplog.text
    assert SECURITY_TOKEN not in caplog.text
    # 排障所需信息(method/path/status)仍在
    assert f"GET {URL_PATH}?<redacted>" in caplog.text
    assert "200 OK" in caplog.text
