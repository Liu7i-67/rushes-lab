/// 资产宫格页(B2 §8.1):3 列缩略图(缓存+降级色块)、点按=预览、长按=多选
/// (选择态本批:打勾+底部计数条,批量操作 B4/B5 点亮);进页拉单夹详情取
/// my_can_download(列表响应恒 False,§11 钉子);上传成功后失效列表+子树计数。
library;

import 'package:flutter/material.dart';

import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../services/album.dart';
import '../../services/app_log.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import '../preview/preview_page.dart';
import 'asset_actions.dart';
import 'asset_tile.dart';

class AssetsPage extends StatefulWidget {
  const AssetsPage({
    super.key,
    required this.folderId,
    required this.folderName,
  });

  final String folderId;
  final String folderName;

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

  /// 单夹详情回填;三态(B2 修复 P2-4):true/false=详情可信值,
  /// null=详情未到/拉取失败(≠无权限)——下载钮提示退回中性「后续版本」,
  /// 不误显「可申请」。后端仍最终裁决。
  bool? _canDownload;

  /// 上传入口显隐(§13 上传入口 my_can_upload);null=详情未到/失败,保持现役
  /// 显示口径(B1 上传链路不回归,已知 false 才隐藏)。
  bool? _canUpload;

  late AssetActions _actions;

  @override
  void initState() {
    super.initState();
    _actions = AssetActions(folderId: widget.folderId, say: _say);
    _refresh();
  }

  void _say(String msg) {
    AppLog.info('assets', msg);
    if (!mounted) return;
    setState(() {
      _log.insert(0, msg);
      if (_log.length > 3) _log.removeRange(3, _log.length);
    });
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // P2-10:列表与单夹详情并行拉取;详情失败独立兜底为 null(三态未知),
      // 不拖累列表渲染,列表失败仍走整页错误(P2-4:null≠false 勿混)。
      final results = await Future.wait<Object?>([
        session.api!.assets.list(widget.folderId, limit: _pageSize),
        session.api!.folders
            .get(widget.folderId)
            .then<Folder?>((f) => f)
            .catchError((_) => null), // 详情失败 → null(未知),非 false
      ]);
      final page = results[0] as AssetPage;
      final detail = results[1] as Folder?;
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _total = page.total.toInt();
        // my_can_* 唯一可信回填点=单夹详情(web useFolder 同源,列表恒 False 勿消费)
        _canDownload = detail?.myCanDownload;
        _canUpload = detail?.myCanUpload;
        _selected.clear();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
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

  Future<void> _upload() async {
    if (await _actions.upload(context)) {
      RefreshBus.I.invalidate('assets:${widget.folderId}');
      RefreshBus.I.invalidate('folders'); // 子树计数变化
      await _refresh();
    }
  }

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
      appBar: AppBar(title: Text(widget.folderName)),
      // 上传入口 my_can_upload 显隐(§13):已知无权才隐藏;详情未到保持显示
      floatingActionButton: _canUpload == false
          ? null
          : FloatingActionButton.extended(
              onPressed: _upload,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: Text(AlbumService.isSupported ? '上传实况' : '上传 livp'),
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
      return const EmptyState(icon: Icons.image_outlined, message: '空文件夹');
    }
    final hasMore = _items.length < _total;
    return Column(
      children: [
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
