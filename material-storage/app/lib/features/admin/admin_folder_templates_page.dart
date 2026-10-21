/// AdminFolderTemplatesPage — 目录模板管理(B8 功能点 6;web
/// AdminFolderTemplatesPage 移动版):列表(条目数/条目预览)+ 建(路径校验)
/// + 编辑 + 删除。闸门 = is_folder_template_manager ?? is_system_admin
/// (我的页独立磁贴放行;后端写端点 require_folder_template_manager 终审)。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import 'folder_template_form_sheet.dart';

class AdminFolderTemplatesPage extends StatefulWidget {
  const AdminFolderTemplatesPage({super.key});

  @override
  State<AdminFolderTemplatesPage> createState() =>
      _AdminFolderTemplatesPageState();
}

class _AdminFolderTemplatesPageState extends State<AdminFolderTemplatesPage> {
  var _items = <FolderTemplate>[];
  var _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = _items.isEmpty);
    try {
      final items = await session.api!.adminTemplates.folderTemplates();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message; // 403 detail 透传(读弱门外的深链兜底)
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

  Future<void> _delete(FolderTemplate t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除目录模板「${t.name}」?'),
        content: Text('${t.entryCount} 条目录条目将一并删除;已建项目不受影响'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(foregroundColor: Tk.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await session.api!.adminTemplates.deleteFolderTemplate(t.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已删除目录模板「${t.name}」')));
      _reload();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message))); // 404/403 透传
    }
  }

  Future<void> _openActions(FolderTemplate t) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('编辑'),
            onTap: () => Navigator.of(context).pop('edit'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('删除'),
            onTap: () => Navigator.of(context).pop('delete'),
          ),
        ]),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'edit':
        final ok =
            await showFolderTemplateFormSheet(context, template: t);
        if (ok) _reload();
      case 'delete':
        await _delete(t);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('目录模板'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新建模板',
            onPressed: () async {
              final ok = await showFolderTemplateFormSheet(context);
              if (ok) _reload();
            },
          ),
        ],
      ),
      body: _body(),
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
      return const EmptyState(message: '无目录模板 · 新建一个供新建项目时一键建立目录树');
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.builder(
        itemCount: _items.length,
        itemBuilder: (context, i) {
          final t = _items[i];
          return ListTile(
            title: Row(children: [
              Flexible(
                child: Text(t.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 6),
              Text('${t.entryCount} 个目录',
                  style: const TextStyle(fontSize: 11, color: Tk.subtle)),
            ]),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (t.description != null && t.description!.isNotEmpty)
                  Text(t.description!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5)),
                // 条目一览(最多 6 条,余量折叠;web TemplateRow 同口径)
                for (final e in t.entries.take(6))
                  Text(e.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: Tk.muted)),
                if (t.entries.length > 6)
                  Text('+${t.entries.length - 6}',
                      style:
                          const TextStyle(fontSize: 11, color: Tk.subtle)),
              ],
            ),
            isThreeLine: t.entries.length > 3,
            trailing: const Icon(Icons.more_horiz),
            onTap: () => _openActions(t),
          );
        },
      ),
    );
  }
}
