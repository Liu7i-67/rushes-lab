/**
 * /settings/mcp — MCP 访问令牌二级页(2026-11-19 设置页 MCP 收拢方案 F2)。
 *
 * 设置页只留入口,令牌管理本体(创建 / 列表 / 吊销 / include_revoked /
 * 一次性明文 / MCP 使用说明)整体迁入本页;components/settings/ 四件套
 * 原样复用、功能零变化(admin 侧 AdminTokensTable 对 token-status.ts 的
 * 相对引用也因此保持原路径)。
 * 入口:设置页「MCP / AI 接入」卡片 navigate('/settings/mcp')。
 */
import { TokensSection } from '../components/settings/TokensSection';

export default function SettingsMcpPage() {
  return (
    <div className="ms-enter">
      {/* 页头(照 SettingsPage / AdminStatsPanelPage 惯例) */}
      <div style={{ marginBottom: 'var(--ms-sp-xl)' }}>
        <h1 style={{
          margin: 0, fontFamily: 'var(--ms-font-display)',
          fontSize: 32, fontWeight: 500, letterSpacing: '-0.02em',
          color: 'var(--ms-ink)', lineHeight: 1.1,
        }}>MCP 访问令牌</h1>
        <p style={{ margin: '8px 0 0', fontSize: 13, color: 'var(--ms-ink-muted)' }}>
          个人访问令牌(PAT)— 供 MCP / AI 客户端以你的身份调用素材库 API
        </p>
      </div>

      <TokensSection />
    </div>
  );
}
