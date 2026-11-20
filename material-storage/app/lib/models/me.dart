/// Me — /api/v1/auth/me 契约(auth.py 实际返回;B6 补三组级旗标,
/// B8 补 is_folder_template_manager 管理入口例外闸门;
/// 用户模块组级授权开放补 is_user_manager + user_create_groups;
/// phone-bind 批补 phone 可空解析,旧后端无此字段回落 null=未绑定)。
library;

import 'user.dart';

class Me {
  Me({
    required this.id,
    required this.name,
    this.mustChangePassword = false,
    this.isSystemAdmin = false,
    this.baiduBackupEnabled = false,
    this.phone,
    bool? isProjectCreator,
    bool? isProjectDeleter,
    bool? isArtistAccountCreator,
    bool? isFolderTemplateManager,
    bool? isUserManager,
    this.userCreateGroups = const [],
  }) : isProjectCreator = isProjectCreator ?? isSystemAdmin,
       isProjectDeleter = isProjectDeleter ?? isSystemAdmin,
       isArtistAccountCreator = isArtistAccountCreator ?? isSystemAdmin,
       isFolderTemplateManager = isFolderTemplateManager ?? isSystemAdmin,
       isUserManager = isUserManager ?? isSystemAdmin;

  factory Me.fromJson(Map<String, dynamic> j) {
    final sysAdmin = (j['is_system_admin'] ?? false) as bool;
    return Me(
      id: j['id'] as String,
      name: (j['name'] ?? '') as String,
      mustChangePassword: (j['must_change_password'] ?? false) as bool,
      isSystemAdmin: sysAdmin,
      baiduBackupEnabled: (j['baidu_backup_enabled'] ?? false) as bool,
      // 手机号(可空;null=未绑定或旧后端无此字段,web `phone?: string | null`
      // 同口径,SPA/App 先于 API 上线不炸)。
      phone: j['phone'] as String?,
      // 旧后端字段缺失回落 is_system_admin(web `?? is_system_admin` 同口径;
      // 现役后端恒回填,组级开关经 group#member 展开已并入字段值)。
      isProjectCreator: j['is_project_creator'] as bool?,
      isProjectDeleter: j['is_project_deleter'] as bool?,
      isArtistAccountCreator: j['is_artist_account_creator'] as bool?,
      // B8:目录模板入口独立闸门(web AppHeader `?? is_system_admin` 同口径;
      // auth.py 恒回填,持组 flag 非 admin 亦为 true;缺省回落 sysAdmin)。
      isFolderTemplateManager: j['is_folder_template_manager'] as bool?,
      // 用户模块组级授权开放(2026-11-15 方案 §5.4):「用户」入口闸门
      // (web `(me.is_user_manager ?? me.is_system_admin)` 同口径;admin 恒
      // true;缺省回落 sysAdmin 照 isFolderTemplateManager 先例)。
      isUserManager: j['is_user_manager'] as bool?,
      // 非 admin 被授权时 = 新建用户可选的目标组集合(含名称);admin 恒 []
      // (admin 走 directory groups 接口取全量选项;缺省 [] 照 web `?? []`)。
      userCreateGroups: [
        for (final g in (j['user_create_groups'] ?? const []) as List)
          GroupBrief(
            id: (g as Map<String, dynamic>)['id'] as String,
            name: (g['name'] ?? '') as String,
          ),
      ],
    );
  }

  final String id;
  final String name;

  /// 首登/重置后强制改密(§2 路由守卫闸门;后端仅在已设本地密码时为 true)。
  final bool mustChangePassword;

  /// 管理后台入口闸门(B8 管理区;我的页角色展示)。
  final bool isSystemAdmin;

  /// 百度网盘备份菜单显隐开关(B0① 入口置灰判断;关闭时后端 /baidu/* 统一 404)。
  final bool baiduBackupEnabled;

  /// 绑定手机号(完整号展示 D13;null=未绑定,旧后端无此字段亦 null)。
  final String? phone;

  /// 新建项目总闸门(B6;create_project 守门 require_project_creator 同口径:
  /// is_org_admin 或 组级 project_creator;构造时缺省回落 [isSystemAdmin])。
  final bool isProjectCreator;

  /// 已删除项目入口闸门(B6;deleted/restore 双端点 require_project_deleter
  /// 同口径;构造时缺省回落 [isSystemAdmin])。
  final bool isProjectDeleter;

  /// 内嵌开通艺人账号闸门(B6 新建项目表单区块显隐;构造时缺省回落
  /// [isSystemAdmin];username-available 预检守门是组合弱门,此处仅做显隐)。
  final bool isArtistAccountCreator;

  /// 目录模板入口独立闸门(B8;`is_folder_template_manager ?? is_system_admin`
  /// web 同口径;持组 flag 非 admin 仅见目录模板入口,见不到其余管理子页)。
  final bool isFolderTemplateManager;

  /// 「用户」模块入口闸门(用户模块组级授权开放;admin 恒 true,非 admin =
  /// 持 user_create_grants 授权组成员;构造时缺省回落 [isSystemAdmin])。
  final bool isUserManager;

  /// 非 admin 被授权时新建用户可选的目标组集合(含名称;admin 恒 [],
  /// admin 建号表单走 directory groups 接口取全量选项)。
  final List<GroupBrief> userCreateGroups;

  String get roleLabel => isSystemAdmin ? '系统管理员' : '成员';
}
