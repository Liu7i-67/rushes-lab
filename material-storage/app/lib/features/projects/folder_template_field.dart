/// FolderTemplateField — 新建项目目录模板选择(B6;自 new_project_sheet.dart
/// 拆分):拉 GET /admin/folder-templates(失败静默降级为「不使用模板」),
/// 选中提交 folder_template_id,选中后展示路径预览(目录树由后端创建流程建立)。
/// app-polish-2 I2(#6):下拉改「只读字段+弹层选择器」(PickerField +
/// showPickerSheet,可搜索);「不使用模板(默认)」null 项经 PickerOption 包装
/// 保留语义——选中 null 项=回退到不使用,取消弹层=维持现状,两者可区分;
/// 传入 value 不在已加载列表时按未选渲染(无下拉 value 命中断言问题,语义不变)。
library;

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/pickers/picker_sheet.dart';

class FolderTemplateField extends StatefulWidget {
  const FolderTemplateField({
    super.key,
    required this.value,
    required this.onChanged,
  });

  /// 选中模板 id;null = 不使用(不传字段,行为与现状一致)。
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  State<FolderTemplateField> createState() => _FolderTemplateFieldState();
}

class _FolderTemplateFieldState extends State<FolderTemplateField> {
  late final Future<List<FolderTemplate>> _templates = _load();

  Future<List<FolderTemplate>> _load() async {
    try {
      return await session.api!.adminTemplates.folderTemplates();
    } catch (_) {
      return const []; // 403/网络失败 → 静默降级(web 同口径)
    }
  }

  /// 模板展示文案(字段关闭态与弹层行共用;含「不使用模板(默认)」null 项)。
  static String _label(FolderTemplate? t) => t == null
      ? '不使用模板(默认)'
      : '${t.name}(${t.entryCount} 个目录)';

  /// 弹层选择(I2):null 项经 PickerOption 包装——选中它返回非 null option
  /// (value=null → 回退),取消返回 null(维持现状),语义与原下拉完全一致。
  Future<void> _pick(BuildContext context, List<FolderTemplate> templates) async {
    FolderTemplate? selected;
    for (final t in templates) {
      if (t.id == widget.value) selected = t;
    }
    final picked = await showPickerSheet<PickerOption<FolderTemplate>>(
      context: context,
      title: '目录模板',
      items: [
        const PickerOption<FolderTemplate>(null),
        for (final t in templates) PickerOption<FolderTemplate>(t),
      ],
      initial: PickerOption<FolderTemplate>(selected),
      labelOf: (o) => _label(o.value),
      searchTextHint: '搜索模板…',
    );
    if (picked == null || !mounted) return; // 取消 = 维持现状
    widget.onChanged(picked.value?.id);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<FolderTemplate>>(
      future: _templates,
      builder: (context, snap) {
        final templates = snap.data ?? const <FolderTemplate>[];
        FolderTemplate? selected;
        for (final t in templates) {
          if (t.id == widget.value) selected = t;
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PickerField(
              value: selected == null ? null : _label(selected),
              hint: '不使用模板(默认)',
              onTap: () => _pick(context, templates),
            ),
            if (selected != null)
              Container(
                margin: const EdgeInsets.only(top: Tk.spaceSm - 2),
                padding: const EdgeInsets.all(10),
                constraints: const BoxConstraints(maxHeight: 140),
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Tk.surface2,
                  borderRadius: BorderRadius.circular(Tk.rSm),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    '目录树预览:${selected.entries.map((e) => e.path).join('\n')}',
                    style: const TextStyle(fontSize: Tk.fzXs, color: Tk.muted),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
