/// AppTabBar — 底部四格导航(Material 3 NavigationBar 包装,§2「TabBar 四格」)。
/// B3:传输格 badge=TransferQueue running 数(§7,含上传+下载混排)。
library;

import 'package:flutter/material.dart';

import '../../core/transfers/transfer_queue.dart';

class AppTabBar extends StatelessWidget {
  const AppTabBar({
    super.key,
    required this.index,
    required this.onChanged,
    this.queue,
  });

  final int index;
  final ValueChanged<int> onChanged;

  /// 测试注入用;默认全局单例。
  final TransferQueue? queue;

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
            const NavigationDestination(
              icon: Icon(Icons.person_outline),
              selectedIcon: Icon(Icons.person),
              label: '我的',
            ),
          ],
        );
      },
    );
  }
}
