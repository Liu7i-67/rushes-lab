/// AdminHomePage — 管理后台入口(B8 功能点 1;方案 §8.9):六子页磁贴
/// (用户/用户组/审计/权限模板/目录模板/备份任务)。
///
/// 闸门:页面本身仅 is_system_admin(我的页入口已闸;深链兜底二次判),
/// 目录模板例外闸门 `is_folder_template_manager ?? is_system_admin` 由
/// 我的页独立磁贴直达,不依赖本页。
library;

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../theme/tokens.dart';
import '../../widgets/empty_state.dart';
import 'admin_audit_page.dart';
import 'admin_baidu_tasks_page.dart';
import 'admin_folder_templates_page.dart';
import 'admin_grant_templates_page.dart';
import 'admin_groups_page.dart';
import 'admin_users_page.dart';

class AdminHomePage extends StatelessWidget {
  const AdminHomePage({super.key});

  void _open(BuildContext context, Widget page) {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    // 深链兜底:非 system admin(web 各 Admin*Page 内嵌 Alert 同口径)
    if (!(session.me?.isSystemAdmin ?? false)) {
      return Scaffold(
        appBar: AppBar(title: const Text('管理')),
        body: const EmptyState(
            icon: Icons.lock_outline, message: '只有系统管理员可以进入管理后台'),
      );
    }
    final tiles = <_Tile>[
      _Tile(
        Icons.person_outline,
        '用户',
        '本地账号创建 / 停用 / 重置密码 / 解锁',
        () => _open(context, const AdminUsersPage()),
      ),
      _Tile(
        Icons.groups_outlined,
        '用户组',
        '组 CRUD + 成员管理 + 组级开关',
        () => _open(context, const AdminGroupsPage()),
      ),
      _Tile(
        Icons.receipt_long_outlined,
        '审计',
        '全量行为日志 / 筛选 / CSV 导出',
        () => _open(context, const AdminAuditPage()),
      ),
      _Tile(
        Icons.rule_outlined,
        '权限模板',
        '授权预设 + 应用默认(存量项目批量刷新)',
        () => _open(context, const AdminGrantTemplatesPage()),
      ),
      _Tile(
        Icons.account_tree_outlined,
        '目录模板',
        '新建项目一键建立目录树',
        () => _open(context, const AdminFolderTemplatesPage()),
      ),
      _Tile(
        Icons.cloud_upload_outlined,
        '备份任务',
        '全系统百度备份任务只读观测',
        () => _open(context, const AdminBaiduTasksPage()),
      ),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('管理')),
      body: ListView.builder(
        itemCount: tiles.length,
        itemBuilder: (context, i) {
          final t = tiles[i];
          return ListTile(
            leading: Icon(t.icon, color: Tk.accent),
            title: Text(t.title),
            subtitle: Text(t.subtitle,
                style: const TextStyle(fontSize: 12, color: Tk.muted)),
            trailing: const Icon(Icons.chevron_right),
            onTap: t.onTap,
          );
        },
      ),
    );
  }
}

class _Tile {
  const _Tile(this.icon, this.title, this.subtitle, this.onTap);

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
}
