/// TransferStore 单测(mobile-ux-polish-2 批 R4c):
/// - encodeTasks 纯函数:快照字段齐(id/kind/filename/where/status/error/进度/
///   startedAt),error 空缺省不落键;超 kMaxSnapshotTasks 截尾(丢最旧);
/// - decodeTasks 纯函数:终态原样还原;非终态(queued/running)标 failed
///   「进程中断」(kInterruptedError);字段残缺容错(where/totalBytes/startedAt
///   缺失有兜底);坏 JSON/条目残缺 → null(调用方按空快照重来);
/// - openDefault:应用支持目录 transfers.json 真实读写(path_provider 通道
///   mock);通道失败 → null(队列整体降级仅内存,不崩溃)。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/transfers/transfer_store.dart';
import 'package:ms_app/core/transfers/transfer_task.dart';

TransferTask task(
  String id, {
  TransferKind kind = TransferKind.upload,
  String filename = 'a.jpg',
  TransferStatus status = TransferStatus.done,
  String? error,
  int totalBytes = 100,
  int doneBytes = 100,
}) =>
    TransferTask(
      id: id,
      kind: kind,
      filename: filename,
      where: '项目A/夹B',
      totalBytes: totalBytes,
      doneBytes: doneBytes,
      status: status,
      error: error,
      startedAt: DateTime(2026, 10, 21, 9, 30),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); // openDefault 通道 mock 依赖

  group('encodeTasks(R4c 快照字段口径)', () {
    test('字段齐:id/kind/filename/where/status/error/进度/startedAt', () {
      final rows =
          (jsonDecode(encodeTasks([task('t1', error: '空间不足')])) as List)
              .cast<Map<String, dynamic>>();
      expect(rows, hasLength(1));
      expect(rows.single['id'], 't1');
      expect(rows.single['kind'], 'upload');
      expect(rows.single['filename'], 'a.jpg');
      expect(rows.single['where'], '项目A/夹B');
      expect(rows.single['status'], 'done');
      expect(rows.single['error'], '空间不足');
      expect(rows.single['totalBytes'], 100);
      expect(rows.single['doneBytes'], 100);
      expect(rows.single['startedAt'], '2026-10-21T09:30:00.000');
      expect(DateTime.parse(rows.single['startedAt'] as String).year, 2026,
          reason: 'startedAt 为 ISO8601 可解析');
    });

    test('error 为空不落键(恢复后展示无原因行)', () {
      final rows =
          (jsonDecode(encodeTasks([task('t1')])) as List)
              .cast<Map<String, dynamic>>();
      expect(rows.single.containsKey('error'), isFalse);
    });

    test('超 kMaxSnapshotTasks 截尾:列表序=展示序,丢最旧留最新 200 条', () {
      final tasks =
          List.generate(kMaxSnapshotTasks + 30, (i) => task('t${i + 1}'));
      final rows = (jsonDecode(encodeTasks(tasks)) as List)
          .cast<Map<String, dynamic>>();
      expect(rows, hasLength(kMaxSnapshotTasks));
      expect(rows.first['id'], 't1', reason: 'index 0 最新,保留');
      expect(rows.last['id'], 't$kMaxSnapshotTasks', reason: '尾部最旧被截');
    });
  });

  group('decodeTasks(R4c 启动恢复口径)', () {
    test('roundtrip:终态原样还原(done/failed/canceled 状态与原因不变)', () {
      final raw = encodeTasks([
        task('t1', status: TransferStatus.done),
        task('t2', status: TransferStatus.failed, error: '该文件夹已存在同名文件'),
        task('t3', status: TransferStatus.canceled),
      ]);
      final restored = decodeTasks(raw)!;
      expect(restored, hasLength(3));
      expect(restored[0].status, TransferStatus.done);
      expect(restored[0].error, isNull);
      expect(restored[1].status, TransferStatus.failed);
      expect(restored[1].error, '该文件夹已存在同名文件');
      expect(restored[2].status, TransferStatus.canceled);
      expect(restored[1].startedAt, DateTime(2026, 10, 21, 9, 30));
    });

    test('非终态(queued/running)标 failed「进程中断」,允许重试展示', () {
      final restored = decodeTasks(encodeTasks([
        task('t1', status: TransferStatus.running, doneBytes: 40),
        task('t2', status: TransferStatus.queued),
      ]))!;
      for (final t in restored) {
        expect(t.status, TransferStatus.failed,
            reason: '上次运行被杀,任务实际已中断');
        expect(t.error, kInterruptedError);
        expect(t.error, '进程中断', reason: '需求文档口径文案');
      }
    });

    test('字段残缺容错:where/totalBytes/doneBytes 缺失有兜底,startedAt 乱值落 epoch',
        () {
      final restored = decodeTasks(jsonEncode([
        {
          'id': 't9',
          'kind': 'download',
          'filename': 'v.mp4',
          'status': 'done',
          'startedAt': 'not-a-date',
        },
      ]))!;
      expect(restored.single.where, '');
      expect(restored.single.totalBytes, 0);
      expect(restored.single.doneBytes, 0);
      expect(restored.single.kind, TransferKind.download);
      expect(restored.single.startedAt, DateTime.fromMillisecondsSinceEpoch(0));
    });

    test('坏 JSON → null(调用方按空快照重来,不崩溃)', () {
      expect(decodeTasks('{not-json'), isNull);
      expect(decodeTasks(''), isNull);
    });

    test('条目残缺(缺 status/id 等必填)→ 整体 null,不做半截恢复', () {
      expect(
        decodeTasks(jsonEncode([
          {'id': 't1', 'kind': 'upload', 'filename': 'a.jpg'},
        ])),
        isNull,
        reason: '缺 status:解析抛 → 整体 null(空快照口径,防半截状态)');
    });
  });

  group('openDefault(真实存储,通道 mock)', () {
    test('应用支持目录 transfers.json 写读 roundtrip;无文件 read=null', () async {
      final tmp = await Directory.systemTemp.createTemp('ms_transfers');
      addTearDown(() => tmp.delete(recursive: true));
      final binding = TestWidgetsFlutterBinding.instance;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? tmp.path
              : null);
      addTearDown(() => binding.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'), null));

      final store = await TransferStore.openDefault();
      expect(store, isNotNull);
      expect(await store!.read(), isNull, reason: '首启无快照文件=null(非错误)');

      await store.write(encodeTasks([task('t1')]));
      expect(File('${tmp.path}/transfers.json').existsSync(), isTrue);
      expect(await store.read(), encodeTasks([task('t1')]),
          reason: '写读一致(roundtrip)');
    });

    test('通道失败(无插件环境)→ null,队列整体降级仅内存不崩溃', () async {
      final binding = TestWidgetsFlutterBinding.instance;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => throw PlatformException(
              code: 'missing-plugin', message: 'no channel in test'));
      addTearDown(() => binding.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'), null));

      expect(await TransferStore.openDefault(), isNull);
    });
  });
}
