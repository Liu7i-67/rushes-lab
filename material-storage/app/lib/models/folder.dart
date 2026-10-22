/// Folder — /api/v1/folders 契约(B2 补 subtree_file_count / my_can_* 全量)。
///
/// 契约钉子(方案 §11):`subtree_file_count` / `direct_file_count` 仅 list
/// 端点回填(单夹响应恒 0);`my_can_*` 仅单夹详情 GET /folders/{id} 回填
/// (列表/创建响应恒默认 False,勿消费)。
library;

class Folder {
  Folder({
    required this.id,
    required this.name,
    required this.parentFolderId,
    this.projectId,
    this.isSensitive = false,
    this.subtreeFileCount = 0,
    this.directFileCount = 0,
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
        directFileCount: (j['direct_file_count'] ?? 0) as int,
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

  /// 本夹直属(不含子树)活跃文件数 — 仅列表端点回填(单夹响应恒 0)。
  ///
  /// 2026-10-22 K1(真机反馈 #1):主数字「N 项」按直属展示,子树数降为
  /// 「子级 M 项」弱提示。旧后端兼容:响应缺 `direct_file_count` 键时按 0
  /// 解析 → 直属空但有子树文件的夹会显示「子级 M 项」(而非旧「M 项」),
  /// 不再误导,可接受。
  final int directFileCount;

  /// 单夹详情回填的当前用户权限;列表响应恒 False,只有详情取值可信(null=未拉详情)。
  final bool? myCanView;
  final bool? myCanDownload;
  final bool? myCanUpload;
  final bool? myCanAdmin;

  /// 组级「删除文件与文件夹」授权生效态 — 仅单夹详情回填(web folder.my_delete_grant
  /// 同源;回收站入口/删除闸门与 my_can_admin 取或;列表响应恒 False 勿消费)。
  final bool? myDeleteGrant;
}

/// FolderMemberRow — GET /folders/{id}/members 行(sensitive 邀请成员;B6)。
/// expires_at 后端由 tuple condition 反推,可能缺省。
class FolderMemberRow {
  FolderMemberRow({
    required this.subject,
    required this.kind,
    required this.subjectId,
    required this.name,
    required this.level,
    required this.permanent,
    this.expiresAt,
  });

  factory FolderMemberRow.fromJson(Map<String, dynamic> j) => FolderMemberRow(
        subject: j['subject'] as String,
        kind: j['kind'] as String,
        subjectId: j['subject_id'] as String,
        name: j['name'] as String?,
        level: j['level'] as String,
        permanent: (j['permanent'] ?? true) as bool,
        expiresAt: j['expires_at'] as String?,
      );

  /// 完整 OpenFGA subject(`user:<uuid>` / `group:<gid>#member`);撤销入参原样回传。
  final String subject;
  final String kind; // user / group / department(遗留)
  final String subjectId;
  final String? name; // 后端 resolve_subject_names 解析,未命中走 id 兜底
  final String level; // viewer / downloader
  final bool permanent; // true=invited(永久);false=explicit_invited(临时)
  final String? expiresAt; // ISO 时间;永久恒 null
}

/// FolderGrantRow — GET /folders/{id}/grants 行(普通一级夹 explicit grant;B6)。
class FolderGrantRow {
  FolderGrantRow({
    required this.subject,
    required this.kind,
    required this.subjectId,
    required this.name,
    required this.level,
  });

  factory FolderGrantRow.fromJson(Map<String, dynamic> j) => FolderGrantRow(
        subject: j['subject'] as String,
        kind: j['kind'] as String,
        subjectId: j['subject_id'] as String,
        name: j['name'] as String?,
        level: j['level'] as String,
      );

  final String subject;
  final String kind; // user / group / department(遗留)
  final String subjectId;
  final String? name;
  final String level; // viewer / downloader / uploader(恒永久,无有效期)
}
