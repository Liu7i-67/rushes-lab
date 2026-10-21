/// 浣花视界 App 入口。目录结构见方案 §9(core/features/models/services/widgets);
/// 主题令牌见 theme/;探活与会话见 core/session.dart。
/// 后端入口:冷启动自动探活(dart-define MS_API_BASE → 内网 → 公网),
/// 登录页不再有地址切换 UI(§4 定稿)。
library;

import 'package:flutter/material.dart';

import 'app.dart';
import 'core/polling_controller.dart';
import 'core/session.dart';
import 'features/assets/thumbnail_image.dart' show thumbnailCache;
import 'services/app_log.dart';

/// 源码最后编辑时间(YYYY-MM-DD HH:mm),打包期注入、项目页标题展示,
/// 用于 TestFlight 肉眼确认装到的是最新构建(取 git HEAD 提交时刻):
///   flutter build ipa --release \
///     --dart-define=APP_BUILD_TIME="$(git log -1 --format='%cd' --date=format:'%Y-%m-%d %H:%M')"
/// 未注入(本地 flutter run/test)为空 → 标题不显示该段。
const kAppBuildStamp = String.fromEnvironment(
  'APP_BUILD_TIME',
  defaultValue: '',
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 会话清空钩子注册(B2 遗留 core→features 环引用解耦:Session 暴露回调,
  // 特性侧缓存在此挂载,core 不再反向 import features)
  session.addSessionClearHook(thumbnailCache.clear);
  // B7 通知未读轮询(§8.7 单一 PollingController):挂 App 生命周期 +
  // Session 门控(登录/登出/401 清会话即经 syncGate 起停,仅前台+已登录才轮)
  unreadPoller.attach();
  session.addListener(unreadPoller.syncGate);
  // 全量日志先行(framework/zone 兜底在此挂上),UI 起来前的异常也不丢;
  // init 异步不阻塞启动,文件就绪前的日志走内存/控制台,就绪后逐条落盘
  AppLog.init();
  runApp(const MsApp());
}
