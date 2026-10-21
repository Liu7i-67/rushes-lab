/// toast() 基础 widget 测试(app-polish A6):floating 形态、tone 图标、
/// action 文案与回调、latest wins(hideCurrent 后展示)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/widgets/toast.dart';

void main() {
  /// 挂「show」按钮,点击弹一条 tone/参数可配的 toast。
  Future<void> host(
    WidgetTester tester, {
    ToastTone tone = ToastTone.info,
    String message = '已入队 2 项',
    String? actionLabel,
    VoidCallback? onAction,
  }) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: FilledButton(
                onPressed: () => toast(ctx, message,
                    tone: tone, actionLabel: actionLabel, onAction: onAction),
                child: const Text('show'),
              ),
            ),
          ),
        ),
      ));

  testWidgets('floating SnackBar + info 图标渲染', (tester) async {
    await host(tester);
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();

    final bar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(bar.behavior, SnackBarBehavior.floating, reason: 'floating 悬浮');
    expect(find.text('已入队 2 项'), findsOneWidget);
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
  });

  testWidgets('action 文案渲染且回调;success/error 图标随 tone', (tester) async {
    var tapped = false;
    await host(tester,
        tone: ToastTone.success,
        actionLabel: '查看详情',
        onAction: () => tapped = true);
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    await tester.tap(find.text('查看详情'));
    await tester.pumpAndSettle();
    expect(tapped, isTrue, reason: 'action 回调触发');

    await host(tester, tone: ToastTone.error);
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
  });

  testWidgets('latest wins:连发两条只留最新', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () {
                toast(ctx, '第一条');
                toast(ctx, '第二条');
              },
              child: const Text('show'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();

    expect(find.text('第一条'), findsNothing, reason: 'hideCurrent 后被顶掉');
    expect(find.text('第二条'), findsOneWidget);
  });
}
