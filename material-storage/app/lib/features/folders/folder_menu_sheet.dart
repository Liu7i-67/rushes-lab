/// FolderMenuSheet — 文件夹「⋯」菜单(B6;自 folder_row.dart 拆分守 300 行):
/// 闸门数据源=单夹详情(列表响应 my_can_* 恒 False 勿消费,§11),开菜单时拉一次、
/// 各动作 tile 共用。闸门=web ProjectDetailPage 实况:新建子夹 my_can_upload;
/// 重命名 sensitive?admin:upload;移动=普通夹+upload(sensitive 源禁移动);
/// 邀请管理仅敏感夹(admin);授权管理仅普通一级夹(admin);删除
/// sensitive?admin:(upload||delete_grant);回收站 canSeeTrash(B5 实码平移)。
/// 请求链接发起位(folder menu)=单夹详情 my_can_admin:P2-4 qplan 定稿口径
/// 「项目内发起位=my_can_admin」——有权限可见可点,无权限完全不渲染(勿置灰)。
/// app-polish D1:骨架迁移 showAppSheet(标题=夹名);「权限核验中…」改静态
/// 骨架占位(不闪现、无动画,pumpAndSettle 安全);删除确认统一 showAppConfirm
/// (danger);错误/成功反馈收口 toast+errorMessage(E14)。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart' show errorMessage;
import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_confirm.dart';
import '../../widgets/sheet_scaffold.dart';
import '../../widgets/toast.dart';
import '../assets/trash_page.dart' show canSeeTrash;
import '../share/request_link_sheet.dart';
import 'folder_form_sheet.dart';
import 'folder_grants_sheet.dart';
import 'folder_invite_sheet.dart';
import 'move_folder_sheet.dart';

/// ⋯ 菜单(B6 全量点亮;对外 API 不变):闸门=单夹详情,开菜单时拉一次、
/// 各动作 tile 共用(详见文件头)。
void showFolderMenu(BuildContext context, {required Folder folder}) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => SheetScaffold(
      title: folder.name,
      child: _FolderMenuSheet(folder: folder),
    ),
  );
}

/// 菜单加载段骨架占位(D1,替代「权限核验中…」裸文案):静态灰条无动画
/// (菜单详情为一次性微任务级请求,骨架仅闪现一帧;动画件会让 pumpAndSettle
/// 挂起,故不用 ListSkeleton)。
Widget menuSkeleton() {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: Tk.spaceMd),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(height: Tk.spaceSm),
          Container(
            height: 36,
            decoration: BoxDecoration(
              color: Tk.fill,
              borderRadius: BorderRadius.circular(Tk.rSm),
            ),
          ),
        ],
      ],
    ),
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
    final ok = await showAppConfirm(
      context,
      title: '删除文件夹「${d.name}」?',
      content: '仅可删除空文件夹(子文件夹、文件需先删光,回收站也须彻底清空)。'
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
      toast(context, '删除失败:${errorMessage(e, '请稍后重试')}',
          tone: ToastTone.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 菜单项多(标题+7 项),小屏防 RenderFlex overflow → 骨架滚动区可滚
    return FutureBuilder<Folder>(
      future: _detail,
      builder: (context, snap) {
        final d = snap.data;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (snap.connectionState != ConnectionState.done)
              menuSkeleton()
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
              // B9 §8.11 请求链接(P2-4 qplan 定稿:项目内发起位=
              // 单夹详情 my_can_admin,数据源即本 FutureBuilder 已拉的
              // get_folder 回填,可得性无虞):有权限可见可点发起;
              // 无权限/未知=完全不渲染(勿置灰)。敏感夹
              // target=sensitive_folder 可申请 access。
              if (d.myCanAdmin ?? false)
                _actionTile(
                  icon: Icons.link_outlined,
                  title: '请求链接',
                  enabled: true,
                  onTap: () {
                    _close();
                    showRequestLinkSheet(context,
                        targetType:
                            d.isSensitive ? 'sensitive_folder' : 'folder',
                        targetId: d.id,
                        targetLabel: d.name);
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
            const SizedBox(height: Tk.spaceSm),
          ],
        );
      },
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
          enabled ? null : Text(hint ?? '', style: const TextStyle(fontSize: Tk.fzSm)),
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
          hint == null ? null : Text(hint, style: const TextStyle(fontSize: Tk.fzSm)),
      enabled: allowed,
      onTap: () {
        _close();
        Navigator.of(context).pushNamed(
            '/trash', arguments: (widget.folder.id, widget.folder.name));
      },
    );
  }
}
