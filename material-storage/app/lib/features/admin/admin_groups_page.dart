/// AdminGroupsPage — 用户组管理(B8 功能点 3;web AdminGroupsPage 移动版):
/// 列表(q 搜索 + 成员数 + 五组级 flag 徽标)+ 建/编 + 成员管理(加/移)。
/// 组内成员变更即时生效(OpenFGA group#member)。require_system_admin。
/// 视觉:PageHeader + 搜索行 + SectionCard 行卡(金浅底组图标)。
library;

import 'dart:async';

import 'package:flutter/material.dart' hide Badge;

import '../../core/api/ms_api.dart';
import '../../core/fmt.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_confirm.dart';
import '../../widgets/app_row.dart';
import '../../widgets/badge.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import '../../widgets/page_header.dart';
import '../../widgets/search_field.dart';
import '../../widgets/toast.dart';
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
      final items = await session.api!.directory.listGroups(
        q: _search.text.trim(),
        limit: 200,
      );
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
        _error = errorMessage(e, '加载失败,请稍后重试');
        _loading = false;
      });
    }
  }

  Future<void> _delete(DirectoryGroup g) async {
    // F3:确认口径 `!= true`——取消 false / 遮罩关闭 null 均视为未确认
    final ok = await showAppConfirm(
      context,
      title: '删除用户组「${g.name}」?',
      content: '组内 ${g.memberCount} 名成员将立即失去该组授予的全部权限',
      confirmLabel: '删除',
      danger: true,
    );
    if (ok != true) return;
    try {
      await session.api!.directory.deleteGroup(g.id);
      if (!mounted) return;
      toast(context, '已删除用户组「${g.name}」', tone: ToastTone.success);
      _reload();
    } on ApiException catch (e) {
      if (!mounted) return;
      toast(context, e.message, tone: ToastTone.error); // detail 透传
    }
  }

  Future<void> _openActions(DirectoryGroup g) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
          ],
        ),
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
      body: Column(
        children: [
          PageHeader(
            back: true,
            title: '用户组',
            subtitle: _loading ? null : '共 ${_items.length} 个组 · 按团队批量授权',
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
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Tk.spacePage,
              Tk.spaceSm,
              Tk.spacePage,
              Tk.spaceSm,
            ),
            child: SearchField(
              controller: _search,
              hintText: '搜用户组名…',
              onChanged: (v) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 300), _reload);
              },
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
      return const EmptyState(icon: Icons.groups_outlined, message: '无用户组');
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          Tk.spacePage,
          Tk.spaceMd,
          Tk.spacePage,
          Tk.space2xl,
        ),
        children: [
          SectionCard(
            children: [
              for (final g in _items)
                _GroupRow(group: g, onOpen: () => _openActions(g)),
            ],
          ),
        ],
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
    final tk = context.tk;
    final g = group;
    final desc = (g.description ?? '').trim();
    final flags = _flags(g);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppRow(
          leading: const Icon(Icons.groups_outlined),
          goldIcon: true,
          title: g.name,
          subtitle: desc.isEmpty ? '创建于 ${fmtDate(g.createdAt)}' : desc,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${g.memberCount} 人',
                style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
              ),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right, size: 18, color: tk.ink3),
            ],
          ),
          onTap: onOpen,
        ),
        if (flags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(60, 0, 14, 10),
            child: Wrap(
              spacing: Tk.spaceXs,
              runSpacing: Tk.spaceXs,
              children: flags,
            ),
          ),
      ],
    );
  }

  List<Widget> _flags(DirectoryGroup g) => [
    if (g.canCreateProject) const Badge(label: '可建项目', tone: BadgeTone.gold),
    if (g.canDeleteProject) const Badge(label: '可删项目', tone: BadgeTone.danger),
    if (g.canManageFolderTemplates)
      const Badge(label: '可管模板', tone: BadgeTone.gold),
    if (g.canDeleteFiles) const Badge(label: '可删文件', tone: BadgeTone.danger),
  ];
}
