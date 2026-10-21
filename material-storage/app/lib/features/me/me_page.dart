/// 我的页(B1 骨架,§2/§6):账号信息行 + 账号与安全(改密)+ 项目管理
/// (B6:回收站(项目),仅 is_project_deleter 可见)+ 诊断(日志推送)+
/// 当前服务入口(只读,内网/公网标识)+ 退出登录。B0 批挂载:网盘备份区
/// (features/baidu/bind_code_page.dart)。B4:B0 落盘 PoC 入口移除(使命完成,
/// 正式实现=下载线落盘矩阵,决策 #1)。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/badge.dart';
import 'log_push.dart';

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
              const _SectionLabel('账号与安全'),
              ListTile(
                leading: const Icon(Icons.password_outlined),
                title: const Text('修改密码'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () =>
                    Navigator.of(context).pushNamed('/change-password',
                        arguments: false),
              ),
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
                title: Text(session.entryLabel.isEmpty
                    ? '(探测中)'
                    : session.entryLabel),
                subtitle: Text(
                  session.baseUrl ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Badge(label: '只读'),
              ),
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: FilledButton.tonal(
                  style: FilledButton.styleFrom(
                    foregroundColor: Tk.red,
                  ),
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
              await Navigator.of(context).pushNamed('/baidu-bind');
              _load(); // 返回即刷新(绑定成功后入口行显示已绑定状态)
            }
          : null,
    );
  }
}
