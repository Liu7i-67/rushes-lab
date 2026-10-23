/// AppSegmented — 分段控件(§7.1):surface3 轨道 + 选中 surface4 滑块
/// (圆角 9)+ 可选计数;160ms 过渡,disableAnimations 时瞬时。
library;

import 'package:flutter/material.dart';

import '../theme/context_tk.dart';
import '../theme/tokens.dart';

class Segment<T> {
  const Segment({required this.value, required this.label, this.count});

  final T value;
  final String label;
  final int? count;
}

class AppSegmented<T> extends StatelessWidget {
  const AppSegmented({
    super.key,
    required this.segments,
    required this.value,
    required this.onChanged,
  });

  final List<Segment<T>> segments;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final duration = reduced
        ? Duration.zero
        : const Duration(milliseconds: 160);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: tk.surface3,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          for (final segment in segments)
            Expanded(
              child: Semantics(
                selected: segment.value == value,
                button: true,
                child: AnimatedContainer(
                  duration: duration,
                  height: 44,
                  decoration: BoxDecoration(
                    color: segment.value == value
                        ? tk.surface4
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => onChanged(segment.value),
                      borderRadius: BorderRadius.circular(9),
                      child: Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              segment.label,
                              maxLines: 1,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: segment.value == value
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: segment.value == value
                                    ? tk.ink
                                    : tk.ink2,
                              ),
                            ),
                            if (segment.count != null) ...[
                              const SizedBox(width: 3),
                              Text(
                                '${segment.count}',
                                style: TextStyle(
                                  fontSize: Tk.fzMd,
                                  // ink2 在 surface4 滑块/ surface3 轨道上
                                  // 均 ≥4.5:1(ink3 在滑块上仅约 4.1)。
                                  color: tk.ink2,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
