/// ForgotPasswordPage 三态验收(phone-bind 批,§7.2/§7.4):
/// - 初态①手机号;send-code 200 → 进态②验证码;
/// - send-code 400「无法发送验证码」→ 固定错误区原样透出、停留态①、可再点;
/// - confirm 200 → 态③结果视图:账号大字(username → email → name)、仅 name
///   附钉死提示小字、新密码 mono+复制钮、D2 钉死提示、「去登录」回 '/';
/// - confirm 400 码错 → 固定错误区;「返回上一步」回态①。
/// 验收反馈修复(2026-11-23):态②挂「重新获取」重发倒计时按钮(与态①共用
/// GlobalKey,倒计时按截止时刻跨态连续)、小字「换个手机号」升级为全宽次级
/// 按钮「返回上一步」(保留手机号与倒计时剩余)。
/// 套路:FakeAuthApi 注入;页面含循环桃花动画,一律定长 pump,用例末尾
/// pumpWidget(SizedBox.shrink) 卸载(照 login_petals_test 先例)。
/// 倒计时秒数口径:_cdDeadline 用墙钟 DateTime.now(),截断取整后 120s 的
/// retry_after 落到「重新获取(119s)」(测试内墙钟推进仅毫秒级,值稳定)。
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

    testWidgets('send-code 200:入参记录+进态②验证码+重发按钮显眼次级返回', (tester) async {
      addTearDown(resetSession);
      final auth = installFakeAuthApi();
      auth.sendResetRetry = 120;
      await pumpPage(tester);
      await sendAndReachCodeStep(tester, '13800138000');

      expect(auth.sendResetCalls, ['13800138000']);
      expect(find.text('输入验证码'), findsOneWidget, reason: '进态②');
      expect(find.text('验证码已发送至 13800138000'), findsOneWidget);
      expect(find.text('重置密码'), findsOneWidget);
      expect(find.text('返回上一步'), findsOneWidget, reason: '小字升级为显眼次级按钮');
      expect(find.text('换个手机号'), findsNothing);
      expect(
        find.byType(CodeSendButton),
        findsOneWidget,
        reason: '态②同挂重发倒计时按钮(与态①共用 GlobalKey)',
      );
      expect(
        find.text('重新获取(119s)'),
        findsOneWidget,
        reason: 'retry_after 120 按截止时刻跨态恢复剩余秒',
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

    testWidgets('confirm 400 码错:错误区透出,停留态②;返回上一步回态①', (tester) async {
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
      expect(find.text('返回上一步'), findsOneWidget);

      await tester.tap(find.text('返回上一步'));
      await tester.pump();
      await tester.pump();
      expect(find.text('找回密码'), findsOneWidget);
      expect(find.text('验证码错误'), findsNothing, reason: '回态①错误区清空');

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('态②倒计时跨态连续:进入态②按剩余秒显示且随秒递减', (tester) async {
      addTearDown(resetSession);
      final auth = installFakeAuthApi();
      auth.sendResetRetry = 120;
      await pumpPage(tester);
      await sendAndReachCodeStep(tester, '13800138000');

      expect(find.text('重新获取(119s)'), findsOneWidget, reason: '进入态②显示剩余秒');
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('重新获取(116s)'), findsOneWidget, reason: '态②内倒计时持续走秒');

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('态②重发成功:用已填手机号+按 retry_after 重启倒计时', (tester) async {
      addTearDown(resetSession);
      final auth = installFakeAuthApi();
      auth.sendResetRetry = 120;
      await pumpPage(tester);
      await sendAndReachCodeStep(tester, '13800138000');

      // 冷却走完回可点态(定长 pump 推进假时钟,墙钟不动)。
      await tester.pump(const Duration(seconds: 121));
      expect(find.text('获取验证码'), findsOneWidget, reason: '倒计时结束回空闲');

      auth.sendResetRetry = 60;
      await tester.tap(find.text('获取验证码'));
      await tester.pump();
      await tester.pump();

      expect(auth.sendResetCalls, [
        '13800138000',
        '13800138000',
      ], reason: '态②重发沿用态①已填手机号,不重新输入');
      expect(find.text('输入验证码'), findsOneWidget, reason: '重发后停留态②');
      expect(
        find.text('重新获取(59s)'),
        findsOneWidget,
        reason: '重发成功以响应 retry_after 60 重启倒计时',
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('态②重发失败带 retry_after(429):重启倒计时+错误透出;无 retry_after 只透错误', (
      tester,
    ) async {
      addTearDown(resetSession);
      final auth = installFakeAuthApi();
      auth.sendResetRetry = 120;
      await pumpPage(tester);
      await sendAndReachCodeStep(tester, '13800138000');
      await tester.pump(const Duration(seconds: 121));

      // 429 带 retry_after:错误落固定错误区,同时按 raw 取值重启倒计时。
      auth.sendResetStaged = ApiException(
        429,
        '操作过于频繁,请稍后再试',
        raw: {'detail': '操作过于频繁,请稍后再试', 'retry_after': 30},
      );
      await tester.tap(find.text('获取验证码'));
      await tester.pump();
      await tester.pump();
      expect(find.text('操作过于频繁,请稍后再试'), findsOneWidget, reason: '固定错误区透出');
      expect(
        find.text('重新获取(29s)'),
        findsOneWidget,
        reason: '非 200 经 raw 取 retry_after 重启',
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('返回上一步:回态①保留已填手机号与剩余倒计时', (tester) async {
      addTearDown(resetSession);
      final auth = installFakeAuthApi();
      auth.sendResetRetry = 120;
      await pumpPage(tester);
      await sendAndReachCodeStep(tester, '13800138000');
      expect(find.text('重新获取(119s)'), findsOneWidget);

      await tester.tap(find.text('返回上一步'));
      await tester.pump();
      await tester.pump();

      expect(find.text('找回密码'), findsOneWidget, reason: '回态①');
      expect(find.text('13800138000'), findsOneWidget, reason: '已填手机号保留');
      expect(
        find.text('重新获取(119s)'),
        findsOneWidget,
        reason: '倒计时剩余按截止时刻跨态保留,不重建为空闲态',
      );
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('重新获取(117s)'), findsOneWidget, reason: '回态①后继续走秒');

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
