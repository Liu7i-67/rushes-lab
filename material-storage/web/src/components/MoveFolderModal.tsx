/**
 * MoveFolderModal — 目录「移动到」(W5,六项优化 2026-10-17)。
 * 目标选择复用 FolderTree selectMode/disabledIds(先例 BaiduNewTaskModal),
 * 目标集合含项目根(树外独立选项;parent_folder_id=null = 移为一级)。
 * 禁选:sensitive 及其整棵子树(三句式②)+ 自身及自身后代(防环)。
 * sensitive 源的「移动」入口本就不可达(三句式①,调用方闸门),这里只做目标侧预判。
 */
import { App, Modal, Typography } from 'antd';
import { Folder as FolderIcon } from 'lucide-react';
import { useMemo, useState } from 'react';
import { useMoveFolder } from '../api/hooks';
import { errorMessage } from '../api/client';
import type { Folder } from '../api/types';
import { FolderTree } from './FolderTree';

interface Props {
  open: boolean;
  onClose: () => void;
  /** 被移动的文件夹 */
  folder: Folder;
  /** 项目全量可见 folder(拼树 + 禁选集合计算) */
  folders: Folder[];
  projectName?: string;
}

type Target = { kind: 'root' } | { kind: 'folder'; id: string; name: string };

/** folderId 的全部后代 id(显式栈迭代,沿 parent_folder_id 链向下收集)。*/
function collectDescendantIds(folders: Folder[], folderId: string): Set<string> {
  const childrenOf = new Map<string, string[]>();
  for (const f of folders) {
    if (!f.parent_folder_id) continue;
    const arr = childrenOf.get(f.parent_folder_id) ?? [];
    arr.push(f.id);
    childrenOf.set(f.parent_folder_id, arr);
  }
  const out = new Set<string>();
  const stack = [...(childrenOf.get(folderId) ?? [])];
  while (stack.length) {
    const id = stack.pop() as string;
    if (out.has(id)) continue;   // 防御环
    out.add(id);
    stack.push(...(childrenOf.get(id) ?? []));
  }
  return out;
}

export function MoveFolderModal({ open, onClose, folder, folders, projectName }: Props) {
  const move = useMoveFolder();
  const { message } = App.useApp();
  const [target, setTarget] = useState<Target | null>(null);

  // 禁选 = sensitive 全集(②)+ 自身 + 自身后代(防环);三句式③「移出敏感子树」
  // 的普通夹在 GUI 本不可达(孤儿不进树),无需为其做入口
  const disabledIds = useMemo(() => {
    const ids = folders.filter(f => f.is_sensitive).map(f => f.id);
    ids.push(folder.id, ...collectDescendantIds(folders, folder.id));
    return ids;
  }, [folders, folder.id]);

  const submit = async () => {
    if (!target) {
      message.warning('请先选择目标位置');
      return;
    }
    try {
      await move.mutateAsync({
        folder_id: folder.id,
        parent_folder_id: target.kind === 'root' ? null : target.id,
        project_id: folder.project_id,
      });
      message.success(
        `文件夹「${folder.name}」已移动到${target.kind === 'root' ? '项目根' : `「${target.name}」`}`,
      );
      onClose();
    } catch (e) {
      message.error(errorMessage(e, '移动文件夹失败'));
    }
  };

  return (
    <Modal
      title={`移动文件夹「${folder.name}」`}
      open={open}
      onCancel={onClose}
      okText="移动"
      okButtonProps={{ disabled: !target, loading: move.isPending }}
      onOk={submit}
      destroyOnHidden
      maskClosable={false}
      width="min(520px, 100vw)"
    >
      <div style={{ fontSize: 12.5, color: 'var(--ms-ink-muted)', margin: '4px 0 12px' }}>
        当前位置:<Typography.Text code style={{ fontSize: 12 }}>{folder.minio_prefix || '项目根'}</Typography.Text>
        <span style={{ marginLeft: 12 }}>选择目标位置(敏感目录及其子目录不可选):</span>
      </div>
      {/* 项目根 = 树外独立选项(parent_folder_id=null 移为一级,§5.2 合法方向) */}
      <div
        onClick={() => setTarget({ kind: 'root' })}
        style={{
          display: 'flex', alignItems: 'center', gap: 8,
          padding: '7px 10px',
          border: `1px solid ${target?.kind === 'root' ? 'var(--ms-accent)' : 'var(--ms-hairline)'}`,
          background: target?.kind === 'root' ? 'var(--ms-accent-soft)' : 'transparent',
          borderRadius: 'var(--ms-radius-sm)',
          cursor: 'pointer', fontSize: 13, color: 'var(--ms-ink)',
        }}>
        <FolderIcon size={14} strokeWidth={1.7} style={{ color: 'var(--ms-ink-muted)', flexShrink: 0 }} />
        <span style={{ fontWeight: target?.kind === 'root' ? 500 : 400 }}>项目根</span>
        <span style={{ fontSize: 11, color: 'var(--ms-ink-subtle)' }}>
          移为项目一级文件夹
        </span>
      </div>
      <div style={{
        marginTop: 8,
        border: '1px solid var(--ms-hairline)',
        borderRadius: 'var(--ms-radius-sm)',
        maxHeight: 300, overflow: 'auto',
      }}>
        <FolderTree
          folders={folders}
          projectName={projectName}
          selectMode
          disabledIds={disabledIds}
          activeFolderId={target?.kind === 'folder' ? target.id : null}
          onSelect={(fid) => {
            const f = folders.find(x => x.id === fid);
            if (f) setTarget({ kind: 'folder', id: f.id, name: f.name });
          }}
        />
      </div>
      <Typography.Text type="secondary" style={{ fontSize: 12, display: 'block', marginTop: 12 }}>
        移动后子文件夹与文件的访问权限跟随新位置;目录存储前缀同步更新,已上传文件本身不迁移。
      </Typography.Text>
    </Modal>
  );
}
