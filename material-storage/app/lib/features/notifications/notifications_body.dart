/// NotificationsBody — 通知列表体(§7.2 拆分):错误/加载/空态/行卡列表,
/// 列表收进 SectionCard;滚动到底(距底 <200)自动加载下一页,下拉刷新
/// 与行点击回调由页面注入,本件不持有状态。
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import 'notification_row.dart';

/// 距底不足此距离即预取下一页(自动加载阈值)。
const double _kLoadMoreThreshold = 200.0;

class NotificationsBody extends StatelessWidget {
  const NotificationsBody({
    super.key,
    required this.data,
    required this.error,
    required this.loadingMore,
    required this.onRefresh,
    required this.onLoadMore,
    required this.onOpen,
  });

  final NotificationsList? data;
  final String? error;
  final bool loadingMore;
  final Future<void> Function() onRefresh;
  final VoidCallback onLoadMore;
  final ValueChanged<NotificationItem> onOpen;

  @override
  Widget build(BuildContext context) {
    if (error != null && data == null) {
      return ErrorView(message: error!, onRetry: onRefresh);
    }
    if (data == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (data!.items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 80),
          EmptyState(
            icon: Icons.notifications_none_outlined,
            message: '暂无通知',
            description: '审批、邀请等动态会出现在这里。',
          ),
        ],
      );
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      // 滚动到底自动加载:用 NotificationListener 而非 ScrollController,
      // 内容不足一屏时 ScrollUpdate/Overscroll 恒派发。
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if ((n is ScrollUpdateNotification || n is OverscrollNotification) &&
              n.metrics.extentAfter < _kLoadMoreThreshold) {
            onLoadMore();
          }
          return false;
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(
            Tk.spacePage,
            Tk.spaceMd,
            Tk.spacePage,
            Tk.spaceXl,
          ),
          children: [
            SectionCard(
              dividerIndent: Tk.spaceLg,
              children: [
                for (final n in data!.items)
                  NotificationRow(item: n, onTap: () => onOpen(n)),
                if (loadingMore) const _LoadingMore(),
              ],
            ),
            const SizedBox(height: Tk.space2xl),
          ],
        ),
      ),
    );
  }
}

/// 自动加载 in-flight(替代「加载更多」按钮)。
class _LoadingMore extends StatelessWidget {
  const _LoadingMore();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: Tk.spaceLg),
      child: Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}
