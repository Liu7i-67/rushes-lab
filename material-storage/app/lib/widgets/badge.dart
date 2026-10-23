/// Badge — 徽标 pill(墨色 + 金色语言,§6 F3):22 高 / 11.5 字 / pill。
///
/// 兼容旧五态(accent/green/neutral/amber/red),新增设计语言四态
/// (gold/ok/warn/danger/outline);颜色全部来自 `context.tk`,两种主题同构。
library;

import 'package:flutter/material.dart';

import '../theme/context_tk.dart';
import '../theme/tokens.dart';

enum BadgeTone {
  accent,
  green,
  neutral,
  amber,
  red,
  gold,
  ok,
  warn,
  danger,
  outline,
}

class Badge extends StatelessWidget {
  const Badge({super.key, required this.label, this.tone = BadgeTone.neutral});

  final String label;
  final BadgeTone tone;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final (fg, bg) = switch (tone) {
      BadgeTone.accent || BadgeTone.gold => (tk.goldInk, tk.goldSoft),
      BadgeTone.green || BadgeTone.ok => (tk.ok, tk.okSoft),
      BadgeTone.amber || BadgeTone.warn => (tk.warn, tk.warnSoft),
      BadgeTone.red || BadgeTone.danger => (tk.danger, tk.dangerSoft),
      BadgeTone.neutral => (tk.ink2, tk.surface3),
      BadgeTone.outline => (tk.ink3, Colors.transparent),
    };
    return Container(
      height: 22,
      // 不用 alignment 居中(那会在 ListTile.trailing 的松约束下横向撑满,
      // 触发「Trailing widget consumes the entire tile width」);用 min Row
      // 横收窄 + 纵向居中。
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Tk.rPill),
        border: tone == BadgeTone.outline
            ? Border.all(color: tk.controlBorder)
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: TextStyle(
              color: fg,
              fontSize: 11.5,
              height: 1.2,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.115, // .01em @ 11.5
            ),
          ),
        ],
      ),
    );
  }
}
