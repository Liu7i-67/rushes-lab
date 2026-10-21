/// R4a(mobile-ux-polish-2)「我的」页传输通知状态行单测:
/// - TransferNotifyTile 注入桩:已开启(✓ 纯展示)/未开启(点击跳系统设置,
///   返回后自动重查实时刷新)/查询中(占位);仅未开启可点,跳前不再弹引导框;
/// - MePage 集成:「传输」区出现「传输通知」行;真实查询路径在测试环境降级
///   为已开启(查不出不误报未开启)。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/features/me/me_page.dart';

void main() {
  group('TransferNotifyTile(R4a 状态行)', () {
    testWidgets('已开启:✓ 标识纯展示,不可点(不弹引导不跳设置)', (tester) async {
      var queries = 0;
      var openCalls = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TransferNotifyTile(
            query: () async {
              queries++;
              return true;
            },
            openSettings: () async => openCalls++,
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('传输通知'), findsOneWidget);
      expect(find.text('已开启,后台上传/下载完成可提醒'), findsOneWidget);
      expect(find.text('✓已开启'), findsOneWidget);

      await tester.tap(find.text('传输通知'), warnIfMissed: false);
      await tester.pump();
      expect(openCalls, 0, reason: '已开启态 onTap=null(纯展示)');
      expect(queries, 1, reason: '仅 initState 查一次');
    });

    testWidgets('未开启:可点跳设置;返回后自动重查实时刷新为已开启',
        (tester) async {
      final results = <bool>[false, true];
      var openCalls = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TransferNotifyTile(
            query: () async =>
                results.isNotEmpty ? results.removeAt(0) : true,
            openSettings: () async => openCalls++,
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('未开启,收不到后台传输完成提醒'), findsOneWidget);
      expect(find.text('未开启'), findsOneWidget,
          reason: 'trailing 状态字(与「未开启,收不到…」subtitle 区分)');
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);

      await tester.tap(find.text('传输通知'));
      await tester.pump();
      await tester.pump();
      expect(openCalls, 1, reason: '点击 → 跳系统设置');
      expect(find.text('✓已开启'), findsOneWidget,
          reason: '设置页开启返回 → 自动重查实时刷新(resumed 观察者+返回即查)');
    });

    testWidgets('查询中:占位展示,不可点', (tester) async {
      final gate = Completer<bool>();
      var openCalls = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TransferNotifyTile(
            query: () => gate.future,
            openSettings: () async => openCalls++,
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('查询中…'), findsOneWidget);

      await tester.tap(find.text('传输通知'), warnIfMissed: false);
      await tester.pump();
      expect(openCalls, 0, reason: '查询中 onTap=null');
      gate.complete(true);
      await tester.pump();
      await tester.pump(); // 微任务续体(setState)→ 下一帧渲染
      expect(find.text('✓已开启'), findsOneWidget);
    });
  });

  testWidgets('MePage 集成:「传输」区挂「传输通知」行;测试环境降级不误报未开启',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: MePage()));
    await tester.pump();
    await tester.pump();

    expect(find.text('传输通知'), findsOneWidget);
    // 无插件通道 → queryPermission 降级 true → 按已开启呈现
    expect(find.text('✓已开启'), findsOneWidget,
        reason: '真实路径在无插件环境降级为已开启(查不出不误报)');
    expect(find.text('未开启,收不到后台传输完成提醒'), findsNothing);
  });
}
