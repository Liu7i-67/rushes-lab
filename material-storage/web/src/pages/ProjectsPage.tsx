/**
 * 项目列表 — 卡片网格(b1 现代化重做)。
 * 管理后台优化:「已删除项目」入口 + Modal(分页 + 恢复)、卡片「删除项目」
 * (逻辑删除,project_deleter 权限,Popconfirm 二次确认)。
 * 2026-10-28 UI 修复批:ProjectCard/SkeletonCard/MyRolesBadge 拆到
 * components/ProjectCard.tsx(页面超 500 行);MyRolesBadge 在此 re-export,
 * /my-permissions 既有 import 路径不变。
 */
import { Button, Tooltip } from 'antd';
import { Plus, Archive } from 'lucide-react';
import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useMe, useProjects } from '../api/hooks';
import { NewProjectModal } from '../components/NewProjectModal';
import { DeletedProjectsModal } from '../components/DeletedProjectsModal';
import { ProjectCard, SkeletonCard } from '../components/ProjectCard';

// /my-permissions 既从本页面 import MyRolesBadge(拆件前路径),re-export 保持兼容
export { MyRolesBadge } from '../components/ProjectCard';

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
