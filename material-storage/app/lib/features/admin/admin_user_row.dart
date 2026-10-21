/// 用户行(B8 功能点 2 拆件):状态徽标行 + 操作菜单(编辑/启停/重置密码/
/// 解锁——解锁仅 login_locked 行渲染,web W1 同口径);确认 → 调端点 →
/// toast/一次性密码回显 → 刷新;409/422 detail 透传。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/api/ms_api.dart';
import '../../core/fmt.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_confirm.dart';
import '../../widgets/badge.dart';
import '../../widgets/toast.dart';
import 'temp_password_sheet.dart';
import 'user_edit_sheet.dart';

class AdminUserRow extends StatelessWidget {
  const AdminUserRow({super.key, required this.user, required this.onChanged});

  final DirectoryUser user;
  final VoidCallback onChanged;

  Future<void> _openActions(BuildContext context) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('编辑'),
            onTap: () => Navigator.of(context).pop('edit'),
          ),
          if (user.isActive)
            ListTile(
              leading: const Icon(Icons.block_outlined),
              title: const Text('停用'),
              subtitle: const Text('撤销全部权限并禁止登录'),
              onTap: () => Navigator.of(context).pop('disable'),
            )
          else
            ListTile(
              leading: const Icon(Icons.check_circle_outline),
              title: const Text('启用'),
              onTap: () => Navigator.of(context).pop('enable'),
            ),
          ListTile(
            leading: const Icon(Icons.key_outlined),
            title: const Text('重置密码'),
            subtitle: const Text('生成新临时密码,仅回显一次'),
            onTap: () => Navigator.of(context).pop('reset'),
          ),
          if (user.loginLocked)
            ListTile(
              leading: const Icon(Icons.lock_open_outlined),
              title: const Text('解锁'),
              subtitle: const Text('清登录锁定与失败计数'),
              onTap: () => Navigator.of(context).pop('unlock'),
            ),
        ]),
      ),
    );
    if (action == null || !context.mounted) return;
    await _run(context, action);
  }

  /// 行操作执行(确认 → 调端点 → toast/回显 → 刷新;409/422 detail 透传)。
  Future<void> _run(BuildContext context, String action) async {
    final api = session.api!.directory;
    final name = user.name;
    try {
      switch (action) {
        case 'edit':
          final ok = await showEditUserSheet(context, user);
          if (!context.mounted) return;
          if (ok) {
            toast(context, '已保存 $name 的资料', tone: ToastTone.success);
            onChanged();
          }
        case 'disable':
          if (!await _confirm(
                  context, '停用 $name?', '其全部权限 tuple 将被撤销并禁止登录。') ||
              !context.mounted) {
            return;
          }
          await api.disableUser(user.id);
          if (!context.mounted) return;
          toast(context, '已停用 $name — 其全部权限已撤销', tone: ToastTone.success);
          onChanged();
        case 'enable':
          if (!await _confirm(
                  context, '启用 $name?', '恢复登录与组织/组内权限 tuple。') ||
              !context.mounted) {
            return;
          }
          await api.enableUser(user.id);
          if (!context.mounted) return;
          toast(context, '已重新启用 $name', tone: ToastTone.success);
          onChanged();
        case 'reset':
          if (!await _confirm(context, '重置 $name 的密码?',
                  '将生成新的临时密码,首登强制改密;顺带清除登录锁定。') ||
              !context.mounted) {
            return;
          }
          final pw = await api.resetPassword(user.id);
          if (!context.mounted) return;
          await showTempPasswordSheet(context,
              password: pw, title: '新临时密码');
          onChanged();
        case 'unlock':
          if (!await _confirm(context, '解锁 $name 的登录锁定?',
                  '清除用户名维度锁定与失败计数,并连带清近 24h 失败 IP 的锁;'
                  '完成后即可重新登录。') ||
              !context.mounted) {
            return;
          }
          final r = await api.unlockUser(user.id);
          if (!context.mounted) return;
          toast(
              context,
              r.wasLocked
                  ? '已解锁 $name(清 ${r.clearedUserForms.length} 个登录名形态 / '
                      '${r.clearedIps.length} 个 IP 锁)'
                  : '$name 当前无登录锁,已顺手清理失败计数',
              tone: ToastTone.success);
          onChanged();
      }
    } on ApiException catch (e) {
      if (!context.mounted) return;
      toast(context, e.message, tone: ToastTone.error); // 409 已禁用/已启用等透传
    } catch (e) {
      if (!context.mounted) return;
      toast(context, errorMessage(e, '操作失败,请稍后重试'), tone: ToastTone.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = user.email;
    final subtitle = StringBuffer(user.username ?? '—');
    if (email != null && email.isNotEmpty) subtitle.write(' · $email');
    subtitle.write(' · 创建于 ${fmtDate(user.createdAt)}');
    return ListTile(
      title: Row(
        children: [
          Flexible(
            child:
                Text(user.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 6),
          if (!user.isActive)
            const Badge(label: '停用', tone: BadgeTone.red)
          else if (user.mustChangePassword)
            const Badge(label: '待改密', tone: BadgeTone.amber),
          if (user.loginLocked)
            const Padding(
              padding: EdgeInsets.only(left: Tk.spaceXs),
              child: Badge(label: '登录已锁定', tone: BadgeTone.red),
            ),
        ],
      ),
      subtitle: Text(subtitle.toString(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: Tk.fzXs)),
      trailing: const Icon(Icons.more_horiz),
      onTap: () => _openActions(context),
    );
  }
}

/// 操作确认(F3 收口 showAppConfirm):取消 false / 遮罩关闭 null 均 = false,
/// 与原 `ok ?? false` 口径一致;四个调用点(停用/启用/重置密码/解锁)均非危险态。
Future<bool> _confirm(BuildContext context, String title, String content) =>
    showAppConfirm(context, title: title, content: content)
        .then((ok) => ok ?? false);
