/**
 * 刷新默认权限弹层(PR-3,方案 §3.2):Transfer 选存量项目 → 批量调
 * POST /api/v1/admin/grant-templates/apply-default(逐项目合并默认模板授权)。
 * - 数据源 = GET /projects 循环分页拉全(默认 limit=100 会静默截断;归档项目天然不在列表);
 * - 勾选上限 100 = 接口单批上限,超限禁止再勾并提示分批;
 * - 叠加不删:只补缺失授权,不移除项目现有授权;
 * - 部分成功:结果按项目展示 {applied, skipped_stale, error},失败项不阻塞其余。
 */
import { Alert, App, Button, Modal, Result, Skeleton, Tag, Tooltip, Transfer } from 'antd';
import { useMemo, useState, type Key } from 'react';
import { useAllProjects, useApplyDefaultTemplate } from '../api/hooks';
import { errorMessage } from '../api/client';
import type { ApplyDefaultResult } from '../api/types';

const MAX_BATCH = 100;   // 接口单批上限(project_ids 1..100)

interface Props {
  open: boolean;
  onClose: () => void;
}

interface ProjectOption {
  key: string;
  title: string;        // 项目名
  code: string;         // 项目编码(搜索用)
  description: string;  // Transfer 条目副行
}

const sectionStyle = { width: 'calc(50% - 44px)', height: 420 };

export function ApplyDefaultModal({ open, onClose }: Props) {
  const { message, modal } = App.useApp();
  const apply = useApplyDefaultTemplate();
  const { data: projects, isLoading } = useAllProjects(open);
  const [targetKeys, setTargetKeys] = useState<string[]>([]);
  const [selectedKeys, setSelectedKeys] = useState<string[]>([]);
  const [result, setResult] = useState<ApplyDefaultResult | null>(null);

  // 关闭动画结束后复位,下次打开即初始态(不走 effect;首挂载本就是空态)
  const resetOnClosed = (o: boolean) => {
    if (!o) {
      setTargetKeys([]);
      setSelectedKeys([]);
      setResult(null);
    }
  };

  const nameById = useMemo(
    () => new Map((projects ?? []).map(p => [p.id, p.name])),
    [projects],
  );

  const dataSource: ProjectOption[] = useMemo(
    () => (projects ?? [])
      .filter(p => !p.is_archived)   // 归档项目不可刷新(API 预检也会 400,双保险)
      .map(p => ({ key: p.id, title: p.name, code: p.code, description: p.code })),
    [projects],
  );

  const atLimit = targetKeys.length >= MAX_BATCH;

  // 到达单批上限后禁用其余源侧项(禁止再勾,提示分批)
  const transferData = useMemo(
    () => dataSource.map(d => ({
      ...d,
      disabled: atLimit && !targetKeys.includes(d.key),
    })),
    [dataSource, atLimit, targetKeys],
  );

  const handleChange = (next: Key[], direction: 'left' | 'right') => {
    if (direction === 'right' && next.length > MAX_BATCH) {
      message.warning(`单批最多 ${MAX_BATCH} 个项目(接口上限),请分批刷新`);
      return;
    }
    setTargetKeys(next as string[]);
    setSelectedKeys([]);
  };

  const doApply = () => {
    if (targetKeys.length === 0) {
      message.warning('请先在左侧勾选要刷新的项目');
      return;
    }
    modal.confirm({
      title: `刷新 ${targetKeys.length} 个项目的默认权限?`,
      content: '将逐项目合并默认模板授权(叠加不删,不移除现有授权)。项目较多时耗时较长(满批可达数分钟),建议每批 20–30 个项目分次提交。',
      okText: '开始刷新',
      cancelText: '取消',
      onOk: async () => {
        try {
          const res = await apply.mutateAsync({ project_ids: targetKeys });
          setResult(res);
        } catch (e) {
          message.error(errorMessage(e, '刷新失败'));
        }
      },
    });
  };

  // 结果视图:按项目展示 {applied, skipped_stale} / error(部分成功语义)
  if (open && result) {
    const failed = result.results.filter(r => r.error);
    return (
      <Modal
        title="刷新默认权限 — 结果"
        open={open}
        onCancel={onClose}
        afterOpenChange={resetOnClosed}
        footer={<Button type="primary" onClick={onClose}>完成</Button>}
        width="min(560px, calc(100vw - 16px))"
        styles={{ body: { maxHeight: '70vh', overflowY: 'auto' } }}
      >
        <Alert
          type={failed.length > 0 ? 'warning' : 'success'}
          showIcon
          message={failed.length > 0
            ? `部分成功:${result.results.length - failed.length} 个项目已刷新,${failed.length} 个失败`
            : `刷新完成:共补写 ${result.total_applied} 条授权,跳过 ${result.total_skipped} 条过期条目`}
          description={failed.length > 0
            ? `成功项共补写 ${result.total_applied} 条授权、跳过 ${result.total_skipped} 条过期条目;失败项可稍后重试。`
            : undefined}
        />
        <div style={{
          marginTop: 12, display: 'flex', flexDirection: 'column', gap: 6,
          maxHeight: '46vh', overflowY: 'auto',
        }}>
          {result.results.map(r => {
            const name = nameById.get(r.project_id) ?? r.project_id.slice(0, 12) + '…';
            return (
              <div key={r.project_id} style={{
                display: 'flex', alignItems: 'center', gap: 8,
                padding: '6px 10px', background: 'var(--ms-canvas)',
                border: '1px solid var(--ms-hairline-soft)',
                borderRadius: 'var(--ms-radius-sm)', fontSize: 12,
              }}>
                <span style={{
                  flex: 1, minWidth: 0, overflow: 'hidden',
                  textOverflow: 'ellipsis', whiteSpace: 'nowrap',
                  color: 'var(--ms-ink)',
                }}>{name}</span>
                {r.error ? (
                  <Tooltip title={r.error}>
                    <span style={{
                      fontFamily: 'var(--ms-font-mono)', fontSize: 11,
                      color: 'var(--ms-crimson)',
                    }}>失败</span>
                  </Tooltip>
                ) : (
                  <>
                    <Tag style={{ margin: 0 }}>补写 {r.applied ?? 0}</Tag>
                    <Tag style={{ margin: 0 }}>跳过过期 {r.skipped_stale ?? 0}</Tag>
                  </>
                )}
              </div>
            );
          })}
        </div>
      </Modal>
    );
  }

  return (
    <Modal
      title="刷新默认权限"
      open={open}
      onCancel={onClose}
      afterOpenChange={resetOnClosed}
      destroyOnClose
      width="min(820px, calc(100vw - 16px))"
      confirmLoading={apply.isPending}
      onOk={doApply}
      okText="刷新"
      okButtonProps={{ disabled: targetKeys.length === 0 }}
      styles={{ body: { maxHeight: '70vh', overflowY: 'auto' } }}
    >
      <Alert
        type="info"
        showIcon
        style={{ marginBottom: 12 }}
        message="叠加不删:只补缺失的默认模板授权,不移除项目现有授权;单批最多 100 个项目(接口上限),满批可达数分钟,建议每批 20–30 个分次提交。"
      />
      {isLoading ? (
        <Skeleton active paragraph={{ rows: 6 }} />
      ) : dataSource.length === 0 ? (
        <Result
          status="info"
          title="暂无项目"
          subTitle="当前没有可刷新的项目(归档项目不支持)"
        />
      ) : (
        <Transfer
          dataSource={transferData}
          rowKey={r => r.key}
          targetKeys={targetKeys}
          selectedKeys={selectedKeys}
          onChange={handleChange}
          onSelectChange={(src, tgt) => setSelectedKeys([...src, ...tgt] as string[])}
          showSearch
          filterOption={(inputValue, item) => {
            const q = inputValue.trim().toLowerCase();
            if (!q) return true;
            return item.title.toLowerCase().includes(q)
              || item.code.toLowerCase().includes(q);
          }}
          render={item => `${item.title}(${item.code})`}
          titles={['全部项目', '待刷新']}
          locale={{ searchPlaceholder: '搜项目名 / 编码…' }}
          styles={{
            source: { section: sectionStyle },
            target: { section: sectionStyle },
          }}
        />
      )}
    </Modal>
  );
}
