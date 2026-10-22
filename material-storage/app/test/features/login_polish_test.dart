/// app-polish-2 包 H(登录页三项真机反馈修复,docs/qdev/2026-10-22-app-polish-2.md):
/// - H1(#4) 探活不阻断:探活横幅文案「正在连接服务…」;探活期间用户名/密码
///   框保持可用;登录钮探活中禁用、phase→ready 即恢复;
/// - H2(#10a) 品牌区真 logo:Image.asset('assets/logo.png') 圆角裁剪替代
///   语义图标占位(标题排版保留);
/// - H3(#10b) 法务入口:底部「登录即代表同意《服务条款》与《隐私政策》」,
///   两个书名号可点,经注入 openUrl 记录外开 URL(短路径→静态页回退→
///   两连失败落固定错误区,不 toast)。
///
/// session 为全局单例:用例直接改 phase/baseUrl/me 并 notifyListeners 走
/// 页面真监听路径;各用例 addTearDown 复位,互不污染。openUrl 注入缝替代
/// mock platform channel(实现成本低且断言直接)。
// ignore_for_file: invalid_use_of_protected_member
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/auth/login_page.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/theme/tokens.dart';

void main() {
  // 单例复位:离开用例前回到冷启动默认态(probing / 未定 baseUrl / 未登录)
  void resetSession() {
    session.phase = SessionPhase.probing;
    session.baseUrl = null;
    session.me = null;
  }

  Future<void> pumpLogin(
    WidgetTester tester, {
    Future<bool> Function(String url)? openUrl,
  }) async {
    await tester.pumpWidget(MaterialApp(home: LoginPage(openUrl: openUrl)));
    await tester.pump();
  }

  FilledButton loginButton(WidgetTester tester) => tester
      .widget<FilledButton>(find.widgetWithText(FilledButton, '登录'));

  // ── H1(#4) 探活不阻断 ──────────────────────────────────────────────────
  testWidgets('H1:探活中横幅文案「正在连接服务…」+进度条,输入框可用可输入',
      (tester) async {
    addTearDown(resetSession);
    expect(session.phase, SessionPhase.probing, reason: '前置:单例冷启动默认态');
    await pumpLogin(tester);

    expect(find.text('正在连接服务…'), findsOneWidget,
        reason: 'H1:探测中文案直白(替代费解的「优化网络」表述)');
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    final username = tester
        .widget<TextField>(find.widgetWithText(TextField, '用户名 / 邮箱'));
    final password =
        tester.widget<TextField>(find.widgetWithText(TextField, '密码'));
    expect(username.enabled, isNot(false),
        reason: 'H1:探活期间用户名框不禁用');
    expect(password.enabled, isNot(false), reason: 'H1:探活期间密码框不禁用');

    // 实际可输入(探活未完成也能先把账密填好)
    await tester.enterText(find.widgetWithText(TextField, '用户名 / 邮箱'), 'alice');
    expect(find.text('alice'), findsOneWidget);

    expect(loginButton(tester).onPressed, isNull,
        reason: 'H1:登录钮探活中禁用(phase != ready)');
  });

  testWidgets('H1:phase→ready 登录钮恢复可点、探测横幅消失', (tester) async {
    addTearDown(resetSession);
    await pumpLogin(tester);
    expect(loginButton(tester).onPressed, isNull, reason: '前置:探活中禁用');

    // 走真监听路径:置 ready + notify(me 先置非空,避开 restore 分支)
    session.me = Me(id: 'u1', name: '甲');
    session.phase = SessionPhase.ready;
    session.notifyListeners();
    await tester.pump();

    expect(loginButton(tester).onPressed, isNotNull,
        reason: 'H1:探活完成登录钮即恢复');
    expect(find.text('正在连接服务…'), findsNothing, reason: 'H1:就绪横幅收起');
  });

  // ── H2(#10a) 品牌区真 logo ─────────────────────────────────────────────
  testWidgets('H2:品牌区 assets/logo.png 圆角裁剪,语义图标占位置换,排版保留',
      (tester) async {
    addTearDown(resetSession);
    await pumpLogin(tester);

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<AssetImage>()
        .having((a) => a.assetName, 'assetName', 'assets/logo.png'),
        reason: 'H2:登录页用真 logo 资源');
    expect(image.width, 72, reason: 'H2:尺寸沿用品牌区原排版');
    expect(image.height, 72);
    expect(image.fit, BoxFit.cover, reason: 'H2:圆角容器内裁剪');
    final clip = tester.widget<ClipRRect>(find.byType(ClipRRect));
    expect(clip.borderRadius, const BorderRadius.all(Radius.circular(Tk.rLg)),
        reason: 'H2:Tk.rLg 圆角裁剪');

    expect(find.byIcon(Icons.movie_filter_outlined), findsNothing,
        reason: 'H2:语义图标占位已移除');
    expect(find.text('浣花视界'), findsOneWidget, reason: 'H2:标题排版保留');
    expect(find.text('素材管理协作平台'), findsOneWidget);
  });

  // ── H3(#10b) 法务入口 ──────────────────────────────────────────────────
  testWidgets('H3:底部渲染法务小字行(同意文案 + 两个书名号链接)', (tester) async {
    addTearDown(resetSession);
    await pumpLogin(tester);

    expect(find.textContaining('登录即代表同意'), findsOneWidget);
    expect(find.text('《服务条款》'), findsOneWidget);
    expect(find.text('《隐私政策》'), findsOneWidget);
  });

  testWidgets('H3:点《服务条款》外开短路径 {baseUrl}/terms,成功不落错误区',
      (tester) async {
    addTearDown(resetSession);
    session.baseUrl = 'https://b6.test.local';
    final urls = <String>[];
    await pumpLogin(tester, openUrl: (u) async {
      urls.add(u);
      return true;
    });

    await tester.tap(find.text('《服务条款》'));
    await tester.pump();

    expect(urls, ['https://b6.test.local/terms'], reason: 'H3:优先公网短路径');
    expect(find.text('打开失败,请稍后重试'), findsNothing, reason: 'H3:打开成功不提示');
  });

  testWidgets('H3:短路径失败回退 /static/web/privacy.html,再失败落固定错误区',
      (tester) async {
    addTearDown(resetSession);
    session.baseUrl = 'https://b6.test.local';
    final urls = <String>[];
    await pumpLogin(tester, openUrl: (u) async {
      urls.add(u);
      return false;
    });

    await tester.tap(find.text('《隐私政策》'));
    await tester.pump(); // 第一次外开(短路径)返回
    await tester.pump(); // 第二次外开(静态页)+ 错误区 setState

    expect(
        urls,
        const [
          'https://b6.test.local/privacy',
          'https://b6.test.local/static/web/privacy.html',
        ],
        reason: 'H3:短路径失败回退 api 静态页(§决策#10)');
    expect(find.text('打开失败,请稍后重试'), findsOneWidget,
        reason: 'H3:两连失败落固定错误区(不 toast)');
  });

  testWidgets('H3:baseUrl 未就绪(探活未完成)点链接直接落错误区,不外开',
      (tester) async {
    addTearDown(resetSession);
    session.baseUrl = null;
    var calls = 0;
    await pumpLogin(tester, openUrl: (u) async {
      calls++;
      return true;
    });

    await tester.tap(find.text('《服务条款》'));
    await tester.pump();
    await tester.pump();

    expect(calls, 0, reason: 'H3:无从拼 URL,不发起外开');
    expect(find.text('打开失败,请稍后重试'), findsOneWidget);
  });
}
