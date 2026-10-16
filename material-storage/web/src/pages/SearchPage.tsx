/**
 * #151 盲搜结果页 — /search?q=…
 * 后端已按 can_view 过滤(敏感素材零泄露);此处只做展示:
 * tag chips + 命中词高亮(文件名 / 备注 / 标签)。
 * 盲搜跳转定位方案 A(§3.1):行点击 = 原地开单文件详情 Drawer,URL ?focus= 驱动
 * (刷新/回退/分享可重放);Drawer 内「在文件夹中查看」跳 /folders/:id?asset= 深链。
 */
import { App, Button, Drawer, Empty, Input, Skeleton, Tag } from 'antd';
import { FolderOpen, Search as SearchIcon, Tag as TagIcon } from 'lucide-react';
import { useEffect, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { useFolder, useMe, useSearchAssets } from '../api/hooks';
import { useCompactViewport } from '../lib/use-viewports';
import { useKeyboardViewportHeight } from '../lib/use-keyboard-visible';
import { AppBreadcrumb } from '../components/AppBreadcrumb';
import { AssetSummaryPanel } from '../components/AssetSummaryPanel';

/** 把 text 里命中 q(忽略大小写)的子串用高亮 span 包起来。*/
function Highlight({ text, q }: { text: string; q: string }) {
  const t = text.toLowerCase();
  const needle = q.toLowerCase();
  const out: React.ReactNode[] = [];
  let i = 0;
  while (i < text.length) {
    const idx = t.indexOf(needle, i);
    if (idx < 0) {
      out.push(<span key={`t${i}`}>{text.slice(i)}</span>);
      break;
    }
    if (idx > i) out.push(<span key={`t${i}`}>{text.slice(i, idx)}</span>);
    out.push(
      <span key={`h${idx}`} style={{
        background: 'var(--ms-accent-soft)',
        color: 'var(--ms-accent)',
        borderRadius: 2,
        padding: '0 1px',
      }}>{text.slice(idx, idx + needle.length)}</span>,
    );
    i = idx + needle.length;
  }
  return <>{out}</>;
}

export default function SearchPage() {
  const [sp, setSearchParams] = useSearchParams();
  const navigate = useNavigate();
  const { message } = App.useApp();
  const compact = useCompactViewport();
  // q 直接以 URL 为准 — ⌘K 跳 /search?q=… 也能驱动输入框,无需 effect 同步
  const q = sp.get('q') ?? '';
  const [debounced, setDebounced] = useState(q);

  // 300ms 防抖,避免每击键都打后端
  useEffect(() => {
    const t = setTimeout(() => setDebounced(q), 300);
    return () => clearTimeout(t);
  }, [q]);

  const { data: results, isLoading, isFetching } = useSearchAssets(debounced.trim() || null);

  // 方案 A(§3.1):Drawer 开关 URL 驱动。focus 目标不在结果窗口(分享链接 /
  // 数据变化 / 50 截断)→ focused 未命中,Drawer 静默不开(§5 边界)。
  const focusId = sp.get('focus');
  const focused = results?.find(r => r.id === focusId);
  // AppShell 已取过 me,react-query 缓存命中零额外请求;focusFolder 为 Drawer 提供
  // my_can_download 等 gating(hook 顶层无条件调用,enabled 由 id 存在与否自然控制)
  const { data: me } = useMe();
  const { data: focusFolder } = useFolder(focused?.folder_id);
  // 抽屉形态 = FolderDetailPage 底部抽屉同款(§3.1):键盘弹起收缩为
  // kbViewportHeight - 顶栏(56),否则 min(72vh, 72dvh) —— 只写静态高度会被
  // 移动端软键盘盖住,compact 验收过不了
  const kbViewportHeight = useKeyboardViewportHeight();
  const drawerHeight = kbViewportHeight != null ? kbViewportHeight - 56 : 'min(72vh, 72dvh)';

  return (
    <div className="ms-enter" style={{ maxWidth: 900, margin: '0 auto' }}>
      <AppBreadcrumb />

      {/* 搜索框 */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: 10,
        background: 'var(--ms-surface)',
        border: '1px solid var(--ms-hairline)',
        borderRadius: 'var(--ms-radius-lg)',
        padding: '4px 16px',
        boxShadow: 'var(--ms-shadow-sm)',
        marginTop: 16,
      }}>
        <SearchIcon size={16} strokeWidth={1.8} style={{ color: 'var(--ms-ink-muted)', flexShrink: 0 }} />
        <Input
          value={q}
          onChange={(e) => {
            const v = e.target.value;
            setSearchParams(v ? { q: v } : {}, { replace: true });
            if (v.trim() === '') setDebounced('');
          }}
          variant="borderless"
          placeholder="搜文件名 / 标签 / 备注 — 跨全部有权限的文件夹…"
          allowClear
          autoFocus
          onPressEnter={() => setDebounced(q)}
          style={{ fontSize: 15, padding: '10px 0' }}
        />
        {/* Enter kbd 是键盘优先的 PC 提示,compact 不渲染 */}
        {!compact && (
          <kbd style={{
            fontFamily: 'var(--ms-font-mono)', fontSize: 10.5,
            color: 'var(--ms-ink-subtle)', background: 'var(--ms-canvas)',
            border: '1px solid var(--ms-hairline)', borderRadius: 3, padding: '1px 5px',
          }}>Enter</kbd>
        )}
      </div>

      <div style={{ margin: '14px 2px', fontSize: 12.5, color: 'var(--ms-ink-muted)' }}>
        {debounced.trim() ? (
          isFetching ? <>搜索中…</> : <>找到 <span className="ms-mono">{results?.length ?? 0}</span> 个文件</>
        ) : (
          '输入关键词开始搜索;仅返回你有查看权限的文件夹内容。'
        )}
      </div>

      {!debounced.trim() ? null : isLoading ? (
        <Skeleton active paragraph={{ rows: 6 }} />
      ) : !results || results.length === 0 ? (
        <div style={{
          padding: '60px 20px', textAlign: 'center',
          background: 'var(--ms-surface)',
          border: '1px dashed var(--ms-hairline)',
          borderRadius: 'var(--ms-radius-lg)',
        }}>
          <Empty
            image={Empty.PRESENTED_IMAGE_SIMPLE}
            description={<span style={{ color: 'var(--ms-ink-muted)' }}>
              没有命中「{debounced.trim()}」的文件<br />试试标签 / 文件名关键词
            </span>}
          />
        </div>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          {results.map((r) => {
            const notes = r.notes?.trim();
            const labelHit = r.user_labels.filter(l => l.toLowerCase().includes(debounced.trim().toLowerCase()));
            return (
              <div
                key={r.id}
                onClick={() => setSearchParams({ q, focus: r.id })}
                style={{
                  background: 'var(--ms-surface)',
                  border: '1px solid var(--ms-hairline)',
                  borderRadius: 'var(--ms-radius-lg)',
                  padding: '14px 18px',
                  cursor: 'pointer',
                  transition: 'border-color var(--ms-dur-fast) var(--ms-ease), box-shadow var(--ms-dur-fast) var(--ms-ease)',
                }}
                onMouseEnter={e => {
                  e.currentTarget.style.borderColor = 'var(--ms-hairline-strong, #D8D5CE)';
                  e.currentTarget.style.boxShadow = 'var(--ms-shadow-sm)';
                }}
                onMouseLeave={e => {
                  e.currentTarget.style.borderColor = 'var(--ms-hairline)';
                  e.currentTarget.style.boxShadow = 'none';
                }}
              >
                {/* compact: folder/project meta 换行到文件名下方第二行 */}
                <div style={{
                  display: 'flex', alignItems: 'center',
                  gap: compact ? '4px 10px' : 10,
                  flexWrap: compact ? 'wrap' : undefined,
                }}>
                  <span style={{
                    flex: 1, minWidth: 0,
                    flexBasis: compact ? '100%' : undefined,
                    fontSize: 14.5, fontWeight: 500, color: 'var(--ms-ink)',
                    overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
                  }}>
                    <Highlight text={r.filename} q={debounced.trim()} />
                  </span>
                  <span style={{
                    fontSize: 11, color: 'var(--ms-ink-subtle)',
                    display: 'inline-flex', alignItems: 'center', gap: 4, flexShrink: 0,
                  }}>
                    <FolderOpen size={11} strokeWidth={1.8} />
                    {r.folder_name}
                  </span>
                  <span className="ms-mono" style={{
                    fontSize: 10.5, color: 'var(--ms-ink-subtle)', flexShrink: 0,
                    maxWidth: 140, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
                  }}>{r.project_name}</span>
                </div>

                {/* 标签 chips — 命中标签高亮 */}
                {(r.user_labels.length > 0 || notes) && (
                  <div style={{
                    marginTop: 8,
                    display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap',
                  }}>
                    {r.user_labels.length > 0 && (
                      <TagIcon size={11} strokeWidth={1.8} style={{ color: 'var(--ms-ink-subtle)', flexShrink: 0 }} />
                    )}
                    {r.user_labels.map((l) => (
                      <Tag
                        key={l}
                        style={{
                          marginInlineEnd: 0,
                          background: labelHit.includes(l) ? 'var(--ms-accent-soft)' : undefined,
                          color: labelHit.includes(l) ? 'var(--ms-accent)' : undefined,
                          borderColor: 'var(--ms-hairline)',
                        }}
                      >{l}</Tag>
                    ))}
                    {notes && (
                      <span style={{
                        fontSize: 12, color: 'var(--ms-ink-muted)',
                        overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
                        maxWidth: '60%', minWidth: 0, marginLeft: 4,
                      }}>
                        <Highlight text={notes} q={debounced.trim()} />
                      </span>
                    )}
                  </div>
                )}
              </div>
            );
          })}

          <div style={{ textAlign: 'center', padding: 12 }}>
            <Button type="text" size="small"
                    onClick={() => message.info('MVP 只返回前 50 条,继续输入更精确的关键词')}
                    style={{ color: 'var(--ms-ink-subtle)' }}>
              {results.length >= 50 ? '结果超过 50 条,MVP 截断 — 用更精确关键词缩小范围' : ''}
            </Button>
          </div>
        </div>
      )}

      {/* 方案 A:命中行原地开单文件详情。单文件态不做 ‹ n/N › 跨结果切换(二期可选);
          onClose 只移除 focus 保留 q(replace —— 回退/刷新不再莫名重开);改搜索词
          沿用整表替换丢 focus(有意:新搜索语境,旧 focus 失效,§5) */}
      <Drawer
        placement="bottom"
        open={focused != null}
        onClose={() => setSearchParams({ q }, { replace: true })}
        height={drawerHeight}
        styles={{ body: { padding: 0, overflowY: 'auto' } }}
        title={
          <span style={{
            fontSize: 13, color: 'var(--ms-ink-muted)', minWidth: 0,
            overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
          }}>{focused?.filename}</span>
        }
        extra={
          focused && (
            <Button
              type="text" size="small"
              icon={<FolderOpen size={14} strokeWidth={1.8} />}
              onClick={() => navigate(`/folders/${focused.folder_id}?asset=${focused.id}`)}
            >
              在文件夹中查看
            </Button>
          )
        }
      >
        {focused && (
          <AssetSummaryPanel selected={[focused]} me={me} folder={focusFolder} />
        )}
      </Drawer>
    </div>
  );
}
