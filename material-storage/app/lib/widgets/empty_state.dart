/// EmptyState — 列表空态统一件(§6 F3):56 圆底图标 + 标题 + 说明 + 可选主操作。
///
/// 向后兼容:既有调用只传 [message] 时,message 即标题(视觉与旧版同义);
/// 传了 [title] 时,message 降为说明文案,保证既有测试仍能 find 到 message。
library;

import 'package:flutter/material.dart';

import '../theme/context_tk.dart';
import '../theme/tokens.dart';

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    this.icon = Icons.inbox_outlined,
    required this.message,
    this.title,
    this.description,
    this.actionLabel,
    this.onAction,
    this.iconSize = 26,
  });

  final IconData icon;

  /// 空态文案;无 [title] 时作为标题,有 [title] 时作为说明(既有测试依赖)。
  final String message;

  /// 可选标题(16/w600);非空时 [message] 作为说明展示。
  final String? title;

  /// 可选补充说明(13.5/ink3,最大 28ch)。
  final String? description;

  /// 可选主操作文案(与 [onAction] 同时提供才渲染)。
  final String? actionLabel;
  final VoidCallback? onAction;

  /// 圆底内图标尺寸(圆底固定 56)。
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final heading = title ?? message;
    final secondary = <String>[
      if (title != null) message,
      if (description != null && description!.isNotEmpty) description!,
    ];
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Tk.spacePage),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: tk.surface3,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: iconSize, color: tk.ink3),
            ),
            const SizedBox(height: Tk.spaceLg),
            Text(
              heading,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: Tk.fzBody,
                fontWeight: FontWeight.w600,
                color: tk.ink,
              ),
            ),
            for (final line in secondary) ...[
              const SizedBox(height: Tk.spaceSm),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 28 * 13.5),
                child: Text(
                  line,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13.5, height: 1.6, color: tk.ink3),
                ),
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: Tk.spaceLg),
              FilledButton(
                onPressed: onAction,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(44, 42),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                ),
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
