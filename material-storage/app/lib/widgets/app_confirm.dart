/// showAppConfirm — 统一确认弹层(app-polish A5,方案 §A5):替代 24 处
/// 零散 AlertDialog 确认。标题/正文/确认/取消文案可配,危险态确认钮走
/// DangerButton 红底(删除/撤销等);返回 `Future<bool?>`——确认 true、
/// 取消 false、点遮罩/返回键 null(调用方按 `!= true` 视为未确认,与
/// 存量 `ok != true` 口径一致)。
library;

import 'package:flutter/material.dart';

import 'buttons.dart';

Future<bool?> showAppConfirm(
  BuildContext context, {
  required String title,
  String? content,
  String confirmLabel = '确认',
  String cancelLabel = '取消',
  bool danger = false,
  bool barrierDismissible = true,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (ctx) => AlertDialog(
      // 标题/正文走主题默认字级(M3 titleLarge/bodyMedium),与存量 AlertDialog
      // 视觉零跳变;后续全局字阶调整只动主题一处
      title: Text(title),
      content:
          content == null || content.isEmpty ? null : Text(content),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(cancelLabel),
        ),
        danger
            ? DangerButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                label: confirmLabel,
              )
            : FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(confirmLabel),
              ),
      ],
    ),
  );
}
