/**
 * /reset-password — 重置密码页(邮箱账号方案 §6.3)。
 *
 * token 只读 window.location.hash 的 `#token=`(fragment 不进代理日志/浏览器历史,
 * D8 的全部保护所在;**不支持 `?token=`**)。StrictMode 安全:useState 初始化器在
 * 渲染期一次性捕获内存副本,effect 里再 replaceState 清 hash —— 不能反过来,
 * 开发态 effect 双执行会把第二次读成空。地址栏没有 fragment(邮件客户端截断/
 * 手工复制)时显示「粘贴重置链接或 token」输入框,token 只留在组件内存,不写回 URL。
 *
 * 流程:挂载 POST /password-reset/verify(脱敏邮箱)→ 新密码表单 →
 * POST /password-reset/confirm。200 成功面板留在本页(queryClient.clear() 清掉旧
 * me 缓存,否则已登录浏览器点「去登录」会先被 AppShell 弹回首页再被 401 踢回);
 * 400 失效面板 / 429 冷却倒计时 / 503 功能未开启(独立文案,不伪装成「链接失效」)。
 */
import { Alert, Button, Card, Form, Input, Spin, Typography } from 'antd';
import { useEffect, useState, type ReactNode } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import {
  errorMessage, httpErrorStatus, retryAfterSeconds,
} from '../api/client';
import { usePublicConfig, useResetPassword, useVerifyResetToken } from '../api/hooks';
import {
  buildPasswordRe, DEFAULT_PASSWORD_MIN_LENGTH, passwordPolicyHint,
} from '../lib/password-policy';
import { useCompactViewport } from '../lib/use-viewports';

/** 成功后的 429 冷却默认秒数(Retry-After 缺省时);服务端仍有硬频控兜底。 */
const DEFAULT_COUNTDOWN = 60;
/** Retry-After 封顶,防异常大值把 UI 数字撑爆。 */
const MAX_COUNTDOWN = 24 * 60 * 60;

/** 从地址栏 hash 捕获 `#token=`(仅 fragment;query 的 ?token= 一律不读,§6.3)。 */
function readTokenFromHash(): string | null {
  const h = window.location.hash;
  if (!h.startsWith('#token=')) return null;
  const raw = h.slice('#token='.length);
  if (!raw) return null;
  try { return decodeURIComponent(raw); } catch { return raw; }
}

/** 粘贴框内容 → token:识别完整链接里的 `#token=` 片段,否则整串视为 token 明文。 */
function extractToken(input: string): string | null {
  const s = input.trim();
  if (!s) return null;
  const m = s.match(/#token=([^&#]+)/);
  if (m) {
    try { return decodeURIComponent(m[1]); } catch { return m[1]; }
  }
  return s;
}

export default function ResetPasswordPage() {
  const compact = useCompactViewport();
  const navigate = useNavigate();
  const qc = useQueryClient();
  const { data: publicConfig } = usePublicConfig();
  const reset = useResetPassword();
  const [form] = Form.useForm<{ new_password: string; confirm_password: string }>();

  // 渲染期一次性捕获(StrictMode 双渲染都在 effect 之前,hash 必然还在)
  const [token, setToken] = useState<string | null>(readTokenFromHash);
  const [pasted, setPasted] = useState('');
  const [resetDone, setResetDone] = useState(false);
  const [fatal503, setFatal503] = useState(false);
  const [confirmError, setConfirmError] = useState<string | null>(null);
  const [countdown, setCountdown] = useState(0);

  // resetDone 后停掉 verify observer:confirm 成功会 queryClient.clear(),
  // 不关闸会立刻触发一次多余的 verify 重放(白耗 IP 频控配额)
  const verify = useVerifyResetToken(token && !resetDone ? token : null);

  // 读到 token 后立即清 URL(replaceState 不产生新历史条目;StrictMode 下
  // effect 双执行,第二次结果相同,幂等无副作用)
  useEffect(() => {
    if (!token) return;
    window.history.replaceState(null, '', window.location.pathname + window.location.search);
  }, [token]);

  useEffect(() => {
    if (countdown <= 0) return;
    const t = setTimeout(() => setCountdown((c) => c - 1), 1000);
    return () => clearTimeout(t);
  }, [countdown]);

  const startCountdown = (seconds: number) => {
    setCountdown(Math.min(Math.max(1, seconds), MAX_COUNTDOWN));
  };

  // verify 429(挂载自动校验触发,没有事件处理器可落):Deferred 到宏任务里播种
  // 倒计时,规避 effect 同步 setState 的级联渲染(react-hooks/set-state-in-effect);
  // 归零后「重试」按钮恢复;非 429 错误不设倒计时(可立即重试)
  useEffect(() => {
    if (!(verify.isError && httpErrorStatus(verify.error) === 429)) return;
    const t = setTimeout(() => {
      startCountdown(retryAfterSeconds(verify.error) ?? DEFAULT_COUNTDOWN);
    }, 0);
    return () => clearTimeout(t);
  }, [verify.isError, verify.error]);

  const minLength = publicConfig?.password_min_length ?? DEFAULT_PASSWORD_MIN_LENGTH;
  const pwRe = buildPasswordRe(minLength);

  const submitNewPassword = async (newPassword: string) => {
    setConfirmError(null);
    try {
      await reset.mutateAsync({ token: token as string, new_password: newPassword });
      setResetDone(true);
      // 清全部缓存(含 ['me']):后端已踢全部旧会话,旧 me 缓存会误导 AppShell
      qc.clear();
    } catch (err) {
      const status = httpErrorStatus(err);
      if (status === 503) {
        setFatal503(true);
      } else if (status === 429) {
        startCountdown(retryAfterSeconds(err) ?? DEFAULT_COUNTDOWN);
        setConfirmError(errorMessage(err, '操作过于频繁,请稍后再试'));
      } else if (status === 400) {
        // 策略不达标 / 与原密码相同 / token 已失效(verify 与 confirm 之间过期)
        setConfirmError(errorMessage(err, '重置失败'));
      } else {
        setConfirmError(errorMessage(err, '重置失败,请稍后重试'));
      }
    }
  };

  const countdownLabel = countdown > 0 ? `(${countdown}s 后可重试)` : '';

  // ── 视图分派 ──────────────────────────────────────────────────────────────
  let view: ReactNode;

  if (!token) {
    // 无 fragment:粘贴重置链接或 token(只留组件内存,不写回 URL)
    view = (
      <>
        <Typography.Title level={4} style={{ marginTop: 8, marginBottom: 4 }}>
          重置密码
        </Typography.Title>
        <Typography.Paragraph type="secondary" style={{ marginTop: 0 }}>
          未在链接中识别到重置凭证。请粘贴邮件里的完整链接,或直接粘贴链接中的 token。
        </Typography.Paragraph>
        <Form layout="vertical" onFinish={() => setToken(extractToken(pasted))}>
          <Form.Item style={{ marginBottom: 12 }}>
            <Input.TextArea
              value={pasted}
              onChange={(e) => setPasted(e.target.value)}
              placeholder="粘贴重置链接或 token"
              autoSize={{ minRows: 2, maxRows: 4 }}
              autoFocus
            />
          </Form.Item>
          <Form.Item style={{ marginBottom: 0 }}>
            <Button type="primary" htmlType="submit" block disabled={!pasted.trim()}>
              校验并继续
            </Button>
          </Form.Item>
        </Form>
      </>
    );
  } else if (resetDone) {
    // 成功面板留在本页:navigate('/login?reset=1') 会因旧会话被 AppShell 重定向丢失提示
    view = (
      <>
        <Typography.Title level={4} style={{ marginTop: 8, marginBottom: 4 }}>
          重置完成
        </Typography.Title>
        <Alert
          type="success"
          showIcon
          style={{ marginBottom: 16 }}
          message="密码已重置,请用新密码登录"
          description="原有登录状态已全部失效(含其他浏览器与 App)。"
        />
        <Button type="primary" block onClick={() => navigate('/login')}>
          去登录
        </Button>
      </>
    );
  } else if (fatal503) {
    // 功能被关闭:独立文案,不伪装成「链接失效」(§6.3)
    view = (
      <>
        <Typography.Title level={4} style={{ marginTop: 8, marginBottom: 4 }}>
          重置密码
        </Typography.Title>
        <Alert type="warning" showIcon message="邮箱找回密码功能暂未开启,请联系管理员" />
      </>
    );
  } else if (verify.isLoading) {
    view = (
      <div style={{ padding: '48px 0', textAlign: 'center', color: 'var(--ms-ink-muted)' }}>
        <Spin />
        <div style={{ marginTop: 12, fontSize: 13 }}>正在校验重置链接…</div>
      </div>
    );
  } else if (verify.data?.valid) {
    // verify 通过:脱敏邮箱 + 新密码表单
    const vErr = confirmError;
    view = (
      <>
        <Typography.Title level={4} style={{ marginTop: 8, marginBottom: 4 }}>
          设置新密码
        </Typography.Title>
        <Typography.Paragraph type="secondary" style={{ marginTop: 0 }}>
          正在为 <span style={{ fontFamily: 'var(--ms-font-mono)' }}>{verify.data.email_masked}</span> 重置密码
        </Typography.Paragraph>
        {vErr && <Alert type="error" showIcon style={{ marginBottom: 16 }} message={vErr} />}
        <Form form={form} layout="vertical" onFinish={(v) => submitNewPassword(v.new_password)}>
          <Form.Item
            name="new_password"
            label="新密码"
            rules={[
              { required: true, message: '请输入新密码' },
              { pattern: pwRe, message: passwordPolicyHint(minLength) },
            ]}
          >
            <Input.Password
              placeholder={passwordPolicyHint(minLength)}
              autoFocus
              maxLength={128}
            />
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
            <Input.Password placeholder="再次输入新密码" maxLength={128} />
          </Form.Item>
          <Form.Item style={{ marginBottom: 0 }}>
            <Button
              type="primary"
              htmlType="submit"
              block
              loading={reset.isPending}
              disabled={countdown > 0}
            >
              重置密码{countdownLabel}
            </Button>
          </Form.Item>
        </Form>
      </>
    );
  } else if (verify.isError) {
    const status = httpErrorStatus(verify.error);
    if (status === 400) {
      // 失效面板:token 错误 / 已用过 / 已过期
      view = (
        <>
          <Typography.Title level={4} style={{ marginTop: 8, marginBottom: 4 }}>
            重置密码
          </Typography.Title>
          <Alert
            type="error"
            showIcon
            style={{ marginBottom: 16 }}
            message="链接已失效或已被使用"
            description="重置链接 30 分钟内有效且仅可使用一次。"
          />
          <Link to="/forgot-password">
            <Button type="primary" block>重新申请</Button>
          </Link>
        </>
      );
    } else if (status === 429) {
      view = (
        <>
          <Typography.Title level={4} style={{ marginTop: 8, marginBottom: 4 }}>
            重置密码
          </Typography.Title>
          <Alert
            type="warning"
            showIcon
            style={{ marginBottom: 16 }}
            message={errorMessage(verify.error, '操作过于频繁,请稍后再试')}
          />
          <Button block disabled={countdown > 0} onClick={() => { void verify.refetch(); }}>
            重试{countdown > 0 ? `(${countdown}s)` : ''}
          </Button>
        </>
      );
    } else {
      // 网络/未知错误:可重试(非 429 不设倒计时)
      view = (
        <>
          <Typography.Title level={4} style={{ marginTop: 8, marginBottom: 4 }}>
            重置密码
          </Typography.Title>
          <Alert
            type="error"
            showIcon
            style={{ marginBottom: 16 }}
            message={errorMessage(verify.error, '校验失败,请稍后重试')}
          />
          <Button block onClick={() => { void verify.refetch(); }}>重试</Button>
        </>
      );
    }
  } else {
    // token 有值、query 刚启用还未起跑的空档
    view = (
      <div style={{ padding: '48px 0', textAlign: 'center', color: 'var(--ms-ink-muted)' }}>
        <Spin />
      </div>
    );
  }

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
        {view}
      </Card>
      <div style={{ textAlign: 'center', marginTop: 16, fontSize: 12, color: 'var(--ms-ink-subtle)' }}>
        <Link to="/login">返回登录</Link>
      </div>
    </div>
  );
}
