/// PasswordField — 密码输入框复用组件(P9):默认遮挡,suffixIcon 眼睛按钮
/// 切换明文/遮挡;切换只动本组件内聚 state,controller 内容与焦点均不丢。
/// 外观对齐项目现有输入框 InputDecoration(labelText + prefixIcon),颜色走
/// 主题令牌(眼睛图标 ink3);validator/onSubmitted 透传,校验逻辑不变。
library;

import 'package:flutter/material.dart';

import '../theme/context_tk.dart';

class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    this.controller,
    this.labelText,
    this.hintText,
    this.prefixIcon,
    this.validator,
    this.onSubmitted,
    this.autocorrect = false,
    this.obscureText = true,
    this.textInputAction,
    this.autofillHints,
  });

  final TextEditingController? controller;

  /// 字段标题(现有输入框的 labelText 同位)。
  final String? labelText;

  final String? hintText;
  final Widget? prefixIcon;

  /// 校验器透传(现役各页未用 Form,保留能力供后续接入)。
  final String? Function(String?)? validator;

  /// 键盘提交回调透传(登录/改密页提交用)。
  final ValueChanged<String>? onSubmitted;
  final bool autocorrect;

  /// 初始是否遮挡(默认 true;仅供特殊场景显式放开,不改动现役用法)。
  final bool obscureText;

  /// 键盘动作键透传(app-polish E1:登录页密码框 done 提交;缺省系统默认)。
  final TextInputAction? textInputAction;

  /// 自动填充提示透传(app-polish E1;配合页面级 AutofillGroup 使用)。
  final Iterable<String>? autofillHints;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  late bool _obscure = widget.obscureText;

  @override
  Widget build(BuildContext context) {
    // TextFormField:独立使用与 TextField 无异,validator 仅在 Form 内触发,
    // 透传不改变现役两页(无 Form)的校验行为
    return TextFormField(
      controller: widget.controller,
      obscureText: _obscure,
      autocorrect: widget.autocorrect,
      validator: widget.validator,
      onFieldSubmitted: widget.onSubmitted,
      textInputAction: widget.textInputAction,
      autofillHints: widget.autofillHints,
      decoration: InputDecoration(
        labelText: widget.labelText,
        hintText: widget.hintText,
        prefixIcon: widget.prefixIcon,
        // 眼睛切换:遮挡时显示「可见」图标(点击亮文),亮文时显示「不可见」;
        // IconButton 点击不抢焦点,已输入内容在 controller 里不受影响
        suffixIcon: IconButton(
          icon: Icon(
            _obscure
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined,
            color: context.tk.ink3,
          ),
          tooltip: _obscure ? '显示密码' : '隐藏密码',
          onPressed: () => setState(() => _obscure = !_obscure),
        ),
      ),
    );
  }
}
