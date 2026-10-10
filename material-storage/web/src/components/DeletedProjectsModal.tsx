/**
 * DeletedProjectsModal — 已删除项目列表(项目逻辑删除:深隐藏 + 可恢复)。
 * 入口显隐由调用方门控(is_project_deleter ∨ system admin,后端 require_project_deleter 同规则);
 * 服务端分页(q 过 code/name,deleted_at 倒序,带 deleted_by_name)+ 单行恢复(§7/§8)。
 */
import { App, Button, Empty, Input, Modal, Pagination, Popconfirm, Skeleton, Tooltip } from 'antd';
import { RotateCcw } from 'lucide-react';
import { useState } from 'react';
import dayjs from 'dayjs';
import {
  DELETED_PROJECTS_PAGE_SIZE, useDeletedProjects, useRestoreProject,
} from '../api/hooks';
import { errorMessage } from '../api/client';
import type { DeletedProject } from '../api/types';

interface Props {
  open: boolean;
  onClose: () => void;
}

const VIS_LABEL: Record<string, string> = { public: '公开', private: '私有', stealth: '机密' };

export function DeletedProjectsModal({ open, onClose }: Props) {
  const { message } = App.useApp();
  const [q, setQ] = useState('');
  const [page, setPage] = useState(1);
  const restore = useRestoreProject();

  // open 门控:关闭态不发请求;q 变化重置回第 1 页(Input onChange 逐键触发,清空即回)
  const handleQ = (v: string) => { setQ(v); setPage(1); };
  const { data, isLoading } = useDeletedProjects(
    open
      ? { q, limit: DELETED_PROJECTS_PAGE_SIZE, offset: (page - 1) * DELETED_PROJECTS_PAGE_SIZE }
      : null,
  );
  const items = data?.items ?? [];
  const total = data?.total ?? 0;

  const handleRestore = async (p: DeletedProject) => {
    try {
      await restore.mutateAsync(p.id);
      message.success(`项目「${p.name}」已恢复`);
    } catch (e) {
      message.error(errorMessage(e, '恢复失败'));
    }
  };

  return (
    <Modal title={`已删除项目${total > 0 ? `(${total})` : ''}`}
           open={open} onCancel={onClose} footer={null}
           width="min(680px, calc(100vw - 16px))"
           afterOpenChange={(o) => { if (!o) { setQ(''); setPage(1); } }}>
      <div style={{ fontSize: 12.5, color: 'var(--ms-ink-muted)', marginBottom: 12 }}>
        已删除的项目对所有成员(含系统管理员)隐藏,但数据、授权与分享链接全部保留;
        恢复后立即回到项目列表,原成员权限不变。
      </div>
      <Input.Search
        value={q}
        onChange={e => handleQ(e.target.value)}
        onSearch={v => handleQ(v.trim())}
        allowClear
        placeholder="搜项目代号 / 名称…"
        style={{ marginBottom: 12 }}
      />
      {isLoading ? (
        <Skeleton active paragraph={{ rows: 3 }} />
      ) : items.length === 0 ? (
        <Empty image={Empty.PRESENTED_IMAGE_SIMPLE}
               description={<span style={{ color: 'var(--ms-ink-subtle)' }}>
                 {q ? '无匹配项目' : '没有已删除的项目'}
               </span>}
               style={{ padding: '24px 0' }} />
      ) : (
        <div style={{
          display: 'flex', flexDirection: 'column', gap: 6,
          maxHeight: 'min(420px, 60vh)', overflowY: 'auto',
        }}>
          {items.map(p => (
            <div key={p.id} style={{
              display: 'flex', alignItems: 'center', gap: 10,
              padding: '10px 12px', background: 'var(--ms-canvas)',
              border: '1px solid var(--ms-hairline-soft)', borderRadius: 'var(--ms-radius-sm)',
              flexShrink: 0,
            }}>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                  <span style={{
                    fontSize: 13, fontWeight: 500, color: 'var(--ms-ink)',
                    overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
                  }}>{p.name}</span>
                  <span style={{
                    fontFamily: 'var(--ms-font-mono)', fontSize: 10.5,
                    color: 'var(--ms-ink-subtle)', padding: '1px 7px',
                    background: 'var(--ms-hairline-soft)', borderRadius: 3,
                  }}>{p.code}</span>
                  <span style={{
                    fontSize: 10.5, color: 'var(--ms-ink-muted)',
                    padding: '1px 6px', borderRadius: 3,
                    background: 'var(--ms-hairline-soft)',
                  }}>{VIS_LABEL[p.visibility] ?? p.visibility}</span>
                </div>
                <div style={{
                  marginTop: 3, fontSize: 11, color: 'var(--ms-ink-subtle)',
                  fontFamily: 'var(--ms-font-mono)',
                }}>
                  删除于 {dayjs(p.deleted_at).format('YYYY-MM-DD HH:mm')}
                  {p.deleted_by_name ? ` · 操作人 ${p.deleted_by_name}` : ''}
                </div>
              </div>
              <Popconfirm
                title={`恢复项目「${p.name}」?`}
                description="恢复后项目立即对所有原成员重新可见"
                okText="恢复"
                onConfirm={() => handleRestore(p)}
              >
                <Tooltip title="恢复到项目列表">
                  <Button size="small" icon={<RotateCcw size={12} strokeWidth={2} />}
                          loading={restore.isPending && restore.variables === p.id}>
                    恢复
                  </Button>
                </Tooltip>
              </Popconfirm>
            </div>
          ))}
        </div>
      )}
      {total > DELETED_PROJECTS_PAGE_SIZE && (
        <div style={{ marginTop: 12, display: 'flex', justifyContent: 'flex-end' }}>
          <Pagination
            size="small"
            current={page}
            pageSize={DELETED_PROJECTS_PAGE_SIZE}
            total={total}
            showSizeChanger={false}
            showTotal={(t) => `共 ${t} 个`}
            onChange={setPage}
          />
        </div>
      )}
      <div style={{ display: 'flex', justifyContent: 'flex-end', marginTop: 12 }}>
        <Button onClick={onClose}>关闭</Button>
      </div>
    </Modal>
  );
}
