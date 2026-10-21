/// FolderMenuSheet — 文件夹「⋯」菜单(B6;自 folder_row.dart 拆分守 300 行):
/// 闸门数据源=单夹详情(列表响应 my_can_* 恒 False 勿消费,§11),开菜单时拉一次、
/// 各动作 tile 共用。闸门=web ProjectDetailPage 实况:新建子夹 my_can_upload;
/// 重命名 sensitive?admin:upload;移动=普通夹+upload(sensitive 源禁移动);
/// 邀请管理仅敏感夹(admin);授权管理仅普通一级夹(admin);删除
/// sensitive?admin:(upload||delete_grant);回收站 canSeeTrash(B5 实码平移)。
library;

import 'package:flutter/material.dart';

import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../assets/trash_page.dart' show canSeeTrash;
import 'folder_form_sheet.dart';
import 'folder_grants_sheet.dart';
import 'folder_invite_sheet.dart';
import 'move_folder_sheet.dart';

/// ⋯ 菜单(B6 全量点亮):闸门数据源=单夹详情(列表响应 my_can_* 恒 False
/// 勿消费,§11),开菜单时拉一次、各动作 tile 共用。闸门=web ProjectDetailPage
/// 实况:新建子夹 my_can_upload;重命名 sensitive?admin:upload;移动=普通夹
/// +upload(sensitive 源禁移动);邀请管理仅敏感夹(admin);授权管理仅普通
/// 一级夹(admin);删除 sensitive?admin:(upload||delete_grant);
/// 回收站 canSeeTrash(B5 实码平移)。
void showFolderMenu(BuildContext context, {required Folder folder}) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => _FolderMenuSheet(folder: folder),
  );
}

class _FolderMenuSheet extends StatefulWidget {
  const _FolderMenuSheet({required this.folder});

  final Folder folder;

  @override
  State<_FolderMenuSheet> createState() => _FolderMenuSheetState();
}

class _FolderMenuSheetState extends State<_FolderMenuSheet> {
  /// 单夹详情一次性拉取(initState 取一次;build 内新建会反复重发,P2-5 同款)。
  late final Future<Folder> _detail =
      session.api!.folders.get(widget.folder.id);

  /// 弹动作 sheet 前先收掉菜单(动作面板与菜单叠两层 modal 不友好)。
  void _close() => Navigator.of(context).pop();

  Future<void> _delete(Folder d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除文件夹「${d.name}」?'),
        content: const Text(
            '仅可删除空文件夹(子文件夹、文件需先删光,回收站也须彻底清空)。'
            '删除为永久删除、不可恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(foregroundColor: Tk.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await session.api!.foldersOps.delete(d.id);
      RefreshBus.I.invalidate('folders');
      if (!mounted) return;
      _close();
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('文件夹已删除')));
    } catch (e) {
      if (!mounted) return;
      // 非空 409 / 无权 403 detail 透传(「请先删除其中所有文件」等)
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text('删除失败:$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      // 菜单项多(标题+7 项),小屏防 RenderFlex overflow → 可滚
      child: SingleChildScrollView(
        child: FutureBuilder<Folder>(
          future: _detail,
          builder: (context, snap) {
            final d = snap.data;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    widget.folder.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (snap.connectionState != ConnectionState.done)
                  const Padding(
                    // 权限核验中(勿用进度圈:pumpAndSettle 永不静止,B5 P2-5 同款)
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('权限核验中…',
                        style: TextStyle(color: Tk.subtle, fontSize: 12)),
                  )
                else if (d != null) ...[
                  _actionTile(
                    icon: Icons.create_new_folder_outlined,
                    title: '新建子文件夹',
                    enabled: d.myCanUpload ?? false,
                    hint: '需文件夹上传权限',
                    onTap: () {
                      _close();
                      showFolderFormSheet(context,
                          mode: FolderFormMode.createChild,
                          projectId: d.projectId ?? '',
                          parentFolderId: d.id,
                          parentLabel: d.name);
                    },
                  ),
                  _actionTile(
                    icon: Icons.drive_file_rename_outline,
                    title: '重命名',
                    enabled:
                        (d.isSensitive ? d.myCanAdmin : d.myCanUpload) ?? false,
                    hint: d.isSensitive ? '需文件夹管理权限' : '需文件夹上传权限',
                    onTap: () {
                      _close();
                      showFolderFormSheet(
                          context, mode: FolderFormMode.rename, folder: d);
                    },
                  ),
                  _actionTile(
                    icon: Icons.drag_indicator,
                    title: '移动',
                    enabled: !d.isSensitive && (d.myCanUpload ?? false),
                    hint: d.isSensitive ? '敏感文件夹不支持移动' : '需文件夹上传权限',
                    onTap: () {
                      _close();
                      showMoveFolderSheet(context,
                          folder: d, projectId: d.projectId ?? '');
                    },
                  ),
                  // 敏感夹 → 邀请管理;普通一级夹 → 授权管理(web AssetSummaryPanel
                  // 0 选显隐同款:0选+敏感→invite;0选+普通一级→grants)
                  if (d.isSensitive)
                    _actionTile(
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
                    _actionTile(
                      icon: Icons.manage_accounts_outlined,
                      title: '授权管理',
                      enabled: d.myCanAdmin ?? false,
                      hint: '需文件夹管理权限(仅一级文件夹可设)',
                      onTap: () {
                        _close();
                        showFolderGrantsSheet(context, folder: d);
                      },
                    ),
                  _actionTile(
                    icon: Icons.delete_outline,
                    title: '删除',
                    enabled: (d.isSensitive
                            ? d.myCanAdmin
                            : (d.myCanUpload ?? false) ||
                                (d.myDeleteGrant ?? false)) ??
                        false,
                    hint: '仅空夹可删',
                    onTap: () => _delete(d),
                  ),
                  _trashTile(d),
                ],
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _actionTile({
    required IconData icon,
    required String title,
    required bool enabled,
    String? hint,
    VoidCallback? onTap,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle:
          enabled ? null : Text(hint ?? '', style: const TextStyle(fontSize: 12)),
      enabled: enabled,
      onTap: onTap,
    );
  }

  /// 回收站入口(B5 实码平移):三态=canSeeTrash(普通夹 my_can_admin 或
  /// my_delete_grant;sensitive 仅系统 admin),到达前禁用「权限核验中…」。
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
    return ListTile(
      leading: const Icon(Icons.restore_from_trash_outlined),
      title: const Text('回收站'),
      subtitle:
          hint == null ? null : Text(hint, style: const TextStyle(fontSize: 12)),
      enabled: allowed,
      onTap: () {
        _close();
        Navigator.of(context).pushNamed(
            '/trash', arguments: (widget.folder.id, widget.folder.name));
      },
    );
  }
}
