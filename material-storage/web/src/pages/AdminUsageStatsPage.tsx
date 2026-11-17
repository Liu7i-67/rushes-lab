/**
 * /admin/usage — 客户端使用统计页(F5;docs/qdev/2026-10-27-usage-analytics.md §3.3)。
 *
 * 三端占比(web / Android App / iOS App)+ 内外网占比,依托审计日志聚合:
 * - 日期范围默认近 30 天整日(2026-11-17 需求 F2:纯日期选择,自动补 00:00 / 23:59:59.999;
 *   前端显式传参便于窗口回显);
 * - 占比展示支持条形 / 饼图切换(view 内存态,默认条形;2026-11-17 需求 F1);
 * - metric 切换 active_users(默认)/ logins;
 * - daily 开关控制日趋势取数(false 时后端 daily=[],趋势节自动不渲染);
 * - 页面纯展示:不做二次解析 / 二次去重;daily 的 users 跨维度不可加,前端不求和;
 * - 数据面 require_usage_stats_viewer(backend enforce;2026-11-06 统计面板方案 §4.5,
 *   口径 = org admin ∨ (stats_viewer ∧ usage_stats_viewer)):无权用户直连 URL 由后端 403
 *   (全局 queryCache 静默跳过),页面先用 me 做体验提示(照 AdminBaiduTasksPage)。
 *
 * 布局照 AdminAuditPage 页头 / 过滤栏惯例;占比条与交叉表拆子组件(方案 P3)。
 */
import { Alert, DatePicker, Empty, Segmented, Skeleton, Switch } from 'antd';
import { useMemo, useState } from 'react';
import dayjs, { type Dayjs } from 'dayjs';
import { useAdminUsageStats, useMe } from '../api/hooks';
import type { UsageMetric, UsageStatsParams } from '../api/hooks';
import { UsageProportion } from '../components/admin/UsageProportion';
import { UsageStatsTable } from '../components/admin/UsageStatsTable';
import { useCompactViewport } from '../lib/use-viewports';

type Range = [Dayjs, Dayjs];

const METRIC_OPTIONS = [
  { value: 'active_users', label: '活跃用户' },
  { value: 'logins', label: '登录次数' },
];

// metric 口径说明(切随显,口径照需求 §2:两口径统一过滤 UA 缺失事件)
const METRIC_HINT: Record<UsageMetric, string> = {
  active_users: '口径:窗口内有行为的去重用户(排除登录失败 / 登录锁定事件,UA 缺失的事件不计)。',
  logins: '口径:仅统计登录成功事件(local_login_success),UA 缺失不计。',
};

// 默认窗口:近 30 天整日([today-29d 00:00, today 23:59:59.999];2026-11-17 F2 改整日语义,
// 数据等价于 [today-29d 00:00, now]——未来无事件,窗口回显即自证自动补时)
const defaultRange = (): Range => [dayjs().subtract(29, 'day').startOf('day'), dayjs().endOf('day')];

// ─── 汇总卡 ─────────────────────────────────────────────────────────────────
function SummaryCard({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div style={{
      flex: '1 1 200px', minWidth: 170,
      background: 'var(--ms-surface)',
      border: '1px solid var(--ms-hairline)',
      borderRadius: 'var(--ms-radius-md)',
      padding: '12px 16px',
    }}>
      <div style={{ fontSize: 11.5, color: 'var(--ms-ink-subtle)' }}>{label}</div>
      <div style={{
        marginTop: 4, fontSize: 20, fontWeight: 500, color: 'var(--ms-ink)',
        fontVariantNumeric: 'tabular-nums', lineHeight: 1.3,
      }}>{value}</div>
      {sub && (
        <div style={{ marginTop: 2, fontSize: 11, color: 'var(--ms-ink-subtle)' }}>{sub}</div>
      )}
    </div>
  );
}

export default function AdminUsageStatsPage() {
  const { data: me } = useMe();
  const compact = useCompactViewport();
  const [range, setRange] = useState<Range>(defaultRange);
  const [metric, setMetric] = useState<UsageMetric>('active_users');
  // 占比展示视图:条形(默认)/ 饼图,仅内存态、不进 URL 不持久化(2026-11-17 F1.6)
  const [view, setView] = useState<'bar' | 'pie'>('bar');
  const [daily, setDaily] = useState(true);

  // from/to 传 tz-aware ISO(照 AdminAuditPage toISOString 惯例);参数整体进 queryKey
  const params = useMemo<UsageStatsParams>(
    () => ({ from: range[0].toISOString(), to: range[1].toISOString(), metric, daily }),
    [range, metric, daily],
  );
  const { data, isLoading } = useAdminUsageStats(params);

  // 前端体验守卫(后端仍 enforce;me 未就绪时不拦,交给后端 403 → 空态兜底)
  // 2026-11-06 统计面板方案 §5.3:守门放宽为 is_usage_stats_viewer ?? is_system_admin
  if (me && !(me.is_usage_stats_viewer ?? me.is_system_admin)) {
    return (
      <div className="ms-enter" style={{ maxWidth: 520 }}>
        <Alert
          type="warning" showIcon
          message="只有获得授权的用户可以查看使用统计"
          description="如需查看客户端与网络环境占比,请联系系统管理员开通。"
        />
      </div>
    );
  }

  const empty = !!data && data.totals.events === 0 && data.totals.users === 0;

  return (
    <div className="ms-enter">
      {/* 页头(照 AdminAuditPage) */}
      <div style={{
        display: 'flex', alignItems: 'baseline', justifyContent: 'space-between',
        gap: 24, marginBottom: 'var(--ms-sp-xl)',
      }}>
        <div>
          <h1 style={{
            margin: 0,
            fontFamily: 'var(--ms-font-display)',
            fontSize: 32, fontWeight: 500, letterSpacing: '-0.02em',
            color: 'var(--ms-ink)', lineHeight: 1.1,
          }}>使用统计</h1>
          <p style={{ margin: '8px 0 0', fontSize: 13, color: 'var(--ms-ink-muted)' }}>
            客户端三端占比 / 内外网访问占比(依托审计日志聚合;同一用户多端重复计数)
          </p>
        </div>
      </div>

      {/* 控制栏:日期范围 + metric 切换 + 占比视图切换 + daily 开关 */}
      <div style={{
        display: 'flex', gap: 12, flexWrap: 'wrap', alignItems: 'center',
        marginBottom: 10,
      }}>
        <DatePicker.RangePicker
          value={range}
          // 纯日期选择,自动补 00:00:00/23:59:59.999,后端窗口 [from,to) 独占须 endOf 覆盖末日全天
          onChange={(v) => { if (v && v[0] && v[1]) setRange([v[0].startOf('day'), v[1].endOf('day')]); }}
          allowClear={false}
        />
        <Segmented
          value={metric}
          onChange={(v) => setMetric(v as UsageMetric)}
          options={METRIC_OPTIONS}
        />
        {/* 占比展示条形 / 饼图切换(2026-11-17 F1:全局一个切换,三处占比展示联动) */}
        <Segmented
          value={view}
          onChange={(v) => setView(v as 'bar' | 'pie')}
          options={[
            { value: 'bar', label: '条形图' },
            { value: 'pie', label: '饼图' },
          ]}
        />
        <span style={{
          display: 'inline-flex', alignItems: 'center', gap: 6,
          fontSize: 12.5, color: 'var(--ms-ink-muted)',
        }}>
          <Switch size={compact ? 'small' : 'default'} checked={daily} onChange={setDaily} />
          日趋势
        </span>
      </div>
      <p style={{ margin: '0 0 16px', fontSize: 12, color: 'var(--ms-ink-subtle)' }}>
        {METRIC_HINT[metric]}
      </p>

      {/* 列表态 */}
      {isLoading ? (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          {[0, 1, 2].map(i => (
            <div key={i} style={{
              padding: '16px 20px',
              background: 'var(--ms-surface)',
              border: '1px solid var(--ms-hairline)',
              borderRadius: 'var(--ms-radius-md)',
            }}>
              <Skeleton active title={{ width: '30%' }} paragraph={{ rows: 2 }} />
            </div>
          ))}
        </div>
      ) : !data || empty ? (
        <Empty
          image={Empty.PRESENTED_IMAGE_SIMPLE}
          description={(
            <span style={{ color: 'var(--ms-ink-subtle)' }}>
              所选时间范围内暂无可用数据
            </span>
          )}
          style={{ marginTop: 80 }}
        />
      ) : (
        <>
          {/* 汇总条(totals + 服务端回显窗口) */}
          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginBottom: 16 }}>
            <SummaryCard
              label="去重用户数"
              value={data.totals.users.toLocaleString()}
              sub="窗口内按操作者去重;跨分组不可加"
            />
            <SummaryCard
              label="事件总数"
              value={data.totals.events.toLocaleString()}
              sub={metric === 'logins' ? '登录成功事件计数' : '全部有效事件计数'}
            />
            <SummaryCard
              label="统计窗口"
              value={`${dayjs(data.from).format('MM-DD HH:mm')} ~ ${dayjs(data.to).format('MM-DD HH:mm')}`}
              sub="服务端回显窗口(默认近 30 天)"
            />
          </div>
          <UsageProportion stats={data} view={view} />
          <div style={{ marginTop: 16 }}>
            <UsageStatsTable stats={data} />
          </div>
        </>
      )}
    </div>
  );
}
