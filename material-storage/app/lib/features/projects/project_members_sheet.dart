/// ProjectMembersSheet — 项目成员管理(B6 §8.5;web ProjectMembersDrawer 移动
/// 版):直接成员(角色徽章逐个撤销,admin 自撤/末位 admin 409 detail 透传)+
/// 授权总览(#138 审批/邀请 grant,四元组撤回)+ 邀请表单(SubjectPicker +
/// RoleChips,一次授多角色)。入口=项目行「成员」(仅 my_roles 含 admin 显示;
/// 后端 can_admin 兜底)。
library;

import 'package:flutter/material.dart';

import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import 'member_add_form.dart';
import 'project_grants_overview.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/role_chips.dart';

/// 打开项目成员管理面板。
Future<void> showProjectMembersSheet(
  BuildContext context, {
  required Project project,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _MembersSheet(project: project),
  );
}

class _MembersSheet extends StatefulWidget {
  const _MembersSheet({required this.project});

  final Project project;

  @override
  State<_MembersSheet> createState() => _MembersSheetState();
}

class _MembersSheetState extends State<_MembersSheet> {
  var _showForm = false;
  late Future<List<ProjectMember>> _members = _load();

  Future<List<ProjectMember>> _load() =>
      session.api!.projectsOps.listMembers(widget.project.id);

  void _reload() => setState(() => _members = _load());

  Future<void> _removeRole(ProjectMember m, String role) async {
    final label = kRoleLabels[role] ?? role;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('撤销「${m.name ?? m.subjectId}」的$label角色?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(foregroundColor: Tk.red),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('撤销')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await session.api!.projectsOps
          .removeMember(widget.project.id, subject: m.subject, role: role);
      RefreshBus.I.invalidate('projects');
      _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text('撤销失败:$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: _showForm
            ? MemberAddForm(project: widget.project, onDone: () {
                setState(() {
                  _showForm = false; // 成功回成员列表(web onClose 同款)
                  _members = _load();
                });
              })
            : Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('成员 · ${widget.project.name}',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView(children: [
                        const _SectionLabel(
                            title: '直接成员',
                            hint: '项目级角色:管理/上传/下载/查看(点角色撤销)'),
                        _memberList(),
                        const SizedBox(height: 12),
                        const _SectionLabel(
                            title: '授权总览',
                            hint: '通过审批/邀请获得的授权(含临时与永久),可撤回'),
                        ProjectGrantsOverview(project: widget.project),
                      ]),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        icon: const Icon(Icons.person_add_alt_1, size: 18),
                        label: const Text('添加成员'),
                        onPressed: () => setState(() => _showForm = true),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _memberList() {
    return FutureBuilder<List<ProjectMember>>(
      future: _members,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text('加载中…', style: TextStyle(fontSize: 12.5, color: Tk.subtle)),
          );
        }
        if (snap.hasError) {
          return Text('加载失败:${snap.error}',
              style: const TextStyle(fontSize: 12.5, color: Tk.red));
        }
        final members = snap.data ?? const <ProjectMember>[];
        if (members.isEmpty) {
          return const Text('还没有成员 · 点下方「添加成员」开始',
              style: TextStyle(fontSize: 12.5, color: Tk.subtle));
        }
        return Column(
          children: [
            for (final m in members)
              ListTile(
                visualDensity: VisualDensity.compact,
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  radius: 13,
                  backgroundColor: m.kind == 'user' ? Tk.fg : Tk.border,
                  child: Text(
                    m.kind == 'user'
                        ? (m.name ?? '?').isEmpty
                            ? '?'
                            : m.name!.characters.first.toUpperCase()
                        : '群',
                    style: TextStyle(
                        fontSize: 11,
                        color: m.kind == 'user' ? Tk.surface : Tk.muted),
                  ),
                ),
                title: Text(
                  '${m.name ?? m.subjectId}'
                  '${m.kind != 'user' ? '(${m.kind == 'group' ? '群组' : '部门'})' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w500),
                ),
                subtitle: Wrap(
                  spacing: 6,
                  children: [
                    for (final role in [
                      ...kProjectRoles.where(m.roles.contains),
                    ])
                      ActionChip(
                        label: Text('${kRoleLabels[role] ?? role} ×',
                            style: const TextStyle(fontSize: 11)),
                        visualDensity: VisualDensity.compact,
                        tooltip: '点击撤销该角色',
                        onPressed: () => _removeRole(m, role),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.title, required this.hint});

  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600)),
            Text(hint,
                style: const TextStyle(fontSize: 11, color: Tk.subtle)),
          ]),
    );
  }
}
