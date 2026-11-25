/**
 * AssetWaterfallList — PC 瀑布流列表容器(小图 5 列 / 大图 2 列,variant 决定)。
 * 方案出处:docs/qdev/2026-11-25-pc-folder-view-modes.md §2.4/§2.5 + 决策 D8 退路。
 * 实现(D8 预定退路,测试后修复轮 P1-1):按列均分 —— JS 把 assets 分成 N 列,
 * 外层 grid repeat(N, minmax(0,1fr)) gap 12 只做列容器,每列 flex column gap 12
 * 竖向堆叠;列间互不影响高度,矮瓦片下方不留空洞、后续瓦片自然上移补位(此前
 * 单 grid 按行对齐、行高=该行最高瓦片会留空洞,不满足瀑布流诉求)。
 * 分配策略:贪心最短列优先(useMemo 包裹)—— 按 tags.thumbnail_width/height 估算
 * 瓦片相对高度(以列宽为 1 单位,缺失/非法按 1:1 兜底 §2.11),保持输入顺序遍历、
 * 每次放入当前估算总高最小的列,不全局排序。
 * 职责边界:只负责列分配、布局、loading 占位、空态透传与逐瓦片装配;
 * 单瓦片视觉/缩略图请求在 AssetWaterfallItem,模式持久化在 hooks/use-view-mode.ts(本文件不消费)。
 * data-asset-id 全列表只在 AssetWaterfallItem 根节点一层(深链 querySelector 取第一个不受影响)。
 * props 与 AssetCardList 同名同形:selectable/selectedIds(string[])/onToggle/onOpen(index)/
 * highlightId;空态处理沿用 AssetCardList 的 emptyText ?? null 惯例。
 */
import { useMemo } from 'react';
import { AssetWaterfallItem } from './AssetWaterfallItem';
import type { Asset } from '../api/types';

interface Props {
  assets: Asset[];
  /** small→5 列 + size=small;large→2 列 + size=large(方案 §2.4/§2.5) */
  variant: 'small' | 'large';
  /** true 时渲染等列数灰色占位瓦片(先于空态判断,语义与 AssetCardList.loading 一致) */
  loading?: boolean;
  /** 盲搜深链定位:命中瓦片 accent 描边(AssetCardList.tsx:76,:86-87 同视觉语言) */
  highlightId?: string | null;
  /** 无多选语义时点击回调(与 AssetCardList.onOpen 同形,存 index 不存 id) */
  onOpen?: (index: number) => void;
  /** 与 AssetCardList 同名 prop 语义一致: true 时点击=多选切换 */
  selectable?: boolean;
  /** 与 AssetCardList.selectedIds 完全同形(string[]) */
  selectedIds?: string[];
  onToggle?: (id: string) => void;
  /** 空数组时的占位(沿用 AssetCardList 惯例:emptyText ?? null,由页面传 antd Empty) */
  emptyText?: React.ReactNode;
}

/** 占位瓦片纵横比小循环,模拟瀑布流高低错落的占位观感 */
const PLACEHOLDER_RATIOS = ['1', '4 / 5', '3 / 4', '1', '5 / 4', '4 / 5'];

/** 瓦片相对高度估算(各列等宽,以列宽为 1 单位):宽/高比取倒数;缺失或非法按 1:1 */
function tileRelativeHeight(a: Asset): number {
  const w = a.tags?.thumbnail_width;
  const h = a.tags?.thumbnail_height;
  const ratio = typeof w === 'number' && w > 0 && typeof h === 'number' && h > 0 ? w / h : 1;
  return 1 / ratio;
}

export function AssetWaterfallList({
  assets, variant, loading, highlightId, onOpen, selectable, selectedIds, onToggle, emptyText,
}: Props) {
  const cols = variant === 'small' ? 5 : 2;

  // 列分配(贪心最短列优先):index 随瓦片绑定,onOpen(index) 语义与 AssetCardList
  // 同(原 assets 数组下标),瀑布流列序不改变详情 Drawer 的 ‹ n/N › 切张顺序
  const columns = useMemo(() => {
    const heights = new Array<number>(cols).fill(0);
    const buckets: { asset: Asset; index: number }[][] = Array.from({ length: cols }, () => []);
    assets.forEach((a, i) => {
      let target = 0;
      for (let c = 1; c < cols; c++) {
        if (heights[c] < heights[target]) target = c;
      }
      heights[target] += tileRelativeHeight(a);
      buckets[target].push({ asset: a, index: i });
    });
    return buckets;
  }, [assets, cols]);

  if (loading) {
    // 灰色占位瓦片(两行量,近似每页 30 条的首屏骨架),按列数均分到各列竖排,
    // 与正片同为瀑布流骨架观感
    const rows = 2;
    return (
      <div
        aria-busy="true"
        style={{
          display: 'grid',
          gridTemplateColumns: `repeat(${cols}, minmax(0, 1fr))`,
          gap: 12,
        }}
      >
        {Array.from({ length: cols }, (_, c) => (
          <div key={c} style={{ display: 'flex', flexDirection: 'column', gap: 12, minWidth: 0 }}>
            {Array.from({ length: rows }, (_, r) => {
              const i = c * rows + r;
              return (
                <div
                  key={r}
                  style={{
                    aspectRatio: PLACEHOLDER_RATIOS[i % PLACEHOLDER_RATIOS.length],
                    borderRadius: 'var(--ms-radius-md)',
                    background: 'var(--ms-hairline-soft)',
                    border: '1px solid var(--ms-hairline)',
                  }}
                />
              );
            })}
          </div>
        ))}
      </div>
    );
  }

  // 空态与 AssetCardList 同一处理:透传 emptyText(页面层给 antd Empty),缺省渲染 null
  if (assets.length === 0) {
    return emptyText ?? null;
  }

  return (
    // alignItems:'start' 防列容器被 grid 默认 stretch 拉到同行最高(列高各自自适应)
    <div
      style={{
        display: 'grid',
        gridTemplateColumns: `repeat(${cols}, minmax(0, 1fr))`,
        gap: 12,
        alignItems: 'start',
      }}
    >
      {columns.map((col, c) => (
        <div key={c} style={{ display: 'flex', flexDirection: 'column', gap: 12, minWidth: 0 }}>
          {col.map(({ asset, index }) => (
            <AssetWaterfallItem
              key={asset.id}
              asset={asset}
              index={index}
              variant={variant}
              selectable={selectable}
              selected={selectedIds?.includes(asset.id) ?? false}
              highlight={asset.id === highlightId}
              onOpen={onOpen}
              onToggle={onToggle}
            />
          ))}
        </div>
      ))}
    </div>
  );
}
