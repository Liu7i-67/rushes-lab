/**
 * 新建项目 — 仅系统 admin 可用;创建时必须指派项目 admin(默认 = 自己,可改)。
 * 「初始权限(可选)」(方案 §3.2):主体行列表 × 每行独立角色,提交组装 initial_grants
 * 直通;不选任何主体 = 完全兼容现行为。
 * 「权限模板」Select(方案 §4.4):顶部选项 = 不使用模板 + 模板列表;默认选中 org 的
 * is_default 模板,onChange 把模板 items 逐条预填成主体行(每行各自角色,可再增删改);
 * 模板接口 403 / 失败时静默降级为只有「不使用模板」。
 */
import { Alert, App, Button, Form, Input, Modal, Select, Tooltip } from 'antd';
import { ShieldCheck, Trash2, Users as UsersIcon } from 'lucide-react';
import { useEffect, useMemo, useState } from 'react';
import { useCreateProject, useDirectoryUsers, useGrantTemplates } from '../api/hooks';
import { errorMessage } from '../api/client';
import type { GrantEntry, GrantTemplate, Me, ProjectRole } from '../api/types';
import { UserPicker } from './UserPicker';
import { SubjectPicker, type Subject } from './SubjectPicker';
import { RoleChipGroup } from './RoleChipGroup';

interface Props {
  open: boolean;
  onClose: () => void;
  onCreated?: (project_id: string) => void;
  me: Me;
}

/** 初始权限的主体行:每行主体各自一套角色(与 initial_grants 条目一一对应)。*/
interface GrantRow {
  key: string;             // `${kind}:${id}`,稳定去重键
  kind: 'user' | 'group';
  id: string;
  name?: string;           // 模板条目自带;手选主体的名字走 nameById 兜底
  missing?: boolean;       // 模板条目主体已删(提交会被建项目存在性校验 400 拦下)
  roles: ProjectRole[];
}

const rowKeyOf = (s: { kind: string; id: string }) => `${s.kind}:${s.id}`;
const shortId = (id: string) => id.slice(0, 12) + '…';

const templateRows = (t: GrantTemplate): GrantRow[] =>
  t.items.map(it => ({
    key: rowKeyOf(it),
    kind: it.kind,
    id: it.id,
    name: it.name,
    missing: it.missing || undefined,
    roles: [...it.roles],
  }));

export function NewProjectModal({ open, onClose, onCreated, me }: Props) {
  const create = useCreateProject();
  const [form] = Form.useForm();
  const { message } = App.useApp();
  const [adminUserId, setAdminUserId] = useState<string>(me.id);
  const [rows, setRows] = useState<GrantRow[]>([]);
  // undefined = 自动跟随默认模板(有则预填,方案 §4.4);'' = 显式「不使用模板」;
  // 其余 = 显式选中的模板 id。用户任何行内改动都会把当前值固化,不再自动跟随
  const [templateId, setTemplateId] = useState<string | undefined>(undefined);

  // 模板列表;手选用户名典(SubjectPicker 的 user 分支只回传 id,行显名用)。
  // 弹窗对全员挂载,关闭态不取数(403/失败 → 静默降级为只有「不使用模板」)
  const { data: templates } = useGrantTemplates(open);
  const { data: dirUsers } = useDirectoryUsers(open ? { limit: 200 } : null);
  const nameById = useMemo(
    () => new Map((dirUsers ?? []).map(u => [u.id, u.name])),
    [dirUsers],
  );

  const templateList = templates ?? [];
  const defaultTemplate = templateList.find(t => t.is_default);
  const effectiveTemplateId = templateId !== undefined
    ? templateId
    : (defaultTemplate?.id ?? '');
  // 自动跟随期(未固化)的预填行:默认模板 items 逐条一行 + 各自角色
  const effectiveRows = rows.length === 0 && templateId === undefined && defaultTemplate
    ? templateRows(defaultTemplate)
    : rows;

  useEffect(() => {
    if (open) {
      form.resetFields();
      setAdminUserId(me.id);  // 默认 admin = 自己(users.id UUID)
      setRows([]);
      setTemplateId(undefined);
    }
  }, [open, form, me.id]);

  const rowName = (r: GrantRow) => r.name ?? nameById.get(r.id) ?? shortId(r.id);

  // 行内任何改动都基于 effectiveRows 并固化模板选择
  const commitRows = (next: GrantRow[]) => {
    setRows(next);
    setTemplateId(effectiveTemplateId);
  };

  // SubjectPicker 增删 → 同步行:已有行保留其角色,新行默认「查看」,移除的行丢弃
  const applySubjects = (subjects: Subject[]) => {
    const prevByKey = new Map(effectiveRows.map(r => [r.key, r]));
    const next: GrantRow[] = [];
    for (const s of subjects) {
      const key = rowKeyOf(s);
      next.push(prevByKey.get(key) ?? {
        key, kind: s.kind, id: s.id, name: s.name, roles: ['viewer'],
      });
    }
    commitRows(next);
  };

  // 模板切换:逐条预填(items 每 item 一行 + 各自角色);「不使用模板」清空重来
  const applyTemplate = (tid: string) => {
    setTemplateId(tid);
    if (!tid) {
      setRows([]);
      return;
    }
    const t = templateList.find(x => x.id === tid);
    setRows(t ? templateRows(t) : []);
  };

  const submit = async () => {
    try {
      const v = await form.validateFields();
      if (!adminUserId) {
        message.warning('请指派项目管理员');
        return;
      }
      if (effectiveRows.some(r => r.roles.length === 0)) {
        message.warning('请至少勾选一个角色');
        return;
      }
      const initial_grants: GrantEntry[] =
        effectiveRows.map(r => ({ kind: r.kind, id: r.id, roles: r.roles }));
      const p = await create.mutateAsync({
        code: v.code.trim(),
        name: v.name.trim(),
        description: v.description?.trim() || undefined,
        organization_id: '',
        minio_bucket: v.minio_bucket || 'ms-dev',
        admin_user_id: adminUserId,
        ...(initial_grants.length > 0 ? { initial_grants } : {}),
      });
      message.success(initial_grants.length > 0
        ? `项目 "${p.name}" 已创建,已为 ${initial_grants.length} 个主体授予初始权限`
        : `项目 "${p.name}" 已创建`);
      onCreated?.(p.id);
      onClose();
    } catch (e) {
      if ((e as { errorFields?: unknown }).errorFields) return;
      message.error(errorMessage(e, '创建失败'));
    }
  };

  // 非系统 admin → 禁用并提示
  if (!me.is_system_admin) {
    return (
      <Modal title="新建项目" open={open} onCancel={onClose} footer={null}>
        <Alert
          type="warning"
          showIcon
          message="只有系统管理员可以创建项目"
          description="如需新建项目,请联系系统管理员;管理员通过后台命令 grant_org_admin 指定。"
          style={{ marginTop: 4 }}
        />
      </Modal>
    );
  }

  return (
    <Modal
      title="新建项目"
      open={open}
      onCancel={onClose}
      destroyOnClose
      confirmLoading={create.isPending}
      onOk={submit}
      okText="创建"
    >
      <Form form={form} layout="vertical"
            initialValues={{ minio_bucket: 'ms-dev' }}>
        {/* 权限模板(方案 §4.4)— 顶部:默认模板自动选中,onChange 预填下方初始权限 */}
        <Form.Item label="权限模板"
                   extra="按模板预填初始权限,预填后可自由增删行 / 改角色;仅预填,不锁定">
          <Select
            value={effectiveTemplateId}
            onChange={applyTemplate}
            optionLabelProp="labelText"
            options={[
              { value: '', labelText: '不使用模板', label: '不使用模板' },
              ...(templateList.map(t => ({
                value: t.id,
                labelText: t.name + (t.is_default ? '(默认)' : ''),
                label: (
                  <div style={{ display: 'flex', flexDirection: 'column', padding: '2px 0' }}>
                    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
                      <span style={{ fontSize: 13, color: 'var(--ms-ink)' }}>{t.name}</span>
                      {t.is_default && (
                        <span style={{
                          padding: '0 5px', fontSize: 9.5, letterSpacing: '0.04em',
                          fontFamily: 'var(--ms-font-mono)',
                          color: 'var(--ms-accent)', background: 'var(--ms-accent-soft)',
                          borderRadius: 2, lineHeight: '14px',
                        }}>默认</span>
                      )}
                    </span>
                    {t.description && (
                      <span style={{
                        fontSize: 11, color: 'var(--ms-ink-subtle)', lineHeight: 1.5,
                        display: 'flex', flexDirection: 'column',
                      }}>{t.description}</span>
                    )}
                  </div>
                ),
              }))),
            ]}
          />
        </Form.Item>

        <Form.Item name="name" label="项目名称"
                   rules={[{ required: true, max: 255 }]}>
          <Input placeholder="2026 春季婚礼策划" autoFocus />
        </Form.Item>
        <Form.Item name="code" label="项目编码(URL slug,小写字母/数字/-)"
                   rules={[{
                     required: true, min: 2, max: 64,
                     pattern: /^[a-z0-9][a-z0-9-]*$/,
                     message: '小写字母/数字/-,以字母数字开头',
                   }]}
                   extra="提交后不可改;影响 MinIO 路径前缀">
          <Input placeholder="wedding-2026-spring" />
        </Form.Item>
        <Form.Item name="description" label="描述(可选)">
          <Input.TextArea rows={3} maxLength={500} showCount />
        </Form.Item>

        {/* 指派 admin — 系统 admin 必填,默认自己 */}
        <Form.Item label="项目管理员"
                   extra="可以是自己;创建后会自动获得项目内全部权限,并可进一步邀请成员">
          <UserPicker
            multiple={false}
            value={adminUserId}
            onChange={(v) => setAdminUserId((v as string) || '')}
            preset={[{ id: me.id, username: null, open_id: me.open_id, union_id: me.union_id,
                       name: me.name + '(自己)', email: me.email }]}
            placeholder="选一个项目管理员"
          />
          {adminUserId === me.id && (
            <div style={{
              marginTop: 6, fontSize: 11, color: 'var(--ms-ink-subtle)',
              display: 'inline-flex', alignItems: 'center', gap: 4,
            }}>
              <ShieldCheck size={11} strokeWidth={1.8} />
              你本人将作为项目管理员
            </div>
          )}
        </Form.Item>

        {/* 初始权限(可选)(方案 §3.2)— 主体行列表 × 每行独立角色 */}
        <Form.Item label="初始权限(可选)"
                   extra="创建时同时授权给用户 / 用户组;每行主体各自勾选角色,不选则不额外授权">
          <SubjectPicker
            value={effectiveRows.map(r => ({ kind: r.kind, id: r.id, name: rowName(r) }))}
            onChange={applySubjects}
            me={me}
          />
          {effectiveRows.length > 0 && (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8, marginTop: 10 }}>
              {effectiveRows.map(r => (
                <GrantRowCard
                  key={r.key} row={r} name={rowName(r)}
                  onRolesChange={(roles) => commitRows(
                    effectiveRows.map(x => (x.key === r.key ? { ...x, roles } : x)))}
                  onRemove={() => commitRows(effectiveRows.filter(x => x.key !== r.key))}
                />
              ))}
            </div>
          )}
        </Form.Item>

        <Form.Item name="minio_bucket" label="MinIO bucket"
                   rules={[{ required: true, max: 63 }]}
                   extra="PoC 统一 ms-dev">
          <Select options={[
            { label: 'ms-dev(开发环境)', value: 'ms-dev' },
          ]} />
        </Form.Item>
      </Form>
    </Modal>
  );
}

/** 初始权限的一行:主体(名 / 类型)+ 该行自己的 RoleChipGroup + 移除按钮。*/
function GrantRowCard({ row, name, onRolesChange, onRemove }: {
  row: GrantRow;
  name: string;
  onRolesChange: (roles: ProjectRole[]) => void;
  onRemove: () => void;
}) {
  return (
    <div style={{
      padding: '10px 12px',
      background: 'var(--ms-surface)',
      border: '1px solid var(--ms-hairline)',
      borderRadius: 'var(--ms-radius-md)',
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 8 }}>
        {row.kind === 'user' ? (
          <span style={{
            display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
            width: 24, height: 24, flexShrink: 0,
            background: 'var(--ms-ink)', color: 'var(--ms-canvas)',
            borderRadius: '50%',
            fontFamily: 'var(--ms-font-display)', fontSize: 11, fontWeight: 500,
          }}>{(name || '?').slice(0, 1).toUpperCase()}</span>
        ) : (
          <span style={{
            display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
            width: 24, height: 24, flexShrink: 0,
            background: 'var(--ms-hairline-soft)', color: 'var(--ms-ink-muted)',
            borderRadius: 'var(--ms-radius-sm)',
          }}><UsersIcon size={13} strokeWidth={1.7} /></span>
        )}
        <span style={{
          flex: 1, minWidth: 0, display: 'flex', alignItems: 'center', gap: 6,
          fontSize: 13, fontWeight: 500, color: 'var(--ms-ink)',
        }}>
          <span style={{
            overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
            flex: '0 1 auto', minWidth: 0,
          }}>{name}</span>
          <span style={{
            flexShrink: 0, padding: '0 5px', fontSize: 9.5, letterSpacing: '0.04em',
            fontFamily: 'var(--ms-font-mono)',
            color: 'var(--ms-ink-subtle)', background: 'var(--ms-hairline-soft)',
            borderRadius: 2, lineHeight: '14px',
          }}>{row.kind === 'user' ? '用户' : '群组'}</span>
          {row.missing && (
            <span style={{
              flexShrink: 0, padding: '0 5px', fontSize: 9.5, letterSpacing: '0.04em',
              fontFamily: 'var(--ms-font-mono)',
              color: 'var(--ms-amber)', background: '#FEF3E8',
              borderRadius: 2, lineHeight: '14px',
            }}>已删除</span>
          )}
        </span>
        <Tooltip title="移除该主体" mouseEnterDelay={0.3}>
          <Button size="small" type="text" danger
                  icon={<Trash2 size={13} strokeWidth={2} />}
                  onClick={onRemove} style={{ flexShrink: 0 }} />
        </Tooltip>
      </div>
      <RoleChipGroup value={row.roles} onChange={onRolesChange} />
    </div>
  );
}
