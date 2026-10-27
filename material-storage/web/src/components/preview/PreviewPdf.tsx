/**
 * pdf 预览(从 AssetPreviewModal 原样抽出,行为不变):
 * iOS Safari 不支持 iframe 内嵌 PDF 交互 → 降级提示卡;其余走 iframe 原生 viewer。
 */
import { Button } from 'antd';
import { Download, FileText } from 'lucide-react';
import type { Asset } from '../../api/types';
import { isIOS } from '../../lib/ua';

interface Props {
  asset: Asset;
  /** download-link 签名 URL。*/
  content: string;
  compact: boolean;
  /** 下载按钮 loading 态(沿用调用方的 dlLink mutation 实例)。*/
  downloadPending: boolean;
  onDownload: () => void;
}

export function PreviewPdf({ asset, content, compact, downloadPending, onDownload }: Props) {
  if (isIOS()) {
    // iOS 内嵌 PDF 受限(Safari 不支持 iframe 内嵌 PDF 交互),降级为提示卡(§3.6)
    return (
      <div style={{
        padding: 32, textAlign: 'center',
        border: '1px dashed var(--ms-hairline)',
        borderRadius: 'var(--ms-radius-sm)',
        background: 'var(--ms-hairline-soft)',
      }}>
        <FileText size={28} strokeWidth={1.5}
                  style={{ color: 'var(--ms-ink-subtle)', marginBottom: 12 }} />
        <div style={{
          fontSize: 13, color: 'var(--ms-ink-muted)', lineHeight: 1.7,
          marginBottom: 16,
        }}>
          iOS 内嵌预览受限,<br />点击下载后用系统预览打开。
        </div>
        <Button type="primary" size={compact ? 'large' : 'middle'}
                icon={<Download size={15} strokeWidth={1.8} />}
                loading={downloadPending}
                onClick={onDownload}>
          下载 PDF
        </Button>
      </div>
    );
  }
  return (
    <iframe
      src={content}
      title={asset.filename}
      style={{
        width: '100%', height: 'min(68vh, 68dvh)',
        border: '1px solid var(--ms-hairline)',
        borderRadius: 'var(--ms-radius-sm)',
        background: 'var(--ms-hairline-soft)',
      }}
    />
  );
}
