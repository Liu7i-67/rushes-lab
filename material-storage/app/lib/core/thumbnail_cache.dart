/// ThumbnailCache — 缩略图 presigned URL 缓存纯逻辑(B2 §8.1 宫格,可单测):
/// ① URL+过期时间内存缓存,临期自动重签(后端签 30min,留 5min 余量,web 同哲学);
/// ② 同 assetId 并发去重(单飞,并发调用共享同一次签名请求);
/// ③ LRU 驱逐:条目按近似字节计权,总量超 [capacityBytes] 时从最久未用开始逐出
///    (约 80MB 上限;每条默认按 1024px JPEG ≈ 256KB 估算,签名方未给实际大小时用)。
///
/// 只管 URL 不持有位图字节;Image 网络解码缓存交给 Flutter ImageCache。
library;

class SignedThumb {
  SignedThumb({required this.url, this.expiresInSeconds = 1800, this.approxBytes});

  final String url;
  final int expiresInSeconds;

  /// 签名方可回报条目近似大小;null 用缓存默认估算。
  final int? approxBytes;
}

typedef ThumbSigner = Future<SignedThumb> Function(String assetId);

class _Entry {
  _Entry({required this.url, required this.expiresAt, required this.approxBytes});

  final String url;
  final DateTime expiresAt;
  final int approxBytes;
}

class ThumbnailCache {
  ThumbnailCache({
    required this.signer,
    DateTime Function()? now,
    this.expiryMargin = const Duration(minutes: 5),
    this.fallbackTtl = const Duration(minutes: 25),
    this.capacityBytes = 80 * 1024 * 1024,
    this.defaultEntryBytes = 256 * 1024,
  }) : _now = now ?? DateTime.now;

  final ThumbSigner signer;
  final DateTime Function() _now;

  /// 提前重签余量(presigned 30min → 25min 即视为过期,避免拿到手就过期)。
  final Duration expiryMargin;
  final Duration fallbackTtl;
  final int capacityBytes;
  final int defaultEntryBytes;

  /// LinkedHashMap 保持插入序 = LRU 序(访问即挪尾,驱逐从头)。
  final _cache = <String, _Entry>{};
  final _inflight = <String, Future<String>>{};

  int get length => _cache.length;

  int get totalBytes =>
      _cache.values.fold(0, (sum, e) => sum + e.approxBytes);

  /// 取 assetId 的缩略图 URL:命中未过期直接回;过期/未命中走单飞签名。
  Future<String> urlOf(String assetId) {
    final hit = _cache[assetId];
    if (hit != null && _now().isBefore(hit.expiresAt)) {
      _touch(assetId, hit);
      return Future.value(hit.url);
    }
    if (hit != null) _cache.remove(assetId); // 过期条目先逐出再重签
    final existing = _inflight[assetId];
    if (existing != null) return existing; // ② 并发去重
    final f = _sign(assetId);
    _inflight[assetId] = f;
    return f;
  }

  Future<String> _sign(String assetId) async {
    try {
      final s = await signer(assetId);
      final ttl = s.expiresInSeconds > 0
          ? Duration(seconds: s.expiresInSeconds) - expiryMargin
          : fallbackTtl;
      final ttl0 = ttl.isNegative ? Duration.zero : ttl;
      _put(
        assetId,
        _Entry(
          url: s.url,
          expiresAt: _now().add(ttl0),
          approxBytes: s.approxBytes ?? defaultEntryBytes,
        ),
      );
      return s.url;
    } finally {
      _inflight.remove(assetId);
    }
  }

  void _put(String assetId, _Entry e) {
    _cache.remove(assetId);
    _cache[assetId] = e;
    _evict();
  }

  void _touch(String assetId, _Entry e) {
    _cache.remove(assetId);
    _cache[assetId] = e;
  }

  /// ③ LRU:从头(最久未用)逐出,直到总量回到 [capacityBytes] 内;
  /// 单条超大(超容量)时不驱逐自身,避免永远取不到。
  void _evict() {
    while (totalBytes > capacityBytes && _cache.length > 1) {
      _cache.remove(_cache.keys.first);
    }
  }

  /// 测试/登出清空。
  void clear() {
    _cache.clear();
    _inflight.clear();
  }
}
