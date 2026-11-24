/// AssetsBody — 宫格页 body 装配件(assets_page 拆件,守 300 行硬顶):
/// 首载骨架 / 错误 / 空态 / 3 列宫格全分支;AlwaysScrollable 可下拉刷新;
/// ScrollController 到底(<200px)自动加载 + 底部线性指示,失败 toast + 底部
/// 点击重试条。数据/选中态归 AssetsPage 所有,本组件纯展示。
/// 快速滚动批(F3):GridView itemCount=total(全量撑出正确滚动高度),
/// itemBuilder 经 PagedWindow.assetAt 取数——未命中渲染 AssetTileSkeleton,
/// 命中渲染既有 AssetGridTile。数据流取最简标量透传:页面只传 `total` /
/// `descending`(_sortDesc),本组件每次 build 自建 PagedWindow(纯值对象,
/// 不存在过期窗口对象;窗口状态本体仍在页面 _items/_total/_sortDesc)。
/// 右缘叠 FastScrollBar(F2,纯 UI;loading/error/empty 态无网格故整体
/// 不在树中),显隐只看 selecting 与 total≥100;滚动条释放 onSeek 与骨架
/// 命中 onEnsureVisible 均回调页面补齐(页面侧去重防风暴)。
library;

import 'package:flutter/material.dart';

import '../../core/paged_window.dart';
import '../../core/thumb_variant.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/error_view.dart';
import '../../widgets/fast_scroll_bar.dart';
import '../../widgets/list_skeleton.dart';
import 'asset_tile.dart';
import 'upload_guide.dart';

/// 距底部不足该像素即触发自动加载。
const _loadMoreThreshold = 200.0;

/// 宫格列间距(原型 10)。
const _gridGap = 10.0;

/// 快速滚动条显示的最小全量数(D4:小列表滚动条是噪音)。
const _fastScrollMinTotal = 100;

class AssetsBody extends StatefulWidget {
  const AssetsBody({
    super.key,
    required this.loading,
    required this.error,
    required this.items,
    required this.total,
    required this.descending,
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
    required this.onSeek,
    required this.onEnsureVisible,
    required this.onUploadTap,
  });

  final bool loading;
  final String? error;
  final List<Asset> items;

  /// 后端全量计数(快速滚动批 F3):itemCount=total 撑出正确滚动高度。
  final int total;

  /// 页面排序是否 DESC(快速滚动批 F3):本组件据其自建 PagedWindow,
  /// ASC 时已加载区在显示序尾(骨架在头部)。
  final bool descending;
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

  /// 快速滚动条拖动释放定位(显示序,快速滚动批 F2/F3)。
  final ValueChanged<int> onSeek;

  /// 骨架 tile 命中(传显示序=视口内最深骨架;页面侧 _ensureVisibleLoaded
  /// 自带在途/pending 去重,骨架反复 rebuild 不会请求风暴)。
  final ValueChanged<int> onEnsureVisible;
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

  /// 骨架 tile 命中:帧末回调页面补齐(build 期间不得 setState,延一帧;
  /// 重复触发由页面 _ensureVisibleLoaded 在途/pending 守卫吸收)。
  void _notifyEnsure(int displayIndex) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onEnsureVisible(displayIndex);
    });
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
                Expanded(
                  child: Stack(
                    children: [
                      _grid(context),
                      // 右缘竖条与底部 UploadPillOverlay 不重叠,无需特判避让;
                      // Align 摆右缘(组件吃满高,用法见 fast_scroll_bar 头注)
                      Align(
                        alignment: Alignment.centerRight,
                        child: FastScrollBar(
                          controller: _scroll,
                          total: widget.total,
                          visible:
                              !widget.selecting &&
                              widget.total >= _fastScrollMinTotal,
                          onSeek: widget.onSeek,
                        ),
                      ),
                    ],
                  ),
                ),
                if (widget.loadingMore)
                  const LinearProgressIndicator(minHeight: 2),
                if (widget.loadMoreFailed && !widget.loadingMore)
                  _retryBar(context),
              ],
            ),
    );
  }

  Widget _grid(BuildContext context) {
    // 窗口按 build 现态重建(纯值对象):显示序 ↔ 已加载区 映射。
    final window = PagedWindow(
      total: widget.total,
      loaded: widget.items.length,
      descending: widget.descending,
    );
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
      itemCount: widget.total,
      itemBuilder: (context, i) {
        final a = window.assetAt(i, widget.items);
        if (a == null) {
          // 未加载区:骨架占位(不可点按),命中即帧末触发一次补齐。
          _notifyEnsure(i);
          return const AssetTileSkeleton();
        }
        final selected = widget.selectedIds.contains(a.id);
        return AssetGridTile(
          index: i,
          asset: a,
          // thumb-variant 批 D1:宫格 cell 实渲染 ≈110dp → small(240px)变体
          variant: ThumbVariant.small,
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
