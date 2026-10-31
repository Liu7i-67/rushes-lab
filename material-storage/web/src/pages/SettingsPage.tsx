/**
 * /settings — 账号设置页(2026-10-30 MCP 素材服务 D15:令牌管理只做 Web)。
 *
 * 当前唯一区域:个人访问令牌(PAT),供能配置静态 `Authorization: Bearer` 的
 * MCP 客户端(如 ZCode / Claude Desktop / mcp-remote)以本人身份调用 API。
 * 入口:UserMenu「设置」/ PC AppHeader 齿轮图标 / 移动端「更多 → 设置」。
 */
import { TokensSection } from '../components/settings/TokensSection';

export default function SettingsPage() {
  return (
    <div className="ms-enter">
      <div style={{ marginBottom: 'var(--ms-sp-xl)' }}>
        <h1 style={{
          margin: 0, fontFamily: 'var(--ms-font-display)',
          fontSize: 32, fontWeight: 500, letterSpacing: '-0.02em',
          color: 'var(--ms-ink)', lineHeight: 1.1,
        }}>设置</h1>
        <p style={{ margin: '8px 0 0', fontSize: 13, color: 'var(--ms-ink-muted)' }}>
          账号设置 — 个人访问令牌(MCP / AI 客户端接入)
        </p>
      </div>

      <TokensSection />
    </div>
  );
}
