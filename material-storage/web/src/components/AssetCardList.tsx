/**
 * AssetCardList — 移动端(compact)资产卡片列表,ProjectDetailPage / FolderDetailPage 共用。
 * 交互模型(方案 §3.1):tap 卡片主体 = open(详情 Drawer);checkbox(44px 命中区)= 多选;
 * 行尾下载按钮(44px,stopPropagation)走既有下载链路(403 → 申请弹窗,与 PC Table 行一致)。
 * 排序降级(显式声明):PC Table 的客户端 sorter 在卡片列表不做(§3.1)。
 */
import { App, Button, Checkbox, Skeleton, Tooltip } from 'antd';
import { Download } from 'lucide-react';
import { useState } from 'react';
import { useDownloadLink } from '../api/hooks';
import { errorMessage } from '../api/client';
import { useDownloads } from '../lib/download-store';
import { AssetThumbnail } from './AssetThumbnail';
import { RequestAccessModal } from './RequestAccessModal';
import type { Asset } from '../api/types';

function fmtBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(1)} MB`;
  return `${(n / 1024 ** 3).toFixed(2)} GB`;
}

interface Props {
  assets: Asset[];
  /** 点卡片主体 → 单文件详情(调用方传 assetItems 的 index,state 存 index 不存 id) */
  onOpen: (index: number) => void;
  /** 勾选多选(批量打标/删除);缺省 = 纯浏览(FolderDetailPage) */
  selectable?: boolean;
  selectedIds?: string[];
  onToggle?: (id: string) => void;
  loading?: boolean;
  emptyText?: React.ReactNode;
}

export function AssetCardList({
  assets, onOpen, selectable, selectedIds, onToggle, loading, emptyText,
}: Props) {
  const { message } = App.useApp();
  const dlLink = useDownloadLink();
  const downloads = useDownloads();
  const [applyAsset, setApplyAsset] = useState<Asset | null>(null);

  const handleDownload = async (a: Asset) => {
    try {
      const link = await dlLink.mutateAsync(a.id);
      await downloads.start(link.url, a.filename, { assetId: a.id });
    } catch (e: unknown) {
      const err = e as { response?: { status?: number } };
      if (err.response?.status === 403) setApplyAsset(a);
      else message.error(errorMessage(e, '下载失败'));
    }
  };

  if (loading) {
    return (
      <div style={{ padding: '16px 4px' }}>
        <Skeleton active paragraph={{ rows: 8 }} />
      </div>
    );
  }

  if (assets.length === 0) {
    return emptyText ?? null;
  }

  return (
    <div>
      {assets.map((a, i) => {
        const labels = a.user_labels ?? [];
        return (
          <div
            key={a.id}
            onClick={() => onOpen(i)}
            style={{
              display: 'flex', alignItems: 'center', gap: 10,
              padding: '8px 8px 8px 4px', marginBottom: 8,
              background: 'var(--ms-surface)',
              border: '1px solid var(--ms-hairline)',
              borderRadius: 'var(--ms-radius-lg)',
              cursor: 'pointer',
            }}
          >
            {selectable && (
              // 44px 命中区;勾选不触发 open(stopPropagation 在外层 label 拦)
              <label
                onClick={e => e.stopPropagation()}
                style={{
                  display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
                  width: 44, height: 44, flexShrink: 0, cursor: 'pointer',
                }}
              >
                <Checkbox
                  checked={selectedIds?.includes(a.id)}
                  onChange={() => onToggle?.(a.id)}
                />
              </label>
            )}
            <AssetThumbnail asset={a} size={44} />
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{
                fontSize: 13.5, fontWeight: 500, lineHeight: 1.35,
                color: 'var(--ms-ink)', wordBreak: 'break-all',
                display: '-webkit-box', WebkitLineClamp: 2, WebkitBoxOrient: 'vertical',
                overflow: 'hidden',
              }}>{a.filename}</div>
              <div style={{ marginTop: 2, fontSize: 11.5, color: 'var(--ms-ink-muted)' }}>
                <span className="ms-mono">{fmtBytes(a.size_bytes)}</span>
                <span style={{ margin: '0 6px', opacity: 0.4 }}>·</span>
                <span>{new Date(a.created_at).toLocaleString('zh-CN', {
                  month: '2-digit', day: '2-digit',
                  hour: '2-digit', minute: '2-digit',
                })}</span>
              </div>
              {labels.length > 0 && (
                <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, marginTop: 5 }}>
                  {labels.slice(0, 3).map(l => (
                    <span key={l} style={{
                      padding: '1px 6px',
                      background: 'var(--ms-hairline-soft)',
                      borderRadius: 3,
                      fontSize: 10.5,
                      color: 'var(--ms-ink-muted)',
                    }}>{l}</span>
                  ))}
                  {labels.length > 3 && (
                    <span style={{
                      padding: '1px 6px',
                      fontSize: 10.5,
                      color: 'var(--ms-ink-subtle)',
                    }}>+{labels.length - 3}</span>
                  )}
                </div>
              )}
            </div>
            <Tooltip title="下载">
              <Button
                type="text"
                aria-label={`下载 ${a.filename}`}
                icon={<Download size={18} strokeWidth={1.8} />}
                loading={dlLink.isPending && dlLink.variables === a.id}
                onClick={(e) => { e.stopPropagation(); void handleDownload(a); }}
                style={{
                  width: 44, height: 44, flexShrink: 0,
                  color: 'var(--ms-ink-muted)',
                }}
              />
            </Tooltip>
          </div>
        );
      })}

      {applyAsset && (
        <RequestAccessModal
          open onClose={() => setApplyAsset(null)}
          targetId={applyAsset.id} targetName={applyAsset.filename}
          targetType="asset" defaultAction="download"
        />
      )}
    </div>
  );
}
