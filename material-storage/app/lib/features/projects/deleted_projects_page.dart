/// DeletedProjectsPage — 已删除项目回收站(B6 §8.5;web DeletedProjectsModal
/// 移动版):列表(q 过 code/name,deleted_at 倒序,带删除人)+ 服务端分页
/// + 单行恢复。入口=我的→「回收站(项目)」,仅 is_project_deleter 可见
/// (后端 deleted/restore 双端点 require_project_deleter 同口径);恢复成功
/// invalidate projects scope。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import '../../core/fmt.dart';

/// 分页页大小(web DELETED_PROJECTS_PAGE_SIZE 同款)。
const kDeletedProjectsPageSize = 20;

class DeletedProjectsPage extends StatefulWidget {
  const DeletedProjectsPage({super.key});

  @override
  State<DeletedProjectsPage> createState() => _DeletedProjectsPageState();
}

class _DeletedProjectsPageState extends State<DeletedProjectsPage> {
  String _q = '';
  final _items = <DeletedProject>[];
  var _total = 0;
  var _loading = true;
  String? _error;

  /// P2-2 加载更多防连点 + 代际 tag(参照 pickers stale tag 模式):
  /// 搜索 reload 使 tag 自增,旧 loadMore 的迟到响应按 tag 不匹配丢弃,
  /// 不污染新词列表。
  var _loadingMore = false;
  var _reloadTag = 0;

  /// P2-1 恢复防重:restore await 期间禁用行内按钮并拦下重复调用。
  var _restoring = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  /// 拉第一页并整表替换(搜索词变化/恢复后);[q] 传 null = 沿用当前词。
  Future<void> _reload() async {
    final tag = ++_reloadTag;
    try {
      final page = await session.api!.projectsOps
          .listDeleted(q: _q, limit: kDeletedProjectsPageSize, offset: 0);
      if (tag != _reloadTag || !mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _total = page.total;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (tag != _reloadTag || !mounted) return;
      setState(() {
        _error = e.message; // 403 detail 透传(非 is_project_deleter 深链兜底)
        _loading = false;
      });
    } catch (e) {
      if (tag != _reloadTag || !mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// 追加下一页(加载更多;P2-2:_loadingMore 防连点,快照代际 tag 防搜索
  /// reload 后旧响应追加进新词列表)。
  Future<void> _loadMore() async {
    if (_loadingMore) return;
    final tag = _reloadTag;
    setState(() => _loadingMore = true);
    try {
      final page = await session.api!.projectsOps.listDeleted(
          q: _q,
          limit: kDeletedProjectsPageSize,
          offset: _items.length);
      if (tag != _reloadTag || !mounted) return;
      setState(() {
        _items.addAll(page.items);
        _total = page.total;
      });
    } catch (e) {
      if (tag != _reloadTag || !mounted) return;
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text('加载更多失败:$e')));
    } finally {
      _loadingMore = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _restore(DeletedProject p) async {
    if (_restoring) return; // P2-1 防连点(守卫须在首个 await 前同步生效)
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('恢复项目「${p.name}」?'),
        content: const Text('恢复后立即回到项目列表,原成员权限不变。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('恢复')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _restoring = true);
    try {
      await session.api!.projectsOps.restore(p.id);
      RefreshBus.I.invalidate('projects');
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text('项目「${p.name}」已恢复')));
      _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text('恢复失败:$e')));
    } finally {
      _restoring = false;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('回收站(项目)')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            decoration: const InputDecoration(
              isDense: true,
              hintText: '搜项目代号 / 名称…',
              prefixIcon: Icon(Icons.search, size: 20),
              border: OutlineInputBorder(),
            ),
            onSubmitted: (v) {
              _q = v.trim();
              setState(() => _loading = true);
              _reload();
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '已删除的项目对所有成员(含系统管理员)隐藏,但数据、授权与分享链接'
            '全部保留;恢复后立即回到项目列表。',
            style: const TextStyle(fontSize: 11.5, color: Tk.subtle),
          ),
        ),
        Expanded(child: _body()),
      ]),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ErrorView(message: _error!, onRetry: _reload);
    }
    if (_items.isEmpty) {
      return EmptyState(
        icon: Icons.delete_sweep_outlined,
        message: _q.isEmpty ? '没有已删除的项目' : '无匹配项目',
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.separated(
        itemCount: _items.length + (_items.length < _total ? 1 : 0),
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          if (i >= _items.length) {
            return TextButton(
              onPressed: _loadingMore ? null : _loadMore,
              child: Text(_loadingMore ? '加载中…' : '加载更多'),
            );
          }
          final p = _items[i];
          return ListTile(
            leading: const Icon(Icons.folder_delete_outlined),
            title: Text('${p.name}(${p.code})',
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '删除于 ${p.deletedAt.isEmpty ? '—' : fmtDate(p.deletedAt)}'
              '${p.deletedByName == null ? '' : ' · ${p.deletedByName}'}',
              style: const TextStyle(fontSize: 11.5),
            ),
            trailing: TextButton.icon(
              icon: const Icon(Icons.restore_from_trash_outlined, size: 16),
              label: const Text('恢复'),
              onPressed: _restoring ? null : () => _restore(p),
            ),
          );
        },
      ),
    );
  }
}
