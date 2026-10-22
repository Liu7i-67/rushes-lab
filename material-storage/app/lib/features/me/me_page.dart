/// 我的页(B1 骨架,§2/§6):账号信息行 + 账号与安全(改密)+ 协作(B7:
/// 审批中心/通知/我的权限)+ 项目管理(B6:回收站(项目),仅 is_project_deleter
/// 可见)+ 网盘备份(B9)+ 传输(R4a:传输通知授权状态行)+ 诊断(日志推送)
/// + 当前服务入口(只读,内网/公网标识)+ 关于(版本号/检查更新,仅 Android
/// 显示检查入口)+ 退出登录。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/session.dart';
import '../../main.dart' show kAppBuildStamp;
import '../../models/models.dart';
import '../../services/notifier.dart' show Notifier, openNotificationSettings;
import '../../theme/tokens.dart';
import '../../widgets/badge.dart';
import 'admin_tiles.dart';
import 'collab_tiles.dart';
import 'log_push.dart';
import 'update_tile.dart';

class MePage extends StatelessWidget {
  const MePage({super.key});

  Future<void> _logout(BuildContext context) async {
    await session.logout();
    if (!context.mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/', (r) => false);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: session,
      builder: (context, _) {
        final me = session.me;
        return Scaffold(
          appBar: AppBar(title: const Text('我的')),
          body: ListView(
            children: [
              // ── 账号信息 ──
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: Tk.accentFaint,
                  foregroundColor: Tk.accentStrong,
                  child: Text(
                    me == null || me.name.isEmpty
                        ? '?'
                        : me.name.characters.first,
                  ),
                ),
                title: Text(me?.name ?? '(未登录)'),
                subtitle: Text(me?.roleLabel ?? ''),
              ),
              // P6:构建 stamp(打包注入,新包核验锚点自项目页标题迁此);
              // 本地 run/test 未注入为空 → 整行不渲染
              if (buildStampLabel(kAppBuildStamp) != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Text(
                    buildStampLabel(kAppBuildStamp)!,
                    style: const TextStyle(color: Tk.subtle, fontSize: 12),
                  ),
                ),
              const _SectionLabel('账号与安全'),
              ListTile(
                leading: const Icon(Icons.password_outlined),
                title: const Text('修改密码'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () =>
                    Navigator.of(context)
                        .pushNamed('/change-password', arguments: false),
              ),
              // B8:管理区(§8.9)——管理后台仅 is_system_admin;目录模板独立
              // 闸门 is_folder_template_manager(持 flag 非 admin 仅见此入口)。
              ...adminSectionTiles(context),
              // B7:协作区(审批中心 badge 仅 admin;通知红点=全局未读)
              const _SectionLabel('协作'),
              // badge 从严:仅 is_system_admin 挂待审数(§8.6 钉子;
              // 入口人人可见——scope=self「我发起的」对普通用户有效)
              ApprovalsTile(badgeEnabled: me?.isSystemAdmin ?? false),
              const NotificationsTile(),
              const MyPermissionsTile(),
              // B6:已删除项目回收站(恢复);仅 is_project_deleter 可见
              // (后端 deleted/restore 双端点 require_project_deleter 同口径)
              if (me?.isProjectDeleter ?? false)
                ListTile(
                  leading: const Icon(Icons.delete_sweep_outlined),
                  title: const Text('回收站(项目)'),
                  subtitle: const Text('已删除项目的恢复入口'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () =>
                      Navigator.of(context).pushNamed('/deleted-projects'),
                ),
              const _SectionLabel('网盘备份'),
              const _BaiduBackupTile(),
              // R4a(mobile-ux-polish-2):传输通知授权状态行(实时查询,
              // 未开启点击直达系统设置,跳前不再弹引导框)
              const _SectionLabel('传输'),
              const TransferNotifyTile(),
              const _SectionLabel('诊断'),
              ListTile(
                leading: const Icon(Icons.bug_report_outlined),
                title: const Text('日志推送到企业微信'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showLogPushDialog(context),
              ),
              const _SectionLabel('当前服务'),
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: Text(
                  session.entryLabel.isEmpty ? '(探测中)' : session.entryLabel,
                ),
                subtitle: Text(
                  session.baseUrl ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Badge(label: '只读'),
              ),
              // feat/app-qiniu-update F2-1:版本号全平台展示;「检查更新」仅
              // Android(D6),手动检查反馈与下载安装流程见 core/update/
              const _SectionLabel('关于'),
              const UpdateCheckTile(),
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: FilledButton.tonal(
                  style: FilledButton.styleFrom(foregroundColor: Tk.red),
                  onPressed: () => _logout(context),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('退出登录'),
                  ),
                ),
              ),
              const SizedBox(height: 24),
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

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.title);

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

/// 网盘备份入口行(占位,B9 做完整页):开关关闭时置灰不可点按、显示「未启用」
/// (功能点 8 字面口径;后端 /baidu/* 对关闭部署统一 404);开启时查询绑定状态
/// (GET /baidu/backup/binding,404→未启用;查询异常→「状态未知」≠未启用),
/// 绑定后显示账号。
class _BaiduBackupTile extends StatefulWidget {
  const _BaiduBackupTile();

  @override
  State<_BaiduBackupTile> createState() => _BaiduBackupTileState();
}

class _BaiduBackupTileState extends State<_BaiduBackupTile> {
  BaiduBindingInfo? _status;
  bool _loaded = false;
  bool _failed = false;

  bool get _enabled => session.me?.baiduBackupEnabled ?? false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_enabled) return;
    try {
      final s = await session.api!.baidu.bindingStatus();
      if (mounted) {
        setState(() {
          _status = s;
          _loaded = true;
          _failed = false;
        });
      }
    } catch (_) {
      // 查询失败 ≠ 未启用:显示「状态未知」与开关关闭区分;入口仍可点按
      if (mounted) {
        setState(() {
          _loaded = true;
          _failed = true;
        });
      }
    }
  }

  String get _subtitle {
    if (!_enabled) return '未启用';
    if (_failed) return '状态未知,点按进入后重试';
    if (_loaded && _status == null) return '未启用';
    if (_status == null) return '…';
    if (_status!.bound) return '已绑定:${_status!.displayName}';
    return _status!.status == 'expired' ? '绑定已失效,点按重新绑定' : '未绑定';
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _enabled;
    return ListTile(
      leading: const Icon(Icons.cloud_outlined),
      title: const Text('网盘备份'),
      subtitle: Text(_subtitle),
      // 开关关闭:入口置灰(disabled,不可点按),chevron 一并隐藏
      trailing: enabled ? const Icon(Icons.chevron_right) : null,
      enabled: enabled,
      onTap: enabled
          ? () async {
              // B9:完整用户侧页(绑定状态+任务列表+新建任务;绑定页页内进入)
              await Navigator.of(context).pushNamed('/baidu');
              _load(); // 返回即刷新(绑定/解绑后入口行显示最新状态)
            }
          : null,
    );
  }
}

/// R4a(mobile-ux-polish-2):传输通知授权状态行(「我的」页)。
/// 实时查询系统通知授权(Android 13+ 真实反映;低版本/查询失败恒视为已开启,
/// 降级不误报);未开启 → 点击跳应用详情设置页(跳前不再弹引导框,口径见需求
/// 文档 R4a),已开启纯展示不可点。从设置授权回来(回前台)自动重查。
/// [query]/[openSettings] 注入供单测(生产用 Notifier / 系统设置跳转默认实现)。
class TransferNotifyTile extends StatefulWidget {
  const TransferNotifyTile({super.key, this.query, this.openSettings});

  /// 授权态查询(null=Notifier.queryPermission 真实查询)。
  final Future<bool> Function()? query;

  /// 跳设置动作(null=openNotificationSettings 真实跳转)。
  final Future<void> Function()? openSettings;

  @override
  State<TransferNotifyTile> createState() => _TransferNotifyTileState();
}

class _TransferNotifyTileState extends State<TransferNotifyTile>
    with WidgetsBindingObserver {
  /// null=查询中;true=已开启(纯展示);false=未开启(点击跳设置)。
  bool? _enabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 「去设置」授权回来 → 回前台实时重查(页内无路由返回事件可挂)
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final enabled =
        await (widget.query?.call() ?? Notifier.I.queryPermission());
    if (mounted) setState(() => _enabled = enabled);
  }

  Future<void> _goSettings() async {
    await (widget.openSettings?.call() ?? openNotificationSettings());
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _enabled;
    return ListTile(
      leading: const Icon(Icons.notifications_outlined),
      title: const Text('传输通知'),
      subtitle: Text(switch (enabled) {
        null => '查询中…',
        true => '已开启,后台上传/下载完成可提醒',
        false => '未开启,收不到后台传输完成提醒',
      }),
      trailing: enabled == true
          ? const Text(
              '✓已开启',
              style: TextStyle(color: Tk.green),
            )
          : enabled == false
              ? const Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('未开启', style: TextStyle(color: Tk.subtle)),
                  Icon(Icons.chevron_right, color: Tk.subtle),
                ])
              : null,
      // 仅未开启可点(跳设置,跳前不再弹引导框);已开启/查询中纯展示
      onTap: enabled == false ? _goSettings : null,
    );
  }
}
