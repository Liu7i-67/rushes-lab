/**
 * UA 功能性降级判定(方案 §3.6 / §1.2)。
 * 不参与布局切换(布局唯一判定源是 useCompactViewport);
 * 唯一使用点:AssetPreviewModal 的 PDF 内嵌预览 iOS 降级。
 */
export function isIOS(): boolean {
  const ua = navigator.userAgent;
  return /iP(hone|od)/.test(ua)
    || (/Mac/.test(ua) && navigator.maxTouchPoints > 1); // iPadOS 13+ 伪装 Mac UA
}
