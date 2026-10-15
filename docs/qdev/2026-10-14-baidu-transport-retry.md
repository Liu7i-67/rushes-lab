# 百度导入传输层容错 实施需求（qdev）

> 2026-10-14。权威技术规格 = [rushes-spec/material-storage/baidu-import-transport-retry-plan.md](../../rushes-spec/material-storage/baidu-import-transport-retry-plan.md)（qplan 13 轮盲审定稿，76fd27d）。本文档是 qdev 派发用的需求契约：接口签名以本文为准，实现细节以方案文档为准，两者冲突时**先报告再动手**。

## 1. 背景与目标

prod 2026-10-14 事件：备份任务链路抖动期 9 轮死于下载流读取（8×ReadTimeout+1×ReadError），每次死亡等 sweeper 10-15 分钟接管，推进效率降至 ~6 文件/15 分钟。三短板：①传输层异常杀整轮 job；②流中断后整文件从 0 重拉；③无熔断与跳过手段。

目标（G1-G4）：
- G1 下载传输层异常（建连 ConnectTimeout/ConnectError 与正文 ReadTimeout/ReadError/WriteError/CloseError 等 `httpx.TransportError` 家族）不杀整轮 job，进文件内重试；
- G2 流中断重试从已上传分片边界 Range 续传，不整文件重拉；
- G3 崩溃-接管循环中同一文件零进展地反复被认领（attempts 累计且 bytes_done 停留 0）超阈值 → 行 failed 熔断跳过，任务继续；
- G4 每次重试/熔断有日志，熔断行带明确 last_error。

非目标：不改任务状态机/租约/sweeper/48h 语义；不做 md5 校验；不动 dlink 生命周期；HTTP 层错误路径（rate_limited 等）保持现状；无前端改动。

## 2. 功能点明细（逐条可验收）

| # | 功能点 | 验收标准 |
|---|--------|----------|
| F-1 | `BaiduTransportError` 异常定型 | 新异常类存在于 `app/services/baidu_client.py`，继承 `BaiduApiError`（frozen dataclass，新增字段带默认值）；`stream_download` 正文读与建连段的 `httpx.TransportError` 均包装上抛 |
| F-2 | `BaiduRangeIgnored` 异常与状态门收紧 | `range_header` 非空且响应 200 → raise（raise 前 `aclose`）；206 Content-Range 起点可解析且 ≠ 请求起点 → raise；206 无头/不可解析 → 放行；无 Range 的 200 照常放行 |
| F-3 | `_download_parts` 流内重试 | 按方案 §3.2 伪代码：`pos>=size` 卫语句、双分支预算校验（共享 stream_retry 计数）、`pending.clear()`、退避走 `_sharded_backoff` 且消费返回值、RangeIgnored 分支 abort+清三元组+`row.minio_upload_id=None`+经 `_resume_or_create_session` 重建+五件套复位、空会话预算耗尽前补 abort（双分支对称） |
| F-4 | `_DownloadResult` 回传 upload_id；complete 用 `dl.upload_id`；`content_type` 下传 `_download_parts` | 签名变更落地 |
| F-5 | attempts 熔断 | `_import_loop` 认领前谓词：`attempts >= baidu_max_row_attempts(10)` **且** `row.bytes_done == 0` → `_fail_row(code='attempts_exhausted')`；返回 "lost" 向上传播，"ok" 继续取下一行 |
| F-6 | 文件级循环处理传输异常 | `except BaiduTransportError` / `except BaiduRangeIgnored` 列在 `except BaiduApiError` **之前**；计入 attempt + 退避（`min(2**attempt, FILE_BACKOFF_CAP_S)` 走 `_sharded_backoff`）；循环记录末次错误类别，耗尽落码分叉：transport/RangeIgnored → `network_transport`（non_retryable=false），其余保持 rate_limited 文案 |
| F-7 | 配置项与校验 | `baidu_stream_retry_max=3`、`baidu_stream_retry_backoff_s="2,5,15"`、`baidu_max_row_attempts=10`；`validate_baidu_settings()` 增校验（退避串非空/逐项正整数/两计数 ≥1）；解析辅助 `Settings.baidu_stream_backoff_steps() -> list[int]`（0 基，索引钳位末档 `backoff[min(n, len)-1]`）；`workers/main.py` WorkerSettings 增 `on_startup` 钩子调用校验 |
| F-8 | 观测 | 流内重试与 RangeIgnored 各一条 `log.warning`（字段：task/file/kind 或 range_ignored/pos/stream_retry）；abort 失败 log.warning 带 bucket/key/upload_id |

## 3. 数据库修改方案

**不涉及**（无迁移、无新表新列；仅 Settings 配置项，全部带默认值，无 .env 变更）。

## 4. 接口定义（内部契约，两个开发包的共同依据）

**不涉及新 HTTP 端点**。内部接口签名钉死如下：

```python
# app/services/baidu_client.py
@dataclass(frozen=True)
class BaiduTransportError(BaiduApiError):
    kind: str = "unknown"       # httpx 异常类名
    bytes_read: int = 0         # 本次流消费已读字节(尽力值,仅日志)

@dataclass(frozen=True)
class BaiduRangeIgnored(BaiduApiError):
    pass                        # message 携带上下午;category=CATEGORY_UNKNOWN
```

- `stream_download(access_token, dlink, *, range_header, chunk_size)` 签名不变，行为按 F-2/F-1 收紧；模块 docstring 补传输层语义说明（含 UnsupportedProtocol 等确定性错误被当可重试的取舍、DecodingError/TooManyRedirects 不包装）。
- `Settings.baidu_stream_backoff_steps() -> list[int]`：解析 `baidu_stream_retry_backoff_s` 逗号串为正 int 列表。
- `workers/baidu_backup.py`：`_DownloadResult` 增 `upload_id: str` 字段；`_download_parts` 增 `content_type: str` 关键字参数。

## 5. 前端改动点

**不涉及**。

## 6. 后端改动点

四个文件（与方案 §5 部署清单一字不差）：
- `material-storage/api/app/services/baidu_client.py`：F-1/F-2 + docstring + `contextlib` 导入 + `finally: aclose` 加 `contextlib.suppress(Exception)`；
- `material-storage/api/app/workers/baidu_backup.py`：F-3/F-4/F-5/F-6/F-8；
- `material-storage/api/app/workers/main.py`：F-7 的 on_startup 校验钩子；
- `material-storage/api/app/settings.py`：F-7 配置与校验。

**实现约束全部来自方案 §3.2「实现约束（踩坑高发，逐条钉死）」与 §3.1/§3.3，实施前必须通读方案文档全文**，特别是：except 顺序、复位以 `_resume_or_create_session` 实际返回值为准、退避索引 `backoff[min(stream_retry, len)-1]`（首次重试取档 0）、dlink 流内复用不刷新、multipart 会话重试间不重建、文件级循环耗尽落码按末次类别分叉。

## 7. 测试功能点

单测（离线，新建 `api/tests/test_baidu_transport_retry.py`，遵循 `test_baidu_unit.py` 既有模式）：
- T1 流第 1/2/3 次抛 `BaiduTransportError` 后成功 → 文件成功、重试日志 3 条、bytes_done=size；
- T2 中断在已传 N 字节后 → Range 起点=已上传分片边界（`download_calls` 断言）+ 首片不含中断前缓冲字节（断言载体=upload_part body 序列）+ 边界子用例 pos==size 不发越界 Range 直接 complete；注入小 `baidu_part_size_bytes`；
- T3 流内 3 次耗尽 → 文件级 5 轮耗尽 → 行 failed、last_error 前缀 `network_transport: `、non_retryable=false、任务继续（种子含其他 pending 行）；
- T4 client 层（httpx MockTransport）：Range+200→RangeIgnored；无 Range 200 放行；206 Content-Range 起点不符→raise、无头/不可解析→放行；建连/正文 TransportError→BaiduTransportError；
- T4b worker 层（fake 注入）：RangeIgnored → 废弃会话从 0 重拉计次、complete 用重建后 upload_id、预算耗尽升级文件级且落 network_transport、退避中 cancel 仅停写、except 顺序哨兵、接管重进注入 RangeIgnored → abort+清三元组+从 0 重拉；
- T5 attempts=10 且 bytes_done=0 种子行熔断（前缀 `attempts_exhausted: `、取下一行、任务不终态化）+ 反例 bytes_done>0 不熔断；种子含其他 pending 行；
- T6 回归：HTTP 层错误分类、rate_limited 退避、link_expired 刷新、`_UploadSessionLost` 行为不变；
- T7 退避期间租约续期与 cancel 感知（10s 分片心跳；注入秒级退避）；
- T10 配置校验直测：非法退避串/零值 raise；`baidu_stream_backoff_steps()` 解析+末档钳位。

桩同步：`test_baidu_integration.py` 的 `BaiduScript` 增 `fail_after_bytes[fs_id]` 中途失败注入（产出足够字节触发 ≥1 次 `_flush` 上传后抛 `BaiduTransportError`）；`fail_first` 支持新异常类型。

集成（隔离栈，测试阶段执行，本阶段不写）：T8 全量回归、T9 kill -9 接管续传。

## 8. 模糊点与决策记录

方案 §7 决策点 D1-D4 原标记「待拍板」；用户指令「按你的建议，开始 qdev」→ **采纳方案建议列**：

| # | 决策 | 取值 |
|---|------|------|
| D1 | 熔断行 non_retryable | **false**（retry-failed 可复活且 attempts 归零；亦是假阳性自愈通道） |
| D2 | 流内重试上限/退避 | 3 次，2/5/15s |
| D3 | 行熔断阈值与豁免 | **10 + bytes_done==0 零进展豁免**（量级推演见方案 D3；三条残余注记备查） |
| D4 | 任务运行中跳过指定文件端点 | 本次不做 |

其他口径：新配置校验补到 worker 进程（on_startup）；测试全部注入秒级时延；`last_error` 沿用 `_fail_row` "<code>: <message>" 结构化前缀。

## 9. 项目约定

- 代码根：worktree `E:\qbb\github_not_me\rushes-lab-feat-baidu-transport-retry\material-storage\api`；代码风格对齐仓库现状（中文注释、类型标注、ruff/mypy 零新增告警）。
- 本地测试命令（主仓 venv，从 worktree api 目录跑，cwd 优先解析 worktree 代码）：
  `cd E:\qbb\github_not_me\rushes-lab-feat-baidu-transport-retry\material-storage\api && E:\qbb\github_not_me\rushes-lab\material-storage\api\.venv\Scripts\python.exe -m pytest tests/<文件> -q`
- 不 commit、不 push，改动留在工作区由 PM 验收。
