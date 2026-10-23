/// AssetsBody — 宫格页 body 装配件(assets_page 拆件,守 300 行硬顶):
/// 首载骨架 / 错误 / 空态 / 3 列宫格全分支;AlwaysScrollable 可下拉刷新;
/// ScrollController 到底(<200px)自动加载 + 底部线性指示,失败 toast + 底部
/// 点击重试条。数据/选中态归 AssetsPage 所有,本组件纯展示。
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/error_view.dart';
import '../../widgets/list_skeleton.dart';
import 'asset_tile.dart';
import 'upload_guide.dart';

/// 距底部不足该像素即触发自动加载。
const _loadMoreThreshold = 200.0;

/// 宫格列间距(原型 10)。
const _gridGap = 10.0;

class AssetsBody extends StatefulWidget {
  const AssetsBody({
    super.key,
    required this.loading,
    required this.error,
    required this.items,
    required this.selectedIds,
    required this.selecting,
    required this.loadingMore,
    required this.loadMoreFailed,
    required this.canUpload,
    required this.hasFab,
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
  final Set<String> selectedIds;

  /// 页面显式多选态(0 选中也成立;长按/「选择」进入)。
  final bool selecting;
  final bool loadingMore;

  /// 上次加载更多失败(底部显示点击重试条;滚动重滑亦可再触发)。
  final bool loadMoreFailed;

  /// 上传入口显隐;null=详情未到/失败,保持现役显示口径。
  final bool? canUpload;

  /// 页面当前挂上传 FAB(宫格底部留白避让,防末行被遮)。
  final bool hasFab;

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

  /// 滚到底(<200px)自动加载;页面侧有 _loadingMore/total 双保险去重。
  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.extentAfter < _loadMoreThreshold) {
      widget.onLoadMore();
    }
  }

  /// 非列表内容包全高可滚动,使 RefreshIndicator 在 loading/error/empty 态
  /// 也能下拉刷新(projects_page 同款 R3 模式)。
  Widget _scrollable(Widget child) {
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: constraints.maxHeight,
            child: Center(child: child),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      child: widget.loading
          ? _scrollable(const ListSkeleton(columns: 3))
          : widget.error != null
          ? _scrollable(
              ErrorView(message: widget.error!, onRetry: widget.onRetry),
            )
          : widget.items.isEmpty
          ? _scrollable(
              UploadEmptyGuide(
                enabled: widget.canUpload != false,
                onTap: widget.onUploadTap,
              ),
            )
          : Column(
              children: [
                Expanded(child: _grid(context)),
                if (widget.loadingMore)
                  const LinearProgressIndicator(minHeight: 2),
                if (widget.loadMoreFailed && !widget.loadingMore)
                  _retryBar(context),
              ],
            ),
    );
  }

  Widget _grid(BuildContext context) {
    return GridView.builder(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(
        Tk.spacePage,
        Tk.spaceXs,
        Tk.spacePage,
        widget.hasFab ? Tk.spaceXl * 4 : Tk.spacePage,
      ),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: _gridGap,
        crossAxisSpacing: _gridGap,
        childAspectRatio: 0.72,
      ),
      itemCount: widget.items.length,
      itemBuilder: (context, i) {
        final a = widget.items[i];
        final selected = widget.selectedIds.contains(a.id);
        return AssetGridTile(
          index: i,
          asset: a,
          selected: selected,
          selecting: widget.selecting,
          onTap: widget.selecting
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
    final color = context.tk.danger;
    return InkWell(
      onTap: widget.onLoadMore,
      child: SizedBox(
        height: 28,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 14, color: color),
            const SizedBox(width: Tk.spaceXs),
            Text(
              '加载失败,点击重试',
              style: TextStyle(fontSize: Tk.fzXs, color: color),
            ),
          ],
        ),
      ),
    );
  }
}
