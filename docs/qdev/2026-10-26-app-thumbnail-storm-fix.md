# App 缩略图加载风暴修复（app-thumbnail-storm-fix）

日期：2026-10-26 · 实施分支：`feat/app-thumb-storm-fix`（自 liuqi 切出） · 范围：`material-storage/api/`（新增 1 端点）+ `material-storage/app/`（core + features）· web 不动

## 背景与根因（2026-10-25 真机日志调研结论）

安卓真机进入 1000+ 文件文件夹快速下滑：后面图片长时间加载不出，点预览弹全局报错页。日志显示同一秒 5 条 `GET /assets/{id}/thumbnail-url` 的 DioException connectionTimeout（15s）。根因链：

1. **请求风暴**：宫格每格在 initState 发「1 次签名 API（dio）+ 1 次缩略图字节下载（独立静态 HttpClient）」，无全局并发上限、离屏不取消（`thumbnail_image.dart:61` 注释明确「无需 cancel」）；列表 200 条/页（`assets_page.dart:45`），快速滚过 1000+ 格 = 十几秒内数百并发请求、约 100-250MB 流量。
2. **单一通道饱和**：API 与缩略图字节同 vhost 同源（`api/app/routers/assets.py:2090` 注释），全部挤 `bucket.taoxiplan.com` → 跳板机 nginx 443 → ssh 隧道一条通道；新建 TCP/TLS 握手排队 >15s → connectTimeout 风暴（已建立的 keep-alive 连接同期仍秒回 200，服务端健康、端点本身极轻：认证 + 主键 get + 本地 HMAC）。
3. **报错页误弹**：全局报错页把任何主 dio 传输层异常当「系统级错误」跳 `/error-report`（`error_report_controller.dart:87-106`）；缩略图签名请求未打 `noErrorReport` 标记（banner/notifications 轮询已有先例），后台缩略图超时直接弹整页报错。
4. **预览放大闪空**：G2 特性（`preview_media.dart`）捏合/双击 >1.5x 签 `download-link` 原图、`AnimatedSwitcher` 200ms fade 替换，但 `Image.network` 无 loadingBuilder，原图首帧到达前是空白——用户实测「放大着放大着图没了」。

## 决策记录

| # | 模糊点 | 决策 | 说明 |
|---|---|---|---|
| D1 | 并发治理形态 | **字节侧：全局并发闸（上限 6）+ 订阅句柄式取消（最后订阅者离开即终止任务，不分排队/运行态）+ 任务硬超时。签名侧：`ThumbnailCache` 内签名并发闸（上限 6 FIFO，槽内 20s race 超时即放槽 + `abandonAwait` 放弃链）**，不做显式优先级队列 | 签名与字节是两条通道（dio / 静态 HttpClient），只闸字节侧签名风暴仍在。签名闸保证**新发起**单发签名 ≤6 并发（底层悬挂签名不强杀、10min 自愈，见 W2 #11），配合 D3 批量预热把签名量降到「2 批/页 + 冷窗口限流单发」，含 D8 旧后端退化窗口也全程限流。字节侧终止语义统一：排队态撤销；运行态按 D7 分阶段断流、置 `isCancelled`、取消 watchdog、释放名额——名额恒归可见格子，等价免费视口优先。代价=快速滚过时部分下载作废（滚回重下，签名已落缓存不浪费） |
| D2 | 后台缩略图请求报错口径 | **签名请求（单发+批量）一律打 `noErrorReport` extra**；管线放弃等待/abort 后的底层 future 异常一律在管线内吞掉；`prewarmThumbUrls` async + 最外层 catch（`session.api == null` 等同步异常也兜） | 失败只落格内降级色块；未处理异步异常会经 `onSystemError` 把报错页从另一条路弹回来，必须全线 swallow。真断网时列表/预览/**原图/视频 inline 等关键请求**（`downloadLink`，未打标记）仍会弹报错页，信号不丢 |
| D3 | 降低签名请求数的形态 | **新增批量签名端点，宫格页列表数据落地后按页批量预热 URL**；不做 list 响应内联 URL | 批量端点纯新增零破坏；对 web 开放但 web 本批不接入（浏览器同 host 6 连接天然限流）。预热只签 URL 不预下载字节。预期签名量：每页 ≤2 批批量 + 冷窗口单发（**新发起经闸 ≤6 并发；race 放槽后的底层悬挂签名不计入该口径**，10min 自愈，与 W2 #11/验收 1 同一口径），与总格数无关 |
| D4 | 预览放大是否换原图 | **有缩略图的图片资产，放大永不自动换原图**（用户拍板 2026-10-26） | 保持缩略图（1024px）恒显；**无缩略图资产维持原图 inline（`Image.network`）分支不变**；heic/svg 等恒缩略图分支不变。G2 链路整体删除（含 `AnimatedSwitcher`），需要高质量原图走「下载」按钮既有链路 |
| D5 | 连接池参数 | **缩略图字节下载的静态 HttpClient 不设 `maxConnectionsPerHost`（维持现状）——并发治理唯一归口管线闸（6）**；主 dio 不设 | 曾考虑「池=6 硬限兜底」，但 SDK 实证该组合在取消场景反噬：建连期取消的任务不可断、`_connecting` 继续占池预算（≤15s connectionTimeout 才消亡），此时新任务（管线名额已释放）的 `getUrl` 会停在 `_pending` 队列——**该队列无计时器、不吃 connectionTimeout**（`http_impl.dart:2666-2677/2703-2710`），只能等管线 20s watchdog 兜底落色块，恰在「建连慢」的目标病理场景下批量误伤新可见格。不设池限时并发上界=在跑任务 6 + 建连期僵尸数（瞬时、≤15s 自愈），可控且无 `_pending` 死等 |
| D6 | 预览缩略图数据源 | **预览进入先读磁盘缓存命中 `Image.memory`；未命中经共享取字节入口（`core/thumb_fetch.dart`，走管线，与宫格/胶片条共享订阅去重）拿字节并写盘**，缩略图路径 `Image.network` 退场 | 现状预览只取 URL 经 `Image.network` 重下（Flutter 内置 HttpClient，不受闸/池约束的第二条通道，横切 N 张=N 个无闸签名、悬挂可到 dio 10min）。统一入口后受闸/超时/abort 治理，字节落盘下次秒出 |
| D7 | 超时/取消打断范围（分阶段写死） | **池排队/建连期**：无 request 对象不可主动断，靠 15s connectionTimeout 兜底，管线终止仅释放名额+置 `isCancelled`；**`getUrl` 返回后（连接已建）发现已取消 → 立即 `req.abort()`**（晚注册立即触发规则覆盖此点，防占用池连接后才丢弃）；**TTFB/响应头期**：`req.abort()` 有效（仅 `_responseCompleter` 未完成时销毁连接，`http_impl.dart:1702-1709`）；**响应体期**：`subscription.cancel()` 触发 `onCancel` 关闭连接（`http_parser.dart:1264-1270`），取消同时以异常完成下载 completer——`await for` 拿不到 subscription，下载必须改显式 `resp.listen`。签名不强杀（不加 CancelToken，防破坏十余处测试 fake），靠 `abandonAwait` 放弃等待 + 根 future swallow（W2 #11）+ `isCancelled` 短路后续 | dart:io 语义精确化：`abort()` 对响应头已到的连接是空操作（`http.dart:1877`）；「连接即时归还」仅对 TTFB/body 期成立，建连期最坏等 15s |
| D8 | 发布顺序 | **API 先行部署，App 后发版** | 新 App + 旧后端：预热 404 静默 + 单发兜底（经 D1 签名闸限流，退化窗口也不风暴） |
| D9 | 入口层（跳板机 nginx/隧道） | **不在本批**，记遗留核查项 | 客户端治理先行 |
| D10 | `preview_media.dart` 300 行硬顶 | **默认 b（本方案推荐），派发前向用户确认一次，否决则改 a**：a) 历史债务豁免（本批净减 ~20 行，674→~654，需用户明确接受违规——仓库先例 `2026-10-23-app-ink-gold-ui.md:338-342` 定的是「超限文件先拆再改」，仅 2 处颜色替换才豁免，本批改动远超该口径）；b) **提交顺序写死：先拆分（独立 commit）→ W4+W6 合并 commit**：拆 `preview_image_view.dart`（渲染/手势/InteractiveViewer/`_player`/`_liveToggle`，约 -224）→ 拆 `preview_media_loader.dart`（`_load`/`_loadThumb`/`_loadInlineUrl` 编排与状态，约 -130）→ W4+W6 合并改造（合计净减 ~20）→ 主文件 674-224-130-20 ≈ 300 行达标（+1 天，本方案推荐；**W4/W6 各条目引用的行号一律以拆分前 `preview_media.dart` 为参照，拆分时按符号迁移定位**，符合 ink-gold「先拆再改」规矩） | 单拆 image_view 一层只能到 ~454 行不达标（674-60-200+40），b 必须两步拆分；拆分本身独立成 commit，W4/W6 改动落在小文件里更安全 |

## 架构：共享取字节入口（本方案的拼合件）

`thumbnailCache` 实例与字节下载器现散在 `features/assets/thumbnail_image.dart`（实例 `:24-29`、静态 `_http` `:56`、`_download` `:115`），core 层无法复用（预览要走管线就会 core→features 反向依赖，`main.dart:38-39` 解耦红线）。本批下沉：

- **`core/thumbnail_cache.dart`**：全局实例 `final thumbnailCache = ThumbnailCache(signer: ...)` 移入此处（signer 只依赖 core 的 `session.api`，合法）；签名闸（D1）在此实现。
- **新建 `core/thumb_fetch.dart`**：静态 `_thumbHttp`（connectionTimeout 15s，不设池限，见 D5）+ 显式 `resp.listen` 下载 + **`ThumbHandle fetchThumb(String assetId)`**——进程级共享任务：磁盘 miss 后宫格/胶片条/预览统一经它 submit（签名→下载，`ctx.isCancelled` 检查 + 两段式 `registerAbort`），同 assetId 自动共享订阅与字节。
- `features/assets/thumbnail_image.dart` 改为消费 `fetchThumb`（删本地 `_http`/`_download`；**保留一行 `export '../../core/thumbnail_cache.dart' show thumbnailCache;`**——`main.dart:17,40`、`thumbnail_image_disk_test.dart:27` 等既有 `show thumbnailCache` import 无需改动，避免编译断；旧 export 的彻底清理记遗留），`preview_media.dart` 同。

## 功能点明细（逐条可验收）

### W1 缩略图管线全局并发闸（P0）

1. 新建进程级 `ThumbPipeline`：`submit(assetId, job)` 返回句柄，排队执行、并发上限 6、FIFO；**同 assetId 去重（排队态与运行态均共享同一次执行；任务任一终态——成功/失败/超时/取消——立即从去重表移除**，否则一次 404 后同 assetId 新格子会 join 到已终态任务复用旧失败结果，「下次重建自然重试」失效），多订阅者共享同一内部 future，每个订阅者持独立句柄。
2. 订阅式取消（统一终止语义）：
   - `handle.cancel()` 解除本订阅，取消者句柄 future 以 `null` 完成；**cancel 幂等，任务已终态后再 cancel 无操作**；
   - **最后一个订阅者离开** → 任务终止：排队态=撤销（job 不执行）；运行态=按 D7 分阶段触发已注册 abort、置 `isCancelled`（job 在下一 await 边界自行短路，僵尸 job 不再发起后续网络请求）、取消 watchdog、释放名额；deadline 与 cancel 竞态以先到者为准；
   - 仍有其他订阅者在 → 任务照常继续（宫格+胶片条+预览共享互不误伤）。
3. **任务硬超时（20s，自任务开始执行起算，排队不计时）**：deadline 到 → 走第 2 条同款终止路径，任务以超时异常终态。
4. abort 注册与终止信号：job 接收 `ThumbTaskContext`（`isCancelled` + `registerAbort`）；可多次 `registerAbort`（响应头前注册 `req.abort()`；`resp.listen` 后注册「`subscription.cancel()` + 以异常完成下载 completer」）；deadline 已过/任务已终态后才注册的立即触发；任务终态时管线取消 watchdog、清空回调。
5. 异常与未处理错误防线：管线在 `submit` 时即给共享 job future 挂终态处理（`then(onValue, onError)`）——任务终态后 job 迟到抛出的异常一律管线内吞掉并 AppLog 留痕（否则 release 下 `onSystemError` 弹报错页架空 D2）；abort 回调自身异常 catch。
6. 名额释放与代际：任务任一终态必须释放并发名额，**且全路径幂等（`releaseOnce`：每任务一次性终态令牌/`released` 标志，cancel/deadline 的立即释放与 job 迟到结束的 `finally` 清算只生效首次）**——否则快滚高频 cancel 下 active 计数被多减、实际运行 >6 击穿 T1/验收 1；任务携带（代数, assetId）。**`clear()` 行为写死**：① 先终止全部运行中任务（置 `isCancelled`、按序触发 abort、以 `null` 完成每个句柄、取消 watchdog）；② 再同步撤销全部队列（**队列内每个订阅者句柄同样以 `null` 完成，与 cancel 同口径**——防 W6 预览 `.timeout` 计时器悬到 20s）、清空运行集合与去重表、重置计数、代数自增——旧任务的 late `finally` 对旧代一律 no-op。
7. 任务边界=「签名→字节下载」返回字节；**落盘与 `setState` 在管线外**由调用方执行（**字节就位先 `setState` 显示、写盘 fire-and-forget**——全局写互斥 + `_evict` 全目录扫描下同步等写盘会把首屏「渐进出现」拖成串行；`_evict` 节流已列遗留）；**磁盘代数在 `_load`/`_loadThumb` 开始、`ThumbDiskStore.I.read` 之前捕获**（write 紧前才捕获形同虚设——clear 已完成时读到的是新代，校验必过），贯穿到 `write(expectedGeneration:)`；调用方收到超时/异常/cancel（null）时不落盘、置 `_failed` 色块，下次重建自然重试。
8. Timer 纪律：管线调度/重试用 `Future`/microtask；**本方案新增的 Timer 仅三类，且每类都有确定取消路径**（既有 Timer 如 `preview_media.dart` 双击窗口 `_tapWindow` 已有 dispose 取消，不在本清单、不需重构）——① deadline watchdog（任务任一终态在调用栈内同步或仅经 microtask 取消，禁 `Future(() {...})` 事件队列）；② W6 预览外层 `.timeout(20s)`（onTimeout 内必调 `handle.cancel()`，触发后自然结束）；③ 签名闸槽内 race 计时器（随任务终态经 `abandonAwait` 取消，见 W2 #11；测试卸载树→dispose→cancel→abandonAwait 链路先于不变量断言，永挂起签名用例不遗留 pending timer）。提供 `@visibleForTesting reset()`。
9. 测试隔离：新建 `app/test/flutter_test_config.dart` 全局 `tearDown`——`thumbPipeline.reset()` + `thumbnailCache.clear()`（仅状态清理；watchdog 正确性由「终态必取消 + testWidgets 卸载树在不变量断言前触发全部 dispose→cancel」保证）。

### W2 缩略图签名静默 + 签名闸（P0）

10. 单发 `assets.thumbnailUrl`、新增批量 `assets.thumbnailUrls`、**livp 实况短片 `livePreviewUrl`** 均带 `Options(extra: {'noErrorReport': true})`；失败不进全局报错页，仅 AppLog 留痕 + 格内降级色块（livp 失败静默回退静态图，防断网横切到 livp 张弹整页报错页与验收 2 冲突）。
11. **签名并发闸（含放弃链与迟到异常防线）**：`ThumbnailCache` 对 `_sign` 增加上限 6 的 FIFO 闸 + **`abandonAwait(String assetId, {int? generation})`**——管线任务终态（最后订阅者 cancel/deadline/clear）时经 job 的 abort 链同步调用（`fetchThumb` job **在 `urlOf` 之前**即注册该回调）：**abandon 按等待者状态分流（显式三态 queued/running/abandoned）**：**被放弃的 waiter 无论何种状态总是先移除并以取消异常完成**（abandon 仅作用于该 job 注册且仍活跃的 waiter；waiter 已成功完成/已出表则一律 no-op——防同 assetId 新 waiter 被旧 job 的迟到 abandon 误取消）；其余动作按状态——**排队态**（未取得闸槽、无 race 计时器）→ **只移除该 waiter**（该 sign job 已无任何 waiter 时才整体出 FIFO 并清 `_inflight`——按字面移除整个 job 会误伤同签名其他 waiter）、不动闸 active 计数；**运行态** → **仅当该签名再无其他等待者**：归还闸槽 + 取消 race 计时器（计时器与还槽绑定为一件——若仍有其他等待者（如新任务重新挂上同一悬挂签名），保留计时器或重新起一轮 20s race，防「槽在而计时器没了」的无兜底悬挂）；带代数——clear 后旧代 late 注册的 abandon 一律 no-op（防误伤新代同 assetId 的等待者/计时器）。

    **waiter 计数写死**：cache 对每个根 future 维护活跃 waiter 计数（`urlOf` 消费方各注册一个 waiter，`fetchThumb` 管线任务注册时携带句柄），`abandonAwait` 按 waiter 递减、归零才还槽——最终形态（W4 起）全部签名消费方都在管线任务内，无双 waiter 归属歧义。

    **闸槽释放全路径幂等（`slotHeld`/`releaseOnce`，携代数）**：每个 sign job acquire 时置 `slotHeld=true`；`releaseSlot()` 仅在 `slotHeld && 代数匹配` 时 `active--`、置 false。**race 计时器归属写死：每 waiter 一个**——waiter abandon 必取消自身计时器（不论是否还有其他 waiter），slot 归还走 `slotHeld` 独立判定；join 到已放槽悬挂签名的新 waiter `slotHeld=false`、其 `releaseSlot` no-op 但自身计时器照常取消（否则 pending-timer 红线）。四类释放点统一走它——signer 正常成功/失败、race 20s 超时放槽、`abandonAwait`（仅最后 waiter 还槽分支）、`clear()`（重置计数并升代，旧代 late 释放 no-op）；**join 到已放槽的悬挂签名的新任务不得置 `slotHeld`**（否则其 abandon 会二次还槽）。防 active 计数漂移/为负导致实际签名并发 >6 击穿 D1/验收 1。内部结构写死为「**sign job（根 future）+ waiter completer**」两层：根 future 创建时即挂终态处理（成功与失败都按代清理 `_inflight`——否则失败后同 assetId 永远 join 已失败根 future、「签名失败不缓存毒、下次重签」既有语义失效；成功另落缓存；失败 → **存在 active waiter 时异常照常传播给 waiter**——管线 job 立即失败释放名额、宫格/预览立即落降级（`thumbnail_cache_test.dart:66-84`「签名失败不缓存毒」与 `preview_media_fallback_test` 立即失败卡两条既有语义保持）；**全部 waiter 已放弃/超时/clear 后才 swallow + 仅 AppLog 留痕**——被放弃签名的迟到失败不会成为未处理异步异常经 `onSystemError` 弹报错页架空 D2）；waiter 的取消异常不转嫁根 future；`clear()` 时对全部在途根 future 同样保证 swallow。**race 计时器按 waiter 持有（与上文归属一致）：waiter abandon 取消自身计时器；signer future 终态（成功或失败）时取消该 sign job 全部剩余计时器**（成功路径不留 pending timer，`thumbnail_image_disk_test.dart:219-251` 等成功签名用例不受影响）。防「悬挂签名（dio receiveTimeout 10min）占满闸槽 → 后续全部排队到死」的局部卡死。`_inflight` 单飞去重先于入闸；**`clear()` 写死**：取消全部闸计时器、归零闸 active 计数、**所有 active waiter（queued + running）均以取消异常完成（不悬挂；对 waiter future 先挂内部 `ignore()` 兜底——防无监听者的取消异常变成未处理异步错误触发 `onSystemError` 弹报错页）**、清空 `_inflight`/`_cache`、代数自增。**在途签名口径**：新发起单发签名经闸 ≤6 并发；race 放槽后底层悬挂签名不强杀（连接已建、由 receiveTimeout 10min 兜底自然消亡），极端拥塞窗口内在途可短暂超过 6（自愈上限 10min）；批量预热请求（≤2 批/页）不经此闸。
12. 缩略图字节下载走静态 HttpClient（不经 dio），天然不触报错页——仅确认不改动。

### W3 批量签名端点 + 宫格批量预热（P1）

13. 后端新增 `POST /api/v1/assets/thumbnail-urls`：body `{"asset_ids": [...]}`（1..100，pydantic 约束超限 422，风格对齐 `BatchDownloadLinkIn`）；认证同单发端点（`get_current_user`，不做 per-asset FGA——1024px 模糊化信任组织内可见性，与单发同拍板口径）。
14. 实现：单条 `select(Asset).where(Asset.id.in_(ids))`（禁止 N+1）；内存分流——有 `thumbnail_key` 逐个 `sign_thumbnail_url`（本地 HMAC；**100 条串行签名走 `asyncio.to_thread` 或每批 20 条 `await asyncio.sleep(0)` 让出事件循环**，防同步 botocore 阻塞），不存在/无 key 进 `missing`；重复 id 以唯一 id 出。软删照常返回；`request_base` 跟随入口；响应顺序不保证，App 按 `asset_id` 匹配。
15. `ThumbnailCache` 批量接口与容量校准：`missingOf(ids)`；`putBatch(entries, {int? expectedGeneration})`（TTL 语义与 `_sign` 现状一致：`expiresIn ≤ 0` → `fallbackTtl`；`0 < expiresIn ≤ margin(300s)` → **不缓存该条**（`_sign` 现状 clamp 0 即立即过期，不缓存更省且等价）；预热方发请求前捕获 `generation` 透传）。**`defaultEntryBytes` 256KB→4KB**（URL 只存字符串，256KB 估权 LRU 上限仅 ~320 条，千格夹整页预热会抖动驱逐；4KB≈2 万条）+ **LRU 改 running total 维护**（`_put`/逐出 O(1)，现状 fold 是 2 万条下 O(n²)）；`urlOf` 按代数过滤旧代 `_inflight`；文件头旧注释同步更新。
16. 新建 `features/assets/thumb_prewarm.dart`：`prewarmThumbUrls(List<Asset> items)` async + 最外层 catch——过滤 `hasThumbnail` 且 `missingOf` 命中 → 捕获代数 → 分批 ≤100 → `assets.thumbnailUrls` → `putBatch(带代数)`；失败静默，不自动重试、不做负缓存（`missing` 项忽略——有 `thumbnail_key` 的格子进入视野时单发兜底，端点 404 的格子弹一次后落色块；无 key 格子本就不发请求、直接色块）。
17. 宫格页接入**两个挂点**（`assets_page.dart`）：① `_applyPage` 之后（首载/下拉刷新/重试/静默刷新共用落点）；② `_loadMore` merge `[..._items, ...page.items]` 完成后（**`_loadMore` 不经 `_applyPage`**，`:147-176` 手工 merge，是快速滚动新增数据的唯一路径）。两处均传增量 `page.items`，页面净增 ≤5 行守 300 硬顶（现 294 行）。
18. 预热与单格签名并发写同一 assetId：幂等覆盖，最坏重复一次签名（`_inflight` 单飞仍在）。

### W4 预览放大不换原图（P1，用户拍板）

19. `preview_media.dart` 删除 G2 自动升级链路（**W4 与 W6 合并为一个 commit「预览缩略图数据源与放大行为改造」**——边界耦合过深（G2 删除使 `_url` 语义变化、磁盘直读依赖句柄化数据面），拆开会出现「预览仍直连 `urlOf` 的无句柄等待者」中间态，签名闸 race 计时器无取消路径、`preview_polish_test.dart:54-56` 等永挂起签名用例必红；合并后单一 revert 单元=整个预览改造）：`_maybeRequestOriginal`/`_requestOriginal`/`_canUpgradeToOriginal`/`kOriginalZoomThreshold`/`_originalRequested` 全删（双击/捏合回调中的触发点一并删）；`_showingThumb`/`_thumbUrl` 连同**全部写点**一并删（`:334` 的 `if (_fail == null) _showingThumb = true;` 与 `:384` 的 `_url = _thumbUrl = await ...` 都要改——`:384` 所在的 `_loadThumb` 整体被 fetchThumb 化数据源替换，字段随删不残留）；errorBuilder 内 `_thumbUrl`/`_showingThumb` 回退块（`:591-600`）整块删除（改为直接 `return _block('图片解码失败,建议下载后打开')`；`AnimatedSwitcher` 一并移除（缩略图路径来源单一）；文件头 G2/P2-1 注释段同步清理。**合并 commit 必须自带 `flutter analyze` 0 + 相关预览测试绿验证**（防写点漏删编译断）。
20. `errorBuilder` 按来源分流（**不统一**——无缩略图原图 inline 的现有行为是「失败块就地渲染、不改状态」，`preview_page_swipe_test.dart:9-14`（文件头说明）、`preview_polish_test.dart:329-364`（C3 双击用例走无缩略图路径）、`probe_p2_test.dart:300-316`、`preview_fallback_thumb_test.dart:139-154`（inline 成功路径，依赖 Image.network 存在）四处既有用例依赖该行为，必须保持）：**`Image.memory`（缩略图字节）失败** → post-frame 置 `_fail`（文案用「图片解码失败，建议下载后打开」——坏字节与「预览图还在生成」语义不符；**`_loadThumb` 签名失败路径统一用 `thumbFailText`（404/5xx/网络皆然，`preview_media_fallback_test.dart:114-135` p7-both 的 500 用例现状语义保持不动）**，两条规则按「签名失败 vs 解码失败」分流而非按状态码）+ `remove(id)` + **同时 `_thumbFallback = false`**（防视频回退分支残留矛盾提示）；**`Image.network`（无缩略图原图 inline）失败** → 保留现状 errorBuilder 行为（直接渲染失败块「图片解码失败，建议下载后打开」，不改 `_fail`、不摘 InteractiveViewer）。失败文案与现状两条真实来源对齐：原图 inline 的 **download-link 签发失败**（`_loadInlineUrl` catch，`:369`）→ 「预览加载失败」；**解码失败**（errorBuilder，`:601`）→ 按上文分流。
21. 视频分支零改动；**livp 分支仅两处小改**：① `_loadThumb` 数据源随 W4/W6（句柄化/磁盘直读）；② **`livePreviewUrl` 与 `_loadThumb` 并行发起**（现状串行——冷缓存下 live URL 要等缩略图字节（W6 后最坏 20s）才发出，断网可达 35s 落降级破验收 2；改并行后 `_loading` 在 `_loadThumb` 落定即 false，live URL 后台续跑、失败静默回退静态图维持现状；**晚到的 live URL 赋值必须 `setState(() => _liveUrl = r.url)`**——现状依赖 `_loading=false` 的 setState 顺带刷新，并行后该时机先于 live URL 到达，不 setState 则「播放实况」按钮/播放器永不出现）：`preview_player`/`filmstrip` 零改动（胶片条经共享入口自然受益）；PDF/text/markdown 分支零改动。

### W5 缩略图字节下载连接池决策（P1）

22. `core/thumb_fetch.dart` 静态 `_thumbHttp` **维持不设 `maxConnectionsPerHost`**（决策依据见 D5：池限在取消场景制造无计时器 `_pending` 死等；并发治理唯一归口管线闸）；connectionTimeout 15s 保持。

### W6 预览缩略图统一数据源（P1）

23. `_loadThumb` 改造（顺序写死）：先判 `_a.hasThumbnail`（无 key 走现状 inline/失败分支，不读盘）→ 捕获磁盘代数 → `ThumbDiskStore.I.read(id)`（**读返回后先查 mounted**——read 期间 dispose 则直接返回不发 fetch，防无人取消的任务占名额至 20s；再校验代数，跨代丢弃——**丢弃视同磁盘 miss：重新捕获当前 `ThumbDiskStore.I.generation`，后续 fetchThumb 与写盘均用新代数**（用旧代会每次跨代白下载不落盘；直接 return 会三空永久转圈，故重新捕获续走）)→ 命中记 `_thumbBytes`（零网络）；未命中 → `fetchThumb(id)` **保存句柄 `_thumbHandle`**（每 State 生命周期只允许发起一次——`ValueKey(asset.id)` 切张重建保证；注释写死防将来重入泄漏旧句柄），外层 `.timeout(20s)`（**有意为之的 UI 总等待上限，自进入预览起算、含排队时间**——与管线 deadline「执行起算」不同口径；onTimeout 内调 `_thumbHandle.cancel()` 再置 `_fail`）；成功记 `_thumbBytes` + 按捕获代数写盘；**收到 null（cancel/clear）且仍 mounted → 置 `_fail`**（防 `_thumbBytes/_url/_fail` 三空落永久 loading）。**`dispose` 必调 `_thumbHandle.cancel()`**（防横切/退出后任务残留占名额与 watchdog）。预览侧与宫格/胶片条共享同 assetId 任务，不重复下载。
24. **预览状态机改造**（磁盘命中时 `_url` 为 null，以下消费点必须全部同步改）：
    - `_zoomable`（`:438`）与两处 `previewBodyPlan(hasUrl:)`（`:442/:446`、`:514/:518`）的「可渲染」判定改为 `_url != null || _thumbBytes != null`；
    - `_image`（`:618`）改 `_previewImage(bytes: _thumbBytes, url: _url)`；
    - `_previewImage` 显式二选一：`bytes != null` → `Image.memory`（key=assetId+`'mem'`）；`bytes == null && url != null`（仅无缩略图原图 inline）→ `Image.network`（保留现状）；外层 `SizedBox.expand`/`Center` 恒撑满（旧 `AnimatedSwitcher` layoutBuilder 注释 `:572-574` 教训）；video `_playUrl` 的 `_url` 语义不变。
25. 磁盘字节损坏兜底：`Image.memory` 解码失败 → `ThumbDiskStore.remove(id, expectedGeneration: 捕获代数)`（不复写空、防跨代误删新会话写入）+ post-frame 置 `_fail`；**坏字节 write/remove 顺序天然安全**——fire-and-forget 的 write 先入互斥 FIFO、解码失败的 remove 后入队，串行执行下 remove 必然删掉刚落盘的坏字节（T13 加「网络坏字节 → 目录最终无该文件」断言）；**宫格 `ThumbnailImage` 的 errorBuilder 同样 `remove(id, 带代数)` 并 post-frame 置 `_failed`/清 `_bytes`（post-frame 内先比对捕获的 `_tag`/assetId 再 setState——防切张后旧资产解码回调误伤新格）**（防同一 State 内坏字节反复重解码）。
26. 覆盖范围：共享入口生效于全部 `ThumbnailImage` 入口——宫格（`asset_tile.dart:99`）、预览胶片条（`filmstrip.dart:162`）、搜索结果行（`search/result_row.dart:113`）+ 预览主图 miss 分支。web 零改动。

## 组件拆分方案

### 新建文件

| 文件 | 职责 | 预估行数 |
|---|---|---|
| `app/lib/core/thumb_pipeline.dart` | 任务闸：并发 6、FIFO、同 assetId 订阅去重、句柄 cancel（最后订阅者即终止）、ThumbTaskContext、20s watchdog、管线级 swallow、代际、clear/reset | ~200 |
| `app/lib/core/thumb_fetch.dart` | 共享取字节入口：`fetchThumb(assetId)`（签名→下载 job：isCancelled 检查+两段式 abort）+ 静态 `_thumbHttp`（不设池限）+ 显式 `resp.listen` 下载 | ~130 |
| `app/lib/core/thumb_sign_gate.dart` | 签名并发闸独立件（现 `thumbnail_cache.dart` 仅 118 行，加闸/abandon/代际/putBatch/running total 必超 300 硬顶）：上限 6 FIFO + queued/running/abandoned 三态 + race 20s + slotHeld releaseOnce + 代数 | ~140 |
| `app/lib/features/assets/thumb_prewarm.dart` | 批量预热编排：过滤/捕获代数/分批/调 API/putBatch，失败静默 | ~90 |
| `app/lib/features/preview/preview_image_view.dart`（D10 选 b 时） | 迁出 `_previewImage`/`_image`/双击捏合手势/InteractiveViewer | ~200 |
| `app/lib/features/preview/preview_media_loader.dart`（D10 选 b 时） | 迁出 `_load`/`_loadThumb`/`_loadInlineUrl` 加载编排与状态（loader 持 `_url`/`_thumbBytes`/`_fail`/`_thumbHandle`，向 view 层暴露不可变快照） | ~130 |
| `app/test/flutter_test_config.dart` | 全局 tearDown：`thumbPipeline.reset()` + `thumbnailCache.clear()` | ~15 |
| `app/test/core/thumb_pipeline_test.dart` | 闸单测（T1-T6、T14 管线部分） | ~240 |
| `app/test/core/api/thumbnail_no_report_test.dart` | noErrorReport 钩子断言（T11②，runZonedGuarded 口径） | ~80 |
| `app/test/core/thumb_fetch_test.dart` | 下载两段式 abort（fake `HttpClientResponse` 记录 subscription.cancel） | ~120 |
| `app/test/features/thumb_prewarm_test.dart` | 预热单元（T11① prewarm 侧） | ~120 |
| `app/test/features/assets_page_prewarm_test.dart` | 宫格两挂点集成（T11① 页面侧） | ~140 |
| `app/test/features/preview_thumb_source_test.dart` | T13 预览数据源用例集中落点（磁盘命中三分支/冷缓存/损坏/null/并行 livp 等） | ~200 |
| `api/tests/test_thumbnail_urls_batch.py` | 批量端点测试（T7-T10） | ~150 |

### 契约（并行开发的硬边界）

```dart
// core/thumb_pipeline.dart
final thumbPipeline = ThumbPipeline(concurrency: 6, taskDeadline: Duration(seconds: 20));
class ThumbTaskContext {
  bool get isCancelled; // job 每个 await 后、发起下一个请求前检查，已终止即短路
  void registerAbort(void Function() abort); // 多次注册按序保留；终态后才注册立即触发
}
class ThumbHandle {
  Future<Uint8List?> get future; // 超时/异常向上抛（调用方 catch 置降级）；cancel/终止以 null 完成
  void cancel(); // 幂等；最后一个订阅者离开 → 终止任务
}
class ThumbPipeline {
  ThumbHandle submit(String assetId, Future<Uint8List?> Function(ThumbTaskContext ctx) job);
  void clear(); // ①终止全部运行任务(置标记+abort+句柄null完成+取消watchdog) ②撤队列(队列句柄同样null完成)/清集合/去重表/计数 ③代数自增
  @visibleForTesting
  void reset();
}

// core/thumb_fetch.dart
ThumbHandle fetchThumb(String assetId);
// 进程级共享任务：签名→下载字节（宫格/胶片条/预览统一入口）。
// job 内在 urlOf 之前 registerAbort(() => thumbnailCache.abandonAwait(assetId, generation: gen))，
// 拿到 HttpClientRequest 后 registerAbort(req.abort)；req.close() 返回后立即查
// isCancelled——已取消则 resp.drain().catchError 后抛取消（此时无 subscription、abort
// 对已到响应头连接无效，drain 归还连接）；未取消则 resp.listen 后注册
// subscription.cancel + 异常完成下载 completer；每个 await 后检查 ctx.isCancelled。

// core/thumbnail_cache.dart（全局实例移入 core；增量）
final thumbnailCache = ThumbnailCache(signer: ...); // signer 只依赖 session.api，core 内合法
// features/assets/thumbnail_image.dart 保留 export ... show thumbnailCache 兼容旧 import
class ThumbnailCache {
  int get generation;
  Iterable<String> missingOf(Iterable<String> assetIds);
  void putBatch(Iterable<({String assetId, String url, int expiresIn})> entries,
      {int? expectedGeneration});
  /// 管线任务终态时经 abort 链同步调用：取消闸 race 计时器、无其他等待者则归还
  /// 闸槽、等待者以取消异常完成（底层 signer 继续跑，落缓存供下次复用）
  void abandonAwait(String assetId, {int? generation}); // 此 generation 指 ThumbnailCache.generation（签名闸代数，勿传 ThumbDiskStore 的磁盘代数）
  // 签名闸实现于 core/thumb_sign_gate.dart（上限 6 FIFO + 三态 + race 20s + slotHeld releaseOnce + 代数）；
  // _inflight/_sign/闸队列按代数管理，urlOf 过滤旧代；defaultEntryBytes 4KB；LRU running total
}

// features/assets/thumb_prewarm.dart
Future<void> prewarmThumbUrls(List<Asset> items); // async+全 catch；只预热 URL

// core/api/assets_api.dart（增量）
Future<({Map<String, ({String url, int expiresIn})> byId, Set<String> missing})>
    thumbnailUrls(List<String> assetIds); // 带 noErrorReport

// core/thumb_disk_store.dart（增量）
int get generation;
/// clear 同步升代后、异步删除期间置 _clearing——期间 read 一律返回 null（防读到旧代文件）；
/// write/remove/clear 共用内部互斥串行（互斥已消除竞态）；write 的 rename 前校验
/// 代数，失配只放弃（删唯一 tmp 文件），rename 原子替换后不再判断、绝不删目标
/// 文件；clear() 第一行同步自增代数再进入异步删除
Future<void> write(String id, Uint8List bytes, {int? expectedGeneration});
Future<void> remove(String id, {int? expectedGeneration}); // 纳入同一互斥+代数（防旧会话迟到 remove 误删新会话写入）
@visibleForTesting
void debugSetWriteGate(Future<void> Function()? gate); // T14 注入慢写窗口；传 null 清除（用例间防挂起，单例全局）
@visibleForTesting
void debugSetReadGate(Future<void> Function()? gate); // T13 注入慢读窗口（read 在途时 dispose 用例）；传 null 清除
@visibleForTesting
void debugAttachDirectory(Directory? dir); // 传 null 恢复默认目录（T12 tearDown 重挂默认用；现仅接受非空目录，需扩展）
```

```python
# api/app/routers/assets.py（单发 thumbnail-url 端点旁新增）
class ThumbUrlOut(BaseModel):
    asset_id: uuid.UUID
    url: str
    expires_in: int

class ThumbUrlsIn(BaseModel):
    asset_ids: list[uuid.UUID] = Field(..., min_length=1, max_length=100)

class ThumbUrlsOut(BaseModel):
    urls: list[ThumbUrlOut] = Field(default_factory=list)
    missing: list[uuid.UUID] = Field(default_factory=list)  # 不存在或无 thumbnail_key
```

### 修改文件

| 文件 | 改动 |
|---|---|
| `app/lib/features/assets/thumbnail_image.dart` | `_load` 网络段改经 `fetchThumb` + dispose/换 asset 调 `handle.cancel()`（`_tag` 保留）；删本地 `_http`/`_download`；**保留 `export ... show thumbnailCache`**（旧 import 兼容）；errorBuilder 补 `remove(id, 带代数)`+post-frame 置 `_failed`；**`_load` 开始（read 前）捕获磁盘代数**，read 返回后校验代数（**跨代丢弃不得直接 return（会停占位态），重新捕获当前代数继续 fetchThumb**），贯穿 `write/remove(expectedGeneration:)` |
| `app/lib/core/thumbnail_cache.dart` | 全局实例移入 + 挂接 `thumb_sign_gate`（闸实现独立文件防超 300）+ missingOf/putBatch/generation + 代际 + 4KB 权重 + LRU running total |
| `app/lib/core/thumb_disk_store.dart` | generation/write(串行+双校验)/remove/`_clearing` try-finally/写闸注入 |
| `app/lib/core/api/assets_api.dart` | `thumbnailUrl` 与 `livePreviewUrl` 加 noErrorReport；新增 `thumbnailUrls` |
| `app/lib/features/assets/assets_page.dart` | `_applyPage` 后 + `_loadMore` merge 后各 1 行 `prewarmThumbUrls(page.items)`（现 294 行，净增 ≤5 守 300 硬顶） |
| `app/lib/features/preview/preview_media.dart` | W4 删 G2 链路与 AnimatedSwitcher（净减 ~60 行）+ W6 `fetchThumb` 化数据源与状态机改造（净增 ~40 行）；D10 口径实施前落定 |
| `app/lib/main.dart` | 会话清空钩子加 `thumbPipeline.clear()`（顺序 pipeline → cache → disk）；钩子注册抽 `registerSessionClearHooks()`（幂等防重复累积）便于测试 |
| `app/lib/core/session.dart` | 仅加 `@visibleForTesting` 钩子观测（T14 用） |
| `app/test/probe_qa_boundary_test.dart`（既有，修改，**唯一归属包 C**） | C2 预览用例（`:357-390`，`_img` 带 `thumbnail_key`、`thumbnailUrl` 永挂起桩）按 W6 数据源适配；B 包对该文件只读不改（避免并行冲突） |
| `app/test/helpers/api_harness.dart` | `FakeAssetsApi` 补 `thumbnailUrls`/`livePreviewUrl`/`thumbnailUrl`（可控 404/计数）桩 |
| `app/test/core/thumbnail_cache_test.dart` | 增量：签名闸/missingOf/putBatch/代际/4KB（T6） |
| `app/test/core/thumb_disk_store_test.dart`（既有，修改） | 增量：代际/remove/串行写竞态（T14 磁盘部分，经写闸注入慢写） |
| `app/test/features/thumbnail_image_disk_test.dart`（既有，修改） | `_StubRequest` 补 `abort` 实现并记录 `abortCalls` 计数（现状经 `noSuchMethod` 静默 no-op——tear-off 本身非空、不抛 TypeError，但取消行为不可观测；补齐后 `thumb_fetch_test` 才能断言 TTFB 期/body 期路径）；`:219-251` 等落盘断言改「轮询等待文件出现」（写盘 fire-and-forget 后 pumpAndSettle 不等文件 IO） |
| `app/test/features/preview_polish2_test.dart` | G2 用例改写（`:269`/`:303`，同样按 T12 配方预写磁盘字节——否则 `_mediaScale` 找不到 InteractiveViewer 抛 No element；放大断言补 zoom 生效）+ `:246-267` 缩略图直显用例按 T12 唯一稳妥配方预写磁盘 → 断言改为「零签名调用/磁盘直出（Image.memory）」（原 `contains('g2a')` 签名断言在预写磁盘后必红，须同步改）；**`:314` `contains('g2c')` 与 `:332` `thumbCalls.length==1` 同口径改**（预写磁盘后必红；改零签名或换用首次 fetch 前假 HttpClient 保留计数）；用例标题「仅请求 thumbnail-url」语义同步改「磁盘命中零签名」 |
| `app/test/features/preview_polish_test.dart` | `:397-416`（断言 NetworkImage 与 `:400` `thumbCalls==['g2a-1']`）改 `Image.memory` 断言（补字节源——**磁盘预写后签名计数断言改「零签名」，或用假 HttpClient 保留签名计数**，防桩法与断言互斥；`:397` 用例标题「进入预览默认只签 thumbnail-url」同步改「磁盘命中零签名」）；`:418`/`:464` G2 用例改「放大无新增调用 + zoom 生效」 |
| `app/test/features/probe_p2_test.dart` | `:318`、`:368` G2 探针 → 删除或改写 |
| `app/test/features/preview_fallback_thumb_test.dart` | 有缩略图用例（`:97-119` 断言 InteractiveViewer、`:110` `thumbCalls contains('a403')`）补字节源（**磁盘预写则签名断言改零签名，或用假 HttpClient 保留计数**；`:112` reason「入口直签 thumbnail-url」同步改）；无缩略图路径（`:147-148` 断言 NetworkImage）保持 |
| `app/test/features/preview_media_fallback_test.dart` | 图片分支（`:89-105`）与视频降级（`:137-156`）用例按 W6 数据源补字节源适配（`p7-both` `:114-135` 签名失败立即失败卡语义经 W2 #11 传播规则保持，不动） |
| `app/test/features/preview_filmstrip_tap_test.dart` | 永挂起签名用例：依赖 `PreviewMedia.dispose` 取消句柄→abandonAwait 链路保证无 pending timer（无需改断言；若初始化桩顺序受静态 `_thumbHttp` 影响可就地适配） |
| `api/app/routers/assets.py` | 新增 `POST /assets/thumbnail-urls` |

## 测试功能点

- **T1** 并发上限：同时 submit 10 个长任务，任一时刻运行中 ≤6（**文件内所有直接 submit 的用例（T1/T2/T4/T5）末尾必须显式 cancel 全部句柄或 `thumbPipeline.reset()`**——无 widget 卸载链路、watchdog 不会被自动取消）。
- **T2** FIFO：按提交序开始执行。
- **T3** 句柄 cancel：① 两订阅者共享排队任务，A cancel → A future null、B future bytes、job 继续；② 仅剩 B 且排队中 → B cancel → 撤销、job 不执行、名额未占用；③ 运行中唯一订阅者 cancel → abort 回调触发、`isCancelled` 置位、名额回收、watchdog 已取消（fake-async 无 pending timer）、job 在下一 await 边界短路不再发起后续请求；**④ 名额幂等：取消/超时若干运行中任务后连续 submit 10 个，任一时刻运行中 ≤6、active 计数不为负（双释放回归）**。
- **T4** 同 assetId 去重：排队态与运行态重复 submit 均共享同一次执行。
- **T5** 名额回收与防线（分层，**用 `testWidgets` + `tester.pump(Duration(seconds: 20))` 提供假时，不引 `fake_async` 依赖**）：管线级——job 抛异常立即回收；job 永不完成 → deadline 触发 abort、超时异常、名额回收；deadline 后 job 才抛异常 → 无未处理异步错误（`runZonedGuarded` 断言，不依赖 debug 下天然为真的 errorReporter）；组件级（`thumb_fetch_test`）——fake `HttpClientResponse` body 永不产出 → `subscription.cancel` 被调、下载 completer 以异常完成、后续任务可进管线执行（名额回收；dart:io 池行为不在单测范围，D7 分阶段语义以代码审查+真机验收兜底）。
- **T6** 缓存层（Timer 相关断言用 `testWidgets`+`pump` 假时，与 T5 同款；纯逻辑用例保持 `test()`；**本地 `ThumbnailCache` 实例的计时器用例必须在测试体末尾显式 `cache.clear()`**——`addTearDown`/全局 tearDown 都晚于 pending-timer 不变量断言，救不了当条用例；`addTearDown(cache.clear)` 仅作跨用例状态清理）：签名闸上限 6 FIFO + 槽内 20s race 超时放槽（等待者收 TimeoutException，底层 signer 完成仍落缓存）+ **`abandonAwait`：最后等待者放弃后闸槽归还、race 计时器取消（无 pending timer）；排队态放弃：6 个悬挂 signer + 第 7 个排队 waiter 被取消 → 从 FIFO 移除、signer 未被调用、active 仍为 6、新任务进入 FIFO 队列（pump 20s 让 6 个 race 放槽后才能真正进闸）**；**闸槽幂等四断言**：race 超时后 signer 迟到成功 → active 不变；race 放槽后 abandon → active 不变；clear 后旧 signer 完成 → active 仍为 0；join 到已放槽悬挂签名的第二个任务 abandon → 不双减、**其 race 计时器已取消（无 pending timer）** + **被放弃/超时后根 future 迟到失败 → 仅 AppLog、无未处理异步异常（`runZonedGuarded`）、不弹报错页**；**存在 active waiter 时签名失败（404/500）照常传播（`thumbnail_cache_test.dart:66-84` 既有语义保持）**；**签名成功路径 race 计时器同步取消、无 pending timer**；putBatch 后 missingOf 不含未过期项；**`expiresIn ≤ 0` → fallbackTtl、`0 < expiresIn ≤ 300s` → 不缓存**；LRU 按 4KB 权重生效；clear 代际后在途 `_sign`/`putBatch(旧代数)` 丢弃、闸旧队列等待者以异常完成不悬挂、闸 active 归零、clear 后新同 assetId 单飞不被误删、`urlOf` 不返回旧代 inflight。
- **T7** 批量端点正常：N 个有缩略图资产 → urls 全量返回，断言 URL 前缀/形状 + `expires_in=1800`（直调 handler + stub 依赖，先例 `test_batch_download_link.py`）。
- **T8** 部分 missing：混合无 thumbnail_key/不存在资产 → missing 精确；重复 id 以唯一 id 出。
- **T9** 入参与认证：模型级构造空/101 断言 `ValidationError`，路由级（`create_app` + `httpx.ASGITransport` **+ lifespan fixture 或 `app.dependency_overrides` 注入 auth/presign/db**——`main.py:40-97`（state 赋值 `50-68`）的 state 仅 lifespan 设置，裸 client 会 500，先例 `test_asset_batch_move.py:67-78` 的 `app_with_lifespan`）断言 422/401。
- **T10** 软删照常返回；单条 `IN` 查询（fake session 记录 `execute` 次数 = 1）。
- **T11** 预热：① `prewarmThumbUrls` 单元（分批/代数/静默失败/session.api null 容错）+ `assets_page` 集成（注入带计数假 API + `thumbnailUrl` 404 桩隔离宫格签名：首载后发批、`_loadMore` 第二页后同样发批、≤100/批）；② 钩子级——请求构造为可失败（adapter 抛 DioException），断言 `onNetworkError` 不被调用（对照不带标记会被调用），先例 `error_report_regression_test.dart:78-97`。
- **T12** 预览放大（**字节源配方固定：优先 `ThumbDiskStore.I.debugAttachDirectory` 预写字节（不动静态 HttpClient，同文件已有先跑用例时唯一稳妥选项——如 `preview_polish2_test.dart:167-243` G1 先跑会把 `_thumbHttp` 初始化到 flutter_test 默认 400 桩，后装的 zone 桩不生效）；`HttpOverrides.runZoned` 假 `HttpClient` 仅可用于同文件首个 fetch 之前（`thumbnail_image_disk_test.dart:43-55` 先例）；使用磁盘预写的文件在 setUp 建临时目录挂载、tearDown 删除并重挂默认（单例全局，防跨用例读旧字节）**）：双击/捏合前后 **`downloadLink` 调用数不变、`thumbnailUrl`/fetch 调用数不增加**（记录调用序列区分入口签名与放大新增）；**放大后仍断言缩放生效（InteractiveViewer transformation scale > 1.05），防「图未渲染假绿」**；有缩略图恒显 `Image.memory` 来源；无缩略图资产仍走原图 inline（NetworkImage 保留）；六个测试文件按上表改写/适配。
- **T13** 预览数据源（行为断言）：磁盘命中 → image/heic 断言零网络、`Image.memory` 呈现；livp 断言「磁盘命中（用例显式预写字节）时零缩略图网络（无签名/无字节下载），`livePreviewUrl` 允许一次」；**冷缓存 livp（缩略图悬挂桩）→ live URL 不被阻塞、总时长 ≤20s 落定**（并行化回归用例）；**晚到 live URL → `setState` 生效、`_liveToggle` 按钮出现**（`:629` 渲染回归）；磁盘 miss → 经 `fetchThumb`（与宫格共享任务不重复下载——断言下载计数 =1）、成功写盘（断言目录中出现该文件）；损坏字节 → **断言目录中该文件已被删** + 落 `_fail`；签名悬挂 → 20s 超时置 `_fail`（非永久 loading）；收到 null（cancel）仍 mounted → 置 `_fail` 不落永久 loading；**read 期间 dispose → 不发起 fetchThumb（下载计数为 0）**；**clear 发生在下载期间 → 写盘被丢弃（经 `debugSetWriteGate` 构造）**；退出预览（dispose）→ 句柄取消、无 pending timer。
- **T14** 登出清理（行为断言，落点 `test/core/thumb_pipeline_test.dart` 尾部独立 group）：`registerSessionClearHooks()` 幂等（**断言重复注册后清会话钩子只执行一次**，经 `Session` 增 `@visibleForTesting` 钩子列表长度或测试注入 spy 观测）；`clear()` 后运行中下载被 abort、句柄 null 完成、无 pending timer、**clear 后立即 submit 同 assetId 启动全新任务正常完成**；磁盘代际——经 `debugSetWriteGate` 注入慢写构造「clear 前开始、clear 后完成的 `write`」被丢弃、clear 后新写入不被误删（write/clear 串行互斥）；缓存代际——「clear 前捕获旧 `generation` 的 `putBatch`」直接调用即被丢弃（内存写无需慢闸）。
- 全量 `flutter analyze` 0 issue + `flutter test` 全绿；后端 pytest 新增用例绿（常规在 hh2 dev 容器跑，本地不跑 docker）。

## 实施拆包（qdev，含每包允许改动文件清单）

| 包 | 内容 | 允许文件 | 依赖 |
|---|---|---|---|
| A（后端） | W3 端点 + T7-T10 | `api/app/routers/assets.py`、`api/tests/test_thumbnail_urls_batch.py` | 无（契约本文档已定） |
| B（App core+assets 底座） | W1 管线 + 共享取字节入口 + W2 签名闸/标记 + W3 缓存批量/api 方法/预热编排 + W5 池参数 + T1-T6/T11②/T14 | `lib/core/thumb_pipeline.dart`（新）、`lib/core/thumb_fetch.dart`（新）、`lib/core/thumb_sign_gate.dart`（新）、`lib/features/assets/thumb_prewarm.dart`（新）、`lib/core/thumbnail_cache.dart`、`lib/core/thumb_disk_store.dart`、`lib/core/api/assets_api.dart`、`lib/features/assets/thumbnail_image.dart`、`lib/main.dart`、`lib/core/session.dart`（仅加 `@visibleForTesting` 钩子观测，T14 用）、`test/flutter_test_config.dart`（新）、`test/core/thumb_pipeline_test.dart`（新）、`test/core/thumb_fetch_test.dart`（新）、`test/core/api/thumbnail_no_report_test.dart`（新）、`test/features/thumb_prewarm_test.dart`（新）、`test/core/thumbnail_cache_test.dart`、`test/core/thumb_disk_store_test.dart`、`test/features/thumbnail_image_disk_test.dart`（兜底权：abandonAwait 链若影响既有用例可就地适配）、`test/probe_qa_boundary_test.dart`（只读；适配唯一归属包 C） | 无（按契约可与 A 并行） |
| C（App features） | 宫格预热接入 + W4 预览改版 + W6 + T11①/T12/T13（D10 选 b 时含两步拆分） | `lib/features/assets/assets_page.dart`、`lib/features/preview/preview_media.dart`、`lib/features/preview/preview_image_view.dart`（选 b 时新）、`lib/features/preview/preview_media_loader.dart`（选 b 时新）、`test/helpers/api_harness.dart`、`test/features/assets_page_prewarm_test.dart`（新）、`test/features/preview_thumb_source_test.dart`（新，T13 落点）、`test/features/preview_polish2_test.dart`、`test/features/preview_polish_test.dart`、`test/features/probe_p2_test.dart`、`test/features/preview_fallback_thumb_test.dart`、`test/features/preview_media_fallback_test.dart`、`test/features/preview_filmstrip_tap_test.dart`（`preview_page_swipe_test.dart` 已核验：无缩略图 inline 失败不改状态的行为保留后无需改动，不占清单）、`test/probe_qa_boundary_test.dart`（C2 用例 W6 适配唯一归属此包） | B 的接口 |

交付约定：`scripts/changelog.md` 按天记条目（W4 为用户可感知行为变更，须含 commit hash）；W4 与 W6 **合并为一个 commit**（耦合过深拆不开，单一 revert 单元=整个预览改造）；选 b 时提交顺序「先拆分（独立 commit）→ W4+W6 合并 commit」，改造落在 loader/view 层；**派发包 C 前向用户确认 D10（默认 b）**。

## 验收标准

1. 真机 1000+ 文件文件夹快速滚动至底：无 connectionTimeout 风暴、无报错页跳转；缩略图随滚动渐进出现（**观测项：快滚时新进视口格子不得批量落「20s 超时」降级色块——若出现说明并发/取消语义回归，阻断发版**）；日志口径：批量请求 ≤2 批/页；**管线运行中任务（含新发起单发签名经闸）≤6 并发**（建连期已取消僵尸连接另计、≤15s 自愈，无硬上界——D5 取舍），与总格数无关（已放槽的悬挂签名不强杀、10min 自愈，见 W2 #11）。
2. 滚动中途点击**有缩略图的图片**进预览：宫格已加载过的张磁盘直读秒出（无网络请求）；未加载过的张不弹报错页，出图或 20s 内落降级提示；快速横切预览 20 张无卡死/无报错页（无缩略图/视频 inline 属关键请求，失败弹报错页为 D2 预期行为）；横切流畅度观察项：`Image.memory` 以字节为 ImageCache key、回切可能重复解码 1024px JPEG——若真机有感知，后续给预览 `cacheWidth`（≤2048）优化（记遗留）。
3. 预览双击/捏合放大至 4x：画面恒为缩略图，无原图切换、无闪空。
4. 断网场景：宫格格子落降级色块，随后一次关键操作（如刷新列表）触发报错页——信号链路仍通。
5. 上传并发叠加场景：后台传输任务（并发 2）进行中快速滚动 1000+ 文件夹，无超时风暴、无报错页。
6. 发布顺序遵循 D8（API 先行）；预发验证批量端点后再发 App。

## 风险与回滚

- **管线名额泄漏**：T5 分层专项（异常/永不完成/迟到失败/body 卡死）；20s 硬超时 + 分阶段断流 + `isCancelled` 短路，僵尸 job 不越界。
- **签名槽悬挂与迟到异常**：签名闸槽内 20s race 放槽 + `abandonAwait` 放弃链，局部卡死上限 20s×队列深度；底层悬挂签名不占闸/不占管线名额、10min 自愈；根 future 终态 swallow 防迟到失败弹报错页（T6 断言）。
- **建连期不可断**：D7 已写死——池排队/建连期无 request 可 abort，靠 15s connectionTimeout 兜底，任务侧仅释放名额+短路。
- **撤销误伤**：订阅句柄式 cancel + 最后订阅者统一终止；签名不强杀隔离共享 `_inflight`。
- **测试 Timer 红线**：三类 Timer（watchdog/预览 timeout/签名闸 race）全部有确定取消路径（任务终态同步或仅 microtask 取消；闸 race 经 abandonAwait 链随终态取消）；卸载树→dispose→cancel 先于不变量断言，永挂起签名用例不遗留 pending timer；T3③/T5/T6/T13 fake-async 断言无 pending timer。
- **未处理异步异常**：管线级 swallow + prewarm 全 catch。
- **批量端点滥用面**：认证 + 100/批上限；与单发同信任模型（同账号本可循环单发探测），批量化仅提高枚举效率，本批接受该面不加频控（若需防枚举另加 per-user 频控，记遗留）。
- **W4/W6 回退**：合并单 commit，连同对应测试整体 revert。
- **兼容性**：端点纯新增，旧版 App 不受影响；新 App + 旧后端 = 预热 404 静默 + 单发兜底（签名闸限流，不会更糟）；web 零改动。

## 遗留项

- P2：跳板机 nginx `worker_connections`/keepalive 与 ssh 隧道并发参数核查（运维验证项，D9）。
- P2：web 端接入批量签名端点（可选优化）。
- P2：显式优先级队列（dispose 收敛若实测仍有可感知延迟再上）。
- P2：`ThumbDiskStore` 容量评估（150MB 对千格 1024px JPEG 处于边界）与 `_evict` 全目录扫描节流。
- P2：格子等待同页预热 Future（带超时兜底）消除冷窗口单发（当前经签名闸限流可接受）。
- P2：预热失败的轻量重试策略（当前：静默 + 单格单发兜底）。
- P2：签名请求 CancelToken 全链改造（本批 race 放槽；未来需强杀在途签名时连同十余处测试 fake 同步改）。
- P2：批量端点 per-user 频控（若防枚举需求成立）。
- P2：悬挂签名上限策略（race 放槽后病理性网络下悬挂数可随时间累积而非「短暂」；发版观察项——若验收 1 真机观测到在途签名持续增长，补「悬挂根数达阈值暂停入闸」降级；当前按自愈上限 10min 接受）。
- P2：`thumbnail_image.dart` 的 `export ... show thumbnailCache` 兼容层清理（旧 import 全量迁 core 后删除）。
- P2：预览 `Image.memory` 的 `cacheWidth`（≤2048）解码优化（视验收 2 横切流畅度观察结果）。
