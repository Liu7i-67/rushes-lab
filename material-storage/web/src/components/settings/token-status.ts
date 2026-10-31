/**
 * 访问令牌展示态 — `/settings` 与 `/admin/mcp-settings` 两处列表共用。
 *
 * 后端没有 status 列:吊销看 revoked_at;过期优先用后端响应期派生列
 * `expired`(TokenOut.expired),缺失时按 expires_at 与当前时刻自行派生。
 * 口径与后端活跃定义一致:`revoked_at IS NULL AND expires_at > now()`。
 */
import type { PatToken } from '../../api/types';

export type PatTokenStatus = 'active' | 'revoked' | 'expired';

export function patTokenStatus(
  t: Pick<PatToken, 'revoked_at' | 'expires_at'> & { expired?: boolean },
): PatTokenStatus {
  if (t.revoked_at) return 'revoked';
  if (typeof t.expired === 'boolean') return t.expired ? 'expired' : 'active';
  return new Date(t.expires_at).getTime() <= Date.now() ? 'expired' : 'active';
}

export const PAT_STATUS_LABEL: Record<PatTokenStatus, string> = {
  active: '有效',
  revoked: '已吊销',
  expired: '已过期',
};

/** antd Tag 色:有效绿;过期红;吊销灰(历史行)。 */
export const PAT_STATUS_COLOR: Record<PatTokenStatus, string> = {
  active: 'green',
  revoked: 'default',
  expired: 'red',
};
