/**
 * useProgressiveThumb — web 预览渐进加载(doc §3.6.1/§3.6.2):
 * 1) fetchQuery ['thumbnail-url', id, 'small'] 与列表 AssetThumbnail 共享缓存(同 key 族
 *    同 staleTime,列表已拉过即零请求);响应 variant==='small' → 后台再 fetchQuery large,
 *    调用方在 small <img> onload 后把 src 换成 largeUrl(平滑替换);
 * 2) variant==='large'(后端只有 1024 规格,small 请求直接签发了它)或 variant 字段缺失
 *    (旧后端瞬态)→ 当前 URL 即终态,不发起 large 请求,phase 直接 'swapped';
 * 3) 任一请求失败 → phase 'fallback-needed',调用方回落 download-link 原图。
 * useVideoPoster — video poster 用的 large 单发(doc §3.6.7),与渐进链路同缓存族。
 * 切 asset 用「渲染期重置」(react.dev「props 变化时调整 state」范式):同一渲染内清空,
 * 任何 commit/effect 都不会看到上一个 asset 的 URL;卸载/禁用不清(同 asset 重开瞬通),
 * 在途请求由 generation 守卫丢弃(先例:AssetPreviewModal cancelled)。
 */
import { useEffect, useRef, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import type { QueryClient } from '@tanstack/react-query';
import { http } from '../api/client';

export type ThumbVariant = 'small' | 'large';

interface ThumbUrlResp {
  url: string;
  expires_in: number;
  /** 实际签发的对象规格;旧后端无此字段(缺失按 large 语义短路,不发 large 请求)。*/
  variant?: ThumbVariant;
}

export type ProgressivePhase = 'small' | 'swapped' | 'fallback-needed';

/** 单发缩略图 URL fetchQuery(video poster 复用;key 与 AssetThumbnail 同族共享缓存)。*/
export function fetchThumbUrl(qc: QueryClient, assetId: string, size: ThumbVariant) {
  return qc.fetchQuery({
    queryKey: ['thumbnail-url', assetId, size],
    staleTime: 25 * 60 * 1000, // 25 min(presigned 30 min,留余量;与列表口径一致)
    retry: false,              // 失败即回落,不重试拖慢渐进链路
    queryFn: async () =>
      (await http.get<ThumbUrlResp>(
        `/api/v1/assets/${assetId}/thumbnail-url?size=${size}`,
      )).data,
  });
}

interface Params {
  assetId: string;
  enabled: boolean;
}

/** 渲染期重置通用片段:assetId 变化的同一渲染内清 state,杜绝跨 asset 串图。*/
function useResetOnAssetChange<T>(assetId: string, initial: T): [T, (v: T) => void] {
  const [value, setValue] = useState<T>(initial);
  const [prevAssetId, setPrevAssetId] = useState(assetId);
  if (prevAssetId !== assetId) {
    setPrevAssetId(assetId);
    setValue(initial);
  }
  return [value, setValue];
}

export function useProgressiveThumb({ assetId, enabled }: Params) {
  const queryClient = useQueryClient();
  const [smallUrl, setSmallUrl] = useResetOnAssetChange<string | null>(assetId, null);
  const [largeUrl, setLargeUrl] = useResetOnAssetChange<string | null>(assetId, null);
  const [phase, setPhase] = useResetOnAssetChange<ProgressivePhase>(assetId, 'small');
  // generation 守卫:重挂/禁用后再启用会递增,迟到响应一律丢弃(不入 state)
  const genRef = useRef(0);

  useEffect(() => {
    if (!enabled || !assetId) return;
    const gen = ++genRef.current;
    (async () => {
      try {
        const small = await fetchThumbUrl(queryClient, assetId, 'small');
        if (gen !== genRef.current) return;
        setSmallUrl(small.url);
        // variant 非 'small'(= 'large' 或字段缺失)→ small 已是终态,跳过 large
        if (small.variant !== 'small') { setPhase('swapped'); return; }
        const large = await fetchThumbUrl(queryClient, assetId, 'large');
        if (gen !== genRef.current) return;
        setLargeUrl(large.url);
        setPhase('swapped');
      } catch {
        if (gen !== genRef.current) return;
        setPhase('fallback-needed');
      }
    })();
  }, [enabled, assetId, queryClient, setSmallUrl, setLargeUrl, setPhase]);

  return { smallUrl, largeUrl, phase };
}

/** video poster(doc §3.6.7):large 缩略图 URL;签名失败/未生成 → null(黑帧,不阻塞视频)。*/
export function useVideoPoster(assetId: string, enabled: boolean) {
  const queryClient = useQueryClient();
  const [posterUrl, setPosterUrl] = useResetOnAssetChange<string | null>(assetId, null);
  useEffect(() => {
    if (!enabled || !assetId) return;
    let cancelled = false;
    fetchThumbUrl(queryClient, assetId, 'large')
      .then((d) => { if (!cancelled) setPosterUrl(d.url); })
      .catch(() => { /* 无 poster 可用,保持黑帧 */ });
    return () => { cancelled = true; };
  }, [enabled, assetId, queryClient, setPosterUrl]);
  return posterUrl;
}
