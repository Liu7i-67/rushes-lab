/// toast() widget 测试(app-polish A6;J1 改造为顶部 Overlay 悬浮条):
/// 顶部位置(非旧 SnackBar 底部)、点击条身销毁、action 文案与回调、tone
/// 图标、latest-wins(新条顶替旧条)、duration 到时自动销毁。
/// P1-2(J1 探针实证缺陷修复):toast 生命周期绑定路由变化——存续期 push
/// 路由即销毁(ToastRouteObserver,app.dart 同装配),Back 首击不被吞。
/// 收尾统一「pump 过 duration + pumpAndSettle」排空自动销毁 timer 与退场
/// 动画(widget 测试不容留 pending timer)。
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
    Duration duration = const Duration(seconds: 3),
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => toast(
                ctx,
                message,
                tone: tone,
                actionLabel: actionLabel,
                onAction: onAction,
                duration: duration,
              ),
              child: const Text('show'),
            ),
          ),
        ),
      ),
    ),
  );

  /// 排空 toast 自动销毁 timer + 退场动画(J1 Overlay 实现的 pump 收尾)。
  Future<void> drain(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  }

  testWidgets('J1:顶部悬浮条渲染(info 图标),到期自动销毁', (tester) async {
    await host(tester);
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();

    expect(find.text('已入队 2 项'), findsOneWidget);
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
    // 位置断言:条身出现在屏幕顶部 SafeArea 下(旧 SnackBar 从底部弹出)
    final dy = tester.getTopLeft(find.text('已入队 2 项')).dy;
    expect(dy, lessThan(100), reason: 'J1:toast 固定在顶部');

    await drain(tester);
    expect(find.text('已入队 2 项'), findsNothing, reason: 'duration 到时自动销毁');
  });

  testWidgets('J1:点击条身即销毁', (tester) async {
    await host(tester);
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();
    expect(find.text('已入队 2 项'), findsOneWidget);

    await tester.tap(find.text('已入队 2 项'));
    await tester.pumpAndSettle();
    expect(find.text('已入队 2 项'), findsNothing, reason: '点击条身直接销毁');
  });

  testWidgets('action 文案渲染且回调后销毁;success/error 图标随 tone', (tester) async {
    var tapped = false;
    await host(
      tester,
      tone: ToastTone.success,
      actionLabel: '查看详情',
      onAction: () => tapped = true,
    );
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    await tester.tap(find.text('查看详情'));
    await tester.pumpAndSettle();
    expect(tapped, isTrue, reason: 'action 回调触发');
    expect(find.text('已入队 2 项'), findsNothing, reason: 'action 后销毁');

    await host(tester, tone: ToastTone.error);
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    await drain(tester);
  });

  testWidgets('latest wins:连发两条只留最新', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
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
      ),
    );
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();

    expect(find.text('第一条'), findsNothing, reason: '新 toast 先移除旧 entry');
    expect(find.text('第二条'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('P1-2:toast 存续期 push 路由→toast 即销毁,Back 首击生效',
      (tester) async {
    // 同 app.dart 装配挂 ToastRouteObserver(裸 MaterialApp 不挂则不生效)。
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [ToastRouteObserver()],
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: FilledButton(
                onPressed: () {
                  toast(ctx, '已入队 2 项');
                  Navigator.of(ctx).push(MaterialPageRoute(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: const Text('第二页')),
                      body: const Center(child: Text('第二页内容')),
                    ),
                  ));
                },
                child: const Text('show'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();

    expect(find.text('第二页'), findsOneWidget, reason: '前置:新路由在顶');
    expect(find.text('已入队 2 项', skipOffstage: false), findsNothing,
        reason: 'P1-2:push 路由即销毁 toast(旧页提示对新页无意义,含 '
            'offstage 残留)');

    // 兼修口径:隐形 toast 不再吞新页 AppBar 返回键首击
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('show'), findsOneWidget, reason: 'P1-2:返回键首击生效');
  });
}
