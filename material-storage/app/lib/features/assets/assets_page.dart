/// 资产宫格页(B2 §8.1):3 列缩略图、点按=预览、长按=多选;B4 功能点 4②:
/// 多选底部操作栏亮「下载」键(批量逐文件入队,>20 确认弹窗,其余键 B5);
/// 进页拉单夹详情取 my_can_download / my_can_upload(列表响应恒 False,§11);
/// 上传入口唯一(「⬆」+空态引导),RefreshBus 订阅 + 顶部迷你进度条。
library;

import 'package:flutter/material.dart';

import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../core/transfers/transfer_queue.dart';
import '../../models/models.dart';
import '../../services/app_log.dart';
import '../../widgets/error_view.dart';
import '../preview/preview_page.dart';
import 'asset_selection_bar.dart';
import 'asset_tile.dart';
import 'upload_pick.dart' show showUploadSheet;
import 'upload_sheet.dart';

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
  final _log = <String>[];
  var _total = 0;
  var _loading = true;
  var _loadingMore = false;
  String? _error;

  /// 刷新代际(P2-2):响应落地时对不上最新代际则丢弃,防慢响应覆盖新数据。
  var _fetchEpoch = 0;

  /// 单夹详情回填;三态(P2-4):bool=详情可信值,null=详情未到/失败(≠无权限)。
  bool? _canDownload;

  /// 上传入口显隐(§13);null=详情未到/失败,保持现役显示口径。
  bool? _canUpload;

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

  void _say(String msg) {
    AppLog.info('assets', msg);
    if (!mounted) return;
    setState(() => _log.insert(0, msg));
    if (_log.length > 3) _log.removeRange(3, _log.length);
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
  }

  /// 全屏刷新(首拉/下拉/ErrorView 重试):整页 spinner,失败走整页错误。
  Future<void> _refresh() async {
    final epoch = ++_fetchEpoch;
    setState(() {
      _loading = true;
      _error = null;
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
        _error = '$e';
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
        _error = null;
        _loading = false;
      });
    } catch (e) {
      AppLog.error('assets', '静默刷新失败,保留旧列表', e);
      if (fresh()) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _items.length >= _total) return;
    setState(() => _loadingMore = true);
    try {
      final page = await session.api!.assets.list(widget.folderId,
          limit: _pageSize, offset: _items.length);
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items);
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      _say('加载更多失败:$e');
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

  @override
  Widget build(BuildContext context) {
    final selecting = _selected.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.folderName),
        // 上传入口唯一(AppBar「⬆」,§5):已知无权才隐藏,详情未到保持显示
        actions: [
          if (_canUpload != false)
            IconButton(
                onPressed: _openUploadSheet,
                icon: const Icon(Icons.upload_outlined),
                tooltip: '上传'),
        ],
      ),
      bottomNavigationBar: selecting
          ? AssetSelectionBar(
              count: _selected.length,
              canDownload: _canDownload,
              onDownload: _downloadSelected,
              onClear: () => setState(() => _selected.clear()))
          : null,
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return ErrorView(message: _error!, onRetry: _refresh);
    }
    if (_items.isEmpty) {
      // 空态引导=上传第二入口(§5);my_can_upload 已知 false 时只留文案
      return Column(
        children: [
          UploadMiniBar(queue: widget.transferQueue),
          Expanded(
              child: UploadEmptyGuide(
                  enabled: _canUpload != false, onTap: _openUploadSheet)),
        ],
      );
    }
    final hasMore = _items.length < _total;
    return Column(
      children: [
        UploadMiniBar(queue: widget.transferQueue),
        if (_log.isNotEmpty)
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: Text(_log.first,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 0.72,
              ),
              itemCount: _items.length + (hasMore ? 1 : 0),
              itemBuilder: (context, i) {
                if (i >= _items.length) {
                  return _loadMoreTile();
                }
                final a = _items[i];
                final selected = _selected.contains(a.id);
                return AssetGridTile(
                  asset: a,
                  selected: selected,
                  selecting: _selected.isNotEmpty,
                  onTap: _selected.isNotEmpty ? () => _toggle(a) : () => _openPreview(i),
                  onLongPress: () {
                    if (!selected) _toggle(a); // 长按=进入多选
                  },
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _loadMoreTile() => InkWell(
        onTap: _loadMore,
        child: Center(
          child: _loadingMore
              ? const Center(
                  child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2)))
              : Text('加载更多(${_items.length}/$_total)'),
        ),
      );
}
