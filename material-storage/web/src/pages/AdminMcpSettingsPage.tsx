/**
 * /admin/mcp-settings — MCP 素材服务管理页(2026-10-30 方案 B 节 / D5 / D6 / D11)。
 *
 * 三块:
 * 1. 通道与配额(开关 + 四个滑杆;PUT /admin/mcp-settings,跨字段校验前后端同款);
 * 2. 实时指标(在途并发 / 今日成功 / 今日拒绝分列 / infra / signer 回落;
 *    今日计数为 UTC 日,使用统计页为北京时间日);
 * 3. 全部用户令牌(分页 + 管理员吊销)。
 *
 * 门禁:require_system_admin(后端 enforce);非系统管理员先用 me 做体验提示,
 * 页面不发数据请求(useMcpSettings 以 is_system_admin 为 enabled)。
 * 刷新口径:项目全局 refetchOnWindowFocus=false,指标不自动轮询(避免定时
 * 重取把正在编辑的滑杆回填掉);页头「刷新」手动读取最新配置 + 指标。
 */
import { Alert, Button, Skeleton } from 'antd';
import { RefreshCw } from 'lucide-react';
import { errorMessage } from '../api/client';
import { useMcpSettings, useMe } from '../api/hooks';
import { McpConfigCard } from '../components/admin/mcp/McpConfigCard';
import { McpMetricsCard } from '../components/admin/mcp/McpMetricsCard';
import { AdminTokensTable } from '../components/admin/mcp/AdminTokensTable';

export default function AdminMcpSettingsPage() {
  const { data: me } = useMe();
  const isAdmin = !!me?.is_system_admin;
  const { data, isLoading, isFetching, isError, error, refetch } = useMcpSettings(isAdmin);

  // 非系统管理员体验守卫(后端仍 enforce;isAdmin=false 时查询保持禁用,不发起 403 请求)
  if (me && !me.is_system_admin) {
    return (
      <div className="ms-enter" style={{ maxWidth: 560 }}>
        <Alert
          type="warning"
          showIcon
          message="只有系统管理员可以管理 MCP 设置"
          description="通道开关 / 配额与全部用户令牌属于系统级配置,如需调整请联系系统管理员。"
        />
      </div>
    );
  }

  return (
    <div className="ms-enter">
      {/* 页头(照 AdminRiskPage / AdminUsageStatsPage 惯例)+ 刷新 */}
      <div style={{
        display: 'flex', alignItems: 'baseline', justifyContent: 'space-between',
        gap: 24, marginBottom: 'var(--ms-sp-xl)',
      }}>
        <div>
          <h1 style={{
            margin: 0, fontFamily: 'var(--ms-font-display)',
            fontSize: 32, fontWeight: 500, letterSpacing: '-0.02em',
            color: 'var(--ms-ink)', lineHeight: 1.1,
          }}>MCP 设置</h1>
          <p style={{ margin: '8px 0 0', fontSize: 13, color: 'var(--ms-ink-muted)' }}>
            MCP 素材服务 — 通道开关 / 配额(仅作用于令牌请求)/ 实时指标 / 全部用户令牌
          </p>
        </div>
        <Button
          icon={<RefreshCw size={14} strokeWidth={2} />}
          loading={isFetching && !isLoading}
          onClick={() => refetch()}
        >
          刷新
        </Button>
      </div>

      {isLoading || (!data && !isError) ? (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          {[0, 1].map(i => (
            <div key={i} style={{
              padding: '16px 20px', background: 'var(--ms-surface)',
              border: '1px solid var(--ms-hairline)', borderRadius: 'var(--ms-radius-md)',
            }}>
              <Skeleton active title={{ width: '30%' }} paragraph={{ rows: 2 }} />
            </div>
          ))}
        </div>
      ) : isError && !data ? (
        <Alert
          type="error"
          showIcon
          message="MCP 设置加载失败"
          description={errorMessage(error, '请稍后重试')}
          action={<Button size="small" onClick={() => refetch()}>重试</Button>}
        />
      ) : data ? (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
          <McpConfigCard settings={data} />
          <McpMetricsCard settings={data} />
          <AdminTokensTable />
        </div>
      ) : null}
    </div>
  );
}
