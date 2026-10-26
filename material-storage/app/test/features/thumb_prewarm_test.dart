/// prewarmThumbUrls 单元(storm-fix 测试功能点 T11① 预热侧):
/// 过滤 hasThumbnail 且 missingOf 命中 → 捕获代数 → 分批 ≤100 → thumbnailUrls →
/// putBatch 带代数;失败静默(session.api null / 端点异常 / missing 项忽略)。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/core/thumbnail_cache.dart';
import 'package:ms_app/features/assets/thumb_prewarm.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

Asset _asset(String id, {bool withThumb = true}) => Asset(
  id: id,
  filename: '$id.jpg',
  sizeBytes: 4,
  contentType: 'image/jpeg',
  createdAt: '2026-10-20T10:00:00Z',
  tags: withThumb ? const {'thumbnail_key': 'k'} : const {},
);

class _PrewarmAssetsApi extends FakeAssetsApi {
  _PrewarmAssetsApi(super.api);

  final batchCalls = <List<String>>[];
  Object? batchStaged;

  /// 命中 missing 的 id(每次调用都按此集合报 missing)。
  Set<String> missingIds = <String>{};

  @override
  Future<
    ({Map<String, ({String url, int expiresIn})> byId, Set<String> missing})
  >
  thumbnailUrls(List<String> assetIds) async {
    batchCalls.add(List.of(assetIds));
    final staged = batchStaged;
    if (staged is Exception) throw staged;
    return (
      byId: {
        for (final id in assetIds)
          if (!missingIds.contains(id))
            id: (url: 'http://thumb.test/$id', expiresIn: 1800),
      },
      missing: missingIds.where(assetIds.contains).toSet(),
    );
  }
}

class _PrewarmMsApi extends FakeMsApi {
  late final _assets = _PrewarmAssetsApi(this);

  @override
  _PrewarmAssetsApi get assets => _assets;
}

void main() {
  tearDown(() {
    session.api = null;
    thumbnailCache.clear();
  });

  test('过滤:只预热 hasThumbnail 且 missingOf 命中的资产', () async {
    final api = installFakeApi(_PrewarmMsApi()) as _PrewarmMsApi;
    thumbnailCache.putBatch([
      (assetId: 'warm-a', url: 'http://cached/a', expiresIn: 1800),
    ]);

    await prewarmThumbUrls([
      _asset('warm-a'), // 已有未过期缓存 → 跳过
      _asset('warm-b'), // 有 key 且未缓存 → 预热
      _asset('warm-c', withThumb: false), // 无 key → 不发请求
    ]);

    expect(api.assets.batchCalls, [
      ['warm-b'],
    ], reason: '无 key 与已缓存项均不过批量端点');
    expect(
      thumbnailCache.missingOf(['warm-a', 'warm-b']),
      isEmpty,
      reason: '预热后批量落缓存',
    );
  });

  test('分批 ≤100:250 项 → 3 批(100/100/50)', () async {
    final api = installFakeApi(_PrewarmMsApi()) as _PrewarmMsApi;
    final items = [for (var i = 0; i < 250; i++) _asset('bulk-$i')];

    await prewarmThumbUrls(items);

    expect(api.assets.batchCalls.length, 3);
    expect(api.assets.batchCalls[0].length, 100);
    expect(api.assets.batchCalls[1].length, 100);
    expect(api.assets.batchCalls[2].length, 50);
    final all = api.assets.batchCalls.expand((e) => e).toSet();
    expect(all.length, 250, reason: '全部资产恰好覆盖一次');
  });

  test('missing 项忽略:不做负缓存不重试,可由单发兜底', () async {
    final api = installFakeApi(_PrewarmMsApi()) as _PrewarmMsApi;
    api.assets.missingIds = {'miss-1'};

    await prewarmThumbUrls([_asset('miss-1'), _asset('hit-1')]);

    expect(api.assets.batchCalls.length, 1, reason: '不自动重试');
    expect(thumbnailCache.missingOf(['miss-1']), [
      'miss-1',
    ], reason: 'missing 不做负缓存(有 key 格子进入视野时单发兜底)');
    expect(thumbnailCache.missingOf(['hit-1']), isEmpty);
  });

  test('失败静默:批量端点异常不外抛(session.api null 同样容错)', () async {
    final api = installFakeApi(_PrewarmMsApi()) as _PrewarmMsApi;
    api.assets.batchStaged = Exception('404 旧后端无批量端点');

    await prewarmThumbUrls([_asset('s-1'), _asset('s-2')]); // 不抛
    expect(api.assets.batchCalls.length, 1, reason: '请求已发出,失败被吞');

    session.api = null;
    await prewarmThumbUrls([_asset('s-3')]); // session.api null → 静默返回
    expect(api.assets.batchCalls.length, 1, reason: '无会话不再发新请求');
  });

  test('预热带代数:putBatch 后 clear 升代,旧代结果不覆盖新状态', () async {
    installFakeApi(_PrewarmMsApi());
    final items = [_asset('gen-1')];
    await prewarmThumbUrls(items);
    expect(thumbnailCache.missingOf(['gen-1']), isEmpty);

    final genBefore = thumbnailCache.generation;
    thumbnailCache.clear();
    expect(thumbnailCache.generation, genBefore + 1);
    // 模拟旧代 late putBatch(预热内部已带捕获代数,此处直接验证 putBatch 语义)
    thumbnailCache.putBatch([
      (assetId: 'gen-1', url: 'http://stale/u', expiresIn: 1800),
    ], expectedGeneration: genBefore);
    expect(thumbnailCache.missingOf(['gen-1']), [
      'gen-1',
    ], reason: '旧代 putBatch 被丢弃');
  });
}
