/// TransferQueue 单测(B3 测试功能点 1/2/3/8):状态机全转移 / FIFO 并发 2
/// (第 3 个任务等待,完成即补位)/ 取消语义(token 触发,abort 失败不阻塞
/// 取消态)/ 重试=从头重新入队(非续传)/ 清已完成只清终态 / complete 响应
/// 丢失文案+禁自动重传 / 迷你条 n/m 与 badge 口径。注入 worker+假时钟,无真实 IO。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/assets_api.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/transfers/transfer_queue.dart';
import 'package:ms_app/core/transfers/transfer_task.dart';

void main() {
  final fixedNow = DateTime(2026, 10, 20, 10, 0);

  TransferRequest req(
    String name, {
    TransferKind kind = TransferKind.upload,
    int total = 100,
    required TransferWorker worker,
  }) =>
      TransferRequest(
          kind: kind,
          filename: name,
          where: '项目A/夹B',
          totalBytes: total,
          worker: worker);

  /// 排空微任务:worker 的 then/catchError 落地
  Future<void> drain([int ticks = 6]) async {
    for (var i = 0; i < ticks; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('状态机:queued→running→done(进度上报,done 回满字节)', () async {
    final q = TransferQueue(now: () => fixedNow);
    final gate = Completer<void>();
    final progressSeen = <int>[];
    final id = q.enqueue(req('a', worker: (p, token) async {
      // worker 在 enqueue 返回前已同步启动:此刻队列唯一任务即本任务且已 running
      expect(q.tasks.single.status, TransferStatus.running);
      p(40);
      progressSeen.add(q.tasks.single.doneBytes);
      await gate.future;
    }));
    expect(q.tasks.single.status, TransferStatus.running);
    expect(progressSeen, [40]);
    expect(q.byId(id)!.startedAt, fixedNow);
    gate.complete();
    await drain();
    expect(q.byId(id)!.status, TransferStatus.done);
    expect(q.byId(id)!.error, isNull);
    expect(q.byId(id)!.doneBytes, 100, reason: 'done 回满字节(迷你条满格口径)');
  });

  test('状态机:worker 抛 ApiException → failed,error 透传 detail', () async {
    final q = TransferQueue(now: () => fixedNow);
    final id = q.enqueue(req('b',
        worker: (_, _) async => throw ApiException(409, '该文件夹已存在同名文件')));
    await drain();
    expect(q.byId(id)!.status, TransferStatus.failed);
    expect(q.byId(id)!.error, '该文件夹已存在同名文件');
  });

  test('worker 同步抛(P2-5 防御):落该任务 failed,不沿 enqueue 炸穿,队列照常可用',
      () async {
    final q = TransferQueue(now: () => fixedNow);
    Object? leaked;
    try {
      // 非 async 闭包首行同步 throw:修复前会沿 _pump→enqueue 同步抛出
      q.enqueue(req('sync', worker: (p, t) {
        throw StateError('同步抛');
      }));
    } catch (e) {
      leaked = e;
    }
    await drain();
    expect(leaked, isNull, reason: '同步异常不得炸穿入队方');
    expect(q.byId(q.tasks.single.id)!.status, TransferStatus.failed);
    expect(q.tasks.single.error, contains('同步抛'));
    // 队列状态机未破:后续任务正常跑满生命周期
    final ok = q.enqueue(req('ok', worker: (p, t) async {}));
    await drain();
    expect(q.byId(ok)!.status, TransferStatus.done);
  });

  test('FIFO 并发 2:第 3 个等待,完成即补位,等待线按入队序', () async {
    final q = TransferQueue(now: () => fixedNow);
    final gates = {
      'a': Completer<void>(),
      'b': Completer<void>(),
      'c': Completer<void>(),
      'd': Completer<void>(),
    };
    final ids = <String, String>{};
    TransferRequest gated(String n) => req(n, worker: (p, t) async {
          p(10);
          await gates[n]!.future;
        });
    ids['a'] = q.enqueue(gated('a'));
    ids['b'] = q.enqueue(gated('b'));
    ids['c'] = q.enqueue(gated('c'));
    ids['d'] = q.enqueue(gated('d'));
    expect(q.runningCount, 2); // 并发 2
    expect(q.byId(ids['a']!)!.status, TransferStatus.running);
    expect(q.byId(ids['b']!)!.status, TransferStatus.running);
    expect(q.byId(ids['c']!)!.status, TransferStatus.queued);
    expect(q.byId(ids['d']!)!.status, TransferStatus.queued);

    gates['a']!.complete();
    await drain();
    // 补位的是队首 c(非 d):FIFO
    expect(q.byId(ids['c']!)!.status, TransferStatus.running);
    expect(q.byId(ids['d']!)!.status, TransferStatus.queued);

    gates['b']!.complete();
    await drain();
    expect(q.byId(ids['d']!)!.status, TransferStatus.running);
    expect(q.runningCount, 2);
  });

  test('取消 running:CancelToken 触发、立即落取消态、槽位让出;'
      'worker 事后异常(abort 失败)不覆盖取消态', () async {
    final q = TransferQueue(now: () => fixedNow);
    final tokens = <String, CancelToken>{};
    final ids = <String, String>{};
    void cancellable(String name) {
      ids[name] = q.enqueue(req(name, worker: (p, token) async {
        tokens[name] = token;
        p(10);
        while (!token.isCancelled) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        throw StateError('模拟 abort 清理也失败'); // 尽力 abort 失败
      }));
    }

    cancellable('a');
    cancellable('b');
    final c = q.enqueue(req('c', worker: (p, t) async {
      await Completer<void>().future; // 永不完成
    }));
    expect(q.runningCount, 2);
    expect(q.byId(c)!.status, TransferStatus.queued);

    await q.cancel(ids['a']!);
    // 立即落取消态(不等 worker 收尾),槽位让给 c
    expect(q.byId(ids['a']!)!.status, TransferStatus.canceled);
    expect(tokens['a']!.isCancelled, isTrue, reason: 'CancelToken 已触发');
    expect(q.byId(c)!.status, TransferStatus.running, reason: '补位不等 abort');
    expect(q.runningCount, 2);

    await drain(20); // worker a 抛(abort 失败)→ 取消态不被覆盖
    expect(q.byId(ids['a']!)!.status, TransferStatus.canceled);
    expect(q.byId(c)!.status, TransferStatus.running);
    await q.cancel(ids['b']!); // 收尾:停掉轮询 worker,不留活跃定时器
  });

  test('取消 queued:不启动 worker 直接落取消态', () async {
    final q = TransferQueue(now: () => fixedNow);
    final gates = List.generate(2, (_) => Completer<void>());
    var ran = false;
    // 占满两个并发槽 → b 必然排队
    q.enqueue(req('g0', worker: (p, t) async => await gates[0].future));
    q.enqueue(req('g1', worker: (p, t) async => await gates[1].future));
    final b = q.enqueue(req('b', worker: (p, t) async => ran = true));
    expect(q.byId(b)!.status, TransferStatus.queued);
    await q.cancel(b);
    expect(q.byId(b)!.status, TransferStatus.canceled);
    gates[0].complete();
    gates[1].complete();
    await drain();
    expect(ran, isFalse, reason: '取消的排队任务不启动');
    expect(q.byId(b)!.status, TransferStatus.canceled);
  });

  test('重试=同描述重新入队从头来(非续传):旧任务移除、新 id、进度从零重报', () async {
    final q = TransferQueue(now: () => fixedNow);
    var runs = 0;
    final second = Completer<void>();
    final id = q.enqueue(req('a', worker: (p, token) async {
      runs += 1;
      if (runs == 1) {
        p(60);
        throw StateError('boom'); // 首跑推进到 60 后失败
      }
      p(30); // 重跑从零重报(非从 60 续传)
      await second.future;
    }));
    await drain();
    expect(q.byId(id)!.status, TransferStatus.failed);
    expect(q.byId(id)!.doneBytes, 60);

    final newId = q.retry(id);
    expect(newId, isNotNull);
    expect(newId, isNot(id));
    expect(q.byId(id), isNull, reason: '旧任务移出列表');
    final t2 = q.byId(newId!)!;
    expect(t2.status, TransferStatus.running, reason: '有空位立即重新跑');
    expect(runs, 2, reason: 'worker 重新执行');
    expect(t2.doneBytes, 30, reason: '从头来:进度=新跑重报值,非 60 续传');
    expect(t2.filename, 'a');

    second.complete();
    await drain();
    expect(t2.status, TransferStatus.done);
  });

  test('done 不提供重试(同名重传必撞 409);终态才可 retry', () async {
    final q = TransferQueue(now: () => fixedNow);
    final id = q.enqueue(req('a', worker: (p, t) async {}));
    await drain();
    expect(q.byId(id)!.status, TransferStatus.done);
    expect(q.retry(id), isNull);
  });

  test('清已完成只清终态:queued/running 保留,done/failed/canceled 移除', () async {
    final q = TransferQueue(now: () => fixedNow);
    final gates = List.generate(2, (_) => Completer<void>());
    final running1 = q.enqueue(req('r1',
        total: 100, worker: (p, t) async => await gates[0].future));
    final running2 = q.enqueue(req('r2',
        total: 100, worker: (p, t) async => await gates[1].future));
    // 两个槽位已占满 → 以下均排队
    final doneId = q.enqueue(req('done', worker: (p, t) async {}));
    final failedId = q.enqueue(
        req('failed', worker: (p, t) async => throw StateError('x')));
    await q.cancel(doneId); // 排队期取消 → 直接终态,worker 不启动
    expect(q.byId(doneId)!.status, TransferStatus.canceled);

    gates[0].complete(); // 释放槽位 → failedId 起跑即失败;running1 变 done
    await drain();
    expect(q.byId(failedId)!.status, TransferStatus.failed);
    expect(q.byId(running1)!.status, TransferStatus.done);

    q.clearFinished();
    expect(q.byId(doneId), isNull, reason: 'canceled 清除');
    expect(q.byId(failedId), isNull, reason: 'failed 清除');
    expect(q.byId(running1), isNull, reason: 'done 清除');
    expect(q.byId(running2)!.status, TransferStatus.running,
        reason: '活动任务保留');
    gates[1].complete();
    await drain();
  });

  test('remove 仅终态可移除', () async {
    final q = TransferQueue(now: () => fixedNow);
    final gate = Completer<void>();
    final running = q.enqueue(req('r', worker: (p, t) async {
      await gate.future;
    }));
    q.remove(running); // 活动态拒绝
    expect(q.byId(running), isNotNull);
    await q.cancel(running);
    q.remove(running);
    expect(q.byId(running), isNull);
    gate.complete();
  });

  test('complete 响应丢失(§4.1):failed+「可能已上传」文案,禁自动重传', () async {
    final q = TransferQueue(now: () => fixedNow);
    final id = q.enqueue(req(
      'v.mp4',
      worker: (p, t) async => throw UploadAmbiguousException(DioException(
          requestOptions: RequestOptions(path: '/complete'))),
    ));
    await drain();
    final t = q.byId(id)!;
    expect(t.status, TransferStatus.failed);
    expect(t.error, '可能已上传,请先在素材列表核实');
    await drain(10); // 队列无自动重试:状态不自行变化
    expect(t.status, TransferStatus.failed);
  });

  test('迷你条/badge 口径:n/m=已完成/总上传数,bar 聚合字节,running 含下载', () async {
    final q = TransferQueue(now: () => fixedNow);
    final gates = List.generate(4, (_) => Completer<void>());
    var i = 0;
    String add({TransferKind kind = TransferKind.upload}) {
      final n = i++;
      return q.enqueue(req('f$n',
          kind: kind,
          total: 100,
          worker: (p, t) async {
            p(n == 0 ? 50 : 0);
            await gates[n].future;
          }));
    }

    add();
    add();
    add();
    add(kind: TransferKind.download);
    expect(q.uploadCount, 3, reason: 'm=上传总数(下载不计)');
    expect(q.uploadDoneCount, 0);
    expect(q.activeUploadCount, 3);
    expect(q.runningCount, 2, reason: 'badge=running 总数,并发上限 2(混排)');
    expect(q.uploadByteProgress, closeTo(50 / 300, 1e-9));

    // f0 完成 → 等待线队首 f2 补位
    gates[0].complete();
    await drain();
    expect(q.uploadDoneCount, 1);
    expect(q.uploadByteProgress, closeTo(100 / 300, 1e-9),
        reason: 'done 按满格计(f0 totalBytes 100)');

    gates[1].complete();
    await drain();
    expect(q.uploadDoneCount, 2, reason: 'n=2');
    // f2(已被补位启动)改为取消态,验证终态都让 active 归零
    final f2 = q.tasks.firstWhere((t) => t.filename == 'f2');
    await q.cancel(f2.id);
    await drain();
    expect(q.activeUploadCount, 0, reason: '无活动上传 → 迷你条隐藏');
    expect(q.uploadCount, 3, reason: 'm 恒为列表内上传任务总数');
  });
}
