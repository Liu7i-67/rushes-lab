"""回填脚本 backfill_ai.py — 契约测试(ai-tagging-slicing 方案 §8.7)。

需求依据:docs/qdev/2026-11-03-ai-tagging-slicing.md 测试功能点 12(backfill:
--force 真重置 done 也重置 / --reset-skipped 排除 asset_gone / 批大小)与方案
§8.7。全 monkeypatch 隔离(DB/arq pool/ai_jobs 服务函数),不依赖真实容器;
mock 风格沿 tests/test_backfill_script.py。

测试 ↔ 功能点12 映射:
  筛选口径(livp/图片/视频含 thumbnail_failed):test_fetch_annotate_sql_semantics /
  test_fetch_slice_sql_semantics_incl_thumbnail_failed
  --force 重置调用(含 done):test_decide_matrix / test_force_resets_done_rows
  asset_gone 排除:test_reset_skipped_excludes_asset_gone
  dry-run 不派发:test_dry_run_no_dispatch
  派发契约(job id 后缀/_expires/_queue_name):test_annotate_dispatch_new_rows /
  test_slice_dispatch_contract
  重派保鲜 touch:test_retry_dispatches_and_touches_done_skipped
  批间节奏(annotate 眠 / slice 不眠):test_annotate_sleeps_between_batches /
  test_slice_unbatched_no_sleep
  refresh-context 路径:test_refresh_context_full_rebuild / test_refresh_context_dry_run
"""
from __future__ import annotations

import sys
import uuid
from types import SimpleNamespace
from typing import Any

import pytest
from sqlalchemy.dialects import postgresql

import scripts.backfill_ai as bf
from app.settings import Settings


def mk_settings() -> Settings:
    return Settings(
        env="test", db_url="postgresql+asyncpg://u:p@localhost/db",
        redis_url="redis://localhost:6379/0",
        minio_endpoint_internal="http://minio:9000", minio_endpoint_public="http://localhost:9000",
        minio_access_key="k", minio_secret_key="s", openfga_api_url="http://openfga:8080",
        openfga_store_id="01TEST", web_app_base_url="http://localhost/ms-static/web/",
        session_jwt_secret="test-secret",
    )


def mk_row(*, filename: str = "a.jpg", content_type: str | None = "image/jpeg",
           tags: dict[str, Any] | None = None) -> SimpleNamespace:
    return SimpleNamespace(id=uuid.uuid4(), filename=filename, content_type=content_type,
                           tags=tags if tags is not None else {}, deleted_at=None)


class _ScalarRows:
    def __init__(self, rows: list[Any]) -> None:
        self._rows = rows

    def scalars(self) -> list[Any]:
        return list(self._rows)


class _CapDB:
    """fetch_* 的 db 替身:捕获 execute 语句(SQL 编译断言)并回放预置行。"""

    def __init__(self, rows: list[Any]) -> None:
        self._rows = rows
        self.stmts: list[Any] = []

    async def execute(self, stmt: Any, *a: Any, **kw: Any) -> _ScalarRows:
        self.stmts.append(stmt)
        return _ScalarRows(self._rows)


class _Sess:
    def __init__(self, db: Any) -> None:
        self._db = db

    async def __aenter__(self) -> Any:
        return self._db

    async def __aexit__(self, *exc: Any) -> bool:
        return False


class _SM:
    def __init__(self, db: Any) -> None:
        self._db = db

    def __call__(self) -> _Sess:
        return _Sess(self._db)


class FakePool:
    def __init__(self) -> None:
        self.jobs: list[tuple[str, tuple[Any, ...], dict[str, Any]]] = []

    async def enqueue_job(self, name: str, *args: Any, **kwargs: Any) -> Any:
        self.jobs.append((name, args, kwargs))
        return SimpleNamespace(name=name)

    async def aclose(self) -> None:
        return None


class Rec:
    """async 记录替身:记每次调用的 (args, kwargs),返回预设值。"""

    def __init__(self, ret: Any = True) -> None:
        self.calls: list[tuple[tuple[Any, ...], dict[str, Any]]] = []
        self._ret = ret

    async def __call__(self, *a: Any, **k: Any) -> Any:
        self.calls.append((a, k))
        return self._ret


def _compiled(stmt: Any) -> tuple[str, set[str]]:
    c = stmt.compile(dialect=postgresql.dialect())
    return " ".join(str(c).split()), {str(v) for v in c.params.values()}


async def _boom_pool(settings: Any) -> Any:
    raise AssertionError("此处不应创建 arq pool")


def patch_flow(monkeypatch: pytest.MonkeyPatch, *, rows: list[Any],
               statuses: dict[Any, Any], pool: FakePool | None = None) -> FakePool:
    """main() 派发路径统一打桩:sessionmaker/settings/扫描/状态/pool。"""
    pool = pool if pool is not None else FakePool()

    async def _rows(db: Any) -> list[Any]:
        return rows

    async def _statuses(sm: Any, ids: list[Any], kind: str, mv: str) -> dict[Any, Any]:
        want = set(ids)
        return {i: st for i, st in statuses.items() if i in want}

    monkeypatch.setattr(bf, "get_sessionmaker", lambda: _SM(_CapDB([])))
    monkeypatch.setattr(bf, "get_settings", mk_settings)
    monkeypatch.setattr(bf, "fetch_annotate_targets", _rows)
    monkeypatch.setattr(bf, "fetch_slice_targets", _rows)
    monkeypatch.setattr(bf, "fetch_job_statuses", _statuses)
    monkeypatch.setattr(bf, "create_arq_pool", lambda settings: _ret_pool(pool))
    return pool


async def _ret_pool(pool: FakePool) -> FakePool:
    return pool


# ─── 筛选口径(功能点12:livp/图片/视频含 thumbnail_failed)────────────────────
async def test_fetch_annotate_sql_semantics() -> None:
    """annotate:SQL 粗筛 image/% + IMAGE_EXTS 正则 + %.livp + thumbnail_key 非空
    (+ 未删);Python 终筛 is_image_asset/is_livp_asset —— octet-stream 盲区行
    (.jpg/.heic/.livp)命中,image/svg+xml 与 .ts 排除。"""
    db = _CapDB([])
    await bf.fetch_annotate_targets(db)
    sql, vals = _compiled(db.stmts[0])
    assert "deleted_at IS NULL" in sql
    assert "LIKE" in sql and "ILIKE" in sql and "~*" in sql
    assert {"image/%", "%.livp"} <= vals
    assert "->>" in sql and "thumbnail_key" in vals, "缩略图 tags 就绪前置(§8.7)"

    rows = [
        mk_row(filename="a.livp", content_type="application/octet-stream"),
        mk_row(filename="b.jpg", content_type="application/octet-stream"),
        mk_row(filename="c.heic", content_type="application/octet-stream"),
        mk_row(filename="logo.svg", content_type="image/svg+xml"),
        mk_row(filename="c.ts", content_type="application/octet-stream"),
    ]
    out = await bf.fetch_annotate_targets(_CapDB(rows))
    assert [r.filename for r in out] == ["a.livp", "b.jpg", "c.heic"]


async def test_fetch_slice_sql_semantics_incl_thumbnail_failed() -> None:
    """slice:video/% + VIDEO_EXTS 正则 + 未删,无任何 tags 前置条件(含
    thumbnail_failed —— 方案 §8.7 唯一补打通道);Python 终筛 is_video_asset,
    .livp(实为 zip)/.ts 排除。"""
    db = _CapDB([])
    await bf.fetch_slice_targets(db)
    sql, vals = _compiled(db.stmts[0])
    assert "deleted_at IS NULL" in sql and "LIKE" in sql and "~*" in sql
    assert "video/%" in vals
    assert "->>" not in sql, "slice 无 tags 条件(thumbnail_failed 也纳入)"

    rows = [
        mk_row(filename="v.mov", content_type="application/octet-stream",
               tags={"thumbnail_failed": "decode_failed"}),
        mk_row(filename="v2.mp4", content_type="video/mp4"),
        mk_row(filename="a.livp", content_type="application/octet-stream"),
        mk_row(filename="c.ts", content_type="application/octet-stream"),
    ]
    out = await bf.fetch_slice_targets(_CapDB(rows))
    assert [r.filename for r in out] == ["v.mov", "v2.mp4"], \
        "thumbnail_failed 视频行纳入;.livp/.ts 排除"


# ─── 动作裁决矩阵(--force 真重置 / asset_gone 排除)─────────────────────────
@pytest.mark.parametrize("st,force,reset,want", [
    (None, False, False, bf.DISPATCH_NEW),
    (None, True, False, bf.DISPATCH_RESET),
    (("done", None), False, False, bf.SKIP_DONE),
    (("done", None), True, False, bf.DISPATCH_RESET),
    (("skipped", "asset_gone"), False, True, bf.SKIP_ASSET_GONE),
    (("skipped", "asset_gone"), True, False, bf.DISPATCH_RESET),
    (("skipped", "poison"), False, False, bf.SKIP_SKIPPED),
    (("skipped", "poison"), False, True, bf.DISPATCH_RESET),
    (("pending", None), False, False, bf.DISPATCH_RETRY),
    (("failed", "ml_error"), False, False, bf.DISPATCH_RETRY),
    (("running", None), False, False, bf.DISPATCH_RETRY),
])
def test_decide_matrix(st: Any, force: bool, reset: bool, want: str) -> None:
    """裁决矩阵:--force 压倒一切(含 done/skipped/asset_gone 全复位);done 未
    --force 跳过;skipped 仅 --reset-skipped 复位且 asset_gone 恒排除;三中间态重派。"""
    assert bf.decide(st, force=force, reset_skipped=reset) == want


# ─── dry-run:不落行不派发不建 pool ───────────────────────────────────────────
async def test_dry_run_no_dispatch(monkeypatch: pytest.MonkeyPatch,
                                   capsys: pytest.CaptureFixture[str]) -> None:
    """--dry-run:只读状态做裁决统计,零 reset/ensure/touch、不建 pool、零派发;
    汇总打 would_enqueue。"""
    rows = [mk_row(), mk_row(filename="b.jpg", content_type="application/octet-stream")]
    patch_flow(monkeypatch, rows=rows, statuses={})
    ensure, reset, touch = Rec(), Rec(), Rec()
    monkeypatch.setattr(bf, "ensure_ai_job", ensure)
    monkeypatch.setattr(bf, "reset_ai_job", reset)
    monkeypatch.setattr(bf, "touch_ai_job", touch)
    monkeypatch.setattr(bf, "create_arq_pool", _boom_pool)
    monkeypatch.setattr(sys, "argv", ["backfill", "--kind", "annotate", "--dry-run"])

    await bf.main()

    assert ensure.calls == [] and reset.calls == [] and touch.calls == []
    out = capsys.readouterr().out
    assert "would_enqueue=2" in out and "dry-run" in out and "batch 1" in out


# ─── 派发契约:job 名 / job id 唯一后缀 / _expires / _queue_name ──────────────
async def test_annotate_dispatch_new_rows(monkeypatch: pytest.MonkeyPatch) -> None:
    """annotate 新行:ensure_ai_job(sm,id,kind,mv) 落行后派发;_job_id 形如
    ai:annotate:{id}@{v}:b{ts}(唯一时间戳后缀),_expires=1800,_queue_name="ai";
    非 --force 零 reset/touch。"""
    rows = [mk_row(filename="a.jpg"),
            mk_row(filename="b.livp", content_type="application/octet-stream")]
    pool = patch_flow(monkeypatch, rows=rows, statuses={})
    ensure, reset, touch = Rec(), Rec(), Rec()
    monkeypatch.setattr(bf, "ensure_ai_job", ensure)
    monkeypatch.setattr(bf, "reset_ai_job", reset)
    monkeypatch.setattr(bf, "touch_ai_job", touch)
    monkeypatch.setattr(sys, "argv", [
        "backfill", "--kind", "annotate", "--model-version", "v9", "--sleep-s", "0",
    ])

    await bf.main()

    assert len(pool.jobs) == 2 and len(ensure.calls) == 2
    assert reset.calls == [] and touch.calls == []
    by_id = {str(r.id): r for r in rows}
    for name, a, kw in pool.jobs:
        aid = a[0]
        assert name == "ai_annotate_asset" and aid == str(by_id[aid].id)
        assert kw["_job_id"].startswith(f"ai:annotate:{aid}@v9:b")
        assert kw["_job_id"].rsplit("b", 1)[1].isdigit(), "唯一时间戳后缀 :b{unix_ts}"
        assert kw["_expires"] == 1800 and kw["_queue_name"] == "ai"
    for call_args, _ in ensure.calls:
        sm_, aid, kind, mv = call_args
        assert kind == "annotate" and mv == "v9" and sm_ is not None


async def test_slice_dispatch_contract(monkeypatch: pytest.MonkeyPatch) -> None:
    """slice 契约:job 名 ai_slice_video、_expires=86400(§8.1)、_queue_name="ai"。"""
    rows = [mk_row(filename="v.mp4", content_type="video/mp4")]
    pool = patch_flow(monkeypatch, rows=rows, statuses={})
    monkeypatch.setattr(bf, "ensure_ai_job", Rec())
    monkeypatch.setattr(sys, "argv", ["backfill", "--kind", "slice"])

    await bf.main()

    name, a, kw = pool.jobs[0]
    assert name == "ai_slice_video"
    assert kw["_job_id"].startswith(f"ai:slice:{a[0]}@") and ":b" in kw["_job_id"]
    assert kw["_expires"] == 86400 and kw["_queue_name"] == "ai"


# ─── --force:done 行也真重置后派发(§8.7 / §15-3 幂等验收)────────────────────
async def test_force_resets_done_rows(monkeypatch: pytest.MonkeyPatch) -> None:
    """--force:done/failed 行均 reset_ai_job(置 pending/attempts=0)+ ensure + 派发。"""
    rows = [mk_row(), mk_row(filename="b.jpg")]
    pool = patch_flow(monkeypatch, rows=rows,
                      statuses={rows[0].id: ("done", None),
                                rows[1].id: ("failed", "ml_error")})
    ensure, reset = Rec(), Rec()
    monkeypatch.setattr(bf, "ensure_ai_job", ensure)
    monkeypatch.setattr(bf, "reset_ai_job", reset)
    monkeypatch.setattr(sys, "argv", [
        "backfill", "--kind", "annotate", "--force", "--model-version", "v9", "--sleep-s", "0",
    ])

    await bf.main()

    assert {c[0][1] for c in reset.calls} == {r.id for r in rows}, "done/failed 全真重置"
    for _, k in reset.calls:
        assert k == {}, "reset_ai_job(sm, asset_id, kind, model_version) 位置传参"
    assert len(ensure.calls) == 2 and len(pool.jobs) == 2


# ─── --reset-skipped:复位 skipped,asset_gone 恒排除 ─────────────────────────
async def test_reset_skipped_excludes_asset_gone(monkeypatch: pytest.MonkeyPatch,
                                                 capsys: pytest.CaptureFixture[str]) -> None:
    """--reset-skipped:poison 行 reset+派发;asset_gone 行排除(简化:恢复场景走
    restore 钩子,不逐一判资产存活性);无行资产正常补派。"""
    rows = [mk_row(), mk_row(filename="b.jpg"), mk_row(filename="c.jpg")]
    pool = patch_flow(monkeypatch, rows=rows,
                      statuses={rows[0].id: ("skipped", "poison"),
                                rows[1].id: ("skipped", "asset_gone")})
    ensure, reset = Rec(), Rec()
    monkeypatch.setattr(bf, "ensure_ai_job", ensure)
    monkeypatch.setattr(bf, "reset_ai_job", reset)
    monkeypatch.setattr(sys, "argv", [
        "backfill", "--kind", "annotate", "--reset-skipped", "--sleep-s", "0",
    ])

    await bf.main()

    assert {c[0][1] for c in reset.calls} == {rows[0].id}, "只复位 poison,不碰 asset_gone"
    assert len(pool.jobs) == 2, "poison + 无行新资产派发;asset_gone 不派发"
    out = capsys.readouterr().out
    assert "skip_asset_gone=1" in out and "enqueued=2" in out


# ─── 重派保鲜:pending/failed/running 重派 + touch;done 跳过 ──────────────────
async def test_retry_dispatches_and_touches_done_skipped(
        monkeypatch: pytest.MonkeyPatch,
        capsys: pytest.CaptureFixture[str]) -> None:
    """非 --force:pending/failed/running 行重派且逐行 touch updated_at(防 sweeper
    臂③ 陈旧重派,§8.5);done 行跳过(行认领见 done 即 return,派了也白派);
    已有行不重复 ensure。"""
    rows = [mk_row(), mk_row(filename="b.jpg"), mk_row(filename="c.jpg"),
            mk_row(filename="d.jpg")]
    pool = patch_flow(monkeypatch, rows=rows,
                      statuses={rows[0].id: ("pending", None),
                                rows[1].id: ("failed", "minio_transient"),
                                rows[2].id: ("running", None),
                                rows[3].id: ("done", None)})
    ensure, touch = Rec(), Rec()
    monkeypatch.setattr(bf, "ensure_ai_job", ensure)
    monkeypatch.setattr(bf, "touch_ai_job", touch)
    monkeypatch.setattr(sys, "argv", ["backfill", "--kind", "annotate", "--sleep-s", "0"])

    await bf.main()

    assert len(pool.jobs) == 3 and {c[0][1] for c in touch.calls} == {
        rows[0].id, rows[1].id, rows[2].id}, "三中间态重派 + 保鲜 touch"
    assert ensure.calls == [], "已有行不重复 ensure(仅新行补插)"
    out = capsys.readouterr().out
    assert "skip_done=1" in out and "enqueued=3" in out


# ─── 批间节奏:annotate 眠 / slice 不眠(slice 不限批)──────────────────────────
async def _run_capture_sleeps(monkeypatch: pytest.MonkeyPatch, kind: str,
                              n_rows: int) -> list[Any]:
    rows = [mk_row(filename=f"v{i}.mp4" if kind == "slice" else f"a{i}.jpg",
                   content_type="video/mp4" if kind == "slice" else "image/jpeg")
            for i in range(n_rows)]
    patch_flow(monkeypatch, rows=rows, statuses={})
    monkeypatch.setattr(bf, "ensure_ai_job", Rec())
    sleeps: list[Any] = []

    async def _fake_sleep(s: Any) -> None:
        sleeps.append(s)

    monkeypatch.setattr(bf.asyncio, "sleep", _fake_sleep)
    monkeypatch.setattr(sys, "argv", [
        "backfill", "--kind", kind, "--batch-size", "2", "--sleep-s", "3",
    ])
    await bf.main()
    return sleeps


async def test_annotate_sleeps_between_batches(monkeypatch: pytest.MonkeyPatch,
                                               capsys: pytest.CaptureFixture[str]) -> None:
    """annotate 批间休眠(--sleep-s):3 行批 2 → 两批,批间睡一次 3s;逐批打印进度。"""
    sleeps = await _run_capture_sleeps(monkeypatch, "annotate", 3)
    assert sleeps == [3], "仅批间一睡(末批后不再睡)"
    out = capsys.readouterr().out
    assert "batch 1" in out and "batch 2" in out, "逐批打印 scanned/enqueued/skipped"


async def test_slice_unbatched_no_sleep(monkeypatch: pytest.MonkeyPatch) -> None:
    """slice 不限批(§8.7:闸满自延迟 + sweeper touch 保鲜,不重复堆积):
    跨批也不休眠,--sleep-s 被忽略。"""
    sleeps = await _run_capture_sleeps(monkeypatch, "slice", 3)
    assert sleeps == [], "slice 批间不睡"


# ─── --refresh-context:不走派发,直接全量重拼(§8.6)──────────────────────────
async def test_refresh_context_full_rebuild(monkeypatch: pytest.MonkeyPatch,
                                            capsys: pytest.CaptureFixture[str]) -> None:
    """--refresh-context:取全部未软删 asset id → refresh_context(sm, asset_ids=…,
    batch_size=…);不建 pool 不派发;打印 updated 行数。"""
    ids = [uuid.uuid4(), uuid.uuid4(), uuid.uuid4()]
    sm = _SM(_CapDB([]))
    monkeypatch.setattr(bf, "get_sessionmaker", lambda: sm)
    monkeypatch.setattr(bf, "get_settings", mk_settings)

    async def _ids(db: Any) -> list[uuid.UUID]:
        return ids

    refresh = Rec(ret=5)
    monkeypatch.setattr(bf, "fetch_all_asset_ids", _ids)
    monkeypatch.setattr(bf, "refresh_context", refresh)
    monkeypatch.setattr(bf, "create_arq_pool", _boom_pool)
    monkeypatch.setattr(sys, "argv", [
        "backfill", "--kind", "annotate", "--refresh-context", "--batch-size", "7",
    ])

    await bf.main()

    assert refresh.calls == [((sm,), {"asset_ids": ids, "batch_size": 7})]
    out = capsys.readouterr().out
    assert "updated=5" in out and "scanned=3" in out


async def test_refresh_context_dry_run_skips_rebuild(
        monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]) -> None:
    """--refresh-context --dry-run:只报对账范围,不调 refresh_context。"""
    monkeypatch.setattr(bf, "get_sessionmaker", lambda: _SM(_CapDB([])))
    monkeypatch.setattr(bf, "get_settings", mk_settings)

    async def _ids(db: Any) -> list[uuid.UUID]:
        return [uuid.uuid4()]

    monkeypatch.setattr(bf, "fetch_all_asset_ids", _ids)
    monkeypatch.setattr(bf, "refresh_context", _boom_refresh)
    monkeypatch.setattr(sys, "argv", [
        "backfill", "--kind", "slice", "--refresh-context", "--dry-run",
    ])

    await bf.main()

    assert "dry-run 完成" in capsys.readouterr().out


async def _boom_refresh(*a: Any, **k: Any) -> int:
    raise AssertionError("dry-run 下不应重拼上下文")
