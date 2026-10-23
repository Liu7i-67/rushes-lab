/// ErrorBoundary — 全局渲染异常兜底(B9 功能点 4,§4.1 不白屏口径):
/// ErrorWidget.builder 把 build 阶段异常换成友好页 + AppLog 留痕,不再红屏/
/// 白屏;zone/未捕获异常兜底已有(AppLog.init 挂 FlutterError.onError +
/// PlatformDispatcher.onError,本批核对无需重复挂)。
///
/// 注意:builder 产物会在 MaterialApp 之外渲染(如根布局本身出错),必须
/// 自带 Directionality/Localizations/MediaQuery 兜底,不依赖 Theme/MediaApp;
/// 配色取 `context.tk`(有主题随主题,无主题按 brightness 回退)。
library;

import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_log.dart';
import '../theme/context_tk.dart';
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
    return FriendlyErrorPage(
      diagnostics:
          '${details.exceptionAsString()}\n'
          '${details.stack ?? ''}',
    );
  };
}

/// release 渲染异常友好页(builder 产物;P2-7 提为可测:测试直接对产物
/// 做布局冒烟断言)。在 MaterialApp 之外也须成立:自带 Directionality/
/// Localizations/MediaQuery,配色回退不依赖 Theme。
@visibleForTesting
class FriendlyErrorPage extends StatefulWidget {
  const FriendlyErrorPage({super.key, this.diagnostics, this.onRetry});

  /// 「复制诊断」写入剪贴板的文本;为空时按钮禁用。
  final String? diagnostics;

  /// 「重试」回调(宿主可挂重建/返回逻辑);为空时仅重建本页。
  final VoidCallback? onRetry;

  @override
  State<FriendlyErrorPage> createState() => _FriendlyErrorPageState();
}

class _FriendlyErrorPageState extends State<FriendlyErrorPage> {
  bool _copied = false;

  void _retry() {
    widget.onRetry?.call();
    if (mounted) setState(() {}); // 重建本页;宿主重建失败子树时随之恢复
  }

  Future<void> _copy() async {
    final text = widget.diagnostics?.trim();
    if (text == null || text.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) setState(() => _copied = true);
    } catch (_) {
      // 剪贴板通道不可用时保持原状:ErrorWidget 产物里禁止再次抛错
    }
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final hasDiagnostics = widget.diagnostics?.trim().isNotEmpty ?? false;
    final page = Scaffold(
      backgroundColor: tk.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Tk.spaceXl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: tk.dangerSoft,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.error_outline, size: 30, color: tk.danger),
                ),
                const SizedBox(height: Tk.spaceLg),
                Text(
                  '页面出现了一点问题',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: Tk.fzTitle,
                    fontWeight: FontWeight.w600,
                    color: tk.ink,
                  ),
                ),
                const SizedBox(height: Tk.spaceSm),
                Text(
                  '页面渲染遇到异常，已记录诊断信息。可重试，或复制诊断发给开发同学。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: Tk.fzMd,
                    height: 1.5,
                    color: tk.ink2,
                  ),
                ),
                const SizedBox(height: Tk.spaceXl),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _retry,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('重试'),
                      ),
                    ),
                    const SizedBox(width: Tk.spaceMd),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: hasDiagnostics ? _copy : null,
                        icon: Icon(
                          _copied ? Icons.check : Icons.copy_outlined,
                          size: 18,
                        ),
                        label: Text(_copied ? '已复制' : '复制诊断'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // builder 产物可能在没有 MaterialApp 的根布局里渲染:只补齐缺失的最小
    // 依赖(已有主题/本地化时保持宿主环境,不覆盖 App 的 locale/方向)。
    final mq = MediaQuery.maybeOf(context);
    final hasLocalizations =
        Localizations.of<MaterialLocalizations>(
          context,
          MaterialLocalizations,
        ) !=
        null;
    Widget body = page;
    if (!hasLocalizations) {
      body = Localizations(
        locale: const Locale('en'),
        delegates: const [
          DefaultMaterialLocalizations.delegate,
          DefaultWidgetsLocalizations.delegate,
        ],
        child: body,
      );
    }
    if (mq == null) {
      body = MediaQuery(data: const MediaQueryData(), child: body);
    }
    return Directionality(
      textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
      child: body,
    );
  }
}
