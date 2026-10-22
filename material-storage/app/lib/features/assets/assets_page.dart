/// 资产宫格页(B2 §8.1):3 列缩略图、点按=预览、长按=多选;app-polish 重做:
/// B5 上传入口改右下 FloatingActionButton.extended(AppBar 图标移除,多选态
/// 让位底部操作栏);B1 多选栏全量点亮+全选/✕ 退出;B4 开发日志横条移除
/// (调试信息只入 AppLog);B3 到底自动加载+失败 toast 重试;进页拉单夹详情
/// 取 my_can_* + projectId(列表响应恒 False,§11);RefreshBus 订阅+迷你进度条。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart' show errorMessage;
import '../../core/haptics.dart';
import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../core/transfers/transfer_queue.dart';
import '../../models/models.dart';
import '../../services/app_log.dart';
import '../../widgets/toast.dart';
import '../preview/preview_page.dart';
import 'asset_selection_bar.dart';
import 'assets_body.dart';
import 'selection_actions.dart';
import 'upload_pick.dart' show showUploadSheet;

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

  /// 传输队列(迷你条数据源);测试注入用,默认全局单例。
  final TransferQueue? transferQueue;

  @override
  State<AssetsPage> createState() => _AssetsPageState();
}

class _AssetsPageState extends State<AssetsPage> {
  static const _pageSize = 200;

  final _items = <Asset>[];
  final _selected = <String>{};
  var _total = 0;
  var _loading = true;
  var _loadingMore = false;

  /// B3:上次加载更多失败(宫格底部显示点击重试条;toast 同步提示)。
  var _loadMoreFailed = false;
  String? _error;

  /// 刷新代际(P2-2):响应落地时对不上最新代际则丢弃,防慢响应覆盖新数据。
  var _fetchEpoch = 0;

  /// 单夹详情回填;三态(P2-4):bool=详情可信值,null=详情未到/失败(≠无权限)。
  bool? _canDownload;

  /// 上传入口显隐(§13);null=详情未到/失败,保持现役显示口径。
  bool? _canUpload;

  /// 单夹详情原对象(B5:projectId→批量移动目标树数据源;trash/移动闸门口径)。
  Folder? _detail;

  @override
  void initState() {
    super.initState();
    // 数据新鲜度(B3 功能点 6):上传成功 → 失效 assets:<folderId> → 自动重拉
    RefreshBus.I.addListener('assets:${widget.folderId}', _onInvalidated);
    _refresh();
  }

  @override
  void dispose() {
    RefreshBus.I.removeListener('assets:${widget.folderId}', _onInvalidated);
    super.dispose();
  }

  /// P2-2:失效驱动路径改静默刷新——旧列表保留后台重拉后 swap,不打断浏览。
  void _onInvalidated() {
    AppLog.info('assets', 'assets:${widget.folderId} 失效 → 宫格静默刷新');
    _silentRefresh();
  }

  /// 并行拉列表+单夹详情(P2-10);详情失败独立兜底 null(未知≠false 勿混)。
  Future<(AssetPage, Folder?)> _fetchPage() async {
    final results = await Future.wait<Object?>([
      session.api!.assets.list(widget.folderId, limit: _pageSize),
      session.api!.folders.get(widget.folderId).then<Folder?>((f) => f).catchError((_) => null),
    ]);
    return (results[0] as AssetPage, results[1] as Folder?);
  }

  /// 回填列表与详情(my_can_* 唯一可信回填点=单夹详情,列表恒 False 勿消费)。
  void _applyPage(AssetPage page, Folder? detail) {
    _items..clear()..addAll(page.items);
    _total = page.total.toInt();
    _canDownload = detail?.myCanDownload;
    _canUpload = detail?.myCanUpload;
    _detail = detail;
  }

  /// 全屏刷新(首拉/下拉/ErrorView 重试):整页骨架,失败走整页错误。
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
        _selected.clear();
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

  /// 静默刷新(P2-2):旧列表保留后台重拉成功 swap;B3 修复:出口均以「本路
  /// 仍最新代际」为界清 _loading(全屏在途被丢弃时全屏路不会回来清,否则卡死)。
  Future<void> _silentRefresh() async {
    final epoch = ++_fetchEpoch;
    bool fresh() => mounted && epoch == _fetchEpoch;
    try {
      final (page, detail) = await _fetchPage();
      if (!fresh()) return;
      setState(() {
        _applyPage(page, detail);
        // P2-3:他端删除的资产不在新页,剪掉失效选中 id(操作栏计数与实际一致;
        // 全屏 _refresh 已整清选中,此处只管 silent swap 路径)
        final liveIds = {for (final a in page.items) a.id};
        _selected.removeWhere((id) => !liveIds.contains(id));
        _error = null;
        _loading = false;
      });
    } catch (e) {
      AppLog.error('assets', '静默刷新失败,保留旧列表', e);
      if (fresh()) setState(() => _loading = false);
    }
  }

  /// B3:滚动到底自动加载;失败 toast+置失败标记(底部重试条,重新滑动亦可)。
  Future<void> _loadMore() async {
    if (_loadingMore || _items.length >= _total) return;
    setState(() {
      _loadingMore = true;
      _loadMoreFailed = false;
    });
    try {
      final page = await session.api!.assets.list(widget.folderId,
          limit: _pageSize, offset: _items.length);
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items);
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

  /// 统一上传面板(入口唯一:B3 功能点 1);入队即返回,刷新由 RefreshBus 驱动。
  Future<void> _openUploadSheet() => showUploadSheet(context,
      folderId: widget.folderId, where: widget.where ?? widget.folderName);

  /// 批量下载(功能点 4②):>20 确认、逐文件入队;入队成功即清选中态。
  Future<void> _downloadSelected() async {
    final picked = _items.where((a) => _selected.contains(a.id)).toList();
    final r = await downloadSelectedAssets(context,
        assets: picked,
        canDownload: _canDownload,
        where: widget.where ?? widget.folderName);
    if (r != null && mounted) setState(() => _selected.clear());
  }

  // ── B5 功能点 1:操作栏全量回调(编排拆件见 selection_actions.dart)────────
  List<Asset> get _picked =>
      _items.where((a) => _selected.contains(a.id)).toList();

  Future<void> _shareSelected() async {
    await shareSingleAsset(context, _picked);
  }

  Future<void> _moveSelected() async {
    final moved = await moveSelectedAssets(context,
        selectedIds: _selected.toList(),
        sourceFolderId: widget.folderId,
        detail: _detail,
        whereLabel: widget.where?.split('/').first,
        // D5:跳过行显示文件名(id→文件名映射由本页选中资产给出)
        assetNames: {for (final a in _picked) a.id: a.filename});
    if (moved && mounted) setState(() => _selected.clear());
  }

  Future<void> _deleteSelected() async {
    if (await deleteSelected(context,
        picked: _picked, folderId: widget.folderId)) {
      if (mounted) setState(() => _selected.clear());
    }
  }

  Future<void> _batchTag() async {
    if (await batchTagSelected(context,
        selectedIds: _selected.toList(), folderId: widget.folderId)) {
      if (mounted) setState(() => _selected.clear());
    }
  }

  void _batchPrefix() {
    batchPrefixSelected(context,
        picked: _picked,
        selectedIds: _selected.toList(),
        folderId: widget.folderId, onSettle: (remaining) {
      if (!mounted) return;
      setState(() => _selected..clear()..addAll(remaining));
    });
  }

  Future<void> _requestAccess() async {
    await requestAccessSingle(context, _picked);
  }

  void _openPreview(int index) {
    Navigator.of(context).pushNamed('/preview',
        arguments: PreviewArgs(
            items: List.of(_items),
            index: index,
            folderId: widget.folderId,
            canDownload: _canDownload,
            where: widget.where ?? widget.folderName));
  }

  void _toggle(Asset a) =>
      setState(() => _selected.contains(a.id) ? _selected.remove(a.id) : _selected.add(a.id));

  /// B1:全选/取消全选切换——未勾满→勾满已加载条目;已勾满→清空并退出多选。
  void _toggleAll() => setState(() {
        if (_items.isNotEmpty && _selected.length >= _items.length) {
          _selected.clear();
        } else {
          _selected
            ..clear()
            ..addAll([for (final a in _items) a.id]);
        }
      });

  @override
  Widget build(BuildContext context) {
    final selecting = _selected.isNotEmpty;
    final showFab = !selecting && _canUpload != false;
    return Scaffold(
      appBar: AppBar(title: Text(widget.folderName)),
      // B5:上传入口唯一改 FAB(原 AppBar「⬆」移除);已知无权隐藏(详情未到
      // 保持现役显示口径),多选态让位底部操作栏。
      floatingActionButton: showFab
          ? FloatingActionButton.extended(
              tooltip: '上传',
              onPressed: _openUploadSheet,
              icon: const Icon(Icons.upload_outlined),
              label: const Text('上传'),
            )
          : null,
      bottomNavigationBar: selecting
          ? AssetSelectionBar(
              count: _selected.length,
              canDownload: _canDownload,
              allSelected: _items.isNotEmpty && _selected.length >= _items.length,
              onToggleAll: _toggleAll,
              onDownload: () {
                Haptics.light();
                _downloadSelected();
              },
              onShare: _shareSelected,
              onMove: _moveSelected,
              onDelete: _deleteSelected,
              onBatchTag: _batchTag,
              onBatchPrefix: _batchPrefix,
              onRequest: _requestAccess,
              onClear: () => setState(() => _selected.clear()))
          : null,
      body: _body(context, showFab: showFab),
    );
  }

  Widget _body(BuildContext context, {required bool showFab}) => AssetsBody(
        loading: _loading,
        error: _error,
        items: _items,
        total: _total,
        selectedIds: _selected,
        loadingMore: _loadingMore,
        loadMoreFailed: _loadMoreFailed,
        canUpload: _canUpload,
        hasFab: showFab,
        transferQueue: widget.transferQueue,
        onRefresh: _refresh,
        onRetry: _refresh,
        onToggle: _toggle,
        onOpen: _openPreview,
        onLoadMore: _loadMore,
        onUploadTap: _openUploadSheet,
      );
}
