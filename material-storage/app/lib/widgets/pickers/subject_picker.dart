/// SubjectPicker — 统一选择权限主体(B6 §9;web SubjectPicker 移动版):
/// app-polish-3 D1 起改为「已选汇总 + 弹层添加」形态——内联用户/用户组
/// 常驻列表下线,点「添加用户 / 用户组」弹 [showSubjectPickerSheet]
/// (搜索、双段切换、勾选、完成回填都在弹层内)。对外 API(Subject /
/// SubjectKind / mePreset / SubjectPicker 的 value/onChanged/preset)不变,
/// 调用点零改动。#154 部门轴下线,仅剩 user / group 两类。主体语义:
/// user → {user_id},group → {group_id}。
library;

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import 'subject_picker_sheet.dart';

enum SubjectKind { user, group }

/// 权限主体(kind+id;name 仅供回显)。
class Subject {
  const Subject({required this.kind, required this.id, required this.name});

  final SubjectKind kind;
  final String id; // users.id / groups.id UUID
  final String name;

  @override
  bool operator ==(Object other) =>
      other is Subject && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

/// me → 预置候选(web preset 同语义;null 安全由调用方保证已登录)。
List<UserBrief> mePreset() {
  final me = session.me;
  return [
    if (me != null)
      UserBrief(id: me.id, name: '${me.name}(自己)'),
  ];
}

class SubjectPicker extends StatefulWidget {
  const SubjectPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.preset,
  });

  final List<Subject> value;
  final ValueChanged<List<Subject>> onChanged;

  /// 弹层用户段空 query 预置候选(通常 = 自己)。
  final List<UserBrief>? preset;

  @override
  State<SubjectPicker> createState() => _SubjectPickerState();
}

class _SubjectPickerState extends State<SubjectPicker> {
  Future<void> _add() async {
    final next = await showSubjectPickerSheet(
      context: context,
      initial: widget.value,
      preset: widget.preset,
    );
    if (next != null) widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SelectedSummary(
          value: widget.value,
          onRemove: (s) =>
              widget.onChanged(widget.value.where((x) => x != s).toList()),
        ),
        const SizedBox(height: Tk.spaceSm),
        OutlinedButton.icon(
          onPressed: _add,
          icon: const Icon(Icons.add),
          label: const Text('添加用户 / 用户组'),
        ),
      ],
    );
  }
}

/// id 缩略(短 id 防越界;web `id.slice(0,n)+'…'` 同义)。
String _shortId(String id, int n) =>
    id.length > n ? '${id.substring(0, n)}…' : id;

/// 已选汇总(空 → 灰字「尚未添加主体」;web _SelectedSummary 同语义):
/// 👤/🏷 前缀 + 可删 chip。
class _SelectedSummary extends StatelessWidget {
  const _SelectedSummary({required this.value, required this.onRemove});

  final List<Subject> value;
  final ValueChanged<Subject> onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Tk.spaceSm),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Tk.rSm),
      ),
      child: value.isEmpty
          ? const Text('尚未添加主体',
              style: TextStyle(fontSize: Tk.fzSm, color: Tk.muted))
          : Wrap(
              spacing: Tk.spaceSm, // 6→spaceSm(A2 就近归档)
              runSpacing: Tk.spaceXs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('已选 ${value.length} 项:',
                    style: const TextStyle(fontSize: Tk.fzXs)),
                for (final s in value)
                  InputChip(
                    label: Text(
                      '${s.kind == SubjectKind.user ? '👤' : '🏷'} '
                      '${s.name.isEmpty ? _shortId(s.id, 12) : s.name}',
                      style: const TextStyle(fontSize: Tk.fzXs),
                    ),
                    visualDensity: VisualDensity.compact,
                    onDeleted: () => onRemove(s),
                  ),
              ],
            ),
    );
  }
}
