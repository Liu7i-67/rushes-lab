/**
 * /settings — 账号设置页(2026-11-19 设置页 MCP 收拢方案 F1/F3/D4/D7)。
 *
 * 结构 = 页头「设置」+ 两个区块:
 * - 「偏好」:【默认收拢全部文件夹】antd Switch(服务端存储,读写
 *   GET/PUT /api/v1/me/preferences,走 api/prefs.ts 固定契约 hooks);
 *   开启后进入项目时所有文件夹树默认收拢,点击箭头逐层展开,选择弹窗
 *   同样生效;生效时机 D4 = 下一次挂载(重进项目 / 重开弹窗),切换本身
 *   即时持久化到服务端;
 * - 「MCP / AI 接入」:入口卡片「访问令牌(Personal Access Token)」,
 *   整卡可点 → /settings/mcp(令牌管理本体收拢到二级页 SettingsMcpPage;
 *   旧注释「令牌管理只做 Web」随 App 端 PAT 管理上线作废)。
 * 入口:UserMenu「设置」/ PC AppHeader 齿轮图标 / 移动端「更多 → 设置」。
 */
import type { CSSProperties } from 'react';
import { App, Switch } from 'antd';
import { useNavigate } from 'react-router-dom';
import { ChevronRight, FolderTree, KeyRound } from 'lucide-react';
import { errorMessage } from '../api/client';
import { useUpdateUserPreferences, useUserPreferences } from '../api/prefs';
import { useCompactViewport } from '../lib/use-viewports';

/** 区块标题(照 TokensSection h2 惯例)。 */
function BlockTitle({ children }: { children: string }) {
  return (
    <h2 style={{ margin: 0, fontSize: 15, fontWeight: 500, color: 'var(--ms-ink)' }}>
      {children}
    </h2>
  );
}

export default function SettingsPage() {
  const navigate = useNavigate();
  const compact = useCompactViewport();
  const { message } = App.useApp();

  // F3:偏好读写走 api/prefs.ts 固定契约;乐观更新 + 失败回滚由 mutation 契约
  // 承担,这里只负责失败 Toast(Switch 值随缓存回滚自动回弹)。
  // 请求失败按 false(现状行为)兜底。
  const { prefs, isLoading } = useUserPreferences();
  const update = useUpdateUserPreferences();

  // 卡片基底(照 AdminStatsPanelPage 模块卡片:图标 + 标题 + 描述 + 右侧元素)
  const cardStyle: CSSProperties = {
    display: 'flex', alignItems: 'center', gap: 14, width: '100%',
    padding: compact ? '14px 16px' : '16px 20px',
    background: 'var(--ms-surface)',
    border: '1px solid var(--ms-hairline)',
    borderRadius: 'var(--ms-radius-md)',
  };
  const iconBoxStyle: CSSProperties = {
    display: 'grid', placeItems: 'center', width: 40, height: 40, flexShrink: 0,
    background: 'var(--ms-accent-soft)', borderRadius: 'var(--ms-radius-sm)',
    color: 'var(--ms-accent)',
  };
  const titleStyle: CSSProperties = {
    display: 'block', fontSize: 14.5, fontWeight: 500, color: 'var(--ms-ink)',
  };
  const descStyle: CSSProperties = {
    display: 'block', marginTop: 3, fontSize: 12, lineHeight: 1.5,
    color: 'var(--ms-ink-muted)',
  };

  return (
    <div className="ms-enter">
      {/* 页头(照 AdminStatsPanelPage 惯例) */}
      <div style={{ marginBottom: 'var(--ms-sp-xl)' }}>
        <h1 style={{
          margin: 0, fontFamily: 'var(--ms-font-display)',
          fontSize: 32, fontWeight: 500, letterSpacing: '-0.02em',
          color: 'var(--ms-ink)', lineHeight: 1.1,
        }}>设置</h1>
        <p style={{ margin: '8px 0 0', fontSize: 13, color: 'var(--ms-ink-muted)' }}>
          账号偏好与 MCP / AI 客户端接入
        </p>
      </div>

      {/* 「偏好」区块(F3):默认收拢全部文件夹 */}
      <section style={{ marginBottom: 'var(--ms-sp-lg)' }}>
        <BlockTitle>偏好</BlockTitle>
        <div style={{ ...cardStyle, marginTop: 12, maxWidth: 640 }}>
          <span style={iconBoxStyle}>
            <FolderTree size={20} strokeWidth={1.8} />
          </span>
          <span style={{ flex: 1, minWidth: 0 }}>
            <span style={titleStyle}>默认收拢全部文件夹</span>
            <span style={descStyle}>
              开启后进入项目时所有文件夹树默认收拢,点击箭头逐层展开;对选择弹窗同样生效。
              切换后重新进入项目 / 打开弹窗时生效。
            </span>
          </span>
          <Switch
            checked={prefs?.folder_tree_default_collapsed ?? false}
            loading={isLoading || update.isPending}
            onChange={(checked) => {
              update.mutate(
                { folder_tree_default_collapsed: checked },
                { onError: (e) => message.error(errorMessage(e, '保存失败,请稍后重试')) },
              );
            }}
          />
        </div>
      </section>

      {/* 「MCP / AI 接入」区块(F1):入口卡片,整卡可点(照 AdminStatsPanelPage 模块卡片) */}
      <section>
        <BlockTitle>MCP / AI 接入</BlockTitle>
        <button
          onClick={() => navigate('/settings/mcp')}
          style={{
            ...cardStyle, marginTop: 12, maxWidth: 640,
            textAlign: 'left', cursor: 'pointer', fontFamily: 'inherit',
            transition: 'background var(--ms-dur-fast) var(--ms-ease)',
          }}
          onMouseEnter={e => (e.currentTarget.style.background = 'var(--ms-hairline-soft)')}
          onMouseLeave={e => (e.currentTarget.style.background = 'var(--ms-surface)')}
        >
          <span style={iconBoxStyle}>
            <KeyRound size={20} strokeWidth={1.8} />
          </span>
          <span style={{ flex: 1, minWidth: 0 }}>
            <span style={titleStyle}>访问令牌(Personal Access Token)</span>
            <span style={descStyle}>
              创建与管理 MCP / AI 客户端使用的个人访问令牌;令牌等同账号级全权限凭证
            </span>
          </span>
          <ChevronRight size={16} strokeWidth={1.8} style={{ color: 'var(--ms-ink-subtle)', flexShrink: 0 }} />
        </button>
      </section>
    </div>
  );
}
