/**
 * BatchMoveAssetsModal — 文件批量移动(W6 一期:项目内,六项优化 2026-10-17)。
 * POST /api/v1/assets/batch-move body {asset_ids, target_folder_id}。
 * 项目 Select 默认当前项目且禁切换(一期仅项目内,禁用态明示「跨项目移动即将支持」);
 * 目标目录复用 FolderTree selectMode(sensitive 及其子树禁选;target_folder_id 必填,
 * 无「项目根」伪节点 —— 与 W4/W5 的 MoveFolderModal 口径不同)。
 * 提交后结果弹窗展示 moved / skipped(逐条 reason 中文)/ fga_pending(权限同步延迟)。
 */
import { Alert, App, Button, Modal, Select, Typography } from 'antd';
import { useMemo, useState } from 'react';
import { useBatchMoveAssets } from '../api/hooks';
import { errorMessage } from '../api/client';
import type { Asset, AssetBatchMoveResult, Folder } from '../api/types';
import { FolderTree } from './FolderTree';

interface Props {
  open: boolean;
  /** 未提交取消(保留选中,可重新打开) */
  onClose: () => void;
  /** 提交成功后关闭(清空已移动/跳过的选中) */
  onMoved: () => void;
  projectId: string;
  projectName?: string;
  /** 项目全量可见 folder(目标树数据源) */
  folders: Folder[];
  /** 当前页已加载的选中项(skipped 明细回显文件名;跨页保留选中时为全量子集) */
  assets: Asset[];
  /** 全量选中 id(提交数据源,≤1000) */
  selectedIds: string[];
}

/** skipped reason → 中文(键固定 ASCII;未知键回落 raw token,tlabel 同款兜底)。*/
const SKIP_REASON_LABEL: Record<string, string> = {
  duplicate_location: '已在目标位置',
  duplicate_filename: '目标已有同名文件',
};

/** 单批上限(与后端 asset_ids ≤1000 对齐;超出禁提交)。*/
const BATCH_MOVE_LIMIT = 1000;

export function BatchMoveAssetsModal({
  open, onClose, onMoved, projectId, projectName, folders, assets, selectedIds,
}: Props) {
  const move = useBatchMoveAssets();
  const { message } = App.useApp();
  const [target, setTarget] = useState<{ id: string; name: string } | null>(null);
  // 非 null = 已提交,切结果视图;组件由调用方条件挂载,重开自动复位
  const [result, setResult] = useState<AssetBatchMoveResult | null>(null);

  const sensitiveIds = useMemo(
    () => folders.filter(f => f.is_sensitive).map(f => f.id),
    [folders],
  );
  const overLimit = selectedIds.length > BATCH_MOVE_LIMIT;
  // skipped 明细回显文件名:已加载项用 filename,未加载(跨页保留)用短 id 占位
  const nameById = useMemo(() => new Map(assets.map(a => [a.id, a.filename])), [assets]);

  const submit = async () => {
    if (!target) {
      message.warning('请先选择目标目录');
      return;
    }
    try {
      const r = await move.mutateAsync({
        asset_ids: selectedIds,
        target_folder_id: target.id,
      });
      setResult(r);
    } catch (e) {
      message.error(errorMessage(e, '批量移动失败'));
    }
  };

  const close = () => (result ? onMoved() : onClose());

  return (
    <Modal
      title={result ? '批量移动结果' : `移动 ${selectedIds.length} 个文件`}
      open={open}
      onCancel={close}
      // 仅结果视图覆盖 footer(「完成」走 onMoved 清选中);选择视图用默认 footer
      // (取消 = onClose 保留选中,确定 = onOk 提交)
      footer={result
        ? <Button type="primary" onClick={close}>完成</Button>
        : undefined}
      okText="移动"
      okButtonProps={{ disabled: !target || overLimit, loading: move.isPending }}
      onOk={submit}
      destroyOnHidden
      maskClosable={false}
      width="min(560px, 100vw)"
    >
      {result ? (
        <BatchMoveResultView result={result} submitted={selectedIds.length} nameById={nameById} />
      ) : (
        <>
          <div style={{ marginBottom: 12 }}>
            <FieldLabel>目标项目</FieldLabel>
            <Select
              style={{ width: '100%' }}
              value={projectId}
              disabled
              options={[{ value: projectId, label: projectName ?? projectId }]}
            />
            <Typography.Text type="secondary" style={{ fontSize: 11.5, display: 'block', marginTop: 4 }}>
              一期仅支持项目内移动;跨项目移动即将支持。
            </Typography.Text>
          </div>
          <FieldLabel>移动到哪个目录(敏感目录及其子目录不可选)</FieldLabel>
          <div style={{
            border: '1px solid var(--ms-hairline)',
            borderRadius: 'var(--ms-radius-sm)',
            maxHeight: 320, overflow: 'auto',
          }}>
            <FolderTree
              folders={folders}
              projectName={projectName}
              selectMode
              disabledIds={sensitiveIds}
              activeFolderId={target?.id ?? null}
              onSelect={(fid) => {
                const f = folders.find(x => x.id === fid);
                if (f) setTarget({ id: f.id, name: f.name });
              }}
            />
          </div>
          <div style={{ fontSize: 11.5, color: 'var(--ms-ink-muted)', marginTop: 8 }}>
            已选目标:{target ? `目录「${target.name}」` : '未选择(点选左侧目录)'}
            {overLimit && (
              <span style={{ color: 'var(--ms-amber)', marginLeft: 8 }}>
                单次最多移动 {BATCH_MOVE_LIMIT} 个文件,请减少选中后重试
              </span>
            )}
          </div>
        </>
      )}
    </Modal>
  );
}

// ─── 结果视图(对账恒等式:moved + skipped + fga_pending = 提交数)──────────────
function BatchMoveResultView({ result, submitted, nameById }: {
  result: AssetBatchMoveResult;
  submitted: number;
  nameById: Map<string, string>;
}) {
  const skippedCount = result.skipped.length;
  const pendingCount = result.fga_pending.length;
  const shortId = (id: string) => `asset_${id.slice(0, 8)}`;
  return (
    <div>
      <Alert
        type={pendingCount > 0 ? 'warning' : 'success'}
        showIcon
        message={`成功移动 ${result.moved_count} 个文件(共提交 ${submitted} 个)`}
        description={`对账:成功 ${result.moved_count} + 跳过 ${skippedCount}${pendingCount > 0 ? ` + 待同步 ${pendingCount}` : ''} = ${submitted}`}
      />
      {skippedCount > 0 && (
        <div style={{ marginTop: 12 }}>
          <FieldLabel>跳过 {skippedCount} 个(未改动)</FieldLabel>
          <ul style={{
            margin: 0, paddingLeft: 18, maxHeight: 180, overflow: 'auto',
            fontSize: 12.5, color: 'var(--ms-ink-muted)', lineHeight: 1.9,
          }}>
            {result.skipped.map(s => (
              <li key={s.asset_id}>
                <span style={{ color: 'var(--ms-ink)' }}>
                  {nameById.get(s.asset_id) ?? shortId(s.asset_id)}
                </span>
                {' — '}
                {SKIP_REASON_LABEL[s.reason] ?? s.reason}
              </li>
            ))}
          </ul>
        </div>
      )}
      {pendingCount > 0 && (
        <div style={{ marginTop: 12 }}>
          <FieldLabel>权限同步待完成 {pendingCount} 个</FieldLabel>
          <Typography.Text type="secondary" style={{ fontSize: 12, display: 'block' }}>
            以下文件已移动到目标目录,但访问权限同步暂时失败,系统将自动重试修复;
            若长时间未生效请联系管理员。
          </Typography.Text>
          <div className="ms-mono" style={{
            marginTop: 4, fontSize: 11.5, color: 'var(--ms-ink-subtle)',
            maxHeight: 120, overflow: 'auto', wordBreak: 'break-all',
          }}>
            {result.fga_pending.map(shortId).join('、')}
          </div>
        </div>
      )}
    </div>
  );
}

function FieldLabel({ children }: { children: React.ReactNode }) {
  return (
    <div style={{
      fontSize: 11, color: 'var(--ms-ink-muted)',
      marginBottom: 6, fontWeight: 500,
    }}>{children}</div>
  );
}
