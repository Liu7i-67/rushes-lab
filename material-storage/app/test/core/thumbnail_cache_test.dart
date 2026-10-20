/// 测试功能点 2(B2):缩略图缓存纯逻辑 — 过期重签判定 / 同 URL 并发去重(单飞)/
/// LRU 驱逐顺序。注入假时钟与计数签名器,不发网络。
library;

import 'package:flutter_test/flutter_test.dart';
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
}
