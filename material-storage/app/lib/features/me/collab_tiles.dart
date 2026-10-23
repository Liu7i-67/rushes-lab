/// MePage 协作区入口(B7 §8.6/§8.7;墨金 WP2 视觉):审批中心(admin 挂
/// 待审数徽标,RefreshBus 'approvals' 失效同步)+ 通知(全局未读金点,
/// unreadPoller 驱动)+ 我的权限。入口人人可见,badge 从严收敛。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/polling_controller.dart';
import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../theme/context_tk.dart';
import '../../widgets/app_row.dart';
import '../../widgets/badge.dart';

/// 审批中心入口:badge=待我审批数(scope=all&status=pending 同源;
/// **仅 is_system_admin 挂 badge**——非 admin 挂 badge 只见全组织噪声)。
class ApprovalsTile extends StatefulWidget {
  const ApprovalsTile({super.key, this.badgeEnabled = true});

  /// 测试注入可关 badge 拉取(非 admin 口径单测)。
  final bool badgeEnabled;

  @override
  State<ApprovalsTile> createState() => _ApprovalsTileState();
}

class _ApprovalsTileState extends State<ApprovalsTile> {
  int? _pendingCount;
  bool get _badgeOn =>
      widget.badgeEnabled && (session.me?.isSystemAdmin ?? false);

  @override
  void initState() {
    super.initState();
    _loadBadge();
    RefreshBus.I.addListener('approvals', _loadBadge);
  }

  @override
  void dispose() {
    RefreshBus.I.removeListener('approvals', _loadBadge);
    super.dispose();
  }

  Future<void> _loadBadge() async {
    if (!_badgeOn) return;
    try {
      final r = await session.api!.approvalsOps.list(
        scope: 'all',
        status: 'pending',
      );
      if (mounted) setState(() => _pendingCount = r.length);
    } catch (_) {} // badge 静默失败:入口仍可点,列表页内重试
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final n = _pendingCount ?? 0;
    return AppRow(
      leading: const Icon(Icons.how_to_vote_outlined),
      title: '审批中心',
      onTap: () async {
        await Navigator.of(context).pushNamed('/approvals');
        _loadBadge(); // 返回即对账
      },
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_badgeOn && n > 0) ...[
            Badge(label: n >= 50 ? '50+' : '$n', tone: BadgeTone.gold),
            const SizedBox(width: 6),
          ],
          Icon(Icons.chevron_right, size: 18, color: tk.ink3),
        ],
      ),
    );
  }
}

/// 通知入口:金点=全局未读(unreadPoller 驱动,mark-read 即时同步)。
class NotificationsTile extends StatelessWidget {
  const NotificationsTile({super.key, this.poller});

  /// 测试注入;默认全局单例。
  final UnreadPoller? poller;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final p = poller ?? unreadPoller;
    return AnimatedBuilder(
      animation: p,
      builder: (context, _) {
        final unread = p.unreadCount;
        return AppRow(
          leading: const Icon(Icons.notifications_outlined),
          title: '通知',
          onTap: () => Navigator.of(context).pushNamed('/notifications'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (unread > 0) ...[
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: tk.gold,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Icon(Icons.chevron_right, size: 18, color: tk.ink3),
            ],
          ),
        );
      },
    );
  }
}

/// 我的权限入口(双数据源列表页;无 badge 口径)。
class MyPermissionsTile extends StatelessWidget {
  const MyPermissionsTile({super.key});

  @override
  Widget build(BuildContext context) {
    return AppRow(
      leading: const Icon(Icons.shield_outlined),
      title: '我的权限',
      subtitle: '项目角色与临时授权',
      onTap: () => Navigator.of(context).pushNamed('/my-permissions'),
    );
  }
}
