/// 多选操作栏的单键(自 asset_selection_bar.dart 拆出,§5.6):icon + label
/// 竖排,触控 48 高;可用态保留 Tooltip(桌面悬停语义),禁用态不靠
/// Tooltip——点按 toast 说明原因。
library;

import 'package:flutter/material.dart';

import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/toast.dart';

class SelectionActionButton extends StatelessWidget {
  const SelectionActionButton({
    super.key,
    required this.icon,
    required this.label,
    this.tooltip,
    this.disabledReason,
    this.enabled = false,
    this.primary = false,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String? tooltip;
  final String? disabledReason;
  final bool enabled;
  final bool primary;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final color = enabled ? (primary ? tk.goldInk : tk.ink2) : tk.ink3;
    final btn = InkWell(
      borderRadius: BorderRadius.circular(Tk.rMd),
      onTap: enabled
          ? onTap
          : disabledReason == null
          ? null
          : () => toast(context, disabledReason!),
      // P2-1:最小触控 48,标签允许两行(320dp+1.3 字号不省略号)。
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(vertical: Tk.spaceXs),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 2,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: Tk.fzXs, height: 1.15, color: color),
            ),
          ],
        ),
      ),
    );
    if (!enabled) return btn;
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}
