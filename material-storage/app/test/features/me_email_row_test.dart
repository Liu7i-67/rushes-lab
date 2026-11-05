/// 我的页「邮箱」行(邮箱账号方案 §7.3):
/// - 显隐纯函数:仅明确 emailAuthEnabled == false 且无邮箱才隐藏
///   (unknown/true 都显示;已有邮箱始终显示);
/// - 副标题:当前邮箱(未验证加注)/ 未绑定;
/// - MePage 实渲染:账号与安全组内「修改密码」上方出现邮箱行,
///   点击 pushNamed('/account/email') 可达邮箱页。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/app.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/me/account_email_page.dart';
import 'package:ms_app/features/me/me_page.dart';
import 'package:ms_app/models/models.dart';

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

  group('showMeEmailRow / emailRowSubtitle(纯函数)', () {
    test('config=true:无邮箱也显示', () {
      expect(showMeEmailRow(meOf(), emailAuthEnabled: true), isTrue);
    });

    test('config=null(unknown):显示(fail-open 兜底)', () {
      expect(showMeEmailRow(meOf(), emailAuthEnabled: null), isTrue);
    });

    test('config=false 且无邮箱:隐藏(唯一隐藏分支)', () {
      expect(showMeEmailRow(meOf(), emailAuthEnabled: false), isFalse);
    });

    test('config=false 但已有邮箱:仍显示(页内只留解绑)', () {
      expect(
        showMeEmailRow(meOf(email: 'a@x.com'), emailAuthEnabled: false),
        isTrue,
      );
    });

    test('me=null:按无邮箱口径(config=false 隐藏 / 其余显示)', () {
      expect(showMeEmailRow(null, emailAuthEnabled: false), isFalse);
      expect(showMeEmailRow(null, emailAuthEnabled: null), isTrue);
    });

    test('副标题:无邮箱=未绑定;有邮箱未验证加注;已验证裸邮箱', () {
      expect(emailRowSubtitle(meOf()), '未绑定');
      expect(emailRowSubtitle(meOf(email: 'a@x.com')), 'a@x.com(未验证)');
      expect(
        emailRowSubtitle(meOf(email: 'a@x.com', verified: true)),
        'a@x.com',
      );
    });
  });

  group('MePage 账号与安全组「邮箱」行', () {
    Future<void> pumpMe(WidgetTester tester) async {
      // onGenerateRoute 接 msOnGenerateRoute:邮箱行点击 pushNamed 可达
      await tester.pumpWidget(MaterialApp(
        onGenerateRoute: msOnGenerateRoute,
        home: const MePage(),
      ));
      await tester.pump();
      await tester.pump();
    }

    Future<void> scrollRowIntoView(WidgetTester tester) async {
      await tester.dragUntilVisible(
        find.text('邮箱'),
        find.byType(ListView),
        const Offset(0, -260),
      );
      await tester.pump();
    }

    testWidgets('有邮箱:邮箱行渲染(修改密码上方),点击进邮箱页', (tester) async {
      addTearDown(resetSession);
      session.me = meOf(email: 'alice@example.com', verified: true);
      await pumpMe(tester);
      await scrollRowIntoView(tester);

      expect(find.text('邮箱'), findsOneWidget);
      expect(find.text('alice@example.com'), findsOneWidget, reason: '副标题=当前邮箱');

      await tester.tap(find.text('邮箱'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AccountEmailPage), findsOneWidget,
          reason: '/account/email 路由可达(app.dart 已接线)');
    });

    testWidgets('config=false 且无邮箱:整行隐藏(修改密码行仍在上)', (tester) async {
      addTearDown(resetSession);
      session.me = meOf();
      session.emailAuthEnabled = false;
      await pumpMe(tester);
      await tester.dragUntilVisible(
        find.text('修改密码'),
        find.byType(ListView),
        const Offset(0, -260),
      );
      await tester.pump();

      expect(find.text('邮箱'), findsNothing, reason: '唯一隐藏分支');
      expect(find.text('修改密码'), findsOneWidget);
    });

    testWidgets('无邮箱 + config unknown:行渲染,副标题未绑定', (tester) async {
      addTearDown(resetSession);
      session.me = meOf();
      await pumpMe(tester);
      await scrollRowIntoView(tester);

      expect(find.text('邮箱'), findsOneWidget);
      expect(find.text('未绑定'), findsOneWidget);
    });
  });
}
