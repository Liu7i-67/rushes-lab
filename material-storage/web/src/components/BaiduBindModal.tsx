/**
 * BaiduBindModal — 百度网盘账号绑定/切换账号(方案 §3.2,步骤式)。
 * oob 复制码流程:生成授权链接 → 用户在可上网设备的浏览器打开并登录百度 →
 * 复制授权码回填 → 后端 code 换 token(Fernet 加密落库)。
 * 授权码单次有效约 10 分钟,失败需重新获取。
 */
import { App, Alert, Button, Input, Modal, Space, Steps, Typography } from 'antd';
import { Check, Copy, ExternalLink } from 'lucide-react';
import { useState } from 'react';
import { errorMessage } from '../api/client';
import { useBaiduAuthorizeUrl, useBaiduBind } from '../api/hooks';

interface Props {
  open: boolean;
  onClose: () => void;
}

export function BaiduBindModal({ open, onClose }: Props) {
  const { message } = App.useApp();
  const authorize = useBaiduAuthorizeUrl();
  const bind = useBaiduBind();
  const [step, setStep] = useState(0);
  const [url, setUrl] = useState('');
  const [code, setCode] = useState('');
  const [copied, setCopied] = useState(false);

  // destroyOnHidden:关闭即卸载,重开自然回到初始步骤,无需 effect 重置

  const genUrl = async () => {
    try {
      const d = await authorize.mutateAsync();
      setUrl(d.url);
      setStep(1);
    } catch (e) {
      message.error(errorMessage(e, '生成授权链接失败'));
    }
  };

  const copyUrl = async () => {
    try {
      await navigator.clipboard.writeText(url);
      setCopied(true);
      message.success('授权链接已复制');
      setTimeout(() => setCopied(false), 1500);
    } catch {
      message.error('复制失败,请手动选择链接复制');
    }
  };

  const submit = async () => {
    const trimmed = code.trim();
    if (!trimmed) {
      message.warning('请先粘贴授权码');
      return;
    }
    try {
      await bind.mutateAsync(trimmed);
      message.success('百度网盘账号已绑定');
      onClose();
    } catch (e) {
      message.error(`${errorMessage(e, '绑定失败')}(授权码单次有效约 10 分钟,请重新获取)`);
    }
  };

  return (
    <Modal
      title="绑定百度网盘账号"
      open={open}
      onCancel={onClose}
      destroyOnHidden
      maskClosable={false}
      footer={step === 0 ? (
        <Button type="primary" loading={authorize.isPending} onClick={genUrl}>
          生成授权链接
        </Button>
      ) : (
        <Space>
          <Button onClick={() => setStep(0)}>上一步</Button>
          <Button type="primary" loading={bind.isPending} disabled={!code.trim()}
                  onClick={submit}>
            绑定
          </Button>
        </Space>
      )}
    >
      <Steps
        size="small"
        current={step}
        items={[{ title: '获取授权链接' }, { title: '粘贴授权码' }]}
        style={{ marginTop: 16, marginBottom: 20 }}
      />
      {step === 0 ? (
        <Typography.Paragraph type="secondary" style={{ fontSize: 13 }}>
          点击上方按钮生成百度 OAuth 授权链接,用于确认<b>本人</b>百度账号身份。
        </Typography.Paragraph>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
          <div>
            <FieldLabel>第 1 步 · 复制授权链接</FieldLabel>
            <Space.Compact style={{ width: '100%' }}>
              <Input readOnly value={url} size="small" style={{ fontFamily: 'var(--ms-font-mono)', fontSize: 11 }}
                     placeholder="" />
              <Button icon={copied ? <Check size={13} /> : <Copy size={13} />}
                      onClick={copyUrl}>
                {copied ? '已复制' : '复制'}
              </Button>
            </Space.Compact>
            <Typography.Paragraph type="secondary" style={{ fontSize: 12, marginTop: 8, marginBottom: 0 }}>
              <ExternalLink size={11} strokeWidth={2} style={{ verticalAlign: -1 }} />{' '}
              在手机或可上网电脑的浏览器中打开该链接,登录<b>本人</b>百度账号并同意授权,
              授权完成后页面会显示一串授权码。
            </Typography.Paragraph>
          </div>
          <div>
            <FieldLabel>第 2 步 · 粘贴授权码</FieldLabel>
            <Input
              value={code}
              onChange={(e) => setCode(e.target.value)}
              placeholder="粘贴百度返回的授权码"
              onPressEnter={submit}
              allowClear
            />
          </div>
          <Alert
            type="warning"
            showIcon
            message="仅粘贴本人百度账号的授权码"
            description="授权码等同于账号授权凭证,误贴他人授权码会把对方账号绑定到你的系统账号;授权码单次有效约 10 分钟,过期请回上一步重新生成链接。"
            style={{ fontSize: 12 }}
          />
        </div>
      )}
    </Modal>
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
