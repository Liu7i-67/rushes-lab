/// me_sections — 「我的」页分组与状态行(§6 F12):
/// - [MeGroup]:SectionLabel + SectionCard 分组容器;
/// - [AppearanceRow]:偏好「外观」行(副标题=当前模式,打开设置面板);
/// - [MeLogoutRow]:红字退出登录行(确认逻辑在页面层);
/// - [BaiduBackupTile]/[TransferNotifyTile]:原 me_page 内的实时状态行,
///   行为不变,仅换成 AppRow 视觉。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/session.dart';
import '../../models/models.dart';
import '../../services/notifier.dart' show Notifier, openNotificationSettings;
import '../../theme/context_tk.dart';
import '../../theme/theme_controller.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_row.dart';
import '../../widgets/section_label.dart';
import 'settings_sheet.dart';

/// 分组:分组微标签 + 圆角组卡(组内 1px 分隔)。
class MeGroup extends StatelessWidget {
  const MeGroup({
    super.key,
    required this.title,
    required this.children,
    this.hint,
  });

  final String title;
  final String? hint;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(title: title, hint: hint),
        SectionCard(
          margin: const EdgeInsets.symmetric(horizontal: Tk.spacePage),
          dividerIndent: 48,
          children: children,
        ),
      ],
    );
  }
}

/// 偏好 · 外观:副标题实时显示当前模式;点按打开外观设置面板。
class AppearanceRow extends StatelessWidget {
  const AppearanceRow({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: themeController,
      builder: (context, _) => AppRow(
        key: const Key('me_appearance'),
        leading: const Icon(Icons.palette_outlined),
        title: '外观',
        subtitle: themeController.labelFor(
          MediaQuery.platformBrightnessOf(context),
        ),
        onTap: () => showAppearanceSheet(context),
      ),
    );
  }
}

/// 退出登录行:红字 + 整行 56 高;点击后由页面弹 danger 确认。
class MeLogoutRow extends StatelessWidget {
  const MeLogoutRow({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 56,
          child: Center(
            child: Text(
              '退出登录',
              style: TextStyle(
                fontSize: Tk.fzBody,
                fontWeight: FontWeight.w500,
                color: tk.danger,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 网盘备份入口行:开关关闭时置灰不可点按、显示「未启用」;开启时查询绑定
/// 状态(GET /baidu/backup/binding,404→未启用;查询异常→「状态未知」)。
class BaiduBackupTile extends StatefulWidget {
  const BaiduBackupTile({super.key});

  @override
  State<BaiduBackupTile> createState() => _BaiduBackupTileState();
}

class _BaiduBackupTileState extends State<BaiduBackupTile> {
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
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: AppRow(
        leading: const Icon(Icons.cloud_outlined),
        title: '网盘备份',
        subtitle: _subtitle,
        // 开关关闭:入口置灰(不可点按),chevron 一并隐藏
        onTap: enabled
            ? () async {
                await Navigator.of(context).pushNamed('/baidu');
                _load(); // 返回即刷新(绑定/解绑后入口行显示最新状态)
              }
            : null,
      ),
    );
  }
}

/// 传输通知授权状态行:实时查询系统通知授权;未开启 → 点击跳应用详情设置页,
/// 已开启纯展示;从设置授权回来(回前台)自动重查。
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
    final tk = context.tk;
    final enabled = _enabled;
    return AppRow(
      leading: const Icon(Icons.notifications_outlined),
      title: '传输通知',
      subtitle: switch (enabled) {
        null => '查询中…',
        true => '已开启,后台上传/下载完成可提醒',
        false => '未开启,收不到后台传输完成提醒',
      },
      trailing: enabled == true
          ? Text(
              '✓已开启',
              style: TextStyle(color: tk.ok, fontSize: Tk.fzMd),
            )
          : enabled == false
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '未开启',
                  style: TextStyle(color: tk.ink3, fontSize: Tk.fzMd),
                ),
                Icon(Icons.chevron_right, size: 18, color: tk.ink3),
              ],
            )
          : null,
      // 仅未开启可点(跳设置);已开启/查询中纯展示
      onTap: enabled == false ? _goSettings : null,
    );
  }
}
