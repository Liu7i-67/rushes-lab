/// UserPickerField — 用户选择只读字段(app-polish-3 C2):I2「只读字段 +
/// chevron → 点按弹层」形态推广到远程数据源。无值渲染 [PickerField](hint);
/// 有值渲染 InputDecorator 只读字段(单选名/「N 人」)+ 可选清除钮;点按弹
/// [showUserPickerSheet]。受控组件:值完全由外层持有;用 InputDecorator 而非
/// TextField,不持 controller,免只读光标/输入态问题。
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import 'picker_sheet.dart';
import 'remote_picker_sheet.dart';

/// 用户选择字段(value = UserBrief 列表;单选至多 1 个,多选任意)。
class UserPickerField extends StatelessWidget {
  const UserPickerField({
    super.key,
    required this.value,
    required this.onChanged,
    this.multiple = false,
    this.label,
    this.hint = '选择用户',
    this.preset,
    this.allowClear = true,
  });

  final List<UserBrief> value;
  final ValueChanged<List<UserBrief>> onChanged;
  final bool multiple;

  /// 浮动标签(null = 不渲染,表单区已有分节标题)。
  final String? label;
  final String hint;

  /// 空 query 时并入弹层候选的预置项(通常 = 自己)。
  final List<UserBrief>? preset;

  /// 有值时是否提供清除钮(清除 = onChanged([]),对齐 web allowClear 语义)。
  final bool allowClear;

  Future<void> _pick(BuildContext context) async {
    final next = await showUserPickerSheet(
      context: context,
      initial: value,
      multiple: multiple,
      preset: preset,
    );
    if (next != null) onChanged(next); // 取消(null)不动现值
  }

  /// 展示文案:单选取 name(历史数据 name 空回退短 id);多选「N 人」。
  String get _display {
    if (multiple || value.length > 1) return '${value.length} 人';
    final u = value.first;
    if (u.name.isNotEmpty) return u.name;
    return u.id.length > 12 ? '${u.id.substring(0, 12)}…' : u.id;
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    // 无值 → PickerField(hint 语义);有值 → InputDecorator(PickerField 不支持
    // suffix 清除钮,故直接渲染只读装饰;装饰口径与 C5 后的 PickerField 一致)
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
