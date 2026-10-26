/// ThumbnailCache — 缩略图 presigned URL 缓存(B2 §8.1,app-thumbnail-storm-fix
/// W2/W3 增量):① URL+过期时间内存缓存,临期自动重签(后端签 30min,留 5min
/// 余量,web 同哲学);② 同 assetId 并发去重(单飞,经 [ThumbSignGate] 签名并发
/// 闸:上限 6 FIFO + 槽内 20s race 放槽 + abandonAwait 放弃链);③ LRU 驱逐:
/// 条目按近似字节计权,总量超 [capacityBytes] 时从最久未用开始逐出(running
/// total O(1) 维护;每条默认按 URL 字符串 4KB 估算,上限 ~2 万条)。
/// ④ 代际:clear() 升代,旧代 in-flight/putBatch 一律丢弃;abandonAwait 带
/// 代数防旧代 late 注册误伤新代。
///
/// 只管 URL 不持有位图字节;位图磁盘见 ThumbDiskStore,Image 解码缓存交给
/// Flutter ImageCache。全局实例 [thumbnailCache] 移入 core(签名只依赖
/// session.api,core 内合法;features 侧经 thumbnail_image.dart 一行 export
/// 兼容旧 import)。
library;

import 'package:flutter/foundation.dart';

import 'session.dart';
import 'thumb_sign_gate.dart';

class SignedThumb {
  SignedThumb({
    required this.url,
    this.expiresInSeconds = 1800,
    this.approxBytes,
  });

  final String url;
  final int expiresInSeconds;

  /// 签名方可回报条目近似大小;null 用缓存默认估算。
  final int? approxBytes;
}

typedef ThumbSigner = Future<SignedThumb> Function(String assetId);

class _Entry {
  _Entry({
    required this.url,
    required this.expiresAt,
    required this.approxBytes,
  });

  final String url;
  final DateTime expiresAt;
  final int approxBytes;
}

/// 进程级缩略图 URL 缓存(只存 URL 不存位图;签名走会话 API,失败静默)。
final thumbnailCache = ThumbnailCache(
  signer: (assetId) async {
    final r = await session.api!.assets.thumbnailUrl(assetId);
    return SignedThumb(url: r.url, expiresInSeconds: r.expiresIn);
  },
);

class ThumbnailCache {
  ThumbnailCache({
    required this.signer,
    DateTime Function()? now,
    this.expiryMargin = const Duration(minutes: 5),
    this.fallbackTtl = const Duration(minutes: 25),
    this.capacityBytes = 80 * 1024 * 1024,
    this.defaultEntryBytes = 4 * 1024,
  }) : _now = now ?? DateTime.now,
       _gate = ThumbSignGate<SignedThumb>();

  final ThumbSigner signer;
  final DateTime Function() _now;

  /// 提前重签余量(presigned 30min → 25min 即视为过期,避免拿到手就过期)。
  final Duration expiryMargin;
  final Duration fallbackTtl;
  final int capacityBytes;

  /// 条目默认字节权(URL 只存字符串;W3 #15:256KB→4KB,防千格夹整页预热
  /// 抖动驱逐,4KB≈2 万条)。
  final int defaultEntryBytes;

  final ThumbSignGate<SignedThumb> _gate;

  /// LinkedHashMap 保持插入序 = LRU 序(访问即挪尾,驱逐从头)。
  final _cache = <String, _Entry>{};
  final _inflight = <String, SignJob<SignedThumb>>{};
  int _totalBytes = 0;

  /// 签名闸代数(clear 自增;管线/预热捕获透传 abandonAwait/putBatch)。
  int get generation => _gate.generation;

  int get length => _cache.length;

  int get totalBytes => _totalBytes;

  /// 签名闸占槽数/排队数(T6 断言用)。
  @visibleForTesting
  int get debugGateActive => _gate.activeCount;

  @visibleForTesting
  int get debugGateQueued => _gate.queuedCount;

  @visibleForTesting
  int get debugGatePendingJobs => _gate.pendingJobCount;

  /// 取 assetId 的缩略图 URL:命中未过期直接回;过期/未命中走单飞签名(经闸)。
  Future<String> urlOf(String assetId) {
    final hit = _cache[assetId];
    if (hit != null && _now().isBefore(hit.expiresAt)) {
      _touch(assetId, hit);
      return Future.value(hit.url);
    }
    if (hit != null) _cache.remove(assetId); // 过期条目先逐出再重签
    final existing = _inflight[assetId];
    if (existing != null &&
        (existing.settled || existing.generation != _gate.generation)) {
      // 旧代/已终 inflight 过滤(成功/失败都按代清理的兜底面):不 join
      _inflight.remove(assetId);
    }
    final job = _inflight[assetId] ??= _openSign(assetId);
    return _gate.addWaiter(job).then((s) => s.url);
  }

  SignJob<SignedThumb> _openSign(String assetId) {
    final gen = _gate.generation;
    SignJob<SignedThumb>? job;
    job = _gate.open(
      assetId,
      () => _sign(assetId, gen),
      onSettled: () {
        // 根 future 成功/失败都按代清 _inflight(身份比对防误删 clear 后新单飞)
        final j = job;
        if (j != null && identical(_inflight[assetId], j)) {
          _inflight.remove(assetId);
        }
      },
    );
    return job;
  }

  Future<SignedThumb> _sign(String assetId, int gen) async {
    final s = await signer(assetId);
    if (gen != _gate.generation) {
      // clear 后旧代迟到完成:不落缓存(登出不残留旧会话 URL);
      // 同代放弃(abandonAwait)不受影响,仍落缓存供下次复用
      return s;
    }
    final expiresIn = s.expiresInSeconds;
    final Duration ttl;
    if (expiresIn <= 0) {
      ttl = fallbackTtl;
    } else {
      final t = Duration(seconds: expiresIn) - expiryMargin;
      if (t <= Duration.zero) return s; // 0<expiresIn≤margin:不缓存该条(省容量,等价立即过期)
      ttl = t;
    }
    _put(
      assetId,
      _Entry(
        url: s.url,
        expiresAt: _now().add(ttl),
        approxBytes: s.approxBytes ?? defaultEntryBytes,
      ),
    );
    return s;
  }

  /// 未命中未过期缓存的 assetId(宫格批量预热 W3 #16 过滤用;去重保序)。
  Iterable<String> missingOf(Iterable<String> assetIds) {
    final seen = <String>{};
    final out = <String>[];
    for (final id in assetIds) {
      if (!seen.add(id)) continue;
      final e = _cache[id];
      if (e == null || !_now().isBefore(e.expiresAt)) out.add(id);
    }
    return out;
  }

  /// 批量写入(宫格预热 W3 #15):TTL 语义与 [_sign] 一致——expiresIn≤0 落
  /// [fallbackTtl];0<expiresIn≤margin 不缓存该条。[expectedGeneration] 为
  /// 预热方发请求前捕获的代数,clear 后旧代整批丢弃。
  void putBatch(
    Iterable<({String assetId, String url, int expiresIn})> entries, {
    int? expectedGeneration,
  }) {
    if (expectedGeneration != null && expectedGeneration != _gate.generation) {
      return; // 跨代:整批丢弃(内存写无需慢闸)
    }
    for (final e in entries) {
      final Duration ttl;
      if (e.expiresIn <= 0) {
        ttl = fallbackTtl;
      } else {
        final t = Duration(seconds: e.expiresIn) - expiryMargin;
        if (t <= Duration.zero) continue;
        ttl = t;
      }
      _put(
        e.assetId,
        _Entry(
          url: e.url,
          expiresAt: _now().add(ttl),
          approxBytes: defaultEntryBytes,
        ),
      );
    }
  }

  /// 管线任务终态时经 abort 链同步调用:取消闸 race 计时器、无其他等待者则
  /// 归还闸槽、等待者以取消异常完成(底层 signer 继续跑,落缓存供下次复用)。
  /// [generation] 指 [ThumbnailCache].generation(签名闸代数,勿传磁盘代数);
  /// 带 clear 前旧代则 no-op。
  void abandonAwait(String assetId, {int? generation}) {
    _gate.abandon(assetId, generation: generation);
  }

  void _put(String assetId, _Entry e) {
    final old = _cache.remove(assetId);
    if (old != null) _totalBytes -= old.approxBytes;
    _cache[assetId] = e;
    _totalBytes += e.approxBytes;
    _evict();
  }

  void _touch(String assetId, _Entry e) {
    _cache.remove(assetId);
    _cache[assetId] = e;
  }

  /// ③ LRU:从头(最久未用)逐出,直到总量回到 [capacityBytes] 内;
  /// 单条超大(超容量)时不驱逐自身,避免永远取不到。
  void _evict() {
    while (_totalBytes > capacityBytes && _cache.length > 1) {
      final k = _cache.keys.first;
      _totalBytes -= _cache.remove(k)!.approxBytes;
    }
  }

  /// 测试/登出清空(W2 #11 写死):取消全部闸计时器、归零闸计数、所有 active
  /// waiter 以取消异常完成(waiter future 已挂内部 ignore 兜底)、清 _inflight/
  /// _cache、代数自增。
  void clear() {
    _gate.clear();
    _inflight.clear();
    _cache.clear();
    _totalBytes = 0;
  }
}
