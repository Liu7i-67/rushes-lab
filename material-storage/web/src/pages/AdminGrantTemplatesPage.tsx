/**
 * /admin/grant-templates — 项目权限模板管理(方案 §4.4)。
 * 模板 = 保存的授权组合预设(一组 {主体, 角色});新建项目时选模板预填初始权限
 * (提交走 initial_grants)。PR-3 起默认模板例外:创建时由后端直通合并(不再前端预选),
 * 头部「刷新默认权限」可为存量项目按需补(叠加不删)。布局 / 门控照 AdminGroupsPage。
 */
import {
  Alert, App, Button, Empty, Form, Input, Modal, Popconfirm, Skeleton, Switch, Tooltip,
} from 'antd';
import { LayoutTemplate, Plus, RefreshCw, Trash2 } from 'lucide-react';
import { useMemo, useState } from 'react';
import {
  useMe, useGrantTemplates, useCreateGrantTemplate, useUpdateGrantTemplate,
  useDeleteGrantTemplate, useDirectoryUsers,
} from '../api/hooks';
import { errorMessage } from '../api/client';
import { useCompactViewport } from '../lib/use-viewports';
import type { GrantEntry, GrantTemplate, Me, ProjectRole } from '../api/types';
import { SubjectPicker, type Subject } from '../components/SubjectPicker';
import { RoleChipGroup, RoleBadges } from '../components/RoleChipGroup';
import { ApplyDefaultModal } from '../components/ApplyDefaultModal';

export default function AdminGrantTemplatesPage() {
  const { data: me } = useMe();
  const { data, isLoading } = useGrantTemplates();

  if (me && !me.is_system_admin) {
    return (
      <div className="ms-enter" style={{ maxWidth: 520 }}>
        <Alert
          type="warning" showIcon
          message="只有系统管理员可以管理权限模板"
          description="如需新建权限模板,请联系系统管理员。"
        />
      </div>
    );
  }

  return (
    <div className="ms-enter">
      <TemplatesHeader me={me} templates={data} />
      {isLoading ? (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          {[0, 1].map(i => (
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
               description={<span style={{ color: 'var(--ms-ink-subtle)' }}>
                 无权限模板 · 新建一个供新建项目时预填初始权限
               </span>}
               style={{ marginTop: 60 }} />
      ) : (
        <div className="ms-enter-stagger"
             style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          {data.map(t => <TemplateRow key={t.id} template={t} me={me} />)}
        </div>
      )}
    </div>
  );
}

function TemplatesHeader({ me, templates }: { me: Me | undefined; templates: GrantTemplate[] | undefined }) {
  const [open, setOpen] = useState(false);
  const [applyOpen, setApplyOpen] = useState(false);
  // PR-3: 无默认模板时「刷新默认权限」不可用(接口也会 400,这里提前 disabled)
  const hasDefault = !!templates?.some(t => t.is_default);
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
        }}>权限模板</h1>
        <p style={{ margin: '8px 0 0', fontSize: 13, color: 'var(--ms-ink-muted)' }}>
          项目授权预设 — 新建项目时按模板预填初始权限;默认模板的授权由创建流程自动合并
        </p>
      </div>
      <div style={{ display: 'flex', gap: 8, flexShrink: 0 }}>
        <Tooltip title={hasDefault
          ? '为存量项目补齐默认模板授权(叠加不删)'
          : '需先设一个默认模板'}>
          <Button icon={<RefreshCw size={14} strokeWidth={2} />}
                  disabled={!hasDefault}
                  onClick={() => setApplyOpen(true)}>
            刷新默认权限
          </Button>
        </Tooltip>
        <Button type="primary" icon={<Plus size={14} strokeWidth={2} />}
                onClick={() => setOpen(true)}>
          新建模板
        </Button>
      </div>
      {me && <TemplateFormModal me={me} open={open} onClose={() => setOpen(false)} />}
      <ApplyDefaultModal open={applyOpen} onClose={() => setApplyOpen(false)} />
    </div>
  );
}

function TemplateRow({ template, me }: { template: GrantTemplate; me: Me | undefined }) {
  const { message } = App.useApp();
  const [editOpen, setEditOpen] = useState(false);
  const del = useDeleteGrantTemplate();
  const [deleting, setDeleting] = useState(false);
  const compact = useCompactViewport();

  const doDelete = async () => {
    setDeleting(true);
    try {
      await del.mutateAsync(template.id);
      message.success(`已删除权限模板「${template.name}」`);
    } catch (e) {
      message.error(errorMessage(e, '删除失败'));
    } finally { setDeleting(false); }
  };

  return (
    <div style={{
      display: 'flex', alignItems: 'flex-start', gap: 12, flexWrap: 'wrap',
      padding: '12px 16px', background: 'var(--ms-surface)',
      border: '1px solid var(--ms-hairline)', borderRadius: 'var(--ms-radius-md)',
    }}>
      <div style={{
        display: 'grid', placeItems: 'center', width: 34, height: 34, flexShrink: 0,
        background: 'var(--ms-accent-soft)', borderRadius: 'var(--ms-radius-sm)',
        color: 'var(--ms-accent)',
      }}>
        <LayoutTemplate size={16} strokeWidth={1.8} />
      </div>
      <div style={{ flex: 1, minWidth: 220 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
          <span style={{ fontSize: 13, fontWeight: 500, color: 'var(--ms-ink)' }}>
            {template.name}
          </span>
          {template.is_default && (
            <span style={{
              padding: '1px 7px', fontSize: 10, letterSpacing: '0.04em',
              fontFamily: 'var(--ms-font-mono)',
              color: 'var(--ms-accent)', background: 'var(--ms-accent-soft)',
              borderRadius: 3,
            }}>默认</span>
          )}
          <span style={{
            fontFamily: 'var(--ms-font-mono)', fontSize: 10.5, color: 'var(--ms-ink-subtle)',
            padding: '1px 7px', background: 'var(--ms-hairline-soft)', borderRadius: 3,
          }}>
            {template.items.length} 个主体
          </span>
        </div>
        {template.description && (
          <div style={{
            marginTop: 3, fontSize: 11.5, color: 'var(--ms-ink-muted)',
            overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
          }}>{template.description}</div>
        )}
        {/* 条目一览(最多展示 6 条,余量折叠) */}
        {template.items.length > 0 && (
          <div style={{
            marginTop: 6, display: 'flex', flexWrap: 'wrap', gap: 4, alignItems: 'center',
          }}>
            {template.items.slice(0, 6).map(it => (
              <span key={`${it.kind}:${it.id}`} style={{
                display: 'inline-flex', alignItems: 'center', gap: 5,
                padding: '1px 8px', background: 'var(--ms-hairline-soft)',
                borderRadius: 3, fontSize: 11, color: 'var(--ms-ink-muted)',
              }}>
                {it.name}
                {it.missing && (
                  <span style={{
                    fontFamily: 'var(--ms-font-mono)', fontSize: 9.5,
                    color: 'var(--ms-amber)',
                  }}>已删除</span>
                )}
                <RoleBadges roles={it.roles} />
              </span>
            ))}
            {template.items.length > 6 && (
              <span style={{ fontSize: 11, color: 'var(--ms-ink-subtle)' }}>
                +{template.items.length - 6}
              </span>
            )}
          </div>
        )}
      </div>
      <div style={{ display: 'flex', gap: 6, flexShrink: 0, flexBasis: compact ? '100%' : undefined,
                    justifyContent: compact ? 'flex-end' : undefined }}>
        <Button size="small" onClick={() => setEditOpen(true)}>编辑</Button>
        <Popconfirm
          title={`删除权限模板「${template.name}」?`}
          description={`${template.items.length} 条授权条目将一并删除;已建项目不受影响`}
          okText="删除" okButtonProps={{ danger: true }}
          onConfirm={doDelete}
        >
          <Button size="small" danger icon={<Trash2 size={12} strokeWidth={2} />}
                  loading={deleting} />
        </Popconfirm>
      </div>
      {me && (
        <TemplateFormModal me={me} open={editOpen} onClose={() => setEditOpen(false)}
                           template={template} />
      )}
    </div>
  );
}

// ─── 新建 / 编辑模板 ─────────────────────────────────────────────────────────
/** 授权条目行:与 NewProjectModal 的初始权限行同形(每行主体各自一套角色)。*/
interface GrantRow {
  key: string;
  kind: 'user' | 'group';
  id: string;
  name?: string;
  missing?: boolean;
  roles: ProjectRole[];
}

const rowKeyOf = (s: { kind: string; id: string }) => `${s.kind}:${s.id}`;
const shortId = (id: string) => id.slice(0, 12) + '…';

function TemplateFormModal({ open, onClose, template, me }: {
  open: boolean; onClose: () => void; template?: GrantTemplate; me: Me;
}) {
  const create = useCreateGrantTemplate();
  const update = useUpdateGrantTemplate();
  const [form] = Form.useForm();
  const { message } = App.useApp();
  const isEdit = !!template;

  // 手选用户名典(SubjectPicker 的 user 分支只回传 id,行显名用;同 key 全页共享缓存)
  const { data: dirUsers } = useDirectoryUsers(open ? { limit: 200 } : null);
  const nameById = useMemo(
    () => new Map((dirUsers ?? []).map(u => [u.id, u.name])),
    [dirUsers],
  );
  const rowName = (r: GrantRow) => r.name ?? nameById.get(r.id) ?? shortId(r.id);

  const toRows = (t: GrantTemplate | undefined): GrantRow[] =>
    t ? t.items.map(it => ({
      key: rowKeyOf(it), kind: it.kind, id: it.id,
      name: it.name, missing: it.missing || undefined, roles: [...it.roles],
    })) : [];

  // 条目行:初值取模板 items;关闭动画结束后复位,下次打开即初始态
  // (Modal destroyOnClose 负责重建 Form,行状态在此复位,不走 effect)
  const [rows, setRows] = useState<GrantRow[]>(() => toRows(template));

  // SubjectPicker 增删 → 同步行:已有行保留其角色,新行默认「查看」,移除的行丢弃
  const applySubjects = (subjects: Subject[]) => {
    setRows(prev => {
      const prevByKey = new Map(prev.map(r => [r.key, r]));
      const next: GrantRow[] = [];
      for (const s of subjects) {
        const key = rowKeyOf(s);
        next.push(prevByKey.get(key) ?? {
          key, kind: s.kind, id: s.id, name: s.name, roles: ['viewer'],
        });
      }
      return next;
    });
  };

  const submit = async () => {
    try {
      const v = await form.validateFields();
      if (rows.length === 0) {
        message.warning('请至少添加一个主体');
        return;
      }
      if (rows.some(r => r.roles.length === 0)) {
        message.warning('请至少勾选一个角色');
        return;
      }
      const items: GrantEntry[] = rows.map(r => ({ kind: r.kind, id: r.id, roles: r.roles }));
      if (isEdit) {
        await update.mutateAsync({
          templateId: template.id,
          name: v.name.trim(),
          description: v.description?.trim() || null,
          is_default: v.is_default === true,
          items,
        });
        message.success('已保存');
      } else {
        await create.mutateAsync({
          name: v.name.trim(),
          description: v.description?.trim() || undefined,
          is_default: v.is_default === true,
          items,
        });
        message.success(`权限模板「${v.name.trim()}」已创建`);
      }
      onClose();
    } catch (e) {
      if ((e as { errorFields?: unknown }).errorFields) return;
      message.error(errorMessage(e, isEdit ? '保存失败' : '创建失败'));
    }
  };

  return (
    <Modal title={isEdit ? `编辑权限模板 — ${template.name}` : '新建权限模板'}
           open={open} onCancel={onClose} destroyOnClose
           afterOpenChange={(o) => { if (!o) setRows(toRows(template)); }}
           width="min(640px, calc(100vw - 16px))"
           confirmLoading={isEdit ? update.isPending : create.isPending}
           onOk={submit} okText={isEdit ? '保存' : '创建'}>
      <Form key={isEdit ? template.id : 'new'} form={form} layout="vertical" preserve={false}
            initialValues={template ? {
              name: template.name, description: template.description || undefined,
              is_default: template.is_default,
            } : { is_default: false }}>
        <Form.Item name="name" label="模板名" rules={[{ required: true, max: 128 }]}>
          <Input placeholder="婚礼策划项目标准授权" autoFocus />
        </Form.Item>
        <Form.Item name="description" label="描述(可选)" rules={[{ max: 1024 }]}>
          <Input.TextArea rows={2} maxLength={1024} showCount />
        </Form.Item>
        <Form.Item name="is_default" label="设为默认模板" valuePropName="checked"
                   extra="默认模板的授权会在项目创建时自动合并(存量项目可用「刷新默认权限」补齐);每 org 至多一个默认,设为默认会自动取消原默认">
          <Switch checkedChildren="默认" unCheckedChildren="关" />
        </Form.Item>
        <Form.Item label="授权条目"
                   extra="每行主体各自勾选角色;即新建项目时预填的初始权限">
          <SubjectPicker
            value={rows.map(r => ({ kind: r.kind, id: r.id, name: rowName(r) }))}
            onChange={applySubjects}
            me={me}
          />
          {rows.length > 0 && (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8, marginTop: 10 }}>
              {rows.map(r => (
                <GrantRowCard
                  key={r.key} row={r} name={rowName(r)}
                  onRolesChange={(roles) => setRows(prev =>
                    prev.map(x => (x.key === r.key ? { ...x, roles } : x)))}
                  onRemove={() => setRows(prev => prev.filter(x => x.key !== r.key))}
                />
              ))}
            </div>
          )}
        </Form.Item>
      </Form>
    </Modal>
  );
}

function GrantRowCard({ row, name, onRolesChange, onRemove }: {
  row: GrantRow;
  name: string;
  onRolesChange: (roles: ProjectRole[]) => void;
  onRemove: () => void;
}) {
  return (
    <div style={{
      padding: '10px 12px',
      background: 'var(--ms-canvas)',
      border: '1px solid var(--ms-hairline-soft)',
      borderRadius: 'var(--ms-radius-sm)',
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 8 }}>
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
            <Tooltip title="该主体已被删除,保存前请移除此行或替换主体">
              <span style={{
                flexShrink: 0, padding: '0 5px', fontSize: 9.5, letterSpacing: '0.04em',
                fontFamily: 'var(--ms-font-mono)',
                color: 'var(--ms-amber)', background: '#FEF3E8',
                borderRadius: 2, lineHeight: '14px', cursor: 'help',
              }}>已删除</span>
            </Tooltip>
          )}
        </span>
        <Button size="small" type="text" danger
                icon={<Trash2 size={13} strokeWidth={2} />}
                onClick={onRemove} style={{ flexShrink: 0 }} />
      </div>
      <RoleChipGroup value={row.roles} onChange={onRolesChange} />
    </div>
  );
}
