"""回补脚本 backfill_thumbnails.py(重写版)— 契约测试。

需求依据:docs/qdev/2026-10-27-thumb-variant-video-cover.md §3.8 与「测试功能点」
10。全 monkeypatch 隔离(DB/redis/arq pool/时钟),不依赖真实容器;窗口语义用
固定钟(UTC+8 固定偏移)验证,锁语义用内存 redis 替身。

实现问题注:_EXT_RE 曾把带点扩展名拼成通配符致正常文件名永不命中(SQL 侧捞不出
octet-stream 盲区行),BE4 已修复(lstrip('.') + re.escape),扩展名正则用例为常态断言。

测试 ↔ 功能点10 映射:三模式筛选 SQL(test_fetch_missing_sql_and_python_filter /
test_fetch_missing_covers_sql_semantics / test_missing_covers_ext_regex_semantics /
test_fetch_missing_covers_python_classify / test_fetch_derive_small_sql_semantics /
test_classify_covers_livp_priority);dry-run/--apply(test_dry_run_default_no_
dispatch / test_apply_dispatches_job_id_per_family / test_apply_derive_small_mode_
job_name / test_oversized_image_reported_not_dispatched);--window(test_window_
utc8_boundary_and_cross_day / test_window_startup_gate_blocks / test_window_per_
batch_recheck_stops);锁(test_lock_held_by_other_exits_without_delete /
test_lock_release_compare_and_del)。
"""
from __future__ import annotations

import logging
import re
import sys
import uuid
from datetime import datetime, timedelta
from types import SimpleNamespace
from typing import Any

import pytest
from sqlalchemy.dialects import postgresql

import scripts.backfill_thumbnails as bf
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
           size_bytes: int = 1024, tags: dict[str, Any] | None = None) -> SimpleNamespace:
    return SimpleNamespace(id=uuid.uuid4(), filename=filename, content_type=content_type,
                           size_bytes=size_bytes, tags=tags if tags is not None else {},
                           deleted_at=None)


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


class FakeRedis:
    """内存 redis 替身:脚本用到的 set(nx/ex)/get/delete/expire/aclose。"""

    def __init__(self, held_by: str | None = None) -> None:
        self.store: dict[str, str] = {}
        self.deletes: list[str] = []
        self.set_calls: list[dict[str, Any]] = []
        self.get_returns: str | None = None   # 非 None 时 get 恒返回它(compare-and-del 用)
        if held_by is not None:
            self.store[bf.LOCK_KEY] = held_by

    async def set(self, key: str, value: str, nx: bool = False, ex: int | None = None) -> bool:
        self.set_calls.append({"key": key, "value": value, "nx": nx, "ex": ex})
        if nx and key in self.store:
            return False
        self.store[key] = value
        return True

    async def get(self, key: str) -> str | None:
        return self.get_returns if self.get_returns is not None else self.store.get(key)

    async def delete(self, key: str) -> None:
        self.deletes.append(key)
        self.store.pop(key, None)

    async def expire(self, key: str, ttl: int) -> None:
        return None

    async def aclose(self) -> None:
        return None


class FakePool:
    def __init__(self) -> None:
        self.jobs: list[tuple[str, tuple[Any, ...], dict[str, Any]]] = []

    async def enqueue_job(self, name: str, *args: Any, **kwargs: Any) -> Any:
        self.jobs.append((name, args, kwargs))
        return SimpleNamespace(name=name)

    async def aclose(self) -> None:
        return None


def _boom(*a: Any, **k: Any) -> Any:
    raise AssertionError("此处不应触达真实依赖(dry-run / 越窗 / 锁互斥分支)")


async def _boom_pool(settings: Any) -> Any:
    raise AssertionError("此处不应创建 arq pool")


async def _ret_pool(pool: FakePool) -> FakePool:
    return pool


def make_fake_clock(monkeypatch: pytest.MonkeyPatch, times: list[datetime]) -> None:
    """把 bf.datetime 替换成按序返回 times 的假钟(耗尽后停在最后一个)。"""
    counter = {"i": 0}

    class _FakeDT(datetime):
        @classmethod
        def now(cls, tz: Any = None) -> datetime:
            t = times[min(counter["i"], len(times) - 1)]
            counter["i"] += 1
            return t if tz is None else t.astimezone(tz)

    monkeypatch.setattr(bf, "datetime", _FakeDT)


def patch_run_env(monkeypatch: pytest.MonkeyPatch, *, db: _CapDB, redis: FakeRedis,
                  pool: FakePool) -> FakePool:
    """main() 外部依赖统一打桩:sessionmaker / settings / redis / arq pool。"""
    monkeypatch.setattr(bf, "get_sessionmaker", lambda: _SM(db))
    monkeypatch.setattr(bf, "get_settings", mk_settings)
    monkeypatch.setattr(bf, "redis_asyncio", SimpleNamespace(from_url=lambda *a, **k: redis))
    monkeypatch.setattr(bf, "create_arq_pool", lambda settings: _ret_pool(pool))
    return pool


def _compiled(stmt: Any) -> tuple[str, set[str]]:
    c = stmt.compile(dialect=postgresql.dialect())
    return " ".join(str(c).split()), {str(v) for v in c.params.values()}


# ─── 三模式筛选 SQL 语义(功能点10)───────────────────────────────────────────
async def test_fetch_missing_sql_and_python_filter() -> None:
    """missing(默认,兼容旧行为):image/% | video/% | %.livp 且未删;Python 侧
    thumbnail_key falsy(含空串)即视为缺,--force 全量纳入。"""
    db = _CapDB([])
    await bf.fetch_missing(db, force=False)
    sql, vals = _compiled(db.stmts[0])
    assert "deleted_at IS NULL" in sql and "LIKE" in sql and "ILIKE" in sql
    assert {"image/%", "video/%", "%.livp"} <= vals

    with_key = mk_row(tags={"thumbnail_key": "thumbnails/x.jpg"})
    no_key, empty_key = mk_row(tags={}), mk_row(tags={"thumbnail_key": ""})
    assert await bf.fetch_missing(_CapDB([with_key, no_key, empty_key]),
                                  force=False) == [no_key, empty_key]
    assert await bf.fetch_missing(_CapDB([with_key]), force=True) == [with_key]


async def test_fetch_missing_covers_sql_semantics() -> None:
    """missing-covers:video/% + image/%(!= image/svg+xml)+ %.livp + 扩展名正则
    下推;tags 无 key/skipped,failed 默认排除、--include-failed 纳入。"""
    db = _CapDB([])
    await bf.fetch_missing_covers(db, include_failed=False)
    sql, vals = _compiled(db.stmts[0])
    assert "deleted_at IS NULL" in sql
    assert "LIKE" in sql and "ILIKE" in sql and "~*" in sql
    assert {"%.livp", "image/svg+xml"} <= vals
    assert sql.count("->>") == 3, "key/skipped/failed 三段 astext 条件"
    assert {"thumbnail_key", "thumbnail_skipped", "thumbnail_failed"} <= vals

    db2 = _CapDB([])
    await bf.fetch_missing_covers(db2, include_failed=True)
    sql2, vals2 = _compiled(db2.stmts[0])
    assert sql2.count("->>") == 2 and "thumbnail_failed" not in vals2


@pytest.mark.parametrize("name,want", [
    ("clip.mov", True), ("IMG_1.heic", True), ("v.webm", True),
    ("logo.svg", False), ("clip.ts", False), ("a.txt", False),
])
def test_missing_covers_ext_regex_semantics(name: str, want: bool) -> None:
    """扩展名兜底正则语义:应命中 VIDEO_EXTS/IMAGE_EXTS 清单、排除 .ts/.svg。"""
    assert (re.search(bf._EXT_RE, name) is not None) == want, f"扩展名正则 {name}"


async def test_fetch_missing_covers_python_classify() -> None:
    """Python 侧 classify_covers 过滤:octet-stream 盲区行(.mov/.heic)与 .livp
    命中;.svg(image/svg+xml)/.ts/.txt 排除。"""
    rows = [
        mk_row(filename="clip.mov", content_type="application/octet-stream"),
        mk_row(filename="IMG_1.heic", content_type="application/octet-stream"),
        mk_row(filename="a.livp", content_type="application/octet-stream"),
        mk_row(filename="logo.svg", content_type="image/svg+xml"),
        mk_row(filename="logo.svg", content_type="application/octet-stream"),
        mk_row(filename="clip.ts", content_type="application/octet-stream"),
        mk_row(filename="a.txt", content_type="text/plain"),
    ]
    out = await bf.fetch_missing_covers(_CapDB(rows), include_failed=False)
    assert [r.filename for r in out] == ["clip.mov", "IMG_1.heic", "a.livp"]


async def test_fetch_derive_small_sql_semantics() -> None:
    """derive-small:deleted_at IS NULL + thumbnail_key IS NOT NULL +
    thumbnail_small_key IS NULL(有 1024 缺 small)。"""
    db = _CapDB([])
    await bf.fetch_derive_small(db)
    sql, vals = _compiled(db.stmts[0])
    assert "deleted_at IS NULL" in sql and "IS NOT NULL" in sql and "IS NULL" in sql
    assert sql.count("->>") == 2 and {"thumbnail_key", "thumbnail_small_key"} <= vals


def test_classify_covers_livp_priority() -> None:
    """livp 优先级最高(§3.5 同序);JOBS 族名 → worker job 名契约。"""
    assert bf.classify_covers(mk_row(filename="a.livp", content_type="video/mp4")) == "livp"
    assert bf.classify_covers(mk_row(filename="b.mov", content_type="application/octet-stream")) == "video"
    assert bf.classify_covers(mk_row(filename="c.heic", content_type=None)) == "image"
    assert bf.classify_covers(mk_row(filename="d.ts", content_type="application/octet-stream")) is None
    assert bf.JOBS == {"video": "generate_video_thumbnail", "image": "generate_thumbnail",
                       "livp": "generate_livp_thumbnail", "derive-small": "derive_small_thumbnail"}


# ─── dry-run / --apply 派发 ──────────────────────────────────────────────────
async def test_dry_run_default_no_dispatch(monkeypatch: pytest.MonkeyPatch,
                                           capsys: pytest.CaptureFixture[str]) -> None:
    """默认 dry-run:只打印命中报告,不建 redis / 不建 arq pool、零派发。"""
    rows = [mk_row(filename="clip.mov", content_type="application/octet-stream")]
    monkeypatch.setattr(bf, "get_sessionmaker", lambda: _SM(_CapDB(rows)))
    monkeypatch.setattr(bf, "get_settings", mk_settings)
    monkeypatch.setattr(bf, "redis_asyncio", SimpleNamespace(from_url=_boom))
    monkeypatch.setattr(bf, "create_arq_pool", _boom_pool)
    monkeypatch.setattr(sys, "argv", ["backfill", "--mode", "missing-covers"])

    await bf.main()

    out = capsys.readouterr().out
    assert "命中 1 条" in out and "video: 1" in out and "dry-run 完成" in out


async def test_apply_dispatches_job_id_per_family(monkeypatch: pytest.MonkeyPatch,
                                                  caplog: pytest.LogCaptureFixture) -> None:
    """--apply --yes:按族派发(video/image/livp 各自 job 名),_job_id=
    thumbbf:{mode}:{id} + _expires=3600 在途去重;结束 compare-and-del 释放锁。"""
    rows = [
        mk_row(filename="clip.mov", content_type="application/octet-stream"),
        mk_row(filename="IMG_1.heic", content_type="application/octet-stream"),
        mk_row(filename="a.livp", content_type="application/octet-stream"),
    ]
    redis, pool = FakeRedis(), FakePool()
    patch_run_env(monkeypatch, db=_CapDB(rows), redis=redis, pool=pool)
    monkeypatch.setattr(sys, "argv", [
        "backfill", "--mode", "missing-covers", "--apply", "--yes", "--sleep", "0",
    ])
    caplog.set_level(logging.INFO)   # bf 的 basicConfig 在 pytest 下是 no-op,显式放行 INFO

    await bf.main()

    by_id = {str(r.id): r for r in rows}
    assert len(pool.jobs) == 3
    for name, args, kwargs in pool.jobs:
        assert name == {"clip.mov": "generate_video_thumbnail",
                        "IMG_1.heic": "generate_thumbnail",
                        "a.livp": "generate_livp_thumbnail"}[by_id[args[0]].filename]
        assert kwargs["_job_id"] == f"thumbbf:missing-covers:{args[0]}"
        assert kwargs["_expires"] == bf.JOB_EXPIRES_S == 3600
    sc = redis.set_calls[0]
    assert len(redis.set_calls) == 1 and sc["key"] == "backfill:lock" \
        and sc["nx"] is True and sc["ex"] == 90, "锁:SET backfill:lock NX EX 90"
    assert redis.deletes == ["backfill:lock"], "结束释放自己的锁(compare-and-del)"
    assert "enqueued=3" in caplog.text


async def test_apply_derive_small_mode_job_name(monkeypatch: pytest.MonkeyPatch,
                                                caplog: pytest.LogCaptureFixture) -> None:
    """--mode derive-small --apply:命中行派 derive_small_thumbnail,_job_id 形如
    thumbbf:derive-small:{id}。"""
    rows = [mk_row(tags={"thumbnail_key": "thumbnails/x.jpg"})]
    redis, pool = FakeRedis(), FakePool()
    patch_run_env(monkeypatch, db=_CapDB(rows), redis=redis, pool=pool)
    monkeypatch.setattr(sys, "argv", [
        "backfill", "--mode", "derive-small", "--apply", "--yes", "--sleep", "0",
    ])
    caplog.set_level(logging.INFO)

    await bf.main()

    assert len(pool.jobs) == 1
    name, args, kwargs = pool.jobs[0]
    assert name == "derive_small_thumbnail" and args == (str(rows[0].id),)
    assert kwargs["_job_id"] == f"thumbbf:derive-small:{rows[0].id}"
    assert "enqueued=1" in caplog.text


async def test_oversized_image_reported_not_dispatched(monkeypatch: pytest.MonkeyPatch,
                                                       capsys: pytest.CaptureFixture[str]) -> None:
    """missing-covers:图片族 >200MB 不派发不打标仅报告(防 OOM);视频族不受此限
    (cap 由 worker 8GB 防御值把守);≤200MB 图片正常派发。"""
    rows = [
        mk_row(filename="small.jpg", content_type="image/jpeg", size_bytes=10 * 1024**2),
        mk_row(filename="huge.jpg", content_type="image/jpeg", size_bytes=bf.IMG_CAP_BYTES + 1),
        mk_row(filename="big.mov", content_type="application/octet-stream", size_bytes=9 * 1024**3),
    ]
    redis, pool = FakeRedis(), FakePool()
    patch_run_env(monkeypatch, db=_CapDB(rows), redis=redis, pool=pool)
    monkeypatch.setattr(sys, "argv", [
        "backfill", "--mode", "missing-covers", "--apply", "--yes", "--sleep", "0",
    ])

    await bf.main()

    enqueued_ids = {j[1][0] for j in pool.jobs}
    assert str(rows[2].id) in enqueued_ids, "超 8GB 视频仍派发(worker 侧才 cap)"
    assert str(rows[0].id) in enqueued_ids, "≤200MB 图片正常派发"
    assert str(rows[1].id) not in enqueued_ids, ">200MB 图片不派发"
    out = capsys.readouterr().out
    assert "超限图片" in out and "huge.jpg" in out


# ─── --window(UTC+8 固定偏移)与跑批锁 ───────────────────────────────────────
def test_window_utc8_boundary_and_cross_day() -> None:
    """窗口判定:UTC+8 固定偏移;端点值含;end <= start 视为跨日窗;非法格式
    SystemExit;未设窗恒在窗。"""
    assert bf.TZ_CN.utcoffset(None) == timedelta(hours=8)

    def at(h: int, m: int) -> datetime:
        return datetime(2026, 10, 27, h, m, tzinfo=bf.TZ_CN)

    win = bf.parse_window("01:00-07:00")
    assert bf.in_window(win, at(1, 0)) and bf.in_window(win, at(7, 0)), "端点值含"
    assert not bf.in_window(win, at(0, 59)) and not bf.in_window(win, at(7, 1))
    assert not bf.in_window(win, at(12, 0))
    cross = bf.parse_window("23:00-01:00")
    assert bf.in_window(cross, at(23, 0)) and bf.in_window(cross, at(0, 30))
    assert bf.in_window(cross, at(1, 0))
    assert not bf.in_window(cross, at(12, 0)) and not bf.in_window(cross, at(22, 59))
    assert bf.in_window(None, at(12, 0)) is True, "未设 --window 恒在窗"
    for bad in ("25:00-07:00", "01:00"):
        with pytest.raises(SystemExit):
            bf.parse_window(bad)


async def test_window_startup_gate_blocks(monkeypatch: pytest.MonkeyPatch,
                                          capsys: pytest.CaptureFixture[str]) -> None:
    """启动时越窗(UTC+8 语义,假钟固定正午):不连 redis、不建 pool、不派发。"""
    monkeypatch.setattr(bf, "get_sessionmaker",
                        lambda: _SM(_CapDB([mk_row(filename="clip.mov",
                                                   content_type="application/octet-stream")])))
    monkeypatch.setattr(bf, "get_settings", mk_settings)
    monkeypatch.setattr(bf, "redis_asyncio", SimpleNamespace(from_url=_boom))
    monkeypatch.setattr(bf, "create_arq_pool", _boom_pool)
    make_fake_clock(monkeypatch, [datetime(2026, 10, 27, 12, 0, tzinfo=bf.TZ_CN)])
    monkeypatch.setattr(sys, "argv", [
        "backfill", "--mode", "missing-covers", "--apply", "--yes", "--window", "01:00-07:00",
    ])

    await bf.main()

    assert "启动时已越窗" in capsys.readouterr().out


async def test_window_per_batch_recheck_stops(monkeypatch: pytest.MonkeyPatch,
                                              caplog: pytest.LogCaptureFixture) -> None:
    """每批派发前复检(BATCH_SIZE 粒度):假钟按序走 01:00(报告)→ 01:45(启动
    在窗)→ 02:30(第 2 批前越窗)→ 优雅停止,已完成的第一批保留;仍释放锁。"""
    rows = [mk_row(filename=f"v{i}.mov", content_type="application/octet-stream")
            for i in range(bf.BATCH_SIZE + 1)]
    redis, pool = FakeRedis(), FakePool()
    patch_run_env(monkeypatch, db=_CapDB(rows), redis=redis, pool=pool)
    make_fake_clock(monkeypatch, [
        datetime(2026, 10, 27, 1, 0, tzinfo=bf.TZ_CN),
        datetime(2026, 10, 27, 1, 45, tzinfo=bf.TZ_CN),
        datetime(2026, 10, 27, 2, 30, tzinfo=bf.TZ_CN),
    ])
    monkeypatch.setattr(sys, "argv", [
        "backfill", "--mode", "missing-covers", "--apply", "--yes", "--sleep", "0",
        "--window", "01:00-02:00",
    ])
    caplog.set_level(logging.INFO)

    await bf.main()

    assert len(pool.jobs) == bf.BATCH_SIZE, "第一批派发完成后才停止"
    assert {j[1][0] for j in pool.jobs} == {str(r.id) for r in rows[:bf.BATCH_SIZE]}
    assert "优雅停止" in caplog.text and "enqueued=50" in caplog.text
    assert redis.deletes == ["backfill:lock"], "越窗停止仍走 finally 释放锁"


async def test_lock_held_by_other_exits_without_delete(monkeypatch: pytest.MonkeyPatch,
                                                       capsys: pytest.CaptureFixture[str]) -> None:
    """锁被其他实例持有(NX 失败)→ 打印持锁者后退出:不建 pool、不删他人锁。"""
    redis = FakeRedis(held_by="someone-else")
    monkeypatch.setattr(bf, "get_sessionmaker",
                        lambda: _SM(_CapDB([mk_row(filename="clip.mov",
                                                   content_type="application/octet-stream")])))
    monkeypatch.setattr(bf, "get_settings", mk_settings)
    monkeypatch.setattr(bf, "redis_asyncio", SimpleNamespace(from_url=lambda *a, **k: redis))
    monkeypatch.setattr(bf, "create_arq_pool", _boom_pool)
    monkeypatch.setattr(sys, "argv", [
        "backfill", "--mode", "missing-covers", "--apply", "--yes", "--sleep", "0",
    ])

    await bf.main()

    assert "另一实例在跑" in capsys.readouterr().out
    assert redis.store.get("backfill:lock") == "someone-else", "他人锁原样保留"
    assert redis.deletes == [], "不得误删他人锁"


async def test_lock_release_compare_and_del(monkeypatch: pytest.MonkeyPatch,
                                            caplog: pytest.LogCaptureFixture) -> None:
    """compare-and-del:释放前校验锁 value 是本机 hostname —— 锁已易主(value
    变他人)时不得 DEL,残留 90s 自愈。"""
    redis, pool = FakeRedis(), FakePool()
    redis.get_returns = "someone-else"   # 模拟「释放前锁已易主」
    patch_run_env(monkeypatch, db=_CapDB([mk_row(filename="clip.mov",
                                                 content_type="application/octet-stream")]),
                  redis=redis, pool=pool)
    monkeypatch.setattr(sys, "argv", [
        "backfill", "--mode", "missing-covers", "--apply", "--yes", "--sleep", "0",
    ])
    caplog.set_level(logging.INFO)

    await bf.main()

    assert len(pool.jobs) == 1, "正常派发不受影响"
    assert redis.set_calls[0]["nx"] is True and redis.set_calls[0]["ex"] == 90
    assert redis.deletes == [] and "backfill:lock" in redis.store, "易主锁保留不 DEL"
