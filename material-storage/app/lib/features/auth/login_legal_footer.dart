/// 登录页底部法务小字行(§7.2 / F5;自 login_form.dart 拆出,§5.6):
/// 「登录即代表同意《服务条款》与《隐私政策》」,两个书名号为可点链接
/// (金色 + 下划线),回退逻辑在 LoginPage._openLegal。
library;

import 'package:flutter/material.dart';

import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';

class LoginLegalFooter extends StatelessWidget {
  const LoginLegalFooter({
    super.key,
    required this.onOpenTerms,
    required this.onOpenPrivacy,
  });

  final VoidCallback onOpenTerms;
  final VoidCallback onOpenPrivacy;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final base = TextStyle(fontSize: Tk.fzMd, height: 1.6, color: tk.ink3);
    final link = base.copyWith(
      color: tk.goldInk,
      decoration: TextDecoration.underline,
      decorationColor: tk.goldInk.withValues(alpha: 0.6),
    );
    return Text.rich(
      TextSpan(
        text: '登录即代表同意',
        style: base,
        children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: _LegalLink(
              label: '服务条款',
              text: '《服务条款》',
              style: link,
              onTap: onOpenTerms,
            ),
          ),
          const TextSpan(text: '与'),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: _LegalLink(
              label: '隐私政策',
              text: '《隐私政策》',
              style: link,
              onTap: onOpenPrivacy,
            ),
          ),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}

/// 法务链接(P2-6):语义标记为 link + 名称;最小 44 高触控区,行内换行
/// 仍由外层 Text.rich 负责(WidgetSpan 只撑高当前行)。
class _LegalLink extends StatelessWidget {
  const _LegalLink({
    required this.label,
    required this.text,
    required this.style,
    required this.onTap,
  });

  final String label;
  final String text;
  final TextStyle style;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      link: true,
      label: label,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: Text(text, style: style),
          ),
        ),
      ),
    );
  }
}
