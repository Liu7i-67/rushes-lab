# 移动端安卓真机体验优化批（10 项）

> qdev 需求文档 · 2026-10-21 · 基线 liuqi@73cfaa4 · worktree `rushes-lab-feat-mobile-ux-polish` · 分支 `feat/mobile-ux-polish`
> 来源：用户安卓真机测试最新版 APP（stamp 2026-10-21 14:15）反馈 10 项。
> 本批为**纯 Flutter 前端批**：无数据库修改、无后端接口改动（第 7 点依赖的 `GET /api/v1/assets/{id}/thumbnail-url` 已确认只要登录即可用，`assets.py:1490-1518`）。

## 背景与目标

移动端完整版 B0-B9 交付后用户真机走查，提出 10 项体验优化：预览页与系统 UI 的适配（虚拟按键遮挡、滑动切图）、权限与降级体验（相册引导英文、无下载权限预览失败）、信息架构（标题语义、实心文件夹图标对齐 web、去调试噪音）、以及通知与表单体验（系统级通知、密码明文切换、企微推送携带身份）。目标：全部 10 项落地且不回退既有功能。

## 功能点明细（逐条可验收）

### P1 预览页底部操作栏避开 Android 虚拟导航栏
- 现状：`lib/features/preview/preview_actions.dart:37-72` 底部三钮（下载/分享/申请权限）为裸 `Container+Row`，固定 padding 底 8，无 SafeArea，被虚拟按键遮挡。
- 改动：外层带色 Container（`Tk.darkSurface`，背景延伸到导航栏区域）内包 `SafeArea(top: false)`，内容 Row 保持 `EdgeInsets.fromLTRB(16, 4, 16, 8)`。无虚拟按键设备视觉不变。
- 验收：有虚拟导航栏的真机上三钮完整可见可点，不被遮挡；导航栏区域背景为 darkSurface 不露底色。

### P2 相册选择：直通系统权限 + 中文引导
- 现状：`lib/features/assets/upload_pick.dart:73-89` 调 `AlbumService.ensurePermission()`（`services/album.dart:25-31`，`PhotoManager.requestPermissionExtend()`）后进 `AssetPicker.pickAssets`；权限未过时 wechat_assets_picker 内置英文 PermissionGuide 界面（「选择照片访问权限」）。
- 改动（组合拳）：
  1. app 启动时全局设置 `AssetPicker.textDelegate = AssetPickerTextDelegate_CN()`（wechat_assets_picker 自带中文 delegate），picker 内置界面含权限引导页全部中文化；
  2. 权限已授权/limited 的用户点击上传 → 直接进选图（现状即如此，保持）；
  3. 权限被拒绝时不再抛 `StateError` + toast：改为弹自绘中文 `AlertDialog`：标题「需要相册访问权限」、正文说明用途、按钮「去设置」（`url_launcher` 打开 `android.settings.APPLICATION_DETAILS_SETTINGS`（`package:com.rushes.lab.tx`））与「取消」；iOS 侧引导文案同样中文、按钮仅「重新尝试」（重新走 requestPermissionExtend）。
- 验收：首次安装后点上传 → 直接弹系统权限弹窗；授权后直接进选图无英文界面；拒绝过再点上传 → 弹中文引导，「去设置」能跳到应用详情页。

### P3 预览页：去顶部左右按钮，支持横滑切换
- 现状：`lib/features/preview/preview_page.dart:107-135` AppBar title 内 `chevron_left/right` 两个 IconButton + `n / N` 计数；切换靠 `FilmstripPager` + setState，无滑动手势；大图 `InteractiveViewer(maxScale:4)+Image.network`（`preview_media.dart:235-244`）。
- 改动：
  1. 移除 AppBar 内两个 IconButton，保留 `n / N` 计数与文件名（形如 `3 / 12  文件名.jpg`）；
  2. 预览主体外层加 `GestureDetector(onHorizontalDragEnd:)`：左滑（dx 速度 < -阈值 或位移超阈值）→ `_pager.next()`，右滑 → `prev()`，边界即停；切页沿用现有 `_go`/`ValueKey` 重建逻辑；
  3. 与 `InteractiveViewer` 协作：未放大（scale≈1）时 `panEnabled: false` 让横滑手势穿透到外层 GestureDetector；放大后 `panEnabled: true` 拖动看图、不触发切页；捏合回到 scale≈1 后恢复可滑切（用 `TransformationController` 或 `onInteractionEnd` 维护缩放态）。双指捏合手势天然不被单指 drag 干扰。
  4. 底部胶片条点选切页（现有 moveTo）保持；视频/livp/文档等其他 PreviewKind 同样支持横滑（GestureDetector 在 PreviewMedia 外层统一处理）。
- 验收：单指左滑下一张、右滑上一张；放大后单指拖动为平移图片不切页；捏合还原后可再滑切；顶部无左右按钮，计数仍正确显示。

### P4 项目内文件夹页顶部显示项目名
- 现状：`lib/features/folders/folders_page.dart:118-119` `AppBar(title: const Text('文件夹'))`；`FoldersPage` 已带 `projectName` 构造参数（`app.dart:74-80` 路由解包）。
- 改动：title 改为 `Text(projectName)`，空/null 时回退「文件夹」；用 `FittedBox(scaleDown)` 防长名溢出。宫格页（assets_page 已显示 folderName）不动。
- 验收：进入项目后顶部标题为项目名；超长项目名缩小不溢出。

### P5 目录树含文件文件夹实心深色图标（对齐 web）
- 现状：`lib/features/folders/folder_row.dart:59` 所有夹统一 `Icons.folder_outlined, color: Tk.accent`（橙）；尾部「N 项」badge（`folder_row.dart:73-79`）用户认可保留。
- 改动（用户拍板口径）：`subtreeFileCount > 0` → `Icons.folder`（实心）+ `Tk.fg`（#1A1A1A 深色）；否则维持 `Icons.folder_outlined + Tk.accent`。敏感锁徽标逻辑不动。字段已到端（`folders_api.dart:12-20`，仅 list 端点回填），无需后端改动。
- 验收：含文件（子树计数>0）的文件夹显示实心深色图标，空文件夹保持橙色空心；「N 项」badge 保留；与 web 端「实心=含文件」语义一致。

### P6 项目页标题清理 + 移除 debug 图标（stamp 迁移）
- 现状：`projects_page.dart:19-23` `projectsTitle()` 显示「项目 · 最后编辑 <stamp> · <用户名>」（stamp=`kAppBuildStamp`，`main.dart:17-25` dart-define 注入）；项目页 AppBar 有 `logPushButton`（`Icons.bug_report_outlined`，`projects_page.dart:82`）。
- 改动（用户拍板：标题只显「项目」）：
  1. 标题固定为「项目」，去掉 stamp 与用户名段（函数简化，调用处同步）；
  2. **stamp 迁移**：标题不再承载构建时刻后，在「我的」页（`me_page.dart`）用户信息区底部加一行小字（`Tk.subtle`，如「构建 2026-10-21 14:15」，空 stamp 不显示），保持「确认装的是新包」的验收锚点（`mobile-app-acceptance-checklist.md` 同步更新该核验方式）；`kAppBuildStamp`/dart-define 机制本身不动；
  3. 移除项目页 AppBar 的 logPushButton；登录页右上角与我的页诊断区的日志推送入口**保留**（P10 还依赖该功能）。
- 验收：项目页标题为「项目」，无日期无用户名无 bug 图标；我的页显示构建 stamp；日志推送在登录页与我的页仍可进。

### P7 无下载权限用户预览回退缩略图（原图失败降级）
- 现状：普通图片/视频预览走 `download-link(as_attachment:false)` 原图 presigned（`preview_media.dart:96-106`），无下载权限时后端 403 → 「预览加载失败」降级卡（`preview_doc_views.dart:27-45`）；而底部缩略图条走 `thumbnail-url`（1024px，仅需登录）正常显示——出现「缩略图能看大图不能看」的诡异体验。
- 改动：`_loadInlineUrl()` 失败（catch，含 403 与网络错误）时，若 `asset.hasThumbnail` 则回退 `_loadThumb()`，并在预览区显示不打断的小字提示「原图不可用（无下载权限或加载失败），当前为缩略图预览」；无缩略图时维持原失败卡（文案不变）。livp 实况短片已有 403→静态缩略图降级（`preview_media.dart:66-69`），不动；heic/静态帧本就走缩略图，不动。
- 验收：仅查看权限用户打开图片：大图区显示缩略图放大 + 小字提示，不再出现「预览加载失败」卡；有下载权限用户行为不变（原图）。

### P8 上传/下载完成改系统级通知（后台通知 + 前台应用内，用户拍板）
- 现状：全 SnackBar——下载完成 toast（`services/downloads.dart:181`）、上传仅入队 SnackBar「已入队 x 个」（`upload_pick.dart:68/148`）、上传完成无提示（`transfer_queue.dart:203-215` 只改状态记日志）；无任何本地通知库，Manifest 无 `POST_NOTIFICATIONS`。
- 改动：
  1. 新依赖 `flutter_local_notifications`（pub.dev 当前稳定版，pubspec 注释写明用途与批次，遵循现有注释风格）；
  2. `AndroidManifest.xml` 加 `<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>`；
  3. 新增 `services/notifier.dart`：初始化（Android channel `ms_transfers`「传输完成」）、Android 13+/iOS 通知权限请求（幂等，只在未决时弹）、`notify(title, body)`；
  4. 通知时机（`AppLifecycleState != resumed` = 后台才发系统通知；`resumed` 前台维持现状 SnackBar/无提示）：下载完成 → 「下载完成：filename（保存结果摘要）」；上传任务终态 → 「上传完成：filename」/「上传失败：filename（简短原因）」；下载失败终态 → 「下载失败：filename（简短原因）」；
  5. **防轰炸**：同一批多文件完成聚合为一条汇总通知（如「上传完成：5 个文件」/「3 成功 · 2 失败」，实现可用短窗口聚合 ~3s 或按批次分组），不逐文件弹；
  6. 通知权限请求时机：首次创建传输任务（上传入队/下载入队）时请求一次，不在 app 启动即弹。
- 验收：Android 13+ 首次入队传输弹通知权限授权弹窗；切到桌面/锁屏后任务完成 → 系统通知栏出现结果通知，点开 app 可见传输页终态；前台完成行为与现状一致；批量完成只有一条汇总通知。

### P9 所有密码输入框支持明文切换
- 现状：全仓 4 处 `obscureText` 均无切换（`login_page.dart:119-127` 登录；`change_password_page.dart:104-111/113-120/122-130` 原密码/新密码/确认）。管理端临时密码是明文展示非输入框，不涉及。
- 改动：新增复用组件 `widgets/password_field.dart`（TextField/TextFormField 包装：默认遮挡，`suffixIcon` 为 `Icons.visibility_outlined`/`visibility_off_outlined` IconButton 切换，切换不丢已输入内容与焦点）；替换上述 4 处，外观与现有输入框一致。
- 验收：4 处密码框均有眼睛按钮，切换明文后已输入内容保持、再次切换恢复遮挡；登录/改密功能不回退。

### P10 企微日志推送携带用户名
- 现状：`services/wecom_push.dart` 两步（upload_media → file 消息），消息不含任何用户身份；`session.me` 仅 `id`/`name`（`models/me.dart:40-41`）。
- 改动：`pushLogFile()` 已登录（`session.me != null`）时，先发一条 text 消息：「【移动端日志】用户 {name}（uid {id}）· {yyyy-MM-dd HH:mm}」，随后照常传 file；未登录（登录页调试出口）维持现状只发 file。`log_push.dart` 对话框已登录时顺带显示当前用户名一行。
- 验收：登录状态推送日志 → 企微群先收 text 身份消息再收日志文件；未登录推送维持只收文件。

## 数据库修改方案

不涉及。

## 接口定义

不涉及（全部使用既有端点：`download-link`、`thumbnail-url`、`live-preview-url`；企微 webhook 为客户端直发既有通道）。

## 前端改动点 / 后端改动点

全部为前端（`material-storage/app`），文件清单见各条目；后端不涉及。新增文件：`widgets/password_field.dart`、`services/notifier.dart`；新依赖：`flutter_local_notifications`；Manifest 加 `POST_NOTIFICATIONS`；`rushes-spec/material-storage/mobile-app-acceptance-checklist.md` 同步 P6 的 stamp 核验方式变更。

## 测试功能点

1. P1：窄屏/带虚拟按键场景下预览操作栏可用性（widget 测试验证 SafeArea 结构存在）。
2. P2：中文 delegate 已设置（启动后 `AssetPicker.textDelegate` 为 CN）；权限拒绝路径弹自绘中文对话框而非异常 toast；「去设置」intent 构造正确。
3. P3：横滑回调触发 pager 前后移动且边界即停；AppBar 无切换按钮、计数渲染正确；放大态不触发切页（逻辑单测）。
4. P4：标题=projectName，null 回退「文件夹」，长名 scaleDown。
5. P5：`subtreeFileCount>0` → 实心 `Icons.folder`+`Tk.fg`；`=0` → `folder_outlined`+`Tk.accent`；badge 保留（widget 测试断言 icon 与 color）。
6. P6：`projectsTitle` 恒为「项目」（既有含 stamp/userName 的断言需更新）；项目页无 logPushButton；我的页 stamp 行（空 stamp 不显示）。
7. P7：inline 失败 + hasThumbnail → 走缩略图 URL 且提示文案出现；无 thumbnail → 失败卡（既有单测改造）。
8. P8：后台终态 → notifier 收到调用；前台 → 不通知；聚合逻辑（同批多完成一条）；权限请求幂等。
9. P9：PasswordField 切换 obscure、controller 内容保持；4 处替换后表单提交行为不变。
10. P10：已登录 → 先 text 后 file 两条请求体正确；未登录 → 仅 file。
11. 回归：`flutter test` 既有套件全过、`flutter analyze` 无新增告警。

## 模糊点与决策记录

| # | 模糊点 | 决策 | 依据 |
|---|---|---|---|
| 1 | 实心夹配色（web=灰 #6B6B68 vs 移动端现状橙） | 实心+`Tk.fg` 深色，空夹维持橙色空心 | 用户选「实心深色+空夹保持橙色」，对比直观改动最小 |
| 2 | 系统通知是否前台也发 | 后台（非 resumed）才发系统通知，前台维持应用内现状 | 用户选「后台系统通知+前台应用内」，避免前台双打扰 |
| 3 | 去「最后编辑」后标题用户名去留 | 标题固定「项目」，stamp 迁「我的」页作新包核验锚点 | 用户选「只显示项目」；stamp 锚点丢失是连带影响，迁移保住验收链 |
| 4 | P7 降级触发范围 | 任何 inline 加载失败（403/网络）都回退缩略图 | 通用降级更稳，无需区分错误类型 |
| 5 | P3 手势方案 | 外层 GestureDetector + InteractiveViewer `panEnabled` 随缩放态联动 | 避免 PageView+InteractiveViewer 手势冲突的成熟做法，改动面小 |
| 6 | P8 聚合粒度 | 同批完成聚合一条汇总通知（~3s 窗口或按批分组） | 防 99 张逐张轰炸 |
| 7 | P6 其余日志推送入口 | 登录页+我的页保留，仅移除项目页入口 | 用户只点名项目界面；P10 依赖该功能存续 |
| 8 | P2 中文化 API 偏差 | 需求原文「app 启动全局设 `AssetPicker.textDelegate`」为 8.x 旧 API；实测 9.8.0 无全局静态入口，改为唯一调用点 `AssetPickerConfig.textDelegate: AssetPickerTextDelegate()`（基类即 zh-Hans，已核包源码 `languageCode='zh'`），仓内仅一处 pickAssets，功能等效 | 开发实证 + PM 核包源码确认 |
| 9 | P8 Android 侧工程配套 | 插件要求 core library desugaring（build.gradle.kts 开启 + desugar_jdk_libs:2.1.5）与通知小图标 drawable（flutter_launcher_icons 产物在 mipmap 不可用） | 插件官方要求，APK 构建实证通过 |

## 附 · 构建与验收命令（Windows Git Bash）

```bash
cd material-storage/app
export PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export JAVA_HOME=E:/qbb/soft/java ANDROID_HOME=E:/qbb/soft/android_sdk
/e/qbb/soft/flutter/bin/flutter analyze
/e/qbb/soft/flutter/bin/flutter test
/e/qbb/soft/flutter/bin/flutter build apk --release \
  --dart-define=APP_BUILD_TIME="$(git log -1 --format='%cd' --date=format:'%Y-%m-%d %H:%M')"
# 产物 build/app/outputs/flutter-apk/app-release.apk；stamp 核验点=我的页（P6 迁移后）
```
