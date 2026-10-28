/**
 * 项目卡片 — 从 ProjectsPage 拆件(2026-10-28 UI 修复批:页面加置顶按钮后超
 * 500 行,按需求文档拆分条款迁出渲染件)。
 * 卡片结构:左侧 4px visibility 色块条 + Fraunces 标题(已置顶带金色图钉)
 * + mono code + 描述 + admins 段 + 底部 meta 行。
 * meta 行(2026-10-28 换行修复):320px 窄卡按钮放不下时**整颗按钮换行**
 * (右侧组 flex-wrap),visibility chip 与所有按钮/时间戳一律 nowrap ——
 * 杜绝按钮内文字断行。
 * MyRolesBadge 一并迁入,由 ProjectsPage re-export 保持 /my-permissions
 * 既有 import 路径不破坏。
 */
import { App, Popconfirm, Skeleton, Tooltip } from 'antd';
import { Lock, Globe, EyeOff, Link2, Trash2, Pin, PinOff } from 'lucide-react';
import { useState } from 'react';
import { Link } from 'react-router-dom';
import dayjs from 'dayjs';
import 'dayjs/locale/zh-cn';
import relativeTime from 'dayjs/plugin/relativeTime';
import { useDeleteProject, usePinProject, useUnpinProject } from '../api/hooks';
import { errorMessage } from '../api/client';
import { RequestLinkCreateModal } from './RequestLinkCreateModal';
import type { Project } from '../api/types';

dayjs.extend(relativeTime);
dayjs.locale('zh-cn');

const VIS_META: Record<string, {
  color: string; label: string;
  Icon: React.ComponentType<{ size?: number; strokeWidth?: number }>;
}> = {
  public:  { color: 'var(--ms-vis-public)',  label: '公开', Icon: Globe },
  private: { color: 'var(--ms-vis-private)', label: '私有', Icon: Lock },
  stealth: { color: 'var(--ms-vis-stealth)', label: '机密', Icon: EyeOff },
};

export function ProjectCard({ project: p, canDelete }: { project: Project; canDelete: boolean }) {
  const { message } = App.useApp();
  const vis = VIS_META[p.visibility] || VIS_META.private;
  const VisIcon = vis.Icon;
  // #112 PR-2: project admin 才显"生成申请链接"按钮
  const isAdmin = (p.my_roles ?? []).includes('admin');
  const [linkOpen, setLinkOpen] = useState(false);
  const delProject = useDeleteProject();

  // 项目置顶(方案 §2.5):user 私有偏好,任意用户可用;不做乐观更新,
  // mutate 成功后 hook 内失效两列表 key 重取(后端已按置顶优先排序)
  const pinned = !!p.is_pinned;
  const pinProject = usePinProject();
  const unpinProject = useUnpinProject();

  // 逻辑删除:二次确认后提交;成功提示 + 列表失效(hook 内),卡片随重取消失
  const handleDelete = async () => {
    try {
      await delProject.mutateAsync(p.id);
      message.success(`项目「${p.name}」已删除,可在「已删除项目」中恢复`);
    } catch (e) {
      message.error(errorMessage(e, '删除失败'));
    }
  };

  // 置顶/取消置顶:两端点均 204 幂等;失败兜底照 handleDelete 的 errorMessage 模式
  const handlePin = async () => {
    try {
      await (pinned ? unpinProject : pinProject).mutateAsync(p.id);
      message.success(pinned ? `已取消置顶「${p.name}」` : `已置顶「${p.name}」,已排到列表最前`);
    } catch (e) {
      message.error(errorMessage(e, pinned ? '取消置顶失败' : '置顶失败'));
    }
  };
  return (
    <>
    {/* 卡片外壳是普通 div:操作按钮(申请链接/删除)放在 Link 子树之外 ——
        antd v6 portal 内的点击会沿 React 组件树冒泡,Popconfirm 确认/取消曾把
        Link 当祖先触发路由跳转(P1);结构性移出后该类问题不存在,不靠逐事件
        stopPropagation 打补丁 */}
    <div
      className="ms-card-hover"
      style={{
        position: 'relative',
        padding: '24px 24px 20px 28px',
        background: 'var(--ms-surface)',
        border: '1px solid var(--ms-hairline)',
        borderRadius: 'var(--ms-radius-lg)',
        overflow: 'hidden',
      }}
    >
      {/* visibility 色块条 */}
      <span style={{
        position: 'absolute',
        left: 0, top: 16, bottom: 16,
        width: 3,
        background: vis.color,
        borderRadius: '0 2px 2px 0',
      }} />

      {/* 主体(标题/描述/admins)整块可点 → 详情 */}
      <Link
        to={`/projects/${p.id}`}
        style={{
          display: 'block',
          textDecoration: 'none',
          color: 'inherit',
        }}
      >
      {/* 标题 + 我的角色 chip */}
      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 8 }}>
        <h2 style={{
          flex: 1, minWidth: 0,
          margin: 0,
          fontFamily: 'var(--ms-font-display)',
          fontSize: 20, fontWeight: 500,
          lineHeight: 1.25, letterSpacing: '-0.01em',
          color: 'var(--ms-ink)',
        }}>{p.name}
          {/* 已置顶标识(方案 §2.5②):金色小图钉,12px;span 承载原生 title(lucide 无 title prop) */}
          {pinned && (
            <span title="已置顶" style={{
              display: 'inline-flex', alignItems: 'center',
              marginLeft: 6, color: 'var(--ms-accent)', verticalAlign: '-1px',
            }}>
              <Pin size={12} strokeWidth={2.2} fill="currentColor" />
            </span>
          )}
        </h2>
        <MyRolesBadge roles={p.my_roles || []} />
      </div>

      <div style={{
        marginTop: 4,
        fontFamily: 'var(--ms-font-mono)',
        fontSize: 11.5,
        color: 'var(--ms-ink-subtle)',
      }}>{p.code}</div>

      <p style={{
        margin: '14px 0 0',
        fontSize: 13, lineHeight: 1.55,
        color: 'var(--ms-ink-muted)',
        minHeight: 40,
        display: '-webkit-box',
        WebkitLineClamp: 2,
        WebkitBoxOrient: 'vertical',
        overflow: 'hidden',
      }}>
        {p.description || (
          <span style={{ color: 'var(--ms-ink-subtle)', fontStyle: 'italic' }}>
            未填描述
          </span>
        )}
      </p>

      {/* admins 段 — 头像堆叠 + 名字;无 admin 时显示"(未指派)"提示 */}
      <div style={{
        marginTop: 14,
        display: 'flex', alignItems: 'center', gap: 8,
        fontSize: 11.5, color: 'var(--ms-ink-muted)',
      }}>
        <span style={{
          fontSize: 10, letterSpacing: '0.06em', textTransform: 'uppercase',
          fontFamily: 'var(--ms-font-mono)', color: 'var(--ms-ink-subtle)',
          flexShrink: 0,
        }}>Admin</span>
        {p.admins && p.admins.length > 0 ? (
          <>
            <span style={{
              display: 'inline-flex', alignItems: 'center', gap: -6,
              paddingLeft: 0,
            }}>
              {p.admins.slice(0, 3).map((a, i) => (
                <span key={a.user_id} title={a.name} style={{
                  display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
                  width: 22, height: 22, marginLeft: i === 0 ? 0 : -6,
                  background: 'var(--ms-ink)', color: 'var(--ms-canvas)',
                  borderRadius: '50%',
                  fontFamily: 'var(--ms-font-display)',
                  fontSize: 10, fontWeight: 500,
                  border: '1.5px solid var(--ms-surface)',
                  position: 'relative', zIndex: 3 - i,
                }}>{(a.name || '?').slice(0, 1).toUpperCase()}</span>
              ))}
            </span>
            <span style={{
              color: 'var(--ms-ink)', fontSize: 12,
              overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
            }}>
              {p.admins.slice(0, 2).map(a => a.name).join(' · ')}
              {p.admins.length > 2 && (
                <span style={{ color: 'var(--ms-ink-subtle)' }}>
                  {' '}+{p.admins.length - 2}
                </span>
              )}
            </span>
          </>
        ) : (
          <span
            title="本项目没有指派任何 admin — 进入项目 → 成员 → 邀请,role 选「管理」"
            style={{
              fontSize: 11, color: 'var(--ms-ink-subtle)',
              fontStyle: 'italic',
            }}>未指派</span>
        )}
      </div>
      </Link>

      {/* 底部 meta 行在 Link 之外(负 margin 全出血布局不变):色块 chip 与时间戳
          不再触发跳转,按钮天然不受 portal 冒泡影响 */}
      <div style={{
        margin: '14px -24px -20px -28px',
        padding: '14px 24px 0 28px',
        borderTop: '1px solid var(--ms-hairline-soft)',
        display: 'flex', alignItems: 'center', justifyContent: 'space-between',
        gap: 12,
        fontSize: 11.5,
      }}>
        <span style={{
          display: 'inline-flex', alignItems: 'center', gap: 6,
          color: vis.color, fontWeight: 500,
          // 320px 窄卡上右侧按钮组放不下时,chip 整颗不换行(文字断行很怪,见 2026-10-28 UI 修复)
          whiteSpace: 'nowrap', flexShrink: 0,
        }}>
          <VisIcon size={12} strokeWidth={1.8} />
          {vis.label}
        </span>
        {/* 放不下整颗按钮换行(flex-wrap),而非按钮内文字断行;所有按钮/时间戳一律 nowrap */}
        <span style={{
          display: 'inline-flex', alignItems: 'center', gap: 10,
          rowGap: 4, flexWrap: 'wrap', justifyContent: 'flex-end',
          color: 'var(--ms-ink-subtle)',
        }}>
          {/* 置顶按钮(方案 §2.5①):任意用户可用;与申请链接/删除同在 Link 子树外,
              无 portal 冒泡问题。已置顶=Pin 实心金 --ms-accent / 未置顶=PinOff 灰 */}
          <Tooltip title={pinned ? '取消置顶' : '置顶到列表最前'}>
            <button
              onClick={handlePin}
              style={{
                display: 'inline-flex', alignItems: 'center', gap: 4,
                padding: '2px 8px', fontSize: 11,
                color: pinned ? 'var(--ms-accent)' : 'var(--ms-ink-subtle)',
                background: 'transparent',
                border: `1px solid ${pinned ? 'var(--ms-accent)' : 'var(--ms-hairline)'}`,
                borderRadius: 'var(--ms-radius-sm)',
                cursor: 'pointer',
                lineHeight: 1.4,
                whiteSpace: 'nowrap', flexShrink: 0,
              }}
            >
              {pinned
                ? <Pin size={11} strokeWidth={2} fill="currentColor" />
                : <PinOff size={11} strokeWidth={2} />}
              {pinned ? '取消置顶' : '置顶'}
            </button>
          </Tooltip>
          {isAdmin && (
            <Tooltip title="生成一个申请链接,发给别人让他来申请这个项目的权限(不直接授权)">
              <button
                onClick={() => setLinkOpen(true)}
                style={{
                  display: 'inline-flex', alignItems: 'center', gap: 4,
                  padding: '2px 8px', fontSize: 11,
                  color: 'var(--ms-accent)',
                  background: 'transparent',
                  border: '1px solid var(--ms-accent)',
                  borderRadius: 'var(--ms-radius-sm)',
                  cursor: 'pointer',
                  lineHeight: 1.4,
                  whiteSpace: 'nowrap', flexShrink: 0,
                }}
              >
                <Link2 size={11} strokeWidth={2} />
                申请链接
              </button>
            </Tooltip>
          )}
          {/* 逻辑删除(project_deleter):已移出 Link 子树,确认/取消点击不会误触路由 */}
          {canDelete && (
            <Popconfirm
              title={`删除项目「${p.name}」?`}
              description="删除后所有成员均不可见;数据保留,可在「已删除项目」中恢复"
              okText="删除" okButtonProps={{ danger: true }}
              onConfirm={handleDelete}
            >
              <button
                style={{
                  display: 'inline-flex', alignItems: 'center', gap: 4,
                  padding: '2px 8px', fontSize: 11,
                  color: 'var(--ms-crimson)',
                  background: 'transparent',
                  border: '1px solid var(--ms-crimson)',
                  borderRadius: 'var(--ms-radius-sm)',
                  cursor: 'pointer',
                  lineHeight: 1.4,
                  whiteSpace: 'nowrap', flexShrink: 0,
                }}
              >
                <Trash2 size={11} strokeWidth={2} />
                删除项目
              </button>
            </Popconfirm>
          )}
          <span style={{ whiteSpace: 'nowrap' }}>{dayjs(p.created_at).fromNow()}</span>
        </span>
      </div>
    </div>
    {isAdmin && (
      <RequestLinkCreateModal
        open={linkOpen}
        onClose={() => setLinkOpen(false)}
        targetType="project"
        targetId={p.id}
        targetName={p.name}
      />
    )}
    </>
  );
}

export function SkeletonCard() {
  return (
    <div style={{
      padding: '24px 24px 20px 28px',
      background: 'var(--ms-surface)',
      border: '1px solid var(--ms-hairline)',
      borderRadius: 'var(--ms-radius-lg)',
    }}>
      <Skeleton active title={{ width: '60%' }}
                paragraph={{ rows: 2, width: ['100%', '70%'] }} />
    </div>
  );
}

// ─── MyRolesBadge — 卡片右上小标识(自 ProjectsPage 迁入;/my-permissions 复用)──
const ROLE_META: Record<string, { label: string; color: string; bg: string }> = {
  admin:      { label: '管理', color: 'var(--ms-accent)',  bg: 'var(--ms-accent-soft)' },
  uploader:   { label: '上传', color: 'var(--ms-amber)',   bg: '#FEF3E8' },
  downloader: { label: '下载', color: 'var(--ms-emerald)', bg: 'var(--ms-emerald-soft)' },
  viewer:     { label: '查看', color: 'var(--ms-ink-muted)', bg: 'var(--ms-hairline-soft)' },
};
const ROLE_RANK = ['admin', 'uploader', 'downloader', 'viewer'];

export function MyRolesBadge({ roles }: { roles: string[] }) {
  if (!roles || roles.length === 0) {
    return (
      <span title="无角色 — 仅 visibility=public 项目可见"
            style={{
              flexShrink: 0, fontSize: 10, letterSpacing: '0.02em',
              padding: '1px 6px',
              background: 'var(--ms-hairline-soft)',
              color: 'var(--ms-ink-subtle)',
              borderRadius: 3,
              fontFamily: 'var(--ms-font-mono)',
            }}>仅访客</span>
    );
  }
  // 优先级最高的 role 显示主 chip;额外 role 数 +N
  const sorted = [...roles].sort((a, b) => ROLE_RANK.indexOf(a) - ROLE_RANK.indexOf(b));
  const top = sorted[0];
  const meta = ROLE_META[top] || ROLE_META.viewer;
  return (
    <span title={`你的角色: ${sorted.join(' + ')}`}
          style={{
            flexShrink: 0,
            display: 'inline-flex', alignItems: 'center', gap: 3,
            padding: '1px 7px',
            background: meta.bg, color: meta.color,
            borderRadius: 3,
            fontSize: 10.5, fontWeight: 500, letterSpacing: '0.02em',
          }}>
      我·{meta.label}
      {sorted.length > 1 && (
        <span style={{ opacity: 0.7 }}>+{sorted.length - 1}</span>
      )}
    </span>
  );
}
