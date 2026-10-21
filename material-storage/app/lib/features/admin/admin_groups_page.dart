/// AdminGroupsPage — 用户组管理(B8 功能点 3;web AdminGroupsPage 移动版):
/// 列表(q 搜索 + 成员数 + 五组级 flag 徽标)+ 建/编 + 成员管理(加/移)。
/// 组内成员变更即时生效(OpenFGA group#member)。require_system_admin。
library;

import 'dart:async';

import 'package:flutter/material.dart' hide Badge;

import '../../core/api/ms_api.dart';
import '../../core/fmt.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/badge.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import 'group_form_sheet.dart';
import 'group_members_sheet.dart';

class AdminGroupsPage extends StatefulWidget {
  const AdminGroupsPage({super.key});

  @override
  State<AdminGroupsPage> createState() => _AdminGroupsPageState();
}

class _AdminGroupsPageState extends State<AdminGroupsPage> {
  final _search = TextEditingController();
  Timer? _debounce;
  var _items = <DirectoryGroup>[];
  var _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() => _loading = _items.isEmpty);
    try {
      final items = await session.api!.directory
          .listGroups(q: _search.text.trim(), limit: 200);
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

  Future<void> _delete(DirectoryGroup g) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除用户组「${g.name}」?'),
        content: Text('组内 ${g.memberCount} 名成员将立即失去该组授予的全部权限'),
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
      await session.api!.directory.deleteGroup(g.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已删除用户组「${g.name}」')));
      _reload();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message))); // detail 透传
    }
  }

  Future<void> _openActions(DirectoryGroup g) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.people_outline),
            title: const Text('成员管理'),
            onTap: () => Navigator.of(context).pop('members'),
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('编辑(改名/描述/组级开关)'),
            onTap: () => Navigator.of(context).pop('edit'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('删除用户组'),
            onTap: () => Navigator.of(context).pop('delete'),
          ),
        ]),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'members':
        // 成员抽屉内增删驻留不关闭(web 同款);关闭后组列表可能已变,恒刷新
        await showGroupMembersSheet(context, g);
        if (mounted) _reload();
      case 'edit':
        final ok = await showGroupFormSheet(context, group: g);
        if (ok) _reload();
      case 'delete':
        await _delete(g);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('用户组'),
        actions: [
          IconButton(
            icon: const Icon(Icons.group_add),
            tooltip: '新建用户组',
            onPressed: () async {
              final ok = await showGroupFormSheet(context);
              if (ok) _reload();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _search,
              onChanged: (v) {
                _debounce?.cancel();
                _debounce =
                    Timer(const Duration(milliseconds: 300), _reload);
              },
              decoration: const InputDecoration(
                isDense: true,
                hintText: '搜用户组名…',
                prefixIcon: Icon(Icons.search, size: 20),
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(child: _body()),
        ],
      ),
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
      return const EmptyState(message: '无用户组');
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.builder(
        itemCount: _items.length,
        itemBuilder: (context, i) => _GroupRow(
          group: _items[i],
          onOpen: () => _openActions(_items[i]),
        ),
      ),
    );
  }
}

class _GroupRow extends StatelessWidget {
  const _GroupRow({required this.group, required this.onOpen});

  final DirectoryGroup group;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final g = group;
    return ListTile(
      title: Row(
        children: [
          Flexible(
            child: Text(g.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 6),
          Text('${g.memberCount} 人',
              style: const TextStyle(fontSize: 11, color: Tk.subtle)),
          const SizedBox(width: 6),
          if (g.canCreateProject)
            const Badge(label: '可建项目', tone: BadgeTone.accent),
          if (g.canDeleteProject)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Badge(label: '可删项目', tone: BadgeTone.red),
            ),
          if (g.canManageFolderTemplates)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Badge(label: '可管模板', tone: BadgeTone.accent),
            ),
          if (g.canDeleteFiles)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Badge(label: '可删文件', tone: BadgeTone.red),
            ),
        ],
      ),
      subtitle: Text(
        '${g.description ?? ''} · 创建于 ${fmtDate(g.createdAt)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11.5),
      ),
      trailing: const Icon(Icons.more_horiz),
      onTap: onOpen,
    );
  }
}
