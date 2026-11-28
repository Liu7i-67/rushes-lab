# iOS App 后台持续上传修复(qdev 需求文档)

日期:2026-11-27 · 分支:`feat/ios-bg-upload`(自 liuqi be305d0)· worktree:`rushes-lab-feat-ios-bg-upload`

## 1. 背景与目标

用户反馈(iOS App):上传文件时切到后台使用其他软件,上传自动停止;返回 App 后重新上传;后台时间较长时上传任务报超时。实测与既有调研(ios-download-timeout-investigation)一致:App 无任何后台执行能力,切后台后主 isolate 被 iOS 挂起,dio 传输断流。

**修复目标:后台运行时上传仍然继续。**

根因(代码证据):全仓无 `beginBackgroundTask`/`BGTaskScheduler`;传输队列无生命周期监听(`transfer_queue.dart`);iOS Info.plist 无 `UIBackgroundModes`;`transfer_foreground.dart` 的前台服务仅 Android(`if (!_isAndroid) return`),iOS 分支纯 no-op。

## 2. 可行性结论(红线闸口)

**可行,且有成熟实现路线,成本可控。** 依据:

- iOS 官方唯一正规后台传输通道 = `NSURLSession background configuration`:App 挂起后传输由系统网络进程接管,完成后 `handleEventsForBackgroundURLSession` 唤醒 App(Apple 官方文档实证)。uploadTask body 必须来自磁盘文件——本仓上传协议恰好是「分片二进制 PUT 直传 MinIO 预签名 URL」,天然适配。
- Flutter 生态选型:**background_downloader 9.6.x**(pub 510 likes/339k 下载,2026-11 仍在发版):iOS 原生走 background URLSession,支持 `PUT + binary` 上传,`TaskStatusUpdate.responseHeaders` 可取 ETag;无需 UIBackgroundModes(v9.5.5+)、无需改 AppDelegate、无需 entitlements;GitHub issue #414 即「S3 分片 PUT」同构生产案例。
- 否决项:beginBackgroundTask(iOS13+ 实际 ~30 秒,撑不住长上传);audio/voip UIBackgroundModes hack(审核 2.5.4 拒审风险);BGProcessingTask(机会式分钟级,不能承载传输);flutter_uploader(停更 5 年);自研原生桥(成本高、投入产出比低)。

## 3. 功能点明细(逐条可验收)

1. **F1 iOS 前台上传行为不变**:入口、进度条、完成入库、缩略图、审计、409 同名查重全部与现状一致;非 iOS 平台上传代码路径逐字节同现状(dio 通道原样保留)。
2. **F2 iOS 上传中切后台持续上传**(核心):切后台(含锁屏)后,已入队原生队列的分片由系统继续上传;「预签窗口」内(≥4×16MB=64MB)传输不依赖 App 进程存活;回前台后进度反映后台真实进度,任务不重传、不报超时。
3. **F3 iOS 后台传完自动完成**:全部分片完成后,complete 调用在 isolate 可运行时(回前台或系统唤醒窗口)自动补发,任务落 done、素材列表出现。
4. **F4 取消语义保留**:前台/后台均可取消任务;取消时联动取消原生队列分片任务、删除临时分片文件、尽力 abort 服务端 multipart(现状语义)。
5. **F5 会话三元组持久化**:uploadId/bucket/key 写入 TransferTask 并进 transfers.json 快照;进程被杀后恢复时,非终态任务照旧标「进程中断」,且尽力 DELETE abort 服务端会话(两平台通用,减少孤儿分片)。
6. **F6 残留清理**:App 启动(iOS)清空上传分片临时目录(进程被杀残留的 chunk 文件)。
7. **F7 Android 零行为变化**:上传仍走 dio + 前台服务;Android debug 构建通过(新插件进 Android 构建图,需验证编译)。
8. **F8 后端分片签名 TTL 独立**:新增 `presigned_part_ttl_seconds`(默认 7200s),仅 `GET /uploads/{id}/parts/{n}` 使用;下载/缩略图共享 TTL(`presigned_normal_ttl_seconds=900`)不动;web Uppy 不受影响。
9. **F9 单文件上限、分片 16MB、三步协议契约、`UploadAmbiguousException`(complete 响应丢失禁自动重传)全部不变。**

## 4. 组件拆分方案

### 可复用资产盘点(直接复用)

| 资产 | 位置 | 复用方式 |
|---|---|---|
| 三步上传协议编排 | `lib/core/api/assets_upload_api.dart` | 改造复用(PUT 执行器抽象化) |
| 预签名 dio 实例 `_put` | `ms_api.dart:138-145` | 注入 dio 通道(下载侧三个调用点不动) |
| 队列/状态机/transfers.json | `lib/core/transfers/*` | 改造复用(加会话字段,状态机不动) |
| `completeResponseLost`/`UploadAmbiguousException` | `assets_upload_api.dart:17-44` | 原样复用 |
| Android 前台服务 | `transfer_foreground.dart` | 不动 |
| 前端(web)Uppy 链路 | web/ | 不动 |

### 组件清单(每文件 ≤500 行)

**App 包 A — PUT 通道抽象 + dio 实现(Android 现状原样)**
- NEW `lib/core/transfers/part_put_channel.dart`(~140 行):`PartPutRequest`(url/chunk/uploadId/partNumber/cancelToken)、`PartPutResult`(etag)、`PartPutChannel` 接口(`put`/`cancelActive(token)`/`batchCapable`)+ 工厂 `platformDefault({Dio? presignedHttp})`:iOS→bg 通道,其余→dio 通道;工厂参数可注入(测试覆盖用)。
- NEW `lib/core/transfers/dio_part_put_channel.dart`(~90 行):现 `assets_upload_api.dart:88-98/201-209` 的 dio PUT 原样搬移(显式 Content-Length、etag 响应头解析、CancelToken 透传)。

**App 包 B — background_downloader 适配(iOS 后台通道)**
- NEW `lib/core/transfers/bg_downloader_adapter.dart`(~130 行):`BgDownloader` 接口(`init`/`enqueue`/`cancelTasksWithIds`/`registerStatusCallback`)+ 真实实现包 `FileDownloader`(经典 API:`enqueue`+`registerCallbacks(group:'ms-upload-parts')`;**v9 初始化方式以 9.6.6 文档/源码为准**,v8 的 `start()` 若仍在则调用);仅 iOS 构造真实实例;unit test 全用 fake。
- NEW `lib/core/transfers/bg_part_put_channel.dart`(~300 行):iOS 实现——chunk 写临时文件(cache `bg-upload-parts/<uploadId>/part-<n>.bin`)→ `UploadTask`(PUT binary,`post:'binary'`/`httpRequestMethod:'PUT'`,group、retries 0、headers 带 Content-Length)→ enqueue → Completer 桥(注册的 taskStatusCallback:`complete` 态取 `responseHeaders['etag']`(小写键)→ PartPutResult;`failed` 态按 `exception` 映射异常,403=签名过期文案)→ finally 删临时文件;`cancelActive`→cancelTasksWithIds+清临时文件;静态 `clearStaleChunkDir()`(启动清理);幂等初始化。

**App 包 C — 协议编排改造(协议语义不动)**
- MODIFY `lib/core/api/assets_upload_api.dart`(净增 ~130 行):PUT 换 `PartPutChannel`;抽 `signGet`/`completeAndParse`/`abortSession` 私有方法消除 uploadBytes/uploadFile 双轨重复(abort 提为公开 `abortUpload(uploadId,bucket,key)` 供恢复中断用);`uploadFile`/`uploadBytes` 在 `channel.batchCapable` 时走**预签窗口循环**(K=4 常量:窗口内逐片 读chunk→sign→enqueue(不等完成),窗口末 `Future.wait` 收敛 etag/异常;窗口推进时上报进度);非 batch 平台走现顺序循环;新增可选 `onSessionCreated(uploadId,bucket,key)` 回调参数;所有钉子保留:显式 Content-Length、`partRanges`、`_readExact`、取消片间检查、`UploadAmbiguousException`、catch 尽力 abort。
- MODIFY `pubspec.yaml`(+2):`background_downloader: ^9.6.6`。**实施前核验插件 SPM 支持(仓库含 Package.swift)与 iOS 13+/Android minSdk 兼容(本仓 minSdk=29/iOS 15 无忧);若不支持 SPM 停手上报,不得擅自改平台结构(Podfile/CocoaPods)**。

**App 包 D — 会话持久化 + 队列接线**
- MODIFY `lib/core/transfers/transfer_task.dart`(+~18):`TransferUploadSession{uploadId,bucket,key}`;`TransferRequest` 增可变 `onSessionCreated` 回调字段;`TransferTask` 增 `uploadId/uploadBucket/uploadKey` 可空字段。
- MODIFY `lib/core/transfers/transfer_store.dart`(+~12):encode/decode 三字段(仅非 null 时写入);恢复中断口径不变。
- MODIFY `lib/core/transfers/transfer_queue.dart`(+~30):`enqueue` 建 task 时若 `req.onSessionCreated` 非空,包装为「写回 task 三字段+调度持久化+原回调」;新增 `setInterruptedAbort(Future<void> Function(String,String,String)?)`(可注入,测试桩);恢复路径(attachStore)对「非终态∧有 uploadId」任务 fire-and-forget abort(catch 只记日志);启动时(iOS,channel 内 gate)调 `clearStaleChunkDir`。
- MODIFY `lib/features/assets/upload_sheet.dart`(+~10):worker 闭包 create 成功后调 `req.onSessionCreated`;`enqueueLocalUpload` 处装配。
- MODIFY `lib/main.dart`(+~12):iOS gate 初始化 bg 通道(注册回调+清残留);session api 就绪后 `setInterruptedAbort((id,b,k)=>api.assets.abortUpload(...))`(读现状装配点接线,session 未就绪可延后)。

**Backend 包 F(小)**
- MODIFY `api/app/settings.py`(+2):`presigned_part_ttl_seconds: int = 7200`(注释:仅分片 PUT 签名;下载/缩略图共享 TTL 不动)。
- MODIFY `api/app/routers/assets.py` `sign_part`(:224/:227 两处):`presigned_normal_ttl_seconds` → `presigned_part_ttl_seconds`。
- NEW `api/tests/test_sign_part_ttl.py`(~60 行):settings 默认值断言 + sign_part 端点 `expires_in=7200` 断言(沿用现有 tests 基建/风格;容器内跑)。

### 组件依赖与数据流

`upload_sheet worker → AssetsUploadApi(uploadFile/uploadBytes) → PartPutChannel.platformDefault → [dio 通道 | bg 通道 → BgDownloader → iOS background URLSession]`;worker `onSessionCreated → TransferQueue(写 task 三字段)→ TransferStore(transfers.json)`;恢复:`TransferStore.decode → TransferQueue.attachStore → setInterruptedAbort → AssetsUploadApi.abortUpload`。包 A/B/C 依赖接口契约(§4 通道接口)可并行;包 D 依赖 A/C 的类型定义(串行后置);包 F 独立并行。

### 平台文件(核验结论:全不动)

`Info.plist`(无需 UIBackgroundModes;ATS 已放开)、`AppDelegate.swift`(插件自动注册+转发 `handleEventsForBackgroundURLSession`)、entitlements(不需要)、`Podfile`(不存在,SPM)、Android gradle(minSdk 29 满足)。

## 5. 数据库修改方案

不涉及。

## 6. 接口定义(后端)

无新端点。变更:`GET /api/v1/assets/uploads/{upload_id}/parts/{n}` 返回 `expires_in` 由 900 → **7200**(`presigned_part_ttl_seconds`,env `PRESIGNED_PART_TTL_SECONDS` 可覆盖)。动机:iOS 后台通道预签窗口内,后入队分片可能在签名后较久才真正发起 PUT(SigV4 在请求受理时校验过期;900s 在 iOS 后台限速极端场景(≈100KB/s)下不够 4×16MB 窗口,7200s 彻底消除 403 过期失败模式;URL 仅授权单一 object PUT,暴露面增量可忽略)。

## 7. 前端(App)改动点 / 后端改动点

- App:见 §4 包 A-E;UI 零改动(进度条行为:batch 窗口口径下进度按「已完成分片」推进,粒度略粗于现状,可接受)。
- 后端:见 §4 包 F;web 零改动。

## 8. 测试功能点

**App 单测(Windows 可跑,全部经接口 fake,不触真实平台通道)**:
1. 工厂分流:iOS→bg 通道,Android→dio 通道,注入覆盖生效。
2. dio 通道:PUT 形态(Stream body/Content-Length 头/etag 解析/取消透传)与现状逐项等价。
3. bg 通道(fake BgDownloader):complete 态从 `responseHeaders['etag']` 取值;failed 态异常映射(403→签名过期文案);取消→cancelTasksWithIds+临时文件清理;临时文件写/删时序;幂等 init;非 iOS 构造保护(抛/降级)。
4. 预签窗口循环(fake channel):K=4 窗口切分与推进、parts 顺序与 PartNumber 正确、窗口完成才上报进度、单分片失败→整任务失败且 abort、`UploadAmbiguousException` 透传、`onSessionCreated` 触发一次。
5. uploadBytes 单/多分片同口径(livp 小包轨走同一通道)。
6. transfer_task/store:三字段 roundtrip;decode 恢复中断口径不变。
7. transfer_queue:onSessionCreated 包装写回 task+持久化;setInterruptedAbort 注入后恢复中断触发 abort(含无 uploadId 任务不触发);现有队列测试全绿(回归)。
8. 全量:`flutter analyze` 0 告警 + 既有测试套件全绿。

**Backend**:
9. settings 默认 7200;`sign_part` 端点返回 `expires_in=7200`;`presigned_normal_ttl_seconds` 使用点(assets.py:1612 下载)不变 900。容器内 pytest 冒烟 + `ruff check` + `mypy app`。

**构建验证**:
10. Android:`flutter build apk --debug`(新插件进 Android 构建图,验证编译;勿用 release.mjs,防 bump 版本)。iOS 构建需 Mac,本机不可,列真机人工清单(§11)。

## 9. 模糊点与决策记录(用户已授权「不要提问」,以下由 PM 拍板)

- **D1 选型 background_downloader 9.6.x**:唯一同时满足「iOS 真·后台传输+binary PUT+活跃维护」的包;自研原生桥/其他包否决理由见 §2。
- **D2 iOS 全量走后台会话通道(前台后台统一)**:不做「前台 dio+切后台换通道」双状态切换(社区共识:两套状态对账得不偿失);Android 保持 dio+FGS 不动(已有等价后台能力,本次需求仅 iOS)。
- **D3 预签窗口模型(K=4)**:Dart 侧常规回调在挂起期间不保证执行(插件文档实证),纯「传一片签一片」挂起后最多再传 16MB 就断;预签 4 片入队原生队列,挂起期间传输不依赖 Dart 存活,唤醒/回前台补签推进;4×16MB=64MB 窗口深度在 7200s TTL 下无过期风险。
- **D4 ETag 来源=插件 `responseHeaders`(小写键)**,不做后端 ListParts 兜底(插件能力已文档实证);etag 缺失按失败处理(与现状「etag 为空字符串回传」不同——现状 dio 拿不到 etag 时回传空串,后端 complete 会因 MinIO 校验失败报错,行为等价)。
- **D5 后端新增独立 TTL 设置而非放宽共享 TTL**:下载/缩略图短 TTL 有安全意义,不动;7200 仅分片 PUT。
- **D6 会话三元组持久化+恢复 abort(两平台)**:后台通道会放大「进程被杀→分片已传但 complete 永不调用」的孤儿 multipart,持久化 abort 是低成本对账;不做 server 端 multipart 清理 cron(既有独立遗留,不在本周期)。
- **D7 create/sign/complete 仍走 dio(不进后台会话)**:均为短 JSON 请求,挂起击中窗口极小;挂起期失败按现状落 failed,回前台手动重试;避免协议状态机全回调化的大改。
- **D8 上传进度 iOS 通道按分片粒度推进**:batch 窗口口径,放弃片内字节级平滑(现状 dio 通道保持原样);不做原生 Live Activity(超出范围)。
- **D9 测试策略**:全链接口抽象+fake 单测(Windows 可跑);Android debug 构建验证插件集成;iOS 真机验证列人工清单(Mac 构建)。
- **D10 插件 API 用经典 API(`enqueue`+`registerCallbacks`+`updates`)而非实验性 High-Level Transfer API**:文档实证充分;9.6.6 字段名(`post:'binary'`/`httpRequestMethod:'PUT'`/`TransferHint.binaryUpload` 等)以实施时 pub cache 源码为准,如有出入按源码适配并在汇报注明。

## 10. 已知限制与遗留(P2,记录不强修)

- iOS 后台吞吐低于前台(系统限流,社区实测);低电量模式后台传输可能延迟/降速——预期管理,不算 bug。
- 用户上滑强杀:Apple 设计使 background session 全部取消,任务「进程中断」,下次手动重新发起(与现状一致)。
- 挂起恰好击中 create/sign/complete 短请求 → 任务 failed(现状语义),概率极低(D7)。
- server 端 multipart 孤儿清理 cron(既有遗留);dio sendTimeout 未设置(既有)。
- BGProcessingTask 定期兜底扫描补传(不做,当前模型已够)。

## 11. iOS 真机验收清单(需 Mac 构建,人工)

- T1 前台上传大文件(≥500MB)中途锁屏/切后台 ≥10 分钟:期间上传持续(回前台看进度增长连续,无从头重传),无超时报错。
- T2 后台放至传完:回前台任务 done、素材出现、缩略图正常。
- T3 弱网(蜂窝)+后台:任务继续或保持可恢复,无崩溃。
- T4 前台/后台各取消一次:任务 canceled,MinIO 无悬挂分片(可选后端 `list-multipart-upload` 核对)。
- T5 Android 回归:上传中切后台仍继续(FGS),行为与 0.1.20 一致。
- T6 杀进程重启:中断任务标「进程中断」;服务端对应 multipart 会话被 abort(可选核对)。

## 12. 验收修正记录(2026-11-28)

专职测试全量 1610 绿 / analyze 0 告警 / P0=0 后的验收后收口批次:1×P1 + 4×P2(修/修/修/拆)。

### P1 撤销失效的「resumed 补收」兜底(撤代码,不是绕过)

依据(pub cache background_downloader 9.6.6 源码逐行核验):

- `lib/src/base_downloader.dart:270-293` `retrieveLocallyStoredData()` 受 `retrievedLocallyStoredData`(:112)**一次性 flag** 守卫——落库补收全局只有一次机会,之后调用恒 no-op;
- `lib/src/file_downloader.dart:807/827` `start()` **无条件**先调 `resumeFromBackground()`(→ retrieveLocallyStoredData),而 `RealBgDownloader.init()` 启动时已调 `start()`:唯一一次补收机会在 init 即被消费;
- 此后挂起期间的更新由 iOS 原生 delegate 直投:插件自注册 AppDelegate(`BDPlugin.swift:71` `addApplicationDelegate`)并自动处理 `handleEventsForBackgroundURLSession`(BDPlugin.swift:921),系统唤醒窗口拉起 App 直接转发事件;
- `doTrackTasks:false` 下插件不维护可读回的本地任务库,不存在「二次补收」的数据面。

结论:验收前加的「resumed 观察者调 resumeFromBackground」兜底在真实插件上**恒为 no-op**,注释口径与插件行为矛盾、误导维护;主路径(原生 delegate 直投)不受影响。处置(撤代码):

- `bg_downloader_adapter.dart`:删接口方法 `resumeFromBackground()` 与 Real 实现;头注释如实改写为上述更新送达机制(①init 内唯一一次落库补收(引源码行号)②挂起期更新 iOS 原生 delegate 直投 ③doTrackTasks:false 无二次补收面);
- `bg_part_put_channel.dart`:删 lifecycle observer 全套(`_BgLifecycleObserver`/`_registerLifecycleObserver`/`_handleResumed`/`lifecycleRegistered` getter 及注册调用点);
- `bg_part_put_channel_test.dart`:删 lifecycle/resume 组 3 用例与 fake 的 `resumeCalls`/`initThrows` 面;`bg_upload_restore_test.dart` fake 的 `resumeFromBackground` override 随接口变更删除。

### P2 四项处置

- **P2-1(修)token 映射不残留**:`bg_part_put_channel.dart` put finally 与 cancelForToken 清理路径——移除 taskId 后若 `_tokenTasks[token]` 空集则整键 `remove`(进程级单例不再随上传次数无界累积空 Set+CancelToken);`@visibleForTesting tokenKeyCount` 最小计数 + 2 条行为用例(put 收尾清键/cancelForToken 清键)。
- **P2-2(修)失败后取消同窗兄弟分片**:`assets_upload_api.dart` `_putParts` batch 分支窗口 `Future.wait` 包 try-catch,失败先 `channel.cancelForToken(cancelToken)`(仅 cancelToken 非 null;dio 通道该方法 no-op,无需区分平台;对已终态任务 no-op)再 rethrow 原异常——保证「失败→兄弟分片原生任务取消→abort 服务端」顺序语义;异常类型与 abort 语义不变。
- **P2-3(修)cleanupUpload 接线**:`assets_upload_api.dart` 两轨(uploadFile/uploadBytes)catch 块在 `abortUpload(...)` 后追加 `await ch.cleanupUpload(uploadId)`(自带 try-catch;bg 通道删会话临时分片目录,dio 通道 no-op),消除「接口无人调」的误导。
- **P2-4(拆)测试文件行数口径**:`bg_upload_restore_test.dart` 527 行超 500——「bg 通道真实逻辑」组(2 用例及专用 fake/helper)整体移入新文件 `bg_channel_integration_test.dart`,语义一字不改(包 D 仲裁后的基线);restore 文件拆后 370 行,新文件 167 行。

### 测试同步与自测口径

- `bg_part_put_channel_test.dart`:删 lifecycle 组后通道行为断言不弱化(put 终态收敛/异常映射/取消联动/临时目录收口全保留),新增 P2-1 两用例;
- `assets_upload_api_test.dart` / `bg_upload_flow_test.dart`:「单分片失败」「分片失败(livp 轨)」类用例补 `cancelForToken` 被调断言(fake channel 记录调用,断言同一 token 实例)与 `cleanupUpload` 被调断言;成功路径无 abort/cleanup 的既有断言保留;
- 自测:`flutter analyze` 0 告警、`flutter test` 全量绿、全部改动文件 ≤500 行。
