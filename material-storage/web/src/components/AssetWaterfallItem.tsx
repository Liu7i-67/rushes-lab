/**
 * AssetWaterfallItem — PC 瀑布流单瓦片(小图 5 列 / 大图 2 列共用,variant 决定缩略图规格)。
 * 方案出处:docs/qdev/2026-11-25-pc-folder-view-modes.md §3.1 C。
 * 职责边界:只渲染单个资产瓦片(aspect-ratio 盒 + 封面图 + 选中/高亮/hover 视觉 + 点击回调);
 * 列数/网格布局由 AssetWaterfallList 负责,页面层状态(选中集合/Drawer)不在此感知。
 * 缩略图 URL 走 react-query,queryKey ['thumbnail-url', asset.id, size] 与 AssetThumbnail.tsx:21-31
 * 同族共享缓存(staleTime 25min 同口径);无缩略图/加载失败回落 FileText 文件图标(沿用其兜底视觉)。
 */
import { FileText, Check } from 'lucide-react';
import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { http } from '../api/client';
import type { Asset } from '../api/types';

// color-mix() 支持检测(P2-1 渐变回退门控):老浏览器(<Chrome 111)不支持时,
// 含 color-mix 的 background 声明会在 CSS 解析期整条丢弃。检测一次存模块级常量,
// 不随渲染重复求值
const supportsColorMix = typeof CSS !== 'undefined'
  && typeof CSS.supports === 'function'
  && CSS.supports('color', 'color-mix(in srgb, red 50%, transparent)');

interface Props {
  asset: Asset;
  /** 点击打开详情时的下标(容器传入,语义与 AssetCardList.onOpen 的 index 一致) */
  index: number;
  /** small→240px 规格(size=small);large→1024px 规格(size=large) */
  variant: 'small' | 'large';
  selectable?: boolean;
  selected?: boolean;
  /** 盲搜深链定位高亮(与 AssetCardList.tsx:76,:86-87 同视觉语言) */
  highlight?: boolean;
  onOpen?: (index: number) => void;
  onToggle?: (id: string) => void;
}

export function AssetWaterfallItem({
  asset, index, variant, selectable, selected, highlight, onOpen, onToggle,
}: Props) {
  const hasThumb = !!asset.tags?.thumbnail_key;
  const [imgError, setImgError] = useState(false);
  const [hover, setHover] = useState(false);

  const { data } = useQuery({
    // key 含规格维度(全局契约):variant='small' 时与 AssetThumbnail 列表缓存互通共享
    queryKey: ['thumbnail-url', asset.id, variant],
    queryFn: async () =>
      (await http.get<{ url: string; expires_in: number; variant?: 'small' | 'large' }>(
        `/api/v1/assets/${asset.id}/thumbnail-url?size=${variant}`,
      )).data,
    enabled: hasThumb && !imgError,
    staleTime: 25 * 60 * 1000,   // 25 min(presigned 30 min,留余量;与 AssetThumbnail 一致)
    retry: false,
  });

  // 纵横比:tags.thumbnail_width/height;缺失或非法 → 1:1 兜底(方案 §2.11 不破版式)
  const w = asset.tags?.thumbnail_width;
  const h = asset.tags?.thumbnail_height;
  const ratio = typeof w === 'number' && w > 0 && typeof h === 'number' && h > 0 ? w / h : 1;
  const showImg = hasThumb && data?.url && !imgError;

  const handleClick = () => {
    // selectable 时点击=多选切换(项目详情页语义);否则=打开详情(独立文件夹页语义)。
    // dev-only 漏配告警(P2-3):selectable 传了但 onToggle 未传(或反之)时点击会
    // 静默 no-op,开发期直接提示;生产构建 DEV 恒 false 被静态消除,零行为变化
    if (import.meta.env.DEV
        && ((selectable && !onToggle) || (!selectable && !onOpen))) {
      console.warn('[AssetWaterfallItem] selectable/onOpen 回调缺失', asset.id);
    }
    if (selectable) onToggle?.(asset.id);
    else onOpen?.(index);
  };

  return (
    <div
      data-asset-id={asset.id}
      title={asset.filename}
      role="button"
      tabIndex={0}
      onClick={handleClick}
      onKeyDown={(e) => {
        // 键盘可达性(P2-4):Enter/Space 与点击同款 handleClick;Space 需
        // preventDefault,否则按键会滚动页面。仅改交互,视觉零变化
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          handleClick();
        }
      }}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        position: 'relative',
        width: '100%',
        aspectRatio: String(ratio),
        overflow: 'hidden',
        borderRadius: 'var(--ms-radius-md)',
        background: 'var(--ms-hairline-soft)',
        // 描边分层:选中=accent 2px;深链高亮=accent 1px+soft 环(AssetCardList 同语言);
        // 平时 hairline,hover 描边加深给可点击反馈
        border: selected ? '2px solid var(--ms-accent)'
          : highlight ? '1px solid var(--ms-accent)'
          : hover ? '1px solid var(--ms-ink-subtle)'
          : '1px solid var(--ms-hairline)',
        boxShadow: highlight ? '0 0 0 3px var(--ms-accent-soft)' : undefined,
        cursor: 'pointer',
      }}
    >
      {showImg ? (
        <img
          src={data.url}
          alt=""
          loading="lazy"
          decoding="async"
          onError={() => setImgError(true)}
          style={{
            position: 'absolute', inset: 0,
            width: '100%', height: '100%',
            objectFit: 'cover',
            display: 'block',
          }}
        />
      ) : (
        // 兜底:无缩略图资产 / 签名失败 / img onError(视觉沿用 AssetThumbnail 的 FileText)
        <span style={{
          position: 'absolute', inset: 0,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          color: 'var(--ms-ink-subtle)',
        }}>
          <FileText size={variant === 'large' ? 48 : 32} strokeWidth={1.5} />
        </span>
      )}

      {selected && (
        // 选中徽标:左上角 accent 圆点 + 对勾(方案 §2.8)
        <span style={{
          position: 'absolute', top: 8, left: 8, zIndex: 2,
          width: 22, height: 22, borderRadius: '50%',
          background: 'var(--ms-accent)', color: 'var(--ms-surface)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
        }}>
          <Check size={14} strokeWidth={3} />
        </span>
      )}

      {hover && (
        // hover 浮层:底部渐变 + 文件名单行截断。两层同位(P2-1):外层浮层带纯色
        // 半透明回退底(rgba 硬编码:无令牌对应的遮罩色,非主题色),内层满尺寸 span
        // 叠 --ms-ink 的 color-mix 渐变。老浏览器不支持 color-mix → 渐变整条声明
        // 被丢弃,显示外层纯色;支持 color-mix 的浏览器按 supportsColorMix 跳过外层
        // 纯色只渲染渐变(两层同显会让渐变顶部透明段透出纯色,柔和渐变变硬边色块)。
        // 渐变层 zIndex:-1 落在外层背景之上、文件名文字之下,两种情况下都可读;
        // 单行截断与现有视觉不变
        <span style={{
          position: 'absolute', left: 0, right: 0, bottom: 0, zIndex: 1,
          padding: '22px 10px 8px',
          background: supportsColorMix ? undefined : 'rgba(26, 26, 26, 0.72)',
          color: 'var(--ms-canvas)',
          fontSize: 12.5, lineHeight: 1.4,
          whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
        }}>
          <span aria-hidden style={{
            position: 'absolute', inset: 0, zIndex: -1,
            background: 'linear-gradient(to top, color-mix(in srgb, var(--ms-ink) 78%, transparent), transparent)',
          }} />
          {asset.filename}
        </span>
      )}
    </div>
  );
}
