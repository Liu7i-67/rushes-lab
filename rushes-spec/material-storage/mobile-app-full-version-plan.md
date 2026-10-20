# 浣花视界 App 完整版实施方案(v1)

> 状态:**待评审**(2026-10-20 起草)。
> 输入:MVP 已打通 iOS livp 上传/下载(`material-storage/app/`,至 658d865);
> UI 设计稿(Open Design 项目 `536948e5-…`,12 屏,暖中性 + 焦糖橙,令牌对齐 web `tokens.css`);
> 本轮用户定调:核心流程 = 上传/下载,必须简单明了;统一点收拢上传入口;补齐 Android;
> 后端地址自动探测(内网 HTTP → 公网 HTTPS 兜底),去掉手动选择;日志上传收拢到非主界面。
> 关联:`ios-livp-app-mvp-feasibility.md` / `ios-livp-app-build-handbook.md`(构建链)、
> `mobile-adaptation-plan.md`(web 响应式,与本方案无关,勿混)。

---

## 0. 背景与目标

MVP 是单链路验证壳(登录 → 项目/文件夹 → livp 上传/下载),完整版把它长成可日常使用的双端 App:

| 维度 | MVP 现状 | 完整版 v1 目标 |
| --- | --- | --- |
| 平台 | iOS 真机为主,Android 仅"能跑" | iOS + Android 双端一等公民 |
| 浏览 | 文字列表 | 缩略图宫格 + 预览 + 盲搜 |
| 上传 | 专属「上传 livp」按钮 | 统一上传入口(相册图/视频/实况/任意文件) |
| 下载 | 临时目录(iOS livp 除外) | 双端正确落盘(相册 / 图库 / Downloads) |
| 传输 | 页内日志行 | 传输中心(队列/进度/重试) |
| 后端地址 | 登录页 dev/prod/自定义手填 | 启动自动探测,无 UI 选择 |
| 日志推送 | 登录页/首页 AppBar 常驻 | 收拢到「我的」页 + 登录页底部小字 |

**后端零改动**:v1 全部走既有端点(§10),不需要迁移、不需要新路由。

## 1. 范围:12 屏设计稿 → v1 裁剪

设计稿 12 屏按「核心流程优先」裁剪。v1 = P0 列;P2 列明确不做、留二期。

| 设计稿 | 内容 | 级别 | 说明 |
| --- | --- | --- | --- |
| 01 登录 | 账号密码一步进入 | **P0** | 去掉环境切换(§4);底部小字诊断日志入口 |
| 02 项目 | 项目列表 = 首页 tab | **P0** | 权限徽标可编辑/可管理/仅查看/已归档;搜索框入口 |
| 03 项目内文件夹 | 目录列表(数量徽标) | **P0** | 行内 `N 项`(subtree_file_count);容量后端无此字段,不显示 |
| 04 素材浏览 | 宫格 + 多选 + 操作栏 | **P0** | 操作栏 v1 = 下载 + 删除;分享/移动 P2(§16 D2) |
| 05 预览 | 暗色画布 + 胶片条 + 元数据 | **P0** | 大图用缩略图 URL;视频播放 P2;收藏/评论 P2 |
| 06 搜索 | 盲搜 + 结果高亮 | **P0** | 后端 `/assets/search` 现成;点结果进预览(结果序列做胶片条) |
| 07 审批 | 审批中心 | P2 | 非核心流程 |
| 08 传输 | 传输中心 | **P0** | 上传/下载统一队列(§7) |
| 09 分享 | 分享链接管理 | P2 | 移动端非首发 |
| 10 通知 | 通知中心 | P2 | tab 徽标先占位不亮 |
| 11 我的 | 账号/设置/日志/退出 | **P0** | 日志推送收拢至此;显示当前服务入口(§4) |
| 12 管理后台 | 移动摘要 | P2 | PC 端职责 |

底部 TabBar 四格:**项目 / 搜索 / 传输 / 我的**(与设计稿一致)。

## 2. 核心流程的用户路径(简单性验收线)

- **上传两步**:素材页右上「⬆」→ 半屏面板二选一(从相册选择 / 选择文件)→ 选完即入队,
  宫格顶部出现进行中迷你进度,可继续浏览;结果 toast + 列表刷新。
  iOS 相册里的实况照片自动走现有 livp 打包逻辑,用户无感知(§5)。
- **下载一步**:宫格点开预览 → 「下载」;或多选 → 操作栏「下载」。落盘规则对用户透明:
  iOS 图/视频/实况 → 相册;Android 图/视频 → 图库;其余 → Downloads / iOS 存到"文件"。
  所有下载在传输 tab 可查进度,失败可重试。
- 任何时刻离开页面不中断传输(队列在 app 级单例,§7)。

**不做的事**(防复杂度回潮):断点续传、后台上传(iOS background session)、相册自动备份、
文件夹拖拽、批量移动 —— 全部 P2 或不做。

## 3. 信息架构与导航

```
Login(未会话)
└─ HomeShell(IndexedStack 保 4 tab 状态)
   ├─ tab 项目:ProjectsPage
   │    └─ push FoldersPage(projectId)
   │         └─ push AssetsPage(folderId)        # 宫格 + 多选
   │              └─ push PreviewPage(assets, index)
   ├─ tab 搜索:SearchPage
   │    └─ push PreviewPage(结果序列, index)
   ├─ tab 传输:TransfersPage
   └─ tab 我的:MePage(日志推送 dialog / 退出登录)
```

- 路由:保留命名路由 + `Navigator.push`(MVP 同款,够用;不引 go_router)。
- HomeShell 用 `IndexedStack` 保住各 tab 滚动位置与缓存;push 页盖在其上。
- 会话恢复:启动 → 探活 → `me()` 成功直进 HomeShell,否则 Login(MVP 逻辑保留)。

## 4. 后端地址自动探测(定稿口径)

**候选与顺序**(每次冷启动探测,不持久化结果):

1. `--dart-define=MS_API_BASE=…`(仅开发构建注入,PC 调试隧道口;不进任何 UI)
2. `http://192.168.110.221`(内网正式环境,工作室 WiFi 直连,最快)
3. `https://bucket.taoxiplan.com`(公网 HTTPS 反代同一正式环境,兜底)

**探测方式**:对每个候选拿独立裸 Dio 发 `GET /healthz`(已核实:免鉴权,返回
`{"status":"ok","version":…}`),connectTimeout 3s;第一个 200 即选定,全失败进 Login
并显示「服务不可达 · 重试」横幅(点按重新走一遍探测)。

**删除的东西**:

- 登录页 dev/prod/custom 分段按钮与服务地址输入框(整块 UI 消失,登录页只剩账号密码);
- `shared_preferences` 的 `ms_api_base` 手动选择持久化(键废弃不读);
- `kDevEntry`(47.108.196.211:8080)预设——公网 HTTP 入口不再使用,dev 调试走 dart-define。

**保留的东西**:

- cookie 会话持久化(PersistCookieJar,重启免登录);
- 我的页只读显示当前入口来源(「内网直连 / 公网」+ host),排障用;
- iOS ATS `NSAllowsArbitraryLoads`、Android `usesCleartextTraffic`(内网裸 IP http 必需,已有)。

**边界情形**:探测成功但登录时服务又不可达(如切网)→ 登录错误文案带「重试探测」;
运行中连续连接层失败 → 传输任务标记 failed 可重试,不做自动热切换(避免半途换 baseUrl
把 cookie/上传状态搞乱;下次冷启动自然纠正)。

## 5. 统一上传(收拢专属 livp 入口)

**入口唯一**:素材页 AppBar 上传按钮(设计稿 04)+ 空文件夹空态引导按钮。点开半屏面板:

| 选项 | 选择器 | 行为 |
| --- | --- | --- |
| 从相册选择 | wechat_assets_picker,`RequestType.all`(图+视频,多选) | **iOS**:实况照片(`AssetEntity.isLivePhoto`)→ 现有 `entityToLivp` 打包 `.livp` 上传;普通图/视频 → 原文件上传。**Android**:全部原文件上传(安卓无实况概念,motion photo 整档即原文件) |
| 选择文件 | file_picker,`type: any`,多选 | 原文件上传(含 `.livp` 文件本身,PC/Android 链路保留) |

**上传实现改造**(`MsApi`):

- 现有 `uploadBytes` 整读内存 → 仅保留给 livp(几十 MB 量级);新增 **`uploadFile(path,…)` 流式**:
  `File.length()` 报 size_bytes,按 16MB 分片 `RandomAccessFile` 逐片读,三步编排
  (create → sign+PUT → complete)不变,失败 abort 清悬挂分片(现有哲学)。
  **大视频(GB 级)必须走这条**,否则 OOM。
- content_type 按扩展名映射(jpg/png/heic/mov/mp4/pdf/zip/livp→application/zip…),
  未知回落 `application/octet-stream`;filename 净化沿用 `LivpService.baseNameOf` 钉子
  (空标题兜底、`/` `\` 分隔符替换,勿回退)。
- `folder.my_can_upload == false` 时上传按钮置灰隐藏(模型字段已有);
  sensitive folder 沿用锁图标。

## 6. 下载与双端落盘(Android 缺陷修复重点)

**根因**:MVP 把下载写进 `Directory.systemTemp`(应用私有 cache)——Android 图库与
Download 目录天然不可见,iOS 同理只在 app 沙盒。v1 按媒体类型 + 平台路由落盘:

| 资产 | iOS | Android |
| --- | --- | --- |
| `.livp` | 解包 → `PhotoManager.editor.darwin.saveLivePhoto` 恢复实况(现有) | **解包 → 静态图 + 视频分别存图库**(推荐,§16 D1;安卓无实况恢复通道) |
| 图片/视频 | `PhotoManager.editor` 存相册(`saveImageWithPath` / `saveVideo`) | 同左(photo_manager 双端 API);失败兜底 media_store_plus 直写 Pictures/Movies |
| 其他文件 | share_plus 系统分享面板(用户选「存储到文件」) | **media_store_plus 写入 MediaStore Downloads**(文件管理器/系统下载页可见) |

- 下载先落 app cache(现有 `downloadTo`,带进度回调),**成功落盘后删临时文件**;
  落盘动作在传输任务里完成,失败 = 任务 failed 可重试(临时文件重下)。
- 多选批量下载:逐个入队,全部走传输中心,不弹 N 个 toast。
- Android 权限:READ_MEDIA_IMAGES/VIDEO(13+)已在清单;MediaStore 写入无需存储权限
  (scoped storage);iOS 增量权限 `NSPhotoLibraryAddUsageDescription` 已有。
- 每次落盘成功 toast 说明去处(「已存入相册」「已存入 Download/浣花视界」),解决"下载完找不到"。

## 7. 传输中心

`TransferQueue`:app 级单例 `ChangeNotifier`(main 里构造,不引状态管理框架)。

```dart
class TransferTask {
  String id;            // uuid
  TransferKind kind;    // upload / download
  String filename;
  String where;         // 显示用:项目 / 文件夹 路径
  int doneBytes, totalBytes;
  TransferStatus status; // queued / running / done / failed / canceled
  String? error;
  DateTime startedAt;
}
```

- 并发:全局 FIFO,同时跑 2 个(上传下载混排;简单够用)。
- 取消:dio CancelToken;上传取消尽力调 abort 清 MinIO 悬挂分片(现有 catch 逻辑);
  **重试 = 重新入队从头来**(断点续传 P2)。
- 页面(设计稿 08 简化):分段 全部/上传/下载;「进行中」卡(进度条 + 百分比 + 取消)
  与「已完成」卡(成功/失败 + 重试);清已完成按钮。速度/剩余时间 v1 不做。
- TabBar 传输格 badge = running 数;宫格页顶部迷你条 = 当前 running 的第一个任务。

## 8. 代码架构与组件化

**硬约定:单文件目标 ≤ 200 行,硬顶 300;超了拆子组件文件。** 页面文件只留骨架与状态,
行/卡/条目全部独立小组件文件。MVP 的 5 个大页面按此拆散重排:

```
lib/
  main.dart                  # bootstrap:AppLog.init + 探活 + runApp(< ~60 行)
  app.dart                   # MaterialApp + ThemeData + 路由表
  theme/tokens.dart          # §9 设计令牌(颜色/圆角/间距常量)
  core/
    session.dart             # 探活顺序 + baseUrl + cookie 持久化 + Me 缓存
    api/ms_api.dart          # REST 客户端(登录/浏览/上传三步/下载/缩略图/搜索/删除)
    api/content_types.dart   # 扩展名 → content_type 映射
    transfers/transfer_task.dart
    transfers/transfer_queue.dart
    fmt.dart                 # 字节数/时间格式化(现 assets_page 里的 _fmtSize 迁入)
  models/                    # me / project / folder(+subtree_file_count) /
                             # asset(+tags/user_labels) / search_result
  services/                  # album / livp / app_log / wecom_push(现役平移)
    media_save.dart          # §6 落盘策略路由(平台×类型矩阵,纯函数可单测)
    downloads.dart           # media_store_plus 封装(Android)
  features/
    auth/login_page.dart
    shell/home_shell.dart    # Scaffold + TabBar + IndexedStack
    projects/projects_page.dart + project_row.dart
    folders/folders_page.dart + folder_row.dart
    assets/assets_page.dart  # 状态:列表/多选/上传触发
    assets/asset_grid.dart + asset_tile.dart    # 宫格 3 列,缩略图 + 类型角标 + 勾选
    assets/upload_sheet.dart # 半屏统一上传面板
    preview/preview_page.dart + filmstrip.dart + meta_panel.dart
    search/search_page.dart + result_row.dart
    transfers/transfers_page.dart + transfer_card.dart
    me/me_page.dart + log_push_dialog.dart(自 pages/log_push.dart 迁入)
  widgets/                   # badge / empty_state / error_view / retry_button / mini_progress
```

- 状态管理:`setState` + `FutureBuilder`(列表)+ `ListenableBuilder`(队列/会话)。
  **不引入 riverpod/bloc/go_router**——依赖与认知成本换不来对等收益。
- 缩略图组件:复刻 web `AssetThumbnail` 语义——`asset.tags['thumbnail_key']` 存在才请求
  `thumbnail-url`(presigned ~30min,内存缓存 Map<assetId, url> + 失败降级图标);
  非图/视频/PDF 等无缩略图走类型色块 + 扩展名角标(设计稿 04 的 `.art .ext` 样式)。

## 9. 视觉与主题令牌

设计稿 `app.css :root` → `theme/tokens.dart` 常量 + `ThemeData`(仅亮色):

| 令牌 | 值 | 用途 |
| --- | --- | --- |
| bg | #FAFAF7 | 页面底 |
| surface | #FFFFFF | 卡片 |
| surface2 / fill | #F5F4EF / #F0EEE9 | 次级面/填充 |
| fg / muted / subtle | #1A1A1A / #6B6B68 / #9A9A95 | 文字三级 |
| border / borderSoft | #E8E6E1 / #F0EEE9 | 发丝线 |
| accent / strong / soft / faint | #C2410C / #9A3412 / #FEE4D0 / #FEF3E8 | 焦糖橙主色(MVP seed 已是 #C2410C,平滑过渡) |
| green / amber / red | #047857 / #B45309 / #9F1239 | 徽标:可管理/已归档/危险 |
| dark / dark2 | #141210 / #1E1B18 | 预览暗色画布 |

- `ColorScheme.fromSeed(#C2410C)` 起步,再覆写 surface/surfaceContainer/border 精调到上表;
  卡片圆角 20、列表行高紧凑、徽标 pill。
- 字体:系统字体栈(Geist/Fraunces/JetBrains Mono 不打包,减少体积;数字用
  `FontFeature.tabularFigures` 近似等宽效果)。
- 组件清单(均落 widgets/,一处实现全站用):Badge(accent/green/neutral/amber)、
  EmptyState、ErrorView(错误 + 重试)、类型色块(扩展名角标)、进度条卡。

## 10. 后端契约(零改动)与模型扩展

v1 使用的端点全部已存在(mvp 客户端已对齐,新增仅 3 个):

| 端点 | 用途 | 状态 |
| --- | --- | --- |
| GET /healthz | 探活(免鉴权) | 已核实 `app/main.py:143` |
| POST /api/v1/auth/local/login / me / logout | 会话 | MVP 已接 |
| GET /api/v1/projects | 项目 | MVP 已接 |
| GET /api/v1/folders?project_id= | 目录(**含 subtree_file_count**) | 模型补字段 |
| GET /api/v1/assets?folder_id&limit&offset | 素材分页(**+tags/user_labels**) | 模型补字段 |
| GET /api/v1/assets/search?q&limit&offset | 盲搜(**SearchResult: +folder_name/project_***) | 新接 |
| GET /api/v1/assets/{id}/thumbnail-url | 缩略图 presigned | 新接 |
| POST /api/v1/assets/uploads(+parts/complete/abort) | 分片上传 | MVP 已接(补流式) |
| POST /api/v1/assets/{id}/download-link | 下载 | MVP 已接 |
| DELETE /api/v1/assets/{id} | 删除(软删) | MVP 已接 |

分页:assets limit 30 滚动加载(ScrollController 触底 +1 页,total 对账);projects/folders
单页 100 不分页(与 web 一致)。

## 11. 权限与安全边界

- 浏览可见性完全由后端裁决(projects/folders/assets 列表已按 FGA 过滤),App 不自判。
- 上传入口由 `folder.my_can_upload` 控制;删除按钮**不做客户端权限预判**——直接请求,
  403 时透出后端 detail(与 web `errorMessage` 同哲学,MVP `_extractDetail` 已兼容)。
- sensitive folder:锁图标 + 列表可进(后端已保证只见有权者)。
- 日志推送走企业微信机器人(现役逻辑平移,密钥仍在代码侧白名单环境);
  日志不含凭据(cookie jar 不入日志,现役 AppLog 只记 host+path)。

## 12. 依赖变更

| 包 | 动作 | 用途 |
| --- | --- | --- |
| media_store_plus | 新增 | Android Downloads 落盘(scoped storage 合规) |
| share_plus | 新增 | iOS 任意文件「存储到文件」兜底 |
| photo_manager / wechat_assets_picker / file_picker / dio / archive / … | 保留 | 现役 |
| (状态管理/路由框架) | **不引入** | setState + ChangeNotifier 够用 |

版本在 B1 批次锁死并记入 pubspec 注释(pub add 时取当前稳定版,升级须单独批次)。

## 13. 测试与验收

**单测(flutter test,PC 可跑)**:

- 现有用例保留(base_name / livp / base_url / ms_api / wecom_push / projects_title);
- 新增:探活顺序与超时降级(mock dio adapter)、TransferQueue 状态机
  (入队/并发/取消/失败重试/完成清除)、content_type 映射、
  **落盘策略矩阵(平台 × 文件类型 → 期望通道)**、分片流式切块边界(16MB 整除/余 1)。

**联调(本地隔离栈 `api/docker-compose.feat-ms.yml` + seed_demo_data)**:
登录 → 项目/文件夹/宫格缩略图 → 上传(图/视频/livp/大文件>32MB 跨分片)→
下载(各类型)→ 删除 → 盲搜;`flutter analyze` + `flutter test` 全绿。

**真机验收(关键,双端)**:

| 场景 | iPhone(TestFlight) | Android(release APK) |
| --- | --- | --- |
| 工作室 WiFi | 走内网 192.168.110.221(我的页确认入口) | 同左 |
| 蜂窝/外网 | 自动落 https://bucket.taoxiplan.com | 同左 |
| 上传 | 相册实况→livp;普通图视频;文件选择器 | 相册图/视频;文件选择器(含 SAF 深层目录) |
| 下载落点 | 相册(实况/图/视频)、文件 app(其他) | **图库可见、Download 目录可见**(本缺陷的验收线) |
| 权限拒绝 | 相册拒绝 → 引导跳设置 | 13+ 细分媒体权限拒绝流 |

构建链照 `ios-livp-app-build-handbook.md`(Windows+镜像变量+JAVA_HOME;
APP_BUILD_TIME 注入、release APK 核验流程不变)。

## 14. 风险与对策

| # | 风险 | 对策 |
| --- | --- | --- |
| R1 | photo_manager Android 保存 API 行为与 iOS 有差(厂商 ROM 差异) | B4 批真机首验;兜底 media_store_plus 直写 Pictures/Movies;失败 toast 明示 |
| R2 | livp 解包出的 HEIC 在部分安卓图库不识别 | 落盘前不改码不转码;失败时该任务标 failed 并提示改存 .livp 原档(D1 开关) |
| R3 | 大文件上传 OOM / UI 卡顿 | uploadFile 流式分片(§5);分片 PUT 已带 Content-Length(prod 411 钉子,勿动) |
| R4 | 探活误判(WiFi 通但隔离/防火墙拦截) → 选了内网却不可用 | 业务连接层失败时登录页给「重试探测」;不做运行中自动热切换(§4) |
| R5 | Android file_picker SAF 取 path 失败(云端文件) | withData 兜底读 bytes 走 uploadBytes;两者都失败提示先下载到本机 |
| R6 | 缩略图 presigned 30min 过期导致宫格裂图 | 内存缓存 URL + 过期时间,过期重签;失败降级类型色块 |
| R7 | 取消上传与 abort 端点竞态残留悬挂分片 | 尽力清理(现役哲学);MinIO lifecycle 兜底(既有) |

## 15. 实施批次与记账

每批:独立分支(基于 liuqi)→ 自测绿 → commit → `scripts/changelog.md` 记账
(天分节、一句话 + hash)→ 可部署验证的批次同步隔离栈联调。

| 批 | 内容 | 交付判据 |
| --- | --- | --- |
| B1 基建 | 目录重构(§8)+ tokens/主题 + Session 探活(§4)+ 登录页简化 + 我的页骨架(日志收拢) | 探活双端真机过;登录进空 shell;旧功能不回归 |
| B2 浏览线 | HomeShell 4 tab + 项目/文件夹/宫格(缩略图)+ 预览(胶片条+元数据) | 双端真机浏览流畅,缩略图命中率符合预期 |
| B3 上传线 | 统一上传面板 + uploadFile 流式 + TransferQueue 骨架 + 传输页 | 大文件(>1GB)上传不 OOM;取消/重试可用 |
| B4 下载线 | 落盘矩阵(§6)+ 批量下载 + 传输页完善 | **Android 图库/Download 可见性验收过** |
| B5 搜索+打磨 | 盲搜页 + 徽标/空态/错误态统一 + 单测补齐 | 全部单测绿;真机全场景走查 |

## 16. 待拍板决策点(不阻塞 B1 开工,默认按推荐执行)

| # | 问题 | 推荐 | 备选 |
| --- | --- | --- | --- |
| D1 | Android 下载 livp 的落点 | 解包后图+视频分别存图库(与 iOS「下载即进相册」心智一致) | 原样存 .livp 到 Downloads(保留原档不可看);或两者都做(占双倍空间) |
| D2 | 宫格多选操作栏 v1 放哪些 | 下载 + 删除(删除带确认,403 透传) | 仅下载(更保守);+分享/移动(P2 内容提前) |
| D3 | 搜索 tab 是否进 v1 | 进(产品重心「标签盲搜」,后端现成,增量约 1 天) | 延后 P2,tab 暂三格 |
| D4 | 预览页大图清晰度 | 用缩略图(1024px)v1 交差 | 原图 presigned 渐进加载(流量大,P2) |
