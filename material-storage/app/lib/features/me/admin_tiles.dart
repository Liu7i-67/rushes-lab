/// 管理区磁贴(B8 功能点 1;方案 §8.9 我的页「管理」区):
/// - 管理后台:仅 is_system_admin(六子页入口页);
/// - 目录模板:独立闸门 `is_folder_template_manager ?? is_system_admin`
///   (Me 构造已回落;持组 flag 非 admin 仅见目录模板入口,进 App 看不到其余
///   管理子页——web AppHeader 同口径)。
library;

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../theme/tokens.dart';

/// 我的页「管理」区条目(插入在账号与安全之后;无权限时整区不渲染)。
List<Widget> adminSectionTiles(BuildContext context) {
  final me = session.me;
  if (me == null) return const [];
  final showAdminHome = me.isSystemAdmin;
  // Me.isFolderTemplateManager 已按 `?? is_system_admin` 回填,单字段即闸门
  final showFolderTemplates = me.isFolderTemplateManager;
  if (!showAdminHome && !showFolderTemplates) return const [];
  return [
    const _AdminSectionLabel('管理'),
    if (showAdminHome)
      ListTile(
        leading: const Icon(Icons.admin_panel_settings_outlined),
        title: const Text('管理后台'),
        subtitle: const Text('用户 / 用户组 / 审计 / 权限模板 / 备份任务'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).pushNamed('/admin'),
      ),
    if (showFolderTemplates)
      ListTile(
        leading: const Icon(Icons.account_tree_outlined),
        title: const Text('目录模板'),
        subtitle: showAdminHome
            ? const Text('新建项目一键建立目录树')
            : const Text('目录结构预设(你的组有管理权限)'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).pushNamed('/admin/folder-templates'),
      ),
  ];
}

class _AdminSectionLabel extends StatelessWidget {
  const _AdminSectionLabel(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: const TextStyle(
          color: Tk.subtle,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
