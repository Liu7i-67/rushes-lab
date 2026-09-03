/**
 * FolderTrashModal — 当前文件夹的回收站(软删文件列表)。
 * 对 folder admin 开放:恢复(回到文件列表)/ 彻底删除(硬删,不可恢复)。
 */
import { App, Button, Empty, Modal, Popconfirm, Table, Tooltip } from 'antd';
import { RotateCcw, Trash2 } from 'lucide-react';
import { AssetThumbnail } from './AssetThumbnail';
import { errorMessage } from '../api/client';
import { usePurgeAsset, useRestoreAsset, useTrashAssets } from '../api/hooks';
import type { Asset } from '../api/types';

interface Props {
  folderId: string;
  open: boolean;
  onClose: () => void;
}

function fmtBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(1)} MB`;
  return `${(n / 1024 ** 3).toFixed(2)} GB`;
}

export function FolderTrashModal({ folderId, open, onClose }: Props) {
  const { message } = App.useApp();
  const { data: items, isLoading } = useTrashAssets(folderId, open);
  const restore = useRestoreAsset();
  const purge = usePurgeAsset();

  const handleRestore = async (a: Asset) => {
    try {
      await restore.mutateAsync(a.id);
      message.success(`「${a.filename}」已恢复`);
    } catch (e) {
      message.error(errorMessage(e, '恢复失败'));
    }
  };

  const handlePurge = async (a: Asset) => {
    try {
      await purge.mutateAsync(a.id);
      message.success(`「${a.filename}」已彻底删除`);
    } catch (e) {
      message.error(errorMessage(e, '彻底删除失败'));
    }
  };

  const cols = [
    {
      title: '文件', dataIndex: 'filename', ellipsis: true,
      render: (v: string, a: Asset) => (
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <AssetThumbnail asset={a} />
          <span style={{ color: 'var(--ms-ink)' }}>{v}</span>
        </div>
      ),
    },
    {
      title: '大小', dataIndex: 'size_bytes', width: 90,
      render: (n: number) => (
        <span className="ms-mono" style={{ color: 'var(--ms-ink-muted)', fontSize: 12.5 }}>
          {fmtBytes(n)}
        </span>
      ),
    },
    {
      title: '删除时间', dataIndex: 'deleted_at', width: 150,
      render: (v: string | null) => (
        <span style={{ color: 'var(--ms-ink-muted)', fontSize: 12.5 }}>
          {v ? new Date(v).toLocaleString('zh-CN', {
            month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit',
          }) : '—'}
        </span>
      ),
    },
    {
      title: '', width: 110,
      render: (_: unknown, a: Asset) => (
        <div style={{ display: 'flex', gap: 4, justifyContent: 'flex-end' }}>
          <Tooltip title="恢复到文件夹">
            <Button type="text" size="small" icon={<RotateCcw size={13} strokeWidth={1.8} />}
                    loading={restore.isPending && restore.variables === a.id}
                    onClick={() => handleRestore(a)} />
          </Tooltip>
          <Popconfirm
            title={`彻底删除「${a.filename}」?`}
            description="MinIO 原对象一并删除,不可恢复"
            okText="彻底删除" okButtonProps={{ danger: true }}
            onConfirm={() => handlePurge(a)}
          >
            <Button type="text" size="small" danger icon={<Trash2 size={13} strokeWidth={1.8} />}
                    loading={purge.isPending && purge.variables === a.id} />
          </Popconfirm>
        </div>
      ),
    },
  ];

  return (
    <Modal
      title="回收站(已删除文件)"
      open={open}
      onCancel={onClose}
      footer={null}
      width="min(720px, 92vw)"
      destroyOnClose
    >
      <div style={{ fontSize: 12.5, color: 'var(--ms-ink-muted)', marginBottom: 12 }}>
        软删除的文件保留在此;删除文件夹时,回收站内的文件会被一并彻底清除。
      </div>
      <Table
        dataSource={items ?? []}
        rowKey="id"
        loading={isLoading}
        columns={cols}
        size="small"
        pagination={{ pageSize: 10, hideOnSinglePage: true }}
        locale={{
          emptyText: (
            <Empty description="回收站是空的" style={{ padding: '24px 0' }} />
          ),
        }}
      />
    </Modal>
  );
}
