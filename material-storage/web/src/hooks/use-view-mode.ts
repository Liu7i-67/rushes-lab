/**
 * use-view-mode — PC 文件夹三视图模式(detail/small/large)持久化。
 * 方案出处:docs/qdev/2026-11-25-pc-folder-view-modes.md §3.1 A。
 * 职责边界:仅负责 FolderViewMode 的 localStorage 读写 + React hook 封装;
 * 不感知页面与视口(compact 判定由页面用 useCompactViewport 做),不做 Context。
 * 写法跟随 api/client.ts:9-16 先例(key 常量 + try/catch get/set 一对函数)。
 */
import { useState } from 'react';

export type FolderViewMode = 'detail' | 'small' | 'large';

export const FOLDER_VIEW_MODE_KEY = 'ms-pc-folder-view-mode';

/** 合法值白名单:缓存被手改/旧版本残留时回落 'detail'(方案 §2.6)。 */
const VALID_MODES: FolderViewMode[] = ['detail', 'small', 'large'];

export function readViewMode(): FolderViewMode {
  try {
    const raw = localStorage.getItem(FOLDER_VIEW_MODE_KEY);
    return VALID_MODES.includes(raw as FolderViewMode) ? (raw as FolderViewMode) : 'detail';
  } catch {
    return 'detail'; // 隐私模式 localStorage 不可用等,静默回落
  }
}

export function writeViewMode(m: FolderViewMode): void {
  try {
    localStorage.setItem(FOLDER_VIEW_MODE_KEY, m);
  } catch { /* ignore:落盘失败不影响本次会话内切换 */ }
}

/** 惰性 useState(首读一次 localStorage)+ set 时同步落盘;返回 readonly 元组。 */
export function useViewMode(): readonly [FolderViewMode, (m: FolderViewMode) => void] {
  const [mode, setMode] = useState<FolderViewMode>(readViewMode);
  const update = (m: FolderViewMode) => {
    setMode(m);
    writeViewMode(m);
  };
  return [mode, update] as const;
}
