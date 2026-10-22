/// 边界补测(测试子智能体):UpdateCheckTile 本地版本读取抛异常时的兜底 —
/// 版本行落「…」、入口仍可点(任务书边界项)。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/update/update_flow.dart';
import 'package:ms_app/features/me/update_tile.dart';

/// 恒抛异常的本地版本来源(复刻 PackageInfo 通道缺失)。
Future<LocalAppVersion> _boom() async => throw StateError('no package_info');

class _RecordingFlow extends AppUpdateFlow {
  int manualChecks = 0;

  @override
  Future<void> manualCheck(BuildContext context) async {
    manualChecks++;
  }
}

Future<void> _pumpTile(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pump(); // initState 异步 _load 微任务
  await tester.pump(); // setState 后重渲染
}

void main() {
  testWidgets('Android 态:localVersion 抛异常 → 版本行「…」且入口仍可点',
      (tester) async {
    final flow = _RecordingFlow();
    await _pumpTile(
      tester,
      UpdateCheckTile(
        isAndroid: true,
        flow: flow,
        localVersion: _boom,
      ),
    );

    expect(find.text('当前版本 …'), findsOneWidget,
        reason: '读取异常静默,版本行落 …');
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('检查更新'));
    await tester.pump();
    expect(flow.manualChecks, 1, reason: '版本读取失败不影响检查入口可用');
  });

  testWidgets('iOS 态:localVersion 抛异常 → trailing 落「…」,行仍渲染',
      (tester) async {
    await _pumpTile(
      tester,
      UpdateCheckTile(isAndroid: false, localVersion: _boom),
    );

    expect(find.text('当前版本'), findsOneWidget);
    expect(find.text('…'), findsOneWidget, reason: 'iOS 版本行 trailing 落 …');
    expect(tester.takeException(), isNull);
  });

  testWidgets('localVersion 正常后由「…」切换为具体版本号', (tester) async {
    final completer = Completer<LocalAppVersion>();
    await _pumpTile(
      tester,
      UpdateCheckTile(
        isAndroid: false,
        localVersion: () => completer.future,
      ),
    );

    expect(find.text('…'), findsOneWidget, reason: '读取中显示 …');
    completer.complete((version: '2.3.4', build: 7));
    await tester.pump();
    await tester.pump();
    expect(find.text('2.3.4+7'), findsOneWidget);
    expect(find.text('…'), findsNothing);
  });
}
