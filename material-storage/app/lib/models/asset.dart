/// Asset — /api/v1/assets 契约(现役平移;tags/user_labels/notes 后续批补)。
library;

class Asset {
  Asset({
    required this.id,
    required this.filename,
    required this.sizeBytes,
    this.contentType,
    required this.createdAt,
  });

  factory Asset.fromJson(Map<String, dynamic> j) => Asset(
        id: j['id'] as String,
        filename: (j['filename'] ?? '') as String,
        sizeBytes: (j['size_bytes'] ?? 0) as num,
        contentType: j['content_type'] as String?,
        createdAt: (j['created_at'] ?? '') as String,
      );

  final String id;
  final String filename;
  final num sizeBytes;
  final String? contentType;
  final String createdAt;

  bool get isLivp => filename.toLowerCase().endsWith('.livp');
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
