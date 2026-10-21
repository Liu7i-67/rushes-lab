# 移动端二期优化（真机验收反馈 4 项）

> qdev 需求文档 · 2026-10-21 · 基线 feat/mobile-ux-polish@9066eab（一期） · worktree `rushes-lab-feat-mobile-ux-polish`
> 来源：用户安卓真机验收一期后反馈。本批为**纯 Flutter 前端批**：无数据库修改、无后端接口改动（后端会话 TTL 已核=7 天，`settings.py:78`，重登非过期问题）。

## 背景与目标

一期 10 项验收通过后用户提出 4 项：①sheet 弹层内复制成功无感知；②相册权限与百度网盘对比缺「音乐和音频」申明；③项目页刷新按钮冗余；④后台下载完成通知收不到 + 切后台后重登/传输记录丢失。目标：4 项全落地，含传输记录持久化与前台服务保活两项用户拍板实施的能力。

## 功能点明细（逐条可验收）

### R1 复制反馈在 modal 态可见（根因=SnackBar 被弹层遮挡）
- 现状：`temp_password_sheet.dart:61-71` 复制后有 SnackBar「已复制」，但该 sheet 经 `showModalBottomSheet`（:16）弹出，SnackBar 渲染在页面底部被 modal 遮挡——用户看不到（`request_link_sheet.dart:92-93` 注释已印证该坑：modal 态下 snackbar 不可见）。
- 改动：
  1. 新增复用组件 `widgets/copy_button.dart`：IconButton，点击写剪贴板后**就地反馈**=图标 `copy_outlined`→`check`（Tk 绿或 accent）约 1.5s 回切，期间禁重复点击；失败保留原样+错误日志；
  2. 替换 sheet/modal 态的复制点：`temp_password_sheet.dart`（临时密码）、`artist_account_field.dart:147`（艺人账号面板，处于新建项目 sheet 内）、`share_create_sheet.dart:74`（分享链接 `_copyLink`；其复制失败降级文案保留，成功 SnackBar 改就地）；
  3. 页面级复制点不动（`bind_code_page.dart:139` SnackBar 可见、`request_link_sheet.dart` 由结果视图承载是有意设计，均保持）。
- 验收：创建用户后 sheet 内点复制→按钮图标变 ✓ 可感知；艺人账号/分享链接同；无任何 modal 遮挡导致的「无反馈」。

### R2 相册权限：补音频申明，修 Android 13 隐性炸点
- 现状：`RequestType.all` 含 audio，但 Manifest 未申明 `READ_MEDIA_AUDIO`/`READ_MEDIA_VISUAL_USER_SELECTED`——**Android 13 整机上 picker 内部权限请求含 audio，未申明立即 DENY → 整体判 Denied → StateError → 「相册选择失败」**（photo_manager 3.12 `PermissionDelegate33` 实证）；Android 14+ 归并 Limited 可用但音频条目永远不可见。
- 改动（用户拍板：加申明支持音频）：
  1. Manifest 加 `READ_MEDIA_AUDIO`、`READ_MEDIA_VISUAL_USER_SELECTED`（**此项由 R4 前端 B 统一改 Manifest，本条前端 A 不碰 Manifest**）；
  2. `AlbumService.ensurePermission()` 显式传 `PermissionRequestOption(androidPermission: AndroidPermission(type: RequestType.all))`——与 picker 内部请求口径一致，系统弹窗一次展示「照片和视频 / 音乐和音频」全部权限组（此前 ensurePermission 用 common 图+视频、picker 内部又用 all，两次口径不一致）；
  3. 保持 `RequestType.all`（音频可选可传）。
- 预期管理（写给用户，非代码）：**加申明不会消除首次授权弹窗**——运行时权限申明了才需要授权，首次一次是 Android 机制（百度网盘同样弹）；本改动消除的是 Android 13 报错与音频不可见。photo_manager 3.12 无免权限系统 Photo Picker 路径（调研实证，presentLimited 亦为权限路径）。
- 验收：Android 13 真机选图不再「相册选择失败」；Android 13/14 弹窗含「音乐和音频」；音频文件在选图器可见可选可上传；limited（选择部分照片）路径正常。

### R3 项目页去刷新按钮，下拉刷新全覆盖
- 现状：`projects_page.dart:84` AppBar 刷新钮与 `:96-97` RefreshIndicator 并存同调 `_reload`；但 RefreshIndicator 只包非空列表分支（loading/error/empty 三分支无下拉，刷新钮是这些状态的唯一刷新入口）。
- 改动：删 AppBar 刷新 IconButton；RefreshIndicator 上提包裹三分支（loading/error/empty 也支持下拉刷新——必要时用 AlwaysScrollableScrollPhysics + 可滚动容器包装）；同步更新 `projects_page_ux_test.dart:45-46` 回归锚（断言改为无刷新钮+空态可下拉）。
- 验收：项目页无右上角刷新钮；空态/错误态/加载态均可下拉刷新；正常列表下拉刷新不回退。

### R4 后台传输体验（通知可达 + 会话可观测 + 记录持久化 + 前台服务保活）
- 现状四个断点（调研实证）：
  - a) 通知权限被拒后全链路静默：`notifier.dart` ensurePermission 不查结果不记态，被拒后 OS 永不再弹，后台完成通知静默丢，用户零感知（`notifier.dart:198-218`、`_send` 仅记日志）；
  - b) 会话恢复失败被静默吞：`session.dart:148-157` `restore()` 任何异常直接 `me=null` 留登录页，无日志无原因——用户「切出重开要求重登」无法定位（后端 TTL=7 天排除过期，最可能=进程被杀冷启动恢复链路失败，如 `initPersistence` 插件通道失败落内存兜底）；
  - c) 传输队列纯内存：`transfer_queue.dart` 文件头注明「任务不持久化(仅内存,杀 App 即清)」，杀进程记录全丢（用户实测传输页无记录）；
  - d) 无保活：无 foreground service/wakelock，下载在主 isolate 尽力而为，Android 随时可杀进程。
- 改动：
  - **R4a 通知可达性**：`ensurePermission()` 消费请求结果（授权态入内存记录）；请求后仍未授权→弹一次中文引导框（标题「开启系统通知」正文说明后台传输完成提醒用途；按钮「去设置」复用应用详情页跳转（一期 `openAlbumPermissionSettings` 同款）+「取消」；会话内至多一次）；「我的」页加「传输通知」状态行（已开启 ✓ / 未开启→点击去设置），状态实时查询（`getNotificationsPermission`）。
  - **R4b 会话恢复可观测**：`restore()` catch 记 `AppLog.error`（含异常 toString、持久化 jar 是否初始化、cookie 文件目录是否存在、`auth.me()` 的 statusCode 若可用）；`initPersistence` 失败分支同样记日志；不改恢复语义（失败仍留登录页），只为下次真机重登时日志可定位（配合企微日志推送闭环）。
  - **R4c 传输记录持久化**：TransferQueue 任务快照落盘（`getApplicationSupportDirectory()/transfers.json`，写入时机=入队/状态变更/收尾去抖）；启动时恢复：终态（done/failed/cancelled）原样还原展示，非终态（pending/running）标 failed（原因「进程中断」）允许重试；快照含 kind/filename/status/progress/error/时间戳（设计时注意 livp 等任务的源信息若不可序列化，恢复后重试可降级为提示重新发起——实现自选并在代码注释说明）；上传与下载统一走队列（现状已如此，持久化点单一）。
  - **R4d 前台服务保活**（用户拍板实施）：
    - 引入前台服务能力（插件选型开发定，候选 `flutter_foreground_task`，备选 `flutter_background_service`；在需求文档决策记录补最终选型与理由）；
    - Manifest：`FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_DATA_SYNC` 权限（targetSdk 36，Android 14+ 强制 type）；service 声明按插件要求（含 `foregroundServiceType="dataSync"`）；
    - 启停联动：队列存在活跃任务（pending/running）→ 启动前台服务（常驻通知「正在传输 N 个任务」，独立 channel「传输进行中」）；全终态→必须停止服务（不留常驻）；通知内容可含简单进度（已考虑实现成本，可选）；
    - 与 P8 完成通知协同：完成通知照常发（服务通知与完成通知两 channel 并存，服务随队列清空停止）；
    - iOS：无前台服务概念，**不做保活**（维持现状尽力而为），代码平台分支隔离；
    - Android 版本注意：Android 14+ dataSync 前台服务有 6h/24h 系统限时（超时系统停服务不杀进程），实现处理 service 被系统停止的边界（至少不崩溃、队列继续尽力执行）。
  - **Manifest 统一由本包改**：`READ_MEDIA_AUDIO`+`READ_MEDIA_VISUAL_USER_SELECTED`（R2）+ 前台服务权限（R4d）一并由 R4 前端 B 添加，避免并行冲突。
- 验收：拒绝过通知权限的用户下次入队传输→弹中文引导可去设置；「我的」页可见通知状态；杀进程重开→传输页保留历史记录与终态；批量下载中切后台→前台服务通知出现、下载继续、完成后系统通知可达（权限已开时）；会话重登复现时日志有可定位原因；队列清空后前台服务通知消失。

## 数据库修改方案

不涉及。

## 接口定义

不涉及（全部客户端侧；后端仅被读取验证：会话 TTL=7 天）。

## 前端改动点 / 后端改动点

全部前端（`material-storage/app`）。新增文件：`widgets/copy_button.dart`、传输持久化与前台服务相关代码（R4c/R4d）。新依赖：前台服务插件（R4d，选型待开发回报）。后端不涉及。

## 测试功能点

1. R1：copy_button 图标切换与回切、防重复点击、失败路径；temp_password/artist_account/share_create 替换后复制功能不回退；bind_code/request_link 不变。
2. R2：ensurePermission 传 all 的 AndroidPermission 断言；albumPickerConfig 仍 all；Manifest 权限四项齐（A 不改 Manifest，B 改后统一验）；真机项=Android 13 选图不再报错、音频可见。
3. R3：项目页无 Icons.refresh；空态/error 态包装后可下拉（widget 测试模拟拖拽触发 onRefresh）；列表态回归。
4. R4a：ensurePermission 结果消费与记录；被拒弹一次引导（二次入队不再弹）；我的页状态行渲染与点击回调；已授权不弹。
5. R4b：restore 失败路径日志断言（含 cookie 目录存在性）；initPersistence 失败日志；恢复语义不变（失败仍 me=null）。
6. R4c：快照写入时机；启动恢复=终态还原/非终态标 failed「进程中断」；文件损坏/缺失的容错（坏 JSON 清空重来不崩溃）；恢复后重试链路。
7. R4d：活跃任务→启服务、全终态→停服务的状态机断言（插件接口 mock）；平台分支（iOS 不启）；服务被系统停止的容错。
8. 回归：一期全部 478 用例不回退；flutter analyze 0 告警；release APK 构建。

## 模糊点与决策记录

| # | 模糊点 | 决策 | 依据 |
|---|---|---|---|
| 1 | 上传是否支持音频 | 加 READ_MEDIA_AUDIO+VISUAL_USER_SELECTED 申明，保持 RequestType.all | 用户拍板；顺带修 Android 13 炸点 |
| 2 | 传输记录持久化 | 本期实施（快照落盘+启动恢复） | 用户拍板；解决「传输界面没有记录」 |
| 3 | 后台保活 | 本期直接实施前台服务（不做仅调研） | 用户拍板（超出推荐项） |
| 4 | R1 反馈形式 | 复制按钮就地图标切换（✓ 1.5s） | modal 态 SnackBar 不可见是根因，就地反馈不依赖 scaffold |
| 5 | R2 ensurePermission 口径 | 显式 AndroidPermission(type: all) 与 picker 一致 | 消除两次请求口径不一致 |
| 6 | 用户预期管理 | 加申明≠免首次授权弹窗（Android 机制，百度网盘同） | 调研实证；文档明示避免误解 |
| 7 | R4a 引导频率 | 被拒后会话内至多弹一次引导 | 防骚扰 |
| 8 | R4c 恢复语义 | 非终态任务标 failed（进程中断）可重试，不做断点续传 | 断点续传改动大另期；记录与可重试已满足诉求 |
| 9 | R4d 平台范围 | 仅 Android；iOS 维持现状 | iOS 无前台服务概念 |
| 10 | Manifest 编辑权 | 全部权限改动归 R4 前端 B（含 R2 的两项）避免并行冲突 | 工程协调 |
| 11 | 前台服务插件选型 | **flutter_foreground_task ^11.0.3**（定稿）：只需保活+常驻通知，接入面最小；自带独立 channel 与 P8 完成通知零冲突；与本仓工具链（Flutter 3.47.7/Dart 3.13/AGP 9.1）兼容。备选 flutter_background_service 需手写 service 通信协议，成本更高 | 开发实测+APK 构建通过 |
| 12 | R2 补充裁决：ensurePermission 判定 | `state.isAuth` → `state.hasAccess`（authorized\|\|limited）——isAuth 仅认 authorized，Android 14+ partial（部分照片）归并 limited 会被误拒进不了选图（一期 P2 潜在 bug，测试钉红实证） | PM 裁决（2026-10-21 二期），依据=一期注释语义+R2 验收「limited 路径正常」+photo_manager 3.12 hasAccess 定义 |

## 遗留项（专职测试后记录，2026-10-21）

- **P2 FGS 被系统停服后本轮无法重启保活**（`transfer_foreground.dart:184-211`）：Android 14+ dataSync 6h 限时（或系统停服）后 `_running` 仍 true，后续 sync 走 update 对已死服务必失败，直到队列全终态才复位——超 6h 的持续大批量传输期间保活静默失效（队列照常尽力执行，不崩溃）。修复方向：update 连续失败 N 次复位 `_running` 改走 start。另建议 FGS onDestroy 事件同步主 isolate 状态。
- **P3 TransferStore.write 同步抛错锐边**：write 允许 FutureOr 同步闭包，同步抛时 catchError 未挂上会沿 _persistNow 冒泡；生产 openDefault 恒 async 不触发，仅测试注入同步桩可炸。建议 write 内包 try/catch 或注释锁「必须异步」。
- **P3 Notifier 真实平台通道分支零自动化**：真实透传分支依赖真机清单第 7/8 条验证（注入桩已覆盖分支契约）。

## 附 · 构建与验收命令

同一期（见 `docs/qdev/2026-10-21-mobile-ux-polish.md` 附录）；stamp 核验点=「我的」页「构建 <stamp>」。
