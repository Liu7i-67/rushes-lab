/// Badge — 徽标 pill 五色(accent/green/neutral/amber/red,§10;red=B7
/// 审批「已拒绝」补,web STATUS_META crimson 同源)。
library;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

enum BadgeTone { accent, green, neutral, amber, red }

class Badge extends StatelessWidget {
  const Badge({super.key, required this.label, this.tone = BadgeTone.neutral});

  final String label;
  final BadgeTone tone;

  @override
  Widget build(BuildContext context) {
    final (fg, bg) = switch (tone) {
      BadgeTone.accent => (Tk.accentStrong, Tk.accentFaint),
      BadgeTone.green => (Tk.green, Tk.green.withValues(alpha: 0.10)),
      BadgeTone.amber => (Tk.amber, Tk.amber.withValues(alpha: 0.10)),
      BadgeTone.red => (Tk.red, Tk.red.withValues(alpha: 0.10)),
      BadgeTone.neutral => (Tk.muted, Tk.fill),
    };
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: Tk.spaceSm, vertical: 3), // 3=<4 视觉微缝,保留
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Tk.rPill),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontSize: Tk.fzSm,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
