/// Buttons — 按钮变体工具(app-polish A10):DangerButton=FilledButton 红色
/// 变体(危险确认,收敛 3+ 处 `FilledButton.styleFrom(foregroundColor: Tk.red)`
/// 复制;红底白字对比达标,前景取 Tk.surface 与主题 onPrimary 同源),
/// PrimaryXl=吸底大按钮(SheetScaffold bottomActions 主操作,通栏加高)。
library;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// 危险按钮统一样式(AlertDialog 内联按钮也可直接取用,免再 styleFrom)。
ButtonStyle dangerButtonStyle() => FilledButton.styleFrom(
      backgroundColor: Tk.red,
      foregroundColor: Tk.surface, // on-red 白,与主题 onPrimary 同源
    );

class DangerButton extends StatelessWidget {
  const DangerButton({
    super.key,
    this.onPressed,
    required this.label,
    this.icon,
  });

  final VoidCallback? onPressed;
  final String label;

  /// 可选前导图标(删除/撤销类动作用)。
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    if (icon != null) {
      return FilledButton.icon(
        style: dangerButtonStyle(),
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(label),
      );
    }
    return FilledButton(
      style: dangerButtonStyle(),
      onPressed: onPressed,
      child: Text(label),
    );
  }
}

/// 吸底主操作大按钮(通栏加高;SheetScaffold bottomActions/表单提交位用)。
class PrimaryXl extends StatelessWidget {
  const PrimaryXl({
    super.key,
    this.onPressed,
    required this.label,
    this.icon,
  });

  final VoidCallback? onPressed;
  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    // 通栏:外层多在 Row>Expanded 里,SizedBox 保证单独使用时也占满;
    // 加高至 48 触控达标,主文案加粗
    final style = FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(48),
      textStyle:
          const TextStyle(fontSize: Tk.fzBody, fontWeight: FontWeight.w600),
    );
    if (icon != null) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          style: style,
          onPressed: onPressed,
          icon: Icon(icon),
          label: Text(label),
        ),
      );
    }
    return SizedBox(
      width: double.infinity,
      child: FilledButton(style: style, onPressed: onPressed, child: Text(label)),
    );
  }
}
