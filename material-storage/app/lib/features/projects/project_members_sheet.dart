/// ProjectMembersSheet — 项目成员管理(B6 §8.5;2026-10 墨金重做):直接成员卡
/// (34 金浅底头像 + 角色 Badge + 显式移除钮)+ 授权总览(#138,四元组撤回)+
/// 邀请表单(SubjectPicker + RoleChips)。403 detail 透传不变。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/api/ms_api.dart' show errorMessage;
import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_confirm.dart';
import '../../widgets/badge.dart';
import '../../widgets/buttons.dart';
import '../../widgets/role_chips.dart';
import '../../widgets/sheet_scaffold.dart';
import '../../widgets/toast.dart';
import 'member_add_form.dart';
import 'project_grants_overview.dart';
import 'role_badge.dart' show kRoleMeta;

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
    // E13:显式移除钮 → showAppConfirm 危险态确认
    final ok = await showAppConfirm(
      context,
      title: '撤销「${m.name ?? m.subjectId}」的$label角色?',
      confirmLabel: '撤销',
      danger: true,
    );
    if (ok != true) return;
    try {
      await session.api!.projectsOps.removeMember(
        widget.project.id,
        subject: m.subject,
        role: role,
      );
      RefreshBus.I.invalidate('projects');
      _reload();
    } catch (e) {
      if (!mounted) return;
      toast(context, '撤销失败:${errorMessage(e, '请稍后重试')}', tone: ToastTone.error);
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
          ? MemberAddForm(
              project: widget.project,
              onDone: () {
                setState(() {
                  _showForm = false; // 成功回成员列表(web onClose 同款)
                  _members = _load();
                });
              },
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _header('直接成员', '点角色旁移除图标可撤销该角色'),
                _memberList(),
                const SizedBox(height: Tk.spaceLg),
                _header('授权总览', '审批/邀请获得的授权(含临时与永久),可撤回'),
                AppCard(
                  padding: const EdgeInsets.symmetric(vertical: Tk.spaceXs),
                  child: ProjectGrantsOverview(project: widget.project),
                ),
              ],
            ),
    );
  }

  Widget _memberList() {
    final tk = context.tk;
    return FutureBuilder<List<ProjectMember>>(
      future: _members,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return _Hint('加载中…');
        }
        if (snap.hasError) {
          return Text(
            '加载失败:${errorMessage(snap.error!, '请稍后重试')}',
            style: TextStyle(fontSize: Tk.fzMd, color: tk.danger),
          );
        }
        final members = snap.data ?? const <ProjectMember>[];
        if (members.isEmpty) {
          return const _Hint('还没有成员 · 点下方「添加成员」开始');
        }
        return SectionCard(
          children: [
            for (final m in members)
              _MemberRow(member: m, onRemove: (role) => _removeRole(m, role)),
          ],
        );
      },
    );
  }

  /// 区块标签(13/600/ink2 + hint 11/ink3)。
  Widget _header(String title, String hint) {
    final tk = context.tk;
    return Padding(
      padding: const EdgeInsets.only(top: Tk.spaceXs, bottom: Tk.spaceSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: Tk.fzMd,
              fontWeight: FontWeight.w600,
              color: tk.ink2,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            hint,
            style: TextStyle(fontSize: Tk.fzXs, color: tk.ink3),
          ),
        ],
      ),
    );
  }
}

/// 成员行:34 金浅底头像 + 姓名 15.5 + 来源 13/ink3 + 角色 Badge(各自可撤)。
class _MemberRow extends StatelessWidget {
  const _MemberRow({required this.member, required this.onRemove});

  final ProjectMember member;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final isUser = member.kind == 'user';
    final name = member.name ?? member.subjectId;
    final source = isUser ? '用户' : (member.kind == 'group' ? '群组' : '部门');
    final initial = isUser
        ? (name.isEmpty ? '?' : name.characters.first.toUpperCase())
        : '群';
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isUser ? tk.goldSoft : tk.surface3,
              shape: BoxShape.circle,
            ),
            child: Text(
              initial,
              style: TextStyle(
                fontSize: Tk.fzMd,
                fontWeight: FontWeight.w600,
                color: isUser ? tk.goldInk : tk.ink2,
              ),
            ),
          ),
          const SizedBox(width: Tk.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: Tk.fzRowTitle,
                    fontWeight: FontWeight.w500,
                    color: tk.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$source · 项目成员',
                  style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: Tk.spaceXs,
                  runSpacing: Tk.spaceXs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final role in [
                      ...kProjectRoles.where(member.roles.contains),
                    ])
                      _RoleBadge(role: role, onRemove: () => onRemove(role)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 角色徽标 + 行尾移除钮(徽标本身不可点,避免误触;tooltip 带角色名)。
class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.role, required this.onRemove});

  final String role;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final label = kRoleLabels[role] ?? role;
    final tone = kRoleMeta[role]?.$2 ?? BadgeTone.neutral;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Badge(label: label, tone: tone),
        SizedBox(
          // 44×44 触控目标(F14);视觉图标仍 15
          width: 44,
          height: 44,
          child: IconButton(
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            iconSize: 15,
            tooltip: '移除$label角色',
            icon: Icon(Icons.person_remove_alt_1, color: context.tk.ink3),
            onPressed: onRemove,
          ),
        ),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(fontSize: Tk.fzMd, color: context.tk.ink3),
  );
}
