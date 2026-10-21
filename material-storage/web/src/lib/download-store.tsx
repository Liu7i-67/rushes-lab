/**
 * 下载任务 store —
 *   桌面(有 File System Access API):stream 直写本地文件,零内存 + 进度 + 可取消。
 *   移动端(无 showSaveFilePicker,方案 §3.5):请求 as_attachment=true 链接后
 *   `<a target=_blank>` 直连系统下载器,登记一条立即完成的任务记录 + toast。
 *   原 fetch→Blob 全量内存路径已删除(GB 级原片把移动 Safari 顶爆的元凶);
 *   直连路径无 blob,blobUrl 字段与清理逻辑一并移除。
 *   两段式(livp-download-unpack §6.4):start() 内联的「弹保存框 → 流式写盘」拆为
 *   pickSaveTarget() / streamToHandle() — 批量下载须在点击瞬间(transient activation
 *   窗口 ~5s 内)先弹保存框,轮询 ready 后再 streamToHandle 写盘;单文件 start()
 *   改调两段式,行为不变。
 */
import { createContext, useCallback, useContext, useState, type ReactNode } from 'react';
import { App } from 'antd';
import { useDownloadLink } from '../api/hooks';
import type { DownloadVariant } from './asset-download';

export type DownloadStatus = 'pending' | 'running' | 'success' | 'failed' | 'cancelled';

export interface DownloadTask {
  id: string;
  filename: string;
  url: string;
  startedAt: number;
  status: DownloadStatus;
  loaded: number;
  total: number;
  speedBps?: number;
  error?: string;
  /** 直连系统下载器路径的说明文字(任务中心可后续渲染) */
  note?: string;
  abort?: () => void;
}

interface DownloadCtx {
  tasks: DownloadTask[];
  start: (url: string, filename: string, opts?: {
    assetId?: string;
    variant?: DownloadVariant;
  }) => Promise<string>;  // 返 task id
  /** 批量打包占位(§6.4):仅登记任务记录,不发请求不弹框,返 task id。*/
  addPlaceholder: (filename: string, note?: string) => string;
  /** 两段式②:向已取的 FSA handle 流式写盘;进度/取消/失败都落在该 task 上。*/
  streamToHandle: (handle: unknown, url: string, taskId: string) => Promise<void>;
  /** 局部更新任务(占位 note / 状态推进)。*/
  patchTask: (id: string, p: Partial<DownloadTask>) => void;
  cancel: (id: string) => void;
  remove: (id: string) => void;
}

const Ctx = createContext<DownloadCtx | null>(null);

// 与 DownloadProvider 同文件是 context 惯用形态,拆文件波及 6+ 个使用方;本规则只影响 dev HMR 粒度,豁免
// eslint-disable-next-line react-refresh/only-export-components
export function useDownloads() {
  const v = useContext(Ctx);
  if (!v) throw new Error('useDownloads 必须在 DownloadProvider 内');
  return v;
}

// File System Access API 检测(有 = 桌面;无 = 移动端直连路径)
// eslint-disable-next-line react-refresh/only-export-components
export function hasFSA(): boolean {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return typeof (window as any).showSaveFilePicker === 'function';
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function showSavePicker(filename: string): Promise<any> {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return (window as any).showSaveFilePicker({ suggestedName: filename });
}

/**
 * 两段式①(F13/§6.4)— 弹保存框取落盘 handle。必须在用户手势的 transient activation
 * 窗口内调用(Chromium ~5s):「轮询分钟级 ready 再弹」必抛 SecurityError,批量路径
 * 因此点击瞬间先调它。用户取消(AbortError)/无 FSA/其他失败 → null。
 * createWritable() 不需要激活 — 拿到 handle 后何时写盘不受窗口约束。
 */
// eslint-disable-next-line react-refresh/only-export-components
export async function pickSaveTarget(filename: string): Promise<unknown> {
  if (!hasFSA()) return null;
  try {
    return await showSavePicker(filename);
  } catch {
    return null;
  }
}

const genTaskId = () => `dl-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;

export function DownloadProvider({ children }: { children: ReactNode }) {
  const [tasks, setTasks] = useState<DownloadTask[]>([]);
  const { message } = App.useApp();
  const dlLink = useDownloadLink();

  const patch = useCallback((id: string, p: Partial<DownloadTask>) => {
    setTasks(ts => ts.map(t => t.id === id ? { ...t, ...p } : t));
  }, []);

  // 两段式②:原 start() 内联的 FSA 流式写盘段原样拆出(进度/取消/错误语义不变;
  // 失败不向调用方抛错,落 task.status — 单文件与批量同口径)
  const streamToHandle = useCallback(async (handle: unknown, url: string, taskId: string): Promise<void> => {
    const ctrl = new AbortController();
    patch(taskId, { url, status: 'running', abort: () => ctrl.abort() });
    try {
      const res = await fetch(url, { signal: ctrl.signal });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const total = parseInt(res.headers.get('content-length') ?? '0', 10);
      patch(taskId, { total });

      const reader = res.body!.getReader();
      let loaded = 0;
      let lastTick = Date.now();
      let lastLoaded = 0;

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const writable = await (handle as any).createWritable();

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        await writable.write(value);
        loaded += value.length;

        const now = Date.now();
        if (now - lastTick > 500) {
          const speedBps = ((loaded - lastLoaded) * 1000) / (now - lastTick);
          patch(taskId, { loaded, speedBps });
          lastTick = now; lastLoaded = loaded;
        }
      }
      patch(taskId, { loaded });

      await writable.close();
      patch(taskId, { status: 'success' });
    } catch (e) {
      const err = e as { name?: string; message?: string };
      if (err.name === 'AbortError') patch(taskId, { status: 'cancelled', error: '已取消' });
      else patch(taskId, { status: 'failed', error: err.message ?? String(e) });
    }
  }, [patch]);

  const addPlaceholder = useCallback((filename: string, note?: string): string => {
    const id = genTaskId();
    setTasks(ts => [{
      id, filename, url: '', startedAt: Date.now(),
      status: 'pending', loaded: 0, total: 0, note,
    }, ...ts]);
    return id;
  }, []);

  const start = useCallback(async (
    url: string, filename: string, opts?: { assetId?: string; variant?: DownloadVariant },
  ): Promise<string> => {
    // ── 移动端直连(§3.5):attachment 链接 → 系统下载器,无 JS 内存占用 ──
    if (!hasFSA()) {
      const id = genTaskId();
      let linkUrl = url;
      if (opts?.assetId) {
        // 403 在此抛出,沿用调用方既有 catch → 申请弹窗链路(与 PC 同);
        // 重签必须带 variant(livp 直连也要拿解包 zip;404 由 helper 兜底回落原始)
        const link = await dlLink.mutateAsync({
          assetId: opts.assetId,
          as_attachment: true,
          ...(opts.variant ? { variant: opts.variant } : {}),
        });
        linkUrl = link.url;
      }
      const a = document.createElement('a');
      a.href = linkUrl;
      a.target = '_blank';   // 防御:attachment 失效时不顶掉 SPA
      a.rel = 'noopener';
      document.body.appendChild(a);
      a.click();
      a.remove();
      // 立即完成的任务记录 + toast;保持 start(): Promise<string> 契约(任务中心依赖 task id)
      setTasks(ts => [{
        id, filename, url: linkUrl, startedAt: Date.now(),
        status: 'success', loaded: 0, total: 0, note: '已交给系统下载',
      }, ...ts]);
      message.success(`「${filename}」已交给系统下载`);
      return id;
    }

    // ── 桌面:FSA 零内存 stream(两段式;与原内联版行为一致)──
    const id = genTaskId();
    setTasks(ts => [{
      id, filename, url, startedAt: Date.now(),
      status: 'pending', loaded: 0, total: 0,
    }, ...ts]);
    const handle = await pickSaveTarget(filename);
    if (!handle) {
      // user cancel(SecurityError 等同样落取消,不阻断)
      patch(id, { status: 'cancelled', error: '用户取消保存' });
      return id;
    }
    await streamToHandle(handle, url, id);
    return id;
  }, [patch, streamToHandle, dlLink, message]);

  const cancel = useCallback((id: string) => {
    setTasks(ts => {
      const t = ts.find(x => x.id === id);
      t?.abort?.();
      return ts;
    });
  }, []);

  const remove = useCallback((id: string) => {
    setTasks(ts => ts.filter(x => x.id !== id));
  }, []);

  return (
    <Ctx.Provider value={{ tasks, start, addPlaceholder, streamToHandle, patchTask: patch, cancel, remove }}>
      {children}
    </Ctx.Provider>
  );
}
