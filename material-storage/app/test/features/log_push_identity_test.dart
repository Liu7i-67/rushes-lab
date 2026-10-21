/// P10 日志推送对话框身份展示单测:已登录时内容区显示当前用户名一行
/// (与企微身份消息同源),未登录(登录页调试出口)不显示该行;
/// 对话框本体(标题/统计/推送钮)不回退。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/me/log_push.dart';
import 'package:ms_app/models/models.dart';

void main() {
  Future<void> openDialog(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => showLogPushDialog(ctx),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('已登录:对话框显示「当前用户:<name>」一行', (tester) async {
    session.me = Me(id: 'u-123', name: 'Evan');
    addTearDown(() => session.me = null);

    await openDialog(tester);

    expect(find.text('推送日志到企业微信'), findsOneWidget, reason: '对话框本体不回退');
    expect(find.textContaining('当前用户:Evan'), findsOneWidget,
        reason: 'P10:已登录显示用户名行(与身份消息同源)');
    // 只点「关闭」,不触推送(推送链路见 test/wecom_push_test.dart)
    await tester.tap(find.text('关闭'));
    await tester.pump();
  });

  testWidgets('未登录:不显示用户名行,对话框照常可开', (tester) async {
    expect(session.me, isNull);

    await openDialog(tester);

    expect(find.text('推送日志到企业微信'), findsOneWidget);
    expect(find.textContaining('当前用户'), findsNothing,
        reason: '未登录(登录页调试出口)无身份行');
    await tester.tap(find.text('关闭'));
    await tester.pump();
  });
}
