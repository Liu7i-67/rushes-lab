/// 审计筛选栏拆件(自 admin_audit_page.dart 抽出,行为零变化):
/// 事件类型/项目/操作者(UserPicker 单选)/单日时间四行筛选;
/// 受控无状态——筛选值由页面持有,变更回调页面 setState + reload。
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../widgets/pickers/user_picker.dart';
import 'audit_labels.dart';

/// 审计筛选栏(projectId ''=全部;actor null=全部;day null=不限单日)。
class AuditFilterBar extends StatelessWidget {
  const AuditFilterBar({
    super.key,
    required this.eventType,
    required this.projectId,
    required this.actor,
    required this.day,
    required this.projects,
    required this.onEventTypeChanged,
    required this.onProjectChanged,
    required this.onActorChanged,
    required this.onPickDate,
    required this.onClearDate,
  });

  final String eventType;
  final String projectId;
  final UserBrief? actor;
  final DateTime? day;
  final List<Project> projects;
  final ValueChanged<String> onEventTypeChanged;
  final ValueChanged<String> onProjectChanged;
  final ValueChanged<List<UserBrief>> onActorChanged;
  final VoidCallback onPickDate;
  final VoidCallback onClearDate;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: DropdownButtonFormField<String>(
            initialValue: eventType,
            isDense: true,
            decoration: const InputDecoration(
                labelText: '事件类型', border: OutlineInputBorder()),
            items: [
              for (final t in kAuditEventTypes)
                DropdownMenuItem(
                    value: t,
                    child: Text(t.isEmpty ? '— 全部 —' : t,
                        style: const TextStyle(fontSize: 13))),
            ],
            onChanged: (v) => onEventTypeChanged(v ?? ''),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: DropdownButtonFormField<String>(
            initialValue: projectId.isEmpty ? null : projectId,
            isDense: true,
            decoration: const InputDecoration(
                labelText: '按项目筛选(可选)', border: OutlineInputBorder()),
            items: [
              const DropdownMenuItem(value: null, child: Text('— 全部 —')),
              for (final p in projects)
                DropdownMenuItem(
                    value: p.id,
                    child: Text('${p.name}(${p.code})',
                        style: const TextStyle(fontSize: 13))),
            ],
            onChanged: (v) => onProjectChanged(v ?? ''),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: UserPicker(
            value: [?actor],
            multiple: false,
            hint: '按操作者筛选(单选,可留空)',
            onChanged: onActorChanged,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.date_range, size: 18),
                label: Text(day == null
                    ? '按日期筛选(可选)'
                    : '${day!.year}-${day!.month.toString().padLeft(2, '0')}-'
                        '${day!.day.toString().padLeft(2, '0')}'),
                onPressed: onPickDate,
              ),
            ),
            if (day != null)
              IconButton(
                icon: const Icon(Icons.clear, size: 18),
                tooltip: '清除日期',
                onPressed: onClearDate,
              ),
          ]),
        ),
      ],
    );
  }
}
