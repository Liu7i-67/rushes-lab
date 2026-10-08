/**
 * 新建项目 — 闸门 = is_project_creator ?? is_system_admin 回落(PR-2:组织管理员或
 * 被授予「允许新建项目」组权限的成员;旧后端字段缺失回落系统 admin)。
 * 创建时必须指派项目 admin(默认 = 自己,可改)。
 * 「权限(可选)」组(PR-3 重排):PC 双栏(左基础字段 / 右权限组),移动端单栏权限在尾;
 * 组内顶部模板 Select 仅显式选中时预填初始权限(可再增删改)—— 默认模板不再前端预选,
 * 改由后端创建时直通合并(有默认模板时提交区明示)。
 */
import { Alert, App, Button, Form, Input, Modal, Select, Tooltip } from 'antd';
import { ShieldCheck, Trash2, Users as UsersIcon } from 'lucide-react';
import { useEffect, useMemo, useState } from 'react';
import { useAllUsers, useCreateProject, useGrantTemplates } from '../api/hooks';
import { errorMessage } from '../api/client';
import { useCompactViewport } from '../lib/use-viewports';
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
  const compact = useCompactViewport();
  const [adminUserId, setAdminUserId] = useState<string>(me.id);
  const [rows, setRows] = useState<GrantRow[]>([]);
  // '' = 不使用模板(默认);其余 = 显式选中的模板 id。
  // PR-3 起「自动跟随默认模板」已删:默认模板由后端创建时直通合并,前端不再预选/预填
  const [templateId, setTemplateId] = useState<string>('');

  // 模板列表;手选用户名典(SubjectPicker 的 user 分支只回传 id,行显名用)。
  // nameById 走已放宽的 GET /api/v1/users(offset 分页拉全;原 directory 端点
  // require_system_admin 未放宽,零项目组长会 403)。
  // 弹窗对全员挂载,关闭态不取数(403/失败 → 静默降级为只有「不使用模板」)
  const { data: templates } = useGrantTemplates(open);
  const { data: allUsers } = useAllUsers(open);
  const nameById = useMemo(
    () => new Map((allUsers ?? []).map(u => [u.id, u.name])),
    [allUsers],
  );

  const templateList = templates ?? [];
  const defaultTemplate = templateList.find(t => t.is_default);

  // 打开即重置表单到默认态:有意的「open 翻转重置」,改 render 期重置/key 重挂载会改动态,豁免 cascading 警告
  /* eslint-disable react-hooks/set-state-in-effect */
  useEffect(() => {
    if (open) {
      form.resetFields();
      setAdminUserId(me.id);  // 默认 admin = 自己(users.id UUID)
      setRows([]);
      setTemplateId('');
    }
  }, [open, form, me.id]);
  /* eslint-enable react-hooks/set-state-in-effect */

  const rowName = (r: GrantRow) => r.name ?? nameById.get(r.id) ?? shortId(r.id);

  // SubjectPicker 增删 → 同步行:已有行保留其角色,新行默认「查看」,移除的行丢弃
  const applySubjects = (subjects: Subject[]) => {
    const prevByKey = new Map(rows.map(r => [r.key, r]));
    const next: GrantRow[] = [];
    for (const s of subjects) {
      const key = rowKeyOf(s);
      next.push(prevByKey.get(key) ?? {
        key, kind: s.kind, id: s.id, name: s.name, roles: ['viewer'],
      });
    }
    setRows(next);
  };

  // 模板切换:逐条预填(items 每 item 一行 + 各自角色);「不使用模板」清空重来。
  // 仅显式选中的模板预填;默认模板不预选(创建后由后端合并,见提交区提示)
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
      if (rows.some(r => r.roles.length === 0)) {
        message.warning('请至少勾选一个角色');
        return;
      }
      const initial_grants: GrantEntry[] =
        rows.map(r => ({ kind: r.kind, id: r.id, roles: r.roles }));
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
      const err = e as { errorFields?: { name: (string | number)[] }[] };
      if (err.errorFields) {
        // body 是滚动容器,显式滚到第一个出错字段(方案 §3.3:scrollToFirstError 可用)
        form.scrollToField(err.errorFields[0].name);
        return;
      }
      message.error(errorMessage(e, '创建失败'));
    }
  };

  // 无新建权限 → 禁用并提示(口径 = is_org_admin ∨ 用户组 project_creator;
  // 旧后端无 is_project_creator 字段时回落 is_system_admin)
  if (!(me.is_project_creator ?? me.is_system_admin)) {
    return (
      <Modal title="新建项目" open={open} onCancel={onClose} footer={null}>
        <Alert
          type="warning"
          showIcon
          message="当前账号暂无新建项目权限"
          description="需要组织管理员,或加入已开启「允许组成员新建项目」的用户组;请联系组织管理员开通。"
          style={{ marginTop: 4 }}
        />
      </Modal>
    );
  }

  // 权限模板下拉项(默认模板带「默认」徽标;仅显式选中才预填)
  const templateOptions = [
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
  ];

  return (
    <Modal
      title="新建项目"
      open={open}
      onCancel={onClose}
      destroyOnClose
      confirmLoading={create.isPending}
      onOk={submit}
      okText="创建"
      // PR-3 重排:PC 双栏拉宽到 ≈1040;body 限高滚动(权限行多时不撑爆弹窗)
      width={compact ? 'min(640px, calc(100vw - 16px))' : 'min(1040px, calc(100vw - 32px))'}
      styles={{ body: { maxHeight: '70vh', overflowY: 'auto' } }}
    >
      <Form form={form} layout="vertical"
            initialValues={{ minio_bucket: 'ms-dev' }}>
        <div style={compact
          ? { display: 'flex', flexDirection: 'column' }
          : { display: 'grid', gridTemplateColumns: 'minmax(0,1fr) minmax(0,1fr)', columnGap: 32 }}>
          {/* 左栏:基础字段(移动端 = 表单主体,权限组自然落到尾部) */}
          <div>
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

            {/* 指派 admin — 必填,默认自己 */}
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

            <Form.Item name="minio_bucket" label="MinIO bucket"
                       rules={[{ required: true, max: 63 }]}
                       extra="PoC 统一 ms-dev">
              <Select options={[
                { label: 'ms-dev(开发环境)', value: 'ms-dev' },
              ]} />
            </Form.Item>
          </div>

          {/* 右栏:「权限(可选)」组 — 模板 Select 从顶部移入,初始权限区在其下 */}
          <div>
            <Form.Item label="权限(可选)"
                       extra="选模板可预填初始权限(预填后可自由增删行 / 改角色),或直接手选主体;每行主体各自勾选角色">
              <Select
                value={templateId}
                onChange={applyTemplate}
                optionLabelProp="labelText"
                options={templateOptions}
              />
              <div style={{ marginTop: 12 }}>
                <SubjectPicker
                  value={rows.map(r => ({ kind: r.kind, id: r.id, name: rowName(r) }))}
                  onChange={applySubjects}
                  me={me}
                />
              </div>
              {rows.length > 0 && (
                <div style={{
                  display: 'flex', flexDirection: 'column', gap: 8,
                  marginTop: 10, maxHeight: 320, overflowY: 'auto', paddingRight: 2,
                }}>
                  {rows.map(r => (
                    <GrantRowCard
                      key={r.key} row={r} name={rowName(r)}
                      onRolesChange={(roles) => setRows(
                        rows.map(x => (x.key === r.key ? { ...x, roles } : x)))}
                      onRemove={() => setRows(rows.filter(x => x.key !== r.key))}
                    />
                  ))}
                </div>
              )}
            </Form.Item>
          </div>
        </div>

        {/* 默认模板直通(PR-3)提交区明示:防「行内显式删掉的角色被默认模板 union 顶回」无感知 */}
        {defaultTemplate && (
          <Alert
            type="info"
            showIcon
            style={{ marginTop: 4 }}
            message={`已设默认模板「${defaultTemplate.name}」— 创建后将自动合并其授权`}
            description="与上方权限取并集、不重复;行内显式删除的角色也可能被默认模板合并回来。"
          />
        )}
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
