"""批量绑定脚本 bind_user_phones.py 契约测试(方案 §10.1 B5 条目,逐条)。

范式:tests/test_backfill_script.py(monkeypatch 隔离 + 固定 argv + 桩替身)叠加
tests/test_local_auth.py 的 aiosqlite 内存库 —— users 表真建(唯一约束/占用查询
真跑),审计侧桩 FakeAuditService(audit.write 是 pg_insert PG 方言,SQLite 编译
失败;方案 §10.1 钉死审计真跑只在容器内,本地单测断言脚本的调用形状)。

测试 ↔ §10.1 B5 映射:D5 归一化折叠冲突名单 / 已有 phone 跳过 / 候选号已被他人
占用进冲突名单跳过 / --csv 双给冲突 / --csv 二跑对占用冲突拒绝(不覆盖唯一约束)
/ 幂等重跑零变更 / 审计 details(source=backfill,masked 前3+****+后4)/
dry-run 不写库(SQLite 快照前后对比)+ --apply 无 --yes 不写库。
"""

from __future__ import annotations

import sys
from types import SimpleNamespace
from typing import Any, ClassVar

import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

import scripts.bind_user_phones as bp
from app.db.tables import User


# ─── 基建:内存 SQLite(真 User 表)+ 审计桩 + argv/会话工厂注入 ─────────────
@pytest.fixture
async def factory():
    """内存 SQLite,只建 users 表(唯一约束 uq_users_phone 随表生效)。"""
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(User.metadata.create_all, tables=[User.__table__])
    sm = async_sessionmaker(engine, expire_on_commit=False)
    yield sm
    await engine.dispose()


class FakeAuditService:
    """AuditService 替身:只记录 (event_type, details);真实 PG 方言不进 SQLite。"""

    records: ClassVar[list[tuple[str, dict[str, Any]]]] = []

    def __init__(self, session: Any) -> None:
        pass

    async def write(
        self, *, event_type: str, details: dict[str, Any] | None = None, **_kw: Any
    ) -> SimpleNamespace:
        FakeAuditService.records.append((event_type, dict(details or {})))
        return SimpleNamespace(event_type=event_type)


@pytest.fixture
def audit_records(monkeypatch: pytest.MonkeyPatch) -> list[tuple[str, dict[str, Any]]]:
    FakeAuditService.records = []
    monkeypatch.setattr(bp, "AuditService", FakeAuditService)
    return FakeAuditService.records


def inject(monkeypatch: pytest.MonkeyPatch, factory: Any) -> None:
    """main() 外部依赖统一打桩:sessionmaker 指向内存库;argv 由各用例自设。"""
    monkeypatch.setattr(bp, "get_sessionmaker", lambda: factory)


async def seed(factory: Any, *users: User) -> None:
    async with factory() as db:
        db.add_all(users)
        await db.commit()


async def phones(factory: Any) -> dict[str, str | None]:
    """全量 users.phone 快照(dry-run 不写库 / 幂等重跑零变更的对比基线)。"""
    async with factory() as db:
        res = await db.execute(select(User))
        return {str(u.id): u.phone for u in res.scalars()}


def mk(name: str, username: str | None = None, phone: str | None = None, email: str | None = None) -> User:
    return User(name=name, username=username, phone=phone, email=email)


async def run(monkeypatch: pytest.MonkeyPatch, factory: Any, *argv: str) -> None:
    monkeypatch.setattr(sys, "argv", ["bind_user_phones", *argv])
    await bp.main()


def csv_file(tmp_path: Any, *lines: str) -> str:
    path = tmp_path / "pairs.csv"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return str(path)


# ─── D5 归一化折叠冲突名单(dry-run 即暴露,不写库)──────────────────────────
async def test_dry_run_folding_conflict_listed_and_no_write(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    audit_records: list[Any],
    capsys: pytest.CaptureFixture[str],
) -> None:
    """13800138000 与 138-0013-8000 归一化折叠为同号 → 全部候选进冲突名单;
    非 phone 形态 username 不自动绑;dry-run 前后快照一致、零审计。"""
    u1 = mk("张三", username="13800138000")
    u2 = mk("李四", username="138-0013-8000")
    u3 = mk("王五", username="alice")
    await seed(factory, u1, u2, u3)
    before = await phones(factory)
    inject(monkeypatch, factory)

    await run(monkeypatch, factory)  # 默认 dry-run

    out = capsys.readouterr().out
    assert "13800138000" in out and "138-0013-8000" in out
    assert out.count("conflict") >= 2 and "归一化折叠" in out and "冲突名单" in out
    assert "username 非手机号形态" in out, "非 phone 形态 username 走 skip"
    assert "dry-run 完成" in out
    assert await phones(factory) == before, "dry-run 不写库"
    assert audit_records == [], "dry-run 零审计"


# ─── 已有 phone 跳过(幂等口径)───────────────────────────────────────────────
async def test_existing_phone_user_skipped(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    audit_records: list[Any],
    capsys: pytest.CaptureFixture[str],
) -> None:
    """已有 phone 的用户(即便 username 也是手机号形态)→ skip;候选者列出 bind。"""
    bound = mk("已绑", username="13800001234", phone="13800001234")
    cand = mk("候选", username="13900001234")
    await seed(factory, bound, cand)
    inject(monkeypatch, factory)

    await run(monkeypatch, factory)

    out = capsys.readouterr().out
    assert "已有手机号 138****1234" in out and "幂等跳过" in out
    assert "13900001234" in out and "bind" in out
    assert audit_records == []


# ─── 候选号已被他人占用 → 冲突名单跳过 ────────────────────────────────────────
async def test_candidate_phone_taken_by_other_user_conflict(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    audit_records: list[Any],
    capsys: pytest.CaptureFixture[str],
) -> None:
    """username 候选号已被其他用户持有 → 进冲突名单跳过,绝不写库。"""
    holder = mk("占用者", username="alice", phone="13811112222")
    cand = mk("候选", username="13811112222")
    await seed(factory, holder, cand)
    before = await phones(factory)
    inject(monkeypatch, factory)

    await run(monkeypatch, factory)

    out = capsys.readouterr().out
    assert "手机号已被其他用户占用" in out and "冲突名单" in out
    assert await phones(factory) == before and audit_records == []


# ─── --csv 双给冲突(同用户重复 / 同号指多用户)───────────────────────────────
async def test_csv_double_assignment_conflict(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    audit_records: list[Any],
    capsys: pytest.CaptureFixture[str],
    tmp_path: Any,
) -> None:
    """同一用户重复出现与同一 phone 指给多个用户,双双进冲突名单,未写库。"""
    alice, bob, carol = (
        mk("Alice", username="alice"),
        mk("Bob", username="bob"),
        mk("Carol", username="carol"),
    )
    await seed(factory, alice, bob, carol)
    path = csv_file(
        tmp_path,
        "alice,13800002222",
        "alice,13800003333",  # 同一用户重复出现
        "bob,13800004444",
        "carol,13800004444",
    )  # 同一 phone 指给多个用户
    before = await phones(factory)
    inject(monkeypatch, factory)

    await run(monkeypatch, factory, "--csv", path)

    out = capsys.readouterr().out
    assert "同一用户被指定 2 次" in out
    assert "该手机号同时指给多个用户" in out
    assert "冲突名单" in out
    assert await phones(factory) == before and audit_records == []


# ─── --csv 二跑对占用冲突拒绝(不覆盖唯一约束)────────────────────────────────
async def test_csv_second_run_refuses_occupation_no_overwrite(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    audit_records: list[Any],
    capsys: pytest.CaptureFixture[str],
    tmp_path: Any,
) -> None:
    """第一跑 csv 绑定成功;第二跑把同号指给另一用户 → 占用冲突拒绝,
    不覆盖唯一约束(被占用户 phone 保持 NULL,原持号不变,零新审计)。"""
    alice, bob = mk("Alice", username="alice"), mk("Bob", username="bob")
    await seed(factory, alice, bob)
    path1 = csv_file(tmp_path, "alice,13800005555")
    inject(monkeypatch, factory)

    await run(monkeypatch, factory, "--apply", "--yes", "--csv", path1)
    assert "实跑完成:绑定 1 条" in capsys.readouterr().out
    assert len(audit_records) == 1

    path2 = csv_file(tmp_path, "bob,13800005555")
    await run(monkeypatch, factory, "--apply", "--yes", "--csv", path2)

    out = capsys.readouterr().out
    assert "手机号已被其他用户占用" in out, "二跑对占用冲突同样拒绝并输出名单"
    after = await phones(factory)
    assert after[str(bob.id)] is None, "绝不覆盖唯一约束"
    assert after[str(alice.id)] == "13800005555", "原绑定原样保留"
    assert len(audit_records) == 1, "拒绝行零写库零审计"


# ─── 幂等重跑零变更 ──────────────────────────────────────────────────────────
async def test_apply_idempotent_rerun_zero_changes(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    audit_records: list[Any],
    capsys: pytest.CaptureFixture[str],
) -> None:
    """--apply --yes 实跑绑定;原样重跑:全部 skip、零新绑定、零新审计、快照不变。"""
    u1, u2 = mk("甲", username="13600001111"), mk("乙", username="13600002222")
    await seed(factory, u1, u2)
    inject(monkeypatch, factory)

    await run(monkeypatch, factory, "--apply", "--yes")
    assert "实跑完成:绑定 2 条" in capsys.readouterr().out
    first_snapshot = await phones(factory)
    assert len(audit_records) == 2

    await run(monkeypatch, factory, "--apply", "--yes")
    out = capsys.readouterr().out
    assert "bind 0 / skip 2 / conflict 0" in out, "重跑全部幂等 skip"
    assert await phones(factory) == first_snapshot, "重跑零变更"
    assert len(audit_records) == 2, "重跑零新审计"


# ─── 审计 phone_bound details 形状(cli/backfill/脱敏)────────────────────────
async def test_audit_details_cli_backfill_masked(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    audit_records: list[Any],
) -> None:
    """逐条审计 phone_bound:details actor=cli / source=backfill /
    old_masked=None(首次绑定)/ new_masked=前3+****+后4。"""
    u = mk("丙", username="13899990000")
    await seed(factory, u)
    inject(monkeypatch, factory)

    await run(monkeypatch, factory, "--apply", "--yes")

    assert len(audit_records) == 1
    event_type, details = audit_records[0]
    assert event_type == "phone_bound"
    assert details["actor"] == "cli" and details["source"] == "backfill"
    assert details["old_masked"] is None
    assert details["new_masked"] == "138****0000"


# ─── dry-run / --apply 无 --yes 都不写库 ─────────────────────────────────────
async def test_apply_without_yes_is_refused(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    audit_records: list[Any],
    capsys: pytest.CaptureFixture[str],
) -> None:
    """--apply 未显式搭配 --yes → 只打印提示退出,零写库零审计。"""
    u = mk("丁", username="13700001111")
    await seed(factory, u)
    before = await phones(factory)
    inject(monkeypatch, factory)

    await run(monkeypatch, factory, "--apply")

    out = capsys.readouterr().out
    assert "--yes" in out and "未写库" in out
    assert await phones(factory) == before and audit_records == []


# ─── --csv:phone 归一化写入 + identifier 四形态匹配 ─────────────────────────
async def test_csv_phone_normalized_and_identifier_forms(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    audit_records: list[Any],
    capsys: pytest.CaptureFixture[str],
    tmp_path: Any,
) -> None:
    """phone 带连字符/前缀同样走 D5 归一化后写入;identifier 支持
    username/email/name/UUID(set_password 同口径)。"""
    by_name = mk("显示名九", username=None, email=None)
    by_email = mk("Em", username=None, email="em@x.com")
    by_username = mk("U", username="plainuser")
    await seed(factory, by_name, by_email, by_username)
    path = csv_file(
        tmp_path,
        "显示名九,+86 138-0013-8000",  # name + 归一化(去+86/连字符/空格)
        "em@x.com,13900001111",  # email
        "plainuser,139 1111 2222",  # username
        f"{by_name.id},13866667777",
    )  # UUID → 与 name 行双给同一用户
    inject(monkeypatch, factory)

    await run(monkeypatch, factory, "--apply", "--yes", "--csv", path)

    out = capsys.readouterr().out
    assert "同一用户被指定 2 次" in out, "UUID 与 name 命中同一用户 = 双给冲突"
    after = await phones(factory)
    assert after[str(by_email.id)] == "13900001111"
    assert after[str(by_username.id)] == "13911112222", "空格分隔同样归一化"
    assert after[str(by_name.id)] is None, "双给冲突行不写库"
    assert len(audit_records) == 2
    assert "13866667777" in out, "冲突名单展示该用户被指定的末次 pair 号"


# ─── --csv identifier 解析失败按冲突计,不中断整批 ────────────────────────────
async def test_csv_unresolved_identifier_counted_as_conflict(
    monkeypatch: pytest.MonkeyPatch,
    factory: Any,
    audit_records: list[Any],
    capsys: pytest.CaptureFixture[str],
    tmp_path: Any,
) -> None:
    """identifier 找不到用户 / phone 格式非法 → 进解析失败名单(按冲突计),
    其余行照常绑定。"""
    ok = mk("正常", username="plainuser")
    await seed(factory, ok)
    path = csv_file(
        tmp_path,
        "ghost,13800001111",  # 找不到用户
        "plainuser,not-a-phone",  # phone 归一化失败
        "plainuser,13600003333",
    )
    inject(monkeypatch, factory)

    await run(monkeypatch, factory, "--apply", "--yes", "--csv", path)

    out = capsys.readouterr().out
    assert "--csv 解析失败" in out and "ghost" in out and "not-a-phone" in out
    assert (await phones(factory))[str(ok.id)] == "13600003333", "合法行照常绑定"
    assert len(audit_records) == 1
