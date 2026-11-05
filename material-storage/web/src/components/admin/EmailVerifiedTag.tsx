/* eslint-disable react-refresh/only-export-components --
   页面私有共享件:StatusPill / EmailVerifiedTag / EmailFieldLabel(组件)与
   changedEmail(纯函数)按设计收拢同一文件(先例:components/admin/usage_shared.tsx),
   拆分反而增加文件数;代价仅为本文件改动时 HMR 全量刷新,可接受。 */

/**
 * 邮箱账号方案(§5.3.5/§6.4)前端共享件 — 自 AdminUsersPage 原样搬出(纯搬家,零行为变化):
 *
 * - StatusPill:用户行状态 pill 组(启用/停用、待改密、登录已锁定、邮箱验证态);
 * - EmailVerifiedTag:邮箱验证状态 pill(列表行与编辑弹窗 label 共用);
 * - EmailFieldLabel:编辑弹窗「邮箱」字段 label(字段名 + 详情侧验证态 Tag);
 * - changedEmail:编辑提交的 email 脏检查 —— 未改动返回 undefined(不发送 email 键)。
 */
import { Tooltip } from 'antd';

export function StatusPill({ active, mustChange, loginLocked, emailVerified, hasEmail }: {
  active: boolean; mustChange: boolean; loginLocked?: boolean;
  emailVerified?: boolean; hasEmail: boolean;
}) {
  return (
    <>
      <span style={{
        fontFamily: 'var(--ms-font-mono)', fontSize: 10.5,
        fontWeight: 500, padding: '1px 7px', borderRadius: 3,
        color: active ? 'var(--ms-emerald)' : 'var(--ms-crimson)',
        background: active ? 'var(--ms-emerald)14' : 'var(--ms-crimson)14',
      }}>
        {active ? '启用' : '停用'}
      </span>
      {mustChange && (
        <span style={{
          fontFamily: 'var(--ms-font-mono)', fontSize: 10.5,
          fontWeight: 500, padding: '1px 7px', borderRadius: 3,
          color: 'var(--ms-amber)', background: 'var(--ms-amber)14',
        }}>
          待改密
        </span>
      )}
      {/* W1: 登录已锁定 — 只反映 user 维度(IP 维度锁不在此列,命中时登录仍 429),
          tooltip 明示口径;可用行内「解锁」立即清除 */}
      {loginLocked && (
        <Tooltip title="连续登录失败触发锁定(用户名维度;IP 维度锁不在此列)。可用「解锁」立即清除。">
          <span style={{
            fontFamily: 'var(--ms-font-mono)', fontSize: 10.5,
            fontWeight: 500, padding: '1px 7px', borderRadius: 3,
            color: 'var(--ms-crimson)', background: 'var(--ms-crimson)14',
          }}>
            登录已锁定
          </span>
        </Tooltip>
      )}
      {/* 邮箱账号方案 §6.4:email_verified Tag(仅在有邮箱时渲染;旧后端无此字段
          回落 false,排查「为什么用户说没验证」) */}
      {hasEmail && <EmailVerifiedTag verified={emailVerified ?? false} />}
    </>
  );
}

// 邮箱账号方案 §6.4:验证状态 pill(列表行与编辑弹窗 label 共用)
export function EmailVerifiedTag({ verified }: { verified: boolean }) {
  return (
    <Tooltip title={verified
      ? '邮箱已验证(绑定/重置成功后自动置位)'
      : '邮箱未验证(存量录入或尚未完成验证;不影响登录与找回)'}>
      <span style={{
        fontFamily: 'var(--ms-font-mono)', fontSize: 10.5,
        fontWeight: 500, padding: '1px 7px', borderRadius: 3,
        color: verified ? 'var(--ms-emerald)' : 'var(--ms-amber)',
        background: verified ? 'var(--ms-emerald)14' : 'var(--ms-amber)14',
      }}>
        {verified ? '邮箱已验证' : '邮箱未验证'}
      </span>
    </Tooltip>
  );
}

// §6.4:编辑弹窗「邮箱」字段 label — 字段名 + 详情侧验证状态 Tag(仅在有邮箱时展示)
export function EmailFieldLabel({ hasEmail, verified }: { hasEmail: boolean; verified: boolean }) {
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
      邮箱
      {hasEmail && <EmailVerifiedTag verified={verified} />}
    </span>
  );
}

// 邮箱账号方案 §5.3.5/§6.4:编辑提交的 email 脏检查 —— 后端把「提交 email 键」视为一次
// 邮箱变更(清验证态、作废未用重置 token),未改动就不该触发。未改动返回 undefined
// (调用方不发送 email 键);实际修改时返回 trim 后的新值,留空返回 null(D6:显式清空)。
export function changedEmail(
  originalEmail: string | null | undefined,
  nextEmail: string | null | undefined,
): string | null | undefined {
  const original = originalEmail ?? '';
  const next = nextEmail?.trim() || '';
  if (next === original) return undefined;
  return next === '' ? null : next;
}
