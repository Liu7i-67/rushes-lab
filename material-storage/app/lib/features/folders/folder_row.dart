/// FolderRow — 文件夹树行(B2 §8.1 + app-polish E4 精修):按深度缩进+
/// 每级 2px 竖向参考线(subtle)、计数徽标(仅列表端点回填)、
/// 敏感锁(amber 点缀)、「⋯」图标钮菜单(在 folder_menu_sheet.dart,B6 全量)、
/// 点行进该夹宫格上下文。E4:行尾 chevron 移除(与整行可点重复);展开箭头
/// 触控区≥44×44。多级下钻靠树递归展开。
/// K(2026-10-22 真机反馈 #1):计数三态 —— 直属>0「N 项」主徽标;直属 0 且
/// 子树>0「子级 M 项」fzXs muted 灰字(弱提示,不再误导「点进去为空」);
/// 皆 0 不显示。图标实心(子树含文件)语义保持不变。
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
    // P5:含文件(子树计数>0)的夹实心深色图标,对齐 web「实心=含文件」语义;
    // 空夹维持橙色空心
    final hasFiles = f.subtreeFileCount > 0;
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Tk.spaceSm, 0, Tk.spaceXs, 0),
        child: Row(
          children: [
            // E4:层级参考线——每级 16px 缩进段首一根 2px 竖线(层次一眼可辨)
            for (var i = 0; i < depth; i++)
              SizedBox(
                width: Tk.spaceLg,
                height: 44,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Container(width: 2, height: 28, color: Tk.border),
                ),
              ),
            // 展开箭头:无子级占位对齐;有子级可折叠(默认全展开)。
            // E4:触控区≥44×44(含 padding 的实心 IconButton)
            SizedBox(
              width: 44,
              height: 44,
              child: hasChildren
                  ? IconButton(
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        expanded ? Icons.expand_more : Icons.chevron_right,
                        size: 22,
                      ),
                      onPressed: onToggle,
                    )
                  : const SizedBox.shrink(),
            ),
            Icon(
              hasFiles ? Icons.folder : Icons.folder_outlined,
              size: 20,
              color: hasFiles ? Tk.fg : Tk.accent,
            ),
            const SizedBox(width: Tk.spaceSm),
            Expanded(
              child: Text(
                f.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: Tk.fzTitle),
              ),
            ),
            if (f.isSensitive) ...[
              const SizedBox(width: Tk.spaceXs),
              // E4:敏感夹 amber 小标点缀(锁图标 amber 化,弱存在感提示)
              const Icon(Icons.lock_outline, size: 14, color: Tk.amber),
            ],
            if (f.directFileCount > 0) ...[
              const SizedBox(width: Tk.spaceXs),
              // 直属>0:「N 项」主徽标(数字 = 本夹直属,不含子树)
              Badge(
                label: '${f.directFileCount} 项',
                tone: BadgeTone.neutral,
              ),
            ] else if (f.subtreeFileCount > 0) ...[
              const SizedBox(width: Tk.spaceXs),
              // 直属 0 且子树>0:「子级 M 项」灰字弱提示(fzXs muted,弱于主
              // 徽标)—— 旧后端缺 direct_file_count 键时解析默认 0,同样落到
              // 此态(子树>0),不再出现误导的「M 项」主数字,可接受
              Text(
                '子级 ${f.subtreeFileCount} 项',
                style: const TextStyle(fontSize: Tk.fzXs, color: Tk.muted),
              ),
            ],
            // ⋯ 菜单:回收站 B5 点亮(入口三态闸门);其余管理动作 B6 填。
            // E4:「⋯」图标钮化(IconButton,视觉提权 muted→fg)
            IconButton(
              tooltip: '文件夹操作',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.more_horiz, size: 20, color: Tk.muted),
              onPressed: () => showFolderMenu(context, folder: f),
            ),
            // E4:行尾 chevron 移除——整行可点已表意,三重导航符号减为两层
          ],
        ),
      ),
    );
  }
}
