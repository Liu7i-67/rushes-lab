/// 双主题真实页面冒烟共用夹具(P1-4):390×844 / 320×640 × light/dark ×
/// 字号 1.3 的 pump 与基础断言(无异常、Scaffold 背景=palette.bg、
/// PageHeader 标题=palette.ink、Theme/TkColors brightness 正确)。
/// 只做测试装配,不引入生产改动;定长 pump,不用 pumpAndSettle 死等。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/theme/app_theme.dart';
import 'package:ms_app/theme/tk_colors.dart';
import 'package:ms_app/widgets/page_header.dart';

/// 冒烟尺寸矩阵(mobile 大屏 + 最小支持宽)。
const kSmokeSizes = [Size(390, 844), Size(320, 640)];

/// 双主题矩阵。
const kSmokeBrightnesses = [Brightness.light, Brightness.dark];

/// 系统字号放大档位(1.3 为产品验收上限)。
const kSmokeTextScaler = TextScaler.linear(1.3);

String smokeBrightnessLabel(Brightness b) => b == Brightness.dark ? '深色' : '浅色';

String smokeSizeLabel(Size s) => '${s.width.toInt()}x${s.height.toInt()}';

/// 组合标签:390x844 · 深色。
String smokeComboLabel(Size size, Brightness brightness) =>
    '${smokeSizeLabel(size)} · ${smokeBrightnessLabel(brightness)}';

/// 断言页面上下文确实处于 1.3 字号缩放(放大矩阵的生效证据)。
void expectSmokeTextScale(WidgetTester tester) {
  final ctx = tester.element(find.byType(Scaffold).first);
  expect(
    MediaQuery.textScalerOf(ctx).scale(100),
    closeTo(130, 0.01),
    reason: '字号 1.3 已生效',
  );
}

/// 在指定尺寸/主题/字号下 pump 真实页面。
///
/// 主题经 [buildAppTheme] 直接注入(与生产 MaterialApp 同源);字号经
/// 页面外层 MediaQuery 放大 1.3。pump 序列:首帧 → 假 API 微任务落地 →
/// 400ms 动画过渡(避开 pumpAndSettle 在无限动画(spinner)下死等)。
Future<void> pumpSmokePage(
  WidgetTester tester, {
  required Size size,
  required Brightness brightness,
  required Widget home,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(brightness),
      home: Builder(
        builder: (ctx) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(textScaler: kSmokeTextScaler),
          child: home,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// 基础断言:无 overflow/异常、Scaffold 背景=对应 palette.bg、
/// PageHeader 标题存在且文字色=palette.ink、Theme 与 TkColors 扩展的
/// brightness 与输入一致;可选关键文案存在。
void expectSmokeBaseline(
  WidgetTester tester, {
  required Brightness brightness,
  required String title,
  String? keyword,
}) {
  final tk = TkColors.of(brightness);
  final combo = smokeBrightnessLabel(brightness);

  expect(tester.takeException(), isNull, reason: '$combo 无 overflow/异常');

  final scaffolds = find.byType(Scaffold);
  expect(scaffolds, findsWidgets, reason: '真实页面应含 Scaffold');
  final scaffold = tester.widget<Scaffold>(scaffolds.first);
  final theme = Theme.of(tester.element(scaffolds.first));
  expect(theme.brightness, brightness, reason: 'Theme.brightness = $combo');
  expect(
    theme.extension<TkColors>()?.brightness,
    brightness,
    reason: 'TkColors 扩展 brightness = $combo',
  );
  final actualBg = scaffold.backgroundColor ?? theme.scaffoldBackgroundColor;
  expect(actualBg, tk.bg, reason: 'Scaffold 背景 = $combo palette.bg');
  expectSmokeTextScale(tester);

  final titleFinder = find.descendant(
    of: find.byType(PageHeader),
    matching: find.text(title),
  );
  expect(titleFinder, findsOneWidget, reason: '页头标题「$title」存在');
  final titleText = tester.widget<Text>(titleFinder);
  expect(
    titleText.style?.color,
    tk.ink,
    reason: '页头标题文字色 = $combo palette.ink',
  );

  if (keyword != null) {
    expect(find.text(keyword), findsWidgets, reason: '关键文案「$keyword」存在');
  }
}
