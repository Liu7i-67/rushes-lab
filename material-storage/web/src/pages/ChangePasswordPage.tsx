/**
 * 修改密码页(#149)。
 *
 * 两种进入方式:
 * - 强制流程:登录后 must_change_password=true,AppShell 路由守卫只放行本页
 * - 自愿流程:UserMenu「修改密码」(me.password_set 时可见)
 *
 * 未登录访问 → 跳 /login?next=/change-password。
 * 邮箱账号方案 §6.6:改密成功后 session_version 自增、原会话已失效 —— 成功后
 * queryClient.clear() 清掉旧 me 缓存并回 /login?reset=1(导航只此一处,不再回首页)。
 */
import { App, Alert, Button, Card, Form, Input, Typography } from 'antd';
import { Navigate, useNavigate } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { errorMessage } from '../api/client';
import { useChangePassword, useMe, usePublicConfig } from '../api/hooks';
import {
  buildPasswordRe, DEFAULT_PASSWORD_MIN_LENGTH, passwordPolicyHint,
} from '../lib/password-policy';
import { useCompactViewport } from '../lib/use-viewports';

export default function ChangePasswordPage() {
  const navigate = useNavigate();
  const { message } = App.useApp();
  const queryClient = useQueryClient();
  const { data: me, isLoading, isError } = useMe();
  const { data: publicConfig } = usePublicConfig();
  const change = useChangePassword();
  const [form] = Form.useForm();
  const compact = useCompactViewport();

  if (isLoading) return null; // AppShell 已展示加载态
  if (isError || !me) return <Navigate to="/login?next=/change-password" replace />;

  const forced = me.must_change_password;
  // 密码策略与重置页共用一份(§6.3);min_length 来自 public-config,拉取失败回落 8
  const minLength = publicConfig?.password_min_length ?? DEFAULT_PASSWORD_MIN_LENGTH;
  const pwRe = buildPasswordRe(minLength);

  const onFinish = async (v: { old_password: string; new_password: string }) => {
    try {
      await change.mutateAsync({ old_password: v.old_password, new_password: v.new_password });
      // §6.6:改密后原会话已失效(session_version 自增),不再 invalidate ['me'](必 401);
      // 清全部缓存回登录,导航只此一处
      queryClient.clear();
      message.success(forced ? '密码已设置,请重新登录' : '密码已修改,请重新登录');
      navigate('/login?reset=1', { replace: true });
    } catch (err) {
      message.error(errorMessage(err, '修改密码失败'));
    }
  };

  return (
    <div style={{ maxWidth: 520, margin: compact ? '24px auto' : '64px auto', padding: 16 }}>
      <Card>
        <Typography.Title level={4} style={{ marginTop: 0, marginBottom: 4 }}>
          {forced ? '首次登录,请设置新密码' : '修改密码'}
        </Typography.Title>
        <Typography.Paragraph type="secondary" style={{ marginTop: 0 }}>
          {forced
            ? '为保护你的账号,首次登录必须设置新密码后才能继续使用。'
            : '请先验证原密码,再设置新密码。'}
        </Typography.Paragraph>

        {forced && (
          <Alert type="warning" style={{ marginBottom: 20 }}
                 message="密码重置" showIcon
                 description="新密码设置完成后将自动解除强制要求。" />
        )}

        <Form form={form} layout="vertical" onFinish={onFinish}>
          <Form.Item
            name="old_password"
            label="原密码"
            rules={[{ required: true, message: '请输入原密码' }]}
          >
            <Input.Password placeholder="原密码" autoFocus />
          </Form.Item>
          <Form.Item
            name="new_password"
            label="新密码"
            rules={[
              { required: true, message: '请输入新密码' },
              // antd v6 陷阱:pattern 与 min/max 混在同一 rule 会互吞,长度交给正则表达
              { pattern: pwRe, message: passwordPolicyHint(minLength) },
            ]}
          >
            <Input.Password placeholder={passwordPolicyHint(minLength)} />
          </Form.Item>
          <Form.Item
            name="confirm_password"
            label="确认新密码"
            dependencies={['new_password']}
            rules={[
              { required: true, message: '请再次输入新密码' },
              ({ getFieldValue }) => ({
                validator: (_rule, value) =>
                  !value || getFieldValue('new_password') === value
                    ? Promise.resolve()
                    : Promise.reject(new Error('两次输入的新密码不一致')),
              }),
            ]}
          >
            <Input.Password placeholder="再次输入新密码" />
          </Form.Item>
          <Form.Item style={{ marginBottom: 0 }}>
            <Button type="primary" htmlType="submit" block loading={change.isPending}>
              {forced ? '设置密码' : '确认修改'}
            </Button>
          </Form.Item>
        </Form>
      </Card>
    </div>
  );
}
