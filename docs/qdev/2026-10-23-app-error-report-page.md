# App 报错提醒页面（error-report-page）

日期：2026-10-23 · 分支：`feat/app-error-page`（自 liuqi 切出） · 范围：`material-storage/app/`（Flutter，纯前端，无后端改动）

## 背景与目标

当前 App 的错误处理是分散的：接口业务错经各页面 catch 后 toast 就地提示；5xx/网络异常也走 toast 兜底；系统级异常（渲染异常/未捕获异常）只有 AppLog 留痕 + release 静态友好页，用户看不到详情、也无法便捷地把错误信息交给开发。目标：新增**全局报错提醒页面**，系统级错误发生时统一跳转集中展示错误详情，并提供关闭/复制/推送日志三个操作，把「用户侧报错可观测」闭环。

## 决策记录（用户已拍板）

| # | 模糊点 | 决策 | 说明 |
|---|---|---|---|
| D1 | 跳转门槛 | **仅系统级错误跳转** | 5xx 服务器错 + 网络异常/超时 + 渲染异常 + 未捕获异常 → 跳报错页；4xx 业务错（403/404/409/422 等）保持现有 toast 就地提示；401 仍走既有跳登录链路（`onSessionExpired`） |
| D2 | 已在报错页时的新错误 | **完全忽略** | 页面只展示首次触发跳转的那条错误；在页期间的新错误仅写 AppLog 不进 UI、不重复跳转（防套娃） |
| D3 | 关闭按钮 | **返回上一页** | `Navigator.pop`，保留原页面栈 |
| D4 | 推送日志按钮 | 复用既有 WeComPush 通道 | 错误捕获点已写入 AppLog（本方案保证），推送= `AppLog.dumpFile()` → `WeComPush.pushLogFile` → 成功 `AppLog.clear()`，与「我的→日志推送」完全同链路 |
| D5 | debug/release 分流 | **API 系统级错误 debug+release 都跳**（开发真机可验收）；**框架系统错误（FlutterError/zone/渲染异常）仅 release 跳**，debug 仅记 AppLog | debug 下框架异常噪声多（overflow、图片解码失败等），全跳无法开发；`@visibleForTesting` 提供测试开关 |
| D6 | 连续错误防重复跳转 | 关闭页面后 **3 秒冷却窗**内新错误不跳（仅记日志） | 防轮询接口连环失败导致「关了又弹」骚扰；用户在页期间由 D2 覆盖 |

## 功能点明细（逐条可验收）

1. **F1 接口 5xx 跳转**：任意页面触发的 API 调用返回 5xx（经 `MsApi.err()` 转 `ApiException`）→ 跳转 `/error-report` 展示错误详情。
2. **F2 网络异常跳转**：连接超时/断网等传输层异常（`DioException` 非 badResponse 型，dio onError 拦截器捕获）→ 跳转。
3. **F3 系统异常跳转**：渲染异常（ErrorWidget.builder）/ Flutter 未捕获异常（FlutterError.onError）/ zone 未捕获异常（PlatformDispatcher.onError）→ 跳转（仅 release，D5）。
4. **F4 4xx 不跳转**：4xx 业务错保持现状（toast 就地提示，页面各自 catch 逻辑零改动）；401 走既有跳登录。
5. **F5 防套娃**：已位于报错页期间的新错误完全忽略（仅 AppLog），不重复 push、不改页面内容（D2）。
6. **F6 冷却窗**：关闭报错页后 3s 内新系统级错误不自动跳转（D6）。
7. **F7 错误详情展示**：类型（接口异常/系统异常）、发生时间、来源（METHOD path 或 render/flutter/zone）、HTTP 状态码（接口类）、message、stack 摘要；文本可选中可滚动。
8. **F8 关闭按钮**：AppBar 关闭 + 返回上一页（pop）。
9. **F9 复制按钮**：一键复制格式化错误报告文本（含时间/类型/来源/状态码/详情/堆栈），复用 `CopyButton`（自带成功反馈）。
10. **F10 推送日志按钮**：推送 AppLog 全量日志到企业微信（D4 链路），按钮态（推送中 loading）、成功/失败结果就地块展示；失败不清日志可重试。
11. **F11 推送按钮自身报错不套娃**：WeComPush 走独立 Dio（不经 MsApi），失败就地块提示，不触发新跳转。
12. **F12 回归不变**：现有 toast 语义、401 跳登录、维护横幅、「我的→日志推送」对话框均不受影响。

## 组件拆分方案

### 新建文件

| 文件 | 职责 | 预估行数 |
|---|---|---|
| `lib/core/error_report/error_info.dart` | 错误信息模型：kind(api/system)、time、source、status?、message、stackText?；`toClipboardText()` 格式化为可复制报告 | ~90 |
| `lib/core/error_report/error_report_controller.dart` | 全局错误上报单例 `errorReporter`：接收 API/系统错误 → 判定门槛（5xx/网络/系统、D5 分流）→ 防套娃（在页标志）→ 冷却窗 → **postFrame 调度** `pushNamed('/error-report')`；`install()` 链式挂 FlutterError.onError + PlatformDispatcher.onError（转发 previous）；`markOnPage(bool)` 供页面调 | ~190 |
| `lib/features/error_report/error_report_page.dart` | 报错页 UI：详情展示（可选中滚动）+ 关闭（AppBar+底部）+ 复制（CopyButton）+ 推送日志（WeComPush 流程、结果就地块） | ~260 |
| `test/core/error_report/error_report_controller_test.dart` | controller 单测（第 2 步只写，第 4 步跑） | ~180 |
| `test/features/error_report/error_report_page_test.dart` | 页面单测（同上） | ~140 |

### 契约（两包并行开发的硬边界）

```dart
// error_info.dart
enum ErrorKind { api, system }
class ErrorInfo {
  const ErrorInfo({required this.kind, required this.time, required this.source,
    this.status, required this.message, this.stackText});
  final ErrorKind kind; final DateTime time; final String source;
  final int? status; final String message; final String? stackText;
  String get kindLabel;            // '接口异常' / '系统异常'
  String toClipboardText();        // 格式化报告全文
}

// error_report_controller.dart
final errorReporter = ErrorReportController();
class ErrorReportController {
  void install({bool debugFrameworkJump = kDebugMode}); // main() 调一次
  void onApiError(ApiException e, {String? method, String? path}); // MsApi 钩子
  void onNetworkError(DioException e, {String? method, String? path}); // dio onError 钩子
  void onSystemError(Object error, StackTrace? stack, String source); // 框架钩子
  void markOnPage(bool onPage);    // 页面 initState(true)/dispose(false)
  ErrorInfo? currentError;         // 供测试与页面断言
}

// app.dart 路由
case '/error-report': // arguments: ErrorInfo（errorReporter push 时传入）
  return MaterialPageRoute(builder: (_) => const ErrorReportPage());
// ErrorReportPage 无构造参数，经 static ErrorInfo? pendingError 或 controller.currentError 取值（取后即清）
```

### 修改文件（接线，全部小改）

| 文件 | 改动 |
|---|---|
| `lib/core/api/ms_api.dart` | 构造加 `void Function(ApiException)? onApiError` + `void Function(DioException)? onNetworkError`；`err()` 抛前 `status>=500` 时调 onApiError；主 Dio `_logInterceptor` 的 onError 分支对非 badResponse 型调 onNetworkError（`_put` 裸 Dio 不挂——presigned 上传失败由上层任务语义处置，不全局跳） |
| `lib/core/session.dart` | `_activate` 里 MsApi 构造传 `onApiError: errorReporter.onApiError, onNetworkError: errorReporter.onNetworkError`（core 内互引，不违反 core→features 解耦约定） |
| `lib/core/error_boundary.dart` | `installErrorBoundary` 的 builder 里加 `errorReporter.onSystemError(details.exception, details.stack, 'render')`（经 controller 内部 D5 分流，debug 不跳） |
| `lib/main.dart` | `AppLog.init()` 之后加 `errorReporter.install()` |
| `lib/app.dart` | onGenerateRoute 加 `/error-report` case |

### 可复用资产映射

| 资产 | 用法 |
|---|---|
| `widgets/copy_button.dart` | F9 直接复用（label 模式按钮） |
| `services/wecom_push.dart` + `AppLog.dumpFile/clear` | F10 直接复用（与 log_push.dart 同流程） |
| `core/session.dart` `navigatorKey` | 全局 push（handleSessionExpired 已有同款先例） |
| `widgets/toast.dart` | 页内推送失败的轻提示（如需） |
| `theme/tokens.dart`（Tk.*） | 页面样式一律走令牌 |

### 数据流

```
MsApi.err()(5xx) ──onApiError──┐
dio onError(网络异常) ─────────┤
ErrorWidget.builder ──┐        │
FlutterError.onError ─┼─install┤→ ErrorReportController
PlatformDispatcher ───┘        │   ├ 门槛判定(D1/D5) → 不满足: 仅 AppLog
                               │   ├ markOnPage=true → 忽略(D2)
                               │   ├ 冷却窗内 → 忽略(D6)
                               │   └ addPostFrameCallback → navigatorKey
                               │        .pushNamed('/error-report', ErrorInfo)
                               ▼
                        ErrorReportPage(展示/关闭/复制/推送日志)
```

### 实现钉子（子智能体必读）

1. **build 期禁止直接导航**：FlutterError.onError / ErrorWidget.builder 都可能在 build/layout 阶段触发，直接 pushNamed 会抛 `setState() called during build` —— push 必须 `WidgetsBinding.instance.addPostFrameCallback` 调度，并防重入（帧回调挂起期间再来的错误按 D2/D6 语义忽略）。
2. **AppLog 留痕前置**：所有上报路径先 `AppLog.error(...)` 再走跳转判定，保证 F10 推送的日志文件必含该错误。
3. **链式钩子必须转发 previous**：`FlutterError.onError`/`PlatformDispatcher.onError` 已被 AppLog.init 挂过，install 链式包裹并转发，不得吞掉既有日志兜底。
4. **ErrorWidget.builder 的 debug 分流**（现有语义保持）：debug 红屏不变，controller 内部判定 debug 框架错误不跳（D5）。
5. **`_put` 裸 Dio（presigned 上传/下载）不挂钩子**：分片上传失败由传输队列语义处置，全局跳转会打断批量任务观测。
6. **防重复上报**：同一异常只走一个上报点（err() 与 onError 拦截器互斥：validateStatus 全放行下 badResponse 型 DioException 不应出现，onError 仅报非 badResponse 型）。
7. 单文件硬上限 300 行，超限先拆。

## 数据库修改方案

不涉及。

## 接口定义

不涉及（无新后端接口；推送日志走既有企业微信 webhook 外部通道）。

## 前端改动点 / 后端改动点

- 前端：见组件拆分方案（3 新文件 + 5 接线小改 + 2 测试文件）。
- 后端：不涉及。

## 测试功能点

1. 门槛：5xx ApiException → 上报；4xx → 不上报；401 → 不上报；网络异常 DioException(connectionTimeout) → 上报；badResponse 型不上报。
2. D5 分流：debug 模式下框架系统错误不跳、API 5xx 跳；release 下都跳（`debugFrameworkJump` 注入翻转验证）。
3. 防套娃：markOnPage(true) 期间上报不 push、currentError 不变。
4. 冷却窗：模拟关闭（markOnPage(false) 后 3s 内）上报不 push；超窗后恢复。
5. 帧后调度：在 build 回调内同步调 onSystemError 不抛异常（postFrame 生效）。
6. install 链式：挂载后调用 FlutterError.onError 既有 previous 仍被调（AppLog 兜底不丢）。
7. 页面渲染：ErrorInfo 四要素（类型/时间/来源/详情）可见；stackText 有/无两态布局成立。
8. 复制：toClipboardText 含全部字段；CopyButton 存在。
9. 推送日志：成功路径（mock WeComPush）展示成功文案；失败路径展示失败文案且不弹新跳转。
10. 关闭：pop 返回（navigator 栈深减一）。
11. 回归：`flutter analyze` 0 issue；既有测试全绿；toast 语义/401 跳登录/日志推送对话框不受影响（既有用例覆盖）。
12. 组件化质量：新增/修改文件 ≤300 行；无职责堆叠。

## 工作包划分（第 2 步并行派发）

- **包A（core）**：error_info.dart + error_report_controller.dart + 五处接线（ms_api/session/error_boundary/main）。
- **包B（页面）**：error_report_page.dart + app.dart 加路由。
- **包C（测试）**：两个测试文件（按契约只写不跑）。

## 测试轮次与修复记录（第 4 步补记）

首轮专职测试（独立视角）：无 P0；P1×2 + P2×2，另 14 个维度已检查无问题。修复与复验：

| 问题 | 修复 | 复验 |
|---|---|---|
| P1-1 cancel 型被误当网络异常上报跳转（搜索防抖/传输取消属正常业务） | ms_api onError 拦截器与 controller.onNetworkError 双重排除 `DioExceptionType.cancel` | PASS（真实 socket 链路：在途 cancel 不上报、connectionError/500 照常上报） |
| P1-2 后台轮询（banner 8s/未读 30s）失败触发报错页，3s 冷却挡不住下一拍（D6 初衷失效） | per-request `noErrorReport` extra 标记：banner 轮询请求直接带 Options extra；notifications.list 加 `silent` 参数仅轮询传 true；ms_api err()/onError 两处识别跳过 | PASS（轮询 5xx/断网均不上报；同端点非 silent 调用照常上报；silent 401 仍走跳登录；D6 原语义不破） |
| P2-1 帧后窗口双错误双跳竞态（叠两层报错页、D2 首条被覆盖） | `_pushScheduled` 跨帧保持，`markOnPage(true)` 复位，navigator 未就绪/跳转失败兜底复位 | PASS（竞态只 push 一次、currentError 首条；关闭冷却后可二次跳转；无永久卡死） |

修复补 8 个正式用例（cancel×2/轮询标记×3/竞态×3，含对照）；最终 `flutter analyze` 零 issue、全量 `flutter test` 831/831 绿（报错页相关 18 用例）。

## 遗留项（不随本批强修）

1. **P2-2 推送链路重复**：error_report_page._pushLog 与 features/me/log_push.dart 的 dumpFile→pushLogFile→clear→文案 几乎逐行相同，建议抽 services 级公共函数；时间格式化两份同构实现且时区口径不一（页面 toLocal/复制文本未用），建议收敛到 ErrorInfo 公共方法。无功能影响。
2. cancel 仍会以 ERROR 级进 AppLog（api 日志拦截器先记后过滤），推送日志中带正常取消噪声——既有日志行为，观察项。
3. 真机验收清单（tester）：真机断网触发报错页、报错页三按钮手测、推送日志到企微群实收、5xx 场景（可用 dev 停后端模拟）。
