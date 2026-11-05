/**
 * /forgot-password — 忘记密码页(邮箱账号方案 §6.2)。
 *
 * 公开页(AppShell 无条件放行,同 /login):提交邮箱 → 后端发重置邮件
 * (链接 30 分钟有效、单次,token 只在 URL fragment)。
 * 结果分支:200 成功面板 / 400 后端文案(该邮箱未绑定)/ 429 冷却 + 按钮倒计时 /
 * 502 发送失败 / 503 功能未开启。60s 本地倒计时只管体验,服务端冷却兜底。
 * 注意:登录页是匿名用户唯一入口,本页所有失败都在页面内呈现,不跳全局报错。
 */
import { Alert, Button, Card, Form, Input, Typography } from 'antd';
import { Mail } from 'lucide-react';
import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { errorMessage, httpErrorStatus, retryAfterSeconds } from '../api/client';
import { useRequestPasswordReset } from '../api/hooks';
import { useCompactViewport } from '../lib/use-viewports';

/** 本地倒计时上限:429 无 Retry-After 或成功后的默认冷却(服务端 60s 兜底)。 */
const DEFAULT_COUNTDOWN = 60;
/** Retry-After 异常大值(如 IP 配额 3600)也照显,只封顶防 UI 溢出。 */
const MAX_COUNTDOWN = 24 * 60 * 60;

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export default function ForgotPasswordPage() {
  const compact = useCompactViewport();
  const request = useRequestPasswordReset();
  const [form] = Form.useForm<{ email: string }>();
  const [sentTo, setSentTo] = useState<string | null>(null);   // 200 → 成功面板
  const [failure, setFailure] = useState<{ type: 'error' | 'warning'; text: string } | null>(null);
  const [countdown, setCountdown] = useState(0);

  // 倒计时:每秒 -1 的链式 setTimeout(依赖 countdown 自身,卸载/归零自动停)
  useEffect(() => {
    if (countdown <= 0) return;
    const t = setTimeout(() => setCountdown((c) => c - 1), 1000);
    return () => clearTimeout(t);
  }, [countdown]);

  const submitEmail = async (email: string) => {
    setFailure(null);
    try {
      await request.mutateAsync({ email });
      // 200:成功面板 + 60s 本地倒计时(服务端仍有冷却兜底)
      setSentTo(email);
      setCountdown(DEFAULT_COUNTDOWN);
    } catch (err) {
      const status = httpErrorStatus(err);
      if (status === 400) {
        // 直接显示后端文案(「该邮箱未绑定任何账号」等;方案 D7 显式报错)
        setFailure({ type: 'warning', text: errorMessage(err, '申请失败') });
      } else if (status === 429) {
        const wait = Math.min(retryAfterSeconds(err) ?? DEFAULT_COUNTDOWN, MAX_COUNTDOWN);
        setCountdown(wait);
        setFailure({ type: 'warning', text: errorMessage(err, '操作过于频繁,请稍后再试') });
      } else if (status === 502) {
        setFailure({ type: 'error', text: '邮件发送失败,请稍后重试' });
      } else if (status === 503) {
        setFailure({ type: 'warning', text: '邮箱找回密码功能暂未开启,请联系管理员' });
      } else {
        setFailure({ type: 'error', text: errorMessage(err, '申请失败,请稍后重试') });
      }
    }
  };

  const onFinish = async (v: { email: string }) => {
    await submitEmail(v.email.trim());
  };

  const countdownLabel = countdown > 0 ? `(${countdown}s 后可重试)` : '';

  return (
    <div style={{ maxWidth: 520, margin: compact ? '24px auto' : '64px auto', padding: 16 }}>
      <Card>
        {/* 品牌印记(与 LoginPage 一致的几何方块) */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 8 }}>
          <span style={{ position: 'relative', display: 'inline-block', width: 22, height: 22 }}>
            <span style={{
              position: 'absolute', left: 0, top: 0,
              width: 14, height: 14, background: 'var(--ms-ink)', borderRadius: 2,
            }} />
            <span style={{
              position: 'absolute', left: 4, top: 4,
              width: 14, height: 14, background: 'var(--ms-accent)', borderRadius: 2, opacity: 0.85,
            }} />
            <span style={{
              position: 'absolute', left: 8, top: 8,
              width: 14, height: 14, background: 'var(--ms-emerald)', borderRadius: 2, opacity: 0.7,
            }} />
          </span>
          <span style={{
            fontFamily: 'var(--ms-font-display)', fontWeight: 500, fontSize: 16,
            letterSpacing: '-0.01em', color: 'var(--ms-ink)',
          }}>
            material<span style={{ color: 'var(--ms-accent)' }}>·</span>storage
          </span>
        </div>

        {sentTo === null ? (
          <>
            <Typography.Title level={4} style={{ marginTop: 8, marginBottom: 4 }}>
              找回密码
            </Typography.Title>
            <Typography.Paragraph type="secondary" style={{ marginTop: 0 }}>
              输入绑定的邮箱,我们会向该邮箱发送重置链接。
            </Typography.Paragraph>

            {failure && (
              <Alert type={failure.type} showIcon style={{ marginBottom: 20 }} message={failure.text} />
            )}

            <Form form={form} layout="vertical" onFinish={onFinish}
                  initialValues={{ email: '' }}>
              <Form.Item
                name="email"
                label="邮箱"
                rules={[
                  { required: true, whitespace: true, message: '请输入邮箱' },
                  { pattern: EMAIL_RE, message: '邮箱格式不正确' },
                ]}
              >
                <Input
                  type="email"
                  prefix={<Mail size={14} strokeWidth={1.8} />}
                  placeholder="name@example.com"
                  autoFocus
                  maxLength={254}
                />
              </Form.Item>
              <Form.Item style={{ marginBottom: 0 }}>
                <Button
                  type="primary"
                  htmlType="submit"
                  block
                  loading={request.isPending}
                  disabled={countdown > 0}
                >
                  发送重置链接{countdownLabel}
                </Button>
              </Form.Item>
            </Form>
          </>
        ) : (
          <>
            <Typography.Title level={4} style={{ marginTop: 8, marginBottom: 4 }}>
              请查收邮件
            </Typography.Title>
            <Alert
              type="success"
              showIcon
              style={{ marginBottom: 16 }}
              message={`重置链接已发送至 ${sentTo}`}
              description="链接 30 分钟内有效,仅可使用一次;请同时检查垃圾邮件。"
            />
            {failure && (
              <Alert type={failure.type} showIcon style={{ marginBottom: 16 }} message={failure.text} />
            )}
            <Button
              block
              loading={request.isPending}
              disabled={countdown > 0}
              onClick={() => { void submitEmail(sentTo); }}
            >
              重新发送{countdownLabel}
            </Button>
          </>
        )}
      </Card>
      <div style={{ textAlign: 'center', marginTop: 16, fontSize: 12, color: 'var(--ms-ink-subtle)' }}>
        <Link to="/login">返回登录</Link>
      </div>
    </div>
  );
}
