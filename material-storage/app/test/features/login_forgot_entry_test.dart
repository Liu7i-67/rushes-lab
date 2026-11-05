/// 登录页「忘记密码?」入口(邮箱账号方案 §7.1):
/// - 显隐三态:public-config 三态写 Session 后,仅明确 false 隐藏,
///   null(未拉到/失败)/true 都显示(点进去由后端 503 文案兜底);
/// - _onReady fire-and-forget 拉 GET /auth/public-config(3s 短超时,
///   _configLoaded 守卫只拉一次),成功写 Session 两三态字段,失败保持 null;
/// - 点击 pushNamed('/forgot-password')(msOnGenerateRoute 接线)。
/// 登录页桃花动画:只用定长 pump,禁 pumpAndSettle(先例 login_polish_test)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/app.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/auth/forgot_password_page.dart';
import 'package:ms_app/features/auth/login_page.dart';

import '../helpers/api_harness.dart';

void main() {
  // 单例复位(先例 login_polish_test resetSession)+ 配置三态复位
  void resetSession() {
    session.phase = SessionPhase.probing;
    session.baseUrl = null;
    session.me = null;
    session.emailAuthEnabled = null;
    session.passwordResetEnabled = null;
  }

  Future<void> pumpLogin(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      onGenerateRoute: msOnGenerateRoute,
      home: LoginPage(),
    ));
    await tester.pump();
  }

  final forgotEntry = find.byKey(const Key('login_forgot_password'));

  testWidgets('config=true:入口可见;点击 pushNamed /forgot-password 可达', (
    tester,
  ) async {
    addTearDown(resetSession);
    session.passwordResetEnabled = true;
    await pumpLogin(tester);

    expect(forgotEntry, findsOneWidget, reason: '§7.1:true 显示');
    await tester.tap(forgotEntry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(ForgotPasswordPage), findsOneWidget,
        reason: '/forgot-password 路由可达(app.dart 已接线)');
  });

  testWidgets('config=false:入口隐藏(唯一明确隐藏的三态)', (tester) async {
    addTearDown(resetSession);
    session.passwordResetEnabled = false;
    await pumpLogin(tester);

    expect(forgotEntry, findsNothing, reason: '§7.1:仅明确 false 才隐藏');
  });

  testWidgets('config=null(未拉到/失败):入口仍显示(fail-open 兜底)', (tester) async {
    addTearDown(resetSession);
    expect(session.passwordResetEnabled, isNull);
    await pumpLogin(tester);

    expect(forgotEntry, findsOneWidget,
        reason: 'null=unknown:一次配置请求抖动不藏恢复入口');
  });

  testWidgets('_onReady 拉公开配置:成功写 Session 三态;restore 不被阻塞阻断', (
    tester,
  ) async {
    addTearDown(resetSession);
    final api = installFakeApi();
    api.auth.meStaged = Exception('401 未登录'); // restore 失败 → 留登录页
    session.phase = SessionPhase.ready; // initState 即触发 _onReady
    await pumpLogin(tester);
    await tester.pump();
    await tester.pump();

    expect(api.auth.publicConfigCalls, 1, reason: '探活就绪即拉公开配置(一次性)');
    expect(session.emailAuthEnabled, isTrue);
    expect(session.passwordResetEnabled, isTrue);
    expect(forgotEntry, findsOneWidget);
  });

  testWidgets('配置请求失败:三态保持 null,入口不隐藏(§7.1 兜底)', (tester) async {
    addTearDown(resetSession);
    final api = installFakeApi();
    api.auth.meStaged = Exception('401 未登录');
    api.auth.publicConfigStaged = Exception('503');
    session.phase = SessionPhase.ready;
    await pumpLogin(tester);
    await tester.pump();
    await tester.pump();

    expect(api.auth.publicConfigCalls, 1);
    expect(session.passwordResetEnabled, isNull);
    expect(session.emailAuthEnabled, isNull);
    expect(forgotEntry, findsOneWidget, reason: '失败落 unknown:入口保留');
  });
}
