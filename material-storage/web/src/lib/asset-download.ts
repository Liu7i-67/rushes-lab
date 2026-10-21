/**
 * 资产下载共享 helper(livp-download-unpack 定稿 §5.1 / 需求 F12-F15)。
 *
 * 单文件:四处下载入口(表格行 / 卡片 / 预览弹窗 / 右栏面板)统一走 downloadAsset —
 *   livp 默认请求 variant='unpacked'(服务端解包 zip)。tag 缺失也必走:404 是自愈回路
 *   (上传漏派 / 瞬时失败 600s 频控重派)的唯一入口,D6);404 → 回落原始 .livp + 弱承诺提示;
 *   永久失败 tag(download_zip_failed)有值 → 直落原始,不误导「生成中」。
 *   非 livp / forceOriginal → 原始下载,现行为零变化;403 一律上抛,由调用方既有分支处理
 *   (申请弹窗 / 提示),helper 不吞权限错误。
 *
 * 批量(PC 单 zip):postBatchDownloadLink 创建/轮询双职能端点的调用封装与响应类型;
 *   编排(两段式 FSA + 3s 轮询 + 各状态分支处置)在 ProjectDetailPage.handleBulkDownload。
 */
import { http } from '../api/client';
import type { Asset } from '../api/types';

export type DownloadVariant = 'original' | 'unpacked';

/** downloadAsset 的环境依赖(调用方注入:message 来自 App.useApp(),dlLink / downloads
 *  来自 useDownloadLink() / useDownloads()。结构化类型,避免耦合具体 hook 返回类型)。*/
export interface DownloadAssetDeps {
  dlLink: {
    mutateAsync: (vars: string | {
      assetId: string;
      as_attachment?: boolean;
      variant?: DownloadVariant;
    }) => Promise<{ url: string }>;
  };
  downloads: {
    start: (url: string, filename: string, opts?: {
      assetId?: string;
      variant?: DownloadVariant;
    }) => Promise<string>;
  };
  message: {
    info: (content: string) => void;
    warning: (content: string) => void;
    error: (content: string) => void;
  };
}

/** livp 判定(与 AssetPreviewModal detectKind 同口径:扩展名大小写不敏感)。*/
export function isLivpAsset(a: Asset): boolean {
  return a.filename.toLowerCase().endsWith('.livp');
}

// Windows 非法字符 + 控制字符(与后端 zip 内名清洗 §2.3 同一套规则,前端 suggestedName 侧同样适用)
// no-control-regex 豁免:控制字符清洗正是本行目的(文件名带 \x00-\x1f 在 Windows 落盘必错)
// eslint-disable-next-line no-control-regex
const WIN_ILLEGAL_RE = /[<>:"/\\|?*\u0000-\u001F]/g;
// Windows 保留设备名(含带扩展名形态 — 只比对首个点前的 stem)
const WIN_RESERVED_RE = /^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$/i;

/** 基名清洗:非法字符/控制字符 → _,去尾部点/空格,保留名 stem 加 _ 后缀;
 *  清洗后空串回落 asset_{id 前 8 位}(与后端回落口径一致)。中文等非 ASCII 保留。*/
export function sanitizeBasename(name: string, fallbackId = ''): string {
  let base = name.replace(WIN_ILLEGAL_RE, '_').replace(/[. ]+$/, '');
  const dot = base.indexOf('.');
  const stem = dot >= 0 ? base.slice(0, dot) : base;
  if (WIN_RESERVED_RE.test(stem)) base = `${stem}_${base.slice(stem.length)}`;
  if (!base) base = `asset_${fallbackId.slice(0, 8)}`;
  return base;
}

/** axios 错误里的 HTTP 状态码(非 axios 错误 → undefined)。*/
function httpStatus(e: unknown): number | undefined {
  return (e as { response?: { status?: number } } | undefined)?.response?.status;
}

/** 原始下载(livp 回落与非 livp 共用):直连重签不带 variant → 后端默认 original,零变化。*/
async function startOriginal(deps: DownloadAssetDeps, a: Asset): Promise<void> {
  // assetId 供无 FSA 环境的直连路径换 as_attachment 链接(Chromium FSA 路径忽略)
  const link = await deps.dlLink.mutateAsync(a.id);
  await deps.downloads.start(link.url, a.filename, { assetId: a.id });
}

/** 未就绪回落提示 — 文案弱化承诺(反复瞬时失败的资产可能长期不就绪,不承诺「生成中」)。*/
function notifyUnpackedNotReady(deps: DownloadAssetDeps, a: Asset): void {
  deps.message.info(`「${a.filename}」解包版尚未就绪,已下载原始 livp`);
}

/**
 * 单文件下载统一入口(F12)。403 恒上抛(调用方保留申请弹窗/提示分支);
 * 其余非预期错误同样上抛走调用方通用报错。
 */
export async function downloadAsset(
  deps: DownloadAssetDeps,
  a: Asset,
  opts?: { forceOriginal?: boolean },
): Promise<void> {
  // 非 livp / 显式要原始(.livp 次选项)→ 现行为原样
  if (!isLivpAsset(a) || opts?.forceOriginal) {
    await startOriginal(deps, a);
    return;
  }

  // 永久失败 tag 有值(无静态图/超限/解码失败)→ 重派注定同结果,直落原始;
  // 勿把永久失败也报「生成中」误导用户(tags 随 AssetOut.tags 下发)
  const failToken = a.tags?.download_zip_failed;
  if (typeof failToken === 'string' && failToken) {
    deps.message.info(`「${a.filename}」暂不支持解包,已下载原始 livp`);
    await startOriginal(deps, a);
    return;
  }

  // 其余情形(含 tag 缺失)一律请求 unpacked — 自愈回路的唯一入口(定稿 §5.1/D6)
  let link: { url: string };
  try {
    link = await deps.dlLink.mutateAsync({ assetId: a.id, variant: 'unpacked' });
  } catch (e) {
    if (httpStatus(e) === 404) {
      // 未就绪 → 服务端已自愈 enqueue;回落原始 + info
      notifyUnpackedNotReady(deps, a);
      await startOriginal(deps, a);
      return;
    }
    throw e;  // 403 / 其他 → 调用方既有分支
  }

  try {
    // FSA suggestedName = 基名.zip(基名清洗与后端 §2.3 同规则)
    const base = sanitizeBasename(a.filename.slice(0, -'.livp'.length), a.id);
    await deps.downloads.start(link.url, `${base}.zip`, { assetId: a.id, variant: 'unpacked' });
  } catch (e) {
    // 二道防线(§5.1):移动直连重签若报错(首签与重签之间衍生物失效,典型 404)→
    // 兜底原始下载;403 仍上抛走申请链路
    const status = httpStatus(e);
    if (status === 403 || status == null) throw e;
    notifyUnpackedNotReady(deps, a);
    await startOriginal(deps, a);
  }
}

// ─── 批量下载(PC 单 zip,定稿 §6;编排在本文件外,见 ProjectDetailPage)────────

/** POST /api/v1/assets/batch-download-link 响应(三态同形;url/expires_in 仅 ready;
 *  跳过列表只回 id 不回文件名 — 防侧信道,前端用自己已加载的 Asset 名渲染)。*/
export interface BatchDownloadResult {
  status: 'ready' | 'packing' | 'failed';
  /** 确定性缓存 key;轮询附 resume_key = 最近一次响应的 key。*/
  key: string;
  url?: string;
  expires_in?: number;
  filename: string;
  skipped_no_permission: string[];
  skipped_missing_count: number;
  /** 以原始 .livp 兜底入包的数量(packing 首响应按当时 tags 判定,ready 以实际计数为准)。*/
  livp_raw_count: number;
  /** packing 且撞跨用户 per-key 闸时携带(闸剩余 TTL,供提示预计等待)。*/
  retry_after_seconds?: number;
}

export interface BatchDownloadBody {
  asset_ids: string[];
  /** 无 FSA(火狐/移动)直连路径带 true;FSA 主路径不带(disposition 无意义)。*/
  as_attachment?: boolean;
  resume_key?: string;
  /** failed 后手动重试:服务端清失败标记重新入队。*/
  retry?: boolean;
}

/** 创建/轮询双职能端点(定稿 §6.2):首次 POST 全量校验并落作业记录;带 resume_key 的
 *  轮询只做轻校验。429(异 key 锁)/422(>100)/403(全无权限或轮询期回收)/
 *  400(超限/跨桶/全不存在/resume 不符)由调用方分流处置。*/
export async function postBatchDownloadLink(body: BatchDownloadBody): Promise<BatchDownloadResult> {
  return (await http.post<BatchDownloadResult>('/api/v1/assets/batch-download-link', body)).data;
}

// 轮询上限自适应(定稿 §6.4):max(180s, 估算合计 bytes ÷ 20MB/s),封顶 900s。
// 10GB 视频批量的打包时间是主路径而非边缘 — 未加载页资产无 size 时按 50MB/个 保守均值
// 计入估算(调用方负责合计),避免混选场景提前假超时。
export const BULK_POLL_MIN_MS = 180_000;
export const BULK_POLL_MAX_MS = 900_000;
export const BULK_UNLOADED_EST_BYTES = 50 * 1024 * 1024;

export function bulkPollCapMs(totalEstBytes: number): number {
  const estMs = Math.ceil(totalEstBytes / (20 * 1024 * 1024)) * 1000;
  return Math.min(BULK_POLL_MAX_MS, Math.max(BULK_POLL_MIN_MS, estMs));
}

/** 行内下载按钮 loading 判定:dlLink.variables 兼容两种形态 — 原始分支传 string id,
 *  livp unpacked 分支传 { assetId, variant } 对象。*/
export function isLinkPendingFor(
  dlLink: { isPending: boolean; variables?: unknown },
  assetId: string,
): boolean {
  if (!dlLink.isPending) return false;
  const v = dlLink.variables as string | { assetId?: string } | undefined;
  return v === assetId
    || (typeof v === 'object' && v !== null && v.assetId === assetId);
}
