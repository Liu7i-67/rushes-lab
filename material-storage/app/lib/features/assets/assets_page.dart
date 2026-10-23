/// 资产宫格页(F8):3 列缩略图、点按=预览、长按/「选择」=多选。
/// 页面只保留状态与编排(页头/网格/操作栏/上传胶囊各自拆件);
/// 保留 RefreshBus 订阅、静默刷新代际、分页自动加载、my_can_* 与上传闸门。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart' show errorMessage;
import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../core/transfers/transfer_queue.dart';
import '../../models/models.dart';
import '../../services/app_log.dart';
import '../../theme/tokens.dart';
import '../../widgets/toast.dart';
import 'asset_selection_bar.dart';
import 'assets_body.dart';
import 'assets_header.dart';
import 'selection_actions.dart';
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

  /// 滚动到底自动加载;失败 toast + 置失败标记(底部重试条)。
  Future<void> _loadMore() async {
    if (_loadingMore || _items.length >= _total) return;
    setState(() {
      _loadingMore = true;
      _loadMoreFailed = false;
    });
    try {
      final page = await session.api!.assets.list(
        widget.folderId,
        limit: _pageSize,
        offset: _items.length,
      );
      if (!mounted) return;
      setState(() {
        final merged = [..._items, ...page.items];
        _items
          ..clear()
          ..addAll(sortAssetsByCreatedAt(merged, desc: _sortDesc));
        _loadingMore = false;
      });
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

  String get _where => widget.where ?? widget.folderName;
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
  void _open(int i) => openAssetPreview(
    context,
    _items,
    i,
    widget.folderId,
    _canDownload,
    _where,
  );

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
                  onLoadMore: _loadMore,
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
