/// iOS 后台持续上传 — 会话三元组持久化与恢复中断 abort 集成单测
/// (qdev 2026-11-27 §8-6/7,决策 D5/D6):
/// - TransferTask 三字段(uploadId/uploadBucket/uploadKey)快照 encode/decode
///   roundtrip:仅非 null 落键;旧快照(无三字段键)兼容解析;恢复中断口径
///   不变(非终态仍标 failed「进程中断」,三元组字段保留作 abort 数据源);
/// - TransferQueue.setInterruptedAbort 注入桩:恢复「非终态∧有 uploadId」任务
///   触发 abort(参数=三元组、恰一次);无 uploadId 不触发、终态不触发、
///   未注入回调不崩、abort 抛错不影响恢复流程(fire-and-forget);
/// - enqueue×onSessionCreated 写回:worker 运行期(create 成功桥接,同
///   upload_sheet 形态)触发包装层 → task 三字段写回 + 原回调链路保留 +
///   进持久化快照(回调前的入队快照无键)。
/// (bg 通道真实逻辑组已拆至 bg_channel_integration_test.dart,验收修正 P2-4。)
///
/// 确定性:store 读写/去抖定时器全注入(同 transfer_queue_persist_test 惯例),
/// abort 为注入桩,无真实网络/等待。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/transfers/transfer_queue.dart';
import 'package:ms_app/core/transfers/transfer_store.dart';
import 'package:ms_app/core/transfers/transfer_task.dart';

void main() {
  final fixedNow = DateTime(2026, 11, 27, 10, 0);

  TransferTask task(
    String id, {
    TransferKind kind = TransferKind.upload,
    TransferStatus status = TransferStatus.done,
    String? error,
    String? uploadId,
    String? uploadBucket,
    String? uploadKey,
  }) =>
      TransferTask(
        id: id,
        kind: kind,
        filename: 'a.jpg',
        where: '项目A/夹B',
        totalBytes: 100,
        status: status,
        error: error,
        uploadId: uploadId,
        uploadBucket: uploadBucket,
        uploadKey: uploadKey,
        startedAt: fixedNow,
      );

  /// 排空微任务:worker 收尾/abort 桩落地(取 10 拍)
  Future<void> drain([int ticks = 10]) async {
    for (var i = 0; i < ticks; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// 组装:注入 store(read 固定 [raw];write 捕获到 [writes])与去抖定时器
  /// (回调收集到 [flushes] 手动触发),同 transfer_queue_persist_test 口径。
  (TransferQueue, List<String>, List<void Function()>) build({String? raw}) {
    final writes = <String>[];
    final flushes = <void Function()>[];
    final q = TransferQueue(
      now: () => fixedNow,
      store: TransferStore(
          read: () async => raw, write: (content) async => writes.add(content)),
      schedule: (_, cb) => flushes.add(cb),
    );
    return (q, writes, flushes);
  }

  /// 触发全部在途去抖回调(真实 Timer 语义:触发即出队)。
  void flushAll(List<void Function()> flushes) {
    final pending = List.of(flushes);
    flushes.clear();
    for (final f in pending) {
      f();
    }
  }

  List<Map<String, dynamic>> rowsOf(String content) =>
      (jsonDecode(content) as List).cast<Map<String, dynamic>>();

  group('三字段快照 roundtrip(仅非 null 落键,F5)', () {
    test('encode:三字段非空落键;null 不落键(旧快照口径不回归)', () {
      final rows = rowsOf(encodeTasks([
        task('t1',
            uploadId: 'up-1', uploadBucket: 'ms-bucket', uploadKey: 'p/obj'),
        task('t2'),
      ]));
      expect(rows[0]['uploadId'], 'up-1');
      expect(rows[0]['uploadBucket'], 'ms-bucket');
      expect(rows[0]['uploadKey'], 'p/obj');
      expect(rows[1].containsKey('uploadId'), isFalse,
          reason: '仅非 null 时写入(无会话任务不落键)');
      expect(rows[1].containsKey('uploadBucket'), isFalse);
      expect(rows[1].containsKey('uploadKey'), isFalse);
    });

    test('decode roundtrip:终态任务三字段原样还原,与既有字段并存', () {
      final restored = decodeTasks(encodeTasks([
        task('t1',
            status: TransferStatus.done,
            uploadId: 'up-1',
            uploadBucket: 'bk-1',
            uploadKey: 'k-1'),
        task('t2',
            status: TransferStatus.failed,
            error: '空间不足',
            uploadId: 'up-2',
            uploadBucket: 'bk-2',
            uploadKey: 'k-2'),
      ]))!;
      expect(restored[0].uploadId, 'up-1');
      expect(restored[0].uploadBucket, 'bk-1');
      expect(restored[0].uploadKey, 'k-1');
      expect(restored[0].status, TransferStatus.done);
      expect(restored[1].uploadId, 'up-2');
      expect(restored[1].uploadBucket, 'bk-2');
      expect(restored[1].uploadKey, 'k-2');
      expect(restored[1].error, '空间不足', reason: '既有终态原因不受影响');
    });

    test('旧快照(无三字段键)兼容解析:字段为 null,不崩溃', () {
      final old = jsonEncode([
        {
          'id': 't1',
          'kind': 'upload',
          'filename': '旧.jpg',
          'where': '项目A',
          'totalBytes': 10,
          'doneBytes': 10,
          'status': 'done',
          'startedAt': fixedNow.toIso8601String(),
        },
      ]);
      final restored = decodeTasks(old)!;
      expect(restored, hasLength(1));
      expect(restored.single.uploadId, isNull);
      expect(restored.single.uploadBucket, isNull);
      expect(restored.single.uploadKey, isNull);
      expect(restored.single.status, TransferStatus.done,
          reason: '升级兼容:旧快照恢复口径不变');
    });

    test('恢复中断口径不变:含三字段的非终态仍标 failed「进程中断」,三元组保留',
        () {
      final restored = decodeTasks(encodeTasks([
        task('t1',
            status: TransferStatus.running,
            uploadId: 'up-1',
            uploadBucket: 'bk-1',
            uploadKey: 'k-1'),
        task('t2',
            status: TransferStatus.queued,
            uploadId: 'up-2',
            uploadBucket: 'bk-2',
            uploadKey: 'k-2'),
      ]))!;
      for (final t in restored) {
        expect(t.status, TransferStatus.failed, reason: '口径不变(上次运行被杀)');
        expect(t.error, kInterruptedError);
        expect(t.error, '进程中断');
      }
      expect(restored[0].uploadId, 'up-1', reason: '三元组保留:恢复 abort 数据源');
      expect(restored[0].uploadBucket, 'bk-1');
      expect(restored[0].uploadKey, 'k-1');
    });
  });

  group('恢复中断 abort(setInterruptedAbort 注入,D6)', () {
    test('注入桩:恢复「非终态∧有 uploadId」任务触发 abort,参数=三元组,恰一次',
        () async {
      final snapshot = encodeTasks([
        task('t1',
            status: TransferStatus.running,
            uploadId: 'up-1',
            uploadBucket: 'ms-bucket',
            uploadKey: 'k-1'),
        task('t2', status: TransferStatus.queued),
      ]);
      final aborts = <List<String>>[];
      final (q, _, _) = build(raw: snapshot);
      q.setInterruptedAbort((u, b, k) async => aborts.add([u, b, k]));
      await q.attachStore(TransferStore(read: () async => snapshot));
      await drain();

      expect(aborts, [
        ['up-1', 'ms-bucket', 'k-1']
      ], reason: '仅非终态∧有 uploadId 触发,参数=三元组(无会话的中断任务不触发)');
      expect(q.byId('t1')!.status, TransferStatus.failed);
      expect(q.byId('t1')!.error, kInterruptedError, reason: '中断口径不变');
      expect(q.byId('t2')!.status, TransferStatus.failed);
    });

    test('无 uploadId 的中断任务不触发;终态任务(含三字段)不触发', () async {
      final snapshot = encodeTasks([
        task('t1', status: TransferStatus.running),
        task('t2',
            status: TransferStatus.failed,
            error: '超时',
            uploadId: 'up-2',
            uploadBucket: 'bk-2',
            uploadKey: 'k-2'),
        task('t3',
            status: TransferStatus.canceled,
            uploadId: 'up-3',
            uploadBucket: 'bk-3',
            uploadKey: 'k-3'),
      ]);
      final aborts = <List<String>>[];
      final (q, _, _) = build(raw: snapshot);
      q.setInterruptedAbort((u, b, k) async => aborts.add([u, b, k]));
      await q.attachStore(TransferStore(read: () async => snapshot));
      await drain();

      expect(aborts, isEmpty,
          reason: 'abort 只对「非终态∧有 uploadId」:终态任务对象已成形(或已失败落定),'
              '无会话任务无服务端会话可清');
    });

    test('未注入回调:恢复含 uploadId 的中断任务不崩,口径不变', () async {
      final snapshot = encodeTasks([
        task('t1',
            status: TransferStatus.running,
            uploadId: 'up-1',
            uploadBucket: 'bk-1',
            uploadKey: 'k-1'),
      ]);
      final (q, _, _) = build(raw: snapshot);
      await q.attachStore(TransferStore(read: () async => snapshot));
      await drain();
      expect(q.byId('t1')!.status, TransferStatus.failed);
      expect(q.byId('t1')!.error, kInterruptedError);
    });

    test('abort 抛异常:fire-and-forget 吞掉(只记日志),恢复流程不受影响', () async {
      final snapshot = encodeTasks([
        task('t1',
            status: TransferStatus.running,
            uploadId: 'up-1',
            uploadBucket: 'bk-1',
            uploadKey: 'k-1'),
      ]);
      var called = false;
      final (q, _, _) = build(raw: snapshot);
      q.setInterruptedAbort((u, b, k) async {
        called = true;
        throw StateError('abort 网络失败');
      });
      await q.attachStore(TransferStore(read: () async => snapshot));
      await drain();
      expect(called, isTrue, reason: 'abort 桩被调用');
      expect(q.byId('t1')!.status, TransferStatus.failed,
          reason: 'abort 失败不改变恢复中断口径');
      expect(q.byId('t1')!.error, kInterruptedError);
    });
  });

  group('enqueue×onSessionCreated 写回(包 D 接线,worker 桥接形态)', () {
    test('worker 内触发回调:task 三字段写回 + 原回调仍被调 + 进持久化快照(回调前快照无键)',
        () async {
      final (q, writes, flushes) = build();
      final seen = <List<String>>[];
      // 先占满两个并发槽,使目标任务保持 queued(worker 不随 enqueue 同步启动):
      // 入队快照(无三字段)与桥接后的快照才能各自落盘,验证「回调前快照无键」。
      // (有空槽时 worker 在 enqueue 内同步起跑,桥接与入队两个变化点同落一个
      // 去抖窗口,R4c 机制下仅最新编码落盘——见 transfer_queue._schedulePersist。)
      final slotGates = List.generate(2, (_) => Completer<void>());
      TransferRequest placeholder(String name, Completer<void> gate) =>
          TransferRequest(
            kind: TransferKind.upload,
            filename: name,
            where: '项目A/夹B',
            totalBytes: 100,
            worker: (p, token) async => gate.future,
          );
      q.enqueue(placeholder('占位0', slotGates[0]));
      q.enqueue(placeholder('占位1', slotGates[1]));
      // 同 upload_sheet 形态:worker 闭包引用 req 自身字段(经 holder 破自引用,
      // req 在 enqueue 前完成赋值);队列包装后 worker 读到的必是包装层。
      TransferRequest? reqRef;
      final req = TransferRequest(
        kind: TransferKind.upload,
        filename: 'v.mp4',
        where: '项目A/夹B',
        totalBytes: 100,
        onSessionCreated: (s) => seen.add([s.uploadId, s.bucket, s.key]),
        worker: (p, token) async {
          reqRef!.onSessionCreated?.call(const TransferUploadSession(
              uploadId: 'up-9', bucket: 'ms-bucket', key: 'obj-9'));
        },
      );
      reqRef = req;
      final id = q.enqueue(req);
      await drain();
      expect(q.byId(id)!.status, TransferStatus.queued,
          reason: '并发槽已占满,目标任务排队(回调尚未发生)');
      flushAll(flushes);
      await drain();
      expect(writes, hasLength(1));
      expect(
        rowsOf(writes.single).firstWhere((r) => r['filename'] == 'v.mp4')
            .containsKey('uploadId'),
        isFalse,
        reason: '回调前的快照无三字段(入队变化点编码,queued 态)',
      );

      // 让出槽位 → 目标任务起跑,worker 桥接三元组(队列包装层写回+调度持久化)
      slotGates[0].complete();
      await drain();
      final t = q.byId(id)!;
      expect(t.uploadId, 'up-9', reason: '包装层写回 task 三字段');
      expect(t.uploadBucket, 'ms-bucket');
      expect(t.uploadKey, 'obj-9');
      expect(seen, [
        ['up-9', 'ms-bucket', 'obj-9']
      ], reason: '原回调链路保留(入队方感知会话建立)');

      flushAll(flushes);
      await drain();
      final targetRow =
          rowsOf(writes.last).firstWhere((r) => r['filename'] == 'v.mp4');
      expect(targetRow['uploadId'], 'up-9',
          reason: '回调触发后三字段进持久化快照');
      expect(targetRow['uploadBucket'], 'ms-bucket');
      expect(targetRow['uploadKey'], 'obj-9');
      slotGates[1].complete(); // 收尾:释放占位 worker,不留在途任务
      await drain();
    });

    test('未设置 onSessionCreated:入队/收尾不崩,快照无三字段键(向后兼容)', () async {
      final (q, writes, flushes) = build();
      final id = q.enqueue(TransferRequest(
        kind: TransferKind.upload,
        filename: 'b.jpg',
        where: '项目A/夹B',
        totalBytes: 10,
        worker: (p, token) async {},
      ));
      await drain();
      expect(q.byId(id)!.status, TransferStatus.done);
      flushAll(flushes);
      await drain();
      final row = rowsOf(writes.last).single;
      expect(row.containsKey('uploadId'), isFalse);
      expect(row.containsKey('uploadBucket'), isFalse);
      expect(row.containsKey('uploadKey'), isFalse);
    });

    test('worker 未触发回调:快照不落三字段键(有回调装配但会话未建立)', () async {
      final (q, writes, flushes) = build();
      final req = TransferRequest(
        kind: TransferKind.upload,
        filename: 'c.jpg',
        where: '项目A/夹B',
        totalBytes: 10,
        onSessionCreated: (_) {},
        worker: (p, token) async {}, // create 尚未成功,不桥接
      );
      q.enqueue(req);
      await drain();
      flushAll(flushes);
      await drain();
      expect(rowsOf(writes.last).single.containsKey('uploadId'), isFalse,
          reason: '仅回调触发才写回+落盘,不预写空值');
    });
  });
}
