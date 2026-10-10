/**
 * 项目列表 — 卡片网格(b1 现代化重做)。
 * 卡片左侧 4px visibility 色块条 + Fraunces display 大标题 + mono code + meta row。
 * 管理后台优化:「已删除项目」入口 + Modal(分页 + 恢复)、卡片「删除项目」
 * (逻辑删除,project_deleter 权限,Popconfirm 二次确认)。
 */
import { App, Button, Popconfirm, Skeleton, Tooltip } from 'antd';
import { Plus, Lock, Globe, EyeOff, Link2, Archive, Trash2 } from 'lucide-react';
import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import dayjs from 'dayjs';
import 'dayjs/locale/zh-cn';
import relativeTime from 'dayjs/plugin/relativeTime';
import { useMe, useProjects, useDeleteProject } from '../api/hooks';
import { errorMessage } from '../api/client';
import { NewProjectModal } from '../components/NewProjectModal';
import { RequestLinkCreateModal } from '../components/RequestLinkCreateModal';
import { DeletedProjectsModal } from '../components/DeletedProjectsModal';
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

export default function ProjectsPage() {
  const { data, isLoading } = useProjects();
  const { data: me } = useMe();
  const [createOpen, setCreateOpen] = useState(false);
  // 项目逻辑删除:「已删除项目」Modal 入口(§6.8)
  const [deletedOpen, setDeletedOpen] = useState(false);
  const navigate = useNavigate();
  // PR-2: 新建闸门口径回落式替换 —— 新后端 is_project_creator 已含系统 admin,
  // `??` 仅在旧后端(字段 undefined)时回落 is_system_admin
  const canCreate = me ? (me.is_project_creator ?? me.is_system_admin) : false;
  // 同款口径:可删项目 = is_project_deleter(已含系统 admin)
  const canDelete = me ? (me.is_project_deleter ?? me.is_system_admin) : false;

  return (
    <div className="ms-enter">
      {/* 标题区:Display + 极简元信息 */}
      <div style={{
        display: 'flex', alignItems: 'baseline', justifyContent: 'space-between',
        gap: 24, marginBottom: 'var(--ms-sp-2xl)',
      }}>
        <div>
          <h1 style={{
            margin: 0,
            fontFamily: 'var(--ms-font-display)',
            fontSize: 36,
            fontWeight: 500,
            letterSpacing: '-0.02em',
            color: 'var(--ms-ink)',
            lineHeight: 1.1,
          }}>项目</h1>
          <p style={{
            margin: '8px 0 0',
            fontSize: 13,
            color: 'var(--ms-ink-muted)',
          }}>
            {data ? <>共 <span className="ms-mono">{data.length}</span> 个项目</>
                  : isLoading ? '加载中…' : '—'}
          </p>
        </div>
        {me && (
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexShrink: 0 }}>
            {canDelete && (
              <Button
                icon={<Archive size={14} strokeWidth={2} />}
                onClick={() => setDeletedOpen(true)}
                style={{ height: 36, fontWeight: 500 }}
              >已删除项目</Button>
            )}
            <Tooltip title={canCreate ? '' : '需要组织管理员,或加入已开启「允许新建项目」的用户组'} placement="left">
              <Button
                type="primary"
                icon={<Plus size={15} strokeWidth={2.2} />}
                onClick={() => setCreateOpen(true)}
                disabled={!canCreate}
                style={{ height: 36, fontWeight: 500 }}
              >新建项目</Button>
            </Tooltip>
          </div>
        )}
      </div>

      {isLoading ? (
        <Grid>
          {Array.from({ length: 6 }).map((_, i) => <SkeletonCard key={i} />)}
        </Grid>
      ) : (!data || data.length === 0) ? (
        <EmptyState onCreate={canCreate ? () => setCreateOpen(true) : undefined} />
      ) : (
        <div className="ms-enter-stagger">
          <Grid>
            {data.map(p => <ProjectCard key={p.id} project={p} canDelete={canDelete} />)}
          </Grid>
        </div>
      )}

      {me && (
        <NewProjectModal
          open={createOpen}
          onClose={() => setCreateOpen(false)}
          onCreated={(id) => navigate(`/projects/${id}`)}
          me={me}
        />
      )}
      <DeletedProjectsModal open={deletedOpen} onClose={() => setDeletedOpen(false)} />
    </div>
  );
}

function Grid({ children }: { children: React.ReactNode }) {
  return (
    <div style={{
      display: 'grid',
      gridTemplateColumns: 'repeat(auto-fill, minmax(320px, 1fr))',
      gap: 'var(--ms-sp-xl)',
    }}>{children}</div>
  );
}

function ProjectCard({ project: p, canDelete }: { project: Project; canDelete: boolean }) {
  const { message } = App.useApp();
  const vis = VIS_META[p.visibility] || VIS_META.private;
  const VisIcon = vis.Icon;
  // #112 PR-2: project admin 才显"生成申请链接"按钮
  const isAdmin = (p.my_roles ?? []).includes('admin');
  const [linkOpen, setLinkOpen] = useState(false);
  const delProject = useDeleteProject();

  // 逻辑删除:二次确认后提交;成功提示 + 列表失效(hook 内),卡片随重取消失
  const handleDelete = async () => {
    try {
      await delProject.mutateAsync(p.id);
      message.success(`项目「${p.name}」已删除,可在「已删除项目」中恢复`);
    } catch (e) {
      message.error(errorMessage(e, '删除失败'));
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
        }}>{p.name}</h2>
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
        }}>
          <VisIcon size={12} strokeWidth={1.8} />
          {vis.label}
        </span>
        <span style={{ display: 'inline-flex', alignItems: 'center', gap: 10, color: 'var(--ms-ink-subtle)' }}>
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
                }}
              >
                <Trash2 size={11} strokeWidth={2} />
                删除项目
              </button>
            </Popconfirm>
          )}
          <span>{dayjs(p.created_at).fromNow()}</span>
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

function SkeletonCard() {
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

function EmptyState({ onCreate }: { onCreate?: () => void }) {
  return (
    <div style={{
      marginTop: 80,
      padding: '60px 40px',
      textAlign: 'center',
      background: 'var(--ms-surface)',
      border: '1px dashed var(--ms-hairline)',
      borderRadius: 'var(--ms-radius-lg)',
    }}>
      <svg width="48" height="48" viewBox="0 0 48 48" style={{ marginBottom: 20 }}>
        <rect x="8" y="14" width="32" height="22" rx="2"
              fill="none" stroke="var(--ms-hairline)" strokeWidth="1.5" />
        <rect x="12" y="10" width="24" height="4" rx="1"
              fill="none" stroke="var(--ms-ink-subtle)" strokeWidth="1.5" />
        <line x1="14" y1="20" x2="34" y2="20" stroke="var(--ms-hairline)" strokeWidth="1" />
        <line x1="14" y1="25" x2="28" y2="25" stroke="var(--ms-hairline)" strokeWidth="1" />
        <line x1="14" y1="30" x2="22" y2="30" stroke="var(--ms-hairline)" strokeWidth="1" />
      </svg>
      <div style={{
        fontFamily: 'var(--ms-font-display)',
        fontSize: 18, fontWeight: 500,
        color: 'var(--ms-ink)', marginBottom: 8,
      }}>还没有可见项目</div>
      <p style={{
        margin: 0, fontSize: 13, color: 'var(--ms-ink-muted)',
        maxWidth: 320, marginInline: 'auto',
      }}>
        申请加入已有项目,或者点击下方按钮新建一个属于你的素材库。
      </p>
      {onCreate && (
        <Button type="primary" icon={<Plus size={15} strokeWidth={2.2} />}
                onClick={onCreate} style={{ marginTop: 24, height: 36 }}>
          新建项目
        </Button>
      )}
    </div>
  );
}

// ─── MyRolesBadge — 卡片右上小标识(导出供 /my-permissions 复用)──────────
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
