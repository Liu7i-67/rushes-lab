/// 测试功能点 6(B2):my_can_download=false → 下载钮禁用 + 「申请权限」入口样式
/// 提示(PreviewActions 组件态;三钮 B2 全批占位禁用)。
/// 附:数据新鲜度 RefreshBus 失效回调(功能点 5 的机制件)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/refresh_bus.dart';
import 'package:ms_app/features/preview/preview_actions.dart';

void main() {
  Future<void> pump(WidgetTester tester, {required bool? canDownload}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: PreviewActions(canDownload: canDownload)),
    ));
  }

  testWidgets('canDownload=false:下载钮禁用 + 申请权限提示文案在位', (tester) async {
    await pump(tester, canDownload: false);
    expect(find.text('下载'), findsOneWidget);
    expect(find.text('分享'), findsOneWidget);
    expect(find.text('申请权限'), findsOneWidget);
    // 无下载权 → 下载钮 tooltip 走「申请权限」入口提示(动作 B5 点亮)
    expect(
      find.byTooltip('无下载权限 · 可申请(B5 开放申请入口)'),
      findsOneWidget,
    );
  });

  testWidgets('canDownload=true:下载钮 tooltip 回落到「后续版本」占位', (tester) async {
    await pump(tester, canDownload: true);
    expect(find.byTooltip('后续版本开放'), findsNWidgets(3)); // 三钮全占位
    expect(find.byTooltip('无下载权限 · 可申请(B5 开放申请入口)'), findsNothing);
  });

  testWidgets('canDownload=null(夹详情未到/失败,B2 修复 P2-4 三态):与 true 同中性口径', (tester) async {
    await pump(tester, canDownload: null);
    // 详情未知 ≠ 无权限:提示退回中性「后续版本」,不误显「可申请」
    expect(find.byTooltip('后续版本开放'), findsNWidgets(3));
    expect(find.byTooltip('无下载权限 · 可申请(B5 开放申请入口)'), findsNothing);
  });

  testWidgets('两态均为禁用呈现:无可交互按钮(onPressed 类回调不存在)', (tester) async {
    for (final can in [false, true]) {
      await pump(tester, canDownload: can);
      // 占位禁用:组件只有 Tooltip+图标文本,无 IconButton/FilledButton 可点
      expect(find.byType(IconButton), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(TextButton), findsNothing);
    }
  });

  group('RefreshBus(数据新鲜度机制件)', () {
    test('invalidate 只回调对应 scope 的监听者;重复回调到解除为止', () {
      final bus = RefreshBus();
      var projects = 0;
      var folders = 0;
      void onProjects() => projects++;
      void onFolders() => folders++;
      bus
        ..addListener('projects', onProjects)
        ..addListener('folders', onFolders);

      bus.invalidate('projects');
      expect(projects, 1);
      expect(folders, 0);

      bus.removeListener('projects', onProjects);
      bus.invalidate('projects'); // 已解除,不再回调
      expect(projects, 1);

      bus.invalidate('folders');
      expect(folders, 1);
    });

    test('invalidate 期间新增/移除监听不影响本轮遍历(快照安全)', () {
      final bus = RefreshBus();
      var calls = 0;
      void reentrant() {
        calls++;
        bus.removeListener('s', reentrant); // 遍历中自摘
      }

      bus.addListener('s', reentrant);
      bus.invalidate('s');
      bus.invalidate('s'); // 已摘除
      expect(calls, 1);
    });
  });
}
