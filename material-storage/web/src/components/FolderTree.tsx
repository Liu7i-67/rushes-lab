/**
 * 左侧 folder 树 — sensitive 用 2px accent 竖条标识 + lucide icons + 紧凑 typography。
 * 沿用 antd Tree 引擎,通过 title 自定义 + components token 调整视觉。
 *
 * W4/W5(六项优化 2026-10-17):节点操作菜单(重命名/移动到)+ PC 拖拽换父。
 * - 菜单/拖拽仅在调用方传回调时启用(selectMode 目标选择零感知);
 * - allowDrop 三句式:源 sensitive 禁移;目标 sensitive 及其子树禁入;禁入自身后代(防环)。
 *   「移出敏感子树放行」在 GUI 本不可达(敏感子树内的普通孤儿夹不进拼树),不做特判;
 * - 拖拽落点只取语义(新父 = dropToGap ? 目标节点父 : 目标节点),不做 gap 精细排序 ——
 *   列表排序由后端 minio_prefix 决定,前端不持久化顺序。
 */
import { Dropdown, Tooltip, Tree } from 'antd';
import type { MenuProps, TreeProps } from 'antd';

// antd v6 的 TreeProps['allowDrop'/'onDrop'] 含 undefined,useCallback 泛型约束要纯函数型
type TreeAllowDrop = NonNullable<TreeProps['allowDrop']>;
type TreeOnDrop = NonNullable<TreeProps['onDrop']>;
import { Ellipsis, Folder as FolderIcon, FolderInput, FolderOpen, Lock, Pencil, Plus } from 'lucide-react';
import { useCallback, useMemo } from 'react';
import type { Folder } from '../api/types';

interface Props {
  folders: Folder[];
  projectName?: string;
  activeFolderId: string | null;
  onSelect: (folderId: string) => void;
  onCreateChild?: () => void;
  onCreateRoot?: () => void;
  /** 项目级上传权限(uploader/admin)— 后端建目录强制 can_upload,前端据此隐藏入口 */
  canUpload?: boolean;
  /** 选择模式(备份目标选择等):仅选择语义,不隐藏标题区;onSelect 行为不变 */
  selectMode?: boolean;
  /** 禁选节点 id 集合 — 命中节点**及其整棵子树**一律禁选
   *  (antd Tree 节点 disabled;备份目标选择时传 sensitive 集合,§7)。 */
  disabledIds?: string[];
  /** 禁选节点 id 集合 — 仅命中节点**自身**禁选,**不级联子树**(与 disabledIds 的
   *  整子树级联语义互补;批量移动弹窗禁选源夹自身用,子夹仍可选 ——
   *  A 夹文件移入 A/B 子夹是合法操作,不得改用 disabledIds 误伤子夹)。 */
  disabledSelfIds?: string[];
  /** 节点操作菜单闸门(调用方按 my_can_upload/my_can_admin + is_system_admin 判):
   *  返回 null/全 false = 不渲染菜单;sensitive 源禁 move(三句式①)。 */
  nodeActions?: (folder: Folder) => { rename: boolean; move: boolean } | null;
  onRenameFolder?: (folder: Folder) => void;
  onMoveFolder?: (folder: Folder) => void;
  /** PC 专属:启用拖拽换父(移动端 Drawer 树不适合拖拽,走「移动到」菜单,§5.2) */
  enableDrag?: boolean;
  /** 拖拽落点确认:调用方弹确认框后调 useMoveFolder(parent_folder_id=null = 项目根) */
  onMoveDrop?: (args: { folder: Folder; newParentId: string | null }) => void;
}

interface TreeNode {
  key: string;
  title: React.ReactNode;
  icon: React.ReactNode;
  isLeaf?: boolean;
  disabled?: boolean;
  children?: TreeNode[];
}

/** folderId 是否为 ancestorId 的后代(沿 parent 链显式栈上溯,迭代防深链)。*/
function isDescendant(folders: Folder[], ancestorId: string, maybeDescId: string): boolean {
  const byId = new Map(folders.map(f => [f.id, f] as const));
  let cur = byId.get(maybeDescId);
  while (cur?.parent_folder_id) {
    if (cur.parent_folder_id === ancestorId) return true;
    cur = byId.get(cur.parent_folder_id);
  }
  return false;
}

/** 节点自身或任一祖先为 sensitive(目标侧三句式②:sensitive 子树整体禁入)。*/
function hasSensitiveAncestry(folders: Folder[], folderId: string): boolean {
  const byId = new Map(folders.map(f => [f.id, f] as const));
  let cur = byId.get(folderId);
  while (cur) {
    if (cur.is_sensitive) return true;
    cur = cur.parent_folder_id ? byId.get(cur.parent_folder_id) : undefined;
  }
  return false;
}

function buildTree(
  folders: Folder[],
  disabledSet: Set<string>,
  selfDisabledSet: Set<string>,
  renderNodeOps?: (folder: Folder) => React.ReactNode,
): TreeNode[] {
  const byParent = new Map<string | null, Folder[]>();
  for (const f of folders) {
    const k = f.parent_folder_id ?? null;
    const arr = byParent.get(k) ?? [];
    arr.push(f);
    byParent.set(k, arr);
  }
  for (const arr of byParent.values()) {
    arr.sort((a, b) => {
      // sensitive 排在普通后(更"档案"逻辑)
      if (a.is_sensitive !== b.is_sensitive) return a.is_sensitive ? 1 : -1;
      return a.name.localeCompare(b.name);
    });
  }

  const build = (parent: string | null, ancestorDisabled: boolean): TreeNode[] =>
    (byParent.get(parent) ?? []).map(f => {
      // 整棵子树级联禁选:disabledSet 命中为级联源(后代全 disabled);
      // selfDisabledSet 只禁节点自身,不进级联源,子夹仍可选
      const disabled = ancestorDisabled || disabledSet.has(f.id) || selfDisabledSet.has(f.id);
      const sub = build(f.id, ancestorDisabled || disabledSet.has(f.id));
      // 子树含活跃文件(subtree_file_count>0,软删不计)→ 图标实心填充;空夹保持空心。
      // D1 定档:仅图标区分,无数字、无 tooltip。lucide 透传 fill 覆盖默认 fill="none"(已核实 v1.16.0 Icon 源码)。
      const hasFiles = (f.subtree_file_count ?? 0) > 0;
      const ops = renderNodeOps?.(f);
      return {
        key: f.id,
        disabled: disabled || undefined,
        title: (
          <span style={{
            display: 'inline-flex',
            alignItems: 'center',
            gap: 8,
            position: 'relative',
            paddingLeft: f.is_sensitive ? 6 : 0,
            color: 'var(--ms-ink)',
            fontSize: 13,
          }}>
            {f.is_sensitive && (
              <span
                aria-label="敏感目录"
                title={disabled ? '敏感目录及其子目录不可选' : '敏感目录 — 仅邀请可见'}
                style={{
                  position: 'absolute',
                  left: -2, top: 4, bottom: 4,
                  width: 2,
                  background: 'var(--ms-sensitive)',
                  borderRadius: 1,
                }}
              />
            )}
            <span style={{
              flex: 1,
              overflow: 'hidden',
              textOverflow: 'ellipsis',
              whiteSpace: 'nowrap',
            }}>{f.name}</span>
            {f.is_sensitive && (
              <Lock size={10} strokeWidth={2}
                    style={{ color: 'var(--ms-sensitive)', flexShrink: 0 }} />
            )}
            {ops}
          </span>
        ),
        icon: f.is_sensitive
          ? <FolderIcon size={14} strokeWidth={1.7}
                        fill={hasFiles ? 'currentColor' : 'none'}
                        style={{ color: 'var(--ms-sensitive)' }} />
          : sub.length > 0
            ? <FolderOpen size={14} strokeWidth={1.7}
                          fill={hasFiles ? 'currentColor' : 'none'}
                          style={{ color: 'var(--ms-ink-muted)' }} />
            : <FolderIcon size={14} strokeWidth={1.7}
                          fill={hasFiles ? 'currentColor' : 'none'}
                          style={{ color: 'var(--ms-ink-muted)' }} />,
        children: sub.length > 0 ? sub : undefined,
      };
    });
  return build(null, false);
}

export function FolderTree({
  folders, projectName, activeFolderId, onSelect, onCreateChild, onCreateRoot, canUpload,
  selectMode, disabledIds, disabledSelfIds, nodeActions, onRenameFolder, onMoveFolder,
  enableDrag, onMoveDrop,
}: Props) {
  const disabledSet = useMemo(() => new Set(disabledIds ?? []), [disabledIds]);
  const selfDisabledSet = useMemo(() => new Set(disabledSelfIds ?? []), [disabledSelfIds]);
  const tree = useMemo(
    () => buildTree(folders, disabledSet, selfDisabledSet, renderNodeOps),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [folders, disabledSet, selfDisabledSet, nodeActions, onRenameFolder, onMoveFolder],
  );

  function renderNodeOps(folder: Folder): React.ReactNode {
    const actions = nodeActions?.(folder);
    if (!actions || (!actions.rename && !actions.move)) return null;
    const items = [
      actions.rename && { key: 'rename', icon: <Pencil size={12} strokeWidth={1.8} />, label: '重命名' },
      actions.move && { key: 'move', icon: <FolderInput size={12} strokeWidth={1.8} />, label: '移动到' },
    ].filter(Boolean) as NonNullable<MenuProps['items']>;
    return (
      <Dropdown
        trigger={['click']}
        menu={{
          items,
          onClick: ({ key, domEvent }) => {
            domEvent.stopPropagation();
            if (key === 'rename') onRenameFolder?.(folder);
            else if (key === 'move') onMoveFolder?.(folder);
          },
        }}
      >
        <button
          aria-label={`文件夹「${folder.name}」操作`}
          onClick={e => e.stopPropagation()}
          className="ms-ghost-btn"
          style={nodeOpsBtn}
          onMouseEnter={e => Object.assign(e.currentTarget.style, ghostIconBtnHover)}
          onMouseLeave={e => Object.assign(e.currentTarget.style, ghostIconBtnRest)}
        >
          <Ellipsis size={14} strokeWidth={2} />
        </button>
      </Dropdown>
    );
  }

  // ── 拖拽换父(仅 enableDrag):语义取落点,排序不持久化 ──────────────────────
  const allowDrop = useCallback<TreeAllowDrop>(({ dragNode, dropNode }) => {
    const src = folders.find(f => f.id === String(dragNode?.key));
    const dst = folders.find(f => f.id === String(dropNode?.key));
    if (!src || !dst) return false;
    if (src.is_sensitive) return false;                      // 三句式①:源 sensitive 禁移
    if (hasSensitiveAncestry(folders, dst.id)) return false; // 三句式②:目标 sensitive 及其子树禁
    if (src.id === dst.id) return false;                     // 自身
    if (isDescendant(folders, src.id, dst.id)) return false; // 目标是源的后代(防环)
    return true;                                             // gap 落点 = 同层移动,一并放行
  }, [folders]);

  const handleDrop = useCallback<TreeOnDrop>((info) => {
    const src = folders.find(f => f.id === String(info.dragNode.key));
    if (!src || src.is_sensitive) return;
    const dst = folders.find(f => f.id === String(info.node.key));
    if (!dst || hasSensitiveAncestry(folders, dst.id)) return;
    // dropToGap=true → 与目标节点同层,新父 = 目标节点之父(目标为根夹时 = null,项目根);
    // false → 移入目标节点内部。允许落在原父(no-op 直接忽略,不打扰后端)
    const newParentId = info.dropToGap ? dst.parent_folder_id : dst.id;
    if ((src.parent_folder_id ?? null) === (newParentId ?? null)) return;
    onMoveDrop?.({ folder: src, newParentId: newParentId ?? null });
  }, [folders, onMoveDrop]);

  const defaultExpanded = useMemo(() => {
    if (!activeFolderId) return [];
    const idById = new Map(folders.map(f => [f.id, f] as const));
    const path: string[] = [];
    const seen = new Set<string>([activeFolderId]);   // 防御环:脏数据成环时 while 不会挂死
    let cur = idById.get(activeFolderId);
    while (cur?.parent_folder_id) {
      if (seen.has(cur.parent_folder_id)) break;
      seen.add(cur.parent_folder_id);
      path.push(cur.parent_folder_id);
      cur = idById.get(cur.parent_folder_id);
    }
    return path;
  }, [activeFolderId, folders]);

  const Header = (
    <div style={{
      display: 'flex', alignItems: 'center',
      padding: '12px 14px 10px',
      gap: 6,
      borderBottom: '1px solid var(--ms-hairline-soft)',
    }}>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{
          fontSize: 10, letterSpacing: '0.08em', textTransform: 'uppercase',
          color: 'var(--ms-ink-subtle)', fontFamily: 'var(--ms-font-mono)',
          fontWeight: 500,
        }}>
          {selectMode ? '选择目标目录' : 'Folders'}
        </div>
        {projectName && (
          <div style={{
            marginTop: 2,
            fontSize: 13, fontWeight: 500, color: 'var(--ms-ink)',
            overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
          }}>{projectName}</div>
        )}
      </div>
      {canUpload && onCreateRoot && (
        <Tooltip title="项目根新建" placement="bottom">
          <button
            onClick={onCreateRoot}
            aria-label="新建一级文件夹"
            className="ms-ghost-btn"
            style={ghostIconBtn}
            onMouseEnter={e => Object.assign(e.currentTarget.style, ghostIconBtnHover)}
            onMouseLeave={e => Object.assign(e.currentTarget.style, ghostIconBtnRest)}
          >
            <Plus size={14} strokeWidth={2} />
          </button>
        </Tooltip>
      )}
      {canUpload && onCreateChild && activeFolderId && (
        <Tooltip title="当前文件夹下新建子" placement="bottom">
          <button
            onClick={onCreateChild}
            aria-label="新建子文件夹"
            className="ms-ghost-btn"
            style={{ ...ghostIconBtn, color: 'var(--ms-accent)' }}
            onMouseEnter={e => Object.assign(e.currentTarget.style, ghostIconBtnHover)}
            onMouseLeave={e => Object.assign(e.currentTarget.style, {
              ...ghostIconBtnRest, color: 'var(--ms-accent)',
            })}
          >
            <Plus size={14} strokeWidth={2} />
            <span style={{ marginLeft: 1, fontSize: 11 }}>子</span>
          </button>
        </Tooltip>
      )}
    </div>
  );

  if (tree.length === 0) {
    return (
      <div>
        {Header}
        <div style={{ padding: '40px 16px', textAlign: 'center', color: 'var(--ms-ink-subtle)' }}>
          <FolderIcon size={28} strokeWidth={1.4}
                      style={{ color: 'var(--ms-hairline)', marginBottom: 12 }} />
          <div style={{ fontSize: 12.5, lineHeight: 1.6 }}>
            {projectName ?? '项目'}<br/>还没有文件夹
          </div>
          {onCreateRoot && (
            <button
              onClick={onCreateRoot}
              style={{
                marginTop: 16,
                padding: '6px 12px',
                background: 'var(--ms-accent)',
                color: '#fff',
                border: 0,
                borderRadius: 'var(--ms-radius-sm)',
                fontFamily: 'inherit',
                fontSize: 12.5,
                fontWeight: 500,
                cursor: 'pointer',
              }}
            >
              + 新建文件夹
            </button>
          )}
        </div>
      </div>
    );
  }

  return (
    <div>
      {Header}
      <div className="ms-folder-tree" style={{ padding: '6px 4px 12px' }}>
        <Tree
          treeData={tree}
          showIcon
          blockNode
          defaultExpandAll={tree.length < 30}
          defaultExpandedKeys={defaultExpanded}
          selectedKeys={activeFolderId ? [activeFolderId] : []}
          onSelect={(keys) => keys[0] && onSelect(keys[0] as string)}
          // icon:false 隐藏 antd 默认拖拽把手(⠿)回收占宽;拖拽能力挂在节点内容
          // wrapper 上(rc-tree 语义),隐藏把手不影响拖拽 —— 抓节点标题即可拖
          draggable={enableDrag ? { icon: false } : false}
          allowDrop={enableDrag ? allowDrop : undefined}
          onDrop={enableDrag ? handleDrop : undefined}
        />
      </div>
    </div>
  );
}

// ─── style consts ────────────────────────────────────────────────────────────
const ghostIconBtn: React.CSSProperties = {
  display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
  height: 24, minWidth: 24, padding: '0 4px',
  background: 'transparent', border: 0, borderRadius: 'var(--ms-radius-sm)',
  color: 'var(--ms-ink-muted)',
  cursor: 'pointer',
  transition: 'all var(--ms-dur-fast) var(--ms-ease)',
};
const nodeOpsBtn: React.CSSProperties = {
  ...ghostIconBtn,
  height: 20, minWidth: 20, padding: '0 2px',
  flexShrink: 0,
};
const ghostIconBtnHover: React.CSSProperties = {
  background: 'var(--ms-hairline-soft)',
  color: 'var(--ms-ink)',
};
const ghostIconBtnRest: React.CSSProperties = {
  background: 'transparent',
  color: 'var(--ms-ink-muted)',
};
