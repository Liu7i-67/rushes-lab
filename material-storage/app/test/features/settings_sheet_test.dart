/// 外观设置面板单测(WP0b §5.4):三档切换即时生效、面板不关闭、
/// 持久化写入、说明文案随系统明暗变化。ThemeController 注入零 IO;
/// 宿主 MaterialApp 用 AnimatedBuilder 监听 controller(与生产 app.dart 同构),
/// 否则选深色后 themeMode 不重建、sheet 仍按浅色渲染。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/features/me/settings_sheet.dart';
import 'package:ms_app/theme/app_theme.dart';
import 'package:ms_app/theme/theme_controller.dart';
import 'package:ms_app/theme/theme_store.dart';
import 'package:ms_app/theme/tk_colors.dart';
import 'package:ms_app/widgets/app_segmented.dart';

ThemeStore storeWith({String? initial, List<String>? writes}) =>
    ThemeStore(read: () async => initial, write: (v) => writes?.add(v));

/// 宿主:AnimatedBuilder 包 MaterialApp,themeMode 随 controller 即时重建。
Future<ThemeController> openSheet(
  WidgetTester tester, {
  required ThemeStore store,
}) async {
  final controller = ThemeController(store: store);
  await tester.pumpWidget(
    AnimatedBuilder(
      animation: controller,
      builder: (context, _) => MaterialApp(
        theme: buildAppTheme(Brightness.light),
        darkTheme: buildAppTheme(Brightness.dark),
        themeMode: controller.mode,
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: FilledButton(
                onPressed: () =>
                    showAppearanceSheet(ctx, controller: controller),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return controller;
}

/// sheet 内分段控件选中格的底色(0=跟随系统 / 1=深色 / 2=浅色)。
Color segmentColor(WidgetTester tester, int index) {
  final containers = find.descendant(
    of: find.byType(AppSegmented<ThemePref>),
    matching: find.byType(AnimatedContainer),
  );
  expect(containers, findsNWidgets(3));
  final decoration = tester
      .widget<AnimatedContainer>(containers.at(index))
      .decoration!;
  return (decoration as BoxDecoration).color!;
}

/// sheet 实际读到的主题调色板(经 AppSegmented 的 context)。
TkColors sheetPalette(WidgetTester tester) {
  final ctx = tester.element(find.byType(AppSegmented<ThemePref>));
  return Theme.of(ctx).extension<TkColors>()!;
}

void main() {
  testWidgets('三档切换:sheet 选中底随主题(surface4)、面板不关闭、异步落盘', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    final writes = <String>[];
    final controller = await openSheet(
      tester,
      store: storeWith(writes: writes),
    );

    expect(find.text('设置'), findsOneWidget);
    expect(find.text('外观'), findsOneWidget);
    expect(find.text('跟随系统'), findsOneWidget);
    expect(find.text('深色'), findsOneWidget);
    expect(find.text('浅色'), findsOneWidget);
    expect(find.textContaining('当前系统为浅色'), findsOneWidget);

    // 初始:跟随系统 + 系统浅色 → 第 1 格 light.surface4,其余透明。
    expect(segmentColor(tester, 0), TkColors.light.surface4);
    expect(segmentColor(tester, 1), Colors.transparent);
    expect(segmentColor(tester, 2), Colors.transparent);

    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(controller.pref, ThemePref.dark);
    expect(controller.mode, ThemeMode.dark);
    expect(writes, ['dark']);
    expect(find.text('设置'), findsOneWidget, reason: '选择后面板不关闭');
    expect(sheetPalette(tester).brightness, Brightness.dark);
    expect(
      segmentColor(tester, 1),
      TkColors.dark.surface4,
      reason: '选深色后 sheet 用 dark.surface4(不是 light)',
    );
    expect(segmentColor(tester, 1), isNot(TkColors.light.surface4));
    expect(segmentColor(tester, 0), Colors.transparent);
    expect(segmentColor(tester, 2), Colors.transparent);

    await tester.tap(find.text('浅色'));
    await tester.pumpAndSettle();
    expect(controller.pref, ThemePref.light);
    expect(controller.mode, ThemeMode.light);
    expect(writes, ['dark', 'light']);
    expect(sheetPalette(tester).brightness, Brightness.light);
    expect(
      segmentColor(tester, 2),
      TkColors.light.surface4,
      reason: '选浅色后 sheet 用 light.surface4',
    );
    expect(segmentColor(tester, 1), Colors.transparent);

    await tester.tap(find.text('跟随系统'));
    await tester.pumpAndSettle();
    expect(controller.pref, ThemePref.system);
    expect(controller.mode, ThemeMode.system);
    expect(writes, ['dark', 'light', 'system']);
    expect(find.textContaining('当前系统为浅色'), findsOneWidget);
    expect(
      segmentColor(tester, 0),
      TkColors.light.surface4,
      reason: '系统为浅色时跟随系统 = light.surface4',
    );
    expect(segmentColor(tester, 2), Colors.transparent);
  });

  testWidgets('系统深色:说明文案与「跟随系统」选中底均为深色', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await openSheet(tester, store: storeWith());
    expect(find.textContaining('当前系统为深色'), findsOneWidget);
    expect(sheetPalette(tester).brightness, Brightness.dark);
    expect(segmentColor(tester, 0), TkColors.dark.surface4);
    expect(segmentColor(tester, 0), isNot(TkColors.light.surface4));
    expect(segmentColor(tester, 1), Colors.transparent);
  });
}
