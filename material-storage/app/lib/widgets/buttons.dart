/// Buttons — 按钮变体工具(墨色 + 金色语言):
/// DangerButton=FilledButton 危险变体(红底 `dangerFill` + `onDanger` 前景);
/// PrimaryXl=吸底大按钮(金底深墨字,SheetScaffold bottomActions 主操作)。
library;

import 'package:flutter/material.dart';

import '../theme/context_tk.dart';
import '../theme/tokens.dart';

/// 金色主按钮上的深墨字(与 app_theme FilledButton 同值)。
const Color _kOnGold = Color(0xFF1A1509);

/// 危险按钮统一样式(AlertDialog 内联按钮也可直接取用,免再 styleFrom)。
ButtonStyle dangerButtonStyle(BuildContext context) {
  final tk = context.tk;
  return FilledButton.styleFrom(
    backgroundColor: tk.dangerFill,
    foregroundColor: tk.onDanger,
    minimumSize: const Size(44, 48),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Tk.rSm)),
    textStyle: const TextStyle(
      fontSize: Tk.fzRowTitle,
      fontWeight: FontWeight.w600,
    ),
  );
}

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
        style: dangerButtonStyle(context),
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(label),
      );
    }
    return FilledButton(
      style: dangerButtonStyle(context),
      onPressed: onPressed,
      child: Text(label),
    );
  }
}

/// 吸底主操作大按钮(通栏 48 高;SheetScaffold bottomActions/表单提交位用)。
class PrimaryXl extends StatelessWidget {
  const PrimaryXl({super.key, this.onPressed, required this.label, this.icon});

  final VoidCallback? onPressed;
  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    // 通栏:外层多在 Row>Expanded 里,SizedBox 保证单独使用时也占满;
    // 金底深墨字与主题 FilledButton 同源,显式写出便于独立主题环境测试。
    final style = FilledButton.styleFrom(
      backgroundColor: context.tk.gold,
      foregroundColor: _kOnGold,
      minimumSize: const Size.fromHeight(48),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Tk.rSm),
      ),
      textStyle: const TextStyle(
        fontSize: Tk.fzRowTitle,
        fontWeight: FontWeight.w600,
      ),
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
      child: FilledButton(
        style: style,
        onPressed: onPressed,
        child: Text(label),
      ),
    );
  }
}
