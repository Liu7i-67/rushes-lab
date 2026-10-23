/// NotificationRow — 通知行(§6 F13 二级页):未读 8 金点 + goldSoft 行底,
/// kind 徽标(pending=warn / decided=ok / invite=gold / 未知=neutral),
/// 标题 14.5/w600、正文 13/ink2、相对时间 11.5/ink3;整行点击(跳转+标已读
/// 由页面统一处理)。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/fmt.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/badge.dart';

/// kind → chip tone:待审=warn / 结果=ok / 邀请=gold / 未知=neutral
/// (chip 文案 raw token 回落,不崩溃)。
BadgeTone kindTone(String kind) => switch (kind) {
  'approval_pending' => BadgeTone.warn,
  'approval_decided' => BadgeTone.ok,
  'folder_invite' => BadgeTone.gold,
  _ => BadgeTone.neutral,
};

class NotificationRow extends StatelessWidget {
  const NotificationRow({super.key, required this.item, this.onTap});

  final NotificationItem item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final n = item;
    // P2-6:未读不再只靠颜色——整行语义标注「未读/已读通知」+ 按钮角色,
    // 读屏用户不必依赖视觉差异。
    return Semantics(
      container: true,
      button: true,
      label: n.isUnread ? '未读通知' : '已读通知',
      child: Material(
        // 未读行金色浅底;已读透明(分隔线由外层 SectionCard 提供)
        color: n.isUnread ? tk.goldSoft : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Tk.spaceLg,
              vertical: 14,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 未读金点(8);已读留同宽透明位保持标题对齐
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Container(
                    key: ValueKey('notif-dot-${n.id}'),
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: n.isUnread ? tk.gold : Colors.transparent,
                    ),
                  ),
                ),
                const SizedBox(width: Tk.spaceMd),
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
                                fontSize: 14.5,
                                height: 1.45,
                                fontWeight: FontWeight.w600,
                                color: tk.ink,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if ((n.body ?? '').isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          n.body!,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: Tk.fzMd,
                            height: 1.55,
                            color: tk.ink2,
                          ),
                        ),
                      ],
                      const SizedBox(height: 5),
                      // 相对时间(刚刚/N 分钟前/N 小时前/昨天/日期)
                      Text(
                        fmtRelativeTime(n.createdAt),
                        style: TextStyle(fontSize: 11.5, color: tk.ink3),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// ISO → 'YYYY-MM-DD HH:mm'(绝对短格式保留供他处复用;通知行用
/// core/fmt.dart 的 fmtRelativeTime)。
String fmtTime(String iso) {
  final t = DateTime.tryParse(iso)?.toLocal();
  if (t == null) return iso;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}';
}
