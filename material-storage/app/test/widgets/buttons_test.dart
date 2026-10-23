/// DangerButton/PrimaryXl 基础 widget 测试(app-polish A10 + 墨金视觉):
/// 危险钮红底(dangerFill)浅字(onDanger)、图标变体;吸底大按钮金底深墨字、
/// 通栏 48 高。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/theme/tk_colors.dart';
import 'package:ms_app/widgets/buttons.dart';

void main() {
  testWidgets('DangerButton:红底(dangerFill)浅字;onPressed 透传', (tester) async {
    var pressed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DangerButton(
            onPressed: () => pressed++,
            label: '删除',
            icon: Icons.delete_outline,
          ),
        ),
      ),
    );

    final btn = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(btn.style?.backgroundColor?.resolve({}), TkColors.light.dangerFill);
    expect(btn.style?.foregroundColor?.resolve({}), TkColors.light.onDanger);
    expect(btn.style?.minimumSize?.resolve({})?.height, 48);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);

    await tester.tap(find.text('删除'));
    expect(pressed, 1);
  });

  testWidgets('dangerButtonStyle 同源(AlertDialog 内联场景)', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox())),
    );
    final ctx = tester.element(find.byType(SizedBox));
    final style = dangerButtonStyle(ctx);
    expect(style.backgroundColor?.resolve({}), TkColors.light.dangerFill);
    expect(style.foregroundColor?.resolve({}), TkColors.light.onDanger);
    expect(style.minimumSize?.resolve({})?.height, 48);
  });

  testWidgets('PrimaryXl:通栏 + 金底深墨字 + 48 高触控', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: PrimaryXl(label: '创建项目')),
        ),
      ),
    );

    final size = tester.getSize(find.byType(PrimaryXl));
    expect(size.width, 800, reason: '测试面 800 宽,通栏占满');
    final btn = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(btn.style?.backgroundColor?.resolve({}), TkColors.light.gold);
    expect(btn.style?.foregroundColor?.resolve({}), const Color(0xFF1A1509));
    expect(btn.style?.minimumSize?.resolve({})?.height, 48);
  });
}
