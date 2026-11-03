/// 「关于我们」页 + 备案号展示单测(qdev 2026-11-03-app-about-icp §6/§7):
/// - MePage「关于」分组渲染「关于我们」行,与原更新区行共存且位于其上(§6.1);
/// - 点击入口行请求路由 /about(onGenerateRoute 捕获路由名,§6.2);
/// - AboutPage 渲染 logo(Key about_logo)/名称「浣花视界」/备案号文本(§6.3),
///   备案号精确等于 kAppIcpNumber,Key about_icp 行内即该文本(§6.4);
/// - 点击备案号调注入 openUrl,入参 == kIcpQueryUrl(§6.5);返回 false 落
///   SnackBar「打开失败，请稍后重试」,页面不打断(§6.6);
/// - 版本注入 1.2.3+45 →「版本 1.2.3+45」;getter 抛异常 →「版本 …」不 crash(§6.7);
/// - 补充:logo 资产 assets/logo.png 真实可加载;/about 请求无 arguments(§7);
///   连点备案号现状记录(无防抖,不崩页);顶层常量字面值比对锁定契约,防漂移(§7)。
/// 版本/外开链接全部经构造注入,不触 PackageInfo 通道与 launchUrl。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/update/update_flow.dart';
import 'package:ms_app/features/me/about_page.dart';
import 'package:ms_app/features/me/me_page.dart';
import 'package:ms_app/widgets/page_header.dart';

/// §6.7 注入版本样本(1.2.3, 45)。
Future<LocalAppVersion> _v123() async => (version: '1.2.3', build: 45);

/// 恒抛异常的版本来源(复刻 PackageInfo 通道缺失;照抄 me_update_edge_tile_test)。
Future<LocalAppVersion> _boomLocal() async =>
    throw StateError('no package_info');

/// 每样本独立的外开链接记录器(表驱动铁律:样本各自 new,不共享状态)。
class _OpenUrlRecorder {
  _OpenUrlRecorder(this.result);

  final bool result;
  final List<String> urls = <String>[];

  Future<bool> call(String url) async {
    urls.add(url);
    return result;
  }
}

/// pump AboutPage:注入 localVersion/openUrl;两帧等 initState 异步微任务落定
/// (照抄 me_update_tile_test 的 _pumpTile 节奏)。
Future<void> _pumpAbout(
  WidgetTester tester, {
  Future<LocalAppVersion> Function()? localVersion,
  Future<bool> Function(String url)? openUrl,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: AboutPage(localVersion: localVersion, openUrl: openUrl),
    ),
  );
  await tester.pump(); // initState 异步 _load 微任务
  await tester.pump(); // setState 后重渲染
}

/// MePage 是长列表:目标滚到可见再断言/点击(照抄 me_page_stamp_test)。
Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.dragUntilVisible(
    target,
    find.byType(ListView),
    const Offset(0, -260),
  );
  await tester.pump();
}

void main() {
  group('MePage「关于」分组入口(§6.1/§6.2)', () {
    testWidgets('渲染「关于我们」行,与原更新区行共存且位于其上', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: MePage()));
      await tester.pump();
      await _scrollTo(tester, find.text('关于我们'));

      expect(find.text('关于我们'), findsOneWidget);
      // 更新区行:Android 分支标题「检查更新」/其余平台标题「当前版本」;
      // 测试宿主机非 Android → 落「当前版本」分支,两行必须共存(§6.1)
      final updateTitle = find.text('检查更新').evaluate().isNotEmpty
          ? find.text('检查更新')
          : find.text('当前版本');
      expect(updateTitle, findsWidgets, reason: '原「检查更新/当前版本」行不受影响');

      // §2.1:「关于我们」为分组内第一项,位于更新区行之上
      expect(
        tester.getRect(find.text('关于我们')).top,
        lessThan(tester.getRect(updateTitle.first).top),
        reason: '入口行在「关于」分组内排第一项',
      );
    });

    testWidgets('点击「关于我们」行 → 请求路由 /about', (tester) async {
      final requested = <String?>[];
      final routeArgs = <Object?>[];
      await tester.pumpWidget(
        MaterialApp(
          onGenerateRoute: (settings) {
            requested.add(settings.name);
            routeArgs.add(settings.arguments);
            return MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('AboutT')),
            );
          },
          home: const MePage(),
        ),
      );
      await tester.pump();
      await _scrollTo(tester, find.text('关于我们'));

      await tester.tap(find.text('关于我们'));
      await tester.pump();
      await tester.pump();

      expect(
        requested,
        contains('/about'),
        reason: '入口行 onTap:Navigator.pushNamed(\'/about\'),无 arguments(§7)',
      );
      // §7:pushNamed('/about') 无 arguments,锁定调用契约
      expect(routeArgs.last, isNull, reason: '/about 请求不带 arguments(§7)');
    });
  });

  group('AboutPage 渲染(§6.3/§6.4)', () {
    testWidgets('logo(Key about_logo)/名称「浣花视界」/备案号文本齐全', (tester) async {
      await _pumpAbout(tester, localVersion: _v123);

      expect(
        find.byKey(const Key('about_logo')),
        findsOneWidget,
        reason: 'App 图标(assets/logo.png)',
      );
      expect(find.text('浣花视界'), findsOneWidget, reason: 'App 名称');
      expect(find.byKey(const Key('about_icp')), findsOneWidget);

      // 二级页头(§2.2):PageHeader「关于我们」带返回钮
      expect(find.byType(PageHeader), findsOneWidget);
      expect(find.text('关于我们'), findsOneWidget);
      expect(find.byTooltip('返回'), findsOneWidget);
    });

    testWidgets('logo 资产真实存在且可加载(assets/logo.png 不缺失)', (tester) async {
      await _pumpAbout(tester, localVersion: _v123);

      // 渲染无异常:资产缺失时 Image.asset 的图片流会带异常完成
      expect(tester.takeException(), isNull);

      // 锁定 §2.2 资产口径:确为 assets/logo.png,而非其它占位图
      final image = tester.widget<Image>(
        find.descendant(
          of: find.byKey(const Key('about_logo')),
          matching: find.byType(Image),
        ),
      );
      expect(image.image, isA<AssetImage>());
      expect((image.image as AssetImage).assetName, 'assets/logo.png');

      // pubspec 声明 + 文件字节真实可读(防声明丢失/文件缺失)
      final data = await rootBundle.load('assets/logo.png');
      expect(data.lengthInBytes, greaterThan(0));
    });

    testWidgets('备案号文本精确等于 kAppIcpNumber(Key 行内即该文本)', (tester) async {
      await _pumpAbout(tester, localVersion: _v123);

      final icpRow = find.byKey(const Key('about_icp'));
      expect(icpRow, findsOneWidget);
      expect(
        find.descendant(of: icpRow, matching: find.text(kAppIcpNumber)),
        findsOneWidget,
        reason: '备案号 Key 所在行内文本精确等于 kAppIcpNumber',
      );
      expect(find.text(kAppIcpNumber), findsOneWidget);
    });
  });

  group('备案号外开链接(§6.5/§6.6)', () {
    testWidgets('点击备案号 → 注入 openUrl 被调,入参 == kIcpQueryUrl', (tester) async {
      final open = _OpenUrlRecorder(true);
      await _pumpAbout(tester, localVersion: _v123, openUrl: open.call);

      await tester.tap(find.byKey(const Key('about_icp')));
      await tester.pump();
      await tester.pump();

      expect(open.urls, <String>[kIcpQueryUrl], reason: '外开工信部核验站,入参即顶层常量');
      expect(find.byType(SnackBar), findsNothing, reason: '打开成功不落失败提示');
    });

    testWidgets('openUrl 返回 false → SnackBar「打开失败，请稍后重试」,页面不打断', (
      tester,
    ) async {
      final open = _OpenUrlRecorder(false);
      await _pumpAbout(tester, localVersion: _v123, openUrl: open.call);

      await tester.tap(find.byKey(const Key('about_icp')));
      await tester.pump();
      await tester.pump();

      expect(open.urls, <String>[kIcpQueryUrl]);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text('打开失败，请稍后重试'), findsOneWidget);
      expect(find.text('浣花视界'), findsOneWidget, reason: 'SnackBar 不打断页面');
    });

    testWidgets('连点备案号两次 → 各触发一次外开请求,页面不崩(记录现状无防抖)', (tester) async {
      final open = _OpenUrlRecorder(true);
      await _pumpAbout(tester, localVersion: _v123, openUrl: open.call);

      await tester.tap(find.byKey(const Key('about_icp')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('about_icp')));
      await tester.pump();
      await tester.pump();

      expect(open.urls.length, 2, reason: '当前实现无防抖:连点各触发一次(记录现状)');
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('浣花视界'), findsOneWidget, reason: '连点不崩页面');
    });
  });

  group('版本行(§6.7)', () {
    testWidgets('注入 (1.2.3, 45) → 显示「版本 1.2.3+45」', (tester) async {
      await _pumpAbout(tester, localVersion: _v123);

      expect(
        find.text('版本 1.2.3+45'),
        findsOneWidget,
        reason: '文案口径「版本 \${localVersionLabel(v)}」(§7)',
      );
    });

    testWidgets('版本 getter 抛异常 → 显示「版本 …」不 crash(参照 update_tile 容错)', (
      tester,
    ) async {
      await _pumpAbout(tester, localVersion: _boomLocal);

      expect(tester.takeException(), isNull, reason: '读取异常静默,页面不崩');
      expect(
        find.text('版本 …'),
        findsOneWidget,
        reason: '无数字占位,PackageInfo 通道异常不渲染数字(§7)',
      );
    });
  });

  test('契约锁定(§7):顶层常量字面值,防漂移', () {
    expect(kAppIcpNumber, '蜀ICP备2021008473号-4A');
    expect(kIcpQueryUrl, 'https://beian.miit.gov.cn');
  });
}
