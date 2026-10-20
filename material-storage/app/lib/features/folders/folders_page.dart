/// 项目内文件夹页(B2 §8.1):flat 列表自组树、按缩进展示、支持多级下钻,
/// 行=subtree_file_count 徽标+敏感锁+「⋯」占位菜单;点夹进宫格上下文。
/// my_can_* 列表响应恒 False,本页不消费(宫格页拉单夹详情,§11 钉子)。
library;

import 'package:flutter/material.dart';

import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import 'folder_row.dart';
import 'folder_tree.dart';

class FoldersPage extends StatefulWidget {
  const FoldersPage({
    super.key,
    required this.projectId,
    this.projectName = '',
  });

  final String projectId;

  /// 项目显示名(B3:宫格上传任务 where=「项目/…/文件夹」路径前缀)。
  final String projectName;

  @override
  State<FoldersPage> createState() => _FoldersPageState();
}

class _FoldersPageState extends State<FoldersPage> {
  var _all = const <Folder>[];
  var _loading = true; // 仅首轮整页 spinner;刷新在旧数据上原地等(B2 修复 P2-9)
  String? _error;
  final _collapsed = <String>{};

  @override
  void initState() {
    super.initState();
    // 数据新鲜度:上传等写操作成功后失效 'folders',本页自动重拉子树计数
    RefreshBus.I.addListener('folders', _reload);
    _reload();
  }

  @override
  void dispose() {
    RefreshBus.I.removeListener('folders', _reload);
    super.dispose();
  }

  /// 拉取并落态(失效总线/下拉刷新/返回重拉同路);返回真 future,
  /// RefreshIndicator 的圈等完成后才收,旧树在刷新期间继续展示不整页替换。
  Future<void> _reload() async {
    try {
      final folders = await session.api!.folders.list(widget.projectId);
      if (!mounted) return;
      setState(() {
        _all = folders;
        _error = null;
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

  /// 深度优先铺平可见行(折叠的子树跳过);roots 顺序保持后端返回序。
  List<(FolderNode, int)> _visibleRows(List<FolderNode> roots) {
    final rows = <(FolderNode, int)>[];
    void walk(List<FolderNode> nodes, int depth) {
      for (final n in nodes) {
        rows.add((n, depth));
        if (n.children.isNotEmpty && !_collapsed.contains(n.folder.id)) {
          walk(n.children, depth + 1);
        }
      }
    }

    walk(roots, 0);
    return rows;
  }

  /// 显示路径(项目/…/本夹,§7 where):父链自 flat 列表回溯;
  /// 环防御=已访问 id 集合,孤儿/断链取已得前缀。
  String _whereOf(Folder f) {
    final byId = {for (final x in _all) x.id: x};
    final names = <String>[f.name];
    final seen = <String>{f.id};
    var cur = f.parentFolderId;
    while (cur != null && seen.add(cur)) {
      final p = byId[cur];
      if (p == null) break;
      names.insert(0, p.name);
      cur = p.parentFolderId;
    }
    return [
      if (widget.projectName.isNotEmpty) widget.projectName,
      ...names,
    ].join('/');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('文件夹')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorView(message: _error!, onRetry: _reload)
              : _buildTree(context),
    );
  }

  Widget _buildTree(BuildContext context) {
    final roots = buildFolderTree(_all);
    if (roots.isEmpty) {
      // 含全被过滤(孤儿/环不可达)的情况:与 web 同口径,空即空
      return const EmptyState(
        icon: Icons.folder_outlined,
        message: '暂无文件夹',
      );
    }
    final rows = _visibleRows(roots);
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.separated(
        itemCount: rows.length + 1,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          if (i == rows.length) {
            return const SizedBox(height: 24); // 底部呼吸空间
          }
          final (node, depth) = rows[i];
          return FolderRow(
            node: node,
            depth: depth,
            expanded: !_collapsed.contains(node.folder.id),
            onToggle: () => setState(() {
              _collapsed.contains(node.folder.id)
                  ? _collapsed.remove(node.folder.id)
                  : _collapsed.add(node.folder.id);
            }),
            onOpen: () => Navigator.of(context)
                .pushNamed('/assets', arguments: (
                  node.folder.id,
                  node.folder.name,
                  _whereOf(node.folder),
                ))
                .then((_) => _reload()), // 返回按需刷新(子树计数可能变)
          );
        },
      ),
    );
  }
}
