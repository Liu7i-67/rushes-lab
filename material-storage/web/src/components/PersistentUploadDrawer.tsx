/**
 * 全局上传抽屉 — 挂在 App 顶层,任何页面通过 useUpload().open(folderId) 唤起。
 * 关闭只 hide UI,uppy 实例仍在 store,上传后台继续。
 */
import { Button, Drawer, Progress, Space } from 'antd';
import { Tags } from 'lucide-react';
import { useCallback, useEffect, useRef } from 'react';
import { computeUploadStats, useUpload } from '../lib/upload-store';

import '@uppy/core/dist/style.min.css';
import '@uppy/dashboard/dist/style.min.css';

export function PersistentUploadDrawer() {
  const { activeFolderId, close, getUppy, getAllUppies, version } = useUpload();
  const currentNode = useRef<HTMLDivElement | null>(null);
  // version 驱动重渲染;统计每次渲染直接重算
  void version;
  const u = activeFolderId ? getUppy(activeFolderId) : undefined;
  const stats = computeUploadStats(u ? u.getFiles() : []);
  // pct 按 stats 的字节口径算,不用 uppy totalProgress——后者只在 progress 事件重算,
  // 暂存第二批/分片并发时会和「上传进度 x/y」的文件计数明显矛盾
  const pct = stats.total === 0 ? 0
    : stats.bytesTotal > 0 ? Math.round((stats.loaded / stats.bytesTotal) * 100)
      : Math.round(((stats.success + stats.failed) / stats.total) * 100);
  const status = stats.failed > 0 ? 'exception'
    : stats.total > 0 && stats.success + stats.failed >= stats.total ? 'success' : 'active';

  const mountCb = useCallback((node: HTMLDivElement | null) => {
    currentNode.current = node;
    if (!node || !activeFolderId) return;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const u = getUppy(activeFolderId) as any;
    if (!u) return;

    // 清旧 Dashboard(目标 div 已无效)
    const existing = u.getPlugin('Dashboard');
    if (existing) u.removePlugin(existing);

    // dynamic import dashboard plugin
    void import('@uppy/dashboard').then(({ default: Dashboard }) => {
      // race:可能 mount node 已被新 node 覆盖
      if (currentNode.current !== node) return;
      u.use(Dashboard, {
        inline: true,
        target: node,
        height: 460,
        width: '100%',
        showProgressDetails: true,
        proudlyDisplayPoweredByUppy: false,
        note: '支持拖拽 / 多选;最大 5GB,16MB 分片;关闭抽屉不会中断,可后台跑;单批最多 10000 个文件',
      });
    });
  }, [activeFolderId, getUppy]);

  // close 时清所有 uppy 的 Dashboard plugin(div 已 unmount)
  useEffect(() => {
    if (activeFolderId) return;
    for (const u of getAllUppies().values()) {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const p = (u as any).getPlugin('Dashboard');
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      if (p) (u as any).removePlugin(p);
    }
  }, [activeFolderId, getAllUppies]);

  return (
    <Drawer
      title={activeFolderId ? `上传到 folder ${activeFolderId.slice(0, 8)}…` : '上传'}
      open={!!activeFolderId}
      onClose={close}
      width="min(760px, 100vw)"
      maskClosable
      keyboard
      destroyOnHidden={false}
    >
      {/* 汇总栏 — 当前 folder 有文件时显示总进度 + 重试 */}
      {activeFolderId && stats.total > 0 && (
        <div style={{
          marginBottom: 12,
          display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap',
          padding: '8px 12px',
          background: 'var(--ms-canvas)',
          border: '1px solid var(--ms-hairline)',
          borderRadius: 'var(--ms-radius-sm)',
          fontSize: 12, color: 'var(--ms-ink-muted)',
        }}>
          <span>上传进度 {stats.success}/{stats.total}</span>
          <Progress percent={pct} size="small" status={status} style={{ flex: 1, minWidth: 120, margin: 0 }} />
          <Space size={12}>
            <span>成功 <span style={{ color: '#52c41a' }}>{stats.success}</span></span>
            <span style={stats.failed > 0 ? { color: '#ff4d4f' } : undefined}>失败 {stats.failed}</span>
            {stats.failed > 0 && (
              <Button size="small" onClick={() => u.retryAll()}>重试失败项 ({stats.failed})</Button>
            )}
          </Space>
        </div>
      )}

      {/* 大批量提示 */}
      {activeFolderId && stats.total > 500 && (
        <div style={{ marginBottom: 8, fontSize: 12, color: 'var(--ms-ink-muted)', lineHeight: 1.6 }}>
          已选 {stats.total} 个文件,批量较大:加入/开始上传时页面可能短暂无响应,属正常现象,请勿关闭页面
        </div>
      )}

      {activeFolderId && <div ref={mountCb} style={{ minHeight: 460, width: '100%' }} />}

      {/* #151: 打标引导 — 上传完成后在列表选中文件打标,之后可跨文件夹盲搜 */}
      {activeFolderId && (
        <div style={{
          marginTop: 12,
          display: 'flex', alignItems: 'flex-start', gap: 8,
          padding: '10px 12px',
          background: 'var(--ms-canvas)',
          border: '1px solid var(--ms-hairline)',
          borderRadius: 'var(--ms-radius-sm)',
          fontSize: 12, color: 'var(--ms-ink-muted)', lineHeight: 1.6,
        }}>
          <Tags size={13} strokeWidth={1.8}
                style={{ color: 'var(--ms-accent)', flexShrink: 0, marginTop: 2 }} />
          <span>
            上传完成后,选中文件点「打标」加标签/备注(如<em>棚拍</em>、<em>VIP</em>),
            之后就能用 ⌘K 跨所有文件夹搜到它。
          </span>
        </div>
      )}
    </Drawer>
  );
}
