/// ThumbVariant 全链键维度单测(thumb-variant 批 T3,测试功能点 12 §6.12;
/// 契约 §3.7 键维度段——「漏一环即互串」的三个环节逐一验证):
/// ① 管线去重键 `'$assetId:${variant.diskTag}'`——同 assetId 不同 variant
///    并存两条任务(排队/运行互不共享、互不去重),同 variant 仍单飞;
/// ② URL 缓存键同维度——large/small 条目独立存取互不命中,missingOf/
///    putBatch 按 variant 判定,并发单飞按 variant 隔离;
/// ③ 签名闸 _Job 注册表键同维度——同 assetId 不同 variant 并存两个 sign
///    job,abandonAwait 仅放弃对应 variant、不波及另一变体;
/// ④ fetchThumb 默认 large、显式 small 透传(经 ThumbVariantX.apiSize 落到
///    签名函数入参)。
///
/// 网络纪律(仓内已知坑):fetchThumb 用例必须在首个 fetch 前用
/// HttpOverrides.runZoned 安装桩 HttpClient——core/thumb_fetch.dart 的模块级
/// `_thumbHttp` 静态单例首次访问即初始化,之后整文件复用该桩;签名走记录式
/// 假 API(本文件自持,签名与 lib 现行签名一致),全程无真实 socket。
/// Timer 纪律:假时/桩推进用 testWidgets + pump;plain test 用例显式释放
/// 全部 Completer 并收尾 thumbPipeline.reset()(全局 tearDown 兜底重置)。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/assets_api.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/core/thumb_fetch.dart';
import 'package:ms_app/core/thumb_pipeline.dart';
import 'package:ms_app/core/thumb_sign_gate.dart';
import 'package:ms_app/core/thumb_variant.dart';
import 'package:ms_app/core/thumbnail_cache.dart';

Uint8List _bytes(List<int> l) => Uint8List.fromList(l);

const _kBytes = [1, 2, 3, 7, 8, 9];

/// 微任务冲刷(plain test 用:job 完成经 microtask 链释放名额/回填缓存)。
Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

// ── 记录式假 API(签名可计数、可挂起;与 assets_api 现行签名一致)────────────

class _SignAssetsApi extends AssetsApi {
  _SignAssetsApi(super.api);

  /// 单发签名入参记录(size 经 ThumbVariantX.apiSize 映射)。
  final calls = <({String assetId, String size})>[];

  /// 批量签名入参记录(本文件批量走本地 ThumbnailCache 不经此;预留)。
  final batchCalls = <({List<String> assetIds, String? size})>[];

  /// 非 null 时挂起签名(并发期并存断言用;置 null 放行)。
  Completer<void>? hang;

  @override
  Future<({String url, int expiresIn})> thumbnailUrl(
    String assetId, {
    required String size,
  }) async {
    calls.add((assetId: assetId, size: size));
    final gate = hang;
    if (gate != null) await gate.future;
    return (url: 'http://thumb.test/$assetId', expiresIn: 1800);
  }

  @override
  Future<({Map<String, ({String url, int expiresIn})> byId, Set<String> missing})>
  thumbnailUrls(List<String> assetIds, {String? size}) async {
    batchCalls.add((assetIds: List.of(assetIds), size: size));
    return (
      byId: {
        for (final id in assetIds)
          id: (url: 'http://thumb.test/$id', expiresIn: 1800),
      },
      missing: const <String>{},
    );
  }
}

class _SignMsApi extends MsApi {
  _SignMsApi() : super(baseUrl: 'http://thumb-variant-keys.test.local');

  late final _assets = _SignAssetsApi(this);

  @override
  _SignAssetsApi get assets => _assets;
}

// ── 桩 HTTP(仅本文件首颗 _thumbHttp 初始化时被 zone 捕获)───────────────────

int _getUrlCalls = 0;

class _StubHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    _getUrlCalls++;
    return _StubRequest();
  }

  @override
  set connectionTimeout(Duration? _) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _StubRequest implements HttpClientRequest {
  @override
  Future<HttpClientResponse> close() =>
      Future<HttpClientResponse>.value(_StubResponse());

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _StubResponse implements HttpClientResponse {
  @override
  int get statusCode => 200;

  @override
  Future<E> drain<E>([E? futureValue]) {
    return listen((_) {}).asFuture<E>().then((_) => futureValue as E);
  }

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> element)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable([_kBytes]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  setUp(() {
    _getUrlCalls = 0;
    session.api = _SignMsApi();
  });

  tearDown(() {
    session.api = null;
    // 全局 test_config 已重置 thumbPipeline/thumbnailCache;此处显式再清一次
    // (防个别用例遗留 race 计时器跨用例触发)
    thumbnailCache.clear();
  });

  group('① 管线去重键(ThumbPipeline.submit)', () {
    test('同 assetId 不同 variant 并存两条任务;同 variant 仍去重共享', () async {
      var runs = 0;
      final largeGate = Completer<void>();
      final smallGate = Completer<void>();

      final hLarge = thumbPipeline.submit('kv-a', (ctx) async {
        runs++;
        await largeGate.future;
        return _bytes([1]);
      }); // 默认 variant=large
      await _flush();
      final hSmall = thumbPipeline.submit(
        'kv-a',
        (ctx) async {
          runs++;
          await smallGate.future;
          return _bytes([2]);
        },
        variant: ThumbVariant.small,
      );
      await _flush();
      expect(runs, 2, reason: '同 assetId 不同 variant 互不去重(键含 variant)');

      final hLargeJoin = thumbPipeline.submit('kv-a', (ctx) async {
        runs++;
        return _bytes([9]);
      }); // 同 variant 再提交:应共享
      await _flush();
      expect(runs, 2, reason: '同 assetId 同 variant 仍去重(共享同一次执行)');

      largeGate.complete();
      smallGate.complete();
      expect(await hLarge.future, _bytes([1]));
      expect(await hLargeJoin.future, _bytes([1]), reason: '共享者拿到同一次结果');
      expect(await hSmall.future, _bytes([2]), reason: 'small 任务独立完成');
      thumbPipeline.reset();
    });
  });

  group('② URL 缓存键(ThumbnailCache 本地实例)', () {
    test('large/small 条目独立:互不命中、各自单飞、命中不重签', () async {
      final calls = <({String assetId, String tag})>[];
      final cache = ThumbnailCache(
        signer: (assetId, variant) async {
          calls.add((assetId: assetId, tag: variant.diskTag));
          return SignedThumb(url: 'u-$assetId-${variant.diskTag}');
        },
      );

      expect(await cache.urlOf('kv-u'), 'u-kv-u-lg');
      expect(
        await cache.urlOf('kv-u', variant: ThumbVariant.small),
        'u-kv-u-s',
        reason: '同 assetId 换 variant:重签(缓存键含 variant,不命中 large 条目)',
      );
      expect(calls, [
        (assetId: 'kv-u', tag: 'lg'),
        (assetId: 'kv-u', tag: 's'),
      ], reason: '两变体各签一次,签名器收到各自 variant');

      expect(await cache.urlOf('kv-u'), 'u-kv-u-lg');
      expect(await cache.urlOf('kv-u', variant: ThumbVariant.small), 'u-kv-u-s');
      expect(calls.length, 2, reason: '两变体条目独立命中,不再重签');
      cache.clear();
    });

    test('并发期按 variant 隔离单飞:不共享同一签名', () async {
      final hang = Completer<void>();
      final calls = <String>[];
      final cache = ThumbnailCache(
        signer: (assetId, variant) async {
          calls.add('$assetId:${variant.diskTag}');
          await hang.future;
          return SignedThumb(url: 'u-$assetId-${variant.diskTag}');
        },
      );

      final fLarge = cache.urlOf('kv-c');
      final fSmall = cache.urlOf('kv-c', variant: ThumbVariant.small);
      hang.complete();
      expect(await fLarge, 'u-kv-c-lg');
      expect(await fSmall, 'u-kv-c-s');
      expect(calls, ['kv-c:lg', 'kv-c:s'],
          reason: '同 assetId 两变体并发:各自单飞一次(去重键含 variant)');
      cache.clear();
    });

    test('putBatch/missingOf 按 variant 判定:small 批量只落 small 键', () {
      final cache = ThumbnailCache(signer: (assetId, variant) async {
        return SignedThumb(url: 'u-$assetId-${variant.diskTag}');
      });
      cache.putBatch(
        [(assetId: 'kv-p', url: 'u-kv-p-s', expiresIn: 1800)],
        variant: ThumbVariant.small,
      );
      expect(
        cache.missingOf(['kv-p'], variant: ThumbVariant.small).toList(),
        isEmpty,
        reason: 'small 条目落 small 缓存键:small 维度视为已就绪',
      );
      expect(
        cache.missingOf(['kv-p']).toList(),
        ['kv-p'],
        reason: 'large 维度仍视为 missing(条目互不串)',
      );
      cache.clear();
    });
  });

  group('③ 签名闸 _Job 键(ThumbSignGate 本地实例)', () {
    test('同 assetId 不同 variant 并存两个 job;abandon 仅放弃对应 variant',
        () async {
      final gate = ThumbSignGate<String>();
      final runs = <String>[];
      final largeDone = Completer<String>();
      final smallDone = Completer<String>();

      final jLarge = gate.open('kv-g', () async {
        runs.add('lg');
        return largeDone.future;
      });
      final jSmall = gate.open(
        'kv-g',
        () async {
          runs.add('s');
          return smallDone.future;
        },
        variant: ThumbVariant.small,
      );
      final fLarge = gate.addWaiter(jLarge);
      final fSmall = gate.addWaiter(jSmall);
      await _flush();

      expect(gate.pendingJobCount, 2,
          reason: '同 assetId 不同 variant 并存两条 _Job(注册表键含 variant)');
      expect(gate.activeCount, 2, reason: '两 job 各自占槽执行');
      expect(runs, ['lg', 's'], reason: '两 job 互不共享地执行');

      gate.abandon('kv-g', variant: ThumbVariant.small);
      await expectLater(
        fSmall,
        throwsA(isA<ThumbSignAbandoned>()),
        reason: 'abandon 精确放弃 small 等待者',
      );
      expect(gate.activeCount, 1, reason: '仅 small job 还槽');

      largeDone.complete('u-large');
      expect(await fLarge, 'u-large', reason: 'large job 不受 small abandon 波及');
      expect(gate.activeCount, 0, reason: 'large 正常终态还槽');
    });
  });

  group('④ fetchThumb 变体透传', () {
    testWidgets('默认 large、显式 small 透传签名;两变体任务并存不被去重',
        (tester) async {
      await HttpOverrides.runZoned(() async {
        final api = session.api as _SignMsApi;
        final signGate = Completer<void>();
        api.assets.hang = signGate;

        final hLarge = fetchThumb('kv-f'); // 默认 variant=large
        await tester.pump();
        expect(api.assets.calls, [
          (assetId: 'kv-f', size: 'large'),
        ], reason: 'fetchThumb 缺省走 large(apiSize=large 透传签名)');

        final hSmall = fetchThumb('kv-f', variant: ThumbVariant.small);
        await tester.pump();
        expect(api.assets.calls, [
          (assetId: 'kv-f', size: 'large'),
          (assetId: 'kv-f', size: 'small'),
        ], reason: '显式 small 透传(apiSize=small);large 悬挂期不被去重挡住');
        expect(thumbPipeline.debugActiveCount, 2,
            reason: '同 assetId 两变体任务并存运行(管线去重键含 variant)');

        signGate.complete(); // 放行两签名 → 各自走桩下载
        await tester.pump();
        expect(await hLarge.future, _kBytes);
        expect(await hSmall.future, _kBytes);
        expect(_getUrlCalls, 2, reason: '两任务各自下载一次(不共享字节)');
        await tester.pump(); // watchdog 随终态取消,无 pending timer
      }, createHttpClient: (_) => _StubHttpClient());
    });
  });
}
