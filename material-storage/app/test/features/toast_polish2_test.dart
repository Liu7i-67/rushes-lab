/// app-polish-2(P2 批)toast 验收用例(对应需求文档 2026-10-22-app-polish-2.md
/// J1 #9):toast 改 Overlay 顶部悬浮条——
/// - 出现于顶部(SafeArea 下,不再是底部 floating SnackBar);
/// - 点击条身即销毁;
/// - actionLabel 点击执行回调并销毁(既有语义回归锚);
/// - 连续两条第二条顶替第一条(latest-wins 回归锚)。
///
/// 套路:同 widgets/toast_test.dart——挂「show」按钮宿主页直接调 toast()
/// (签名不变,零调用点改动);弹层结构用 find.text/byType 基础件断言,
/// 不探测 Overlay 内部实现。J1 已交付:以下断言均为交付后绿灯口径
/// (先红阶段的 TODO 标注已摘除);收尾统一 pump 过 duration 排空自动
/// 销毁 timer(同 toast_test.dart 正例,不留 pending timer)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/widgets/toast.dart';

void main() {
  /// 排空 toast 自动销毁 timer + 退场动画(同 toast_test.dart drain 正例)。
  Future<void> drain(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  }

  /// 挂「show」按钮,点击弹一条参数可配的 toast。
  Future<void> host(
    WidgetTester tester, {
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
                    actionLabel: actionLabel, onAction: onAction),
                child: const Text('show'),
              ),
            ),
          ),
        ),
      ));

  testWidgets('J1:toast 出现于顶部(SafeArea 下悬浮条),不再 SnackBar',
      (tester) async {
    await host(tester);
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();

    // 已交付转绿(J1):Overlay 顶部悬浮条,不再是 SnackBar
    expect(find.byType(SnackBar), findsNothing,
        reason: 'J1:不再以 SnackBar 呈现(Overlay 顶部悬浮条)');

    final msg = find.text('已入队 2 项');
    expect(msg, findsOneWidget);
    final top = tester.getTopLeft(msg).dy;
    expect(top, greaterThanOrEqualTo(0), reason: 'J1:不出屏');
    expect(top, lessThan(120), reason: 'J1:贴顶部 SafeArea 下悬浮(非底部)');

    await drain(tester); // 收尾:排空自动销毁 timer(测试卫生)
  });

  testWidgets('J1:点击 toast 条身即销毁', (tester) async {
    await host(tester, message: '点我销毁');
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();
    expect(find.text('点我销毁'), findsOneWidget, reason: '前置:toast 在场');

    await tester.tap(find.text('点我销毁'));
    await tester.pumpAndSettle();
    expect(find.text('点我销毁'), findsNothing, reason: 'J1:点击条身销毁');
  });

  testWidgets('J1:actionLabel 点击执行回调并销毁(既有语义回归锚)', (tester) async {
    var fired = false;
    await host(tester,
        message: '已入队 2 项', actionLabel: '查看详情', onAction: () => fired = true);
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('查看详情'));
    await tester.pumpAndSettle();
    expect(fired, isTrue, reason: 'J1:action 回调触发');
    expect(find.text('已入队 2 项'), findsNothing, reason: 'J1:action 后销毁');
  });

  testWidgets('J1:连续两条第二条顶替第一条(latest-wins 回归锚,仍居顶部)',
      (tester) async {
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

    expect(find.text('第一条'), findsNothing, reason: 'J1:新 toast 顶替旧的');
    expect(find.text('第二条'), findsOneWidget);
    expect(tester.getTopLeft(find.text('第二条')).dy, lessThan(120),
        reason: 'J1:顶替后的新条仍在顶部');
    await drain(tester); // 收尾:排空自动销毁 timer(测试卫生)
  });
}
