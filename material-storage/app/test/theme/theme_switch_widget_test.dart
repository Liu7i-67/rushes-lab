/// 双主题切换 widget 测试(WP12,§11.2 / §12.3):
/// - 跟随系统:platformBrightness dark/light → Scaffold 背景随 palette 切换;
/// - 设置面板三档:点「深色/浅色/跟随系统」→ controller.mode 与页面背景即时变化,
///   选择写入注入的内存 ThemeStore(零真实 IO);
/// - 切换主题不重建 Navigator:列表滚动位置与页面内状态保留。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/features/me/settings_sheet.dart';
import 'package:ms_app/theme/app_theme.dart';
import 'package:ms_app/theme/theme_controller.dart';
import 'package:ms_app/theme/theme_store.dart';
import 'package:ms_app/theme/tk_colors.dart';

/// 内存 store:记录每次写入,读取返回最后值(重启恢复语义同真实文件)。
class _MemoryStore {
  String? value;
  final List<String> writes = [];

  late final ThemeStore store = ThemeStore(
    read: () async => value,
    write: (v) async {
      value = v;
      writes.add(v);
    },
  );
}

/// 宿主:AnimatedBuilder 包 MaterialApp(生产 app.dart 同构),
/// 页面含可滚动列表 + 本页状态计数器,用于验证切主题不丢状态。
class _ThemeHost extends StatefulWidget {
  const _ThemeHost({required this.controller});

  final ThemeController controller;

  @override
  State<_ThemeHost> createState() => _ThemeHostState();
}

class _ThemeHostState extends State<_ThemeHost> {
  final ScrollController _scroll = ScrollController();
  int _taps = 0;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => MaterialApp(
        theme: buildAppTheme(Brightness.light),
        darkTheme: buildAppTheme(Brightness.dark),
        themeMode: controller.mode,
        // 与生产 app.dart 同构:外层 AnnotatedRegion 按当前主题设置状态栏
        // 图标明暗(预览页可在页内嵌套覆盖)。
        builder: (context, child) {
          final dark = Theme.of(context).brightness == Brightness.dark;
          final tk = TkColors.of(dark ? Brightness.dark : Brightness.light);
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle(
              statusBarColor: tk.bg,
              statusBarIconBrightness: dark
                  ? Brightness.light
                  : Brightness.dark,
              // iOS 语义相反:浅色背景配深色图标。
              statusBarBrightness: dark ? Brightness.dark : Brightness.light,
              systemNavigationBarColor: tk.barBg,
              systemNavigationBarIconBrightness: dark
                  ? Brightness.light
                  : Brightness.dark,
            ),
            child: child ?? const SizedBox.shrink(),
          );
        },
        home: Builder(
          builder: (ctx) => Scaffold(
            body: SafeArea(
              child: Column(
                children: [
                  Row(
                    children: [
                      Text('taps: $_taps'),
                      TextButton(
                        onPressed: () => setState(() => _taps++),
                        child: const Text('tap'),
                      ),
                      TextButton(
                        onPressed: () =>
                            showAppearanceSheet(ctx, controller: controller),
                        child: const Text('设置外观'),
                      ),
                    ],
                  ),
                  Expanded(
                    child: ListView.builder(
                      controller: _scroll,
                      itemCount: 40,
                      itemBuilder: (_, i) =>
                          SizedBox(height: 56, child: Text('row $i')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Color _scaffoldBg(WidgetTester tester) {
  final ctx = tester.element(find.byType(Scaffold).first);
  return Theme.of(ctx).scaffoldBackgroundColor;
}

double _scrollOffset(WidgetTester tester) => tester
    .state<ScrollableState>(find.byType(Scrollable).first)
    .position
    .pixels;

/// 宿主外层 AnnotatedRegion 的状态栏样式(生产 app.dart builder 同构)。
SystemUiOverlayStyle _statusOverlay(WidgetTester tester) {
  final finder = find.byType(AnnotatedRegion<SystemUiOverlayStyle>);
  expect(finder, findsWidgets, reason: '外层 AnnotatedRegion 存在');
  return tester
      .widget<AnnotatedRegion<SystemUiOverlayStyle>>(finder.first)
      .value;
}

void main() {
  testWidgets('跟随系统:platformBrightness 深/浅 → 对应 palette 背景', (tester) async {
    final mem = _MemoryStore();
    final controller = ThemeController(store: mem.store);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await tester.pumpWidget(_ThemeHost(controller: controller));
    await tester.pumpAndSettle();
    expect(controller.mode, ThemeMode.system);
    expect(_scaffoldBg(tester), TkColors.dark.bg);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(_scaffoldBg(tester), TkColors.light.bg);
  });

  testWidgets('设置面板三档:mode/页面背景即时变化,选择写入内存 store', (tester) async {
    final mem = _MemoryStore();
    final controller = ThemeController(store: mem.store);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await tester.pumpWidget(_ThemeHost(controller: controller));
    await tester.pumpAndSettle();
    expect(_scaffoldBg(tester), TkColors.light.bg);

    await tester.tap(find.text('设置外观'));
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsOneWidget, reason: '前置:外观面板已打开');

    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(controller.pref, ThemePref.dark);
    expect(controller.mode, ThemeMode.dark);
    expect(mem.writes, ['dark'], reason: '选择即写盘(异步,内存 store 记录)');
    expect(
      _scaffoldBg(tester),
      TkColors.dark.bg,
      reason: '深色:页面背景切到 dark.bg,面板保持打开',
    );
    expect(find.text('设置'), findsOneWidget);

    await tester.tap(find.text('浅色'));
    await tester.pumpAndSettle();
    expect(controller.mode, ThemeMode.light);
    expect(mem.writes, ['dark', 'light']);
    expect(_scaffoldBg(tester), TkColors.light.bg);

    await tester.tap(find.text('跟随系统'));
    await tester.pumpAndSettle();
    expect(controller.mode, ThemeMode.system);
    expect(mem.writes, ['dark', 'light', 'system']);
    expect(
      _scaffoldBg(tester),
      TkColors.light.bg,
      reason: '系统为浅色时,跟随系统落回 light.bg',
    );
  });

  testWidgets('切换主题后列表滚动位置与页面内状态不丢', (tester) async {
    final mem = _MemoryStore();
    final controller = ThemeController(store: mem.store);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await tester.pumpWidget(_ThemeHost(controller: controller));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    final scrolled = _scrollOffset(tester);
    expect(scrolled, greaterThan(0), reason: '前置:列表已滚动');

    await tester.tap(find.text('tap'));
    await tester.pump();
    expect(find.text('taps: 1'), findsOneWidget, reason: '前置:页面内状态已变更');

    await tester.tap(find.text('设置外观'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();

    expect(_scaffoldBg(tester), TkColors.dark.bg);
    expect(
      find.text('taps: 1'),
      findsOneWidget,
      reason: '切主题不重建页面状态(导航/计数器保留)',
    );
    expect(_scrollOffset(tester), scrolled, reason: '切主题不重建滚动视图,offset 不变');
  });

  testWidgets('AnnotatedRegion:状态栏图标明暗随主题切换', (tester) async {
    final mem = _MemoryStore();
    final controller = ThemeController(store: mem.store);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await tester.pumpWidget(_ThemeHost(controller: controller));
    await tester.pumpAndSettle();

    expect(
      _statusOverlay(tester).statusBarIconBrightness,
      Brightness.dark,
      reason: '浅色背景 → 深色状态栏图标',
    );
    expect(_statusOverlay(tester).statusBarBrightness, Brightness.light);
    expect(_statusOverlay(tester).statusBarColor, TkColors.light.bg);

    await tester.tap(find.text('设置外观'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();

    expect(
      _statusOverlay(tester).statusBarIconBrightness,
      Brightness.light,
      reason: '深色背景 → 浅色状态栏图标',
    );
    expect(_statusOverlay(tester).statusBarBrightness, Brightness.dark);
    expect(_statusOverlay(tester).statusBarColor, TkColors.dark.bg);
    expect(
      _statusOverlay(tester).systemNavigationBarIconBrightness,
      Brightness.light,
    );

    await tester.tap(find.text('浅色'));
    await tester.pumpAndSettle();
    expect(
      _statusOverlay(tester).statusBarIconBrightness,
      Brightness.dark,
      reason: '切回浅色 → 状态栏图标恢复深色',
    );
    expect(_statusOverlay(tester).statusBarColor, TkColors.light.bg);
  });
}
