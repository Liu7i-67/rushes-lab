/// FolderRow — 文件夹树行(B2 §8.1):按深度缩进、subtree_file_count 徽标
/// (仅列表端点回填)、敏感锁、「⋯」菜单(回收站 B5 点亮,其余管理动作 B6)、
/// 点行进该夹宫格上下文。多级下钻靠树递归展开。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/badge.dart';
import '../assets/trash_page.dart' show canSeeTrash;
import 'folder_tree.dart';

class FolderRow extends StatelessWidget {
  const FolderRow({
    super.key,
    required this.node,
    required this.depth,
    required this.expanded,
    required this.onToggle,
    required this.onOpen,
  });

  final FolderNode node;
  final int depth;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final f = node.folder;
    final hasChildren = node.children.isNotEmpty;
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: EdgeInsets.fromLTRB(8.0 + depth * 16, 0, 4, 0),
        child: Row(
          children: [
            // 展开箭头:无子级占位对齐;有子级可折叠(默认全展开)
            SizedBox(
              width: 32,
              height: 40,
              child: hasChildren
                  ? IconButton(
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        expanded
                            ? Icons.expand_more
                            : Icons.chevron_right,
                        size: 20,
                      ),
                      onPressed: onToggle,
                    )
                  : const SizedBox.shrink(),
            ),
            const Icon(Icons.folder_outlined, size: 20, color: Tk.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                f.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15),
              ),
            ),
            if (f.isSensitive) ...[
              const SizedBox(width: 6),
              const Icon(Icons.lock_outline, size: 14, color: Tk.amber),
            ],
            if (f.subtreeFileCount > 0) ...[
              const SizedBox(width: 6),
              Badge(
                label: '${f.subtreeFileCount} 项',
                tone: BadgeTone.neutral,
              ),
            ],
            // ⋯ 菜单:回收站 B5 点亮(入口三态闸门);其余管理动作 B6 填
            IconButton(
              icon: const Icon(Icons.more_horiz, size: 18, color: Tk.subtle),
              onPressed: () => showFolderMenu(context, folder: f),
            ),
            const Icon(Icons.chevron_right, size: 18, color: Tk.subtle),
          ],
        ),
      ),
    );
  }
}

/// ⋯ 菜单(B2 壳,B5 点亮「回收站」):回收站入口三态=web canSeeTrash 实码:
/// 普通夹 my_can_admin 或 my_delete_grant;sensitive 夹仅系统 admin。
/// 闸门数据源=单夹详情(列表响应 my_can_* 恒 False 勿消费,§11),开菜单时拉。
/// 新建子夹/重命名/移动/邀请与授权/删除仍占位禁用(B6)。
void showFolderMenu(BuildContext context, {required Folder folder}) {
  final isSystemAdmin = session.me?.isSystemAdmin ?? false;
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      // 菜单项多(6 项+标题),小屏防 RenderFlex overflow → 可滚
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              folder.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          const ListTile(
            leading: Icon(Icons.create_new_folder_outlined),
            title: Text('新建子文件夹'),
            enabled: false,
          ),
          const ListTile(
            leading: Icon(Icons.drive_file_rename_outline),
            title: Text('重命名'),
            enabled: false,
          ),
          const ListTile(
            leading: Icon(Icons.drag_indicator),
            title: Text('移动'),
            enabled: false,
          ),
          const ListTile(
            leading: Icon(Icons.manage_accounts_outlined),
            title: Text('邀请与授权'),
            enabled: false,
          ),
          const ListTile(
            leading: Icon(Icons.delete_outline),
            title: Text('删除'),
            enabled: false,
          ),
          _TrashTile(folder: folder, isSystemAdmin: isSystemAdmin),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              '其余文件夹管理动作将在后续版本开放',
              style: TextStyle(color: Tk.subtle, fontSize: 12),
            ),
          ),
        ],
        ),
      ),
    ),
  );
}

/// 回收站入口:详情到达前禁用(「权限核验中…」),到达后按 canSeeTrash 三态
/// 显隐启停;点按进回收站页(列表+恢复)。P2-5:future 在 initState 取一次
/// (build 内新建每次重建都重发请求,FutureBuilder 反复回到等待态闪烁)。
class _TrashTile extends StatefulWidget {
  const _TrashTile({required this.folder, required this.isSystemAdmin});

  final Folder folder;
  final bool isSystemAdmin;

  @override
  State<_TrashTile> createState() => _TrashTileState();
}

class _TrashTileState extends State<_TrashTile> {
  late final Future<Folder> _detail = session.api!.folders.get(widget.folder.id);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Folder>(
      future: _detail,
      builder: (context, snap) {
        final detail = snap.data;
        final allowed = detail != null &&
            canSeeTrash(
              myCanAdmin: detail.myCanAdmin,
              myDeleteGrant: detail.myDeleteGrant,
              isSensitive: detail.isSensitive,
              isSystemAdmin: widget.isSystemAdmin,
            );
        final hint = snap.connectionState != ConnectionState.done
            ? '权限核验中…'
            : (!allowed
                ? (widget.folder.isSensitive ? '仅系统管理员可查看' : '需文件夹管理或删除授权')
                : null);
        return ListTile(
          leading: const Icon(Icons.restore_from_trash_outlined),
          title: const Text('回收站'),
          subtitle: hint == null ? null : Text(hint, style: const TextStyle(fontSize: 12)),
          enabled: allowed,
          onTap: () {
            Navigator.of(context).pop();
            Navigator.of(context).pushNamed(
                '/trash', arguments: (widget.folder.id, widget.folder.name));
          },
        );
      },
    );
  }
}
