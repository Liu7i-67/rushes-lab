/// P9 页面级集成单测(组件本体见 test/widgets/password_field_test.dart):
/// 登录页与改密页 4 处密码框替换 PasswordField 后——
/// - 每处都有眼睛切换,切换明文/遮挡且 controller 内容保持;
/// - 改密页三框遮挡态互相独立;
/// - 表单提交行为不回退(改密校验链原样;登录页提交钮结构不变;app-polish
///   E1 起登录页右上角日志入口移除,断言已同步翻转)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/features/auth/change_password_page.dart';
import 'package:ms_app/features/auth/login_page.dart';
import 'package:ms_app/widgets/app_card.dart';
import 'package:ms_app/widgets/page_header.dart';

/// 第 [i] 个可编辑框的遮挡态与内容
({bool obscure, String text}) fieldState(WidgetTester tester, int i) {
  final e = tester.widget<EditableText>(find.byType(EditableText).at(i));
  return (obscure: e.obscureText, text: e.controller.text);
}

void main() {
  group('P9:登录页密码框(替换后表单结构不回退)', () {
    testWidgets('眼睛切换明文/遮挡,内容保持;登录钮与日志入口结构不变', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: LoginPage()));
      await tester.pump();

      // 两个输入框:0=用户名(明文),1=密码(默认遮挡)
      expect(fieldState(tester, 0).obscure, isFalse);
      expect(fieldState(tester, 1).obscure, isTrue, reason: '默认遮挡');
      expect(
        find.byIcon(Icons.visibility_outlined),
        findsOneWidget,
        reason: '遮挡态亮「显示」眼睛钮',
      );

      await tester.enterText(find.byType(TextField).at(1), 's3cret!');
      expect(fieldState(tester, 1).text, 's3cret!');

      // 切明文:内容保持,眼睛图标翻转
      await tester.tap(find.byIcon(Icons.visibility_outlined));
      await tester.pump();
      expect(fieldState(tester, 1).obscure, isFalse);
      expect(fieldState(tester, 1).text, 's3cret!', reason: '切换不丢已输入内容');
      expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);

      // 再切回遮挡
      await tester.tap(find.byIcon(Icons.visibility_off_outlined));
      await tester.pump();
      expect(fieldState(tester, 1).obscure, isTrue);
      expect(fieldState(tester, 1).text, 's3cret!');

      // 表单结构回归:登录钮存在(探活未就绪禁用);E1 起右上角日志推送
      // 入口移除(功能保留在「我的」诊断区,pages_polish E1 验收同口径)
      final loginBtn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '登录'),
      );
      expect(loginBtn.onPressed, isNull, reason: '探活未就绪(probing)时禁用——提交闸门行为不变');
      expect(
        find.byIcon(Icons.bug_report_outlined),
        findsNothing,
        reason: 'app-polish E1:登录页日志推送入口移除(并入我的页诊断组)',
      );
    });
  });

  group('P9:改密页三框独立切换 + 提交校验不回退', () {
    Future<void> pumpPage(WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: ChangePasswordPage(forced: false)),
      );
      await tester.pump();
    }

    testWidgets('P2-10:二级页头(PageHeader)+ AppCard 表单容器,无 AppBar', (
      tester,
    ) async {
      await pumpPage(tester);

      expect(
        find.byType(AppBar),
        findsNothing,
        reason: 'AppBar 由 PageHeader 取代',
      );
      expect(find.byType(PageHeader), findsOneWidget);
      expect(find.text('修改密码'), findsOneWidget);
      expect(find.text('至少 8 位，包含字母与数字'), findsOneWidget);
      expect(find.byTooltip('返回'), findsOneWidget, reason: '非强制流保留返回');
      expect(find.byType(AppCard), findsOneWidget, reason: '表单容器=AppCard');
      expect(find.text('退出登录'), findsNothing, reason: '非强制流无退出出口');
    });

    testWidgets('P2-10:强制改密流保留「退出登录」且无返回键', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: ChangePasswordPage(forced: true)),
      );
      await tester.pump();

      expect(find.byType(PageHeader), findsOneWidget);
      expect(find.text('设置新密码'), findsOneWidget);
      expect(find.byTooltip('返回'), findsNothing, reason: '强制流不可返回');
      expect(find.text('退出登录'), findsOneWidget, reason: '保留退出出口');
    });

    testWidgets('三框各自独立遮挡;切换互不影响且内容保持', (tester) async {
      await pumpPage(tester);

      await tester.enterText(find.byType(TextField).at(0), 'old123');
      await tester.enterText(find.byType(TextField).at(1), 'new123');
      await tester.enterText(find.byType(TextField).at(2), 'new123');
      expect(find.byIcon(Icons.visibility_outlined), findsNWidgets(3));

      // 只切「新密码」框:其余两框遮挡态不动
      await tester.tap(find.byIcon(Icons.visibility_outlined).at(1));
      await tester.pump();
      expect(fieldState(tester, 0).obscure, isTrue);
      expect(fieldState(tester, 1).obscure, isFalse, reason: '新密码框已明文');
      expect(fieldState(tester, 2).obscure, isTrue);
      expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);

      // 切换后内容保持
      expect(fieldState(tester, 0).text, 'old123');
      expect(fieldState(tester, 1).text, 'new123');
      expect(fieldState(tester, 2).text, 'new123');
    });

    testWidgets('切换遮挡后提交,校验链原样(两次不一致即拦,不触发请求)', (tester) async {
      await pumpPage(tester);

      await tester.enterText(find.byType(TextField).at(0), 'old123');
      await tester.enterText(find.byType(TextField).at(1), 'new123');
      await tester.enterText(find.byType(TextField).at(2), 'nope');
      // 全部切到明文再提交:内容可读且校验照常
      while (find.byIcon(Icons.visibility_outlined).evaluate().isNotEmpty) {
        await tester.tap(find.byIcon(Icons.visibility_outlined).first);
        await tester.pump();
      }
      await tester.tap(find.widgetWithText(FilledButton, '确认修改'));
      await tester.pump();

      expect(
        find.text('两次输入的新密码不一致'),
        findsOneWidget,
        reason: 'PasswordField 替换不改变表单校验(未通过不发请求)',
      );
      expect(fieldState(tester, 1).text, 'new123', reason: '提交校验后已输入内容仍在');
    });
  });
}
