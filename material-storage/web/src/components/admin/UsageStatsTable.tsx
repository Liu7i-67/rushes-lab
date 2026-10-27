/**
 * UsageStatsTable — 使用统计交叉表 + 日趋势(F5,需求 docs/qdev/2026-10-27-usage-analytics.md)。
 *
 * - 交叉表:cross 扁平行(行 = platform × network,含 users / events;后端已按
 *   users DESC → (platform, network) 字典序排定,前端不重排)。
 * - 日趋势:daily 按 date 聚合 **events** 画条形 —— 事件数是计数,跨 (platform, network)
 *   分组可加;daily 的 users 是分组内 count(DISTINCT),**跨行求和无意义,禁止求和**,
 *   故日趋势不做 users 展示(按日 users 只允许单一完整维度切片,本页不提供);
 *   daily=false 时响应 daily 为 [],本组件自动不渲染趋势节;
 * - 不引图表库:条形自绘(同 UsageStatBars 视觉语言)。
 */
import { Table } from 'antd';
import type { ColumnsType } from 'antd/es/table';
import { useMemo } from 'react';
import type { UsageCrossRow, UsageStatsOut } from '../../api/hooks';

// P5 决策:统计枚举中文文案为页面私有映射(不进 labels.ts)。
// UsageStatBars.tsx 有孪生副本,新增枚举值两处同步。
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

const crossColumns: ColumnsType<UsageCrossRow> = [
  {
    title: '客户端',
    dataIndex: 'platform',
    render: (v) => <span style={{ color: 'var(--ms-ink)' }}>{PLATFORM_LABEL[v] ?? v}</span>,
  },
  {
    title: '网络',
    dataIndex: 'network',
    width: 90,
    render: (v) => NETWORK_LABEL[v] ?? v,
  },
  {
    title: '用户数',
    dataIndex: 'users',
    align: 'right',
    width: 100,
    render: (v) => <span style={{ fontVariantNumeric: 'tabular-nums' }}>{v.toLocaleString()}</span>,
  },
  {
    title: '事件数',
    dataIndex: 'events',
    align: 'right',
    width: 100,
    render: (v) => <span style={{ fontVariantNumeric: 'tabular-nums' }}>{v.toLocaleString()}</span>,
  },
];

// ─── 卡片节(与 UsageStatBars 的 Section 孪生,页内私有组件不外借)────────────
function Panel({ title, caption, children }: {
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
      <div style={{ marginTop: 14 }}>{children}</div>
    </section>
  );
}

export function UsageStatsTable({ stats }: { stats: UsageStatsOut }) {
  // 日趋势数据源:按 date 聚合 events(可加)。daily 行已按 date ASC 排序,Map 保序
  // 兜底再 sort 一次,防御后端排序契约变化。
  const dayBars = useMemo(() => {
    const byDate = new Map<string, number>();
    for (const r of stats.daily) {
      byDate.set(r.date, (byDate.get(r.date) ?? 0) + r.events);
    }
    return [...byDate.entries()].sort(([a], [b]) => a.localeCompare(b));
  }, [stats.daily]);
  const maxEvents = dayBars.reduce((m, [, e]) => Math.max(m, e), 0);
  // 日期轴标签抽稀:最多约 12 个刻度,超出按步长跳标(条形仍全量渲染,悬浮看明细)
  const labelStep = Math.max(1, Math.ceil(dayBars.length / 12));

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
      <Panel
        title="客户端 × 网络交叉"
        caption="users 为该 (客户端, 网络) 组合内去重,跨行相加不等于总去重用户数。"
      >
        <Table<UsageCrossRow>
          rowKey={(r) => `${r.platform}|${r.network}`}
          columns={crossColumns}
          dataSource={stats.cross}
          pagination={false}
          size="small"
        />
      </Panel>

      {dayBars.length > 0 && (
        <Panel
          title="日趋势(事件数)"
          caption="按天(Asia/Shanghai)聚合事件数,事件计数跨维度可加;用户数按天去重跨维度不可加,不做按日求和展示。网络维度(内外网)自 2026-10-19 起数据可信。"
        >
          <div style={{
            display: 'flex', alignItems: 'flex-end', gap: 3,
            overflowX: 'auto', paddingBottom: 4,
          }}>
            {dayBars.map(([date, events], i) => (
              <div
                key={date}
                title={`${date} · ${events.toLocaleString()} 次事件`}
                style={{
                  flexShrink: 0, width: 20,
                  display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4,
                }}
              >
                <div style={{
                  height: 110, width: '100%',
                  display: 'flex', alignItems: 'flex-end',
                }}>
                  <div style={{
                    width: '100%',
                    height: maxEvents > 0
                      ? `${Math.max((events / maxEvents) * 100, events > 0 ? 2 : 0)}%`
                      : 0,
                    background: 'var(--ms-accent)',
                    opacity: 0.85,
                    borderRadius: 3,
                    transition: 'height var(--ms-dur-mid) var(--ms-ease)',
                  }} />
                </div>
                <span style={{
                  height: 14, fontSize: 10, lineHeight: '14px',
                  color: 'var(--ms-ink-subtle)', whiteSpace: 'nowrap',
                }}>
                  {i % labelStep === 0 ? date.slice(5) : ''}
                </span>
              </div>
            ))}
          </div>
        </Panel>
      )}
    </div>
  );
}
