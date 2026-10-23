/// AdminGrantTemplatesPage — 权限模板管理(B8 功能点 5;web
/// AdminGrantTemplatesPage 移动版):列表(默认徽标/条目预览)+ 建模板
/// (主体行×独立角色,50 条上限)+ 编辑 + 删除 + 应用默认(多项目批量,
/// require_system_admin——全 App 唯一应用默认入口;无默认模板时禁用)。
/// 视觉:PageHeader + SectionCard 金浅底图标行卡,右侧条数与 chevron。
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
import '../../widgets/badge.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import '../../widgets/page_header.dart';
import '../../widgets/role_chips.dart' show joinedRoleLabels;
import '../../widgets/toast.dart';
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
        _error = errorMessage(e, '加载失败,请稍后重试');
        _loading = false;
      });
    }
  }

  Future<void> _delete(GrantTemplate t) async {
    // F3:确认口径 `!= true`——取消 false / 遮罩关闭 null 均视为未确认
    final ok = await showAppConfirm(
      context,
      title: '删除权限模板「${t.name}」?',
      content: '${t.items.length} 条授权条目将一并删除;已建项目不受影响',
      confirmLabel: '删除',
      danger: true,
    );
    if (ok != true) return;
    try {
      await session.api!.adminTemplates.deleteTemplate(t.id);
      if (!mounted) return;
      toast(context, '已删除权限模板「${t.name}」', tone: ToastTone.success);
      _reload();
    } on ApiException catch (e) {
      if (!mounted) return;
      toast(context, e.message, tone: ToastTone.error); // 404/403 detail 透传
    }
  }

  Future<void> _openActions(GrantTemplate t) async {
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
        final ok = await showGrantTemplateFormSheet(context, template: t);
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
      body: Column(
        children: [
          PageHeader(
            back: true,
            title: '授权模板',
            subtitle: '新建项目时可直接套用',
            actions: [
              // F4:「应用默认」非刷新语义 → published_with_changes + 行内文字标签,
              // 与相邻「新建」add 图标明确区分(位置不变,仅图标/标签语义化)
              Tooltip(
                message: hasDefault
                    ? '应用默认:为存量项目补齐默认模板授权(叠加不删)'
                    : '应用默认:需先设一个默认模板',
                child: TextButton.icon(
                  onPressed: hasDefault && !_loading
                      ? () => showApplyDefaultSheet(context)
                      : null,
                  icon: const Icon(Icons.published_with_changes, size: 20),
                  label: const Text(
                    '应用默认',
                    style: TextStyle(fontSize: Tk.fzSm),
                  ),
                ),
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
        icon: Icons.key_outlined,
        message: '无权限模板',
        description: '新建一个供新建项目时预填初始权限',
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

  Widget _templateRow(GrantTemplate t) {
    final desc = (t.description ?? '').trim();
    final preview = t.items.isEmpty
        ? ''
        : t.items
              .take(3)
              .map(
                (it) =>
                    '${it.name.isEmpty ? '已删主体' : it.name}'
                    ' · ${joinedRoleLabels(it.roles)}',
              )
              .join('  |  ');
    final subtitle = desc.isNotEmpty
        ? desc
        : (preview.isNotEmpty ? preview : '暂无授权条目');
    return AppRow(
      leading: const Icon(Icons.key_outlined),
      goldIcon: true,
      title: t.name,
      subtitle: subtitle,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (t.isDefault) ...[
            const Badge(label: '默认', tone: BadgeTone.gold),
            const SizedBox(width: 6),
          ],
          Text(
            '${t.items.length} 条',
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
