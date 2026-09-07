/**
 * 全局上传 store — uppy 实例提升到 App 顶层。
 * - per folderId 一个 uppy(切 folder 各自独立)
 * - 关 drawer 只 hide UI,uppy 在后台继续上传
 * - dynamic import uppy(保持 code splitting,首屏不加载 uppy chunk)
 */
import { useQueryClient } from '@tanstack/react-query';
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from 'react';
import { apiBase, http } from '../api/client';

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type UppyAny = any;

export interface UploadStats {
  total: number;    // 全部文件数
  success: number;  // uploadComplete
  failed: number;   // error 非空
  inflight: number; // 未完成且无 error(排队 + 上传中)
  loaded: number;   // bytesUploaded 之和
  bytesTotal: number; // 各文件 size 之和
}

// eslint-disable-next-line react-refresh/only-export-components
export function computeUploadStats(files: UppyAny[]): UploadStats {
  const stats: UploadStats = { total: 0, success: 0, failed: 0, inflight: 0, loaded: 0, bytesTotal: 0 };
  for (const f of files) {
    stats.total++;
    // else-if 链保证三数互斥且合计 = total;error 优先(失败不应再计成功)
    if (f.error) stats.failed++;
    else if (f.progress?.uploadComplete) stats.success++;
    else stats.inflight++;
    stats.loaded += f.progress?.bytesUploaded ?? 0;
    stats.bytesTotal += f.size ?? 0;
  }
  return stats;
}

interface UploadCtx {
  activeFolderId: string | null;
  open: (folderId: string) => Promise<void>;
  close: () => void;
  getUppy: (folderId: string) => UppyAny | undefined;
  getAllUppies: () => Map<string, UppyAny>;
  // tick — UI 用来重渲染 floating indicator
  version: number;
}

const Ctx = createContext<UploadCtx | null>(null);

// eslint-disable-next-line react-refresh/only-export-components
export function useUpload() {
  const v = useContext(Ctx);
  if (!v) throw new Error('useUpload 必须在 UploadProvider 内');
  return v;
}

export function UploadProvider({ children }: { children: ReactNode }) {
  const [activeFolderId, setActiveFolderId] = useState<string | null>(null);
  const uppies = useRef<Map<string, UppyAny>>(new Map());
  // per-folder 列表刷新 debounce timer
  const refreshTimers = useRef<Map<string, ReturnType<typeof setTimeout>>>(new Map());
  const [version, setVersion] = useState(0);
  const qc = useQueryClient();

  const buildUppy = useCallback(async (folderId: string): Promise<UppyAny> => {
    const [{ default: Uppy }, { default: AwsS3 }, locale] = await Promise.all([
      import('@uppy/core'),
      import('@uppy/aws-s3'),
      import('@uppy/locales/lib/zh_CN').then(m => m.default),
    ]);

    const u: UppyAny = new Uppy({
      locale,
      restrictions: { maxNumberOfFiles: 10000, maxFileSize: 5 * 1024 * 1024 * 1024 },
      autoProceed: false,
    }).use(AwsS3, {
      shouldUseMultipart: true,
      getChunkSize: () => 16 * 1024 * 1024,
      listParts: async () => [],

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      createMultipartUpload: async (file: any) => {
        const { data } = await http.post<{ upload_id: string; key: string; bucket: string }>(
          '/api/v1/assets/uploads',
          {
            folder_id: folderId,
            filename: file.name,
            content_type: file.type || 'application/octet-stream',
            size_bytes: file.size ?? 0,
          });
        u.setFileMeta(file.id, { bucket: data.bucket });
        return { uploadId: data.upload_id, key: data.key };
      },

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      signPart: async (file: any, opts: any) => {
        const bucket = file.meta?.bucket ?? 'ms-dev';
        const url = `${apiBase}/api/v1/assets/uploads/${opts.uploadId}/parts/${opts.partNumber}` +
          `?bucket=${encodeURIComponent(bucket)}&key=${encodeURIComponent(opts.key)}`;
        const { data } = await http.get<{ url: string }>(url);
        return { url: data.url, headers: {} };
      },

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      completeMultipartUpload: async (file: any, opts: any) => {
        const bucket = file.meta?.bucket ?? 'ms-dev';
        await http.post(`/api/v1/assets/uploads/${opts.uploadId}/complete`, {
          upload_id: opts.uploadId,
          bucket, key: opts.key, parts: opts.parts,
        });
        return { location: `s3://${bucket}/${opts.key}` };
      },

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      abortMultipartUpload: async (file: any, opts: any) => {
        const bucket = file.meta?.bucket ?? 'ms-dev';
        await http.delete(`/api/v1/assets/uploads/${opts.uploadId}`, {
          params: { bucket, key: opts.key },
        });
      },
    });

    // 列表刷新走 per-folder 2s trailing debounce,大批量时避免每个文件成功都打一次接口
    u.on('upload-success', () => {
      const prev = refreshTimers.current.get(folderId);
      if (prev) clearTimeout(prev);
      refreshTimers.current.set(folderId, setTimeout(() => {
        refreshTimers.current.delete(folderId);
        qc.invalidateQueries({ queryKey: ['assets', folderId] });
      }, 2000));
      setVersion(v => v + 1);
    });
    u.on('upload-error', () => setVersion(v => v + 1));
    u.on('progress', () => setVersion(v => v + 1));
    u.on('file-added', () => setVersion(v => v + 1));
    u.on('file-removed', () => setVersion(v => v + 1));
    u.on('upload-retry', () => setVersion(v => v + 1));
    // 批次结束立即 flush debounce 并刷列表
    u.on('complete', () => {
      const t = refreshTimers.current.get(folderId);
      if (t) clearTimeout(t);
      refreshTimers.current.delete(folderId);
      qc.invalidateQueries({ queryKey: ['assets', folderId] });
      setVersion(v => v + 1);
    });

    return u;
  }, [qc]);

  const open = useCallback(async (folderId: string) => {
    if (!uppies.current.has(folderId)) {
      const u = await buildUppy(folderId);
      uppies.current.set(folderId, u);
    }
    setActiveFolderId(folderId);
  }, [buildUppy]);

  const close = useCallback(() => setActiveFolderId(null), []);
  const getUppy = useCallback((folderId: string) => uppies.current.get(folderId), []);
  const getAllUppies = useCallback(() => uppies.current, []);

  // 有在上传/排队的文件时拦截页面关闭防误关(失败文件已停止推进,不算 in-flight)
  useEffect(() => {
    const hasInflight = () => {
      for (const u of uppies.current.values()) {
        for (const f of u.getFiles()) {
          if (!f.progress?.uploadComplete && !f.error) return true;
        }
      }
      return false;
    };
    const onBeforeUnload = (e: BeforeUnloadEvent) => {
      e.preventDefault();
      e.returnValue = '';
    };
    if (hasInflight()) window.addEventListener('beforeunload', onBeforeUnload);
    return () => window.removeEventListener('beforeunload', onBeforeUnload);
  }, [version]);

  // 卸载时清空所有列表刷新 timer
  useEffect(() => {
    const timers = refreshTimers.current;
    return () => {
      for (const t of timers.values()) clearTimeout(t);
      timers.clear();
    };
  }, []);

  return (
    <Ctx.Provider value={{ activeFolderId, open, close, getUppy, getAllUppies, version }}>
      {children}
    </Ctx.Provider>
  );
}
