/**
 * /admin/risk — 登录风控页(风控模块 2026-10-28;正本
 * rushes-spec/material-storage/risk-control-module-plan.md §4.2)。
 *
 * 当前登录锁定快照(拉取式,非实时):
 * - 被锁账号表:登录名形态(form,mono)/ 账号匹配(unique → 姓名+登录名,username
 *   为 null 的老飞书用户只显示姓名;none → 灰字「未匹配账号」;ambiguous → 橙字
 *   「重名歧义」+ Tooltip 命中名单)/ 当前窗口失败次数(滚动窗口,非累计)/
 *   剩余时间(mm:ss 静态换算,D2 不做倒计时)/ 操作;
 * - 被锁 IP 表:IP(unknown 哨兵标注「链路异常」,如实展示不静默过滤,可解)/
 *   失败次数 / 剩余时间 / 近 24h 失败用户名(小 tag,超 5 个折叠 + Tooltip)/ 操作;
 * - 账号解锁复用既有 useUnlockUser(W1 端点,连带清近 24h 失败来源 IP 锁行为保留);
 *   hook 的 onSuccess 只 invalidate ['directory-users'] 且不带 toast —— 页面在
 *   mutateAsync 返回后**自行 invalidate ['risk-locks'] 并自行 toast**(文案照
 *   AdminUsersPage 既有格式);none / ambiguous 无 user_id 锚点不提供解锁(D4),
 *   给引导文案;
 * - IP 解锁走新端点 useUnlockIp(hook 成功即 invalidate ['risk-locks'],toast 归页面)。
 * 刷新口径(D1):项目 QueryClient 全局 refetchOnWindowFocus: false,不开轮询、
 * 不开聚焦刷新,列表更新只靠挂载拉取 + 手动「刷新」按钮;锁 15 分钟自动过期。
 * 非 admin 兜底照 AdminUsageStatsPage 双层:先 me 层 Alert,后端 403 走全局
 * queryCache 静默 + 页面空态。
 */
import { Alert, App, Button, Empty, Popconfirm, Skeleton, Table, Tag, Tooltip } from 'antd';
import type { ColumnsType } from 'antd/es/table';
import { useQueryClient } from '@tanstack/react-query';
import { LockOpen, RefreshCw, ShieldOff } from 'lucide-react';
import { useState, type CSSProperties } from 'react';
import { useMe, useRiskLocks, useUnlockIp, useUnlockUser } from '../api/hooks';
import { errorMessage } from '../api/client';
import type { RiskIpLock, RiskUserLock } from '../api/types';
import { useCompactViewport } from '../lib/use-viewports';

/** 剩余秒 → mm:ss(渲染时刻静态换算,快照语义,不倒计时 —— D2)。 */
const fmtTtl = (s: number) =>
  `${String(Math.floor(Math.max(s, 0) / 60)).padStart(2, '0')}:${String(Math.max(s, 0) % 60).padStart(2, '0')}`;

const numStyle: CSSProperties = {
  fontSize: 12.5, color: 'var(--ms-ink)', fontVariantNumeric: 'tabular-nums',
};

const sectionTitleStyle: CSSProperties = {
  margin: '24px 0 10px', fontSize: 15, fontWeight: 500, color: 'var(--ms-ink)',
};

export default function AdminRiskPage() {
  const { data: me } = useMe();
  const { data, isLoading, isFetching, refetch } = useRiskLocks();
  // 账号解锁复用 W1 既有 hook(不带 toast;onSuccess 只失效 ['directory-users']),
  // 风控快照由页面自行失效;IP 解锁 hook 成功自带失效
  const unlock = useUnlockUser();
  const unlockIp = useUnlockIp();
  const qc = useQueryClient();
  const { message } = App.useApp();
  const compact = useCompactViewport();
  // 行级 busy(以 form / ip 为键;快照行数极小,单 state 足够)
  const [busy, setBusy] = useState<string | null>(null);

  // unique 行解锁:先走既有端点,成功后自行失效 ['risk-locks'] 并 toast
  // (文案照 AdminUsersPage:192-194 既有格式)
  const doUnlockUser = async (row: RiskUserLock) => {
    const target = row.matched_users[0];
    if (!target) return;
    setBusy(row.form);
    try {
      const out = await unlock.mutateAsync(target.id);
      await qc.invalidateQueries({ queryKey: ['risk-locks'] });
      message.success(out.was_locked
        ? `已解锁 ${target.name}(清 ${out.cleared_user_forms.length} 个登录名形态 / ${out.cleared_ips.length} 个 IP 锁)`
        : `${target.name} 当前无用户名维度登录锁,已顺手清理失败计数`);
    } catch (e) {
      message.error(errorMessage(e, '解锁失败'));
    } finally { setBusy(null); }
  };

  const doUnlockIp = async (ip: string) => {
    setBusy(ip);
    try {
      const out = await unlockIp.mutateAsync(ip);
      message.success(out.was_locked
        ? `已解除 ${ip === 'unknown' ? '未知 IP' : ip} 的登录锁定`
        : `${ip} 当前无 IP 登录锁(可能已自然过期)`);
    } catch (e) {
      message.error(errorMessage(e, '解除失败'));
    } finally { setBusy(null); }
  };

  // 非 admin 体验守卫(后端仍 enforce;me 未就绪时不拦,交给后端 403 → 全局静默 + 空态)
  if (me && !me.is_system_admin) {
    return (
      <div className="ms-enter" style={{ maxWidth: 520 }}>
        <Alert
          type="warning" showIcon
          message="只有系统管理员可以查看登录风控"
          description="如需解锁账号或解除 IP 登录锁定,请联系系统管理员。"
        />
      </div>
    );
  }

  const users = data?.users ?? [];
  const ips = data?.ips ?? [];
  const allEmpty = !!data && users.length === 0 && ips.length === 0;

  const userColumns: ColumnsType<RiskUserLock> = [
    {
      title: '登录名形态',
      dataIndex: 'form',
      width: 170,
      render: (v: string) => (
        <Tooltip title={v} placement="topLeft">
          <span className="ms-mono" style={{
            fontSize: 12.5, color: 'var(--ms-ink)',
            display: 'inline-block', maxWidth: '100%',
            overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
          }}>{v}</span>
        </Tooltip>
      ),
    },
    {
      title: '账号',
      key: 'match',
      width: 190,
      render: (_v, row) => {
        if (row.match === 'unique') {
          const u = row.matched_users[0];
          // unique 但 matched_users 空属契约外异常,按未匹配灰显兜底(不渲染空行)
          if (!u) {
            return <span style={{ fontSize: 12.5, color: 'var(--ms-ink-subtle)' }}>未匹配账号</span>;
          }
          return (
            <div style={{ minWidth: 0 }}>
              <div style={{ fontSize: 13, color: 'var(--ms-ink)' }}>{u.name}</div>
              {/* username 可空(老飞书用户无本地登录名):null 时只显示姓名 */}
              {u.username && (
                <div className="ms-mono" style={{
                  fontSize: 11, color: 'var(--ms-ink-subtle)',
                  overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
                }}>{u.username}</div>
              )}
            </div>
          );
        }
        if (row.match === 'ambiguous') {
          // name 重名歧义:批量反查口径刻意保守(登录语义可能 unique),不给解锁防误伤
          const names = row.matched_users
            .map(u => (u.username ? `${u.name}(${u.username})` : u.name))
            .join('、');
          return (
            <Tooltip title={`命中 ${row.matched_users.length} 个账号:${names}`}>
              <span style={{ fontSize: 12.5, color: 'var(--ms-amber)' }}>重名歧义</span>
            </Tooltip>
          );
        }
        return <span style={{ fontSize: 12.5, color: 'var(--ms-ink-subtle)' }}>未匹配账号</span>;
      },
    },
    {
      title: '当前窗口失败次数',
      dataIndex: 'fail_count',
      width: 140,
      render: (v: number) => <span style={numStyle}>{v}</span>,
    },
    {
      title: '剩余时间',
      dataIndex: 'lock_ttl_seconds',
      width: 90,
      render: (v: number) => <span style={numStyle}>{fmtTtl(v)}</span>,
    },
    {
      title: '操作',
      key: 'action',
      width: 230,
      render: (_v, row) => {
        if (row.match !== 'unique') {
          // none / ambiguous 无 user_id 锚点,走不了既有账号解锁端点(D4);引导解 IP
          return (
            <span style={{ fontSize: 11.5, color: 'var(--ms-ink-subtle)' }}>
              该锁定无对应账号,可解除相关 IP 锁
            </span>
          );
        }
        const target = row.matched_users[0];
        return (
          <Popconfirm
            title={`解锁 ${target?.name ?? row.form} 的登录锁定?`}
            description="清除用户名维度锁定与失败计数,并连带清近 24h 失败 IP 的锁;完成后即可重新登录。"
            okText="解锁" cancelText="取消"
            onConfirm={() => doUnlockUser(row)}
          >
            <Button size="small" icon={<LockOpen size={12} strokeWidth={2} />}
                    loading={busy === row.form}>
              解锁
            </Button>
          </Popconfirm>
        );
      },
    },
  ];

  const ipColumns: ColumnsType<RiskIpLock> = [
    {
      title: 'IP',
      dataIndex: 'ip',
      width: 220,
      render: (v: string) => (
        <div style={{ display: 'flex', alignItems: 'center', gap: 6, minWidth: 0 }}>
          <span className="ms-mono" style={{ fontSize: 12.5, color: 'var(--ms-ink)' }}>{v}</span>
          {/* 哨兵 IP:登录链路 request_ip 缺失回落 unknown,如实展示但标注(§3.1) */}
          {v === 'unknown' && (
            <Tooltip title="未知 IP(链路异常,IP 缺失)">
              <Tag color="warning" style={{ marginInlineEnd: 0 }}>链路异常</Tag>
            </Tooltip>
          )}
        </div>
      ),
    },
    {
      title: '当前窗口失败次数',
      dataIndex: 'fail_count',
      width: 140,
      render: (v: number) => <span style={numStyle}>{v}</span>,
    },
    {
      title: '剩余时间',
      dataIndex: 'lock_ttl_seconds',
      width: 90,
      render: (v: number) => <span style={numStyle}>{fmtTtl(v)}</span>,
    },
    {
      title: '近 24h 失败用户名',
      dataIndex: 'recent_failed_userforms',
      render: (forms: string[]) => {
        if (!forms || forms.length === 0) {
          return <span style={{ fontSize: 12, color: 'var(--ms-ink-subtle)' }}>—</span>;
        }
        const shown = forms.slice(0, 5);
        const rest = forms.slice(5);
        return (
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
            {shown.map(f => (
              <Tag key={f} className="ms-mono"
                   style={{ fontSize: 11, marginInlineEnd: 0, maxWidth: 160 }}>
                {f}
              </Tag>
            ))}
            {rest.length > 0 && (
              <Tooltip title={rest.join('、')}>
                <Tag style={{ fontSize: 11, marginInlineEnd: 0 }}>+{rest.length}</Tag>
              </Tooltip>
            )}
          </div>
        );
      },
    },
    {
      title: '操作',
      key: 'action',
      width: 120,
      render: (_v, row) => (
        <Popconfirm
          title={`解除 ${row.ip === 'unknown' ? '未知 IP' : row.ip} 的登录锁定?`}
          description="清除该 IP 的锁定与失败计数;锁定期间该 IP 的本地登录将被拦截。"
          okText="解除锁定" cancelText="取消"
          onConfirm={() => doUnlockIp(row.ip)}
        >
          <Button size="small" icon={<ShieldOff size={12} strokeWidth={2} />}
                  loading={busy === row.ip}>
            解除锁定
          </Button>
        </Popconfirm>
      ),
    },
  ];

  return (
    <div className="ms-enter">
      {/* 页头(照 AdminAuditPage / AdminUsageStatsPage 惯例)+ 刷新按钮(必要交互) */}
      <div style={{
        display: 'flex', alignItems: 'baseline', justifyContent: 'space-between',
        gap: 24, marginBottom: 'var(--ms-sp-xl)',
      }}>
        <div>
          <h1 style={{
            margin: 0, fontFamily: 'var(--ms-font-display)',
            fontSize: 32, fontWeight: 500, letterSpacing: '-0.02em',
            color: 'var(--ms-ink)', lineHeight: 1.1,
          }}>登录风控</h1>
          <p style={{ margin: '8px 0 0', fontSize: 13, color: 'var(--ms-ink-muted)' }}>
            当前被锁账号与被锁 IP 快照 — 剩余时间为打开时刻的静态值,锁定 15 分钟自动过期;
            不自动刷新,处置后点「刷新」看最新
          </p>
        </div>
        <Button icon={<RefreshCw size={14} strokeWidth={2} />}
                loading={isFetching} onClick={() => refetch()}>
          刷新
        </Button>
      </div>

      {isLoading ? (
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
      ) : allEmpty ? (
        <Empty
          image={Empty.PRESENTED_IMAGE_SIMPLE}
          description={(
            <span style={{ color: 'var(--ms-ink-subtle)' }}>当前无任何登录锁定</span>
          )}
          style={{ marginTop: 80 }}
        />
      ) : (
        <>
          <h2 style={sectionTitleStyle}>被锁账号({users.length})</h2>
          <Table<RiskUserLock>
            rowKey="form"
            columns={userColumns}
            dataSource={users}
            loading={isFetching}
            scroll={compact ? { x: 'max-content' } : undefined}
            pagination={false}
            locale={{ emptyText: '当前无被锁账号' }}
          />
          <h2 style={sectionTitleStyle}>被锁 IP({ips.length})</h2>
          <Table<RiskIpLock>
            rowKey="ip"
            columns={ipColumns}
            dataSource={ips}
            loading={isFetching}
            scroll={compact ? { x: 'max-content' } : undefined}
            pagination={false}
            locale={{ emptyText: '当前无被锁 IP' }}
          />
        </>
      )}
    </div>
  );
}
