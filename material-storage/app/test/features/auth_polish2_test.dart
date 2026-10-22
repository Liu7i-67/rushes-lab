/// app-polish-2(P2 批)登录页验收用例(对应需求文档 2026-10-22-app-polish-2.md):
/// - H1(#4) 探活不阻断:探活中文案「正在连接服务…」、输入框保持可用、
///   登录钮禁用;探活完成(phase→ready)登录钮恢复可点、横幅消失;
/// - H3(#10) 法务入口:底部小字行渲染《服务条款》《隐私政策》可点链接,
///   点击经注入缝外开(openUrl recorder;优先 baseUrl 短路径,失败回退
///   /static/web/*.html,两连失败落固定错误区,不弹 toast)。
///
/// 套路:session.phase/me/baseUrl 均为公开字段直接置位;phase 切换经「重新
/// pumpWidget 触发 build 重读」(不调 notifyListeners,避免 protected 告警;
/// ready 态配 session.me 非 null 使 initState 的会话恢复短路,不触发网络)。
/// H3 按包 H 的可注入回调设计(LoginPage.openUrl)直接注入记录器。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/auth/login_page.dart';
import 'package:ms_app/models/models.dart';

void main() {
  testWidgets('H1:探活中「正在连接服务…」横幅出现,输入框可用,登录钮禁用',
      (tester) async {
    session.phase = SessionPhase.probing;
    session.me = null;
    addTearDown(() => session.me = null);

    await tester.pumpWidget(const MaterialApp(home: LoginPage()));
    await tester.pump();

    // 已交付转绿(H1):探活态文案「正在连接服务…」(原仅细进度条无文字)
    expect(find.text('正在连接服务…'), findsOneWidget,
        reason: 'H1:探活文案改「正在连接服务…」');

    // 探活期间输入框保持可用:用户名可输入落字(无禁用/遮挡)
    await tester.enterText(find.byType(TextField).first, 'alice');
    await tester.pump();
    expect(find.text('alice'), findsOneWidget, reason: 'H1:探活中输入框可用');

    // 登录钮探活中禁用
    final btn = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '登录'));
    expect(btn.onPressed, isNull, reason: 'H1:探活未完成登录钮禁用');
  });

  testWidgets('H1:探活完成登录钮恢复可点,探活横幅消失', (tester) async {
    session.phase = SessionPhase.probing;
    session.me = null;
    addTearDown(() {
      session.me = null;
      session.phase = SessionPhase.probing;
    });

    await tester.pumpWidget(const MaterialApp(home: LoginPage()));
    await tester.pump();
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '登录'))
            .onPressed,
        isNull,
        reason: '前置:探活中禁用');

    // 探活完成(phase→ready):重新挂页触发 build 重读公开字段
    // (me 非 null 令 initState 的 cookie 恢复短路,不发网络;非 const 新
    // 实例保证 update 走到 build,同 const 实例会被 updateChild 短路)
    session.phase = SessionPhase.ready;
    session.me = Me(id: 'u1', name: '甲');
    await tester.pumpWidget(MaterialApp(home: LoginPage()));
    await tester.pump();

    final btn = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '登录'));
    expect(btn.onPressed, isNotNull, reason: 'H1:探活完成登录钮恢复可点');
    expect(find.text('正在连接服务…'), findsNothing, reason: 'H1:探活横幅消失');
  });

  testWidgets('H3:渲染《服务条款》《隐私政策》可点链接;点击注入外开短路径',
      (tester) async {
    session.baseUrl = 'https://ms.test';
    session.me = null;
    addTearDown(() {
      session.baseUrl = null;
      session.me = null;
    });
    final opened = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: LoginPage(
        openUrl: (url) async {
          opened.add(url);
          return true;
        },
      ),
    ));
    await tester.pump();

    expect(find.text('《服务条款》'), findsOneWidget, reason: 'H3:条款链接渲染');
    expect(find.text('《隐私政策》'), findsOneWidget, reason: 'H3:隐私链接渲染');

    await tester.tap(find.text('《服务条款》'));
    await tester.pump();
    await tester.tap(find.text('《隐私政策》'));
    await tester.pump();

    expect(opened, [
      'https://ms.test/terms',
      'https://ms.test/privacy',
    ], reason: 'H3:优先公网 nginx 短路径外开(url_launcher externalApplication 同参)');
    expect(find.text('打开失败,请稍后重试'), findsNothing,
        reason: '打开成功不落错误区');
  });

  testWidgets('H3:外开失败回退静态页路径;两连失败落固定错误区(不弹 toast)',
      (tester) async {
    session.baseUrl = 'https://ms.test';
    session.me = null;
    addTearDown(() {
      session.baseUrl = null;
      session.me = null;
    });
    final opened = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: LoginPage(
        openUrl: (url) async {
          opened.add(url);
          return false; // 模拟外开失败(无法打开浏览器等)
        },
      ),
    ));
    await tester.pump();

    await tester.tap(find.text('《服务条款》'));
    await tester.pump();

    expect(opened, [
      'https://ms.test/terms',
      'https://ms.test/static/web/terms.html',
    ], reason: 'H3:短路径失败回退 api 静态页');

    // 已交付转绿(H3):两连失败落固定错误区文案
    expect(find.text('打开失败,请稍后重试'), findsOneWidget,
        reason: 'H3:两连失败落固定错误提示');
    expect(find.byType(SnackBar), findsNothing, reason: 'H3:不弹 toast 打扰');
  });
}
