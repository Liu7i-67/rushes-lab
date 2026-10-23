/// WP3 登录桃花层验收(§8.1 / F5 / F15):
/// - reduced-motion:不启动无限 ticker,pumpAndSettle 可正常结束;
/// - 正常动画:LoginPetals 在场,连续 pump 数帧不抛异常;
/// - 主题切换(dark→light):按新配色重建不抛异常。
///
/// 登录页存在循环动画,本文件一律用定长 pump,并在用例末尾卸载页面。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/auth/login_page.dart';
import 'package:ms_app/features/auth/login_petals.dart';
import 'package:ms_app/theme/app_theme.dart';

void main() {
  // 单例复位:probing / 未登录(探活态不触发 restore 网络分支)。
  void resetSession() {
    session.phase = SessionPhase.probing;
    session.baseUrl = null;
    session.me = null;
  }

  testWidgets('disableAnimations:桃花不启动 ticker,pumpAndSettle 可完成', (
    tester,
  ) async {
    addTearDown(resetSession);
    resetSession();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: const LoginPage(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(LoginPetals), findsOneWidget, reason: '桃花层仍绘制(静态少量花瓣)');
    expect(
      tester.binding.transientCallbackCount,
      0,
      reason: 'reduced-motion 下不得有无限 ticker',
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('动画模式:LoginPetals 在场,pump 数帧不抛异常', (tester) async {
    addTearDown(resetSession);
    resetSession();
    await tester.pumpWidget(const MaterialApp(home: LoginPage()));
    await tester.pump();

    expect(find.byType(LoginPetals), findsOneWidget);
    expect(
      tester.widget<LoginPetals>(find.byType(LoginPetals)).count,
      22,
      reason: 'F5:动画模式 22 片',
    );
    expect(
      tester.binding.transientCallbackCount,
      greaterThan(0),
      reason: '正常模式下桃花动画在跑',
    );

    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('主题切换 dark→light:桃花按新配色重建,不抛异常', (tester) async {
    addTearDown(resetSession);
    resetSession();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: const LoginPage(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: const LoginPage(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 300)); // 主题过渡 220ms

    expect(find.byType(LoginPetals), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  // 双主题 + 390/320 宽冒烟:桃花在场、不 overflow(§11.3)。
  for (final (width, height, brightness, scale)
      in <(double, double, Brightness, double)>[
        (390, 844, Brightness.dark, 1.0),
        (320, 640, Brightness.light, 1.3),
      ]) {
    testWidgets('F5 冒烟:${width.toInt()}×${height.toInt()} '
        '${brightness.name} scale=$scale 无 overflow', (tester) async {
      addTearDown(resetSession);
      resetSession();
      tester.view.physicalSize = Size(width, height);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(brightness),
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: const LoginPage(),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));

      expect(find.byType(LoginPetals), findsOneWidget);
      expect(find.text('浣花视界'), findsOneWidget);
      expect(find.text('登录'), findsOneWidget);
      expect(find.textContaining('登录即代表同意'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '登录页在目标宽/字号下无 overflow');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
