/// Me — /api/v1/auth/me 契约(auth.py 实际返回,B1 消费子集;
/// 其余字段 open_id/email/各权限旗标按需后续补)。
library;

class Me {
  Me({
    required this.id,
    required this.name,
    this.mustChangePassword = false,
    this.isSystemAdmin = false,
    this.baiduBackupEnabled = false,
  });

  factory Me.fromJson(Map<String, dynamic> j) => Me(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        mustChangePassword: (j['must_change_password'] ?? false) as bool,
        isSystemAdmin: (j['is_system_admin'] ?? false) as bool,
        baiduBackupEnabled: (j['baidu_backup_enabled'] ?? false) as bool,
      );

  final String id;
  final String name;

  /// 首登/重置后强制改密(§2 路由守卫闸门;后端仅在已设本地密码时为 true)。
  final bool mustChangePassword;

  /// 管理后台入口闸门(B 后续批用;我的页角色展示)。
  final bool isSystemAdmin;

  /// 百度网盘备份菜单显隐开关(B0① 入口置灰判断;关闭时后端 /baidu/* 统一 404)。
  final bool baiduBackupEnabled;

  String get roleLabel => isSystemAdmin ? '系统管理员' : '成员';
}
