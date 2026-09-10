/**
 * /folders/:id — 盲搜落点(方案 §3.2):AssetCardList(不带 checkbox)+
 * tap=open 单文件详情 bottom Drawer(‹ n/N › 切张,两端尺寸通用,不分分支)。
 */
import { Button, Drawer, Empty, Pagination, Skeleton, Space, Tag, Tooltip, Typography } from 'antd';
import { KeyOutlined, UploadOutlined } from '@ant-design/icons';
import { ChevronLeft, ChevronRight } from 'lucide-react';
import { useParams } from 'react-router-dom';
import { useState } from 'react';
import { ASSETS_PAGE_SIZE, useAssets, useFolder, useMe } from '../api/hooks';
import { AppBreadcrumb } from '../components/AppBreadcrumb';
import { AssetCardList } from '../components/AssetCardList';
import { AssetSummaryPanel } from '../components/AssetSummaryPanel';
import { useKeyboardViewportHeight } from '../lib/use-keyboard-visible';
import { useCompactViewport } from '../lib/use-viewports';
import { scrollMainToTop } from '../lib/main-scroll';
import { useUpload } from '../lib/upload-store';

export default function FolderDetailPage() {
  const { folderId } = useParams<{ folderId: string }>();
  const { data: folder } = useFolder(folderId);
  const { data: me } = useMe();
  const compact = useCompactViewport();
  // 服务端分页:此前列表被后端默认 limit=100 静默截断,超出的旧文件看不见。
  // 切夹回第一页用 render 期比较旧值重置(不走 setState-in-effect)
  const [page, setPage] = useState(1);
  const [prevFolderId, setPrevFolderId] = useState(folderId);
  if (prevFolderId !== folderId) {
    setPrevFolderId(folderId);
    setPage(1);
  }
  const { data, isLoading, isFetching } = useAssets(folderId, page, ASSETS_PAGE_SIZE);
  const items = data?.items ?? [];
  const total = data?.total ?? 0;
  // 详情 Drawer state 存 index 不存 id(‹ n/N › 切张只换内容,Drawer 常驻)
  const [detailIndex, setDetailIndex] = useState<number | null>(null);
  const kbViewportHeight = useKeyboardViewportHeight();
  const upload = useUpload();
  // 后端 /assets/uploads 对每个上传都强制 can_upload;这里按 folder 权限禁用按钮,
  // 避免无权限用户(select 完文件才被 403)白走流程
  const canUpload = folder?.my_can_upload === true;
  // 键盘弹起:Drawer 收缩为 visualViewport.height - 顶栏(56)
  const drawerHeight = kbViewportHeight != null ? kbViewportHeight - 56 : 'min(72vh, 72dvh)';
  const detailAsset = detailIndex != null ? items[detailIndex] : null;

  return (
    <div>
      <AppBreadcrumb />
      <Typography.Title level={4} style={{ marginTop: 0 }}>
        <Space>
          {folder?.name ?? <Skeleton.Input active size="small" />}
          {folder?.is_sensitive && <Tag color="volcano" icon={<KeyOutlined />}>sensitive</Tag>}
        </Space>
      </Typography.Title>
      {/* 长路径单行省略只在 compact 加(PC 保持换行原样,红线不动) */}
      <Typography.Paragraph type="secondary" code style={{
        fontSize: 12,
        ...(compact ? { overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' } : {}),
      }}>{folder?.minio_prefix}</Typography.Paragraph>

      <Space style={{ marginBottom: 12 }}>
        <Tooltip title={canUpload ? '' : '无上传权限 — 请联系项目管理员授 uploader 角色'}>
          <Button type="primary" icon={<UploadOutlined />} disabled={!canUpload}
                  onClick={() => folderId && upload.open(folderId)}>
            上传文件
          </Button>
        </Tooltip>
        {canUpload && (
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            后台上传:关掉抽屉/换页面不打断,右下浮窗可查进度
          </Typography.Text>
        )}
      </Space>

      {isLoading ? (
        <Skeleton active />
      ) : total === 0 ? (
        <Empty description={canUpload ? '空文件夹 — 点上传文件添加内容' : '空文件夹(无上传权限,如需上传请联系项目管理员)'} />
      ) : (
        <>
          <AssetCardList
            assets={items}
            loading={isFetching}
            onOpen={setDetailIndex}
          />
          {/* 分页器吸附滚动容器底:翻页后自动回顶,不用滚到底找页码;
              compact 下滚动容器是 main(钉底 = TabBar 上沿),PC 是 window,语义一致 */}
          <div style={{
            position: 'sticky',
            bottom: 0,
            marginTop: 16, padding: '8px 4px',
            display: 'flex', justifyContent: 'flex-end',
            background: 'var(--ms-canvas)',
            borderTop: '1px solid var(--ms-hairline-soft)',
          }}>
            <Pagination
              current={page}
              pageSize={ASSETS_PAGE_SIZE}
              total={total}
              onChange={(p) => {
                setPage(p);
                setDetailIndex(null);
                // compact 下 main 是滚动容器(window 不滚);PC 维持 window 回顶
                if (compact) scrollMainToTop();
                else window.scrollTo({ top: 0 });
              }}
              showSizeChanger={false}
              showTotal={(t) => `共 ${t} 个文件`}
            />
          </div>
        </>
      )}

      {/* 单文件详情 bottom Drawer:内容 = AssetSummaryPanel 单选态原样复用;
          预览 Modal 在 Drawer 内叠层(同 z 1000,靠 DOM 挂载序,不改 getContainer) */}
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
              }}>{(detailIndex ?? 0) + 1} / {items.length}</span>
              <Button type="text" size="small" aria-label="下一个"
                      icon={<ChevronRight size={16} strokeWidth={1.8} />}
                      disabled={(detailIndex ?? 0) >= items.length - 1}
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

      </div>
  );
}
