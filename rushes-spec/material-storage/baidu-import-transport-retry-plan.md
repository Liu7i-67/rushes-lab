# 百度导入传输层容错方案:流中断文件内重试 + Range 断点续传 + attempts 熔断

> 2026-10-14 定稿。源自当日 prod 事件复盘:备份任务 69cb3945 在链路抖动期 9 轮死于下载流读取(8×ReadTimeout + 1×ReadError),每轮死亡→等 sweeper 10-15 分钟接管→重派,推进效率降到 ~6 文件/15 分钟;同队头文件反复被尝试造成"某文件卡死"的表象。本方案把「一次网络抖动 = 杀整轮 job」降级为「单文件内重试几次」,并补上熔断与跳过能力。
> 定位:既有设计短板的治理,**不改变任务状态机/租约/sweeper 语义**(那套机制本次事件已实证有效),只在文件导入路径内加容错。

---

## 0. 事件复盘与根因(代码通路实证)

**现象时间线**(prod 2026-10-14,worker 日志+DB 取证):round 1-3 正常 55min 接力;round 4 起 9 次崩溃,traceback 9 次完全一致:

```
workers/baidu_backup.py:217  baidu_backup_run
workers/baidu_backup.py:675  _import_loop            ← 无捕获
workers/baidu_backup.py:888  _import_one_file        ← 重试循环只认 HTTP 层错误
workers/baidu_backup.py:1475 _transfer_and_finalize
workers/baidu_backup.py:1380 _download_parts
services/baidu_client.py:488   async for chunk in resp.aiter_bytes(...)   ← 裸抛
→ httpx.ReadTimeout(8 次)/ ReadError(1 次)
```

**根因链(三个叠加)**:
1. `stream_download` 只把**建连**(`send`)包进 `except httpx.HTTPError`(`baidu_client.py:444-450`),**正文读取裸抛**(`:487-491`);worker 全链路只捕 `BaiduApiError` 系(`workers/baidu_backup.py:893-920`),传输异常一路上穿到 job 顶层 `except Exception`(`:225-227`)→ 杀整轮;
2. `bytes_done=0` 时下一轮从 0 重拉同一文件,且 `_next_pending_row` 按 id 升序(`:650-656`)使队头文件成为每轮固定起点 → "同一文件反复尝试"表象;
3. 无熔断:`TaskFile.attempts` 只在认领时 +1(`:669-673`)且**无任何上限谓词**,`non_retryable` 的置位点(枚举护栏/permission_denied/not_found/FolderChainError)全部够不到网络层——确定性死文件会让任务死循环到 48h 轮判停整任务 failed。

**已被证实的既有正确设计(本方案不动)**:跨轮续传本身是好的——sweeper 接管复位 importing→pending **保留 bytes_done**(`services/baidu_backup.py:328-337`),multipart 会话按 `list_parts` 续传;读超时 15s ≤ 租约/4(`baidu_client.py:41`);UA=pan.baidu.com 正确(`:35,:429`);dlink 8h TTL+懒刷新正确。**唯一缺的就是"轮内"容错。**

## 1. 目标与非目标

**目标**:
- G1 下载流传输层异常(ReadTimeout/ReadError/WriteError/ConnectionError 等)不再杀整轮 job,进入**文件内重试**;
- G2 流中断重试从**已上传分片边界**续传(Range),不整文件重拉;
- G3 单文件 attempts 超阈值 → 行 failed 熔断跳过,任务继续其余文件,不再有"死循环到 48h"路径;
- G4 全程可观测:每次重试/熔断有日志,熔断行带明确 last_error。

**非目标**:不改任务状态机/租约/sweeper/48h 语义;不做内容级 md5 校验;不做下载并发提速;不动 dlink 生命周期;`rate_limited` 等 HTTP 层错误路径保持现状。

## 2. 现状代码事实(改动点对照表)

| # | 位置 | 现状 | 问题 |
|---|------|------|------|
| F1 | `baidu_client.py:444-491` `stream_download` | `send` 包 `except httpx.HTTPError` → `BaiduApiError`;`aiter_bytes` 裸抛 | 正文读取零容错 |
| F2 | `workers/baidu_backup.py:1379-1404` `_download_parts` | 只捕 `BaiduApiError`(link_expired 分支) | 传输异常穿透 |
| F3 | `workers/baidu_backup.py:871-925` `_import_one_file` 重试循环 | `MAX_FILE_ATTEMPTS=5`(`:121`),except 只认 `_LinkRefreshNeeded/_UploadSessionLost/BaiduTaskError/BaiduApiError` | 传输异常不入循环 |
| F4 | `workers/baidu_backup.py:1347` | `range_header = f"bytes={pos}-" if pos > 0 else None` | Range 续传能力**已存在**,只是没人从"流中断"路径再进来 |
| F5 | `workers/baidu_backup.py:669-673` | attempts 仅认领时 +1,无上限谓词 | 无熔断 |
| F6 | `baidu_client.py:421-423` docstring | 「服务端忽略 Range 返回 200 全量属其自由」 | 续传重试必须处理 200≠206 |
| F7 | `workers/baidu_backup.py:1275-1326` `_resume_or_create_session` | list_parts 为空 → 清零重创;有 parts → pos=已传字节 | 续传锚点已有 |

## 3. 方案设计

### 3.1 改动一:传输层异常定型(`services/baidu_client.py`)

- 新增异常类型 `BaiduTransportError(BaiduApiError)`,构造参数带 `kind`(timeout/reset/…)+ 已读字节数尽力值(可 0,仅日志用)。**继承 `BaiduApiError`** 是关键:让现有「按 errno 分类」的调用方默认把它当可重试未知错误,改动面最小;
- `stream_download` 的正文读取段改为:

```python
try:
    async for chunk in resp.aiter_bytes(chunk_size):
        yield chunk
except httpx.TransportError as e:          # ReadTimeout/ReadError/WriteError/ConnectionError…
    raise BaiduTransportError(kind=type(e).__name__) from e
```

  - 只捕 `httpx.TransportError`(不含 `httpx.HTTPStatusError` 等 HTTP 语义错误,那些已被现有 4xx 分类覆盖);
  - 建连段 `send` 的既有包装保持不变;
  - `baidu_client.py:8` 模块 docstring 补一行:传输层中断以 `BaiduTransportError` 上抛,含语义说明。

### 3.2 改动二:`_download_parts` 流内重试 + Range 续传(`workers/baidu_backup.py:1340-1404`)

把现有「单次流消费」改为**带预算的重试循环**:

```text
stream_retry = 0
while True:
    pos = 当前已 upload 分片边界(现有变量)
    try:
        async for chunk in runner.client.stream_download(dlink, …, range_header=f"bytes={pos}-" if pos>0 else None):
            缓冲 → upload_part → 更新 pos          # 现有逻辑不动
        break                                     # 流自然结束 = 成功
    except BaiduTransportError:
        丢弃未 flush 的缓冲(未 upload 的字节不计入 pos)
        stream_retry += 1
        if stream_retry > settings.baidu_stream_retry_max:      # 默认 3
            raise                                   # 升级到文件级重试循环(改动三的入口)
        await asyncio.sleep(backoff[stream_retry])  # 2s/5s/15s;期间照常走租约续期检查点
        # 重试前按 _LinkRefreshNeeded 语义顺带校验 dlink 新鲜度(过期则先刷新,复用既有 :1395-1403 分支)
```

**边界处理**:
- **Range 被忽略(F6)**:重试请求带 Range 但响应为 200(非 206)时,`stream_download` 需把 `response.status_code` 暴露给调用方(返回值或异常内字段):200 = 服务端全量重发 → 本次不能续拼现有 parts,须**废弃当前 multipart 会话**(abort,走既有 `_resume_or_create_session` 的死会话清零分支 `:1312-1317`)从 0 重拉,计一次 stream_retry。实施时先核对现有跨轮续传路径对 200/206 的处理是否已覆盖,未覆盖则一并补上(同一条坑);
- **退避期间租约**:退避 sleep 用既有的分片退避等待模式(`:460`「每 ≤10s 醒来做一次续期+取消检查」),15s 退避拆成 2×8s 心跳粒度,保证租约不死、cancel_requested 可感知;
- **multipart 会话**:重试间**不**重建会话(只有 Range 被忽略/会话失效才重建),减少孤儿会话产生速率(事件期间已积累 41 个,现有 30d 清理兜底不变);
- **频控顾虑**:重试会多发 dlink 请求;退避上限 15s + 单文件流内 ≤3 次,单文件最多多 3 个请求,远低于 HTTP 层 rate_limited 路径的既有退避强度,可接受。

### 3.3 改动三:attempts 熔断(`workers/baidu_backup.py:662-682 _import_loop`)

- 取行后(现有 `:669-673` 认领 UPDATE 处)增加前置谓词:

```text
若 TaskFile.attempts >= settings.baidu_max_row_attempts(默认 10):
    行置 failed + last_error='attempts_exhausted' + non_retryable 按决策点 D1
    log.warning + 继续 _next_pending_row 取下一行(不杀任务)
```

- 文件级重试循环(`:871-925`)对 `BaiduTransportError` 的处理:与 `BaiduApiError` 未知错误同档——计入 `attempt`,退避复用既有档位;`MAX_FILE_ATTEMPTS=5` 耗尽后走既有 `_fail_row` 路径,`last_error='network_transport'`,**non_retryable=false**(网络类失败不定性为永久,见 D1);
- 熔断与文件级重试的关系:流内 3 次(3.2)→ 升级文件级(3.3 循环,≤5 轮,每轮内又可流内重试)→ 行 failed 可复活 → 行 attempts 认领累计到 10 → 熔断跳过。**最坏路径收敛**:一个真死文件约 15×5=75 次流尝试后让位,任务继续。

### 3.4 配置项(`app/settings.py:131-136` 时延常量组)

| 键 | 默认 | 说明 |
|----|------|------|
| `baidu_stream_retry_max` | 3 | 单次流消费内的传输中断重试上限 |
| `baidu_stream_retry_backoff_s` | "2,5,15" | 重试退避档(逗号串,复用既有配置风格则改三 int,实施时对齐) |
| `baidu_max_row_attempts` | 10 | 行级 attempts 熔断阈值 |

集成测试注入秒级值(对齐 `:137` 既有注释的测试口径);加入 `settings.py:158-160` 的正数校验组。

## 4. 测试功能点

**单测(离线,mock `stream_download`)**:
- T1 流第 1/2/3 次抛 `BaiduTransportError` 后成功 → 文件成功,重试日志 3 条,`bytes_done` 最终= size;
- T2 中断发生在已传 N 字节后 → 重试请求的 Range 起点恰为已 upload 分片边界(断言 range_header 参数);
- T3 流内 3 次耗尽 → 升级文件级循环;文件级 5 轮耗尽 → 行 failed、`last_error='network_transport'`、`non_retryable=false`、任务继续下一行;
- T4 重试响应 200(忽略 Range)→ 废弃会话从 0 重拉,计次;
- T5 attempts=10 的行被认领前熔断:行 failed、`last_error='attempts_exhausted'`、循环取下一行、任务不终态化;
- T6 回归:HTTP 层错误(4xx/5xx/BaiduApiError)分类、`rate_limited` 5 次退避、link_expired 刷新、`_UploadSessionLost` 各路径行为不变;
- T7 退避期间租约续期与 cancel_requested 感知(退避被拆分心跳)。

**集成(隔离栈,容器内)**:
- T8 全量回归 `pytest tests/` 与基线一致(注意 `test_admin_baidu_tasks.py` 顶部的 env 前置惯例);
- T9 kill -9 worker 中途(模拟既有事件)→ sweeper 接管后从断点续传——验证新代码未破坏跨轮续传。

## 5. 部署与回滚

- 纯 `api/app/services/baidu_client.py` + `api/app/workers/baidu_backup.py` + `settings.py` 改动:无迁移、无 FGA、无 .env 变更(新配置全有默认值);
- 生效需 restart **ms-worker**(ms-api 不含改动可不重启;注意部署时机——若 prod 有 running 备份任务,复用「任务终态后执行」的定时模式,或接受一次 10-15min 自愈窗口);
- 回滚:revert commit 重推 + restart,无数据残留(行状态语义不变)。

## 6. 风险与边界

- 重试风暴:双层上限(流内 3 × 文件级 5)+ 退避封顶,最坏单文件 75 次流尝试后熔断,远小于现状"无限轮循环";
- 百度频控:prod 已过审核正式凭证,增量请求量级(每文件 ≤3)不构成风险;dev 测试态频控环境注意观测;
- 孤儿 multipart 会话:重试不重建会话,产生速率反而下降;30d 清理不变;
- `BaiduTransportError` 继承 `BaiduApiError` 的口径:现有按 errno 分类的调用方若对"未知错误"有特殊处理,实施时逐点核对(重点 `:893-920` 的分类循环与 `:921-925` rate_limited 分支),确保新 kind 落"可重试未知"档;
- 观测面:admin 备份任务页已能看 failed_files/last_error(2026-10-14 上线),熔断行天然可见,无需改前端。

## 7. 决策点(待拍板)

| # | 问题 | 建议 |
|---|------|------|
| D1 | 熔断行的 non_retryable 取值 | **false**(网络类失败不定性永久,任务收尾 failed('file_failed') 后用户可用既有 retry-failed 端点复活重跑;true 会让 retry-failed 409,只能 DB 手改,留给确定性错误类别) |
| D2 | 流内重试上限/退避 | 3 次,2/5/15s(保守起步,上线后按观测调) |
| D3 | 行熔断阈值 | 10(覆盖"文件级 5 轮×流内 3 次"约 2 个完整循环,留余量) |
| D4 | 是否顺带做「任务运行中跳过指定文件」端点 | 本次**不做**(熔断已消解死循环;需要时另立小需求,挂 admin 页操作按钮) |

## 8. 工作量估计

后端(三处改动+配置)1 人天;单测 7 例 0.5 人天;隔离栈集成回归 0.5 人天;合计 **~2 人天**。建议走 qdev(方案本文档可先过 qplan 盲审)。

## 9. 关联与遗留

- 事件本身(2026-10-14)已由 sweeper 自愈机制消化,任务最终正常推进,本方案不回溯处理;
- 遗留 multipart 会话 41 个:既有 30d 清理兜底,不专项处理;
- 本方案不覆盖「上传到 MinIO 侧」的传输异常(MinIO 在内网,历史无此故障模式);若未来出现可平移同款设计。
