/// 我的页(§6 F12;WP2 拆分后只保留编排/状态):PageHeader 大标题 +
/// 设置入口;身份卡(me_header_card);分组顺序:协作 → 网盘与传输 → 偏好 →
/// 管理 → 账号与安全 → 诊断 → 关于(me_sections 提供分组容器/外观行/
/// 退出登录行/实时状态行)。所有闸门与实时查询逻辑保持原行为。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/haptics.dart';
import '../../core/session.dart';
import '../../main.dart' show kAppBuildStamp;
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_confirm.dart';
import '../../widgets/app_row.dart';
import '../../widgets/badge.dart';
import '../../widgets/page_header.dart';
import 'admin_tiles.dart';
import 'collab_tiles.dart';
import 'log_push.dart';
import 'me_header_card.dart';
import 'me_sections.dart';
import 'settings_sheet.dart';
import 'update_tile.dart';

export 'me_sections.dart' show BaiduBackupTile, TransferNotifyTile;

class MePage extends StatelessWidget {
  const MePage({super.key});

  Future<void> _logout(BuildContext context) async {
    // 退出登录前弹确认(danger);取消/遮罩不登出
    final ok = await showAppConfirm(
      context,
      title: '退出登录?',
      content: '退出后需重新登录才能继续使用。',
      confirmLabel: '退出',
      danger: true,
    );
    if (ok != true || !context.mounted) return;
    Haptics.impact(); // 危险确认瞬间
    await session.logout();
    if (!context.mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/', (r) => false);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: session,
      builder: (context, _) {
        final tk = context.tk;
        final me = session.me;
        final adminTiles = adminSectionTiles(context);
        final stamp = buildStampLabel(kAppBuildStamp);
        return Scaffold(
          body: ListView(
            padding: const EdgeInsets.only(bottom: Tk.spaceXl),
            children: [
              PageHeader(
                title: '我的',
                actions: [
                  IconButton(
                    tooltip: '设置',
                    icon: const Icon(Icons.settings_outlined),
                    onPressed: () => showAppearanceSheet(context),
                  ),
                ],
              ),
              MeHeaderCard(me: me),
              // P6:构建 stamp(打包注入;本地 run/test 未注入为空 → 不渲染)
              if (stamp != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Tk.spacePage,
                    0,
                    Tk.spacePage,
                    Tk.spaceSm,
                  ),
                  child: Text(
                    stamp,
                    style: TextStyle(fontSize: Tk.fzSm, color: tk.ink3),
                  ),
                ),
              MeGroup(
                title: '协作',
                children: [
                  // badge 从严:仅 is_system_admin 挂待审数(入口人人可见)
                  ApprovalsTile(badgeEnabled: me?.isSystemAdmin ?? false),
                  const NotificationsTile(),
                  const MyPermissionsTile(),
                  if (me?.isProjectDeleter ?? false)
                    AppRow(
                      leading: const Icon(Icons.delete_sweep_outlined),
                      title: '回收站(项目)',
                      subtitle: '已删除项目的恢复入口',
                      onTap: () =>
                          Navigator.of(context).pushNamed('/deleted-projects'),
                    ),
                ],
              ),
              const MeGroup(
                title: '网盘与传输',
                children: [BaiduBackupTile(), TransferNotifyTile()],
              ),
              const MeGroup(title: '偏好', children: [AppearanceRow()]),
              // B8:管理区——管理后台仅 is_system_admin;目录模板独立闸门
              if (adminTiles.isNotEmpty)
                MeGroup(title: '管理', children: adminTiles),
              MeGroup(
                title: '账号与安全',
                children: [
                  AppRow(
                    leading: const Icon(Icons.password_outlined),
                    title: '修改密码',
                    onTap: () =>
                        Navigator.of(context)
                            .pushNamed('/change-password', arguments: false),
                  ),
                  MeLogoutRow(onTap: () => _logout(context)),
                ],
              ),
              MeGroup(
                title: '诊断',
                children: [
                  AppRow(
                    leading: const Icon(Icons.bug_report_outlined),
                    title: '日志推送到企业微信',
                    onTap: () => showLogPushDialog(context),
                  ),
                  AppRow(
                    leading: const Icon(Icons.dns_outlined),
                    title: session.entryLabel.isEmpty
                        ? '(探测中)'
                        : session.entryLabel,
                    subtitle: session.baseUrl ?? '',
                    trailing: const Badge(label: '只读'),
                  ),
                ],
              ),
              // 关于:版本号全平台展示;「检查更新」仅 Android(D6)
              const MeGroup(title: '关于', children: [UpdateCheckTile()]),
            ],
          ),
        );
      },
    );
  }
}

/// P6:构建 stamp 行文案;未注入(空)返回 null → 整行不渲染。
/// 独立纯函数便于单测(test 环境恒空 stamp,无法经环境变量注入)。
@visibleForTesting
String? buildStampLabel(String stamp) => stamp.isEmpty ? null : '构建 $stamp';
