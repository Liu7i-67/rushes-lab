/// FolderRow — 文件夹树行(B2 §8.1):按深度缩进、subtree_file_count 徽标
/// (仅列表端点回填)、敏感锁、「⋯」菜单(在 folder_menu_sheet.dart,B6 全量)、
/// 点行进该夹宫格
/// 上下文。多级下钻靠树递归展开。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../theme/tokens.dart';
import '../../widgets/badge.dart';
import 'folder_tree.dart';
import 'folder_menu_sheet.dart' show showFolderMenu;

export 'folder_menu_sheet.dart' show showFolderMenu;

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

