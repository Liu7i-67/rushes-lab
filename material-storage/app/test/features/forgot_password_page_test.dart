/// ForgotPasswordPage 三态验收(phone-bind 批,§7.2/§7.4):
/// - 初态①手机号;send-code 200 → 进态②验证码;
/// - send-code 400「无法发送验证码」→ 固定错误区原样透出、停留态①、可再点;
/// - confirm 200 → 态③结果视图:账号大字(username → email → name)、仅 name
///   附钉死提示小字、新密码 mono+复制钮、D2 钉死提示、「去登录」回 '/';
/// - confirm 400 码错 → 固定错误区;「换个手机号」回态①。
/// 套路:FakeAuthApi 注入;页面含循环桃花动画,一律定长 pump,用例末尾
/// pumpWidget(SizedBox.shrink) 卸载(照 login_petals_test 先例)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/components/code_send_button.dart';
import 'package:ms_app/core/api/auth_api.dart' show PhoneResetResult;
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/auth/forgot_password_page.dart';
import 'package:ms_app/widgets/copy_button.dart';
import 'package:ms_app/widgets/form_text_field.dart';

import '../helpers/fake_auth_phone.dart';

void resetSession() {
  session.api = null;
  session.me = null;
}

Future<void> pumpPage(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: ForgotPasswordPage()));
  await tester.pump();
}

/// 态①发码 → 态②(动作后双 pump:首拍冲微任务,次拍重建脏树)。
Future<void> sendAndReachCodeStep(WidgetTester tester, String phone) async {
  await tester.enterText(find.byType(AppTextField).first, phone);
  await tester.tap(find.text('获取验证码'));
  await tester.pump();
  await tester.pump();
}

void main() {
  group('ForgotPasswordPage', () {
    testWidgets('态①初渲染:标题+手机号字段+获取验证码按钮', (tester) async {
      addTearDown(resetSession);
      installFakeAuthApi();
      await pumpPage(tester);

      expect(find.text('找回密码'), findsOneWidget);
      expect(find.text('获取验证码'), findsOneWidget);
      expect(find.byType(CodeSendButton), findsOneWidget);
      expect(find.byType(OutlinedButton), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('send-code 200:入参记录+进态②验证码', (tester) async {
      addTearDown(resetSession);
      final auth = installFakeAuthApi();
      auth.sendResetRetry = 120;
      await pumpPage(tester);
      await sendAndReachCodeStep(tester, '13800138000');

      expect(auth.sendResetCalls, ['13800138000']);
      expect(find.text('输入验证码'), findsOneWidget, reason: '进态②');
      expect(find.text('验证码已发送至 13800138000'), findsOneWidget);
      expect(find.text('重置密码'), findsOneWidget);
      expect(find.text('换个手机号'), findsOneWidget);
      expect(
        find.byType(CodeSendButton),
        findsNothing,
        reason: '态②不渲染发送按钮;冷却未过时重发由 429 retry_after 重同步倒计时',
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('send-code 400「无法发送验证码」:固定错误区原样透出+停留态①', (tester) async {
      addTearDown(resetSession);
      final auth = installFakeAuthApi();
      auth.sendResetStaged = ApiException(400, '无法发送验证码');
      await pumpPage(tester);
      await sendAndReachCodeStep(tester, '13800138000');

      expect(find.text('无法发送验证码'), findsOneWidget, reason: '后端 detail 落固定错误区');
      expect(find.text('找回密码'), findsOneWidget, reason: '停留态①');
      expect(find.text('输入验证码'), findsNothing);
      final outlined = tester.widget<OutlinedButton>(
        find.descendant(
          of: find.byType(CodeSendButton),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(outlined.onPressed, isNotNull, reason: '无 retry_after 不启动倒计时,可再点');

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('confirm 200(username+email):结果视图账号+新密码可复制+去登录', (
      tester,
    ) async {
      addTearDown(resetSession);
      final auth = installFakeAuthApi();
      auth.confirmResult = PhoneResetResult(
        username: 'jia',
        email: 'jia@x.com',
        name: '甲',
        newPassword: 'Rand0m-Pass12',
      );
      await pumpPage(tester);

      await sendAndReachCodeStep(tester, '13800138000');
      await tester.enterText(find.byType(AppTextField).first, 'ZX34QW');
      await tester.tap(find.text('重置密码'));
      await tester.pump();
      await tester.pump();

      expect(auth.confirmCalls.single, (phone: '13800138000', code: 'ZX34QW'));
      expect(find.text('密码已重置'), findsOneWidget);
      expect(find.text('jia'), findsOneWidget, reason: '账号优先级 username 最高');
      expect(
        find.text('若显示名重复导致无法登录,请联系管理员'),
        findsNothing,
        reason: 'username 在,不附小字',
      );
      expect(find.text('Rand0m-Pass12'), findsOneWidget, reason: '新密码一次性展示');
      expect(find.byType(CopyButton), findsOneWidget);
      expect(
        find.text('请使用该密码登录,首次登录后系统会引导你设置新密码'),
        findsOneWidget,
        reason: 'D2 钉死提示',
      );

      // 去登录 → pushNamedAndRemoveUntil('/'):栈重置,落地 / 的新实例(态①);
      // 旧路由退场(反向动画+imperative 移除)需足量时钟推进后才完成卸载。
      await tester.tap(find.text('去登录'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('密码已重置'), findsNothing, reason: '旧结果页已出栈');
      expect(find.text('找回密码'), findsOneWidget, reason: '"/" 路由落地');

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('confirm 200(仅 name):附「显示名重复」小字', (tester) async {
      addTearDown(resetSession);
      final auth = installFakeAuthApi();
      auth.confirmResult = PhoneResetResult(
        username: null,
        email: null,
        name: '张三',
        newPassword: 'Rand0m-Pass12',
      );
      await pumpPage(tester);

      await sendAndReachCodeStep(tester, '13800138000');
      await tester.enterText(find.byType(AppTextField).first, 'ZX34QW');
      await tester.tap(find.text('重置密码'));
      await tester.pump();
      await tester.pump();

      expect(find.text('张三'), findsOneWidget);
      expect(
        find.text('若显示名重复导致无法登录,请联系管理员'),
        findsOneWidget,
        reason: '仅 name 时附钉死小字',
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('confirm 400 码错:错误区透出,停留态②;换个手机号回态①', (tester) async {
      addTearDown(resetSession);
      final auth = installFakeAuthApi();
      auth.confirmStaged = ApiException(400, '验证码错误');
      await pumpPage(tester);

      await sendAndReachCodeStep(tester, '13800138000');
      await tester.enterText(find.byType(AppTextField).first, 'WRONG1');
      await tester.tap(find.text('重置密码'));
      await tester.pump();
      await tester.pump();

      expect(find.text('验证码错误'), findsOneWidget);
      expect(find.text('密码已重置'), findsNothing, reason: '失败停留态②');
      expect(find.text('换个手机号'), findsOneWidget);

      await tester.tap(find.text('换个手机号'));
      await tester.pump();
      await tester.pump();
      expect(find.text('找回密码'), findsOneWidget);
      expect(find.text('验证码错误'), findsNothing, reason: '回态①错误区清空');

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
