/// MemberAddForm — 项目加成员表单(B6;自 project_members_sheet.dart 拆分):
/// SubjectPicker(用户/组)+ RoleChips(默认「查看」),逐主体 POST members;
/// 成功失效 projects scope 并回调刷新列表。
library;

import 'package:flutter/material.dart';

import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/pickers/subject_picker.dart';
import '../../widgets/role_chips.dart';

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
    final roles = [for (final r in kProjectRoles) if (_roles.contains(r)) r];
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
        firstError ??= '${s.name}: $e';
      }
    }
    if (!mounted) return;
    setState(() => _submitting = false);
    if (ok > 0) {
      RefreshBus.I.invalidate('projects');
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: Text('已为 $ok 个主体授予'
              '「${joinedRoleLabels(roles)}」${fail > 0 ? ' · 失败 $fail' : ''}')));
      widget.onDone();
      return;
    }
    setState(() => _error = firstError ?? '添加失败');
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('添加成员 → ${widget.project.name}',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            const Text('添加主体(用户 / 用户组)',
                style: TextStyle(fontSize: 12, color: Tk.muted)),
            SubjectPicker(
              value: _subjects,
              onChanged: (v) => setState(() {
                _subjects = v;
                _error = null;
              }),
              preset: mePreset(),
            ),
            const SizedBox(height: 12),
            const Text('角色(可多选,一次授予)',
                style: TextStyle(fontSize: 12, color: Tk.muted)),
            RoleChips(
                value: _roles,
                onChanged: (v) => setState(() => _roles = v)),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12.5)),
              ),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _submitting ? null : widget.onDone,
                  child: const Text('返回'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _submitting ? null : _submit,
                  child: Text(_submitting ? '添加中…' : '添加'),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
