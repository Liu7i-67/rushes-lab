/// AssetsBody — 宫格页 body 装配件(assets_page 拆件,守 300 行硬顶):
/// 全屏 spinner/错误重试/空态引导(上传第二入口)+ 顶部迷你进度条 + 日志横条
/// + 3 列网格(下拉刷新+加载更多)。数据/选中态归 AssetsPage 所有,纯展示。
library;

import 'package:flutter/material.dart';

import '../../core/transfers/transfer_queue.dart' show TransferQueue;
import '../../models/models.dart';
import '../../widgets/error_view.dart';
import 'asset_tile.dart';
import 'upload_sheet.dart';

class AssetsBody extends StatelessWidget {
  const AssetsBody({
    super.key,
    required this.loading,
    required this.error,
    required this.items,
    required this.total,
    required this.selectedIds,
    required this.loadingMore,
    required this.canUpload,
    required this.logLine,
    this.transferQueue,
    required this.onRefresh,
    required this.onRetry,
    required this.onToggle,
    required this.onOpen,
    required this.onLoadMore,
    required this.onUploadTap,
  });

  final bool loading;
  final String? error;
  final List<Asset> items;
  final int total;
  final Set<String> selectedIds;
  final bool loadingMore;

  /// 上传入口显隐(§13);null=详情未到/失败,保持现役显示口径。
  final bool? canUpload;

  /// 顶部日志横条文案(单行快照;null=不渲染)。
  final String? logLine;
  final TransferQueue? transferQueue;

  final Future<void> Function() onRefresh;
  final VoidCallback onRetry;
  final void Function(Asset a) onToggle;
  final void Function(int index) onOpen;
  final VoidCallback onLoadMore;
  final VoidCallback onUploadTap;

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null) return ErrorView(message: error!, onRetry: onRetry);
    if (items.isEmpty) {
      // 空态引导=上传第二入口(§5);my_can_upload 已知 false 时只留文案
      return Column(
        children: [
          UploadMiniBar(queue: transferQueue),
          Expanded(
              child: UploadEmptyGuide(
                  enabled: canUpload != false, onTap: onUploadTap)),
        ],
      );
    }
    return Column(
      children: [
        UploadMiniBar(queue: transferQueue),
        if (logLine != null)
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: Text(logLine!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall),
          ),
        Expanded(child: _grid(context)),
      ],
    );
  }

  Widget _grid(BuildContext context) {
    final hasMore = items.length < total;
    final selecting = selectedIds.isNotEmpty;
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: GridView.builder(
        padding: const EdgeInsets.all(8),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 0.72,
        ),
        itemCount: items.length + (hasMore ? 1 : 0),
        itemBuilder: (context, i) {
          if (i >= items.length) {
            return InkWell(
              onTap: onLoadMore,
              child: Center(
                child: loadingMore
                    ? const Center(
                        child: SizedBox(
                            width: 18,
                            height: 18,
                            child:
                                CircularProgressIndicator(strokeWidth: 2)))
                    : Text('加载更多(${items.length}/$total)'),
              ),
            );
          }
          final a = items[i];
          final selected = selectedIds.contains(a.id);
          return AssetGridTile(
            asset: a,
            selected: selected,
            selecting: selecting,
            onTap: selecting ? () => onToggle(a) : () => onOpen(i),
            onLongPress: () {
              if (!selected) onToggle(a); // 长按=进入多选
            },
          );
        },
      ),
    );
  }
}
