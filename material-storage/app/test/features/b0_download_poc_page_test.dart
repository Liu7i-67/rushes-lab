/// B0② 单测(PC):双路落盘编排 runBothSinks(纯 Dart,注入平台通道结果):
/// 并发启动、互不阻塞、单路抛错兜成失败 outcome;各路持独立副本——一路删自己的
/// 源文件不反噬另一路(Downloads 路 media_store_plus saveFile 会无条件删源,
/// 2026-10-20 真机竞态回归锁定);成功路副本清理。外加页面冒烟(渲染/空态)。
/// 真插件通道由 b0_sinks.dart 薄封装 + 真机验证承接(§16 B0② 决策)。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/features/me/b0_download_poc_page.dart';
import 'package:ms_app/features/me/b0_sink_plan.dart';

/// 真实源文件(runBothSinks 会为各路复制独立副本,必须可读)
Future<File> _makeSource({String name = 'IMG_0001.jpg'}) async {
  final dir = await Directory.systemTemp.createTemp('b0_plan_test');
  final f = File('${dir.path}/$name');
  await f.writeAsBytes(const [1, 2, 3, 4]);
  return f;
}

Future<void> _cleanupSrc(File src) async {
  try {
    await src.parent.delete(recursive: true);
  } catch (_) {
    // 测试自清理,失败不掩盖用例结果
  }
}

void main() {
  test('两路并发启动:先启动后等待,慢路不阻塞快路完成', () async {
    final src = await _makeSource();
    addTearDown(() => _cleanupSrc(src));
    final entered = <String>[];
    final exited = <String>[];
    final (g, d) = await runBothSinks(
      src,
      B0AssetKind.image,
      gallery: (f, k) async {
        entered.add('gallery');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        exited.add('gallery');
        return const B0SinkOutcome.ok('相册落点');
      },
      downloads: (f) async {
        entered.add('downloads');
        exited.add('downloads');
        return const B0SinkOutcome.ok('Downloads 落点');
      },
    );
    expect(g.detail, '相册落点');
    expect(d.detail, 'Downloads 落点');
    expect(entered.toSet(), {'gallery', 'downloads'},
        reason: '两路都已启动(不等慢路完成才启动快路)');
    expect(exited, ['downloads', 'gallery'], reason: '快路先完成');
  });

  test('图库路失败不影响 Downloads 路:各报各的成败与完整错误', () async {
    final src = await _makeSource(name: 'IMG_0002.livp');
    addTearDown(() => _cleanupSrc(src));
    final (g, d) = await runBothSinks(
      src,
      B0AssetKind.livp,
      gallery: (f, k) async => const B0SinkOutcome.fail('未获相册权限(模拟)'),
      downloads: (f) async =>
          const B0SinkOutcome.ok('Download/浣花视界/IMG.livp(模拟)'),
    );
    expect(g.isOk, isFalse);
    expect(g.detail, '未获相册权限(模拟)');
    expect(d.isOk, isTrue);
    expect(d.detail, contains('Download/浣花视界'));
  });

  test('单路抛异常兜成失败 outcome,另一路照常成功(编排级兜底)', () async {
    final src = await _makeSource(name: 'clip.mp4');
    addTearDown(() => _cleanupSrc(src));
    final (g, d) = await runBothSinks(
      src,
      B0AssetKind.video,
      gallery: (f, k) async => throw StateError('photo_manager 通道炸了'),
      downloads: (f) async => const B0SinkOutcome.ok('落点(模拟)'),
    );
    expect(g.isOk, isFalse);
    expect(g.detail, contains('图库路 异常'));
    expect(g.detail, contains('photo_manager 通道炸了'));
    expect(d.isOk, isTrue);
  });

  test('Downloads 路抛异常同样兜底,不反噬图库路', () async {
    final src = await _makeSource();
    addTearDown(() => _cleanupSrc(src));
    final (g, d) = await runBothSinks(
      src,
      B0AssetKind.image,
      gallery: (f, k) async => const B0SinkOutcome.ok('相册落点(模拟)'),
      downloads: (f) async =>
          throw const FileSystemException('no space', 'disk full'),
    );
    expect(g.isOk, isTrue);
    expect(d.isOk, isFalse);
    expect(d.detail, contains('disk full'));
  });

  test('竞态锁定:各路持独立副本,Downloads 路删自己的源不反噬图库路读取', () async {
    final src = await _makeSource();
    addTearDown(() => _cleanupSrc(src));
    final routes = <String>[];
    final (g, d) = await runBothSinks(
      src,
      B0AssetKind.image,
      gallery: (f, k) async {
        routes.add(f.path);
        // 复刻真机时序:等 Downloads 路先完成(其 saveFile 语义=搬运后删源),
        // 旧实现共用同一文件时此处 readAsBytes 必炸
        await Future<void>.delayed(const Duration(milliseconds: 30));
        final bytes = await f.readAsBytes();
        return B0SinkOutcome.ok('读到 ${bytes.length} 字节');
      },
      downloads: (f) async {
        routes.add(f.path);
        await f.delete(); // media_store_plus saveFile 实证行为:搬运后无条件删源
        return const B0SinkOutcome.ok('已搬运');
      },
    );
    expect(routes.toSet().length, 2, reason: '两路文件路径互不相同(独立副本)');
    expect(d.isOk, isTrue);
    expect(g.isOk, isTrue,
        reason: '图库路用自己的副本,不受 Downloads 路删源影响');
    expect(g.detail, '读到 4 字节');
    // 源文件未被任何一路动过(删源只发生在各路副本上)
    expect(await src.exists(), isTrue);
  });

  test('成功路副本清理,失败路副本保留供取证', () async {
    final src = await _makeSource();
    addTearDown(() => _cleanupSrc(src));
    File? okCopy;
    File? failCopy;
    final (g, d) = await runBothSinks(
      src,
      B0AssetKind.image,
      gallery: (f, k) async {
        okCopy = f;
        return const B0SinkOutcome.ok('相册落点(模拟)');
      },
      downloads: (f) async {
        failCopy = f;
        return const B0SinkOutcome.fail('未获存储权限(模拟)');
      },
    );
    expect(g.isOk, isTrue);
    expect(d.isOk, isFalse);
    // 副本清理是 fire-and-forget(_cleanupCopy 的 .ignore()),固定 10ms 在重
    // IO 负载下偶发不可见(B3 全量回归 16MB 分片用例并发写盘时实锤一次);
    // 改有界轮询兜住,语义不放宽:终态必须删干净
    var gone = false;
    for (var i = 0; i < 100 && !gone; i++) {
      gone = !(await okCopy!.exists());
      if (!gone) await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(gone, isTrue, reason: '成功路副本已清理');
    expect(await failCopy!.exists(), isTrue, reason: '失败路副本保留供真机取证');
    expect(await File(failCopy!.path).readAsBytes(), const [1, 2, 3, 4]);
  });

  test('源文件不可读:两路各自兜成失败 outcome(编排不抛出)', () async {
    final dir = await Directory.systemTemp.createTemp('b0_plan_test');
    addTearDown(() => dir.delete().ignore());
    final missing = File('${dir.path}/ghost.jpg'); // 从未写入
    final (g, d) = await runBothSinks(
      missing,
      B0AssetKind.image,
      gallery: (f, k) async => const B0SinkOutcome.ok('不该到达'),
      downloads: (f) async => const B0SinkOutcome.ok('不该到达'),
    );
    expect(g.isOk, isFalse);
    expect(g.detail, contains('图库路 异常'));
    expect(d.isOk, isFalse);
    expect(d.detail, contains('Downloads 路 异常'));
  });

  testWidgets('页面冒烟:渲染双路卡;空 asset_id 点执行仅警示', (tester) async {
    final msApi = MsApi(baseUrl: 'http://mock.local'); // 不触网,仅占位注入
    await tester.pumpWidget(MaterialApp(
        home: B0DownloadPocPage(
      api: msApi,
      gallerySink: (f, k) async => const B0SinkOutcome.ok('x'),
      downloadsSink: (f) async => const B0SinkOutcome.ok('x'),
    )));
    expect(find.textContaining('① 图库路'), findsOneWidget);
    expect(find.textContaining('② Downloads 路'), findsOneWidget);
    expect(find.text('待执行'), findsNWidgets(2));
    await tester.tap(find.text('下载并双路落盘'));
    await tester.pump();
    expect(find.text('请先输入 asset_id 或点「取第一页第一个」'), findsOneWidget);
  });
}
