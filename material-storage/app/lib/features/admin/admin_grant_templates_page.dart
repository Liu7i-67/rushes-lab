/// AdminGrantTemplatesPage — 权限模板管理(B8 功能点 5;web
/// AdminGrantTemplatesPage 移动版):列表(默认徽标/条目预览)+ 建模板
/// (主体行×独立角色,50 条上限)+ 编辑 + 删除 + 应用默认(多项目批量,
/// require_system_admin——全 App 唯一应用默认入口;无默认模板时禁用)。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/badge.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import '../../widgets/role_chips.dart' show joinedRoleLabels;
import 'apply_default_sheet.dart';
import 'grant_template_form_sheet.dart';

class AdminGrantTemplatesPage extends StatefulWidget {
  const AdminGrantTemplatesPage({super.key});

  @override
  State<AdminGrantTemplatesPage> createState() =>
      _AdminGrantTemplatesPageState();
}

class _AdminGrantTemplatesPageState extends State<AdminGrantTemplatesPage> {
  var _items = <GrantTemplate>[];
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
      final items = await session.api!.adminTemplates.grantTemplates();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message; // 403 detail 透传(非 admin 深链兜底)
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

  Future<void> _delete(GrantTemplate t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除权限模板「${t.name}」?'),
        content: Text('${t.items.length} 条授权条目将一并删除;已建项目不受影响'),
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
      await session.api!.adminTemplates.deleteTemplate(t.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已删除权限模板「${t.name}」')));
      _reload();
    } on ApiException catch (e) {
      _toast(e.message); // 404/403 detail 透传
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openActions(GrantTemplate t) async {
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
            await showGrantTemplateFormSheet(context, template: t);
        if (ok) _reload();
      case 'delete':
        await _delete(t);
    }
  }

  @override
  Widget build(BuildContext context) {
    // web 同款:无默认模板时「应用默认」禁用(接口也会 400,提前拦)
    final hasDefault = _items.any((t) => t.isDefault);
    return Scaffold(
      appBar: AppBar(
        title: const Text('权限模板'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, size: 22),
            tooltip: hasDefault
                ? '应用默认:为存量项目补齐默认模板授权(叠加不删)'
                : '应用默认:需先设一个默认模板',
            onPressed: hasDefault && !_loading
                ? () => showApplyDefaultSheet(context)
                : null,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新建模板',
            onPressed: () async {
              final ok = await showGrantTemplateFormSheet(context);
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
      return const EmptyState(message: '无权限模板 · 新建一个供新建项目时预填初始权限');
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
              if (t.isDefault)
                const Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: Badge(label: '默认', tone: BadgeTone.accent),
                ),
              const SizedBox(width: 6),
              Text('${t.items.length} 个主体',
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
                for (final it in t.items.take(6))
                  Text(
                    '${it.name}${it.missing ? '(已删除)' : ''} · '
                    '${joinedRoleLabels(it.roles)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11,
                        color: it.missing ? Tk.amber : Tk.muted),
                  ),
                if (t.items.length > 6)
                  Text('+${t.items.length - 6}',
                      style:
                          const TextStyle(fontSize: 11, color: Tk.subtle)),
              ],
            ),
            isThreeLine: t.items.length > 3,
            trailing: const Icon(Icons.more_horiz),
            onTap: () => _openActions(t),
          );
        },
      ),
    );
  }
}
