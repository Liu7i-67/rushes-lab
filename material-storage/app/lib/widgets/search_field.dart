/// SearchField — 统一搜索框(app-polish A7,方案 §A7):替代 7 处复制的
/// 搜索输入。46 高(isDense + 垂直 11 + 主题描边),填充/描边/聚焦金边全部
/// 走主题 inputDecorationTheme(`bg` 填充、`controlBorder` 描边、`gold` 聚焦);
/// prefixIcon 搜索图标 + 有文字时显示清除钮;onSubmitted + onChanged 双
/// 通道透传;controller 可注入(搜索页自持)或缺省自建。
library;

import 'package:flutter/material.dart';

import '../theme/context_tk.dart';

class SearchField extends StatefulWidget {
  const SearchField({
    super.key,
    this.controller,
    this.hintText = '搜索…',
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.textInputAction = TextInputAction.search,
  });

  /// 外部自持时注入;缺省组件自建(仅组件内消费,无需 dispose 外部传入的)。
  final TextEditingController? controller;

  final String? hintText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final TextInputAction textInputAction;

  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  TextEditingController? _own;

  TextEditingController get _c =>
      widget.controller ?? (_own ??= TextEditingController());

  bool get _hasText => _c.text.isNotEmpty;

  @override
  void initState() {
    super.initState();
    // 外部注入的 controller 也可能带初始值,监听以同步清除钮可见性
    widget.controller?.addListener(_sync);
  }

  @override
  void didUpdateWidget(covariant SearchField old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller?.removeListener(_sync);
      widget.controller?.addListener(_sync);
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_sync);
    _own?.dispose();
    super.dispose();
  }

  void _sync() {
    if (mounted) setState(() {});
  }

  void _clear() {
    _c.clear();
    widget.onChanged?.call('');
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return TextField(
      controller: _c,
      autofocus: widget.autofocus,
      textInputAction: widget.textInputAction,
      // 填充/描边/圆角/聚焦金边走主题;此处只补 46 高的密集排布
      // (isDense:true 不会裁切——搜索框无浮起 label)。
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 11,
        ),
        hintText: widget.hintText,
        prefixIcon: Icon(Icons.search, size: 20, color: tk.ink3),
        suffixIcon: _hasText
            ? IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.clear, size: 18, color: tk.ink3),
                tooltip: '清除',
                onPressed: _clear,
              )
            : null,
        // border 不设:圆角/填充/描边全部由主题输入档提供,
        // 组件内覆盖会以默认 4px 半径压掉主题圆角。
      ),
      onChanged: (v) {
        _sync(); // 自建 controller 无外部监听者,重建刷新清除钮可见性
        widget.onChanged?.call(v);
      },
      onSubmitted: widget.onSubmitted,
    );
  }
}
