/// DangerButton/PrimaryXl 基础 widget 测试(app-polish A10):危险钮红底
/// 白字、图标变体;吸底大按钮通栏加高。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/theme/tokens.dart';
import 'package:ms_app/widgets/buttons.dart';

void main() {
  testWidgets('DangerButton:红底白字;onPressed 透传', (tester) async {
    var pressed = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DangerButton(
            onPressed: () => pressed++, label: '删除', icon: Icons.delete_outline),
      ),
    ));

    final btn = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(btn.style?.backgroundColor?.resolve({}), Tk.red);
    expect(btn.style?.foregroundColor?.resolve({}), Tk.surface);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);

    await tester.tap(find.text('删除'));
    expect(pressed, 1);
  });

  test('dangerButtonStyle 同源(AlertDialog 内联场景)', () {
    expect(dangerButtonStyle().backgroundColor?.resolve({}), Tk.red);
  });

  testWidgets('PrimaryXl:通栏 + 48 高触控', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(child: PrimaryXl(label: '创建项目')),
      ),
    ));

    final size = tester.getSize(find.byType(PrimaryXl));
    expect(size.width, 800, reason: '测试面 800 宽,通栏占满');
    final btn = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(btn.style?.minimumSize?.resolve({})?.height, 48);
  });
}
