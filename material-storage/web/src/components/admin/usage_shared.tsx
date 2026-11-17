/* eslint-disable react-refresh/only-export-components --
   页面私有共享件:标签映射(常量)与 Section(组件)按设计收拢同一文件,
   拆分反而增加文件数;代价仅为本文件改动时 HMR 全量刷新,可接受。 */

/**
 * usage_shared — 使用统计页(UsageProportion / UsageStatsTable)共享的页面私有件。
 *
 * - PLATFORM_LABEL / NETWORK_LABEL:统计枚举中文文案。P5 决策:页面私有映射
 *   (不进 labels.ts);含 unknown → 「未知」兜底,调用处再以 `?? 原值` 兜底
 *   后端新出现的未知枚举;
 * - Section:卡片节布局。此前占比组件(Section)与 UsageStatsTable(Panel)
 *   各持一份孪生副本,新增枚举值 / 调样式需两处同步易漂移,现收拢于此——
 *   以占比组件版为正本(children 容器为 flex 纵排 gap 14,单子元素时
 *   渲染与原 Panel 一致),两处统一引用;
 * - PLATFORM_CLASS_LABEL / BAR_COLOR(2026-11-17 迁入,需求
 *   docs/qdev/2026-11-17-usage-stats-pie-and-date-range.md §3):自 UsageStatBars
 *   (现 UsageProportion)迁入,条形 / 饼图两视图共用,单一正本;
 * - formatUsageLine:「N 人 · M 次 · X%」数值行文案单一正本(条形行 / 饼图图例 /
 *   扇区悬浮共用;2026-11-17 测试 P1-1 收口,输出与既有格式一字不差)。
 */
export const PLATFORM_LABEL: Record<string, string> = {
  web_desktop: 'Web · 桌面浏览器',
  web_mobile: 'Web · 移动浏览器',
  android_app: 'Android App',
  ios_app: 'iOS App',
  app_legacy: '旧版 App',
  // MCP 素材服务(2026-10-30):UA=msmcp/* 的 AI 客户端渠道(后端 _PLATFORM_CASE 新增)
  mcp: 'MCP / AI 助手',
  unknown: '未知',
};
export const NETWORK_LABEL: Record<string, string> = {
  lan: '内网',
  wan: '外网',
  unknown: '未知',
};

// P5 决策:统计枚举中文文案为页面私有映射(不进 labels.ts);
// PLATFORM_CLASS_LABEL / BAR_COLOR 自 UsageStatBars 迁入(2026-11-17 饼图切换需求 §3),
// 条形 / 饼图两视图共用,单一正本。
export const PLATFORM_CLASS_LABEL: Record<string, string> = {
  web: 'Web 网页端',
  android_app: 'Android App',
  ios_app: 'iOS App',
  app_legacy: '旧版 App',
  // MCP 素材服务(2026-10-30):AI 客户端渠道(不进 web 归并,后端 platform_class 原值透出)
  mcp: 'MCP / AI 助手',
  unknown: '未知',
};

// 色条配色(web 主色橙;unknown 兜底灰)
export const BAR_COLOR: Record<string, string> = {
  web: 'var(--ms-accent)',
  web_desktop: 'var(--ms-accent)',
  web_mobile: 'var(--ms-amber)',
  android_app: 'var(--ms-emerald)',
  ios_app: 'var(--ms-crimson)',
  app_legacy: 'var(--ms-ink-subtle)',
  // MCP(2026-10-30):色板无第 5 个色相,复用 amber(与 Web 移动端同色不同分区,仅粗分类)
  mcp: 'var(--ms-amber)',
  lan: 'var(--ms-emerald)',
  wan: 'var(--ms-accent)',
  unknown: 'var(--ms-ink-subtle)',
};

// ─── 数值行文案(页内私有,仅 UsageProportion / UsageDonut 引用)──────────────
// 「N 人 · M 次 · X%」单一正本(2026-11-17 测试 P1-1):此前 StatRow(条形行)、
// UsageDonut 图例行 / 扇区 title 三处各写一遍易漂移,收拢于此;
// 输出与既有格式一字不差。
export function formatUsageLine(users: number, events: number, percent: number): string {
  return `${users.toLocaleString()} 人 · ${events.toLocaleString()} 次 · ${percent.toFixed(1)}%`;
}

// ─── 卡片节(页内私有组件,仅 UsageProportion / UsageStatsTable 引用)──────────
export function Section({ title, caption, children }: {
  title: string;
  caption?: string;
  children: React.ReactNode;
}) {
  return (
    <section style={{
      background: 'var(--ms-surface)',
      border: '1px solid var(--ms-hairline)',
      borderRadius: 'var(--ms-radius-md)',
      padding: '16px 20px',
    }}>
      <h2 style={{
        margin: 0, fontSize: 13.5, fontWeight: 500,
        color: 'var(--ms-ink)', lineHeight: 1.4,
      }}>{title}</h2>
      {caption && (
        <p style={{ margin: '4px 0 0', fontSize: 11.5, color: 'var(--ms-ink-subtle)' }}>
          {caption}
        </p>
      )}
      <div style={{ marginTop: 14, display: 'flex', flexDirection: 'column', gap: 14 }}>
        {children}
      </div>
    </section>
  );
}
