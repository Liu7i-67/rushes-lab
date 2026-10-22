/// BaiduTargetPicker — 新建备份任务·目标选择(项目 + 承接夹;B9 §8.10,
/// web BaiduNewTaskModal 右栏移动版):项目下拉仅列出可上传项目
/// (is_system_admin ∪ my_roles 含 admin/uploader);目标=项目根(自动创建
/// 承接夹,同名复用)或项目内夹树选定——敏感夹及其整棵子树禁选(后端对
/// sensitive 祖先链 400,前端先收敛)。
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../folders/folder_tree.dart';

/// 目标:{项目根} | {某文件夹}。
class BaiduTarget {
  const BaiduTarget.root() : folder = null;
  const BaiduTarget.folderOf(Folder f) : folder = f;

  final Folder? folder;
  bool get isRoot => folder == null;
  String get label =>
      isRoot ? '项目根(自动创建承接夹)' : '目录「${folder!.name}」';
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
  final nameOf = <String, String>{};
  for (final f in all) {
    byParent.putIfAbsent(f.parentFolderId, () => []).add(f.id);
    nameOf[f.id] = f.name;
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

/// 目标夹选择列表(项目根选项 + 树形行;value/onChanged 受控)。
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
    final blocked = sensitiveSubtreeIds(folders);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('导入到哪个目录(敏感目录及其子目录不可选)',
            style: TextStyle(fontSize: Tk.fzSm, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        _rootRow(context),
        Container(
          constraints: const BoxConstraints(maxHeight: 240),
          decoration: BoxDecoration(
            border: Border.all(color: Tk.border),
            borderRadius: BorderRadius.circular(Tk.rSm),
          ),
          child: folders.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(
                      child: Text('项目暂无文件夹',
                          style: TextStyle(fontSize: Tk.fzSm, color: Tk.muted))),
                )
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final (node, depth) in _rows(buildFolderTree(folders)))
                      if (!blocked.contains(node.folder.id))
                        _folderRow(node.folder, depth),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _rootRow(BuildContext context) {
    final selected = value.isRoot;
    return ListTile(
      visualDensity: VisualDensity.compact,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.folder_special_outlined,
          size: 20, color: Tk.muted),
      title: Text('项目根',
          style: TextStyle(
              fontSize: Tk.fzMd,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? Tk.accentStrong : Tk.fg)),
      subtitle: const Text('自动创建承接文件夹(以网盘目录名命名,同名复用)',
          style: TextStyle(fontSize: Tk.fzXs)),
      tileColor: selected ? Tk.accentFaint : null,
      onTap: () => onChanged(const BaiduTarget.root()),
    );
  }

  Widget _folderRow(Folder f, int depth) {
    final selected = !value.isRoot && value.folder!.id == f.id;
    return ListTile(
      visualDensity: VisualDensity.compact,
      contentPadding: EdgeInsets.only(left: 8.0 + depth * 16, right: 8),
      leading: const Icon(Icons.folder_outlined, size: 18, color: Tk.muted),
      title: Text(f.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: Tk.fzMd,
              color: selected ? Tk.accentStrong : Tk.fg,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
      tileColor: selected ? Tk.accentFaint : null,
      onTap: () => onChanged(BaiduTarget.folderOf(f)),
    );
  }
}
