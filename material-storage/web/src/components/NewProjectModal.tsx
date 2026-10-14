/**
 * 新建项目 — 闸门 = is_project_creator ?? is_system_admin 回落(PR-2:组织管理员或
 * 被授予「允许新建项目」组权限的成员;旧后端字段缺失回落系统 admin)。
 * 创建时必须指派项目 admin(默认 = 自己,可改)。
 * 「权限(可选)」组(PR-3 重排):PC 双栏(左基础字段 / 右权限组),移动端单栏权限在尾;
 * 组内顶部模板 Select 仅显式选中时预填初始权限(可再增删改)—— 默认模板不再前端预选,
 * 改由后端创建时直通合并(有默认模板时提交区明示)。
 * 「目录模板(可选)」(folder-templates 方案 §6-F6,初始权限区之后):选中模板提交
 * folder_template_id,目录树由后端创建流程自动建立;不选不传字段,行为与现状一致。
 * 「艺人账号」区(艺人账号方案 §6-F3,基本信息区之后、右栏权限区之前):闸门
 * is_artist_account_creator ?? is_system_admin,关闭者不渲染(零回归);登录名+姓名
 * 两项全空 = 纯项目创建,登录名停顿预检冲突即时提示;创建成功一次性展示初始密码。
 */
import { Alert, App, Button, Form, Input, Modal, Select, Tooltip, Tree, Typography } from 'antd';
import axios from 'axios';
import { Folder, ShieldCheck, Trash2, Users as UsersIcon } from 'lucide-react';
import { useEffect, useMemo, useState } from 'react';
import { useAllUsers, useCreateProject, useFolderTemplates, useGrantTemplates,
         useUsernameAvailable, USERNAME_PATTERN } from '../api/hooks';
import { errorMessage } from '../api/client';
import { useCompactViewport } from '../lib/use-viewports';
import type {
  ArtistAccountCreated,
  FolderTemplate,
  GrantEntry,
  GrantTemplate,
  Me,
  ProjectRole,
} from '../api/types';
import { UserPicker } from './UserPicker';
import { SubjectPicker, type Subject } from './SubjectPicker';
import { RoleChipGroup } from './RoleChipGroup';
import { pathsToTreeData, collectTreeKeys } from '../utils/folder-tree';

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
  // 目录模板(folder-templates §6-F6):'' = 不使用模板(默认);其余 = 模板 id
  const [folderTemplateId, setFolderTemplateId] = useState<string>('');

  // ─── 艺人账号区(艺人账号方案 §6-F3)────────────────────────────────────────
  // 闸门照 is_project_creator 回落惯例;关闭者不渲染整块(零回归)
  const artistGate = me.is_artist_account_creator ?? me.is_system_admin;
  // 项目名是否被手动编辑过:手动编辑后与「艺人姓名」联动脱钩
  const [projectNameManual, setProjectNameManual] = useState(false);
  // 登录名停顿 ~500ms 后的预检输入(useWatch 取表单值,不复制状态)
  const [debouncedUsername, setDebouncedUsername] = useState('');
  // 创建成功且带 artist_account 时的一次性结果(替代 message.success 路径);独立结果 Modal 展示
  const [artistCreated, setArtistCreated] = useState<{
    projectId: string; projectName: string; projectCode: string; artist: ArtistAccountCreated;
  } | null>(null);
  const artistUsername = Form.useWatch('artist_username', form) as string | undefined;

  // 登录名输入停顿 500ms 才预检(方案 F3-①);弹窗关闭期间不触发
  useEffect(() => {
    if (!open) return;
    const t = setTimeout(() => setDebouncedUsername((artistUsername ?? '').trim()), 500);
    return () => clearTimeout(t);
  }, [artistUsername, open]);

  // 预检(enabled 由 hook 内做正则+长度前置,防半截非法值打 422);闸门关闭/弹窗关闭不发
  const { data: usernameAvail } = useUsernameAvailable(
    open && artistGate ? debouncedUsername || null : null,
  );
  // 冲突提示仅在「当前输入与已预检值一致」时显示 —— 用户继续输入即隐藏,等下一轮预检
  const usernameConflict = !!artistGate
    && debouncedUsername.length > 0
    && (artistUsername ?? '').trim() === debouncedUsername
    && usernameAvail?.available === false;

  // 模板列表;手选用户名典(SubjectPicker 的 user 分支只回传 id,行显名用)。
  // nameById 走已放宽的 GET /api/v1/users(offset 分页拉全;原 directory 端点
  // require_system_admin 未放宽,零项目组长会 403)。
  // 弹窗对全员挂载,关闭态不取数(403/失败 → 静默降级为只有「不使用模板」)
  const { data: templates } = useGrantTemplates(open);
  const { data: folderTemplates } = useFolderTemplates(open);
  const { data: allUsers } = useAllUsers(open);
  const nameById = useMemo(
    () => new Map((allUsers ?? []).map(u => [u.id, u.name])),
    [allUsers],
  );

  const templateList = templates ?? [];
  const defaultTemplate = templateList.find(t => t.is_default);
  const folderTemplateList = folderTemplates ?? [];
  const selectedFolderTemplate = folderTemplateList.find(t => t.id === folderTemplateId);

  // 打开即重置表单到默认态:有意的「open 翻转重置」,改 render 期重置/key 重挂载会改动态,豁免 cascading 警告
  /* eslint-disable react-hooks/set-state-in-effect */
  useEffect(() => {
    if (open) {
      form.resetFields();
      setAdminUserId(me.id);  // 默认 admin = 自己(users.id UUID)
      setRows([]);
      setTemplateId('');
      setFolderTemplateId('');
      setProjectNameManual(false);
      setDebouncedUsername('');
      setArtistCreated(null);
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
    // 艺人账号 body(try 内赋值;catch 失败特判按「本次是否带 artist_account」收窄)
    let artist_account: { username: string; name: string } | undefined;
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
      // 艺人账号(方案 F3-①):两项全空 = 不创建(提交不带字段);填一项则两项都必填
      // (rules 联动校验已拦,此处 trim 兜底)
      const artistUsername = (v.artist_username as string | undefined)?.trim() ?? '';
      const artistName = (v.artist_name as string | undefined)?.trim() ?? '';
      artist_account = artistUsername && artistName
        ? { username: artistUsername, name: artistName }
        : undefined;
      const p = await create.mutateAsync({
        code: v.code.trim(),
        name: v.name.trim(),
        description: v.description?.trim() || undefined,
        organization_id: '',
        minio_bucket: v.minio_bucket || 'ms-dev',
        admin_user_id: adminUserId,
        ...(initial_grants.length > 0 ? { initial_grants } : {}),
        // 目录模板:不选不传字段,与不选模板的现状行为完全一致(方案 §4.2)
        ...(folderTemplateId ? { folder_template_id: folderTemplateId } : {}),
        // 艺人账号内嵌:两项都有值才带字段(方案 §4.1)
        ...(artist_account ? { artist_account } : {}),
      });
      // 成功且有 artist_account → 一次性结果 Modal 替代 message.success(密码只展示这一次,
      // 方案 F3-②);主弹窗保持打开,结果 Modal 叠其上,确认后统一 onCreated + onClose
      if (p.artist_account) {
        setArtistCreated({
          projectId: p.id, projectName: p.name, projectCode: p.code, artist: p.artist_account,
        });
        return;
      }
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
      // 失败特判(方案 F3-③,仅带艺人账号的提交):全局 mutationCache toast 与本地 catch
      // 同时触发,errorMessage 的对象 detail 兜底保证全局通道不炸,这里给精确引导文案
      if (artist_account && axios.isAxiosError(e)) {
        const detail = (
          e.response?.data as { detail?: { code?: string; project_id?: string } } | undefined
        )?.detail;
        // 结构化 409(登录名冲突):按 detail.project_id 区分「预检阶段项目未建」与
        // 「竞态阶段项目已建、艺人未建」两种残留态
        if (e.response?.status === 409 && detail?.code === 'username_taken') {
          message.error(detail.project_id
            ? '项目已创建，但艺人账号未能建立（登录名刚被占用）；可联系管理员在后台开通账号后在项目成员中添加；或由管理员删除该项目后用新登录名重建'
            : '登录名已被占用；若该艺人此前已开通请勿重复开通（可联系管理员将其加入本项目成员），否则请更换登录名重试');
          return;
        }
        // 500(艺人段或既有项目段异常,密码未返回):中性引导,不指向性提"密码未生成"
        if (e.response?.status === 500) {
          message.error('创建过程中出现异常，请到项目列表确认项目是否已创建；若已创建，联系管理员确认艺人账号状态或重置密码');
          return;
        }
      }
      message.error(errorMessage(e, '创建失败'));
    }
  };

  // 结果 Modal 唯一按钮(方案 F3-②):「我已保存,进入项目」→ onCreated + onClose
  const finishArtistCreated = () => {
    if (!artistCreated) return;
    const { projectId } = artistCreated;
    setArtistCreated(null);
    onCreated?.(projectId);
    onClose();
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

  // 目录模板下拉项(「不使用模板(默认)」置顶;option 副标带条目数)
  const folderTemplateOptions = [
    { value: '', labelText: '不使用模板(默认)', label: '不使用模板(默认)' },
    ...folderTemplateList.map(t => ({
      value: t.id,
      labelText: t.name,
      label: (
        <div style={{ display: 'flex', flexDirection: 'column', padding: '2px 0' }}>
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
            <span style={{ fontSize: 13, color: 'var(--ms-ink)' }}>{t.name}</span>
            <span style={{
              fontFamily: 'var(--ms-font-mono)', fontSize: 9.5, color: 'var(--ms-ink-subtle)',
              padding: '0 5px', background: 'var(--ms-hairline-soft)', borderRadius: 2,
              lineHeight: '14px',
            }}>{t.entry_count} 个目录</span>
          </span>
          {t.description && (
            <span style={{
              fontSize: 11, color: 'var(--ms-ink-subtle)', lineHeight: 1.5,
              display: 'flex', flexDirection: 'column',
            }}>{t.description}</span>
          )}
        </div>
      ),
    })),
  ];

  // 主弹窗 + 艺人账号一次性结果 Modal(兄弟节点;fragment 包裹,缩进沿用原主弹窗层级)
  return (
    <>
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
              <Input placeholder="2026 春季婚礼策划" autoFocus
                     onChange={() => setProjectNameManual(true)} />
            </Form.Item>
            {/* rules 拆三条:antd v6 校验器一条 rule 混 pattern 时 min/max 会被静默忽略,
                必须长度一条(无 pattern)、pattern 单独一条,各配 message 才能拦住 code="1" */}
            <Form.Item name="code" label="项目编码(URL slug,小写字母/数字/-)"
                       rules={[
                         { required: true, message: '请输入项目编码' },
                         { min: 2, max: 64, message: '长度 2-64 个字符' },
                         { pattern: /^[a-z0-9][a-z0-9-]*$/, message: '小写字母/数字/-,以字母数字开头' },
                       ]}
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

            {/* 艺人账号区(艺人账号方案 §6-F3-①):基本信息区之后、右栏权限区之前;
                闸门关闭者整块不渲染(零回归)。两项全空 = 纯项目创建(现状行为);
                填一项则两项都必填(dependencies 联动校验)。登录名停顿 500ms 预检,
                冲突经 validateStatus/help 数据驱动展示(勿走 setFieldsValue 注错) */}
            {artistGate && (
              <>
                <Form.Item
                  name="artist_username"
                  label="艺人登录名"
                  dependencies={['artist_name']}
                  extra="同步开通艺人账号并加入本项目(上传/下载/查看);与艺人姓名都留空 = 仅创建项目"
                  validateStatus={usernameConflict ? 'error' : undefined}
                  help={usernameConflict
                    ? '该登录名已被占用；若属于该艺人本人（此前已开通），请勿重复开通，可联系管理员将其加入本项目成员'
                    : undefined}
                  rules={[
                    ({ getFieldValue }) => ({
                      validator: async (_, value: string | undefined) => {
                        const self = (value ?? '').trim();
                        const other = ((getFieldValue('artist_name') as string | undefined) ?? '').trim();
                        if (!self && !other) return;      // 两项全空 = 不创建,免填
                        if (!self) throw new Error('已填写艺人姓名,登录名为必填');
                        if (self.length < 2 || self.length > 64 || !USERNAME_PATTERN.test(self)) {
                          throw new Error('登录名仅限字母/数字与 . _ -,长度 2-64');
                        }
                      },
                    }),
                  ]}
                >
                  <Input
                    placeholder="如 chenming(字母/数字/._-,2-64 位)"
                    autoComplete="off"
                  />
                </Form.Item>
                <Form.Item
                  name="artist_name"
                  label="艺人姓名"
                  dependencies={['artist_username']}
                  rules={[
                    ({ getFieldValue }) => ({
                      validator: async (_, value: string | undefined) => {
                        const self = (value ?? '').trim();
                        const other = ((getFieldValue('artist_username') as string | undefined) ?? '').trim();
                        if (!self && !other) return;      // 两项全空 = 不创建,免填
                        if (!self) throw new Error('已填写登录名,艺人姓名为必填(不能全为空白)');
                      },
                    }),
                  ]}
                >
                  <Input
                    placeholder="1-128 字;填写后自动带入项目名称(手改后脱钩)"
                    maxLength={128}
                    onChange={(e) => {
                      // 项目名联动(方案 F3-①):项目名未被手动编辑过时跟随艺人姓名
                      if (!projectNameManual) form.setFieldValue('name', e.target.value);
                    }}
                  />
                </Form.Item>
              </>
            )}
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

            {/* 目录模板(可选,folder-templates §6-F6):选中提交 folder_template_id,
                目录树由后端创建流程自动建立;不选不传字段,行为与现状一致 */}
            <Form.Item label="目录模板(可选)"
                       extra="选中模板后,项目创建时将按模板自动建立素材目录树;不选则行为不变">
              <Select
                value={folderTemplateId}
                onChange={setFolderTemplateId}
                optionLabelProp="labelText"
                options={folderTemplateOptions}
              />
              {selectedFolderTemplate && <FolderTemplatePreview template={selectedFolderTemplate} />}
              {folderTemplateId && (
                <div style={{
                  marginTop: 6, fontSize: 11, color: 'var(--ms-ink-subtle)',
                  display: 'inline-flex', alignItems: 'center', gap: 4,
                }}>
                  <Folder size={11} strokeWidth={1.8} />
                  目录将在项目创建后自动建立
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

    {/* 艺人账号一次性结果(艺人账号方案 §6-F3-②):替代 message.success 路径。
          三重防误关(closable/maskClosable/keyboard 全 false),密码只展示这一次;
          独立 Modal 不套 Form(antd v6 忌 Modal 内 setFieldsValue 回显) */}
      <Modal
        title="项目与艺人账号已创建"
        open={!!artistCreated}
        closable={false}
        maskClosable={false}
        keyboard={false}
        width={compact ? 'min(560px, calc(100vw - 16px))' : 560}
        footer={(
          <Button type="primary" onClick={finishArtistCreated}>我已保存，进入项目</Button>
        )}
      >
        {artistCreated && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            <div style={{ fontSize: 14, color: 'var(--ms-ink)' }}>
              项目「{artistCreated.projectName}（{artistCreated.projectCode}）」创建成功
            </div>
            <div style={{
              display: 'flex', flexDirection: 'column', gap: 8, padding: '12px 16px',
              background: 'var(--ms-surface)', border: '1px solid var(--ms-hairline)',
              borderRadius: 'var(--ms-radius-md)',
            }}>
              <div style={{ fontSize: 13, color: 'var(--ms-ink)' }}>
                艺人姓名:{artistCreated.artist.name}
              </div>
              <div style={{ fontSize: 13, color: 'var(--ms-ink)' }}>
                登录名:
                <Typography.Text copyable style={{ marginLeft: 4 }}>
                  {artistCreated.artist.username}
                </Typography.Text>
              </div>
              <div style={{ fontSize: 13, color: 'var(--ms-ink)' }}>
                初始密码:
                <Typography.Text copyable style={{ marginLeft: 4 }}>
                  {artistCreated.artist.temporary_password}
                </Typography.Text>
              </div>
            </div>
            <Alert
              type="warning"
              showIcon
              message="密码仅展示这一次，关闭后无法再查；请复制并转交艺人，首次登录将要求修改密码"
            />
          </div>
        )}
      </Modal>
    </>
  );
}

/** 目录模板只读树预览(选中模板时展示;与 AdminFolderTemplatesPage 共用 paths→treeData 纯函数)。*/
function FolderTemplatePreview({ template }: { template: FolderTemplate }) {
  const paths = useMemo(() => template.entries.map(e => e.path), [template]);
  const treeData = useMemo(() => pathsToTreeData(paths), [paths]);
  const treeKeys = useMemo(() => collectTreeKeys(treeData), [treeData]);
  return (
    <div style={{
      marginTop: 12, padding: '10px 12px', background: 'var(--ms-surface)',
      border: '1px solid var(--ms-hairline)', borderRadius: 'var(--ms-radius-md)',
      maxHeight: 260, overflowY: 'auto',
    }}>
      <div style={{
        display: 'flex', justifyContent: 'space-between', gap: 8,
        fontSize: 11, color: 'var(--ms-ink-subtle)', marginBottom: 4,
      }}>
        <span>目录树预览</span>
        <span>{paths.length} 条路径 · 去重后 {treeKeys.length} 个目录</span>
      </div>
      {/* key 取全部节点 key 签名:结构变化即重挂载,保证 defaultExpandAll 恒全展开 */}
      <Tree blockNode showLine selectable={false} defaultExpandAll
            key={treeKeys.join('\n')} treeData={treeData} />
    </div>
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
