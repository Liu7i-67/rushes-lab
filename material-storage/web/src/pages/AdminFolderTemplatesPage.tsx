/**
 * /admin/folder-templates — 目录模板管理(方案 folder-templates §6-F3)。
 * 模板 = 一组项目根下相对路径(素材/视频/原始);新建项目时选模板一键建目录树。
 * 编辑 = 行式路径(Form.List)+ 只读树预览(所见即所存);写门 require_folder_template_manager,
 * 读门为组合弱门 — 页面路由可达即渲染,写操作失败按 403 提示(方案 §6-F3,不整抄
 * AdminGrantTemplatesPage 的系统 admin 硬门);布局 / 行交互照 AdminGrantTemplatesPage。
 */
import {
  Alert, App, Button, Empty, Form, Input, Modal, Popconfirm, Skeleton, Tooltip, Tree,
} from 'antd';
import { FolderTree, Plus, Trash2 } from 'lucide-react';
import { useMemo, useState } from 'react';
import {
  useFolderTemplates, useCreateFolderTemplate, useUpdateFolderTemplate,
  useDeleteFolderTemplate,
} from '../api/hooks';
import { errorMessage } from '../api/client';
import { useCompactViewport } from '../lib/use-viewports';
import type { FolderTemplate } from '../api/types';
import { pathsToTreeData, collectTreeKeys } from '../utils/folder-tree';

export default function AdminFolderTemplatesPage() {
  const { data, isLoading } = useFolderTemplates();

  return (
    <div className="ms-enter">
      <TemplatesHeader />
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
                 无目录模板 · 新建一个供新建项目时一键建立目录树
               </span>}
               style={{ marginTop: 60 }} />
      ) : (
        <div className="ms-enter-stagger"
             style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          {data.map(t => <TemplateRow key={t.id} template={t} />)}
        </div>
      )}
    </div>
  );
}

function TemplatesHeader() {
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
        }}>目录模板</h1>
        <p style={{ margin: '8px 0 0', fontSize: 13, color: 'var(--ms-ink-muted)' }}>
          目录结构预设 — 新建项目时选模板一键建立素材目录树;应用即快照,后续改模板不影响已建项目
        </p>
      </div>
      <div style={{ display: 'flex', gap: 8, flexShrink: 0 }}>
        <Button type="primary" icon={<Plus size={14} strokeWidth={2} />}
                onClick={() => setOpen(true)}>
          新建模板
        </Button>
      </div>
      <TemplateFormModal open={open} onClose={() => setOpen(false)} />
    </div>
  );
}

function TemplateRow({ template }: { template: FolderTemplate }) {
  const { message } = App.useApp();
  const [editOpen, setEditOpen] = useState(false);
  const del = useDeleteFolderTemplate();
  const [deleting, setDeleting] = useState(false);
  const compact = useCompactViewport();

  const doDelete = async () => {
    setDeleting(true);
    try {
      await del.mutateAsync(template.id);
      message.success(`已删除目录模板「${template.name}」`);
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
        <FolderTree size={16} strokeWidth={1.8} />
      </div>
      <div style={{ flex: 1, minWidth: 220 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
          <span style={{ fontSize: 13, fontWeight: 500, color: 'var(--ms-ink)' }}>
            {template.name}
          </span>
          <span style={{
            fontFamily: 'var(--ms-font-mono)', fontSize: 10.5, color: 'var(--ms-ink-subtle)',
            padding: '1px 7px', background: 'var(--ms-hairline-soft)', borderRadius: 3,
          }}>
            {template.entry_count} 个目录
          </span>
        </div>
        {template.description && (
          <div style={{
            marginTop: 3, fontSize: 11.5, color: 'var(--ms-ink-muted)',
            overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
          }}>{template.description}</div>
        )}
        {/* 条目一览(最多展示 6 条,余量折叠) */}
        {template.entries.length > 0 && (
          <div style={{
            marginTop: 6, display: 'flex', flexWrap: 'wrap', gap: 4, alignItems: 'center',
          }}>
            {template.entries.slice(0, 6).map(e => (
              <Tooltip key={e.path} title={e.path}>
                <span style={{
                  maxWidth: 220, overflow: 'hidden', textOverflow: 'ellipsis',
                  whiteSpace: 'nowrap',
                  padding: '1px 8px', background: 'var(--ms-hairline-soft)',
                  borderRadius: 3, fontSize: 11, color: 'var(--ms-ink-muted)',
                }}>{e.path}</span>
              </Tooltip>
            ))}
            {template.entries.length > 6 && (
              <span style={{ fontSize: 11, color: 'var(--ms-ink-subtle)' }}>
                +{template.entries.length - 6}
              </span>
            )}
          </div>
        )}
      </div>
      <div style={{ display: 'flex', gap: 6, flexShrink: 0, flexBasis: compact ? '100%' : undefined,
                    justifyContent: compact ? 'flex-end' : undefined }}>
        <Button size="small" onClick={() => setEditOpen(true)}>编辑</Button>
        <Popconfirm
          title={`删除目录模板「${template.name}」?`}
          description={`${template.entry_count} 条目录条目将一并删除;已建项目不受影响`}
          okText="删除" okButtonProps={{ danger: true }}
          onConfirm={doDelete}
        >
          <Button size="small" danger icon={<Trash2 size={12} strokeWidth={2} />}
                  loading={deleting} />
        </Popconfirm>
      </div>
      <TemplateFormModal open={editOpen} onClose={() => setEditOpen(false)}
                         template={template} />
    </div>
  );
}
// ─── 新建 / 编辑模板 ─────────────────────────────────────────────────────────
interface TemplateFormValues {
  name: string;
  description?: string;
  entries?: string[];
}

/** 单条路径前端校验(镜像后端 _validate_entry_paths 的明显非法项,便于提前提示;后端仍复检)。*/
const pathErrorOf = (raw: string): string | null => {
  const p = raw.trim();
  if (!p) return '路径为空';
  if (p.startsWith('/') || p.endsWith('/')) return '不能以 / 开头或结尾';
  const segs = p.split('/');
  if (segs.some(s => s === '')) return '含空段(连续 //)';
  if (segs.length > 10) return '层级超 10 段';
  for (const s of segs) {
    if (s === '.' || s === '..') return `段「${s}」非法`;
    if (s.includes('\\')) return '段不能含反斜杠 \\';
    if (s !== s.trim()) return `段「${s}」首尾含空白`;
    if (s.length > 255) return '单段超 255 字符';
  }
  if (p.length > 600) return '总长超 600 字符';
  return null;
};

function TemplateFormModal({ open, onClose, template }: {
  open: boolean; onClose: () => void; template?: FolderTemplate;
}) {
  const create = useCreateFolderTemplate();
  const update = useUpdateFolderTemplate();
  const [form] = Form.useForm<TemplateFormValues>();
  const { message } = App.useApp();
  const isEdit = !!template;

  // 树预览数据源:Form.List 当前值(输入即所得);行值统一规整为字符串后切树
  const watchEntries = Form.useWatch('entries', form);
  const toPaths = (vals: unknown[]) => vals.map(v => (typeof v === 'string' ? v : ''));
  const paths = toPaths(watchEntries ?? []);
  const treeData = useMemo(() => pathsToTreeData(toPaths(watchEntries ?? [])), [watchEntries]);
  const treeKeys = useMemo(() => collectTreeKeys(treeData), [treeData]);

  const submit = async () => {
    try {
      const v = await form.validateFields();
      const rows = (v.entries ?? []).map(e => (e ?? '').trim());
      if (rows.length === 0) {
        message.warning('请至少添加一个目录');
        return;
      }
      if (rows.length > 200) {
        message.warning('目录条目不能超过 200 条');
        return;
      }
      for (let i = 0; i < rows.length; i++) {
        const err = pathErrorOf(rows[i]);
        if (err) {
          message.warning(`第 ${i + 1} 行:${err}`);
          return;
        }
      }
      const seen = new Set<string>();
      for (const p of rows) {
        if (seen.has(p)) {
          message.warning(`存在重复路径:「${p}」`);
          return;
        }
        seen.add(p);
      }
      const entries = rows.map(path => ({ path }));
      if (isEdit) {
        await update.mutateAsync({
          templateId: template.id,
          name: v.name.trim(),
          description: v.description?.trim() || null,
          entries,
        });
        message.success('已保存');
      } else {
        await create.mutateAsync({
          name: v.name.trim(),
          description: v.description?.trim() || undefined,
          entries,
        });
        message.success(`目录模板「${v.name.trim()}」已创建`);
      }
      onClose();
    } catch (e) {
      if ((e as { errorFields?: unknown }).errorFields) return;
      message.error(errorMessage(e, isEdit ? '保存失败' : '创建失败'));
    }
  };

  return (
    <Modal title={isEdit ? `编辑目录模板 — ${template.name}` : '新建目录模板'}
           open={open} onCancel={onClose} destroyOnClose
           width="min(680px, calc(100vw - 16px))"
           styles={{ body: { maxHeight: '70vh', overflowY: 'auto' } }}
           confirmLoading={isEdit ? update.isPending : create.isPending}
           onOk={submit} okText={isEdit ? '保存' : '创建'}>
      <Form key={isEdit ? template.id : 'new'} form={form} layout="vertical" preserve={false}
            initialValues={template ? {
              name: template.name, description: template.description || undefined,
              entries: template.entries.map(e => e.path),
            } : { entries: [''] }}>
        <Form.Item name="name" label="模板名" rules={[{ required: true, max: 128 }]}>
          <Input placeholder="婚礼项目素材分类" autoFocus />
        </Form.Item>
        <Form.Item name="description" label="描述(可选)" rules={[{ max: 1024 }]}>
          <Input.TextArea rows={2} maxLength={1024} showCount />
        </Form.Item>
        <Form.Item label="目录条目" required
                   extra="每行一条项目根下相对路径,以 / 分隔层级(如 素材/视频/原始);保存时全量替换,最多 200 条">
          <Form.List name="entries">
            {(fields, { add, remove }) => (
              <>
                {fields.map(field => (
                  <div key={field.key}
                       style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 8 }}>
                    <Form.Item name={field.name} noStyle>
                      <Input placeholder="素材/视频/原始" autoComplete="off" allowClear />
                    </Form.Item>
                    <Tooltip title="移除该行">
                      <Button size="small" type="text" danger
                              icon={<Trash2 size={13} strokeWidth={2} />}
                              onClick={() => remove(field.name)} style={{ flexShrink: 0 }} />
                    </Tooltip>
                  </div>
                ))}
                <Button type="dashed" block icon={<Plus size={14} strokeWidth={2} />}
                        onClick={() => add('')}>
                  添加目录
                </Button>
              </>
            )}
          </Form.List>
        </Form.Item>
        {/* 只读树预览:paths→treeData 纯函数按 / 切裂(与 NewProjectModal 共用) */}
        {treeData.length > 0 ? (
          <div style={{
            marginTop: 4, padding: '10px 12px', background: 'var(--ms-canvas)',
            border: '1px solid var(--ms-hairline-soft)', borderRadius: 'var(--ms-radius-sm)',
            maxHeight: 260, overflowY: 'auto',
          }}>
            <div style={{
              display: 'flex', justifyContent: 'space-between', gap: 8,
              fontSize: 11, color: 'var(--ms-ink-subtle)', marginBottom: 4,
            }}>
              <span>目录树预览(只读)</span>
              <span>{paths.length} 条路径 · 去重后 {treeKeys.length} 个目录</span>
            </div>
            {/* key 取全部节点 key 签名:结构变化即重挂载,保证 defaultExpandAll 恒全展开 */}
            <Tree blockNode showLine selectable={false} defaultExpandAll
                  key={treeKeys.join('\n')} treeData={treeData} />
          </div>
        ) : (
          <Alert type="info" showIcon style={{ marginTop: 8 }}
                 message="添加目录后此处显示树形预览" />
        )}
      </Form>
    </Modal>
  );
}
