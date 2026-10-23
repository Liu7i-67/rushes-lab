/// 登录页验收(app-polish-2 H1/H2/H3 + 墨金 WP3):探活闸门与状态行(金点/
/// 不可达暖色卡)、品牌区真 logo 66 + wordmark 21/.18em + 金线、双主题令牌、
/// 法务外开短路径→静态页回退→错误区。登录页有桃花循环动画:全部用例只用
/// 定长 pump(禁止 pumpAndSettle);session 单例由 addTearDown 复位。
// ignore_for_file: invalid_use_of_protected_member
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/auth/login_brand.dart';
import 'package:ms_app/features/auth/login_form.dart';
import 'package:ms_app/features/auth/login_page.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/theme/app_theme.dart';
import 'package:ms_app/theme/tk_colors.dart';
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

  FilledButton loginButton(WidgetTester tester) =>
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, '登录'));

  // ── H1(#4) 探活不阻断 ──────────────────────────────────────────────────
  testWidgets('H1:探活中「正在连接服务…」+ 金色脉冲点,输入框可用可输入', (tester) async {
    addTearDown(resetSession);
    expect(session.phase, SessionPhase.probing, reason: '前置:单例冷启动默认态');
    await pumpLogin(tester);

    expect(
      find.text('正在连接服务…'),
      findsOneWidget,
      reason: 'H1:探测中文案直白(替代费解的「优化网络」表述)',
    );
    expect(
      find.byKey(const Key('login_probe_pulse')),
      findsOneWidget,
      reason: 'WP3:探测中为金色脉冲圆点(替代线性进度条)',
    );
    expect(
      find.byType(LinearProgressIndicator),
      findsNothing,
      reason: 'WP3:F5 设计以金点脉冲表达探测中',
    );

    final username = tester.widget<TextField>(
      find.widgetWithText(TextField, '用户名 / 邮箱'),
    );
    final password = tester.widget<TextField>(
      find.widgetWithText(TextField, '密码'),
    );
    expect(username.enabled, isNot(false), reason: 'H1:探活期间用户名框不禁用');
    expect(password.enabled, isNot(false), reason: 'H1:探活期间密码框不禁用');

    // 实际可输入(探活未完成也能先把账密填好)
    await tester.enterText(find.widgetWithText(TextField, '用户名 / 邮箱'), 'alice');
    expect(find.text('alice'), findsOneWidget);

    expect(
      loginButton(tester).onPressed,
      isNull,
      reason: 'H1:登录钮探活中禁用(phase != ready)',
    );
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

    expect(loginButton(tester).onPressed, isNotNull, reason: 'H1:探活完成登录钮即恢复');
    expect(find.text('正在连接服务…'), findsNothing, reason: 'H1:就绪横幅收起');
  });

  testWidgets('F5:探活不可达显示暖色卡(surface2/rMd/warn)与重试', (tester) async {
    addTearDown(resetSession);
    session.phase = SessionPhase.unreachable;
    await pumpLogin(tester);

    expect(find.text('服务不可达,请检查网络后重试'), findsOneWidget);
    expect(find.byIcon(Icons.wifi_off_outlined), findsOneWidget);
    final card = tester.widget<Container>(
      find.byKey(const Key('login_unreachable')),
    );
    final deco = card.decoration! as BoxDecoration;
    expect(deco.color, TkColors.light.surface2, reason: 'F5:暖色卡 surface2 底');
    expect(deco.borderRadius, BorderRadius.circular(Tk.rMd));
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '重试'))
          .onPressed,
      isNotNull,
      reason: 'F5:右侧重试可点(session.probe)',
    );
    expect(loginButton(tester).onPressed, isNull, reason: '不可达时登录闸门仍关闭');
  });

  // ── H2(#10a) + WP3 品牌区 ──────────────────────────────────────────────
  testWidgets('H2/WP3:品牌区 logo 66×66 rLg 金描边,wordmark 21/.18em + 金线', (
    tester,
  ) async {
    addTearDown(resetSession);
    await pumpLogin(tester);

    final image = tester.widget<Image>(find.byType(Image));
    expect(
      image.image,
      isA<AssetImage>().having(
        (a) => a.assetName,
        'assetName',
        'assets/logo.png',
      ),
      reason: 'H2:登录页用真 logo 资源',
    );
    expect(image.width, 66, reason: 'WP3:F5 logo 66');
    expect(image.height, 66);
    expect(image.fit, BoxFit.cover, reason: 'WP3:圆角容器内裁剪');

    final clip = tester.widget<ClipRRect>(find.byType(ClipRRect));
    expect(
      clip.borderRadius,
      const BorderRadius.all(Radius.circular(Tk.rLg)),
      reason: 'WP3:圆角 18 = Tk.rLg',
    );

    final wordmark = tester.widget<Text>(find.text('浣花视界'));
    expect(wordmark.style?.fontSize, 21, reason: 'WP3:F5 wordmark 21');
    expect(wordmark.style?.fontWeight, FontWeight.w600);
    expect(
      wordmark.style?.letterSpacing,
      closeTo(21 * 0.18, 0.001),
      reason: 'WP3:字距 .18em',
    );
    expect(
      wordmark.style?.color,
      TkColors.light.ink,
      reason: '无 extension 的裸 MaterialApp 回退浅色令牌',
    );

    final brandContainers = tester
        .widgetList<Container>(
          find.descendant(
            of: find.byType(LoginBrand),
            matching: find.byType(Container),
          ),
        )
        .toList();
    expect(brandContainers.length, 2, reason: 'logo 容器 + 金线');
    final line = brandContainers.last;
    expect(
      line.constraints,
      BoxConstraints.tightFor(width: 26, height: 1),
      reason: 'WP3:26×1 金色渐变细线',
    );
    expect(
      line.decoration,
      isA<BoxDecoration>().having(
        (d) => d.gradient,
        'gradient',
        isA<LinearGradient>(),
      ),
    );
  });

  testWidgets('WP3:深色主题下背景/文字取 TkColors.dark 令牌', (tester) async {
    addTearDown(resetSession);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: const LoginPage(),
      ),
    );
    await tester.pump();

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(
      scaffold.backgroundColor,
      TkColors.dark.bg,
      reason: 'F5:Scaffold 背景 = tk.bg',
    );

    final bg = tester.widget<Container>(find.byKey(const Key('login_bg')));
    expect(
      (bg.decoration as BoxDecoration).gradient,
      TkColors.dark.loginBg,
      reason: 'F5:背景层用 tk.loginBg 渐变',
    );
    final glow = tester.widget<Container>(find.byKey(const Key('login_glow')));
    expect(
      (glow.decoration as BoxDecoration).gradient,
      TkColors.dark.loginGlow,
      reason: 'F5:右上金色光晕取 tk.loginGlow',
    );
    expect(
      tester.widget<Text>(find.text('浣花视界')).style?.color,
      TkColors.dark.ink,
      reason: 'F5:wordmark 用 tk.ink',
    );
  });

  // ── P2-1 小屏 + 放大字号 / P2-6 法务语义 ───────────────────────────────
  testWidgets('P2-1:320 宽 + 1.3 字号错误区两行自然增高不裁切', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final username = TextEditingController();
    final password = TextEditingController();
    addTearDown(username.dispose);
    addTearDown(password.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: LoginForm(
                  usernameController: username,
                  passwordController: password,
                  busy: false,
                  error: '打开失败,请稍后重试',
                  phase: SessionPhase.ready,
                  onSubmit: () {},
                  onRetry: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull, reason: '320/1.3 无溢出异常');
    final error = find.text('打开失败,请稍后重试');
    expect(error, findsOneWidget);
    final paragraph = tester.renderObject<RenderParagraph>(error);
    expect(paragraph.didExceedMaxLines, isFalse, reason: '错误文案两行内完整显示');
    // 最小 48 高占位保留:1.3 字号下随两行自然增高,不裁切。
    final area = tester.getSize(
      find.ancestor(of: error, matching: find.byType(Align)).first,
    );
    expect(area.height, greaterThanOrEqualTo(48));
  });

  testWidgets('P2-6:法务链接语义 link + 名称,触控区 ≥44 高', (tester) async {
    addTearDown(resetSession);
    await pumpLogin(tester);

    final terms = find.byWidgetPredicate(
      (w) =>
          w is Semantics &&
          w.properties.link == true &&
          w.properties.label == '服务条款',
    );
    final privacy = find.byWidgetPredicate(
      (w) =>
          w is Semantics &&
          w.properties.link == true &&
          w.properties.label == '隐私政策',
    );
    expect(terms, findsOneWidget, reason: '服务条款标为 link 语义');
    expect(privacy, findsOneWidget, reason: '隐私政策标为 link 语义');
    expect(
      tester.getSize(terms).height,
      greaterThanOrEqualTo(44),
      reason: '法务链接触控区高度 ≥44',
    );
    // 点击仍走原外开链路(语义节点不拦截命中)。
    session.baseUrl = 'https://b6.test.local';
    final urls = <String>[];
    await pumpLogin(
      tester,
      openUrl: (u) async {
        urls.add(u);
        return true;
      },
    );
    await tester.tap(find.text('《服务条款》'));
    await tester.pump();
    expect(urls, ['https://b6.test.local/terms']);
  });

  // ── H3(#10b) 法务入口 ──────────────────────────────────────────────────
  testWidgets('H3:底部渲染法务小字行(同意文案 + 两个书名号链接)', (tester) async {
    addTearDown(resetSession);
    await pumpLogin(tester);

    expect(find.textContaining('登录即代表同意'), findsOneWidget);
    expect(find.text('《服务条款》'), findsOneWidget);
    expect(find.text('《隐私政策》'), findsOneWidget);
  });

  testWidgets('H3:点《服务条款》外开短路径 {baseUrl}/terms,成功不落错误区', (tester) async {
    addTearDown(resetSession);
    session.baseUrl = 'https://b6.test.local';
    final urls = <String>[];
    await pumpLogin(
      tester,
      openUrl: (u) async {
        urls.add(u);
        return true;
      },
    );

    await tester.tap(find.text('《服务条款》'));
    await tester.pump();

    expect(urls, ['https://b6.test.local/terms'], reason: 'H3:优先公网短路径');
    expect(find.text('打开失败,请稍后重试'), findsNothing, reason: 'H3:打开成功不提示');
  });

  testWidgets('H3:短路径失败回退 /static/web/privacy.html,再失败落固定错误区', (tester) async {
    addTearDown(resetSession);
    session.baseUrl = 'https://b6.test.local';
    final urls = <String>[];
    await pumpLogin(
      tester,
      openUrl: (u) async {
        urls.add(u);
        return false;
      },
    );

    await tester.tap(find.text('《隐私政策》'));
    await tester.pump(); // 第一次外开(短路径)返回
    await tester.pump(); // 第二次外开(静态页)+ 错误区 setState

    expect(urls, const [
      'https://b6.test.local/privacy',
      'https://b6.test.local/static/web/privacy.html',
    ], reason: 'H3:短路径失败回退 api 静态页(§决策#10)');
    expect(
      find.text('打开失败,请稍后重试'),
      findsOneWidget,
      reason: 'H3:两连失败落固定错误区(不 toast)',
    );
  });

  testWidgets('H3:baseUrl 未就绪(探活未完成)点链接直接落错误区,不外开', (tester) async {
    addTearDown(resetSession);
    session.baseUrl = null;
    var calls = 0;
    await pumpLogin(
      tester,
      openUrl: (u) async {
        calls++;
        return true;
      },
    );

    await tester.tap(find.text('《服务条款》'));
    await tester.pump();
    await tester.pump();

    expect(calls, 0, reason: 'H3:无从拼 URL,不发起外开');
    expect(find.text('打开失败,请稍后重试'), findsOneWidget);
  });
}
