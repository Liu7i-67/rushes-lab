import { App, Button, Empty, List, Pagination, Skeleton, Space, Tag, Tooltip, Typography } from 'antd';
import { CloudDownloadOutlined, KeyOutlined, UploadOutlined } from '@ant-design/icons';
import { useParams } from 'react-router-dom';
import { useState } from 'react';
import { ASSETS_PAGE_SIZE, useAssets, useDownloadLink, useFolder } from '../api/hooks';
import { AppBreadcrumb } from '../components/AppBreadcrumb';
import { RequestAccessModal } from '../components/RequestAccessModal';
import { useUpload } from '../lib/upload-store';
import { useDownloads } from '../lib/download-store';
import { errorMessage } from '../api/client';
import type { Asset } from '../api/types';

function fmtBytes(n: number) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(1)} MB`;
  return `${(n / 1024 ** 3).toFixed(2)} GB`;
}

export default function FolderDetailPage() {
  const { folderId } = useParams<{ folderId: string }>();
  const { data: folder } = useFolder(folderId);
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
  const dlLink = useDownloadLink();
  const { message } = App.useApp();
  const upload = useUpload();
  const downloads = useDownloads();
  const [applyAsset, setApplyAsset] = useState<Asset | null>(null);
  // 后端 /assets/uploads 对每个上传都强制 can_upload;这里按 folder 权限禁用按钮,
  // 避免无权限用户(select 完文件才被 403)白走流程
  const canUpload = folder?.my_can_upload === true;

  const handleDownload = async (a: Asset) => {
    try {
      const link = await dlLink.mutateAsync(a.id);
      // 走任务中心(fetch + progress + 可取消),右下浮按显示
      await downloads.start(link.url, a.filename);
    } catch (e: unknown) {
      const err = e as { response?: { status?: number } };
      if (err.response?.status === 403) {
        message.warning('无下载权限,自动打开申请...');
        setApplyAsset(a);
      } else {
        message.error(errorMessage(e, '下载失败'));
      }
    }
  };

  return (
    <div>
      <AppBreadcrumb />
      <Typography.Title level={4} style={{ marginTop: 0 }}>
        <Space>
          {folder?.name ?? <Skeleton.Input active size="small" />}
          {folder?.is_sensitive && <Tag color="volcano" icon={<KeyOutlined />}>sensitive</Tag>}
        </Space>
      </Typography.Title>
      <Typography.Paragraph type="secondary" code style={{ fontSize: 12 }}>{folder?.minio_prefix}</Typography.Paragraph>

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
          <List
            bordered
            loading={isFetching}
            dataSource={items}
            renderItem={(a) => (
              <List.Item
                actions={[
                  <Tooltip title="拿 presigned URL 直下" key="dl">
                    <Button type="link" icon={<CloudDownloadOutlined />}
                            loading={dlLink.isPending && dlLink.variables === a.id}
                            onClick={() => handleDownload(a)}>下载</Button>
                  </Tooltip>,
                ]}
              >
                <List.Item.Meta
                  title={a.filename}
                  description={
                    <Space size="middle" style={{ fontSize: 12, color: '#999' }}>
                      <span>{fmtBytes(a.size_bytes)}</span>
                      <span>{a.content_type ?? '—'}</span>
                      <span>{new Date(a.created_at).toLocaleString()}</span>
                    </Space>
                  }
                />
              </List.Item>
            )}
          />
          {/* 分页器吸附视口底部:翻页后自动回顶,不用滚到底找页码 */}
          <div style={{
            position: 'sticky', bottom: 0,
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
                window.scrollTo({ top: 0 });
              }}
              showSizeChanger={false}
              showTotal={(t) => `共 ${t} 个文件`}
            />
          </div>
        </>
      )}

      {applyAsset && (
        <RequestAccessModal
          open
          onClose={() => setApplyAsset(null)}
          targetId={applyAsset.id}
          targetName={applyAsset.filename}
          targetType="asset"
          defaultAction="download"
        />
      )}
    </div>
  );
}
