/// PickerSheet — 通用单选弹层选择器(app-polish-2 I1,#6 表单下拉不友好:
/// 「点击后弹层选择,支持搜索」):SheetScaffold 骨架 + 顶部 SearchField 过滤
/// (labelOf 包含匹配,不分大小写)+ 单选列表(当前项高亮 accent + 对勾),
/// 点选即返回。参照 user_picker/subject_picker 既有形态。
///
/// 可空项语义(I2「不使用模板」null 项):T 为可空类型时,「选中 null 项」与
/// 「取消弹层」都返回 null,调用方无法区分 → 用 [PickerOption] 把 null 项包成
/// 非空选项对象(选中 = 返回非 null 的 option、其 value 为 null;取消 = 整体
/// 返回 null)。
/// [PickerField] 是表单内下拉的替代形态(I2):只读展示字段(已选值 + chevron),
/// 点击弹 [showPickerSheet]。
library;

import 'package:flutter/material.dart';

import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../search_field.dart';
import '../sheet_scaffold.dart';

/// 打开通用单选弹层:点选条目即关闭并返回该条目;取消(关闭钮/遮罩/返回键)
/// 返回 null。T 为非空类型(String/Project 等)时条目值即返回值;T 含 null 项
/// 时请改用 `showPickerSheet<PickerOption<...>>`(见库头注释)。
Future<T?> showPickerSheet<T>({
  required BuildContext context,
  required String title,
  required List<T> items,
  T? initial,
  required String Function(T) labelOf,
  bool searchable = true,
  String? searchTextHint,
}) {
  return showAppSheet<T>(
    context: context,
    title: title,
    child: _PickerSheetBody<T>(
      items: items,
      initial: initial,
      labelOf: labelOf,
      searchable: searchable,
      searchTextHint: searchTextHint,
    ),
  );
}

/// 可空项包装(T 实际为可空类型时,区分「选中 null 项」与「取消弹层」;
/// 语义见库头注释)。
class PickerOption<T> {
  const PickerOption(this.value);

  final T? value;

  @override
  bool operator ==(Object other) =>
      other is PickerOption<T> && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

class _PickerSheetBody<T> extends StatefulWidget {
  const _PickerSheetBody({
    required this.items,
    required this.labelOf,
    this.initial,
    this.searchable = true,
    this.searchTextHint,
  });

  final List<T> items;
  final T? initial;
  final String Function(T) labelOf;
  final bool searchable;
  final String? searchTextHint;

  @override
  State<_PickerSheetBody<T>> createState() => _PickerSheetBodyState<T>();
}

class _PickerSheetBodyState<T> extends State<_PickerSheetBody<T>> {
  var _query = '';

  /// labelOf 包含匹配,不分大小写(I1 口径)。
  List<T> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.items;
    return <T>[
      for (final item in widget.items)
        if (widget.labelOf(item).toLowerCase().contains(q)) item,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final filtered = _filtered;
    // 列表自封顶内滚(搜索框恒在顶):高度余量交给 SheetScaffold 的 maxHeight
    // 收口,不与外层滚动区叠加;小屏降到底线 160,大屏封顶 420
    final listMax = (MediaQuery.sizeOf(context).height * 0.45).clamp(
      160.0,
      420.0,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.searchable)
          Padding(
            padding: const EdgeInsets.only(bottom: Tk.spaceSm),
            child: SearchField(
              hintText: widget.searchTextHint ?? '搜索…',
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
        Container(
          constraints: BoxConstraints(maxHeight: listMax),
          decoration: BoxDecoration(
            border: Border.all(color: tk.line),
            borderRadius: BorderRadius.circular(Tk.rSm),
          ),
          child: filtered.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(Tk.spaceMd),
                  child: Center(
                    child: Text(
                      '无匹配',
                      style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
                    ),
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: filtered.length,
                  itemBuilder: (context, i) {
                    final item = filtered[i];
                    final selected = item == widget.initial;
                    return ListTile(
                      dense: true,
                      selected: selected,
                      selectedTileColor: tk.goldSoft,
                      title: Text(
                        widget.labelOf(item),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: Tk.fzRowTitle,
                          // 当前项高亮(金浅底 + 金字)+ 对勾(I1)
                          color: selected ? tk.goldInk : tk.ink,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                      ),
                      trailing: selected
                          ? Icon(Icons.check, size: 18, color: tk.gold)
                          : null,
                      // 点选即返回(I1:确认即选即关)
                      onTap: () => Navigator.of(context).pop(item),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// 表单内下拉的替代形态(I2):只读展示字段——已选值 + dropdown 箭头图标
/// (TextField readOnly 同款外框),点击经 [onTap] 弹 [showPickerSheet]。
/// [value] 为 null/空时显示 [hint](原下拉 hint 语义)。
class PickerField extends StatefulWidget {
  const PickerField({
    super.key,
    this.label,
    required this.value,
    this.hint,
    required this.onTap,
  });

  /// 浮动标签(筛选栏带 label 形态;null = 不渲染,表单区已有分节标题)。
  final String? label;

  /// 当前已选展示文案;null/空 → 显示 [hint]。
  final String? value;
  final String? hint;
  final VoidCallback onTap;

  @override
  State<PickerField> createState() => _PickerFieldState();
}

class _PickerFieldState extends State<PickerField> {
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant PickerField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) _sync();
  }

  void _sync() {
    final v = widget.value ?? '';
    if (_controller.text != v) _controller.text = v;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return TextField(
      controller: _controller,
      readOnly: true,
      onTap: widget.onTap,
      style: TextStyle(fontSize: Tk.fzBody, color: tk.ink),
      decoration: InputDecoration(
        // app-polish-3 D6:isDense 在 filled+outline 组合下压缩竖向内边距,
        // 浮起 label 上半截被 InputDecorator 裁掉 → 去 isDense,显式内边距
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Tk.spaceMd,
          vertical: Tk.spaceMd,
        ),
        labelText: widget.label,
        hintText: widget.hint,
        border: const OutlineInputBorder(),
        suffixIcon: Icon(Icons.expand_more, size: 20, color: tk.ink3),
      ),
    );
  }
}
