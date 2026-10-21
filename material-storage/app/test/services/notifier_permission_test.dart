/// R4a(mobile-ux-polish-2)通知权限可达性单测(Notifier 注入桩,零平台通道):
/// - ensurePermission 消费请求结果:授权入内存(permissionGranted);
///   null 结果(<13/iOS 未给结论)视为可用;
/// - 请求后仍被拒 → 弹一次中文引导(标题「开启系统通知」,「去设置」跳应用
///   详情设置页);会话内至多一次(二次入队不再弹);已授权不弹;
/// - 请求链路失败 ≠ 拒绝:不记授权态、不弹引导(静默降级,不影响任务);
/// - 引导框文案与按钮面钉死(独立公开便于 widget 测试);
/// - queryPermission:注入直通;真实路径在测试环境(无插件通道)降级返回 true
///   (查不出就不误报「未开启」)。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/services/notifier.dart';

Notifier buildNotifier({
  required Future<bool?> Function() permission,
  Future<void> Function()? guide,
}) =>
    Notifier.test(
      batcher: TransferNotifyBatcher(
        sink: (_, _) async {},
        gate: () => true,
        schedule: (_, _) {},
      ),
      permission: permission,
      guide: guide,
    );

void main() {
  group('ensurePermission(R4a:结果消费+被拒引导一次)', () {
    test('已授权:permissionGranted=true,不弹引导', () async {
      var asked = 0;
      final guides = <int>[];
      final notifier = buildNotifier(
        permission: () async {
          asked++;
          return true;
        },
        guide: () async => guides.add(asked),
      );
      for (var i = 0; i < 3; i++) {
        await notifier.ensurePermission();
      }
      expect(asked, 1, reason: '幂等不变:本会话至多请求一次');
      expect(notifier.permissionGranted, isTrue);
      expect(guides, isEmpty, reason: '已授权不弹引导');
      expect(notifier.guideShown, isFalse);
    });

    test('被拒:弹一次引导(会话内至多一次,二次入队不再弹)', () async {
      var asked = 0;
      var guideCount = 0;
      final notifier = buildNotifier(
        permission: () async {
          asked++;
          return false;
        },
        guide: () async => guideCount++,
      );

      await notifier.ensurePermission();
      expect(asked, 1);
      expect(notifier.permissionGranted, isFalse, reason: '拒绝态入内存(不再全链路静默)');
      expect(guideCount, 1, reason: '请求后仍被拒 → 引导一次');
      expect(notifier.guideShown, isTrue);

      // 二次入队(传输页再次 enqueue → ensurePermission):幂等挡重入,不再弹
      await notifier.ensurePermission();
      expect(asked, 1);
      expect(guideCount, 1, reason: 'R4a 决策 #7:防骚扰,会话内至多弹一次');
    });

    test('null 结果(系统未给结论,<13/iOS):视为可用,不弹引导', () async {
      final guides = <int>[];
      final notifier = buildNotifier(
        permission: () async => null,
        guide: () async => guides.add(1),
      );
      await notifier.ensurePermission();
      expect(notifier.permissionGranted, isTrue, reason: 'null=未拦截,按可用记');
      expect(guides, isEmpty);
    });

    test('请求链路失败 ≠ 拒绝:不记授权态、不弹引导(静默降级不影响任务)',
        () async {
      final guides = <int>[];
      final notifier = buildNotifier(
        permission: () async => throw PlatformException(code: 'channel-error'),
        guide: () async => guides.add(1),
      );
      await notifier.ensurePermission();
      expect(notifier.permissionGranted, isNull,
          reason: '失败不视为拒绝(null=未请求/链路失败)');
      expect(guides, isEmpty, reason: '链路失败不弹引导(引导只对「明确拒绝」)');
    });
  });

  group('showNotificationGuideDialog(R4a 中文引导框)', () {
    testWidgets('标题/正文/按钮面:开启系统通知 + 用途说明 + 去设置/取消',
        (tester) async {
      final launches = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/url_launcher'),
          (call) async {
        if (call.method == 'launch') {
          launches.add((call.arguments as Map)['url'] as String);
          return true;
        }
        return false;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/url_launcher'), null));

      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: SizedBox.shrink())));
      final dialog = Notifier.I.showNotificationGuideDialog(
        tester.element(find.byType(Scaffold)),
      );
      await tester.pumpAndSettle();

      expect(find.text('开启系统通知'), findsOneWidget);
      expect(find.textContaining('系统通知权限'), findsOneWidget,
          reason: '正文说明用途:后台传输完成提醒需要通知权限');
      expect(find.textContaining('后台'), findsOneWidget);
      expect(find.text('去设置'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);

      // 取消:仅关框,不跳设置
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await dialog; // 弹窗 future 正常收尾(void)
      expect(find.text('开启系统通知'), findsNothing);
      expect(launches, isEmpty, reason: '取消不跳设置');
    });

    testWidgets('「去设置」:关框并跳应用详情设置页(url_launcher 通道桩)',
        (tester) async {
      final launches = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/url_launcher'),
          (call) async {
        if (call.method == 'launch') {
          launches.add((call.arguments as Map)['url'] as String);
          return true;
        }
        return false;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/url_launcher'), null));

      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: SizedBox.shrink())));
      final dialog = Notifier.I.showNotificationGuideDialog(
        tester.element(find.byType(Scaffold)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('去设置'));
      await tester.pumpAndSettle();
      await dialog; // 弹窗 future 正常收尾(void)
      expect(launches, ['package:$kNotifierAndroidAppPackage'],
          reason: '与一期相册引导同款:ACTION_VIEW package: 意图=应用详情页');
    });
  });

  group('queryPermission(R4a:我的页状态行实时查询)', () {
    test('注入直通', () async {
      final notifier = Notifier.test(
        batcher: TransferNotifyBatcher(
            sink: (_, _) async {}, gate: () => true, schedule: (_, _) {}),
        queryPermission: () async => false,
      );
      expect(await notifier.queryPermission(), isFalse);
    });

    test('真实路径降级:测试环境无插件通道 → true(查不出不误报「未开启」)',
        () async {
      expect(await Notifier.I.queryPermission(), isTrue);
    });
  });
}
