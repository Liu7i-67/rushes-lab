/// GroupMultiSelect — 所属用户组多选(建用户带组/编辑所属组共用):
/// app-polish-3 D2 起为 [GroupPickerField] 薄包装(「只读字段 + 点按弹层」
/// 形态,弹层内远程搜索、勾选、完成回填)。对外 API(value/onChanged)不变,
/// 两处调用点零改动;原内联「搜索框 + 常驻列表」实现删除。
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../widgets/pickers/group_picker_field.dart';

class GroupMultiSelect extends StatefulWidget {
  const GroupMultiSelect({super.key, required this.value, required this.onChanged});

  final List<DirectoryGroup> value;
  final ValueChanged<List<DirectoryGroup>> onChanged;

  @override
  State<GroupMultiSelect> createState() => _GroupMultiSelectState();
}

class _GroupMultiSelectState extends State<GroupMultiSelect> {
  @override
  Widget build(BuildContext context) {
    return GroupPickerField(
      value: widget.value,
      onChanged: widget.onChanged,
      label: '所属用户组(可多选,可留空)',
      hint: '点击选择所属用户组',
    );
  }
}
