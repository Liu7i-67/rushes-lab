/**
 * 全部用户令牌表(/admin/mcp-settings;GET/DELETE /api/v1/admin/tokens)。
 *
 * - require_system_admin(后端 enforce;页面入口仅系统管理员可见);
 * - limit/offset 分页(页大小 50,后端 limit ≤500;排序由后端固定
 *   created_at DESC, id DESC);
 * - 只展示前缀与元数据,**任何界面不展示令牌明文 / token_hash**;
 * - 管理员吊销任意令牌(二次确认);吊销后对方下一次调用立即 401。
 */
import { Alert, App, Button, Empty, Popconfirm, Table, Tag, Tooltip } from 'antd';
import type { ColumnsType } from 'antd/es/table';
import dayjs from 'dayjs';
import { RefreshCw } from 'lucide-react';
import { useMemo, useState } from 'react';
import { errorMessage } from '../../../api/client';
import {
  ADMIN_TOKENS_PAGE_SIZE,
  useAdminRevokeToken,
  useAdminTokens,
} from '../../../api/hooks';
import type { AdminPatToken } from '../../../api/types';
import { useCompactViewport } from '../../../lib/use-viewports';
import { PAT_STATUS_COLOR, PAT_STATUS_LABEL, patTokenStatus } from '../../settings/token-status';

const fmtTime = (iso: string | null | undefined) =>
  iso ? dayjs(iso).format('YYYY-MM-DD HH:mm') : '—';

const userLabel = (t: AdminPatToken) =>
  t.user_name || t.username || `用户 ${t.user_id.slice(0, 8)}`;

export function AdminTokensTable() {
  const compact = useCompactViewport();
  const { message } = App.useApp();
  const [page, setPage] = useState(1);
  const params = useMemo(
    () => ({ limit: ADMIN_TOKENS_PAGE_SIZE, offset: (page - 1) * ADMIN_TOKENS_PAGE_SIZE }),
    [page],
  );
  const { data, isLoading, isFetching, isError, error, refetch } = useAdminTokens(params);
  const revoke = useAdminRevokeToken();
  const [revokingId, setRevokingId] = useState<string | null>(null);

  const items = data?.items ?? [];
  const total = data?.total;
  // 后端若回裸数组(无 total):满页时才给「下一页」,末页不足一页即止
  const effectiveTotal = total
    ?? (page - 1) * ADMIN_TOKENS_PAGE_SIZE + items.length
       + (items.length === ADMIN_TOKENS_PAGE_SIZE ? 1 : 0);

  const doRevoke = async (t: AdminPatToken) => {
    setRevokingId(t.id);
    try {
      await revoke.mutateAsync(t.id);
      message.success(`已吊销 ${userLabel(t)} 的令牌「${t.name}」,下次调用立即失效`);
      // 吊销后当前页可能空掉:回退一页(失效已由 hook 触发,翻页再取新窗口)
      if (items.length === 1 && page > 1) setPage(p => p - 1);
    } catch (e) {
      message.error(errorMessage(e, '吊销失败'));
    } finally {
      setRevokingId(null);
    }
  };

  const columns: ColumnsType<AdminPatToken> = [
    {
      title: '用户',
      key: 'user',
      width: 190,
      render: (_v, row) => (
        <div style={{ minWidth: 0 }}>
          <div style={{ fontSize: 13, color: 'var(--ms-ink)' }}>{userLabel(row)}</div>
          <Tooltip title={`user_id: ${row.user_id}`}>
            <div className="ms-mono" style={{
              fontSize: 11, color: 'var(--ms-ink-subtle)',
              overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
            }}>
              {row.username || row.user_id}
            </div>
          </Tooltip>
        </div>
      ),
    },
    {
      title: '令牌名称',
      dataIndex: 'name',
      width: 150,
      render: (v: string) => <span style={{ fontSize: 13, color: 'var(--ms-ink)' }}>{v}</span>,
    },
    {
      title: '前缀',
      dataIndex: 'token_prefix',
      width: 190,
      render: (v: string) => (
        <Tooltip title="列表只显示前缀;明文只在创建者本人的创建弹窗出现一次">
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
            title={`吊销 ${userLabel(row)} 的令牌「${row.name}」?`}
            description="吊销后立即失效且不可恢复;对方下一次 MCP 调用会收到 401。"
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
        display: 'flex', alignItems: 'flex-start', gap: 12,
        flexWrap: 'wrap', marginBottom: 12,
      }}>
        <div style={{ flex: 1, minWidth: 220 }}>
          <h2 style={{ margin: 0, fontSize: 15, fontWeight: 500, color: 'var(--ms-ink)' }}>
            全部用户令牌
          </h2>
          <p style={{ margin: '4px 0 0', fontSize: 11.5, color: 'var(--ms-ink-subtle)' }}>
            所有账号的访问令牌(仅前缀与元数据,不展示明文 / 哈希);按创建时间倒序
          </p>
        </div>
        <Button
          icon={<RefreshCw size={13} strokeWidth={2} />}
          loading={isFetching && !isLoading}
          onClick={() => refetch()}
        >
          刷新
        </Button>
      </div>

      {isError ? (
        <Alert
          type="error"
          showIcon
          message="令牌列表加载失败"
          description={errorMessage(error, '请稍后重试')}
          action={<Button size="small" onClick={() => refetch()}>重试</Button>}
        />
      ) : (
        <Table<AdminPatToken>
          rowKey="id"
          columns={columns}
          dataSource={items}
          loading={isFetching}
          scroll={compact ? { x: 'max-content' } : undefined}
          pagination={{
            current: page,
            pageSize: ADMIN_TOKENS_PAGE_SIZE,
            total: effectiveTotal,
            showSizeChanger: false,
            showTotal: total !== undefined ? (t) => `共 ${t} 条` : undefined,
            onChange: setPage,
          }}
          locale={{
            emptyText: (
              <Empty
                image={Empty.PRESENTED_IMAGE_SIMPLE}
                description={<span style={{ color: 'var(--ms-ink-subtle)' }}>暂无令牌</span>}
              />
            ),
          }}
        />
      )}
    </section>
  );
}
