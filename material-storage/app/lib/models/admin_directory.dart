/// 管理后台目录域出参契约(B8;api/app/routers/directory.py 实码):
/// 用户列表/建号(一次性临时密码)/详情/组列表(五组级 flag)/组成员。
library;

/// DirectoryUserOut(用户列表行;login_locked 仅 user 维度回显,W1)。
class DirectoryUser {
  DirectoryUser({
    required this.id,
    required this.username,
    required this.name,
    required this.email,
    required this.isActive,
    required this.mustChangePassword,
    required this.createdAt,
    this.resignedAt,
    this.loginLocked = false,
  });

  factory DirectoryUser.fromJson(Map<String, dynamic> j) => DirectoryUser(
        id: j['id'] as String,
        username: j['username'] as String?,
        name: (j['name'] ?? '') as String,
        email: j['email'] as String?,
        isActive: (j['is_active'] ?? false) as bool,
        mustChangePassword: (j['must_change_password'] ?? false) as bool,
        createdAt: (j['created_at'] ?? '') as String,
        resignedAt: j['resigned_at'] as String?,
        loginLocked: (j['login_locked'] ?? false) as bool,
      );

  final String id;
  final String? username;
  final String name;
  final String? email;
  final bool isActive;
  final bool mustChangePassword;
  final String createdAt;
  final String? resignedAt;

  /// 连续登录失败触发的 user 维度锁定(仅回显;IP 维度不在此列)。
  final bool loginLocked;
}

/// DirectoryUsersPageOut(分页包装;total=同条件 count 不含 limit/offset)。
class DirectoryUsersPage {
  DirectoryUsersPage({required this.items, required this.total});

  factory DirectoryUsersPage.fromJson(Map<String, dynamic> j) =>
      DirectoryUsersPage(
        items: ((j['items'] ?? const []) as List)
            .map((e) => DirectoryUser.fromJson(e as Map<String, dynamic>))
            .toList(),
        total: (j['total'] ?? 0) as int,
      );

  final List<DirectoryUser> items;
  final int total;
}

/// UserCreateOut(建号 201 响应;temporary_password 只回显这一次,
/// 不落 audit/log——展示后不持有)。
class DirectoryUserCreated extends DirectoryUser {
  DirectoryUserCreated({
    required super.id,
    required super.username,
    required super.name,
    required super.email,
    required super.isActive,
    required super.mustChangePassword,
    required super.createdAt,
    super.resignedAt,
    super.loginLocked,
    required this.temporaryPassword,
  });

  factory DirectoryUserCreated.fromJson(Map<String, dynamic> j) =>
      DirectoryUserCreated(
        id: j['id'] as String,
        username: j['username'] as String?,
        name: (j['name'] ?? '') as String,
        email: j['email'] as String?,
        isActive: (j['is_active'] ?? false) as bool,
        mustChangePassword: (j['must_change_password'] ?? false) as bool,
        createdAt: (j['created_at'] ?? '') as String,
        resignedAt: j['resigned_at'] as String?,
        loginLocked: (j['login_locked'] ?? false) as bool,
        temporaryPassword: (j['temporary_password'] ?? '') as String,
      );

  final String temporaryPassword;
}

/// DirectoryUserDetailOut(详情:基础字段 + 所属组 ids/names 同序,按组名排序)。
class DirectoryUserDetail extends DirectoryUser {
  DirectoryUserDetail({
    required super.id,
    required super.username,
    required super.name,
    required super.email,
    required super.isActive,
    required super.mustChangePassword,
    required super.createdAt,
    super.resignedAt,
    super.loginLocked,
    required this.groupIds,
    required this.groupNames,
  });

  factory DirectoryUserDetail.fromJson(Map<String, dynamic> j) =>
      DirectoryUserDetail(
        id: j['id'] as String,
        username: j['username'] as String?,
        name: (j['name'] ?? '') as String,
        email: j['email'] as String?,
        isActive: (j['is_active'] ?? false) as bool,
        mustChangePassword: (j['must_change_password'] ?? false) as bool,
        createdAt: (j['created_at'] ?? '') as String,
        resignedAt: j['resigned_at'] as String?,
        loginLocked: (j['login_locked'] ?? false) as bool,
        groupIds: ((j['group_ids'] ?? const []) as List).map((e) => e as String).toList(),
        groupNames: ((j['group_names'] ?? const []) as List)
            .map((e) => e as String)
            .toList(),
      );

  final List<String> groupIds;
  final List<String> groupNames;
}

/// DirectoryGroupOut(组列表行;五组级 flag 按 FGA tuple 真实态回显)。
class DirectoryGroup {
  DirectoryGroup({
    required this.id,
    required this.name,
    required this.description,
    required this.memberCount,
    required this.createdAt,
    this.canCreateProject = false,
    this.canDeleteProject = false,
    this.canManageFolderTemplates = false,
    this.canCreateArtistAccount = false,
    this.canDeleteFiles = false,
  });

  factory DirectoryGroup.fromJson(Map<String, dynamic> j) => DirectoryGroup(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        description: j['description'] as String?,
        memberCount: (j['member_count'] ?? 0) as int,
        createdAt: (j['created_at'] ?? '') as String,
        canCreateProject: (j['can_create_project'] ?? false) as bool,
        canDeleteProject: (j['can_delete_project'] ?? false) as bool,
        canManageFolderTemplates:
            (j['can_manage_folder_templates'] ?? false) as bool,
        canCreateArtistAccount: (j['can_create_artist_account'] ?? false) as bool,
        canDeleteFiles: (j['can_delete_files'] ?? false) as bool,
      );

  final String id;
  final String name;
  final String? description;
  final int memberCount;
  final String createdAt;
  final bool canCreateProject;
  final bool canDeleteProject;
  final bool canManageFolderTemplates;
  final bool canCreateArtistAccount;
  final bool canDeleteFiles;
}

/// GroupMemberOut(组内成员行)。
class GroupMember {
  GroupMember({
    required this.userId,
    required this.username,
    required this.name,
    required this.email,
    required this.isActive,
  });

  factory GroupMember.fromJson(Map<String, dynamic> j) => GroupMember(
        userId: j['user_id'] as String,
        username: j['username'] as String?,
        name: (j['name'] ?? '') as String,
        email: j['email'] as String?,
        isActive: (j['is_active'] ?? false) as bool,
      );

  final String userId;
  final String? username;
  final String name;
  final String? email;
  final bool isActive;
}
