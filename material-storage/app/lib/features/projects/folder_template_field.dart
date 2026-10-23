/// FolderTemplateField — 新建项目目录模板选择(B6;自 new_project_sheet.dart
/// 拆分;2026-10 墨金重做):拉 GET /admin/folder-templates(失败静默降级为
/// 仅「空目录」),选中提交 folder_template_id;选中后展示路径预览(目录树由
/// 后端创建流程建立)。形态=AppChip 横轨单选:「空目录」=不使用模板(null),
/// 模板项=预填并预览;再次点「空目录」可回退。
library;

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_chip.dart';

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

  /// 模板展示文案(选中态与 chip 共用)。
  static String _label(FolderTemplate t) => '${t.name}(${t.entryCount} 个目录)';

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
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
            // 横轨单选:空目录 + 全部模板(chip 44 高,小屏横向滚动)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  AppChip(
                    label: '空目录',
                    selected: selected == null,
                    onTap: () => widget.onChanged(null),
                  ),
                  for (final t in templates) ...[
                    const SizedBox(width: Tk.spaceSm),
                    AppChip(
                      label: _label(t),
                      selected: selected?.id == t.id,
                      onTap: () => widget.onChanged(t.id),
                    ),
                  ],
                ],
              ),
            ),
            if (selected != null) ...[
              Container(
                margin: const EdgeInsets.only(top: Tk.spaceSm),
                padding: const EdgeInsets.all(Tk.spaceMd),
                constraints: const BoxConstraints(maxHeight: 140),
                width: double.infinity,
                decoration: BoxDecoration(
                  color: tk.surface2,
                  border: Border.all(color: tk.line),
                  borderRadius: BorderRadius.circular(Tk.rSm),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    '目录树预览:${selected.entries.map((e) => e.path).join('\n')}',
                    style: TextStyle(
                      fontSize: Tk.fzXs,
                      height: 1.55,
                      color: tk.ink3,
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
