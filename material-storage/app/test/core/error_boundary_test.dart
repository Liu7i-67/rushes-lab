/// B9 功能点 4:渲染异常全局兜底接线——installErrorBoundary 换装
/// ErrorWidget.builder(渲染异常 → AppLog 留痕;debug 期透传原 builder 保留
/// 红字细节,release 走友好页不白屏;zone/未捕获兜底由 AppLog.init 挂,
/// 本处不重复)。P2-7 补 release 路径覆盖:debug 开关注入(installErrorBoundary
/// (debug: false))+ 友好页产物布局冒烟断言。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/error_boundary.dart';
import 'package:ms_app/theme/app_theme.dart';
import 'package:ms_app/theme/tk_colors.dart';

void main() {
  testWidgets('渲染异常经新 builder 不逃逸(debug 呈原细节;release 为友好页)', (tester) async {
    final original = ErrorWidget.builder;
    installErrorBoundary();
    try {
      expect(
        identical(ErrorWidget.builder, original),
        isFalse,
        reason: 'builder 已换装',
      );

      await tester.pumpWidget(
        Builder(
          builder: (context) {
            throw StateError('boom-in-build');
          },
        ),
      );
      // builder 正常返回 Widget(异常不逃逸出 builder);debug=原 builder 红字,
      // release=友好页——两种产物都是合法 Widget,页面不白屏由同一入口保证
      expect(tester.takeException(), isNotNull);
    } finally {
      // 框架校验 ErrorWidget.builder 测试后须复位(早于 tearDown)
      ErrorWidget.builder = original;
    }
  });

  test('builder 产物为合法 Widget(debug 原细节 / release 友好页)', () {
    final page = ErrorWidget.builder(
      FlutterErrorDetails(exception: StateError('x'), library: 'test'),
    );
    expect(page, isA<Widget>());
  });

  testWidgets('P2-7 release 注入(debug:false):渲染异常落友好页关键文案', (tester) async {
    final original = ErrorWidget.builder;
    installErrorBoundary(debug: false);
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => throw StateError('boom-in-release'),
            ),
          ),
        ),
      );
      // 异常被 builder 接住(不逃逸),页面换成友好页而非红字/白屏
      expect(tester.takeException(), isNotNull);
      expect(find.text('页面出现了一点问题'), findsOneWidget);
      expect(find.textContaining('已记录诊断信息'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('复制诊断'), findsOneWidget);
      // release 不再透传原 builder 红字细节
      expect(find.textContaining('boom-in-release'), findsNothing);
    } finally {
      ErrorWidget.builder = original;
    }
  });

  testWidgets('P2-7 友好页产物布局冒烟(MaterialApp 外仅 Directionality 亦可立)', (
    tester,
  ) async {
    // builder 产物可能在 MaterialApp 之外渲染(根布局自身出错):
    // 仅包 Directionality 冒烟,验证不依赖 Theme/MediaApp 即可完整布局
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: FriendlyErrorPage(diagnostics: 'boom'),
      ),
    );
    expect(find.text('页面出现了一点问题'), findsOneWidget);
    expect(find.textContaining('已记录诊断信息'), findsOneWidget, reason: '说明文案告知可自救');
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('复制诊断'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('双主题渲染不抛:Scaffold 背景随主题', (tester) async {
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(brightness),
          home: const FriendlyErrorPage(diagnostics: 'boom'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('页面出现了一点问题'), findsOneWidget);
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        TkColors.of(brightness).bg,
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('重试按钮回调宿主', (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: FriendlyErrorPage(onRetry: () => retried++),
      ),
    );
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(retried, 1);
    expect(find.text('页面出现了一点问题'), findsOneWidget, reason: '重试后页面仍可布局(无二次异常)');
  });
}
