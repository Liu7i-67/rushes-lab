/// FolderTemplateField — 新建项目目录模板选择(B6;自 new_project_sheet.dart
/// 拆分):拉 GET /admin/folder-templates(失败静默降级为「不使用模板」),
/// 选中提交 folder_template_id,选中后展示路径预览(目录树由后端创建流程建立)。
library;

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';

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
        // 传入 value 不在(或尚未在)已加载列表时按未选渲染,避免
        // DropdownButton「value 必须命中 items」断言炸首帧
        final effectiveValue = selected?.id;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: Tk.spaceMd),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(Tk.rSm),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String?>(
                  value: effectiveValue,
                  isExpanded: true,
                  hint: const Text('不使用模板(默认)',
                      style: TextStyle(fontSize: Tk.fzMd)),
                  items: [
                    // P2-3:「不使用模板(默认)」显式项(value=null):选中模板
                    // 后可回退(web 同款;value=null 时按钮显示该项而非 hint,
                    // initial_grants_field 同先例)
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('不使用模板(默认)',
                          style: TextStyle(fontSize: Tk.fzMd)),
                    ),
                    for (final t in templates)
                      DropdownMenuItem(
                        value: t.id,
                        child: Text('${t.name}(${t.entryCount} 个目录)',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: Tk.fzMd)),
                      ),
                  ],
                  onChanged: (v) => widget.onChanged(v),
                ),
              ),
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
