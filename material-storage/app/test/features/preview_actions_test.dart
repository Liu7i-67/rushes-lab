/// 预览页操作钮单测(B4 下载点亮保留;B5 功能点 4:分享/申请权限点亮):
/// 分享=单资产恒可点(后端 403 最终裁决);申请权限=my_can_download==false 时
/// 入口可点;canDownload=null 中性(申请不亮)。附 RefreshBus 机制件单测(原
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
    VoidCallback? onShare,
    VoidCallback? onRequest,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PreviewActions(
          canDownload: canDownload,
          onDownload: onDownload,
          onShare: onShare,
          onRequest: onRequest,
        ),
      ),
    ));
  }

  testWidgets('点亮态:canDownload=true + onDownload → 点按触发入队回调', (tester) async {
    var fired = 0;
    await pump(tester, canDownload: true, onDownload: () => fired++);
    await tester.tap(find.text('下载'));
    expect(fired, 1);
    expect(find.byTooltip('下载到本机(相册 / Download/浣花视界)'), findsOneWidget);
    expect(find.byTooltip('无下载权限 · 可申请'), findsNothing);
  });

  testWidgets('canDownload=false:下载钮禁用(点按不触发)+ 申请权限点亮可点(B5)',
      (tester) async {
    var downloadFired = 0;
    var requestFired = 0;
    await pump(tester,
        canDownload: false,
        onDownload: () => downloadFired++,
        onRequest: () => requestFired++);
    await tester.tap(find.text('下载'), warnIfMissed: false);
    await tester.pump();
    expect(downloadFired, 0, reason: '已知无权 → 禁用');
    expect(find.byTooltip('无下载权限 · 可申请'), findsOneWidget);
    await tester.tap(find.text('申请权限'));
    await tester.pump();
    expect(requestFired, 1, reason: 'my_can_download==false → 申请入口可点');
  });

  testWidgets('canDownload=null(夹详情未到/失败,三态):下载中性放行,申请入口不亮',
      (tester) async {
    var downloadFired = 0;
    var requestFired = 0;
    await pump(tester,
        canDownload: null,
        onDownload: () => downloadFired++,
        onRequest: () => requestFired++);
    await tester.tap(find.text('下载'));
    expect(downloadFired, 1);
    await tester.tap(find.text('申请权限'), warnIfMissed: false);
    await tester.pump();
    expect(requestFired, 0, reason: 'null=详情未到,申请入口不亮(详情到了再看)');
  });

  testWidgets('canDownload=true:申请权限禁用(已有下载权,无需申请)', (tester) async {
    var requestFired = 0;
    await pump(tester, canDownload: true, onRequest: () => requestFired++);
    expect(find.byTooltip('已有下载权限,无需申请'), findsOneWidget);
    await tester.tap(find.text('申请权限'), warnIfMissed: false);
    await tester.pump();
    expect(requestFired, 0);
  });

  testWidgets('分享钮点亮(B5):回调注入即可点;未注入时退占位「后续版本开放」',
      (tester) async {
    var shareFired = 0;
    await pump(tester,
        canDownload: true,
        onShare: () => shareFired++,
        onDownload: () {},
        onRequest: () {});
    await tester.tap(find.text('分享'));
    expect(shareFired, 1);
    expect(find.byTooltip('分享链接(需登录访问)'), findsOneWidget);
    // 全回调缺省:下载/分享退占位
    await pump(tester, canDownload: true);
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
