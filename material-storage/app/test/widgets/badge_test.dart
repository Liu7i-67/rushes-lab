/// Badge 组件测试(§6 F3 / §11.4):10 态枚举向后兼容,六态金/绿/黄/红/
/// 中性/描边的底色 + 字色 + 描边;尺寸 22 高 / 11.5 字 / pill。
library;

import 'package:flutter/material.dart' hide Badge;
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/theme/app_theme.dart';
import 'package:ms_app/theme/tk_colors.dart';
import 'package:ms_app/widgets/badge.dart';

void main() {
  Future<void> host(WidgetTester tester, Badge badge) => tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      home: Scaffold(body: Center(child: badge)),
    ),
  );

  Container boxOf(WidgetTester tester) => tester.widget<Container>(
    find
        .ancestor(of: find.byType(Text), matching: find.byType(Container))
        .first,
  );

  testWidgets('六态:gold/ok/warn/danger/neutral/outline 底色字色描边', (tester) async {
    final tk = TkColors.dark;
    final cases = <BadgeTone, (Color fg, Color bg)>{
      BadgeTone.gold: (tk.goldInk, tk.goldSoft),
      BadgeTone.ok: (tk.ok, tk.okSoft),
      BadgeTone.warn: (tk.warn, tk.warnSoft),
      BadgeTone.danger: (tk.danger, tk.dangerSoft),
      BadgeTone.neutral: (tk.ink2, tk.surface3),
      BadgeTone.outline: (tk.ink3, Colors.transparent),
    };
    for (final entry in cases.entries) {
      await host(tester, Badge(label: 'X', tone: entry.key));
      final text = tester.widget<Text>(find.text('X')).style!;
      final box = boxOf(tester).decoration! as BoxDecoration;
      expect(text.color, entry.value.$1, reason: '${entry.key} 字色');
      expect(box.color, entry.value.$2, reason: '${entry.key} 底色');
      if (entry.key == BadgeTone.outline) {
        expect(box.border, isNotNull, reason: 'outline 1px 描边');
        expect(
          (box.border! as Border).top.color,
          tk.controlBorder,
          reason: 'P1-1:outline 徽标描边用可交互/可读性描边 controlBorder',
        );
      } else {
        expect(box.border, isNull);
      }
    }
  });

  testWidgets('尺寸:22 高 / 11.5 字 w600 / pill 圆角', (tester) async {
    await host(tester, const Badge(label: '已通过', tone: BadgeTone.ok));
    expect(tester.getSize(find.byType(Badge)).height, 22);
    final text = tester.widget<Text>(find.text('已通过')).style!;
    expect(text.fontSize, 11.5);
    expect(text.fontWeight, FontWeight.w600);
    final box = boxOf(tester).decoration! as BoxDecoration;
    expect(box.borderRadius, BorderRadius.circular(999));
  });

  testWidgets('旧五态仍可用(accent/green/neutral/amber/red)', (tester) async {
    await host(tester, const Badge(label: '旧', tone: BadgeTone.accent));
    expect(
      tester.widget<Text>(find.text('旧')).style!.color,
      TkColors.dark.goldInk,
    );
    await host(tester, const Badge(label: '旧', tone: BadgeTone.red));
    expect(
      tester.widget<Text>(find.text('旧')).style!.color,
      TkColors.dark.danger,
    );
  });
}
