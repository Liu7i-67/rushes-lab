/**
 * 任务中心抽屉 — 顶部 Segmented 切换上传 / 下载,带进度条 + 取消 + 移除。
 * 布局:汇总/筛选固定在顶部,列表区自身滚动,分页器钉在抽屉底部
 * (翻页 / 切筛选自动滚回列表顶部,不用来回拖滚动条)。
 */
import { Button, Drawer, Empty, List, Pagination, Progress, Segmented, Space, Tag, Tooltip, Typography } from 'antd';
import { CloseOutlined, DeleteOutlined, FileOutlined, FolderOutlined } from '@ant-design/icons';
import { useRef, useState } from 'react';
import { computeUploadStats, useUpload } from '../lib/upload-store';
import { useDownloads, type DownloadTask } from '../lib/download-store';

function fmtBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(1)} MB`;
  return `${(n / 1024 ** 3).toFixed(2)} GB`;
}
function fmtSpeed(bps: number): string {
  return `${fmtBytes(bps)}/s`;
}
function fmtError(s: string): string {
  return s.length > 120 ? `${s.slice(0, 120)}…` : s;
}

const PAGE_SIZE = 100;
const showTotal = (t: number) => `共 ${t} 条`;

const STATUS_TAG: Record<string, { color: string; text: string }> = {
  pending: { color: 'default', text: '等待' },
  running: { color: 'blue', text: '进行中' },
  success: { color: 'green', text: '完成' },
  failed: { color: 'red', text: '失败' },
  cancelled: { color: 'default', text: '已取消' },
};

interface Props {
  open: boolean;
  onClose: () => void;
}

type UploadFilter = 'all' | 'inflight' | 'done' | 'failed';

const FILTER_EMPTY: Record<UploadFilter, string> = {
  all: '无上传任务',
  inflight: '无进行中任务',
  done: '无已完成项',
  failed: '无失败项',
};

/** 分页器钉底:列表区内滚,翻页后自动回顶 */
function BottomPager(props: { total: number; current: number; onChange: (p: number) => void }) {
  return (
    <div style={{
      flexShrink: 0,
      borderTop: '1px solid #f0f0f0',
      marginTop: 8, padding: '8px 0 12px',
      display: 'flex', justifyContent: 'flex-end',
    }}>
      <Pagination size="small" current={props.current} total={props.total}
                  pageSize={PAGE_SIZE} showSizeChanger={false} showTotal={showTotal}
                  onChange={props.onChange} />
    </div>
  );
}

function UploadList() {
  const { getAllUppies, getUppy, open, version } = useUpload();
  const [filter, setFilter] = useState<UploadFilter>('all');
  const [page, setPage] = useState(1);
  const scrollRef = useRef<HTMLDivElement | null>(null);

  // 把所有 uppy 实例的所有 files 平铺出来
  const items: { folderId: string; file: { id: string; name: string; size?: number; progress?: { uploadComplete?: boolean; bytesUploaded?: number; bytesTotal?: number; percentage?: number }; error?: unknown } }[] = [];
  for (const [folderId, u] of getAllUppies()) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const files = (u as any).getFiles();
    for (const file of files) items.push({ folderId, file });
  }
  // version dep keeps lint happy:
  void version;

  const stats = computeUploadStats(items.map(i => i.file));
  // 失败优先于已完成(与 status 判定同序)
  const filtered = items.filter(({ file }) => {
    const failed = !!file.error;
    const complete = !!file.progress?.uploadComplete;
    if (filter === 'failed') return failed;
    if (filter === 'done') return !failed && complete;
    if (filter === 'inflight') return !failed && !complete;
    return true;
  });

  const retryAllFailed = () => {
    for (const u of getAllUppies().values()) {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const files = (u as any).getFiles();
      if (files.some((f: { error?: unknown }) => f.error)) u.retryAll();
    }
  };

  // 重试成功等状态变化会让页数收缩,钳住当前页防空白页
  const totalPages = Math.max(1, Math.ceil(filtered.length / PAGE_SIZE));
  const safePage = Math.min(page, totalPages);
  const pageItems = filtered.slice((safePage - 1) * PAGE_SIZE, safePage * PAGE_SIZE);

  const changePage = (p: number) => {
    setPage(p);
    scrollRef.current?.scrollTo({ top: 0 });
  };
  const changeFilter = (v: UploadFilter) => {
    setFilter(v);
    setPage(1);
    scrollRef.current?.scrollTo({ top: 0 });
  };

  if (items.length === 0) return <Empty description="无上传任务" style={{ marginTop: 60 }} />;

  return (
    <div style={{ flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap', marginBottom: 8, fontSize: 12, color: '#999' }}>
        <span>共 {stats.total} · 成功 {stats.success} · 失败 {stats.failed} · 进行中 {stats.inflight}</span>
        {stats.failed > 0 && (
          <Button size="small" onClick={retryAllFailed}>重试全部失败项 ({stats.failed})</Button>
        )}
      </div>
      <Segmented
        style={{ marginBottom: 12 }}
        value={filter}
        onChange={(v) => changeFilter(v as UploadFilter)}
        options={[
          { label: `全部 (${stats.total})`, value: 'all' },
          { label: `进行中 (${stats.inflight})`, value: 'inflight' },
          { label: `已完成 (${stats.success})`, value: 'done' },
          { label: `失败 (${stats.failed})`, value: 'failed' },
        ]}
      />
      <div ref={scrollRef} style={{ flex: 1, minHeight: 0, overflowY: 'auto' }}>
        {filtered.length === 0 ? (
          <Empty description={FILTER_EMPTY[filter]} style={{ marginTop: 60 }} />
        ) : (
          <List
            dataSource={pageItems}
            renderItem={({ folderId, file }) => {
              const pct = file.progress?.percentage ?? 0;
              const complete = !!file.progress?.uploadComplete;
              const failed = !!file.error;
              const status = failed ? 'failed' : complete ? 'success' : pct > 0 ? 'running' : 'pending';
              const tag = STATUS_TAG[status];
              const loaded = file.progress?.bytesUploaded ?? 0;
              const total = file.progress?.bytesTotal ?? file.size ?? 0;

              const actions: React.ReactNode[] = [];
              if (failed) {
                actions.push(
                  <Button key="retry" size="small" type="link"
                          onClick={() => getUppy(folderId)?.retryUpload(file.id)}>重试</Button>
                );
              } else if (!complete) {
                actions.push(
                  <Button key="open" size="small" type="link" onClick={() => open(folderId)}>查看</Button>
                );
              }

              return (
                <List.Item actions={actions}>
                  <List.Item.Meta
                    avatar={<FolderOutlined />}
                    title={
                      <Space>
                        <Typography.Text ellipsis={{ tooltip: file.name }} style={{ maxWidth: 280 }}>{file.name}</Typography.Text>
                        <Tag color={tag.color}>{tag.text}</Tag>
                      </Space>
                    }
                    description={
                      <div>
                        <Progress percent={Math.round(pct)} size="small"
                                  status={failed ? 'exception' : complete ? 'success' : 'active'}
                                  showInfo={false} />
                        <Space size="middle" style={{ fontSize: 12, color: '#999' }}>
                          <span>{fmtBytes(loaded)} / {fmtBytes(total)}</span>
                          <span>folder · <code>{folderId.slice(0, 8)}…</code></span>
                        </Space>
                        {failed && !!file.error && (
                          <div style={{ color: '#ff4d4f', fontSize: 12, wordBreak: 'break-all' }}>
                            {fmtError(String(file.error))}
                          </div>
                        )}
                      </div>
                    }
                  />
                </List.Item>
              );
            }}
          />
        )}
      </div>
      {filtered.length > PAGE_SIZE && (
        <BottomPager total={filtered.length} current={safePage} onChange={changePage} />
      )}
    </div>
  );
}

function DownloadList() {
  const { tasks, cancel, remove } = useDownloads();
  const [page, setPage] = useState(1);
  const scrollRef = useRef<HTMLDivElement | null>(null);

  const totalPages = Math.max(1, Math.ceil(tasks.length / PAGE_SIZE));
  const safePage = Math.min(page, totalPages);
  const pageTasks = tasks.slice((safePage - 1) * PAGE_SIZE, safePage * PAGE_SIZE);

  const changePage = (p: number) => {
    setPage(p);
    scrollRef.current?.scrollTo({ top: 0 });
  };

  if (tasks.length === 0) return <Empty description="无下载任务" style={{ marginTop: 60 }} />;

  return (
    <div style={{ flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column' }}>
      <div ref={scrollRef} style={{ flex: 1, minHeight: 0, overflowY: 'auto' }}>
        <List
          dataSource={pageTasks}
          renderItem={(t: DownloadTask) => {
            const tag = STATUS_TAG[t.status];
            const pct = t.total > 0 ? Math.round((t.loaded / t.total) * 100) : 0;
            const finalProgress = t.status === 'success' ? 'success' : t.status === 'failed' ? 'exception' : 'active';
            return (
              <List.Item
                actions={[
                  t.status === 'running' && (
                    <Tooltip title="取消下载" key="cancel">
                      <Button size="small" type="text" icon={<CloseOutlined />} onClick={() => cancel(t.id)} />
                    </Tooltip>
                  ),
                  t.status !== 'running' && (
                    <Tooltip title="移除记录" key="remove">
                      <Button size="small" type="text" icon={<DeleteOutlined />} onClick={() => remove(t.id)} />
                    </Tooltip>
                  ),
                ].filter(Boolean) as React.ReactNode[]}
              >
                <List.Item.Meta
                  avatar={<FileOutlined />}
                  title={
                    <Space>
                      <Typography.Text ellipsis={{ tooltip: t.filename }} style={{ maxWidth: 280 }}>{t.filename}</Typography.Text>
                      <Tag color={tag.color}>{tag.text}</Tag>
                    </Space>
                  }
                  description={
                    <div>
                      <Progress percent={pct} size="small" status={finalProgress} showInfo={false} />
                      <Space size="middle" style={{ fontSize: 12, color: '#999' }}>
                        <span>{fmtBytes(t.loaded)}{t.total ? ` / ${fmtBytes(t.total)}` : ''}</span>
                        {t.status === 'running' && t.speedBps != null && <span>{fmtSpeed(t.speedBps)}</span>}
                        {t.error && <span style={{ color: '#ff4d4f' }}>{t.error}</span>}
                      </Space>
                    </div>
                  }
                />
              </List.Item>
            );
          }}
        />
      </div>
      {tasks.length > PAGE_SIZE && (
        <BottomPager total={tasks.length} current={safePage} onChange={changePage} />
      )}
    </div>
  );
}

export function TaskCenterDrawer({ open, onClose }: Props) {
  const { tasks } = useDownloads();
  const { getAllUppies, version } = useUpload();
  const [tab, setTab] = useState<'upload' | 'download'>('upload');
  void version;

  let uploadCount = 0;
  for (const u of getAllUppies().values()) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    uploadCount += (u as any).getFiles().length;
  }
  const dlCount = tasks.length;

  return (
    <Drawer
      title="任务中心"
      open={open}
      onClose={onClose}
      width="min(560px, 100vw)"
      maskClosable
      // 关闭即卸载内容:大批量上传期间 version tick 很频繁,别在后台白白重算列表
      destroyOnHidden
      // body 变 flex 列且不滚:汇总/筛选钉顶、列表区内滚、分页器钉底
      styles={{ body: { display: 'flex', flexDirection: 'column', overflow: 'hidden', paddingBottom: 0 } }}
    >
      <Segmented
        style={{ marginBottom: 12, alignSelf: 'flex-start' }}
        value={tab}
        onChange={(v) => setTab(v as 'upload' | 'download')}
        options={[
          { label: `上传 (${uploadCount})`, value: 'upload' },
          { label: `下载 (${dlCount})`, value: 'download' },
        ]}
      />
      {tab === 'upload' ? <UploadList /> : <DownloadList />}
    </Drawer>
  );
}
