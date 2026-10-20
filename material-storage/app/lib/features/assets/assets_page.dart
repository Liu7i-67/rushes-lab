/// 资产宫格页(B2 §8.1):3 列缩略图(缓存+降级色块)、点按=预览、长按=多选
/// (选择态本批:打勾+底部计数条,批量操作 B4/B5 点亮);进页拉单夹详情取
/// my_can_download / my_can_upload(列表响应恒 False,§11 钉子)。
/// B3:上传入口唯一化(AppBar「⬆」+空态引导 → 统一上传面板 upload_sheet),
/// 挂 RefreshBus `assets:<folderId>` 订阅(上传成功自动刷新,B2 预留落地),
/// 顶部迷你进度条显示活动上传 n/m(§5)。
library;

import 'package:flutter/material.dart';

import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../core/transfers/transfer_queue.dart';
import '../../models/models.dart';
import '../../services/app_log.dart';
import '../../widgets/error_view.dart';
import '../preview/preview_page.dart';
import 'asset_tile.dart';
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

  /// 上传任务归属显示路径(项目/文件夹;路由未传时退回宫格名)。
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

  /// 刷新代际(P2-2):全屏/静默两路刷新共用,响应落地时对不上最新代际
  /// (期间又发起了更新的刷新)则丢弃旧结果,防慢响应回写覆盖新数据。
  var _fetchEpoch = 0;

  /// 单夹详情回填;三态(B2 修复 P2-4):true/false=详情可信值,
  /// null=详情未到/拉取失败(≠无权限)——下载钮提示退回中性「后续版本」,
  /// 不误显「可申请」。后端仍最终裁决。
  bool? _canDownload;

  /// 上传入口显隐(§13 上传入口 my_can_upload);null=详情未到/失败,保持现役
  /// 显示口径(B1 上传链路不回归,已知 false 才隐藏)。
  bool? _canUpload;

  @override
  void initState() {
    super.initState();
    // 数据新鲜度(B3 功能点 6):上传 complete 成功 → upload_sheet 失效
    // assets:<folderId> → 本页自动重拉(B2 预留订阅落地,IndexedStack 外的
    // 常驻上下文也能靠返回+失效保持新鲜)。
    RefreshBus.I.addListener('assets:${widget.folderId}', _onInvalidated);
    _refresh();
  }

  @override
  void dispose() {
    RefreshBus.I.removeListener('assets:${widget.folderId}', _onInvalidated);
    super.dispose();
  }

  void _onInvalidated() {
    // P2-2:失效驱动路径(上传成功等)改静默刷新——保留旧列表后台重拉后
    // 整体 swap,不整页 spinner 打断浏览
    AppLog.info('assets', 'assets:${widget.folderId} 失效 → 宫格静默刷新');
    _silentRefresh();
  }

  void _say(String msg) {
    AppLog.info('assets', msg);
    if (!mounted) return;
    setState(() {
      _log.insert(0, msg);
      if (_log.length > 3) _log.removeRange(3, _log.length);
    });
  }

  /// 并行拉取列表+单夹详情(P2-10);详情失败独立兜底 null(三态未知,
  /// ≠false 勿混),不拖累列表渲染。
  Future<(AssetPage, Folder?)> _fetchPage() async {
    final results = await Future.wait<Object?>([
      session.api!.assets.list(widget.folderId, limit: _pageSize),
      session.api!.folders
          .get(widget.folderId)
          .then<Folder?>((f) => f)
          .catchError((_) => null), // 详情失败 → null(未知),非 false
    ]);
    return (results[0] as AssetPage, results[1] as Folder?);
  }

  /// 回填列表与详情(my_can_* 唯一可信回填点=单夹详情,web useFolder 同源,
  /// 列表恒 False 勿消费)。只改字段,调用方负责 setState。
  void _applyPage(AssetPage page, Folder? detail) {
    _items
      ..clear()
      ..addAll(page.items);
    _total = page.total.toInt();
    _canDownload = detail?.myCanDownload;
    _canUpload = detail?.myCanUpload;
  }

  /// 全屏刷新(首拉/下拉/ErrorView 重试,下拉保留全屏 loading 口径):
  /// 整页 spinner,失败走整页错误;清选中态。
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

  /// 静默刷新(P2-2):RefreshBus 失效驱动路径专用——旧列表原地保留后台重拉,
  /// 成功后整体 swap 并清错误;失败仅记日志(旧列表仍在,等下次失效/下拉再试),
  /// 不清选中态(用户多选中收到失效不应被打断)。
  Future<void> _silentRefresh() async {
    final epoch = ++_fetchEpoch;
    try {
      final (page, detail) = await _fetchPage();
      if (!mounted || epoch != _fetchEpoch) return;
      setState(() {
        _applyPage(page, detail);
        _error = null;
      });
    } catch (e) {
      AppLog.error('assets', '静默刷新失败,保留旧列表', e);
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

  /// 统一上传面板(入口唯一:B3 功能点 1)。入队即返回;列表刷新由
  /// RefreshBus 失效驱动(worker 成功回调),不再同步等待上传结果。
  Future<void> _openUploadSheet() =>
      showUploadSheet(context,
          folderId: widget.folderId, where: widget.where ?? widget.folderName);

  void _openPreview(int index) {
    Navigator.of(context).pushNamed(
      '/preview',
      arguments: PreviewArgs(
        items: List.of(_items),
        index: index,
        folderId: widget.folderId,
        canDownload: _canDownload,
      ),
    );
  }

  void _toggle(Asset a) =>
      setState(() => _selected.contains(a.id) ? _selected.remove(a.id) : _selected.add(a.id));

  @override
  Widget build(BuildContext context) {
    final selecting = _selected.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.folderName),
        // 上传入口唯一(AppBar「⬆」,§5);my_can_upload 显隐沿用 §13:
        // 已知无权才隐藏,详情未到保持显示
        actions: [
          if (_canUpload != false)
            IconButton(
              onPressed: _openUploadSheet,
              icon: const Icon(Icons.upload_outlined),
              tooltip: '上传',
            ),
        ],
      ),
      bottomNavigationBar: selecting ? _selectionBar(context) : null,
      body: _body(context),
    );
  }

  Widget _selectionBar(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            const SizedBox(width: 16),
            Text('已选 ${_selected.length} 项'),
            const Spacer(),
            const Text(
              '批量操作后续版本开放',
              style: TextStyle(fontSize: 12),
            ),
            TextButton(
              onPressed: () => setState(() => _selected.clear()),
              child: const Text('清空'),
            ),
          ],
        ),
      ),
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
              enabled: _canUpload != false,
              onTap: _openUploadSheet,
            ),
          ),
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
            child: Text(
              _log.first,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
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
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text('加载更多(${_items.length}/$_total)'),
        ),
      );
}
