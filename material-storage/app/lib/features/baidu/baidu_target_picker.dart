/// BaiduTargetPicker — 新建备份任务·目标选择(项目 + 承接夹;B9 §8.10,
/// web BaiduNewTaskModal 右栏移动版):项目下拉仅列出可上传项目
/// (is_system_admin ∪ my_roles 含 admin/uploader);目标=项目根(自动创建
/// 承接夹,同名复用)或项目内夹树选定——敏感夹及其整棵子树禁选(后端对
/// sensitive 祖先链 400,前端先收敛)。
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_row.dart';
import '../folders/folder_tree.dart';

/// 目标:{项目根} | {某文件夹}。
class BaiduTarget {
  const BaiduTarget.root() : folder = null;
  const BaiduTarget.folderOf(Folder f) : folder = f;

  final Folder? folder;
  bool get isRoot => folder == null;
  String get label => isRoot ? '项目根(自动创建承接夹)' : '目录「${folder!.name}」';
}

/// 项目可承接判定(web creatableProjects 同口径)。
bool projectAcceptsTask(Project p, Me? me) =>
    (me?.isSystemAdmin ?? false) ||
    p.myRoles.contains('admin') ||
    p.myRoles.contains('uploader');

/// 敏感夹 id 及其全部后代 id(整棵子树禁选)。
Set<String> sensitiveSubtreeIds(List<Folder> all) {
  final blocked = <String>{};
  final byParent = <String?, List<String>>{};
  for (final f in all) {
    byParent.putIfAbsent(f.parentFolderId, () => []).add(f.id);
  }
  void blockSubtree(String id) {
    if (!blocked.add(id)) return;
    for (final c in byParent[id] ?? const <String>[]) {
      blockSubtree(c);
    }
  }

  for (final f in all) {
    if (f.isSensitive) blockSubtree(f.id);
  }
  return blocked;
}

/// 目标夹选择列表(项目根选项 + 树形 AppRow;value/onChanged 受控)。
class BaiduTargetPicker extends StatelessWidget {
  const BaiduTargetPicker({
    super.key,
    required this.projectId,
    required this.projectName,
    required this.folders,
    required this.value,
    required this.onChanged,
  });

  final String projectId;
  final String projectName;
  final List<Folder> folders;
  final BaiduTarget value;
  final ValueChanged<BaiduTarget> onChanged;

  /// 深度优先铺平可见行(跳过被禁选的敏感子树)。
  List<(FolderNode, int)> _rows(List<FolderNode> roots) {
    final rows = <(FolderNode, int)>[];
    void walk(List<FolderNode> nodes, int depth) {
      for (final n in nodes) {
        rows.add((n, depth));
        walk(n.children, depth + 1);
      }
    }

    walk(roots, 0);
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final blocked = sensitiveSubtreeIds(folders);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '导入到哪个目录(敏感目录及其子目录不可选)',
          style: TextStyle(fontSize: Tk.fzSm, color: tk.ink3),
        ),
        const SizedBox(height: Tk.spaceSm),
        AppCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              _rootRow(context),
              if (folders.isNotEmpty)
                Divider(height: 1, thickness: 1, color: tk.line),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: folders.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(Tk.spaceLg),
                        child: Text(
                          '项目暂无文件夹',
                          style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
                        ),
                      )
                    : ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(
                          vertical: Tk.spaceXs,
                        ),
                        children: [
                          for (final (node, depth) in _rows(
                            buildFolderTree(folders),
                          ))
                            if (!blocked.contains(node.folder.id))
                              Padding(
                                padding: EdgeInsets.only(left: depth * 16.0),
                                child: _folderRow(context, node.folder),
                              ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _rootRow(BuildContext context) {
    final tk = context.tk;
    final selected = value.isRoot;
    return AppRow(
      leading: const Icon(Icons.folder_special_outlined),
      goldIcon: selected,
      title: '项目根',
      subtitle: '自动创建承接文件夹(以网盘目录名命名,同名复用)',
      trailing: selected
          ? Icon(Icons.check_circle, size: 20, color: tk.gold)
          : null,
      onTap: () => onChanged(const BaiduTarget.root()),
    );
  }

  Widget _folderRow(BuildContext context, Folder f) {
    final tk = context.tk;
    final selected = !value.isRoot && value.folder!.id == f.id;
    return AppRow(
      leading: const Icon(Icons.folder_outlined),
      goldIcon: selected,
      title: f.name,
      trailing: selected
          ? Icon(Icons.check_circle, size: 20, color: tk.gold)
          : null,
      onTap: () => onChanged(BaiduTarget.folderOf(f)),
    );
  }
}
