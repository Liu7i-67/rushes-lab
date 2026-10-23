/// FolderRow — 文件夹树行(F7/§7.2 墨色 + 金色):40×40 图标容器
/// (敏感=goldSoft 底 + goldInk 锁;普通=surface3 + ink2,含文件用实心
/// folder、空夹用 folder_outlined)、名称 15.5/500、副标题 13/ink3
/// (只表「敏感目录」/「空文件夹」)+ 敏感锁 14/warn +「⋯」44 图标钮。
///
/// 计数唯一入口=行尾「N 项」徽标(directFileCount,直属数,不含子树;
/// 直属=0 不显示徽标);副标题不再承载数字(保留 app-polish-3 D1 已上线
/// 的徽标语义,避免同一数字双写)。
///
/// 结构语义保持:按深度每级 16px 缩进 + 2px 竖直参考线(tk.line)、
/// 有子级可展开/折叠(默认全展开)、整行可点进宫格、行尾无 chevron
/// (E4 定稿);图标实心仍按子树含文件(subtree>0)点亮。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../models/models.dart';
import '../../theme/context_tk.dart';
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
    final tk = context.tk;
    final f = node.folder;
    final hasChildren = node.children.isNotEmpty;
    final hasFiles = f.subtreeFileCount > 0;
    // P2-3:金底只给敏感夹;普通含文件=实心 folder + surface3 + ink2。
    final accented = f.isSensitive;
    final subtitle = _subtitleOf(f);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Tk.spaceSm, 0, Tk.spaceXs, 0),
            child: Row(
              children: [
                // 层级参考线:每级 16 一段,段首 2px 竖线。
                for (var i = 0; i < depth; i++)
                  SizedBox(
                    width: Tk.spaceLg,
                    height: 56,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Container(width: 2, height: 28, color: tk.line),
                    ),
                  ),
                // 展开箭头:无子级占位对齐;44×44 触控区。
                SizedBox(
                  width: 44,
                  height: 44,
                  child: hasChildren
                      ? IconButton(
                          padding: EdgeInsets.zero,
                          tooltip: expanded ? '折叠' : '展开',
                          iconSize: 22,
                          color: tk.ink2,
                          icon: Icon(
                            expanded ? Icons.expand_more : Icons.chevron_right,
                          ),
                          onPressed: onToggle,
                        )
                      : const SizedBox.shrink(),
                ),
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: accented ? tk.goldSoft : tk.surface3,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(
                    f.isSensitive
                        ? Icons.lock_outline
                        : hasFiles
                        ? Icons.folder
                        : Icons.folder_outlined,
                    size: 20,
                    color: accented ? tk.goldInk : tk.ink2,
                  ),
                ),
                const SizedBox(width: Tk.spaceMd),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        f.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: Tk.fzRowTitle,
                          height: 1.4,
                          fontWeight: FontWeight.w500,
                          letterSpacing: -0.08,
                          color: tk.ink,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: Tk.fzMd,
                            height: 1.4,
                            color: tk.ink3,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (f.directFileCount > 0) ...[
                  const SizedBox(width: Tk.spaceXs),
                  // 唯一计数位:直属数「N 项」徽标(不含子树)。
                  Badge(
                    label: '${f.directFileCount} 项',
                    tone: BadgeTone.neutral,
                  ),
                ],
                if (f.isSensitive) ...[
                  const SizedBox(width: Tk.spaceXs),
                  Icon(Icons.lock_outline, size: 14, color: tk.warn),
                ],
                SizedBox(
                  width: 44,
                  height: 44,
                  child: IconButton(
                    tooltip: '文件夹操作',
                    padding: EdgeInsets.zero,
                    iconSize: 20,
                    color: tk.ink3,
                    icon: const Icon(Icons.more_horiz),
                    onPressed: () => showFolderMenu(context, folder: f),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 副标题:只表敏感目录/空文件夹;直属计数由行尾「N 项」徽标唯一承担。
  String? _subtitleOf(Folder f) {
    if (f.isSensitive) return '敏感目录';
    if (f.directFileCount > 0) return null;
    return '空文件夹';
  }
}
