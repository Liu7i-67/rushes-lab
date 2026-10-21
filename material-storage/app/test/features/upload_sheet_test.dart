/// 统一上传面板纯函数 + 批量入队纯循环 + 迷你进度条单测(B3 测试功能点
/// 6/7;B3 修复 P1-1:批量入队单点失败不中断整批):
/// filename 净化(沿用 LivpService.baseNameOf 钉子)/ content_type 扩展名映射 /
/// 上传成功 → RefreshBus invalidate 收到(宫格订阅同源) / enqueueBatch 单点
/// 失败跳过不中断 / 迷你条 n/m 计数与显隐。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/content_types.dart';
import 'package:ms_app/core/refresh_bus.dart';
import 'package:ms_app/core/transfers/transfer_queue.dart';
import 'package:ms_app/core/transfers/transfer_task.dart';
import 'package:ms_app/features/assets/upload_sheet.dart';

void main() {
  group('sanitizeUploadName(filename 净化钉子)', () {
    test('常规名原样保留(含扩展名)', () {
      expect(sanitizeUploadName('IMG_1234.livp'), 'IMG_1234.livp');
      expect(sanitizeUploadName('hello.mov'), 'hello.mov');
    });
    test('路径分隔符净化:取 basename,不应 400(create_upload 拒 "/")', () {
      expect(sanitizeUploadName(r'a\b\c.png'), 'c.png');
      expect(sanitizeUploadName('x/y.mov'), 'y.mov');
      // iOS PHAsset localIdentifier 兜底名形如 UUID/L0/001
      expect(sanitizeUploadName('UUID/L0/001'), '001');
    });
    test('空/点文件走兜底基名(空基名点文件钉子)', () {
      expect(sanitizeUploadName(''), '文件');
      expect(sanitizeUploadName('   '), '文件');
      expect(sanitizeUploadName('.livp'), '文件', reason: '点文件=空基名,走兜底');
      expect(sanitizeUploadName('', fallback: 'IMG_9'), 'IMG_9');
    });
  });

  group('contentTypeForFilename(§5 扩展名映射)', () {
    test('常见类型:大小写不敏感', () {
      expect(contentTypeForFilename('a.MOV'), 'video/quicktime');
      expect(contentTypeForFilename('b.heic'), 'image/heic');
      expect(contentTypeForFilename('c.mp4'), 'video/mp4');
      expect(contentTypeForFilename('d.jpg'), 'image/jpeg');
      expect(contentTypeForFilename('e.pdf'), 'application/pdf');
    });
    test('livp 固定 application/zip(现役语义);未识别落 octet-stream', () {
      expect(contentTypeForFilename('f.livp'), 'application/zip');
      expect(contentTypeForFilename('g.livp'.toUpperCase()), 'application/zip');
      expect(contentTypeForFilename('noext'), 'application/octet-stream');
      expect(contentTypeForFilename('.hidden'), 'application/octet-stream',
          reason: '点文件无主名');
    });
  });

  group('notifyUploadSuccess(§8.1 数据新鲜度)', () {
    test('上传成功 → assets:<folderId> 与 folders 双失效,无关 scope 不动',
        () {
      final hits = <String>[];
      void lAssets() => hits.add('assets:f9');
      void lFolders() => hits.add('folders');
      void lProjects() => hits.add('projects');
      RefreshBus.I.addListener('assets:f9', lAssets);
      RefreshBus.I.addListener('folders', lFolders);
      RefreshBus.I.addListener('projects', lProjects);
      addTearDown(() {
        RefreshBus.I.removeListener('assets:f9', lAssets);
        RefreshBus.I.removeListener('folders', lFolders);
        RefreshBus.I.removeListener('projects', lProjects);
      });

      notifyUploadSuccess('f9');
      expect(hits, containsAll(['assets:f9', 'folders']));
      expect(hits, isNot(contains('projects')));
    });
  });

  group('enqueueBatch(P1-1:批量入队单点失败不中断整批)', () {
    test('3 项批次第 2 项抛错 → 2 项入队 + 1 项跳过,其余顺序保持', () async {
      final done = <int>[];
      final errors = <Object>[];
      final r = await enqueueBatch(
        List.generate(3, (i) => () async {
          // 模拟 iCloud 未下载:第 2 项 entityToLivp 抛 StateError
          if (i == 1) throw StateError('iCloud 未下载(asset 2)');
          done.add(i);
        }),
        onError: errors.add,
      );
      expect(r.$1, 2, reason: '入队数=2');
      expect(r.$2, 1, reason: '跳过数=1');
      expect(done, [0, 2], reason: '第 2 项失败不中断第 1、3 项');
      expect(errors, hasLength(1), reason: '失败项经 onError 逐项上报');
      expect(errors.single, isA<StateError>());
    });

    test('空批次 → (0,0);全部失败 → (0,n),异常不外泄', () async {
      expect(await enqueueBatch(<Future<void> Function()>[]), (0, 0));
      final r = await enqueueBatch(
          List.generate(2, (i) => () async => throw StateError('x$i')));
      expect(r, (0, 2));
    });

    test('batchSummary 文案:有跳过报双数,无跳过只报入队数', () {
      expect(batchSummary(2, 1), '已入队 2 个,跳过 1 个');
      expect(batchSummary(3, 0), '已入队 3 个');
      expect(batchSummary(0, 3), '已入队 0 个,跳过 3 个');
    });
  });

  group('UploadMiniBar(§5 队列指示)', () {
    testWidgets('有活动上传才显示;n/m=已完成/总上传数;条=聚合字节进度',
        (tester) async {
      final q = TransferQueue();
      final gateA = Completer<void>();
      final gateB = Completer<void>();
      TransferRequest req(String name, int total, Completer<void> gate) =>
          TransferRequest(
            kind: TransferKind.upload,
            filename: name,
            where: '项目/夹',
            totalBytes: total,
            worker: (p, token) async {
              p(name == 'a' ? 50 : 0);
              await gate.future;
            },
          );
      q.enqueue(req('a', 200, gateA));
      q.enqueue(req('b', 100, gateB));
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: UploadMiniBar(queue: q))));
      await tester.pump();
      expect(find.text('0/2'), findsOneWidget, reason: 'n/m=已完成/总上传数');
      expect(
        tester.widget<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator)),
        isA<LinearProgressIndicator>()
            .having((w) => w.value, 'value', closeTo(50 / 300, 1e-9)),
      );

      // a 完成 → n 进位,b 仍活动 → 条在
      q.tasks.firstWhere((t) => t.filename == 'a').doneBytes = 200;
      gateA.complete();
      await tester.pumpAndSettle();
      expect(find.text('1/2'), findsOneWidget);
      expect(
        tester.widget<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator)),
        isA<LinearProgressIndicator>()
            .having((w) => w.value, 'value', closeTo(200 / 300, 1e-9)),
      );

      // 全部终态 → 无活动上传 → 条消失(等 worker 收尾落地)
      gateB.complete();
      await tester.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('下载任务不计入 n/m(上传口径)', (tester) async {
      final q = TransferQueue();
      q.enqueue(TransferRequest(
        kind: TransferKind.download,
        filename: 'd.livp',
        where: '项目/夹',
        totalBytes: 100,
        worker: (p, token) async {},
      ));
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: UploadMiniBar(queue: q))));
      await tester.pump();
      expect(find.text('0/1'), findsNothing, reason: '下载不算上传 m');
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });
  });
}
