/// Asset — /api/v1/assets 契约(B2 补 tags/user_labels/notes/folder_id)。
///
/// 契约核对(2026-10-20,api/app/models/__init__.py AssetOut):**无 duration 字段**
/// → 视频时长角标无数据源,本批不做;tags 为自由 dict(worker 写入 thumbnail_key /
/// live_video_key),`tags.thumbnail_key` 存在才可请求 thumbnail-url。
library;

class Asset {
  Asset({
    required this.id,
    required this.filename,
    required this.sizeBytes,
    this.contentType,
    required this.createdAt,
    this.folderId,
    this.deletedAt,
    this.tags = const {},
    this.userLabels = const [],
    this.notes,
  });

  factory Asset.fromJson(Map<String, dynamic> j) => Asset(
        id: j['id'] as String,
        filename: (j['filename'] ?? '') as String,
        sizeBytes: (j['size_bytes'] ?? 0) as num,
        contentType: j['content_type'] as String?,
        createdAt: (j['created_at'] ?? '') as String,
        folderId: j['folder_id'] as String?,
        deletedAt: j['deleted_at'] as String?,
        // 测试夹具/JSON 解码可能给 Map<dynamic,dynamic>,cast 宽进
        tags: (j['tags'] as Map?)?.cast<String, dynamic>() ?? const {},
        userLabels: ((j['user_labels'] ?? const []) as List)
            .map((e) => e as String)
            .toList(),
        notes: j['notes'] as String?,
      );

  final String id;
  final String filename;
  final num sizeBytes;
  final String? contentType;
  final String createdAt;
  final String? folderId;

  /// 软删时间:普通列表恒 null,回收站列表有值(AssetOut.deleted_at)。
  final String? deletedAt;

  /// worker 元数据:thumbnail_key(1024px 缩略图)/ live_video_key(livp 实况短片)。
  final Map<String, dynamic> tags;
  final List<String> userLabels;
  final String? notes;

  bool get isLivp => filename.toLowerCase().endsWith('.livp');

  /// worker 已生成缩略图(存在才允许请求 thumbnail-url,否则端点 404)。
  bool get hasThumbnail => (tags['thumbnail_key'] as String? ?? '').isNotEmpty;

  // 注:曾有的 hasLiveVideo(tags.live_video_key 判定)B2 修复 P2-7 删除——
  // 全仓零消费(livp 实况走 live-preview-url,后端 404 即静态图兜底);
  // B4 需要时再按消费点加回。
}

/// /api/v1/assets?folder_id&limit&offset → {items,total}
class AssetPage {
  AssetPage({required this.items, required this.total});

  factory AssetPage.fromJson(Map<String, dynamic> j) => AssetPage(
        items: ((j['items'] ?? const []) as List)
            .map((e) => Asset.fromJson(e as Map<String, dynamic>))
            .toList(),
        total: (j['total'] ?? 0) as num,
      );

  final List<Asset> items;
  final num total;
}

/// /api/v1/assets/trash?folder_id&limit&offset → {items,total}
/// (items=软删分页窗口,total=全量计数;AssetOut.deleted_at 有值)。
class TrashPage {
  TrashPage({required this.items, required this.total});

  factory TrashPage.fromJson(Map<String, dynamic> j) => TrashPage(
        items: ((j['items'] ?? const []) as List)
            .map((e) => Asset.fromJson(e as Map<String, dynamic>))
            .toList(),
        total: (j['total'] ?? 0) as num,
      );

  final List<Asset> items;
  final num total;
}

/// POST /assets/batch-prefix 结果(BatchPrefixReasonsOut 键固定 ASCII,前端
/// 中文映射照 web SKIPPED_REASON_LABEL;对账恒等式 renamed+skipped=提交数)。
class AssetBatchPrefixResult {
  AssetBatchPrefixResult({
    required this.renamed,
    required this.skipped,
    this.skippedReasons = const {},
  });

  factory AssetBatchPrefixResult.fromJson(Map<String, dynamic> j) =>
      AssetBatchPrefixResult(
        renamed: (j['renamed'] ?? 0) as int,
        skipped: (j['skipped'] ?? 0) as int,
        skippedReasons:
            ((j['skipped_reasons'] ?? const {}) as Map).cast<String, int>(),
      );

  final int renamed;
  final int skipped;

  /// 跳过原因计数(too_long/no_match/already_prefixed/empty_result/deleted/
  /// key_conflict/key_copy_failed);汇总 toast 中文映射用。
  final Map<String, int> skippedReasons;

  /// skipped_reasons 键 → 中文(web BatchPrefixModal 同映射;未知键回落 raw)。
  static String reasonLabel(String key) =>
      const {
        'too_long': '加后超长',
        'no_match': '前缀不匹配',
        'already_prefixed': '已带该前缀',
        'empty_result': '去后为空',
        'deleted': '已删除/不存在',
        'key_conflict': '新名存储位置被占',
        'key_copy_failed': '存储端复制失败',
      }[key] ?? key;
}

/// POST /assets/batch-move 单条跳过(理由固定 ASCII,前端中文映射)。
class AssetBatchMoveSkip {
  AssetBatchMoveSkip({required this.assetId, required this.reason});

  factory AssetBatchMoveSkip.fromJson(Map<String, dynamic> j) =>
      AssetBatchMoveSkip(
        assetId: j['asset_id'] as String,
        reason: (j['reason'] ?? '') as String,
      );

  final String assetId;
  final String reason;

  /// reason → 中文(web BatchMoveAssetsModal SKIP_REASON_LABEL;未知回落 raw)。
  static String reasonLabel(String reason) =>
      const {
        'duplicate_location': '已在目标位置',
        'duplicate_filename': '目标已有同名文件',
        'deleted': '已删除/不存在',
      }[reason] ?? reason;
}

/// POST /assets/batch-move 结果:对账 moved + skipped + fga_pending = 提交数
/// (fga_pending=DB 已迁入但 OpenFGA parent 元组交换失败,系统自动重试)。
class AssetBatchMoveResult {
  AssetBatchMoveResult({
    required this.movedCount,
    this.skipped = const [],
    this.fgaPending = const [],
  });

  factory AssetBatchMoveResult.fromJson(Map<String, dynamic> j) =>
      AssetBatchMoveResult(
        movedCount: (j['moved_count'] ?? 0) as int,
        skipped: ((j['skipped'] ?? const []) as List)
            .map((e) =>
                AssetBatchMoveSkip.fromJson(e as Map<String, dynamic>))
            .toList(),
        fgaPending: ((j['fga_pending'] ?? const []) as List)
            .map((e) => e as String)
            .toList(),
      );

  final int movedCount;
  final List<AssetBatchMoveSkip> skipped;
  final List<String> fgaPending;
}

/// GET /assets/search 行(B7 §8.8;SearchResultOut = AssetOut + 归属 enrich:
/// folder_name / project_id / project_name)。asset 本体完整可复用
/// (缩略图门槛 tags.thumbnail_key、预览跳转 folder_id 均在)。
class SearchResult {
  SearchResult({
    required this.asset,
    required this.folderName,
    required this.projectId,
    required this.projectName,
  });

  factory SearchResult.fromJson(Map<String, dynamic> j) => SearchResult(
        asset: Asset.fromJson(j),
        folderName: (j['folder_name'] ?? '') as String,
        projectId: j['project_id'] as String,
        projectName: (j['project_name'] ?? '') as String,
      );

  final Asset asset;
  final String folderName;
  final String projectId;
  final String projectName;

  /// 预览页路径段(下载任务归属显示)。
  String get where => '$projectName/$folderName';
}
