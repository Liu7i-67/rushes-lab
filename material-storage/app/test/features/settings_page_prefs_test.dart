/// App 设置页「默认收拢全部文件夹」开关验收(2026-11-19 settings-mcp-collapse
/// §9 App 4,F7/D3):
/// - 初值来自 GET /me/preferences(prefs 开→开;关→关);初值加载失败保持
///   禁用,防「未加载完成即写入」的误报;
/// - 切换乐观更新触发 updatePrefs(PUT,实参逐次记录);
/// - 成功:按服务端返回对账,开关保持新值、无误报 Toast;
/// - 失败:error Toast(文案=透传 detail,桩注入 ApiException)且开关回弹;
/// - 重进页面(重挂载)初值回读最新 GET(服务端持久化语义);
/// - P2-3 请求代际守卫:慢 PUT 先发快 PUT 后发,终态=后发值;慢响应
///   (成功/失败)后到一律被丢弃——不覆盖新值、不回弹、不误弹 Toast。
///
/// 打桩:helpers/api_harness 的 FakePrefsApi(session.api!.prefs 域覆写),
/// 桩在 pumpWidget(首个请求)前就位;SettingsPage 无参构造(契约
/// features/settings/settings_page.dart);失败文案断言经 errorMessage 透传
/// 桩内 detail,不耦合页面兜底文案。Toast 收尾排空自动销毁 timer
/// (toast_polish2_test 同款测试卫生)。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/settings/settings_page.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

/// 开关行(SwitchListTile 标题含「默认收拢全部文件夹」;定位与实现形态解耦,
/// 照 user_delegation_test 口径)。
Finder get _collapseTile => find.ancestor(
      of: find.textContaining('默认收拢全部文件夹'),
      matching: find.byType(SwitchListTile),
    );

SwitchListTile _tile(WidgetTester tester) =>
    tester.widget<SwitchListTile>(_collapseTile.first);

bool _tileOn(WidgetTester tester) => _tile(tester).value;

/// 排空 toast 自动销毁 timer + 退场动画(失败用例收尾;无 toast 时为空操作)。
Future<void> _drainToast(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 4));
  await tester.pumpAndSettle();
}

/// 挂设置页 + prefs 假域;返回 prefs 桩供断言/编排。
Future<FakePrefsApi> _pumpSettings(
  WidgetTester tester, {
  bool initial = false,
  Object? getStaged,
  Object? updateStaged,
}) async {
  final api = installFakeApi();
  api.prefs.getStaged = getStaged ?? UserPrefs(folderTreeDefaultCollapsed: initial);
  if (updateStaged != null) api.prefs.updateStaged = updateStaged;
  addTearDown(() => session.api = null);
  await tester.pumpWidget(
    MaterialApp(home: SettingsPage(key: UniqueKey())),
  );
  await tester.pumpAndSettle();
  return api.prefs;
}

void main() {
  group('初值来自 GET(§9 App 4)', () {
    testWidgets('prefs 开 → 开关开;页面两组内容齐备', (tester) async {
      final prefs = await _pumpSettings(tester, initial: true);

      expect(
        prefs.getPrefsCalls,
        greaterThanOrEqualTo(1),
        reason: '初值经 GET /me/preferences',
      );
      expect(_tileOn(tester), isTrue);
      expect(find.textContaining('默认收拢全部文件夹'), findsWidgets);
      expect(find.text('偏好'), findsOneWidget, reason: 'F7 偏好分组');
      expect(find.text('MCP / AI 接入'), findsOneWidget, reason: 'F7 MCP 分组');
      expect(find.text('访问令牌'), findsOneWidget, reason: 'F7 入口行');
    });

    testWidgets('prefs 关 → 开关关', (tester) async {
      await _pumpSettings(tester, initial: false);
      expect(_tileOn(tester), isFalse);
    });

    testWidgets('初值加载失败:开关禁用且点按不触发 PUT(防误报)', (tester) async {
      final prefs = await _pumpSettings(
        tester,
        getStaged: ApiException(500, '偏好加载失败'),
      );

      expect(_tileOn(tester), isFalse, reason: '未知初值展示为关(禁用)');
      expect(_tile(tester).onChanged, isNull, reason: '加载失败保持禁用');
      await tester.tap(_collapseTile);
      await tester.pumpAndSettle();
      expect(prefs.updateCalls, isEmpty, reason: '禁用态点按不发起 PUT');
    });
  });

  group('切换 → updatePrefs(乐观更新)', () {
    testWidgets('切换成功:PUT(true) 被调,开关保持开、无失败 Toast', (tester) async {
      final prefs = await _pumpSettings(tester, initial: false);

      await tester.tap(_collapseTile);
      await tester.pumpAndSettle();

      expect(prefs.updateCalls, [true], reason: 'PUT 实参=切换后新值');
      expect(_tileOn(tester), isTrue, reason: '成功按服务端返回对账,不回弹');
      expect(
        find.byKey(const ValueKey<String>('toast-dot')),
        findsNothing,
        reason: '成功无误报 Toast',
      );
    });

    testWidgets('切换失败:error Toast(透传 detail)且开关回弹(不误报成功)',
        (tester) async {
      final prefs = await _pumpSettings(
        tester,
        initial: false,
        updateStaged: ApiException(500, '保存失败'),
      );

      await tester.tap(_collapseTile);
      await tester.pumpAndSettle();

      expect(prefs.updateCalls, [true], reason: '失败前确已发起 PUT');
      expect(_tileOn(tester), isFalse, reason: '失败回弹到切换前值');
      expect(
        find.byKey(const ValueKey<String>('toast-dot')),
        findsOneWidget,
        reason: '失败有 Toast',
      );
      expect(
        find.text('保存失败'),
        findsOneWidget,
        reason: 'error 文案=errorMessage 透传桩内 detail',
      );

      await _drainToast(tester);
      expect(
        find.byKey(const ValueKey<String>('toast-dot')),
        findsNothing,
        reason: 'toast 到时自动销毁(timer 排空)',
      );
    });

    testWidgets('重进页面:初值回读最新 GET(服务端持久化语义)', (tester) async {
      final prefs = await _pumpSettings(tester, initial: false);

      await tester.tap(_collapseTile);
      await tester.pumpAndSettle();
      expect(_tileOn(tester), isTrue);

      // 模拟重进后 GET 拿到已保存的新值;UniqueKey 强制重建 State
      prefs.getStaged = const UserPrefs(folderTreeDefaultCollapsed: true);
      await tester.pumpWidget(
        MaterialApp(home: SettingsPage(key: UniqueKey())),
      );
      await tester.pumpAndSettle();

      expect(_tileOn(tester), isTrue, reason: '重进初值=已保存值');
      expect(
        prefs.getPrefsCalls,
        greaterThanOrEqualTo(2),
        reason: '每次挂载各 GET 一次',
      );
    });
  });

  group('P2-3 请求代际守卫(旧响应后到一律丢弃)', () {
    /// 双 PUT 编排:慢请求(Completer 挂起)先发、快请求(UserPrefs 直落)
    /// 后发;返回 (prefs 桩, 慢请求 Completer) 供用例控制放行次序。
    Future<(FakePrefsApi, Completer<UserPrefs>)> pumpTwoPuts(
      WidgetTester tester,
    ) async {
      final prefs = await _pumpSettings(tester, initial: false);
      final slow = Completer<UserPrefs>();
      prefs.updateStagedQueue
        ..add(slow) // 第一次 PUT(true):慢,先发
        ..add(const UserPrefs(folderTreeDefaultCollapsed: false)); // 快,后发
      await tester.tap(_collapseTile); // 乐观 true,PUT(true) 挂起
      await tester.pump();
      await tester.tap(_collapseTile); // 值已重建为 true,本次切回 false
      await tester.pumpAndSettle();
      return (prefs, slow);
    }

    testWidgets('慢 PUT 先发快 PUT 后发:终态=后发值,慢值后到不覆盖', (tester) async {
      final (prefs, slow) = await pumpTwoPuts(tester);

      expect(prefs.updateCalls, [true, false], reason: '两次 PUT 次序=先慢后快');
      expect(
        _tileOn(tester),
        isFalse,
        reason: '终态=后发(快)请求按服务端对账的值',
      );
      expect(find.byKey(const ValueKey<String>('toast-dot')), findsNothing);

      // 慢请求后到(成功落「开」):必须被代际守卫丢弃,开关不回跳
      slow.complete(const UserPrefs(folderTreeDefaultCollapsed: true));
      await tester.pumpAndSettle();

      expect(_tileOn(tester), isFalse, reason: '旧成功响应不覆盖新值');
      expect(
        find.byKey(const ValueKey<String>('toast-dot')),
        findsNothing,
        reason: '被丢弃的旧成功响应不产生任何 Toast',
      );
    });

    testWidgets('慢 PUT 失败后到:被丢弃——不回弹、无误报 Toast', (tester) async {
      final (prefs, slow) = await pumpTwoPuts(tester);

      expect(_tileOn(tester), isFalse, reason: '快请求已按服务端对账落定');

      // 慢请求后到且失败:失败处理同样只属于最新请求,旧失败整包丢弃
      slow.completeError(ApiException(500, '慢请求失败'));
      await tester.pumpAndSettle();

      expect(_tileOn(tester), isFalse, reason: '旧失败不触发回弹');
      expect(
        find.byKey(const ValueKey<String>('toast-dot')),
        findsNothing,
        reason: '旧失败不误弹 Toast',
      );
      expect(find.text('慢请求失败'), findsNothing);
    });
  });
}
