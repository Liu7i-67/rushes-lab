/**
 * MCP 实时指标卡片(/admin/mcp-settings)。
 *
 * 数据来自 GET /admin/mcp-settings 的附带回显字段(D5/D11),不新增端点:
 * - in_flight = ZCOUNT mcp:conc:global now +inf(与并发闸判定同口径);
 * - today_success / today_rejected_policy / today_rejected_quota = Redis
 *   `mcp:stats:*:{UTC yyyyMMdd}` —— **UTC 日**,与使用统计页(北京时间日)
 *   口径不同,必须在页面明示;
 * - rejected_infra_since_start / dynamic_signers_cap_hits 为进程内计数,重启清零;
 * - 指标读取失败时字段为 null:显示占位而非报错,配置体仍可正常读写。
 */
import { Alert, Tooltip } from 'antd';
import type { McpSettingsOut } from '../../../api/types';

const NULL_HINT = '指标读取失败或暂不可用(Redis / 计数异常);配置读写不受影响';

function MetricCard({ label, value, sub, danger = false }: {
  label: string;
  value: number | null;
  sub: string;
  danger?: boolean;
}) {
  const missing = value == null;
  const text = missing ? '—' : value.toLocaleString();
  return (
    <div style={{
      flex: '1 1 180px', minWidth: 168,
      background: 'var(--ms-surface)',
      border: '1px solid var(--ms-hairline)',
      borderRadius: 'var(--ms-radius-md)',
      padding: '12px 16px',
    }}>
      <div style={{ fontSize: 11.5, color: 'var(--ms-ink-subtle)' }}>{label}</div>
      <div style={{
        marginTop: 4, fontSize: 20, fontWeight: 500,
        color: danger ? 'var(--ms-crimson)' : missing ? 'var(--ms-ink-subtle)' : 'var(--ms-ink)',
        fontVariantNumeric: 'tabular-nums', lineHeight: 1.3,
      }}>
        {missing ? <Tooltip title={NULL_HINT}>{text}</Tooltip> : text}
      </div>
      <div style={{ marginTop: 2, fontSize: 11, color: 'var(--ms-ink-subtle)' }}>{sub}</div>
    </div>
  );
}

export function McpMetricsCard({ settings }: { settings: McpSettingsOut }) {
  const capHits = settings.dynamic_signers_cap_hits;
  return (
    <section style={{
      background: 'var(--ms-surface)',
      border: '1px solid var(--ms-hairline)',
      borderRadius: 'var(--ms-radius-md)',
      padding: '16px 20px',
    }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 12, flexWrap: 'wrap' }}>
        <h2 style={{ margin: 0, fontSize: 15, fontWeight: 500, color: 'var(--ms-ink)' }}>
          实时指标
        </h2>
        <span style={{ fontSize: 11.5, color: 'var(--ms-ink-subtle)' }}>
          今日计数按 <strong>UTC 日</strong>,使用统计页为北京时间日(两者口径不同);
          点页头「刷新」读取最新值
        </span>
      </div>

      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginTop: 14 }}>
        <MetricCard
          label="在途并发"
          value={settings.in_flight}
          sub="ZCOUNT mcp:conc:global(与闸判定同口径)"
        />
        <MetricCard
          label="今日成功请求"
          value={settings.today_success}
          sub="PAT 请求 2xx · UTC 日"
        />
        <MetricCard
          label="今日拒绝(策略类)"
          value={settings.today_rejected_policy}
          sub="通道关闭 / 令牌禁用端点 / 强制改密 · UTC 日"
        />
        <MetricCard
          label="今日拒绝(配额类)"
          value={settings.today_rejected_quota}
          sub="IP 桶 / 每令牌 RPM / 并发闸 · UTC 日"
        />
        <MetricCard
          label="基础设施拒绝(进程内)"
          value={settings.rejected_infra_since_start}
          sub="配置读不到 / Redis 故障 · 重启清零"
        />
        <MetricCard
          label="动态签名回落次数"
          value={capHits}
          sub="预签名缓存打满回落静态地址 · 进程内"
          danger={typeof capHits === 'number' && capHits > 0}
        />
      </div>

      {typeof capHits === 'number' && capHits > 0 && (
        <Alert
          type="error"
          showIcon
          style={{ marginTop: 12 }}
          message={`动态预签名缓存打满过 ${capHits} 次,已回落静态 MINIO_ENDPOINT_PUBLIC(进程内累计)`}
          description="新入口将拿到静态地址签出的 URL。请核对 prod .env 的 MINIO_ENDPOINT_PUBLIC 是否指向客户端可达入口,并检查 ms-mcp 的 Host 白名单是否漏配入口拼法(漏配会放大动态 signer 占用)。"
        />
      )}
    </section>
  );
}
