/**
 * /admin/users — 本地用户管理(#150 数据源本地化)。
 * 系统 admin 创建本地账号(临时密码 + must_change_password)、停用/启用、重置密码。
 * backend 对目录接口 enforce system admin;前端仅做体验提示。
 * 管理后台优化:新建用户可选用户组(F3.1)、行内编辑姓名/邮箱/用户组(F4.1)、
 * 服务端分页 + 总数(F5.2)。
 */
import {
  Alert, App, Button, Empty, Form, Input, Modal, Pagination, Select, Skeleton, Tooltip,
} from 'antd';
import { KeyRound, Pencil, Power, RotateCcw, UserPlus } from 'lucide-react';
import { useState } from 'react';
import dayjs from 'dayjs';
import { useMe, useCreateUser, useUpdateUser, useDirectoryUserDetail, useDirectoryGroups,
         useDisableUser, useEnableUser, useDirectoryUsers, useResetUserPassword,
         USERS_PAGE_SIZE } from '../api/hooks';
import { errorMessage } from '../api/client';
import { copyToClipboard } from '../utils/copy';
import { useCompactViewport } from '../lib/use-viewports';
import type { DirectoryUser, DirectoryUserCreateOut } from '../api/types';

export default function AdminUsersPage() {
  const { data: me } = useMe();
  const [q, setQ] = useState('');
  const [isActive, setIsActive] = useState<boolean | undefined>(undefined);
  // F5.2: 服务端分页(pageSize 20;q/is_active 筛选变化重置回第 1 页)
  const [page, setPage] = useState(1);
  const { data, isLoading } = useDirectoryUsers({
    q, is_active: isActive, limit: USERS_PAGE_SIZE, offset: (page - 1) * USERS_PAGE_SIZE,
  });
  const handleQ = (v: string) => { setQ(v); setPage(1); };
  const handleIsActive = (v: boolean | undefined) => { setIsActive(v); setPage(1); };

  if (me && !me.is_system_admin) {
    return (
      <div className="ms-enter" style={{ maxWidth: 520 }}>
        <Alert
          type="warning" showIcon
          message="只有系统管理员可以管理用户"
          description="如需创建本地账号,请联系系统管理员。"
        />
      </div>
    );
  }

  return (
    <div className="ms-enter">
      <UsersHeader />
      <FilterBar q={q} setQ={handleQ} isActive={isActive} setIsActive={handleIsActive}
                 total={data?.total} />
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
      ) : !data || data.items.length === 0 ? (
        <Empty image={Empty.PRESENTED_IMAGE_SIMPLE}
               description={<span style={{ color: 'var(--ms-ink-subtle)' }}>无用户</span>}
               style={{ marginTop: 60 }} />
      ) : (
        <div className="ms-enter-stagger"
             style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          {data.items.map(u => <UserRow key={u.id} user={u} />)}
        </div>
      )}
      {data && data.total > USERS_PAGE_SIZE && (
        <div style={{ marginTop: 16, display: 'flex', justifyContent: 'flex-end' }}>
          <Pagination
            current={page}
            pageSize={USERS_PAGE_SIZE}
            total={data.total}
            showSizeChanger={false}
            showTotal={(t) => `共 ${t} 名用户`}
            onChange={setPage}
          />
        </div>
      )}
    </div>
  );
}

function UsersHeader() {
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
        }}>用户</h1>
        <p style={{ margin: '8px 0 0', fontSize: 13, color: 'var(--ms-ink-muted)' }}>
          本地账号(ADR-0007)创建 / 停用 / 重置密码 — 停用立即撤销全部权限并禁止登录
        </p>
      </div>
      <Button type="primary" icon={<UserPlus size={14} strokeWidth={2} />}
              onClick={() => setOpen(true)}>
        新建用户
      </Button>
      <CreateUserModal open={open} onClose={() => setOpen(false)} />
    </div>
  );
}

function FilterBar({ q, setQ, isActive, setIsActive, total }: {
  q: string; setQ: (v: string) => void;
  isActive: boolean | undefined; setIsActive: (v: boolean | undefined) => void;
  total?: number;
}) {
  const compact = useCompactViewport();
  return (
    <div style={{ display: 'flex', gap: 12, marginBottom: 16, flexWrap: 'wrap', alignItems: 'center' }}>
      <Input.Search
        value={q}
        onChange={e => setQ(e.target.value)}
        onSearch={v => setQ(v.trim())}
        allowClear placeholder="搜用户名 / 姓名 / 邮箱…"
        style={compact ? { flex: 1, minWidth: 0 } : { width: 260 }} />
      <Select
        value={isActive === undefined ? '' : isActive}
        onChange={(v) => setIsActive(v === '' ? undefined : v as boolean)}
        style={compact ? { flex: 1, minWidth: 0 } : { width: 120 }}
        options={[
          { value: '', label: '全部状态' },
          { value: true, label: '启用' },
          { value: false, label: '停用' },
        ]} />
      {/* F5.2: 列表头部总数 */}
      {total !== undefined && (
        <span style={{ marginLeft: 'auto', fontSize: 12.5, color: 'var(--ms-ink-muted)' }}>
          共 <span className="ms-mono" style={{ color: 'var(--ms-ink)' }}>{total}</span> 名用户
        </span>
      )}
    </div>
  );
}

function UserRow({ user }: { user: DirectoryUser }) {
  const { message } = App.useApp();
  const disable = useDisableUser();
  const enable = useEnableUser();
  const reset = useResetUserPassword();
  const [pw, setPw] = useState<string | null>(null);
  // F4.1: 编辑姓名 / 邮箱 / 所属用户组
  const [editOpen, setEditOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const compact = useCompactViewport();

  const doDisable = async () => {
    setBusy(true);
    try {
      await disable.mutateAsync(user.id);
      message.success(`已停用 ${user.name} — 其全部权限 tuple 已撤销`);
    } catch (e) {
      message.error(errorMessage(e, '停用失败'));
    } finally { setBusy(false); }
  };
  const doEnable = async () => {
    setBusy(true);
    try {
      await enable.mutateAsync(user.id);
      message.success(`已重新启用 ${user.name}`);
    } catch (e) {
      message.error(errorMessage(e, '启用失败'));
    } finally { setBusy(false); }
  };
  const doReset = async () => {
    setBusy(true);
    try {
      const out = await reset.mutateAsync(user.id);
      setPw(out.temporary_password);
    } catch (e) {
      message.error(errorMessage(e, '重置失败'));
    } finally { setBusy(false); }
  };

  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap',
      padding: '12px 16px', background: 'var(--ms-surface)',
      border: '1px solid var(--ms-hairline)', borderRadius: 'var(--ms-radius-md)',
    }}>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <span style={{ fontSize: 13, fontWeight: 500, color: 'var(--ms-ink)' }}>{user.name}</span>
          <StatusPill active={user.is_active} mustChange={user.must_change_password} />
          {!user.is_active && user.resigned_at && (
            <Tooltip title={`停用于 ${dayjs(user.resigned_at).format('YYYY-MM-DD HH:mm')}`}>
              <span style={{ fontSize: 11, color: 'var(--ms-ink-subtle)' }}>已停用</span>
            </Tooltip>
          )}
        </div>
        <div style={{
          marginTop: 3, fontSize: 11.5, color: 'var(--ms-ink-muted)',
          fontFamily: 'var(--ms-font-mono)',
          overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
        }}>
          {user.username || '—'}{user.email ? ` · ${user.email}` : ''}
        </div>
      </div>
      {/* compact: 日期占满一整行,操作按钮换行到下一行 */}
      <span style={{
        fontSize: 11.5, color: 'var(--ms-ink-subtle)', whiteSpace: 'nowrap',
        flexBasis: compact ? '100%' : undefined,
      }}>
        创建于 {dayjs(user.created_at).format('YYYY-MM-DD')}
      </span>
      <div style={{ display: 'flex', gap: 6, flexShrink: 0 }}>
        <Button size="small" icon={<Pencil size={12} strokeWidth={2} />}
                onClick={() => setEditOpen(true)}>
          编辑
        </Button>
        {user.is_active ? (
          <Button size="small" danger icon={<Power size={12} strokeWidth={2} />}
                  loading={busy} onClick={doDisable}>
            停用
          </Button>
        ) : (
          <Button size="small" icon={<Power size={12} strokeWidth={2} />}
                  loading={busy} onClick={doEnable}>
            启用
          </Button>
        )}
        <Button size="small" icon={<RotateCcw size={12} strokeWidth={2} />}
                loading={busy} onClick={doReset}>
          重置密码
        </Button>
      </div>
      <TempPasswordModal open={!!pw} password={pw} onClose={() => setPw(null)} />
      {/* F4.1: 条件挂载 — 打开才发详情请求(编辑弹窗挂每行,常挂会 N 倍请求) */}
      {editOpen && <EditUserModal user={user} onClose={() => setEditOpen(false)} />}
    </div>
  );
}

function StatusPill({ active, mustChange }: { active: boolean; mustChange: boolean }) {
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
    </>
  );
}

// ─── 新建用户 ───────────────────────────────────────────────────────────────
function CreateUserModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const create = useCreateUser();
  const [form] = Form.useForm();
  const { message } = App.useApp();
  const [created, setCreated] = useState<DirectoryUserCreateOut | null>(null);
  // F3.1: 用户组多选(可搜索;不选可提交)
  const { data: groups } = useDirectoryGroups('');

  const submit = async () => {
    try {
      const v = await form.validateFields();
      const out = await create.mutateAsync({
        username: v.username.trim(),
        name: v.name.trim(),
        email: v.email?.trim() || undefined,
        group_ids: (v.group_ids ?? []) as string[],
      });
      setCreated(out);
      message.success(`用户 "${out.name}" 已创建`);
      onClose();
      form.resetFields();
    } catch (e) {
      if ((e as { errorFields?: unknown }).errorFields) return;
      message.error(errorMessage(e, '创建失败'));
    }
  };

  return (
    <>
      <Modal title="新建本地用户" open={open} onCancel={onClose} destroyOnClose
             confirmLoading={create.isPending} onOk={submit} okText="创建">
        <Form form={form} layout="vertical">
          <Form.Item name="username" label="登录名(拼音 / 工号,登录用)"
                     rules={[
                       { required: true, min: 2, max: 64 },
                       { pattern: /^[a-zA-Z0-9._-]+$/, message: '仅字母/数字/._- 组成' },
                     ]}
                     extra="提交后不可改;本地用户无飞书身份,登录名是唯一标识">
            <Input placeholder="zhangsan / 10086" autoFocus />
          </Form.Item>
          <Form.Item name="name" label="姓名" rules={[{ required: true, max: 128 }]}>
            <Input placeholder="张三" />
          </Form.Item>
          <Form.Item name="email" label="邮箱(可选)">
            <Input placeholder="zhangsan@example.com" />
          </Form.Item>
          <Form.Item name="group_ids" label="用户组(可选)"
                     extra="创建后直接加入所选组并即时生效;可不选,之后在用户组里再加">
            <Select
              mode="multiple"
              showSearch
              optionFilterProp="label"
              allowClear
              placeholder="选择用户组(可多选)"
              options={(groups ?? []).map(g => ({ value: g.id, label: g.name }))}
              notFoundContent="无用户组"
            />
          </Form.Item>
          <Alert type="info" showIcon style={{ marginBottom: 8 }}
                 message="创建成功后会显示一次性临时密码,用户首次登录需改密。" />
        </Form>
      </Modal>
      <TempPasswordModal open={!!created} password={created?.temporary_password ?? null}
                         onClose={() => setCreated(null)}
                         title="用户已创建" />
    </>
  );
}

// ─── 编辑用户(F4.1:姓名 / 邮箱 / 所属用户组)──────────────────────────────
/** 条件挂载(行内仅在打开时 render):detail/groups 请求只在弹窗打开时发出。*/
function EditUserModal({ user, onClose }: { user: DirectoryUser; onClose: () => void }) {
  const [form] = Form.useForm();
  const { message } = App.useApp();
  // 回显:GET /admin/directory/users/{id}(含 group_ids,§2)
  const { data: detail } = useDirectoryUserDetail(user.id);
  const { data: groups } = useDirectoryGroups('');
  const update = useUpdateUser();

  // 回显走 initialValues 数据驱动,不用 setFieldsValue:本组件按次开关条件挂载
  // (每次打开都是新 Form 实例),缓存命中时 detail 首帧即到,useEffect 里的
  // setFieldsValue 会先于 Form 字段注册执行 → 二次打开 name/email/组全空(P1 根治)。
  // detail 未到时不渲染 Form(只渲染 Skeleton),字段注册时初值必然已就位。
  // username 只读不入表单
  const submit = async () => {
    // 「详情未回显前保存禁用」双保险:按钮 disabled 之外这里再挡一层 ——
    // 无 detail 提交会以空 group_ids 全量同步,把用户移出全部组
    if (!detail) return;
    try {
      const v = await form.validateFields();
      await update.mutateAsync({
        userId: user.id,
        body: {
          name: v.name.trim(),
          // D6: 留空 = 显式提交 null 清空
          email: v.email?.trim() || null,
          // D3: 全量同步终态(清空选择 = 移出全部组;后端 diff 加/移双写)
          group_ids: (v.group_ids ?? []) as string[],
        },
      });
      message.success(`已保存 ${user.name} 的资料`);
      onClose();
    } catch (e) {
      if ((e as { errorFields?: unknown }).errorFields) return;
      message.error(errorMessage(e, '保存失败'));
    }
  };

  return (
    <Modal title={`编辑用户 — ${user.name}`} open onCancel={onClose}
           destroyOnHidden confirmLoading={update.isPending}
           onOk={submit} okText="保存"
           okButtonProps={{ disabled: !detail }}>
      {!detail ? (
        <Skeleton active paragraph={{ rows: 2 }} style={{ marginBottom: 12 }} />
      ) : (
        <Form form={form} layout="vertical"
              initialValues={{
                name: detail.name,
                email: detail.email ?? '',
                group_ids: detail.group_ids ?? [],
              }}>
          <Form.Item label="登录名" extra="创建后不可改">
            <Input value={user.username || '—'} disabled />
          </Form.Item>
          <Form.Item name="name" label="姓名" rules={[{ required: true, max: 128 }]}>
            <Input placeholder="张三" autoFocus />
          </Form.Item>
          <Form.Item name="email" label="邮箱"
                     extra="留空提交 = 清空邮箱">
            <Input placeholder="zhangsan@example.com" />
          </Form.Item>
          <Form.Item name="group_ids" label="所属用户组"
                     extra="保存按此处勾选全量同步;移出组将立即失去该组授予的全部权限">
            <Select
              mode="multiple"
              showSearch
              optionFilterProp="label"
              allowClear
              placeholder="选择用户组(可多选)"
              loading={!groups}
              options={(groups ?? []).map(g => ({ value: g.id, label: g.name }))}
              notFoundContent="无用户组"
            />
          </Form.Item>
        </Form>
      )}
    </Modal>
  );
}

// ─── 临时密码展示(创建 / 重置共用,只回显一次)────────────────────────────
function TempPasswordModal({ open, password, onClose, title }: {
  open: boolean; password: string | null; onClose: () => void; title?: string;
}) {
  const { message } = App.useApp();
  // F1: 统一复制入口 — HTTP 非安全上下文自动降级 execCommand
  const copy = () => {
    if (!password) return;
    if (copyToClipboard(password)) message.success('已复制');
    else message.error('复制失败,请手动选中');
  };
  return (
    <Modal title={title || '临时密码'} open={open} onCancel={onClose}
           footer={<Button type="primary" onClick={onClose}>完成</Button>}>
      <p style={{ fontSize: 13, color: 'var(--ms-ink-muted)', lineHeight: 1.7, marginTop: 0 }}>
        这是<strong>唯一一次</strong>展示,不会写入日志 / 审计。请直接交给对方,首次登录后必须修改。
      </p>
      <div style={{
        display: 'flex', alignItems: 'center', gap: 8,
        padding: '12px 14px', background: 'var(--ms-canvas)',
        border: '1px solid var(--ms-hairline)', borderRadius: 'var(--ms-radius-sm)',
      }}>
        <KeyRound size={15} strokeWidth={1.8} style={{ color: 'var(--ms-ink-muted)', flexShrink: 0 }} />
        <code style={{
          flex: 1, fontFamily: 'var(--ms-font-mono)', fontSize: 15,
          color: 'var(--ms-ink)', letterSpacing: '0.04em',
          overflowWrap: 'anywhere',
        }}>{password}</code>
        <Button size="small" onClick={copy}>复制</Button>
      </div>
    </Modal>
  );
}
