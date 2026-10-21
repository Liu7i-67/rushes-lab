/// AssetSelectionBar 单测(B5 功能点 1:操作栏全量点亮;下载 B4 编排保留):
/// 四键回调点亮/多选置灰(分享·申请权限仅恰好单选)/⋯ 菜单三项;
/// deleteSelectedAssets 编排:确认弹窗、逐条 DELETE、403 detail 透传、失效。
/// 入队经注入 TransferQueue/DownloadIo,PC 零通道。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/refresh_bus.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/core/transfers/transfer_queue.dart';
import 'package:ms_app/features/assets/asset_selection_bar.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/services/downloads.dart';
import 'package:ms_app/services/media_save.dart';

import '../helpers/api_harness.dart';

Asset _asset(String name) => Asset(
    id: 'a-$name', filename: name, sizeBytes: 10,
    contentType: 'application/zip', createdAt: '2026-10-20T10:00:00Z');

DownloadIo _io() => DownloadIo(
      link: (a) async => 'http://presigned/${a.filename}',
      fetch: ({required url, required savePath, required totalBytes,
        required onProgress, required token}) async {
        final f = File(savePath);
        await f.writeAsBytes(const [1]);
        onProgress(totalBytes);
        return f;
      },
      freeBytes: (_) async => 1 << 40,
      tempRoot: () => Directory.systemTemp.createTemp('sel_bar_test'),
      savers: PlatformSavers(
        gallery: (f, a) async => const SinkOutcome.ok('相册'),
        downloads: (f) async => const SinkOutcome.ok('Downloads'),
        share: (f) async => const SinkOutcome.ok('share'),
      ),
      toast: (_) {},
    );

Future<void> pumpBar(
  WidgetTester tester, {
  required bool? canDownload,
  required VoidCallback onDownload,
  int count = 2,
  VoidCallback? onShare,
  VoidCallback? onMove,
  VoidCallback? onDelete,
  VoidCallback? onBatchTag,
  VoidCallback? onBatchPrefix,
  VoidCallback? onRequest,
  VoidCallback? onClear,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: const SizedBox.shrink(),
      bottomNavigationBar: AssetSelectionBar(
        count: count,
        canDownload: canDownload,
        onDownload: onDownload,
        onShare: onShare,
        onMove: onMove,
        onDelete: onDelete,
        onBatchTag: onBatchTag,
        onBatchPrefix: onBatchPrefix,
        onRequest: onRequest,
        onClear: onClear ?? () {},
      ),
    ),
  ));
}

void main() {
  testWidgets('操作栏全量(B5):四键点亮回调 + ⋯ 菜单三项(打标/前缀/申请)',
      (tester) async {
    var fired = '';
    await pumpBar(tester,
        canDownload: true,
        count: 1,
        onDownload: () => fired = 'download',
        onShare: () => fired = 'share',
        onMove: () => fired = 'move',
        onDelete: () => fired = 'delete',
        onBatchTag: () => fired = 'tag',
        onBatchPrefix: () => fired = 'prefix',
        onRequest: () => fired = 'request');
    expect(find.text('已选 1 项'), findsOneWidget);
    await tester.tap(find.byTooltip('批量下载'));
    expect(fired, 'download');
    await tester.tap(find.byTooltip('分享链接(需登录访问)'));
    expect(fired, 'share');
    await tester.tap(find.byTooltip('移动到其他目录'));
    expect(fired, 'move');
    await tester.tap(find.byTooltip('移入回收站'));
    expect(fired, 'delete');
    // ⋯ 溢出菜单
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('批量打标'));
    await tester.pumpAndSettle();
    expect(fired, 'tag');
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('批量前缀'));
    await tester.pumpAndSettle();
    expect(fired, 'prefix');
  });

  testWidgets('多选置灰:分享/申请权限仅恰好单选可用(B5 钉子);⋯ 菜单申请项禁用',
      (tester) async {
    var shareFired = 0;
    var requestFired = 0;
    await pumpBar(tester,
        canDownload: true,
        count: 2,
        onDownload: () {},
        onShare: () => shareFired++,
        onRequest: () => requestFired++);
    await tester.tap(find.byTooltip('仅单选可用'), warnIfMissed: false);
    await tester.pump();
    expect(shareFired, 0, reason: '多选分享置灰');
    // ⋯ 菜单:申请权限带「仅单选可用」副标题且禁用
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('仅单选可用'), findsOneWidget);
    await tester.tap(find.text('申请权限'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(requestFired, 0);
    // 禁用项点选不关闭弹出菜单 → 点空白处先收起,避免遮住后续操作键
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    // 恰好单选时可用(点 label 文本直击 InkWell,绕开 Tooltip 命中怪癖)
    await pumpBar(tester,
        canDownload: true,
        count: 1,
        onDownload: () {},
        onShare: () => shareFired++,
        onRequest: () => requestFired++);
    await tester.pump();
    await tester.tap(find.text('分享'));
    await tester.pump();
    expect(shareFired, 1);
    expect(find.byTooltip('仅单选可用'), findsNothing, reason: '单选不再置灰');
  });

  testWidgets('canDownload=false:下载键禁用 + 无权提示 tooltip(三态口径同预览页)',
      (tester) async {
    var fired = 0;
    await pumpBar(tester, canDownload: false, onDownload: () => fired++);
    expect(find.byTooltip('无下载权限 · 可先在预览页申请'), findsOneWidget);
    await tester.tap(find.byTooltip('无下载权限 · 可先在预览页申请'),
        warnIfMissed: false);
    expect(fired, 0);
  });

  testWidgets('downloadSelectedAssets:canDownload=false → 提示并不入队', (tester) async {
    final q = TransferQueue();
    late BuildContext captured;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) {
            captured = ctx;
            return const SizedBox.shrink();
          },
        ),
      ),
    ));
    final r = await downloadSelectedAssets(
      captured,
      assets: [_asset('a.jpg')],
      canDownload: false,
      where: 'w',
      queue: q,
      io: _io(),
    );
    expect(r, isNull);
    expect(q.tasks, isEmpty);
    await tester.pump(); // SnackBar 进场帧
    expect(find.textContaining('无下载权限'), findsOneWidget);
  });

  testWidgets('downloadSelectedAssets:≤20 直接逐文件入队,汇总 toast 报数',
      (tester) async {
    final q = TransferQueue();
    late BuildContext captured;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) {
            captured = ctx;
            return const SizedBox.shrink();
          },
        ),
      ),
    ));
    final r = await downloadSelectedAssets(
      captured,
      assets: [_asset('a.jpg'), _asset('b.jpg')],
      canDownload: true,
      where: '项目/夹',
      queue: q,
      io: _io(),
    );
    expect(r, (2, 0));
    expect(q.tasks.length, 2, reason: '逐文件入队');
    await tester.pump(); // SnackBar 进场帧
    expect(find.text('已加入下载队列 2 个'), findsOneWidget);
    // 不在 testWidgets(FakeAsync)里等队列跑完:worker 走真实文件 IO,
    // FakeAsync 不推进;入队计数与 toast 已断言,编排细节见 downloads_test
  });

  testWidgets('downloadSelectedAssets:>20 弹确认;取消 → 不入队;继续 → 全量入队',
      (tester) async {
    final q = TransferQueue();
    late BuildContext captured;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) {
            captured = ctx;
            return const SizedBox.shrink();
          },
        ),
      ),
    ));
    final assets = [for (var i = 0; i < 21; i++) _asset('f$i.jpg')];

    // 取消路径:弹窗出现且不入队
    final canceled = downloadSelectedAssets(
      captured,
      assets: assets,
      canDownload: true,
      where: 'w',
      queue: q,
      io: _io(),
    );
    await tester.pump(); // dialog 进场
    expect(find.text('批量下载确认'), findsOneWidget);
    expect(find.textContaining('即将下载 21 个文件'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(await canceled, isNull, reason: '用户取消确认 → null');
    expect(q.tasks, isEmpty);

    // 继续路径:确认后 21 个逐文件入队
    final go = downloadSelectedAssets(
      captured,
      assets: assets,
      canDownload: true,
      where: 'w',
      queue: q,
      io: _io(),
    );
    await tester.pump();
    await tester.tap(find.text('继续下载'));
    final r = await go;
    expect(r, (21, 0));
    expect(q.tasks.length, 21);
  });

  testWidgets('deleteSelectedAssets:确认弹窗取消 → null 不发请求', (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    late BuildContext captured;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (ctx) {
          captured = ctx;
          return const SizedBox.shrink();
        }),
      ),
    ));
    final r = deleteSelectedAssets(captured,
        assets: [_asset('a.jpg')], folderId: 'f1');
    await tester.pump(); // 弹窗进场
    expect(find.text('删除 1 个文件?'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(await r, isNull);
    expect(api.assets.deleteCalls, isEmpty);
  });

  testWidgets('deleteSelectedAssets:全败(403)→ (0,1) 不失效;detail 透传入汇总',
      (tester) async {
    final api = installFakeApi();
    api.assets.deleteStaged =
        ApiException(403, 'no permission to delete this asset');
    addTearDown(() => session.api = null);
    var assetsInvalidated = 0;
    var foldersInvalidated = 0;
    void onAssets() => assetsInvalidated++;
    void onFolders() => foldersInvalidated++;
    RefreshBus.I.addListener('assets:f1', onAssets);
    RefreshBus.I.addListener('folders', onFolders);
    addTearDown(() {
      RefreshBus.I.removeListener('assets:f1', onAssets);
      RefreshBus.I.removeListener('folders', onFolders);
    });

    late BuildContext captured;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (ctx) {
          captured = ctx;
          return const SizedBox.shrink();
        }),
      ),
    ));
    final allFail = deleteSelectedAssets(captured,
        assets: [_asset('403.jpg')], folderId: 'f1');
    await tester.pump(); // 弹窗进场
    await tester.tap(find.text('删除'));
    expect(await allFail, (0, 1));
    expect(assetsInvalidated, 0, reason: '全败不失效');
    await tester.pump(); // SnackBar 进场
    expect(find.textContaining('删除 0 个文件 · 失败 1 个'), findsOneWidget);
    expect(find.textContaining('首个失败:no permission to delete this asset'),
        findsOneWidget, reason: '403 detail 透传入汇总');
  });

  testWidgets('deleteSelectedAssets:全成功 → (n,0) 并失效两 scope', (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    var assetsInvalidated = 0;
    var foldersInvalidated = 0;
    void onAssets() => assetsInvalidated++;
    void onFolders() => foldersInvalidated++;
    RefreshBus.I.addListener('assets:f1', onAssets);
    RefreshBus.I.addListener('folders', onFolders);
    addTearDown(() {
      RefreshBus.I.removeListener('assets:f1', onAssets);
      RefreshBus.I.removeListener('folders', onFolders);
    });

    late BuildContext captured;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (ctx) {
          captured = ctx;
          return const SizedBox.shrink();
        }),
      ),
    ));
    final r = deleteSelectedAssets(captured,
        assets: [_asset('ok1.jpg'), _asset('ok2.jpg')], folderId: 'f1');
    await tester.pump(); // 弹窗进场
    await tester.tap(find.text('删除'));
    expect(await r, (2, 0));
    expect(api.assets.deleteCalls, ['a-ok1.jpg', 'a-ok2.jpg'],
        reason: '逐条 DELETE');
    expect(assetsInvalidated, greaterThan(0));
    expect(foldersInvalidated, greaterThan(0));
  });

  testWidgets('deleteSelectedAssets:部分失败(2 ok+1 fail)→ (2,1) 失效一次,'
      '汇总含首个失败 detail', (tester) async {
    final api = installFakeApi();
    api.assets.deleteStagedById['a-403.jpg'] =
        ApiException(403, 'no permission to delete this asset');
    addTearDown(() {
      session.api = null;
      api.assets.deleteStagedById.clear();
    });
    var assetsInvalidated = 0;
    void onAssets() => assetsInvalidated++;
    RefreshBus.I.addListener('assets:f1', onAssets);
    addTearDown(() => RefreshBus.I.removeListener('assets:f1', onAssets));

    late BuildContext captured;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (ctx) {
          captured = ctx;
          return const SizedBox.shrink();
        }),
      ),
    ));
    final r = deleteSelectedAssets(captured,
        assets: [_asset('ok1.jpg'), _asset('403.jpg'), _asset('ok2.jpg')],
        folderId: 'f1');
    await tester.pump(); // 弹窗进场
    await tester.tap(find.text('删除'));
    expect(await r, (2, 1), reason: '失败不中断:ok=2 fail=1');
    expect(api.assets.deleteCalls,
        ['a-ok1.jpg', 'a-403.jpg', 'a-ok2.jpg'],
        reason: '单条失败后继续删完剩余');
    expect(assetsInvalidated, greaterThan(0),
        reason: '有任一成功即失效(宫格订阅静默刷新)');
    await tester.pump(); // SnackBar 进场
    expect(find.text('删除 2 个文件 · 失败 1 个'
        '(首个失败:no permission to delete this asset)'), findsOneWidget);
  });
}
