/**
 * RoleChipGroup — 项目角色多选 chips(admin/uploader/downloader/viewer,一次授多角色)。
 * 自 InviteModal(ProjectMembersDrawer)抽出,InviteModal 与 NewProjectModal /
 * AdminGrantTemplatesPage 共用;角色 hint 文案随迁(含批次一放开的用户组授管理语义)。
 * RoleBadges:同款配色的只读徽章串,模板列表等展示用。
 */
import { Check } from 'lucide-react';
import type { ProjectRole } from '../api/types';

// 角色 → 展示配色(与 ProjectMembersDrawer 徽章用同一套;组件内私有,勿导出
// — react-refresh 组件文件只允许导出组件)
const ROLE_META: Record<ProjectRole, { label: string; color: string; bg: string }> = {
  admin:      { label: '管理', color: 'var(--ms-accent)',  bg: 'var(--ms-accent-soft)' },
  uploader:   { label: '上传', color: 'var(--ms-amber)',   bg: '#FEF3E8' },
  downloader: { label: '下载', color: 'var(--ms-emerald)', bg: 'var(--ms-emerald-soft)' },
  viewer:     { label: '查看', color: 'var(--ms-ink-muted)', bg: 'var(--ms-hairline-soft)' },
};

const ROLE_ORDER: ProjectRole[] = ['admin', 'uploader', 'downloader', 'viewer'];

interface Props {
  value: ProjectRole[];
  onChange: (roles: ProjectRole[]) => void;
  disabled?: boolean;
}

export function RoleChipGroup({ value, onChange, disabled = false }: Props) {
  const toggleRole = (r: ProjectRole) => {
    if (disabled) return;
    onChange(value.includes(r) ? value.filter(x => x !== r) : [...value, r]);
  };

  const roleLabels = ROLE_ORDER.filter(r => value.includes(r)).map(r => ROLE_META[r].label);

  return (
    <div>
      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
        {ROLE_ORDER.map(r => {
          const meta = ROLE_META[r];
          const active = value.includes(r);
          return (
            <span key={r} onClick={() => toggleRole(r)} aria-checked={active} role="checkbox"
                  tabIndex={disabled ? -1 : 0}
                  onKeyDown={(e) => {
                    if (!disabled && (e.key === 'Enter' || e.key === ' ')) toggleRole(r);
                  }}
                  style={{
                    display: 'inline-flex', alignItems: 'center', gap: 5,
                    padding: '6px 14px', borderRadius: 6,
                    fontSize: 13, fontWeight: active ? 600 : 400,
                    cursor: disabled ? 'not-allowed' : 'pointer', userSelect: 'none',
                    border: `1.5px solid ${active ? meta.color : 'var(--ms-hairline)'}`,
                    background: active ? meta.bg : 'var(--ms-surface)',
                    color: active ? meta.color : 'var(--ms-ink-muted)',
                    boxShadow: active ? `0 0 0 1px ${meta.color}` : 'none',
                    transition: 'all 0.14s',
                    opacity: disabled ? 0.6 : 1,
                  }}>
              {active && <Check size={14} strokeWidth={3} />}
              {meta.label}
            </span>
          );
        })}
      </div>
      <div style={{
        marginTop: 8, fontSize: 11, color: 'var(--ms-ink-subtle)', lineHeight: 1.7,
      }}>
        {value.length === 0 ? (
          <span style={{ color: 'var(--ms-amber)' }}>至少勾选一个角色</span>
        ) : (
          <>
            已选:<b style={{ color: 'var(--ms-ink)' }}>{roleLabels.join(' + ')}</b>。
            {value.includes('admin') &&
              '管理:全部权限 + 可管成员 + 可建敏感目录(用户组授权 = 组成员均获管理)。'}
            {value.includes('uploader') && '上传:传文件 + 建子目录,自动含查看。'}
            {value.includes('downloader') && '下载:下载文件,自动含查看。'}
            {value.includes('viewer') && '查看:仅浏览元数据。'}
          </>
        )}
      </div>
    </div>
  );
}

/** 只读角色徽章串(展示用,无撤销交互)。*/
export function RoleBadges({ roles }: { roles: ProjectRole[] }) {
  const sorted = [...roles].sort((a, b) => ROLE_ORDER.indexOf(a) - ROLE_ORDER.indexOf(b));
  return (
    <>
      {sorted.map(r => (
        <span key={r} style={{
          padding: '1px 7px', background: ROLE_META[r].bg, color: ROLE_META[r].color,
          borderRadius: 3, fontSize: 11, fontWeight: 500, letterSpacing: '0.02em',
        }}>{ROLE_META[r].label}</span>
      ))}
    </>
  );
}
