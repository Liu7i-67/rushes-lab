/**
 * BaiduTaskDetail — 百度备份任务明细(抽屉二级视图,方案 §3.1)。
 * 头部:返回 + 来源/目标 + 进度(文件数/字节)+ ETA + 失败原因;
 * 主体:manifest Table,状态筛选 Tabs(服务端 status 过滤 + 分页),
 * 行操作:重试(failed 任务失败行;non_retryable 置灰)/ 覆盖导入(failed/completed
 * 任务的跳过行与 key_conflict 失败行,清除-再导入,永久删除原文件)/
 * 随机后缀导入(key_conflict 失败行,换不冲突 key 重导,原文件名不变)。
 */
import { App, Alert, Button, Popconfirm, Progress, Space, Spin, Table, Tabs, Tag, Tooltip, Typography } from 'antd';
import type { ColumnsType } from 'antd/es/table';
import { ArrowLeft } from 'lucide-react';
import { useState } from 'react';
import { errorMessage } from '../api/client';
import { useBaiduFileRandomSuffix, useBaiduOverwriteFile, useBaiduRetryFile, useBaiduTask, useBaiduTaskFiles } from '../api/hooks';
import type { BaiduTaskFile } from '../api/types';
import {
  BAIDU_FAIL_REASON_LABEL,
  BAIDU_FILE_ERROR_LABEL,
  BAIDU_FILE_STATUS_COLOR,
  BAIDU_FILE_STATUS_LABEL,
  BAIDU_TASK_STATUS_COLOR,
  BAIDU_TASK_STATUS_LABEL,
  baiduTaskDisplayStatus,
} from '../lib/labels';

const PAGE_SIZE = 20;

interface Props {
  taskId: string;
  onBack: () => void;
}

const FILE_TABS = [
  { key: 'all', label: '全部' },
  { key: 'pending', label: '等待' },
  { key: 'importing', label: '导入中' },
  { key: 'success', label: '成功' },
  { key: 'skipped_exists', label: '跳过' },
  { key: 'failed', label: '失败' },
  { key: 'cancelled', label: '已取消' },
];

export function BaiduTaskDetail({ taskId, onBack }: Props) {
  const { message } = App.useApp();
  const { data: task } = useBaiduTask(taskId);
  const retryFile = useBaiduRetryFile();
  const overwriteFile = useBaiduOverwriteFile();
  const randomSuffixFile = useBaiduFileRandomSuffix();

  const [statusFilter, setStatusFilter] = useState<string>('all');
  const [page, setPage] = useState(1);

  const active = !!task && (task.status === 'enumerating' || task.status === 'running');
  const { data: filesPage, isLoading } = useBaiduTaskFiles(
    taskId,
    statusFilter === 'all' ? undefined : statusFilter,
    PAGE_SIZE,
    (page - 1) * PAGE_SIZE,
    active,
  );

  const changeTab = (k: string) => {
    setStatusFilter(k);
    setPage(1);
  };

  const retry = async (f: BaiduTaskFile) => {
    try {
      await retryFile.mutateAsync({ taskId, fileId: f.id });
      message.success(`「${fileName(f)}」已重新排队`);
    } catch (e) {
      message.error(errorMessage(e, '重试失败'));
    }
  };

  const overwrite = async (f: BaiduTaskFile) => {
    try {
      await overwriteFile.mutateAsync({ taskId, fileId: f.id });
      message.success(`「${fileName(f)}」已加入覆盖导入(原文件将在导入前被永久删除)`);
    } catch (e) {
      message.error(errorMessage(e, '覆盖导入失败'));
    }
  };

  const randomSuffix = async (f: BaiduTaskFile) => {
    try {
      await randomSuffixFile.mutateAsync({ taskId, fileId: f.id });
      message.success(`「${fileName(f)}」已用随机后缀重新导入`);
    } catch (e) {
      message.error(errorMessage(e, '随机后缀导入失败'));
    }
  };

  const columns: ColumnsType<BaiduTaskFile> = [
    {
      title: '原网盘路径',
      dataIndex: 'source_path',
      width: 180,
      ellipsis: { showTitle: false },
      render: (v: string) => (
        <Tooltip title={v} placement="topLeft">
          <Typography.Text code style={{ fontSize: 11 }}>{v}</Typography.Text>
        </Tooltip>
      ),
    },
    {
      title: '预计导入路径',
      dataIndex: 'target_path',
      width: 180,
      ellipsis: { showTitle: false },
      render: (v: string | null, row) => {
        const text = v ?? `${row.source_path}(目标已删除)`;
        return (
          <Tooltip title={text} placement="topLeft">
            <span style={{ fontSize: 11.5, color: v ? 'var(--ms-ink-muted)' : 'var(--ms-amber)' }}>
              {text}
            </span>
          </Tooltip>
        );
      },
    },
    {
      title: '大小',
      dataIndex: 'source_size',
      width: 84,
      render: (v: number) => <span style={{ fontSize: 11.5 }}>{fmtBytes(v)}</span>,
    },
    {
      title: '状态',
      dataIndex: 'status',
      width: 110,
      render: (v: string) => <Tag color={BAIDU_FILE_STATUS_COLOR[v]}>{tlabelFile(v)}</Tag>,
    },
    {
      title: '失败原因',
      dataIndex: 'last_error',
      ellipsis: { showTitle: false },
      render: (v: string | null, row) => {
        if (row.status !== 'failed' || !v) return null;
        const text = fileErrorText(v);
        return (
          <Tooltip title={text} placement="topLeft">
            <span style={{ fontSize: 11.5, color: '#ff4d4f', wordBreak: 'break-all' }}>{text}</span>
          </Tooltip>
        );
      },
    },
    {
      title: '操作',
      key: 'actions',
      width: 170,
      render: (_v, row) => {
        // key_conflict 失败行:原样重试必然再次命中同一冲突,操作列改为
        // 【覆盖导入】【随机后缀导入】两条处置出路(F2),不显示普通重试
        const isKeyConflict = isKeyConflictRow(row);
        const canRetry = task?.status === 'failed' && row.status === 'failed' && !isKeyConflict;
        const canOverwrite = (task?.status === 'failed' || task?.status === 'completed')
          && row.status === 'skipped_exists';
        const canResolveConflict = isKeyConflict
          && (task?.status === 'failed' || task?.status === 'completed');
        return (
          <Space size={4}>
            {canRetry && (
              <Tooltip title={row.non_retryable
                ? '结构性失败(路径/文件名超限等),重试无法恢复,请删除任务后拆分重建'
                : '重试该文件(断点续传)'}>
                <Button size="small" type="link" disabled={row.non_retryable}
                        loading={retryFile.isPending && retryFile.variables?.fileId === row.id}
                        onClick={() => retry(row)}>
                  重试
                </Button>
              </Tooltip>
            )}
            {canResolveConflict && (
              <Popconfirm
                title="覆盖导入?"
                description={keyConflictOverwriteDesc(row.last_error)}
                okText="覆盖导入" okButtonProps={{ danger: true }}
                onConfirm={() => overwrite(row)}
              >
                <Button size="small" type="link" danger
                        loading={overwriteFile.isPending && overwriteFile.variables?.fileId === row.id}>
                  覆盖导入
                </Button>
              </Popconfirm>
            )}
            {canResolveConflict && (
              <Tooltip title="换一个不冲突的存储位置重新导入(网盘原文件名不变)">
                <Button size="small" type="link"
                        loading={randomSuffixFile.isPending && randomSuffixFile.variables?.fileId === row.id}
                        onClick={() => randomSuffix(row)}>
                  随机后缀导入
                </Button>
              </Tooltip>
            )}
            {canOverwrite && (
              <Popconfirm
                title="覆盖导入?"
                description="将永久删除目标位置的原文件后重新导入(需对该文件有管理权限);同一任务同时只能有一个覆盖在途。"
                okText="覆盖导入" okButtonProps={{ danger: true }}
                onConfirm={() => overwrite(row)}
              >
                <Button size="small" type="link" danger
                        loading={overwriteFile.isPending && overwriteFile.variables?.fileId === row.id}>
                  覆盖导入
                </Button>
              </Popconfirm>
            )}
          </Space>
        );
      },
    },
  ];

  if (!task) {
    return <div style={{ padding: '60px 0', textAlign: 'center' }}><Spin /></div>;
  }

  const display = baiduTaskDisplayStatus(task);
  const total = task.total_files ?? 0;
  const done = task.done_files ?? 0;
  const pct = total > 0 ? Math.round((done / total) * 100) : (task.status === 'completed' ? 100 : 0);
  const terminal = task.status === 'completed' || task.status === 'cancelled' || task.status === 'failed';

  return (
    <div style={{ display: 'flex', flexDirection: 'column', minHeight: 0, flex: 1 }}>
      {/* 头部:返回 + 任务概要 */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 12 }}>
        <Button size="small" type="text" icon={<ArrowLeft size={15} strokeWidth={2} />}
                onClick={onBack} aria-label="返回任务列表" />
        <Tag color={BAIDU_TASK_STATUS_COLOR[display]}>{tlabelTask(display)}</Tag>
        <Typography.Text type="secondary" style={{ fontSize: 12, flex: 1, minWidth: 0 }}
                         ellipsis={{ tooltip: task.source_dir }}>
          {task.source_dir}
        </Typography.Text>
      </div>

      <div style={{
        border: '1px solid var(--ms-hairline)',
        borderRadius: 'var(--ms-radius-md)',
        padding: '10px 14px',
        marginBottom: 12,
      }}>
        <div style={{ fontSize: 12, color: 'var(--ms-ink-muted)', marginBottom: 6 }}>
          目标:{task.project_name ?? task.project_id}
          {task.target_folder_name
            ? ` / ${task.target_folder_name}`
            : task.target_auto_created ? ' / 项目根(自动创建承接夹)' : ' / (已删除)'}
        </div>
        <Progress
          percent={pct}
          size="small"
          status={task.status === 'failed' ? 'exception'
            : task.status === 'completed' ? 'success' : 'active'}
        />
        <Space size="middle" style={{ fontSize: 12, color: 'var(--ms-ink-muted)', flexWrap: 'wrap' }}>
          <span>{done} / {total} 个文件</span>
          <span>{fmtBytes(task.done_bytes)}{task.total_bytes != null ? ` / ${fmtBytes(task.total_bytes)}` : ''}</span>
          {active && (
            <span>
              {task.eta_seconds != null ? `预计剩余 ${fmtEta(task.eta_seconds)}` : '估算中'}
            </span>
          )}
          {task.status === 'failed' && task.fail_reason && (
            <span style={{ color: '#ff4d4f' }}>{tlabelFail(task.fail_reason)}</span>
          )}
          {task.status === 'completed' && total === 0 && <span>源目录为空</span>}
          {terminal && task.failed_files ? <span>失败 {task.failed_files}</span> : null}
          {terminal && task.skipped_files ? <span>跳过 {task.skipped_files}</span> : null}
        </Space>
      </div>

      {/* failed/completed 任务对跳过行开放覆盖导入;提示一次清除-再导入语义 */}
      {(task.status === 'failed' || task.status === 'completed') && (task.skipped_files ?? 0) > 0 && (
        <Alert
          type="warning"
          showIcon
          message="「覆盖导入」会永久删除原文件后重新导入(需管理权限);同一任务同时只能有一个覆盖在途,多行覆盖需等上一轮结束后再触发。"
          style={{ marginBottom: 12, fontSize: 12 }}
        />
      )}

      <Tabs
        size="small"
        activeKey={statusFilter}
        onChange={changeTab}
        items={FILE_TABS.map(t => ({ key: t.key, label: t.label }))}
        style={{ marginBottom: 0 }}
      />
      <div style={{ flex: 1, minHeight: 0, overflow: 'auto' }}>
        <Table<BaiduTaskFile>
          size="small"
          rowKey="id"
          columns={columns}
          dataSource={filesPage?.items ?? []}
          loading={isLoading}
          pagination={{
            size: 'small',
            current: page,
            pageSize: PAGE_SIZE,
            total: filesPage?.total ?? 0,
            showSizeChanger: false,
            showTotal: (t) => `共 ${t} 条`,
            onChange: (p) => setPage(p),
          }}
          locale={{ emptyText: '无文件' }}
        />
      </div>
    </div>
  );
}

// ─── helpers ────────────────────────────────────────────────────────────────
function fileName(f: BaiduTaskFile): string {
  const idx = f.source_path.lastIndexOf('/');
  return idx >= 0 ? f.source_path.slice(idx + 1) : f.source_path;
}

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

const tlabelTask = (s: string) => BAIDU_TASK_STATUS_LABEL[s] ?? s;
const tlabelFile = (s: string) => BAIDU_FILE_STATUS_LABEL[s] ?? s;
const tlabelFail = (s: string) => BAIDU_FAIL_REASON_LABEL[s] ?? s;

/** key_conflict 失败行(F1 格式:last_error 以 `key_conflict:` 开头,点名占用者)。 */
function isKeyConflictRow(f: BaiduTaskFile): boolean {
  return f.status === 'failed' && !!f.last_error?.startsWith('key_conflict:');
}

/**
 * 从 key_conflict last_error 解析占用者文件名列表(F1 格式,后端
 * `format_key_conflict_message`:f"{key} 已被 {names}占用" — names 与「占用」间无空格;
 * 占用者软删时名后直拼 `(回收站)`,整串经 _fail_row [:512] 截断),
 * 解析不出/格式不可信返回 null(调用方回退通用确认文案)。
 *
 * 从右侧锚定最后一个 ` 已被 ` 解析:占用者名自身可含「占用」「已被」等字样,
 * 左侧懒惰匹配会把名截断失真(如「已占用.txt」解析成「已」)。
 * 终止符「占用」要求整段以它收尾——512 截断的串没有该尾部,直接回退;
 * 剥离只做一次且锚定段尾,避免误剥名字本身以「占用」结尾的合法名(如「已占用」)。
 * 「、」既是多名分隔符又是名字合法字符,单个含「、」的名拆分后拼接回显示串
 * 与后端原文逐字节一致(仅 1/N 个文件的语义歧义,无法从格式判别)。
 */
function keyConflictHolders(err: string): string[] | null {
  const marker = ' 已被 ';
  const terminator = '占用';
  const recycleSuffix = '(回收站)';
  const idx = err.lastIndexOf(marker);               // 右锚:躲开名内「已被」字样
  if (idx < 0) return null;
  let segment = err.slice(idx + marker.length);
  if (!segment.endsWith(terminator)) return null;    // 无终止符=截断/非 F1 格式 → 回退
  segment = segment.slice(0, -terminator.length);
  if (!segment) return null;
  const holders = segment
    .split('、')
    .map(s => (s.endsWith(recycleSuffix) ? s.slice(0, -recycleSuffix.length).trim() : s.trim()))
    .filter(s => s.length > 0 && !s.includes(marker)); // 空名/残留标记位=解析不可信 → 回退
  return holders.length > 0 ? holders : null;
}

/** key_conflict 行覆盖导入确认文案:点名将删除的占用者文件(解析失败回退通用文案)。 */
function keyConflictOverwriteDesc(lastError: string | null): string {
  const holders = lastError ? keyConflictHolders(lastError) : null;
  return holders
    ? `将删除占用该位置的文件:${holders.join('、')},且不可恢复(需对占用文件有管理权限)。`
    : '将永久删除占用该位置的文件后重新导入,且不可恢复(需对占用文件有管理权限)。';
}

/** 失败原因用户化:已知前缀换中文标签并保留明细,overwrite_ambiguous 引导文案(§7 文案基调)。 */
function fileErrorText(err: string): string {
  for (const [prefix, label] of Object.entries(BAIDU_FILE_ERROR_LABEL)) {
    if (err.startsWith(`${prefix}:`)) {
      const detail = err.slice(prefix.length + 1).trim();
      return detail ? `${label}:${detail}` : label;
    }
  }
  if (err.includes('overwrite_ambiguous')) {
    return '目标位置存在同名文件(可能位于回收站),请先彻底删除后再重试覆盖导入';
  }
  return err;
}
