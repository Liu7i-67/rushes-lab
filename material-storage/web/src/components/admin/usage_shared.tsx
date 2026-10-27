/* eslint-disable react-refresh/only-export-components --
   页面私有共享件:标签映射(常量)与 Section(组件)按设计收拢同一文件,
   拆分反而增加文件数;代价仅为本文件改动时 HMR 全量刷新,可接受。 */

/**
 * usage_shared — 使用统计页(UsageStatBars / UsageStatsTable)共享的页面私有件。
 *
 * - PLATFORM_LABEL / NETWORK_LABEL:统计枚举中文文案。P5 决策:页面私有映射
 *   (不进 labels.ts);含 unknown → 「未知」兜底,调用处再以 `?? 原值` 兜底
 *   后端新出现的未知枚举;
 * - Section:卡片节布局。此前 UsageStatBars(Section)与 UsageStatsTable(Panel)
 *   各持一份孪生副本,新增枚举值 / 调样式需两处同步易漂移,现收拢于此——
 *   以 UsageStatBars 版为正本(children 容器为 flex 纵排 gap 14,单子元素时
 *   渲染与原 Panel 一致),两处统一引用。
 */
export const PLATFORM_LABEL: Record<string, string> = {
  web_desktop: 'Web · 桌面浏览器',
  web_mobile: 'Web · 移动浏览器',
  android_app: 'Android App',
  ios_app: 'iOS App',
  app_legacy: '旧版 App',
  unknown: '未知',
};
export const NETWORK_LABEL: Record<string, string> = {
  lan: '内网',
  wan: '外网',
  unknown: '未知',
};

// ─── 卡片节(页内私有组件,仅 UsageStatBars / UsageStatsTable 引用)──────────
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
