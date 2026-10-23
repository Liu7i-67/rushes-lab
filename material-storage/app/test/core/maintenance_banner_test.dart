/// B9 维护横幅单测(§8.12,web MaintenanceBanner 状态机移动版):
/// ① controller:active 弹(maintaining)/true→false 完成(justFinished→6s 自动
/// idle)/网络错误与非 200 不误判完成(lastKnownActive 兜底)/未登录也轮询
/// (canPoll 不要求 session.me);② overlay:不可关强提示(PopScope canPop:false
/// + barrierDismissible:false)/完成自动关/内容跟随刷新。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/maintenance/banner_controller.dart';
import 'package:ms_app/core/maintenance/maintenance_overlay.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/theme/app_theme.dart';
import 'package:ms_app/theme/tk_colors.dart';

MaintenanceBannerInfo bannerOf(bool active, {String? message}) =>
    MaintenanceBannerInfo(active: active, message: message);

void main() {
  group('MaintenanceBannerController 状态机(apply 直驱)', () {
    test('idle → active:maintaining 且 info 落地;重复 active 内容刷新', () {
      final c = MaintenanceBannerController(api: MsApi(baseUrl: 'http://t'));
      addTearDown(c.dispose);
      c.apply(bannerOf(true, message: '部署窗口'));
      expect(c.phase, MaintenancePhase.maintaining);
      expect(c.info?.message, '部署窗口');
      c.apply(bannerOf(true, message: '部署窗口 v2'));
      expect(c.phase, MaintenancePhase.maintaining);
      expect(c.info?.message, '部署窗口 v2', reason: '维持中更新可见');
    });

    test('true→false:justFinished(6s 自动关由 overlay widget 假时钟用例覆盖)', () {
      final c = MaintenanceBannerController(api: MsApi(baseUrl: 'http://t'));
      addTearDown(c.dispose);
      c.apply(bannerOf(true));
      c.apply(bannerOf(false));
      expect(c.phase, MaintenancePhase.justFinished);
    });

    test('网络错误不误判完成:active 期出错保持 maintaining;出错不误激活', () async {
      final c = MaintenanceBannerController(api: MsApi(baseUrl: 'http://t'));
      addTearDown(c.dispose);
      c.apply(bannerOf(true));
      // performTick 失败(widget 测试绑定下 HTTP 恒 400,等价网络错误):
      // lastKnownActive=true → 保持 maintaining,不误判完成
      await c.performTick();
      expect(
        c.phase,
        MaintenancePhase.maintaining,
        reason: 'lastKnownActive=true:出错不误判完成',
      );
      // true→false 进入完成;期间出错(400)既不误激活也不误回 maintaining
      c.apply(bannerOf(false));
      expect(c.phase, MaintenancePhase.justFinished);
      await c.performTick();
      expect(
        c.phase,
        MaintenancePhase.justFinished,
        reason: '非 active 期出错保持现状',
      );
    });

    test('未登录也轮询:canPoll 只看 API 就绪,不要求 session.me', () {
      final savedApi = session.api;
      session.api = null;
      addTearDown(() => session.api = savedApi);
      final c = MaintenanceBannerController(api: MsApi(baseUrl: 'http://t'));
      addTearDown(c.dispose);
      expect(session.me, isNull, reason: '测试环境未登录');
      expect(c.canPoll(), isTrue, reason: 'banner 前台即轮询、不分登录态(与通知轮询门控的差别)');
    });
  });

  group('MaintenanceOverlay(挂 builder,弹层不可关)', () {
    testWidgets('maintaining 弹不可关 modal(PopScope canPop:false);完成自动关', (
      tester,
    ) async {
      final c = MaintenanceBannerController(api: MsApi(baseUrl: 'http://t'));
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: session.navigatorKey,
          home: const Scaffold(body: Text('页面本体')),
          builder: (context, child) => Stack(
            children: [
              child ?? const SizedBox.shrink(),
              MaintenanceOverlay(controller: c),
            ],
          ),
        ),
      );
      expect(find.text('页面本体'), findsOneWidget);
      expect(find.text('系统升级中'), findsNothing);

      c.apply(bannerOf(true, message: '正在部署一次更新'));
      await tester.pumpAndSettle();
      expect(find.text('系统升级中'), findsOneWidget);
      expect(find.text('正在部署一次更新'), findsOneWidget);
      // 不可关:barrierDismissible false + PopScope canPop false
      expect(
        tester.widget<PopScope>(find.byType(PopScope)).canPop,
        isFalse,
        reason: '部署窗口强提示,返回键不可关',
      );

      // true→false:内容切「升级完成」(进出动画 settle)
      c.apply(bannerOf(false));
      await tester.pumpAndSettle();
      expect(find.text('升级完成'), findsOneWidget);
      expect(find.text('系统升级中'), findsNothing);

      // 6s 自动关(controller 计时;widget 假时钟推进)
      await tester.pump(const Duration(seconds: 6, milliseconds: 100));
      await tester.pumpAndSettle();
      expect(find.text('升级完成'), findsNothing);
      expect(find.text('页面本体'), findsOneWidget);
    });

    testWidgets('idle 不弹;信息 issues 列表渲染', (tester) async {
      final c = MaintenanceBannerController(api: MsApi(baseUrl: 'http://t'));
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: session.navigatorKey,
          home: const Scaffold(body: Text('页面本体')),
          builder: (context, child) => Stack(
            children: [
              child ?? const SizedBox.shrink(),
              MaintenanceOverlay(controller: c),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing, reason: 'idle 无弹层');

      c.apply(MaintenanceBannerInfo(active: true, issues: [(101, '修复上传中断')]));
      await tester.pumpAndSettle();
      expect(find.text('#101'), findsOneWidget);
      expect(find.text('修复上传中断'), findsOneWidget);
    });

    testWidgets('墨金主题:issues 编号 goldInk、遮罩 scrim、标题 20', (tester) async {
      final c = MaintenanceBannerController(api: MsApi(baseUrl: 'http://t'));
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          navigatorKey: session.navigatorKey,
          home: const Scaffold(body: Text('页面本体')),
          builder: (context, child) => Stack(
            children: [
              child ?? const SizedBox.shrink(),
              MaintenanceOverlay(controller: c),
            ],
          ),
        ),
      );
      const tk = TkColors.dark;
      c.apply(
        MaintenanceBannerInfo(
          active: true,
          message: '部署窗口',
          issues: [(101, '修复上传中断')],
        ),
      );
      await tester.pumpAndSettle();

      // issues 编号金色、正文 ink2、底部说明 ink3
      expect(tester.widget<Text>(find.text('#101')).style?.color, tk.goldInk);
      expect(tester.widget<Text>(find.text('修复上传中断')).style?.color, tk.ink2);
      expect(tester.widget<Text>(find.text('本次解决')).style?.color, tk.ink3);
      expect(tester.widget<Text>(find.text('部署窗口')).style?.color, tk.ink2);
      // 标题 20 由 DialogTheme 提供(不显式覆盖)
      expect(
        DefaultTextStyle.of(tester.element(find.text('系统升级中'))).style.fontSize,
        20,
      );
      // 遮罩使用 scrim
      final barrier = tester
          .widgetList<ModalBarrier>(find.byType(ModalBarrier))
          .last;
      expect(barrier.color, tk.scrim);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    });

    testWidgets('浅色主题渲染不抛(双主题)', (tester) async {
      final c = MaintenanceBannerController(api: MsApi(baseUrl: 'http://t'));
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          navigatorKey: session.navigatorKey,
          home: const Scaffold(body: Text('页面本体')),
          builder: (context, child) => Stack(
            children: [
              child ?? const SizedBox.shrink(),
              MaintenanceOverlay(controller: c),
            ],
          ),
        ),
      );
      c.apply(bannerOf(true));
      await tester.pumpAndSettle();
      c.apply(bannerOf(false));
      await tester.pumpAndSettle();
      expect(find.text('升级完成'), findsOneWidget);
      expect(
        tester.widget<Icon>(find.byIcon(Icons.check_circle)).color,
        TkColors.light.ok,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    });
  });
}
