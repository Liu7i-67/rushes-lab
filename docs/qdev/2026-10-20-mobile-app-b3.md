# 浣花视界 App 完整版 · B3 上传+传输需求文档

> 2026-10-20 · qdev 链式第 2 批。上位方案 §3(核心流程)/§5(统一上传)/§7(传输中心)/
> §16 B3。worktree:`E:\qbb\github_not_me\rushes-lab-feat-mobile-app-b2-b9`(B2 后)。
> 交付判据:GB 级上传不 OOM;取消/重试可用。

## 功能点明细

1. **统一上传面板(§5)**:入口唯一=宫格页 AppBar「⬆」+空态引导按钮 → 半屏 bottom sheet
   两选:「从相册选择」(wechat_assets_picker RequestType.all 多选;iOS 实况照片→
   `entityToLivp` 打包 .livp 现役逻辑;普通图/视频原文件;Android 全原文件)与
   「选择文件」(file_picker any 多选,原文件直传含 .livp 本身)。选完即入队,
   面板可关,继续浏览;`folder.my_can_upload==false` 隐藏入口(B2 已有显隐,沿用)。
2. **uploadFile 流式(§5)**:`uploadFile(path,…)` 流式分片 16MB(RandomAccessFile
   逐片读,三步编排+失败 abort 语义与现役 uploadBytes 一致;分片 PUT 必带
   Content-Length 411 钉子);GB 级视频不 OOM;`uploadBytes` 仅留 livp 小包路径。
   filename 净化沿用 `LivpService.baseNameOf`(空标题兜底+`/` `\` 净化钉子)。
3. **TransferQueue(§7)**:app 级单例 ChangeNotifier(core/transfers/
   transfer_task.dart+transfer_queue.dart);TransferTask{id/kind(upload|download)/
   filename/where(项目/文件夹显示路径)/doneBytes/totalBytes/status(queued|running|
   done|failed|canceled)/error/startedAt};**全局 FIFO 并发 2**(上传下载混排);
   取消=CancelToken(上传尽力 abort 清悬挂分片);重试=重新入队从头来(无断点续传);
   清已完成;**任务不持久化**(仅内存,杀 App 即清——与 web Uppy 同语义,已定稿)。
4. **传输页(§7)**:tab3 替换占位:全部/上传/下载分段+进行中(进度条/百分比/取消钮)+
   已完成(重试/移除);TabBar 传输格 badge=running 数;速度/剩余时间不做(App 简化,
   web 下载列表有速度属有据差异,§17 已登记)。
5. **队列指示(§5)**:宫格顶部迷你进度条(有 running 上传时显示 n/m)。
6. **数据新鲜度(§8.1)**:上传 complete 成功 → invalidate assets scope → 宫格刷新
   (落地 B2 预留的 RefreshBus assets:<folderId> 订阅,宫格页订阅)。
7. **架构(§9)**:core/transfers/ 两文件;features/transfers/(transfers_page/
   transfer_card);features/assets/upload_sheet.dart(统一面板,替代现役两路入口逻辑);
   单文件 ≤200 目标/300 硬顶(注意 preview_media.dart 431 行 B2 遗留超顶,B4 拆);
   不引状态管理框架。
8. **上传 complete 响应丢失(§4.1 已定稿)**:complete 阶段网络断(请求已达后端但响应
   丢失)→任务标 failed+提示「可能已上传,请先在素材列表核实」,**禁止自动重传**
   (UploadUrlRequest 无幂等键);实现上 complete 的 DioException 且 kind=连接类
   (receiveTimeout/connectionError)按此语义,后端 4xx/5xx detail 照常透传。

## 数据库/后端改动

不涉及。契约自查:`material-storage/api/app/routers/assets.py` uploads 三步+abort。

## 测试功能点

1. TransferQueue 状态机:queued→running→done/failed/canceled 全转移+FIFO 并发 2
   (第 3 个任务等待,完成即补位)。
2. 取消语义:running 上传取消→CancelToken 触发→abort 清分片尽力(失败不阻塞取消态)。
3. 重试=从头重新入队(非续传);清已完成只清终态。
4. uploadFile 分片边界:文件大小恰为 16MB 整数倍/余 0 字节最后片不空发;流式不整体
   载入内存(以实现结构保证+单测分片迭代)。
5. complete 响应丢失语义(连接类异常→failed+特定文案,禁自动重传)。
6. 宫格迷你条 n/m 计数;badge=running 数。
7. RefreshBus 订阅生效(上传成功→宫格 invalidate 收到)。
8. 回归:现役 122 用例全绿;livp 打包/上传链路不回归。

## 决策记录

| # | 决策 | 理由 |
| --- | --- | --- |
| 1 | 下载任务类型本批先入模型(TransferKind.download)但无下载入队方(预览页下载钮 B4 点亮) | 模型一次定型,B4 只接入队 |
| 2 | 迷你条=宫格 AppBar 下方细进度条 | 方案 §5「宫格顶部迷你进度」 |

## 项目约定

同前批(Flutter 路径/镜像变量/analyze+test/不 commit/单文件纪律)。
