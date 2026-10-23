/// PageHeader — 页面头(§6 F4):一级页 27 大标题 + 计数/副标题,
/// 二级页 17 标题 + 44×44 返回。底部 1px line,内容 minHeight 60。
/// 不承担 AppBar 语义;返回钮带 `Semantics(button, label: 返回)`。
library;

import 'package:flutter/material.dart';

import '../theme/context_tk.dart';
import '../theme/tokens.dart';

class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.count,
    this.subtitle,
    this.actions = const [],
    this.back = false,
    this.onBack,
  });

  final String title;
  final String? count;
  final String? subtitle;
  final List<Widget> actions;
  final bool back;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final titleStyle = TextStyle(
      fontSize: back ? Tk.fzTitle : Tk.fzDisplay,
      height: back ? 1.3 : 1.15,
      fontWeight: FontWeight.w600,
      letterSpacing: back ? -0.3 : -0.54,
      color: tk.ink,
    );
    return Container(
      color: tk.bg,
      child: SafeArea(
        bottom: false,
        child: Container(
          constraints: const BoxConstraints(minHeight: 60),
          padding: const EdgeInsets.fromLTRB(Tk.spacePage, 10, Tk.spaceSm, 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: tk.line)),
          ),
          child: Row(
            children: [
              if (back) ...[
                Semantics(
                  button: true,
                  label: '返回',
                  child: IconButton(
                    tooltip: '返回',
                    onPressed: onBack ?? () => Navigator.maybePop(context),
                    icon: const Icon(Icons.arrow_back_ios_new, size: 20),
                  ),
                ),
                const SizedBox(width: Tk.spaceXs),
              ],
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: titleStyle,
                          ),
                        ),
                        if (count != null) ...[
                          const SizedBox(width: Tk.spaceSm),
                          Text(
                            count!,
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: Tk.fzMd,
                              color: tk.ink3,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ],
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
              if (actions.isNotEmpty) ...[
                const SizedBox(width: Tk.spaceSm),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 2,
                  children: actions,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
