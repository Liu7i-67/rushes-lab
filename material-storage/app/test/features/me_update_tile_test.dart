/// 测试功能点 T4(F2-1/D6):「我的」页更新区平台 gate widget 单测 —
/// 当前版本号 x.y.z+n 全平台展示;「检查更新」入口仅 Android 渲染,
/// 点击触发一次 manualCheck,检查中(转圈)不可重复点。
/// isAndroid/localVersion/flow 全注入,不触 Platform 与 PackageInfo。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/update/update_flow.dart';
import 'package:ms_app/features/me/update_tile.dart';

Future<LocalAppVersion> _fakeLocal() async => (version: '0.1.0', build: 4);

/// 记录 manualCheck 调用;gate 非空时挂起以复刻「检查中」态。
class _RecordingFlow extends AppUpdateFlow {
  int manualChecks = 0;
  Completer<void>? gate;

  @override
  Future<void> manualCheck(BuildContext context) async {
    manualChecks++;
    final g = gate;
    if (g != null) await g.future;
  }
}

Future<void> _pumpTile(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pump(); // initState 异步 _load 微任务
  await tester.pump(); // setState 后重渲染
}

void main() {
  group('T4 平台 gate(UpdateCheckTile)', () {
    testWidgets('isAndroid=false(iOS/web):仅版本行,无「检查更新」入口',
        (tester) async {
      await _pumpTile(
        tester,
        UpdateCheckTile(isAndroid: false, localVersion: _fakeLocal),
      );

      expect(find.text('当前版本'), findsOneWidget);
      expect(find.text('0.1.0+4'), findsOneWidget, reason: '版本号全平台展示(F2-1)');
      expect(find.textContaining('检查更新'), findsNothing,
          reason: 'iOS/web 不渲染检查入口(D6)');
      expect(find.byIcon(Icons.info_outline), findsOneWidget);
      expect(find.byIcon(Icons.system_update_outlined), findsNothing);
    });

    testWidgets('isAndroid=true:渲染「检查更新」入口,版本号在副标题',
        (tester) async {
      await _pumpTile(
        tester,
        UpdateCheckTile(isAndroid: true, localVersion: _fakeLocal),
      );

      expect(find.text('检查更新'), findsOneWidget);
      expect(find.text('当前版本 0.1.0+4'), findsOneWidget);
      expect(find.byIcon(Icons.system_update_outlined), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: '空闲态无进行中转圈');
    });

    testWidgets('isAndroid=true:点击触发一次 manualCheck;检查中不可重复点',
        (tester) async {
      final flow = _RecordingFlow()..gate = Completer<void>();
      await _pumpTile(
        tester,
        UpdateCheckTile(
          isAndroid: true,
          flow: flow,
          localVersion: _fakeLocal,
        ),
      );

      await tester.tap(find.text('检查更新'));
      await tester.pump();
      expect(flow.manualChecks, 1);
      expect(find.byType(CircularProgressIndicator), findsOneWidget,
          reason: '检查中呈现进行中态');

      await tester.tap(find.text('检查更新'), warnIfMissed: false);
      await tester.pump();
      expect(flow.manualChecks, 1, reason: 'onTap=null,进行中不重复触发');

      flow.gate!.complete();
      await tester.pump();
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: '检查结束回到空闲态');
    });
  });
}
