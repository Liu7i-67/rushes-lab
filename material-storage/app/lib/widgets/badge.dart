/// Badge — 徽标 pill 四色(accent/green/neutral/amber,§10)。
library;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

enum BadgeTone { accent, green, neutral, amber }

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
      BadgeTone.neutral => (Tk.muted, Tk.fill),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
