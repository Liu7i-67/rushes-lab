/**
 * 素材类型判定(AI 区挂载用)— 与 AssetPreviewModal.detectKind 的扩展名/Content-Type
 * 口径保持一致(白名单同源):AI 打标链覆盖图片 + 视频两族(livp 走静态图段,
 * 见缩略图链式挂载设计),切片区只对真视频显示(livp 实况短片不在 slice 范围)。
 */
import type { Asset } from '../api/types';

/** 与 AssetPreviewModal.IMAGE_EXT 同源(livp 除外,单列)。*/
const IMAGE_EXT = new Set([
  '.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg', '.bmp', '.avif', '.ico',
]);

/** 与 AssetPreviewModal.VIDEO_EXT 同源。*/
const VIDEO_EXT = new Set(['.mp4', '.mov', '.webm', '.m4v']);

function extOf(a: Asset): string {
  const dot = a.filename.toLowerCase().lastIndexOf('.');
  return dot >= 0 ? a.filename.toLowerCase().slice(dot) : '';
}

function contentType(a: Asset): string {
  return (a.content_type || '').toLowerCase();
}

/** 真视频(mp4/mov/webm/m4v 或 video/*);livp 是 zip 容器(静态图 + 实况短片),
 *  不算视频 —— 智能分段区对 livp 不显示。*/
export function isVideoAsset(a: Asset): boolean {
  if (a.filename.toLowerCase().endsWith('.livp')) return false;
  return contentType(a).startsWith('video/') || VIDEO_EXT.has(extOf(a));
}

/** AI 识别区挂载面:图片 / 视频两族;livp 也算(缩略图链对其静态图段同样派打标)。*/
export function isAiTaggableAsset(a: Asset): boolean {
  if (a.filename.toLowerCase().endsWith('.livp')) return true;
  const ct = contentType(a);
  if (ct.startsWith('image/') || ct.startsWith('video/')) return true;
  const ext = extOf(a);
  return IMAGE_EXT.has(ext) || VIDEO_EXT.has(ext);
}
