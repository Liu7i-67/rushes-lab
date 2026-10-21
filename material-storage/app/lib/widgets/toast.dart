/// toast — 全局轻提示统一封装(app-polish A6,方案 §A6):floating SnackBar
/// (离底避让导航栏)+ 统一 tone 图标配色(成功绿/失败红/信息橙)。
/// 替代各页自拼 ScaffoldMessenger(存量 117 处无 floating 无 action)。
/// 「latest wins」:展示前 hideCurrent,避免长队排播挤掉新反馈;需要
/// 排队语义的场景(少见)调用方自行 ScaffoldMessenger。
library;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

enum ToastTone { success, error, info }

/// 展示轻提示;[actionLabel] 非空时挂右侧文字 action(如「查看详情」)。
void toast(
  BuildContext context,
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
  ToastTone tone = ToastTone.info,
  Duration duration = const Duration(seconds: 3),
}) {
  final (icon, color) = switch (tone) {
    ToastTone.success => (Icons.check_circle_outline, Tk.green),
    ToastTone.error => (Icons.error_outline, Tk.red),
    ToastTone.info => (Icons.info_outline, Tk.accent),
  };
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(
          Tk.spaceMd, 0, Tk.spaceMd, Tk.spaceMd),
      duration: duration,
      content: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: Tk.spaceSm),
          Expanded(child: Text(message)),
        ],
      ),
      action: actionLabel == null
          ? null
          : SnackBarAction(label: actionLabel, onPressed: onAction ?? () {}),
    ));
}
