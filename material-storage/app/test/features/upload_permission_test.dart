/// P2 相册权限引导单测:中文选图配置 / 权限被拒对话框双平台按钮面 /
/// Android 应用详情设置页 URI 构造(album.dart 拒绝态返 false 的契约在
/// 真机上验,单测侧以 upload_pick 消费侧为主)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/features/assets/upload_pick.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

void main() {
  group('albumPickerConfig(P2 中文 delegate)', () {
    test('显式指定基类中文 delegate(zh-Hans),多选上限 99', () {
      final config = albumPickerConfig();
      expect(config.maxAssets, 99);
      expect(config.requestType, RequestType.all);
      final d = config.textDelegate;
      expect(d, isNotNull);
      expect(d!.languageCode, 'zh', reason: 'picker 内置界面全中文化');
      expect(d.scriptCode, 'Hans');
      // 反向锚:不是英文 delegate
      expect(d, isNot(isA<EnglishAssetPickerTextDelegate>()));
      // 内置权限引导覆盖层文案走中文 delegate
      expect(d.unableToAccessAll, '无法访问所有资源');
      expect(d.goToSystemSettings, '前往系统设置');
    });
  });

  group('showAlbumPermissionDialog(P2 权限被拒引导)', () {
    // Scaffold 唯一,取其 element 作 showDialog 的宿主 context
    BuildContext hostContext(WidgetTester tester) =>
        tester.element(find.byType(Scaffold));

    testWidgets('Android:标题/正文中文,按钮为「去设置」+「取消」', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
      );
      final dialog = showAlbumPermissionDialog(
        hostContext(tester),
        isAndroid: true,
      );
      await tester.pumpAndSettle();
      expect(find.text('需要相册访问权限'), findsOneWidget);
      expect(find.textContaining('选择照片、视频上传'), findsOneWidget);
      expect(find.text('去设置'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);

      // 点「去设置」→ 返回 openSettings
      await tester.tap(find.text('去设置'));
      expect(await dialog, AlbumPermissionAction.openSettings);
    });

    testWidgets('iOS:按钮为「重新尝试」+「取消」', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
      );
      final dialog = showAlbumPermissionDialog(
        hostContext(tester),
        isAndroid: false,
      );
      await tester.pumpAndSettle();
      expect(find.text('重新尝试'), findsOneWidget);
      expect(find.text('去设置'), findsNothing);

      await tester.tap(find.text('重新尝试'));
      expect(await dialog, AlbumPermissionAction.retry);
    });

    testWidgets('取消返回 null(不算上传)', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
      );
      final dialog = showAlbumPermissionDialog(
        hostContext(tester),
        isAndroid: true,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      expect(await dialog, isNull);
    });
  });

  group('androidAppDetailsSettingsUri(P2 去设置)', () {
    test('package: scheme + 现役 applicationId(ACTION_VIEW 即应用详情页)', () {
      final uri = androidAppDetailsSettingsUri();
      expect(uri.scheme, 'package');
      expect(uri.path, 'com.taoxiplan.huanhuashijie');
      expect(uri.toString(), 'package:com.taoxiplan.huanhuashijie');
    });

    test('可注入其他包名', () {
      final uri = androidAppDetailsSettingsUri(packageName: 'com.example.x');
      expect(uri.toString(), 'package:com.example.x');
    });
  });

  group('ensureAlbumPermissionGuided(P2 权限引导循环编排)', () {
    // Scaffold 唯一,取其 element 作宿主 context
    BuildContext hostContext(WidgetTester tester) =>
        tester.element(find.byType(Scaffold));

    Future<void> pumpHost(WidgetTester tester) => tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
    );

    /// 注入版依赖:check 按队列逐次返回,calls 记录调用序列。
    Future<bool> Function() stagedCheck(List<bool> queue, List<String> calls) =>
        () async {
          calls.add('check');
          return queue.removeAt(0);
        };

    testWidgets('已授权直通:true,不弹框不跳设置不等前台', (tester) async {
      await pumpHost(tester);
      final calls = <String>[];
      final r = await ensureAlbumPermissionGuided(
        hostContext(tester),
        checkPermission: stagedCheck([true], calls),
        openSettings: () async => calls.add('settings'),
        waitResume: () async {
          calls.add('resume');
          return true;
        },
      );
      expect(r, isTrue);
      expect(calls, ['check']);
      expect(find.text('需要相册访问权限'), findsNothing);
    });

    testWidgets('拒绝→取消:false,不跳设置(取消不算上传)', (tester) async {
      await pumpHost(tester);
      final calls = <String>[];
      final f = ensureAlbumPermissionGuided(
        hostContext(tester),
        checkPermission: stagedCheck([false], calls),
        openSettings: () async => calls.add('settings'),
        waitResume: () async {
          calls.add('resume');
          return true;
        },
      );
      await tester.pumpAndSettle(); // 引导框出现
      expect(find.text('需要相册访问权限'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(await f, isFalse);
      expect(calls, ['check'], reason: '取消后不跳设置、不等前台');
    });

    testWidgets('P2-1 Android 去设置→回前台已授权:等 resumed 后再判→true', (tester) async {
      await pumpHost(tester);
      final calls = <String>[];
      final f = ensureAlbumPermissionGuided(
        hostContext(tester),
        isAndroid: true,
        checkPermission: stagedCheck([false, true], calls),
        openSettings: () async => calls.add('settings'),
        waitResume: () async {
          calls.add('resume');
          return true;
        },
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('去设置'));
      await tester.pumpAndSettle();
      expect(await f, isTrue);
      // 顺序钉子:重判必发生在「跳设置+等回前台」之后(P2-1 修复点)
      expect(calls, ['check', 'settings', 'resume', 'check']);
    });

    testWidgets('P2-1 去设置后超时未回前台:false 且不再重判(无陈旧框)', (tester) async {
      await pumpHost(tester);
      final calls = <String>[];
      final f = ensureAlbumPermissionGuided(
        hostContext(tester),
        isAndroid: true,
        checkPermission: stagedCheck([false], calls),
        openSettings: () async => calls.add('settings'),
        // 超时未回前台:等前台以 false 收场
        waitResume: () async {
          calls.add('resume');
          return false;
        },
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('去设置'));
      await tester.pumpAndSettle();
      expect(await f, isFalse);
      expect(calls, [
        'check',
        'settings',
        'resume',
      ], reason: '超时路径放弃本次,不再触发第二次重判');
    });

    testWidgets('去设置→回前台仍未授权→再弹引导→取消:false', (tester) async {
      await pumpHost(tester);
      final calls = <String>[];
      final f = ensureAlbumPermissionGuided(
        hostContext(tester),
        isAndroid: true,
        checkPermission: stagedCheck([false, false], calls),
        openSettings: () async => calls.add('settings'),
        waitResume: () async {
          calls.add('resume');
          return true;
        },
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('去设置'));
      await tester.pumpAndSettle();
      // 回前台后仍未授权 → 引导框再次出现(此次是真实重判后的合理引导)
      expect(find.text('需要相册访问权限'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(await f, isFalse);
      expect(calls, ['check', 'settings', 'resume', 'check']);
    });

    testWidgets('iOS 重新尝试:重走授权判定,不经设置页与前台等待', (tester) async {
      await pumpHost(tester);
      final calls = <String>[];
      final f = ensureAlbumPermissionGuided(
        hostContext(tester),
        isAndroid: false,
        checkPermission: stagedCheck([false, true], calls),
        openSettings: () async => calls.add('settings'),
        waitResume: () async {
          calls.add('resume');
          return true;
        },
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('重新尝试'));
      await tester.pumpAndSettle();
      expect(await f, isTrue);
      expect(calls, ['check', 'check'], reason: 'retry 不跳设置、不等前台');
    });
  });

  group('waitForAppResume(P2-1 等 resumed 再重判)', () {
    /// 沿合法迁移链把宿主 binding 切到后台(AppLifecycleListener debug 断言
    /// 校验迁移合法性:resumed→inactive→hidden→paused)。
    void toBackground(WidgetTester tester) {
      final b = tester.binding;
      final s = b.lifecycleState;
      if (s == AppLifecycleState.paused) return;
      if (s == null || s == AppLifecycleState.resumed) {
        b.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      }
      if (b.lifecycleState == AppLifecycleState.inactive) {
        b.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      }
      b.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    }

    /// 沿合法迁移链切回前台(paused→hidden→inactive→resumed;detached/null
    /// 可直达 resumed)。
    void toForeground(WidgetTester tester) {
      final b = tester.binding;
      final s = b.lifecycleState;
      if (s == AppLifecycleState.resumed) return;
      if (s == AppLifecycleState.paused) {
        b.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      }
      if (b.lifecycleState == AppLifecycleState.hidden) {
        b.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      }
      b.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }

    testWidgets('已在前台(resumed):直接 true,不挂监听不等待', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      toForeground(tester);
      expect(tester.binding.lifecycleState, AppLifecycleState.resumed);
      expect(
        await waitForAppResume(
          binding: tester.binding,
          timeout: const Duration(milliseconds: 10),
        ),
        isTrue,
      );
      await tester.pump(); // 若有定时器残留此处会暴露
    });

    testWidgets('后台等待→回前台 resumed→true', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      toBackground(tester);
      final f = waitForAppResume(
        binding: tester.binding,
        timeout: const Duration(minutes: 1),
      );
      await tester.pump(); // 让监听与超时定时器挂上
      toForeground(tester); // 模拟用户从系统设置页返回
      await tester.pump();
      expect(await f, isTrue);
      await tester.pump(); // 超时定时器应已取消,无 pending timer
    });

    testWidgets('后台等待→超时未回前台→false(防死等,定时器可取消)', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      toBackground(tester);
      final f = waitForAppResume(
        binding: tester.binding,
        timeout: const Duration(milliseconds: 10),
      );
      await tester.pump(const Duration(seconds: 1)); // FakeAsync 推进过超时点
      expect(await f, isFalse);
      await tester.pump(); // 无 pending timer
    });
  });
}
