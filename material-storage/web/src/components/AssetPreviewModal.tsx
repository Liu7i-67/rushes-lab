/**
 * AssetPreviewModal — md / txt inline 预览(一期)。
 * 后续二期可加 docx (mammoth) + xlsx (sheetjs)。
 * livp(iOS Live Photo):静态图走缩略图,实况短片走 live-preview-url(可播放)。
 * heic/heif:浏览器(除 Safari)不解码原图,大图预览走服务端转码的缩略图。
 * image kind(非 GIF):渐进缩略图(small→large,useProgressiveThumb),原图仅兜底/显式按钮。
 */
import { App, Button, Modal, Spin, Tooltip } from 'antd';
import { ChevronLeft, ChevronRight, Download, Image as ImageIcon } from 'lucide-react';
import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import type { Asset } from '../api/types';
import { useDownloadLink } from '../api/hooks';
import { http, errorMessage } from '../api/client';
import { useProgressiveThumb, useVideoPoster } from '../hooks/useProgressiveThumb';
import { useDownloads } from '../lib/download-store';
import { downloadAsset } from '../lib/asset-download';
import { useCompactViewport } from '../lib/use-viewports';
import { PreviewHeicImage } from './preview/PreviewHeicImage';
import { PreviewImage } from './preview/PreviewImage';
import { ViewOriginalButton } from './preview/PreviewImageFooter';
import { PreviewLivp } from './preview/PreviewLivp';
import { PreviewPdf } from './preview/PreviewPdf';

interface Props {
  asset: Asset;
  open: boolean;
  onClose: () => void;
  // ── B 包列表导航(全部可选向后兼容:不传 list = 现行为,单 asset 无导航条)──
  /** 页面持有的完整列表(传入后 title 区出现 ‹ n/N › 导航)。*/
  list?: Asset[];
  /** asset 在 list 中的下标;页面实态是 number | null(null = 未开),null/-1 时不渲染导航条。*/
  index?: number | null;
  /** 切张回调(与页面 Drawer 翻页同 state,天然同步)。*/
  onIndexChange?: (i: number) => void;
  /** 缺省 true;false(无下载权)时 footer 下载禁用 + tooltip 指引申请入口。*/
  canDownload?: boolean;
}

type Kind = 'markdown' | 'text' | 'image' | 'pdf' | 'video' | 'livp' | 'heic' | 'unsupported';

const IMAGE_EXT = new Set([
  '.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg', '.bmp', '.avif', '.ico',
]);

const VIDEO_EXT = new Set(['.mp4', '.mov', '.webm', '.m4v']);

function detectKind(a: Asset): Kind {
  const name = a.filename.toLowerCase();
  const ct = (a.content_type || '').toLowerCase();
  // livp 先按扩展名判(iOS Live Photo,zip 容器;content_type 是浏览器猜的 octet-stream)
  if (name.endsWith('.livp')) return 'livp';
  if (name.endsWith('.md') || ct.startsWith('text/markdown')) return 'markdown';
  if (name.endsWith('.txt') || ct === 'text/plain') return 'text';
  if (name.endsWith('.pdf') || ct === 'application/pdf') return 'pdf';
  // HEIC/HEIF 必须先于 image/* 前缀判:否则落入 image kind 走原图 <img>,
  // 而 Windows Chrome/Edge/Firefox 不解码 HEIC(黑图)。此 kind 预览走缩略图。
  // 注意 IMAGE_EXT 白名单刻意不加 .heic/.heif — 那条路同样是原图直塞。
  if (name.endsWith('.heic') || name.endsWith('.heif')
      || ct === 'image/heic' || ct === 'image/heif') return 'heic';
  if (ct.startsWith('image/')) return 'image';
  if (ct.startsWith('video/')) return 'video';
  const dot = name.lastIndexOf('.');
  if (dot >= 0 && IMAGE_EXT.has(name.slice(dot))) return 'image';
  if (dot >= 0 && VIDEO_EXT.has(name.slice(dot))) return 'video';
  // text/* 兜底也按 text 处理(csv/log/json 看着也能用)
  if (ct.startsWith('text/')) return 'text';
  return 'unsupported';
}

// 被 AssetSummaryPanel 等跨组件复用 — 拆独立文件属结构重构且本规则只影响 dev HMR 粒度,豁免
// eslint-disable-next-line react-refresh/only-export-components
export function isPreviewable(a: Asset): boolean {
  return detectKind(a) !== 'unsupported';
}

export function AssetPreviewModal({
  asset, open, onClose, list, index, onIndexChange, canDownload,
}: Props) {
  const { message } = App.useApp();
  // hooks 置顶(compact 判定唯一源,见 use-viewports 模块注释)
  const compact = useCompactViewport();
  const dlLink = useDownloadLink();
  // F14 次选项独立 mutation 实例(P2-6):与主下载共用一个实例时任一点击两按钮同时转圈
  const dlLinkOriginal = useDownloadLink();
  const downloads = useDownloads();
  const [content, setContent] = useState<string | null>(null);
  // livp 实况短片 URL(null = 无/未生成/无权限 — 只显示静态图)
  const [liveUrl, setLiveUrl] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  // 切换重置钉子的 asset.id 比较基准(见下方 effect)
  const prevAssetIdRef = useRef<string | null>(null);
  const kind = detectKind(asset);
  // ── 渐进式缩略图(doc §3.6):image kind(非 GIF 非 heic)small 先行 → onload 后换 large;
  // GIF 刻意维持原图预览(可播动画,carve-out);heic 分支独立不动。
  const isGif = asset.filename.toLowerCase().endsWith('.gif');
  const hasThumbKey = !!asset.tags?.thumbnail_key;
  const progressive = kind === 'image' && !isGif && hasThumbKey;
  const { smallUrl, largeUrl, phase } = useProgressiveThumb({
    assetId: asset.id, enabled: open && progressive,
  });
  // video poster(doc §3.6.7):large 缩略图;无 thumbnail_key 不设 poster,src 仍走原文件
  const posterUrl = useVideoPoster(asset.id, open && kind === 'video' && hasThumbKey);
  // 「查看原图」点击后 POST download-link 换 src(显式出口,审计随之产生;doc §3.6.5)
  const [viewOriginalUrl, setViewOriginalUrl] = useState<string | null>(null);
  // 缩略图 <img> 加载失败(presigned 过期/被撤):记下 asset.id,切张后旧标记自动失效
  const [imgFailedFor, setImgFailedFor] = useState<string | null>(null);
  // 渐进链路失败回落原图(仅渐进 asset 会写入;非渐进回落本就经由 content)
  const [fallbackUrl, setFallbackUrl] = useState<string | null>(null);
  // 「查看原图」独立 mutation 实例(P2-6 同理:loading 与下载按钮互不影响)
  const dlLinkViewOriginal = useDownloadLink();
  // image 渲染 src 优先级:显式查看原图 > 失败回落原图 > 渐进 small/large;
  // 非渐进(GIF/无 key)维持 content(原图)不变
  const imageSrc = progressive ? (viewOriginalUrl ?? fallbackUrl ?? smallUrl) : content;
  // 正在显示原图 → 压缩图提示与「查看原图」按钮都应消失
  const showingOriginal = !!viewOriginalUrl || !!fallbackUrl;
  // 渐进链路失败(fetchQuery 失败或缩略图 <img> onError)→ 回落 download-link 原图
  const needFallback = progressive
    && (phase === 'fallback-needed' || imgFailedFor === asset.id);

  // iOS PDF 降级卡(§3.6)的下载按钮 — 走共享 helper(F12:livp 默认请求解包 zip,
  // 未就绪回落原始 + 提示;非 livp 行为零变化);forceOriginal = 「下载源文件」次选项(F14)。
  // 403 兜底走组件级提示(与三张降级卡同文案)
  const handleDownload = async (forceOriginal = false) => {
    try {
      await downloadAsset(
        // 主/次选项各用各的 mutation 实例 — loading 状态互不影响(P2-6)
        { dlLink: forceOriginal ? dlLinkOriginal : dlLink, downloads, message },
        asset,
        { forceOriginal },
      );
    } catch (e) {
      const err = e as { response?: { status?: number } };
      if (err.response?.status === 403) message.warning('无下载权限,请联系项目管理员');
      else message.error(errorMessage(e, '下载失败'));
    }
  };

  // 「查看原图」(doc §3.6.5):点击才 POST download-link 换 <img src>;403 兜底与
  // handleDownload 同文案;切张后迟到的响应按 prevAssetIdRef 判定丢弃,不串图
  const handleViewOriginal = async () => {
    const targetId = asset.id;
    try {
      const link = await dlLinkViewOriginal.mutateAsync(targetId);
      if (targetId === prevAssetIdRef.current) setViewOriginalUrl(link.url);
    } catch (e) {
      if (targetId !== prevAssetIdRef.current) return;
      const err = e as { response?: { status?: number } };
      if (err.response?.status === 403) message.warning('无下载权限,请联系项目管理员');
      else message.error(errorMessage(e, '预览加载失败'));
    }
  };

  // 关闭即清预览态:有意的 modal 生命周期重置;重排为 render 期重置会改动态,豁免 cascading 警告
  /* eslint-disable react-hooks/set-state-in-effect */
  useLayoutEffect(() => {
    // 切换重置钉子:asset.id 变化(列表导航切张)时也清状态 — 不清的话 livp A
    // 播放实况中切到 C 再切回,残留的 liveUrl 会把 A 的实况串到 C 上(playingLive
    // 随 PreviewLivp 重挂载自清);content 同步清空(loading 态盖住),无视觉问题
    const assetChanged = prevAssetIdRef.current !== asset.id;
    prevAssetIdRef.current = asset.id;
    if (!open || assetChanged) {
      setContent(null); setLiveUrl(null);
      setViewOriginalUrl(null); setFallbackUrl(null); setImgFailedFor(null);
    }
    if (!open) return;
    if (kind === 'unsupported') return;
    let cancelled = false;
    setLoading(true);
    (async () => {
      try {
        if (kind === 'livp') {
          // 静态图走缩略图(组织内可见);实况走 live-preview-url(can_download enforce,
          // 404 = 转码未生成 / 403 = 无下载权 → 均只显示静态图)
          const [thumb, live] = await Promise.allSettled([
            http.get<{ url: string }>(`/api/v1/assets/${asset.id}/thumbnail-url`),
            http.get<{ url: string }>(`/api/v1/assets/${asset.id}/live-preview-url`),
          ]);
          if (thumb.status === 'fulfilled' && !cancelled) setContent(thumb.value.data.url);
          if (live.status === 'fulfilled' && !cancelled) setLiveUrl(live.value.data.url);
          return;
        }
        if (kind === 'heic') {
          // 浏览器不解码 HEIC 原图:大图预览走服务端 pillow-heif 转码的 JPEG 缩略图
          // (≤1024px,与列表缩略图同源)。404 = 还没生成/派发未命中 → content 保持
          // null,下方渲染「生成中/失败」卡(与 livp 同口径)
          try {
            const { data } = await http.get<{ url: string }>(
              `/api/v1/assets/${asset.id}/thumbnail-url`,
            );
            if (!cancelled) setContent(data.url);
          } catch {
            // 404 落到卡片分支
          }
          return;
        }
        // image 渐进路径(doc §3.6.1):缩略图 URL 由 useProgressiveThumb 拉取,此处不发
        // download-link — 打开预览不再必拉原图,审计只在「查看原图」/失败回落时产生
        if (progressive) return;
        const { data } = await http.post<{ url: string }>(
          `/api/v1/assets/${asset.id}/download-link`, {},
        );
        // image / pdf / video 不 fetch body,直接给浏览器原生 viewer
        // (video 走浏览器原生 Range request,MinIO presign 支持;走 nginx 默认透传不剥 Range)
        // text/md 拉文本
        if (kind === 'image' || kind === 'pdf' || kind === 'video') {
          if (!cancelled) setContent(data.url);
        } else {
          const r = await fetch(data.url);
          if (!r.ok) throw new Error(`fetch ${r.status}`);
          const text = await r.text();
          if (!cancelled) setContent(text);
        }
      } catch (e) {
        if (!cancelled) message.error(errorMessage(e, '预览加载失败'));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, [open, asset.id, kind, progressive, message]);
  /* eslint-enable react-hooks/set-state-in-effect */

  // 渐进链路失败回落(doc §3.6.2):small/large fetchQuery 失败(phase)或缩略图 <img>
  // onError → 沿用主 effect 的 download-link 调用路径拉原图兜底(fallbackUrl 切张即清)
  useEffect(() => {
    if (!open || !needFallback || fallbackUrl !== null) return;
    let cancelled = false;
    (async () => {
      try {
        const { data } = await http.post<{ url: string }>(
          `/api/v1/assets/${asset.id}/download-link`, {},
        );
        if (!cancelled) setFallbackUrl(data.url);
      } catch (e) {
        if (!cancelled) message.error(errorMessage(e, '预览加载失败'));
      }
    })();
    return () => { cancelled = true; };
  }, [open, needFallback, fallbackUrl, asset.id, message]);

  // 键盘导航(B6):预览打开且列表 >1 时 ←/→ 切张(边界即停,与导航条禁用同语义)。
  // livp 播放态 video 有自己的键位,e.target 是 video 时忽略;Esc 维持 antd Modal 自带
  useEffect(() => {
    if (!open || !onIndexChange || !list || list.length <= 1 || index == null) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.target instanceof HTMLVideoElement) return;
      if (e.key === 'ArrowLeft' && index > 0) onIndexChange(index - 1);
      if (e.key === 'ArrowRight' && index < list.length - 1) onIndexChange(index + 1);
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [open, list, onIndexChange, index]);

  // 导航条(B2):title 区 ‹ n/N › + 文件名省略,样式对齐 Folder/ProjectDetailPage
  // Drawer 标题既有写法;不传 list 或 index 为 null/-1 = 单文件模式,不渲染
  let title: React.ReactNode = asset.filename;
  if (list && list.length > 0 && onIndexChange && index != null && index >= 0) {
    title = (
      <div style={{ display: 'flex', alignItems: 'center', gap: 4, minWidth: 0 }}>
        <Button type="text" size="small" aria-label="上一个"
                icon={<ChevronLeft size={16} strokeWidth={1.8} />}
                disabled={index <= 0}
                onClick={() => onIndexChange(index - 1)} />
        <span className="ms-mono" style={{
          fontSize: 12.5, color: 'var(--ms-ink-muted)', flexShrink: 0,
        }}>{index + 1} / {list.length}</span>
        <Button type="text" size="small" aria-label="下一个"
                icon={<ChevronRight size={16} strokeWidth={1.8} />}
                disabled={index >= list.length - 1}
                onClick={() => onIndexChange(index + 1)} />
        <span style={{
          flex: 1, minWidth: 0, marginLeft: 6, fontSize: 13,
          color: 'var(--ms-ink-muted)',
          overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
        }}>{asset.filename}</span>
      </div>
    );
  }

  // footer 常驻下载(B5):所有 kind(含 unsupported 卡)可见;403 兜底走组件级
  // handleDownload(与三张降级卡同文案);无下载权时禁用 + tooltip 指引申请入口
  // —— antd disabled Button 不触发 hover,Tooltip 须包住 Button(同 ProjectDetailPage
  // 批量删除既有写法)
  const downloadButton = (
    <Button size={compact ? 'large' : 'middle'}
            icon={<Download size={15} strokeWidth={1.8} />}
            disabled={canDownload === false}
            loading={dlLink.isPending}
            onClick={() => void handleDownload()}>
      下载
    </Button>
  );

  // F14:livp 专属次选项 — 默认下载已是解包 zip,需要回传 iPhone 的用户才拿原始 .livp
  // loading 用次选项自己的实例(P2-6):与主下载互不影响
  const originalLivpButton = kind === 'livp' && (
    <Button size={compact ? 'large' : 'middle'} type="text"
            icon={<Download size={15} strokeWidth={1.8} />}
            disabled={canDownload === false}
            loading={dlLinkOriginal.isPending}
            onClick={() => void handleDownload(true)}>
      下载源文件
    </Button>
  );

  // 「查看原图」(doc §3.6.5):仅非 GIF image kind 且有 thumbnail_key 时显示;
  // 已显示原图(点击后/失败回落)则无意义 → 隐藏;无下载权禁用(403 与下载按钮同语义)
  const viewOriginalButton = progressive && !showingOriginal && (
    <ViewOriginalButton
      compact={compact}
      disabled={canDownload === false}
      loading={dlLinkViewOriginal.isPending}
      onClick={() => void handleViewOriginal()}
    />
  );

  return (
    <Modal
      open={open}
      onCancel={onClose}
      footer={
        <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8 }}>
          {originalLivpButton}
          {viewOriginalButton}
          {canDownload === false ? (
            <Tooltip title="无下载权限,可在文件面板点『申请下载』">{downloadButton}</Tooltip>
          ) : downloadButton}
        </div>
      }
      title={title}
      width="min(960px, 92vw)"
      styles={{ body: { maxHeight: 'min(72vh, 72dvh)', overflow: 'auto', padding: 24 } }}
      destroyOnClose
    >
      {loading && (
        <div style={{ padding: 60, textAlign: 'center' }}>
          <Spin />
        </div>
      )}
      {!loading && kind === 'unsupported' && (
        <div style={{
          padding: 40, textAlign: 'center',
          color: 'var(--ms-ink-muted)', fontSize: 13, lineHeight: 1.7,
        }}>
          此文件类型暂不支持在线预览。<br/>
          请下载后用本地软件打开。
        </div>
      )}
      {!loading && kind === 'text' && content !== null && (
        <pre style={{
          margin: 0, padding: 16,
          background: 'var(--ms-hairline-soft)',
          borderRadius: 'var(--ms-radius-sm)',
          fontSize: 12.5, lineHeight: 1.7,
          fontFamily: 'var(--ms-font-mono)',
          color: 'var(--ms-ink)',
          whiteSpace: 'pre-wrap', wordBreak: 'break-word',
        }}>{content}</pre>
      )}
      {!loading && kind === 'markdown' && content !== null && (
        <div className="ms-md-preview" style={{
          fontSize: 14, lineHeight: 1.75, color: 'var(--ms-ink)',
        }}>
          <ReactMarkdown remarkPlugins={[remarkGfm]}>{content}</ReactMarkdown>
        </div>
      )}
      {!loading && kind === 'image' && imageSrc && (
        <PreviewImage
          key={asset.id}
          asset={asset}
          src={imageSrc}
          largeUrl={progressive && !showingOriginal ? largeUrl : null}
          showHint={progressive && !showingOriginal}
          onImgError={progressive && !showingOriginal ? () => {
            // 缩略图 URL 加载失败(presigned 过期/被撤)→ 回落原图兜底;已显原图不触发
            if (imgFailedFor !== asset.id) setImgFailedFor(asset.id);
          } : undefined}
        />
      )}
      {!loading && kind === 'image' && progressive && !imageSrc && (
        // 渐进缩略图 URL 拉取中 / 失败回落请求中(缓存命中时瞬通;失败有 toast 提示)
        <div style={{ padding: 60, textAlign: 'center' }}>
          <Spin />
        </div>
      )}
      {!loading && kind === 'heic' && content !== null && (
        <PreviewHeicImage asset={asset} url={content} />
      )}
      {!loading && kind === 'pdf' && content !== null && (
        <PreviewPdf asset={asset} content={content} compact={compact}
                    downloadPending={dlLink.isPending}
                    onDownload={() => void handleDownload()} />
      )}
      {!loading && kind === 'video' && content !== null && (
        <div style={{
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          background: '#000',
          borderRadius: 'var(--ms-radius-sm)',
        }}>
          <video
            controls
            src={content}
            poster={posterUrl ?? undefined}
            style={{
              width: '100%', maxHeight: 'min(68vh, 68dvh)',
              display: 'block', borderRadius: 'var(--ms-radius-sm)',
            }}
          />
        </div>
      )}
      {!loading && kind === 'heic' && content === null && (
        asset.tags?.thumbnail_failed ? (
          // 与 livp 失败卡同款:缩略图明确失败 → 给下载出口,不再误导「稍后重试」
          <div style={{
            padding: 32, textAlign: 'center',
            border: '1px dashed var(--ms-hairline)',
            borderRadius: 'var(--ms-radius-sm)',
            background: 'var(--ms-hairline-soft)',
          }}>
            <ImageIcon size={28} strokeWidth={1.5}
                       style={{ color: 'var(--ms-ink-subtle)', marginBottom: 12 }} />
            <div style={{
              fontSize: 13, color: 'var(--ms-ink-muted)', lineHeight: 1.7,
              marginBottom: 16,
            }}>
              预览图生成失败(原因标记:{asset.tags.thumbnail_failed}),<br />
              可下载原片查看,恢复请联系管理员。
            </div>
            <Button type="primary" size={compact ? 'large' : 'middle'}
                    icon={<Download size={15} strokeWidth={1.8} />}
                    loading={dlLink.isPending}
                    onClick={() => void handleDownload()}>
              下载原片
            </Button>
          </div>
        ) : (
          <div style={{
            padding: 40, textAlign: 'center',
            color: 'var(--ms-ink-muted)', fontSize: 13, lineHeight: 1.7,
          }}>
            HEIC 预览图还在生成(或生成失败),请稍后刷新重试。<br/>
            也可直接下载原片查看。
          </div>
        )
      )}
      {!loading && kind === 'livp' && content === null && (
        asset.tags?.thumbnail_failed ? (
          // 缩略图已明确失败(fail 标记随 AssetOut.tags 下发,见 workers/main.py 失败路径)
          // → 显示失败卡,不再误导「稍后刷新重试」(W1-B);样式对齐 iOS PDF 降级卡
          <div style={{
            padding: 32, textAlign: 'center',
            border: '1px dashed var(--ms-hairline)',
            borderRadius: 'var(--ms-radius-sm)',
            background: 'var(--ms-hairline-soft)',
          }}>
            <ImageIcon size={28} strokeWidth={1.5}
                       style={{ color: 'var(--ms-ink-subtle)', marginBottom: 12 }} />
            <div style={{
              fontSize: 13, color: 'var(--ms-ink-muted)', lineHeight: 1.7,
              marginBottom: 16,
            }}>
              预览生成失败(原因标记:{asset.tags.thumbnail_failed}),<br />
              可下载原片查看,恢复请联系管理员。
            </div>
            <Button type="primary" size={compact ? 'large' : 'middle'}
                    icon={<Download size={15} strokeWidth={1.8} />}
                    loading={dlLink.isPending}
                    onClick={() => void handleDownload()}>
              下载原片
            </Button>
          </div>
        ) : (
          <div style={{
            padding: 40, textAlign: 'center',
            color: 'var(--ms-ink-muted)', fontSize: 13, lineHeight: 1.7,
          }}>
            实况照片预览还在生成(或生成失败),请稍后刷新重试。<br/>
            也可直接下载原片查看。
          </div>
        )
      )}
      {!loading && kind === 'livp' && content !== null && (
        <PreviewLivp key={asset.id} asset={asset} thumbUrl={content}
                     liveUrl={liveUrl} compact={compact} />
      )}
    </Modal>
  );
}
