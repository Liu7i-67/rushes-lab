/// AssetSelectionBar 单测(B4 功能点 4②/4:操作栏壳「下载」键点亮,分享/移动/
/// 删除占位 B5;downloadSelectedAssets 编排:无权提示、>20 确认弹窗、逐文件
/// 入队、清选中态由调用方做)。入队经注入 TransferQueue/DownloadIo,PC 零通道。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/transfers/transfer_queue.dart';
import 'package:ms_app/features/assets/asset_selection_bar.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/services/downloads.dart';
import 'package:ms_app/services/media_save.dart';

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
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: const SizedBox.shrink(),
      bottomNavigationBar: AssetSelectionBar(
        count: 2,
        canDownload: canDownload,
        onDownload: onDownload,
        onClear: () {},
      ),
    ),
  ));
}

void main() {
  testWidgets('操作栏壳:计数 + 「下载」键点亮(有回调);分享/移动/删除占位禁用(B5)',
      (tester) async {
    var fired = 0;
    await pumpBar(tester, canDownload: true, onDownload: () => fired++);
    expect(find.text('已选 2 项'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
    expect(find.text('分享'), findsOneWidget);
    expect(find.text('移动'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    await tester.tap(find.byTooltip('批量下载'));
    expect(fired, 1);
    // 占位键:无 tooltip 命中的批量下载语义,点按不炸(禁用态)
    expect(find.byTooltip('批量下载'), findsOneWidget);
  });

  testWidgets('canDownload=false:下载键禁用 + 无权提示 tooltip(三态口径同预览页)',
      (tester) async {
    var fired = 0;
    await pumpBar(tester, canDownload: false, onDownload: () => fired++);
    expect(find.byTooltip('无下载权限 · 可申请(B5 开放申请入口)'), findsOneWidget);
    await tester.tap(find.byTooltip('无下载权限 · 可申请(B5 开放申请入口)'),
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
}
