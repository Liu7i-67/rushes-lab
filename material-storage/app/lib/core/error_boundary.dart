/// ErrorBoundary — 全局渲染异常兜底(B9 功能点 4,§4.1 不白屏口径):
/// ErrorWidget.builder 把 build 阶段异常换成友好页 + AppLog 留痕,不再红屏/
/// 白屏;zone/未捕获异常兜底已有(AppLog.init 挂 FlutterError.onError +
/// PlatformDispatcher.onError,本批核对无需重复挂)。
///
/// 注意:builder 产物会在 MaterialApp 之外渲染(如根布局本身出错),必须
/// 自带 Directionality/配色,不依赖 Theme/MediaApp。
library;

import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import 'package:flutter/material.dart';

import '../services/app_log.dart';
import '../theme/tokens.dart';
import 'error_report/error_report_controller.dart';

/// main() 调用一次;幂等。[debug] 供测试注入 release 路径(P2-7;缺省随
/// kDebugMode,main() 调用点不变)。
void installErrorBoundary({bool debug = kDebugMode}) {
  final previous = ErrorWidget.builder;
  ErrorWidget.builder = (details) {
    AppLog.error('ui', '渲染异常:${details.exception}', details.stack);
    // 全局报错页:分流判定在 controller 内(debug 框架错误只留日志、release
    // 才跳);此处仍在 build/layout 期,controller 内部会推迟到帧后导航
    errorReporter.onSystemError(details.exception, details.stack, 'render');
    // debug 期保留 Flutter 原生红字细节,便于开发定位;release 走友好页
    if (debug) return previous(details);
    return const FriendlyErrorPage();
  };
}

/// release 渲染异常友好页(builder 产物;P2-7 提为可测:测试直接对产物
/// 做布局冒烟断言)。在 MaterialApp 之外也须成立:自带 Directionality/
/// 配色,不依赖 Theme。
@visibleForTesting
class FriendlyErrorPage extends StatelessWidget {
  const FriendlyErrorPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(Tk.spaceXl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.error_outline, size: 48, color: Tk.red),
          SizedBox(height: Tk.spaceMd),
          Text('页面出现了一点问题',
              style: TextStyle(
                  fontSize: Tk.fzTitle, fontWeight: FontWeight.w600)),
          SizedBox(height: Tk.spaceSm),
          Text(
            '请返回重试;若反复出现,可在「我的 → 日志推送」把诊断日志发给我们。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: Tk.fzMd, color: Tk.muted),
          ),
        ],
      ),
    );
  }
}
