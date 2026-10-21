/// 权限模板表单条目行拆件(自 grant_template_form_sheet.dart 抽出,行为零变化):
/// 单条授权行 = 主体名(群组/用户)+ 已删主体 amber 标记 + 移除按钮 + RoleChips;
/// 容器/文案/交互与原内联版逐行一致,行数据与回调由表单页持有。
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/role_chips.dart';

/// 表单内单条授权行数据(主体 + 已勾角色;key=kind:id 去重标识)。
class GrantRow {
  GrantRow({
    required this.key,
    required this.kind,
    required this.id,
    required this.roles,
    this.name,
    this.missing = false,
  });

  /// missing 透传(P2-3):主体已删行渲染 amber「已删除」标记(web 同款),
  /// 保存会被建项目/模板主体存在性校验 400 拦下,行上先显式提示。
  factory GrantRow.fromItem(GrantTemplateItem it) => GrantRow(
        key: '${it.kind}:${it.id}',
        kind: it.kind,
        id: it.id,
        name: it.name,
        roles: {...it.roles},
        missing: it.missing,
      );

  final String key;
  final String kind; // user / group
  final String id;
  final String? name;
  final bool missing;
  Set<String> roles;
}

/// 单条授权行渲染(受控无状态;删除/改角色均回调表单页 setState)。
class GrantTemplateRow extends StatelessWidget {
  const GrantTemplateRow({
    super.key,
    required this.row,
    required this.onDelete,
    required this.onRolesChanged,
  });

  final GrantRow row;
  final VoidCallback onDelete;
  final ValueChanged<Set<String>> onRolesChanged;

  @override
  Widget build(BuildContext context) {
    final r = row;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Tk.fill,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(
                '${r.name?.isNotEmpty == true ? r.name : r.id}'
                '${r.kind == 'group' ? '(群组)' : '(用户)'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ),
            // 已删主体 amber 标记(P2-3;web TemplateFormModal
            // 「已删除」pill + tooltip 同语义,移动端以文案呈现)
            if (r.missing)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Text('已删除',
                    style: TextStyle(
                        fontSize: 10.5,
                        letterSpacing: 0.4,
                        color: Tk.amber)),
              ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: onDelete,
            ),
          ]),
          if (r.missing)
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text('该主体已被删除,保存前请移除此行或替换主体',
                  style: TextStyle(fontSize: 10.5, color: Tk.amber)),
            ),
          RoleChips(
            value: r.roles,
            onChanged: onRolesChanged,
          ),
        ],
      ),
    );
  }
}
