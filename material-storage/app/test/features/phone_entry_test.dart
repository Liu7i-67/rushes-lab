/// 入口验收(phone-bind 批,§7.1/§7.3/§7.4):
/// - 登录页:密码框与登录按钮之间右对齐「忘记密码?」,点击跳 /forgot-password;
/// - 我的页:账号与安全分组「修改密码」上方加「手机号」行,subtitle 随
///   session.me.phone 实时(完整号 / 未绑定),点击跳 /account-phone。
/// 套路:照 auth_polish2_test(me_page_stamp_test)先例,session 公开字段直接
/// 置位;routes map 挂同名标记页断言命名路由跳转;MePage 列表滚动用
/// dragUntilVisible。登录页桃花为循环动画,一律定长 pump,末尾卸载页面。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/auth/login_page.dart';
import 'package:ms_app/features/me/me_page.dart';
import 'package:ms_app/models/models.dart';

void resetSession() {
  session.phase = SessionPhase.probing;
  session.me = null;
  session.api = null;
}

Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.dragUntilVisible(
    target,
    find.byType(ListView),
    const Offset(0, -260),
  );
  await tester.pump();
}

void main() {
  group('登录页忘记密码入口(§7.1)', () {
    testWidgets('「忘记密码?」渲染,位于密码框与登录按钮之间', (tester) async {
      addTearDown(resetSession);
      await tester.pumpWidget(const MaterialApp(home: LoginPage()));
      await tester.pump();

      expect(find.text('忘记密码?'), findsOneWidget);
      // 位置序:密码字段 → 忘记密码入口 → 登录按钮
      final passwordY = tester.getTopLeft(find.text('密码')).dy;
      final forgotY = tester.getTopLeft(find.text('忘记密码?')).dy;
      final loginY = tester.getTopLeft(find.text('登录')).dy;
      expect(
        passwordY < forgotY && forgotY < loginY,
        isTrue,
        reason: '入口落在密码框与登录按钮之间',
      );
      // 右对齐:入口左缘明显越过表单中线
      final forgotLeft = tester.getTopLeft(find.text('忘记密码?')).dx;
      final loginLeft = tester.getTopLeft(find.text('登录')).dx;
      expect(forgotLeft > loginLeft, isTrue, reason: '右对齐');

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('点击跳 /forgot-password 命名路由', (tester) async {
      addTearDown(resetSession);
      await tester.pumpWidget(
        MaterialApp(
          home: const LoginPage(),
          routes: {
            '/forgot-password': (_) =>
                const Scaffold(body: Text('MARK_FORGOT')),
          },
        ),
      );
      await tester.pump();

      await tester.tap(find.text('忘记密码?'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.text('MARK_FORGOT'),
        findsOneWidget,
        reason: '跳 /forgot-password',
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('我的页手机号行(§7.3)', () {
    testWidgets('账号与安全分组:「修改密码」上方,subtitle=完整号', (tester) async {
      addTearDown(resetSession);
      session.me = Me(id: 'u-1', name: '甲', phone: '13800138000');
      await tester.pumpWidget(const MaterialApp(home: MePage()));
      await tester.pump();

      await _scrollTo(tester, find.text('手机号'));
      expect(find.text('手机号'), findsOneWidget);
      expect(find.text('13800138000'), findsOneWidget, reason: '完整号展示(D13)');

      // 行序:手机号在修改密码之上
      final phoneY = tester.getTopLeft(find.text('手机号')).dy;
      final changePwY = tester.getTopLeft(find.text('修改密码')).dy;
      expect(phoneY < changePwY, isTrue, reason: '手机号行在「修改密码」上方');

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('未绑定:subtitle=「未绑定」', (tester) async {
      addTearDown(resetSession);
      session.me = Me(id: 'u-1', name: '甲');
      await tester.pumpWidget(const MaterialApp(home: MePage()));
      await tester.pump();

      await _scrollTo(tester, find.text('手机号'));
      expect(find.text('未绑定'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('点击跳 /account-phone 命名路由', (tester) async {
      addTearDown(resetSession);
      session.me = Me(id: 'u-1', name: '甲');
      await tester.pumpWidget(
        MaterialApp(
          home: const MePage(),
          routes: {
            '/account-phone': (_) => const Scaffold(body: Text('MARK_PHONE')),
          },
        ),
      );
      await tester.pump();

      await _scrollTo(tester, find.text('手机号'));
      await tester.tap(find.text('手机号'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.text('MARK_PHONE'),
        findsOneWidget,
        reason: '跳 /account-phone',
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
