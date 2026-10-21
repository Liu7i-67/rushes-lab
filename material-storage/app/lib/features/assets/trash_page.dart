/// 回收站页(B5 功能点 2,对标 web FolderTrashModal 移动版;仅恢复,彻底删除
/// 留待后续批):GET /assets/trash(参数=实码 folder_id/limit≤500/offset)+
/// POST /assets/{id}/restore;分页=加载更多窗口(total 独立返回)。
/// 入口显隐三态(web ProjectDetailPage canSeeTrash 实码对齐):
/// 普通夹 = my_can_admin 或 my_delete_grant(组级删除授权);sensitive 夹仅系统
/// admin(回收站不得成为项目 admin 窥探敏感文件名的侧信道)。
/// app-polish E10 精修:行首图标按资产 kind 分型(原一律 description_outlined);
/// 恢复 toast 带目标夹名;「加载更多」按钮分页改滚到底自动加载(B3 assets_body
/// 同款:extentAfter<200 触发+底部线性指示+失败 toast/重试条)。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart' show errorMessage;
import '../../core/fmt.dart';
import '../../core/preview_kind.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../services/app_log.dart';
import '../../theme/tokens.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
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

/// B3 同款(assets_body):距底部不足该像素即触发自动加载。
const _loadMoreThreshold = 200.0;

/// 音频扩展名(E10 分型图标;preview_kind 八类判定不含音频,就地补判)。
const _kAudioExts = <String>['.mp3', '.wav', '.m4a', '.aac', '.flac', '.ogg'];

/// E10:回收站行首图标按资产类型分型(原一律 description_outlined)。
/// kind 判定走 detectKind(preview_kind 钉子:endswith 判扩展名,勿改「取末段
/// 比较」写法);音频在其白名单之外,按 content_type/扩展名补判;其余按
/// image/video/livp/doc(pdf·md·txt)/fallback 分型。
@visibleForTesting
IconData trashKindIcon({required String filename, String? contentType}) {
  final name = filename.toLowerCase();
  if ((contentType ?? '').toLowerCase().startsWith('audio/') ||
      _kAudioExts.any(name.endsWith)) {
    return Icons.graphic_eq;
  }
  return switch (detectKind(filename: filename, contentType: contentType)) {
    PreviewKind.image ||
    PreviewKind.heic => Icons.image_outlined,
    PreviewKind.video => Icons.videocam_outlined,
    PreviewKind.livp => Icons.photo_camera_outlined, // 实况=相机意象
    PreviewKind.pdf ||
    PreviewKind.markdown ||
    PreviewKind.text => Icons.description_outlined,
    PreviewKind.unsupported => Icons.insert_drive_file_outlined,
  };
}

class TrashPage extends StatefulWidget {
  const TrashPage({super.key, required this.folderId, required this.folderName});

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

  /// E10:上次自动加载失败(底部重试条;重新下滑到底亦可再触发)。
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

  /// E10:滚到底(<200px)自动加载(替代「加载更多」按钮格,B3 同款)。
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
      final page = await session.api!.ops.listTrash(widget.folderId, limit: _pageSize);
      if (!mounted) return;
      setState(() {
        _items..clear()..addAll(page.items);
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
      final page = await session.api!.ops.listTrash(widget.folderId, limit: _pageSize, offset: _items.length);
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
      // E10:toast 带目标夹名——恢复=deleted_at 置回 NULL、不动 folder_id
      // (api routers/assets.py restore_asset 实码),本页列表即按该夹过滤,
      // 目标夹=本页夹(widget.folderName),信息可得非强造。
      toast(context, '「${a.filename}」已恢复至 ${widget.folderName}',
          tone: ToastTone.success);
    } catch (e) {
      if (!mounted) return;
      setState(() => _restoringId = '');
      toast(context, errorMessage(e, '恢复失败,请稍后重试'), tone: ToastTone.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('回收站 · ${widget.folderName}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorView(message: _error!, onRetry: _refresh)
              : _items.isEmpty
                  ? const EmptyState(
                      icon: Icons.delete_outline, message: '回收站是空的')
                  : _list(context),
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
              itemCount: _items.length, // E10:「加载更多」格子移除,滚到底自动加载
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final a = _items[i];
                return ListTile(
                  leading: Icon(trashKindIcon(
                      filename: a.filename, contentType: a.contentType)),
                  title: Text(a.filename, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                      '${fmtBytes(a.sizeBytes)} · 删除于 ${a.deletedAt == null ? '—' : fmtDate(a.deletedAt!)}'),
                  trailing: _restoringId == a.id
                      // 18px 参与行高尺寸计算,保留原值不套间距 token
                      ? const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : IconButton(
                          icon: const Icon(Icons.restore_outlined),
                          tooltip: '恢复到文件夹',
                          onPressed: () => _restore(a),
                        ),
                );
              },
            ),
          ),
        ),
        // E10:底部线性加载指示(B3 同款,替代「加载更多」格子)
        if (_loadingMore) const LinearProgressIndicator(minHeight: 2),
        // E10:失败重试条(点击重载;重新下滑到底亦可触发)
        if (_loadMoreFailed && !_loadingMore) _retryBar(context),
      ],
    );
  }

  /// B3 同款(assets_body):加载失败底部重试条。
  Widget _retryBar(BuildContext context) {
    final color = Theme.of(context).colorScheme.error;
    return InkWell(
      onTap: _loadMore,
      child: SizedBox(
        height: 28,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 14, color: color),
            const SizedBox(width: Tk.spaceXs),
            Text('加载失败,点击重试',
                style: TextStyle(fontSize: Tk.fzXs, color: color)),
          ],
        ),
      ),
    );
  }
}
