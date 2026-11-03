/**
 * AI 自动打标 + 视频智能分段 client(2026-11-03 ai-tagging-slicing §2.6 契约)。
 * 后端端点并行开发中:读侧(getAssetAi)对 404(AI 未启用/软删/无数据)与网络错误
 * 一律静默降级返回 null —— 组件层渲染「暂无 AI 识别结果」空态,且不触发全局
 * queryCache toast;AI 区故障不得影响详情面板其余功能(整区 try 边界的 client 半边,
 * render 半边由组件对字段逐个兜空)。
 */
import { useQuery } from '@tanstack/react-query';
import { http } from './client';
import type { AssetAiInfo, AssetAiKeyframeUrlsOut } from './types';

/** GET /api/v1/assets/{id}/ai — annotation + segments 一次带回;任何失败 → null(静默)。*/
export async function getAssetAi(assetId: string): Promise<AssetAiInfo | null> {
  try {
    return (await http.get<AssetAiInfo>(`/api/v1/assets/${assetId}/ai`)).data;
  } catch {
    // 404 = AI_ENABLED=false / 资产软删 / 无行;网络错误同样静默。AI 区是辅助信息,
    // 不值得全局报错 toast,吞掉后由组件空态兜底
    return null;
  }
}

/** POST /api/v1/assets/{id}/ai/keyframe-urls — 按需批量签发段关键帧 presigned URL
 *  (入参 segment_idxs ≤10 段/请求,后端 enforce;返回 {str(idx): [url,…]})。
 *  失败向上抛:缩略图属增强信息,调用方(SegmentSection)静默置失败态即可。*/
export async function postKeyframeUrls(
  assetId: string,
  segmentIdxs: number[],
): Promise<Record<string, string[]>> {
  const { data } = await http.post<AssetAiKeyframeUrlsOut>(
    `/api/v1/assets/${assetId}/ai/keyframe-urls`,
    { segment_idxs: segmentIdxs },
  );
  return data.urls ?? {};
}

/** 详情面板 AI 区取数 hook:错误已在 getAssetAi 层静默,query 永不 error(null =
 *  AI 未启用/暂无数据)。切资产换 key,缓存随 staleTime 30s 短暂复用 —— Drawer
 *  ‹ n/N › 切张来回翻不重复打请求。*/
export const useAssetAi = (assetId: string | undefined, enabled = true) =>
  useQuery({
    queryKey: ['asset-ai', assetId],
    queryFn: () => (assetId ? getAssetAi(assetId) : Promise.resolve(null)),
    enabled: !!assetId && enabled,
    staleTime: 30_000,
  });
