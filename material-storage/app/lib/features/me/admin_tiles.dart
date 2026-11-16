/// 管理区入口(B8 §8.9;墨金 WP2 视觉):管理后台仅 is_system_admin;
/// 目录模板独立闸门 `is_folder_template_manager ?? is_system_admin`(Me 构造
/// 已回落);「用户」独立闸门 `is_user_manager ?? is_system_admin`(用户模块
/// 组级授权开放,仅对非 admin 补独立入口——admin 走管理后台,不重复放行)。
/// 无权限返回空,me_page 整组不渲染。
library;

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../widgets/app_row.dart';

List<Widget> adminSectionTiles(BuildContext context) {
  final me = session.me;
  if (me == null) return const [];
  final showAdminHome = me.isSystemAdmin;
  final showFolderTemplates = me.isFolderTemplateManager;
  // 用户模块组级授权开放:被授权非 admin 仅见「用户」入口(F5 菜单弱门;
  // 用户组/审计等其余管理入口仍仅管理员,D8/D9)。
  final showUsers = !showAdminHome && me.isUserManager;
  if (!showAdminHome && !showFolderTemplates && !showUsers) return const [];
  return [
    if (showAdminHome)
      AppRow(
        leading: const Icon(Icons.admin_panel_settings_outlined),
        goldIcon: true,
        title: '管理后台',
        subtitle: '用户 / 用户组 / 审计 / 权限模板 / 备份任务',
        onTap: () => Navigator.of(context).pushNamed('/admin'),
      ),
    if (showUsers)
      AppRow(
        leading: const Icon(Icons.person_outline),
        goldIcon: true,
        title: '用户',
        subtitle: '查看自己创建的用户 / 新建用户 / 重置密码',
        onTap: () => Navigator.of(context).pushNamed('/admin/users'),
      ),
    if (showFolderTemplates)
      AppRow(
        leading: const Icon(Icons.account_tree_outlined),
        goldIcon: true,
        title: '目录模板',
        subtitle: showAdminHome ? '新建项目一键建立目录树' : '目录结构预设(你的组有管理权限)',
        onTap: () => Navigator.of(context).pushNamed('/admin/folder-templates'),
      ),
  ];
}
