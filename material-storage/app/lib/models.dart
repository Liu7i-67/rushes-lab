/// 后端契约模型(与 web/src/api/types.ts 对齐的 MVP 子集)。
/// 仅保留 MVP 三功能(登录 / 浏览 / livp 上传下载)用到的字段。
library;

class Me {
  Me({
    required this.id,
    required this.name,
    this.mustChangePassword = false,
  });

  factory Me.fromJson(Map<String, dynamic> j) => Me(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        mustChangePassword: (j['must_change_password'] ?? false) as bool,
      );

  final String id;
  final String name;
  final bool mustChangePassword;
}

class Project {
  Project({required this.id, required this.name, required this.code});

  factory Project.fromJson(Map<String, dynamic> j) => Project(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        code: (j['code'] ?? '') as String,
      );

  final String id;
  final String name;
  final String code;
}

class Folder {
  Folder({
    required this.id,
    required this.name,
    required this.parentFolderId,
    this.isSensitive = false,
    this.myCanUpload,
  });

  factory Folder.fromJson(Map<String, dynamic> j) => Folder(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        parentFolderId: j['parent_folder_id'] as String?,
        isSensitive: (j['is_sensitive'] ?? false) as bool,
        myCanUpload: j['my_can_upload'] as bool?,
      );

  final String id;
  final String name;
  final String? parentFolderId;
  final bool isSensitive;
  final bool? myCanUpload;
}

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
