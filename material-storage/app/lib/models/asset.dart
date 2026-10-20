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
