/**
 * 右下浮动按钮 — 统一显示上传 + 下载 in-flight 任务数。点开任务中心 drawer。
 */
import { FloatButton, Tooltip } from 'antd';
import { CloudSyncOutlined } from '@ant-design/icons';
import { useMemo, useState } from 'react';
import { useUpload } from '../lib/upload-store';
import { useDownloads } from '../lib/download-store';
import { useCompactViewport } from '../lib/use-viewports';
import { TaskCenterDrawer } from './TaskCenterDrawer';

export function UploadFloatingIndicator() {
  const { getAllUppies, version, activeFolderId } = useUpload();
  const { tasks } = useDownloads();
  const [centerOpen, setCenterOpen] = useState(false);
  const compact = useCompactViewport();

  const stats = useMemo(() => {
    const all = getAllUppies();
    let upInflight = 0;
    let upFailed = 0;
    for (const u of all.values()) {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const files = (u as any).getFiles() as { progress?: { uploadComplete?: boolean }; error?: unknown }[];
      for (const f of files) {
        if (f.error) upFailed++;
        else if (!f.progress?.uploadComplete) upInflight++;
      }
    }
    const dlInflight = tasks.filter(t => t.status === 'pending' || t.status === 'running').length;
    // 失败项计入 badge:全部传完只剩失败时,浮标是任务中心(重试入口)唯一的唤起点
    return { upInflight, upFailed, dlInflight, total: upInflight + upFailed + dlInflight };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [version, getAllUppies, tasks]);

  if (stats.total === 0 && !centerOpen) return null;
  if (activeFolderId && stats.total === 0) return null;

  return (
    <>
      <Tooltip title={`上传 ${stats.upInflight} · 失败 ${stats.upFailed} · 下载 ${stats.dlInflight} — 点击查看`} placement="left">
        <FloatButton
          icon={<CloudSyncOutlined />}
          badge={{ count: stats.total, color: stats.upFailed > 0 ? '#ff4d4f' : '#1677ff' }}
          onClick={() => setCenterOpen(true)}
          style={{
            right: 24,
            // compact: 让开底部 TabBar + 安全区(--ms-tabbar-h 由 tokens.css 移动层定义);PC 维持 80
            bottom: compact
              ? 'calc(var(--ms-tabbar-h) + env(safe-area-inset-bottom))'
              : 80,
          }}
        />
      </Tooltip>
      <TaskCenterDrawer open={centerOpen} onClose={() => setCenterOpen(false)} />
    </>
  );
}
