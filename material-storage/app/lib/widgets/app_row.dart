/// AppRow — 卡片行(§7.1):34×34 图标底 + 标题 15.5 + 副标题 13 +
/// 右侧 trailing/chevron;minHeight 56,InkWell 圆角 rMd。
///
/// `leading` 传普通 [Icon] 时自动套 34×34 圆角容器(`goldIcon` 切金浅底);
/// 传其它自定义 Widget(头像/缩略图)时原样使用。
library;

import 'package:flutter/material.dart';

import '../theme/context_tk.dart';
import '../theme/tokens.dart';

class AppRow extends StatelessWidget {
  const AppRow({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.goldIcon = false,
    this.showChevron = true,
  });

  final Widget? leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool goldIcon;

  /// onTap 非空且未显式传 trailing 时显示 chevron;false 可关闭。
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final chevron = onTap != null && showChevron && trailing == null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Tk.rMd),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                if (leading != null) ...[
                  _Leading(leading: leading!, goldIcon: goldIcon),
                  const SizedBox(width: Tk.spaceMd),
                ],
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: Tk.fzRowTitle,
                          height: 1.45,
                          fontWeight: FontWeight.w500,
                          color: tk.ink,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: Tk.spaceSm),
                  trailing!,
                ] else if (chevron) ...[
                  const SizedBox(width: Tk.spaceSm),
                  Icon(Icons.chevron_right, size: 18, color: tk.ink3),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 默认图标底:34×34 / 圆角 10;其余 leading 原样使用。
class _Leading extends StatelessWidget {
  const _Leading({required this.leading, required this.goldIcon});

  final Widget leading;
  final bool goldIcon;

  @override
  Widget build(BuildContext context) {
    if (leading is! Icon) return leading;
    final tk = context.tk;
    final icon = leading as Icon;
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: goldIcon ? tk.goldSoft : tk.surface3,
        borderRadius: BorderRadius.circular(10),
      ),
      child: IconTheme(
        data: IconThemeData(
          color: goldIcon ? tk.goldInk : tk.ink2,
          size: icon.size ?? 19,
        ),
        child: icon,
      ),
    );
  }
}
