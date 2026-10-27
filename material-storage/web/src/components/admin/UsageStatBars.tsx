/**
 * UsageStatBars — 使用统计占比条(F5,需求 docs/qdev/2026-10-27-usage-analytics.md)。
 *
 * - platform 主展示用 by_platform_class(web / android_app / ios_app / app_legacy,
 *   直接回答「三端占比」);by_platform(web_desktop / web_mobile 拆分)作下钻展示;
 * - network 一块(lan / wan / unknown);
 * - 占比 = 行 users / totals.users(分母是窗口内去重用户总数;各分组 users 独立去重、
 *   跨行不可加 → 同一用户多端重复计数,各行占比之和可 >100%,页内已标注);
 * - 条形自绘色条(inline style + CSS vars,同 AdminAuditPage EventRow 视觉语言),
 *   不引图表库;unknown / 未知枚举值兜底文案「未知」。
 */
import type {
  UsageNetworkRow,
  UsagePlatformClassRow,
  UsagePlatformRow,
  UsageStatsOut,
} from '../../api/hooks';

// P5 决策:统计枚举中文文案为页面私有映射(不进 labels.ts)。
// UsageStatsTable.tsx 有 PLATFORM_LABEL / NETWORK_LABEL 孪生副本,新增枚举值两处同步。
const PLATFORM_CLASS_LABEL: Record<string, string> = {
  web: 'Web 网页端',
  android_app: 'Android App',
  ios_app: 'iOS App',
  app_legacy: '旧版 App',
  unknown: '未知',
};
const PLATFORM_LABEL: Record<string, string> = {
  web_desktop: 'Web · 桌面浏览器',
  web_mobile: 'Web · 移动浏览器',
  android_app: 'Android App',
  ios_app: 'iOS App',
  app_legacy: '旧版 App',
  unknown: '未知',
};
const NETWORK_LABEL: Record<string, string> = {
  lan: '内网',
  wan: '外网',
  unknown: '未知',
};

// 色条配色(web 主色橙;unknown 兜底灰)
const BAR_COLOR: Record<string, string> = {
  web: 'var(--ms-accent)',
  web_desktop: 'var(--ms-accent)',
  web_mobile: 'var(--ms-amber)',
  android_app: 'var(--ms-emerald)',
  ios_app: 'var(--ms-crimson)',
  app_legacy: 'var(--ms-ink-subtle)',
  lan: 'var(--ms-emerald)',
  wan: 'var(--ms-accent)',
  unknown: 'var(--ms-ink-subtle)',
};

// ─── 卡片节(与 UsageStatsTable 的 Panel 孪生,页内私有组件不外借)────────────
function Section({ title, caption, children }: {
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

// ─── 单行占比条 ─────────────────────────────────────────────────────────────
function StatRow({ label, users, events, percent, color }: {
  label: string;
  users: number;
  events: number;
  percent: number;   // 0..100,可带小数;>100 不可能(users ≤ 去重总数),宽度仍钳 100
  color: string;
}) {
  return (
    <div>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, flexWrap: 'wrap' }}>
        <span style={{ fontSize: 13, fontWeight: 500, color: 'var(--ms-ink)' }}>{label}</span>
        <span style={{
          marginLeft: 'auto', fontSize: 12, color: 'var(--ms-ink-muted)',
          fontVariantNumeric: 'tabular-nums',
        }}>
          {users.toLocaleString()} 人 · {events.toLocaleString()} 次 · {percent.toFixed(1)}%
        </span>
      </div>
      <div style={{
        marginTop: 6, height: 8, borderRadius: 4, overflow: 'hidden',
        background: 'var(--ms-hairline-soft)',
      }}>
        <div style={{
          width: `${Math.min(percent, 100)}%`,
          height: '100%',
          borderRadius: 4,
          background: color,
          transition: 'width var(--ms-dur-mid) var(--ms-ease)',
        }} />
      </div>
    </div>
  );
}

export function UsageStatBars({ stats }: { stats: UsageStatsOut }) {
  const total = stats.totals.users;
  const pct = (users: number) => (total > 0 ? (users / total) * 100 : 0);

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
      {/* 客户端占比:by_platform_class 主展示 + by_platform 下钻 */}
      <Section
        title="客户端占比"
        caption="按 User-Agent 解析;占比 = 各行去重用户 / 窗口去重用户总数。同一用户多端使用会重复计数(去重用户跨分组不可加),各行占比之和可能大于 100%。"
      >
        {stats.by_platform_class.map((r: UsagePlatformClassRow) => (
          <StatRow
            key={r.platform_class}
            label={PLATFORM_CLASS_LABEL[r.platform_class] ?? r.platform_class}
            users={r.users}
            events={r.events}
            percent={pct(r.users)}
            color={BAR_COLOR[r.platform_class] ?? 'var(--ms-ink-subtle)'}
          />
        ))}
        {/* by_platform 下钻:web_desktop / web_mobile 拆分 */}
        <div style={{
          marginTop: 2, paddingTop: 12,
          borderTop: '1px dashed var(--ms-hairline)',
        }}>
          <div style={{ fontSize: 12, color: 'var(--ms-ink-muted)', marginBottom: 10 }}>
            下钻 · 客户端明细(Web 拆分桌面 / 移动浏览器)
          </div>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            {stats.by_platform.map((r: UsagePlatformRow) => (
              <StatRow
                key={r.platform}
                label={PLATFORM_LABEL[r.platform] ?? r.platform}
                users={r.users}
                events={r.events}
                percent={pct(r.users)}
                color={BAR_COLOR[r.platform] ?? 'var(--ms-ink-subtle)'}
              />
            ))}
          </div>
        </div>
      </Section>

      {/* 网络环境:lan / wan / unknown */}
      <Section
        title="网络环境占比"
        caption="按请求来源 IP 判定内网 / 外网;IP 缺失或不可判定记为「未知」。多端用户重复计数口径同上。"
      >
        {stats.by_network.map((r: UsageNetworkRow) => (
          <StatRow
            key={r.network}
            label={NETWORK_LABEL[r.network] ?? r.network}
            users={r.users}
            events={r.events}
            percent={pct(r.users)}
            color={BAR_COLOR[r.network] ?? 'var(--ms-ink-subtle)'}
          />
        ))}
      </Section>
    </div>
  );
}
