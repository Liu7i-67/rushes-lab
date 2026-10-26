/**
 * image kind 渲染区(W2 从 AssetPreviewModal 抽出,主文件守住 500 行硬约束):
 * 渐进显示 — 先渲 small(src),onload 后若 largeUrl 已就绪则平滑换 src(doc §3.6.1);
 * GIF carve-out / 无缩略图回落原图时 largeUrl 为 null,行为退化为单张 <img>(同旧版)。
 * key=asset.id 由调用方保证:切张即重挂载,loaded 态不跨 asset 残留。
 */
import { useState } from 'react';
import type { Asset } from '../../api/types';
import { CompressedHint } from './PreviewImageFooter';

interface Props {
  asset: Asset;
  /** 当前应显示的 URL(small 缩略图 / 失败回落原图 / 查看原图)。*/
  src: string;
  /** large 缩略图 URL;null = 不做 onload 换源(原图/GIF/已显原图)。*/
  largeUrl?: string | null;
  /** 是否显示「预览为压缩图」提示(仅渐进缩略图在显时为 true)。*/
  showHint?: boolean;
  /** <img> 加载失败回调(渐进链路据此回落 download-link 原图,doc §3.6.2)。*/
  onImgError?: () => void;
}

export function PreviewImage({ asset, src, largeUrl, showHint, onImgError }: Props) {
  // small onload 后才允许把 src 换成 largeUrl(避免抢跳闪白;doc:onload 后替换)
  const [loaded, setLoaded] = useState(false);
  return (
    <div>
      <div style={{
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        background: 'var(--ms-hairline-soft)',
        borderRadius: 'var(--ms-radius-sm)',
        minHeight: 200,
      }}>
        <img
          src={loaded && largeUrl ? largeUrl : src}
          alt={asset.filename}
          onLoad={() => setLoaded(true)}
          onError={onImgError}
          style={{
            maxWidth: '100%', maxHeight: 'min(65vh, 65dvh)',
            objectFit: 'contain', display: 'block',
          }}
        />
      </div>
      {showHint && <CompressedHint />}
    </div>
  );
}
