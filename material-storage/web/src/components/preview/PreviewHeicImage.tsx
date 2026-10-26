/**
 * heic/heif 大图预览(从 AssetPreviewModal 原样抽出,行为不变,doc §3.6.4 分支不动):
 * 浏览器(除 Safari)不解码 HEIC 原图 → 走服务端 pillow-heif 转码的 JPEG 缩略图(≤1024px)。
 */
import type { Asset } from '../../api/types';

interface Props {
  asset: Asset;
  /** 缩略图签名 URL(由调用方经 thumbnail-url 端点取得)。*/
  url: string;
}

export function PreviewHeicImage({ asset, url }: Props) {
  return (
    <div>
      <div style={{
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        background: 'var(--ms-hairline-soft)',
        borderRadius: 'var(--ms-radius-sm)',
        minHeight: 200,
      }}>
        <img src={url} alt={asset.filename} style={{
          maxWidth: '100%', maxHeight: 'min(65vh, 65dvh)',
          objectFit: 'contain', display: 'block',
        }} />
      </div>
      <div style={{
        textAlign: 'center', marginTop: 8,
        fontSize: 12, color: 'var(--ms-ink-subtle)',
      }}>
        HEIC 预览为服务端压缩图(≤1024px),下载可获取原片。
      </div>
    </div>
  );
}
