/// Me — /api/v1/auth/me 契约(auth.py 实际返回;B6 补三组级旗标)。
library;

class Me {
  Me({
    required this.id,
    required this.name,
    this.mustChangePassword = false,
    this.isSystemAdmin = false,
    this.baiduBackupEnabled = false,
    bool? isProjectCreator,
    bool? isProjectDeleter,
    bool? isArtistAccountCreator,
  })  : isProjectCreator = isProjectCreator ?? isSystemAdmin,
        isProjectDeleter = isProjectDeleter ?? isSystemAdmin,
        isArtistAccountCreator = isArtistAccountCreator ?? isSystemAdmin;

  factory Me.fromJson(Map<String, dynamic> j) {
    final sysAdmin = (j['is_system_admin'] ?? false) as bool;
    return Me(
      id: j['id'] as String,
      name: (j['name'] ?? '') as String,
      mustChangePassword: (j['must_change_password'] ?? false) as bool,
      isSystemAdmin: sysAdmin,
      baiduBackupEnabled: (j['baidu_backup_enabled'] ?? false) as bool,
      // 旧后端字段缺失回落 is_system_admin(web `?? is_system_admin` 同口径;
      // 现役后端恒回填,组级开关经 group#member 展开已并入字段值)。
      isProjectCreator: j['is_project_creator'] as bool?,
      isProjectDeleter: j['is_project_deleter'] as bool?,
      isArtistAccountCreator: j['is_artist_account_creator'] as bool?,
    );
  }

  final String id;
  final String name;

  /// 首登/重置后强制改密(§2 路由守卫闸门;后端仅在已设本地密码时为 true)。
  final bool mustChangePassword;

  /// 管理后台入口闸门(B 后续批用;我的页角色展示)。
  final bool isSystemAdmin;

  /// 百度网盘备份菜单显隐开关(B0① 入口置灰判断;关闭时后端 /baidu/* 统一 404)。
  final bool baiduBackupEnabled;

  /// 新建项目总闸门(B6;create_project 守门 require_project_creator 同口径:
  /// is_org_admin 或 组级 project_creator;构造时缺省回落 [isSystemAdmin])。
  final bool isProjectCreator;

  /// 已删除项目入口闸门(B6;deleted/restore 双端点 require_project_deleter
  /// 同口径;构造时缺省回落 [isSystemAdmin])。
  final bool isProjectDeleter;

  /// 内嵌开通艺人账号闸门(B6 新建项目表单区块显隐;构造时缺省回落
  /// [isSystemAdmin];username-available 预检守门是组合弱门,此处仅做显隐)。
  final bool isArtistAccountCreator;

  String get roleLabel => isSystemAdmin ? '系统管理员' : '成员';
}
