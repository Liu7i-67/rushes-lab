/// 报错页纯展示件(无状态):详情卡/堆栈卡/空态与时间格式化。
/// 页面只做首条错误快照、防套娃(controller)与推送状态编排。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/error_report/error_info.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/badge.dart';
import '../../widgets/empty_state.dart';

/// 发生时间固定格式 yyyy-MM-dd HH:mm:ss(F7 验收口径)。
String formatErrorTime(DateTime t) {
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} '
      '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
}

/// 错误详情卡:告警头(类型/已记录徽标)+ 时间/入口/操作/异常类型 + 详情。
class ErrorDetailCard extends StatelessWidget {
  const ErrorDetailCard({super.key, required this.info});

  final ErrorInfo info;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final withStatus = info.kind == ErrorKind.api && info.status != null;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: tk.dangerSoft,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.error_outline, size: 22, color: tk.danger),
              ),
              const SizedBox(width: Tk.spaceMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '已捕获错误',
                      style: TextStyle(
                        fontSize: Tk.fzRowTitle,
                        fontWeight: FontWeight.w600,
                        color: tk.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '已自动留痕，便于定位',
                      style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Tk.spaceSm),
              const Badge(label: '已记录', tone: BadgeTone.warn),
            ],
          ),
          const SizedBox(height: Tk.spaceLg),
          Divider(color: tk.line, height: 1),
          const SizedBox(height: Tk.spaceMd),
          _kv(context, '时间', formatErrorTime(info.time)),
          _kv(context, '入口', info.source),
          _kv(context, '操作', info.kind == ErrorKind.api ? '接口请求' : '界面渲染'),
          _kv(context, '异常类型', info.kindLabel),
          if (withStatus) _kv(context, 'HTTP 状态码', '${info.status}'),
          const SizedBox(height: Tk.spaceMd),
          Divider(color: tk.line, height: 1),
          const SizedBox(height: Tk.spaceMd),
          Text(
            '错误信息',
            style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
          ),
          const SizedBox(height: Tk.spaceXs),
          SelectableText(
            info.message,
            style: TextStyle(fontSize: 15, height: 1.5, color: tk.ink),
          ),
        ],
      ),
    );
  }

  Widget _kv(BuildContext context, String label, String value) {
    final tk = context.tk;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Tk.spaceXs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(fontSize: 14, height: 1.4, color: tk.ink2),
            ),
          ),
        ],
      ),
    );
  }
}

/// 堆栈卡:等宽 12、surface2 底、限高 240 独立滚动(整页仍可滚动)。
class ErrorStackCard extends StatelessWidget {
  const ErrorStackCard({super.key, required this.stack});

  final String stack;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 240),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: tk.surface2,
        borderRadius: BorderRadius.circular(Tk.rMd),
        border: Border.all(color: tk.line),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Tk.spaceMd),
        child: SelectableText(
          stack,
          style: TextStyle(
            fontSize: 12,
            height: 1.5,
            fontFamily: 'monospace',
            color: tk.ink2,
          ),
        ),
      ),
    );
  }
}

/// 首条错误不可用(null)时的占位:关闭/推送日志仍可用。
class ErrorReportEmpty extends StatelessWidget {
  const ErrorReportEmpty({super.key});

  @override
  Widget build(BuildContext context) => const EmptyState(
    icon: Icons.report_problem_outlined,
    title: '暂无错误详情',
    message: '可返回后重试',
  );
}
