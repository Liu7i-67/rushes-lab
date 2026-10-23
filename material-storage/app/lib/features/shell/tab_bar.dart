/// AppTabBar — 自绘底部四格导航(§6 F4):barBg 底 + 顶部 1px barLine,
/// 选中 tabFgActive + 图标下 4×4 金点,未选中 tabFg;角标为金胶囊
/// (goldBright 底 / 深墨字,0 隐藏)。传输格=TransferQueue.runningCount,
/// 我的格=通知全局未读数(unreadPoller),两类计数独立。
library;

import 'package:flutter/material.dart';

import '../../core/polling_controller.dart';
import '../../core/transfers/transfer_queue.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';

/// 金胶囊上的深墨字(§6 F4 指定 #231C0C;goldBright 在两主题下都偏亮,
/// 不随主题取 onFillInk——浅色主题的 onFillInk 为象牙白,对比不足)。
const _kBadgeInk = Color(0xFF231C0C);

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

  static const _labels = ['项目', '搜索', '传输', '我的'];
  static const _icons = [
    Icons.folder_copy_outlined,
    Icons.search,
    Icons.sync_outlined,
    Icons.person_outline,
  ];

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final q = queue ?? TransferQueue.I;
    final p = poller ?? unreadPoller;
    return AnimatedBuilder(
      animation: q,
      builder: (context, _) => AnimatedBuilder(
        animation: p,
        builder: (context, _) {
          final counts = [0, 0, q.runningCount, p.unreadCount];
          return Material(
            color: tk.barBg,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(height: 1, color: tk.barLine),
                SafeArea(
                  top: false,
                  child: Row(
                    children: [
                      for (var i = 0; i < 4; i++)
                        _TabItem(
                          index: i,
                          icon: _icons[i],
                          label: _labels[i],
                          selected: index == i,
                          badge: counts[i],
                          onTap: () => onChanged(i),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 单格:56 高,图标 22 + 3 间距 + 选中金点/占位 + 标签 11。
class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.index,
    required this.icon,
    required this.label,
    required this.selected,
    required this.badge,
    required this.onTap,
  });

  final int index;
  final IconData icon;
  final String label;
  final bool selected;
  final int badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final fg = selected ? tk.tabFgActive : tk.tabFg;
    return Expanded(
      child: Semantics(
        key: Key('tab_$index'),
        selected: selected,
        button: true,
        label: label,
        child: InkResponse(
          onTap: onTap,
          radius: 34,
          child: SizedBox(
            height: 56,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  height: 24,
                  child: Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.center,
                    children: [
                      Icon(icon, size: 22, color: fg),
                      if (badge > 0)
                        Positioned(
                          right: -14,
                          top: -3,
                          child: _TabBadge(index: index, count: badge),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                if (selected)
                  Container(
                    key: Key('tab_dot_$index'),
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      color: tk.goldBright,
                      shape: BoxShape.circle,
                    ),
                  )
                else
                  const SizedBox(height: 4),
                const SizedBox(height: 2),
                Text(
                  label,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.2,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: fg,
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

/// 金色胶囊角标(16 高 / 11 w700),0 不构建。
class _TabBadge extends StatelessWidget {
  const _TabBadge({required this.index, required this.count});

  final int index;
  final int count;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Container(
      key: Key('tab_badge_$index'),
      height: 16,
      constraints: const BoxConstraints(minWidth: 16),
      padding: const EdgeInsets.symmetric(horizontal: 4.5),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tk.goldBright,
        borderRadius: BorderRadius.circular(Tk.rPill),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        maxLines: 1,
        style: const TextStyle(
          fontSize: 11,
          height: 1,
          fontWeight: FontWeight.w700,
          color: _kBadgeInk,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
