/**
 * BaiduNewTaskModal — 新建百度网盘备份任务(方案 §3.3,双栏)。
 * 左栏:百度网盘目录树(懒加载 GET /backup/netdisk/folders?path=,根部为网盘根;
 * 条目为目录+文件——目录可选可展开,文件仅展示不可选,保持「选目录创建任务」语义);
 * 右栏:项目选择(is_system_admin || 我可上传)+ 目标目录(FolderTree 复用,
 * sensitive 及其整棵子树禁选;选项目根 = 自动创建承接夹)。
 * 底部文案按 §3.3:限速 / 单轮上限 / 单文件上限 / 覆盖导入警示。
 */
import { App, Alert, Button, Empty, Modal, Select, Space, Spin, Tree, Typography } from 'antd';
import type { TreeDataNode } from 'antd';
import { File as FileIcon, FileText, Folder as FolderIcon, Image as ImageIcon, Play, RefreshCw } from 'lucide-react';
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
      .then(({ list, truncated }) => {
        if (!cancelled) setTreeData(toNetdiskNodes('/', list, truncated));
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
                  const parentKey = String(node.key);
                  try {
                    const { list, truncated } = await fetchNetdiskFolders(parentKey);
                    // antd 官方懒加载模式:rc-tree onNodeLoad 只标记 loadedKeys 并 resolve,
                    // loadData 的返回值会被丢弃,必须在此把子节点合并进受控 treeData 再 resolve。
                    setTreeData(prev => attachChildren(prev, parentKey, toNetdiskNodes(parentKey, list, truncated)));
                  } catch (e) {
                    message.error(errorMessage(e, '读取网盘子目录失败'));
                    throw e;   // reject 不置 loadedKeys:节点保持未展开,可重试点开
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

// ── 网盘树节点构造 ──────────────────────────────────────────────────────
// 条目 → 树节点(F2):目录=现状(可选可展开);文件=类型图标+名称+大小,
// isLeaf+selectable:false+灰显(「已选来源」恒为目录,创建任务逻辑零改动)。
// truncated=true 时在子节点尾部插一条不可选提示行(大目录聚合分页未取尽)。
const TRUNCATED_HINT_KEY = (parent: string) => `${parent}::truncated-hint`;

/**
 * 把 children 挂为 treeData 中 key === parentKey 节点的 children(整体替换,D2)。
 * 纯函数 + 不可变更新:命中路径上的节点浅拷贝新建,未受影响分支保持原引用;
 * 全树未命中 parentKey 时返回原数组引用(如刷新竞态:attach 到已清空的树上 = 无操作)。
 * 重复挂载无需特殊处理:rc-tree loadedKeys 保证已加载节点不会再次进入 loadData。
 */
function attachChildren(treeData: TreeDataNode[], parentKey: string, children: TreeDataNode[]): TreeDataNode[] {
  let changed = false;
  const next = treeData.map(node => {
    if (String(node.key) === parentKey) {
      changed = true;
      return { ...node, children };
    }
    if (node.children?.length) {
      const merged = attachChildren(node.children, parentKey, children);
      if (merged !== node.children) {
        changed = true;
        return { ...node, children: merged };
      }
    }
    return node;
  });
  return changed ? next : treeData;
}

function toNetdiskNodes(parent: string, list: BaiduNetdiskFolder[], truncated: boolean): TreeDataNode[] {
  const nodes = list.map(toNetdiskNode);
  if (truncated) {
    nodes.push({
      key: TRUNCATED_HINT_KEY(parent),
      title: '目录过大,仅显示部分内容',
      icon: <FolderIcon size={14} strokeWidth={1.7} style={{ visibility: 'hidden' }} />,   // 占位对齐,不显示
      isLeaf: true,
      selectable: false,
      style: { color: 'var(--ms-amber)', fontStyle: 'italic' },
    });
  }
  return nodes;
}

function toNetdiskNode(f: BaiduNetdiskFolder): TreeDataNode {
  if (f.is_dir) {
    return {
      key: f.path,
      title: f.name,
      icon: <FolderIcon size={14} strokeWidth={1.7} style={{ color: 'var(--ms-ink-muted)' }} />,
      isLeaf: false,   // 目录可能有子目录,展开时懒加载;加载为空则自动收口
    };
  }
  // 文件行:仅展示不可选(D2),灰显低对比度
  return {
    key: f.path,
    title: (
      <span>
        {f.name}
        {f.size_bytes != null && (
          <span style={{ marginLeft: 8, fontSize: 11, color: 'var(--ms-ink-subtle)' }}>
            {fmtBytes(f.size_bytes)}
          </span>
        )}
      </span>
    ),
    icon: <FileTypeIcon name={f.name} />,
    isLeaf: true,
    selectable: false,
    style: { color: 'var(--ms-ink-muted)' },
  };
}

// 文件类型图标(按扩展名,沿用仓内 AssetPreviewModal 的 ImageIcon/Play/FileText 惯例)
const IMAGE_EXT = new Set(['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic', '.heif', '.tif', '.tiff', '.svg']);
const VIDEO_EXT = new Set(['.mp4', '.mov', '.avi', '.mkv', '.webm', '.m4v', '.wmv', '.flv', '.3gp']);
const DOC_EXT = new Set(['.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.txt', '.md', '.csv']);

function FileTypeIcon({ name }: { name: string }) {
  const dot = name.lastIndexOf('.');
  const ext = dot >= 0 ? name.slice(dot).toLowerCase() : '';
  const style: React.CSSProperties = { color: 'var(--ms-ink-muted)' };
  if (IMAGE_EXT.has(ext)) return <ImageIcon size={14} strokeWidth={1.7} style={style} />;
  if (VIDEO_EXT.has(ext)) return <Play size={14} strokeWidth={1.7} style={style} />;
  if (DOC_EXT.has(ext)) return <FileText size={14} strokeWidth={1.7} style={style} />;
  return <FileIcon size={14} strokeWidth={1.7} style={style} />;
}

// bytes 人类可读(与 BaiduBackupDrawer / TaskCenterDrawer 的 fmtBytes 同口径)
function fmtBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(1)} MB`;
  if (n < 1024 ** 4) return `${(n / 1024 ** 3).toFixed(2)} GB`;
  return `${(n / 1024 ** 4).toFixed(2)} TB`;
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
