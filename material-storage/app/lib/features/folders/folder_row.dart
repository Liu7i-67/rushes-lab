/// FolderRow — 文件夹树行(B2 §8.1):按深度缩进、subtree_file_count 徽标
/// (仅列表端点回填)、敏感锁、「⋯」占位菜单(管理动作 B4-B6 逐步点亮)、
/// 点行进该夹宫格上下文。多级下钻靠树递归展开。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../theme/tokens.dart';
import '../../widgets/badge.dart';
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
            // ⋯ 菜单本批占位:菜单项 B4-B6 填(重命名/移动/删除/授权…)
            IconButton(
              icon: const Icon(Icons.more_horiz, size: 18, color: Tk.subtle),
              onPressed: () => showFolderMenuPlaceholder(context, f.name),
            ),
            const Icon(Icons.chevron_right, size: 18, color: Tk.subtle),
          ],
        ),
      ),
    );
  }
}

/// ⋯ 占位菜单(B2):动作壳先立起来,全部禁用,B4-B6 逐项点亮。
void showFolderMenuPlaceholder(BuildContext context, String folderName) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              folderName,
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              '文件夹管理动作将在后续版本开放',
              style: TextStyle(color: Tk.subtle, fontSize: 12),
            ),
          ),
        ],
      ),
    ),
  );
}
