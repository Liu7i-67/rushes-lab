/// AppTheme — 主题组装:ColorScheme.fromSeed(accent) 起步再按令牌精调(§10)。
/// 卡片圆角 20;系统字体 + 全局 tabularFigures 数字。
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: Tk.accent).copyWith(
    surface: Tk.surface,
    primary: Tk.accent,
    onPrimary: Tk.surface,
    secondary: Tk.accentStrong,
    surfaceContainerHighest: Tk.surface2,
    outline: Tk.border,
    outlineVariant: Tk.border,
  );
  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: Tk.bg,
  );
  return base.copyWith(
    textTheme: _tabularFigures(base.textTheme),
    appBarTheme: const AppBarTheme(
      backgroundColor: Tk.surface,
      foregroundColor: Tk.fg,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: Tk.surface,
      elevation: 0,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: Tk.border),
      ),
    ),
    dividerTheme: const DividerThemeData(color: Tk.border, space: 1),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Tk.surface,
      indicatorColor: Tk.accentSoft,
      iconTheme: const WidgetStatePropertyAll(
        IconThemeData(color: Tk.muted),
      ),
      labelTextStyle: const WidgetStatePropertyAll(
        TextStyle(fontSize: 12, color: Tk.muted),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Tk.fill,
      hintStyle: const TextStyle(color: Tk.subtle),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    ),
    listTileTheme: const ListTileThemeData(iconColor: Tk.muted),
  );
}

/// 数字等宽(tabularFigures)套到全部文字样式——文件大小/时间/计数对齐不跳。
TextTheme _tabularFigures(TextTheme base) {
  const ff = <FontFeature>[FontFeature.tabularFigures()];
  TextStyle? f(TextStyle? s) => s?.copyWith(fontFeatures: ff);
  return TextTheme(
    displayLarge: f(base.displayLarge),
    displayMedium: f(base.displayMedium),
    displaySmall: f(base.displaySmall),
    headlineLarge: f(base.headlineLarge),
    headlineMedium: f(base.headlineMedium),
    headlineSmall: f(base.headlineSmall),
    titleLarge: f(base.titleLarge),
    titleMedium: f(base.titleMedium),
    titleSmall: f(base.titleSmall),
    bodyLarge: f(base.bodyLarge),
    bodyMedium: f(base.bodyMedium),
    bodySmall: f(base.bodySmall),
    labelLarge: f(base.labelLarge),
    labelMedium: f(base.labelMedium),
    labelSmall: f(base.labelSmall),
  );
}
