/**
 * /admin/baidu-tasks — 管理员备份任务视图(W3,需求 2026-10-14 F10/F12/F13/F14)。
 *
 * 全系统百度网盘备份任务只读观测:
 * - 列表:状态 Select + q 搜索(后端 username/name/source_dir ilike)+ 服务端分页;
 *   存在活动任务(enumerating/running)时 15s 轮询,无则不轮;
 * - 行点击 → 抽屉:任务详情(含 cancel_reason/bound_baidu_uid/binding/调度观测字段)
 *   + 文件明细表(服务端分页 + 状态 Tabs 过滤,失败行展示 last_error);
 * - 状态/文件状态/失败原因文案与颜色直接复用 labels.ts 现成映射;展示后端**原始
 *   status**,不做 baiduTaskDisplayStatus 的 queued 派生(admin 看原始事实,方案 §3.2);
 * - 进度 =(done+skipped+cancelled)/total;enumerating 阶段聚合列未就绪,不渲染进度条
 *   (用户侧现状渲染 0% 条,admin 页改为不渲染属改进)。
 *
 * 布局参照 BaiduBackupDrawer.tsx / BaiduTaskDetail.tsx(只读参照,未改动它们)。
 */
import {
  Alert, Drawer, Input, Progress, Select, Space, Spin, Table, Tabs, Tag, Tooltip,
  Typography,
} from 'antd';
import type { ColumnsType } from 'antd/es/table';
import { useState } from 'react';
import dayjs from 'dayjs';
import {
  useAdminBaiduTask, useAdminBaiduTaskFiles, useAdminBaiduTasks, useMe,
} from '../api/hooks';
import type { AdminBaiduTask, AdminBaiduTaskFile } from '../api/types';
import {
  BAIDU_FAIL_REASON_LABEL,
  BAIDU_FILE_STATUS_COLOR,
  BAIDU_FILE_STATUS_LABEL,
  BAIDU_TASK_STATUS_COLOR,
  BAIDU_TASK_STATUS_LABEL,
} from '../lib/labels';
import { useCompactViewport } from '../lib/use-viewports';

const PAGE_SIZE = 20;       // 列表页大小(对齐 AdminUsersPage 服务端分页口径)
const FILE_PAGE_SIZE = 20;  // 抽屉文件明细页大小(对齐用户侧 BaiduTaskDetail)

/** cancel_reason token → 文案(tables.py 取值域;labels.ts 无现成映射,页内小表)。 */
const CANCEL_REASON_LABEL: Record<string, string> = {
  user_cancel: '用户取消',
  binding_replaced: '绑定被更换',
};

/** 绑定行 status → 文案(baidu_bindings.status:active/expired/unbound)。 */
const BINDING_STATUS_LABEL: Record<string, string> = {
  active: '正常',
  expired: '已过期',
  unbound: '已解绑',
};

// 状态 Select:后端白名单 5 项,文案走 labels.ts 现成映射(不含派生态 queued)
const STATUS_OPTIONS = [
  { value: '', label: '全部状态' },
  { value: 'enumerating', label: BAIDU_TASK_STATUS_LABEL.enumerating },
  { value: 'running', label: BAIDU_TASK_STATUS_LABEL.running },
  { value: 'completed', label: BAIDU_TASK_STATUS_LABEL.completed },
  { value: 'cancelled', label: BAIDU_TASK_STATUS_LABEL.cancelled },
  { value: 'failed', label: BAIDU_TASK_STATUS_LABEL.failed },
];

const FILE_TABS = [
  { key: 'all', label: '全部' },
  { key: 'pending', label: '等待' },
  { key: 'importing', label: '导入中' },
  { key: 'success', label: '成功' },
  { key: 'skipped_exists', label: '跳过' },
  { key: 'failed', label: '失败' },
  { key: 'cancelled', label: '已取消' },
];

export default function AdminBaiduTasksPage() {
  const { data: me } = useMe();
  const [q, setQ] = useState('');
  const [status, setStatus] = useState<string | undefined>(undefined);
  const [page, setPage] = useState(1);
  const [detailId, setDetailId] = useState<string | null>(null);

  const { data, isLoading } = useAdminBaiduTasks({
    ...(status ? { status } : {}),
    ...(q.trim() ? { q: q.trim() } : {}),
    limit: PAGE_SIZE,
    offset: (page - 1) * PAGE_SIZE,
  });

  // 过滤条件变化一律重置回第 1 页(服务端分页口径)
  const handleQ = (v: string) => { setQ(v); setPage(1); };
  const handleStatus = (v: string) => { setStatus(v === '' ? undefined : v); setPage(1); };

  // 后端对目录接口 enforce system admin;前端仅做体验提示(直连 URL 时后端 403 拦截)
  if (me && !me.is_system_admin) {
    return (
      <div className="ms-enter" style={{ maxWidth: 520 }}>
        <Alert
          type="warning" showIcon
          message="只有系统管理员可以查看备份任务"
          description="如需查看全系统备份任务,请联系系统管理员。"
        />
      </div>
    );
  }

  const columns: ColumnsType<AdminBaiduTask> = [
    {
      title: '用户',
      dataIndex: 'user',
      width: 150,
      render: (_v, row) => (
        <div style={{ minWidth: 0 }}>
          {/* name 为主(NOT NULL),username 副显(可空,飞书账号无本地用户名) */}
          <div style={{ fontSize: 13, color: 'var(--ms-ink)' }}>{row.user.name}</div>
          {row.user.username && (
            <Tooltip title={row.user.username}>
              <div className="ms-mono" style={{
                fontSize: 11, color: 'var(--ms-ink-subtle)',
                overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
              }}>{row.user.username}</div>
            </Tooltip>
          )}
        </div>
      ),
    },
    {
      title: '状态',
      dataIndex: 'status',
      width: 100,
      render: (v: string) => (
        <Tag color={BAIDU_TASK_STATUS_COLOR[v]} style={{ marginInlineEnd: 0 }}>
          {BAIDU_TASK_STATUS_LABEL[v] ?? v}
        </Tag>
      ),
    },
    {
      title: '进度',
      key: 'progress',
      width: 150,
      render: (_v, row) => {
        // enumerating 阶段清单未就绪(聚合列 NULL→0),渲染 0% 条是误导 → 不渲染(§3.2)
        if (row.status === 'enumerating') return null;
        return (
          <Progress
            percent={taskPct(row)}
            size="small"
            style={{ maxWidth: 130 }}
            status={progressStatus(row.status)}
          />
        );
      },
    },
    {
      title: '失败数',
      dataIndex: 'failed_files',
      width: 76,
      render: (v: number) => (
        <span style={{ fontSize: 12.5, color: v > 0 ? '#ff4d4f' : 'var(--ms-ink-subtle)' }}>{v}</span>
      ),
    },
    {
      title: '源目录',
      dataIndex: 'source_dir',
      ellipsis: { showTitle: false },
      render: (v: string) => (
        <Tooltip title={v} placement="topLeft">
          <span style={{ fontSize: 12.5 }}>{v}</span>
        </Tooltip>
      ),
    },
    {
      title: '目标',
      key: 'target',
      width: 200,
      ellipsis: { showTitle: false },
      render: (_v, row) => {
        // 夹已删 target_folder 为 null(SET NULL),显示「已删」
        const text = `${row.project.name} / ${row.target_folder?.name ?? '已删'}`;
        return (
          <Tooltip title={text} placement="topLeft">
            <span style={{
              fontSize: 12.5,
              color: row.target_folder ? 'var(--ms-ink-muted)' : 'var(--ms-amber)',
            }}>{text}</span>
          </Tooltip>
        );
      },
    },
    {
      title: '创建时间',
      dataIndex: 'created_at',
      width: 130,
      render: (v: string) => (
        <span style={{ fontSize: 12, color: 'var(--ms-ink-muted)', whiteSpace: 'nowrap' }}>
          {dayjs(v).format('YYYY-MM-DD HH:mm')}
        </span>
      ),
    },
    {
      title: '失败原因',
      dataIndex: 'fail_reason',
      ellipsis: { showTitle: false },
      render: (v: string | null, row) => {
        if (!v) return null;
        // fail_reason 是 7 个固定 token,走 labels.ts 现成映射(缺 key 回落 raw)
        const text = BAIDU_FAIL_REASON_LABEL[v] ?? v;
        return (
          <Tooltip title={text} placement="topLeft">
            <span style={{
              fontSize: 12,
              color: row.status === 'failed' ? '#ff4d4f' : 'var(--ms-ink-muted)',
            }}>{text}</span>
          </Tooltip>
        );
      },
    },
  ];

  return (
    <div className="ms-enter">
      <div style={{
        display: 'flex', alignItems: 'baseline', justifyContent: 'space-between',
        gap: 24, marginBottom: 'var(--ms-sp-xl)',
      }}>
        <div>
          <h1 style={{
            margin: 0, fontFamily: 'var(--ms-font-display)',
            fontSize: 32, fontWeight: 500, letterSpacing: '-0.02em',
            color: 'var(--ms-ink)', lineHeight: 1.1,
          }}>备份任务</h1>
          <p style={{ margin: '8px 0 0', fontSize: 13, color: 'var(--ms-ink-muted)' }}>
            全系统百度网盘备份任务只读观测 — 状态 / 进度 / 失败原因与文件明细
          </p>
        </div>
      </div>

      <FilterBar q={q} setQ={handleQ} status={status} setStatus={handleStatus} total={data?.total} />

      <Table<AdminBaiduTask>
        rowKey="id"
        columns={columns}
        dataSource={data?.items ?? []}
        loading={isLoading}
        onRow={(row) => ({
          onClick: () => setDetailId(row.id),
          style: { cursor: 'pointer' },
        })}
        pagination={{
          current: page,
          pageSize: PAGE_SIZE,
          total: data?.total ?? 0,
          showSizeChanger: false,
          showTotal: (t) => `共 ${t} 个任务`,
          onChange: (p) => setPage(p),
        }}
        locale={{ emptyText: '暂无备份任务' }}
      />

      {/* 条件挂载:抽屉关闭不挂载,详情/文件明细请求不发出(对齐 EditUserModal 惯例) */}
      {detailId && <TaskDetailDrawer taskId={detailId} onClose={() => setDetailId(null)} />}
    </div>
  );
}

// ─── 过滤栏(状态 Select + q 搜索 + 总数)─────────────────────────────────────
function FilterBar({ q, setQ, status, setStatus, total }: {
  q: string; setQ: (v: string) => void;
  status: string | undefined; setStatus: (v: string) => void;
  total?: number;
}) {
  const compact = useCompactViewport();
  return (
    <div style={{ display: 'flex', gap: 12, marginBottom: 16, flexWrap: 'wrap', alignItems: 'center' }}>
      <Input.Search
        value={q}
        onChange={e => setQ(e.target.value)}
        onSearch={v => setQ(v.trim())}
        allowClear placeholder="搜用户名 / 姓名 / 源目录…"
        style={compact ? { flex: 1, minWidth: 0 } : { width: 260 }} />
      <Select
        value={status ?? ''}
        onChange={setStatus}
        style={compact ? { flex: 1, minWidth: 0 } : { width: 140 }}
        options={STATUS_OPTIONS} />
      {total !== undefined && (
        <span style={{ marginLeft: 'auto', fontSize: 12.5, color: 'var(--ms-ink-muted)' }}>
          共 <span className="ms-mono" style={{ color: 'var(--ms-ink)' }}>{total}</span> 个任务
        </span>
      )}
    </div>
  );
}

// ─── 任务详情抽屉(详情字段 + 文件明细分页)──────────────────────────────────
function TaskDetailDrawer({ taskId, onClose }: { taskId: string; onClose: () => void }) {
  const { data: task, isLoading } = useAdminBaiduTask(taskId);
  const [fileStatus, setFileStatus] = useState<string>('all');
  const [filePage, setFilePage] = useState(1);

  // 活动任务时明细随列表口径 15s 轮询
  const active = !!task && (task.status === 'enumerating' || task.status === 'running');
  const { data: filesPage, isLoading: filesLoading } = useAdminBaiduTaskFiles(
    taskId,
    fileStatus === 'all' ? undefined : fileStatus,
    FILE_PAGE_SIZE,
    (filePage - 1) * FILE_PAGE_SIZE,
    active,
  );

  const fileColumns: ColumnsType<AdminBaiduTaskFile> = [
    {
      title: '文件',
      dataIndex: 'rel_path',
      ellipsis: { showTitle: false },
      render: (v: string) => (
        <Tooltip title={v} placement="topLeft">
          <span style={{ fontFamily: 'var(--ms-font-mono)', fontSize: 11 }}>{v}</span>
        </Tooltip>
      ),
    },
    {
      title: '已传输',
      dataIndex: 'bytes_done',
      width: 84,
      render: (v: number) => <span style={{ fontSize: 11.5 }}>{fmtBytes(v)}</span>,
    },
    {
      title: '状态',
      dataIndex: 'status',
      width: 110,
      render: (v: string) => (
        <Tag color={BAIDU_FILE_STATUS_COLOR[v]}>{BAIDU_FILE_STATUS_LABEL[v] ?? v}</Tag>
      ),
    },
    {
      title: '尝试',
      dataIndex: 'attempts',
      width: 56,
      render: (v: number) => <span style={{ fontSize: 11.5 }}>{v}</span>,
    },
    {
      title: '失败原因',
      dataIndex: 'last_error',
      ellipsis: { showTitle: false },
      render: (v: string | null, row) => {
        if (row.status !== 'failed' || !v) return null;
        // admin 观测面:展示后端原始 last_error(已截 200),不换算用户文案
        return (
          <Tooltip title={v} placement="topLeft">
            <span style={{ fontSize: 11.5, color: '#ff4d4f', wordBreak: 'break-all' }}>{v}</span>
          </Tooltip>
        );
      },
    },
    {
      title: '更新时间',
      dataIndex: 'updated_at',
      width: 110,
      render: (v: string) => (
        <span style={{ fontSize: 11.5, color: 'var(--ms-ink-muted)', whiteSpace: 'nowrap' }}>
          {dayjs(v).format('MM-DD HH:mm')}
        </span>
      ),
    },
  ];

  return (
    <Drawer
      title="备份任务详情"
      open
      onClose={onClose}
      width="min(860px, 100vw)"
      destroyOnHidden
    >
      {isLoading || !task ? (
        <div style={{ padding: '60px 0', textAlign: 'center' }}><Spin /></div>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
          {/* ── 概要:状态 + 源目录 + 进度 + 计数 ── */}
          <div style={{
            border: '1px solid var(--ms-hairline)',
            borderRadius: 'var(--ms-radius-md)',
            padding: '10px 14px',
          }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap', marginBottom: 6 }}>
              <Tag color={BAIDU_TASK_STATUS_COLOR[task.status]} style={{ marginInlineEnd: 0 }}>
                {BAIDU_TASK_STATUS_LABEL[task.status] ?? task.status}
              </Tag>
              {task.cancel_requested && active && (
                <Tag color="orange" style={{ marginInlineEnd: 0 }}>取消请求中</Tag>
              )}
            </div>
            <Typography.Text
              type="secondary"
              ellipsis={{ tooltip: task.source_dir }}
              style={{ fontSize: 12, display: 'block', maxWidth: '100%' }}
            >
              {task.source_dir}
            </Typography.Text>
            {/* enumerating 阶段不渲染进度条(对齐列表口径) */}
            {task.status !== 'enumerating' && (
              <Progress percent={taskPct(task)} size="small" status={progressStatus(task.status)} />
            )}
            <Space size="middle" wrap style={{ fontSize: 12, color: 'var(--ms-ink-muted)' }}>
              <span>共 {task.total_files} 个文件</span>
              <span>完成 {task.done_files}</span>
              <span>跳过 {task.skipped_files}</span>
              {task.failed_files > 0 && (
                <span style={{ color: '#ff4d4f' }}>失败 {task.failed_files}</span>
              )}
              {task.cancelled_files > 0 && <span>取消 {task.cancelled_files}</span>}
              <span>
                {fmtBytes(task.done_bytes)}{task.total_bytes > 0 ? ` / ${fmtBytes(task.total_bytes)}` : ''}
              </span>
              {task.status === 'failed' && task.fail_reason && (
                <span style={{ color: '#ff4d4f' }}>
                  {BAIDU_FAIL_REASON_LABEL[task.fail_reason] ?? task.fail_reason}
                </span>
              )}
            </Space>
          </div>

          {/* ── 任务字段(含取消原因 / 绑定快照 / 当前绑定)── */}
          <div style={{
            border: '1px solid var(--ms-hairline)',
            borderRadius: 'var(--ms-radius-md)',
            padding: '12px 14px',
            display: 'grid',
            gridTemplateColumns: 'repeat(auto-fill, minmax(200px, 1fr))',
            gap: '10px 16px',
          }}>
            <Field label="用户">
              {task.user.name}{task.user.username ? `(${task.user.username})` : ''}
            </Field>
            <Field label="目标">
              {task.project.name} / {task.target_folder?.name ?? '已删'}
            </Field>
            <Field label="失败原因">
              {task.fail_reason
                ? (BAIDU_FAIL_REASON_LABEL[task.fail_reason] ?? task.fail_reason)
                : '—'}
            </Field>
            <Field label="取消原因">
              {task.cancel_reason
                ? (CANCEL_REASON_LABEL[task.cancel_reason] ?? task.cancel_reason)
                : '—'}
            </Field>
            <Field label="创建时间">{fmtTime(task.created_at)}</Field>
            <Field label="更新时间">{fmtTime(task.updated_at)}</Field>
            <Field label="绑定 UID 快照(创建时)">{task.bound_baidu_uid ?? '—'}</Field>
            <Field label="当前绑定">
              {task.binding
                ? `${task.binding.baidu_uid}(${BINDING_STATUS_LABEL[task.binding.status] ?? task.binding.status})`
                : '无绑定行'}
            </Field>
          </div>

          {/* ── 调度观测字段 ── */}
          <div style={{
            border: '1px solid var(--ms-hairline)',
            borderRadius: 'var(--ms-radius-md)',
            padding: '12px 14px',
          }}>
            <div style={{ fontSize: 12, color: 'var(--ms-ink-muted)', marginBottom: 8 }}>调度观测</div>
            <div style={{
              display: 'grid',
              gridTemplateColumns: 'repeat(auto-fill, minmax(180px, 1fr))',
              gap: '10px 16px',
            }}>
              <Field label="复活次数">{task.retry_count}</Field>
              <Field label="枚举完成">{task.enum_done ? '是' : '否'}</Field>
              <Field label="最近派发">{fmtTime(task.dispatched_at)}</Field>
              <Field label="轮起点">{fmtTime(task.round_started_at)}</Field>
              <Field label="租约到期(心跳)">{fmtTime(task.lease_until)}</Field>
              <Field label="Runner">{task.runner_id ?? '—'}</Field>
            </div>
          </div>

          {/* ── 文件明细:状态 Tabs(服务端过滤)+ 服务端分页 ── */}
          <Tabs
            size="small"
            activeKey={fileStatus}
            onChange={(k) => { setFileStatus(k); setFilePage(1); }}
            items={FILE_TABS.map(t => ({ key: t.key, label: t.label }))}
            style={{ marginBottom: 0 }}
          />
          <Table<AdminBaiduTaskFile>
            size="small"
            rowKey="id"
            columns={fileColumns}
            dataSource={filesPage?.items ?? []}
            loading={filesLoading}
            pagination={{
              size: 'small',
              current: filePage,
              pageSize: FILE_PAGE_SIZE,
              total: filesPage?.total ?? 0,
              showSizeChanger: false,
              showTotal: (t) => `共 ${t} 条`,
              onChange: (p) => setFilePage(p),
            }}
            locale={{ emptyText: '无文件' }}
          />
        </div>
      )}
    </Drawer>
  );
}

// ─── helpers ────────────────────────────────────────────────────────────────
/** 字段小格(标签 + 值)。 */
function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div style={{ minWidth: 0 }}>
      <div style={{ fontSize: 11, color: 'var(--ms-ink-subtle)', marginBottom: 2 }}>{label}</div>
      <div style={{ fontSize: 12.5, color: 'var(--ms-ink)', wordBreak: 'break-all' }}>{children}</div>
    </div>
  );
}

/** 进度 =(done+skipped+cancelled)/total;total=0 的 completed 视为 100%(空目录)。 */
function taskPct(t: Pick<AdminBaiduTask,
  'status' | 'total_files' | 'done_files' | 'skipped_files' | 'cancelled_files'>): number {
  const total = t.total_files;
  const processed = t.done_files + t.skipped_files + t.cancelled_files;
  return total > 0 ? Math.round((processed / total) * 100) : (t.status === 'completed' ? 100 : 0);
}

/** 进度条状态色(对齐用户侧口径;cancelled 用 normal 灰条,不再播 active 动画)。 */
function progressStatus(s: string): 'exception' | 'success' | 'normal' | 'active' {
  return s === 'failed' ? 'exception'
    : s === 'completed' ? 'success'
    : s === 'cancelled' ? 'normal' : 'active';
}

function fmtTime(iso: string | null): string {
  return iso ? dayjs(iso).format('YYYY-MM-DD HH:mm:ss') : '—';
}

// 与 BaiduBackupDrawer/BaiduTaskDetail 同口径
function fmtBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(1)} MB`;
  if (n < 1024 ** 4) return `${(n / 1024 ** 3).toFixed(2)} GB`;
  return `${(n / 1024 ** 4).toFixed(2)} TB`;
}
