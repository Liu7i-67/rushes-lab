"""百度导入传输层容错 — 离线单测层(无外部基础设施;沿用 test_baidu_unit.py 模式)。

对应需求契约:docs/qdev/2026-10-14-baidu-transport-retry.md(接口签名 = 其 §4,
断言口径 = 其 §7 测试功能点);权威技术规格:
rushes-spec/material-storage/baidu-import-transport-retry-plan.md(测试点 T1-T10
完整定义在其 §4)。被测符号(BaiduTransportError/BaiduRangeIgnored、stream_download
状态门、Settings 新配置、_DownloadResult.upload_id、_download_parts content_type、
attempts 熔断、文件级落码分叉)由后端并行开发 —— 本文件先落,符号到位即可跑。

离线口径(方案 §3.4):
- 一律不吃真退避:预算无关用例 patch `worker._sharded_backoff` 为即时返回;
  分片心跳用例(T7/T4b cancel)保留真 `_sharded_backoff`,注入 `SLEEP_SHARD_S`
  小值 + `asyncio.sleep` 桩(零真实耗时,禁吃 2/5/15s 真档位);
- `part_size` 注入 64KiB 小值,免为攒满默认 16MiB 首片造大文件;
- T3/T5 种子含其他 pending 行(防任务终态化使「任务继续」断言失真)。

■ 需求 §7 测试功能点 ↔ 测试映射
| T 号 | 测试 |
|------|------|
| T1   | test_t1_stream_retries_three_transport_errors_then_file_success |
| T2   | test_t2_resume_range_from_uploaded_part_boundary_no_stale_buffer |
| T2   | test_t2_boundary_all_parts_uploaded_no_out_of_range_request(边界子用例) |
| T3   | test_t3_stream_budget_exhausted_five_file_rounds_fail_network_transport |
| T4   | TestT4ClientStreamDownloadGate(contract / Range+200 / 无 Range 200 / 206 三态 / 建连与正文 TransportError) |
| T4b  | TestT4bWorkerRangeIgnored(接管重进重拉 / complete 用重建 upload_id / 预算耗尽升级 / 退避中 cancel 仅停写 / except 顺序哨兵) |
| T5   | test_t5_attempts_fuse_before_claim_zero_progress_exempt(含 bytes_done>0 反例) |
| T6   | TestT6Regression(rate_limited 退避与文案 / link_expired 刷新 / _UploadSessionLost) |
| T7   | test_t7_backoff_shards_renew_lease_via_checkpoint |
| T7   | test_t7_cancel_during_transport_backoff_stops_writing |
| T10  | TestT10Settings(invalid 配置 raise / backoff steps 解析+末档钳位) |

桩同步(tests/test_baidu_integration.py 的 BaiduScript):fail_after_bytes 中途失败
注入 + fail_first 支持传输层新异常类型;client 层新契约(Range+200 → RangeIgnored、
建连/正文 TransportError → BaiduTransportError)由本文件 T4 的 httpx MockTransport
直测覆盖(worker 层桩不建模状态码)。
"""
from __future__ import annotations

import asyncio
import dataclasses
import inspect
import logging
import os
import re
import uuid
from collections.abc import AsyncIterator, Callable
from typing import Any

import httpx
import pytest
from botocore.exceptions import ClientError

import app.workers.baidu_backup as worker
from app.db.tables import BaiduBackupTask, Folder, Project
from app.services.baidu_client import (
    CATEGORY_LINK_EXPIRED,
    CATEGORY_RATE_LIMITED,
    CATEGORY_UNKNOWN,
    BaiduApiError,
    BaiduNetdiskClient,
    BaiduRangeIgnored,
    BaiduTransportError,
)
from app.services.baidu_storage import is_no_such_upload_error
from app.settings import Settings
from tests.test_baidu_unit import (
    _CRYPTO,
    FakeDb,
    FakeFolder,
    FakePermissions,
    FakeResult,
    FakeRow,
    FakeTask,
    make_settings,
)

PART = 64 * 1024          # 注入的小 part_size(方案 §3.4 测试口径)
TASK_FILE_TABLE = "baidu_backup_task_files"


# ─── 桩:下载 client(store/client 替身,沿用集成层 BaiduScript 注入面)────────
class FakeDownloadClient:
    """BaiduNetdiskClient 替身(仅下载流):内容按 fs_id 存取;记录 Range 起点注入面:
    - fail_first[fs_id] = [exc, ...]:逐次弹出、流前抛(支持 BaiduTransportError /
      BaiduRangeIgnored 等传输层新异常,与集成层 BaiduScript 同款);
    - always_raise[fs_id] = exc:每次流消费均抛(耗尽类用例);
    - fail_after_bytes[fs_id] = n:产出 n 字节(足够触发 ≥1 次 _flush 上传)后中途抛
      BaiduTransportError(一次性弹出)——「中断发生在已传 N 字节后」的唯一载体。
    """

    def __init__(self, bodies: dict[int, bytes]) -> None:
        self.bodies = bodies
        self.fail_first: dict[int, list[Exception]] = {}
        self.always_raise: dict[int, Exception] = {}
        self.fail_after_bytes: dict[int, int] = {}
        self.download_calls: list[tuple[int, int]] = []   # (fs_id, range_start;0 = 无 Range)

    async def stream_download(
        self, access_token: str, dlink: str, *,
        range_header: str | None = None, **_kwargs: Any,
    ) -> AsyncIterator[bytes]:
        del access_token   # mock 不校验 token;保留真实签名形状
        fs_id = int(dlink.rstrip("/").rsplit("/", 1)[-1])
        start = 0
        if range_header:
            start = int(str(range_header).split("-")[0].lstrip("bytes=").split("=")[-1] or 0)
        self.download_calls.append((fs_id, start))
        if self.fail_first.get(fs_id):
            raise self.fail_first[fs_id].pop(0)
        if fs_id in self.always_raise:
            raise self.always_raise[fs_id]
        body = self.bodies[fs_id]
        limit = self.fail_after_bytes.pop(fs_id, None)
        chunk = 16 * 1024
        if limit is not None and limit <= 0:
            raise BaiduTransportError(
                CATEGORY_UNKNOWN, "下载流中断:ReadTimeout(桩注入,0 字节)",
                kind="ReadTimeout", bytes_read=0,
            )
        produced = 0
        for off in range(start, len(body), chunk):
            piece = body[off:off + chunk]
            if limit is not None and produced + len(piece) > limit:
                piece = piece[:limit - produced]
            yield piece
            produced += len(piece)
            if limit is not None and produced >= limit:
                raise BaiduTransportError(
                    CATEGORY_UNKNOWN,
                    f"下载流中断:ReadTimeout(桩注入 fs_id={fs_id} produced={produced})",
                    kind="ReadTimeout", bytes_read=produced,
                )


class FakeStore:
    """AsyncObjectStore 替身:multipart 生命周期留痕(不触 MinIO)。complete 前的
    head_object 恒 None(head 快捷路径不命中),complete 后回 final_size(落库门放行)。"""

    def __init__(self, *, final_size: int = 0) -> None:
        self.final_size = final_size
        self.created: list[tuple[str, str, str]] = []                  # (bucket, key, content_type)
        self.uploaded: list[tuple[str, str, str, int, bytes]] = []     # (bucket,key,uid,part,body)
        self.aborted: list[str] = []                                   # upload_id
        self.completed: list[tuple[str, str, str, list[dict[str, Any]]]] = []
        self.complete_calls = 0            # 含失败调用(NoSuchUpload 注入时也计数)
        self.fail_complete_with: Exception | None = None
        self._seq = 0

    async def create_multipart_upload(self, bucket: str, key: str, content_type: str) -> str:
        self._seq += 1
        self.created.append((bucket, key, content_type))
        return f"up-{self._seq}"

    async def upload_part(
        self, bucket: str, key: str, upload_id: str, part_number: int, body: bytes,
    ) -> str:
        self.uploaded.append((bucket, key, upload_id, part_number, bytes(body)))
        return f"etag-{upload_id}-{part_number}"

    async def abort_multipart_upload(self, bucket: str, key: str, upload_id: str) -> None:
        self.aborted.append(upload_id)

    async def complete_multipart_upload(
        self, bucket: str, key: str, upload_id: str, parts: list[dict[str, Any]],
    ) -> None:
        self.complete_calls += 1
        if self.fail_complete_with is not None:
            raise self.fail_complete_with
        self.completed.append((bucket, key, upload_id, list(parts)))

    async def list_parts(self, bucket: str, key: str, upload_id: str) -> list[dict[str, Any]]:
        return []   # 恒空 → _resume_or_create_session 走「死会话清零重创」分支

    async def head_object(self, bucket: str, key: str) -> dict[str, Any] | None:
        if not self.completed:
            return None
        return {"size_bytes": self.final_size, "etag": "final-etag",
                "version_id": None, "content_type": "video/mp4"}


class FakePerms(FakePermissions):
    """补 bootstrap_asset(资产落库后 FGA 建链;离线 no-op)。"""

    async def bootstrap_asset(self, **_kwargs: Any) -> None:
        return None


class LandingFakeDb(FakeDb):
    """补 db.add(asset 落库)的 FakeDb(走完整落库链路的离线用例用)。"""

    def __init__(self, **kwargs: Any) -> None:
        super().__init__(**kwargs)
        self.added: list[Any] = []

    def add(self, obj: Any) -> None:
        self.added.append(obj)


# ─── 搭建 helpers(make_settings/make_runner 沿用 test_baidu_unit 模式)────────
def make_retry_settings(**overrides: Any) -> Settings:
    """基础 Settings + 本需求新配置(契约默认;退避档 2/5/15 仅作占位 ——
    用例一律经 patch 不吃真退避,见模块 docstring 离线口径)。
    defaults 先合并再透传:允许 overrides 覆盖同名字段(如 T10 的非法退避串),
    不触发「got multiple values for keyword argument」。"""
    base: dict[str, Any] = dict(
        baidu_stream_retry_max=3,
        baidu_stream_retry_backoff_s="2,5,15",
        baidu_max_row_attempts=10,
    )
    base.update(overrides)
    return make_settings(**base)


def make_retry_runner(*, client: Any, store: Any,
                      settings: Settings | None = None,
                      task_id: uuid.UUID | None = None) -> worker.Runner:
    """task_id 必须与 _import_world 种进 FakeDb.get_map 的 FakeTask.id 同源:
    _import_one_file 首步 db.get(Task, runner.task_id),不接线会得 task_not_found。"""
    return worker.Runner(
        task_id=task_id or uuid.uuid4(),
        expected_seq=1,
        runner_id="runner-transport-retry",
        store=store,                    # type: ignore[arg-type]
        permissions=FakePerms(),        # type: ignore[arg-type]
        presign=None,                   # type: ignore[arg-type]
        crypto=_CRYPTO,
        client=client,                  # type: ignore[arg-type]
        settings=settings or make_retry_settings(),
        binding_id=None,
        user_id=uuid.uuid4(),
    )


def _dlink_of(fs_id: int) -> str:
    return f"https://d.pcs.baidu.com/dl/{fs_id}"


def _patch_current_token(monkeypatch: pytest.MonkeyPatch) -> None:
    async def _tok(_db: Any, _runner: Any) -> str:
        return "token-stub"

    monkeypatch.setattr(worker, "_current_token", _tok)


def _patch_fast_backoff(monkeypatch: pytest.MonkeyPatch) -> None:
    """_download_parts 级用例的公共离线桩:checkpoint 直通 + 退避即时返回
    (禁吃 2/5/15s 真档位;分片心跳语义见 T7 专用用例)。"""
    async def _pass(_db: Any, _runner: Any) -> None:
        return None

    async def _instant(_db: Any, _runner: Any, _seconds: float) -> None:
        return None

    monkeypatch.setattr(worker, "checkpoint", _pass)
    monkeypatch.setattr(worker, "_sharded_backoff", _instant)


def _patch_import_env(monkeypatch: pytest.MonkeyPatch) -> None:
    """_import_one_file 级用例的公共离线桩:checkpoint 直通、token/dlink 直出、
    退避即时、审计捕获(离线无 PG session)。"""
    async def _pass(_db: Any, _runner: Any) -> None:
        return None

    async def _dlink(_db: Any, _runner: Any, row: Any) -> str:
        return _dlink_of(row.fs_id)

    async def _instant(_db: Any, _runner: Any, _seconds: float) -> None:
        return None

    async def _no_audit(**_kwargs: Any) -> None:
        return None

    monkeypatch.setattr(worker, "checkpoint", _pass)
    monkeypatch.setattr(worker, "_ensure_dlink", _dlink)
    monkeypatch.setattr(worker, "_sharded_backoff", _instant)
    monkeypatch.setattr(worker, "write_audit", _no_audit)
    _patch_current_token(monkeypatch)


def _import_world(*, source_size: int) -> tuple[FakeTask, FakeRow, LandingFakeDb]:
    """_import_one_file 离线世界:task → project/target 夹 get_map + 待导入行。"""
    folder_id = uuid.uuid4()
    task = FakeTask(target_folder_id=folder_id)
    row = FakeRow(
        status="importing", target_folder_id=folder_id, source_size=source_size,
        minio_upload_id=None, minio_bucket="bk", minio_key="p/b.mp4", bytes_done=0,
        # source_path:落库审计(baidu_file_imported details)在调用 write_audit 前
        # 取值该字段,离线行必须种上(与集成层 _mk_file 的 source_path 同构;
        # FakeRow.rel_path 默认 "b.mp4")
        source_path="/it-src/b.mp4",
    )
    db = LandingFakeDb(
        select_result=FakeResult(rows=[], scalar_row=0),
        get_map={
            (BaiduBackupTask, task.id): task,
            (Project, task.project_id): FakeFolder(id=task.project_id, minio_prefix="p/"),
            (Folder, folder_id): FakeFolder(id=folder_id),
        },
    )
    return task, row, db


def _failed_updates(db: FakeDb) -> list[dict[str, Any]]:
    return [v for t, v in db.updates
            if t == TASK_FILE_TABLE and v.get("status") == "failed"]


def _bytes_done_updates(db: FakeDb) -> list[Any]:
    return [v["bytes_done"] for t, v in db.updates
            if t == TASK_FILE_TABLE and "bytes_done" in v]


def _transport_error(kind: str = "ReadTimeout", bytes_read: int = 0) -> BaiduTransportError:
    return BaiduTransportError(CATEGORY_UNKNOWN, f"下载流中断:{kind}(桩注入)",
                               kind=kind, bytes_read=bytes_read)


def _range_ignored() -> BaiduRangeIgnored:
    return BaiduRangeIgnored(CATEGORY_UNKNOWN, "服务端忽略 Range 返回 200 全量(桩注入)")


# ════════════════════════════ T1:流内重试至成功 ═══════════════════════════════
async def test_t1_stream_retries_three_transport_errors_then_file_success(
    monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture,
) -> None:
    """T1(需求 §7):流第 1/2/3 次抛 BaiduTransportError 后成功 → 文件成功、
    重试日志 3 条、bytes_done 最终 = size。驱动 _import_one_file 全链路:
    「文件成功」载体 = 行 success 落库 + asset 落库 + complete parts。"""
    _patch_import_env(monkeypatch)
    body = os.urandom(PART * 3 + PART // 2)   # 3.5 片:末片部分填充
    task, row, db = _import_world(source_size=len(body))
    client = FakeDownloadClient({row.fs_id: body})
    client.fail_first[row.fs_id] = [
        _transport_error("ReadTimeout"), _transport_error("ReadError"), _transport_error("ReadTimeout"),
    ]
    store = FakeStore(final_size=len(body))
    runner = make_retry_runner(client=client, store=store,
                               settings=make_retry_settings(baidu_part_size_bytes=PART),
                               task_id=task.id)

    with caplog.at_level(logging.WARNING, logger="worker.baidu"):
        result = await worker._import_one_file(db, runner, row)

    assert result == "ok"
    # 文件成功:行 success + bytes_done=size + asset 落库 + complete parts
    upd = db.last_update(TASK_FILE_TABLE)
    assert upd["status"] == "success"
    assert upd["bytes_done"] == len(body)
    assert db.added and db.added[0].size_bytes == len(body)
    assert [c[2] for c in store.completed] == ["up-1"]
    assert [p["PartNumber"] for p in store.completed[0][3]] == [1, 2, 3, 4]
    # 内容无损:全部 upload_part body 依序拼回原文
    assert b"".join(u[4] for u in store.uploaded) == body
    # 中断均在流前(未传任何字节):4 次流消费全部无 Range(pos 恒 0,不整文件重拉错位)
    assert [start for _, start in client.download_calls] == [0, 0, 0, 0]
    # 会话保留:重试间不重建 multipart(方案 §3.2:仅 Range 被忽略才重建)
    assert store.aborted == [] and len(store.created) == 1
    # 重试日志 3 条(F-8:log.warning 字段含 stream_retry)
    retry_warnings = [r for r in caplog.records
                      if r.levelno == logging.WARNING and "stream_retry" in r.getMessage()]
    assert len(retry_warnings) == 3, \
        f"重试日志须恰 3 条: {[r.getMessage() for r in retry_warnings]}"


# ════════════════════════════ T2:Range 断点续传 ═══════════════════════════════
async def test_t2_resume_range_from_uploaded_part_boundary_no_stale_buffer(
    monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture,
) -> None:
    """T2(需求 §7):中断发生在已传 N 字节后 → 重试 Range 起点 = 已上传分片边界
    (download_calls 断言)+ 重试后首片不含中断前缓冲字节(pending 必须清空,断言
    载体 = upload_part body 序列;残留 [pos,pos+k) 字节会与新流错位续拼)。"""
    _patch_fast_backoff(monkeypatch)
    _patch_current_token(monkeypatch)
    body = os.urandom(PART * 3 + PART // 2)          # 3.5 片
    # 中断注入:产出 1 片(触发 1 次 _flush 上传,pos=PART)+ 10KiB 残留缓冲后抛
    client = FakeDownloadClient({10086: body})
    client.fail_after_bytes[10086] = PART + 10 * 1024
    store = FakeStore()
    runner = make_retry_runner(client=client, store=store)
    row = FakeRow(fs_id=10086, source_size=len(body), bytes_done=0,
                  minio_upload_id=None, minio_bucket="bk", minio_key="p/b.mp4")
    db = FakeDb()

    dl = await worker._download_parts(
        db, runner, row, _dlink_of(row.fs_id), bucket="bk", key="p/b.mp4",
        upload_id="up-0", parts=[], offset=0, next_part=1, part_size=PART,
        content_type="video/mp4",
    )

    assert dl.outcome is None
    assert dl.pos == len(body)
    # Range 起点 = 已上传分片边界(首次无 Range,重试带 bytes=65536-)
    assert [start for _, start in client.download_calls] == [0, PART]
    # upload_part body 序列:依序等于原文切片;重试后首片(part 2)不含中断前缓冲字节
    bodies = [u[4] for u in store.uploaded]
    assert bodies == [body[0:PART], body[PART:2 * PART], body[2 * PART:3 * PART],
                      body[3 * PART:]], "分片内容错位续拼(pending 未清空?)"
    assert [u[3] for u in store.uploaded] == [1, 2, 3, 4]
    # bytes_done 逐片推进,终值 = size
    assert _bytes_done_updates(db)[-1] == len(body)
    # 中途失败 1 次 → 重试日志 1 条
    retry_warnings = [r for r in caplog.records
                      if r.levelno == logging.WARNING and "stream_retry" in r.getMessage()]
    assert len(retry_warnings) == 1


async def test_t2_boundary_all_parts_uploaded_no_out_of_range_request(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """T2 边界子用例(方案 §4):size%part==0 且中断发生在全部整分片已上传后
    (pos==size,「末片已刷、等 EOF」窗口)→ 不发越界 Range(bytes={size}- 会 416)、
    直接 complete 成功。"""
    _patch_fast_backoff(monkeypatch)
    _patch_current_token(monkeypatch)
    body = os.urandom(PART * 2)                       # 恰 2 整片
    client = FakeDownloadClient({10086: body})
    client.fail_after_bytes[10086] = len(body)        # 全部字节产出(2 次 flush)后中断
    store = FakeStore()
    runner = make_retry_runner(client=client, store=store)
    row = FakeRow(fs_id=10086, source_size=len(body), bytes_done=0,
                  minio_upload_id=None, minio_bucket="bk", minio_key="p/b.mp4")
    db = FakeDb()

    dl = await worker._download_parts(
        db, runner, row, _dlink_of(row.fs_id), bucket="bk", key="p/b.mp4",
        upload_id="up-0", parts=[], offset=0, next_part=1, part_size=PART,
        content_type="video/mp4",
    )

    assert dl.outcome is None and dl.pos == len(body)
    # 恰 1 次下载请求且无 Range;绝无 bytes={size}- 越界续传请求
    assert [start for _, start in client.download_calls] == [0]
    assert len(store.uploaded) == 2 and b"".join(u[4] for u in store.uploaded) == body
    assert [p["PartNumber"] for p in dl.parts] == [1, 2]


# ════════════════════════════ T3:双层预算耗尽 → network_transport ═════════════
async def test_t3_stream_budget_exhausted_five_file_rounds_fail_network_transport(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """T3(需求 §7):流内 3 次重试耗尽 → 升级文件级;文件级 5 轮耗尽 → 行 failed、
    last_error 前缀 `network_transport: `、non_retryable=false、任务继续下一行
    (种子含其他 pending 行,防任务终态化使断言失真)。预算断言:单次认领流消费
    = 5x(1+3)=20 次(方案 §6 最坏路径收敛①)。"""
    _patch_import_env(monkeypatch)
    body = os.urandom(PART)
    task, dead_row, db = _import_world(source_size=len(body))
    other_row = FakeRow(status="pending", fs_id=20086, source_size=1024, bytes_done=0)
    client = FakeDownloadClient({dead_row.fs_id: body, other_row.fs_id: os.urandom(1024)})
    client.always_raise[dead_row.fs_id] = _transport_error()
    store = FakeStore()
    runner = make_retry_runner(client=client, store=store,
                               settings=make_retry_settings(baidu_part_size_bytes=PART),
                               task_id=task.id)

    queue = [dead_row, other_row]
    async def _next_row(_db: Any, _task_id: Any) -> Any:
        return queue.pop(0) if queue else None

    imported: list[Any] = []
    real_import = worker._import_one_file

    async def _dispatch(db: Any, runner: Any, row: Any) -> str:
        if row.id == other_row.id:
            imported.append(row.id)          # 脚本化「下一行正常导入成功」
            return "ok"
        return await real_import(db, runner, row)

    agg_calls: list[Any] = []

    async def _agg(_db: Any, *, task_id: Any) -> None:
        agg_calls.append(task_id)            # 仍有 pending 行 → 返回 None(不终态化)

    monkeypatch.setattr(worker, "_next_pending_row", _next_row)
    monkeypatch.setattr(worker, "_import_one_file", _dispatch)
    monkeypatch.setattr(worker, "aggregate_and_finalize_if_done", _agg)

    status = await worker._import_loop(db, runner)

    assert status == "done"
    # 流消费预算:5 次文件级尝试 x (1 + 3 次流内重试) = 20
    assert len(client.download_calls) == 5 * (1 + 3) == 20
    # 行 failed:network_transport 落码 + non_retryable=false(D1:网络类失败不定性永久)
    failed = _failed_updates(db)
    assert len(failed) == 1
    assert str(failed[0]["last_error"]).startswith("network_transport: "), failed[0]
    assert failed[0]["non_retryable"] is False
    # 任务继续:熔断/失败行出局后循环取了下一行,任务未被终态化
    assert imported == [other_row.id]
    assert len(agg_calls) == 1


# ════════════════════════════ T4:client 层状态门与包装(MockTransport)═══════════
_DL = "https://d.pcs.baidu.com/file/10086"


def _mk_client(handler: Callable[[httpx.Request], httpx.Response]) -> BaiduNetdiskClient:
    """真实客户端 + MockTransport 注入(沿 test_baidu_unit 重定向白名单用例同款)。"""
    client = BaiduNetdiskClient(make_settings())
    client._http = httpx.AsyncClient(transport=httpx.MockTransport(handler))  # type: ignore[attr-defined]
    return client


class _BrokenStreamTransport(httpx.AsyncBaseTransport):
    """自造异步 transport:200 响应正常返回,流在产出首个分块后于 aiter_bytes 段
    抛 httpx.TransportError —— 对齐真实网络流「正文已消费若干分块后中断」的时机。
    (MockTransport 的同步生成器 content 注入会让异常从 send 段浮出,不建模。)"""

    def __init__(self, first: bytes, exc: Exception) -> None:
        self._first = first
        self._exc = exc

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        del request

        async def _stream() -> AsyncIterator[bytes]:
            yield self._first
            raise self._exc

        return httpx.Response(200, content=_stream())


async def _drain(client: BaiduNetdiskClient, dlink: str, *,
                 range_header: str | None = None,
                 expect: type[Exception] | None = None) -> Any:
    """消费下载流;expect 非 None 时断言该异常类型上抛,否则返回字节序列。"""
    excinfo: pytest.ExceptionInfo[Any] | None = None
    try:
        if expect is not None:
            with pytest.raises(expect) as excinfo:
                async for _chunk in client.stream_download(
                    "ACCESS.TOKEN", dlink, range_header=range_header,
                ):
                    pass
        else:
            chunks = [
                chunk async for chunk in client.stream_download(
                    "ACCESS.TOKEN", dlink, range_header=range_header,
                )
            ]
            return chunks
    finally:
        await client.close()
    assert excinfo is not None
    return excinfo


class TestT4ClientStreamDownloadGate:
    """T4(client 层,httpx MockTransport;桩不进 worker):Range 状态门收紧 + 传输层
    异常定型。worker 层桩不建模状态码,本组是「200→RangeIgnored 拦截」的唯一断言层。"""

    def test_t4_contract_frozen_dataclasses(self) -> None:
        """F-1/F-2 契约:两异常均继承 BaiduApiError 的 frozen dataclass;
        BaiduTransportError 新增字段带默认(kind="unknown"/bytes_read=0)。"""
        assert issubclass(BaiduTransportError, BaiduApiError)
        err = BaiduTransportError(CATEGORY_UNKNOWN, "下载流中断:ReadTimeout")
        assert err.kind == "unknown" and err.bytes_read == 0
        assert issubclass(BaiduRangeIgnored, BaiduApiError)
        rng = BaiduRangeIgnored(CATEGORY_UNKNOWN, "服务端忽略 Range 返回 200 全量")
        assert rng.category == CATEGORY_UNKNOWN
        with pytest.raises(dataclasses.FrozenInstanceError):
            err.kind = "ReadError"          # type: ignore[misc]
        with pytest.raises(dataclasses.FrozenInstanceError):
            rng.message = "x"               # type: ignore[misc]

    async def test_t4_range_with_200_raises_range_ignored(self) -> None:
        """F-2:range_header 非空且响应 200(非 206)→ raise BaiduRangeIgnored
        (全量内容不得错位续拼;唯一拦截点在 stream_download 单点)。"""

        def handler(_request: httpx.Request) -> httpx.Response:
            return httpx.Response(200, content=os.urandom(1024))

        excinfo = await _drain(_mk_client(handler), _DL,
                               range_header="bytes=1048576-", expect=BaiduRangeIgnored)
        assert excinfo.value.category == CATEGORY_UNKNOWN

    async def test_t4_no_range_200_passes_through(self) -> None:
        """F-2 反向:无 Range 的 200 照常放行(首拉主路径不得误伤)。"""
        body = os.urandom(3 * 64 * 1024)

        def handler(_request: httpx.Request) -> httpx.Response:
            assert "range" not in _request.headers
            return httpx.Response(200, content=body)

        chunks = await _drain(_mk_client(handler), _DL)
        assert b"".join(chunks) == body

    async def test_t4_206_content_range_start_mismatch_raises(self) -> None:
        """F-2:206 Content-Range 起点可解析且 ≠ 请求起点 → raise(收零错位面)。"""

        def handler(request: httpx.Request) -> httpx.Response:
            assert request.headers["range"] == "bytes=100-"
            return httpx.Response(
                206, headers={"Content-Range": "bytes 0-899/900"}, content=os.urandom(900),
            )

        await _drain(_mk_client(handler), _DL, range_header="bytes=100-",
                     expect=BaiduRangeIgnored)

    async def test_t4_206_matching_start_passes(self) -> None:
        """F-2 正向控制:206 起点恰等请求起点 → 放行(解析 off-by-one 防线)。"""
        body = os.urandom(800)

        def handler(request: httpx.Request) -> httpx.Response:
            assert request.headers["range"] == "bytes=100-"
            return httpx.Response(
                206, headers={"Content-Range": "bytes 100-899/900"}, content=body,
            )

        chunks = await _drain(_mk_client(handler), _DL, range_header="bytes=100-")
        assert b"".join(chunks) == body

    @pytest.mark.parametrize("content_range", [
        "bytes */900",      # RFC 通配形态:起点不可解析
        "not-a-range",      # 病态格式
    ])
    async def test_t4_206_unparseable_content_range_passes(self, content_range: str) -> None:
        """F-2:206 无 Content-Range / 不可解析 → 放行(勿把解析失败当异常抛)。"""
        body = os.urandom(128)

        def handler(_request: httpx.Request) -> httpx.Response:
            return httpx.Response(206, headers={"Content-Range": content_range}, content=body)

        chunks = await _drain(_mk_client(handler), _DL, range_header="bytes=100-")
        assert b"".join(chunks) == body

    async def test_t4_206_without_content_range_passes(self) -> None:
        body = os.urandom(128)

        def handler(_request: httpx.Request) -> httpx.Response:
            return httpx.Response(206, content=body)

        chunks = await _drain(_mk_client(handler), _DL, range_header="bytes=100-")
        assert b"".join(chunks) == body

    @pytest.mark.parametrize("exc_cls", [httpx.ConnectTimeout, httpx.ConnectError])
    async def test_t4_connect_transport_error_wrapped(self, exc_cls: type[Exception]) -> None:
        """F-1:建连段(send)TransportError → BaiduTransportError(send 包装收紧一层;
        链路抖动的建连失败与读流中断同进流内重试预算)。"""

        def handler(request: httpx.Request) -> httpx.Response:
            raise exc_cls("连接被拒(桩注入)", request=request)

        excinfo = await _drain(_mk_client(handler), _DL, expect=BaiduTransportError)
        err = excinfo.value
        assert err.kind == exc_cls.__name__ and err.bytes_read == 0
        assert isinstance(err.__cause__, httpx.TransportError)

    @pytest.mark.parametrize("exc_cls", [httpx.ReadTimeout, httpx.ReadError])
    async def test_t4_body_read_transport_error_wrapped_with_bytes_read(
        self, exc_cls: type[Exception],
    ) -> None:
        """F-1:正文读取段 TransportError(本方案治的本体)→ BaiduTransportError,
        kind=httpx 异常类名、bytes_read=已读字节尽力值。

        注入走自造异步 transport(异常真落在 aiter_bytes 段);首个分块取整
        chunk_size(64KiB):aiter_bytes 按 chunk_size 攒块,不足一块不产出则
        bytes_read 恒 0,断言须跨过一块档位。"""
        first = os.urandom(64 * 1024)   # == 默认 chunk_size:保证 ≥1 块已产出
        client = BaiduNetdiskClient(make_settings())
        client._http = httpx.AsyncClient(
            transport=_BrokenStreamTransport(first, exc_cls("连接中断(桩注入)")),
        )  # type: ignore[attr-defined]

        excinfo = await _drain(client, _DL, expect=BaiduTransportError)
        err = excinfo.value
        assert err.kind == exc_cls.__name__
        assert err.bytes_read == len(first), "bytes_read 尽力值 = 已 yield 的字节数"
        assert isinstance(err.__cause__, httpx.TransportError)


# ════════════════════════════ T4b:worker 层 RangeIgnored(fake 注入)════════════
class TestT4bWorkerRangeIgnored:
    """T4b(worker 层,fake 注入):RangeIgnored 分支的会话废弃/重建、upload_id 回传、
    预算升级与落码、退避中 cancel 语义、except 顺序哨兵。"""

    async def test_t4b_takeover_reentry_range_ignored_aborts_clears_and_restarts_from_zero(
        self, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture,
    ) -> None:
        """接管重进形态(已有会话 + pos>0)注入 RangeIgnored → abort 旧会话 + 清三元组
        (bytes_done=0)+ 从 0 重拉(download_calls 起点 0)+ _DownloadResult 回传重建后
        upload_id(F-4:complete 载体);计一次 stream_retry(与 transport 分支共享预算)。"""
        _patch_fast_backoff(monkeypatch)
        _patch_current_token(monkeypatch)
        body = os.urandom(PART * 2 + PART // 2)           # 2.5 片
        client = FakeDownloadClient({10086: body})
        client.fail_first[10086] = [_range_ignored()]
        store = FakeStore()
        runner = make_retry_runner(client=client, store=store)
        row = FakeRow(fs_id=10086, source_size=len(body), bytes_done=PART,
                      minio_upload_id="up-resumed", minio_bucket="bk", minio_key="p/b.mp4")
        db = FakeDb()

        with caplog.at_level(logging.WARNING, logger="worker.baidu"):
            dl = await worker._download_parts(
                db, runner, row, _dlink_of(row.fs_id), bucket="bk", key="p/b.mp4",
                upload_id="up-resumed",
                parts=[{"PartNumber": 1, "ETag": "resumed", "Size": PART}],
                offset=PART, next_part=2, part_size=PART, content_type="video/mp4",
            )

        assert dl.outcome is None
        # 会话废弃:旧 upload_id 被 abort;从 0 重拉(首个请求带断点 Range,重拉无 Range)
        assert store.aborted == ["up-resumed"]
        assert [start for _, start in client.download_calls] == [PART, 0]
        # 全量重传落在重建后的会话上,内容 = 完整原文
        assert {u[2] for u in store.uploaded} == {"up-1"}
        assert b"".join(u[4] for u in store.uploaded) == body
        assert [p["PartNumber"] for p in dl.parts] == [1, 2, 3]
        # F-4:重建后的 upload_id 必须经 _DownloadResult 回传(complete 用它,防对死
        # 会话 complete → NoSuchUpload 白烧一次文件级 attempt)
        assert dl.upload_id == "up-1" and dl.upload_id != "up-resumed"
        # 清三元组落库 + 内存行显式置 None(防御式,防 _resume 读旧值命中存活旧会话;
        # 新 id 的权威载体 = DB 三元组 + dl.upload_id)
        assert any(
            t == TASK_FILE_TABLE and v.get("minio_upload_id", "x") is None
            and v.get("bytes_done") == 0
            for t, v in db.updates
        ), f"清三元组 UPDATE 缺失: {db.updates}"
        assert row.minio_upload_id is None, "重建分支必须显式同步内存 row.minio_upload_id=None"
        # RangeIgnored 重试日志 1 条(F-8:字段含 range_ignored)
        ri_warnings = [r for r in caplog.records
                       if r.levelno == logging.WARNING and "range_ignored" in r.getMessage()]
        assert len(ri_warnings) == 1

    async def test_t4b_complete_uses_rebuilt_upload_id_after_range_ignored(
        self, monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """T4b:RangeIgnored → 流内重建会话后成功 → complete 落在重建后的 upload_id
        (store.completed 载体);content_type 经 _download_parts 下传(F-4 签名变更);
        文件全链路成功(行 success + asset 落库)。"""
        _patch_import_env(monkeypatch)
        body = os.urandom(PART + 1024)
        task, row, db = _import_world(source_size=len(body))
        client = FakeDownloadClient({row.fs_id: body})
        client.fail_first[row.fs_id] = [_range_ignored()]
        store = FakeStore(final_size=len(body))
        runner = make_retry_runner(client=client, store=store,
                                   settings=make_retry_settings(baidu_part_size_bytes=PART),
                                   task_id=task.id)

        result = await worker._import_one_file(db, runner, row)

        assert result == "ok"
        # complete 使用重建后的 upload_id:首会话 up-1 已 abort,complete 落 up-2
        assert store.aborted == ["up-1"]
        assert [c[2] for c in store.completed] == ["up-2"]
        # content_type 下传:两次 create(初始 + 重建)都带视频 MIME(F-4 签名落地)
        assert [c[2] for c in store.created] == ["video/mp4", "video/mp4"], store.created
        # bucket/key 一致(project.minio_bucket="bk-unit",target 夹 prefix "p/")
        assert all(c[0] == "bk-unit" and c[1] == "p/b.mp4" for c in store.created)
        # 全链路成功:行 success + asset 落库(size 门放行)
        upd = db.last_update(TASK_FILE_TABLE)
        assert upd["status"] == "success" and upd["bytes_done"] == len(body)
        assert db.added and db.added[0].size_bytes == len(body)

    async def test_t4b_range_ignored_budget_exhausted_fails_network_transport(
        self, monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """T4b:RangeIgnored 连续触发至流内预算耗尽 → 升级文件级(与 transport 分支
        对称),文件级 5 轮耗尽落 network_transport(钉死,不留 rate_limited 误标)。"""
        _patch_import_env(monkeypatch)
        body = os.urandom(PART)
        task, row, db = _import_world(source_size=len(body))
        client = FakeDownloadClient({row.fs_id: body})
        client.always_raise[row.fs_id] = _range_ignored()
        store = FakeStore()
        runner = make_retry_runner(client=client, store=store,
                                   settings=make_retry_settings(baidu_part_size_bytes=PART),
                                   task_id=task.id)

        await worker._import_one_file(db, runner, row)

        # 预算同 transport 分支:5 次文件级尝试 x (1+3) = 20 次流消费
        assert len(client.download_calls) == 20
        failed = _failed_updates(db)
        assert len(failed) == 1
        assert str(failed[0]["last_error"]).startswith("network_transport: "), failed[0]
        assert failed[0]["non_retryable"] is False

    async def test_t4b_cancel_during_range_ignored_backoff_stops_write_only(
        self, monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """T4b:RangeIgnored 退避中注入 cancel → 仅停写(不 abort、不清三元组、不再写
        库/拉流),按检查点结果退出;所有权已失场景留待下次认领经 _resume 收敛。"""
        _patch_instant_sleep(monkeypatch)
        _patch_current_token(monkeypatch)

        async def _cancel(_db: Any, _runner: Any) -> str:
            return "cancel"

        monkeypatch.setattr(worker, "checkpoint", _cancel)
        body = os.urandom(PART * 2 + PART // 2)
        client = FakeDownloadClient({10086: body})
        client.fail_first[10086] = [_range_ignored()]
        store = FakeStore()
        runner = make_retry_runner(client=client, store=store)
        row = FakeRow(fs_id=10086, source_size=len(body), bytes_done=PART,
                      minio_upload_id="up-resumed", minio_bucket="bk", minio_key="p/b.mp4")
        db = FakeDb()

        dl = await worker._download_parts(
            db, runner, row, _dlink_of(row.fs_id), bucket="bk", key="p/b.mp4",
            upload_id="up-resumed", parts=[], offset=PART, next_part=2,
            part_size=PART, content_type="video/mp4",
        )

        # 仅停写:按检查点结果退出,不 abort、不清三元组、不再拉不再传
        assert dl.outcome == "cancel"
        assert [start for _, start in client.download_calls] == [PART]
        assert store.aborted == [] and store.uploaded == []
        assert not any(
            t == TASK_FILE_TABLE and v.get("minio_upload_id", "x") is None
            for t, v in db.updates
        ), "退避中止路径不得清三元组"
        assert row.minio_upload_id == "up-resumed", "仅停写:内存行会话字段不动"

    def test_t4b_except_order_sentinel(self) -> None:
        """T4b except 顺序哨兵:F-6/方案 §3.2 —— 专属子句(BaiduTransportError /
        BaiduRangeIgnored)必须列在既有 `except BaiduApiError` 之前(子类先匹配;
        顺序事故态 = 流内重试成死代码、RangeIgnored 空耗文件级 5 轮后误标 rate_limited)。
        行为面(注入后在流内被消费、不泄漏到文件级)由本组重拉/升级用例兜住。

        取子句口径:行首锚定 + 排除行内注释(#),防「专属子句必须列于 except
        BaiduApiError 之前」这类说明性注释被误认成 except 子句;_import_one_file
        从 _transfer_and_finalize 调用处切片 —— 其前段 _ensure_dlink 的 try 也有
        except BaiduApiError,不属 F-6 约束的传输链。"""
        def except_clauses(src: str) -> list[str]:
            return [m.group(0) for m in re.finditer(
                r"^[ \t]*except\s+[^#\n]+:", src, re.MULTILINE,
            )]

        def clause_positions(clauses: list[str]) -> dict[str, int]:
            return {
                name: next((i for i, c in enumerate(clauses) if name in c), -1)
                for name in ("BaiduTransportError", "BaiduRangeIgnored", "BaiduApiError")
            }

        # _download_parts:全函数唯一 except BaiduApiError 即被测链
        positions = clause_positions(except_clauses(inspect.getsource(worker._download_parts)))
        # _import_one_file:取传输调用之后的 except 链
        src_f = inspect.getsource(worker._import_one_file)
        tail_f = src_f[src_f.index("await _transfer_and_finalize("):]
        positions_f = clause_positions(except_clauses(tail_f))

        for tag, pos in (("_download_parts", positions), ("_import_one_file", positions_f)):
            for name in ("BaiduTransportError", "BaiduRangeIgnored"):
                assert pos[name] >= 0, f"{tag} 缺 {name} 专属 except 子句: {pos}"
                assert pos[name] < pos["BaiduApiError"], \
                    f"{tag}: {name} 子句必须先于 BaiduApiError(实际: {pos})"


# ════════════════════════════ T5:attempts 熔断(零进展豁免)═════════════════════
async def test_t5_attempts_fuse_before_claim_zero_progress_exempt(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """T5(需求 §7):attempts=10 且 bytes_done=0 的行在认领前熔断 —— 行 failed、
    last_error 前缀 `attempts_exhausted: `(message=认领次数超上限且无进展)、
    non_retryable=false(D1)、循环取下一行、任务不终态化;反例:attempts≥10 但
    bytes_done>0 的行正常认领(零进展豁免,§3.3/D3)。种子含其他 pending 行。
    attempts 用种子直插构造(自然累计需崩溃-接管长窗口,方案 §4 T5 前置说明)。"""
    fuse_row = FakeRow(status="pending", fs_id=30011, attempts=10, bytes_done=0,
                       source_size=1024)
    progress_row = FakeRow(status="pending", fs_id=30012, attempts=12, bytes_done=4096,
                           source_size=1024)   # 反例:有进展不熔断
    normal_row = FakeRow(status="pending", fs_id=30013, attempts=0, bytes_done=0,
                         source_size=1024)
    db = FakeDb()
    runner = make_retry_runner(client=FakeDownloadClient({}), store=FakeStore(),
                               settings=make_retry_settings())

    async def _pass(_db: Any, _runner: Any) -> None:
        return None

    queue = [fuse_row, progress_row, normal_row]

    async def _next_row(_db: Any, _task_id: Any) -> Any:
        return queue.pop(0) if queue else None

    imported: list[Any] = []

    async def _import_ok(_db: Any, _runner: Any, row: Any) -> str:
        imported.append(row.id)              # 能进单文件导入 = 已通过认领前谓词
        return "ok"

    finalize_calls: list[Any] = []

    async def _finalize(_db: Any, *, task_id: Any, status: str,
                        fail_reason: Any = None) -> bool:
        finalize_calls.append((task_id, status))
        return True

    async def _agg(_db: Any, *, task_id: Any) -> None:
        return None                          # 仍有 pending 行 → 任务不终态化

    monkeypatch.setattr(worker, "checkpoint", _pass)
    monkeypatch.setattr(worker, "_next_pending_row", _next_row)
    monkeypatch.setattr(worker, "_import_one_file", _import_ok)
    monkeypatch.setattr(worker, "aggregate_and_finalize_if_done", _agg)
    monkeypatch.setattr(worker, "finalize_task_terminal", _finalize)

    status = await worker._import_loop(db, runner)

    assert status == "done"
    # 熔断行:failed + 结构化前缀 + 文案 + non_retryable=false
    failed = _failed_updates(db)
    assert len(failed) == 1
    assert str(failed[0]["last_error"]).startswith("attempts_exhausted: "), failed[0]
    assert "认领次数超上限" in str(failed[0]["last_error"])
    assert failed[0]["non_retryable"] is False
    # 认领前熔断:熔断行从未进入单文件导入;豁免行与普通行正常认领导入
    assert fuse_row.id not in imported
    assert imported == [progress_row.id, normal_row.id]
    # 任务不终态化:种子含其他 pending 行,行熔断不触发任务终态化
    assert finalize_calls == []


# ════════════════════════════ T6:回归(HTTP 层路径行为不变)═════════════════════
class TestT6Regression:
    """T6(需求 §7):传输层新路径不得吞掉/改写既有 HTTP 层错误路径。"""

    async def test_t6_rate_limited_http_errors_keep_backoff_and_copy(
        self, monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """HTTP 层 rate_limited:不进流内重试预算(每文件级尝试恰 1 次流消费)、
        既有指数退避档不变(2/4/8/16/20)、耗尽落 rate_limited 文案不变。"""
        _patch_import_env(monkeypatch)
        task, row, db = _import_world(source_size=1024)
        client = FakeDownloadClient({row.fs_id: os.urandom(1024)})
        client.always_raise[row.fs_id] = BaiduApiError(
            CATEGORY_RATE_LIMITED, "百度接口 HTTP 503", http_status=503,
        )
        store = FakeStore()
        runner = make_retry_runner(client=client, store=store, task_id=task.id)

        backoff_calls: list[float] = []

        async def _recording(_db: Any, _runner: Any, seconds: float) -> None:
            backoff_calls.append(seconds)

        monkeypatch.setattr(worker, "_sharded_backoff", _recording)

        await worker._import_one_file(db, runner, row)

        # 流内重试不得吞 HTTP 层错误:5 次尝试各 1 次流消费(而非 transport 的 20)
        assert len(client.download_calls) == 5
        # 既有退避档:attempt 1..5 → min(2**attempt, 20)
        assert backoff_calls == [2.0, 4.0, 8.0, 16.0, 20.0]
        failed = _failed_updates(db)
        assert len(failed) == 1
        assert str(failed[0]["last_error"]).startswith("rate_limited: "), failed[0]
        assert "限速" in str(failed[0]["last_error"])
        assert failed[0]["non_retryable"] is False

    async def test_t6_link_expired_clears_dlink_raises_refresh_needed(
        self, monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """link_expired(§3.2 dlink 复用约束):不进流内刷新/重试 —— 清 dlink 缓存、
        抛 _LinkRefreshNeeded 交文件级重取,会话保留。"""
        _patch_fast_backoff(monkeypatch)
        _patch_current_token(monkeypatch)
        client = FakeDownloadClient({10086: os.urandom(1024)})
        client.fail_first[10086] = [BaiduApiError(
            CATEGORY_LINK_EXPIRED, "百度接口 errno=31360", errno=31360,
        )]
        store = FakeStore()
        runner = make_retry_runner(client=client, store=store)
        row = FakeRow(fs_id=10086, source_size=1024, bytes_done=0,
                      minio_upload_id="up-keep", minio_bucket="bk", minio_key="p/b.mp4")
        db = FakeDb()

        with pytest.raises(worker._LinkRefreshNeeded):
            await worker._download_parts(
                db, runner, row, _dlink_of(row.fs_id), bucket="bk", key="p/b.mp4",
                upload_id="up-keep", parts=[], offset=0, next_part=1,
                part_size=PART, content_type="video/mp4",
            )

        # dlink 缓存已清(交上层重新 filemetas);仅 1 次流消费(不进流内重试)、会话保留
        link_updates = [v for t, v in db.updates
                        if t == TASK_FILE_TABLE and v.get("dlink", "x") is None]
        assert link_updates, "link_expired 必须清 dlink 缓存"
        assert len(client.download_calls) == 1
        assert store.aborted == []

    async def test_t6_upload_session_lost_behavior_unchanged(
        self, monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """_UploadSessionLost(complete 时 NoSuchUpload)行为不变:文件级重试循环
        消费(不杀轮),每轮 list_parts 死会话清零重创,5 轮耗尽落 rate_limited。"""
        _patch_import_env(monkeypatch)
        body = os.urandom(1024)
        task, row, db = _import_world(source_size=len(body))
        client = FakeDownloadClient({row.fs_id: body})
        store = FakeStore(final_size=len(body))
        store.fail_complete_with = _no_such_upload()
        runner = make_retry_runner(client=client, store=store, task_id=task.id)

        result = await worker._import_one_file(db, runner, row)

        assert result == "ok"     # _fail_row 收口返回值(行为不变)
        assert len(client.download_calls) == 5          # 每文件级尝试 1 次完整下载
        assert store.complete_calls == 5                # 每轮都尝试 complete(均撞死会话)
        assert len(store.completed) == 0                # 无一次 complete 成功
        assert len(store.created) == 5                  # 每轮死会话清零重创
        failed = _failed_updates(db)
        assert len(failed) == 1
        assert str(failed[0]["last_error"]).startswith("rate_limited: ")
        # 对账:构造的 ClientError 必须被 is_no_such_upload_error 认作死会话
        assert is_no_such_upload_error(_no_such_upload())


def _no_such_upload() -> ClientError:
    return ClientError(
        {"Error": {"Code": "NoSuchUpload", "Message": "The specified upload does not exist"}},
        "CompleteMultipartUpload",
    )


# ════════════════════════════ T7:退避心跳(租约续期 / cancel 感知)══════════════
def _patch_instant_sleep(monkeypatch: pytest.MonkeyPatch) -> None:
    """asyncio.sleep 桩(零真实耗时):配合 SLEEP_SHARD_S 小值保留真分片心跳结构,
    禁吃 2/5/15s 真退避(方案 §3.4 测试口径)。"""
    async def _instant(_seconds: float) -> None:
        return None

    monkeypatch.setattr(asyncio, "sleep", _instant)


async def test_t7_backoff_shards_renew_lease_via_checkpoint(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """T7(需求 §7):流内重试退避走真 _sharded_backoff 分片心跳 —— 每片醒来调一次
    checkpoint(租约续期载体),退避结束续跑至成功。时延注入口径:SLEEP_SHARD_S
    注入 0.2s + asyncio.sleep 桩(2s 首档 → ~10 片,不真睡)。"""
    _patch_instant_sleep(monkeypatch)
    _patch_current_token(monkeypatch)
    monkeypatch.setattr(worker, "SLEEP_SHARD_S", 0.2)

    ckpt_calls: list[int] = []

    async def _renew(_db: Any, _runner: Any) -> None:
        ckpt_calls.append(1)                 # 真实 checkpoint = renew_lease + commit
        return None

    monkeypatch.setattr(worker, "checkpoint", _renew)

    body = os.urandom(PART)
    client = FakeDownloadClient({10086: body})
    client.fail_first[10086] = [_transport_error()]
    store = FakeStore()
    runner = make_retry_runner(client=client, store=store)
    row = FakeRow(fs_id=10086, source_size=len(body), bytes_done=0,
                  minio_upload_id=None, minio_bucket="bk", minio_key="p/b.mp4")
    db = FakeDb()

    dl = await worker._download_parts(
        db, runner, row, _dlink_of(row.fs_id), bucket="bk", key="p/b.mp4",
        upload_id="up-0", parts=[], offset=0, next_part=1, part_size=PART,
        content_type="video/mp4",
    )

    assert dl.outcome is None
    # 2s 退避按 0.2s 分片 → 每片醒来一次 checkpoint(续租约);不 pin 精确片数防浮点漂移
    assert len(ckpt_calls) >= 3, f"退避期间必须分片续租约: {len(ckpt_calls)} 片"
    assert [start for _, start in client.download_calls] == [0, 0]
    assert b"".join(u[4] for u in store.uploaded) == body


async def test_t7_cancel_during_transport_backoff_stops_writing(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """T7:transport 分支退避中 checkpoint 报 cancel → 仅停写(不 abort、不清三元组、
    不再拉流),按检查点结果退出(与 T4b RangeIgnored 分支对称钉死)。"""
    _patch_instant_sleep(monkeypatch)
    _patch_current_token(monkeypatch)

    async def _cancel(_db: Any, _runner: Any) -> str:
        return "cancel"

    monkeypatch.setattr(worker, "checkpoint", _cancel)

    body = os.urandom(PART)
    client = FakeDownloadClient({10086: body})
    client.fail_first[10086] = [_transport_error()]
    store = FakeStore()
    runner = make_retry_runner(client=client, store=store)
    row = FakeRow(fs_id=10086, source_size=len(body), bytes_done=0,
                  minio_upload_id="up-keep", minio_bucket="bk", minio_key="p/b.mp4")
    db = FakeDb()

    dl = await worker._download_parts(
        db, runner, row, _dlink_of(row.fs_id), bucket="bk", key="p/b.mp4",
        upload_id="up-keep", parts=[], offset=0, next_part=1, part_size=PART,
        content_type="video/mp4",
    )

    assert dl.outcome == "cancel"
    assert [start for _, start in client.download_calls] == [0]
    assert store.uploaded == [] and store.aborted == []
    assert not any(
        t == TASK_FILE_TABLE and v.get("minio_upload_id", "x") is None
        for t, v in db.updates
    )
    assert row.minio_upload_id == "up-keep"


# ════════════════════════════ T10:配置校验与解析直测 ═══════════════════════════
class TestT10Settings:
    """T10(需求 §7/F-7):validate_baidu_settings 增校验 + baidu_stream_backoff_steps
    纯函数(0 基解析 + 末档钳位消费口径)。"""

    @pytest.mark.parametrize("bad_backoff", [
        "",        # 空串
        "   ",     # 纯空白
        "2,a",     # 非整数
        "2,0",     # 零值(须正整数)
        "2,-1",    # 负数
    ])
    def test_t10_invalid_backoff_strings_raise(self, bad_backoff: str) -> None:
        s = make_retry_settings(baidu_stream_retry_backoff_s=bad_backoff)
        with pytest.raises(AssertionError):
            s.validate_baidu_settings()

    def test_t10_invalid_counts_raise(self) -> None:
        with pytest.raises(AssertionError):
            make_retry_settings(baidu_stream_retry_max=0).validate_baidu_settings()
        with pytest.raises(AssertionError):
            make_retry_settings(baidu_max_row_attempts=0).validate_baidu_settings()

    def test_t10_valid_defaults_pass(self) -> None:
        make_retry_settings().validate_baidu_settings()   # 不 raise 即通过

    def test_t10_backoff_steps_parse_and_clamp(self) -> None:
        steps = make_retry_settings(
            baidu_stream_retry_backoff_s="2,5,15",
        ).baidu_stream_backoff_steps()
        assert steps == [2, 5, 15]
        # 消费口径:backoff[min(n, len)-1],首次重试(n=1)取档 0
        assert steps[min(1, len(steps)) - 1] == 2
        # 任何重试序号都取得到档(末档钳位),档位不足时延续末档
        for n in range(1, 10):
            assert steps[min(n, len(steps)) - 1] in (2, 5, 15)
        for n in range(3, 10):
            assert steps[min(n, len(steps)) - 1] == 15

    def test_t10_single_step_clamps_to_last(self) -> None:
        single = make_retry_settings(
            baidu_stream_retry_backoff_s="7",
        ).baidu_stream_backoff_steps()
        assert single == [7]
        for n in range(1, 6):
            assert single[min(n, len(single)) - 1] == 7
