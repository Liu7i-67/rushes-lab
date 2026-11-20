/**
 * 忘记密码页(2026-11-20 方案 §6.2;短信找回 = 验证码通过后系统重置随机密码,
 * 一次性展示账号 + 新密码,首登强制再改 D2)。
 *
 * 单页三态(卡片布局与 LoginPage 同款):
 * ① 输手机号 → 「获取验证码」(400「无法发送验证码」原样透出,不解释原因);
 * ② 输验证码 → 「重置密码」+「换一个手机号」链接回态 ①;
 * ③ 结果态 → 账号(username → email → name)+ 新密码 copyable +「去登录」。
 * 倒计时统一规则:有 retry_after 就以之为初值启动;无则不启动(方案 §5.2 分型)。
 */
import { App, Button, Card, Form, Input, Result, Typography } from 'antd';
import { useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { errorMessage, retryAfterOf } from '../api/client';
import { useResetConfirm, useResetSendCode } from '../api/hooks';
import { BrandMark } from '../components/BrandMark';
import { SendCodeButton } from '../components/SendCodeButton';
import type { SendCodeButtonHandle } from '../components/SendCodeButton';
import { isValidPhone, normalizePhone } from '../lib/phone';
import { useCompactViewport } from '../lib/use-viewports';

/** 结果态钉死文案(方案 §5.2:username/email 皆空仅 name 时附此提示)。*/
const ONLY_NAME_HINT = '若显示名重复导致无法登录,请联系管理员';

type Phase = 'phone' | 'code' | 'done';

interface ResetResult {
  username: string | null;
  email: string | null;
  name: string;
  new_password: string;
}

export default function ForgotPasswordPage() {
  const navigate = useNavigate();
  const { message } = App.useApp();
  const compact = useCompactViewport();

  const [phase, setPhase] = useState<Phase>('phone');
  const [phone, setPhone] = useState('');          // 态 ② / ③ 展示用(已归一化)
  const [result, setResult] = useState<ResetResult | null>(null);
  // 发码成功的冷却种子:回态 ① 时按剩余秒数恢复倒计时(后端冷却键仍存活)
  const [cdSeed, setCdSeed] = useState<{ at: number; total: number } | null>(null);

  const sendCode = useResetSendCode();
  const confirm = useResetConfirm();
  const [form] = Form.useForm();
  const sendBtnRef = useRef<SendCodeButtonHandle>(null);

  // 回到态 ①(换一个手机号)时恢复倒计时:成功 / 429·502 拿到的 retry_after
  // 均记入 cdSeed,剩余 >1s 才续,烧完自然放行(真实解锁以后端冷却 / 配额为准)
  useEffect(() => {
    if (phase !== 'phone' || !cdSeed) return;
    const left = cdSeed.total - (Date.now() - cdSeed.at) / 1000;
    if (left >= 1) sendBtnRef.current?.start(Math.ceil(left));
  }, [phase, cdSeed]);

  // 态 ①:发验证码(表单提交;前端先归一化再校验,后端为最终裁判)
  const onSendCode = async (v: { phone: string }) => {
    const p = normalizePhone(v.phone ?? '');
    if (!isValidPhone(p)) {
      message.error('手机号格式不正确');
      return;
    }
    try {
      const res = await sendCode.mutateAsync({ phone: p });
      setPhone(p);
      form.resetFields(['code']); // 清掉可能残留的旧验证码输入
      setPhase('code');
      // 统一规则:有 retry_after 才启动(send-code 200 契约恒带,守约式防御)
      if (res.retry_after > 0) setCdSeed({ at: Date.now(), total: res.retry_after });
    } catch (err) {
      // 失败文案统一原样透出后端 detail(400「无法发送验证码」不解释原因)
      message.error(errorMessage(err, '发送失败,请稍后重试'));
      const ra = retryAfterOf(err); // 429 冷却/配额、502(非 BUSINESS_LIMIT_CONTROL)带 → 启动
      if (ra > 0) setCdSeed({ at: Date.now(), total: ra });
    }
  };

  // 态 ②:确认重置(confirm 不做前端归一化拦截,后端统一 strip/upper 处理)
  const onConfirm = async (v: { code: string }) => {
    try {
      const res = await confirm.mutateAsync({ phone, code: (v.code ?? '').trim() });
      setResult(res);
      setPhase('done');
    } catch (err) {
      message.error(errorMessage(err, '重置失败'));
    }
  };

  // 结果态账号显示优先级:username → email → name
  const account = result
    ? (result.username?.trim() || result.email?.trim() || result.name)
    : '';
  const onlyName = !!result && !result.username?.trim() && !result.email?.trim();

  return (
    <div style={{ maxWidth: 520, margin: compact ? '24px auto' : '64px auto', padding: 16 }}>
      <Card>
        {/* 品牌印记(照 LoginPage,忘记密码与登录同一视觉壳) */}
        <BrandMark />

        {phase === 'phone' && (
          <>
            <Typography.Title level={4} style={{ marginTop: 8, marginBottom: 4 }}>
              找回密码
            </Typography.Title>
            <Typography.Paragraph type="secondary" style={{ marginTop: 0 }}>
              请输入绑定的手机号,我们将发送短信验证码帮你重置密码。
            </Typography.Paragraph>
            <Form form={form} layout="vertical" onFinish={onSendCode}
                  initialValues={{ phone }}>
              <Form.Item
                name="phone"
                label="手机号"
                rules={[
                  { required: true, message: '请输入绑定的手机号' },
                  {
                    validator: (_rule, value: string | undefined) =>
                      isValidPhone(normalizePhone(value ?? ''))
                        ? Promise.resolve()
                        : Promise.reject(new Error('手机号格式不正确')),
                  },
                ]}
              >
                <Input placeholder="支持 +86 / 连字符 / 空格" autoFocus
                       inputMode="tel" maxLength={20} />
              </Form.Item>
              <Form.Item style={{ marginBottom: 8 }}>
                <SendCodeButton
                  ref={sendBtnRef}
                  htmlType="submit"
                  type="primary"
                  block
                  loading={sendCode.isPending}
                />
              </Form.Item>
            </Form>
          </>
        )}

        {phase === 'code' && (
          <>
            <Typography.Title level={4} style={{ marginTop: 8, marginBottom: 4 }}>
              输入验证码
            </Typography.Title>
            <Typography.Paragraph type="secondary" style={{ marginTop: 0 }}>
              验证码已发送至 {phone},15 分钟内有效。
            </Typography.Paragraph>
            <Form form={form} layout="vertical" onFinish={onConfirm}>
              <Form.Item
                name="code"
                label="短信验证码"
                rules={[{ required: true, message: '请输入 6 位验证码' }]}
              >
                <Input placeholder="6 位字母数字" maxLength={6} autoFocus
                       inputMode="text" style={{ letterSpacing: '0.3em' }} />
              </Form.Item>
              <Form.Item style={{ marginBottom: 8 }}>
                <Button type="primary" htmlType="submit" block loading={confirm.isPending}>
                  重置密码
                </Button>
              </Form.Item>
            </Form>
            <Button type="link" size="small" style={{ padding: 0 }}
                    onClick={() => setPhase('phone')}>
              换一个手机号
            </Button>
          </>
        )}

        {phase === 'done' && result && (
          <Result
            status="success"
            title="密码已重置"
            subTitle="请妥善保存下方新密码,它只会展示这一次。"
            style={{ paddingBottom: 0 }}
            extra={
              <div style={{ textAlign: 'left' }}>
                <div style={{ marginBottom: 12 }}>
                  <div style={{ fontSize: 12, color: 'var(--ms-ink-muted)', marginBottom: 4 }}>
                    账号
                  </div>
                  <Typography.Text copyable style={{ fontSize: 16 }}>{account}</Typography.Text>
                  {onlyName && (
                    <div style={{ fontSize: 12, color: 'var(--ms-ink-muted)', marginTop: 4 }}>
                      {ONLY_NAME_HINT}
                    </div>
                  )}
                </div>
                <div style={{ marginBottom: 20 }}>
                  <div style={{ fontSize: 12, color: 'var(--ms-ink-muted)', marginBottom: 4 }}>
                    新密码
                  </div>
                  <Typography.Text copyable style={{ fontSize: 16,
                    fontFamily: 'var(--ms-font-mono)' }}>
                    {result.new_password}
                  </Typography.Text>
                </div>
                <Typography.Paragraph type="secondary" style={{ marginBottom: 16, fontSize: 13 }}>
                  请使用该密码登录,首次登录后系统会引导你设置新密码
                </Typography.Paragraph>
                <Button type="primary" block onClick={() => navigate('/login', { replace: true })}>
                  去登录
                </Button>
              </div>
            }
          />
        )}
      </Card>
    </div>
  );
}
