/**
 * /admin/audit — audit 后台(timeline + 过滤 + CSV 导出)。
 * 数据面 require_system_admin(backend enforce);顶栏「审计」入口已收敛进系统管理员
 * chip 块(W2b,此前全员可见但点进去 403)。
 * W2b(2026-10-17):目标补名展示(项目名/文件名)+ 项目筛选(透传 project_id)。
 */
import { Button, DatePicker, Empty, Pagination, Select, Skeleton, Tooltip } from 'antd';
import {
  ChevronRight, Clock, Download, Filter,
} from 'lucide-react';
import { useQuery } from '@tanstack/react-query';
import { useMemo, useState, type ReactNode } from 'react';
import dayjs, { type Dayjs } from 'dayjs';
import 'dayjs/locale/zh-cn';
import relativeTime from 'dayjs/plugin/relativeTime';
import { http, apiBase } from '../api/client';
import { useAllProjects } from '../api/hooks';
import { UserPicker } from '../components/UserPicker';
import { useCompactViewport } from '../lib/use-viewports';
import { EVENT_TYPE_LABEL, tlabel } from '../lib/labels';
import type { AuditEvent } from '../api/types';

dayjs.extend(relativeTime);
dayjs.locale('zh-cn');

// event_type 过滤下拉 = 后端写入全集 61 项 + 「全部」,共 62 行。
// (原注释「55 项/56 行」自 W1/W4/W5/W6 五个事件随包回填起未同步过期;2026-10-28
// 风控模块 +1(ip_login_unlocked)时按本数组实数更正,后续随包回填须同步本数。)
// 注意:Select 未开 tags 模式,showSearch 只能在既有选项里搜,输不了自定义值 —
// 后端新增 event_type 写入点时须回来补选项(后端对 event_type 是任意字符串精确匹配,无白名单)。
// 全集核对依据:rushes-spec/material-storage/prod-observability-fix-plan.md 附录 A
// (2026-10-14 补全 33 项;删除后端从不写入的死选项 approval_notified/invite_notified)。
const EVENT_TYPES = [
  '', 'upload', 'download', 'signed_url_issued',
  'approval_submitted', 'approval_state_changed',
  'access_denied',
  'project_created', 'project_deleted', 'project_restored',
  'project_member_added', 'project_member_removed',
  'user_created', 'user_updated',
  'group_member_added', 'group_member_removed',
  'folder_created', 'sensitive_folder_invited', 'sensitive_folder_revoked',
  'folder_template_changed', 'folder_template_applied',
  'share_link_created', 'share_link_accessed',
  // ── 以下按上游方案附录 A 分组补全(33 项)────────────────────────────────
  // 备份类(11)
  'baidu_bind', 'baidu_unbind', 'baidu_task_create', 'baidu_task_cancel',
  'baidu_task_delete', 'baidu_task_retry', 'baidu_file_retry',
  'baidu_file_overwrite', 'baidu_file_random_suffix', 'baidu_file_imported',
  'baidu_task_auto_finalized',
  // 文件类(8)
  'asset_deleted', 'asset_restored', 'asset_purged',
  'asset.tag_updated', 'asset.batch_renamed',
  'download_denied', 'proxy_download', 'folder_deleted',
  // 用户/组(7)
  'user_disabled', 'user_enabled', 'user_password_reset',
  'group_created', 'group_updated', 'group_deleted', 'password_changed',
  // 登录/通知(3)
  'local_login_success', 'local_login_failed', 'notification_sent',
  // 权限模板/目录/授权(4)
  'folder_grant_added', 'folder_grant_removed', 'grant_template_changed',
  'grant_revoked',
  // ── 六项优化(2026-10-17)逐包回填(硬约定:本数组 + labels.ts EVENT_TYPE_LABEL 两处同步)──
  // W1 登录锁定(本包);folder_renamed/folder_moved/asset_batch_moved 归 W4/W5/W6 包自行补,勿代填
  'user_login_unlocked', 'local_login_locked',
  // W4/W5/W6 目录改名/移动 + 批量移动资产(前端2 包回填)
  'folder_renamed', 'folder_moved', 'asset_batch_moved',
  // 风控模块(2026-10-28):单独解 IP 锁写入点(routers/risk.py;labels.ts 文案同步)
  'ip_login_unlocked',
];

const PAGE_SIZE = 30;

// C 包(2026-10-19):audit details 键 → 中文 label。与 tlabel 同哲学 —— 缺 key 回落
// raw 键名,后端新增写入点时按需补行,漏掉的键原样展示不会错(白名单制)。
const DETAIL_KEY_LABEL: Record<string, string> = {
  folder_id: '目录',
  target_folder_id: '目标目录',
  parent_folder_id: '父目录',
  old_parent_folder_id: '原父目录',
  new_parent_folder_id: '新父目录',
  group_id: '用户组',
  group_ids: '用户组列表',
  group_name: '用户组名',
  user_id: '用户',
  sharer_user_id: '分享者',
  subject: '主体',
  level: '权限级别',
  role: '角色',
  task_id: '任务',
  file_id: '备份文件',
  source_dir: '源目录',
  reason: '原因',
  size_bytes: '大小',
  expires_at: '过期时间',
  expires_in_seconds: '有效期(秒)',
  token: '令牌',
  via: '来源',
  username: '登录名',
  name: '名称',
  old_name: '原名称',
  new_name: '新名称',
  action: '动作',
  kind: '类型',
  filename: '文件名',
  asset_id: '文件',
  project_id: '项目',
  template_id: '模板',
  changes: '变更内容',
  permanent: '永久',
  fga_swap: 'FGA 变更',
  old_minio_prefix: '原存储前缀',
  new_minio_prefix: '新存储前缀',
  status: '状态',
  fail_reason: '失败原因',
  email: '邮箱',
  notes: '备注',
  user_labels: '手工标签',
  baidu_uid: '百度账号',
};

export default function AdminAuditPage() {
  const compact = useCompactViewport();
  // W2b: 项目筛选选项 —— 项目全量列表(admin 视角全可见;useAllProjects 循环翻页拉全,
  // 默认 limit=100 会静默截断),staleTime 30s
  const { data: projects } = useAllProjects();
  const [filters, setFilters] = useState<{
    event_type: string;
    actor_user_id: string;   // users.id UUID(#148 起)
    project_id: string;      // W2b: 按目标项目过滤(后端已支持 project_id 参数,此前前端未暴露)
    range: [Dayjs, Dayjs] | null;
  }>({ event_type: '', actor_user_id: '', project_id: '', range: null });
  const [page, setPage] = useState(1);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());

  const params = useMemo(() => {
    const p: Record<string, string> = {
      limit: String(PAGE_SIZE),
      offset: String((page - 1) * PAGE_SIZE),
    };
    if (filters.event_type) p.event_type = filters.event_type;
    if (filters.actor_user_id) p.actor_user_id = filters.actor_user_id;
    if (filters.project_id) p.project_id = filters.project_id;
    if (filters.range) {
      p.from = filters.range[0].toISOString();
      p.to = filters.range[1].toISOString();
    }
    return p;
  }, [filters, page]);

  const { data, isLoading } = useQuery({
    queryKey: ['audit', params],
    queryFn: async () => (await http.get<AuditEvent[]>('/api/v1/admin/audit', { params })).data,
  });

  const exportUrl = useMemo(() => {
    const u = new URLSearchParams();
    if (filters.event_type) u.set('event_type', filters.event_type);
    if (filters.actor_user_id) u.set('actor_user_id', filters.actor_user_id);
    if (filters.project_id) u.set('project_id', filters.project_id);
    if (filters.range) {
      u.set('from', filters.range[0].toISOString());
      u.set('to', filters.range[1].toISOString());
    }
    return `${apiBase}/api/v1/admin/audit/export.csv?${u}`;
  }, [filters]);

  return (
    <div className="ms-enter">
      {/* 页头 */}
      <div style={{
        display: 'flex', alignItems: 'baseline', justifyContent: 'space-between',
        gap: 24, marginBottom: 'var(--ms-sp-xl)',
      }}>
        <div>
          <h1 style={{
            margin: 0,
            fontFamily: 'var(--ms-font-display)',
            fontSize: 32, fontWeight: 500, letterSpacing: '-0.02em',
            color: 'var(--ms-ink)', lineHeight: 1.1,
          }}>审计</h1>
          <p style={{ margin: '8px 0 0', fontSize: 13, color: 'var(--ms-ink-muted)' }}>
            全量行为日志 / 可按操作者 / 事件类型 / 时间过滤 / CSV 导出
          </p>
        </div>
        <Button icon={<Download size={14} strokeWidth={2} />}
                href={exportUrl} target="_blank">
          导出 CSV
        </Button>
      </div>

      {/* 过滤栏 */}
      <div style={{
        display: 'flex', gap: 12, marginBottom: 16, flexWrap: 'wrap', alignItems: 'center',
      }}>
        <span style={{
          display: 'inline-flex', alignItems: 'center', gap: 6,
          color: 'var(--ms-ink-muted)', fontSize: 12.5,
        }}>
          <Filter size={13} strokeWidth={2} /> 过滤
        </span>
        <Select
          value={filters.event_type}
          onChange={(v) => { setFilters({ ...filters, event_type: v }); setPage(1); }}
          style={{ minWidth: 240 }}
          showSearch
          allowClear
          placeholder="事件类型(可选)"
          options={EVENT_TYPES.map(t => ({
            value: t,
            label: t ? tlabel(t, EVENT_TYPE_LABEL) : '— 全部 —',
          }))}
        />
        {/* W2b: 项目筛选(透传 project_id;CSV 导出同参)。
            注意:该过滤只命中「写入时带了 target_project_id」的行 —— 历史行与非资产事件
            无该值,选定项目后不出现属正常(后端 LEFT JOIN 补名,历史行不误导) */}
        <Select
          value={filters.project_id}
          onChange={(v) => { setFilters({ ...filters, project_id: v ?? '' }); setPage(1); }}
          style={compact ? { flex: 1, minWidth: 0 } : { minWidth: 200 }}
          showSearch
          allowClear
          optionFilterProp="label"
          loading={!projects}
          placeholder="按项目筛选(可选)"
          options={(projects ?? []).map(p => ({ value: p.id, label: `${p.name}(${p.code})` }))}
        />
        {/* #116 修:actor 过滤从手填 open_id Input 改 UserPicker 选人;
            #148 起 value = users.id UUID,传给 backend actor_user_id */}
        <div style={compact ? { flex: 1, minWidth: 0 } : { width: 280 }}>
          <UserPicker
            multiple={false}
            value={filters.actor_user_id}
            onChange={(v) => {
              setFilters({ ...filters, actor_user_id: (v as string) || '' });
              setPage(1);
            }}
            placeholder="按操作者筛选"
          />
        </div>
        {/* compact: 双月 RangePicker + showTime 手机不可用,换单个 DatePicker(按整天过滤);
            仍写回同一个 filters.range([startOf('day'), endOf('day')]),params/CSV 导出逻辑零变化 */}
        {compact ? (
          <DatePicker
            value={filters.range ? filters.range[0] : null}
            onChange={(d) => {
              setFilters({
                ...filters,
                range: d ? [d.startOf('day'), d.endOf('day')] : null,
              });
              setPage(1);
            }}
            placeholder="按日期筛选"
            style={{ flex: 1, minWidth: 0 }}
          />
        ) : (
          <DatePicker.RangePicker
            value={filters.range}
            onChange={(v) => { setFilters({ ...filters, range: v as [Dayjs, Dayjs] | null }); setPage(1); }}
            showTime
          />
        )}
      </div>

      {/* 列表 */}
      {isLoading ? (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          {[0, 1, 2, 3].map(i => (
            <div key={i} style={{
              padding: '16px 20px',
              background: 'var(--ms-surface)',
              border: '1px solid var(--ms-hairline)',
              borderRadius: 'var(--ms-radius-md)',
            }}>
              <Skeleton active title={{ width: '40%' }} paragraph={{ rows: 1 }} />
            </div>
          ))}
        </div>
      ) : !data || data.length === 0 ? (
        <Empty image={Empty.PRESENTED_IMAGE_SIMPLE}
               description={<span style={{ color: 'var(--ms-ink-subtle)' }}>无匹配记录</span>}
               style={{ marginTop: 80 }} />
      ) : (
        <>
          <div className="ms-enter-stagger"
               style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
            {data.map(e => (
              <EventRow
                key={e.id} event={e}
                expanded={expanded.has(e.id)}
                onToggle={() => {
                  const next = new Set(expanded);
                  if (next.has(e.id)) next.delete(e.id);
                  else next.add(e.id);
                  setExpanded(next);
                }}
              />
            ))}
          </div>
          <div style={{ marginTop: 24, textAlign: 'center' }}>
            <Pagination
              current={page}
              pageSize={PAGE_SIZE}
              total={data.length === PAGE_SIZE ? page * PAGE_SIZE + 1 : (page - 1) * PAGE_SIZE + data.length}
              showSizeChanger={false}
              onChange={setPage}
            />
          </div>
        </>
      )}
    </div>
  );
}

// ─── EventRow ───────────────────────────────────────────────────────────────
function EventRow({
  event: e, expanded, onToggle,
}: { event: AuditEvent; expanded: boolean; onToggle: () => void }) {
  const color = eventColor(e.event_type);
  // W2b: 收起态元信息优先展示补名「项目名 · 文件名」;补名 null(purge 后/历史行)时
  // 回落 UUID 前 8 位(现状行为),key 仍只在展开态显示
  const projectName = e.target_project_name
    ?? (e.target_project_id ? `${e.target_project_id.slice(0, 8)}…` : null);
  const assetName = e.target_asset_filename
    ?? (e.target_asset_id ? `${e.target_asset_id.slice(0, 8)}…` : null);
  // C 包:details 结构化键值列表数据源(空对象 → 渲染空态)
  const detailEntries = Object.entries(e.details ?? {});
  return (
    <div style={{
      position: 'relative',
      padding: '12px 16px 12px 22px',
      background: 'var(--ms-surface)',
      border: '1px solid var(--ms-hairline)',
      borderRadius: 'var(--ms-radius-md)',
      cursor: 'pointer',
      transition: 'border-color var(--ms-dur-fast) var(--ms-ease)',
    }}
    onClick={onToggle}
    onMouseEnter={e => (e.currentTarget.style.borderColor = 'var(--ms-ink-subtle)')}
    onMouseLeave={e => (e.currentTarget.style.borderColor = 'var(--ms-hairline)')}
    >
      <span style={{
        position: 'absolute', left: 0, top: 12, bottom: 12,
        width: 2, background: color,
        borderRadius: '0 2px 2px 0',
      }} />
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
        <ChevronRight size={14} strokeWidth={1.8}
                      style={{
                        color: 'var(--ms-ink-subtle)',
                        transform: expanded ? 'rotate(90deg)' : 'none',
                        transition: 'transform var(--ms-dur-fast) var(--ms-ease)',
                        flexShrink: 0,
                      }} />
        <Tooltip title={e.event_type}>
          <span style={{
            fontFamily: 'var(--ms-font-mono)',
            fontSize: 11.5, color, fontWeight: 500,
            padding: '2px 8px', background: `${color}14`,
            borderRadius: 3,
          }}>{tlabel(e.event_type, EVENT_TYPE_LABEL)}</span>
        </Tooltip>
        <span style={{ fontSize: 13, color: 'var(--ms-ink)' }}>
          {e.actor_name || (
            <span style={{ color: 'var(--ms-ink-subtle)', fontStyle: 'italic' }}>系统</span>
          )}
        </span>
        <div style={{ flex: 1 }} />
        <Tooltip title={dayjs(e.event_time).format('YYYY-MM-DD HH:mm:ss')}>
          <span style={{ fontSize: 11.5, color: 'var(--ms-ink-subtle)',
                          display: 'inline-flex', alignItems: 'center', gap: 4 }}>
            <Clock size={11} strokeWidth={1.8} />
            {dayjs(e.event_time).fromNow()}
          </span>
        </Tooltip>
      </div>

      {/* 元信息行(W2b: project/asset UUID 片段换成「项目名 · 文件名」,有值时) */}
      {!expanded && (
        <div style={{
          marginTop: 6, paddingLeft: 24,
          fontSize: 11.5, color: 'var(--ms-ink-muted)',
          display: 'flex', flexWrap: 'wrap', gap: 16,
        }}>
          {(projectName || assetName) && (
            <span>{[projectName, assetName].filter(Boolean).join(' · ')}</span>
          )}
          {e.request_ip && <span className="ms-mono">{e.request_ip}</span>}
        </div>
      )}

      {/* 展开:full details(C 包 2026-10-19:顶部补操作者 ID/UA/绝对时间;
          details 从整块 JSON dump 改结构化键值列表(id→resolved_names 补名),
          raw JSON 折叠区保留作调试兜底) */}
      {expanded && (
        <div style={{
          marginTop: 10, paddingLeft: 24,
          fontFamily: 'var(--ms-font-mono)', fontSize: 11.5,
          color: 'var(--ms-ink-muted)',
        }}>
          <div>时间: {dayjs(e.event_time).format('YYYY-MM-DD HH:mm:ss')}</div>
          {e.actor_user_id && <div>操作者 ID: {e.actor_user_id}</div>}
          {/* actor_open_id 仅历史飞书行非空(#148 起新用户恒 NULL,单独展示易误导) */}
          {e.actor_open_id && (
            <div title="历史飞书标识(仅历史数据行存在)">
              历史飞书标识: {e.actor_open_id}
            </div>
          )}
          {/* UA 列最长 512,截 120 防撑爆布局;完整值 title 悬浮 */}
          {e.user_agent && (
            <div>UA: <span title={e.user_agent}>{truncateText(e.user_agent, 120)}</span></div>
          )}
          {e.target_project_name && <div>project_name: {e.target_project_name}</div>}
          {e.target_project_id && <div>project: {e.target_project_id}</div>}
          {e.target_asset_filename && <div>asset_filename: {e.target_asset_filename}</div>}
          {e.target_asset_id && <div>asset: {e.target_asset_id}</div>}
          {e.target_minio_key && <div>key: {e.target_minio_key}</div>}
          {e.request_ip && <div>ip: {e.request_ip}</div>}
          {/* details 结构化键值列表(resolved_names 命中 → 名称(id 片段);空对象 → 空态) */}
          <div style={{
            marginTop: 8, display: 'flex', flexDirection: 'column', gap: 2,
            whiteSpace: 'pre-wrap', overflowWrap: 'anywhere',
          }}>
            {detailEntries.length === 0
              ? <div>details: —</div>
              : detailEntries.map(([k, v]) => (
                <div key={k}>
                  {tlabel(k, DETAIL_KEY_LABEL)}: {renderDetailValue(k, v, e.resolved_names)}
                </div>
              ))}
          </div>
          <details style={{ marginTop: 8 }}>
            <summary style={{ cursor: 'pointer', color: 'var(--ms-ink)', userSelect: 'none' }}>
              details
            </summary>
            <pre style={{
              marginTop: 6, padding: 10,
              background: 'var(--ms-canvas)', borderRadius: 'var(--ms-radius-sm)',
              fontSize: 10.5, overflow: 'auto', maxHeight: 320,
              border: '1px solid var(--ms-hairline-soft)',
            }}>{JSON.stringify(e.details, null, 2)}</pre>
          </details>
        </div>
      )}
    </div>
  );
}

// ─── details 值渲染(C 包 2026-10-19)───────────────────────────────────────
// ISO 8601 绝对时间串(如 expires_at)→ 页面统一的 dayjs 绝对格式
const ISO_TIME_RE = /^\d{4}-\d{2}-\d{2}T/;

// UA 列最长 512,展示截断防撑爆键值行(完整值走 title 悬浮)
const truncateText = (s: string, max: number): string =>
  s.length > max ? `${s.slice(0, max)}…` : s;

// subject 串 → 类型标注(前端从原始串前缀取;后端 resolved_names 只回纯名称)
const subjectKindTag = (raw: string): string => {
  if (raw.startsWith('user:')) return '(用户)';
  if (raw.startsWith('group:')) return '(用户组)';
  return '';
};

// subject 串(user:<uuid> / group:<uuid>#member)→ 纯 id 部分(溯源展示用)
const subjectId = (raw: string): string =>
  raw.slice(raw.indexOf(':') + 1).split('#')[0];

// 标量 → 展示串(布尔 → 是/否;ISO 时间串 → 绝对格式;其余原样)
const formatScalar = (x: unknown): string => {
  if (typeof x === 'boolean') return x ? '是' : '否';
  if (x === null || x === undefined) return '—';
  if (typeof x === 'string') {
    return ISO_TIME_RE.test(x) ? dayjs(x).format('YYYY-MM-DD HH:mm:ss') : x;
  }
  return String(x);
};

// 对象数组已知结构({group_id, group_name} 等,实测 user_updated.changes.groups_added)
// → 可读行「名称 (id 前 8 位…)」;未知结构回落紧凑 JSON,杜绝 [object Object]
const formatObjectItem = (item: Record<string, unknown>): string => {
  const name = [item.group_name, item.name, item.username, item.filename]
    .find((x): x is string => typeof x === 'string' && x !== '');
  const id = [item.group_id, item.user_id, item.id, item.asset_id]
    .find((x): x is string => typeof x === 'string' && x !== '');
  if (name !== undefined) {
    return id !== undefined ? `${name} (${id.slice(0, 8)}…)` : name;
  }
  return JSON.stringify(item);
};

// 任意 details 值 → 展示串:标量数组 join('、');对象数组逐项可读/JSON;
// 对象逐字段一行(键同名 label 化),递归复用同一分派
const formatAny = (x: unknown): string => {
  if (Array.isArray(x)) {
    if (x.every((it) => it === null || typeof it !== 'object')) {
      return x.map((it) => formatAny(it)).join('、');
    }
    return x
      .map((it) => (
        it !== null && typeof it === 'object'
          ? formatObjectItem(it as Record<string, unknown>)
          : formatAny(it)
      ))
      .join('\n');
  }
  if (x !== null && typeof x === 'object') {
    return Object.entries(x as Record<string, unknown>)
      .map(([k, v]) => `${tlabel(k, DETAIL_KEY_LABEL)}: ${formatAny(v)}`)
      .join('\n');
  }
  return formatScalar(x);
};

// details 单键值渲染:resolved_names 命中 → 「名称(类型标注) (id 前 8 位…)」并列
// (id 与名称都给,保溯源能力;subject 的 id 取串内 uuid 部分);未命中走通用分派
function renderDetailValue(
  key: string, v: unknown, resolved?: Record<string, string>,
): ReactNode {
  const raw = typeof v === 'string' ? v : null;
  if (raw !== null && raw !== '' && resolved?.[key]) {
    const id8 = (key === 'subject' ? subjectId(raw) : raw).slice(0, 8);
    return <>{resolved[key]}{key === 'subject' ? subjectKindTag(raw) : ''} ({id8}…)</>;
  }
  return formatAny(v);
}

// event_type → 颜色(粗类别)
function eventColor(et: string): string {
  if (et.startsWith('access_denied')) return 'var(--ms-crimson)';
  // 百度网盘备份域(baidu_* 11 项)一组色,避免落到默认灰;
  // tokens.css 暂无第 5 个色相,复用 emerald(与 share/signed_url 同色不同组,仅粗分类)
  if (et.startsWith('baidu_')) return 'var(--ms-emerald)';
  if (et.includes('approval')) return 'var(--ms-amber)';
  if (et.startsWith('share') || et.startsWith('signed_url')) return 'var(--ms-emerald)';
  if (et.startsWith('upload') || et.startsWith('download')) return 'var(--ms-accent)';
  if (et.includes('project') || et.includes('folder') || et.includes('invite'))
    return 'var(--ms-ink)';
  return 'var(--ms-ink-muted)';
}
