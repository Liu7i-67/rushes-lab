/// showAppConfirm 基础 widget 测试(app-polish A5):确认/取消/遮罩 dismissal
/// 三种返回值口径(true/false/null)、危险态确认钮红底、文案可配。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/theme/tokens.dart';
import 'package:ms_app/widgets/app_confirm.dart';

void main() {
  Future<void> ask(WidgetTester tester, void Function(BuildContext) run) => tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: FilledButton(
                onPressed: () => run(ctx),
                child: const Text('ask'),
              ),
            ),
          ),
        ),
      ));

  testWidgets('确认=true;取消=false(文案可配)', (tester) async {
    Future<bool?>? r;
    await ask(tester, (ctx) {
      r = showAppConfirm(
        ctx,
        title: '删除文件夹?',
        content: '删除为永久删除、不可恢复。',
        confirmLabel: '删除',
        cancelLabel: '再想想',
      );
    });
    await tester.tap(find.text('ask'));
    await tester.pumpAndSettle();
    expect(find.text('删除文件夹?'), findsOneWidget);
    expect(find.text('删除为永久删除、不可恢复。'), findsOneWidget);

    await tester.tap(find.text('再想想'));
    await tester.pumpAndSettle();
    expect(await r, isFalse);
  });

  testWidgets('危险态:确认钮红底白字;点确认返回 true', (tester) async {
    Future<bool?>? r;
    await ask(tester, (ctx) {
      r = showAppConfirm(ctx, title: '确认删除?', confirmLabel: '删除', danger: true);
    });
    await tester.tap(find.text('ask'));
    await tester.pumpAndSettle();

    final btn = tester.widget<FilledButton>(find.ancestor(
        of: find.text('删除'), matching: find.byType(FilledButton)));
    expect(btn.style?.backgroundColor?.resolve({}), Tk.red, reason: '危险态红底');
    expect(btn.style?.foregroundColor?.resolve({}), Tk.surface, reason: '白字');

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(await r, isTrue);
  });

  testWidgets('非危险态确认钮不是红色;点遮罩返回 null', (tester) async {
    Future<bool?>? r;
    await ask(tester, (ctx) {
      r = showAppConfirm(ctx, title: '确认操作?');
    });
    await tester.tap(find.text('ask'));
    await tester.pumpAndSettle();

    final btn = tester.widget<FilledButton>(find.ancestor(
        of: find.text('确认'), matching: find.byType(FilledButton)));
    expect(btn.style?.backgroundColor?.resolve({}), isNot(Tk.red));

    await tester.tapAt(const Offset(20, 20)); // 遮罩
    await tester.pumpAndSettle();
    expect(await r, isNull, reason: 'dismiss=null,调用方按 != true 视为未确认');
  });
}
