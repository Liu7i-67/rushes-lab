/// MemberAddForm — 项目加成员表单(B6;自 project_members_sheet.dart 拆分;
/// 2026-10 墨金重做):SubjectPicker(用户/组)+ RoleChips(默认「查看」),
/// 逐主体 POST members;成功失效 projects scope 并回调刷新列表。
/// 版式=分组标签 13/ink3 + chips + 吸底「返回(ghost)/添加(金)」。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/pickers/subject_picker.dart';
import '../../widgets/role_chips.dart';
import '../../widgets/toast.dart';

/// 邀请表单:SubjectPicker + RoleChips(默认「查看」),逐主体 POST members。
class MemberAddForm extends StatefulWidget {
  const MemberAddForm({super.key, required this.project, required this.onDone});

  final Project project;
  final VoidCallback onDone;

  @override
  State<MemberAddForm> createState() => _MemberAddFormState();
}

class _MemberAddFormState extends State<MemberAddForm> {
  var _subjects = const <Subject>[];
  var _roles = <String>{'viewer'};
  var _submitting = false;
  String? _error;

  Future<void> _submit() async {
    if (_subjects.isEmpty) {
      setState(() => _error = '请选至少一个主体');
      return;
    }
    if (_roles.isEmpty) {
      setState(() => _error = '请至少勾选一个角色');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final roles = [
      for (final r in kProjectRoles)
        if (_roles.contains(r)) r,
    ];
    var ok = 0;
    var fail = 0;
    String? firstError;
    for (final s in _subjects) {
      try {
        await session.api!.projectsOps.addMember(
          widget.project.id,
          userId: s.kind == SubjectKind.user ? s.id : null,
          groupId: s.kind == SubjectKind.group ? s.id : null,
          roles: roles,
        );
        ok++;
      } catch (e) {
        fail++;
        // E14:错误中文兜底(勿 '$e' 原始异常直出)
        firstError ??= '${s.name}: ${errorMessage(e, '添加失败')}';
      }
    }
    if (!mounted) return;
    setState(() => _submitting = false);
    if (ok > 0) {
      RefreshBus.I.invalidate('projects');
      toast(
        context,
        '已为 $ok 个主体授予「${joinedRoleLabels(roles)}」${fail > 0 ? ' · 失败 $fail' : ''}',
        tone: fail > 0 ? ToastTone.info : ToastTone.success,
      );
      widget.onDone();
      return;
    }
    setState(() => _error = firstError ?? '添加失败');
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.project.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: Tk.fzMd,
            fontWeight: FontWeight.w600,
            color: tk.ink3,
          ),
        ),
        const SizedBox(height: Tk.spaceLg),
        _GroupLabel('添加主体(用户 / 用户组)'),
        const SizedBox(height: Tk.spaceSm),
        SubjectPicker(
          value: _subjects,
          onChanged: (v) => setState(() {
            _subjects = v;
            _error = null;
          }),
          preset: mePreset(),
        ),
        const SizedBox(height: Tk.spaceLg),
        _GroupLabel('角色(可多选,一次授予)'),
        const SizedBox(height: Tk.spaceSm),
        RoleChips(value: _roles, onChanged: (v) => setState(() => _roles = v)),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: Tk.spaceSm),
            child: Text(
              _error!,
              style: TextStyle(fontSize: Tk.fzMd, color: tk.danger),
            ),
          ),
        const SizedBox(height: Tk.spaceXl),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _submitting ? null : widget.onDone,
                child: const Text('返回'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: PrimaryXl(
                onPressed: _submitting ? null : _submit,
                label: _submitting ? '添加中…' : '添加',
              ),
            ),
          ],
        ),
        const SizedBox(height: Tk.spaceSm),
      ],
    );
  }
}

/// 分组标签(13/600/ink3;与新建项目表单同语言)。
class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: Tk.fzMd,
        fontWeight: FontWeight.w600,
        color: context.tk.ink3,
      ),
    );
  }
}
