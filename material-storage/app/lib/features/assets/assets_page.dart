/// 资产宫格页(F8):3 列缩略图、点按=预览、长按/「选择」=多选。
/// 页面只保留状态与编排(页头/网格/操作栏/上传胶囊各自拆件);
/// 保留 RefreshBus 订阅、静默刷新代际、分页自动加载、my_can_* 与上传闸门。
/// 快速滚动批(F3):页面上叠加 PagedWindow 窗口模型——_items 恒为后端
/// offset 域 [0, n) 连续前缀(D5),显示序由 PagedWindow 按 _sortDesc 换算;
/// _loadMore 泛化为 _ensureVisibleLoaded(跳转/骨架命中缺口分批并行补齐)。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart' show errorMessage;
import '../../core/ensure_planner.dart';
import '../../core/paged_window.dart';
import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../core/thumb_variant.dart';
import '../../core/transfers/transfer_queue.dart';
import '../../models/models.dart';
import '../../services/app_log.dart';
import '../../theme/tokens.dart';
import '../../widgets/toast.dart';
import 'asset_selection_bar.dart';
import 'assets_body.dart';
import 'assets_header.dart';
import 'selection_actions.dart';
import 'thumb_prewarm.dart' show prewarmThumbUrls;
import 'upload_pick.dart' show showUploadSheet;
import 'upload_progress_pill.dart';
import 'upload_sheet.dart' show openTransfersView;

class AssetsPage extends StatefulWidget {
  const AssetsPage({
    super.key,
    required this.folderId,
    required this.folderName,
    this.where,
    this.transferQueue,
  });

  final String folderId;
  final String folderName;

  /// 上传/下载任务归属显示路径(项目/文件夹;路由未传时退回宫格名)。
  final String? where;
  final TransferQueue? transferQueue;

  @override
  State<AssetsPage> createState() => _AssetsPageState();
}

class _AssetsPageState extends State<AssetsPage> {
  static const _pageSize = 200;

  /// 补齐批次上限(后端 assets list limit le=500,快速滚动批 F3)。
  static const _batchLimit = 500;
  final _items = <Asset>[];
  final _selection = GridSelection();
  var _total = 0;
  var _loading = true;
  var _loadingMore = false;
  var _loadMoreFailed = false;
  var _sortDesc = true;
  String? _error;

  /// 刷新代际:响应落地时对不上最新代际则丢弃,防慢响应覆盖新数据。
  var _fetchEpoch = 0;

  /// 补齐加载在途时记下的续补目标(骨架命中/滚动条定位二次触发不丢):
  /// 裸 displayEnd(不含余量,P2-3 统一语义;消费时再 + 一页余量换算缺口),
  /// 本轮完成后按新状态续拉;去重守卫防骨架 tile 反复 setState 造成请求风暴。
  int? _pendingTarget;

  /// 窗口模型由状态派生(F3):total=后端全量计数、loaded=已加载条数、
  /// descending 跟随 _sortDesc(_toggleSort 翻转即同步翻转,骨架区尾↔头)。
  PagedWindow get _window =>
      PagedWindow(total: _total, loaded: _items.length, descending: _sortDesc);

  /// 已加载区的显示序尾(DESC 骨架在尾=len-1;ASC 骨架在头=total-1):
  /// onLoadMore 既有入口语义=ensureVisibleLoaded(当前已加载尾)。
  int get _loadedDisplayEnd => _sortDesc ? _items.length - 1 : _total - 1;

  bool? _canDownload;
  bool? _canUpload;
  Folder? _detail;
  @override
  void initState() {
    super.initState();
    RefreshBus.I.addListener('assets:${widget.folderId}', _onInvalidated);
    _refresh();
  }

  @override
  void dispose() {
    RefreshBus.I.removeListener('assets:${widget.folderId}', _onInvalidated);
    super.dispose();
  }

  void _onInvalidated() {
    AppLog.info('assets', 'assets:${widget.folderId} 失效 → 宫格静默刷新');
    _silentRefresh();
  }

  Future<(AssetPage, Folder?)> _fetchPage() async {
    final results = await Future.wait<Object?>([
      session.api!.assets.list(widget.folderId, limit: _pageSize),
      session.api!.folders
          .get(widget.folderId)
          .then<Folder?>((f) => f)
          .catchError((_) => null),
    ]);
    return (results[0] as AssetPage, results[1] as Folder?);
  }

  void _applyPage(AssetPage page, Folder? detail) {
    _items
      ..clear()
      ..addAll(sortAssetsByCreatedAt(page.items, desc: _sortDesc));
    _total = page.total.toInt();
    _canDownload = detail?.myCanDownload;
    _canUpload = detail?.myCanUpload;
    _detail = detail;
    // thumb-variant 批 D1:宫格 cell 取 small → 预热同规格(small)避免白签 large
    unawaited(prewarmThumbUrls(page.items, variant: ThumbVariant.small));
    // W3 #17 挂点①(首载/刷新/重试/静默刷新共用落点)
  }

  /// 全屏刷新(首拉/下拉/重试):整页骨架,失败走整页错误。
  Future<void> _refresh() async {
    final epoch = ++_fetchEpoch;
    setState(() {
      _loading = true;
      _error = null;
      _loadMoreFailed = false;
    });
    try {
      final (page, detail) = await _fetchPage();
      if (!mounted || epoch != _fetchEpoch) return;
      setState(() {
        _applyPage(page, detail);
        _selection.clear();
        _loading = false;
      });
    } catch (e) {
      if (!mounted || epoch != _fetchEpoch) return;
      setState(() {
        _error = errorMessage(e, '素材加载失败,请下拉重试');
        _loading = false;
      });
    }
  }

  /// 静默刷新:旧列表保留后台重拉成功 swap;出口均以「本路仍最新代际」为界
  /// 清 _loading(全屏在途被丢弃时全屏路不会回来清,否则卡死)。
  Future<void> _silentRefresh() async {
    final epoch = ++_fetchEpoch;
    bool fresh() => mounted && epoch == _fetchEpoch;
    try {
      final (page, detail) = await _fetchPage();
      if (!fresh()) return;
      setState(() {
        _applyPage(page, detail);
        // 他端删除的资产不在新页,剪掉失效选中 id。
        _selection.retain({for (final a in page.items) a.id});
        _error = null;
        _loading = false;
      });
    } catch (e) {
      AppLog.error('assets', '静默刷新失败,保留旧列表', e);
      if (fresh()) setState(() => _loading = false);
    }
  }

  /// 补齐显示序 [0, displayEnd + 一页余量) 覆盖的未加载缺口(快速滚动批 F3,
  /// 原 _loadMore 泛化):在途守卫/pending 续补语义走 EnsurePlanner 决策
  /// (P2-3 抽取,裸 displayEnd 统一语义,消费时再加余量),本页保留 fetch
  /// 策略——缺口按后端上限 500 分批(offset 累进、Future.wait 并行),见
  /// [_fetchGap]。_items 恒为 offset 域连续前缀(D5),故 ASC 头部缺口补齐
  /// 会连带拉齐至列表尾(模型一致的最小拉法)。失败走既有 _loadMoreFailed
  /// + toast 通道;触发入口:滚到底(onLoadMore)、滚动条释放定位(onSeek)、
  /// 骨架命中(onEnsureVisible),三者共用本方法去重防风暴。
  Future<void> _ensureVisibleLoaded(int displayEnd) async {
    // 失败闸不在决策核心:宫格页失败闸在骨架命中入口(_onSkeletonHit:失败
    // 不自动重试,防失败循环风暴),滚动到底/重试入口有意放行(F5 滚动重滑
    // 重试语义),故 loadMoreFailed/force 走默认值(不闸)。
    final decision = EnsurePlanner.decide(
      window: _window,
      displayEnd: displayEnd,
      margin: _pageSize,
      loading: _loading,
      hasError: _error != null,
      loadingMore: _loadingMore,
      pendingTarget: _pendingTarget,
    );
    switch (decision) {
      case EnsureIgnore():
        return;
      case EnsureRecordPending(displayEnd: final target):
        _pendingTarget = target; // 裸显示序;续补消费时再 + 一页余量
        return;
      case EnsureFetch(:final start, :final end):
        await _fetchGap(start, end);
    }
  }

  /// 缺口拉取(宫格 fetch 策略,窗口 [start, end) 由决策层换算):缺口按
  /// 500 分批,offset 累进;并行发出、按 offset 序收拢,append、id 去重,
  /// 再按当前 _sortDesc 全量重排。在途期间记录的续补目标:有进展才续补
  /// 一轮(gap=null 即空转返回;无进展清 pending 防死循环)。
  Future<void> _fetchGap(int start, int end) async {
    setState(() {
      _loadingMore = true;
      _loadMoreFailed = false;
    });
    try {
      final pages = await Future.wait([
        for (var o = start; o < end; o += _batchLimit)
          session.api!.assets.list(
            widget.folderId,
            limit: (o + _batchLimit) > end ? end - o : _batchLimit,
            offset: o,
          ),
      ]);
      if (!mounted) return;
      var progressed = false;
      setState(() {
        final before = _items.length;
        final seen = <String>{};
        final merged = [..._items, for (final page in pages) ...page.items];
        _items
          ..clear()
          ..addAll(
            sortAssetsByCreatedAt([
              for (final a in merged)
                if (seen.add(a.id)) a,
            ], desc: _sortDesc),
          );
        _loadingMore = false;
        // 防御:缺口响应为空时不续补(免死循环),目标作废待再触发。
        progressed = _items.length > before;
      });
      // thumb-variant 批 D1:同挂点①,增量页逐页预热 small(与宫格 cell 同规格)
      for (final page in pages) {
        unawaited(prewarmThumbUrls(page.items, variant: ThumbVariant.small));
      }
      // W3 #17 挂点②(merge 后;不经 _applyPage)
      // 在途期间记录的续补目标:以最新状态再补一轮(gap=null 即空转返回)。
      final pending = EnsurePlanner.nextRound(
        pendingTarget: _pendingTarget,
        progressed: progressed,
      );
      _pendingTarget = null;
      if (pending != null) await _ensureVisibleLoaded(pending);
    } catch (e) {
      AppLog.error('assets', '加载更多失败', e);
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _loadMoreFailed = true;
      });
      toast(context, errorMessage(e, '加载失败,请重试'), tone: ToastTone.error);
    }
  }

  /// 骨架命中入口(快速滚动批 F3):失败态不再自动重试(骨架 tile 未消,
  /// 逐帧重建会形成失败循环风暴),转由重试条/再次滚动的 onLoadMore 重试;
  /// 其余情形与 onSeek 同路(共用 _ensureVisibleLoaded 去重守卫)。
  void _onSkeletonHit(int displayIndex) {
    if (_loadMoreFailed) return;
    _ensureVisibleLoaded(displayIndex);
  }

  String get _where => widget.where ?? widget.folderName;

  /// 升降序切换(快速滚动批 F3):_sortDesc 翻转即 _window.descending 同步
  /// 翻转(派生 getter),骨架区随之尾↔头;滚动位置允许跳动,不做动画。
  void _toggleSort() => setState(() {
    _sortDesc = !_sortDesc;
    final sorted = sortAssetsByCreatedAt(_items, desc: _sortDesc);
    _items
      ..clear()
      ..addAll(sorted);
  });
  Future<void> _openUploadSheet() =>
      showUploadSheet(context, folderId: widget.folderId, where: _where);
  List<Asset> get _picked =>
      _items.where((a) => _selection.selected.contains(a.id)).toList();

  void _clearSelected() => setState(_selection.clear);

  /// 打开预览(快速滚动批 F3):入参为宫格显示序,ASC 时已加载区在显示序
  /// [total-loaded, total),换算回 _items 序再进预览(点谁开谁,现状语义)。
  void _open(int displayIndex) {
    var i = displayIndex;
    if (!_sortDesc) {
      i = displayIndex - (_total - _items.length);
      if (i < 0 || i >= _items.length) return;
    }
    if (i < 0 || i >= _items.length) return;
    openAssetPreview(context, _items, i, widget.folderId, _canDownload, _where);
  }

  /// 批量动作编排(下载/分享/移动/删除/打标/前缀/申请权限)。
  AssetBatchActions get _actions => AssetBatchActions(
    context: context,
    folderId: widget.folderId,
    where: _where,
    whereLabel: widget.where?.split('/').first,
    detail: _detail,
    canDownload: _canDownload,
    picked: _picked,
    selectedIds: _selection.selected.toList(),
    onCleared: _clearSelected,
    onPrefixSettled: (remaining) =>
        setState(() => _selection.settlePrefix(remaining)),
  );
  @override
  Widget build(BuildContext context) {
    final showFab = !_selection.selecting && _canUpload != false;
    final actions = _actions;
    return Scaffold(
      floatingActionButton: showFab
          ? AssetsUploadFab(onPressed: _openUploadSheet)
          : null,
      bottomNavigationBar: _selection.selecting
          ? AssetSelectionBar(
              count: _selection.count,
              canDownload: _canDownload,
              allSelected:
                  _items.isNotEmpty &&
                  _selection.selected.length >= _items.length,
              onToggleAll: () => setState(() => _selection.toggleAll(_items)),
              onDownload: actions.download,
              onShare: actions.share,
              onMove: actions.move,
              onDelete: actions.delete,
              onBatchTag: actions.batchTag,
              onBatchPrefix: actions.batchPrefix,
              onRequest: actions.requestAccess,
              onClear: _clearSelected,
            )
          : null,
      body: Column(
        children: [
          AssetsHeader(
            title: _selection.selecting
                ? '已选 ${_selection.count}'
                : widget.folderName,
            subtitle: '$_where · $_total 个素材',
            selecting: _selection.selecting,
            onToggleSelect: () => setState(_selection.toggleMode),
            total: _total,
            sortDesc: _sortDesc,
            onToggleSort: _toggleSort,
            projectLabel: (widget.where?.contains('/') ?? false)
                ? widget.where!.split('/').first
                : null,
            folderName: widget.folderName,
            onProjectTap: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Stack(
              children: [
                AssetsBody(
                  loading: _loading,
                  error: _error,
                  items: _items,
                  total: _total,
                  descending: _sortDesc,
                  selectedIds: _selection.selected,
                  selecting: _selection.selecting,
                  loadingMore: _loadingMore,
                  loadMoreFailed: _loadMoreFailed,
                  canUpload: _canUpload,
                  hasFab: showFab,
                  onRefresh: _refresh,
                  onRetry: _refresh,
                  onToggle: (a) => setState(() => _selection.toggle(a)),
                  onOpen: _open,
                  onLoadMore: () => _ensureVisibleLoaded(_loadedDisplayEnd),
                  // 滚动条释放定位与骨架命中补齐共用同一入口(内部去重防风暴)
                  onSeek: _ensureVisibleLoaded,
                  onEnsureVisible: _onSkeletonHit,
                  onUploadTap: _openUploadSheet,
                ),
                if (!_selection.selecting)
                  UploadPillOverlay(
                    bottom:
                        MediaQuery.viewPaddingOf(context).bottom +
                        (showFab ? 80 : Tk.spaceLg),
                    queue: widget.transferQueue,
                    onTap: () => openTransfersView(context),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
