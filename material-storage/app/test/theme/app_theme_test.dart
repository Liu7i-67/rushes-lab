/// buildAppTheme / context.tk 单测(WP0):主题装配与无 extension 兜底。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/theme/app_theme.dart';
import 'package:ms_app/theme/context_tk.dart';
import 'package:ms_app/theme/tk_colors.dart';
import 'package:ms_app/theme/tokens.dart';

void main() {
  test('深色主题:背景/extension/primary/输入/AppBar', () {
    final theme = buildAppTheme(Brightness.dark);
    expect(theme.brightness, Brightness.dark);
    expect(theme.scaffoldBackgroundColor, TkColors.dark.bg);
    expect(theme.extension<TkColors>()?.bg, TkColors.dark.bg);
    expect(theme.extension<TkColors>()?.brightness, Brightness.dark);
    expect(theme.colorScheme.primary, TkColors.dark.gold);
    expect(theme.colorScheme.onPrimary, const Color(0xFF1A1509));
    expect(theme.colorScheme.surface, TkColors.dark.surface);
    expect(theme.colorScheme.error, TkColors.dark.danger);
    expect(theme.inputDecorationTheme.fillColor, TkColors.dark.bg);
    expect(theme.appBarTheme.toolbarHeight, 60);
    expect(theme.appBarTheme.titleTextStyle?.fontSize, Tk.fzTitle);
    expect(theme.appBarTheme.backgroundColor, TkColors.dark.bg);
    expect(theme.appBarTheme.elevation, 0);
  });

  test('浅色主题:背景/extension/primary/输入/AppBar', () {
    final theme = buildAppTheme(Brightness.light);
    expect(theme.brightness, Brightness.light);
    expect(theme.scaffoldBackgroundColor, TkColors.light.bg);
    expect(theme.extension<TkColors>()?.bg, TkColors.light.bg);
    expect(theme.colorScheme.primary, TkColors.light.gold);
    expect(theme.inputDecorationTheme.fillColor, TkColors.light.bg);
    expect(theme.appBarTheme.titleTextStyle?.fontSize, 17);
  });

  test('buildAppTheme() 默认浅色(兼容旧调用点)', () {
    expect(buildAppTheme().brightness, Brightness.light);
  });

  testWidgets('context.tk 无 extension 时按 brightness 回落', (tester) async {
    late TkColors seen;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Builder(
          builder: (context) {
            seen = context.tk;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(seen.bg, TkColors.dark.bg);
    expect(seen.brightness, Brightness.dark);
  });

  testWidgets('context.tk 优先取 Theme extension', (tester) async {
    late TkColors seen;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: Builder(
          builder: (context) {
            seen = context.tk;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(seen.bg, TkColors.dark.bg);
  });
}
