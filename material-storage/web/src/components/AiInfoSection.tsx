/**
 * AiInfoSection — 素材详情面板「AI 识别」独立区(ai-tagging-slicing §12/P1)。
 * 呈现 = 上下文行 + 中文标签 chips + 描述 + 元信息(tier/模型版本/更新时间),
 * 与人工标签区视觉隔离(上沿 hairline 分隔 + 弱化配色)。
 * 「采纳为人工标签」→ 既有 PATCH /assets/{id}/meta labels_mode=merge(不新增写路径;
 * can_upload 闸,无权限用户不渲染按钮,后端 403 兜底)。
 * 取数走 api/ai.ts useAssetAi(404/网络错误 client 层静默),任何失败只落空态,
 * 不影响面板其余分区。
 */
import { App, Button, Tag } from 'antd';
import { Sparkles } from 'lucide-react';
import { errorMessage } from '../api/client';
import { useAssetAi } from '../api/ai';
import { useUpdateAssetMeta } from '../api/hooks';
import type { Asset, AssetAiAnnotation } from '../api/types';
import { SectionLabel } from './SectionLabel';

/** coarse/refined 的中文显示;未知值原样回显。*/
function tierLabel(tier: string): string {
  if (tier === 'coarse') return '粗标';
  if (tier === 'refined') return '精标';
  return tier || '—';
}

interface Props {
  asset: Asset;
  /** 面板既有权限判定(folder.my_can_upload,与后端 PATCH meta 的 can_upload 闸同口径)。*/
  canEdit: boolean;
}

export function AiInfoSection({ asset, canEdit }: Props) {
  const { message } = App.useApp();
  const { data, isPending } = useAssetAi(asset.id);
  const meta = useUpdateAssetMeta();

  // 首取中不渲染(避免闪「暂无」;缓存命中时瞬通)。isPending = 无数据且取数中
  if (isPending) return null;

  const annotation: AssetAiAnnotation | null = data?.annotation ?? null;
  // 逐字段兜空(后端并行开发中,契约字段可能缺失;render 半边 try 边界)
  const tagsZh = annotation && Array.isArray(annotation.tags_zh) ? annotation.tags_zh : [];
  const tagsEn = annotation && Array.isArray(annotation.tags_en) ? annotation.tags_en : [];
  const partial = annotation?.meta?.partial === true;
  // 描述优先中文(P2 精标直出);仅英文时灰色斜体呈现(P1 常态,方案 §9)
  const descZh = (annotation?.description ?? '').trim();
  const descEn = (annotation?.description_en ?? '').trim();

  const adopt = async () => {
    if (tagsZh.length === 0) return;
    try {
      await meta.mutateAsync({
        asset_id: asset.id,
        user_labels: tagsZh,
        labels_mode: 'merge',
      });
      message.success(`已采纳 ${tagsZh.length} 个 AI 标签到人工标签`);
    } catch (e) {
      message.error(errorMessage(e, 'AI 标签采纳失败'));
    }
  };

  return (
    <div style={{
      padding: '14px 20px',
      borderTop: '1px solid var(--ms-hairline-soft)',
    }}>
      <SectionLabel>AI 识别</SectionLabel>
      {!annotation ? (
        // 404(AI 未启用/无数据)或 annotation 为空 —— 静默空态,不给红色报错
        <div style={{ fontSize: 12.5, color: 'var(--ms-ink-subtle)' }}>
          暂无 AI 识别结果
        </div>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          {/* 上下文行:项目/目录链/文件名快照(结构化事实,置顶展示 —— 方案 §9)*/}
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, minWidth: 0 }}>
            <span style={{
              flexShrink: 0, fontSize: 11, color: 'var(--ms-ink-subtle)',
            }}>上下文</span>
            <span className="ms-mono" style={{
              flex: 1, minWidth: 0, fontSize: 11.5, color: 'var(--ms-ink-muted)',
              wordBreak: 'break-all', lineHeight: 1.5,
            }}>{annotation.context_path}</span>
          </div>

          {/* 中文标签 chips(+ meta.partial 降级标记)*/}
          {(tagsZh.length > 0 || partial) && (
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, alignItems: 'center' }}>
              {tagsZh.map((t, i) => (
                <Tag key={`${t}-${i}`}
                     style={{ marginInlineEnd: 0, fontSize: 11, lineHeight: '18px' }}>
                  {t}
                </Tag>
              ))}
              {partial && <Tag color="warning" style={{ marginInlineEnd: 0, fontSize: 11 }}>部分识别</Tag>}
            </div>
          )}
          {tagsZh.length === 0 && !partial && tagsEn.length > 0 && (
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
              {tagsEn.slice(0, 8).map((t, i) => (
                <Tag key={`${t}-${i}`}
                     style={{ marginInlineEnd: 0, fontSize: 11, lineHeight: '18px', color: 'var(--ms-ink-muted)' }}>
                  {t}
                </Tag>
              ))}
            </div>
          )}

          {/* 描述:中文优先;仅有英文描述时灰色斜体(P1 形态)*/}
          {(descZh || descEn) && (
            <div style={{
              fontSize: 12.5, lineHeight: 1.6,
              ...(descZh
                ? { color: 'var(--ms-ink)' }
                : { color: 'var(--ms-ink-muted)', fontStyle: 'italic' }),
              wordBreak: 'break-word',
            }}>
              {descZh || descEn}
            </div>
          )}

          {/* 元信息行:tier · 模型版本 · 更新时间(弱化 mono)*/}
          <div className="ms-mono" style={{
            fontSize: 10.5, color: 'var(--ms-ink-subtle)', lineHeight: 1.5,
          }}>
            {tierLabel(annotation.tier)}
            <span style={{ margin: '0 6px', opacity: 0.4 }}>·</span>
            {annotation.model_version}
            <span style={{ margin: '0 6px', opacity: 0.4 }}>·</span>
            {new Date(annotation.updated_at).toLocaleString('zh-CN')}
          </div>

          {/* 采纳为人工标签:can_upload 闸(无权限不渲染,后端 403 兜底);merge 不覆盖既有标签 */}
          {canEdit && tagsZh.length > 0 && (
            <div>
              <Button size="small" loading={meta.isPending}
                      icon={<Sparkles size={12} strokeWidth={1.8} />}
                      onClick={() => void adopt()}>
                采纳为人工标签
              </Button>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
