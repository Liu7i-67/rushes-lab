/**
 * SegmentSection — 素材详情面板「智能分段」区(ai-tagging-slicing §10/§12,P2)。
 * 视频类型且 segments 非空时由面板挂载:段列表(段序 + 起止时间 mm:ss + 段标签 +
 * 段描述省略 + 首帧缩略图)。点击行 → 面板内嵌 <video> currentTime=start/1000 定位
 * 播放(纯前端):预览已开则直接定位;未开则回调面板打开预览 modal,随后短轮询
 * 等视频元素出现再定位(下载链路为既有预览行为,无新增后端语义)。
 * 缩略图懒加载:行进入视口才 POST keyframe-urls([idx]) 签发该段首帧(≤1 段/请求,
 * 有界);失败静默置失败态,不阻塞列表。
 */
import { List, Tag } from 'antd';
import { Clapperboard } from 'lucide-react';
import { useEffect, useRef, useState } from 'react';
import { postKeyframeUrls, useAssetAi } from '../api/ai';
import type { Asset, AssetVideoSegment } from '../api/types';
import { SectionLabel } from './SectionLabel';

/** ms → mm:ss(≥1h 扩展为 h:mm:ss;>60min 长视频是本功能的明确样本)。*/
function fmtMs(ms: number): string {
  const s = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  const mm = String(m).padStart(2, '0');
  const ss = String(sec).padStart(2, '0');
  return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
}

/** 元数据兜底降级字段读取(meta 为 Record<string, unknown>,逐键窄化)。*/
const describeFailed = (seg: AssetVideoSegment) => seg.meta?.describe_failed === true;
const segmentedByInterval = (seg: AssetVideoSegment) => seg.meta?.segmented_by === 'interval';

/** 进入视口一次性触发(IntersectionObserver;环境缺失时异步视为可见)。*/
function useInViewport<T extends HTMLElement>() {
  const ref = useRef<T | null>(null);
  const [inView, setInView] = useState(false);
  useEffect(() => {
    if (inView) return;
    const el = ref.current;
    if (!el) return;
    // 无 IO 的环境(理论分支):异步置可见(setState 进 effect 须走异步回调形态)
    if (typeof IntersectionObserver === 'undefined') {
      const id = window.setTimeout(() => setInView(true), 0);
      return () => window.clearTimeout(id);
    }
    const io = new IntersectionObserver((entries) => {
      if (entries.some((e) => e.isIntersecting)) {
        setInView(true);
        io.disconnect();
      }
    }, { rootMargin: '80px' });   // 提前 80px 预取,滚动到时图已就位
    io.observe(el);
    return () => io.disconnect();
  }, [inView]);
  return { ref, inView };
}

/** 段首帧缩略图(懒加载):进入视口才签发;失败/无帧静默占位。*/
function SegmentThumb({ assetId, seg }: { assetId: string; seg: AssetVideoSegment }) {
  const { ref, inView } = useInViewport<HTMLDivElement>();
  const [url, setUrl] = useState<string | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    if (!inView || failed || url) return;
    let cancelled = false;
    (async () => {
      try {
        const urls = await postKeyframeUrls(assetId, [seg.idx]);
        const first = urls[String(seg.idx)]?.[0] ?? null;
        if (cancelled) return;
        if (first) setUrl(first);
        else setFailed(true);   // 无关键帧对象(如 describe_failed 段)→ 占位
      } catch {
        if (!cancelled) setFailed(true);   // 签发失败静默:缩略图属增强信息
      }
    })();
    return () => { cancelled = true; };
  }, [inView, failed, url, assetId, seg.idx]);

  return (
    <div ref={ref} title={seg.keyframe_count > 0 ? `关键帧 ×${seg.keyframe_count}` : undefined}
         style={{
           flexShrink: 0, width: 64, height: 36, overflow: 'hidden',
           borderRadius: 'var(--ms-radius-sm)',
           background: 'var(--ms-hairline-soft)',
           border: failed && seg.keyframe_count === 0
             ? '1px dashed var(--ms-hairline)' : '1px solid var(--ms-hairline-soft)',
           display: 'grid', placeItems: 'center',
         }}>
      {url ? (
        <img src={url} alt={`段 ${seg.idx + 1} 首帧`} loading="lazy"
             style={{ width: '100%', height: '100%', objectFit: 'cover', display: 'block' }} />
      ) : failed ? (
        <Clapperboard size={13} strokeWidth={1.5} style={{ color: 'var(--ms-ink-subtle)' }} />
      ) : null}
    </div>
  );
}

interface Props {
  asset: Asset;
  /** 面板回调:预览 modal 未开(DOM 无 <video>)时先打开预览,再轮询定位。*/
  onRequestPreview: () => void;
}

export function SegmentSection({ asset, onRequestPreview }: Props) {
  // 自取 AI 数据:与 AiInfoSection 共用同一 queryKey(['asset-ai', id]),react-query
  // 去重后整面板只发一次 GET /assets/{id}/ai;segments 非空才渲染(否则整区不占位)
  const { data, isPending } = useAssetAi(asset.id);
  const segments: AssetVideoSegment[] =
    data?.segments && Array.isArray(data.segments) ? data.segments : [];
  // 定位轮询计时器 + 代际守卫。切张/卸载的清理走 effect cleanup(refs 规则禁止
  // render 期触碰;cleanup 同时覆盖「预览已请求但视频还没挂出」的在途轮询)
  const timerRef = useRef<number | null>(null);
  const seekGenRef = useRef(0);
  useEffect(() => {
    return () => {
      seekGenRef.current += 1;   // 作废在途轮询:迟到 tick 的 gen 不匹配即自弃
      if (timerRef.current !== null) {
        window.clearInterval(timerRef.current);
        timerRef.current = null;
      }
    };
  }, [asset.id]);

  const seekVideoTo = (el: HTMLVideoElement, sec: number) => {
    const apply = () => {
      try { el.currentTime = sec; } catch { /* 元数据未就绪的瞬态,忽略 */ }
      // 自动播放被浏览器策略拦时静默(画面已定位,用户手动播放即可)
      void el.play().catch(() => { /* noop */ });
    };
    if (el.readyState >= HTMLMediaElement.HAVE_METADATA) apply();
    else el.addEventListener('loadedmetadata', apply, { once: true });
  };

  const locate = (startMs: number) => {
    const sec = startMs / 1000;
    const gen = ++seekGenRef.current;
    const existing = document.querySelector('video');
    if (existing) { seekVideoTo(existing, sec); return; }
    // 预览未开:面板打开预览 modal(既有入口),随后轮询等 <video> 出现再定位。
    // 上限 40 tick(250ms × 40 ≈ 10s):tick 计数替代 Date.now 计时
    // (react-hooks/purity 禁组件体函数内调 impure 全局)
    onRequestPreview();
    if (timerRef.current !== null) window.clearInterval(timerRef.current);
    let ticks = 0;
    timerRef.current = window.setInterval(() => {
      ticks += 1;
      if (gen !== seekGenRef.current || ticks > 40) {
        if (timerRef.current !== null) { window.clearInterval(timerRef.current); timerRef.current = null; }
        return;
      }
      const el = document.querySelector('video');
      if (el) {
        if (timerRef.current !== null) { window.clearInterval(timerRef.current); timerRef.current = null; }
        seekVideoTo(el, sec);
      }
    }, 250);
  };

  // 取数中 / 404 静默 / segments 空 → 整区不渲染(面板挂载条件「视频且 segments 非空」
  // 的组件内半边;404 已在 client 层吞掉,data 为 null 不会报错)
  if (isPending || segments.length === 0) return null;

  return (
    <div style={{
      padding: '14px 20px',
      borderTop: '1px solid var(--ms-hairline-soft)',
    }}>
      <SectionLabel>智能分段({segments.length})</SectionLabel>
      <List
        size="small"
        split={false}
        dataSource={segments}
        locale={{ emptyText: '暂无分段数据' }}
        renderItem={(seg) => {
          const tags = Array.isArray(seg.tags_zh) ? seg.tags_zh : [];
          const desc = (seg.description ?? '').trim();
          return (
            <List.Item
              onClick={() => locate(seg.start_ms)}
              title="点击定位播放"
              style={{
                cursor: 'pointer', padding: '8px 6px', borderRadius: 'var(--ms-radius-sm)',
                transition: 'background var(--ms-dur-fast) var(--ms-ease)',
              }}
              onMouseEnter={(e) => { e.currentTarget.style.background = 'var(--ms-hairline-soft)'; }}
              onMouseLeave={(e) => { e.currentTarget.style.background = 'transparent'; }}
            >
              <div style={{ display: 'flex', gap: 10, alignItems: 'center', width: '100%', minWidth: 0 }}>
                <SegmentThumb assetId={asset.id} seg={seg} />
                <div style={{ flex: 1, minWidth: 0 }}>
                  {/* 行 1:段序 + 起止时间 + 段标签 + 降级标记 */}
                  <div style={{
                    display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap', minWidth: 0,
                  }}>
                    <span className="ms-mono" style={{
                      fontSize: 11.5, color: 'var(--ms-ink)', flexShrink: 0,
                    }}>
                      #{seg.idx + 1} {fmtMs(seg.start_ms)} – {fmtMs(seg.end_ms)}
                    </span>
                    {tags.slice(0, 3).map((t, i) => (
                      <Tag key={`${t}-${i}`}
                           style={{ marginInlineEnd: 0, fontSize: 10.5, lineHeight: '16px' }}>
                        {t}
                      </Tag>
                    ))}
                    {tags.length > 3 && (
                      <span className="ms-mono" style={{ fontSize: 10, color: 'var(--ms-ink-subtle)' }}>
                        +{tags.length - 3}
                      </span>
                    )}
                    {describeFailed(seg) && (
                      <Tag style={{
                        marginInlineEnd: 0, fontSize: 10.5, lineHeight: '16px',
                        color: 'var(--ms-ink-subtle)', background: 'var(--ms-hairline-soft)',
                        border: '1px solid var(--ms-hairline-soft)',
                      }}>识别失败</Tag>
                    )}
                    {segmentedByInterval(seg) && (
                      <span style={{
                        fontSize: 10.5, color: 'var(--ms-ink-subtle)',
                        border: '1px dashed var(--ms-hairline)', borderRadius: 'var(--ms-radius-xs)',
                        padding: '0 5px', lineHeight: '16px', flexShrink: 0,
                      }}>按时长分段</span>
                    )}
                  </div>
                  {/* 行 2:段描述(ellipsis;空则给弱占位保持行高稳定)*/}
                  <div title={desc || undefined} style={{
                    marginTop: 2, fontSize: 11.5, lineHeight: 1.5,
                    color: desc ? 'var(--ms-ink-muted)' : 'var(--ms-ink-subtle)',
                    overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
                  }}>
                    {desc || `关键帧 ×${seg.keyframe_count}`}
                  </div>
                </div>
              </div>
            </List.Item>
          );
        }}
      />
    </div>
  );
}
