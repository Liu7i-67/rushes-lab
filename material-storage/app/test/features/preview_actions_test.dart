/// 预览页操作钮单测(B4 功能点 4①):下载钮点亮(onDownload 注入,入队
/// TransferQueue kind=download);my_can_download=false → 禁用+「申请权限」
/// 入口样式提示(申请动作 B5 点亮);null=中性放行(详情未到≠无权,后端 403
/// 最终裁决);分享/申请权限仍占位禁用(B5)。附 RefreshBus 机制件单测(原
/// B2 批落位于此,随迁保留)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/refresh_bus.dart';
import 'package:ms_app/features/preview/preview_actions.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required bool? canDownload,
    VoidCallback? onDownload,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PreviewActions(canDownload: canDownload, onDownload: onDownload),
      ),
    ));
  }

  testWidgets('点亮态:canDownload=true + onDownload → 点按触发入队回调', (tester) async {
    var fired = 0;
    await pump(tester, canDownload: true, onDownload: () => fired++);
    await tester.tap(find.text('下载'));
    expect(fired, 1);
    expect(find.byTooltip('下载到本机(相册 / Download/浣花视界)'), findsOneWidget);
    expect(find.byTooltip('无下载权限 · 可申请(B5 开放申请入口)'), findsNothing);
  });

  testWidgets('canDownload=false:下载钮禁用(点按不触发)+ 申请权限提示在位',
      (tester) async {
    var fired = 0;
    await pump(tester, canDownload: false, onDownload: () => fired++);
    await tester.tap(find.text('下载'), warnIfMissed: false);
    await tester.pump();
    expect(fired, 0, reason: '已知无权 → 禁用');
    expect(find.byTooltip('无下载权限 · 可申请(B5 开放申请入口)'), findsOneWidget);
  });

  testWidgets('canDownload=null(夹详情未到/失败,三态):中性放行,不误显可申请',
      (tester) async {
    var fired = 0;
    await pump(tester, canDownload: null, onDownload: () => fired++);
    await tester.tap(find.text('下载'));
    expect(fired, 1);
    expect(find.byTooltip('无下载权限 · 可申请(B5 开放申请入口)'), findsNothing);
  });

  testWidgets('onDownload 缺省(null):下载钮退占位禁用「后续版本开放」', (tester) async {
    await pump(tester, canDownload: true);
    expect(find.byTooltip('后续版本开放'), findsNWidgets(3));
  });

  testWidgets('分享/申请权限仍占位禁用(B5);禁用态无可交互按钮', (tester) async {
    var fired = 0;
    await pump(tester, canDownload: true, onDownload: () => fired++);
    await tester.tap(find.text('分享'), warnIfMissed: false);
    await tester.tap(find.text('申请权限'), warnIfMissed: false);
    await tester.pump();
    expect(fired, 0);
    expect(find.byTooltip('后续版本开放'), findsNWidgets(2));
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
