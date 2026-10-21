/// FolderTree — flat 文件夹列表 → 内存建树(B2 §8.1,数据源=GET /folders?project_id=
/// 平铺全树含 parent_folder_id,web FolderTree 同数据)。可单测纯逻辑。
///
/// 组树语义(B2 测试修复 PM 决策:对标 web `buildTree` 自 null 根递归):
/// - 一级节点(parent_folder_id=null)为根;子节点挂到父节点 children;
///   根序/子序保持后端返回序(minio_prefix 序,web 的名称排序不照搬);
/// - 孤儿节点(parent_folder_id 指向列表外不存在的夹)→ **不渲染**(父不可见
///   即整支不可达,web 同口径;旧「提升为根」口径已废弃——提升会把用户在 web
///   看不到的夹在 App 里凭空造出来);
/// - 环(parent 链成环/自指)及环外挂靠 → 同为「自 null 根不可达」→ 不渲染;
///   不会死循环(不做图遍历,纯自根递归,环天然挂不进结果树)。
library;

import '../../models/models.dart';

class FolderNode {
  FolderNode(this.folder);

  final Folder folder;
  final List<FolderNode> children = [];
}

List<FolderNode> buildFolderTree(List<Folder> all) {
  final nodes = <String, FolderNode>{};
  for (final f in all) {
    // 同 id 重复防御:后来者覆盖(正常数据不会出现)
    nodes[f.id] = FolderNode(f);
  }

  // 按 parent id 分桶(null=一级);孤儿桶(parent 不在列表)自根不可达即隐藏
  final byParent = <String?, List<FolderNode>>{};
  for (final n in nodes.values) {
    final k = n.folder.parentFolderId;
    if (k != null && !nodes.containsKey(k)) continue; // 孤儿 → 不渲染
    byParent.putIfAbsent(k, () => []).add(n);
  }

  /// 自 null 根递归组树:环上节点只存在于「可达节点的后代桶」里,从根走不到
  /// → 天然不进结果(无 visited 集合也无死循环:每个节点只在自己父节点处挂一次)。
  FolderNode attach(FolderNode n) {
    for (final c in byParent[n.folder.id] ?? const <FolderNode>[]) {
      n.children.add(attach(c));
    }
    return n;
  }

  return [for (final r in byParent[null] ?? const <FolderNode>[]) attach(r)];
}
