/// AppCard / SectionCard — 卡片原语(§7.1 墨色 + 金色):
/// `surface` 底 + `line` 1px 描边 + rMd 圆角 + shadow1 托底,不使用 Material
/// `Card`(避免主题 margin 干扰)。SectionCard 在子项之间插 1px 分隔线,
/// 行卡(AppRow/ListTile)直接作为 children。
library;

import 'package:flutter/material.dart';

import '../theme/context_tk.dart';
import '../theme/tokens.dart';

class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.onTap,
    this.onLongPress,
    this.radius,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final r = radius ?? Tk.rMd;
    final content = Padding(
      padding: padding ?? const EdgeInsets.all(Tk.spaceLg),
      child: child,
    );
    final tappable = onTap != null || onLongPress != null;
    return Container(
      margin: margin ?? EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: tk.surface,
        borderRadius: BorderRadius.circular(r),
        border: Border.all(color: tk.line),
        boxShadow: tk.shadow1,
      ),
      child: Material(
        color: Colors.transparent,
        child: tappable
            ? InkWell(
                onTap: onTap,
                onLongPress: onLongPress,
                borderRadius: BorderRadius.circular(r),
                child: content,
              )
            : content,
      ),
    );
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.children,
    this.margin,
    this.dividerIndent = 0,
  });

  /// 子项通常是 AppRow / ListTile;分隔线只插在相邻两项之间。
  final List<Widget> children;
  final EdgeInsetsGeometry? margin;
  final double dividerIndent;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return AppCard(
      margin: margin,
      padding: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                color: tk.line,
                indent: dividerIndent,
              ),
            children[i],
          ],
        ],
      ),
    );
  }
}
