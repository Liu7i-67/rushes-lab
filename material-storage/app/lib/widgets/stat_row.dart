/// StatRow — 1~4 格概览数字(§7.1):外框 rMd + line 1px,格间 1px 缝,
/// 数字 22/600/tabular,标签 11.5/ink3/letterSpacing .04em。
library;

import 'package:flutter/material.dart';

import '../theme/context_tk.dart';
import '../theme/tokens.dart';

class StatItem {
  const StatItem({required this.value, required this.label, this.onTap});

  final String value;
  final String label;
  final VoidCallback? onTap;
}

class StatRow extends StatelessWidget {
  const StatRow({super.key, required this.items});

  final List<StatItem> items;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    if (items.isEmpty) return const SizedBox.shrink();
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: tk.line,
        border: Border.all(color: tk.line),
        borderRadius: BorderRadius.circular(Tk.rMd),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) SizedBox(width: 1, child: ColoredBox(color: tk.line)),
              Expanded(child: _StatCell(item: items[i])),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatCell extends StatelessWidget {
  const _StatCell({required this.item});

  final StatItem item;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Material(
      color: tk.surface,
      child: InkWell(
        onTap: item.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Tk.spaceMd,
            vertical: 13,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                item.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: Tk.fzStat,
                  height: 1.2,
                  fontWeight: FontWeight.w600,
                  color: tk.ink,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 2),
              Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11.5,
                  letterSpacing: 0.46,
                  color: tk.ink3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
