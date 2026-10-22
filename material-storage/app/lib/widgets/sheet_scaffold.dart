/// SheetScaffold — 底部弹层统一骨架(app-polish A4,方案 §A4/D1):
/// 键盘避让(viewInsets)+ SafeArea + maxHeight 约束 + 标题行(titleMedium
/// + 可选关闭钮)+ 错误文案行工具位 + 单子滚动区 + 可选吸底按钮区(不随
/// 内容滚动)。替代 30 处同构 showModalBottomSheet 零封装。
///
/// 两条迁移路径:
/// 1. 新代码直接 `showAppSheet<T>(...)`(透传 showModalBottomSheet 返回值,
///    兼容现有「返回 bool/结果」约定);
/// 2. 存量 sheet 低成本改造:保留原 showModalBottomSheet 调用(showDragHandle
///    + isScrollControlled),把 builder 里的自拼 Column 换成本组件。
///
/// 形态覆盖:长表单(child 为 StatefulWidget 表单,maxHeightFactor 0.9)、
/// 短菜单(无标题或仅标题,内容自适应收拢)、结果态(child 为结果卡,
/// bottomActions 给「完成」)。吸底按钮区每个 action 等分撑满:单个=通栏、
/// 两个=对半;需非通栏时调用方自行包 SizedBox/ unconstrained 组件。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// 底部弹层便捷封装(showModalBottomSheet + SheetScaffold 组合,参数透传)。
/// [T] 为返回值类型;把手对齐存量调用(showDragHandle: true)。
Future<T?> showAppSheet<T>({
  required BuildContext context,
  String? title,
  required Widget child,
  List<Widget> bottomActions = const <Widget>[],
  String? errorText,
  double maxHeightFactor = 0.9,
  bool showClose = true,
  bool isDismissible = true,
  bool enableDrag = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    builder: (_) => SheetScaffold(
      title: title,
      bottomActions: bottomActions,
      errorText: errorText,
      maxHeightFactor: maxHeightFactor,
      showClose: showClose,
      child: child,
    ),
  );
}

class SheetScaffold extends StatelessWidget {
  const SheetScaffold({
    super.key,
    this.title,
    required this.child,
    this.bottomActions = const <Widget>[],
    this.errorText,
    this.maxHeightFactor = 0.9,
    this.showClose = true,
  });

  /// 标题(titleMedium);null = 不渲染标题行(短菜单/结果态可省)。
  final String? title;

  /// 滚动区内容(长表单/菜单/结果卡;超高自动滚动,不高则收拢)。
  final Widget child;

  /// 吸底按钮区(不随内容滚动);每个 action 等分撑满。
  final List<Widget> bottomActions;

  /// 错误文案行工具位(表单提交失败等;空/null 不渲染,放标题下方)。
  final String? errorText;

  /// 弹层最大高度占屏比(含键盘避让扣除;默认 0.9)。
  final double maxHeightFactor;

  /// 标题行是否带关闭钮(仅 title 非 null 时有效;点按 pop(null))。
  final bool showClose;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final insets = mq.viewInsets.bottom;
    return Padding(
      // 键盘避让:键盘顶起弹层(SafeArea 的 bottom 会被键盘 inset 抵消,不双份)
      padding: EdgeInsets.only(bottom: insets),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          // maxHeight 因内容定:短内容收拢,长内容封顶滚动;扣除键盘后仍不溢出
          constraints: BoxConstraints(
            maxHeight:
                math.max(160.0, mq.size.height * maxHeightFactor - insets),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (title != null) _TitleRow(title: title!, showClose: showClose),
              if (errorText != null && errorText!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      Tk.spaceLg, 0, Tk.spaceLg, Tk.spaceSm),
                  child: Text(
                    errorText!,
                    style: const TextStyle(fontSize: Tk.fzSm, color: Tk.red),
                  ),
                ),
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(Tk.spaceLg, title == null ? Tk.spaceXs : 0,
                      Tk.spaceLg, bottomActions.isEmpty ? Tk.spaceLg : Tk.spaceSm),
                  child: child,
                ),
              ),
              if (bottomActions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      Tk.spaceLg, Tk.spaceXs, Tk.spaceLg, Tk.spaceLg),
                  child: Row(
                    children: [
                      for (var i = 0; i < bottomActions.length; i++) ...[
                        if (i > 0) const SizedBox(width: Tk.spaceSm),
                        Expanded(child: bottomActions[i]),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 标题行:左标题(titleMedium)右关闭钮;关闭=pop(null)。
class _TitleRow extends StatelessWidget {
  const _TitleRow({required this.title, required this.showClose});

  final String title;
  final bool showClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          Tk.spaceLg, Tk.spaceXs, Tk.spaceSm, Tk.spaceXs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (showClose)
            IconButton(
              // app-polish-2 #5 取消可见性:图标 22→24 + 去紧凑密度
              // (默认 padding 8 → 点击区加大);仅视觉/触控微调,
              // 行为仍是 pop(null),API 不变
              padding: const EdgeInsets.all(Tk.spaceSm),
              icon: const Icon(Icons.close, size: 24),
              tooltip: '关闭',
              onPressed: () => Navigator.of(context).maybePop(),
            ),
        ],
      ),
    );
  }
}
