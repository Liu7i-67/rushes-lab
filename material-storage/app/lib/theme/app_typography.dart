/// AppTypography — §4.4 字阶到 Flutter TextTheme 的映射。
///
/// - 不设置 fontFamily:用系统字体栈(PingFang/HarmonyOS/MiSans/Noto/YaHei)。
/// - 全部字号数字等宽(tabularFigures),文件大小/计数/时间对齐不跳。
/// - 字重 Flutter 只有百位档:w620→w600、w550→w500、w650→w600。
/// - letterSpacing 以 em 设计值换算为逻辑像素(负值=中文标题收紧,
///   正值=英文微标签字距)。
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// 数字等宽特性(全局文字样式共用)。
const List<FontFeature> kTkFontFeatures = <FontFeature>[
  FontFeature.tabularFigures(),
];

TextStyle _style(
  double size,
  double height,
  FontWeight weight, {
  double? letterSpacing,
}) => TextStyle(
  fontSize: size,
  height: height,
  fontWeight: weight,
  letterSpacing: letterSpacing,
  fontFeatures: kTkFontFeatures,
);

/// §4.4 全量字阶;颜色留空由 buildAppTheme 按主题 apply。
TextTheme buildTextTheme() => TextTheme(
  // 一级页大标题:27/1.15,w620(→w600),-0.02em(→-0.54)
  displayLarge: _style(
    Tk.fzDisplay,
    1.15,
    FontWeight.w600,
    letterSpacing: -0.54,
  ),
  // 未在 §4.4 单列的 display/headline 档沿用同族层级的最近档
  displayMedium: _style(
    Tk.fzDisplay,
    1.15,
    FontWeight.w600,
    letterSpacing: -0.54,
  ),
  displaySmall: _style(Tk.fzStat, 1.2, FontWeight.w600, letterSpacing: -0.44),
  headlineLarge: _style(24, 1.25, FontWeight.w600, letterSpacing: -0.48),
  headlineMedium: _style(
    Tk.fzSection,
    1.35,
    FontWeight.w600,
    letterSpacing: -0.3,
  ),
  headlineSmall: _style(Tk.fzTitle, 1.3, FontWeight.w600),
  // 区块/弹层标题:20/1.35,w620,-0.015em(→-0.3)
  titleLarge: _style(Tk.fzSection, 1.35, FontWeight.w600, letterSpacing: -0.3),
  // 二级页标题:17/1.3,w600
  titleMedium: _style(Tk.fzTitle, 1.3, FontWeight.w600),
  // 列表标题:15.5/1.45,w550(→w500)
  titleSmall: _style(Tk.fzRowTitle, 1.45, FontWeight.w500),
  bodyLarge: _style(Tk.fzBody, 1.5, FontWeight.w400),
  bodyMedium: _style(14, 1.5, FontWeight.w400), // 密排正文
  bodySmall: _style(Tk.fzMd, 1.5, FontWeight.w400),
  labelLarge: _style(Tk.fzRowTitle, 1.2, FontWeight.w600),
  labelMedium: _style(Tk.fzMd, 1.35, FontWeight.w500),
  // 微标签:11/1.4,w650(→w600),+0.1em(→+1.1)
  labelSmall: _style(Tk.fzXs, 1.4, FontWeight.w600, letterSpacing: 1.1),
);

/// 用 §4.4 字阶覆盖 base 中已定义的档位;base 剩余的档位也补上数字等宽。
TextTheme applyTkType(TextTheme base) {
  final tk = buildTextTheme();
  TextStyle? pick(TextStyle? own, TextStyle? fallback) =>
      own ?? fallback?.copyWith(fontFeatures: kTkFontFeatures);
  return TextTheme(
    displayLarge: pick(tk.displayLarge, base.displayLarge),
    displayMedium: pick(tk.displayMedium, base.displayMedium),
    displaySmall: pick(tk.displaySmall, base.displaySmall),
    headlineLarge: pick(tk.headlineLarge, base.headlineLarge),
    headlineMedium: pick(tk.headlineMedium, base.headlineMedium),
    headlineSmall: pick(tk.headlineSmall, base.headlineSmall),
    titleLarge: pick(tk.titleLarge, base.titleLarge),
    titleMedium: pick(tk.titleMedium, base.titleMedium),
    titleSmall: pick(tk.titleSmall, base.titleSmall),
    bodyLarge: pick(tk.bodyLarge, base.bodyLarge),
    bodyMedium: pick(tk.bodyMedium, base.bodyMedium),
    bodySmall: pick(tk.bodySmall, base.bodySmall),
    labelLarge: pick(tk.labelLarge, base.labelLarge),
    labelMedium: pick(tk.labelMedium, base.labelMedium),
    labelSmall: pick(tk.labelSmall, base.labelSmall),
  );
}
