/// ErrorReportPage — 全局报错提醒页(F7-F11,feat/app-error-page):
/// 展示首条触发跳转的 ErrorInfo(时间/入口/操作/类型/详情/堆栈),
/// 提供关闭(返回 + 底部主按钮,均 pop)、复制(CopyButton 复用)、
/// 推送日志(与「我的→日志推送」同链路:dumpFile → WeComPush → clear,
/// 结果就地展示,失败保留日志可重试,不弹新路由/dialog)。
/// 页面存活期间 markOnPage(true),controller 据此忽略新错误(D2 防套娃)。
/// 视觉:PageHeader(17 + 副标题)+ AppCard 详情 / surface2 堆栈 / 金主按钮。
library;

import 'package:flutter/material.dart';

import '../../core/error_report/error_info.dart';
import '../../core/error_report/error_report_controller.dart';
import '../../services/app_log.dart';
import '../../services/wecom_push.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/copy_button.dart';
import '../../widgets/page_header.dart';
import '../../widgets/section_label.dart';
import 'error_report_sections.dart';

class ErrorReportPage extends StatefulWidget {
  const ErrorReportPage({super.key});

  @override
  State<ErrorReportPage> createState() => _ErrorReportPageState();
}

class _ErrorReportPageState extends State<ErrorReportPage> {
  /// 首条错误快照:页面打开后不再跟随(D2 在页期间的新错误完全忽略)。
  ErrorInfo? _info;
  bool _pushing = false;
  bool _pushOk = false;
  String? _result;

  @override
  void initState() {
    super.initState();
    _info = errorReporter.currentError;
    // 防套娃(D2):在页期间 controller 忽略新错误,仅记 AppLog
    errorReporter.markOnPage(true);
  }

  @override
  void dispose() {
    errorReporter.markOnPage(false);
    super.dispose();
  }

  /// F10:与 log_push.dart 同链路;成功清日志,失败就地提示且可重试。
  /// WeComPush 走独立 Dio(不经 MsApi),失败不会触发新的报错页(F11)。
  Future<void> _pushLog() async {
    if (_pushing) return;
    _result = null; // 重试即清掉上一次结果
    setState(() => _pushing = true);
    try {
      final mediaId = await WeComPush().pushLogFile(await AppLog.dumpFile());
      // 成功才清空;清空后写一条新记录,留下推送时间锚点
      await AppLog.clear();
      AppLog.info('wecom', '报错页日志已推送并清空(media_id=$mediaId)');
      if (!mounted) return;
      _showResult(true, '推送成功,本地日志已清空');
    } catch (e) {
      AppLog.error('wecom', '报错页日志推送失败', e);
      if (!mounted) return;
      _showResult(false, '推送失败:$e\n(本地日志保留,可稍后重试)');
    } finally {
      if (mounted) setState(() => _pushing = false);
    }
  }

  void _showResult(bool ok, String text) => setState(() {
    _pushOk = ok;
    _result = text;
  });

  /// F8:返回键与底部主按钮共用,均返回上一页(保留原页面栈)。
  void _close() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final stack = info?.stackText?.trim();
    final tk = context.tk;
    return Scaffold(
      backgroundColor: tk.bg,
      body: Column(
        children: [
          PageHeader(
            title: '应用错误',
            subtitle: '已记录，可复制或推送诊断',
            back: true,
            onBack: _close,
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(
                top: Tk.spaceSm,
                bottom: Tk.spaceXl,
              ),
              children: [
                const SectionLabel(title: '错误详情'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Tk.spacePage),
                  child: info == null
                      ? const ErrorReportEmpty()
                      : ErrorDetailCard(info: info),
                ),
                if (stack != null && stack.isNotEmpty) ...[
                  const SectionLabel(title: '堆栈信息'),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Tk.spacePage,
                    ),
                    child: ErrorStackCard(stack: stack),
                  ),
                ],
              ],
            ),
          ),
          _bottomBar(info),
        ],
      ),
    );
  }

  /// 底部操作区:结果就地展示(F11)+ 复制/推送 + 主按钮关闭(F8)。
  Widget _bottomBar(ErrorInfo? info) {
    final tk = context.tk;
    return Container(
      decoration: BoxDecoration(
        color: tk.surface,
        border: Border(top: BorderSide(color: tk.line)),
      ),
      padding: const EdgeInsets.fromLTRB(
        Tk.spacePage,
        Tk.spaceMd,
        Tk.spacePage,
        Tk.spaceMd,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_result != null) ...[
              Text(
                _result!,
                style: TextStyle(
                  fontSize: Tk.fzMd,
                  height: 1.4,
                  color: _pushOk ? tk.ok : tk.danger,
                ),
              ),
              const SizedBox(height: Tk.spaceSm),
            ],
            Row(
              children: [
                Expanded(child: _copyButton(info)),
                const SizedBox(width: Tk.spaceMd),
                Expanded(child: _pushButton()),
              ],
            ),
            const SizedBox(height: Tk.spaceMd),
            PrimaryXl(onPressed: _close, label: '关闭'),
          ],
        ),
      ),
    );
  }

  /// F9:label 模式 CopyButton;无 info 时用 IgnorePointer + 降透明禁用
  /// (CopyButton 无 enabled 参数,不为此改公共组件)。
  Widget _copyButton(ErrorInfo? info) {
    final button = CopyButton(
      text: info?.toClipboardText() ?? '',
      label: '复制诊断',
      tooltip: '复制错误信息',
      iconSize: 18,
    );
    return info == null
        ? Opacity(opacity: 0.5, child: IgnorePointer(child: button))
        : button;
  }

  Widget _pushButton() => OutlinedButton.icon(
    onPressed: _pushing ? null : _pushLog,
    icon: _pushing
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.send_outlined, size: 18),
    label: Text(_pushing ? '推送中…' : '推送日志'),
  );
}
