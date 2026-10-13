/**
 * 目录模板共用纯函数 — 相对路径列表 → antd Tree treeData(方案 §6-F3/F6)。
 *
 * AdminFolderTemplatesPage 编辑预览与 NewProjectModal 选中预览共用本函数;
 * 按 `/` 切段逐级挂树,同段自动合并(前缀重叠条目天然去重,与后端
 * ensure 幂等复用的应用语义一致)。节点 key 取当前层级全路径,稳定且唯一。
 * 输入不做合法性裁剪 — 非法路径由提交前的校验与后端 422 把关,这里对空行
 * 直接跳过,保证预览不被未填完的行打断。
 */

export interface FolderTreeNode {
  title: string;
  key: string;
  children?: FolderTreeNode[];
}

/** 供 Tree 展开态用的全部节点 key(含中间层;模板预览恒全展开)。*/
export function collectTreeKeys(nodes: FolderTreeNode[]): string[] {
  const out: string[] = [];
  const walk = (list: FolderTreeNode[]) => {
    for (const n of list) {
      out.push(n.key);
      if (n.children) walk(n.children);
    }
  };
  walk(nodes);
  return out;
}

export function pathsToTreeData(paths: string[]): FolderTreeNode[] {
  const roots: FolderTreeNode[] = [];
  const findOrCreate = (nodes: FolderTreeNode[], title: string, key: string): FolderTreeNode => {
    let node = nodes.find(n => n.title === title);
    if (!node) {
      node = { title, key, children: [] };
      nodes.push(node);
    }
    return node;
  };
  for (const raw of paths) {
    const p = raw.trim();
    if (!p) continue;
    const segments = p.split('/').filter(s => s.length > 0);
    let level = roots;
    let acc = '';
    for (const seg of segments) {
      acc = acc ? `${acc}/${seg}` : seg;
      const node = findOrCreate(level, seg, acc);
      level = node.children!;
    }
  }
  return roots;
}
