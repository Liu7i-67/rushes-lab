/**
 * 本地账号密码登录页(#149;#154:飞书 OIDC 入口下线,ADR-0007)。
 *
 * 未登录用户统一被 AppShell / client.ts 401 拦截器带 `?next=` 引导到这里;
 * 登录成功回 next(首登强制改密 → /change-password)。
 * WEB-06(P2):回跳前先等 useMe 反查完成(否则 AppShell 仍按未登录渲染会把
 * 页面整页弹回 login 丢掉 next);next 经 parseNext 防 open redirect 校验。
 */
import { App, Alert, Button, Card, Form, Input, Typography } from 'antd';
import { KeyRound, User as UserIcon } from 'lucide-react';
import { useQueryClient } from '@tanstack/react-query';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { errorMessage } from '../api/client';
import { useLocalLogin } from '../api/hooks';
import { BrandMark } from '../components/BrandMark';
import { useCompactViewport } from '../lib/use-viewports';

const BASENAME = '/ms-static/web';

/**
 * WEB-06(P2):解析并安全校验 `next` 查询参数 → react-router basename 相对路径。
 *
 * useSearchParams 已解码一层;这里再 decodeURIComponent 兜底一次以消除双重编码
 * (编码残缺如裸 % 时保留一层解码结果继续校验,不抛错)。随后按防 open redirect
 * 规则校验:仅接受「以单个 / 开头且不以 // 开头、不含协议与域名」的本站相对路径,
 * 反斜杠按可疑一并拒绝。不合法 / 缺失一律回落 '/'(既有默认落点);合法且带
 * basename 时剥掉 basename,query 与 hash 原样保留 —— 落点必须是原页面
 * (如 /settings/mcp?include_revoked=1 的「URL 即状态」不丢)。
 */
function parseNext(raw: string | null): string {
  let n = raw ?? '';
  if (!n) return '/';
  try {
    n = decodeURIComponent(n);
  } catch {
    // 编码残缺:不再二次解码,用一层解码结果继续做安全校验
  }
  if (!n.startsWith('/') || n.startsWith('//') || n.includes('\\')) return '/';
  // 显式挡协议头(https: / javascript: 等);以 / 开头时正常不会命中,兜底防御
  if (/^[a-zA-Z][a-zA-Z\d+\-.]*:/.test(n)) return '/';
  if (n.startsWith(BASENAME)) n = n.slice(BASENAME.length);
  return n.startsWith('/') ? n : '/';
}

export default function LoginPage() {
  const navigate = useNavigate();
  const { message } = App.useApp();
  const queryClient = useQueryClient();
  const [params] = useSearchParams();
  const login = useLocalLogin();
  const [form] = Form.useForm();
  const compact = useCompactViewport();
  const next = parseNext(params.get('next'));

  const onFinish = async (values: { username: string; password: string }) => {
    try {
      const res = await login.mutateAsync(values);
      message.success(`欢迎,${res.name || '已登录'}`);
      // WEB-06:先等 useMe 反查完成再跳转。mutation onSuccess 里的 invalidate
      // 是异步的,直接 navigate 时 AppShell 仍按未登录(isError)渲染,会在受保护
      // 路由上整页 assign 回 login?next=…(此时 next 已指向 /login 自身),重载后
      // 走已登录 /login 分支落首页 —— 表现为「登录后一律落首页不回跳」。
      await queryClient.refetchQueries({ queryKey: ['me'] });
      if (res.must_change_password) {
        navigate('/change-password', { replace: true });
      } else {
        navigate(next, { replace: true });
      }
    } catch (err) {
      message.error(errorMessage(err, '登录失败'));
    }
  };

  return (
    <div style={{ maxWidth: 520, margin: compact ? '24px auto' : '64px auto', padding: 16 }}>
      <Card>
        {/* 品牌印记(与 AppHeader 一致的几何方块) */}
        <BrandMark />

        <Typography.Title level={4} style={{ marginTop: 8, marginBottom: 4 }}>
          账号密码登录
        </Typography.Title>
        <Typography.Paragraph type="secondary" style={{ marginTop: 0 }}>
          使用本地账号登录(工号 / 拼音用户名 / 邮箱均可)
        </Typography.Paragraph>

        <Alert
          type="info"
          style={{ marginBottom: 20 }}
          message="首次登录需设置新密码"
          description="初始密码由管理员分配;首次登录成功后系统会要求你设置自己的新密码。"
        />

        <Form form={form} layout="vertical" onFinish={onFinish}
              initialValues={{ username: '', password: '' }}>
          <Form.Item
            name="username"
            label="用户名"
            rules={[{ required: true, message: '请输入用户名' }]}
          >
            <Input prefix={<UserIcon size={14} />} placeholder="工号 / 拼音用户名 / 邮箱" autoFocus />
          </Form.Item>
          <Form.Item
            name="password"
            label="密码"
            rules={[{ required: true, message: '请输入密码' }]}
            style={{ marginBottom: 4 }}
          >
            <Input.Password prefix={<KeyRound size={14} />} placeholder="密码" />
          </Form.Item>
          {/* 忘记密码入口(2026-11-20 方案 §6.1):密码框下方右侧,去短信找回密码三态页 */}
          <div style={{ textAlign: 'right', marginBottom: 12 }}>
            <Button type="link" size="small" style={{ padding: 0 }}
                    onClick={() => navigate('/forgot-password')}>
              忘记密码?
            </Button>
          </div>
          <Form.Item style={{ marginBottom: 8 }}>
            <Button type="primary" htmlType="submit" block loading={login.isPending}>
              登录
            </Button>
          </Form.Item>
        </Form>
      </Card>
      <div style={{ textAlign: 'center', marginTop: 16, fontSize: 12, color: 'var(--ms-ink-subtle)' }}>
        连续 5 次登录失败将锁定 15 分钟
        {import.meta.env.DEV && (
          <div style={{ marginTop: 4 }}>
            {/* dev 下跳过登录的 X-User-Id 通道(local_up.sh 已给 seed 账号设密码,日常不必用) */}
            <a href={`${BASENAME}/dev-login`}>开发者通道(X-User-Id)→</a>
          </div>
        )}
      </div>
    </div>
  );
}
