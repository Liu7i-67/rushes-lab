/// 项目内文件夹树(flat 列表 → 内存建树,ExpansionTile 递归渲染;现役平移)。
library;

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../models/models.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';

class FoldersPage extends StatefulWidget {
  const FoldersPage({super.key, required this.projectId});

  final String projectId;

  @override
  State<FoldersPage> createState() => _FoldersPageState();
}

class _FoldersPageState extends State<FoldersPage> {
  late Future<List<Folder>> _future;

  @override
  void initState() {
    super.initState();
    _future = session.api!.folders.list(widget.projectId);
  }

  void _reload() =>
      setState(() => _future = session.api!.folders.list(widget.projectId));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('文件夹'),
        actions: [
          IconButton(onPressed: _reload, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: FutureBuilder<List<Folder>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return ErrorView(message: '${snap.error}', onRetry: _reload);
          }
          final all = snap.data ?? const [];
          final roots = _buildTree(all);
          if (roots.isEmpty) {
            return const EmptyState(
              icon: Icons.folder_outlined,
              message: '暂无文件夹',
            );
          }
          return ListView(
            children: [
              for (final n in roots) _FolderNodeTile(node: n),
            ],
          );
        },
      ),
    );
  }
}

class _Node {
  _Node(this.folder);

  final Folder folder;
  final List<_Node> children = [];
}

List<_Node> _buildTree(List<Folder> all) {
  final byId = <String, _Node>{};
  for (final f in all) {
    byId[f.id] = _Node(f);
  }
  final roots = <_Node>[];
  for (final n in byId.values) {
    final parent =
        n.folder.parentFolderId != null ? byId[n.folder.parentFolderId] : null;
    if (parent != null) {
      parent.children.add(n);
    } else {
      roots.add(n);
    }
  }
  return roots;
}

class _FolderNodeTile extends StatelessWidget {
  const _FolderNodeTile({required this.node});

  final _Node node;

  @override
  Widget build(BuildContext context) {
    final f = node.folder;
    final titleRow = Row(
      children: [
        Expanded(child: Text(f.name, overflow: TextOverflow.ellipsis)),
        if (f.isSensitive)
          const Padding(
            padding: EdgeInsets.only(left: 6),
            child: Icon(Icons.lock_outline, size: 14),
          ),
      ],
    );
    void open() =>
        Navigator.of(context).pushNamed('/assets', arguments: (f.id, f.name));
    if (node.children.isEmpty) {
      return ListTile(
        dense: true,
        leading: const Icon(Icons.folder_outlined),
        title: titleRow,
        trailing: const Icon(Icons.chevron_right),
        onTap: open,
      );
    }
    return ExpansionTile(
      dense: true,
      leading: const Icon(Icons.folder_outlined),
      title: GestureDetector(onTap: open, child: titleRow),
      children: [for (final c in node.children) _FolderNodeTile(node: c)],
    );
  }
}
