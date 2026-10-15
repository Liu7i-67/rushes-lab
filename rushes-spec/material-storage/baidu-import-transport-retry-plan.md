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
- G1 下载传输层异常(建连段 ConnectTimeout/ConnectError 与正文读取 ReadTimeout/ReadError/WriteError/CloseError 等 `httpx.TransportError` 家族)不再杀整轮 job,进入**文件内重试**;
- G2 流中断重试从**已上传分片边界**续传(Range),不整文件重拉;
- G3 崩溃-接管循环中同一文件**零进展地**反复被认领(attempts 累计且 bytes_done 停留 0)超阈值 → 行 failed 熔断跳过,任务继续其余文件;传输类死循环已由 G1+文件级重试出局兜住,熔断防的是传输外原因反复杀轮(kill/OOM/未包装罕见异常)的"死循环到 48h",且有进展的跨边界续传不被误伤;
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
| F6 | `baidu_client.py:421-423` docstring;`:476` 状态门 | docstring 明示「服务端忽略 Range 返回 200 全量属其自由」;状态门 200/206 同等放行,状态码对调用方不可见 | 续传重试必须处理 200≠206:pos>0 带 Range 遇 200 会把全量内容错位续拼,现状唯一兜底=落库前 head 尺寸门 failed('size_mismatch')+孤儿对象留清理(`:1524-1532`) |
| F7 | `workers/baidu_backup.py:1275-1326` `_resume_or_create_session` | list_parts 为空 → 清零重创;有 parts → pos=已传字节 | 续传锚点已有 |

## 3. 方案设计

### 3.1 改动一:传输层异常定型(`services/baidu_client.py`)

- 新增异常类型 `BaiduTransportError(BaiduApiError)`;父类 `BaiduApiError` 为 frozen dataclass(`category/message` 必填、`errno/http_status` 带默认),dataclass 继承要求新增字段亦带默认值:

```python
@dataclass(frozen=True)
class BaiduTransportError(BaiduApiError):
    kind: str = "unknown"       # httpx 异常类名(ReadTimeout/ReadError/…),仅日志用
    bytes_read: int = 0         # 已读字节数尽力值(可 0,仅日志用)
```

  **继承 `BaiduApiError`** 是关键:让现有「按 category 分派(errno 仅透传)」的调用方默认把它当可重试未知错误,改动面最小;
- `stream_download` 的正文读取段改为:

```python
read = 0
try:
    async for chunk in resp.aiter_bytes(chunk_size):
        read += len(chunk)
        yield chunk
except httpx.TransportError as e:          # ReadTimeout/ReadError/WriteError/ConnectionError…
    raise BaiduTransportError(
        CATEGORY_UNKNOWN,
        sanitize_message(f"下载流中断:{type(e).__name__}"),
        kind=type(e).__name__,
        bytes_read=read,                    # 本次流消费已读字节(尽力值,仅日志用,勿恒 0)
    ) from e
finally:
    with contextlib.suppress(Exception):    # 坏流上 aclose 可能再抛,防掩盖在途 BaiduTransportError
        await resp.aclose()
```

  message 必须过 `sanitize_message`(httpx 异常文本可能带 URL,token 脱敏口径不变);既有 `finally: await resp.aclose()`(`:490-491`)保留但加 `contextlib.suppress` 包裹(一行防御);
  - 只捕 `httpx.TransportError`(不含 `httpx.HTTPStatusError` 等 HTTP 语义错误,那些已被现有 4xx 分类覆盖);`DecodingError`/`TooManyRedirects` 等罕见 `RequestError` 子类不属 `TransportError`,仍走杀轮交 sweeper(可接受);
  - 建连段 `send` 的包装**收紧一层**:`except httpx.TransportError`(必须列在 `except httpx.HTTPError` 之前,子类先匹配)→ 同样包装为 `BaiduTransportError`;其余 `httpx.HTTPError` 维持既有 `BaiduApiError(CATEGORY_UNKNOWN)` 包装不变——建连失败与读流中断同源(链路抖动常相伴),统一进流内重试+退避+落码分叉,消除「unknown 类无退避、耗尽误标 rate_limited」的残留盲区;
  - `baidu_client.py:8` 模块 docstring 补一行:传输层中断以 `BaiduTransportError` 上抛,含语义说明与捕获范围(TransportError 之外的 RequestError 不包装);另注明取舍:`TransportError` 家族含 `UnsupportedProtocol` 等确定性错误(如 302 Location 带非 http scheme——宿主白名单只校验 host 不校验 scheme,`:458-465`),会被当可重试走满预算后 failed('network_transport'):有界、仅失败标签可能误导,接受。

### 3.2 改动二:`_download_parts` 流内重试 + Range 续传(`workers/baidu_backup.py:1340-1404`)

把现有「单次流消费」改为**带预算的重试循环**:

```text
stream_retry = 0
while True:
    pos = 当前已 upload 分片边界(现有变量)
    if pos >= size:                                 # 卫语句:全部分片已传(如 size%part==0 且中断在"末片已刷、等 EOF"窗口)
        break                                       # 直接落收尾(_flush(final=True) 空转 → complete),勿发 bytes={size}- 越界 Range(416→unknown→耗尽误标);亦修复既有跨轮路径同款边界(接管时恰已传完全部分片)
    try:
        async for chunk in runner.client.stream_download(dlink, …, range_header=f"bytes={pos}-" if pos>0 else None):
            缓冲 → upload_part → 更新 pos          # 现有逻辑不动
        break                                     # 流自然结束 = 成功
    except BaiduRangeIgnored:                      # Range 被忽略,机制见下「边界处理」
        log.warning(task/file/range_ignored/pos/stream_retry)
        stream_retry += 1
        if stream_retry > settings.baidu_stream_retry_max:      # 与 transport 分支对称的预算校验,勿漏
            if not collected:                                    # 当前会话为空(重建后 0 parts):raise 前先 abort,
                try: await store.abort_multipart_upload(bucket, key, upload_id)   # 防既有空-parts 清零路径(:1296→:1313,不 abort)留永久孤儿
                except Exception: log.warning(task/file/bucket/key/upload_id, 孤儿交 bucket lifecycle)  # 同款容错与日志口径
            raise                                   # 升级到文件级重试循环(全量重拉昂贵,同样受预算约束)
        slp = await _sharded_backoff(db, runner, backoff[min(stream_retry, len(backoff)) - 1])   # 同款退避档
        if slp is not None:
            return 中止(检查点结果)                 # lost/cancel 时仅停写:不 abort 不清三元组不再写(所有权已失,留待下次认领经 _resume_or_create_session 收敛),与 transport 分支对称
        try: await store.abort_multipart_upload(bucket, key, upload_id)
        except Exception: log.warning(task/file/bucket/key/upload_id, 孤儿交 bucket lifecycle 兜底)   # 30d sweeper 只扫 DB 引用行;字段齐备供 ops 对账,见「实现约束」
        清三元组/bytes_done=0(复用 :1312-1317 死会话清零语句)且同步内存 row.minio_upload_id=None(防御式显式置空,见「实现约束」②)
        parts, upload_id, offset, next_part = await _resume_or_create_session(..., content_type=...)  # 必走重创分支;content_type 需下传(现 _download_parts 签名没有,:1329-1333)
        collected/pos/next_part/pending 全量按实际返回值重置   # _flush 闭包捕获+缓冲残留,必须同步清;以返回值为准,勿按假定值
        continue
    except BaiduTransportError:
        log.warning(task/file/kind/pos/stream_retry)
        pending.clear()                             # 显式清空中断前缓冲:残留 [pos,pos+k) 字节会与新流从 pos 重发的字节错位续拼(仅靠 size 门兜成白拉+错尺寸孤儿);会话保留,collected/next_part/upload_id/pos 不动
        stream_retry += 1
        if stream_retry > settings.baidu_stream_retry_max:      # 默认 3
            if not collected:                                    # 与 RangeIgnored 分支对称:空会话(0 parts,本次事件真实形态=降速下
                try: await store.abort_multipart_upload(bucket, key, upload_id)   # 首片未攒满即超时)raise 前先 abort,
                except Exception: log.warning(task/file/bucket/key/upload_id, 孤儿交 bucket lifecycle)  # 防空-parts 清零路径(:1296→:1313,不 abort)留永久孤儿;口径对齐 _abort_sessions_async
            raise                                   # 升级到文件级重试循环(改动三的入口);collected 非空时勿 abort(保留跨轮续传价值)
        backoff_s = backoff[min(stream_retry, len(backoff)) - 1]    # 首次重试取档 0(2s);索引钳位末档,防越界
        slp = await _sharded_backoff(db, runner, backoff_s)     # 2s/5s/15s;既有 10s 分片心跳(每片醒来续租约+查取消)
        if slp is not None:
            return 中止(检查点结果)                 # 退避中检查点要求中止,交上层消费
```

**实现约束(踩坑高发,逐条钉死)**:
- **except 顺序**:两个新异常都继承 `BaiduApiError`,专属 except 子句必须列在既有 `except BaiduApiError`(`:1395` 流内 / `:905` 文件级)**之前**,否则 Python 按序匹配先落通用分支(流内 `raise` 穿透/文件级 `_handle_baidu_error` 当未知错误),整个重试循环成为死代码;
- **upload_id 回传**:`_DownloadResult`(`:1264-1272`)现有四字段无 `upload_id`——RangeIgnored 重建会话后必须把新 upload_id 回传调用方(增字段回填),`_transfer_and_finalize` 的 complete(`:1493`)改用 `dl.upload_id`;否则调用方局部旧 upload_id 对已 abort 会话 complete → NoSuchUpload → `_UploadSessionLost` 白烧一次文件级 attempt,恢复路径不确定;
- **RangeIgnored 会话复位必须整体,复位后显式同步内存**:①`_flush` 闭包捕获 `upload_id/next_part/collected`,`pending` 缓冲(`:1344`)残留旧偏移字节——复位清单=`collected/next_part/upload_id/pos/pending` 五件套,一律以 `_resume_or_create_session` **实际返回值**为准(勿按假定 `([],0,1)` 写死);卫语句与预算校验用的 `size` 取 `row.source_size`(形参 `row` 已有,无需改签名);②清零 UPDATE 后**显式置 `row.minio_upload_id=None`**——论据中性化:`_SYNC_OFF`(services/baidu_backup.py:52-58)是 services 层「UPDATE 后读对象须显式 refresh/重查」约定,worker 层裸 UPDATE 的实际回填/过期行为随 SQLAlchemy 版本与语句形态而变(services 注记还实证过 onupdate 列触发 expire 的 prod 500),显式置 None 不依赖任何具体同步口径、杜绝 abort 失败时 `_resume_or_create_session`(`:1285` 按内存值分支)读到旧值命中存活旧会话返回 offset>0、与从 0 重拉语义冲突的风险;③abort 失败的孤儿会话已无 DB 引用,**30d sweeper 扫不到**(`:1713-1731` 只扫终态任务且 `minio_upload_id` 非空),兜底=bucket lifecycle(未配 lifecycle 则永存,量级同事件期间 41 个,可接受);④`baidu_client.py` 需补 `contextlib` 导入;
- **日志点(G4 落地)**:流内重试与 RangeIgnored 各一条 `log.warning`(字段:task/file/kind 或 range_ignored/pos/stream_retry),T1 的「重试日志 3 条」以此为断言来源;
- **备选简化形态**:亦可复用 `_UploadSessionLost` 先例——RangeIgnored 分支只做 abort+清三元组后抛内部信号,交 `_transfer_and_finalize`(`content_type` 已在 `:1418` 作用域)重走 `_resume_or_create_session` 再进 `_download_parts`,可同时省去 `_DownloadResult` 加字段与 content_type 下传两处签名改动;**注意该形态下 stream_retry 预算须上移至 `_transfer_and_finalize`(或作参传入)**,防每次重进都从 0 计数使「单次文件级尝试 ≤3 次重试」失真;**且落码/退避须同步钉死**——若直接复用 `_UploadSessionLost` 信号,既有处理(`:896-902`)是无退避+耗尽落 rate_limited,切换形态时须一并改造,两形态并非无条件语义等价;本方案默认按上文细化形态实施,实施时若签名波及面大可切换。

**边界处理**:
- **Range 被忽略(F6,机制定案)**:`stream_download` 状态门(`:476`)收紧——`range_header` 非空且响应 200(非 206)时抛新异常 `BaiduRangeIgnored(BaiduApiError)`(category=unknown,沿用既有 4xx 分类风格;**raise 前先 `await resp.aclose()`**,对齐现状非 200/206 分支 `:478` 口径);不带 Range 的请求 200 照常放行;**顺手收零错位面**:206 应答解析 Content-Range 起点与请求起点不一致时同样抛 `BaiduRangeIgnored`(一行解析成本,把"病态服务端恰好回显正确总长"的残余错位面收敛为零,尺寸门不再兜底;**206 无 Content-Range 或格式不可解析 → 放行**(维持现状行为,勿把解析失败当异常抛),仅 start 可解析且 ≠ 请求起点才抛)。`_download_parts` 捕获后废弃当前 multipart 会话从 0 重拉(计一次 stream_retry);**漏捕(实现错误,指连文件级专属子句也缺失的纯 except 顺序事故态)不会自愈**——会话未 abort,list_parts 续传起点不变,RangeIgnored 每轮复现,空耗文件级 5 轮后 failed('rate_limited',到不了 complete、无 size 门参与;「错位续拼+落库前 size 门 `:1524-1532` 拦截」只发生在现状无拦截的 200 场景);若文件级专属子句在位(§3.3 已钉死其行为),则按 network_transport 落码、不落此事故态——except 顺序约束仍是唯一正确路径,T4b 以断言钉住。**该拦截落在 `stream_download` 单点,既有跨轮续传路径(sweeper 接管 pos>0 重进)自动同享防护——已核实现状未覆盖(200/206 同等放行,唯一兜底=落库前 size_mismatch 门),此项属本方案范围内确定工作项,非可选核对**;
- **dlink 复用**:流内重试复用同一 dlink(8h TTL,单文件传输窗口远短于它),不做额外新鲜度校验;若重试请求恰逢 dlink 过期,按既有 link_expired 分支(`:1395-1403`)清缓存抛 `_LinkRefreshNeeded` 退出到文件级重取,不在流内刷新(避免每次重试多一个 filemetas 请求,保住下面的频控估算);**`pos >= size` 卫语句的病态角落注记**:源实际字节 > `source_size`(百度元数据失真)且中断恰落 pos==size 时,新方案静默 complete 出截断对象且 size 门恰好放行(现状则 loud failed)——窗口极窄(source_size 为权威元数据),接受此取舍;
- **退避期间租约**:统一走既有 `_sharded_backoff`(`SLEEP_SHARD_S=10s` 分片,每片醒来 checkpoint 续租约+感知 cancel),不自造新心跳;
- **multipart 会话**:重试间**不**重建会话(只有 Range 被忽略/会话失效才重建),减少孤儿会话产生速率(事件期间已积累 41 个,现有 30d 清理兜底不变);
- **频控顾虑**:重试会多发 dlink 下载请求;退避上限 15s + 单次文件级尝试 ≤3 次重试 GET(RangeIgnored 全量重拉同计该预算,两类异常共享 stream_retry 计数),单次认领全部耗尽 ≤20 次流消费,远低于 HTTP 层 rate_limited 路径的既有退避强度,可接受。

### 3.3 改动三:attempts 熔断(`workers/baidu_backup.py:662-682 _import_loop`)

- 取行后、认领 UPDATE(`:669-673`)之前增加前置谓词(**零进展豁免**:attempts 达阈值但 `row.bytes_done > 0` 的行不熔断、正常认领——跨接力边界续传的大文件每轮有进展,不该被熔;本次事件形态恰是每轮从 0 重拉、bytes_done=0);落码直接复用 `_fail_row`(自带所有权谓词+聚合重算+commit+日志,勿裸 UPDATE 漏收口):

```text
若 TaskFile.attempts >= settings.baidu_max_row_attempts(默认 10) 且 row.bytes_done == 0:
    res = _fail_row(code='attempts_exhausted', message='认领次数超上限且无进展', non_retryable=按 D1)
    → last_error 实际落 "attempts_exhausted: 认领次数超上限且无进展"(:698-700 结构化前缀约定)
    res == "lost"(所有权已失)则向上传播;仅 "ok" 才继续 _next_pending_row 取下一行(不杀任务)
```

- 文件级重试循环(`:871-925`)对 `BaiduTransportError` 的处理:计入 `attempt` 并退避——**新增**与 rate_limited 分支同款退避(`min(2**attempt, FILE_BACKOFF_CAP_S)` 走 `_sharded_backoff`;注意现状未知类 BaiduApiError 无退避,此处是补齐而非"复用既有档位");`MAX_FILE_ATTEMPTS=5` 耗尽后走既有 `_fail_row` 路径,**落码按循环末次错误类别分叉**:transport → `last_error` 落 `"network_transport: 传输中断重试耗尽"`(经 `_fail_row` 带 message,与 T3 前缀断言对齐)、`non_retryable=false`(网络类失败不定性为永久,见 D1);`BaiduRangeIgnored` 到达文件级有两种来源——①流内预算耗尽的**正常升级**(服务端持续忽略 Range,§3.2 设计路径)、②纯泄漏事故态;两者行为同一:`log.warning` + 与 transport 同档计入 attempt 退避,**耗尽落码同 transport 落 `network_transport`**,钉死不留自由发挥空间;其余类别(含 `_LinkRefreshNeeded` 连续 5 次刷新、unknown 类 BaiduApiError)耗尽 → 保持现状 rate_limited 文案不变,分叉仅 transport/RangeIgnored 一族新增;rate_limited → 保持既有 'rate_limited' 文案(现状兜底硬编码 rate_limited,`:921-925`,不分叉会把网络失败误标为限速);
- 熔断与文件级重试的关系(按代码真实机制):`attempts` 是**认领计数**(importing 认领 +1),文件级 5 轮发生在同一次认领内,耗尽后行 failed 出局(pending-only 选取不再选中);行复活端点(retry-failed/单行/随机后缀)一律 attempts 归零——因此熔断的真实防御对象是**崩溃-接管循环**:job 因传输外原因反复死亡(kill -9/OOM/未包装罕见异常),同队头文件每次崩溃时恰处于 importing → sweeper 复位(保留 attempts)→ 再认领 +1,即本次 prod 事件的形态。传输类确定性死文件不需要熔断兜底:G1 后它们在单次认领的文件级 5 轮内 failed 出局。
- **最坏路径收敛(三条)**:①传输死文件:单次认领 ≤ 5×(1+3)=20 次流消费即 failed 出局,任务继续;②零进展崩溃循环(每轮 bytes_done 停留 0,即事件形态):同文件累计 10 次认领熔断跳行,任务继续;③有进展的跨边界续传(接力/接管后 bytes_done>0):不受熔断影响,靠进展自然收敛——均远好于现状"无限轮循环到 48h 判停整任务"。残余:同偏移 >0 停滞的崩溃循环(bytes_done 停在非 0 值)不受熔断保护——G1 后传输错误已不杀轮,该形态仅剩 job 级反复死亡(kill/OOM)才可维持,由 48h 轮判停兜底,概率与代价可接受。

### 3.4 配置项(`app/settings.py:131-136` 时延常量组)

| 键 | 默认 | 说明 |
|----|------|------|
| `baidu_stream_retry_max` | 3 | 单次**文件级尝试**内(跨 1+N 次流消费共享)的传输中断 + Range 被忽略**共享的**重试上限 |
| `baidu_stream_retry_backoff_s` | "2,5,15" | 重试退避档(逗号分隔正整数串;档位不足 retry_max 时以最后一档延续) |
| `baidu_max_row_attempts` | 10 | 行级 attempts 熔断阈值 |

解析与校验闭环:逗号串在 settings 有先例(`cors_allow_origins`,`:69-72`,str+逗号分隔),沿用同款;`validate_baidu_settings()` 增校验——退避串非空、逐项正整数、`baidu_stream_retry_max ≥ 1`、`baidu_max_row_attempts ≥ 1`(并入 `:158-160` 正数校验组);**校验调用补到 workers/main.py 启动钩子**(现状 `validate_baidu_settings` 仅 api lifespan 调用 `main.py:64`,worker 进程不跑校验——本方案部署形态恰是 worker-only 重启,不补则非法配置带病运行到首次使用才炸;`WorkerSettings`(`:664-678`)现状无任何启动钩子,需新增 arq 标准 `on_startup` 协程字段;worker 的 settings 单例在模块导入期已实例化(`:634-645`),校验放 on_startup 时点晚于 import、早于首 job,满足「不带病运行」意图);退避档解析为 0 基序列,**索引一律钳位末档**(`backoff[min(n, len)-1]`,len ≥ 1 即合法,档位不足时自然延续末档);**单测与集成测试均注入秒级值**(对齐 `:131` 时延组注释的测试口径;`_sharded_backoff` 是实 sleep,离线单测勿吃 2/5/15s 真档位)。

## 4. 测试功能点

**单测(离线,mock `stream_download`)**:
- T1 流第 1/2/3 次抛 `BaiduTransportError` 后成功 → 文件成功,重试日志 3 条,`bytes_done` 最终= size;
- T2 中断发生在已传 N 字节后 → 重试请求的 Range 起点恰为已 upload 分片边界(断言 range_header 参数,载体=`download_calls`),且重试后首片**不含中断前缓冲字节**(断言载体=upload_part 收到的 body 序列或 MinIO 侧 parts 内容,`download_calls` 只记 (fs_id, range_start) 不够用;pending 已显式清空,防错位续拼;**注入小 `baidu_part_size_bytes`** 对齐 `:131` 测试口径,免为攒满 16MiB 首片造大文件);**边界子用例**:size%part==0 且中断发生在全部整分片已上传后(pos==size)→ 不发越界 Range(`download_calls` 断言无 `bytes={size}-`)、直接 complete 成功;
- T3 流内 3 次耗尽 → 升级文件级循环;文件级 5 轮耗尽 → 行 failed、`last_error` 以 `network_transport: ` 为前缀(对齐 `_fail_row` "<code>: <message>" 结构化前缀,`:698-700`)、`non_retryable=false`、任务继续下一行;**种子须含其他 pending 行**(同 T5 理由,防任务被终态化使断言失真);
- T4(client 层,httpx MockTransport):带 Range 请求响应 200 → `stream_download` 抛 `BaiduRangeIgnored`;不带 Range 的 200 照常放行;**206 Content-Range 起点与请求起点不一致 → 同样抛 `BaiduRangeIgnored`;206 无 Content-Range 或不可解析 → 放行**(新增解析代码最易 off-by-one/误抛处,两子行为各一条用例);建连段/正文读抛 `httpx.TransportError` → `BaiduTransportError`(send 段收紧后建连类同样覆盖);
- T4b(worker 层,fake client 注入):`BaiduRangeIgnored` 经 fail_first 队列注入 → 流内废弃会话从 0 重拉并计次,且 **complete 使用重建后的 upload_id**(`_DownloadResult` 回传);**RangeIgnored 连续触发至流内预算耗尽 → 升级文件级**(与 transport 分支对称)且**文件级耗尽落 `network_transport`**;**RangeIgnored 退避中注入 cancel → 仅停写**(不 abort 不清三元组不再写库,行为 cancelled);**except 顺序回归哨兵**(专属子句先于 `BaiduApiError`,漏捕=空耗 5 轮);跨轮接管场景 worker 层只断言「接管后重进注入 RangeIgnored → abort+清三元组+从 0 重拉(download_calls 起点 0)」,「200→RangeIgnored 拦截」语义归 T4(MockTransport 层,桩不建模状态码);
- T5 attempts=10 且 bytes_done=0 的行被认领前熔断:行 failed、`last_error` 以 `attempts_exhausted: ` 为前缀、循环取下一行、任务不终态化;**反例断言**:attempts≥10 但 bytes_done>0 的行不熔断、正常认领(零进展豁免,§3.3);**前置说明**:attempts=10 用种子数据直插构造——自然累计路径需长窗口(崩溃-接管循环 / 55min 接力边界跨 ~9h),单测不便自然到达;**种子须含其他 pending 行**(若熔断行是任务唯一行,熔断后 `_next_pending_row` 返回 None,`aggregate_and_finalize_if_done` 会把任务落 failed,"任务不终态化"断言即失真);
- T6 回归:HTTP 层错误(4xx/5xx/BaiduApiError)分类、`rate_limited` 5 次退避、link_expired 刷新、`_UploadSessionLost` 各路径行为不变;
- T7 退避期间租约续期与 cancel_requested 感知(退避走 `_sharded_backoff` 10s 分片心跳);
- T10 配置校验与解析直测:非法退避串(空/非整数/零值)/`retry_max<1`/`max_row_attempts<1` 启动断言 raise;逗号串解析为 0 基序列+末档钳位(`backoff[min(n,len)-1]`)的纯函数用例。

**桩同步**:worker 层测试桩(如 `test_baidu_integration.py:694-716` 的 fake,按 Range 起点截取返回、天然不触发 RangeIgnored)**无需复刻 client 判断逻辑**,支持两类注入即可——①经 `fail_first` 队列抛新异常类型(流前抛,T4b 用);②**新增「按字节数中途失败」注入**(如 `fail_after_bytes[fs_id]`:产出足够字节触发 ≥1 次 `_flush` 上传后抛 `BaiduTransportError`,T1/T2 的"中断发生在已传 N 字节后"依赖此模式,现有 fail_first 做不到);client 层新契约(Range+200 → `BaiduRangeIgnored`;建连/正文 TransportError → `BaiduTransportError`)由 T4 的 httpx MockTransport 单测覆盖。

**集成(隔离栈,容器内)**:
- T8 全量回归 `pytest tests/` 与基线一致(注意 `test_admin_baidu_tasks.py` 顶部的 env 前置惯例);
- T9 kill -9 worker 中途(模拟既有事件)→ sweeper 接管后从断点续传——验证新代码未破坏跨轮续传。

## 5. 部署与回滚

- 纯 `api/app/services/baidu_client.py` + `api/app/workers/baidu_backup.py` + `api/app/workers/main.py`(§3.4 校验钩子) + `settings.py` 改动:无迁移、无 FGA、无 .env 变更(新配置全有默认值);
- 生效需 restart **ms-worker**(改动文件虽同时被 ms-api 导入——`baidu_client` 在 api lifespan 实例化,统一构建时 api 容器代码同步更新——但行为仅 worker 侧变化,ms-api 不重启亦无妨,重启亦无害;注意部署时机——若 prod 有 running 备份任务,复用「任务终态后执行」的定时模式,或接受一次 10-15min 自愈窗口);
- 回滚:revert commit 重推 + restart,无数据残留(行状态语义不变)。

## 6. 风险与边界

- 重试风暴:双层上限(流内 3 × 文件级 5,RangeIgnored 全量重拉同计流内预算)+ 退避封顶——传输死文件单次认领 ≤20 次流消费即 failed 出局,零进展崩溃循环 10 次认领熔断封顶,均远小于现状"无限轮循环到 48h";
- RangeIgnored 带宽放大:服务端持续忽略 Range × 传输抖动叠加时,最坏 ≤4 次全量拉取/文件级尝试 × 5 ≈ ≤20 次/认领(与流消费预算同口径),GB 级文件带宽可观(频次有界、带宽是主要代价);可选省流变体=本文件首次 RangeIgnored 后,后续重试请求不再带 Range(避免确定性忽略场景反复 200→重拉),实施时按观测决定是否引入;
- attempts 口径为认领计数,天然有假阳性面(55min 接力边界同样复位在途行 +1,劣化期 0.08MiB/s 参照下 55min≈264MB,**无豁免时 >~2.6GB 单文件必然撞阈值**,量级推演见 D3)——已由 §3.3「bytes_done==0 才熔断」**零进展豁免**消解:跨界续传的大文件 bytes_done>0 不熔断,本次事件形态(每轮从 0 重拉)才触发;残余=同偏移 >0 停滞的崩溃循环不受熔断保护(仅剩 job 级反复死亡可维持,48h 判停兜底,见 §3.3);D1 的 non_retryable=false + retry-failed 归零为最后自愈通道;
- RangeIgnored/死会话清零 `bytes_done=0` 不回冲任务级 done_bytes,与既有死会话清零路径(`:1313-1317`)同口径、由 `recompute_aggregates` 收口;差异仅触发频次上限增加(现状每文件级尝试至多 1 次、认领内至多 5 次,RangeIgnored 受流内预算约束可在单次文件级尝试内多次),大文件场景 done_bytes/ETA 虚高窗口相应变大,属已知观测面偏差;
- 百度频控:prod 已过审核正式凭证,增量请求量级(单次文件级尝试 ≤3 个重试 GET、单次认领 ≤20 次流消费)不构成风险;dev 测试态频控环境注意观测;
- 孤儿 multipart 会话:transport 重试**不重建**会话(产生速率下降);RangeIgnored 路径按流内预算重建——服务端持续忽略 Range 的最坏场景,预算耗尽 raise 前已对空会话补 abort(§3.2 伪代码),残余仅 abort 本身失败的一档(交 bucket lifecycle;30d sweeper 只扫 DB 引用行)。既有空-parts 清零不 abort 的泄漏机制(现状 create 后首片前崩溃即触发)维持原状;
- `BaiduTransportError`/`BaiduRangeIgnored` 继承 `BaiduApiError` 的口径:现有调用方按 `category` 分派(errno 仅透传),两者均落"可重试未知"档;实施时逐点核对 `:893-920` 分类循环与 `:921-925` rate_limited 分支(后者已由 §3.3 落码分叉覆盖);`DecodingError`/`TooManyRedirects` 等非 TransportError 的罕见异常仍在杀轮死角(交 sweeper,可接受);
- 建连段(ConnectTimeout/ConnectError 等)已随 §3.1 send 段收紧进 `BaiduTransportError`,不再落「unknown 无退避+耗尽误标 rate_limited」旧路径(该路径对非下载接口仍存在,见 §9 遗留);
- 观测面:admin 备份任务页已能看 failed_files/last_error(2026-10-14 随 liuqi 6368962 合并+prod 发版上线,scripts/changelog.md 同日条目可溯),熔断行天然可见,无需改前端。

## 7. 决策点(待拍板)

| # | 问题 | 建议 |
|---|------|------|
| D1 | 熔断行的 non_retryable 取值 | **false**(网络/崩溃类失败不定性永久,任务收尾后用户可用既有 retry-failed 端点复活重跑且 attempts 归零;true 会让 retry-failed 409,只能 DB 手改,留给确定性错误类别;亦是 §6 attempts 假阳性面的自愈通道) |
| D2 | 流内重试上限/退避 | 3 次,2/5/15s(保守起步,上线后按观测调) |
| D3 | 行熔断阈值与豁免 | **10 + 「bytes_done==0 才熔断」零进展豁免**(无迁移:阈值锚定本次事件 9 轮量级+1 余量;豁免消解接力边界假阳性——无豁免时劣化期(0.08MiB/s,55min≈264MB)>~2.6GB 视频素材必然误熔断需人工复活,有豁免时跨界续传 bytes_done>0 不熔、事件形态(每轮 0 重拉)才触发;较「上次认领以来无进展」方案免加列免改复位口径)。残余注记:①同偏移 >0 停滞的崩溃循环不受熔断保护(48h 判停兜底,§3.3);②overwrite 行的清除-再导入(purge 链)发生在会话创建前、bytes_done 恒 0,接力边界连续 10 次恰落该阶段会误熔断(需 55min 边界连续命中非传输阶段,概率极低,注记备查);③死会话清零会把 bytes_done 归 0 而 attempts 持续累计——会话被外力反复清掉(如 MinIO lifecycle)且**每轮都中断在(重建后的)首片 flush 前**的文件,会在认领边界恒呈 bytes_done=0,10 次后熔断(确属卡死文件,non_retryable=false 可复活,行为可接受)。若拍板不要豁免,须接受误熔断并配 ops 预案 |
| D4 | 是否顺带做「任务运行中跳过指定文件」端点 | 本次**不做**(熔断已消解死循环;需要时另立小需求,挂 admin 页操作按钮) |

## 8. 工作量估计

后端(三处改动+配置)1 人天;单测 9 例(T1-T7+T4b+T10)0.5 人天;隔离栈集成回归 0.5 人天;合计 **~2 人天**。建议走 qdev(方案本文档可先过 qplan 盲审)。

## 9. 关联与遗留

- 事件本身(2026-10-14)已由 sweeper 自愈机制消化,任务最终正常推进,本方案不回溯处理;
- 遗留 multipart 会话 41 个:既有 30d 清理兜底,不专项处理;
- 枚举期与导入期 dlink/filemetas 等非流式接口的网络抖动不在本方案范围:现状网络错误归 unknown(`baidu_client.py:364-369`),枚举期 worker 侧非 rate_limited/auth 类直接 `enum_failed` 任务级 failed(不循环、需人工复活),导入期 `_ensure_dlink` 阶段同样无退避、耗尽误标 rate_limited(`:879-925`,有界:5 次后行 failed 任务继续);如抖动高发于这些阶段,可平移同款包装(非流式 get 的异常已在 `except httpx.HTTPError` 覆盖内,只是分类粒度问题);
- 本方案不覆盖「上传到 MinIO 侧」的传输异常(MinIO 在内网,历史无此故障模式);若未来出现可平移同款设计。
