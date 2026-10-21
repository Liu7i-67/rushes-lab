/**
 * AssetPreviewModal — md / txt inline 预览(一期)。
 * 后续二期可加 docx (mammoth) + xlsx (sheetjs)。
 * livp(iOS Live Photo):静态图走缩略图,实况短片走 live-preview-url(可播放)。
 * heic/heif:浏览器(除 Safari)不解码原图,大图预览走服务端转码的缩略图。
 */
import { App, Button, Modal, Spin, Tooltip } from 'antd';
import { ChevronLeft, ChevronRight, Download, FileText, Image as ImageIcon, Play } from 'lucide-react';
import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import type { Asset } from '../api/types';
import { useDownloadLink } from '../api/hooks';
import { http, errorMessage } from '../api/client';
import { useDownloads } from '../lib/download-store';
import { downloadAsset } from '../lib/asset-download';
import { useCompactViewport } from '../lib/use-viewports';
import { isIOS } from '../lib/ua';

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
  const [playingLive, setPlayingLive] = useState(false);
  const [loading, setLoading] = useState(false);
  // 切换重置钉子的 asset.id 比较基准(见下方 effect)
  const prevAssetIdRef = useRef<string | null>(null);
  const kind = detectKind(asset);

  // iOS PDF 降级卡(§3.6)的下载按钮 — 走共享 helper(F12:livp 默认请求解包 zip,
  // 未就绪回落原始 + 提示;非 livp 行为零变化);forceOriginal = 「下载原始 .livp」次选项(F14)。
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

  // 关闭即清预览态:有意的 modal 生命周期重置;重排为 render 期重置会改动态,豁免 cascading 警告
  /* eslint-disable react-hooks/set-state-in-effect */
  useLayoutEffect(() => {
    // 切换重置钉子:asset.id 变化(列表导航切张)时也清三态 — 不清的话 livp A
    // 播放实况中切到 C 再切回,残留的 playingLive/liveUrl 会把 A 的实况串到 C 上;
    // content 同步清空(loading 态盖住,新请求立即覆盖),无视觉问题
    const assetChanged = prevAssetIdRef.current !== asset.id;
    prevAssetIdRef.current = asset.id;
    if (!open || assetChanged) {
      setContent(null); setLiveUrl(null); setPlayingLive(false);
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
  }, [open, asset.id, kind, message]);
  /* eslint-enable react-hooks/set-state-in-effect */

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
      下载原始 .livp
    </Button>
  );

  return (
    <Modal
      open={open}
      onCancel={onClose}
      footer={
        <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8 }}>
          {originalLivpButton}
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
      {!loading && (kind === 'image' || kind === 'heic') && content !== null && (
        <div>
          <div style={{
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            background: 'var(--ms-hairline-soft)',
            borderRadius: 'var(--ms-radius-sm)',
            minHeight: 200,
          }}>
            <img src={content} alt={asset.filename} style={{
              maxWidth: '100%', maxHeight: 'min(65vh, 65dvh)',
              objectFit: 'contain', display: 'block',
            }} />
          </div>
          {kind === 'heic' && (
            <div style={{
              textAlign: 'center', marginTop: 8,
              fontSize: 12, color: 'var(--ms-ink-subtle)',
            }}>
              HEIC 预览为服务端压缩图(≤1024px),下载可获取原片。
            </div>
          )}
        </div>
      )}
      {!loading && kind === 'pdf' && content !== null && isIOS() && (
        // iOS 内嵌 PDF 受限(Safari 不支持 iframe 内嵌 PDF 交互),降级为提示卡(§3.6)
        <div style={{
          padding: 32, textAlign: 'center',
          border: '1px dashed var(--ms-hairline)',
          borderRadius: 'var(--ms-radius-sm)',
          background: 'var(--ms-hairline-soft)',
        }}>
          <FileText size={28} strokeWidth={1.5}
                    style={{ color: 'var(--ms-ink-subtle)', marginBottom: 12 }} />
          <div style={{
            fontSize: 13, color: 'var(--ms-ink-muted)', lineHeight: 1.7,
            marginBottom: 16,
          }}>
            iOS 内嵌预览受限,<br />点击下载后用系统预览打开。
          </div>
          <Button type="primary" size={compact ? 'large' : 'middle'}
                  icon={<Download size={15} strokeWidth={1.8} />}
                  loading={dlLink.isPending}
                  onClick={() => void handleDownload()}>
            下载 PDF
          </Button>
        </div>
      )}
      {!loading && kind === 'pdf' && content !== null && !isIOS() && (
        <iframe
          src={content}
          title={asset.filename}
          style={{
            width: '100%', height: 'min(68vh, 68dvh)',
            border: '1px solid var(--ms-hairline)',
            borderRadius: 'var(--ms-radius-sm)',
            background: 'var(--ms-hairline-soft)',
          }}
        />
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
        <div>
          <div style={{
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            background: '#000',
            borderRadius: 'var(--ms-radius-sm)',
            minHeight: 200,
          }}>
            {playingLive && liveUrl ? (
              <video
                autoPlay loop muted playsInline
                src={liveUrl}
                style={{
                  width: '100%', maxHeight: 'min(65vh, 65dvh)',
                  display: 'block', borderRadius: 'var(--ms-radius-sm)',
                }}
              />
            ) : (
              <img src={content} alt={asset.filename} style={{
                maxWidth: '100%', maxHeight: 'min(65vh, 65dvh)',
                objectFit: 'contain', display: 'block',
              }} />
            )}
          </div>
          {liveUrl && (
            <div style={{ textAlign: 'center', marginTop: 12 }}>
              <Button
                size={compact ? 'middle' : 'small'}
                icon={playingLive ? <ImageIcon size={13} strokeWidth={1.8} /> : <Play size={13} strokeWidth={1.8} />}
                onClick={() => setPlayingLive(v => !v)}
              >
                {playingLive ? '查看照片' : '播放实况'}
              </Button>
            </div>
          )}
          <div style={{
            textAlign: 'center', marginTop: 8,
            fontSize: 12, color: 'var(--ms-ink-subtle)',
          }}>
            Live Photo(实况照片)= 静态图 + 短视频;此处为压缩预览,下载可获取原片。
          </div>
        </div>
      )}
    </Modal>
  );
}
