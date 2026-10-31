/**
 * 令牌创建成功弹窗 — 明文唯一一次展示(/settings)。
 *
 * D2:后端只在 POST 响应回显一次明文并带 `Cache-Control: no-store`;本弹窗
 * 关闭后上层立即丢弃 token 对象(不写 localStorage / 不进 react-query 缓存)。
 * 因此关闭方式收窄到页脚按钮:X / 遮罩 / Esc 全部禁用,避免误触后无法找回。
 */
import { Alert, App, Button, Modal } from 'antd';
import dayjs from 'dayjs';
import { Copy, KeyRound } from 'lucide-react';
import { copyToClipboard } from '../../utils/copy';
import type { PatTokenCreated } from '../../api/types';

export function TokenCreatedModal({ token, onClose }: {
  token: PatTokenCreated | null;
  onClose: () => void;
}) {
  const { message } = App.useApp();

  const copy = () => {
    if (!token) return;
    if (copyToClipboard(token.token)) message.success('令牌已复制');
    else message.error('复制失败,请手动选中复制');
  };

  return (
    <Modal
      title="令牌已创建"
      open={!!token}
      onCancel={onClose}
      closable={false}
      maskClosable={false}
      keyboard={false}
      footer={<Button type="primary" onClick={onClose}>我已保存,关闭</Button>}
    >
      <Alert
        type="warning"
        showIcon
        style={{ marginBottom: 16 }}
        message="这是令牌明文的唯一一次展示,关闭后无法再次查看"
        description="服务端只保存 SHA-256 哈希,无法找回。本响应带 Cache-Control: no-store,浏览器不会缓存。请立即复制并妥善保管。"
      />

      <div style={{
        display: 'flex', alignItems: 'center', gap: 8,
        padding: '12px 14px', background: 'var(--ms-canvas)',
        border: '1px solid var(--ms-hairline)', borderRadius: 'var(--ms-radius-sm)',
      }}>
        <KeyRound size={15} strokeWidth={1.8}
                  style={{ color: 'var(--ms-ink-muted)', flexShrink: 0 }} />
        <code style={{
          flex: 1, fontFamily: 'var(--ms-font-mono)', fontSize: 14,
          color: 'var(--ms-ink)', letterSpacing: '0.03em',
          overflowWrap: 'anywhere',
        }}>{token?.token}</code>
        <Button size="small" icon={<Copy size={12} strokeWidth={1.8} />} onClick={copy}>
          复制
        </Button>
      </div>

      <div style={{ marginTop: 12, fontSize: 12, color: 'var(--ms-ink-muted)', lineHeight: 1.9 }}>
        <div>名称:{token?.name}</div>
        <div>前缀:<span className="ms-mono">{token?.token_prefix}</span>(列表中以此识别)</div>
        <div>有效期至:{token ? dayjs(token.expires_at).format('YYYY-MM-DD HH:mm') : '—'}</div>
      </div>
    </Modal>
  );
}
