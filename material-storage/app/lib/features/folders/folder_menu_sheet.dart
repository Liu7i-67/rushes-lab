/// FolderMenuSheet — 文件夹「⋯」菜单(F7:单层动作面板,标题=夹名、
/// 行=AppRow 图标金/普通、危险项红)。闸门数据源=单夹详情(列表响应
/// my_can_* 恒 False;开菜单时拉一次、各动作共用),口径保持 B6/B9 实况。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart' show errorMessage;
import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_confirm.dart';
import '../../widgets/app_row.dart';
import '../../widgets/sheet_scaffold.dart';
import '../../widgets/toast.dart';
import '../assets/trash_page.dart' show canSeeTrash;
import '../share/request_link_sheet.dart';
import 'folder_form_sheet.dart';
import 'folder_grants_sheet.dart';
import 'folder_invite_sheet.dart';
import 'move_folder_sheet.dart';

/// ⋯ 菜单(对外 API 不变):闸门=单夹详情,开菜单时拉一次、各动作行共用。
void showFolderMenu(BuildContext context, {required Folder folder}) {
  showAppSheet<void>(
    context: context,
    title: folder.name,
    child: _FolderMenuSheet(folder: folder),
  );
}

class _FolderMenuSheet extends StatefulWidget {
  const _FolderMenuSheet({required this.folder});

  final Folder folder;

  @override
  State<_FolderMenuSheet> createState() => _FolderMenuSheetState();
}

class _FolderMenuSheetState extends State<_FolderMenuSheet> {
  /// 单夹详情一次性拉取(initState 取一次;build 内新建会反复重发)。
  late final Future<Folder> _detail = session.api!.folders.get(
    widget.folder.id,
  );

  /// 弹动作 sheet 前先收掉菜单。
  void _close() => Navigator.of(context).pop();

  Future<void> _delete(Folder d) async {
    final ok = await showAppConfirm(
      context,
      title: '删除文件夹「${d.name}」?',
      content:
          '仅可删除空文件夹(子文件夹、文件需先删光,回收站也须彻底清空)。'
          '删除为永久删除、不可恢复。',
      confirmLabel: '删除',
      danger: true,
    );
    if (ok != true) return;
    try {
      await session.api!.foldersOps.delete(d.id);
      RefreshBus.I.invalidate('folders');
      if (!mounted) return;
      _close();
      toast(context, '文件夹已删除', tone: ToastTone.success);
    } catch (e) {
      if (!mounted) return;
      // 非空 409 / 无权 403 detail 透传(「请先删除其中所有文件」等)
      toast(context, '删除失败:${errorMessage(e, '请稍后重试')}', tone: ToastTone.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Folder>(
      future: _detail,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return _menuSkeleton(context);
        }
        final d = snap.data;
        if (d == null) return const SizedBox.shrink();
        final rows = <Widget>[
          _row(
            icon: Icons.create_new_folder_outlined,
            title: '新建子文件夹',
            enabled: d.myCanUpload ?? false,
            hint: '需文件夹上传权限',
            gold: true,
            onTap: () {
              _close();
              showFolderFormSheet(
                context,
                mode: FolderFormMode.createChild,
                projectId: d.projectId ?? '',
                parentFolderId: d.id,
                parentLabel: d.name,
              );
            },
          ),
          _row(
            icon: Icons.drive_file_rename_outline,
            title: '重命名',
            enabled: (d.isSensitive ? d.myCanAdmin : d.myCanUpload) ?? false,
            hint: d.isSensitive ? '需文件夹管理权限' : '需文件夹上传权限',
            onTap: () {
              _close();
              showFolderFormSheet(
                context,
                mode: FolderFormMode.rename,
                folder: d,
              );
            },
          ),
          _row(
            icon: Icons.drag_indicator,
            title: '移动',
            enabled: !d.isSensitive && (d.myCanUpload ?? false),
            hint: d.isSensitive ? '敏感文件夹不支持移动' : '需文件夹上传权限',
            onTap: () {
              _close();
              showMoveFolderSheet(
                context,
                folder: d,
                projectId: d.projectId ?? '',
              );
            },
          ),
          // 敏感夹→邀请管理;普通一级夹→授权管理(web 0 选显隐同款)。
          if (d.isSensitive)
            _row(
              icon: Icons.manage_accounts_outlined,
              title: '邀请管理',
              enabled: d.myCanAdmin ?? false,
              hint: '需文件夹管理权限',
              onTap: () {
                _close();
                showFolderInviteSheet(context, folder: d);
              },
            ),
          if (!d.isSensitive && d.parentFolderId == null)
            _row(
              icon: Icons.manage_accounts_outlined,
              title: '授权管理',
              enabled: d.myCanAdmin ?? false,
              hint: '需文件夹管理权限(仅一级文件夹可设)',
              onTap: () {
                _close();
                showFolderGrantsSheet(context, folder: d);
              },
            ),
          // 请求链接发起位=单夹详情 my_can_admin(P2-4)。
          if (d.myCanAdmin ?? false)
            _row(
              icon: Icons.link_outlined,
              title: '请求链接',
              enabled: true,
              gold: true,
              onTap: () {
                _close();
                showRequestLinkSheet(
                  context,
                  targetType: d.isSensitive ? 'sensitive_folder' : 'folder',
                  targetId: d.id,
                  targetLabel: d.name,
                );
              },
            ),
          _row(
            icon: Icons.delete_outline,
            title: '删除',
            enabled:
                (d.isSensitive
                    ? d.myCanAdmin
                    : (d.myCanUpload ?? false) || (d.myDeleteGrant ?? false)) ??
                false,
            hint: '仅空夹可删',
            danger: true,
            onTap: () => _delete(d),
          ),
          _trashTile(d),
        ];
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0)
                Divider(height: 1, thickness: 1, color: context.tk.line),
              rows[i],
            ],
            const SizedBox(height: Tk.spaceSm),
          ],
        );
      },
    );
  }

  /// 动作行:普通=AppRow(图标金/普通可切),危险项=红字 ListTile。
  Widget _row({
    required IconData icon,
    required String title,
    required bool enabled,
    String? hint,
    VoidCallback? onTap,
    bool gold = false,
    bool danger = false,
  }) {
    final tk = context.tk;
    if (danger) {
      return ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14),
        leading: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: tk.dangerSoft,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 19, color: tk.danger),
        ),
        title: Text(
          title,
          style: TextStyle(
            fontSize: Tk.fzRowTitle,
            fontWeight: FontWeight.w500,
            color: enabled ? tk.danger : tk.ink3,
          ),
        ),
        subtitle: enabled
            ? null
            : Text(
                hint ?? '',
                style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
              ),
        enabled: enabled,
        onTap: onTap,
      );
    }
    return AppRow(
      leading: Icon(icon),
      title: title,
      subtitle: enabled ? null : hint,
      goldIcon: gold,
      showChevron: false,
      onTap: enabled ? onTap : null,
    );
  }

  /// 回收站入口(B5 实码平移):三态=canSeeTrash,到达前禁用并给提示。
  Widget _trashTile(Folder d) {
    final isSystemAdmin = session.me?.isSystemAdmin ?? false;
    final allowed = canSeeTrash(
      myCanAdmin: d.myCanAdmin,
      myDeleteGrant: d.myDeleteGrant,
      isSensitive: d.isSensitive,
      isSystemAdmin: isSystemAdmin,
    );
    final hint = !allowed
        ? (widget.folder.isSensitive ? '仅系统管理员可查看' : '需文件夹管理或删除授权')
        : null;
    return AppRow(
      leading: const Icon(Icons.restore_from_trash_outlined),
      title: '回收站',
      subtitle: hint,
      showChevron: false,
      onTap: allowed ? _openTrash : null,
    );
  }

  void _openTrash() {
    _close();
    Navigator.of(context)
        .pushNamed('/trash', arguments: (widget.folder.id, widget.folder.name));
  }
}

/// 菜单加载段骨架占位(D1):静态无动画,仅一次性请求的闪现帧。
Widget _menuSkeleton(BuildContext context) {
  final tk = context.tk;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: Tk.spaceMd),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 3; i++)
          Container(
            height: 40,
            margin: EdgeInsets.only(top: i == 0 ? 0 : Tk.spaceSm),
            decoration: BoxDecoration(
              color: tk.surface3,
              borderRadius: BorderRadius.circular(Tk.rSm),
            ),
          ),
      ],
    ),
  );
}
