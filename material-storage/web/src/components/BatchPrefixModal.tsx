/**
 * 批量文件名前缀(PR-1)— 对选中文件统一加/去前缀。
 *
 * - action 单选(加前缀/去前缀)+ prefix 输入(前端校验:非空、不含 "/"、≤128)
 * - 预览:当前页已加载选中项取前 5 条算改名前后对照(服务端按 NFC 归一比较,
 *   NFD 存量名的实际命中以服务端结果为准,预览为近似)
 * - 提交按全量选中 id 分批(≤1000/批,后端单批上限)顺序调用;任一批失败即中止,
 *   toast 已完成批次计数,未提交的剩余 id 经 onSettle 回传父组件保留选中供重试
 *   (后端单事务,批次要么整批生效要么不执行,重试安全);
 *   全部成功后 onSettle([]) 由父组件清空选中(列表由 hook invalidate 刷新)
 */
import { App, Input, Modal, Radio, Typography } from 'antd';
import { useState } from 'react';
import { useBatchPrefix } from '../api/hooks';
import { errorMessage } from '../api/client';
import type { Asset, BatchPrefixAction } from '../api/types';

const BATCH_LIMIT = 1000;   // 后端单批 asset_ids 上限(超出 422)
const PREVIEW_COUNT = 5;    // 预览条数(当前页已加载选中项前 5 条)

/** skipped_reasons 键 → 中文(方案 §1.1:键固定 ASCII,前端映射)。*/
const SKIPPED_REASON_LABEL: Record<string, string> = {
  too_long: '加后超长',
  no_match: '前缀不匹配',
  already_prefixed: '已带该前缀',
  empty_result: '去后为空',
  deleted: '已删除/不存在',
  key_conflict: '新名存储位置被占',
  key_copy_failed: '存储端复制失败',
};

interface Props {
  open: boolean;
  onClose: () => void;
  /** 当前页已加载的选中项(预览数据源;跨页保留选中后仅为全量选中的子集)。*/
  assets: Asset[];
  /** 全量选中 id(提交数据源)。*/
  selectedIds: string[];
  /** 提交完结回调:全部成功 → [](父组件清空选中);中途失败 → 未提交的剩余 id(父组件保留供重试)。*/
  onSettle: (remainingIds: string[]) => void;
}

export function BatchPrefixModal({ open, onClose, assets, selectedIds, onSettle }: Props) {
  const { message } = App.useApp();
  const batchPrefix = useBatchPrefix();
  // 表单态存在本组件(Modal 的父级),destroyOnHidden 只销毁 Modal 内部子树、
  // 重置不到这里 — 关闭动画结束后 afterOpenChange 显式归零
  const [action, setAction] = useState<BatchPrefixAction>('add');
  const [prefix, setPrefix] = useState('');
  const [submitting, setSubmitting] = useState(false);

  const trimmed = prefix.trim();
  const prefixError: string | null =
    trimmed.length === 0 ? '前缀不能为空'
      : trimmed.includes('/') ? '前缀不能包含 "/"'
        : trimmed.length > 128 ? '前缀最长 128 个字符'
          : null;

  const totalCount = selectedIds.length;

  /** 预览行:当前页已加载选中项前 5 条的改名前后对照(after=null 表示预计跳过)。*/
  const previewItems = assets.slice(0, PREVIEW_COUNT).map(a => {
    const hit = a.filename.startsWith(trimmed);
    if (action === 'add') {
      return hit
        ? { id: a.id, before: a.filename, after: null as string | null, skip: '已带该前缀' }
        : { id: a.id, before: a.filename, after: trimmed + a.filename, skip: null };
    }
    if (!hit) {
      return { id: a.id, before: a.filename, after: null as string | null, skip: '前缀不匹配' };
    }
    const rest = a.filename.slice(trimmed.length);
    return rest.length === 0
      ? { id: a.id, before: a.filename, after: null as string | null, skip: '去后为空' }
      : { id: a.id, before: a.filename, after: rest, skip: null };
  });

  const submit = async () => {
    if (prefixError || totalCount === 0) return;
    // 去重兜底(选中源本身无重复,防御性)
    const ids = [...new Set(selectedIds)];
    // ≤1000/批分批,顺序调用
    const batches: string[][] = [];
    for (let i = 0; i < ids.length; i += BATCH_LIMIT) batches.push(ids.slice(i, i + BATCH_LIMIT));

    setSubmitting(true);
    let renamed = 0, skipped = 0;
    const reasons = new Map<string, number>();
    try {
      for (let bi = 0; bi < batches.length; bi++) {
        try {
          const r = await batchPrefix.mutateAsync({ asset_ids: batches[bi], action, prefix: trimmed });
          renamed += r.renamed;
          skipped += r.skipped;
          for (const [k, v] of Object.entries(r.skipped_reasons ?? {})) {
            if (v > 0) reasons.set(k, (reasons.get(k) ?? 0) + v);
          }
        } catch (e) {
          // 任一批失败即中止;失败批整批未执行,连同其后未提交批全部保留选中供重试
          const done = bi * BATCH_LIMIT;
          message.error(
            `第 ${bi + 1} 批提交失败,已中止 — 已完成批次:重命名 ${renamed} 个、跳过 ${skipped} 个;`
            + `剩余 ${ids.length - done} 个保留选中,可重试(${errorMessage(e, '提交失败')})`,
          );
          onSettle(ids.slice(done));
          return;
        }
      }
      const reasonText = [...reasons.entries()]
        .map(([k, v]) => `${SKIPPED_REASON_LABEL[k] ?? k} ${v}`)
        .join(' · ');
      message.success(`已重命名 ${renamed} 个,跳过 ${skipped} 个${reasonText ? `(${reasonText})` : ''}`);
      onSettle([]);
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal
      title={`批量前缀 — ${totalCount} 个文件`}
      open={open}
      onCancel={onClose}
      okText="执行改名"
      okButtonProps={{ disabled: !!prefixError || totalCount === 0, loading: submitting }}
      onOk={submit}
      destroyOnHidden
      afterOpenChange={(o) => {
        if (!o) { setAction('add'); setPrefix(''); }
      }}
    >
      <div style={{ fontSize: 12.5, color: 'var(--ms-ink-muted)', marginBottom: 12 }}>
        对选中的文件统一{action === 'add' ? '加' : '去'}文件名前缀。无批量撤销:
        加前缀可用「去前缀」恢复,误操作可按相同前缀反向执行。
      </div>

      <Radio.Group
        value={action}
        onChange={(e) => setAction(e.target.value as BatchPrefixAction)}
        style={{ marginBottom: 12 }}
      >
        <Radio.Button value="add">加前缀</Radio.Button>
        <Radio.Button value="remove">去前缀</Radio.Button>
      </Radio.Group>

      <Input
        value={prefix}
        onChange={(e) => setPrefix(e.target.value)}
        placeholder={action === 'add' ? '例:2026-09-(将加在文件名最前)' : '例:2026-09-(将从文件名最前剥离)'}
        status={prefixError ? 'error' : undefined}
        maxLength={160}
        allowClear
      />
      {prefixError && (
        <Typography.Text type="danger" style={{ fontSize: 12 }}>
          {prefixError}
        </Typography.Text>
      )}

      {/* 预览:当前页已加载选中项前 5 条(跨页选中时仅为子集,明示口径) */}
      <div style={{
        marginTop: 12, padding: '10px 12px',
        background: 'var(--ms-hairline-soft)',
        borderRadius: 'var(--ms-radius-sm)',
      }}>
        <div style={{ fontSize: 12, color: 'var(--ms-ink-muted)', marginBottom: 8 }}>
          改名预览(前 {PREVIEW_COUNT} 条)— 仅当前页,共已选 {totalCount} 个
        </div>
        {previewItems.map(p => (
          <div key={p.id} style={{
            display: 'flex', alignItems: 'baseline', gap: 8,
            fontSize: 12, padding: '3px 0', minWidth: 0,
          }}>
            <span className="ms-mono" style={{
              flexShrink: 0, color: 'var(--ms-ink-subtle)',
            }}>→</span>
            <span style={{
              minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
              color: 'var(--ms-ink-subtle)', flex: 1,
            }}>{p.before}</span>
            {p.after != null ? (
              <>
                <span className="ms-mono" style={{ flexShrink: 0, color: 'var(--ms-ink-subtle)' }}>→</span>
                <span style={{
                  minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
                  color: 'var(--ms-accent)', fontWeight: 500, flex: 1,
                }}>{p.after}</span>
              </>
            ) : (
              <span style={{ flexShrink: 0, fontSize: 11, color: 'var(--ms-amber)' }}>
                跳过:{p.skip}
              </span>
            )}
          </div>
        ))}
      </div>
    </Modal>
  );
}
