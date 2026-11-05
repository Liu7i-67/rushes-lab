/// 忘记密码页(邮箱账号方案 §7.2 + §10.3):
/// - 提交成功 → 成功卡片,文案必含「请在浏览器中打开邮件里的链接;链接
///   30 分钟内有效」(App 不做深链,§7.5);
/// - 400/429/502/503 → 页面内失败卡片(后端 detail 透传;429 附 Retry-After
///   秒数);502/503 靠 noErrorReport 不整页跳 /error-report(§10.3 用例);
/// - 邮箱格式预检 + 「返回登录」pop。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/app.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/auth/forgot_password_page.dart';
import 'package:ms_app/features/error_report/error_report_page.dart';

import '../helpers/api_harness.dart';

/// 记录 push 次数(§10.3:/error-report 不被 push 断言用;onGenerateRoute
/// 生成的路由 name 为 null,以次数判定)。
class _RouteObserver extends NavigatorObserver {
  int pushedCount = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushedCount++;
  }
}

void main() {
  void resetSession() {
    session.emailAuthEnabled = null;
    session.passwordResetEnabled = null;
  }

  Future<(_RouteObserver, FakeAuthApi)> pumpForgot(WidgetTester tester) async {
    final observer = _RouteObserver();
    final api = FakeMsApi();
    session.api = api;
    addTearDown(() => session.api = null);
    await tester.pumpWidget(MaterialApp(
      onGenerateRoute: msOnGenerateRoute,
      navigatorObservers: [observer],
      initialRoute: '/forgot-password',
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return (observer, api.auth);
  }

  Future<void> submit(WidgetTester tester, String email) async {
    await tester.enterText(find.byKey(const Key('forgot_email')), email);
    await tester.tap(find.byKey(const Key('forgot_submit')));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('提交成功:卡片必含「浏览器打开邮件链接 + 30 分钟内有效」文案', (
    tester,
  ) async {
    addTearDown(resetSession);
    final (_, auth) = await pumpForgot(tester);

    await submit(tester, 'alice@example.com');
    expect(auth.resetRequestCalls, ['alice@example.com']);

    final card = find.byKey(const Key('forgot_success'));
    expect(card, findsOneWidget);
    expect(
      find.descendant(
        of: card,
        matching: find.textContaining('请在浏览器中打开邮件里的链接完成重置;链接 30 分钟内有效'),
      ),
      findsOneWidget,
      reason: '§7.2:成功文案必含浏览器/30 分钟口径(App 无深链)',
    );
    expect(
      find.descendant(
        of: card,
        matching: find.textContaining('alice@example.com'),
      ),
      findsOneWidget,
      reason: '成功卡片回显目标邮箱(输入框同值不计)',
    );
    expect(find.byKey(const Key('forgot_error')), findsNothing);
  });

  testWidgets('400 邮箱未绑定:后端文案透传进页面内失败卡片', (tester) async {
    addTearDown(resetSession);
    final (_, auth) = await pumpForgot(tester);
    auth.resetRequestStaged =
        ApiException(400, '该邮箱未绑定任何账号', retryAfterSeconds: null);

    await submit(tester, 'nobody@example.com');
    expect(find.byKey(const Key('forgot_error')), findsOneWidget);
    expect(find.text('该邮箱未绑定任何账号'), findsOneWidget);
    expect(find.byKey(const Key('forgot_success')), findsNothing);
  });

  testWidgets('502 SMTP 失败:页面内失败卡片;不 push /error-report(§10.3)', (
    tester,
  ) async {
    addTearDown(resetSession);
    final (observer, auth) = await pumpForgot(tester);
    auth.resetRequestStaged = ApiException(502, '邮件发送失败,请稍后重试');

    await submit(tester, 'alice@example.com');
    expect(find.byKey(const Key('forgot_error')), findsOneWidget);
    expect(find.text('邮件发送失败,请稍后重试'), findsOneWidget);
    // initialRoute 层级初始 push = '/' + '/forgot-password' 共 2 次;
    // 提交后无新 push(502 若走全局上报会整页 push /error-report → 3)
    expect(observer.pushedCount, 2, reason: 'noErrorReport:502 只在页面内提示');
    expect(find.byType(ErrorReportPage), findsNothing);
  });

  testWidgets('503 功能未开启:页面内失败卡片,不跳 /error-report', (tester) async {
    addTearDown(resetSession);
    final (observer, auth) = await pumpForgot(tester);
    auth.resetRequestStaged = ApiException(503, '邮箱功能未启用,请联系管理员');

    await submit(tester, 'alice@example.com');
    expect(find.byKey(const Key('forgot_error')), findsOneWidget);
    expect(find.text('邮箱功能未启用,请联系管理员'), findsOneWidget);
    expect(observer.pushedCount, 2, reason: '无新路由 push(含报错页)');
    expect(find.byType(ErrorReportPage), findsNothing);
  });

  testWidgets('429 带 Retry-After:失败卡片附秒数(§5.7.4)', (tester) async {
    addTearDown(resetSession);
    final (_, auth) = await pumpForgot(tester);
    auth.resetRequestStaged = ApiException(
      429,
      '尝试次数过多,请 15 分钟后再试',
      retryAfterSeconds: 900,
    );

    await submit(tester, 'alice@example.com');
    expect(find.byKey(const Key('forgot_error')), findsOneWidget);
    expect(find.textContaining('900 秒后可重试'), findsOneWidget);
  });

  testWidgets('邮箱格式非法:前端预检拦截,不发请求', (tester) async {
    addTearDown(resetSession);
    final (_, auth) = await pumpForgot(tester);

    await submit(tester, 'not-an-email');
    expect(find.byKey(const Key('forgot_error')), findsOneWidget);
    expect(find.text('请输入有效的邮箱地址'), findsOneWidget);
    expect(auth.resetRequestCalls, isEmpty, reason: '预检不过不发请求');
  });

  testWidgets('「返回登录」pop 回上一页(登录页入口 push 场景)', (tester) async {
    addTearDown(resetSession);
    await tester.pumpWidget(MaterialApp(
      onGenerateRoute: msOnGenerateRoute,
      home: Scaffold(
        body: TextButton(
          onPressed: () =>
              Navigator.of(tester.element(find.byType(Scaffold))).pushNamed(
            '/forgot-password',
          ),
          child: const Text('GO'),
        ),
      ),
    ));
    await tester.pump();
    await tester.tap(find.text('GO'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ForgotPasswordPage), findsOneWidget);

    await tester.tap(find.byKey(const Key('forgot_back_login')));
    await tester.pumpAndSettle();
    expect(find.byType(ForgotPasswordPage), findsNothing,
        reason: 'pop 后离开忘记密码页');
    expect(find.text('GO'), findsOneWidget);
  });
}
