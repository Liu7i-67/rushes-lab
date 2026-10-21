/// AppTabBar — 底部四格导航(Material 3 NavigationBar 包装,§2「TabBar 四格」)。
/// B3:传输格 badge=TransferQueue running 数(§7,含上传+下载混排)。
/// B7:我的格 badge=通知全局未读数(§8.7,unreadPoller 驱动,0 不渲染)。
library;

import 'package:flutter/material.dart';

import '../../core/polling_controller.dart';
import '../../core/transfers/transfer_queue.dart';

class AppTabBar extends StatelessWidget {
  const AppTabBar({
    super.key,
    required this.index,
    required this.onChanged,
    this.queue,
    this.poller,
  });

  final int index;
  final ValueChanged<int> onChanged;

  /// 测试注入用;默认全局单例。
  final TransferQueue? queue;

  /// 测试注入用;默认全局单例(B7 通知未读轮询)。
  final UnreadPoller? poller;

  @override
  Widget build(BuildContext context) {
    final q = queue ?? TransferQueue.I;
    return AnimatedBuilder(
      animation: q,
      builder: (context, _) {
        final running = q.runningCount;
        return NavigationBar(
          selectedIndex: index,
          onDestinationSelected: onChanged,
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.folder_copy_outlined),
              selectedIcon: Icon(Icons.folder_copy),
              label: '项目',
            ),
            const NavigationDestination(
              icon: Icon(Icons.search_outlined),
              selectedIcon: Icon(Icons.search),
              label: '搜索',
            ),
            NavigationDestination(
              // badge=running 数(0 隐藏,§7)
              icon: Badge(
                isLabelVisible: running > 0,
                label: Text('$running'),
                child: const Icon(Icons.sync_outlined),
              ),
              selectedIcon: const Icon(Icons.sync),
              label: '传输',
            ),
            NavigationDestination(
              // badge=通知全局未读数(§8.7;0 时连 Badge 一并不渲染)
              icon: _MeTabIcon(poller: poller),
              selectedIcon: const Icon(Icons.person),
              label: '我的',
            ),
          ],
        );
      },
    );
  }
}

/// 我的格图标 + 未读数 badge(unread=0 → 素图标;>0 → material Badge 数字)。
class _MeTabIcon extends StatelessWidget {
  const _MeTabIcon({this.poller});

  /// null = 全局单例(生产);测试注入隔离实例。
  final UnreadPoller? poller;

  @override
  Widget build(BuildContext context) {
    final p = poller ?? unreadPoller;
    return AnimatedBuilder(
      animation: p,
      builder: (context, _) {
        final icon = const Icon(Icons.person_outline);
        final unread = p.unreadCount;
        return unread > 0
            ? Badge(label: Text('$unread'), child: icon)
            : icon;
      },
    );
  }
}
