/// ThumbPipeline 单测(storm-fix 测试功能点 T1-T5 + T14 管线/磁盘/缓存代际):
/// T1 并发上限 6;T2 FIFO;T3 句柄 cancel 四分支(共享/排队撤销/运行终止+
/// watchdog 取消/名额幂等);T4 同 assetId 去重;T5 名额回收与防线(异常/永不
/// 完成/迟到失败 swallow);T14 登出清理(registerSessionClearHooks 幂等、
/// clear 语义、磁盘写闸代际、缓存 putBatch 代际)。
///
/// Timer 纪律:需要假时的用例用 testWidgets + pump(Duration(seconds: 20)),
/// 不引 fake_async;文件内直接 submit 的用例末尾显式 cancel 全部句柄或
/// thumbPipeline.reset()(无 widget 卸载链路,watchdog 不会被自动取消)。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/core/thumb_disk_store.dart';
import 'package:ms_app/core/thumb_pipeline.dart';
import 'package:ms_app/core/thumbnail_cache.dart';
import 'package:ms_app/main.dart' show registerSessionClearHooks;

Uint8List _bytes(List<int> l) => Uint8List.fromList(l);

/// 长任务编排:job 记录开始、挂 [Completer] 等放行。
class _Gate {
  final started = <String>[];
  final aborts = <String>[];
  final shortCircuits = <String>[];
  int concurrent = 0;
  int maxConcurrent = 0;
  final _waiters = <String, Completer<Uint8List?>>{};

  Completer<Uint8List?> _completer(String id) =>
      _waiters.putIfAbsent(id, Completer<Uint8List?>.new);

  Future<Uint8List?> job(String id, [ThumbTaskContext? ctxHolder]) async {
    started.add(id);
    concurrent++;
    if (concurrent > maxConcurrent) maxConcurrent = concurrent;
    try {
      if (ctxHolder != null) {
        ctxHolder.registerAbort(() => aborts.add(id));
      }
      final b = await _completer(id).future;
      return b;
    } finally {
      concurrent--;
    }
  }

  /// 带短路探测的 job:await 后查 isCancelled 并记录(不再发起后续动作)。
  Future<Uint8List?> jobWithShortCircuit(
    String id,
    ThumbTaskContext ctx,
  ) async {
    ctx.registerAbort(() => aborts.add(id));
    started.add(id);
    concurrent++;
    try {
      final b = await _completer(id).future;
      if (ctx.isCancelled) shortCircuits.add(id);
      return b;
    } finally {
      concurrent--;
    }
  }

  void release(String id, [Uint8List? bytes]) =>
      _completer(id).complete(bytes ?? _bytes([1]));

  void fail(String id) => _completer(id).completeError(Exception('boom-$id'));

  void releaseAll() {
    for (final id in started) {
      final c = _waiters[id];
      if (c != null && !c.isCompleted) c.complete(_bytes([1]));
    }
  }
}

/// 微任务/事件冲刷(plain test 用;job 完成经 microtask 链释放名额)。
Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  group('T1 并发上限', () {
    test('同时 submit 10 个长任务,任一时刻运行中 ≤6;放行后补位', () async {
      final g = _Gate();
      final handles = [
        for (var i = 0; i < 10; i++)
          thumbPipeline.submit('t1-$i', (ctx) => g.job('t1-$i')),
      ];
      expect(thumbPipeline.debugActiveCount, 6, reason: '并发上限 6');
      expect(thumbPipeline.debugQueuedCount, 4);
      expect(g.started.length, 6);

      g.release('t1-0');
      g.release('t1-1');
      await _flush();
      expect(g.started.length, 8, reason: '名额释放后 FIFO 补位');
      expect(g.maxConcurrent, 6, reason: '任一时刻运行中 ≤6');
      expect(thumbPipeline.debugActiveCount, 6);

      g.releaseAll();
      await _flush();
      g.releaseAll(); // 补位的 t1-8/t1-9 此刻已开始,再次放行
      await _flush();
      expect(thumbPipeline.debugActiveCount, 0);
      expect(g.maxConcurrent, lessThanOrEqualTo(6));
      for (final h in handles) {
        h.cancel(); // 终态后再 cancel 幂等无操作
      }
      thumbPipeline.reset();
    });
  });

  group('T2 FIFO', () {
    test('按提交序开始执行', () async {
      final g = _Gate();
      final handles = <ThumbHandle>[];
      for (var i = 0; i < 8; i++) {
        final id = 't2-${'abcdefgh'[i]}';
        handles.add(thumbPipeline.submit(id, (ctx) => g.job(id)));
      }
      expect(g.started, ['t2-a', 't2-b', 't2-c', 't2-d', 't2-e', 't2-f']);
      g.release('t2-b');
      await _flush();
      expect(g.started.last, 't2-g', reason: '队首空位由最早提交者补上');
      g.release('t2-a');
      await _flush();
      expect(g.started.last, 't2-h');
      g.releaseAll();
      await _flush();
      for (final h in handles) {
        h.cancel();
      }
      thumbPipeline.reset();
    });
  });

  group('T4 同 assetId 去重', () {
    test('排队态与运行态重复 submit 均共享同一次执行', () async {
      // 运行态:首个任务已执行且悬挂,后 join 者共享同一次执行
      var runs = 0;
      final c = Completer<Uint8List?>();
      Future<Uint8List?> job(ThumbTaskContext _) async {
        runs++;
        return c.future;
      }

      final h1 = thumbPipeline.submit('t4-x', job);
      await _flush();
      expect(runs, 1, reason: '前置:首个任务已开始');
      final h2 = thumbPipeline.submit('t4-x', job); // join 运行态任务
      c.complete(_bytes([7]));
      final r1 = await h1.future;
      final r2 = await h2.future;
      expect(runs, 1, reason: '同 assetId 只执行一次');
      expect(r1, r2);

      // 排队态:占满闸后同 assetId 两订阅者共享排队任务
      final g2 = _Gate();
      final fillers = <ThumbHandle>[];
      for (var i = 0; i < 6; i++) {
        fillers.add(thumbPipeline.submit('t4-f$i', (ctx) => g2.job('t4-f$i')));
      }
      final c2 = Completer<Uint8List?>();
      var runs2 = 0;
      Future<Uint8List?> job2(ThumbTaskContext _) async {
        runs2++;
        return c2.future;
      }

      final hq1 = thumbPipeline.submit('t4-q', job2);
      final hq2 = thumbPipeline.submit('t4-q', job2);
      expect(thumbPipeline.debugQueuedCount, 1, reason: '同 assetId 排队去重');
      for (var i = 0; i < fillers.length; i++) {
        g2.release('t4-f$i');
      }
      await _flush();
      c2.complete(_bytes([9]));
      expect(await hq1.future, _bytes([9]));
      expect(await hq2.future, _bytes([9]));
      expect(runs2, 1);
      thumbPipeline.reset();
    });
  });

  group('T3 句柄 cancel', () {
    test('① 两订阅者共享排队任务:A cancel → A null、B 仍拿到字节', () async {
      final g = _Gate();
      final fillers = <ThumbHandle>[];
      for (var i = 0; i < 6; i++) {
        fillers.add(thumbPipeline.submit('t3-f$i', (ctx) => g.job('t3-f$i')));
      }
      final a = thumbPipeline.submit('t3-shared', (ctx) => g.job('t3-shared'));
      final b = thumbPipeline.submit('t3-shared', (ctx) => g.job('t3-shared'));

      Uint8List? ra = _bytes([0]);
      Uint8List? rb;
      a.future.then((v) => ra = v, onError: (Object _) {});
      b.future.then((v) => rb = v, onError: (Object _) {});
      a.cancel();
      await _flush();
      expect(ra, isNull, reason: '取消者句柄以 null 完成');

      g.releaseAll(); // 只放行已开始的 fillers,腾出闸位
      await _flush();
      g.release('t3-shared', _bytes([1])); // t3-shared 此时才开始执行
      await _flush();
      expect(rb, _bytes([1]), reason: '仍有其他订阅者 → 任务照常继续');
      thumbPipeline.reset();
    });

    test('② 仅剩订阅者且排队中 cancel → 撤销,job 不执行、名额未占用', () async {
      final g = _Gate();
      final fillers = <ThumbHandle>[];
      for (var i = 0; i < 6; i++) {
        fillers.add(thumbPipeline.submit('t3b-f$i', (ctx) => g.job('t3b-f$i')));
      }
      final h = thumbPipeline.submit(
        't3b-victim',
        (ctx) => g.job('t3b-victim'),
      );
      Uint8List? got = _bytes([0]);
      h.future.then((v) => got = v, onError: (Object _) {});
      expect(thumbPipeline.debugQueuedCount, 1);
      h.cancel();
      await _flush();
      expect(got, isNull);
      g.releaseAll();
      await _flush();
      expect(g.started.contains('t3b-victim'), isFalse, reason: '排队撤销,job 不执行');
      expect(thumbPipeline.debugActiveCount, 0, reason: '名额全部回收');
      thumbPipeline.reset();
    });

    testWidgets('③ 运行中唯一订阅者 cancel → abort 触发、isCancelled 置位、'
        '名额回收、watchdog 已取消(无 pending timer)、job 下一 await 短路', (tester) async {
      final g = _Gate();
      final h = thumbPipeline.submit(
        't3c-run',
        (ctx) => g.jobWithShortCircuit('t3c-run', ctx),
      );
      await tester.pump(); // job 已开始并挂在 completer 上
      expect(g.started, ['t3c-run']);

      Uint8List? got = _bytes([0]);
      h.future.then((v) => got = v, onError: (Object _) {});
      h.cancel();
      await tester.pump();
      expect(got, isNull);
      expect(g.aborts, ['t3c-run'], reason: '运行态终止触发已注册 abort');
      expect(thumbPipeline.debugActiveCount, 0, reason: '名额回收');

      g.release('t3c-run'); // 僵尸 job 放行:下一 await 边界短路
      await tester.pump();
      expect(g.shortCircuits, [
        't3c-run',
      ], reason: 'isCancelled 置位,job 不再发起后续请求');
      // 用例结束无 pending timer = watchdog 已同步取消(testWidgets 不变量)
    });

    testWidgets('④ 名额幂等:超时清算后连续 submit 10 个,运行中 ≤6、计数不为负', (tester) async {
      final g = _Gate();
      final handles = <ThumbHandle>[];
      for (var i = 0; i < 6; i++) {
        final h = thumbPipeline.submit('t3d-x$i', (ctx) => g.job('t3d-x$i'));
        h.future.ignore(); // 超时异常监听兜底(断言仍可后挂,监听彼此独立)
        handles.add(h);
      }
      expect(thumbPipeline.debugActiveCount, 6);
      await tester.pump(const Duration(seconds: 20)); // 全部硬超时终态
      expect(thumbPipeline.debugActiveCount, 0, reason: '超时释放全部名额');
      await expectLater(handles.first.future, throwsA(isA<TimeoutException>()));

      final more = <ThumbHandle>[];
      for (var i = 0; i < 10; i++) {
        more.add(thumbPipeline.submit('t3d-y$i', (ctx) async => _bytes([2])));
      }
      expect(thumbPipeline.debugActiveCount, lessThanOrEqualTo(6));
      expect(thumbPipeline.debugActiveCount, isNonNegative);
      await tester.pump();
      await expectLater(more.first.future, completion(_bytes([2])));
      expect(
        thumbPipeline.debugActiveCount,
        0,
        reason: '双释放回归:全部完成后计数精确归零(无多减/负数)',
      );
      thumbPipeline.reset();
    });
  });

  group('T5 名额回收与防线', () {
    test('job 抛异常立即回收名额', () async {
      final handles = <ThumbHandle>[];
      for (var i = 0; i < 6; i++) {
        final h = thumbPipeline.submit('t5a-e$i', (ctx) async {
          throw Exception('t5a-$i');
        });
        h.future.ignore(); // 异常监听兜底,防 unhandled(断言仍可后挂)
        handles.add(h);
      }
      await _flush();
      expect(thumbPipeline.debugActiveCount, 0, reason: '异常立即释放名额');
      var ran = false;
      final h = thumbPipeline.submit('t5a-next', (ctx) async {
        ran = true;
        return _bytes([3]);
      });
      expect(ran, isTrue);
      expect(await h.future, _bytes([3]));
      for (final x in handles) {
        await expectLater(x.future, throwsA(isException));
      }
      thumbPipeline.reset();
    });

    testWidgets('job 永不完成 → deadline 触发 abort、超时异常、名额回收', (tester) async {
      final g = _Gate();
      final h = thumbPipeline.submit(
        't5b-hang',
        (ctx) => g.job('t5b-hang', ctx),
      );
      h.future.ignore(); // 超时异常监听兜底(expectLater 仍可后挂)
      await tester.pump();
      expect(g.started, ['t5b-hang']);
      await tester.pump(const Duration(seconds: 20));

      await expectLater(h.future, throwsA(isA<TimeoutException>()));
      expect(g.aborts, ['t5b-hang'], reason: '超时走同款终止路径,触发 abort');
      expect(thumbPipeline.debugActiveCount, 0, reason: 'deadline 回收名额');

      var ran = false;
      final nxt = thumbPipeline.submit('t5b-next', (ctx) async {
        ran = true;
        return _bytes([4]);
      });
      expect(ran, isTrue, reason: '名额已回收,新任务立即执行');
      expect(await nxt.future, _bytes([4]));
      // 结束无 pending timer = watchdog 已取消
    });

    testWidgets('deadline 后 job 才抛异常 → 无未处理异步错误(runZonedGuarded)', (
      tester,
    ) async {
      final zoneErrors = <Object>[];
      await runZonedGuarded(() async {
        final g = _Gate();
        final h = thumbPipeline.submit(
          't5c-late',
          (ctx) => g.job('t5c-late', ctx),
        );
        h.future.ignore(); // 超时异常监听兜底,防误入 zone handler
        await tester.pump();
        await tester.pump(const Duration(seconds: 20)); // 超时终态
        await expectLater(h.future, throwsA(isA<TimeoutException>()));
        g.fail('t5c-late'); // 僵尸 job 迟到抛异常
        await tester.pump();
      }, (e, st) => zoneErrors.add(e));
      expect(zoneErrors, isEmpty, reason: '管线级 swallow 兜底迟到异常(D2)');
      thumbPipeline.reset();
    });
  });

  group('T14 登出清理', () {
    test('registerSessionClearHooks 幂等:重复注册只挂一次', () {
      registerSessionClearHooks();
      final hooks = session.debugClearHooks;
      expect(hooks.length, 3, reason: 'pipeline → cache → disk 各一个');
      expect(hooks[0], thumbPipeline.clear);
      expect(hooks[1], thumbnailCache.clear);
      expect(hooks[2], ThumbDiskStore.I.clear);
      registerSessionClearHooks();
      registerSessionClearHooks();
      expect(session.debugClearHooks.length, 3, reason: '幂等防重复累积');
    });

    testWidgets('clear():运行中任务 abort、句柄 null 完成、无 pending timer;'
        'clear 后立即 submit 同 assetId 启动全新任务正常完成', (tester) async {
      final g = _Gate();
      final h = thumbPipeline.submit(
        't14-clear',
        (ctx) => g.job('t14-clear', ctx),
      );
      await tester.pump();
      expect(g.started, ['t14-clear']);

      Uint8List? got = _bytes([0]);
      h.future.then((v) => got = v, onError: (Object _) {});
      thumbPipeline.clear();
      await tester.pump();
      expect(got, isNull, reason: '句柄以 null 完成');
      expect(g.aborts, ['t14-clear'], reason: 'clear 触发 abort 链');
      expect(thumbPipeline.debugActiveCount, 0);

      // 同 assetId 立即重发:全新任务正常完成(去重表已清,不 join 僵尸)
      final h2 = thumbPipeline.submit('t14-clear', (ctx) async => _bytes([5]));
      expect(await h2.future, _bytes([5]), reason: 'clear 后同 assetId 全新任务');
      // 结束无 pending timer = clear 已取消 watchdog
    });

    test('T14 磁盘代际:clear 前开始、clear 后完成的 write 被丢弃;'
        'clear 后新写入不被误删(写闸注入慢写,write/clear 串行互斥)', () async {
      final dir = Directory.systemTemp.createTempSync('t14_disk');
      addTearDown(() {
        ThumbDiskStore.I.debugSetWriteGate(null);
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
        ThumbDiskStore.I.debugAttachDirectory(null);
      });
      ThumbDiskStore.I.debugAttachDirectory(dir);
      final gate = Completer<void>();
      ThumbDiskStore.I.debugSetWriteGate(() => gate.future);

      final gen0 = ThumbDiskStore.I.generation;
      final w = ThumbDiskStore.I.write(
        't14-a',
        _bytes([2]),
        expectedGeneration: gen0,
      );
      await Future<void>.delayed(Duration.zero); // write body 进入慢写闸并持有互斥
      final cleared = ThumbDiskStore.I.clear(); // 同步升代,删除排队在慢写后
      gate.complete(); // 放行慢写
      await w;
      await cleared;

      expect(
        await ThumbDiskStore.I.read('t14-a'),
        isNull,
        reason: '跨代 write 被 rename 前代数校验放弃(不落盘)',
      );
      await ThumbDiskStore.I.write(
        't14-b',
        _bytes([3]),
        expectedGeneration: ThumbDiskStore.I.generation,
      );
      expect(
        await ThumbDiskStore.I.read('t14-b'),
        _bytes([3]),
        reason: 'clear 后新写入不被误删',
      );
    });

    test('T14 缓存代际:clear 前捕获旧 generation 的 putBatch 直接调用即丢弃', () {
      final gen0 = thumbnailCache.generation;
      thumbnailCache.clear();
      thumbnailCache.putBatch([
        (assetId: 't14-c', url: 'http://old/u', expiresIn: 1800),
      ], expectedGeneration: gen0);
      expect(thumbnailCache.length, 0, reason: '旧代 putBatch 整批丢弃');
      thumbnailCache.putBatch([
        (assetId: 't14-d', url: 'http://new/u', expiresIn: 1800),
      ], expectedGeneration: thumbnailCache.generation);
      expect(thumbnailCache.length, 1, reason: '新代 putBatch 正常落缓存');
      thumbnailCache.clear();
    });
  });
}
