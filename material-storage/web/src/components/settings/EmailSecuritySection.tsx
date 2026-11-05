/**
 * /settings「账号安全」卡片(邮箱账号方案 §6.4)。
 *
 * 显隐矩阵(以 mail_ready=public-config.email_auth_enabled 为有效开关,D11):
 * - mail_ready=false 且 me.email 为空 → 整块隐藏(不显示必然失败的「绑定邮箱」);
 * - mail_ready=false 但有邮箱 → 只显示「解除绑定」(解绑不依赖 SMTP),
 *   绑定/验证/换绑隐藏并提示「邮箱功能暂未开启」;
 * - me.password_set=false → 全部操作禁用并提示先由管理员初始化本地密码
 *   (后端 /email/code 同样 400,前端不给必然失败的入口);
 * - 无邮箱 →「未绑定邮箱」+ 绑定;有邮箱未验证 → 橙色 Tag + 验证/换绑/解绑;
 *   已验证 → 绿色 Tag + 换绑/解绑。
 *
 * 绑定/换绑/验证共用 EmailBindDialog 两步弹窗(第一步邮箱+当前密码发码,
 * 第二步 6 位验证码确认);解绑独立弹窗(仅当前密码)。成功后 invalidate ['me']
 * (在 useConfirmEmailCode / useUnbindEmail 的 onSuccess,session_version 未变,安全)。
 * 弹窗按 open 条件挂载:重新打开必然从第一步开始,天然满足「关闭清空状态」。
 */
import { Alert, App, Button, Form, Input, Modal, Tag } from 'antd';
import { useEffect, useState } from 'react';
import { errorMessage } from '../../api/client';
import { useConfirmEmailCode, useMe, usePublicConfig, useSendEmailCode, useUnbindEmail } from '../../api/hooks';
import { useCompactViewport } from '../../lib/use-viewports';

/** 邮箱操作失败后的重发冷却默认秒数(与后端 EMAIL_CODE_RESEND_SECONDS 默认一致)。 */
const RESEND_COOLDOWN = 60;

/** 发码目标与用途 —— bind/change 可改邮箱,verify 恒为当前邮箱。 */
type BindMode = 'bind' | 'change' | 'verify';

const MODE_TITLE: Record<BindMode, string> = {
  bind: '绑定邮箱',
  change: '更换邮箱',
  verify: '验证当前邮箱',
};
const MODE_SUCCESS: Record<BindMode, string> = {
  bind: '邮箱已绑定',
  change: '邮箱已更换',
  verify: '邮箱已验证',
};

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export function EmailSecuritySection() {
  const { data: me } = useMe();
  const { data: publicConfig } = usePublicConfig();
  const compact = useCompactViewport();
  const [bindMode, setBindMode] = useState<BindMode | null>(null); // null = 弹窗关闭
  const [unbindOpen, setUnbindOpen] = useState(false);

  const mailReady = publicConfig?.email_auth_enabled === true;
  const email = me?.email ?? null;
  const emailVerified = me?.email_verified ?? false;
  const passwordSet = me?.password_set ?? false;

  // hooks 置顶纪律(use-viewports):条件 return 放在全部 hooks 之后
  if (!me) return null; // me 未到先不渲染,避免闪「未绑定邮箱」
  // mail_ready=false 且无邮箱:整块隐藏(不渲染一个必然失败的绑定入口)
  if (!mailReady && !email) return null;

  const disabled = !passwordSet;

  return (
    <section style={{
      background: 'var(--ms-surface)',
      border: '1px solid var(--ms-hairline)',
      borderRadius: 'var(--ms-radius-md)',
      padding: '16px 20px',
      marginBottom: 'var(--ms-sp-xl)',
    }}>
      <div style={{
        display: 'flex', alignItems: 'center', gap: 12,
        flexWrap: 'wrap', marginBottom: 12,
      }}>
        <h2 style={{ margin: 0, fontSize: 15, fontWeight: 500, color: 'var(--ms-ink)' }}>
          账号安全
        </h2>
        <span style={{ fontSize: 12.5, color: 'var(--ms-ink-muted)' }}>
          绑定邮箱后可通过邮箱自助找回密码
        </span>
      </div>

      {!passwordSet && (
        <Alert
          type="warning"
          showIcon
          style={{ marginBottom: 16 }}
          message="该账号尚未设置本地密码,请联系管理员初始化后再绑定邮箱"
        />
      )}
      {email && !mailReady && (
        <Alert
          type="info"
          showIcon
          style={{ marginBottom: 16 }}
          message="邮箱功能暂未开启"
          description="绑定 / 验证 / 换绑暂不可用;解除绑定不依赖该功能。"
        />
      )}

      <div style={{
        display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap',
      }}>
        <span style={{
          fontSize: 13, fontWeight: 500, color: 'var(--ms-ink)', minWidth: 64,
        }}>邮箱</span>
        {email ? (
          <>
            <span className="ms-mono" style={{
              fontSize: 13, color: 'var(--ms-ink)',
              maxWidth: compact ? '100%' : 360,
              overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
            }}>{email}</span>
            {emailVerified
              ? <Tag color="green" style={{ marginInlineEnd: 0 }}>已验证</Tag>
              : <Tag color="orange" style={{ marginInlineEnd: 0 }}>未验证</Tag>}
          </>
        ) : (
          <>
            <span style={{ fontSize: 13, color: 'var(--ms-ink-muted)' }}>未绑定邮箱</span>
            <Tag style={{ marginInlineEnd: 0 }}>未绑定</Tag>
          </>
        )}
        <div style={{ flex: 1 }} />
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
          {mailReady && (
            <>
              {!email && (
                <Button disabled={disabled} onClick={() => setBindMode('bind')}>绑定邮箱</Button>
              )}
              {email && !emailVerified && (
                <Button disabled={disabled} onClick={() => setBindMode('verify')}>验证邮箱</Button>
              )}
              {email && (
                <Button disabled={disabled} onClick={() => setBindMode('change')}>更换邮箱</Button>
              )}
            </>
          )}
          {email && (
            <Button danger disabled={disabled} onClick={() => setUnbindOpen(true)}>解除绑定</Button>
          )}
        </div>
      </div>

      <p style={{ margin: '12px 0 0', fontSize: 12, color: 'var(--ms-ink-subtle)', lineHeight: 1.7 }}>
        绑定 / 换绑 / 解绑都需要输入当前密码;换绑需新邮箱收到的 6 位验证码。
        邮箱验证状态只影响找回密码的展示口径,未验证邮箱仍可用于登录与找回。
      </p>

      {/* 条件挂载:bindMode 为 null 不渲染 —— 关闭即销毁,重开必然从第一步开始 */}
      {bindMode !== null && (
        <EmailBindDialog
          mode={bindMode}
          currentEmail={email}
          disabled={disabled}
          onClose={() => setBindMode(null)}
        />
      )}
      {unbindOpen && (
        <EmailUnbindDialog onClose={() => setUnbindOpen(false)} />
      )}
    </section>
  );
}

// ─── 绑定 / 换绑 / 验证:两步弹窗(§6.4 EmailBindDialog)────────────────────
function EmailBindDialog({ mode, currentEmail, disabled, onClose }: {
  mode: BindMode;
  currentEmail: string | null;
  disabled: boolean;
  onClose: () => void;
}) {
  const { message } = App.useApp();
  const sendCode = useSendEmailCode();
  const confirmCode = useConfirmEmailCode();
  const [form] = Form.useForm<{ email?: string; password: string; code?: string }>();
  const [step, setStep] = useState<1 | 2>(1);
  // 第二步展示与重发所需:发码成功后记忆目标邮箱(脱敏展示)与当前密码(仅内存)
  const [sentEmail, setSentEmail] = useState<string | null>(null);
  const [sentPassword, setSentPassword] = useState<string | null>(null);
  const [maskedEmail, setMaskedEmail] = useState<string | null>(null);
  const [cooldown, setCooldown] = useState(0);

  useEffect(() => {
    if (cooldown <= 0) return;
    const t = setTimeout(() => setCooldown((c) => c - 1), 1000);
    return () => clearTimeout(t);
  }, [cooldown]);

  const close = () => {
    if (sendCode.isPending || confirmCode.isPending) return; // 请求中禁止关闭
    form.resetFields();
    onClose();
  };

  const send = async (target: string, password: string) => {
    try {
      const out = await sendCode.mutateAsync({ email: target, password });
      setSentEmail(target);
      setSentPassword(password);
      setMaskedEmail(out.masked_email);
      setCooldown(RESEND_COOLDOWN);
      setStep(2);
    } catch (err) {
      message.error(errorMessage(err, '发送验证码失败'));
    }
  };

  const resend = () => {
    if (!sentEmail || !sentPassword || cooldown > 0) return;
    void send(sentEmail, sentPassword);
  };

  const submitStep1 = async () => {
    const v = await form.validateFields();
    const target = mode === 'verify' ? (currentEmail ?? '') : (v.email ?? '').trim();
    await send(target, v.password);
  };

  const submitStep2 = async () => {
    try {
      const v = await form.validateFields(['code']);
      await confirmCode.mutateAsync({ code: (v.code ?? '').trim() });
      message.success(MODE_SUCCESS[mode]);
      onClose();
    } catch (err) {
      if ((err as { errorFields?: unknown }).errorFields) return;
      message.error(errorMessage(err, '验证码校验失败'));
    }
  };

  return (
    <Modal
      title={MODE_TITLE[mode]}
      open
      onCancel={close}
      onOk={step === 1 ? submitStep1 : submitStep2}
      okText={step === 1 ? '发送验证码' : '确认'}
      cancelText="取消"
      confirmLoading={step === 1 ? sendCode.isPending : confirmCode.isPending}
      okButtonProps={{ disabled }}
      closable={!(sendCode.isPending || confirmCode.isPending)}
      maskClosable={!(sendCode.isPending || confirmCode.isPending)}
      keyboard={!(sendCode.isPending || confirmCode.isPending)}
      cancelButtonProps={{ disabled: sendCode.isPending || confirmCode.isPending }}
    >
      {step === 1 ? (
        <Form form={form} layout="vertical">
          {mode === 'verify' ? (
            <Form.Item label="当前绑定邮箱">
              <Input value={currentEmail ?? ''} disabled />
            </Form.Item>
          ) : (
            <Form.Item
              name="email"
              label="新邮箱"
              rules={[
                { required: true, whitespace: true, message: '请输入邮箱' },
                { pattern: EMAIL_RE, message: '邮箱格式不正确' },
              ]}
              extra={mode === 'change' ? '换绑成功后旧邮箱将收到安全告知邮件' : undefined}
            >
              <Input type="email" placeholder="name@example.com" autoFocus maxLength={254} />
            </Form.Item>
          )}
          <Form.Item
            name="password"
            label="当前密码"
            rules={[{ required: true, message: '请输入当前密码' }]}
            extra="邮箱操作需验证当前密码"
          >
            <Input.Password placeholder="当前密码" maxLength={128} />
          </Form.Item>
        </Form>
      ) : (
        <div>
          <p style={{ margin: '0 0 12px', fontSize: 13, color: 'var(--ms-ink-muted)' }}>
            验证码已发送至 <span className="ms-mono">{maskedEmail ?? sentEmail}</span>,
            10 分钟内有效。
          </p>
          <Form form={form} layout="vertical">
            <Form.Item
              name="code"
              label="验证码"
              rules={[
                { required: true, message: '请输入 6 位验证码' },
                { pattern: /^\d{6}$/, message: '验证码为 6 位数字' },
              ]}
            >
              <Input
                placeholder="6 位数字"
                inputMode="numeric"
                maxLength={6}
                autoFocus
                style={{ maxWidth: 200 }}
              />
            </Form.Item>
          </Form>
          <Button
            size="small"
            disabled={cooldown > 0}
            onClick={resend}
          >
            重新发送{cooldown > 0 ? `(${cooldown}s)` : ''}
          </Button>
        </div>
      )}
    </Modal>
  );
}

// ─── 解绑弹窗(仅当前密码;解绑不依赖 SMTP)─────────────────────────────────
function EmailUnbindDialog({ onClose }: { onClose: () => void }) {
  const { message } = App.useApp();
  const unbind = useUnbindEmail();
  const [form] = Form.useForm<{ password: string }>();

  const submit = async () => {
    try {
      const v = await form.validateFields();
      await unbind.mutateAsync({ password: v.password });
      message.success('已解除邮箱绑定');
      onClose();
    } catch (err) {
      if ((err as { errorFields?: unknown }).errorFields) return;
      message.error(errorMessage(err, '解除绑定失败'));
    }
  };

  return (
    <Modal
      title="解除邮箱绑定"
      open
      onCancel={onClose}
      onOk={submit}
      okText="确认解绑"
      cancelText="取消"
      okButtonProps={{ danger: true }}
      confirmLoading={unbind.isPending}
      closable={!unbind.isPending}
      maskClosable={!unbind.isPending}
      keyboard={!unbind.isPending}
      cancelButtonProps={{ disabled: unbind.isPending }}
    >
      <Alert
        type="warning"
        showIcon
        style={{ marginBottom: 16 }}
        message="解除后将无法通过邮箱找回密码"
        description="已发出的重置链接同时作废;如需再次绑定,可随时重新绑定邮箱。"
      />
      <Form form={form} layout="vertical">
        <Form.Item
          name="password"
          label="当前密码"
          rules={[{ required: true, message: '请输入当前密码' }]}
          extra="输入当前密码以确认是本人操作"
        >
          <Input.Password placeholder="当前密码" autoFocus maxLength={128} />
        </Form.Item>
      </Form>
    </Modal>
  );
}
