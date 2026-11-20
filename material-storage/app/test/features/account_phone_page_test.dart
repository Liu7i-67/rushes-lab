/// AccountPhonePage 验收(phone-bind 批,§7.3/§7.4):
/// - 当前绑定展示(完整号/未绑定)与提交按钮文案(绑定/确认换绑);
/// - 发送:成功 toast+倒计时;409 占用 → detail 透出且按钮立即可再点
///   (无 retry_after 不 start,后端已回滚冷却);429 带 retry_after → 倒计时;
/// - 提交:成功 → bind 入参、refreshMe(me 重取)、pop、我的页 subtitle 同步;
///   失败 → 固定错误区不 pop。
/// 套路:FakeAuthApi 注入全局 session(照 api_harness FakeXxxApi 先例);
/// 倒计时用 tester.pump(Duration) 控时;用例末尾卸载页面/冲掉 toast 定时器,
/// 防悬置 Timer 触发框架断言。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/components/code_send_button.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/me/account_phone_page.dart';
import 'package:ms_app/features/me/me_page.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/widgets/form_text_field.dart';

import '../helpers/fake_auth_phone.dart';

void resetSession() {
  session.api = null;
  session.me = null;
}

/// 冲掉 toast 自动销毁 Timer(2.4s 到时 + 150ms 退场),防悬置定时器。
Future<void> flushToast(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pump(const Duration(milliseconds: 200));
}

Future<void> enterPhoneAndCode(WidgetTester tester) async {
  await tester.enterText(find.byType(AppTextField).first, '13800138000');
  await tester.enterText(find.byType(AppTextField).last, 'AB12CD');
  await tester.pump();
  await tester.pump();
}

void main() {
  group('AccountPhonePage', () {
    testWidgets('未绑定初态:「未绑定」提示 + 主按钮「绑定」', (tester) async {
      addTearDown(resetSession);
      installFakeAuthApi(
        me: Me(id: 'u-1', name: '甲'),
      );
      await tester.pumpWidget(const MaterialApp(home: AccountPhonePage()));
      await tester.pump();

      expect(find.text('当前绑定'), findsOneWidget);
      expect(find.text('未绑定'), findsOneWidget);
      expect(find.text('绑定'), findsOneWidget, reason: '未绑定态主按钮=绑定');
      expect(find.byType(CodeSendButton), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('已绑定初态:完整号展示(D13)+ 主按钮「确认换绑」', (tester) async {
      addTearDown(resetSession);
      installFakeAuthApi(
        me: Me(id: 'u-1', name: '甲', phone: '13800138000'),
      );
      await tester.pumpWidget(const MaterialApp(home: AccountPhonePage()));
      await tester.pump();

      expect(find.text('13800138000'), findsOneWidget, reason: '完整号展示');
      expect(find.text('确认换绑'), findsOneWidget, reason: '已绑定态主按钮=确认换绑');

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('发送成功:入参记录 + toast + 以 retry_after 启动倒计时', (tester) async {
      addTearDown(resetSession);
      final auth = installFakeAuthApi(
        me: Me(id: 'u-1', name: '甲'),
      );
      auth.sendBindRetry = 120;
      await tester.pumpWidget(const MaterialApp(home: AccountPhonePage()));
      await tester.pump();

      await tester.enterText(find.byType(AppTextField).first, '13800138000');
      await tester.tap(find.text('获取验证码'));
      await tester.pump();
      await tester.pump();

      expect(auth.sendBindCalls, [
        '13800138000',
      ], reason: '入参=输入原文(trim 后交服务端归一化)');
      expect(find.text('验证码已发送'), findsOneWidget, reason: '成功 toast');
      expect(
        find.text('重新获取(120s)'),
        findsOneWidget,
        reason: 'retry_after=120 启动倒计时',
      );

      await flushToast(tester);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('409 占用:detail 透出 + 无 retry_after 不倒计时(按钮立即可再点)', (
      tester,
    ) async {
      addTearDown(resetSession);
      final auth = installFakeAuthApi(
        me: Me(id: 'u-1', name: '甲'),
      );
      auth.sendBindStaged = ApiException(409, '该手机号已绑定其他账号');
      await tester.pumpWidget(const MaterialApp(home: AccountPhonePage()));
      await tester.pump();

      await tester.enterText(find.byType(AppTextField).first, '13800138000');
      await tester.tap(find.text('获取验证码'));
      await tester.pump();
      await tester.pump();

      expect(find.text('该手机号已绑定其他账号'), findsOneWidget, reason: '固定错误区透出');
      final btn = tester.widget<CodeSendButton>(find.byType(CodeSendButton));
      expect(btn.busy, isFalse);
      expect(
        tester.state<CodeSendButtonState>(find.byType(CodeSendButton)).counting,
        isFalse,
        reason: '409 后端已回滚冷却 → 不 start',
      );
      final outlined = tester.widget<OutlinedButton>(
        find.descendant(
          of: find.byType(CodeSendButton),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(outlined.onPressed, isNotNull, reason: '立即可再点');

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('429 冷却:raw.retry_after 读出并启动倒计时', (tester) async {
      addTearDown(resetSession);
      final auth = installFakeAuthApi(
        me: Me(id: 'u-1', name: '甲'),
      );
      auth.sendBindStaged = ApiException(
        429,
        '发送太频繁,请稍后再试',
        raw: {'detail': '发送太频繁,请稍后再试', 'retry_after': 95},
      );
      await tester.pumpWidget(const MaterialApp(home: AccountPhonePage()));
      await tester.pump();

      await tester.enterText(find.byType(AppTextField).first, '13800138000');
      await tester.tap(find.text('获取验证码'));
      await tester.pump();
      await tester.pump();

      expect(find.text('发送太频繁,请稍后再试'), findsOneWidget);
      expect(
        find.text('重新获取(95s)'),
        findsOneWidget,
        reason: 'raw[retry_after]=95',
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('绑定失败:错误区透出,不 pop、不刷新 me', (tester) async {
      addTearDown(resetSession);
      final auth = installFakeAuthApi(
        me: Me(id: 'u-1', name: '甲'),
      );
      auth.bindStaged = ApiException(400, '验证码错误');
      await tester.pumpWidget(const MaterialApp(home: AccountPhonePage()));
      await tester.pump();
      await enterPhoneAndCode(tester);

      await tester.tap(find.text('绑定'));
      await tester.pump();
      await tester.pump();

      expect(find.text('验证码错误'), findsOneWidget);
      expect(auth.bindCalls.single.phone, '13800138000');
      expect(auth.meCalls, 0, reason: '绑定失败不触发 refreshMe');
      expect(find.byType(AccountPhonePage), findsOneWidget, reason: '失败留在本页');

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('绑定成功全链:refreshMe + pop + 我的页 subtitle 同步', (tester) async {
      addTearDown(resetSession);
      final auth = installFakeAuthApi(
        me: Me(id: 'u-1', name: '甲'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: const MePage(),
          routes: {'/account-phone': (_) => const AccountPhonePage()},
        ),
      );
      await tester.pump();

      // 滚到账号与安全分组,点「手机号」行进入
      await tester.dragUntilVisible(
        find.text('手机号'),
        find.byType(ListView),
        const Offset(0, -260),
      );
      await tester.pump();
      expect(find.text('未绑定'), findsOneWidget, reason: '前置:未绑定 subtitle');
      await tester.tap(find.text('手机号'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AccountPhonePage), findsOneWidget);

      await enterPhoneAndCode(tester);
      auth.meResult = Me(id: 'u-1', name: '甲', phone: '13800138000');
      await tester.tap(find.text('绑定'));
      await tester.pump();
      await tester.pump();

      expect(auth.bindCalls.single.phone, '13800138000');
      expect(auth.bindCalls.single.code, 'AB12CD');
      expect(auth.meCalls, 1, reason: 'refreshMe 重取 me');
      expect(find.text('手机号已绑定'), findsOneWidget, reason: '成功 toast');

      await flushToast(tester);
      expect(find.byType(AccountPhonePage), findsNothing, reason: '成功后 pop');
      expect(
        find.text('13800138000'),
        findsOneWidget,
        reason: '我的页 subtitle 经 notifyListeners 同步',
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
