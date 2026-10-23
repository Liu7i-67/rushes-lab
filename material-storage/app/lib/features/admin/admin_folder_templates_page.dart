/// AdminFolderTemplatesPage — 目录模板管理(B8 功能点 6;web
/// AdminFolderTemplatesPage 移动版):列表(条目数/条目预览)+ 建(路径校验)
/// + 编辑 + 删除。闸门 = is_folder_template_manager ?? is_system_admin
/// (我的页独立磁贴放行;后端写端点 require_folder_template_manager 终审)。
/// 视觉:PageHeader + SectionCard 行卡,右侧条目数与 chevron。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_confirm.dart';
import '../../widgets/app_row.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import '../../widgets/page_header.dart';
import '../../widgets/toast.dart';
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
        _error = errorMessage(e, '加载失败,请稍后重试');
        _loading = false;
      });
    }
  }

  Future<void> _delete(FolderTemplate t) async {
    // F3:确认口径 `!= true`——取消 false / 遮罩关闭 null 均视为未确认
    final ok = await showAppConfirm(
      context,
      title: '删除目录模板「${t.name}」?',
      content: '${t.entryCount} 条目录条目将一并删除;已建项目不受影响',
      confirmLabel: '删除',
      danger: true,
    );
    if (ok != true) return;
    try {
      await session.api!.adminTemplates.deleteFolderTemplate(t.id);
      if (!mounted) return;
      toast(context, '已删除目录模板「${t.name}」', tone: ToastTone.success);
      _reload();
    } on ApiException catch (e) {
      if (!mounted) return;
      toast(context, e.message, tone: ToastTone.error); // 404/403 透传
    }
  }

  Future<void> _openActions(FolderTemplate t) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'edit':
        final ok = await showFolderTemplateFormSheet(context, template: t);
        if (ok) _reload();
      case 'delete':
        await _delete(t);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          PageHeader(
            back: true,
            title: '目录模板',
            subtitle: '新建项目时自动生成结构',
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
      return const EmptyState(
        icon: Icons.account_tree_outlined,
        message: '无目录模板',
        description: '新建一个供新建项目时一键建立目录树',
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          Tk.spacePage,
          Tk.spaceMd,
          Tk.spacePage,
          Tk.space2xl,
        ),
        children: [
          SectionCard(children: [for (final t in _items) _templateRow(t)]),
        ],
      ),
    );
  }

  Widget _templateRow(FolderTemplate t) {
    final desc = (t.description ?? '').trim();
    final preview = t.entries.take(3).map((e) => e.path).join(' / ');
    final subtitle = desc.isNotEmpty
        ? desc
        : (preview.isNotEmpty ? preview : '暂无目录条目');
    return AppRow(
      leading: const Icon(Icons.account_tree_outlined),
      goldIcon: true,
      title: t.name,
      subtitle: subtitle,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${t.entryCount} 个目录',
            style: TextStyle(fontSize: Tk.fzMd, color: context.tk.ink3),
          ),
          const SizedBox(width: 6),
          Icon(Icons.chevron_right, size: 18, color: context.tk.ink3),
        ],
      ),
      onTap: () => _openActions(t),
    );
  }
}
