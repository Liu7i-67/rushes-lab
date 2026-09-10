/**
 * MobileTabBar — compact(<1024)专属底部导航,PC 渲染 null、PC 顶栏零接触。
 * 文档流 flex 项(非 fixed):壳层固定 100dvh + main 内滚,TabBar 常驻可视底。
 * 视觉语言对齐 AppHeader 的 NavChip:inline style + tokens 变量。
 * hooks 置顶(见 use-viewports 模块注释):分支只切 JSX,不挂不同数量的 hook。
 */
import { useState } from 'react';
import { Badge, Drawer } from 'antd';
import { useLocation, useNavigate } from 'react-router-dom';
import {
  Bell, ClipboardCheck, Folder, Menu, Search,
  ScrollText, ShieldCheck, Users as UsersIcon, UsersRound,
} from 'lucide-react';
import { useMe, useNotificationsUnread } from '../api/hooks';
import { useKeyboardVisible } from '../lib/use-keyboard-visible';
import { useCompactViewport } from '../lib/use-viewports';

// active 派生映射写死在本组件:/projects/*、/folders/* 归属"项目"高亮;
// 其余(admin/my-permissions)不高亮——"更多"打开时高亮"更多"
function activeTabOf(pathname: string): string | null {
  if (pathname === '/' || pathname.startsWith('/projects') || pathname.startsWith('/folders')) return 'home';
  if (pathname.startsWith('/search')) return 'search';
  if (pathname.startsWith('/approvals')) return 'approvals';
  if (pathname.startsWith('/notifications')) return 'notifications';
  return null;
}

export function MobileTabBar() {
  const compact = useCompactViewport();
  const navigate = useNavigate();
  const location = useLocation();
  const { data: me } = useMe();
  // 与 AppHeader 同一 query key,react-query 共享缓存自动去重,无双重轮询
  const { data: unread } = useNotificationsUnread();
  const [moreOpen, setMoreOpen] = useState(false);
  // 键盘弹起时隐藏 TabBar(§3.1 键盘交互;详情 Drawer 等不在隐藏清单)
  const kbVisible = useKeyboardVisible();

  if (!compact) return null;

  const active = activeTabOf(location.pathname);

  // "更多"条目:后三个仅系统管理员可见(非 admin 不出现 403 死链)
  const moreItems = [
    { to: '/my-permissions', label: '我的权限', icon: <ShieldCheck size={16} strokeWidth={1.8} /> },
    ...(me?.is_system_admin ? [
      { to: '/admin/audit', label: '审计', icon: <ScrollText size={16} strokeWidth={1.8} /> },
      { to: '/admin/users', label: '用户管理', icon: <UsersIcon size={16} strokeWidth={1.8} /> },
      { to: '/admin/groups', label: '用户组管理', icon: <UsersRound size={16} strokeWidth={1.8} /> },
    ] : []),
  ];

  return (
    <>
      <nav
        style={{
          // 文档流 flex 项(壳层根是 flex 列,main 内滚):常驻可视底,不再叠压内容
          flexShrink: 0,
          height: 'var(--ms-tabbar-h)',
          boxSizing: 'border-box',
          display: kbVisible ? 'none' : 'flex',
          paddingBottom: 'env(safe-area-inset-bottom)',
          alignItems: 'stretch',
          background: 'rgba(255, 255, 255, 0.92)',
          backdropFilter: 'saturate(180%) blur(20px)',
          WebkitBackdropFilter: 'saturate(180%) blur(20px)',
          borderTop: '1px solid var(--ms-hairline)',
        }}
      >
        <TabItem
          label="项目"
          active={active === 'home'}
          onClick={() => navigate('/')}
          icon={<Folder size={20} strokeWidth={1.8} />}
        />
        <TabItem
          label="搜索"
          active={active === 'search'}
          onClick={() => navigate('/search')}
          icon={<Search size={20} strokeWidth={1.8} />}
        />
        <TabItem
          label="审批"
          active={active === 'approvals'}
          onClick={() => navigate('/approvals')}
          icon={<ClipboardCheck size={20} strokeWidth={1.8} />}
        />
        <TabItem
          label="通知"
          active={active === 'notifications'}
          onClick={() => navigate('/notifications')}
          badge={unread ?? 0}
          icon={<Bell size={20} strokeWidth={1.8} />}
        />
        <TabItem
          label="更多"
          active={moreOpen}
          onClick={() => setMoreOpen(true)}
          icon={<Menu size={20} strokeWidth={1.8} />}
        />
      </nav>

      <Drawer
        placement="bottom"
        open={moreOpen}
        onClose={() => setMoreOpen(false)}
        height="auto"
        title={null}
        closable={false}
        styles={{ body: { padding: 0 } }}
      >
        <div style={{ maxHeight: '60vh', overflowY: 'auto' }}>
          {/* 顶部 grip 条 */}
          <div style={{ display: 'flex', justifyContent: 'center', padding: '8px 0 4px' }}>
            <span style={{ width: 36, height: 4, borderRadius: 2, background: 'var(--ms-hairline)' }} />
          </div>
          <div style={{ padding: '4px 8px', paddingBottom: 'calc(8px + env(safe-area-inset-bottom))' }}>
            {moreItems.map(item => (
              <button
                key={item.to}
                onClick={() => { navigate(item.to); setMoreOpen(false); }}
                style={{
                  width: '100%',
                  minHeight: 44,
                  display: 'flex',
                  alignItems: 'center',
                  gap: 12,
                  padding: '0 12px',
                  background: 'transparent',
                  border: 0,
                  borderRadius: 'var(--ms-radius-md)',
                  fontSize: 14,
                  fontFamily: 'inherit',
                  color: 'var(--ms-ink)',
                  textAlign: 'left',
                  cursor: 'pointer',
                  transition: 'background var(--ms-dur-fast) var(--ms-ease)',
                }}
                onMouseEnter={e => (e.currentTarget.style.background = 'var(--ms-hairline-soft)')}
                onMouseLeave={e => (e.currentTarget.style.background = 'transparent')}
              >
                <span style={{ display: 'inline-flex', color: 'var(--ms-ink-muted)' }}>{item.icon}</span>
                {item.label}
              </button>
            ))}
          </div>
        </div>
      </Drawer>
    </>
  );
}

// ─── 单个 tab(图标 pill + 文字,active 用 hairline-soft 底 + accent)─────────
function TabItem({ label, icon, badge = 0, active, onClick }: {
  label: string;
  icon: React.ReactNode;
  badge?: number;
  active: boolean;
  onClick: () => void;
}) {
  const color = active ? 'var(--ms-accent)' : 'var(--ms-ink-muted)';
  return (
    <button
      onClick={onClick}
      aria-label={label}
      style={{
        flex: 1,
        height: '100%',
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 2,
        background: 'transparent',
        border: 0,
        padding: 0,
        cursor: 'pointer',
        fontFamily: 'inherit',
      }}
    >
      <Badge count={badge} size="small" offset={[4, -2]} color="#C2410C" overflowCount={99}>
        <span style={{
          display: 'inline-flex',
          alignItems: 'center',
          justifyContent: 'center',
          minWidth: 44,
          height: 28,
          padding: '0 10px',
          borderRadius: 'var(--ms-radius-md)',
          background: active ? 'var(--ms-hairline-soft)' : 'transparent',
          color,
          transition: 'all var(--ms-dur-fast) var(--ms-ease)',
        }}>
          {icon}
        </span>
      </Badge>
      <span style={{
        fontSize: 10.5,
        lineHeight: '12px',
        fontWeight: active ? 500 : 400,
        color,
        transition: 'color var(--ms-dur-fast) var(--ms-ease)',
      }}>
        {label}
      </span>
    </button>
  );
}
