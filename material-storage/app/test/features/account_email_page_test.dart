/// 账号与安全 · 邮箱页(邮箱账号方案 §7.3 + §10.3):
/// - 顶部卡片三态 Tag(未绑定/未验证/已验证)+ 三态按钮组;
/// - 邮箱功能关闭但已有邮箱 → 只保留「解除绑定」+ 提示(解绑不依赖 SMTP);
/// - passwordSet=false → 操作禁用 + 提示;
/// - 绑定/验证码两步流(FakeAuthApi staged):发码 → 6 位码 → 确认 →
///   session.restore() 刷新 Me(顶部卡片随 meResult 变化);429 按
///   retryAfterSeconds 倒计时;错误码页内提示;
/// - 解绑 = 密码弹层 + danger 确认对话框 → 成功后 Me 刷新。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/me/account_email_page.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

void main() {
  void resetSession() {
    session.me = null;
    session.emailAuthEnabled = null;
    session.passwordResetEnabled = null;
  }

  Me meOf({
    String email = '',
    bool verified = false,
    bool passwordSet = true,
  }) => Me(
    id: 'u1',
    name: '测试',
    email: email,
    emailVerified: verified,
    passwordSet: passwordSet,
  );

  Future<FakeAuthApi> pumpEmail(WidgetTester tester) async {
    final api = FakeMsApi();
    session.api = api;
    addTearDown(() => session.api = null);
    await tester.pumpWidget(const MaterialApp(home: AccountEmailPage()));
    await tester.pump();
    return api.auth;
  }

  group('顶部卡片三态 + 按钮组(§7.3 状态机)', () {
    testWidgets('未绑定:Badge 未绑定 + 「绑定邮箱」主按钮,无解绑', (tester) async {
      addTearDown(resetSession);
      session.me = meOf();
      await pumpEmail(tester);

      expect(find.text('未绑定'), findsOneWidget);
      expect(find.byKey(const Key('email_action_bind')), findsOneWidget);
      expect(find.byKey(const Key('email_action_verify')), findsNothing);
      expect(find.byKey(const Key('email_action_change')), findsNothing);
      expect(find.byKey(const Key('email_action_unbind')), findsNothing);
    });

    testWidgets('未验证:Badge 未验证 + 验证邮箱(主)+ 更换邮箱 + 解除绑定', (
      tester,
    ) async {
      addTearDown(resetSession);
      session.me = meOf(email: 'alice@example.com');
      await pumpEmail(tester);

      expect(find.text('未验证'), findsOneWidget);
      expect(find.text('alice@example.com'), findsOneWidget,
          reason: '顶部卡片展示当前邮箱');
      expect(find.byKey(const Key('email_action_verify')), findsOneWidget);
      expect(find.byKey(const Key('email_action_change')), findsOneWidget);
      expect(find.byKey(const Key('email_action_unbind')), findsOneWidget);
      expect(find.byKey(const Key('email_action_bind')), findsNothing);
    });

    testWidgets('已验证:Badge 已验证 + 更换邮箱(主)+ 解除绑定,无验证邮箱', (
      tester,
    ) async {
      addTearDown(resetSession);
      session.me = meOf(email: 'alice@example.com', verified: true);
      await pumpEmail(tester);

      expect(find.text('已验证'), findsOneWidget);
      expect(find.byKey(const Key('email_action_change')), findsOneWidget);
      expect(find.byKey(const Key('email_action_unbind')), findsOneWidget);
      expect(find.byKey(const Key('email_action_verify')), findsNothing);
      expect(find.byKey(const Key('email_action_bind')), findsNothing);
    });

    testWidgets('邮箱功能关闭但已有邮箱:只保留解除绑定 + 「邮箱功能暂未开启」', (
      tester,
    ) async {
      addTearDown(resetSession);
      session.me = meOf(email: 'alice@example.com', verified: true);
      session.emailAuthEnabled = false;
      await pumpEmail(tester);

      expect(find.byKey(const Key('email_action_unbind')), findsOneWidget,
          reason: '解绑不依赖 SMTP,功能关闭仍可用(§5.3.4)');
      expect(find.byKey(const Key('email_action_change')), findsNothing);
      expect(find.byKey(const Key('email_action_verify')), findsNothing);
      expect(find.text('邮箱功能暂未开启,仅可解除绑定。'), findsOneWidget);
    });

    testWidgets('邮箱功能关闭且无邮箱:无任何操作入口 + 提示', (tester) async {
      addTearDown(resetSession);
      session.me = meOf();
      session.emailAuthEnabled = false;
      await pumpEmail(tester);

      expect(find.byKey(const Key('email_action_bind')), findsNothing);
      expect(find.byKey(const Key('email_action_unbind')), findsNothing);
      expect(find.text('邮箱功能暂未开启。'), findsOneWidget);
    });

    testWidgets('passwordSet=false:操作禁用 + 「需管理员先初始化密码」提示', (tester) async {
      addTearDown(resetSession);
      session.me = meOf(email: 'alice@example.com', passwordSet: false);
      await pumpEmail(tester);

      expect(find.byKey(const Key('email_action_verify')), findsNothing);
      expect(find.byKey(const Key('email_action_change')), findsNothing);
      final unbind = tester.widget<OutlinedButton>(
        find.descendant(
          of: find.byKey(const Key('email_action_unbind')),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(unbind.onPressed, isNull, reason: '解绑同样需要密码,一并禁用');
      expect(find.text('需管理员先初始化密码。'), findsOneWidget);
    });
  });

  group('绑定/验证码两步流(FakeAuthApi staged)', () {
    testWidgets('绑定全流程:新邮箱+密码 → 发码(记录入参)→ 6 位码 → 确认 → '
        'restore 刷新 Me → 顶部卡片翻「已验证」', (tester) async {
      addTearDown(resetSession);
      session.me = meOf();
      final auth = await pumpEmail(tester);

      await tester.tap(find.byKey(const Key('email_action_bind')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('email_sheet_new_email')),
        'alice@example.com',
      );
      await tester.enterText(
        find.byKey(const Key('email_sheet_password')),
        'Old-pass1',
      );
      await tester.tap(find.byKey(const Key('email_sheet_send')));
      await tester.pump();
      await tester.pump();

      expect(auth.sendCodeCalls.single, (
        email: 'alice@example.com',
        password: 'Old-pass1',
      ));
      expect(find.textContaining('验证码已发送至 a***@example.com'), findsOneWidget,
          reason: '第二步展示脱敏目标邮箱');

      // 确认前把 meResult 换成绑定成功后的 Me:restore() 刷新后卡片应翻转
      auth.meResult = meOf(email: 'alice@example.com', verified: true);
      await tester.enterText(
        find.byKey(const Key('email_sheet_code')),
        '123456',
      );
      await tester.tap(find.byKey(const Key('email_sheet_confirm')));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(auth.confirmCalls, ['123456']);
      expect(auth.meCalls, greaterThanOrEqualTo(1),
          reason: '§7.3:成功后 session.restore() 刷新 Me');
      expect(find.text('已验证'), findsOneWidget, reason: 'Me 刷新后卡片状态翻转');
      expect(find.textContaining('邮箱绑定成功'), findsOneWidget,
          reason: '成功 toast');
      // 收尾:排空 toast 自动消失 Timer(pages_polish E2 同款)
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });

    testWidgets('验证当前邮箱:弹层无「新邮箱」框(目标=当前邮箱),确认 action=verify', (
      tester,
    ) async {
      addTearDown(resetSession);
      session.me = meOf(email: 'alice@example.com');
      final auth = await pumpEmail(tester);

      await tester.tap(find.byKey(const Key('email_action_verify')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('email_sheet_new_email')), findsNothing,
          reason: 'verify 目标=当前邮箱,不要求输新地址');
      await tester.enterText(
        find.byKey(const Key('email_sheet_password')),
        'Old-pass1',
      );
      await tester.tap(find.byKey(const Key('email_sheet_send')));
      await tester.pump();
      await tester.pump();

      expect(auth.sendCodeCalls.single.email, 'alice@example.com',
          reason: 'purpose=verify 发往当前邮箱');
    });

    testWidgets('验证码错误:页内错误文案,弹层不关(可重输)', (tester) async {
      addTearDown(resetSession);
      session.me = meOf();
      final auth = await pumpEmail(tester);
      auth.confirmStaged = ApiException(400, '验证码错误或已失效');

      await tester.tap(find.byKey(const Key('email_action_bind')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('email_sheet_new_email')),
        'alice@example.com',
      );
      await tester.enterText(
        find.byKey(const Key('email_sheet_password')),
        'Old-pass1',
      );
      await tester.tap(find.byKey(const Key('email_sheet_send')));
      await tester.pump();
      await tester.pump();
      await tester.enterText(find.byKey(const Key('email_sheet_code')), '000000');
      await tester.tap(find.byKey(const Key('email_sheet_confirm')));
      await tester.pump();
      await tester.pump();

      expect(find.text('验证码错误或已失效'), findsOneWidget);
      expect(find.byKey(const Key('email_sheet_confirm')), findsOneWidget,
          reason: '失败留在弹层可重输');
    });

    testWidgets('发码 429 带 Retry-After:错误附秒数;重发钮按服务端剩余秒数冷却', (
      tester,
    ) async {
      addTearDown(resetSession);
      session.me = meOf();
      final auth = await pumpEmail(tester);

      await tester.tap(find.byKey(const Key('email_action_bind')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('email_sheet_new_email')),
        'alice@example.com',
      );
      await tester.enterText(
        find.byKey(const Key('email_sheet_password')),
        'Old-pass1',
      );
      // 首发成功进第二步(60s 本地倒计时),排空后重发钮恢复
      await tester.tap(find.byKey(const Key('email_sheet_send')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('email_sheet_resend')), findsOneWidget);
      await tester.pump(const Duration(seconds: 60));

      // 重发撞 429(带 Retry-After 42):错误附秒数,重发钮按 42s 冷却
      auth.sendCodeStaged = ApiException(
        429,
        '发送过于频繁,请 42 秒后再试',
        retryAfterSeconds: 42,
        method: 'POST',
        path: '/api/v1/auth/email/code',
      );
      await tester.tap(find.byKey(const Key('email_sheet_resend')));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('42 秒后可重试'), findsOneWidget);
      final resend = tester.widget<TextButton>(
        find.byKey(const Key('email_sheet_resend')),
      );
      expect(resend.onPressed, isNull, reason: '倒计时内重发禁用');
      expect(find.textContaining('重新发送(42 s)'), findsOneWidget);

      // 走完倒计时(排空 periodic Timer),重发恢复可点
      await tester.pump(const Duration(seconds: 42));
      final resendAfter = tester.widget<TextButton>(
        find.byKey(const Key('email_sheet_resend')),
      );
      expect(resendAfter.onPressed, isNotNull, reason: '倒计时归零重发恢复');
    });

    testWidgets('发码 502:错误留在弹层页内(noErrorReport),不关弹层', (tester) async {
      addTearDown(resetSession);
      session.me = meOf();
      final auth = await pumpEmail(tester);
      auth.sendCodeStaged = ApiException(502, '验证码发送失败,请稍后重试');

      await tester.tap(find.byKey(const Key('email_action_bind')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('email_sheet_new_email')),
        'alice@example.com',
      );
      await tester.enterText(
        find.byKey(const Key('email_sheet_password')),
        'Old-pass1',
      );
      await tester.tap(find.byKey(const Key('email_sheet_send')));
      await tester.pump();
      await tester.pump();

      expect(find.text('验证码发送失败,请稍后重试'), findsOneWidget);
      expect(find.byKey(const Key('email_sheet_send')), findsOneWidget,
          reason: '仍在第一步可重试');
    });
  });

  group('解绑流(密码 + danger 确认对话框)', () {
    testWidgets('取消确认:不发请求;确认后解绑成功 → Me 刷新回「未绑定」', (tester) async {
      addTearDown(resetSession);
      session.me = meOf(email: 'alice@example.com', verified: true);
      final auth = await pumpEmail(tester);

      await tester.tap(find.byKey(const Key('email_action_unbind')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('email_unbind_password')),
        'Old-pass1',
      );
      await tester.tap(find.byKey(const Key('email_unbind_submit')));
      await tester.pumpAndSettle();

      expect(find.text('解除邮箱绑定?'), findsOneWidget, reason: 'danger 二次确认');
      expect(auth.unbindCalls, isEmpty, reason: '确认前不发请求');

      // 取消:什么都不发生
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(auth.unbindCalls, isEmpty);

      // 再走一遍并确认;解绑成功后 /me 返回空邮箱(restore 刷新卡片回未绑定)
      auth.meResult = meOf();
      await tester.tap(find.byKey(const Key('email_unbind_submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('解除'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(auth.unbindCalls, ['Old-pass1']);
      expect(auth.meCalls, greaterThanOrEqualTo(1), reason: '成功后 restore 刷新');
      expect(find.text('未绑定'), findsOneWidget, reason: 'Me 刷新后卡片回未绑定');
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });

    testWidgets('解绑密码错误:后端 400 透传页内', (tester) async {
      addTearDown(resetSession);
      session.me = meOf(email: 'alice@example.com', verified: true);
      final auth = await pumpEmail(tester);
      auth.unbindStaged = ApiException(400, '账号密码不正确');

      await tester.tap(find.byKey(const Key('email_action_unbind')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('email_unbind_password')),
        'wrong',
      );
      await tester.tap(find.byKey(const Key('email_unbind_submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('解除'));
      await tester.pump();
      await tester.pump();

      expect(find.text('账号密码不正确'), findsOneWidget);
      expect(find.byKey(const Key('email_unbind_submit')), findsOneWidget,
          reason: '失败留在弹层可重试');
    });
  });
}
