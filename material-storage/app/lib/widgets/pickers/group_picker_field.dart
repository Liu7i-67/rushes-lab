/// GroupPickerField — 用户组选择只读字段(app-polish-3 C3):形态同
/// [UserPickerField],固定多选;值域为 [DirectoryGroup](目录域组行,需保留
/// 五组级 flag)。弹层内部用 GroupBrief(searchGroups 契约):出参转 brief 时
/// memberCount 直传;结果回来按 id 回填 name/人数到原对象(其余字段原样保留),
/// 新选组按搜索结果新建。展示:1 组显示组名,多组「N 组」,空显示 hint。
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import 'picker_sheet.dart';
import 'remote_picker_sheet.dart';

/// 用户组选择字段(固定多选;value = DirectoryGroup 列表)。
class GroupPickerField extends StatelessWidget {
  const GroupPickerField({
    super.key,
    required this.value,
    required this.onChanged,
    this.label,
    this.hint = '选择用户组',
    this.allowClear = true,
  });

  final List<DirectoryGroup> value;
  final ValueChanged<List<DirectoryGroup>> onChanged;
  final String? label;
  final String hint;

  /// 有值时是否提供清除钮(清除 = onChanged([]))。
  final bool allowClear;

  Future<void> _pick(BuildContext context) async {
    final picked = await showGroupPickerSheet(
      context: context,
      initial: [
        for (final g in value)
          GroupBrief(id: g.id, name: g.name, memberCount: g.memberCount),
      ],
      multiple: true,
    );
    if (picked == null) return; // 取消不动现值
    final byId = {for (final g in value) g.id: g};
    onChanged([
      for (final b in picked)
        byId.containsKey(b.id) ? _merge(byId[b.id]!, b) : _fromBrief(b),
    ]);
  }

  /// 原 flag/createdAt 保留,name/人数以搜索结果为准(回填)。
  static DirectoryGroup _merge(DirectoryGroup g, GroupBrief b) =>
      DirectoryGroup(
        id: g.id,
        name: b.name,
        description: b.description ?? g.description,
        memberCount: b.memberCount ?? g.memberCount,
        createdAt: g.createdAt,
        canCreateProject: g.canCreateProject,
        canDeleteProject: g.canDeleteProject,
        canManageFolderTemplates: g.canManageFolderTemplates,
        canCreateArtistAccount: g.canCreateArtistAccount,
        canDeleteFiles: g.canDeleteFiles,
      );

  /// 新选组(DirectoryGroup.memberCount 非 null,缺省 0;createdAt 未知留空)。
  static DirectoryGroup _fromBrief(GroupBrief b) => DirectoryGroup(
    id: b.id,
    name: b.name,
    description: b.description,
    memberCount: b.memberCount ?? 0,
    createdAt: '',
  );

  /// 展示文案:单组显示组名(name 空回退短 id),多组「N 组」。
  String get _display {
    if (value.length > 1) return '${value.length} 组';
    final g = value.first;
    if (g.name.isNotEmpty) return g.name;
    return g.id.length > 12 ? '${g.id.substring(0, 12)}…' : g.id;
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    if (value.isEmpty) {
      return PickerField(
        label: label,
        value: null,
        hint: hint,
        onTap: () => _pick(context),
      );
    }
    return InkWell(
      onTap: () => _pick(context),
      child: InputDecorator(
        isEmpty: false, // 有值 → label 恒浮起,不遮展示文案
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
          // 去 isDense(D6 同口径):filled+outline 下浮起 label 上半截会被裁
          contentPadding: const EdgeInsets.symmetric(
            horizontal: Tk.spaceMd,
            vertical: Tk.spaceMd,
          ),
          suffixIcon: allowClear
              ? IconButton(
                  icon: Icon(Icons.clear, size: 18, color: tk.ink3),
                  tooltip: '清除',
                  onPressed: () => onChanged(const []),
                )
              : Icon(Icons.expand_more, size: 20, color: tk.ink3),
        ),
        child: Text(
          _display,
          style: TextStyle(fontSize: Tk.fzBody, color: tk.ink),
        ),
      ),
    );
  }
}
