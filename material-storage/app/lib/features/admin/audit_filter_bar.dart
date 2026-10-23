/// 审计筛选栏拆件(自 admin_audit_page.dart 抽出):
/// 事件类型/项目/操作者(UserPicker 单选)/单日时间四项筛选,卡片化承载;
/// 受控无状态——筛选值由页面持有,变更回调页面 setState + reload。
/// app-polish-2 I2(#6):事件类型/项目两处下拉改「只读字段+弹层选择器」
/// (PickerField + showPickerSheet,支持搜索);回调与数据流不变——值恒为
/// raw token/项目 id,'' = 全部。
/// app-polish-3 E4/D5:操作者也改 UserPickerField 弹层形态(点按弹层选人),
/// 并提供清除钮(allowClear)——清除 = onChanged([]) = 回「全部操作者」,
/// 对齐 web AuditPage 语义。
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_chip.dart';
import '../../widgets/pickers/picker_sheet.dart';
import '../../widgets/pickers/user_picker_field.dart';
import 'audit_labels.dart';

/// 快捷筛选 chip(全部/下载/上传/分享)。后端 event_type 为精确匹配,
/// 「分享」取 share_link_created 为代表值;细分类型仍走筛选卡。
const kAuditQuickFilters = <(String, String)>[
  ('', '全部'),
  ('download', '下载'),
  ('upload', '上传'),
  ('share_link_created', '分享'),
];

/// 快捷 chip 横轨(受控:value = 当前 eventType)。
class AuditQuickChips extends StatelessWidget {
  const AuditQuickChips({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(
          Tk.spacePage,
          Tk.spaceSm,
          Tk.spacePage,
          0,
        ),
        children: [
          for (final (key, label) in kAuditQuickFilters)
            Padding(
              padding: const EdgeInsets.only(right: Tk.spaceSm),
              child: AppChip(
                label: label,
                selected: value == key,
                onTap: () => onChanged(key),
              ),
            ),
        ],
      ),
    );
  }
}

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
    // 项目 id → 展示文案(名(code));字段关闭态与弹层行共用一份
    final projectLabels = {
      for (final p in projects) p.id: '${p.name}(${p.code})',
    };
    return AppCard(
      margin: const EdgeInsets.fromLTRB(
        Tk.spacePage,
        Tk.spaceSm,
        Tk.spacePage,
        0,
      ),
      padding: const EdgeInsets.all(Tk.spaceMd),
      child: Column(
        children: [
          PickerField(
            label: '事件类型',
            value: eventType.isEmpty ? '— 全部 —' : auditEventLabel(eventType),
            onTap: () => _pickEventType(context),
          ),
          const SizedBox(height: Tk.spaceSm),
          PickerField(
            label: '按项目筛选(可选)',
            value: projectId.isEmpty
                ? '全部项目'
                : (projectLabels[projectId] ?? projectId),
            onTap: () => _pickProject(context, projectLabels),
          ),
          const SizedBox(height: Tk.spaceSm),
          UserPickerField(
            value: [?actor],
            multiple: false,
            label: '按操作者筛选(可选)',
            hint: '全部操作者',
            allowClear: true,
            onChanged: onActorChanged,
          ),
          const SizedBox(height: Tk.spaceSm),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.date_range, size: 18),
                  label: Text(
                    day == null
                        ? '按日期筛选(可选)'
                        : '${day!.year}-${day!.month.toString().padLeft(2, '0')}-'
                              '${day!.day.toString().padLeft(2, '0')}',
                  ),
                  onPressed: onPickDate,
                ),
              ),
              if (day != null)
                IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  tooltip: '清除日期',
                  onPressed: onClearDate,
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 事件类型弹层:kAuditEventTypes 全集,value 恒为 raw token(数据流不变,
  /// F7),文案走中文映射、缺 key 回落原文;'' = 全部。
  Future<void> _pickEventType(BuildContext context) async {
    final v = await showPickerSheet<String>(
      context: context,
      title: '事件类型',
      items: kAuditEventTypes,
      initial: eventType,
      labelOf: (t) => t.isEmpty ? '— 全部 —' : auditEventLabel(t),
      searchTextHint: '搜索事件类型…',
    );
    if (v == null) return; // 取消 = 维持现状
    onEventTypeChanged(v);
  }

  /// 项目弹层:首位 '' = 全部项目(与事件类型「— 全部 —」文案区分,F7 验收
  /// 钉 exactly-one '— 全部 —');value 恒为项目 id/''。
  Future<void> _pickProject(
    BuildContext context,
    Map<String, String> labels,
  ) async {
    final v = await showPickerSheet<String>(
      context: context,
      title: '按项目筛选',
      items: <String>['', for (final p in projects) p.id],
      initial: projectId,
      labelOf: (id) => id.isEmpty ? '全部项目' : (labels[id] ?? id),
      searchTextHint: '搜索项目…',
    );
    if (v == null) return; // 取消 = 维持现状
    onProjectChanged(v);
  }
}
