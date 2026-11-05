"""B6 运维脚本契约测试(check_email_duplicates / send_test_mail / mark_email_verified)。

方案:rushes-spec/material-storage/email-account-and-password-reset-plan.md
§4.4(纯 text 预检)/ §9.5(三脚本规格)/ §10.1 补充分支
(mark 严格正则+大小写比较;check 纯 text、脱敏)。

全 monkeypatch 隔离(DB / SMTP / stdin),不依赖真实容器(2026-10-20 立:
本地 docker 一律禁止);形态照 test_backfill_script.py(CapDB + argv 注入)。
"""

from __future__ import annotations

import sys
import uuid
from io import StringIO
from types import SimpleNamespace
from typing import Any

import pytest
from sqlalchemy import TextClause

import scripts.check_email_duplicates as ced
import scripts.mark_email_verified as mev
import scripts.send_test_mail as stm
from app.services.mailer import MailSendError
from app.settings import Settings


def mk_settings(**extra: Any) -> Settings:
    base: dict[str, Any] = dict(
        env="test", db_url="postgresql+asyncpg://u:p@localhost/db",
        redis_url="redis://localhost:6379/0",
        minio_endpoint_internal="http://minio:9000", minio_endpoint_public="http://localhost:9000",
        minio_access_key="k", minio_secret_key="s", openfga_api_url="http://openfga:8080",
        openfga_store_id="01TEST", web_app_base_url="http://localhost/ms-static/web/",
        session_jwt_secret="test-secret",
    )
    base.update(extra)
    return Settings(**base)


SMTP_OK = dict(
    smtp_host="smtp.example.com", smtp_port=465, smtp_use_ssl=True, smtp_use_tls=False,
    smtp_username="noreply@example.com", smtp_password="pw",
    smtp_from_email="noreply@example.com", smtp_from_name="素材库",
    email_auth_enabled=True, email_link_base_url="https://bucket.example.com/ms-static/web/",
)


# ─── check_email_duplicates(§4.4:纯 text + 脱敏输出 + 阻断退出码)────────────


class _Res:
    def __init__(self, rows: list[Any]) -> None:
        self._rows = rows

    def all(self) -> list[Any]:
        return list(self._rows)

    def one(self) -> Any:
        assert self._rows, "stats 单行结果"
        return self._rows[0]


class _CapDB:
    """按调用序回放结果并捕获语句(断言纯 text、无新列引用)。"""

    def __init__(self, results: list[Any]) -> None:
        self._results = results
        self.stmts: list[Any] = []

    async def execute(self, stmt: Any, params: Any = None) -> _Res:
        self.stmts.append(stmt)
        return _Res(self._results[len(self.stmts) - 1])


async def test_check_pure_text_and_no_new_columns() -> None:
    """§4.4 硬约束:全部语句是 TextClause(不 import ORM);显式列清单里
    不出现 0021 新列(email_verified_at / session_version)。"""
    db = _CapDB([[], [], [SimpleNamespace(non_empty=0, empty_like=0, has_upper=0,
                                         suspect_invalid=0)], [], [], []])
    await ced.run_check(db)
    assert len(db.stmts) == 6
    for stmt in db.stmts:
        assert isinstance(stmt, TextClause), "预检必须纯 text(),不得 import ORM"
        compiled = " ".join(str(stmt.compile()).split()).lower()
        assert "email_verified_at" not in compiled
        assert "session_version" not in compiled
        assert "select *" not in compiled


async def test_check_clean_exit_zero(capsys: pytest.CaptureFixture[str]) -> None:
    db = _CapDB([[], [], [SimpleNamespace(non_empty=0, empty_like=0, has_upper=0,
                                         suspect_invalid=0)], [], [], []])
    code = await ced.run_check(db)
    out = capsys.readouterr().out
    assert code == 0
    assert "无阻断项" in out and "疑似严格格式非法 0" in out


async def test_check_blocks_and_masks(capsys: pytest.CaptureFixture[str]) -> None:
    """重复/跨列冲突 → 退出码 1;终端只出现脱敏值 + 用户 id,完整邮箱不落盘。"""
    dup = SimpleNamespace(norm_email="alice@example.com", n=2,
                          user_ids="11111111-1111-1111-1111-111111111111,"
                                   "22222222-2222-2222-2222-222222222222")
    cross = SimpleNamespace(username_user_id="33333333-3333-3333-3333-333333333333",
                            username_user_name="甲", email_user_id="44444444-4444-4444-4444-444444444444",
                            email_user_name="乙", username_value="alice@example.com",
                            email_value="alice@example.com")
    upper = SimpleNamespace(user_id="55555555-5555-5555-5555-555555555555",
                            email="Bob@Example.com")
    invalid = SimpleNamespace(user_id="66666666-6666-6666-6666-666666666666",
                              email="carol@localhost")
    stats = SimpleNamespace(non_empty=4, empty_like=1, has_upper=1, suspect_invalid=1)
    db = _CapDB([[dup], [cross], [stats], [upper], [invalid],
                 [SimpleNamespace(user_id="77777777-7777-7777-7777-777777777777")]])

    code = await ced.run_check(db)

    out = capsys.readouterr().out
    assert code == 1
    assert "存在阻断项" in out
    assert "a***@example.com" in out, "脱敏形态必须出现(可辨识)"
    assert "alice@example.com" not in out, "完整邮箱不得落终端"
    assert "Bob@Example.com" not in out and "carol@localhost" not in out
    assert "11111111-1111-1111-1111-111111111111" in out, "重复组带用户 id"
    assert "33333333-3333-3333-3333-333333333333" in out, "跨列冲突带双方用户 id"
    assert "疑似严格格式非法 1" in out


# ─── send_test_mail(§9.5:stdin 收件人 + FakeMailer 注入 + 参数解析)──────────


class FakeMailer:
    def __init__(self, exc: Exception | None = None) -> None:
        self.calls: list[dict[str, Any]] = []
        self._exc = exc

    async def __call__(self, settings: Any, **kw: Any) -> None:
        self.calls.append(kw)
        if self._exc is not None:
            raise self._exc


def _patch_env(monkeypatch: pytest.MonkeyPatch, *, mailer: FakeMailer,
               settings: Settings, stdin: str | None = None) -> None:
    monkeypatch.setattr(stm, "send_mail", mailer)
    monkeypatch.setattr(stm, "get_settings", lambda: settings)
    if stdin is not None:
        monkeypatch.setattr(sys, "stdin", StringIO(stdin))


def test_send_reads_recipient_from_stdin_and_masks(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str],
) -> None:
    """`docker exec -i` 管道场景:收件人从 stdin 读;输出/正文脱敏;退出 0。

    (同步用例:main() 内部走 asyncio.run,不能在 pytest-asyncio 事件循环里调。)
    """
    mailer = FakeMailer()
    _patch_env(monkeypatch, mailer=mailer, settings=mk_settings(**SMTP_OK),
               stdin="ops@example.com\n")
    monkeypatch.setattr(sys, "argv", ["send_test_mail"])

    code = stm.main()

    out = capsys.readouterr().out
    assert code == 0
    assert len(mailer.calls) == 1
    assert mailer.calls[0]["to"] == "ops@example.com", "send_mail 收到归一化后的地址"
    assert "o***@example.com" in out and "ops@example.com" not in out
    assert "mail_ready=True(ok)" in out
    assert "素材库" in mailer.calls[0]["body"] or "SMTP" in mailer.calls[0]["body"]


async def test_send_to_dash_flag_reads_stdin(monkeypatch: pytest.MonkeyPatch) -> None:
    """`--to -` 与省略 --to 且非 tty 同型:都从 stdin 读一行。"""
    monkeypatch.setattr(sys, "stdin", StringIO("pipe@example.com\n"))
    assert stm.resolve_recipient("-", prompt=True) == "pipe@example.com"
    monkeypatch.setattr(sys, "stdin", StringIO("pipe2@example.com\n"))
    assert stm.resolve_recipient(None, prompt=False) == "pipe2@example.com"


async def test_send_interactive_prompt_used_when_tty(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(stm, "_prompt", lambda msg: "tty@example.com")
    assert stm.resolve_recipient(None, prompt=True) == "tty@example.com"


def test_send_invalid_recipient_rejected(monkeypatch: pytest.MonkeyPatch,
                                         capsys: pytest.CaptureFixture[str]) -> None:
    mailer = FakeMailer()
    _patch_env(monkeypatch, mailer=mailer, settings=mk_settings(**SMTP_OK),
               stdin="not-an-email\n")
    monkeypatch.setattr(sys, "argv", ["send_test_mail"])

    code = stm.main()

    assert code == 2
    err = capsys.readouterr().err
    assert "不合法" in err
    assert mailer.calls == [], "格式非法不得触达 send_mail"


def test_send_empty_stdin_rejected(monkeypatch: pytest.MonkeyPatch,
                                   capsys: pytest.CaptureFixture[str]) -> None:
    mailer = FakeMailer()
    _patch_env(monkeypatch, mailer=mailer, settings=mk_settings(**SMTP_OK), stdin="\n")
    monkeypatch.setattr(sys, "argv", ["send_test_mail"])

    assert stm.main() == 2
    assert "收件人为空" in capsys.readouterr().err


def test_send_requires_smtp_configured(monkeypatch: pytest.MonkeyPatch,
                                       capsys: pytest.CaptureFixture[str]) -> None:
    mailer = FakeMailer()
    _patch_env(monkeypatch, mailer=mailer, settings=mk_settings(), stdin="ops@example.com\n")
    monkeypatch.setattr(sys, "argv", ["send_test_mail"])

    code = stm.main()

    assert code == 1
    assert "SMTP 未配置" in capsys.readouterr().err
    assert mailer.calls == []


@pytest.mark.parametrize("definite,keyword", [(True, "确定失败"), (False, "结果未知")])
def test_send_failure_branches(monkeypatch: pytest.MonkeyPatch,
                               capsys: pytest.CaptureFixture[str],
                               definite: bool, keyword: str) -> None:
    mailer = FakeMailer(MailSendError("boom", definite=definite))
    _patch_env(monkeypatch, mailer=mailer, settings=mk_settings(**SMTP_OK),
               stdin="ops@example.com\n")
    monkeypatch.setattr(sys, "argv", ["send_test_mail"])

    code = stm.main()

    assert code == 1
    assert keyword in capsys.readouterr().err


# ─── mark_email_verified(§9.5:大小写比较 / 非法拒绝 / 审计脱敏)──────────────


class _Scalars:
    def __init__(self, items: list[Any]) -> None:
        self._items = items

    def first(self) -> Any:
        return self._items[0] if self._items else None

    def __iter__(self) -> Any:
        return iter(self._items)


class _Result:
    def __init__(self, items: list[Any]) -> None:
        self._items = items

    def scalars(self) -> _Scalars:
        return _Scalars(self._items)


class _FakeSession:
    """username lower 查询按编译参数过滤;get 走 id 表;commit 计数。"""

    def __init__(self, users: list[Any]) -> None:
        self.users = users
        self.commits = 0

    async def get(self, model: Any, pk: Any) -> Any:
        for u in self.users:
            if u.id == pk:
                return u
        return None

    async def execute(self, stmt: Any) -> _Result:
        params = stmt.compile().params
        key = next(iter(params.values())) if params else None
        matched = [u for u in self.users
                   if key is not None and (u.username or "").lower() == str(key).lower()]
        return _Result(matched)

    async def commit(self) -> None:
        self.commits += 1

    async def __aenter__(self) -> _FakeSession:
        return self

    async def __aexit__(self, *exc: Any) -> bool:
        return False


class _SM:
    def __init__(self, session: _FakeSession) -> None:
        self._session = session

    def __call__(self) -> _FakeSession:
        return self._session


class FakeAuditService:
    def __init__(self, session: Any) -> None:
        self.writes: list[dict[str, Any]] = []

    async def write(self, **kw: Any) -> None:
        self.writes.append(kw)


def _mk_user(*, username: str | None, email: str | None,
             user_id: uuid.UUID | None = None) -> Any:
    from app.db.tables import User

    return User(id=user_id or uuid.uuid4(), username=username, name=username or "n",
                email=email)


def _patch_mark(monkeypatch: pytest.MonkeyPatch, session: _FakeSession) -> FakeAuditService:
    monkeypatch.setattr(mev, "get_sessionmaker", lambda: _SM(session))
    audit = FakeAuditService(session)
    monkeypatch.setattr(mev, "AuditService", lambda s: audit)
    return audit


async def test_mark_case_insensitive_confirm_passes(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str],
) -> None:
    """§9.5 口径:确认输入与库值 strip().lower() 完全一致即执行(大小写不敏感)。"""
    user = _mk_user(username="alice", email="Alice@Example.com")
    session = _FakeSession([user])
    audit = _patch_mark(monkeypatch, session)
    monkeypatch.setattr(mev, "_prompt", lambda msg: "  ALICE@example.COM ")

    code = await mev.mark_verified(username="alice", user_id=None,
                                   confirm_email=None, verified_by="ops-admin")

    out = capsys.readouterr().out
    assert code == 0
    assert user.email_verified_at is not None
    assert session.commits == 1
    assert len(audit.writes) == 1
    w = audit.writes[0]
    assert w["event_type"] == "email_verified"
    # mask_email 保留库值原大小写(生产所有写入路径已 lower,这里仅遗留混写场景);
    # 比较口径是 strip().lower() —— 大小写变体必须能匹配上
    assert w["details"] == {"source": "ops", "verified_by": "ops-admin",
                            "email_masked": "A***@Example.com"}
    assert w["actor_email_snapshot"] == "A***@Example.com"
    assert "A***@Example.com" in out and "Alice@Example.com" not in out


async def test_mark_wrong_confirm_aborts_without_write(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    user = _mk_user(username="alice", email="alice@example.com")
    session = _FakeSession([user])
    audit = _patch_mark(monkeypatch, session)
    monkeypatch.setattr(mev, "_prompt", lambda msg: "bob@example.com")

    code = await mev.mark_verified(username="alice", user_id=None,
                                   confirm_email=None, verified_by="ops")

    assert code == 2
    assert user.email_verified_at is None
    assert session.commits == 0
    assert audit.writes == []


async def test_mark_stdin_dash_confirmation(monkeypatch: pytest.MonkeyPatch) -> None:
    """`--confirm-email -` 从 stdin 读(防完整邮箱进 shell history)。"""
    user = _mk_user(username="alice", email="alice@example.com")
    session = _FakeSession([user])
    _patch_mark(monkeypatch, session)
    monkeypatch.setattr(mev, "_read_stdin_line", lambda: "alice@example.com\n")

    code = await mev.mark_verified(username="alice", user_id=None,
                                   confirm_email="-", verified_by="ops")

    assert code == 0
    assert user.email_verified_at is not None


async def test_mark_rejects_invalid_stored_email_with_hint(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str],
) -> None:
    """§9.5:存量地址过不了 strict_validate_email → 拒绝并提示先换绑。"""
    user = _mk_user(username="carol", email="carol@localhost")
    session = _FakeSession([user])
    audit = _patch_mark(monkeypatch, session)

    code = await mev.mark_verified(username="carol", user_id=None,
                                   confirm_email="carol@localhost", verified_by="ops")

    assert code == 2
    assert "换绑" in capsys.readouterr().err
    assert user.email_verified_at is None
    assert audit.writes == [], "非法格式不产生任何写入"


async def test_mark_no_email_rejected(monkeypatch: pytest.MonkeyPatch) -> None:
    user = _mk_user(username="dave", email=None)
    session = _FakeSession([user])
    _patch_mark(monkeypatch, session)

    code = await mev.mark_verified(username="dave", user_id=None,
                                   confirm_email="x@example.com", verified_by="ops")

    assert code == 2
    assert user.email_verified_at is None


async def test_mark_ambiguous_username_rejected(monkeypatch: pytest.MonkeyPatch) -> None:
    users = [_mk_user(username="eve", email="e1@example.com"),
             _mk_user(username="EVE", email="e2@example.com")]
    session = _FakeSession(users)
    _patch_mark(monkeypatch, session)

    code = await mev.mark_verified(username="eve", user_id=None,
                                   confirm_email="e1@example.com", verified_by="ops")

    assert code == 2, "lower(username) 多命中必须拒绝,不得猜"


async def test_mark_user_id_lookup(monkeypatch: pytest.MonkeyPatch) -> None:
    uid = uuid.uuid4()
    user = _mk_user(username=None, email="frank@example.com", user_id=uid)
    session = _FakeSession([user])
    _patch_mark(monkeypatch, session)

    code = await mev.mark_verified(username=None, user_id=uid,
                                   confirm_email="frank@example.com", verified_by="ops")

    assert code == 0
    assert user.email_verified_at is not None


def test_mark_username_and_user_id_mutually_exclusive() -> None:
    """argparse 互斥组:两者同给/都不给直接 SystemExit。"""
    with pytest.raises(SystemExit):
        mev.main(["--username", "a", "--user-id", str(uuid.uuid4()),
                  "--confirm-email", "x@example.com"])
    with pytest.raises(SystemExit):
        mev.main(["--confirm-email", "x@example.com"])
