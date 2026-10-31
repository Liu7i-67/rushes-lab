/**
 * /settings 页「访问令牌」区(2026-10-30 MCP 素材服务 D2/D3/D15)。
 *
 * - 自助三端点仅 session 可调(PAT 一律 403,由后端逐路由守卫);
 * - 创建 / 列表 / 吊销;`?include_revoked=1` 展示已吊销与已过期历史行,
 *   URL 即状态(可刷新/分享链接回到同一视图);
 * - 明文只在创建成功弹窗出现一次;列表永远只有 token_prefix;
 * - 每账号活跃上限 5 个(后端 enforce;前端达到上限即禁用创建并给吊销引导)。
 */
import { Alert, App, Button, Empty, Popconfirm, Switch, Table, Tag, Tooltip } from 'antd';
import type { ColumnsType } from 'antd/es/table';
import dayjs from 'dayjs';
import { Plus, RefreshCw } from 'lucide-react';
import { useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { errorMessage } from '../../api/client';
import { useRevokeToken, useTokens } from '../../api/hooks';
import type { PatToken, PatTokenCreated } from '../../api/types';
import { useCompactViewport } from '../../lib/use-viewports';
import { CreateTokenModal } from './CreateTokenModal';
import { TokenCreatedModal } from './TokenCreatedModal';
import { PAT_STATUS_COLOR, PAT_STATUS_LABEL, patTokenStatus } from './token-status';

const MAX_ACTIVE_TOKENS = 5;
/** 历史行可能很多;活跃行 ≤5。超过一屏才启用分页。 */
const HISTORY_PAGE_SIZE = 20;

const fmtTime = (iso: string | null | undefined) =>
  iso ? dayjs(iso).format('YYYY-MM-DD HH:mm') : '—';

export function TokensSection() {
  const { message } = App.useApp();
  const compact = useCompactViewport();
  // ?include_revoked=1 = 含历史(已吊销 / 已过期);默认只回活跃行
  const [searchParams, setSearchParams] = useSearchParams();
  const includeRevoked = searchParams.get('include_revoked') === '1';

  const { data, isLoading, isFetching, isError, error, refetch } = useTokens(includeRevoked);
  const revoke = useRevokeToken();
  const [createOpen, setCreateOpen] = useState(false);
  const [created, setCreated] = useState<PatTokenCreated | null>(null);
  const [revokingId, setRevokingId] = useState<string | null>(null);

  const tokens = data ?? [];
  const activeCount = tokens.filter(t => patTokenStatus(t) === 'active').length;
  const full = activeCount >= MAX_ACTIVE_TOKENS;

  const setIncludeRevoked = (v: boolean) => {
    const next = new URLSearchParams(searchParams);
    if (v) next.set('include_revoked', '1');
    else next.delete('include_revoked');
    setSearchParams(next, { replace: true });
  };

  const doRevoke = async (t: PatToken) => {
    setRevokingId(t.id);
    try {
      await revoke.mutateAsync(t.id);
      message.success(`已吊销令牌「${t.name}」,下次调用立即失效`);
    } catch (e) {
      message.error(errorMessage(e, '吊销失败'));
    } finally {
      setRevokingId(null);
    }
  };

  const columns: ColumnsType<PatToken> = [
    {
      title: '名称',
      dataIndex: 'name',
      width: 170,
      render: (v: string) => (
        <span style={{ fontSize: 13, color: 'var(--ms-ink)', fontWeight: 500 }}>{v}</span>
      ),
    },
    {
      title: '令牌前缀',
      dataIndex: 'token_prefix',
      width: 200,
      render: (v: string) => (
        <Tooltip title="列表只显示前缀;完整令牌仅在创建成功时显示一次">
          <span className="ms-mono" style={{
            fontSize: 12.5, color: 'var(--ms-ink)',
            display: 'inline-block', maxWidth: '100%',
            overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
          }}>{v}…</span>
        </Tooltip>
      ),
    },
    {
      title: '创建时间',
      dataIndex: 'created_at',
      width: 150,
      render: (v: string) => <span style={{ fontSize: 12.5 }}>{fmtTime(v)}</span>,
    },
    {
      title: '最后使用',
      dataIndex: 'last_used_at',
      width: 150,
      render: (v: string | null) => (
        <span style={{ fontSize: 12.5, color: v ? 'var(--ms-ink)' : 'var(--ms-ink-subtle)' }}>
          {v ? fmtTime(v) : '从未使用'}
        </span>
      ),
    },
    {
      title: '过期时间',
      dataIndex: 'expires_at',
      width: 150,
      render: (v: string) => <span style={{ fontSize: 12.5 }}>{fmtTime(v)}</span>,
    },
    {
      title: '状态',
      key: 'status',
      width: 120,
      render: (_v, row) => {
        const status = patTokenStatus(row);
        return (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 3, alignItems: 'flex-start' }}>
            <Tag color={PAT_STATUS_COLOR[status]} style={{ marginInlineEnd: 0 }}>
              {PAT_STATUS_LABEL[status]}
            </Tag>
            {status === 'revoked' && row.revoked_at && (
              <span style={{ fontSize: 11, color: 'var(--ms-ink-subtle)' }}>
                {fmtTime(row.revoked_at)} 吊销
              </span>
            )}
          </div>
        );
      },
    },
    {
      title: '操作',
      key: 'action',
      width: 90,
      render: (_v, row) => {
        if (patTokenStatus(row) !== 'active') {
          return <span style={{ fontSize: 11.5, color: 'var(--ms-ink-subtle)' }}>—</span>;
        }
        return (
          <Popconfirm
            title={`吊销令牌「${row.name}」?`}
            description="吊销后立即失效且不可恢复;正在使用该令牌的 MCP 客户端会立刻收到 401。"
            okText="确认吊销"
            cancelText="取消"
            okButtonProps={{ danger: true }}
            onConfirm={() => doRevoke(row)}
          >
            <Button size="small" danger loading={revokingId === row.id}>吊销</Button>
          </Popconfirm>
        );
      },
    },
  ];

  return (
    <section style={{
      background: 'var(--ms-surface)',
      border: '1px solid var(--ms-hairline)',
      borderRadius: 'var(--ms-radius-md)',
      padding: '16px 20px',
    }}>
      <div style={{
        display: 'flex', alignItems: 'center', gap: 12,
        flexWrap: 'wrap', marginBottom: 12,
      }}>
        <h2 style={{ margin: 0, fontSize: 15, fontWeight: 500, color: 'var(--ms-ink)' }}>
          访问令牌
        </h2>
        <span style={{ fontSize: 12.5, color: 'var(--ms-ink-muted)' }}>
          活跃 <span className="ms-mono">{activeCount}</span> / {MAX_ACTIVE_TOKENS}
        </span>
        {full && (
          <span style={{ fontSize: 12, color: 'var(--ms-amber)' }}>
            已达上限,请先吊销不再使用的令牌
          </span>
        )}
        <div style={{ flex: 1 }} />
        <span style={{
          display: 'inline-flex', alignItems: 'center', gap: 6,
          fontSize: 12.5, color: 'var(--ms-ink-muted)',
        }}>
          <Switch size="small" checked={includeRevoked} onChange={setIncludeRevoked} />
          显示已吊销 / 已过期
        </span>
        <Button
          icon={<RefreshCw size={13} strokeWidth={2} />}
          loading={isFetching && !isLoading}
          onClick={() => refetch()}
        >
          刷新
        </Button>
        <Button
          type="primary"
          icon={<Plus size={14} strokeWidth={2} />}
          disabled={full}
          onClick={() => setCreateOpen(true)}
        >
          创建令牌
        </Button>
      </div>

      {/* D15 强制文案:创建/管理页都必须明示账号级全权限 + 内网明文 http 风险 */}
      <Alert
        type="warning"
        showIcon
        style={{ marginBottom: 16 }}
        message="令牌=账号级全权限凭证,等同你的密码;内网入口为明文 http,勿配置到不可信机器"
        description="持有令牌即可调用本账号可访问的全部 API(含上传与下载),请勿粘贴到聊天工具、截图或代码仓库。怀疑泄露时立即吊销,并修改密码(改密会自动吊销该账号全部令牌)。"
      />

      {isError && !data ? (
        <Alert
          type="error"
          showIcon
          message="令牌列表加载失败"
          description={errorMessage(error, '请稍后重试')}
          action={<Button size="small" onClick={() => refetch()}>重试</Button>}
        />
      ) : (
        <Table<PatToken>
          rowKey="id"
          columns={columns}
          dataSource={tokens}
          loading={isFetching}
          scroll={compact ? { x: 'max-content' } : undefined}
          pagination={tokens.length > HISTORY_PAGE_SIZE ? {
            pageSize: HISTORY_PAGE_SIZE,
            hideOnSinglePage: true,
            showSizeChanger: false,
          } : false}
          locale={{
            emptyText: (
              <Empty
                image={Empty.PRESENTED_IMAGE_SIMPLE}
                description={(
                  <span style={{ color: 'var(--ms-ink-subtle)' }}>
                    {includeRevoked ? '暂无任何令牌(含历史)' : '暂无活跃令牌'}
                  </span>
                )}
              />
            ),
          }}
        />
      )}

      <p style={{ margin: '12px 0 0', fontSize: 12, color: 'var(--ms-ink-subtle)', lineHeight: 1.7 }}>
        完整令牌仅在创建成功弹窗显示一次(响应带 Cache-Control: no-store,浏览器不缓存),
        列表只显示前缀用于识别。令牌过期或吊销后立即不可用;每账号最多 {MAX_ACTIVE_TOKENS} 个活跃令牌。
      </p>

      <CreateTokenModal
        open={createOpen}
        onClose={() => setCreateOpen(false)}
        activeCount={activeCount}
        onCreated={(t) => {
          setCreateOpen(false);
          setCreated(t);
        }}
      />
      <TokenCreatedModal token={created} onClose={() => setCreated(null)} />
    </section>
  );
}
