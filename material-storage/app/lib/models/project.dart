/// Project — /api/v1/projects 契约(B2 补 my_roles;B5 补 is_pinned;素材计数后端无此字段)。
library;

class Project {
  Project({
    required this.id,
    required this.name,
    required this.code,
    this.myRoles = const [],
    this.isPinned = false,
  });

  factory Project.fromJson(Map<String, dynamic> j) => Project(
    id: j['id'] as String,
    name: (j['name'] ?? '') as String,
    code: (j['code'] ?? '') as String,
    myRoles: ((j['my_roles'] ?? const []) as List)
        .map((e) => e as String)
        .toList(),
    // B5 置顶:bool 字段按 `bool? ?? false` 直取(缺省 false 兼容旧后端;
    // 非字符串字段,不涉「?? fallback 不盖空串」通式坑)。
    isPinned: (j['is_pinned'] as bool?) ?? false,
  );

  final String id;
  final String name;
  final String code;

  /// 当前 user 在本项目的有效角色('admin'|'uploader'|'downloader'|'viewer');
  /// 空 = 仅靠 visibility=public 可见(「仅访客」)。
  final List<String> myRoles;

  /// 当前 user 对本项目的置顶标记(B5;/projects 排序置顶优先;旧后端无此
  /// 字段时缺省 false,用户私有偏好互相独立)。
  final bool isPinned;
}

// ─── B6:项目管理(契约=routers/projects.py + models/__init__.py 实码)────────

/// initial_grants 行(ProjectCreateIn.initial_grants 条目;权限模板展开后的
/// 提交形状:主体二选一 kind+id + roles 非空,去重与固定序由后端做)。
class GrantEntry {
  const GrantEntry({required this.kind, required this.id, required this.roles});

  final String kind; // user / group
  final String id; // users.id / groups.id UUID
  final List<String> roles; // PROJECT_ROLES 子集,非空

  Map<String, dynamic> toJson() => {'kind': kind, 'id': id, 'roles': roles};
}

/// ArtistAccountCreated — 内嵌建号一次性回显(仅 POST /projects 201 响应体;
/// temporary_password 不落 audit/log,只展示这一次,方案 D10)。
class ArtistAccountCreated {
  ArtistAccountCreated({
    required this.userId,
    required this.username,
    required this.name,
    required this.temporaryPassword,
  });

  factory ArtistAccountCreated.fromJson(Map<String, dynamic> j) =>
      ArtistAccountCreated(
        userId: j['user_id'] as String,
        username: j['username'] as String,
        name: j['name'] as String,
        temporaryPassword: j['temporary_password'] as String,
      );

  final String userId;
  final String username;
  final String name;
  final String temporaryPassword;
}

/// ProjectCreated — POST /projects 201 响应(ProjectOut 子集 + artist_account)。
class ProjectCreated {
  ProjectCreated({
    required this.id,
    required this.name,
    required this.code,
    this.artistAccount,
  });

  factory ProjectCreated.fromJson(Map<String, dynamic> j) => ProjectCreated(
    id: j['id'] as String,
    name: (j['name'] ?? '') as String,
    code: (j['code'] ?? '') as String,
    artistAccount: j['artist_account'] == null
        ? null
        : ArtistAccountCreated.fromJson(
            j['artist_account'] as Map<String, dynamic>,
          ),
  );

  final String id;
  final String name;
  final String code;
  final ArtistAccountCreated? artistAccount;
}

/// ProjectMember — GET /projects/{id}/members 行(同主体多角色聚合)。
class ProjectMember {
  ProjectMember({
    required this.subject,
    required this.kind,
    required this.subjectId,
    required this.name,
    required this.roles,
  });

  factory ProjectMember.fromJson(Map<String, dynamic> j) => ProjectMember(
    subject: j['subject'] as String,
    kind: j['kind'] as String,
    subjectId: j['subject_id'] as String,
    name: j['name'] as String?,
    roles: ((j['roles'] ?? const []) as List).map((e) => e as String).toList(),
  );

  final String subject; // 完整 subject,撤销入参原样回传
  final String kind; // user / group / department(遗留)
  final String subjectId;
  final String? name;
  final List<String> roles; // admin/uploader/downloader/viewer
}

/// ProjectGrantRow — GET /projects/{id}/grants 行(#138 授权总览:审批/邀请
/// 获得的 explicit/invited grant;DELETE 四元组入参齐全)。
class ProjectGrantRow {
  ProjectGrantRow({
    required this.subject,
    required this.kind,
    required this.subjectId,
    required this.name,
    required this.objectType,
    required this.objectId,
    required this.objectName,
    required this.relation,
    required this.level,
    required this.permanent,
    this.expiresAt,
  });

  factory ProjectGrantRow.fromJson(Map<String, dynamic> j) => ProjectGrantRow(
    subject: j['subject'] as String,
    kind: j['kind'] as String,
    subjectId: j['subject_id'] as String,
    name: j['name'] as String?,
    objectType: j['object_type'] as String,
    objectId: j['object_id'] as String,
    objectName: j['object_name'] as String?,
    relation: j['relation'] as String,
    level: j['level'] as String,
    permanent: (j['permanent'] ?? true) as bool,
    expiresAt: j['expires_at'] as String?,
  );

  final String subject;
  final String kind;
  final String subjectId;
  final String? name;
  final String objectType; // project / folder / sensitive_folder
  final String objectId;
  final String? objectName; // null = object 已删,展示走类型兜底
  final String relation; // 撤回白名单内的 relation
  final String level; // view / download / upload
  final bool permanent;
  final String? expiresAt;
}

/// DeletedProject — GET /projects/deleted 行(F6.5;visibility 仅展示)。
class DeletedProject {
  DeletedProject({
    required this.id,
    required this.code,
    required this.name,
    required this.deletedAt,
    this.description,
    this.deletedByName,
  });

  factory DeletedProject.fromJson(Map<String, dynamic> j) => DeletedProject(
    id: j['id'] as String,
    code: (j['code'] ?? '') as String,
    name: (j['name'] ?? '') as String,
    description: j['description'] as String?,
    deletedAt: (j['deleted_at'] ?? '') as String,
    deletedByName: j['deleted_by_name'] as String?,
  );

  final String id;
  final String code;
  final String name;
  final String? description;

  /// 删除时间(ISO;列表按 deleted_at 倒序)。
  final String deletedAt;

  /// 操作人 users.name(操作人已物理删除时为 null)。
  final String? deletedByName;
}

/// DeletedProjectsPage — 服务端分页窗口(items=当前页,total=全量计数)。
class DeletedProjectsPage {
  DeletedProjectsPage({required this.items, required this.total});

  factory DeletedProjectsPage.fromJson(Map<String, dynamic> j) =>
      DeletedProjectsPage(
        items: ((j['items'] ?? const []) as List)
            .map((e) => DeletedProject.fromJson(e as Map<String, dynamic>))
            .toList(),
        total: (j['total'] ?? 0) as int,
      );

  final List<DeletedProject> items;
  final int total;
}
