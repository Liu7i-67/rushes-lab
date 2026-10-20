/// 资产宫格页(现役平移):列表 + 上传/下载(动作在 asset_actions.dart,
/// 行渲染在 asset_tile.dart)。多选/批量操作按 §16 B5 批交付。
library;

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../models/models.dart';
import '../../services/album.dart';
import '../../services/app_log.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
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
  late Future<AssetPage> _future;
  late AssetActions _actions;
  final _log = <String>[];

  @override
  void initState() {
    super.initState();
    _actions = AssetActions(folderId: widget.folderId, say: _say);
    _future = session.api!.assets.list(widget.folderId);
  }

  void _reload() =>
      setState(() => _future = session.api!.assets.list(widget.folderId));

  void _say(String msg) {
    // 界面浮层 + 全量日志双写(推送企业微信走 AppLog)
    AppLog.info('assets', msg);
    if (!mounted) return;
    setState(() => _log.insert(0, msg));
    if (_log.length > 6) _log.removeRange(6, _log.length);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.folderName)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          if (await _actions.upload(context)) _reload();
        },
        icon: const Icon(Icons.add_photo_alternate_outlined),
        label: Text(AlbumService.isSupported ? '上传实况' : '上传 livp'),
      ),
      body: Column(
        children: [
          if (_log.isNotEmpty)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final l in _log.take(3))
                    Text(
                      l,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          Expanded(
            child: FutureBuilder<AssetPage>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return ErrorView(message: '${snap.error}', onRetry: _reload);
                }
                final items = snap.data?.items ?? const [];
                if (items.isEmpty) {
                  return const EmptyState(
                    icon: Icons.image_outlined,
                    message: '空文件夹',
                  );
                }
                return RefreshIndicator(
                  onRefresh: () async => _reload(),
                  child: ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final a = items[i];
                      return AssetTile(
                        asset: a,
                        onDownload: () => _actions.download(a),
                        onSaveToAlbum: AlbumService.isSupported
                            ? () => _actions.downloadToAlbum(a)
                            : null,
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
