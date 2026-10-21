/// NotificationRow — 通知行(B7 §8.7,web NotificationRow 移动版):
/// 未读橙点 + kind chip + 标题/正文 + 相对时间;点击整行回调(跳转+标已读
/// 由页面统一处理)。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/badge.dart';

/// kind → chip tone(白名单内:pending=amber/decided=green/invite=accent,
/// 未知 kind=neutral;chip 文案 raw token 回落,不崩溃)。
BadgeTone kindTone(String kind) => switch (kind) {
      'approval_pending' => BadgeTone.amber,
      'approval_decided' => BadgeTone.green,
      'folder_invite' => BadgeTone.accent,
      _ => BadgeTone.neutral,
    };

class NotificationRow extends StatelessWidget {
  const NotificationRow({super.key, required this.item, this.onTap});

  final NotificationItem item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final n = item;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: n.isUnread ? Tk.accentFaint.withValues(alpha: 0.45) : null,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 未读橙点(web 同款 accent 圆点;已读灰点)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: n.isUnread ? Tk.accent : Tk.border,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Badge(label: n.kindLabel, tone: kindTone(n.kind)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          n.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight:
                                n.isUnread ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if ((n.body ?? '').isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      n.body!,
                      style:
                          const TextStyle(fontSize: 12.5, color: Tk.muted),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(fmtTime(n.createdAt),
                      style: const TextStyle(
                          fontSize: 11, color: Tk.subtle)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ISO → 'YYYY-MM-DD HH:mm'(web 用相对时间,移动列表取绝对短格式免歧义)。
String fmtTime(String iso) {
  final t = DateTime.tryParse(iso)?.toLocal();
  if (t == null) return iso;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}';
}
