/**
 * BaiduBackupDrawer — 百度网盘备份主抽屉(方案 §3.1/§7)。
 * 头部:绑定状态(绿勾 Badge/未绑定/已过期)+ 绑定/切换账号、新建备份任务、解绑;
 * 主体:任务列表(服务端分页 List + Pagination,惯例参照 TaskCenterDrawer),
 * 轮询 refetchInterval 5s(有进行中任务)/15s;二级视图为 BaiduTaskDetail。
 */
import { App, Badge, Button, Drawer, Empty, List, Pagination, Popconfirm, Progress, Space, Tag, Tooltip, Typography } from 'antd';
import { CloudDownload } from 'lucide-react';
import { useState } from 'react';
import { errorMessage } from '../api/client';
import {
  useBaiduBinding, useBaiduCancelTask, useBaiduDeleteTask, useBaiduRetryTaskFailed,
  useBaiduTasks, useBaiduUnbind,
} from '../api/hooks';
import type { BaiduBackupTask, Me } from '../api/types';
import {
  BAIDU_FAIL_REASON_LABEL,
  BAIDU_TASK_STATUS_COLOR,
  BAIDU_TASK_STATUS_LABEL,
  baiduTaskDisplayStatus,
} from '../lib/labels';
import { BaiduBindModal } from './BaiduBindModal';
import { BaiduNewTaskModal } from './BaiduNewTaskModal';
import { BaiduTaskDetail } from './BaiduTaskDetail';

const PAGE_SIZE = 10;
const dayfmt = (iso: string) => iso.slice(0, 10);

interface Props {
  open: boolean;
  onClose: () => void;
  me: Me;
}

export function BaiduBackupDrawer({ open, onClose, me }: Props) {
  const [bindOpen, setBindOpen] = useState(false);
  const [newTaskOpen, setNewTaskOpen] = useState(false);
  const [detailTaskId, setDetailTaskId] = useState<string | null>(null);

  // 关闭抽屉即清二级视图,下次打开回到列表
  const closeDrawer = () => {
    setDetailTaskId(null);
    onClose();
  };

  return (
    <Drawer
      title="百度网盘备份"
      open={open}
      onClose={closeDrawer}
      width="min(560px, 100vw)"
      maskClosable
      destroyOnHidden
      styles={{ body: { display: 'flex', flexDirection: 'column', overflow: 'hidden', paddingBottom: 0 } }}
    >
      <BindingHeader
        open={open}
        onBind={() => setBindOpen(true)}
        onNewTask={() => setNewTaskOpen(true)}
      />
      {detailTaskId ? (
        <BaiduTaskDetail taskId={detailTaskId} onBack={() => setDetailTaskId(null)} />
      ) : (
        <TaskList onOpenDetail={setDetailTaskId} />
      )}
      <BaiduBindModal open={bindOpen} onClose={() => setBindOpen(false)} />
      <BaiduNewTaskModal open={newTaskOpen} onClose={() => setNewTaskOpen(false)} me={me} />
    </Drawer>
  );
}

// ─── 绑定状态区(§3.1 抽屉头部)───────────────────────────────────────────────
function BindingHeader({ open, onBind, onNewTask }: {
  open: boolean;
  onBind: () => void;
  onNewTask: () => void;
}) {
  const { message } = App.useApp();
  const { data: binding } = useBaiduBinding(open);
  const unbind = useBaiduUnbind();

  const status = binding?.status;
  const bound = !!binding?.bound && status === 'active';
  const expired = status === 'expired';
  const accountName = binding?.nickname || binding?.baidu_uid;

  const doUnbind = async () => {
    try {
      await unbind.mutateAsync();
      message.success('已解绑百度网盘账号');
    } catch (e) {
      message.error(errorMessage(e, '解绑失败'));
    }
  };

  return (
    <div style={{
      flexShrink: 0,
      border: '1px solid var(--ms-hairline)',
      borderRadius: 'var(--ms-radius-md)',
      padding: '12px 14px',
      marginBottom: 12,
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
        {bound ? (
          <Badge status="success" text={<span style={{ fontSize: 13, color: 'var(--ms-ink)' }}>已绑定</span>} />
        ) : expired ? (
          <Badge status="warning" text={<span style={{ fontSize: 13, color: 'var(--ms-ink)' }}>绑定已过期</span>} />
        ) : (
          <Badge status="default" text={<span style={{ fontSize: 13, color: 'var(--ms-ink-muted)' }}>未绑定</span>} />
        )}
        {bound && accountName && (
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            {accountName}{binding?.expires_at ? ` · 授权至 ${dayfmt(binding.expires_at)}` : ''}
          </Typography.Text>
        )}
        {bound && (
          <Popconfirm
            title="解绑百度网盘账号?"
            description="将取消名下进行中的备份任务并作废全部断点;历史任务记录保留。"
            okText="解绑" okButtonProps={{ danger: true }}
            onConfirm={doUnbind}
          >
            <Button size="small" type="text" danger style={{ marginLeft: 'auto' }}
                    loading={unbind.isPending}>
              解绑
            </Button>
          </Popconfirm>
        )}
      </div>
      <div style={{ marginTop: 8, display: 'flex', gap: 8, flexWrap: 'wrap' }}>
        <Button onClick={onBind}>
          {bound ? '切换账号' : expired ? '重新绑定' : '绑定百度网盘账号'}
        </Button>
        <Tooltip title={bound ? '' : '请先绑定百度网盘账号'}>
          <Button type="primary" disabled={!bound} onClick={onNewTask}>
            新建备份任务
          </Button>
        </Tooltip>
      </div>
      {expired && (
        <Typography.Text type="warning" style={{ fontSize: 12, display: 'block', marginTop: 8 }}>
          绑定已过期:进行中的任务会失败终止,请重新绑定后用「全部重试失败」继续。
        </Typography.Text>
      )}
    </div>
  );
}

// ─── 任务列表(服务端分页;轮询 5s/15s)───────────────────────────────────────
function TaskList({ onOpenDetail }: { onOpenDetail: (id: string) => void }) {
  const { message } = App.useApp();
  const [page, setPage] = useState(1);
  const cancel = useBaiduCancelTask();
  const del = useBaiduDeleteTask();
  const retryFailed = useBaiduRetryTaskFailed();

  const { data, isLoading } = useBaiduTasks(PAGE_SIZE, (page - 1) * PAGE_SIZE, true);
  const items = data?.items ?? [];

  const doCancel = async (t: BaiduBackupTask) => {
    try {
      const r = await cancel.mutateAsync(t.id);
      message.success(r.finalized ? '任务已取消' : '取消请求已提交,任务将在最近检查点停止');
    } catch (e) {
      message.error(errorMessage(e, '取消失败'));
    }
  };

  const doRetryFailed = async (t: BaiduBackupTask) => {
    try {
      await retryFailed.mutateAsync(t.id);
      message.success('失败文件已全部重新排队');
    } catch (e) {
      message.error(errorMessage(e, '重试失败'));
    }
  };

  const doDelete = async (t: BaiduBackupTask) => {
    try {
      await del.mutateAsync(t.id);
      message.success('任务记录已删除');
    } catch (e) {
      message.error(errorMessage(e, '删除失败'));
    }
  };

  return (
    <div style={{ flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column' }}>
      <div style={{ flex: 1, minHeight: 0, overflowY: 'auto' }}>
        {!isLoading && items.length === 0 ? (
          <Empty description="暂无备份任务 · 绑定账号后点「新建备份任务」开始"
                 style={{ marginTop: 60 }} image={Empty.PRESENTED_IMAGE_SIMPLE} />
        ) : (
          <List
            loading={isLoading}
            dataSource={items}
            renderItem={(t) => <TaskItem task={t} onOpenDetail={onOpenDetail}
                                         onCancel={doCancel} onRetryFailed={doRetryFailed}
                                         onDelete={doDelete}
                                         actionPending={cancel.isPending || del.isPending || retryFailed.isPending} />}
          />
        )}
      </div>
      {(data?.total ?? 0) > PAGE_SIZE && (
        <div style={{
          flexShrink: 0,
          borderTop: '1px solid #f0f0f0',
          marginTop: 8, padding: '8px 0 12px',
          display: 'flex', justifyContent: 'flex-end',
        }}>
          <Pagination size="small" current={page} total={data?.total ?? 0}
                      pageSize={PAGE_SIZE} showSizeChanger={false}
                      showTotal={(t) => `共 ${t} 条`}
                      onChange={setPage} />
        </div>
      )}
    </div>
  );
}

function TaskItem({ task: t, onOpenDetail, onCancel, onRetryFailed, onDelete, actionPending }: {
  task: BaiduBackupTask;
  onOpenDetail: (id: string) => void;
  onCancel: (t: BaiduBackupTask) => void;
  onRetryFailed: (t: BaiduBackupTask) => void;
  onDelete: (t: BaiduBackupTask) => void;
  actionPending: boolean;
}) {
  const display = baiduTaskDisplayStatus(t);
  const active = t.status === 'enumerating' || t.status === 'running';
  const terminal = !active;
  // 「全部重试失败」:任务 failed 且存在可重试行(§3.1);列表未回传可重试行数时回退 failed_files>0
  const retryable = t.retryable_failed_files != null
    ? t.retryable_failed_files > 0
    : (t.failed_files ?? 0) > 0;

  const total = t.total_files ?? 0;
  const done = t.done_files ?? 0;
  const pct = total > 0 ? Math.round((done / total) * 100) : (t.status === 'completed' ? 100 : 0);
  const targetLabel = t.target_folder_name
    ? `${t.project_name ?? t.project_id} / ${t.target_folder_name}`
    : t.target_auto_created
      ? `${t.project_name ?? t.project_id} / 项目根(自动创建承接夹)`
      : `${t.project_name ?? t.project_id} / (已删除)`;

  return (
    <List.Item actions={[
      <Button key="detail" size="small" type="link" onClick={() => onOpenDetail(t.id)}>查看</Button>,
      active ? (
        <Popconfirm key="cancel" title="取消该任务?"
                    description="未完成文件将停止导入(已完成文件保留)。"
                    okText="取消任务" okButtonProps={{ danger: true }}
                    onConfirm={() => onCancel(t)}>
          <Button size="small" type="link" danger disabled={actionPending}>取消</Button>
        </Popconfirm>
      ) : null,
      t.status === 'failed' && retryable ? (
        <Tooltip key="retry" title="所有可重试的失败文件重新排队(断点续传)">
          <Button size="small" type="link" disabled={actionPending}
                  onClick={() => onRetryFailed(t)}>
            全部重试失败
          </Button>
        </Tooltip>
      ) : null,
      terminal ? (
        <Popconfirm key="delete" title="删除该任务记录?"
                    description="仅删除任务记录与进度,已导入的文件不受影响。"
                    okText="删除" okButtonProps={{ danger: true }}
                    onConfirm={() => onDelete(t)}>
          <Button size="small" type="text" danger icon={null} disabled={actionPending}>删除</Button>
        </Popconfirm>
      ) : null,
    ].filter(Boolean) as React.ReactNode[]}>
      <List.Item.Meta
        avatar={<CloudDownload size={18} strokeWidth={1.7}
                               style={{ color: 'var(--ms-ink-muted)', marginTop: 4 }} />}
        title={
          <Space size={6}>
            <Typography.Text ellipsis={{ tooltip: t.source_dir }}
                             style={{ maxWidth: 300, fontSize: 13 }}>{t.source_dir}</Typography.Text>
            <Tag color={BAIDU_TASK_STATUS_COLOR[display]} style={{ marginInlineEnd: 0 }}>
              {BAIDU_TASK_STATUS_LABEL[display] ?? display}
            </Tag>
          </Space>
        }
        description={
          <div>
            <div style={{ fontSize: 11.5, color: 'var(--ms-ink-muted)', marginBottom: 4 }}>
              → {targetLabel}
            </div>
            <Progress percent={pct} size="small" showInfo={false}
                      status={t.status === 'failed' ? 'exception'
                        : t.status === 'completed' ? 'success' : 'active'} />
            <Space size="middle" style={{ fontSize: 11.5, color: 'var(--ms-ink-muted)', flexWrap: 'wrap' }}>
              <span>{done} / {total} 个文件</span>
              <span>{fmtBytes(t.done_bytes)}{t.total_bytes != null ? ` / ${fmtBytes(t.total_bytes)}` : ''}</span>
              {active && (
                <span>{t.eta_seconds != null ? `预计剩余 ${fmtEta(t.eta_seconds)}` : '估算中'}</span>
              )}
              {t.status === 'failed' && t.fail_reason && (
                <span style={{ color: '#ff4d4f' }}>
                  {BAIDU_FAIL_REASON_LABEL[t.fail_reason] ?? t.fail_reason}
                </span>
              )}
              {t.status === 'completed' && total === 0 && <span>源目录为空</span>}
              {t.status === 'cancelled' && (t.cancelled_files ?? 0) > 0 && (
                <span>已取消 {t.cancelled_files} 个文件</span>
              )}
            </Space>
          </div>
        }
      />
    </List.Item>
  );
}

// ─── fmt helpers(与 TaskCenterDrawer 同口径)────────────────────────────────
function fmtBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(1)} MB`;
  if (n < 1024 ** 4) return `${(n / 1024 ** 3).toFixed(2)} GB`;
  return `${(n / 1024 ** 4).toFixed(2)} TB`;
}

function fmtEta(seconds: number): string {
  if (seconds < 60) return '不足 1 分钟';
  const m = Math.round(seconds / 60);
  if (m < 60) return `约 ${m} 分钟`;
  const h = Math.floor(m / 60);
  const rm = m % 60;
  return rm ? `约 ${h} 小时 ${rm} 分` : `约 ${h} 小时`;
}
