/// TransferQueue 持久化集成单测(mobile-ux-polish-2 批 R4c):
/// - 快照写入时机:入队/状态变化去抖合并(schedule 注入手动触发,高频进度
///   回调不写盘);无 store=仅内存(一期单测口径不回退);
/// - 启动恢复:终态原样还原、恢复记录置列表底、id 序号续接防撞;
/// - 非终态恢复标 failed「进程中断」并立即重写一致快照;
/// - 坏 JSON 清空重来(立即重写空快照,不崩溃);文件缺失不触发重写;
/// - 恢复记录重试降级:无可执行 worker,retry 返回 null(队列面;「提示重新
///   发起」在传输页承载);本会话任务的 retry 不回退;
/// - 写盘失败容错:单次写失败不炸队列,后续状态变化重试。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/transfers/transfer_queue.dart';
import 'package:ms_app/core/transfers/transfer_store.dart';
import 'package:ms_app/core/transfers/transfer_task.dart';

void main() {
  final fixedNow = DateTime(2026, 10, 21, 10, 0);

  TransferRequest req(String name,
          {TransferKind kind = TransferKind.upload,
          required TransferWorker worker}) =>
      TransferRequest(
          kind: kind,
          filename: name,
          where: '项目A/夹B',
          totalBytes: 100,
          worker: worker);

  /// 排空微任务:写盘 future/worker 收尾落地
  Future<void> drain([int ticks = 6]) async {
    for (var i = 0; i < ticks; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// 组装:注入 store(read 固定 [raw];write 记录到 [writes],可注入失败)
  /// 与去抖定时器(回调收集到 [flushes] 手动触发)。
  (TransferQueue, List<String>, List<void Function()>) build({
    String? raw,
    Object? writeError,
  }) {
    final writes = <String>[];
    final flushes = <void Function()>[];
    final q = TransferQueue(
      now: () => fixedNow,
      store: TransferStore(
        read: () async => raw,
        write: (content) async {
          if (writeError != null) throw writeError;
          writes.add(content);
        },
      ),
      schedule: (_, cb) => flushes.add(cb),
    );
    return (q, writes, flushes);
  }

  /// 快照 JSON → 行列表(status 断言用)
  List<Map<String, dynamic>> rowsOf(String content) =>
      (jsonDecode(content) as List).cast<Map<String, dynamic>>();

  /// 触发全部在途去抖回调(真实 Timer 语义:触发即出队,不会重复触发)。
  void flushAll(List<void Function()> flushes) {
    final pending = List.of(flushes);
    flushes.clear();
    for (final f in pending) {
      f();
    }
  }

  group('快照写入时机(R4c:入队/状态变化去抖,进度回调不写盘)', () {
    test('入队挂去抖:未触发不写盘;触发一次合并写入(排队任务落 queued 态)',
        () async {
      final (q, writes, flushes) = build();
      // 占满两个并发槽 → 第三个任务保持 queued(状态确定性)
      final gates = List.generate(2, (_) => Completer<void>());
      q.enqueue(req('g0', worker: (p, t) async => gates[0].future));
      q.enqueue(req('g1', worker: (p, t) async => gates[1].future));
      q.enqueue(req('a', worker: (p, t) async {}));
      expect(writes, isEmpty, reason: '去抖窗口内不落盘');

      flushAll(flushes);
      await drain();
      expect(writes, hasLength(1), reason: '窗口内多次状态变化合并为一次写');
      final rows = rowsOf(writes.single);
      expect(rows, hasLength(3));
      expect(
        rows.firstWhere((r) => r['filename'] == 'a')['status'],
        'queued',
        reason: '排队任务快照=queued(写时机=入队当时态)',
      );
      gates[0].complete();
      gates[1].complete();
      await drain();
    });

    test('终态收尾更新快照:done 落终值(收尾即终态,不留 running 陈迹)',
        () async {
      final (q, writes, flushes) = build();
      final id = q.enqueue(req('a', worker: (p, t) async {}));
      await drain();
      flushAll(flushes);
      await drain();
      expect(q.byId(id)!.status, TransferStatus.done);
      expect(writes, isNotEmpty);
      expect(rowsOf(writes.last).single['status'], 'done',
          reason: 'R4c:状态变化点(收尾)落盘,快照终态=内存终态');
    });
  });

  group('启动恢复(R4c:attachStore)', () {
    test('终态原样还原:状态/原因/字段不变,恢复记录置列表底(最新在上)',
        () async {
      final snapshot = encodeTasks([
        TransferTask(
            id: 't1',
            kind: TransferKind.upload,
            filename: '旧1.jpg',
            where: '项目A',
            totalBytes: 10,
            status: TransferStatus.done,
            startedAt: fixedNow),
        TransferTask(
            id: 't2',
            kind: TransferKind.download,
            filename: '旧2.mp4',
            where: '项目A',
            totalBytes: 20,
            status: TransferStatus.failed,
            error: '空间不足',
            startedAt: fixedNow),
        TransferTask(
            id: 't3',
            kind: TransferKind.upload,
            filename: '旧3.jpg',
            where: '项目A',
            totalBytes: 30,
            status: TransferStatus.canceled,
            startedAt: fixedNow),
      ]);
      final (q, writes, _) = build(raw: snapshot);
      await q.attachStore(TransferStore(read: () async => snapshot));
      await drain();

      expect(q.tasks.map((t) => t.filename),
          ['旧1.jpg', '旧2.mp4', '旧3.jpg']);
      expect(q.byId('t1')!.status, TransferStatus.done);
      expect(q.byId('t2')!.error, '空间不足', reason: '终态原因原样还原');
      expect(q.byId('t3')!.status, TransferStatus.canceled);

      // 新任务插顶,恢复记录沉底(展示序=最新在上)
      q.enqueue(req('新.jpg', worker: (p, t) async {}));
      expect(q.tasks.first.filename, '新.jpg');
      expect(q.tasks.last.filename, '旧3.jpg');
      expect(writes, [snapshot],
          reason: '快照原文存在即重写(保证下次启动所见=本进程恢复口径);'
              '纯终态 roundtrip 恒等 → 重写内容与原文逐字节一致');
    });

    test('id 序号续接快照最大值:恢复 t5 后新任务 t6,不撞 id', () async {
      final snapshot = encodeTasks([
        TransferTask(
            id: 't5',
            kind: TransferKind.upload,
            filename: 'a.jpg',
            where: '项目A',
            totalBytes: 1,
            status: TransferStatus.done,
            startedAt: fixedNow),
      ]);
      final (q, _, _) = build(raw: snapshot);
      await q.attachStore(TransferStore(read: () async => snapshot));

      final id = q.enqueue(req('b', worker: (p, t) async {}));
      expect(id, 't6', reason: '序号续接,防新任务与历史记录撞 id');
      expect(q.byId('t5'), isNotNull, reason: '历史记录不被覆盖');
    });

    test('非终态(queued/running)恢复标 failed「进程中断」,立即重写一致快照',
        () async {
      final snapshot = encodeTasks([
        TransferTask(
            id: 't1',
            kind: TransferKind.upload,
            filename: 'r.jpg',
            where: '项目A',
            totalBytes: 10,
            status: TransferStatus.running,
            startedAt: fixedNow),
        TransferTask(
            id: 't2',
            kind: TransferKind.upload,
            filename: 'q.jpg',
            where: '项目A',
            totalBytes: 10,
            status: TransferStatus.queued,
            startedAt: fixedNow),
      ]);
      final writes = <String>[];
      final q = TransferQueue(
        now: () => fixedNow,
        store: TransferStore(
            read: () async => snapshot,
            write: (content) async => writes.add(content)),
      );
      await q.attachStore(TransferStore(read: () async => snapshot));
      await drain();

      expect(q.byId('t1')!.status, TransferStatus.failed);
      expect(q.byId('t1')!.error, kInterruptedError);
      expect(q.byId('t2')!.status, TransferStatus.failed);
      expect(q.byId('t2')!.error, kInterruptedError);

      expect(writes, hasLength(1), reason: '恢复内容有变 → 立即重写(绕过去抖)');
      final rows = rowsOf(writes.single);
      expect(
        rows.every((r) => r['status'] == 'failed' && r['error'] == '进程中断'),
        isTrue,
        reason: '重写后的快照与内存一致(下次启动不再二次改写)',
      );
    });

    test('坏 JSON:按空快照恢复不崩溃,立即重写空快照(清空重来)', () async {
      final writes = <String>[];
      final q = TransferQueue(
        now: () => fixedNow,
        store: TransferStore(
            read: () async => '{bad-json',
            write: (content) async => writes.add(content)),
      );
      await q.attachStore(TransferStore(read: () async => '{bad-json'));
      await drain();

      expect(q.tasks, isEmpty);
      expect(writes, ['[]'], reason: '坏快照被空快照覆盖(下次启动干净)');
    });

    test('文件缺失(首启 read=null):不重写、不恢复、任务照常入队', () async {
      final (q, writes, flushes) = build(raw: null);
      await q.attachStore(TransferStore(read: () async => null));
      await drain();
      expect(q.tasks, isEmpty);
      expect(writes, isEmpty, reason: '首启无快照,无需重写');

      final id = q.enqueue(req('a', worker: (p, t) async {}));
      flushAll(flushes);
      await drain();
      expect(q.byId(id)!.status, TransferStatus.done);
      expect(writes, hasLength(1));
    });
  });

  group('恢复后重试链路(R4c 决策 #8:降级提示重新发起,不做续传)', () {
    test('恢复记录无可执行 worker:retry 返回 null,列表不变;新任务 retry 不回退',
        () async {
      final snapshot = encodeTasks([
        TransferTask(
            id: 't2',
            kind: TransferKind.upload,
            filename: '旧-失败.jpg',
            where: '项目A',
            totalBytes: 10,
            status: TransferStatus.failed,
            error: '进程中断',
            startedAt: fixedNow),
      ]);
      final (q, _, _) = build(raw: snapshot);
      await q.attachStore(TransferStore(read: () async => snapshot));

      expect(q.retry('t2'), isNull,
          reason: '恢复记录无 worker,不可原地重试(降级提示重新发起)');
      expect(q.byId('t2'), isNotNull, reason: '重试失败不移除历史记录');
      expect(q.tasks, hasLength(1), reason: '没有幽灵新任务入队');

      // 本会话内的失败任务仍可重试(一期行为不回退);worker 仅首跑失败
      var failFirstRun = true;
      final id = q.enqueue(req('新.jpg', worker: (p, t) async {
        if (failFirstRun) {
          failFirstRun = false;
          throw StateError('x');
        }
      }));
      await drain();
      expect(q.byId(id)!.status, TransferStatus.failed);
      final newId = q.retry(id);
      expect(newId, isNotNull);
      await drain();
      expect(q.byId(newId!)!.status, TransferStatus.done);
    });
  });

  group('写盘失败容错(R4c:不阻断队列状态机)', () {
    test('单次写失败不炸:去抖回调不外抛,后续任务照常跑、后续快照照常写',
        () async {
      var failFirst = true;
      final writes = <String>[];
      final flushes = <void Function()>[];
      final q = TransferQueue(
        now: () => fixedNow,
        store: TransferStore(
          read: () async => null,
          write: (content) async {
            if (failFirst) {
              failFirst = false;
              throw StateError('disk full');
            }
            writes.add(content);
          },
        ),
        schedule: (_, cb) => flushes.add(cb),
      );

      final a = q.enqueue(req('a', worker: (p, t) async {}));
      await drain();
      for (final f in List.of(flushes)) {
        f(); // 第一次写盘:抛 disk full(被 catchError 吞)
      }
      await drain();
      expect(writes, isEmpty);

      final b = q.enqueue(req('b', worker: (p, t) async {}));
      flushAll(flushes);
      await drain();
      expect(q.byId(a)!.status, TransferStatus.done, reason: '队列状态机不破');
      expect(q.byId(b)!.status, TransferStatus.done);
      expect(writes, hasLength(1), reason: '下次状态变化重试写盘成功');
      expect(rowsOf(writes.single).map((r) => r['filename']),
          containsAll(['a', 'b']));
    });
  });
}
