/**
 * 分享 Modal — iter3 最小版;#154:飞书 IM 推送下线(ADR-0007),纯链接分享。
 *
 * 提交后展示 landing_url(可复制)+ 有效期;接收人 / 留言 / IM 推送全部移除。
 * 移动端增强(方案 §3.4):compact 结果态 = 全宽大按钮;navigator.share 可用时优先
 * (拉起系统/微信转发面板);复制用 navigator.clipboard,非 HTTPS(内网 HTTP)落
 * execCommand('copy') 兜底。
 */
import { App, Button, Form, Input, Modal, Select, Space, Tag, Typography } from 'antd';
import { CopyOutlined, ShareAltOutlined } from '@ant-design/icons';
import { useEffect, useState } from 'react';
import { useShareAsset, useShareFolder } from '../api/hooks';
import { useCompactViewport } from '../lib/use-viewports';
import { errorMessage } from '../api/client';
import type { ShareCreateOut } from '../api/types';

interface Props {
  open: boolean;
  onClose: () => void;
  target: { kind: 'asset' | 'folder'; id: string; label: string };
}

const TTL_OPTIONS = [
  { label: '1 小时', value: 3600 },
  { label: '24 小时', value: 86400 },
  { label: '7 天', value: 7 * 86400 },
  { label: '30 天', value: 30 * 86400 },
];

// navigator.clipboard 仅安全上下文可用;失败(HTTP 内网)落 execCommand 兜底
async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    try {
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.setAttribute('readonly', '');
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      const ok = document.execCommand('copy');
      ta.remove();
      return ok;
    } catch {
      return false;
    }
  }
}

export function ShareModal({ open, onClose, target }: Props) {
  const [form] = Form.useForm();
  const { message } = App.useApp();
  // hooks 置顶(见 use-viewports 模块注释)
  const compact = useCompactViewport();
  const shareAsset = useShareAsset();
  const shareFolder = useShareFolder();
  const [result, setResult] = useState<ShareCreateOut | null>(null);

  const loading = shareAsset.isPending || shareFolder.isPending;
  const canNativeShare = typeof navigator.share === 'function';

  // 打开即重置结果态:有意的「open 翻转重置」,豁免 cascading 警告
  /* eslint-disable react-hooks/set-state-in-effect */
  useEffect(() => {
    if (open) {
      form.resetFields();
      setResult(null);
    }
  }, [open, form]);
  /* eslint-enable react-hooks/set-state-in-effect */

  const submit = async () => {
    try {
      const v = await form.validateFields();
      const body = {
        expires_in_seconds: v.ttl as number,
        requires_login: true,
      };
      const data = target.kind === 'asset'
        ? await shareAsset.mutateAsync({ asset_id: target.id, ...body })
        : await shareFolder.mutateAsync({ folder_id: target.id, ...body });
      setResult(data);
      message.success('分享链接已生成');
    } catch (e) {
      if ((e as { errorFields?: unknown }).errorFields) return;
      message.error(errorMessage(e, '分享失败'));
    }
  };

  const copyLink = async (url: string) => {
    const ok = await copyText(url);
    if (ok) message.success('链接已复制');
    else message.error('复制失败,请手动选择文本复制');
  };

  const nativeShare = async (r: ShareCreateOut) => {
    try {
      await navigator.share({
        title: `分享:${target.label}`,
        text: `【${target.label}】的分享链接(需登录访问)`,
        url: r.landing_url,
      });
    } catch {
      // 用户取消系统分享面板 — 静默
    }
  };

  return (
    <Modal
      title={`分享 ${target.kind === 'asset' ? '文件' : '文件夹'}`}
      open={open}
      onCancel={onClose}
      destroyOnClose
      footer={result ? (
        <Button onClick={onClose}>关闭</Button>
      ) : [
        <Button key="cancel" onClick={onClose}>取消</Button>,
        <Button key="ok" type="primary" loading={loading} onClick={submit}>
          生成分享链接
        </Button>,
      ]}
    >
      {result ? (
        compact ? (
          <Space direction="vertical" style={{ width: '100%' }} size="middle">
            <div>
              <Typography.Text type="secondary">分享链接(有效期至 {new Date(result.expires_at).toLocaleString('zh-CN')})</Typography.Text>
            </div>
            {canNativeShare && (
              <Button type="primary" size="large" block icon={<ShareAltOutlined />}
                      onClick={() => void nativeShare(result)}>
                分享链接
              </Button>
            )}
            <Button size="large" block icon={<CopyOutlined />}
                    onClick={() => void copyLink(result.landing_url)}>
              复制链接
            </Button>
            <div>
              <Tag color="blue">访问需登录</Tag>
              <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                收件人打开链接后用本地账号登录即可访问(未配置 OIDC 时同)
              </Typography.Text>
            </div>
          </Space>
        ) : (
          <Space direction="vertical" style={{ width: '100%' }} size="middle">
            <div>
              <Typography.Text type="secondary">分享链接(有效期至 {new Date(result.expires_at).toLocaleString('zh-CN')})</Typography.Text>
              <Input.Group compact>
                <Input value={result.landing_url} readOnly style={{ width: 'calc(100% - 88px)' }} />
                <Button icon={<CopyOutlined />} onClick={() => void copyLink(result.landing_url)}>复制</Button>
              </Input.Group>
            </div>
            <div>
              <Tag color="blue">访问需登录</Tag>
              <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                收件人打开链接后用本地账号登录即可访问(未配置 OIDC 时同)
              </Typography.Text>
            </div>
          </Space>
        )
      ) : (
        <Form form={form} layout="vertical" initialValues={{ ttl: 86400 }}>
          <Form.Item label="资源">
            <Typography.Text code>{target.label}</Typography.Text>
          </Form.Item>
          <Form.Item name="ttl" label="有效期" rules={[{ required: true }]}>
            <Select options={TTL_OPTIONS} />
          </Form.Item>
        </Form>
      )}
    </Modal>
  );
}
