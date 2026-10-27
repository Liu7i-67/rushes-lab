/**
 * 预览 footer/文案子件(W2 从 AssetPreviewModal 抽出,主文件守住 500 行硬约束)。
 * ViewOriginalButton — 「查看原图」:渐进缩略图旁的显式出口,点击才 POST download-link
 *   换 <img src>(审计随之产生;仅非 GIF image kind 且有 thumbnail_key 时由调用方渲染)。
 * CompressedHint — 压缩图提示文案(livp/heic 分支同款文案先例,doc §3.6.6)。
 */
import { Button } from 'antd';
import { Maximize2 } from 'lucide-react';

interface ViewOriginalProps {
  /** compact 视口(footer 按钮统一 large 尺寸,见 AssetPreviewModal 既有约定)。*/
  compact: boolean;
  /** 无下载权时禁用(download-link 会 403,与下载按钮同语义)。*/
  disabled?: boolean;
  loading?: boolean;
  onClick: () => void;
}

export function ViewOriginalButton({ compact, disabled, loading, onClick }: ViewOriginalProps) {
  return (
    <Button size={compact ? 'large' : 'middle'} type="text"
            icon={<Maximize2 size={15} strokeWidth={1.8} />}
            disabled={disabled}
            loading={loading}
            onClick={onClick}>
      查看原图
    </Button>
  );
}

export function CompressedHint() {
  return (
    <div style={{
      textAlign: 'center', marginTop: 8,
      fontSize: 12, color: 'var(--ms-ink-subtle)',
    }}>
      预览为压缩图(≤1024px),下载可获取原片。
    </div>
  );
}
