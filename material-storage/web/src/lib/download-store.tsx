/**
 * 下载任务 store —
 *   桌面(有 File System Access API):stream 直写本地文件,零内存 + 进度 + 可取消。
 *   移动端(无 showSaveFilePicker,方案 §3.5):请求 as_attachment=true 链接后
 *   `<a target=_blank>` 直连系统下载器,登记一条立即完成的任务记录 + toast。
 *   原 fetch→Blob 全量内存路径已删除(GB 级原片把移动 Safari 顶爆的元凶);
 *   直连路径无 blob,blobUrl 字段与清理逻辑一并移除。
 */
import { createContext, useCallback, useContext, useState, type ReactNode } from 'react';
import { App } from 'antd';
import { useDownloadLink } from '../api/hooks';

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
  start: (url: string, filename: string, opts?: { assetId?: string }) => Promise<string>;  // 返 task id
  cancel: (id: string) => void;
  remove: (id: string) => void;
}

const Ctx = createContext<DownloadCtx | null>(null);

export function useDownloads() {
  const v = useContext(Ctx);
  if (!v) throw new Error('useDownloads 必须在 DownloadProvider 内');
  return v;
}

// File System Access API 检测(有 = 桌面;无 = 移动端直连路径)
function hasFSA(): boolean {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return typeof (window as any).showSaveFilePicker === 'function';
}

export function DownloadProvider({ children }: { children: ReactNode }) {
  const [tasks, setTasks] = useState<DownloadTask[]>([]);
  const { message } = App.useApp();
  const dlLink = useDownloadLink();

  const patch = useCallback((id: string, p: Partial<DownloadTask>) => {
    setTasks(ts => ts.map(t => t.id === id ? { ...t, ...p } : t));
  }, []);

  const start = useCallback(async (
    url: string, filename: string, opts?: { assetId?: string },
  ): Promise<string> => {
    // ── 移动端直连(§3.5):attachment 链接 → 系统下载器,无 JS 内存占用 ──
    if (!hasFSA()) {
      const id = `dl-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
      let linkUrl = url;
      if (opts?.assetId) {
        // 403 在此抛出,沿用调用方既有 catch → 申请弹窗链路(与 PC 同)
        const link = await dlLink.mutateAsync({ assetId: opts.assetId, as_attachment: true });
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

    // ── 桌面:FSA 零内存 stream(原逻辑;fetch→Blob fallback 已删)──
    const id = `dl-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    const ctrl = new AbortController();
    const task: DownloadTask = {
      id, filename, url, startedAt: Date.now(),
      status: 'pending', loaded: 0, total: 0,
      abort: () => ctrl.abort(),
    };
    setTasks(ts => [task, ...ts]);

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let fileHandle: any;
    try {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      fileHandle = await (window as any).showSaveFilePicker({ suggestedName: filename });
    } catch {
      // user cancel
      patch(id, { status: 'cancelled', error: '用户取消保存' });
      return id;
    }

    try {
      patch(id, { status: 'running' });
      const res = await fetch(url, { signal: ctrl.signal });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const total = parseInt(res.headers.get('content-length') ?? '0', 10);
      patch(id, { total });

      const reader = res.body!.getReader();
      let loaded = 0;
      let lastTick = Date.now();
      let lastLoaded = 0;

      const writable = await fileHandle.createWritable();

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        await writable.write(value);
        loaded += value.length;

        const now = Date.now();
        if (now - lastTick > 500) {
          const speedBps = ((loaded - lastLoaded) * 1000) / (now - lastTick);
          patch(id, { loaded, speedBps });
          lastTick = now; lastLoaded = loaded;
        }
      }
      patch(id, { loaded });

      await writable.close();
      patch(id, { status: 'success' });
    } catch (e) {
      const err = e as { name?: string; message?: string };
      if (err.name === 'AbortError') patch(id, { status: 'cancelled', error: '已取消' });
      else patch(id, { status: 'failed', error: err.message ?? String(e) });
    }

    return id;
  }, [patch, dlLink, message]);

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

  return <Ctx.Provider value={{ tasks, start, cancel, remove }}>{children}</Ctx.Provider>;
}
