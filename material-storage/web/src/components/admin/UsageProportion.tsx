/**
 * UsageProportion — 使用统计三节占比展示(条形 / 饼图双视图;2026-11-17 需求
 * docs/qdev/2026-11-17-usage-stats-pie-and-date-range.md §2 F1,替代 UsageStatBars)。
 *
 * - 三节布局与原 UsageStatBars 完全一致:客户端占比(by_platform_class 主展示 +
 *   by_platform 下钻 + MCP 渠道标注)、网络环境(by_network);
 * - view='bar'(默认):StatRow 自绘占比条,渲染与原版一字不差;
 * - view='pie':每节改渲染 UsageDonut 环形图(SVG 自绘,不引图表库)——扇区颜色沿用
 *   BAR_COLOR(与条形同分类同色),图例数值口径与条形完全一致(行 users / totals.users),
 *   扇区角度由 UsageDonut 按各行 users 归一化铺满整圆;
 * - 占比口径:行 users / totals.users(分母是窗口内去重用户总数;各分组 users 独立去重、
 *   跨行不可加 → 同一用户多端重复计数,各行占比之和可 >100%,页内已标注);
 * - 标签 / 色板全部来自 usage_shared 单一正本;unknown / 未知枚举值兜底文案「未知」。
 */
import type {
  UsageNetworkRow,
  UsagePlatformClassRow,
  UsagePlatformRow,
  UsageStatsOut,
} from '../../api/hooks';
import { UsageDonut, type UsageDonutSlice } from './UsageDonut';
import {
  BAR_COLOR,
  NETWORK_LABEL,
  PLATFORM_CLASS_LABEL,
  PLATFORM_LABEL,
  Section,
  formatUsageLine,
} from './usage_shared';

// 饼图视图各节 caption 末尾追加的角度口径说明(F1.4 / D5:角度按行 users 归一化,
// 标注仍用 users/totals.users);条形视图 caption 不追加。
const PIE_CAPTION_NOTE =
  '饼图扇区角度按各行用户数归一化(多端重复计数时占比之和可大于 100%,角度仍铺满整圆)。';

// 三节数据行统一收敛形状(后端行 key 字段名不同:platform_class / platform / network)
interface ProportionRow {
  key: string;
  users: number;
  events: number;
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
          {formatUsageLine(users, events, percent)}
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

// 行 → 饼图 slices:label / color 与条形同一映射与兜底(BAR_COLOR 缺色兜底灰),
// percent 同条形口径(行 users / totals.users);角度归一化由 UsageDonut 内部处理。
function toSlices(
  rows: ProportionRow[],
  pct: (users: number) => number,
  labelOf: Record<string, string>,
): UsageDonutSlice[] {
  return rows.map((r) => ({
    key: r.key,
    label: labelOf[r.key] ?? r.key,
    users: r.users,
    events: r.events,
    percent: pct(r.users),
    color: BAR_COLOR[r.key] ?? 'var(--ms-ink-subtle)',
  }));
}

export function UsageProportion({ stats, view }: { stats: UsageStatsOut; view: 'bar' | 'pie' }) {
  const total = stats.totals.users;
  const pct = (users: number) => (total > 0 ? (users / total) * 100 : 0);
  const pie = view === 'pie';
  // 各节 caption:条形视图一字不动;饼图视图末尾追加角度口径说明
  const caption = (base: string) => (pie ? `${base}${PIE_CAPTION_NOTE}` : base);

  const platformClassRows: ProportionRow[] = stats.by_platform_class.map((r: UsagePlatformClassRow) => ({
    key: r.platform_class, users: r.users, events: r.events,
  }));
  const platformRows: ProportionRow[] = stats.by_platform.map((r: UsagePlatformRow) => ({
    key: r.platform, users: r.users, events: r.events,
  }));
  const networkRows: ProportionRow[] = stats.by_network.map((r: UsageNetworkRow) => ({
    key: r.network, users: r.users, events: r.events,
  }));

  // 单节占比渲染:bar = StatRow 列表(与原 UsageStatBars 完全一致);pie = 环形图
  // (中心统一放窗口去重用户总数)
  const block = (rows: ProportionRow[], labelOf: Record<string, string>) => (
    pie ? (
      <UsageDonut centerLabel="去重用户" centerValue={total} slices={toSlices(rows, pct, labelOf)} />
    ) : (
      rows.map((r) => (
        <StatRow
          key={r.key}
          label={labelOf[r.key] ?? r.key}
          users={r.users}
          events={r.events}
          percent={pct(r.users)}
          color={BAR_COLOR[r.key] ?? 'var(--ms-ink-subtle)'}
        />
      ))
    )
  );

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
      {/* 客户端占比:by_platform_class 主展示 + by_platform 下钻 */}
      <Section
        title="客户端占比"
        caption={caption('按 User-Agent 解析;占比 = 各行去重用户 / 窗口去重用户总数。同一用户多端使用会重复计数(去重用户跨分组不可加),各行占比之和可能大于 100%。')}
      >
        {block(platformClassRows, PLATFORM_CLASS_LABEL)}
        {/* MCP 素材服务(2026-10-30):渠道口径标注(数据源是 audit_events,
            搜索 / 缩略图等读操作无审计 → 只反映审计可见操作,读流量被低估) */}
        {stats.by_platform_class.some((r: UsagePlatformClassRow) => r.platform_class === 'mcp') && (
          <div style={{ marginTop: -4, fontSize: 11.5, color: 'var(--ms-ink-subtle)' }}>
            注:MCP / AI 助手渠道仅统计审计可见操作(上传 / 下载签发等);搜索 / 缩略图等
            读操作不写审计,该渠道读流量会低估。
          </div>
        )}
        {/* by_platform 下钻:web_desktop / web_mobile 拆分 */}
        <div style={{
          marginTop: 2, paddingTop: 12,
          borderTop: '1px dashed var(--ms-hairline)',
        }}>
          <div style={{ fontSize: 12, color: 'var(--ms-ink-muted)', marginBottom: 10 }}>
            下钻 · 客户端明细(Web 拆分桌面 / 移动浏览器,另含 MCP / AI 助手)
          </div>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            {block(platformRows, PLATFORM_LABEL)}
          </div>
        </div>
      </Section>

      {/* 网络环境:lan / wan / unknown */}
      <Section
        title="网络环境占比"
        caption={caption('按请求来源 IP 判定内网 / 外网;IP 缺失或不可判定记为「未知」。多端用户重复计数口径同上。')}
      >
        {block(networkRows, NETWORK_LABEL)}
      </Section>
    </div>
  );
}
