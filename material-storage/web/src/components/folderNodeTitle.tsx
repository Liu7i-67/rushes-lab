/**
 * folder 树单节点的 title / icon 渲染。
 * 2026-10-22 从 FolderTree.tsx 抽出(加数量 pill 后主文件将超 400 行)。
 *
 * 两条**正交**规则(与 app 端 folder_row.dart 对齐):
 * - 图标:subtree_file_count > 0 → 实心,颜色 --ms-ink(深色);否则空心,颜色
 *   --ms-ink-muted(灰)。敏感夹无论实/空恒用 --ms-sensitive(形状规则不变:
 *   敏感/叶子 → Folder,有子节点 → FolderOpen)。
 * - 数字:direct_file_count > 0 才显示「N 项」;= 0 一律不显示(即使子树有文件)。
 *   选择器(selectMode,如批量移动/移动到/百度目标夹)不显示数量 —— 语义是
 *   「选目标」而非「浏览内容」,与 app 端选择器一致(需求 D4)。
 */
import { Folder as FolderIcon, FolderOpen, Lock } from 'lucide-react';
import type { ReactNode } from 'react';
import type { Folder } from '../api/types';

interface Args {
  folder: Folder;
  /** 节点或其敏感祖先被禁选(antd Tree disabled),仅用于敏感竖条的 title 文案 */
  disabled: boolean;
  /** 调用方按权限渲染的操作菜单,已算好;无权限时为 null */
  ops: ReactNode;
  /** 是否有子节点 —— 决定 FolderOpen / FolderIcon 形状(语义见文件头) */
  hasChildren: boolean;
  /** 是否显示「N 项」pill,缺省 true;选择器(selectMode)传 false(D4) */
  showCount?: boolean;
}

export function renderFolderNode({
  folder: f, disabled, ops, hasChildren, showCount = true,
}: Args): {
  title: ReactNode;
  icon: ReactNode;
} {
  // 子树含活跃文件(subtree_file_count>0,软删不计)→ 图标实心;空夹保持空心。
  // lucide 透传 fill 覆盖默认 fill="none"(已核实 v1.16.0 Icon 源码)。
  const hasFiles = (f.subtree_file_count ?? 0) > 0;
  // 直属活跃文件数:仅 GET /folders 列表端点回填,其余端点恒 0 → 不显示。
  const directCount = f.direct_file_count ?? 0;
  const iconColor = hasFiles ? 'var(--ms-ink)' : 'var(--ms-ink-muted)';

  const title = (
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
      {showCount && directCount > 0 && (
        // 轻量 pill,不抢名称层级。tokens.css 无 --ms-surface-2,次级底色取全站
        // 通用的 --ms-hairline-soft(#F0EEE9);字色 --ms-ink-muted。
        <span style={{
          flexShrink: 0,
          fontSize: 11,
          lineHeight: '16px',
          padding: '0 6px',
          borderRadius: 999,
          background: 'var(--ms-hairline-soft)',
          color: 'var(--ms-ink-muted)',
          fontVariantNumeric: 'tabular-nums',
        }}>{directCount} 项</span>
      )}
      {f.is_sensitive && (
        <Lock size={10} strokeWidth={2}
              style={{ color: 'var(--ms-sensitive)', flexShrink: 0 }} />
      )}
      {ops}
    </span>
  );

  const icon = f.is_sensitive
    ? <FolderIcon size={14} strokeWidth={1.7}
                  fill={hasFiles ? 'currentColor' : 'none'}
                  style={{ color: 'var(--ms-sensitive)' }} />
    : hasChildren
      ? <FolderOpen size={14} strokeWidth={1.7}
                    fill={hasFiles ? 'currentColor' : 'none'}
                    style={{ color: iconColor }} />
      : <FolderIcon size={14} strokeWidth={1.7}
                    fill={hasFiles ? 'currentColor' : 'none'}
                    style={{ color: iconColor }} />;

  return { title, icon };
}
