/// Folder — /api/v1/folders 契约(B2 补 subtree_file_count / my_can_* 全量)。
///
/// 契约钉子(方案 §11):`subtree_file_count` 仅 list 端点回填(单夹响应恒 0);
/// `my_can_*` 仅单夹详情 GET /folders/{id} 回填(列表/创建响应恒默认 False,勿消费)。
library;

class Folder {
  Folder({
    required this.id,
    required this.name,
    required this.parentFolderId,
    this.projectId,
    this.isSensitive = false,
    this.subtreeFileCount = 0,
    this.myCanView,
    this.myCanDownload,
    this.myCanUpload,
    this.myCanAdmin,
    this.myDeleteGrant,
  });

  factory Folder.fromJson(Map<String, dynamic> j) => Folder(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        parentFolderId: j['parent_folder_id'] as String?,
        projectId: j['project_id'] as String?,
        isSensitive: (j['is_sensitive'] ?? false) as bool,
        subtreeFileCount: (j['subtree_file_count'] ?? 0) as int,
        myCanView: j['my_can_view'] as bool?,
        myCanDownload: j['my_can_download'] as bool?,
        myCanUpload: j['my_can_upload'] as bool?,
        myCanAdmin: j['my_can_admin'] as bool?,
        myDeleteGrant: j['my_delete_grant'] as bool?,
      );

  final String id;
  final String name;
  final String? parentFolderId;

  /// 所属项目(FolderOut.project_id;B5 批量移动「项目固定」数据源)。
  final String? projectId;
  final bool isSensitive;

  /// 整棵子树(含本夹)活跃文件数 — 仅列表回填。
  final int subtreeFileCount;

  /// 单夹详情回填的当前用户权限;列表响应恒 False,只有详情取值可信(null=未拉详情)。
  final bool? myCanView;
  final bool? myCanDownload;
  final bool? myCanUpload;
  final bool? myCanAdmin;

  /// 组级「删除文件与文件夹」授权生效态 — 仅单夹详情回填(web folder.my_delete_grant
  /// 同源;回收站入口/删除闸门与 my_can_admin 取或;列表响应恒 False 勿消费)。
  final bool? myDeleteGrant;
}
