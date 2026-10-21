/// AssetsBody — 宫格页 body 装配件(assets_page 拆件,守 300 行硬顶):
/// app-polish 重做——B9 首载 ListSkeleton(3 列)+ loading/error/empty 全分支
/// AlwaysScrollableScrollPhysics 可下拉刷新(R3 模式);B3 移除「加载更多」
/// 格子,ScrollController 到底(<200px)自动加载+底部线性指示,失败 toast+
/// 底部点击重试条;B4 开发日志横条移除(调试信息不入产品 UI)。数据/选中态
/// 归 AssetsPage 所有,纯展示。
library;

import 'package:flutter/material.dart';

import '../../core/transfers/transfer_queue.dart' show TransferQueue;
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/error_view.dart';
import '../../widgets/list_skeleton.dart';
import 'asset_tile.dart';
import 'upload_sheet.dart';

/// B3:距底部不足该像素即触发自动加载。
const _loadMoreThreshold = 200.0;

class AssetsBody extends StatefulWidget {
  const AssetsBody({
    super.key,
    required this.loading,
    required this.error,
    required this.items,
    required this.total,
    required this.selectedIds,
    required this.loadingMore,
    required this.loadMoreFailed,
    required this.canUpload,
    required this.hasFab,
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

  /// B3:上次加载更多失败(底部显示点击重试条;滚动重滑亦可再触发)。
  final bool loadMoreFailed;

  /// 上传入口显隐(§13);null=详情未到/失败,保持现役显示口径。
  final bool? canUpload;

  /// B5:页面当前挂上传 FAB(宫格底部留白避让,防末行被遮)。
  final bool hasFab;

  final TransferQueue? transferQueue;

  final Future<void> Function() onRefresh;
  final VoidCallback onRetry;
  final void Function(Asset a) onToggle;
  final void Function(int index) onOpen;
  final VoidCallback onLoadMore;
  final VoidCallback onUploadTap;

  @override
  State<AssetsBody> createState() => _AssetsBodyState();
}

class _AssetsBodyState extends State<AssetsBody> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// B3:滚到底(<200px)自动加载;页面侧有 _loadingMore/total 双保险去重。
  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.extentAfter < _loadMoreThreshold) {
      widget.onLoadMore();
    }
  }

  /// R3 模式(projects_page 同款):非列表内容包全高可滚动,使 RefreshIndicator
  /// 在 loading/error/empty 态也能下拉刷新。
  Widget _scrollable(Widget child) {
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: constraints.maxHeight, child: Center(child: child)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      child: widget.loading
          ? _scrollable(const ListSkeleton(columns: 3)) // B9:首载宫格骨架
          : widget.error != null
              ? _scrollable(ErrorView(message: widget.error!, onRetry: widget.onRetry))
              : widget.items.isEmpty
                  ? Column(children: [
                      UploadMiniBar(
                          queue: widget.transferQueue,
                          onTap: () => openTransfersView(context)),
                      Expanded(
                          child: _scrollable(UploadEmptyGuide(
                              enabled: widget.canUpload != false,
                              onTap: widget.onUploadTap))),
                    ])
                  : Column(children: [
                      UploadMiniBar(
                          queue: widget.transferQueue,
                          onTap: () => openTransfersView(context)),
                      Expanded(child: _grid(context)),
                      // B3:底部线性加载指示(替代「加载更多」格子)
                      if (widget.loadingMore)
                        const LinearProgressIndicator(minHeight: 2),
                      // B3:失败重试条(点击重载;重新下滑到底亦可触发)
                      if (widget.loadMoreFailed && !widget.loadingMore)
                        _retryBar(context),
                    ]),
    );
  }

  Widget _grid(BuildContext context) {
    return GridView.builder(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      // B5:挂 FAB 时底部留白避让,防末行被浮层遮住
      padding: EdgeInsets.fromLTRB(Tk.spaceSm, Tk.spaceSm, Tk.spaceSm,
          widget.hasFab ? Tk.spaceXl * 4 : Tk.spaceSm),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: Tk.spaceSm,
        crossAxisSpacing: Tk.spaceSm,
        childAspectRatio: 0.72,
      ),
      itemCount: widget.items.length, // B3:「加载更多」格子移除
      itemBuilder: (context, i) {
        final a = widget.items[i];
        final selected = widget.selectedIds.contains(a.id);
        return AssetGridTile(
          asset: a,
          selected: selected,
          selecting: widget.selectedIds.isNotEmpty,
          onTap: widget.selectedIds.isNotEmpty
              ? () => widget.onToggle(a)
              : () => widget.onOpen(i),
          onLongPress: () {
            if (!selected) widget.onToggle(a); // 长按=进入多选
          },
        );
      },
    );
  }

  Widget _retryBar(BuildContext context) {
    final color = Theme.of(context).colorScheme.error;
    return InkWell(
      onTap: widget.onLoadMore,
      child: SizedBox(
        height: 28,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 14, color: color),
            const SizedBox(width: Tk.spaceXs),
            Text('加载失败,点击重试',
                style: TextStyle(fontSize: Tk.fzXs, color: color)),
          ],
        ),
      ),
    );
  }
}
