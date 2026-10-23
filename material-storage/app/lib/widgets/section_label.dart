/// SectionLabel — 分组微标签(11/600/letterSpacing 1.1/ink3),
/// 右侧可选 hint(13/400/ink3,不加大写、不加字距)。
library;

import 'package:flutter/material.dart';

import '../theme/context_tk.dart';
import '../theme/tokens.dart';

class SectionLabel extends StatelessWidget {
  const SectionLabel({super.key, required this.title, this.hint});

  final String title;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Tk.spacePage,
        vertical: Tk.spaceSm,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: Tk.fzXs,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.1,
                color: tk.ink3,
              ),
            ),
          ),
          if (hint != null) ...[
            const SizedBox(width: Tk.spaceSm),
            Flexible(
              child: Text(
                hint!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: Tk.fzMd,
                  fontWeight: FontWeight.w400,
                  color: tk.ink3,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
