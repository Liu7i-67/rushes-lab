/**
 * livp 静态图/实况短片预览(从 AssetPreviewModal 原样抽出,行为不变):
 * thumbUrl = 缩略图(组织内可见),liveUrl = live-preview-url(可播放,可能为 null);
 * playingLive 归本组件自有 — 调用方保证 key=asset.id,切张即重挂载重置,
 * 与原「assetChanged 清 playingLive」同语义(modal destroyOnClose 覆盖关闭场景)。
 */
import { Button } from 'antd';
import { Image as ImageIcon, Play } from 'lucide-react';
import { useState } from 'react';
import type { Asset } from '../../api/types';

interface Props {
  asset: Asset;
  /** 静态缩略图签名 URL。*/
  thumbUrl: string;
  /** 实况短片 URL(null = 无/未生成/无权限 — 只显示静态图)。*/
  liveUrl: string | null;
  compact: boolean;
}

export function PreviewLivp({ asset, thumbUrl, liveUrl, compact }: Props) {
  const [playingLive, setPlayingLive] = useState(false);
  return (
    <div>
      <div style={{
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        background: '#000',
        borderRadius: 'var(--ms-radius-sm)',
        minHeight: 200,
      }}>
        {playingLive && liveUrl ? (
          <video
            autoPlay loop muted playsInline
            src={liveUrl}
            style={{
              width: '100%', maxHeight: 'min(65vh, 65dvh)',
              display: 'block', borderRadius: 'var(--ms-radius-sm)',
            }}
          />
        ) : (
          <img src={thumbUrl} alt={asset.filename} style={{
            maxWidth: '100%', maxHeight: 'min(65vh, 65dvh)',
            objectFit: 'contain', display: 'block',
          }} />
        )}
      </div>
      {liveUrl && (
        <div style={{ textAlign: 'center', marginTop: 12 }}>
          <Button
            size={compact ? 'middle' : 'small'}
            icon={playingLive
              ? <ImageIcon size={13} strokeWidth={1.8} />
              : <Play size={13} strokeWidth={1.8} />}
            onClick={() => setPlayingLive(v => !v)}
          >
            {playingLive ? '查看照片' : '播放实况'}
          </Button>
        </div>
      )}
      <div style={{
        textAlign: 'center', marginTop: 8,
        fontSize: 12, color: 'var(--ms-ink-subtle)',
      }}>
        Live Photo(实况照片)= 静态图 + 短视频;此处为压缩预览,下载可获取原片。
      </div>
    </div>
  );
}
