/**
 * BaiduNewTaskModal — 新建百度网盘备份任务(方案 §3.3,双栏)。
 * 左栏:百度网盘目录树(懒加载 GET /backup/netdisk/folders?path=,根部为网盘根);
 * 右栏:项目选择(is_system_admin || 我可上传)+ 目标目录(FolderTree 复用,
 * sensitive 及其整棵子树禁选;选项目根 = 自动创建承接夹)。
 * 底部文案按 §3.3:限速 / 单轮上限 / 单文件上限 / 覆盖导入警示。
 */
import { App, Alert, Button, Empty, Modal, Select, Space, Spin, Tree, Typography } from 'antd';
import type { TreeDataNode } from 'antd';
import { Folder as FolderIcon, RefreshCw } from 'lucide-react';
import { useEffect, useMemo, useState } from 'react';
import { errorMessage } from '../api/client';
import { useBaiduCreateTask, useBaiduNetdiskFolders, useFolders, useProjects } from '../api/hooks';
import type { BaiduNetdiskFolder, Me } from '../api/types';
import { FolderTree } from './FolderTree';

interface Props {
  open: boolean;
  onClose: () => void;
  me: Me;
}

type Target = { kind: 'root' } | { kind: 'folder'; id: string; name: string };

const COLUMN_MIN_WIDTH = 300;

export function BaiduNewTaskModal({ open, onClose, me }: Props) {
  const { message } = App.useApp();
  const create = useBaiduCreateTask();
  const fetchNetdiskFolders = useBaiduNetdiskFolders();

  // ── 左栏:网盘树(懒加载)──
  const [treeData, setTreeData] = useState<TreeDataNode[]>([]);
  const [rootLoading, setRootLoading] = useState(true);
  const [treeVersion, setTreeVersion] = useState(0);   // 手动刷新 → key 重挂载,清空 loadData 缓存
  const [sourceDir, setSourceDir] = useState<string | null>(null);

  // ── 右栏:项目 + 目标目录 ──
  const { data: projects } = useProjects();
  const creatableProjects = useMemo(() =>
    (projects ?? []).filter(p =>
      me.is_system_admin || p.my_roles.some(r => r === 'admin' || r === 'uploader'),
    ), [projects, me.is_system_admin]);
  const [projectId, setProjectId] = useState<string | null>(null);
  const { data: folders } = useFolders(projectId ?? undefined);
  const [target, setTarget] = useState<Target>({ kind: 'root' });

  // destroyOnHidden:关闭即卸载,状态随重开复位,无需 effect 重置。
  // 首挂(rootLoading 初始 true)拉取网盘根目录;setState 均在异步回调内。
  useEffect(() => {
    if (!open) return;
    let cancelled = false;
    fetchNetdiskFolders('/')
      .then(list => {
        if (!cancelled) setTreeData(list.map(toNetdiskNode));
      })
      .catch(e => {
        if (!cancelled) message.error(errorMessage(e, '读取百度网盘目录失败'));
      })
      .finally(() => {
        if (!cancelled) setRootLoading(false);
      });
    return () => { cancelled = true; };
  }, [open, treeVersion, fetchNetdiskFolders, message]);

  const refreshTree = () => {
    setTreeData([]);
    setSourceDir(null);
    setRootLoading(true);
    setTreeVersion(v => v + 1);
  };

  const selectedProject = creatableProjects.find(p => p.id === projectId);
  const sensitiveIds = useMemo(
    () => (folders ?? []).filter(f => f.is_sensitive).map(f => f.id),
    [folders],
  );

  const targetLabel = target.kind === 'root'
    ? `项目根(自动创建承接文件夹${sourceDir ? `「${dirName(sourceDir)}」` : ''})`
    : `目录「${target.name}」`;

  const submit = async () => {
    if (!sourceDir || sourceDir === '/') {
      message.warning('请先在左侧选择一个网盘目录(不支持整盘根目录)');
      return;
    }
    if (!projectId) {
      message.warning('请选择目标项目');
      return;
    }
    try {
      await create.mutateAsync({
        source_dir: sourceDir,
        project_id: projectId,
        ...(target.kind === 'folder' ? { target_folder_id: target.id } : {}),
      });
      message.success('备份任务已创建,清单准备中');
      onClose();
    } catch (e) {
      message.error(errorMessage(e, '创建任务失败'));
    }
  };

  return (
    <Modal
      title="新建备份任务"
      open={open}
      onCancel={onClose}
      destroyOnHidden
      maskClosable={false}
      width="min(880px, 100vw)"
      footer={
        <Space>
          <Button onClick={onClose}>取消</Button>
          <Button type="primary" loading={create.isPending} onClick={submit}>
            开始备份
          </Button>
        </Space>
      }
    >
      <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap', paddingTop: 8 }}>
        {/* ── 左栏:百度网盘目录树 ── */}
        <div style={{
          flex: `1 1 ${COLUMN_MIN_WIDTH}px`,
          minWidth: COLUMN_MIN_WIDTH,
          border: '1px solid var(--ms-hairline)',
          borderRadius: 'var(--ms-radius-md)',
          display: 'flex', flexDirection: 'column',
          maxHeight: 420,
        }}>
          <div style={{
            display: 'flex', alignItems: 'center', gap: 6,
            padding: '8px 12px',
            borderBottom: '1px solid var(--ms-hairline-soft)',
            fontSize: 12, color: 'var(--ms-ink-muted)', fontWeight: 500,
          }}>
            <span style={{ flex: 1 }}>百度网盘目录</span>
            <Button size="small" type="text" icon={<RefreshCw size={12} strokeWidth={2} />}
                    onClick={refreshTree} aria-label="刷新网盘目录" />
          </div>
          <div style={{ flex: 1, minHeight: 0, overflow: 'auto', padding: '4px 8px' }}>
            {rootLoading ? (
              <div style={{ padding: '40px 0', textAlign: 'center' }}><Spin /></div>
            ) : treeData.length === 0 ? (
              <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description="网盘为空或读取失败,可点右上刷新"
                     style={{ marginTop: 32 }} />
            ) : (
              <Tree
                key={treeVersion}
                treeData={treeData}
                showIcon
                blockNode
                loadData={async (node) => {
                  try {
                    const kids = await fetchNetdiskFolders(String(node.key));
                    return kids.map(toNetdiskNode);
                  } catch (e) {
                    message.error(errorMessage(e, '读取网盘子目录失败'));
                    return [];   // 展开失败收口为空目录,可手动刷新重试
                  }
                }}
                selectedKeys={sourceDir ? [sourceDir] : []}
                onSelect={(keys) => setSourceDir((keys[0] as string) ?? null)}
              />
            )}
          </div>
          <div style={{
            padding: '8px 12px',
            borderTop: '1px solid var(--ms-hairline-soft)',
            fontSize: 11.5, color: 'var(--ms-ink-muted)',
          }}>
            已选来源:{sourceDir ? (
              <Typography.Text code style={{ fontSize: 11, wordBreak: 'break-all' }}>
                {sourceDir}
              </Typography.Text>
            ) : '未选择(点选目录;不支持整盘根目录)'}
          </div>
        </div>

        {/* ── 右栏:项目 + 目标目录 ── */}
        <div style={{
          flex: `1 1 ${COLUMN_MIN_WIDTH}px`,
          minWidth: COLUMN_MIN_WIDTH,
          display: 'flex', flexDirection: 'column', gap: 10,
        }}>
          <div>
            <FieldLabel>目标项目(仅列出你可上传的项目)</FieldLabel>
            <Select
              style={{ width: '100%' }}
              placeholder="选择项目"
              value={projectId}
              onChange={(v) => { setProjectId(v); setTarget({ kind: 'root' }); }}
              showSearch
              optionFilterProp="label"
              options={creatableProjects.map(p => ({ value: p.id, label: p.name }))}
              notFoundContent="无可用项目"
            />
          </div>
          {projectId && selectedProject && (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 6, minHeight: 0 }}>
              <FieldLabel>导入到哪个目录(敏感目录及其子目录不可选)</FieldLabel>
              {/* 项目根 = 自动创建承接夹(以网盘目录末段命名,同名复用) */}
              <div
                onClick={() => setTarget({ kind: 'root' })}
                style={{
                  display: 'flex', alignItems: 'center', gap: 8,
                  padding: '7px 10px',
                  border: `1px solid ${target.kind === 'root' ? 'var(--ms-accent)' : 'var(--ms-hairline)'}`,
                  background: target.kind === 'root' ? 'var(--ms-accent-soft)' : 'transparent',
                  borderRadius: 'var(--ms-radius-sm)',
                  cursor: 'pointer', fontSize: 13, color: 'var(--ms-ink)',
                }}>
                <FolderIcon size={14} strokeWidth={1.7} style={{ color: 'var(--ms-ink-muted)', flexShrink: 0 }} />
                <span style={{ fontWeight: target.kind === 'root' ? 500 : 400 }}>项目根</span>
                <span style={{ fontSize: 11, color: 'var(--ms-ink-subtle)' }}>
                  自动创建承接文件夹(以网盘目录名命名,同名复用)
                </span>
              </div>
              <div style={{
                border: '1px solid var(--ms-hairline)',
                borderRadius: 'var(--ms-radius-sm)',
                maxHeight: 300, overflow: 'auto',
              }}>
                <FolderTree
                  folders={folders ?? []}
                  projectName={selectedProject.name}
                  selectMode
                  disabledIds={sensitiveIds}
                  activeFolderId={target.kind === 'folder' ? target.id : null}
                  onSelect={(fid) => {
                    const f = (folders ?? []).find(x => x.id === fid);
                    if (f) setTarget({ kind: 'folder', id: f.id, name: f.name });
                  }}
                />
              </div>
            </div>
          )}
          <div style={{ fontSize: 11.5, color: 'var(--ms-ink-muted)' }}>
            已选目标:{targetLabel}
          </div>
        </div>
      </div>

      <Alert
        type="info"
        showIcon
        style={{ marginTop: 16 }}
        message="开始前请了解"
        description={
          <ul style={{ margin: 0, paddingLeft: 18, fontSize: 12, lineHeight: 1.9 }}>
            <li>非会员限速约 0.08 MiB/s,大目录耗时较长,请耐心等待。</li>
            <li>单轮导入上限约 14GB / 48 小时;超限后任务失败,可用「全部重试失败」继续下一轮(断点续传)。</li>
            <li>单文件上限 160GB;超过 130GB 的文件须在 30 天内完成(含排队等待),建议拆分目录。</li>
            <li>同名文件默认跳过(已存在的不会被改动);之后可对跳过文件执行「覆盖导入」——该操作会<b>永久删除</b>原文件后重新导入,且需要管理权限。</li>
          </ul>
        }
      />
    </Modal>
  );
}

function toNetdiskNode(f: BaiduNetdiskFolder): TreeDataNode {
  return {
    key: f.path,
    title: f.name,
    icon: <FolderIcon size={14} strokeWidth={1.7} style={{ color: 'var(--ms-ink-muted)' }} />,
    isLeaf: false,   // 目录可能有子目录,展开时懒加载;加载为空则自动收口
  };
}

/** 网盘目录末段(承接夹命名口径,§5.2:先 rstrip('/') 再取末段)。 */
function dirName(path: string): string {
  const trimmed = path.replace(/\/+$/, '');
  const idx = trimmed.lastIndexOf('/');
  return idx >= 0 ? trimmed.slice(idx + 1) : trimmed;
}

function FieldLabel({ children }: { children: React.ReactNode }) {
  return (
    <div style={{
      fontSize: 11, color: 'var(--ms-ink-muted)',
      marginBottom: 6, fontWeight: 500,
    }}>{children}</div>
  );
}
