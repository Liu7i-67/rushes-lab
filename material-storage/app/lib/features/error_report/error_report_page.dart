/// ErrorReportPage — 全局报错提醒页(F7-F11,feat/app-error-page):
/// 展示首条触发跳转的 ErrorInfo(类型/时间/来源/状态码/message/堆栈),
/// 提供关闭(AppBar X + 底部主按钮,均 pop)、复制(CopyButton 复用)、
/// 推送日志(与「我的→日志推送」同链路:dumpFile → WeComPush → clear,
/// 结果就地展示,失败保留日志可重试,不弹新路由/dialog)。
/// 页面存活期间 markOnPage(true),controller 据此忽略新错误(D2 防套娃)。
library;

import 'package:flutter/material.dart';

import '../../core/error_report/error_info.dart';
import '../../core/error_report/error_report_controller.dart';
import '../../services/app_log.dart';
import '../../services/wecom_push.dart';
import '../../theme/tokens.dart';
import '../../widgets/copy_button.dart';

const _kTitleStyle = TextStyle(fontSize: Tk.fzLg, fontWeight: FontWeight.w600);
const _kKeyStyle = TextStyle(fontSize: Tk.fzMd, color: Tk.subtle);
const _kValueStyle = TextStyle(fontSize: Tk.fzMd, color: Tk.fg, height: 1.4);
const _kBodyStyle = TextStyle(fontSize: Tk.fzBody, color: Tk.fg, height: 1.45);
const _kSectionStyle = TextStyle(color: Tk.muted, fontSize: Tk.fzXs);
const _kMonoStyle = TextStyle(fontSize: Tk.fzXs, fontFamily: 'monospace');
const _kCardDecoration = BoxDecoration(
  color: Tk.surface,
  borderRadius: BorderRadius.all(Radius.circular(Tk.rLg)),
  border: Border.fromBorderSide(BorderSide(color: Tk.border)),
);
const _kBarDecoration = BoxDecoration(
  color: Tk.surface,
  border: Border(top: BorderSide(color: Tk.border, width: 0.5)),
);

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

  Color get _resultColor => _pushOk ? Tk.green : Tk.red;

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

  /// F8:AppBar X 与底部主按钮共用,均返回上一页(保留原页面栈)。
  void _close() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final stack = info?.stackText?.trim();
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: '关闭',
          icon: const Icon(Icons.close),
          onPressed: _close,
        ),
        title: const Text('报错提醒'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(Tk.spaceLg),
        children: [
          _headerCard(info),
          if (info == null)
            _emptyPlaceholder()
          else ...[
            const SizedBox(height: Tk.spaceLg),
            _metaCard(info),
            const SizedBox(height: Tk.spaceLg),
            _section('错误详情', _messageCard(info)),
            if (stack != null && stack.isNotEmpty) ...[
              const SizedBox(height: Tk.spaceLg),
              _section('堆栈信息', _stackCard(stack)),
            ],
          ],
        ],
      ),
      bottomNavigationBar: _bottomBar(info),
    );
  }

  /// 顶部告警卡:错误图标(Tk.red)+ 类型标题 + 发生时间。
  Widget _headerCard(ErrorInfo? info) => Container(
    padding: const EdgeInsets.all(Tk.spaceLg),
    decoration: BoxDecoration(
      color: Tk.red.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(Tk.rLg),
      border: Border.all(color: Tk.red.withValues(alpha: 0.18)),
    ),
    child: Row(
      children: [
        const Icon(Icons.error_outline, color: Tk.red, size: 32),
        const SizedBox(width: Tk.spaceMd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(info?.kindLabel ?? '未获取到错误信息', style: _kTitleStyle),
              const SizedBox(height: Tk.spaceXs),
              Text(
                info == null ? '错误详情不可用' : _formatTime(info.time),
                style: const TextStyle(fontSize: Tk.fzSm, color: Tk.muted),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  /// 来源 + HTTP 状态码(仅接口类且有状态码时展示,F7)。
  Widget _metaCard(ErrorInfo info) {
    final withStatus = info.kind == ErrorKind.api && info.status != null;
    return _card(
      Column(
        children: [
          _kv('来源', info.source),
          if (withStatus) _kv('HTTP 状态码', '${info.status}'),
        ],
      ),
    );
  }

  Widget _kv(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Tk.spaceXs),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 88, child: Text(label, style: _kKeyStyle)),
        Expanded(child: SelectableText(value, style: _kValueStyle)),
      ],
    ),
  );

  /// message 卡:可选中文本,随整页滚动。
  Widget _messageCard(ErrorInfo info) =>
      _card(SelectableText(info.message, style: _kBodyStyle));

  /// 堆栈摘要:等宽小字,容器限高内独立滚动(整页仍可滚动)。
  Widget _stackCard(String stack) => Container(
    width: double.infinity,
    constraints: const BoxConstraints(maxHeight: 240),
    clipBehavior: Clip.antiAlias,
    decoration: _kCardDecoration,
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(Tk.spaceMd),
      child: SelectableText(stack, style: _kMonoStyle),
    ),
  );

  /// null 兜底:不展示详情区,仅占位文案(关闭/推送日志仍可用)。
  Widget _emptyPlaceholder() => const Padding(
    padding: EdgeInsets.symmetric(vertical: Tk.spaceXl),
    child: Text(
      '暂无错误详情,可返回后重试',
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: Tk.fzBody, color: Tk.muted),
    ),
  );

  Widget _section(String title, Widget child) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: Tk.spaceXs, bottom: Tk.spaceSm),
        child: Text(title, style: _kSectionStyle),
      ),
      child,
    ],
  );

  Widget _card(Widget child) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(Tk.spaceLg),
    decoration: _kCardDecoration,
    child: child,
  );

  /// 底部操作区:结果就地展示(F11)+ 复制/推送 + 主按钮关闭(F8)。
  Widget _bottomBar(ErrorInfo? info) => Container(
    decoration: _kBarDecoration,
    padding: const EdgeInsets.all(Tk.spaceLg),
    child: SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_result != null) ...[
            Text(
              _result!,
              style: TextStyle(fontSize: Tk.fzSm, color: _resultColor),
            ),
            const SizedBox(height: Tk.spaceMd),
          ],
          Row(
            children: [
              Expanded(child: _copyButton(info)),
              const SizedBox(width: Tk.spaceMd),
              Expanded(child: _pushButton()),
            ],
          ),
          const SizedBox(height: Tk.spaceMd),
          FilledButton(
            onPressed: _close,
            child: const Text('关闭', style: TextStyle(fontSize: Tk.fzTitle)),
          ),
        ],
      ),
    ),
  );

  /// F9:label 模式 CopyButton;无 info 时用 IgnorePointer + 降透明禁用
  /// (CopyButton 无 enabled 参数,不为此改公共组件)。
  Widget _copyButton(ErrorInfo? info) {
    final button = CopyButton(
      text: info?.toClipboardText() ?? '',
      label: '复制错误信息',
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

/// 发生时间固定格式 yyyy-MM-dd HH:mm:ss(F7 验收口径)。
String _formatTime(DateTime t) {
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} '
      '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
}
