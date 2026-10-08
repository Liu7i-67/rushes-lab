/**
 * /admin/groups — 本地用户组管理(#150 数据源本地化)。
 * 组 CRUD + 成员管理;成员变更后端同步 OpenFGA group:<uuid>#member tuple,
 * 加成员即时获得组权限、移出即时失去。
 * PR-2: 组级「新建项目」开关(can_create_project,tri-state PATCH — 仅在用户
 * 改动过 Switch 时才携带该字段,省略 = 不动)+ 列表「可建项目」徽标。
 */
import {
  Alert, App, Button, Empty, Form, Input, Modal, Popconfirm, Skeleton, Switch, Tooltip,
} from 'antd';
import { Pencil, Plus, Trash2, Users as UsersIcon } from 'lucide-react';
import { useState } from 'react';
import dayjs from 'dayjs';
import { useMe, useDirectoryGroups, useCreateGroup, useUpdateGroup,
         useDeleteGroup, useGroupMembers, useAddGroupMember, useRemoveGroupMember } from '../api/hooks';
import { errorMessage } from '../api/client';
import { useCompactViewport } from '../lib/use-viewports';
import type { DirectoryGroup } from '../api/types';
import { UserPicker } from '../components/UserPicker';

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

  const submit = async () => {
    try {
      const v = await form.validateFields();
      if (isEdit) {
        await update.mutateAsync({
          groupId: group.id,
          name: v.name?.trim(),
          description: v.description?.trim() || null,
          ...(flagTouched ? { can_create_project: v.can_create_project === true } : {}),
        });
        message.success('已保存');
      } else {
        await create.mutateAsync({
          name: v.name.trim(),
          description: v.description?.trim(),
          can_create_project: v.can_create_project === true,
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
    <Modal title={isEdit ? `编辑用户组 — ${group.name}` : '新建用户组'}
           open={open} onCancel={onClose} destroyOnClose
           afterOpenChange={(o) => { if (!o) setFlagTouched(false); }}
           confirmLoading={isEdit ? update.isPending : create.isPending}
           onOk={submit} okText={isEdit ? '保存' : '创建'}>
      <Form key={isEdit ? group.id : 'new'} form={form} layout="vertical" preserve={false}
            initialValues={group ? {
              name: group.name, description: group.description || undefined,
              can_create_project: group.can_create_project ?? false,
            } : { can_create_project: false }}>
        <Form.Item name="name" label="组名" rules={[{ required: true, max: 128 }]}>
          <Input placeholder="策划组" autoFocus />
        </Form.Item>
        <Form.Item name="description" label="描述(可选)" rules={[{ max: 1024 }]}>
          <Input.TextArea rows={2} maxLength={1024} showCount />
        </Form.Item>
        <Form.Item name="can_create_project" label="允许组成员新建项目" valuePropName="checked"
                   extra="开启后组内成员可自行新建项目,并自动成为所建项目的管理员;系统管理员不受此开关影响">
          <Switch checkedChildren="开" unCheckedChildren="关"
                  onChange={() => setFlagTouched(true)} />
        </Form.Item>
      </Form>
    </Modal>
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
    <Modal title={`成员 — ${group.name}(${members?.length ?? group.member_count} 人)`}
           open={open} onCancel={onClose} footer={null}
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
      {isLoading ? (
        <Skeleton active paragraph={{ rows: 3 }} />
      ) : !members || members.length === 0 ? (
        <Empty image={Empty.PRESENTED_IMAGE_SIMPLE}
               description={<span style={{ color: 'var(--ms-ink-subtle)' }}>暂无成员</span>} />
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          {members.map(m => (
            <div key={m.user_id} style={{
              display: 'flex', alignItems: 'center', gap: 10,
              padding: '8px 12px', background: 'var(--ms-canvas)',
              border: '1px solid var(--ms-hairline-soft)', borderRadius: 'var(--ms-radius-sm)',
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
