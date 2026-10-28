/// AdminHomePage — 管理后台入口(B8 功能点 1;方案 §8.9):二级页大标题 +
/// 2 列磁贴(用户/用户组/审计/权限模板/目录模板/备份任务/风控/使用统计)。
///
/// 闸门:页面本身仅 is_system_admin(我的页入口已闸;深链兜底二次判),
/// 目录模板例外闸门 `is_folder_template_manager ?? is_system_admin` 由
/// 我的页独立磁贴直达,不依赖本页。
library;

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/page_header.dart';
import 'admin_audit_page.dart';
import 'admin_baidu_tasks_page.dart';
import 'admin_folder_templates_page.dart';
import 'admin_grant_templates_page.dart';
import 'admin_groups_page.dart';
import 'admin_risk_page.dart';
import 'admin_usage_page.dart';
import 'admin_users_page.dart';

class AdminHomePage extends StatelessWidget {
  const AdminHomePage({super.key});

  void _open(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    // 深链兜底:非 system admin(web 各 Admin*Page 内嵌 Alert 同口径)
    if (!(session.me?.isSystemAdmin ?? false)) {
      return Scaffold(
        body: Column(
          children: [
            const PageHeader(back: true, title: '管理后台'),
            Expanded(
              child: EmptyState(
                icon: Icons.lock_outline,
                message: '只有系统管理员可以进入管理后台',
              ),
            ),
          ],
        ),
      );
    }
    final tiles = <_Tile>[
      _Tile(
        Icons.person_outline,
        '用户',
        '账号与角色',
        () => _open(context, const AdminUsersPage()),
      ),
      _Tile(
        Icons.groups_outlined,
        '用户组',
        '按团队授权',
        () => _open(context, const AdminGroupsPage()),
      ),
      _Tile(
        Icons.receipt_long_outlined,
        '审计日志',
        '关键操作留痕',
        () => _open(context, const AdminAuditPage()),
      ),
      _Tile(
        Icons.key_outlined,
        '授权模板',
        '常用权限预设',
        () => _open(context, const AdminGrantTemplatesPage()),
      ),
      _Tile(
        Icons.account_tree_outlined,
        '目录模板',
        '新建项目结构',
        () => _open(context, const AdminFolderTemplatesPage()),
      ),
      _Tile(
        Icons.cloud_outlined,
        '备份任务',
        '全站备份视图',
        () => _open(context, const AdminBaiduTasksPage()),
      ),
      // 风控模块(2026-10-28 §5.1):导航照既有磁贴 _open 直推 widget,不走 pushNamed
      _Tile(
        Icons.shield_outlined,
        '风控',
        '登录锁定处置',
        () => _open(context, const AdminRiskPage()),
      ),
      _Tile(
        Icons.insights,
        '使用统计',
        '三端与内外网占比',
        () => _open(context, const AdminUsagePage()),
      ),
    ];
    return Scaffold(
      body: Column(
        children: [
          const PageHeader(
            back: true,
            title: '管理后台',
            subtitle: '系统管理员 · 用户、用户组、审计与模板',
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // 2 列网格,卡间 10;窄屏(320)下仍两列,说明文案两行收尾
                final width =
                    (constraints.maxWidth - Tk.spacePage * 2 - 10) / 2;
                return ListView(
                  padding: const EdgeInsets.fromLTRB(
                    Tk.spacePage,
                    Tk.spaceLg,
                    Tk.spacePage,
                    Tk.space2xl,
                  ),
                  children: [
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        for (final t in tiles)
                          SizedBox(
                            width: width,
                            child: _TileCard(tile: t),
                          ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _TileCard extends StatelessWidget {
  const _TileCard({required this.tile});

  final _Tile tile;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return AppCard(
      onTap: tile.onTap,
      padding: const EdgeInsets.all(14),
      child: ConstrainedBox(
        // 最小内容高 76(+ 上下 14 内边距 + 1px 描边 ≈ 104 总高);
        // 系统字号放大 1.3 时随内容自然增高,不用固定高防裁切
        constraints: const BoxConstraints(minHeight: 76),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: tk.goldSoft,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(tile.icon, size: 20, color: tk.goldInk),
            ),
            const SizedBox(height: 10),
            Text(
              tile.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14.5,
                height: 1.3,
                fontWeight: FontWeight.w600,
                color: tk.ink,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              tile.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: tk.ink3),
            ),
          ],
        ),
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
