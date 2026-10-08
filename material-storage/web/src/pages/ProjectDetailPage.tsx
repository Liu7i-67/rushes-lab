/**
 * workspace:compact(<1024)单栏骨架(树 Drawer + AssetCardList + 详情 bottom Drawer +
 * 批量操作栏)/ 桌面三栏(左 FolderTree / 中 AssetTable / 右 AssetSummaryPanel,顶 ActionsBar)。
 */
import {
  App, Button, Checkbox, Drawer, Layout, Modal, Pagination, Popconfirm, Select, Skeleton,
  Space, Table, Tooltip,
} from 'antd';
import {
  Archive, ChevronDown, ChevronLeft, ChevronRight, Download, FileText,
  Folder as FolderIcon, FolderPlus, Key, Link2, Lock, Menu, RotateCw, Settings, Tags,
  Trash2, Type, Upload, Users as UsersIcon,
} from 'lucide-react';
import { useNavigate, useParams } from 'react-router-dom';
import { useEffect, useMemo, useRef, useState } from 'react';
import {
  ASSETS_PAGE_SIZE, useAssets, useDeleteAsset, useDeleteFolder, useDownloadLink,
  useFolder, useFolders, useMe, useProject, useTrashAssets, useUpdateAssetMeta,
} from '../api/hooks';
import { AppBreadcrumb } from '../components/AppBreadcrumb';
import { FolderTree } from '../components/FolderTree';
import { AssetSummaryPanel } from '../components/AssetSummaryPanel';
import { AssetCardList } from '../components/AssetCardList';
import { AssetTagEditor } from '../components/AssetTagEditor';
import { AssetThumbnail } from '../components/AssetThumbnail';
import { BatchPrefixModal } from '../components/BatchPrefixModal';
import { FolderTrashModal } from '../components/FolderTrashModal';
import { ProjectMembersDrawer } from '../components/ProjectMembersDrawer';
import { RequestAccessModal } from '../components/RequestAccessModal';
import { RequestLinkCreateModal } from '../components/RequestLinkCreateModal';
import { NewFolderModal } from '../components/NewFolderModal';
import { useCompactViewport } from '../lib/use-viewports';
import { scrollMainToTop } from '../lib/main-scroll';
import { useKeyboardVisible, useKeyboardViewportHeight } from '../lib/use-keyboard-visible';
import { useUpload } from '../lib/upload-store';
import { useDownloads } from '../lib/download-store';
import { errorMessage } from '../api/client';
import type { Asset, Folder } from '../api/types';

function fmtBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(1)} MB`;
  return `${(n / 1024 ** 3).toFixed(2)} GB`;
}

export default function ProjectDetailPage() {
  const { projectId, folderId: paramFolderId } = useParams<{ projectId: string; folderId?: string }>();
  const navigate = useNavigate();
  // hooks 置顶(compact 判定唯一源,见 use-viewports 模块注释:首过返回 mobile,
  // 分支只切 JSX,不挂不同数量的 hook)
  const compact = useCompactViewport();
  const kbVisible = useKeyboardVisible();
  const kbViewportHeight = useKeyboardViewportHeight();

  const { data: project } = useProject(projectId);
  // 项目级上传权限(uploader/admin):建根目录、FolderTree 新建入口用;
  // 后端对建目录/上传都强制 can_upload,这里只是 UI 门控
  const canUploadProject = !!project?.my_roles?.includes('admin')
    || !!project?.my_roles?.includes('uploader');
  const { data: me } = useMe();
  const { data: folders, isLoading: foldersLoading } = useFolders(projectId);
  const [activeFolderId, setActiveFolderId] = useState<string | null>(paramFolderId ?? null);

  // 选中 folder 默认为 path 参数;无则 = 首个可见 folder;
  // activeFolderId 指向的文件夹已不在可见列表(被删/失权)时纠正到首个可见,
  // 避免幽灵选中(header 挂着已删夹且 staleTime 内无自愈)
  // URL 参数 + 异步 folders 数据联动纠正,依赖服务端取数结果,无法在 render 期纯派生 — 豁免 cascading 警告
  /* eslint-disable react-hooks/set-state-in-effect */
  useEffect(() => {
    if (paramFolderId) {
      setActiveFolderId(paramFolderId);
    } else if (!activeFolderId && folders && folders.length > 0) {
      setActiveFolderId(folders[0].id);
    } else if (
      activeFolderId && folders && folders.length > 0
      && !folders.some(f => f.id === activeFolderId)
    ) {
      setActiveFolderId(folders[0].id);
    }
  }, [paramFolderId, folders, activeFolderId]);
  /* eslint-enable react-hooks/set-state-in-effect */

  const { data: folder } = useFolder(activeFolderId ?? undefined);
  // 服务端分页:超一页的 folder 走后端 limit/offset,旧文件不再被 100 条截断吞掉
  const [page, setPage] = useState(1);
  const { data: assets, isLoading: assetsLoading, isFetching, refetch } =
    useAssets(activeFolderId ?? undefined, page, ASSETS_PAGE_SIZE);
  // useMemo 包稳 `?? []` 兜底数组的引用(兜底时每 render 新建导致下游 useMemo 失效,规则建议的等价变换)
  const assetItems = useMemo(() => assets?.items ?? [], [assets]);
  const assetTotal = assets?.total ?? 0;

  const [selectedIds, setSelectedIds] = useState<string[]>([]);
  // PR-1: 批量文件名前缀 — 选中多个文件时统一加/去前缀
  const [batchPrefixOpen, setBatchPrefixOpen] = useState(false);
  // compact 专属 UI 状态(桌面分支不消费;hooks/状态置顶约定 → 无条件声明):
  // 树 Drawer / folder 管理 Drawer / 详情 Drawer(state 存 assetItems 的 index 而非 id,
  // ‹ n/N › 切张只换内容,Drawer 常驻)
  const [treeOpen, setTreeOpen] = useState(false);
  const [manageOpen, setManageOpen] = useState(false);
  const [detailIndex, setDetailIndex] = useState<number | null>(null);
  // 切 folder 回第一页并清空选择:分页选择只针对当前窗口,跨页保留会产生
  // 「选中但未加载 → 批量操作静默漏掉」的错位。render 期比较旧值重置
  // (React「adjust state on prop change」模式,不走 setState-in-effect)
  const [prevFolder, setPrevFolder] = useState<string | null>(activeFolderId);
  if (prevFolder !== activeFolderId) {
    setPrevFolder(activeFolderId);
    setPage(1);
    setSelectedIds([]);
    setDetailIndex(null);
  }
  // 分页器钉在表格区下方(不随行滚动);翻页/切夹把表格滚回顶部
  const tableScrollRef = useRef<HTMLDivElement | null>(null);
  useEffect(() => {
    tableScrollRef.current?.scrollTo({ top: 0 });
  }, [activeFolderId]);

  const selectedAssets = useMemo(
    () => assetItems.filter(a => selectedIds.includes(a.id)),
    [assetItems, selectedIds],
  );
  // PR-1 跨页保留选中:selectedIds 可能含未加载页的 id。id → Asset 索引供批量
  // 操作区分「已加载(有 filename)/未加载(用 id 占位)」;当前页 id 集合供
  // 自绘全选做并/差集与 checked/indeterminate 派生
  const assetById = useMemo(() => new Map(assetItems.map(a => [a.id, a])), [assetItems]);
  const pageIdSet = useMemo(() => new Set(assetItems.map(a => a.id)), [assetItems]);
  // 自绘全选的派生态:按「当前页 id 与 selectedIds 的交集数」对比当前页行数
  // (不再用 selectedIds.length 对比全量行数 — 跨页保留后语义坏)。selectedAssets
  // 即交集(按当前页过滤),长度可直接用
  const allPageSelected = assetItems.length > 0 && selectedAssets.length === assetItems.length;
  const somePageSelected = selectedAssets.length > 0 && !allPageSelected;

  const upload = useUpload();
  const downloads = useDownloads();
  const dlLink = useDownloadLink();
  const del = useDeleteAsset();
  const delFolder = useDeleteFolder();
  const { message, modal } = App.useApp();

  const [applyAsset, setApplyAsset] = useState<Asset | null>(null);
  const [applySensitive, setApplySensitive] = useState(false);
  const [newFolderMode, setNewFolderMode] = useState<'root' | 'child' | null>(null);
  const [membersOpen, setMembersOpen] = useState(false);
  // #151: 批量打标 — 选中多个文件时统一加标签
  const [bulkTagOpen, setBulkTagOpen] = useState(false);
  // #129: folder admin 才显"申请链接"按钮 — folder 级精细化授权入口
  const [linkOpen, setLinkOpen] = useState(false);
  // 回收站:普通夹 folder admin 可管理;sensitive 夹仅系统 admin(后端同规则 —
  // 敏感目录 can_view 不含项目 admin,回收站不能成为其窥探文件名的侧信道)
  const [trashOpen, setTrashOpen] = useState(false);
  const canSeeTrash = !!folder?.my_can_admin
    && (!folder.is_sensitive || !!me?.is_system_admin);
  const { data: trash } = useTrashAssets(activeFolderId ?? undefined, canSeeTrash);
  const trashCount = trash?.total ?? 0;

  const onFolderSelect = (fid: string) => {
    setActiveFolderId(fid);
    navigate(`/projects/${projectId}/folders/${fid}`, { replace: true });
  };

  const handleDownload = async (a: Asset) => {
    try {
      const link = await dlLink.mutateAsync(a.id);
      // assetId 供无 FSA 环境的直连路径换 as_attachment 链接(Chromium FSA 路径忽略)
      await downloads.start(link.url, a.filename, { assetId: a.id });
    } catch (e: unknown) {
      const err = e as { response?: { status?: number } };
      if (err.response?.status === 403) setApplyAsset(a);
      else message.error(errorMessage(e, '下载失败'));
    }
  };

  // 批量下载:切 selectedIds 全量口径(跨页保留后含未加载页的 id)—
  // 已加载项沿用原 filename;未加载 id 无 Asset 对象,用占位名 asset_<id 前 8 位>.bin。
  // 403 分流:已加载项弹申请弹窗(既有行为);未加载项缺完整 Asset,只计入「需申请」聚合计数。
  // 其余失败:已加载项逐条报错,未加载项按 id 聚合计数,避免长列表刷屏
  const handleBulkDownload = async () => {
    let needApply = 0, unloadedFail = 0;
    for (const id of selectedIds) {
      const a = assetById.get(id);
      const filename = a?.filename ?? `asset_${id.slice(0, 8)}.bin`;
      try {
        const link = await dlLink.mutateAsync(id);
        // assetId 供无 FSA 环境的直连路径换 as_attachment 链接(Chromium FSA 路径忽略)
        await downloads.start(link.url, filename, { assetId: id });
      } catch (e: unknown) {
        const err = e as { response?: { status?: number } };
        if (err.response?.status === 403) {
          if (a) setApplyAsset(a);
          else needApply++;
        } else if (a) {
          message.error(`${a.filename}: ${errorMessage(e, '下载失败')}`);
        } else {
          unloadedFail++;
        }
      }
    }
    if (needApply > 0) message.warning(`${needApply} 个未加载文件无下载权限,请翻页后逐个申请`);
    if (unloadedFail > 0) message.error(`${unloadedFail} 个未加载文件下载失败`);
  };

  // 批量下载 >20 加确认:逐条 presigned 循环,连续多下载易被浏览器拦截
  const confirmBulkDownload = () => {
    if (selectedIds.length > 20) {
      modal.confirm({
        title: `下载 ${selectedIds.length} 个文件?`,
        content: '数量较多,将逐个发起下载;浏览器可能拦截连续下载,建议分批(每批 ≤20)操作。',
        okText: '继续下载',
        onOk: handleBulkDownload,
      });
    } else {
      void handleBulkDownload();
    }
  };

  const handleBulkDelete = async () => {
    let ok = 0, fail = 0, unloadedFail = 0, okOnPage = 0;
    for (const id of selectedIds) {
      const a = assetById.get(id);
      try {
        await del.mutateAsync(id);
        ok++;
        if (pageIdSet.has(id)) okOnPage++;
      } catch (e) {
        fail++;
        // 已加载项逐条报错;未加载项按 id 聚合计数
        if (a) message.error(`${a.filename}: ${errorMessage(e)}`);
        else unloadedFail++;
      }
    }
    if (unloadedFail > 0) message.error(`${unloadedFail} 个未加载文件删除失败`);
    if (ok > 0) message.success(`删除 ${ok} 个文件${fail > 0 ? ` · 失败 ${fail}` : ''}`);
    setSelectedIds([]);
    // 删光当前页时回退一页,避免停在空尾页(page 变化触发重取,无需再 refetch);
    // 跨页删除后选中行从当前页消失,按「当前页剩余未删行数」判定(不再用 ok 对比全页行数)
    if (page > 1 && assetItems.length - okOnPage === 0) setPage(page - 1);
    else refetch();
  };

  // 删除 >100 加耗时提示(逐条 DELETE 循环,量大时明显变慢)
  const confirmBulkDelete = () => {
    if (selectedIds.length > 100) {
      modal.confirm({
        title: `删除 ${selectedIds.length} 个文件?`,
        content: '数量较多,逐个提交需要一些时间,期间请保持页面打开。',
        okText: '继续删除',
        okButtonProps: { danger: true },
        onOk: handleBulkDelete,
      });
    } else {
      void handleBulkDelete();
    }
  };

  // 删除文件夹:须 文件夹空(无子夹 + 无活跃文件)**且 回收站空**。
  // UI 预判只为按钮禁用态,真实判定以后端为准(后端 enforce 同规则)
  const folderChildCount = folders?.filter(f => f.parent_folder_id === activeFolderId).length ?? 0;
  const folderIsEmpty = assetTotal === 0 && folderChildCount === 0;
  const folderDeletable = folderIsEmpty && trashCount === 0;

  const handleDeleteFolder = async () => {
    if (!folder || !projectId) return;
    const parentId = folder.parent_folder_id;
    try {
      await delFolder.mutateAsync({ folder_id: folder.id, project_id: projectId });
      message.success(`文件夹「${folder.name}」已删除`);
      // 回上一级:有父文件夹则切到父;根夹顺延到剩余列表第一个。不能回项目页
      // 依赖自动选中 effect —— 它跑在 folders 旧缓存上,被删夹排序第一时会被
      // 重新选回且 staleTime 内无自愈(幽灵文件夹)
      const rest = (folders ?? []).filter(f => f.id !== folder.id);
      if (parentId) onFolderSelect(parentId);
      else if (rest.length > 0) onFolderSelect(rest[0].id);
      else {
        setActiveFolderId(null);
        navigate(`/projects/${projectId}`);
      }
    } catch (e) {
      message.error(errorMessage(e, '删除文件夹失败'));
    }
  };

  if (foldersLoading) return <Skeleton active />;

  // 项目没有任何可见 folder
  if (!folders || folders.length === 0) {
    return (
      <div>
        <AppBreadcrumb />
        <div style={{
          marginTop: 60, padding: '60px 40px', textAlign: 'center',
          background: 'var(--ms-surface)', border: '1px dashed var(--ms-hairline)',
          borderRadius: 'var(--ms-radius-lg)',
        }}>
          <FolderIcon size={36} strokeWidth={1.3}
                      style={{ color: 'var(--ms-hairline)', marginBottom: 18 }} />
          <div style={{
            fontFamily: 'var(--ms-font-display)', fontSize: 18, fontWeight: 500,
            color: 'var(--ms-ink)', marginBottom: 8,
          }}>本项目还没有文件夹</div>
          <p style={{ margin: 0, fontSize: 13, color: 'var(--ms-ink-muted)',
                      maxWidth: 320, marginInline: 'auto' }}>
            {canUploadProject
              ? '新建一个开始管理素材,或申请加入已有的 sensitive 目录。'
              : '该项目还没有文件夹;无上传权限,如需上传素材请联系项目管理员。'}
          </p>
          <Space style={{ marginTop: 24 }}>
            {canUploadProject && (
              <Button type="primary" icon={<FolderPlus size={14} strokeWidth={2} />}
                      onClick={() => setNewFolderMode('root')}>
                新建第一个文件夹
              </Button>
            )}
            <Button onClick={() => setApplySensitive(true)}
                    icon={<Key size={14} strokeWidth={2} />}>
              申请 sensitive 目录
            </Button>
          </Space>
        </div>
        {applySensitive && (
          <RequestAccessModal
            open onClose={() => setApplySensitive(false)}
            targetId="" targetName="(请输入 folder UUID)"
            targetType="sensitive_folder" defaultAction="access"
          />
        )}
        {newFolderMode && projectId && (
          <NewFolderModal
            open
            onClose={() => setNewFolderMode(null)}
            projectId={projectId}
            onCreated={(fid) => {
              setActiveFolderId(fid);
              navigate(`/projects/${projectId}/folders/${fid}`, { replace: true });
            }}
          />
        )}
      </div>
    );
  }

  // ─── 列定义 ─────────────────────────────────────────────────────────────
  const cols = [
    {
      title: '文件', dataIndex: 'filename', ellipsis: true,
      render: (v: string, a: Asset) => (
        <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          <AssetThumbnail asset={a} />
          <span style={{
            fontWeight: 500, color: 'var(--ms-ink)',
            overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
          }}>{v}</span>
          {a.content_type && (
            <span style={{
              fontFamily: 'var(--ms-font-mono)', fontSize: 10.5,
              color: 'var(--ms-ink-subtle)',
              padding: '1px 6px',
              background: 'var(--ms-hairline-soft)',
              borderRadius: 3,
              flexShrink: 0,
            }}>{a.content_type.split('/').pop()}</span>
          )}
        </div>
      ),
    },
    {
      title: '大小', dataIndex: 'size_bytes', width: 96,
      render: (n: number) => (
        <span className="ms-mono" style={{ color: 'var(--ms-ink-muted)', fontSize: 12.5 }}>
          {fmtBytes(n)}
        </span>
      ),
      sorter: (a: Asset, b: Asset) => a.size_bytes - b.size_bytes,
    },
    {
      // #151: 行内打标 — 点击 chips 展开编辑;命中即盲搜可达
      title: '标签', dataIndex: 'user_labels', width: 220,
      render: (_: unknown, a: Asset) => <AssetTagEditor asset={a} />,
      responsive: ['lg' as const],
    },
    {
      title: '创建', dataIndex: 'created_at', width: 160,
      render: (v: string) => (
        <span style={{ color: 'var(--ms-ink-muted)', fontSize: 12.5 }}>
          {new Date(v).toLocaleString('zh-CN', {
            month: '2-digit', day: '2-digit',
            hour: '2-digit', minute: '2-digit',
          })}
        </span>
      ),
      responsive: ['lg' as const],
      sorter: (a: Asset, b: Asset) => a.created_at.localeCompare(b.created_at),
    },
    {
      title: '', width: 56, fixed: 'right' as const,
      render: (_: unknown, a: Asset) => (
        <Tooltip title="下载">
          <Button type="text" size="small" icon={<Download size={14} strokeWidth={1.8} />}
                  loading={dlLink.isPending && dlLink.variables === a.id}
                  onClick={(e) => { e.stopPropagation(); handleDownload(a); }}
                  style={{ color: 'var(--ms-ink-muted)' }}
          />
        </Tooltip>
      ),
    },
  ];

  const hasSelection = selectedIds.length > 0;

  // ─── 共享 modal/抽屉群:PC / compact 两分支共用 ──────────────────────────
  // (均 portal 渲染,挂在哪个 return 里与最终 DOM 位置无关;抽出来避免两分支重复)
  const modals = (
    <>
      {applyAsset && (
        <RequestAccessModal
          open onClose={() => setApplyAsset(null)}
          targetId={applyAsset.id} targetName={applyAsset.filename}
          targetType="asset" defaultAction="download"
        />
      )}

      {newFolderMode && projectId && (
        <NewFolderModal
          open
          onClose={() => setNewFolderMode(null)}
          projectId={projectId}
          parentFolderId={newFolderMode === 'child' ? (activeFolderId ?? undefined) : undefined}
          parentName={newFolderMode === 'child' ? folder?.minio_prefix : undefined}
          parentIsSensitive={newFolderMode === 'child' ? folder?.is_sensitive : false}
          onCreated={(fid) => {
            setActiveFolderId(fid);
            navigate(`/projects/${projectId}/folders/${fid}`, { replace: true });
          }}
        />
      )}

      {project && me && (
        <ProjectMembersDrawer
          open={membersOpen}
          onClose={() => setMembersOpen(false)}
          project={project}
          me={me}
        />
      )}

      {/* #129: folder admin 的"申请链接"modal — 生成 folder 级请求链接 */}
      {folder && folder.my_can_admin && (
        <RequestLinkCreateModal
          open={linkOpen}
          onClose={() => setLinkOpen(false)}
          targetType={folder.is_sensitive ? 'sensitive_folder' : 'folder'}
          targetId={folder.id}
          targetName={folder.name}
        />
      )}

      {/* #151: 批量打标 modal(assets 仅当前页已加载选中项,明细展示用;
          提交按 selectedIds 全量逐 id PATCH + labels_mode=merge) */}
      <BulkTagModal
        open={bulkTagOpen}
        onClose={() => setBulkTagOpen(false)}
        assets={selectedAssets}
        selectedIds={selectedIds}
      />

      {/* PR-1: 批量前缀 modal(桌面 + compact 共用;全部成功清空选中,
          中途失败保留未提交的剩余选中供重试) */}
      <BatchPrefixModal
        open={batchPrefixOpen}
        onClose={() => setBatchPrefixOpen(false)}
        assets={selectedAssets}
        selectedIds={selectedIds}
        onSettle={(remaining) => {
          setBatchPrefixOpen(false);
          setSelectedIds(remaining);
        }}
      />

      {/* 回收站:本文件夹软删文件(恢复 / 彻底清除) */}
      {folder && (
        <FolderTrashModal
          folderId={folder.id}
          open={trashOpen}
          onClose={() => setTrashOpen(false)}
        />
      )}
    </>
  );

  // ─── compact(<1024):单栏工作区(方案 §3.1)─────────────────────────────
  // 放弃 PC 的 height:calc(100vh-…) 内滚,自然文档流滚动;外层无固定高/圆角/阴影。
  if (compact) {
    const detailAsset = detailIndex != null ? assetItems[detailIndex] : null;
    // 键盘弹起:Drawer 收缩为 visualViewport.height - 顶栏(56),打标输入框不被遮挡
    const drawerHeight = kbViewportHeight != null ? kbViewportHeight - 56 : 'min(72vh, 72dvh)';
    const toggleSelect = (id: string) =>
      setSelectedIds(prev => prev.includes(id) ? prev.filter(x => x !== id) : [...prev, id]);

    return (
      <div className="ms-enter">
        {/* folder header — 最左 = 树 Drawer 触发(hamburger + 当前夹名 + chevron-down) */}
        <div style={{ padding: '2px 0 10px', borderBottom: '1px solid var(--ms-hairline-soft)' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <Button type="text" onClick={() => setTreeOpen(true)} style={{
              flex: 1, minWidth: 0, height: 44, maxWidth: '100%',
              justifyContent: 'flex-start', padding: '0 8px', gap: 8,
            }}>
              <Menu size={18} strokeWidth={1.8} style={{ flexShrink: 0, color: 'var(--ms-ink-muted)' }} />
              <span style={{
                flex: 1, minWidth: 0, textAlign: 'left',
                overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
                fontFamily: 'var(--ms-font-display)', fontSize: 16, fontWeight: 500,
                color: 'var(--ms-ink)', letterSpacing: '-0.01em',
              }}>{folder?.name ?? '—'}</span>
              <ChevronDown size={16} strokeWidth={1.8}
                           style={{ flexShrink: 0, color: 'var(--ms-ink-subtle)' }} />
            </Button>
            {folder?.is_sensitive && (
              <span title="敏感目录" style={{
                display: 'inline-flex', alignItems: 'center', gap: 4,
                padding: '2px 8px', flexShrink: 0,
                background: 'var(--ms-accent-soft)',
                color: 'var(--ms-accent)',
                borderRadius: 3,
                fontSize: 10.5, fontWeight: 500, letterSpacing: '0.02em',
              }}>
                <Lock size={10} strokeWidth={2.2} />
                SENSITIVE
              </span>
            )}
            {folder && folder.my_can_admin && (
              <Button size="small" icon={<Settings size={13} strokeWidth={1.8} />}
                      onClick={() => setManageOpen(true)}>
                管理
              </Button>
            )}
          </div>
          {/* 第二行(wrap):权限 chips + folder 级操作(成员/申请链接/删除文件夹) */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap', marginTop: 6 }}>
            {folder && <MyFolderPerms folder={folder} />}
            {project && me && (
              <Button size="small" icon={<UsersIcon size={13} strokeWidth={1.8} />}
                      onClick={() => setMembersOpen(true)}>
                成员
              </Button>
            )}
            {folder && folder.my_can_admin && (
              <Tooltip title="生成申请链接,发给别人让他申请这个文件夹的临时下载权限">
                <Button size="small" icon={<Link2 size={13} strokeWidth={1.8} />}
                        onClick={() => setLinkOpen(true)}>
                  申请链接
                </Button>
              </Tooltip>
            )}
            {folder && (folder.is_sensitive ? folder.my_can_admin : folder.my_can_upload) && (
              <Popconfirm
                title={`删除文件夹「${folder.name}」?`}
                description={trashCount > 0
                  ? `回收站内还有 ${trashCount} 个已删除文件,请先清空回收站`
                  : '删除后不可恢复'}
                okText="删除" okButtonProps={{ danger: true }}
                onConfirm={handleDeleteFolder}
              >
                <Tooltip title={folderDeletable
                  ? '删除当前文件夹(不可恢复)'
                  : trashCount > 0
                    ? `请先清空回收站(还有 ${trashCount} 个已删除文件)`
                    : '先删除文件夹内所有文件'}>
                  <Button size="small" danger icon={<Trash2 size={13} strokeWidth={1.8} />}
                          disabled={!folderDeletable} loading={delFolder.isPending}>
                    删除文件夹
                  </Button>
                </Tooltip>
              </Popconfirm>
            )}
          </div>
          {folder?.minio_prefix && (
            <div style={{
              marginTop: 4,
              fontFamily: 'var(--ms-font-mono)',
              fontSize: 11,
              color: 'var(--ms-ink-subtle)',
              // 长路径窄屏不撑破 x 轴(单行省略);PC 分支保持换行原样
              overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
            }}>{folder.minio_prefix}</div>
          )}
        </div>

        {/* actions bar — 允许 wrap;批量打标/删除收进底部批量操作栏,批量下载不做(§3.1) */}
        <div style={{
          padding: '10px 0',
          borderBottom: '1px solid var(--ms-hairline-soft)',
          display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap',
        }}>
          {/* 全选只作用于当前页(服务端分页只加载本页):勾选 = 当前页 id 并入选中,
              取消 = 从选中剔除当前页 id(跨页保留的其它页 id 不受影响);
              checked/indeterminate 按「当前页 id 与 selectedIds 的交集数」派生 */}
          <Checkbox
            indeterminate={somePageSelected}
            checked={allPageSelected}
            onChange={(e) => setSelectedIds(prev => e.target.checked
              ? [...new Set([...prev, ...assetItems.map(a => a.id)])]
              : prev.filter(id => !pageIdSet.has(id)))}
          />
          <span style={{ fontSize: 12.5, color: 'var(--ms-ink-muted)' }}>
            {hasSelection ? (
              <>已选 <span className="ms-mono" style={{ color: 'var(--ms-accent)', fontWeight: 500 }}>
                {selectedIds.length}</span> / 本页 {assetItems.length}</>
            ) : (
              <>共 <span className="ms-mono">{assetTotal}</span> 个文件</>
            )}
          </span>
          <Space size={6} wrap>
            <Tooltip title={folder?.my_can_upload ? '' : '无上传权限 — 请联系项目管理员授 uploader 角色'}>
              <Button size="small" type="primary"
                      icon={<Upload size={13} strokeWidth={2} />}
                      disabled={!folder?.my_can_upload}
                      onClick={() => activeFolderId && upload.open(activeFolderId)}>上传</Button>
            </Tooltip>
            {/* 回收站:普通夹 folder admin;sensitive 夹仅系统 admin */}
            {canSeeTrash && (
              <Button size="small" icon={<Archive size={13} strokeWidth={2} />}
                      onClick={() => setTrashOpen(true)}>
                回收站{trashCount > 0 ? ` ${trashCount}` : ''}
              </Button>
            )}
            <Button size="small" icon={<RotateCw size={13} strokeWidth={2} />}
                    onClick={() => refetch()}>刷新</Button>
          </Space>
        </div>

        {/* 卡片列表 + 分页器(文档流普通块);勾选态追加批量栏高度 padding-bottom,
            防末端内容被 sticky 批量栏盖住 */}
        <div style={{ padding: '12px 0 0', paddingBottom: hasSelection ? 76 : 12 }}>
          <AssetCardList
            assets={assetItems}
            loading={assetsLoading || isFetching}
            emptyText={
              <div style={{ padding: '60px 16px', textAlign: 'center' }}>
                <FileText size={32} strokeWidth={1.3}
                          style={{ color: 'var(--ms-hairline)' }} />
                <div style={{
                  marginTop: 12, fontSize: 13, color: 'var(--ms-ink-muted)',
                }}>{folder?.my_can_upload ? '空文件夹 — 上传文件开始' : '空文件夹(无上传权限,如需上传请联系项目管理员)'}</div>
              </div>
            }
            selectable
            selectedIds={selectedIds}
            onToggle={toggleSelect}
            onOpen={setDetailIndex}
          />
          {assetTotal > ASSETS_PAGE_SIZE && (
            <div style={{
              padding: '4px 0 8px',
              display: 'flex', justifyContent: 'flex-end',
            }}>
              <Pagination
                size="small"
                current={page}
                pageSize={ASSETS_PAGE_SIZE}
                total={assetTotal}
                showSizeChanger={false}
                showTotal={(t) => `共 ${t} 个文件`}
                onChange={(p) => {
                  setPage(p);
                  // PR-1:跨页保留选中,翻页不再清空(切 folder 仍清空,见上方 prevFolder 逻辑)
                  setDetailIndex(null);
                  // compact 下 main 是滚动容器(window 不滚),回顶滚 main
                  scrollMainToTop();
                }}
              />
            </div>
          )}
        </div>

        {/* 批量操作栏(§3.1):sticky 钉在 main 滚动容器可视底(= TabBar 上沿);
            键盘弹起隐藏。不放「下载」— 移动端浏览器拦截连续多下载,下载走每卡行内按钮 */}
        {hasSelection && (
          <div style={{
            position: 'sticky',
            bottom: 0,
            zIndex: 'var(--ms-z-batchbar)',
            marginTop: 12,
            display: kbVisible ? 'none' : 'flex',
            alignItems: 'center', gap: 8,
            padding: '6px 8px 6px 14px',
            background: 'var(--ms-surface)',
            border: '1px solid var(--ms-hairline)',
            borderRadius: 'var(--ms-radius-lg)',
            boxShadow: 'var(--ms-shadow-md)',
          }}>
            <span style={{ fontSize: 13, color: 'var(--ms-ink-muted)', flexShrink: 0 }}>
              已选 <span className="ms-mono" style={{ color: 'var(--ms-accent)', fontWeight: 500 }}>
                {selectedIds.length}</span>
            </span>
            <div style={{ flex: 1 }} />
            <Button style={{ height: 44 }} icon={<Tags size={14} strokeWidth={2} />}
                    disabled={!folder?.my_can_upload} onClick={() => setBulkTagOpen(true)}>
              打标
            </Button>
            {/* PR-1: 批量前缀 — 门控随打标 = folder.my_can_upload */}
            <Button style={{ height: 44 }} icon={<Type size={14} strokeWidth={2} />}
                    disabled={!folder?.my_can_upload} onClick={() => setBatchPrefixOpen(true)}>
              前缀
            </Button>
            <Popconfirm
              title={`删除 ${selectedIds.length} 个文件?`}
              description="软删除;管理员可在回收站恢复或彻底清除"
              okText="删除" okButtonProps={{ danger: true }}
              disabled={!folder?.my_can_admin}
              onConfirm={confirmBulkDelete}
            >
              <Button danger style={{ height: 44 }} icon={<Trash2 size={14} strokeWidth={2} />}
                      disabled={!folder?.my_can_admin} loading={del.isPending}>
                删除
              </Button>
            </Popconfirm>
            <Button style={{ height: 44 }} onClick={() => setSelectedIds([])}>
              清空选择
            </Button>
          </div>
        )}

        {/* 左:FolderTree Drawer(替代 PC 左栏) */}
        <Drawer
          placement="left"
          open={treeOpen}
          onClose={() => setTreeOpen(false)}
          width="min(320px, 84vw)"
          title={project?.name}
          styles={{ body: { padding: 0, overflowY: 'auto' } }}
        >
          <FolderTree
            folders={folders}
            projectName={project?.name}
            activeFolderId={activeFolderId}
            onSelect={(fid) => { onFolderSelect(fid); setTreeOpen(false); }}
            onCreateRoot={canUploadProject ? () => setNewFolderMode('root') : undefined}
            onCreateChild={canUploadProject ? () => setNewFolderMode('child') : undefined}
            canUpload={canUploadProject}
          />
        </Drawer>

        {/* 单文件详情 bottom Drawer:内容 = AssetSummaryPanel 单选态原样复用;
            头部 ‹ n/N › 行内切换(批量过图选片)。预览 Modal 在 Drawer 内叠层:
            两者同 z 1000,靠 DOM 挂载序后者在上 — 不改 getContainer */}
        <Drawer
          placement="bottom"
          open={detailAsset != null}
          onClose={() => setDetailIndex(null)}
          height={drawerHeight}
          styles={{ body: { padding: 0, overflowY: 'auto' } }}
          title={
            <div style={{ display: 'flex', alignItems: 'center', gap: 4, minWidth: 0 }}>
              <Button type="text" size="small" aria-label="上一个"
                      icon={<ChevronLeft size={16} strokeWidth={1.8} />}
                      disabled={(detailIndex ?? 0) <= 0}
                      onClick={() => setDetailIndex(i => (i == null ? null : i - 1))} />
              <span className="ms-mono" style={{
                fontSize: 12.5, color: 'var(--ms-ink-muted)', flexShrink: 0,
              }}>{(detailIndex ?? 0) + 1} / {assetItems.length}</span>
              <Button type="text" size="small" aria-label="下一个"
                      icon={<ChevronRight size={16} strokeWidth={1.8} />}
                      disabled={(detailIndex ?? 0) >= assetItems.length - 1}
                      onClick={() => setDetailIndex(i => (i == null ? null : i + 1))} />
              <span style={{
                flex: 1, minWidth: 0, marginLeft: 6, fontSize: 13,
                color: 'var(--ms-ink-muted)',
                overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
              }}>{detailAsset?.filename}</span>
            </div>
          }
        >
          {detailAsset && (
            <AssetSummaryPanel selected={[detailAsset]} me={me} folder={folder} />
          )}
        </Drawer>

        {/* folder 级管理面板:AssetSummaryPanel 空选态原样复用
            (内部自动渲染 FolderInvitePanel / FolderGrantsPanel) */}
        <Drawer
          placement="bottom"
          open={manageOpen}
          onClose={() => setManageOpen(false)}
          height={drawerHeight}
          title="文件夹管理"
          styles={{ body: { padding: 0, overflowY: 'auto' } }}
        >
          {folder && me && <AssetSummaryPanel selected={[]} me={me} folder={folder} />}
        </Drawer>

        {modals}
      </div>
    );
  }

  // 桌面:三栏 layout
  return (
    <Layout className="ms-enter" style={{
      // #134: minHeight → height,父容器固高才能让三栏内部 overflow:auto 生效(滚动收敛到 Table 区,
      // 顶部 actions bar / 右侧 summary 不再随页面滚走)。56=header,32=main 顶 padding,80=main 底 padding。
      height: 'calc(100vh - 56px - 32px - 80px)',
      background: 'var(--ms-surface)',
      borderRadius: 'var(--ms-radius-lg)',
      overflow: 'hidden',
      boxShadow: 'var(--ms-shadow-sm)',
    }}>
      {/* 左:folder tree(compact 分支为左滑 Drawer) */}
      <Layout.Sider width={260} theme="light" style={{
        background: 'var(--ms-surface)',
        borderRight: '1px solid var(--ms-hairline)',
        overflow: 'auto',
      }}>
        <FolderTree
          folders={folders}
          projectName={project?.name}
          activeFolderId={activeFolderId}
          onSelect={onFolderSelect}
          onCreateRoot={canUploadProject ? () => setNewFolderMode('root') : undefined}
          onCreateChild={canUploadProject ? () => setNewFolderMode('child') : undefined}
          canUpload={canUploadProject}
        />
      </Layout.Sider>

      {/* 中:folder header + actions bar + asset table */}
      <Layout.Content style={{
        background: 'var(--ms-surface)',
        display: 'flex', flexDirection: 'column',
      }}>
        {/* folder header — sensitive 标记用 accent dot */}
        <div style={{
          padding: '16px 24px 12px',
          borderBottom: '1px solid var(--ms-hairline-soft)',
        }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            {folder?.is_sensitive && (
              <span title="敏感目录" style={{
                display: 'inline-flex', alignItems: 'center', gap: 4,
                padding: '2px 8px',
                background: 'var(--ms-accent-soft)',
                color: 'var(--ms-accent)',
                borderRadius: 3,
                fontSize: 10.5, fontWeight: 500, letterSpacing: '0.02em',
              }}>
                <Lock size={10} strokeWidth={2.2} />
                SENSITIVE
              </span>
            )}
            <span style={{
              fontFamily: 'var(--ms-font-display)',
              fontSize: 18, fontWeight: 500,
              color: 'var(--ms-ink)',
              letterSpacing: '-0.01em',
              flex: 1,
            }}>{folder?.name ?? '—'}</span>
            {folder && <MyFolderPerms folder={folder} />}
            {project && me && (
              <Button size="small" icon={<UsersIcon size={13} strokeWidth={1.8} />}
                      onClick={() => setMembersOpen(true)}>
                成员
              </Button>
            )}
            {/* #129: folder admin 才显 — folder 级临时 download 申请链接 */}
            {folder && folder.my_can_admin && (
              <Tooltip title="生成申请链接,发给别人让他申请这个文件夹的临时下载权限">
                <Button size="small" icon={<Link2 size={13} strokeWidth={1.8} />}
                        onClick={() => setLinkOpen(true)}>
                  申请链接
                </Button>
              </Tooltip>
            )}
            {/* 删除文件夹:须空夹 + 回收站已清空(硬删,不可恢复)。普通夹需
                can_upload(与创建对称);sensitive 夹需 can_admin —— 后端同规则 enforce */}
            {folder && (folder.is_sensitive ? folder.my_can_admin : folder.my_can_upload) && (
              <Popconfirm
                title={`删除文件夹「${folder.name}」?`}
                description={trashCount > 0
                  ? `回收站内还有 ${trashCount} 个已删除文件,请先清空回收站`
                  : '删除后不可恢复'}
                okText="删除" okButtonProps={{ danger: true }}
                onConfirm={handleDeleteFolder}
              >
                <Tooltip title={folderDeletable
                  ? '删除当前文件夹(不可恢复)'
                  : trashCount > 0
                    ? `请先清空回收站(还有 ${trashCount} 个已删除文件)`
                    : '先删除文件夹内所有文件'}>
                  <Button size="small" danger icon={<Trash2 size={13} strokeWidth={1.8} />}
                          disabled={!folderDeletable} loading={delFolder.isPending}>
                    删除文件夹
                  </Button>
                </Tooltip>
              </Popconfirm>
            )}
          </div>
          {folder?.minio_prefix && (
            <div style={{
              marginTop: 4,
              fontFamily: 'var(--ms-font-mono)',
              fontSize: 11,
              color: 'var(--ms-ink-subtle)',
            }}>{folder.minio_prefix}</div>
          )}
        </div>

        {/* actions bar */}
        <div style={{
          padding: '10px 24px',
          borderBottom: '1px solid var(--ms-hairline-soft)',
          display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap',
          background: 'var(--ms-canvas)',
        }}>
          {/* 全选只作用于当前页(服务端分页只加载本页):勾选 = 当前页 id 并入选中,
              取消 = 从选中剔除当前页 id(跨页保留的其它页 id 不受影响);
              checked/indeterminate 按「当前页 id 与 selectedIds 的交集数」派生 */}
          <Checkbox
            indeterminate={somePageSelected}
            checked={allPageSelected}
            onChange={(e) => setSelectedIds(prev => e.target.checked
              ? [...new Set([...prev, ...assetItems.map(a => a.id)])]
              : prev.filter(id => !pageIdSet.has(id)))}
          />
          <span style={{ fontSize: 12.5, color: 'var(--ms-ink-muted)' }}>
            {hasSelection ? (
              <>已选 <span className="ms-mono" style={{ color: 'var(--ms-accent)', fontWeight: 500 }}>
                {selectedIds.length}</span> / 本页 {assetItems.length}</>
            ) : (
              <>共 <span className="ms-mono">{assetTotal}</span> 个文件</>
            )}
          </span>
          <div style={{ flex: 1 }} />
          <Space size={6}>
            {/* 上传/打标需 folder can_upload(uploader),删除需 can_admin —— 后端
                对每个操作都强制;这里禁用按钮避免无权限用户选完文件才被 403 */}
            <Tooltip title={folder?.my_can_upload ? '' : '无上传权限 — 请联系项目管理员授 uploader 角色'}>
              <Button type="primary" size="small"
                      icon={<Upload size={13} strokeWidth={2} />}
                      disabled={!folder?.my_can_upload}
                      onClick={() => activeFolderId && upload.open(activeFolderId)}>上传</Button>
            </Tooltip>
            {/* #151: 批量打标 — 命中标签后可盲搜 */}
            <Tooltip title={!hasSelection ? '' : folder?.my_can_upload ? '' : '无编辑权限(需 uploader 角色)'}>
              <Button size="small" icon={<Tags size={13} strokeWidth={2} />}
                      disabled={!hasSelection || !folder?.my_can_upload} onClick={() => setBulkTagOpen(true)}>
                打标{hasSelection ? ` ${selectedIds.length}` : ''}
              </Button>
            </Tooltip>
            {/* PR-1: 批量前缀 — 门控随打标 = folder.my_can_upload */}
            <Tooltip title={!hasSelection ? '' : folder?.my_can_upload ? '' : '无编辑权限(需 uploader 角色)'}>
              <Button size="small" icon={<Type size={13} strokeWidth={2} />}
                      disabled={!hasSelection || !folder?.my_can_upload} onClick={() => setBatchPrefixOpen(true)}>
                前缀{hasSelection ? ` ${selectedIds.length}` : ''}
              </Button>
            </Tooltip>
            <Button size="small" icon={<RotateCw size={13} strokeWidth={2} />}
                    onClick={() => refetch()}>刷新</Button>
            <Button size="small" icon={<Download size={13} strokeWidth={2} />}
                    disabled={!hasSelection} onClick={confirmBulkDownload}>
              下载{hasSelection ? ` ${selectedIds.length}` : ''}
            </Button>
            {/* 回收站:普通夹 folder admin;sensitive 夹仅系统 admin(后端同规则 enforce) */}
            {canSeeTrash && (
              <Button size="small" icon={<Archive size={13} strokeWidth={2} />}
                      onClick={() => setTrashOpen(true)}>
                回收站{trashCount > 0 ? ` ${trashCount}` : ''}
              </Button>
            )}
            <Popconfirm
              title={`删除 ${selectedIds.length} 个文件?`}
              description="软删除;管理员可在回收站恢复或彻底清除"
              okText="删除" okButtonProps={{ danger: true }}
              disabled={!hasSelection || !folder?.my_can_admin}
              onConfirm={confirmBulkDelete}
            >
              <Tooltip title={!hasSelection ? '' : folder?.my_can_admin ? '' : '无删除权限(需管理员角色)'}>
                <Button size="small" danger icon={<Trash2 size={13} strokeWidth={2} />}
                        disabled={!hasSelection || !folder?.my_can_admin} loading={del.isPending}>
                  删除{hasSelection ? ` ${selectedIds.length}` : ''}
                </Button>
              </Tooltip>
            </Popconfirm>
          </Space>
        </div>

        {/* asset table — 表格区内滚,分页器钉在下方不随行滚动 */}
        <div ref={tableScrollRef} style={{ flex: 1, overflow: 'auto', padding: '0 8px' }}>
          <Table
            dataSource={assetItems}
            rowKey="id"
            loading={assetsLoading || isFetching}
            columns={cols}
            size="middle"
            scroll={{ x: 600 }}
            pagination={false}
            rowSelection={{
              selectedRowKeys: selectedIds,
              onChange: (keys) => setSelectedIds(keys as string[]),
              // PR-1:跨页保留选中 — 翻页后其它页的选中行 key 不丢(行不在当前页也不渲染);
              // 内置表头全选在 preserve 下天然只动当前页,勿改
              preserveSelectedRowKeys: true,
            }}
            onRow={(record) => ({
              onClick: () => {
                setSelectedIds(prev =>
                  prev.includes(record.id) ? prev.filter(x => x !== record.id) : [...prev, record.id]);
              },
              style: { cursor: 'pointer' },
            })}
            locale={{
              emptyText: (
                <div style={{ padding: '60px 16px' }}>
                  <FileText size={32} strokeWidth={1.3}
                            style={{ color: 'var(--ms-hairline)' }} />
                  <div style={{
                    marginTop: 12, fontSize: 13, color: 'var(--ms-ink-muted)',
                  }}>{folder?.my_can_upload ? '空文件夹 — 上传文件开始' : '空文件夹(无上传权限,如需上传请联系项目管理员)'}</div>
                </div>
              ),
            }}
          />
        </div>

        {/* 分页器钉底:翻页后表格自动回顶,不用来回拖滚动条 */}
        {assetTotal > ASSETS_PAGE_SIZE && (
          <div style={{
            flexShrink: 0,
            borderTop: '1px solid var(--ms-hairline-soft)',
            padding: '8px 16px',
            display: 'flex', justifyContent: 'flex-end',
            background: 'var(--ms-surface)',
          }}>
            <Pagination
              size="small"
              current={page}
              pageSize={ASSETS_PAGE_SIZE}
              total={assetTotal}
              showSizeChanger={false}
              showTotal={(t) => `共 ${t} 个文件`}
              onChange={(p) => {
                setPage(p);
                // PR-1:跨页保留选中,翻页不再清空(切 folder 仍清空,见上方 prevFolder 逻辑)
                tableScrollRef.current?.scrollTo({ top: 0 });
              }}
            />
          </div>
        )}
      </Layout.Content>

      {/* 右:summary(compact 分支 = 卡片 tap 打开的详情 Drawer) */}
      <Layout.Sider width={320} theme="light" style={{
        background: 'var(--ms-surface)',
        borderLeft: '1px solid var(--ms-hairline)',
        overflow: 'auto',
      }}>
        {/* PR-1:仅桌面多选批量态加注统计口径 — 批量统计只覆盖当前页已加载项
            (AssetSummaryPanel 三处复用,不能在组件内无条件加注,由页面侧注入) */}
        {selectedIds.length >= 2 && (
          <div style={{ padding: '12px 20px 0', fontSize: 12, color: 'var(--ms-ink-muted)' }}>
            统计为当前页已加载的 {selectedAssets.length} 项(共已选 {selectedIds.length} 个)
          </div>
        )}
        <AssetSummaryPanel selected={selectedAssets} me={me} folder={folder} />
      </Layout.Sider>

      {modals}
    </Layout>
  );
}

// ─── 批量打标(#151;PR-1 merge 化 + selectedIds 全量口径)────────────────────
function BulkTagModal({ open, onClose, assets, selectedIds }: {
  open: boolean; onClose: () => void;
  /** 当前页已加载的选中项(明细展示用;跨页保留选中后仅为全量选中的子集)。*/
  assets: Asset[];
  /** 全量选中 id(提交数据源;逐 id PATCH,无需加载行对象)。*/
  selectedIds: string[];
}) {
  const { message, modal } = App.useApp();
  const meta = useUpdateAssetMeta();
  // 表单态存在本组件(Modal 的父级),destroyOnHidden 重置不到这里 —
  // 关闭动画结束后 afterOpenChange 显式归零(与 BatchPrefixModal 同款)
  const [labels, setLabels] = useState<string[]>([]);
  const [submitting, setSubmitting] = useState(false);

  const totalCount = selectedIds.length;
  // 明细仅为当前页子集时明示口径,避免「列表 N 个、明细 M 个」的错位困惑
  const scopeNote = totalCount > assets.length ? '(明细为当前页已加载项)' : '';

  const apply = async () => {
    const next = [...new Set(labels.map(s => s.trim()).filter(Boolean))];
    if (next.length === 0) { message.warning('先输入至少一个标签'); return; }
    const run = async () => {
      setSubmitting(true);
      let ok = 0, fail = 0, unloadedFail = 0;
      for (const id of selectedIds) {
        const a = assets.find(x => x.id === id);
        try {
          // merge 后端化:与 DB 现值取并集,未加载 id 的旧标签不会被整条替换清掉
          await meta.mutateAsync({ asset_id: id, user_labels: next, labels_mode: 'merge' });
          ok++;
        } catch (e) {
          fail++;
          // 已加载项逐条报错;未加载项按 id 聚合计数
          if (a) message.error(`${a.filename}: ${errorMessage(e)}`);
          else unloadedFail++;
        }
      }
      setSubmitting(false);
      if (unloadedFail > 0) message.error(`${unloadedFail} 个未加载文件打标失败`);
      if (ok > 0) message.success(`已为 ${ok} 个文件打标${fail > 0 ? ` · 失败 ${fail}` : ''}`);
      onClose();
    };
    // 跨页放大后 >100 提示耗时,确认后再提交
    if (totalCount > 100) {
      modal.confirm({
        title: `即将为 ${totalCount} 个文件打标`,
        content: '数量较多,逐个提交需要一些时间,期间请保持页面打开。',
        okText: '继续打标',
        onOk: run,
      });
    } else {
      void run();
    }
  };

  return (
    <Modal
      title={`批量打标 — ${totalCount} 个文件`}
      open={open}
      onCancel={onClose}
      okText="打标"
      okButtonProps={{ disabled: labels.length === 0, loading: meta.isPending || submitting }}
      onOk={apply}
      destroyOnHidden
      afterOpenChange={(o) => {
        if (!o) setLabels([]);
      }}
    >
      <div style={{ fontSize: 12.5, color: 'var(--ms-ink-muted)', marginBottom: 10 }}>
        给选中的 {totalCount} 个文件统一加标签{scopeNote}。与已有标签合并(不清除旧标签)。
        输入后回车确认,支持多个。
      </div>
      <Select
        mode="tags"
        value={labels}
        onChange={setLabels}
        placeholder="例:棚拍 / 现场 / VIP / 修图…"
        style={{ width: '100%' }}
        tokenSeparators={[',', '，']}
        open
        autoFocus
      />
    </Modal>
  );
}

// ─── MyFolderPerms — folder header 上的"我的有效权限"chip ───────────────
function MyFolderPerms({ folder }: { folder: Folder }) {
  const perms = [
    folder.my_can_admin && { label: '管理', color: 'var(--ms-accent)', bg: 'var(--ms-accent-soft)' },
    folder.my_can_upload && { label: '上传', color: 'var(--ms-amber)', bg: '#FEF3E8' },
    folder.my_can_download && { label: '下载', color: 'var(--ms-emerald)', bg: 'var(--ms-emerald-soft)' },
    folder.my_can_view && !folder.my_can_download && !folder.my_can_upload
      && { label: '查看', color: 'var(--ms-ink-muted)', bg: 'var(--ms-hairline-soft)' },
  ].filter(Boolean) as { label: string; color: string; bg: string }[];

  if (perms.length === 0) return null;

  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', gap: 3,
      marginLeft: 8,
    }}>
      <span style={{
        fontSize: 10, letterSpacing: '0.04em', color: 'var(--ms-ink-subtle)',
        fontFamily: 'var(--ms-font-mono)', marginRight: 2,
      }}>我:</span>
      {perms.map(p => (
        <span key={p.label} style={{
          padding: '1px 6px',
          background: p.bg, color: p.color,
          borderRadius: 3,
          fontSize: 10.5, fontWeight: 500, letterSpacing: '0.02em',
        }}>{p.label}</span>
      ))}
    </span>
  );
}
