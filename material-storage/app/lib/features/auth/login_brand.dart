/// 登录页品牌区(§7.2 / F5)——纯展示:logo 66、圆角 18、金色细描边;
/// wordmark 21 / w600 / 字距 .18em;下方 26×1 金色渐变细线。
///
/// 颜色全部走 `context.tk`(深/浅双主题同源),不引用旧 `Tk.<颜色>` 别名。
library;

import 'package:flutter/material.dart';

import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';

class LoginBrand extends StatelessWidget {
  const LoginBrand({super.key});

  /// wordmark 字号与字距(.18em,§4.4/原型 login-wordmark)。
  static const double _wordmarkSize = 21;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 金环用 spreadRadius=1 的 0 模糊阴影模拟(原型 0 0 0 1px 金描边)。
        Container(
          width: 66,
          height: 66,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Tk.rLg),
            boxShadow: [
              BoxShadow(
                color: tk.gold.withValues(alpha: 0.28),
                spreadRadius: 1,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Tk.rLg),
            child: Image.asset(
              'assets/logo.png',
              width: 66,
              height: 66,
              fit: BoxFit.cover,
            ),
          ),
        ),
        const SizedBox(height: 14),
        // 字距会在末字后留白,左补等宽 padding 让视觉居中(原型 text-indent)。
        Padding(
          padding: const EdgeInsets.only(left: _wordmarkSize * 0.18),
          child: Text(
            '浣花视界',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: _wordmarkSize,
              fontWeight: FontWeight.w600,
              letterSpacing: _wordmarkSize * 0.18,
              height: 1.2,
              color: tk.ink,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          width: 26,
          height: 1,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                tk.gold.withValues(alpha: 0),
                tk.gold.withValues(alpha: 0.85),
                tk.gold.withValues(alpha: 0),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
