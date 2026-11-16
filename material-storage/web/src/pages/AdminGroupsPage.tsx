/**
 * /admin/groups — 本地用户组管理(#150 数据源本地化)。
 * 组 CRUD + 成员管理;成员变更后端同步 OpenFGA group:<uuid>#member tuple,
 * 加成员即时获得组权限、移出即时失去。
 * PR-2: 组级「新建项目」开关(can_create_project,tri-state PATCH — 仅在用户
 * 改动过 Switch 时才携带该字段,省略 = 不动)+ 列表「可建项目」徽标。
 * 管理后台优化:组级「删除项目」开关(can_delete_project,同款 tri-state)+
 * 列表「可删项目」徽标;成员弹窗限高滚动 + 组内搜索过滤(F2)。
 * 目录模板(方案 §4.3/F8):第 3 个组级开关「管理目录模板」(can_manage_folder_templates,
 * tri-state 同款;建组态与编辑态均展示,照 can_create_project 形态)+ 列表「可管模板」徽标。
 * 艺人账号(方案 §4.3/F4):第 4 个组级开关「新建项目时创建艺人账号」
 * (can_create_artist_account,tri-state 同款;仅父开关 can_create_project 开启时展示,
 * 父开关 true→false 转变瞬间复位并显式发 false 清 tuple);全部开关的 extra 长描述
 * 收拢进 label 旁问号图标 tooltip(文案内容不变)。
 * 删除文件/文件夹权限可授予用户组(2026-10-16/F11):第 5 个组级开关「允许组成员删除
 * 文件与文件夹」(can_delete_files,tri-state 同款;建组态与编辑态均展示,建组态直接
 * 随表单提交)+ 列表「可删文件」徽标。
 * 统计面板(2026-11-06 方案 §3.3):第 6 个组级开关「允许组成员查看统计面板」
 * (can_view_stats,tri-state 同款)+ 级联两子开关「使用统计」/「文件上传数量统计」
 * (can_view_usage_stats / can_view_upload_stats,照 artist 方案 F4 模式:子开关仅
 * 父开关开启时展示,父开关 true→false 转变瞬间 setFieldValue(false) + 强制置 touched,
 * 确保该次 PATCH 显式发 false 清 tuple;勿改成 watch+effect 形态)+ 列表「统计」徽标
 * (任一 stats flag 置位时展示)。
 * 用户模块组级授权开放(2026-11-15 方案 F3/F4):「用户模块(可新建用户)」开关
 * (UI-only user_create_enabled,后端无 bool — 授权态 = user_create_grants 集合非空)+
 * 「新建时可选择的用户组」多选(user_create_group_ids,开关开时强制 ≥1;照 can_delete_files
 * tri-state touched 惯例:仅改动过才随 PATCH 携带,开关开→关强制置 touched 并提交 []
 * 撤销授权)+ 组行「用户模块」徽标。
 * §12 增量(2026-11-16 ②):组表单 Modal→Drawer(PC 宽 640,小屏 antd 面板样式自带
 * max-width:100vw 自动钳全宽;取消/保存移入 footer;关闭 touched 复位逻辑原样搬
 * afterOpenChange)+ 布局重组为「分区+紧凑行」(项目/内容/统计/用户模块四个分区,
 * 每行左侧标题+问号提示、右侧 Switch,子项缩进挂父项下)——纯展示层重构,touched/
 * 级联复位/Form.useWatch/校验/initialValues 逐字保留;目标组多选换 GroupSearchSelect
 * (服务端检索防抖,本弹窗不再自挂 useDirectoryGroups)。
 */
import {
  Alert, App, Button, Drawer, Empty, Form, Input, Modal, Popconfirm, Skeleton, Switch, Tooltip,
} from 'antd';
import { QuestionCircleOutlined } from '@ant-design/icons';
import { Pencil, Plus, Search as SearchIcon, Trash2, Users as UsersIcon } from 'lucide-react';
import { useState, type ReactNode } from 'react';
import dayjs from 'dayjs';
import { useMe, useDirectoryGroups, useCreateGroup, useUpdateGroup,
         useDeleteGroup, useGroupMembers, useAddGroupMember, useRemoveGroupMember } from '../api/hooks';
import { errorMessage } from '../api/client';
import { useCompactViewport } from '../lib/use-viewports';
import type { DirectoryGroup } from '../api/types';
import { UserPicker } from '../components/UserPicker';
import { GroupSearchSelect } from '../components/GroupSearchSelect';

/** 开关 label + 问号 tooltip(艺人账号方案 D13/F4:长描述收拢进问号图标,文案内容不变)。*/
function switchLabel(text: string, tip: string): ReactNode {
  return (
    <span>
      {text}{' '}
      <Tooltip title={tip}>
        <QuestionCircleOutlined style={{ color: 'var(--ms-ink-subtle)' }} />
      </Tooltip>
    </span>
  );
}

/** §12:抽屉分区标题(小号次级文字 + 发丝线,分区之间留分隔)。*/
function SectionTitle({ text }: { text: string }) {
  return (
    <div style={{
      margin: '16px 0 4px', paddingBottom: 7,
      borderBottom: '1px solid var(--ms-hairline-soft)',
      fontSize: 11.5, fontWeight: 500, letterSpacing: '0.06em',
      color: 'var(--ms-ink-subtle)',
    }}>{text}</div>
  );
}

/** §12:开关紧凑行容器 — 左侧标题区(label 内含问号 tooltip)flex:1,右侧 Switch;
 *  子项传 indent 缩进挂父项下。纯展示层包裹,Form 状态不受影响。*/
function SwitchRow({ label, indent = false, children }: {
  label: ReactNode; indent?: boolean; children: ReactNode;
}) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 12,
      paddingLeft: indent ? 26 : undefined, padding: '5px 0',
    }}>
      <div style={{ flex: 1, minWidth: 0, fontSize: 13, color: 'var(--ms-ink)' }}>{label}</div>
      {children}
    </div>
  );
}

export default function AdminGroupsPage() {
  const { data: me } = useMe();
  const [q, setQ] = useState('');
  const { data, isLoading } = useDirectoryGroups(q);
  const compact = useCompactViewport();

  if (me && !me.is_system_admin) {
    return (
      <div className="ms-enter" style={{ maxWidth: 520 }}>
        <Alert
          type="warning" showIcon
          message="只有系统管理员可以管理用户组"
          description="如需新建用户组,请联系系统管理员。"
        />
      </div>
    );
  }

  return (
    <div className="ms-enter">
      <GroupsHeader />
      <div style={{ marginBottom: 16, display: 'flex' }}>
        <Input.Search
          value={q}
          onChange={e => setQ(e.target.value)}
          onSearch={v => setQ(v.trim())}
          allowClear placeholder="搜用户组名…"
          style={compact ? { flex: 1, minWidth: 0 } : { width: 260 }} />
      </div>
      {isLoading ? (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          {[0, 1, 2].map(i => (
            <div key={i} style={{
              padding: '16px 20px', background: 'var(--ms-surface)',
              border: '1px solid var(--ms-hairline)', borderRadius: 'var(--ms-radius-md)',
            }}>
              <Skeleton active title={{ width: '40%' }} paragraph={{ rows: 1 }} />
            </div>
          ))}
        </div>
      ) : !data || data.length === 0 ? (
        <Empty image={Empty.PRESENTED_IMAGE_SIMPLE}
               description={<span style={{ color: 'var(--ms-ink-subtle)' }}>无用户组</span>}
               style={{ marginTop: 60 }} />
      ) : (
        <div className="ms-enter-stagger"
             style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          {data.map(g => <GroupRow key={g.id} group={g} />)}
        </div>
      )}
    </div>
  );
}

function GroupsHeader() {
  const [open, setOpen] = useState(false);
  return (
    <div style={{
      display: 'flex', alignItems: 'baseline', justifyContent: 'space-between',
      gap: 24, marginBottom: 'var(--ms-sp-xl)',
    }}>
      <div>
        <h1 style={{
          margin: 0, fontFamily: 'var(--ms-font-display)',
          fontSize: 32, fontWeight: 500, letterSpacing: '-0.02em',
          color: 'var(--ms-ink)', lineHeight: 1.1,
        }}>用户组</h1>
        <p style={{ margin: '8px 0 0', fontSize: 13, color: 'var(--ms-ink-muted)' }}>
          本地组管理 — 组内成员立即生效于全部授权规则(OpenFGA group#member)
        </p>
      </div>
      <Button type="primary" icon={<Plus size={14} strokeWidth={2} />}
              onClick={() => setOpen(true)}>
        新建用户组
      </Button>
      <GroupFormModal open={open} onClose={() => setOpen(false)} />
    </div>
  );
}

function GroupRow({ group }: { group: DirectoryGroup }) {
  const { message } = App.useApp();
  const [membersOpen, setMembersOpen] = useState(false);
  const [editOpen, setEditOpen] = useState(false);
  const del = useDeleteGroup();
  const [deleting, setDeleting] = useState(false);
  const compact = useCompactViewport();

  const doDelete = async () => {
    setDeleting(true);
    try {
      await del.mutateAsync(group.id);
      message.success(`已删除用户组「${group.name}」`);
    } catch (e) {
      message.error(errorMessage(e, '删除失败'));
    } finally { setDeleting(false); }
  };

  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap',
      padding: '12px 16px', background: 'var(--ms-surface)',
      border: '1px solid var(--ms-hairline)', borderRadius: 'var(--ms-radius-md)',
    }}>
      <div style={{
        display: 'grid', placeItems: 'center', width: 34, height: 34, flexShrink: 0,
        background: 'var(--ms-emerald)14', borderRadius: 'var(--ms-radius-sm)',
        color: 'var(--ms-emerald)',
      }}>
        <UsersIcon size={16} strokeWidth={1.8} />
      </div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
          <span style={{ fontSize: 13, fontWeight: 500, color: 'var(--ms-ink)' }}>{group.name}</span>
          <span style={{
            fontFamily: 'var(--ms-font-mono)', fontSize: 10.5, color: 'var(--ms-ink-subtle)',
            padding: '1px 7px', background: 'var(--ms-hairline-soft)', borderRadius: 3,
          }}>
            {group.member_count} 人
          </span>
          {/* PR-2: 组级「新建项目」权限徽标(真实态以列表接口的 tuple 定向 read 为准) */}
          {group.can_create_project && (
            <Tooltip title="组内成员可自行新建项目,并自动成为所建项目的管理员">
              <span style={{
                padding: '1px 7px', fontSize: 10, letterSpacing: '0.04em',
                fontFamily: 'var(--ms-font-mono)',
                color: 'var(--ms-accent)', background: 'var(--ms-accent-soft)',
                borderRadius: 3,
              }}>可建项目</span>
            </Tooltip>
          )}
          {/* can_delete_project 徽标(与「可建项目」同款样式,crimson 示危险操作) */}
          {group.can_delete_project && (
            <Tooltip title="组内成员可删除项目(逻辑删除;可在项目列表「已删除项目」中恢复)">
              <span style={{
                padding: '1px 7px', fontSize: 10, letterSpacing: '0.04em',
                fontFamily: 'var(--ms-font-mono)',
                color: 'var(--ms-crimson)', background: 'var(--ms-crimson)14',
                borderRadius: 3,
              }}>可删项目</span>
            </Tooltip>
          )}
          {/* can_manage_folder_templates 徽标(目录模板方案 §4.3;与「可建项目」同款样式) */}
          {group.can_manage_folder_templates && (
            <Tooltip title="组内成员可维护目录模板(新建 / 编辑 / 删除),并在新建项目时选用">
              <span style={{
                padding: '1px 7px', fontSize: 10, letterSpacing: '0.04em',
                fontFamily: 'var(--ms-font-mono)',
                color: 'var(--ms-accent)', background: 'var(--ms-accent-soft)',
                borderRadius: 3,
              }}>可管模板</span>
            </Tooltip>
          )}
          {/* can_delete_files 徽标(删除文件/文件夹组授权;与「可删项目」同款 crimson 示危险操作) */}
          {group.can_delete_files && (
            <Tooltip title="组内成员可删除其可见文件夹中的文件与文件夹(软删除,可在回收站恢复或彻底删除;敏感目录不在此列)">
              <span style={{
                padding: '1px 7px', fontSize: 10, letterSpacing: '0.04em',
                fontFamily: 'var(--ms-font-mono)',
                color: 'var(--ms-crimson)', background: 'var(--ms-crimson)14',
                borderRadius: 3,
              }}>可删文件</span>
            </Tooltip>
          )}
          {/* 统计徽标(2026-11-06 方案 §3.3):任一 stats flag 置位即展示一枚「统计」
              (样式照「可建项目」;子权限详情在编辑弹窗可见,不逐枚加徽标防拥挤) */}
          {(group.can_view_stats || group.can_view_usage_stats || group.can_view_upload_stats) && (
            <Tooltip title="组内成员可见「统计」面板(使用统计 / 文件上传数量统计子模块权限在编辑弹窗内单独配置)">
              <span style={{
                padding: '1px 7px', fontSize: 10, letterSpacing: '0.04em',
                fontFamily: 'var(--ms-font-mono)',
                color: 'var(--ms-accent)', background: 'var(--ms-accent-soft)',
                borderRadius: 3,
              }}>统计</span>
            </Tooltip>
          )}
          {/* 用户模块徽标(2026-11-15 方案 F4):授权态 = user_create_grants 目标组集合非空,
              样式照「可建项目」;tooltip 列目标组名(names 缺失时回落数量) */}
          {(group.user_create_group_ids?.length ?? 0) > 0 && (
            <Tooltip title={`组内成员可使用「用户」模块,新建用户时可选择目标组:${
              (group.user_create_group_names ?? []).join('、')
              || `${group.user_create_group_ids!.length} 个组`}`}>
              <span style={{
                padding: '1px 7px', fontSize: 10, letterSpacing: '0.04em',
                fontFamily: 'var(--ms-font-mono)',
                color: 'var(--ms-accent)', background: 'var(--ms-accent-soft)',
                borderRadius: 3,
              }}>用户模块</span>
            </Tooltip>
          )}
        </div>
        {group.description && (
          <div style={{
            marginTop: 3, fontSize: 11.5, color: 'var(--ms-ink-muted)',
            overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
          }}>{group.description}</div>
        )}
      </div>
      {/* compact: 日期占满一整行,操作按钮换行到下一行 */}
      <span style={{
        fontSize: 11.5, color: 'var(--ms-ink-subtle)', whiteSpace: 'nowrap',
        flexBasis: compact ? '100%' : undefined,
      }}>
        创建于 {dayjs(group.created_at).format('YYYY-MM-DD')}
      </span>
      <div style={{ display: 'flex', gap: 6, flexShrink: 0 }}>
        <Button size="small" onClick={() => setMembersOpen(true)}>成员</Button>
        <Tooltip title="改名 / 改描述">
          <Button size="small" icon={<Pencil size={12} strokeWidth={2} />}
                  onClick={() => setEditOpen(true)} />
        </Tooltip>
        <Popconfirm
          title={`删除用户组「${group.name}」?`}
          description={`组内 ${group.member_count} 名成员将立即失去该组授予的全部权限`}
          okText="删除" okButtonProps={{ danger: true }}
          onConfirm={doDelete}
        >
          <Button size="small" danger icon={<Trash2 size={12} strokeWidth={2} />}
                  loading={deleting} />
        </Popconfirm>
      </div>
      <GroupMembersDrawer group={group} open={membersOpen} onClose={() => setMembersOpen(false)} />
      <GroupFormModal open={editOpen} onClose={() => setEditOpen(false)} group={group} />
    </div>
  );
}

// ─── 新建 / 编辑组 ───────────────────────────────────────────────────────────
function GroupFormModal({ open, onClose, group }: {
  open: boolean; onClose: () => void; group?: DirectoryGroup;
}) {
  const create = useCreateGroup();
  const update = useUpdateGroup();
  const [form] = Form.useForm();
  const { message } = App.useApp();
  const isEdit = !!group;
  // PR-2 tri-state:仅当用户改动过开关,PATCH 才携带 can_create_project
  // (否则省略 = None 不动 —— 防「仅改名保存」也触发 tuple 重写/静默撤权,方案 §2.2)
  const [flagTouched, setFlagTouched] = useState(false);
  // can_delete_project 同款 tri-state(仅在编辑态展示)
  const [deleteFlagTouched, setDeleteFlagTouched] = useState(false);
  // can_manage_folder_templates 同款 tri-state(建组态与编辑态均展示,方案 §4.3)
  const [folderFlagTouched, setFolderFlagTouched] = useState(false);
  // 艺人账号(方案 §4.3/F4):can_create_artist_account 同款 tri-state;
  // 父开关 true→false 转变瞬间的复位也会强制置 touched(PATCH 显式发 false 清 tuple)
  const [artistFlagTouched, setArtistFlagTouched] = useState(false);
  // 删除文件/文件夹组授权(2026-10-16/F11):can_delete_files 同款 tri-state
  const [filesFlagTouched, setFilesFlagTouched] = useState(false);
  // 统计面板(2026-11-06 方案 §3.3):can_view_stats 父开关 + 两子开关 tri-state;
  // 父开关 true→false 转变瞬间的级联复位也会强制置两个子 touched(PATCH 显式发 false 清 tuple)
  const [statsFlagTouched, setStatsFlagTouched] = useState(false);
  const [usageStatsFlagTouched, setUsageStatsFlagTouched] = useState(false);
  const [uploadStatsFlagTouched, setUploadStatsFlagTouched] = useState(false);
  // 用户模块组级授权开放(2026-11-15 方案 F3):开关(user_create_enabled,UI-only —
  // 后端无 bool,授权态 = user_create_grants 集合非空)+ 目标组多选(user_create_group_ids)
  // 各自 tri-state touched;开关开→关强制置 ids touched 并 setFieldValue([]),
  // 确保该次 PATCH 显式发 [] 撤销授权(照 stats 父开关级联复位惯例)
  const [userCreateFlagTouched, setUserCreateFlagTouched] = useState(false);
  const [userCreateIdsTouched, setUserCreateIdsTouched] = useState(false);
  // 子开关仅父开关开启时展示(建组态与编辑态均适用);数据驱动,弹窗挂载时父已 false
  // 不做任何复位动作 —— 防「仅改名保存」静默撤权(directory.py tri-state 注释明确防范)
  const canCreateProject = Form.useWatch('can_create_project', form) === true;
  // 统计面板两子开关同款:Form.useWatch 控渲染(照 artist F4,勿改成 watch+effect)
  const canViewStats = Form.useWatch('can_view_stats', form) === true;
  // 用户模块目标组多选同款:Form.useWatch 控渲染(勿改成 watch+effect)
  const userCreateEnabled = Form.useWatch('user_create_enabled', form) === true;
  // F3 目标组多选:选项来源升级为 GroupSearchSelect(§12 服务端检索防抖),
  // 组件内部自挂 useDirectoryGroups(词, 200),本弹窗不再重复挂载。

  const submit = async () => {
    try {
      const v = await form.validateFields();
      if (isEdit) {
        await update.mutateAsync({
          groupId: group.id,
          name: v.name?.trim(),
          description: v.description?.trim() || null,
          ...(flagTouched ? { can_create_project: v.can_create_project === true } : {}),
          ...(deleteFlagTouched ? { can_delete_project: v.can_delete_project === true } : {}),
          ...(folderFlagTouched
            ? { can_manage_folder_templates: v.can_manage_folder_templates === true } : {}),
          ...(artistFlagTouched
            ? { can_create_artist_account: v.can_create_artist_account === true } : {}),
          ...(filesFlagTouched ? { can_delete_files: v.can_delete_files === true } : {}),
          ...(statsFlagTouched ? { can_view_stats: v.can_view_stats === true } : {}),
          ...(usageStatsFlagTouched
            ? { can_view_usage_stats: v.can_view_usage_stats === true } : {}),
          ...(uploadStatsFlagTouched
            ? { can_view_upload_stats: v.can_view_upload_stats === true } : {}),
          // F3: user_create_group_ids tri-state —— 开关或目标组选择改动过才携带
          // (undefined 省略 = None 不动);开关已关时目标组字段随条件挂载卸载
          // (preserve=false 值不进 form store),`?? []` 显式发 [] = 撤销授权
          ...(userCreateFlagTouched || userCreateIdsTouched
            ? { user_create_group_ids: (v.user_create_group_ids ?? []) as string[] } : {}),
        });
        message.success('已保存');
      } else {
        await create.mutateAsync({
          name: v.name.trim(),
          description: v.description?.trim(),
          can_create_project: v.can_create_project === true,
          can_manage_folder_templates: v.can_manage_folder_templates === true,
          can_create_artist_account: v.can_create_artist_account === true,
          can_delete_files: v.can_delete_files === true,
          // 统计面板三开关:新建 POST 全量传(方案 §3.3)
          can_view_stats: v.can_view_stats === true,
          can_view_usage_stats: v.can_view_usage_stats === true,
          can_view_upload_stats: v.can_view_upload_stats === true,
          // F3: 新建 POST 全量传(照 can_delete_files 惯例;开关关时 `?? []` = 不授权)
          user_create_group_ids: (v.user_create_group_ids ?? []) as string[],
        });
        message.success(`用户组「${v.name.trim()}」已创建`);
      }
      onClose();
    } catch (e) {
      if ((e as { errorFields?: unknown }).errorFields) return;
      message.error(errorMessage(e, isEdit ? '保存失败' : '创建失败'));
    }
  };

  return (
    <Drawer
      title={isEdit ? `编辑用户组 — ${group.name}` : '新建用户组'}
      open={open} onClose={onClose} destroyOnHidden width={640}
      afterOpenChange={(o) => {
        if (!o) {
          setFlagTouched(false); setDeleteFlagTouched(false);
          setFolderFlagTouched(false); setArtistFlagTouched(false);
          setFilesFlagTouched(false);
          setStatsFlagTouched(false);
          setUsageStatsFlagTouched(false); setUploadStatsFlagTouched(false);
          setUserCreateFlagTouched(false); setUserCreateIdsTouched(false);
        }
      }}
      footer={
        <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8 }}>
          <Button onClick={onClose}>取消</Button>
          <Button type="primary" loading={isEdit ? update.isPending : create.isPending}
                  onClick={submit}>
            {isEdit ? '保存' : '创建'}
          </Button>
        </div>
      }>
      <Form key={isEdit ? group.id : 'new'} form={form} layout="vertical" preserve={false}
            initialValues={group ? {
              name: group.name, description: group.description || undefined,
              can_create_project: group.can_create_project ?? false,
              can_delete_project: group.can_delete_project ?? false,
              can_manage_folder_templates: group.can_manage_folder_templates ?? false,
              can_create_artist_account: group.can_create_artist_account ?? false,
              can_delete_files: group.can_delete_files ?? false,
              can_view_stats: group.can_view_stats ?? false,
              can_view_usage_stats: group.can_view_usage_stats ?? false,
              can_view_upload_stats: group.can_view_upload_stats ?? false,
              // F3: 回显 — 授权态 = 目标组集合非空;ids 预填多选
              user_create_enabled: (group.user_create_group_ids ?? []).length > 0,
              user_create_group_ids: group.user_create_group_ids ?? [],
            } : {
              can_create_project: false,
              can_manage_folder_templates: false,
              can_create_artist_account: false,
              can_delete_files: false,
              can_view_stats: false,
              can_view_usage_stats: false,
              can_view_upload_stats: false,
              user_create_enabled: false,
              user_create_group_ids: [],
            }}>
        <Form.Item name="name" label="组名" rules={[{ required: true, max: 128 }]}>
          <Input placeholder="策划组" autoFocus />
        </Form.Item>
        <Form.Item name="description" label="描述(可选)" rules={[{ max: 1024 }]}>
          <Input.TextArea rows={2} maxLength={1024} showCount />
        </Form.Item>
        {/* §12:以下为「分区+紧凑行」纯展示层重组 —— 每行 SwitchRow(左标题+问号提示,
            右 Switch),子项 indent 缩进挂父项下;Form.Item name/valuePropName、Switch
            onChange(级联复位/置 touched)、Form.useWatch 条件渲染、校验 rules、
            initialValues 逐字保留,仅移动视觉位置。*/}

        {/* ── 项目 ── */}
        <SectionTitle text="项目" />
        <SwitchRow label={switchLabel(
          '允许组成员新建项目',
          '开启后组内成员可自行新建项目,并自动成为所建项目的管理员;系统管理员不受此开关影响',
        )}>
          <Form.Item name="can_create_project" valuePropName="checked"
                     style={{ marginBottom: 0, flexShrink: 0 }}>
            <Switch checkedChildren="开" unCheckedChildren="关"
                    onChange={(checked) => {
                      setFlagTouched(true);
                      // 子开关复位时机写死(艺人账号方案 F4):仅父开关 onChange 由 true→false
                      // 的转变瞬间执行 setFieldValue(false) + 置 touched,确保该次 PATCH 显式
                      // 发 can_create_artist_account: false 清 tuple;弹窗挂载时父已 false 不触发
                      if (!checked) {
                        form.setFieldValue('can_create_artist_account', false);
                        setArtistFlagTouched(true);
                      }
                    }} />
          </Form.Item>
        </SwitchRow>
        {/* 艺人账号第 4 开关(方案 §4.3/F4):仅父开关开启时展示(建组态与编辑态均适用);
            复位只在父开关 onChange true→false 转变瞬间做,勿改成 watch+effect 形态 */}
        {canCreateProject && (
          <SwitchRow indent label={switchLabel(
            '允许组成员新建项目时创建艺人账号',
            '开启后,组内成员新建项目时可同时填写艺人登录名与姓名,同步开通艺人账号(自动加入「艺人」用户组并获得该项目上传/下载/查看权限);系统管理员不受此开关影响',
          )}>
            <Form.Item name="can_create_artist_account" valuePropName="checked"
                       style={{ marginBottom: 0, flexShrink: 0 }}>
              <Switch checkedChildren="开" unCheckedChildren="关"
                      onChange={() => setArtistFlagTouched(true)} />
            </Form.Item>
          </SwitchRow>
        )}
        {isEdit && (
          <SwitchRow label={switchLabel(
            '允许组成员删除项目',
            '开启后组内成员可删除其可见的项目(逻辑删除,数据保留,可在「已删除项目」中恢复);系统管理员不受此开关影响',
          )}>
            <Form.Item name="can_delete_project" valuePropName="checked"
                       style={{ marginBottom: 0, flexShrink: 0 }}>
              <Switch checkedChildren="开" unCheckedChildren="关"
                      onChange={() => setDeleteFlagTouched(true)} />
            </Form.Item>
          </SwitchRow>
        )}
        {/* 目录模板第 3 开关(建组态与编辑态均展示,照 can_create_project 形态;勿改回
            can_delete_project 的仅编辑态 {isEdit && …} 形态,方案 §6-F8) */}
        <SwitchRow label={switchLabel(
          '允许组成员管理目录模板',
          '开启后组内成员可维护目录模板(新建 / 编辑 / 删除),并在新建项目时选用;系统管理员不受此开关影响',
        )}>
          <Form.Item name="can_manage_folder_templates" valuePropName="checked"
                     style={{ marginBottom: 0, flexShrink: 0 }}>
            <Switch checkedChildren="开" unCheckedChildren="关"
                    onChange={() => setFolderFlagTouched(true)} />
          </Form.Item>
        </SwitchRow>

        {/* ── 内容 ── */}
        {/* 删除文件/文件夹第 5 开关(2026-10-16/F11):建组态与编辑态均展示(后端
            POST 同样接受 can_delete_files);编辑态 tri-state 仅在用户改动过时才携带 */}
        <SectionTitle text="内容" />
        <SwitchRow label={switchLabel(
          '允许组成员删除文件与文件夹',
          '开启后组内成员可删除其可见文件夹中的文件与文件夹(软删除,可在回收站恢复或彻底删除;敏感目录不在此列,维持原有权限);系统管理员不受此开关影响',
        )}>
          <Form.Item name="can_delete_files" valuePropName="checked"
                     style={{ marginBottom: 0, flexShrink: 0 }}>
            <Switch checkedChildren="开" unCheckedChildren="关"
                    onChange={() => setFilesFlagTouched(true)} />
          </Form.Item>
        </SwitchRow>

        {/* ── 统计 ── */}
        {/* 统计面板父开关(2026-11-06 方案 §3.3,建组态与编辑态均展示):面板入口 flag;
            后端守门为 is_org_admin ∨ (stats_viewer ∧ 对应子),父子约束靠本页 UI 级联落实 */}
        <SectionTitle text="统计" />
        <SwitchRow label={switchLabel(
          '允许组成员查看统计面板',
          '开启后组内成员可见「统计」入口(具体子模块权限见下方两个开关);系统管理员不受此开关影响',
        )}>
          <Form.Item name="can_view_stats" valuePropName="checked"
                     style={{ marginBottom: 0, flexShrink: 0 }}>
            <Switch checkedChildren="开" unCheckedChildren="关"
                    onChange={(checked) => {
                      setStatsFlagTouched(true);
                      // 级联复位时机写死(照 artist F4):仅父开关 onChange 由 true→false
                      // 的转变瞬间 setFieldValue(false) + 强制置两个 touched,确保该次
                      // PATCH 显式发 false 清 tuple;弹窗挂载时父已 false 不触发
                      if (!checked) {
                        form.setFieldValue('can_view_usage_stats', false);
                        form.setFieldValue('can_view_upload_stats', false);
                        setUsageStatsFlagTouched(true);
                        setUploadStatsFlagTouched(true);
                      }
                    }} />
          </Form.Item>
        </SwitchRow>
        {/* 统计两子开关(照 artist F4):仅父开关开启时展示(建组态与编辑态均适用);
            复位只在父开关 onChange true→false 转变瞬间做,勿改成 watch+effect 形态 */}
        {canViewStats && (
          <>
            <SwitchRow indent label={switchLabel(
              '子模块:使用统计',
              '开启后组内成员可经统计面板查看客户端三端占比 / 内外网占比(依托审计日志聚合);系统管理员不受此开关影响',
            )}>
              <Form.Item name="can_view_usage_stats" valuePropName="checked"
                         style={{ marginBottom: 0, flexShrink: 0 }}>
                <Switch checkedChildren="开" unCheckedChildren="关"
                        onChange={() => setUsageStatsFlagTouched(true)} />
              </Form.Item>
            </SwitchRow>
            <SwitchRow indent label={switchLabel(
              '子模块:文件上传数量统计',
              '开启后组内成员可经统计面板查看按项目分类的上传数量统计(遵守数据权限);系统管理员不受此开关影响',
            )}>
              <Form.Item name="can_view_upload_stats" valuePropName="checked"
                         style={{ marginBottom: 0, flexShrink: 0 }}>
                <Switch checkedChildren="开" unCheckedChildren="关"
                        onChange={() => setUploadStatsFlagTouched(true)} />
              </Form.Item>
            </SwitchRow>
          </>
        )}

        {/* ── 用户模块 ── */}
        {/* 用户模块组级授权开放(2026-11-15 方案 F3):父开关 UI-only(后端无 bool,
            授权态 = 下方目标组集合非空);开→关的级联复位照 stats 惯例仅在 onChange
            true→false 转变瞬间做(setFieldValue([]) + 强制置 ids touched → PATCH 显式
            发 [] 撤销授权),勿改成 watch+effect 形态 */}
        <SectionTitle text="用户模块" />
        <SwitchRow label={switchLabel(
          '用户模块(可新建用户)',
          '开启后组内成员可见「用户」模块:可查看自己创建的用户、新建用户(加入下方所选目标组)并重置自建用户密码;编辑/停用/启用等仍仅系统管理员。关闭并保存即撤销授权(此前创建的用户归属不变,但创建者立即失去可见与操作权)',
        )}>
          <Form.Item name="user_create_enabled" valuePropName="checked"
                     style={{ marginBottom: 0, flexShrink: 0 }}>
            <Switch checkedChildren="开" unCheckedChildren="关"
                    onChange={(checked) => {
                      setUserCreateFlagTouched(true);
                      if (!checked) {
                        form.setFieldValue('user_create_group_ids', []);
                        setUserCreateIdsTouched(true);
                      }
                    }} />
          </Form.Item>
        </SwitchRow>
        {/* F3: 目标组多选(仅父开关开启时展示;开关开时校验 ≥1 才允许提交)。
            值变更即置 touched → 该次 PATCH 携带全量终态(list = 全量替换)。
            §12: 选项来源换 GroupSearchSelect(服务端检索防抖 300ms + 已选缓存合并,
            Form.Item name/rules/onChange 置 touched 均不变) */}
        {userCreateEnabled && (
          <div style={{ paddingLeft: 26 }}>
            <Form.Item name="user_create_group_ids"
                       label={switchLabel(
                         '新建时可选择的用户组',
                         '组成员新建用户时,可把用户加入这些目标组(可含本组);至少选择 1 个',
                       )}
                       rules={[{
                         validator: (_, v: unknown) =>
                           Array.isArray(v) && v.length >= 1
                             ? Promise.resolve()
                             : Promise.reject(new Error('至少选择 1 个目标用户组')),
                       }]}
                       style={{ marginTop: 4, marginBottom: 0 }}>
              <GroupSearchSelect onChange={() => setUserCreateIdsTouched(true)} />
            </Form.Item>
          </div>
        )}
      </Form>
    </Drawer>
  );
}

// ─── 成员管理 ───────────────────────────────────────────────────────────────
function GroupMembersDrawer({ group, open, onClose }: {
  group: DirectoryGroup; open: boolean; onClose: () => void;
}) {
  const { data: members, isLoading } = useGroupMembers(open ? group.id : undefined);
  const add = useAddGroupMember();
  const remove = useRemoveGroupMember();
  const { message } = App.useApp();
  const [selected, setSelected] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  // F2: 组内搜索 — 对已加成员按 username/name/email 忽略大小写子串过滤(纯前端)
  const [memberQ, setMemberQ] = useState('');

  const all = members ?? [];
  const kw = memberQ.trim().toLowerCase();
  const filtered = kw
    ? all.filter(m => [m.username, m.name, m.email]
        .some(v => (v ?? '').toLowerCase().includes(kw)))
    : all;
  const total = all.length || group.member_count;

  const doAdd = async () => {
    if (selected.length === 0) return;
    setBusy(true);
    let ok = 0;
    try {
      for (const userId of selected) {
        await add.mutateAsync({ groupId: group.id, user_id: userId });
        ok++;
      }
      message.success(`已添加 ${ok} 名成员`);
      setSelected([]);
    } catch (e) {
      message.error(errorMessage(e, '添加失败'));
    } finally { setBusy(false); }
  };

  const doRemove = async (userId: string, name: string) => {
    try {
      await remove.mutateAsync({ groupId: group.id, userId });
      message.success(`已移出 ${name}`);
    } catch (e) {
      message.error(errorMessage(e, '移出失败'));
    }
  };

  return (
    <Modal title={`成员 — ${group.name}(${kw ? `${filtered.length}/${total}` : total} 人)`}
           open={open} onCancel={onClose} footer={null}
           afterOpenChange={(o) => { if (!o) setMemberQ(''); }}
           width="min(560px, calc(100vw - 16px))">
      <div style={{ display: 'flex', gap: 8, marginBottom: 12 }}>
        <div style={{ flex: 1 }}>
          <UserPicker
            value={selected}
            onChange={v => setSelected(v as string[])}
            placeholder="搜姓名 / 用户名加成员…"
          />
        </div>
        <Button type="primary" onClick={doAdd} loading={busy}>添加</Button>
      </div>
      <Input
        value={memberQ}
        onChange={e => setMemberQ(e.target.value)}
        allowClear
        prefix={<SearchIcon size={13} strokeWidth={1.8} />}
        placeholder="在组内搜索 — 用户名 / 姓名 / 邮箱"
        style={{ marginBottom: 12 }}
      />
      {isLoading ? (
        <Skeleton active paragraph={{ rows: 3 }} />
      ) : all.length === 0 ? (
        <Empty image={Empty.PRESENTED_IMAGE_SIMPLE}
               description={<span style={{ color: 'var(--ms-ink-subtle)' }}>暂无成员</span>} />
      ) : filtered.length === 0 ? (
        <Empty image={Empty.PRESENTED_IMAGE_SIMPLE}
               description={<span style={{ color: 'var(--ms-ink-subtle)' }}>无匹配成员</span>} />
      ) : (
        // F2.1: 限高滚动 — 成员再多弹窗也不被撑开
        <div style={{
          display: 'flex', flexDirection: 'column', gap: 6,
          maxHeight: 'min(420px, 60vh)', overflowY: 'auto',
        }}>
          {filtered.map(m => (
            <div key={m.user_id} style={{
              display: 'flex', alignItems: 'center', gap: 10,
              padding: '8px 12px', background: 'var(--ms-canvas)',
              border: '1px solid var(--ms-hairline-soft)', borderRadius: 'var(--ms-radius-sm)',
              flexShrink: 0,
            }}>
              <div style={{ flex: 1, minWidth: 0 }}>
                <span style={{ fontSize: 13, color: 'var(--ms-ink)' }}>{m.name}</span>
                {!m.is_active && (
                  <span style={{
                    marginLeft: 8, fontFamily: 'var(--ms-font-mono)', fontSize: 10.5,
                    color: 'var(--ms-crimson)', padding: '1px 6px',
                    background: 'var(--ms-crimson)14', borderRadius: 3,
                  }}>已停用</span>
                )}
                <div style={{
                  marginTop: 2, fontSize: 11, color: 'var(--ms-ink-subtle)',
                  fontFamily: 'var(--ms-font-mono)',
                }}>
                  {m.username || '—'}{m.email ? ` · ${m.email}` : ''}
                </div>
              </div>
              <Popconfirm
                title={`把 ${m.name} 移出该组?`}
                description="其将立即失去该组授予的全部权限"
                okText="移出" okButtonProps={{ danger: true }}
                onConfirm={() => doRemove(m.user_id, m.name)}
              >
                <Button size="small" danger>移出</Button>
              </Popconfirm>
            </div>
          ))}
        </div>
      )}
    </Modal>
  );
}
