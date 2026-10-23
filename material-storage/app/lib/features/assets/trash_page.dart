/// 回收站页(B5 功能点 2,对标 web FolderTrashModal 移动版;仅恢复):
/// GET /assets/trash + POST /assets/{id}/restore;分页=滚到底自动加载。
/// 入口显隐三态(web ProjectDetailPage canSeeTrash 实码对齐):
/// 普通夹 = my_can_admin 或 my_delete_grant;sensitive 夹仅系统 admin。
/// 视觉迁移:PageHeader(17 标题 + 返回)+ 卡片行(AppCard/AppRow)。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart' show errorMessage;
import '../../core/fmt.dart';
import '../../core/preview_kind.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../services/app_log.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_row.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import '../../widgets/page_header.dart';
import '../../widgets/toast.dart';
import 'asset_writeback.dart';

/// 入口闸门(web canSeeTrash 实码同式:canDeleteFiles && (!is_sensitive || admin))。
/// 纯函数可单测;参数三态:my_can_*/my_delete_grant 详情未到=null(视为 false)。
bool canSeeTrash({
  required bool? myCanAdmin,
  required bool? myDeleteGrant,
  required bool isSensitive,
  required bool isSystemAdmin,
}) {
  final canDeleteFiles = (myCanAdmin ?? false) || (myDeleteGrant ?? false);
  return canDeleteFiles && (!isSensitive || isSystemAdmin);
}

/// 距底部不足该像素即触发自动加载。
const _loadMoreThreshold = 200.0;

/// 音频扩展名(preview_kind 八类判定不含音频,就地补判)。
const _kAudioExts = <String>['.mp3', '.wav', '.m4a', '.aac', '.flac', '.ogg'];

/// 回收站行首图标按资产类型分型(kind 判定走 detectKind 钉子)。
@visibleForTesting
IconData trashKindIcon({required String filename, String? contentType}) {
  final name = filename.toLowerCase();
  if ((contentType ?? '').toLowerCase().startsWith('audio/') ||
      _kAudioExts.any(name.endsWith)) {
    return Icons.graphic_eq;
  }
  return switch (detectKind(filename: filename, contentType: contentType)) {
    PreviewKind.image || PreviewKind.heic => Icons.image_outlined,
    PreviewKind.video => Icons.videocam_outlined,
    PreviewKind.livp => Icons.photo_camera_outlined,
    PreviewKind.pdf ||
    PreviewKind.markdown ||
    PreviewKind.text => Icons.description_outlined,
    PreviewKind.unsupported => Icons.insert_drive_file_outlined,
  };
}

class TrashPage extends StatefulWidget {
  const TrashPage({
    super.key,
    required this.folderId,
    required this.folderName,
  });

  final String folderId;
  final String folderName;

  @override
  State<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<TrashPage> {
  static const _pageSize = 500; // 后端单窗口上限

  final _items = <Asset>[];
  final _scroll = ScrollController();
  var _total = 0;
  var _loading = true;
  var _loadingMore = false;
  var _loadMoreFailed = false;
  var _restoringId = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
    _refresh();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.extentAfter < _loadMoreThreshold) {
      _loadMore();
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
      _loadMoreFailed = false;
    });
    try {
      final page = await session.api!.ops.listTrash(
        widget.folderId,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _total = page.total.toInt();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = errorMessage(e, '回收站加载失败,请下拉重试');
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _items.length >= _total) return;
    setState(() {
      _loadingMore = true;
      _loadMoreFailed = false;
    });
    try {
      final page = await session.api!.ops.listTrash(
        widget.folderId,
        limit: _pageSize,
        offset: _items.length,
      );
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items);
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _loadMoreFailed = true;
      });
      toast(context, errorMessage(e, '加载失败,请重试'), tone: ToastTone.error);
    }
  }

  Future<void> _restore(Asset a) async {
    setState(() => _restoringId = a.id);
    try {
      await session.api!.ops.restore(a.id);
      AppLog.info('trash', '已恢复:${a.filename} → ${widget.folderName}');
      if (!mounted) return;
      setState(() {
        _items.removeWhere((x) => x.id == a.id);
        _total = (_total - 1).clamp(0, 1 << 31);
        _restoringId = '';
      });
      notifyAssetMutation(widget.folderId); // 列表计数恢复 → 宫格+folders 刷新
      toast(
        context,
        '「${a.filename}」已恢复至 ${widget.folderName}',
        tone: ToastTone.success,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _restoringId = '');
      toast(context, errorMessage(e, '恢复失败,请稍后重试'), tone: ToastTone.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          PageHeader(
            back: true,
            title: '回收站 · ${widget.folderName}',
            subtitle: _total > 0 ? '共 $_total 个已删除文件' : null,
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? ErrorView(message: _error!, onRetry: _refresh)
                : _items.isEmpty
                ? const EmptyState(
                    icon: Icons.delete_outline,
                    message: '回收站是空的',
                    description: '删除的素材会暂存在这里,可随时恢复。',
                  )
                : _list(context),
          ),
        ],
      ),
    );
  }

  Widget _list(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.separated(
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(
                Tk.spacePage,
                Tk.spaceMd,
                Tk.spacePage,
                Tk.spaceXl,
              ),
              itemCount: _items.length,
              separatorBuilder: (_, _) => const SizedBox(height: Tk.spaceSm),
              itemBuilder: (context, i) {
                final a = _items[i];
                return AppCard(
                  padding: EdgeInsets.zero,
                  child: AppRow(
                    leading: Icon(
                      trashKindIcon(
                        filename: a.filename,
                        contentType: a.contentType,
                      ),
                    ),
                    title: a.filename,
                    subtitle:
                        '${fmtBytes(a.sizeBytes)} · 删除于 ${a.deletedAt == null ? '—' : fmtDate(a.deletedAt!)}',
                    showChevron: false,
                    trailing: _restoringId == a.id
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : IconButton(
                            icon: const Icon(Icons.restore_outlined),
                            tooltip: '恢复到文件夹',
                            onPressed: () => _restore(a),
                          ),
                  ),
                );
              },
            ),
          ),
        ),
        if (_loadingMore) const LinearProgressIndicator(minHeight: 2),
        if (_loadMoreFailed && !_loadingMore) _retryBar(context),
      ],
    );
  }

  Widget _retryBar(BuildContext context) {
    final color = context.tk.danger;
    return InkWell(
      onTap: _loadMore,
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
