/// ThumbPrewarm — 宫格批量预热缩略图 URL 编排(app-thumbnail-storm-fix W3 #16):
/// 列表页数据落地后对当前页/增量页过滤「有 thumbnail_key 且缓存未命中」的
/// 资产 → 捕获签名闸代数 → 分批 ≤100 → assets.thumbnailUrls 批量签名 →
/// putBatch(带代数)。失败静默(AppLog 留痕):不自动重试、不做负缓存,
/// missing 项由格子进入视野时单发兜底(签名闸限流)。
/// thumb-variant 批 D1:全链带 [ThumbVariant] 维度——missingOf/putBatch 的
/// URL 缓存键与批量签名 body(small 时带 `"size": "small"`)按 variant 隔离;
/// 调用点(assets_page 两挂点)预热 small 与宫格 cell 同规格。
library;

import '../../core/session.dart';
import '../../core/thumb_variant.dart';
import '../../core/thumbnail_cache.dart';
import '../../models/models.dart';
import '../../services/app_log.dart';

/// 单批上限(后端 pydantic 约束 1..100)。
const int kThumbPrewarmBatchSize = 100;

/// 只预热 URL 不预下载字节;async + 最外层 catch(session.api == null 等同步
/// 异常一并兜住),任何失败不影响页面。[variant] 默认 large;宫格挂点传
/// [ThumbVariant.small](与 cell 取数同规格,避免预热 large URL 白签)。
Future<void> prewarmThumbUrls(
  List<Asset> items, {
  ThumbVariant variant = ThumbVariant.large,
}) async {
  try {
    final api = session.api;
    if (api == null) return;
    final candidates = items
        .where((a) => a.hasThumbnail)
        .map((a) => a.id)
        .toList(growable: false);
    final missing = thumbnailCache
        .missingOf(candidates, variant: variant)
        .toList(growable: false);
    if (missing.isEmpty) return;
    final gen = thumbnailCache.generation; // 发请求前捕获,putBatch 透传
    for (var i = 0; i < missing.length; i += kThumbPrewarmBatchSize) {
      final batch = missing.sublist(
        i,
        i + kThumbPrewarmBatchSize > missing.length
            ? missing.length
            : i + kThumbPrewarmBatchSize,
      );
      // 批量签名 body:small 时带 `"size": "small"`(core 内映射;large 不带
      // 该字段保持现行为)。URL 缓存键/写入条目按 variant 隔离。
      final r = await api.assets.thumbnailUrls(batch, size: variant.apiSize);
      thumbnailCache.putBatch(
        [
          for (final e in r.byId.entries)
            (assetId: e.key, url: e.value.url, expiresIn: e.value.expiresIn),
        ],
        expectedGeneration: gen,
        variant: variant,
      );
    }
  } catch (e) {
    // 预热失败静默(D2):不进报错页;URL 缓存未命中的格子走单发兜底
    AppLog.error('thumb-prewarm', '批量预热失败(静默)', e);
  }
}
