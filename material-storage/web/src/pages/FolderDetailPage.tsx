/**
 * /folders/:id — 盲搜落点(方案 §3.2):AssetCardList(不带 checkbox)+
 * tap=open 单文件详情 bottom Drawer(‹ n/N › 切张,两端尺寸通用,不分分支)。
 * 盲搜跳转定位方案 B(§4.2):URL ?asset=<id> 深链 → locate_index 定位正确页码 →
 * 跳页 + 滚动 + 高亮 + 自动开详情 Drawer;一次性消费防重弹,刷新/分享可完整重放。
 */
import { App, Button, Drawer, Empty, Pagination, Skeleton, Space, Tag, Tooltip, Typography } from 'antd';
import { KeyOutlined, UploadOutlined } from '@ant-design/icons';
import { ChevronLeft, ChevronRight } from 'lucide-react';
import { useParams, useSearchParams } from 'react-router-dom';
import { useEffect, useRef, useState } from 'react';
import { ASSETS_PAGE_SIZE, UUID_RE, useAssets, useFolder, useLocateAsset, useMe } from '../api/hooks';
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
  const { message } = App.useApp();
  const compact = useCompactViewport();
  // 服务端分页:此前列表被后端默认 limit=100 静默截断,超出的旧文件看不见。
  // 切夹回第一页用 render 期比较旧值重置(不走 setState-in-effect)
  const [page, setPage] = useState(1);
  const [prevFolderId, setPrevFolderId] = useState(folderId);
  // 详情 Drawer state 存 index 不存 id(‹ n/N › 切张只换内容,Drawer 常驻)
  const [detailIndex, setDetailIndex] = useState<number | null>(null);
  // ── 盲搜跳转定位(方案 §4.2)。新 state/ref 全部置于组件顶部声明区:下方
  //    render 期消费分支会引用它们,声明靠后会踩 const 时间死区 ──
  // 定位页码 render 期比较基准(幂等跳页;防同值重复 setPage)
  const [prevTarget, setPrevTarget] = useState<number | null>(null);
  // 一次性消费标记:定位成功/失败各赋值一次,永不清空 —— 防 Drawer 重弹/提示
  // 重复的唯一闸(翻页/切夹清高亮时绝不动它,否则翻回目标页违背承诺再弹)
  const [consumedAsset, setConsumedAsset] = useState<string | null>(null);
  // 失败标记单列:toast 是跨组件副作用,严禁 render 期发(StrictMode 双弹 +
  // 「updating a component while rendering」),由下方 effect 发
  const [consumeOutcome, setConsumeOutcome] = useState<'failed' | null>(null);
  // 视觉高亮,独立于消费标记:翻页/切夹清 null(纯视觉态)
  const [highlightId, setHighlightId] = useState<string | null>(null);
  // 失败 toast 去重:StrictMode 双跑 effect 也只弹一次
  const notifiedFor = useRef<string | null>(null);
  // 滚动一次性标记:置位后任何 ['assets'] 前缀失效引发的 refetch(isFetching 翻转)
  // 都不再重滚 —— 否则用户此后在本页打标/上传都会被反复拖回目标卡片
  const scrolledFor = useRef<string | null>(null);
  // 盲搜跳转深链:?asset= 参数不主动清除(刷新可重放;防重复触发靠 consumedAsset)
  const [sp] = useSearchParams();
  const focusAssetId = sp.get('asset');

  if (prevFolderId !== folderId) {
    setPrevFolderId(folderId);
    setPage(1);
    setHighlightId(null);   // 高亮跟夹走(纯视觉态);consumedAsset 不清(§4.2)
  }
  const { data, isLoading, isFetching } = useAssets(folderId, page, ASSETS_PAGE_SIZE);
  const { data: locateData } = useLocateAsset(folderId, focusAssetId);
  const items = data?.items ?? [];
  const total = data?.total ?? 0;
  const kbViewportHeight = useKeyboardViewportHeight();
  const upload = useUpload();
  // 后端 /assets/uploads 对每个上传都强制 can_upload;这里按 folder 权限禁用按钮,
  // 避免无权限用户(select 完文件才被 403)白走流程
  const canUpload = folder?.my_can_upload === true;
  // 键盘弹起:Drawer 收缩为 visualViewport.height - 顶栏(56)
  const drawerHeight = kbViewportHeight != null ? kbViewportHeight - 56 : 'min(72vh, 72dvh)';
  const detailAsset = detailIndex != null ? items[detailIndex] : null;

  // ── render 期:定位结果到达 → 跳页;幂等(同值 no-op)。第二个条件:已消费后
  //    locate 缓存失效重取(index 漂移)不再把用户拉回目标页 ──
  const targetPage = locateData?.locate_index != null
    ? Math.floor(locateData.locate_index / ASSETS_PAGE_SIZE) + 1
    : null;
  if (targetPage !== prevTarget && consumedAsset !== focusAssetId) {
    setPrevTarget(targetPage);
    if (targetPage) setPage(targetPage);
  }

  // ── render 期:目标页数据到达后,在本页 items 里按 id 找,一次性消费。
  //    门禁用 !isFetching(比 !isLoading 严格):keepPreviousData 下跳页首取
  //    isPending+isFetching → isLoading 其实为 true,但同 key 的后台 refetch
  //    窗口只有 isFetching 能拦住 ──
  const hitIndex = items.findIndex(a => a.id === focusAssetId);
  if (focusAssetId && hitIndex >= 0 && consumedAsset !== focusAssetId && !isFetching) {
    setConsumedAsset(focusAssetId);   // 只消费一次,永不清空(防重弹的唯一闸)
    setHighlightId(focusAssetId);     // 视觉高亮,翻页/切夹时清 null
    setDetailIndex(hitIndex);         // Drawer 自动开(现有 open = detailAsset != null)
  }

  // ── render 期:定位失败兜底的完整守卫(三层口径,缺一层都有确定性反例)──
  // ① 格式非法:useLocateAsset enabled 拦下不发请求,locateData 恒 undefined,
  //    必须在这里显式判格式,否则永不提示;
  // ② 已返回但无法定位:locate_index 为 null 或键不存在(老后端忽略 locate 参数
  //    的混合部署窗口)—— 用「是不是 number」判而非 == null,区分「还没返回」;
  // ③ 之外(query 出错:网络/5xx)→ 静默停留当前页不判失败:非 401/403 全局
  //    queryCache.onError 已弹 toast,页面再补是重复;403 本就与现状一致。
  const locateFailed =
    focusAssetId != null && consumedAsset !== focusAssetId && (
      !UUID_RE.test(focusAssetId)
      || (locateData !== undefined
          && typeof locateData.locate_index !== 'number')
    );
  if (locateFailed) {
    // 与成功分支共用一次性标记(串可能是任意 URL 原文,安全性由滚动 effect 的
    // 格式门禁兜住)
    setConsumedAsset(focusAssetId);
    setConsumeOutcome('failed');
  }

  // 失败提示 effect:render 期调 message.info 会触发 React「updating a component
  // while rendering a different component」且 StrictMode 双调用 render 弹两次 ——
  // ref 去重保证只出一次。停留当前页,不开 Drawer。
  useEffect(() => {
    if (consumeOutcome !== 'failed' || !consumedAsset) return;
    if (notifiedFor.current === consumedAsset) return;
    notifiedFor.current = consumedAsset;
    message.info('目标文件可能已被删除或移动');
  }, [consumeOutcome, consumedAsset, message]);

  // 滚动 effect:纯 DOM 副作用(无 setState),必须在 DOM 提交后执行 —— render 期
  // setState 同遍 DOM 尚未提交,querySelector 看不到新卡片;跳页取数期间整列渲染
  // Skeleton,[data-asset-id] 根本不在 DOM。PC window 滚动与 compact main 滚动
  // 容器均天然适配(scrollIntoView)。
  useEffect(() => {
    if (!consumedAsset || isFetching || scrolledFor.current === consumedAsset) return;
    if (!UUID_RE.test(consumedAsset)) {
      // 失败路径的 consumedAsset 是未消毒的 URL 原文,含引号等字符直接拼选择器
      // 会 SyntaxError 打穿 ErrorBoundary
      scrolledFor.current = consumedAsset;
      return;
    }
    const el = document.querySelector(`[data-asset-id="${consumedAsset}"]`);
    if (!el) return;   // 骨架屏刚结束的极端时序:未置位,下轮重试
    el.scrollIntoView({ block: 'center', behavior: 'smooth' });
    scrolledFor.current = consumedAsset;
  }, [consumedAsset, isFetching]);

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
            highlightId={highlightId ?? undefined}
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
                setHighlightId(null);   // 翻页清纯视觉高亮;consumedAsset 不动(§4.2)
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
            <AssetSummaryPanel selected={[detailAsset]} me={me} folder={folder}
              // B 包:list/detailIndex 同源透传 → Drawer 标题与 modal 导航翻同一
              // state 天然同步;null 传 undefined 防导航条渲染
              list={items} listIndex={detailIndex ?? undefined}
              onListIndexChange={setDetailIndex} />
          )}
        </Drawer>

      </div>
  );
}
