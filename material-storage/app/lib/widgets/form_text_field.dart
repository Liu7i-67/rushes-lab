/// AppTextField — 统一表单文本字段(app-polish-3 E1/D6):新建项目/艺人账号
/// 等表单的文本输入统一走此组件,内部 TextFormField。
///
/// D6(浮起 label 裁切根因):`isDense: true` + 主题 `filled: true`
/// (app_theme.dart inputDecorationTheme)+ `OutlineInputBorder` 组合下,
/// dense 会把竖向 contentPadding 压到最小,浮起 label 的上半截被
/// InputDecorator 裁掉(真机 0.1.2+6「MinIO bucket(必填)」只显示下半截)。
/// 故此处显式 `isDense: false`(不用 isCollapsed),contentPadding 统一
/// 12/12;border/填充/聚焦金边/错误色全部由主题 InputDecorationTheme 给,
/// 后续新增表单字段一律复用本组件,不再各自手写 decoration。
library;

import 'package:flutter/material.dart';

/// 表单文本字段(label 浮起;controller 与 initialValue 二选一)。
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    this.controller,
    this.initialValue,
    required this.label,
    this.hint,
    this.validator,
    this.maxLength,
    this.keyboardType,
    this.textInputAction,
    this.onChanged,
    this.enabled = true,
    this.obscureText = false,
    this.autofillHints,
    this.errorText,
    this.counterText,
  }) : assert(
         controller == null || initialValue == null,
         'controller 与 initialValue 二选一,不可同时提供',
       );

  final TextEditingController? controller;
  final String? initialValue;
  final String label;
  final String? hint;
  final String? Function(String?)? validator;
  final int? maxLength;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final bool enabled;
  final bool obscureText;
  final Iterable<String>? autofillHints;

  /// 外部受控错误(如艺人登录名冲突预检;表单校验错误请走 validator)。
  final String? errorText;

  /// 计数器文案覆盖('' = 隐藏计数器;缺省显示 Flutter 默认 n/max)。
  final String? counterText;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      initialValue: initialValue,
      validator: validator,
      maxLength: maxLength,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onChanged: onChanged,
      enabled: enabled,
      obscureText: obscureText,
      autofillHints: autofillHints,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        errorText: errorText,
        counterText: counterText,
        // border 交给主题(OutlineInputBorder + rSm + controlBorder)
        border: const OutlineInputBorder(),
        // 显式 isDense: false(D6,见文件头;测试断言依据),不设 isCollapsed
        isDense: false,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
      ),
    );
  }
}
