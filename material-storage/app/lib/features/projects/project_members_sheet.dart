/// ProjectMembersSheet — 项目成员管理(B6 §8.5;web ProjectMembersDrawer 移动
/// 版):直接成员(角色徽章,admin 自撤/末位 admin 409 detail 透传)+
/// 授权总览(#138 审批/邀请 grant,四元组撤回)+ 邀请表单(SubjectPicker +
/// RoleChips,一次授多角色)。入口=项目行「成员」(仅 my_roles 含 admin 显示;
/// 后端 can_admin 兜底)。
/// app-polish E13:「点角色徽标撤销」改显式移除图标钮(InputChip onDeleted,
/// 语义 icon person_remove)→ showAppConfirm(danger) 确认后再撤销;
/// 错误收口 toast+errorMessage;骨架迁移 SheetScaffold+吸底主操作。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart' show errorMessage;
import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import 'member_add_form.dart';
import 'project_grants_overview.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_confirm.dart';
import '../../widgets/buttons.dart';
import '../../widgets/role_chips.dart';
import '../../widgets/sheet_scaffold.dart';
import '../../widgets/toast.dart';

/// 打开项目成员管理面板(对外 API 不变)。
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
    // E13:显式移除钮 → showAppConfirm 危险态确认(替代点徽标直弹确认)
    final ok = await showAppConfirm(
      context,
      title: '撤销「${m.name ?? m.subjectId}」的$label角色?',
      confirmLabel: '撤销',
      danger: true,
    );
    if (ok != true) return;
    try {
      await session.api!.projectsOps
          .removeMember(widget.project.id, subject: m.subject, role: role);
      RefreshBus.I.invalidate('projects');
      _reload();
    } catch (e) {
      if (!mounted) return;
      toast(context, '撤销失败:${errorMessage(e, '请稍后重试')}',
          tone: ToastTone.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SheetScaffold(
      title: '成员 · ${widget.project.name}',
      maxHeightFactor: 0.8,
      bottomActions: _showForm
          ? const <Widget>[]
          : <Widget>[
              PrimaryXl(
                icon: Icons.person_add_alt_1,
                label: '添加成员',
                onPressed: () => setState(() => _showForm = true),
              ),
            ],
      child: _showForm
          ? MemberAddForm(project: widget.project, onDone: () {
              setState(() {
                _showForm = false; // 成功回成员列表(web onClose 同款)
                _members = _load();
              });
            })
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SectionLabel(
                    title: '直接成员',
                    hint: '项目级角色:管理/上传/下载/查看(点角色旁移除图标撤销)'),
                _memberList(),
                const SizedBox(height: Tk.spaceMd),
                const _SectionLabel(
                    title: '授权总览',
                    hint: '通过审批/邀请获得的授权(含临时与永久),可撤回'),
                ProjectGrantsOverview(project: widget.project),
              ],
            ),
    );
  }

  Widget _memberList() {
    return FutureBuilder<List<ProjectMember>>(
      future: _members,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(Tk.spaceLg),
            child: Text('加载中…',
                style: TextStyle(fontSize: Tk.fzMd, color: Tk.subtle)),
          );
        }
        if (snap.hasError) {
          return Text('加载失败:${errorMessage(snap.error!, '请稍后重试')}',
              style: const TextStyle(fontSize: Tk.fzMd, color: Tk.red));
        }
        final members = snap.data ?? const <ProjectMember>[];
        if (members.isEmpty) {
          return const Text('还没有成员 · 点下方「添加成员」开始',
              style: TextStyle(fontSize: Tk.fzMd, color: Tk.subtle));
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
                        fontSize: Tk.fzXs,
                        color: m.kind == 'user' ? Tk.surface : Tk.muted),
                  ),
                ),
                title: Text(
                  '${m.name ?? m.subjectId}'
                  '${m.kind != 'user' ? '(${m.kind == 'group' ? '群组' : '部门'})' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: Tk.fzMd, fontWeight: FontWeight.w500),
                ),
                subtitle: Wrap(
                  spacing: Tk.spaceSm,
                  children: [
                    for (final role in [
                      ...kProjectRoles.where(m.roles.contains),
                    ])
                      // E13:徽章不再整体可点撤销;行尾显式移除图标钮
                      // (InputChip onDeleted+语义 icon)承接撤销入口
                      InputChip(
                        label: Text(kRoleLabels[role] ?? role,
                            style: const TextStyle(fontSize: Tk.fzXs)),
                        visualDensity: VisualDensity.compact,
                        deleteIcon: const Icon(Icons.person_remove_alt_1,
                            size: 14),
                        deleteButtonTooltipMessage:
                            '移除${kRoleLabels[role] ?? role}角色',
                        onDeleted: () => _removeRole(m, role),
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
      padding: const EdgeInsets.only(top: Tk.spaceXs, bottom: 2),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: Tk.fzMd, fontWeight: FontWeight.w600)),
            Text(hint,
                style: const TextStyle(fontSize: Tk.fzXs, color: Tk.subtle)),
          ]),
    );
  }
}
