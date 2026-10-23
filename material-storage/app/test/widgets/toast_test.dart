/// toast() widget 测试(墨色 + 金色:底部 86 暖炭条):
/// 底部位置(距底 86)、点击条身销毁、action 文案与回调、tone 圆点颜色、
/// 默认 2.4s 自动销毁、latest-wins(新条顶替旧条)。
/// P1-2(J1 探针实证缺陷修复):toast 生命周期绑定路由变化——存续期 push
/// 路由即销毁(ToastRouteObserver,app.dart 同装配),Back 首击不被吞。
/// 收尾统一「pump 过 duration + pumpAndSettle」排空自动销毁 timer 与退场
/// 动画(widget 测试不容留 pending timer)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/theme/tk_colors.dart';
import 'package:ms_app/theme/tokens.dart';
import 'package:ms_app/widgets/toast.dart';

void main() {
  /// 挂「show」按钮,点击弹一条 tone/参数可配的 toast。
  Future<void> host(
    WidgetTester tester, {
    ToastTone tone = ToastTone.info,
    String message = '已入队 2 项',
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = kToastDuration,
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

  /// 排空 toast 自动销毁 timer + 退场动画。
  Future<void> drain(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  }

  /// 左侧 8 圆点颜色(唯一 key `toast-dot`)。
  Color dotColor(WidgetTester tester) {
    final dot = tester.widget<Container>(
      find.byKey(const ValueKey<String>('toast-dot')),
    );
    return (dot.decoration! as BoxDecoration).color!;
  }

  /// 条身(圆点最近的外层 Container)底边距屏幕底的距离。
  double barBottomGap(WidgetTester tester) {
    final bar = find
        .ancestor(
          of: find.byKey(const ValueKey<String>('toast-dot')),
          matching: find.byType(Container),
        )
        .first;
    return tester.view.physicalSize.height / tester.view.devicePixelRatio -
        tester.getRect(bar).bottom;
  }

  testWidgets('底部 86 悬浮条渲染(info 金点),到期自动销毁', (tester) async {
    await host(tester);
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();

    expect(find.text('已入队 2 项'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('toast-dot')),
      findsOneWidget,
      reason: '左侧 8 圆点',
    );
    expect(
      dotColor(tester),
      TkColors.dark.goldBright,
      reason: 'info 圆点金 #DCC084',
    );
    expect(
      barBottomGap(tester),
      closeTo(kToastBottomOffset, 0.01),
      reason: 'toast 固定在距底 86(设计 §2)',
    );
    expect(barBottomGap(tester), greaterThan(60), reason: '不再贴顶部');

    await drain(tester);
    expect(find.text('已入队 2 项'), findsNothing, reason: 'duration 到时自动销毁');
  });

  testWidgets('默认时长 2.4s:2.2s 仍在,2.6s 后消失', (tester) async {
    expect(
      kToastDuration,
      const Duration(milliseconds: 2400),
      reason: '默认时长 2.4s(设计 §2)',
    );
    await host(tester);
    await tester.tap(find.text('show'));
    await tester.pump(); // 起始帧
    await tester.pump(const Duration(milliseconds: 150)); // 入场完成

    await tester.pump(const Duration(milliseconds: 2050)); // t≈2.2s
    expect(find.text('已入队 2 项'), findsOneWidget, reason: '2.2s 仍在');
    await tester.pump(const Duration(milliseconds: 450)); // t≈2.65s
    await tester.pump(const Duration(milliseconds: 200)); // 退场 150ms
    expect(find.text('已入队 2 项'), findsNothing, reason: '2.4s 起退场,2.6s 已销毁');
  });

  testWidgets('点击条身即销毁', (tester) async {
    await host(tester);
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();
    expect(find.text('已入队 2 项'), findsOneWidget);

    await tester.tap(find.text('已入队 2 项'));
    await tester.pumpAndSettle();
    expect(find.text('已入队 2 项'), findsNothing, reason: '点击条身直接销毁');
  });

  testWidgets('action 文案渲染且回调后销毁;success 金点 / error 红点', (tester) async {
    var tapped = false;
    await host(
      tester,
      tone: ToastTone.success,
      actionLabel: '查看详情',
      onAction: () => tapped = true,
    );
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();

    expect(dotColor(tester), TkColors.dark.goldBright, reason: 'success 金点');
    await tester.tap(find.text('查看详情'));
    await tester.pumpAndSettle();
    expect(tapped, isTrue, reason: 'action 回调触发');
    expect(find.text('已入队 2 项'), findsNothing, reason: 'action 后销毁');

    await host(tester, tone: ToastTone.error);
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();
    expect(dotColor(tester), Tk.dangerOnDark, reason: 'error 红点 #EF8B86');
    await drain(tester);
  });

  testWidgets('暖炭底固定深色:浅色主题下仍为 #383228', (tester) async {
    await host(tester);
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();

    final bar = tester.widget<Container>(
      find
          .ancestor(
            of: find.byKey(const ValueKey<String>('toast-dot')),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(
      (bar.decoration! as BoxDecoration).color,
      TkColors.dark.surface4,
      reason: '固定暖炭底,不随主题变浅',
    );
    expect(find.text('已入队 2 项'), findsOneWidget);
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

  testWidgets('P2-7:disableAnimations 下 toast 立即显隐(无进出场动画)', (tester) async {
    // toast 挂在 root Overlay(在 MaterialApp 的 MediaQuery 之下),故用
    // 平台无障碍特性注入(等价系统「移除动画」开关)而非局部包裹。
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: FilledButton(
                onPressed: () => toast(ctx, '已入队 2 项'),
                child: const Text('show'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('show'));
    await tester.pump();

    expect(find.text('已入队 2 项'), findsOneWidget, reason: '首帧即完整可见');
    final fade = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.byKey(const ValueKey<String>('toast-dot')),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    expect(fade.opacity.value, 1.0, reason: '入场动画时长归零,直接不透明');

    await tester.tap(find.text('已入队 2 项'));
    await tester.pump();
    expect(find.text('已入队 2 项'), findsNothing, reason: '点击后立即移除');
    await tester.pump(const Duration(seconds: 4)); // 排空已取消的自动销毁 timer
  });

  testWidgets('P1-2:toast 存续期 push 路由→toast 即销毁,Back 首击生效', (tester) async {
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
                  Navigator.of(ctx).push(
                    MaterialPageRoute(
                      builder: (_) => Scaffold(
                        appBar: AppBar(title: const Text('第二页')),
                        body: const Center(child: Text('第二页内容')),
                      ),
                    ),
                  );
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
    expect(
      find.text('已入队 2 项', skipOffstage: false),
      findsNothing,
      reason:
          'P1-2:push 路由即销毁 toast(旧页提示对新页无意义,含 '
          'offstage 残留)',
    );

    // 兼修口径:隐形 toast 不再吞新页 AppBar 返回键首击
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('show'), findsOneWidget, reason: 'P1-2:返回键首击生效');
  });
}
