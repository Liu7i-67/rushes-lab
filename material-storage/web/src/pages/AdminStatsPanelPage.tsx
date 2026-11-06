/**
 * /admin/stats — 统计面板(2026-11-06 统计面板方案 §5.1)。
 *
 * 模块卡片列表:既有「使用统计」迁入 + 新增「文件上传数量统计」,子模块各自独立控权:
 * - 「使用统计」卡片按 me.is_usage_stats_viewer ?? me.is_system_admin 显隐;
 * - 「文件上传数量统计」卡片按 me.is_upload_stats_viewer ?? me.is_system_admin 显隐;
 * - 面板自身入口由 chip 三态门(is_stats_viewer ?? is_system_admin)控制;直达 URL
 *   或持面板 flag 但两卡片皆无权限时,渲染 Alert「无可用的统计模块,请联系管理员开通」
 *   (体验层守卫,后端 403 兜底同现状双层模式;me 未就绪时不拦)。
 */
import { Alert } from 'antd';
import { useNavigate } from 'react-router-dom';
import { Activity, ChevronRight, Upload } from 'lucide-react';
import { useMe } from '../api/hooks';
import { useCompactViewport } from '../lib/use-viewports';

/** 无可用模块时的体验层守卫(直达 URL / 两子 flag 皆无,同款 Alert)。*/
function NoModuleAlert() {
  return (
    <div className="ms-enter" style={{ maxWidth: 520 }}>
      <Alert
        type="warning" showIcon
        message="无可用的统计模块,请联系管理员开通"
        description="统计面板按用户组授权,开通后此处将展示可用的统计模块。"
      />
    </div>
  );
}

export default function AdminStatsPanelPage() {
  const { data: me } = useMe();
  const navigate = useNavigate();
  const compact = useCompactViewport();

  // 三个口径消费侧 `?? is_system_admin` 回落(旧后端无字段时 admin 行为不变)
  const canEnter = (me?.is_stats_viewer ?? me?.is_system_admin) === true;
  const showUsage = (me?.is_usage_stats_viewer ?? me?.is_system_admin) === true;
  const showUpload = (me?.is_upload_stats_viewer ?? me?.is_system_admin) === true;

  // 体验层守卫(me 未就绪不拦,交给后端 403 → 全局静默,照 AdminUsageStatsPage 双层模式)
  if (me && (!canEnter || (!showUsage && !showUpload))) {
    return <NoModuleAlert />;
  }

  const modules = [
    ...(showUsage ? [{
      key: 'usage',
      to: '/admin/usage',
      icon: <Activity size={20} strokeWidth={1.8} />,
      title: '使用统计',
      desc: '客户端三端占比 / 内外网访问占比(依托审计日志聚合;同一用户多端重复计数)',
    }] : []),
    ...(showUpload ? [{
      key: 'upload-stats',
      to: '/admin/upload-stats',
      icon: <Upload size={20} strokeWidth={1.8} />,
      title: '文件上传数量统计',
      desc: '按项目统计生活图文 / 口播视频 / 生活视频 / 其他分类计数,支持时间范围筛选与全项目汇总',
    }] : []),
  ];

  return (
    <div className="ms-enter">
      {/* 页头(照 AdminAuditPage / AdminUsageStatsPage 惯例) */}
      <div style={{ marginBottom: 'var(--ms-sp-xl)' }}>
        <h1 style={{
          margin: 0,
          fontFamily: 'var(--ms-font-display)',
          fontSize: 32, fontWeight: 500, letterSpacing: '-0.02em',
          color: 'var(--ms-ink)', lineHeight: 1.1,
        }}>统计面板</h1>
        <p style={{ margin: '8px 0 0', fontSize: 13, color: 'var(--ms-ink-muted)' }}>
          可用的统计模块 — 各模块独立授权,如需开通请联系系统管理员
        </p>
      </div>

      {/* 模块卡片列表:图标 + 标题 + 一句话描述 + 进入(整卡可点) */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 12, maxWidth: 640 }}>
        {modules.map(m => (
          <button
            key={m.key}
            onClick={() => navigate(m.to)}
            style={{
              display: 'flex', alignItems: 'center', gap: 14, textAlign: 'left',
              padding: compact ? '14px 16px' : '16px 20px',
              background: 'var(--ms-surface)',
              border: '1px solid var(--ms-hairline)',
              borderRadius: 'var(--ms-radius-md)',
              cursor: 'pointer', fontFamily: 'inherit', width: '100%',
              transition: 'background var(--ms-dur-fast) var(--ms-ease)',
            }}
            onMouseEnter={e => (e.currentTarget.style.background = 'var(--ms-hairline-soft)')}
            onMouseLeave={e => (e.currentTarget.style.background = 'var(--ms-surface)')}
          >
            <span style={{
              display: 'grid', placeItems: 'center', width: 40, height: 40, flexShrink: 0,
              background: 'var(--ms-accent-soft)', borderRadius: 'var(--ms-radius-sm)',
              color: 'var(--ms-accent)',
            }}>
              {m.icon}
            </span>
            <span style={{ flex: 1, minWidth: 0 }}>
              <span style={{
                display: 'block', fontSize: 14.5, fontWeight: 500, color: 'var(--ms-ink)',
              }}>{m.title}</span>
              <span style={{
                display: 'block', marginTop: 3, fontSize: 12, lineHeight: 1.5,
                color: 'var(--ms-ink-muted)',
              }}>{m.desc}</span>
            </span>
            <ChevronRight size={16} strokeWidth={1.8} style={{ color: 'var(--ms-ink-subtle)', flexShrink: 0 }} />
          </button>
        ))}
      </div>
    </div>
  );
}
