/// 回收站页(B5 功能点 2,对标 web FolderTrashModal 移动版;仅恢复,彻底删除
/// 留待后续批):GET /assets/trash(参数=实码 folder_id/limit≤500/offset)+
/// POST /assets/{id}/restore;分页=加载更多窗口(total 独立返回)。
/// 入口显隐三态(web ProjectDetailPage canSeeTrash 实码对齐):
/// 普通夹 = my_can_admin 或 my_delete_grant(组级删除授权);sensitive 夹仅系统
/// admin(回收站不得成为项目 admin 窥探敏感文件名的侧信道)。
library;

import 'package:flutter/material.dart';

import '../../core/fmt.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../services/app_log.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
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
  var _total = 0;
  var _loading = true;
  var _loadingMore = false;
  var _restoringId = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
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
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _items.length >= _total) return;
    setState(() => _loadingMore = true);
    try {
      final page = await session.api!.ops.listTrash(widget.folderId, limit: _pageSize, offset: _items.length);
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items);
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text('加载更多失败:$e')));
    }
  }

  Future<void> _restore(Asset a) async {
    setState(() => _restoringId = a.id);
    try {
      await session.api!.ops.restore(a.id);
      AppLog.info('trash', '已恢复:${a.filename}');
      if (!mounted) return;
      setState(() {
        _items.removeWhere((x) => x.id == a.id);
        _total = (_total - 1).clamp(0, 1 << 31);
        _restoringId = '';
      });
      notifyAssetMutation(widget.folderId); // 列表计数恢复 → 宫格+folders 刷新
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('「${a.filename}」已恢复')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _restoringId = '');
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text('恢复失败:$e')));
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
    final hasMore = _items.length < _total;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        itemCount: _items.length + (hasMore ? 1 : 0),
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          if (i >= _items.length) {
            return ListTile(
              title: Center(
                child: _loadingMore
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Text('加载更多(${_items.length}/$_total)'),
              ),
              onTap: _loadMore,
            );
          }
          final a = _items[i];
          return ListTile(
            leading: const Icon(Icons.description_outlined),
            title: Text(a.filename, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
                '${fmtBytes(a.sizeBytes)} · 删除于 ${a.deletedAt == null ? '—' : fmtDate(a.deletedAt!)}'),
            trailing: _restoringId == a.id
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
    );
  }
}
