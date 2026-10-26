/// 测试功能点 2(B2):缩略图缓存纯逻辑 — 过期重签判定 / 同 URL 并发去重(单飞)/
/// LRU 驱逐顺序。注入假时钟与计数签名器,不发网络。
/// storm-fix T6 增量:签名闸上限/FIFO/race 放槽、abandonAwait 三态、闸槽幂等
/// 四断言、迟到失败 swallow、代际 clear、missingOf/putBatch/4KB 权重。
/// Timer 纪律:Timer 相关断言用 testWidgets+pump 假时;**本地实例计时器用例
/// 末尾显式 cache.clear()**(addTearDown/全局 tearDown 都晚于 pending-timer
/// 不变量断言,仅作跨用例状态清理)。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/thumb_sign_gate.dart';
import 'package:ms_app/core/thumbnail_cache.dart';

void main() {
  group('过期重签', () {
    test('presigned 30min → 留 5min 余量,25min 内命中缓存,过期后重签', () async {
      var t = DateTime(2026, 10, 20, 12);
      var signs = 0;
      final cache = ThumbnailCache(
        signer: (id) async {
          signs++;
          return SignedThumb(url: 'u$signs', expiresInSeconds: 1800);
        },
        now: () => t,
      );
      expect(await cache.urlOf('a'), 'u1');
      expect(signs, 1);

      t = t.add(const Duration(minutes: 20)); // 25min 内:仍命中
      expect(await cache.urlOf('a'), 'u1');
      expect(signs, 1);

      t = t.add(const Duration(minutes: 10)); // 超 25min:重签
      expect(await cache.urlOf('a'), 'u2');
      expect(signs, 2);
    });

    test('expiresInSeconds<=0 落 fallbackTtl,不至于秒过期', () async {
      var t = DateTime(2026, 10, 20, 12);
      final cache = ThumbnailCache(
        signer: (id) async => SignedThumb(url: 'u', expiresInSeconds: 0),
        now: () => t,
        fallbackTtl: const Duration(minutes: 25),
      );
      expect(await cache.urlOf('a'), 'u');
      t = t.add(const Duration(minutes: 24));
      expect(await cache.urlOf('a'), 'u'); // 仍命中
    });
  });

  group('并发去重(单飞)', () {
    test('同 assetId 并发共享一次签名;不同 assetId 各自签', () async {
      var signs = 0;
      final cache = ThumbnailCache(
        signer: (id) async {
          signs++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return SignedThumb(url: 'u-$id-$signs');
        },
      );
      final f1 = cache.urlOf('a');
      final f2 = cache.urlOf('a'); // 未完成前再请求:单飞
      final f3 = cache.urlOf('b');
      expect(await f1, await f2);
      expect(signs, 2); // a 一次 + b 一次
      expect(await f3, 'u-b-2');
      // 完成后再取:走缓存不再签
      await cache.urlOf('a');
      expect(signs, 2);
    });

    test('签名失败不缓存毒:并发方同败,下次重试重签', () async {
      var calls = 0;
      final cache = ThumbnailCache(
        signer: (id) async {
          calls++;
          if (calls == 1) throw Exception('404 no thumbnail yet');
          return SignedThumb(url: 'u-ok');
        },
      );
      final f1 = cache.urlOf('a');
      final f2 = cache.urlOf('a'); // 与 f1 共享同一单飞(签名器只被调一次)
      await expectLater(f1, throwsA(isException));
      await expectLater(f2, throwsA(isException));
      expect(calls, 1);
      expect(await cache.urlOf('a'), 'u-ok'); // 重试重签并成功
      expect(calls, 2);
      expect(await cache.urlOf('a'), 'u-ok'); // 成功后可走缓存
      expect(calls, 2);
    });
  });

  group('LRU 驱逐', () {
    test('超容量从最久未用逐出;命中即挪新;驱逐后重签', () async {
      var t = DateTime(2026, 10, 20, 12);
      var signs = 0;
      final cache = ThumbnailCache(
        signer: (id) async {
          signs++;
          return SignedThumb(url: 'u-$id-$signs', expiresInSeconds: 1800);
        },
        now: () => t,
        capacityBytes: 300,
        defaultEntryBytes: 100,
      );
      await cache.urlOf('a');
      await cache.urlOf('b');
      await cache.urlOf('c'); // 3×100 = 300 恰满
      expect(cache.length, 3);
      expect(cache.totalBytes, 300);
      expect(signs, 3);

      await cache.urlOf('a'); // 命中 a → a 变最新(LRU 序:b,c,a)
      expect(signs, 3);
      await cache.urlOf('d'); // 插入 d 超容 → 逐出最旧 b
      expect(cache.length, 3);
      expect(cache.totalBytes, 300);
      expect(signs, 4);

      // a/c/d 全命中不再签;b 已被逐出 → 重签
      await cache.urlOf('a');
      await cache.urlOf('c');
      await cache.urlOf('d');
      expect(signs, 4);
      await cache.urlOf('b');
      expect(signs, 5);
    });

    test('单条超大不自我驱逐(保证恒可取)', () async {
      final cache = ThumbnailCache(
        signer: (id) async => SignedThumb(url: 'u-$id'),
        capacityBytes: 100,
        defaultEntryBytes: 500, // 单条即超容量
      );
      expect(await cache.urlOf('a'), 'u-a');
      expect(cache.length, 1); // 不驱逐自身
      expect(await cache.urlOf('a'), 'u-a');
    });
  });

  group('T6 签名闸(经 ThumbnailCache 驱动)', () {
    test('闸上限 6 FIFO:第 7 个排队,signer 未被调', () async {
      final calls = <String>[];
      final hang = Completer<void>();
      final cache = ThumbnailCache(
        signer: (id) async {
          calls.add(id);
          await hang.future;
          return SignedThumb(url: 'u-$id');
        },
      );
      addTearDown(cache.clear);
      final fs = [for (var i = 0; i < 7; i++) cache.urlOf('g6-$i')];
      for (final f in fs) {
        f.ignore(); // clear 取消异常监听兜底(expectLater 仍可后挂)
      }
      expect(cache.debugGateActive, 6, reason: '签名闸上限 6');
      expect(cache.debugGateQueued, 1);
      expect(calls.length, 6);
      expect(calls.contains('g6-6'), isFalse, reason: 'FIFO:第 7 个未入闸');

      cache.clear(); // 显式:取消全部 race 计时器(pending-timer 不变量)
      expect(cache.debugGateActive, 0, reason: 'clear 归零闸计数');
      for (final f in fs) {
        await expectLater(
          f,
          throwsA(isA<ThumbSignAbandoned>()),
          reason: 'clear 后 active waiter 以取消异常完成,不悬挂',
        );
      }
    });

    testWidgets('槽内 20s race 超时放槽:等待者收 TimeoutException;'
        '底层 signer 完成仍落缓存', (tester) async {
      final calls = <String>[];
      final done = Completer<void>();
      final cache = ThumbnailCache(
        signer: (id) async {
          calls.add(id);
          await done.future;
          return SignedThumb(url: 'u-slow-$id');
        },
      );
      addTearDown(cache.clear);
      final f = cache.urlOf('race-a');
      f.ignore(); // 超时异常监听兜底(expectLater 仍可后挂)
      await tester.pump();
      expect(cache.debugGateActive, 1);

      await tester.pump(const Duration(seconds: 20));
      await expectLater(f, throwsA(isA<TimeoutException>()));
      expect(cache.debugGateActive, 0, reason: 'race 超时放槽');

      final f2 = cache.urlOf('race-b'); // 放槽后新签名立即可入
      await tester.pump();
      expect(calls, ['race-a', 'race-b']);

      done.complete(); // 底层悬挂签名迟到完成 → 落缓存
      await tester.pump();
      expect(await f2, 'u-slow-race-b', reason: '放槽后新 waiter 照常收到结果');
      expect(
        await cache.urlOf('race-a'),
        'u-slow-race-a',
        reason: '被放弃签名的迟到成功仍落缓存,下次命中不再重签',
      );
      expect(calls, ['race-a', 'race-b']);
      cache.clear();
    });

    testWidgets('abandonAwait:最后 waiter 放弃 → 闸槽归还、race 计时器取消;'
        '排队态放弃:第 7 个排队 waiter 出 FIFO、signer 未调、active 仍 6', (tester) async {
      final calls = <String>[];
      final hang = Completer<void>();
      final cache = ThumbnailCache(
        signer: (id) async {
          calls.add(id);
          await hang.future;
          return SignedThumb(url: 'u-$id');
        },
      );
      addTearDown(cache.clear);

      // 运行态:唯一 waiter 放弃 → 还槽 + 计时器取消
      final f = cache.urlOf('ab-a');
      await tester.pump();
      expect(cache.debugGateActive, 1);
      cache.abandonAwait('ab-a');
      await expectLater(f, throwsA(isA<ThumbSignAbandoned>()));
      expect(cache.debugGateActive, 0, reason: '最后 waiter 放弃 → 还槽');

      // 排队态:6 悬挂 + 第 7 排队;放弃第 7 → 出 FIFO、active 不动
      final fs = [for (var i = 0; i < 6; i++) cache.urlOf('ab-q$i')];
      for (final f in fs) {
        f.ignore(); // 20s race 超时异常监听兜底
      }
      await tester.pump();
      final queued = cache.urlOf('ab-q6');
      expect(cache.debugGateActive, 6);
      expect(cache.debugGateQueued, 1);
      expect(calls.length, 7, reason: '6 悬挂 + ab-a 共 7 次进入 signer');
      cache.abandonAwait('ab-q6');
      await expectLater(queued, throwsA(isA<ThumbSignAbandoned>()));
      expect(cache.debugGateQueued, 0, reason: '排队态放弃:整体出 FIFO');
      expect(cache.debugGateActive, 6, reason: '不动闸 active 计数');
      expect(calls.contains('ab-q6'), isFalse, reason: 'signer 未被调');

      // pump 20s:6 个 race 放槽后,新任务才能真正进闸
      final next = cache.urlOf('ab-new');
      expect(cache.debugGateQueued, 1, reason: '闸满,新任务排队');
      await tester.pump(const Duration(seconds: 20));
      for (final f in fs) {
        await expectLater(f, throwsA(isA<TimeoutException>()));
      }
      expect(cache.debugGateActive, 1, reason: 'race 放槽后新任务进闸');
      expect(calls.last, 'ab-new');

      cache.clear();
      await expectLater(next, throwsA(isA<ThumbSignAbandoned>()));
    });

    testWidgets('闸槽幂等四断言:race 迟到成功/放槽后 abandon/clear 后旧 signer/'
        'join 已放槽悬挂签名再 abandon 均 no-op 不双减', (tester) async {
      final calls = <String>[];
      final hangs = <Completer<void>>[Completer<void>()];
      final cache = ThumbnailCache(
        signer: (id) async {
          calls.add(id);
          await hangs.last.future;
          throw Exception('late-dead-$id');
        },
      );
      addTearDown(cache.clear);

      // a) race 超时后 signer 迟到失败 → active 不变(不双减),迟到失败被吞
      final zoneErrors = <Object>[];
      await runZonedGuarded(() async {
        final f = cache.urlOf('i4-a');
        f.ignore(); // 超时异常监听兜底,防误入 zone handler
        await tester.pump();
        expect(cache.debugGateActive, 1);
        await tester.pump(const Duration(seconds: 20));
        await expectLater(f, throwsA(isA<TimeoutException>()));
        expect(cache.debugGateActive, 0, reason: 'race 放槽');
        hangs.last.complete(); // 底层 signer 迟到失败
        await tester.pump();
        expect(cache.debugGateActive, 0, reason: '迟到 settle 不双减');
      }, (e, st) => zoneErrors.add(e));
      expect(zoneErrors, isEmpty, reason: '被放弃签名的迟到失败仅 AppLog,无未处理异步异常(不弹报错页)');

      // b) race 放槽后 abandon → no-op,active 不变
      cache.abandonAwait('i4-a');
      expect(cache.debugGateActive, 0, reason: 'waiter 已超时出场,abandon no-op');

      // c) clear 后旧 signer 完成 → active 仍为 0
      cache.clear();
      expect(cache.debugGateActive, 0);
      expect(cache.debugGatePendingJobs, 0);

      // d) join 已放槽悬挂签名的第二个 waiter abandon → 不双减 + 自身计时器取消
      hangs.add(Completer<void>()); // 新一轮独立悬挂(上一 completer 已耗尽)
      await runZonedGuarded(() async {
        final f1 = cache.urlOf('i4-b'); // 占槽悬挂
        f1.ignore(); // 超时异常监听兜底,防误入 zone handler
        await tester.pump();
        expect(cache.debugGateActive, 1);
        await tester.pump(const Duration(seconds: 20)); // race 放槽(active 0)
        await expectLater(f1, throwsA(isA<TimeoutException>()));
        final f2 = cache.urlOf('i4-b'); // join 放槽悬挂签名:slotHeld=false
        await tester.pump();
        cache.abandonAwait('i4-b');
        await expectLater(f2, throwsA(isA<ThumbSignAbandoned>()));
        expect(
          cache.debugGateActive,
          0,
          reason: 'join 者 releaseSlot no-op,不双减',
        );
        hangs.last.complete(); // 根 future 迟到失败 → swallow
        await tester.pump();
      }, (e, st) => zoneErrors.add(e));
      expect(zoneErrors, isEmpty, reason: 'join 后放弃,根迟到失败同样被吞');
      cache.clear();
    });

    testWidgets('签名成功路径 race 计时器同步取消、无 pending timer;'
        '存在 active waiter 时签名失败照常传播', (tester) async {
      var flip = false;
      final cache = ThumbnailCache(
        signer: (id) async {
          if (!flip) {
            flip = true;
            return SignedThumb(url: 'u-ok');
          }
          throw Exception('404 no thumbnail yet');
        },
      );
      addTearDown(cache.clear);
      final f = cache.urlOf('ok-a');
      await tester.pump();
      expect(await f, 'u-ok', reason: '成功路径:waiter 收到 url');
      expect(cache.debugGateActive, 0, reason: 'signer 正常成功释放槽');
      // 用例结束无 pending timer = 成功路径 race 计时器同步取消

      final g = cache.urlOf('bad-a'); // active waiter 存在
      g.ignore(); // 失败异常监听兜底(expectLater 仍可后挂)
      await tester.pump();
      await expectLater(
        g,
        throwsA(isException),
        reason: '存在 active waiter:失败照常传播(立即落降级)',
      );
      expect(cache.debugGateActive, 0, reason: 'signer 失败释放槽');
      cache.clear();
    });

    testWidgets('clear 代际:旧代 waiter 异常完成不悬挂、active 归零;'
        'clear 后新同 assetId 单飞重签不被误删;urlOf 不返回旧代 inflight', (tester) async {
      final calls = <String>[];
      final hang = Completer<void>();
      var released = false;
      final cache = ThumbnailCache(
        signer: (id) async {
          calls.add(id);
          if (!released) await hang.future;
          return SignedThumb(
            url: 'u-$id-${calls.where((c) => c == id).length}',
          );
        },
      );
      addTearDown(cache.clear);

      final fillers = [for (var i = 0; i < 6; i++) cache.urlOf('cg-f$i')];
      for (final f in fillers) {
        f.ignore(); // clear 取消异常监听兜底(expectLater 仍可后挂)
      }
      await tester.pump();
      final queued = cache.urlOf('cg-q'); // 排队态 waiter
      queued.ignore();
      final gen0 = cache.generation;

      cache.clear();
      expect(cache.generation, gen0 + 1, reason: 'clear 代数自增');
      expect(cache.debugGateActive, 0, reason: '闸计数归零');
      await expectLater(fillers.first, throwsA(isA<ThumbSignAbandoned>()));
      await expectLater(queued, throwsA(isA<ThumbSignAbandoned>()));

      released = true; // 旧代 signer 迟到完成:settled job 直接 no-op
      hang.complete();
      await tester.pump();
      expect(cache.debugGateActive, 0, reason: '旧代迟到 settle 不影响新代计数');

      // clear 后同 assetId 重新单飞:全新 job,不被旧代 inflight 误删/误 join
      final url = await cache.urlOf('cg-f0');
      expect(url, 'u-cg-f0-2', reason: '重签(旧代 inflight 不复用)');
      expect(calls.where((c) => c == 'cg-f0').length, 2);
      cache.clear();
    });
  });

  group('T6 批量接口与容量(W3 #15)', () {
    test('putBatch 后 missingOf 不含未过期项;过期/未命中仍报 missing', () {
      var t = DateTime(2026, 10, 26, 12);
      final cache = ThumbnailCache(
        signer: (id) async => SignedThumb(url: 'u-$id'),
        now: () => t,
      );
      addTearDown(cache.clear);
      cache.putBatch([(assetId: 'b-a', url: 'http://x/a', expiresIn: 1800)]);
      expect(cache.missingOf(['b-a', 'b-b']), [
        'b-b',
      ], reason: '未过期项不再 missing,未命中照报');
      t = t.add(const Duration(minutes: 30));
      expect(cache.missingOf(['b-a']), ['b-a'], reason: '过期条目视为 missing');
    });

    test('putBatch TTL:expiresIn≤0 落 fallbackTtl;0<expiresIn≤300 不缓存', () {
      var t = DateTime(2026, 10, 26, 12);
      final cache = ThumbnailCache(
        signer: (id) async => SignedThumb(url: 'u-$id'),
        now: () => t,
        fallbackTtl: const Duration(minutes: 25),
      );
      addTearDown(cache.clear);
      cache.putBatch([
        (assetId: 't-zero', url: 'http://x/0', expiresIn: 0),
        (assetId: 't-small', url: 'http://x/s', expiresIn: 200), // ≤ margin 300
        (assetId: 't-ok', url: 'http://x/o', expiresIn: 1800),
      ]);
      expect(cache.missingOf(['t-small']), [
        't-small',
      ], reason: '0<expiresIn≤300 不缓存(等价立即过期,省容量)');
      expect(
        cache.missingOf(['t-zero']),
        isEmpty,
        reason: '≤0 落 fallbackTtl 缓存',
      );
      expect(cache.missingOf(['t-ok']), isEmpty);
      t = t.add(const Duration(minutes: 24)); // fallbackTtl 25min 内仍命中
      expect(cache.missingOf(['t-zero']), isEmpty);
    });

    test('LRU 默认 4KB 权重生效;超容从最久未用逐出', () async {
      var t = DateTime(2026, 10, 26, 12);
      var signs = 0;
      final cache = ThumbnailCache(
        signer: (id) async {
          signs++;
          return SignedThumb(url: 'u-$id-$signs', expiresInSeconds: 1800);
        },
        now: () => t,
        capacityBytes: 12 * 1024, // 3×4KB 恰满
      );
      addTearDown(cache.clear);
      expect(cache.defaultEntryBytes, 4 * 1024, reason: '默认权重 256KB→4KB');
      await cache.urlOf('w-a');
      await cache.urlOf('w-b');
      await cache.urlOf('w-c');
      expect(cache.length, 3);
      expect(cache.totalBytes, 12 * 1024);
      await cache.urlOf('w-d'); // 逐出最旧 w-a
      expect(cache.length, 3);
      expect(cache.totalBytes, 12 * 1024, reason: 'running total 维护,不漂移');
      expect(cache.missingOf(['w-a']), ['w-a'], reason: 'w-a 已被逐出');
      expect(cache.missingOf(['w-b', 'w-c', 'w-d']), isEmpty);
      expect(signs, 4);
    });

    test('abandonAwait 带旧代数 → no-op(不误伤新代 waiter)', () async {
      final hang = Completer<void>();
      final cache = ThumbnailCache(
        signer: (id) async {
          await hang.future;
          return SignedThumb(url: 'u-$id');
        },
      );
      addTearDown(cache.clear);
      final gen0 = cache.generation;
      final f = cache.urlOf('gen-a');
      cache.abandonAwait('gen-a', generation: gen0 - 1); // 旧代 late 注册
      expect(cache.debugGateActive, 1, reason: '旧代 abandon no-op,waiter 无恙');
      cache.abandonAwait('gen-a', generation: cache.generation);
      await expectLater(f, throwsA(isA<ThumbSignAbandoned>()));
      cache.clear();
    });
  });
}
