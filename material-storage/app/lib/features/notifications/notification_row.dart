/// NotificationRow — 通知行(B7 §8.7,web NotificationRow 移动版;
/// app-polish E6 精修):未读橙点 + kind chip + 标题/正文 + 相对时间
/// (fmtRelativeTime);行距/字号/圆角 token 化;点击整行回调(跳转+标已读
/// 由页面统一处理)。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/fmt.dart';
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
      borderRadius: const BorderRadius.all(Radius.circular(Tk.rMd)),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: 14, vertical: Tk.spaceMd),
        decoration: BoxDecoration(
          color: n.isUnread ? Tk.accentFaint.withValues(alpha: 0.45) : null,
          borderRadius: const BorderRadius.all(Radius.circular(Tk.rMd)),
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
                      const SizedBox(width: Tk.spaceSm),
                      Expanded(
                        child: Text(
                          n.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: Tk.fzMd,
                            fontWeight:
                                n.isUnread ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if ((n.body ?? '').isNotEmpty) ...[
                    const SizedBox(height: Tk.spaceXs),
                    Text(
                      n.body!,
                      style: const TextStyle(
                          fontSize: Tk.fzSm, color: Tk.muted),
                    ),
                  ],
                  const SizedBox(height: Tk.spaceXs),
                  // E6:相对时间(刚刚/N 分钟前/N 小时前/昨天/日期)
                  Text(fmtRelativeTime(n.createdAt),
                      style: const TextStyle(
                          fontSize: Tk.fzXs, color: Tk.subtle)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ISO → 'YYYY-MM-DD HH:mm'(绝对短格式保留供他处复用;通知行改用
/// core/fmt.dart 的 fmtRelativeTime,E6 相对时间口径)。
String fmtTime(String iso) {
  final t = DateTime.tryParse(iso)?.toLocal();
  if (t == null) return iso;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}';
}
