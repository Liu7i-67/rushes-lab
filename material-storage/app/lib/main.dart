/// 浣花视界 App 入口。目录结构见方案 §9(core/features/models/services/widgets);
/// 主题令牌见 theme/;探活与会话见 core/session.dart。
/// 后端入口:冷启动自动探活(dart-define MS_API_BASE → 内网 → 公网),
/// 登录页不再有地址切换 UI(§4 定稿)。
library;

import 'package:flutter/material.dart';

import 'app.dart';
import 'core/error_boundary.dart';
import 'core/error_report/error_report_controller.dart';
import 'core/maintenance/banner_controller.dart';
import 'core/polling_controller.dart';
import 'core/session.dart';
import 'core/thumb_disk_store.dart';
import 'core/thumb_pipeline.dart';
import 'core/thumbnail_cache.dart';
import 'core/transfers/transfer_queue.dart';
import 'services/app_log.dart';
import 'services/notifier.dart';
import 'services/transfer_foreground.dart';
import 'theme/theme_controller.dart';

/// 源码最后编辑时间(YYYY-MM-DD HH:mm),打包期注入、项目页标题展示,
/// 用于 TestFlight 肉眼确认装到的是最新构建(取 git HEAD 提交时刻):
///   flutter build ipa --release \
///     --dart-define=APP_BUILD_TIME="$(git log -1 --format='%cd' --date=format:'%Y-%m-%d %H:%M')"
/// 未注入(本地 flutter run/test)为空 → 标题不显示该段。
const kAppBuildStamp = String.fromEnvironment(
  'APP_BUILD_TIME',
  defaultValue: '',
);

/// 客户端版本号(x.y.z),打包期注入(release.mjs 构建命令 dart-define 传入
/// bump 后的 pubspec 版本)、随 User-Agent 上报供后端使用统计识别三端:
///   flutter build apk --release --dart-define=APP_VERSION=0.1.11
/// 未注入(本地 flutter run/test)为空 → UA 输出 `msapp/ (<platform>)`。
const kAppVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '',
);

/// 会话清空钩子注册(B2 遗留 core→features 环引用解耦:Session 暴露回调,
/// core 层资源在此挂载)。**幂等**:重复调用不重复累积(T14 断言),抽函数
/// 便于测试注入。
bool _sessionClearHooksRegistered = false;
void registerSessionClearHooks() {
  if (_sessionClearHooksRegistered) return;
  _sessionClearHooksRegistered = true;
  // 顺序写死:字节任务闸(pipeline)→ URL 缓存(cache)→ 位图磁盘(disk)——
  // 先停在途下载(句柄 null 完成 + abort 链放弃签名等待),再升缓存代数,
  // 最后清磁盘(storm-fix W1/W2)
  session.addSessionClearHook(thumbPipeline.clear);
  session.addSessionClearHook(thumbnailCache.clear);
  session.addSessionClearHook(ThumbDiskStore.I.clear);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // WP0 双主题:启动读外观偏好(跟随系统/深/浅);读盘失败保持 system
  // 且不阻塞后续初始化(ThemeStore 内部已静默降级)。
  await themeController.load();
  // 会话清空钩子(登出/401:缩略图字节任务/URL 缓存/磁盘位图全部清空)
  registerSessionClearHooks();
  // B7 通知未读轮询(§8.7 单一 PollingController):挂 App 生命周期 +
  // Session 门控(登录/登出/401 清会话即经 syncGate 起停,仅前台+已登录才轮)
  unreadPoller.attach();
  session.addListener(unreadPoller.syncGate);
  // B9 维护横幅轮询(§8.12):同一节拍器,**门控不同——前台即轮、不分登录态**
  // (仅要求探活就绪;登录页同样轮询展示)
  maintenanceBanner.attach();
  session.addListener(maintenanceBanner.syncGate);
  // 全量日志先行(framework/zone 兜底在此挂上),UI 起来前的异常也不丢;
  // init 异步不阻塞启动,文件就绪前的日志走内存/控制台,就绪后逐条落盘
  AppLog.init();
  // 全局报错页上报器(error-report):链式挂 FlutterError/zone 钩子并承接
  // MsApi 的 5xx/网络异常钩子。必须在 AppLog.init 之后(转发 previous 保留
  // 既有日志兜底),且在 installErrorBoundary 之前(渲染异常同样走 controller)
  errorReporter.install();
  // P8(mobile-ux-polish):传输完成系统通知初始化——失败静默降级为仅应用内
  // 提示;通知权限不在此请求(首次建传输任务时经 ensurePermission 弹)
  Notifier.I.init();
  // R4d(mobile-ux-polish-2):传输前台服务初始化(通信端口须在 runApp 前,
  // 插件要求;失败/非 Android 静默降级为无保活;启停随队列活跃任务联动)
  TransferForeground.I.init();
  // R4c(mobile-ux-polish-2):传输记录持久化——挂快照存储(应用支持目录
  // transfers.json)并恢复历史记录(终态原样/非终态标「进程中断」;存储打开
  // 失败如测试环境无插件通道,静默降级仅内存)
  TransferQueue.I.attachDefaultStore().ignore();
  // 包 B(app-polish-3):缩略图位图磁盘缓存目录就绪(建目录 + 150MB LRU 清理),
  // 异步不阻塞启动;失败静默降级为纯网络链路(测试环境无插件通道同此)
  ThumbDiskStore.I.init().ignore();
  // B9 功能点 4:渲染异常全局兜底(友好页 + 日志,不白屏)
  installErrorBoundary();
  runApp(const MsApp());
}
