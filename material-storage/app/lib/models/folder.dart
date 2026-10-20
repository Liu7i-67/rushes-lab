/// Folder — /api/v1/folders?project_id= 契约(现役平移)。
library;

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
