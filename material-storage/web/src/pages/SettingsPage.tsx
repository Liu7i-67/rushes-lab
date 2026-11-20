/**
 * /settings — 账号设置页(2026-11-19 设置页 MCP 收拢方案 F1/F3/D4/D7)。
 *
 * 结构 = 页头「设置」+ 三个区块:
 * - 「账号与安全」(2026-11-20 方案 §6.4):手机号当前值(完整号;未绑定灰 Tag)
 *   +「绑定手机 / 更换手机」按钮 → Modal(归一化预校验 + 验证码 + SendCodeButton;
 *   成功 invalidateQueries(['me']) 由 useBindPhone 承担);
 * - 「偏好」:【默认收拢全部文件夹】antd Switch(服务端存储,读写
 *   GET/PUT /api/v1/me/preferences,走 api/prefs.ts 固定契约 hooks);
 *   开启后进入项目时所有文件夹树默认收拢,点击箭头逐层展开,选择弹窗
 *   同样生效;生效时机 D4 = 下一次挂载(重进项目 / 重开弹窗),切换本身
 *   即时持久化到服务端;
 * - 「MCP / AI 接入」:入口卡片「访问令牌(Personal Access Token)」,
 *   整卡可点 → /settings/mcp(令牌管理本体收拢到二级页 SettingsMcpPage;
 *   旧注释「令牌管理只做 Web」随 App 端 PAT 管理上线作废)。
 * 入口:UserMenu「设置」/ PC AppHeader 齿轮图标 / 移动端「更多 → 设置」。
 */
import type { CSSProperties } from 'react';
import { useRef, useState } from 'react';
import { App, Button, Form, Input, Modal, Space, Switch, Tag } from 'antd';
import { useNavigate } from 'react-router-dom';
import { ChevronRight, FolderTree, KeyRound, Smartphone } from 'lucide-react';
import { errorMessage, retryAfterOf } from '../api/client';
import { useBindPhone, useMe, useSendPhoneCode } from '../api/hooks';
import { useUpdateUserPreferences, useUserPreferences } from '../api/prefs';
import { SendCodeButton } from '../components/SendCodeButton';
import type { SendCodeButtonHandle } from '../components/SendCodeButton';
import { isValidPhone, normalizePhone } from '../lib/phone';
import { useCompactViewport } from '../lib/use-viewports';

/** 区块标题(照 TokensSection h2 惯例)。 */
function BlockTitle({ children }: { children: string }) {
  return (
    <h2 style={{ margin: 0, fontSize: 15, fontWeight: 500, color: 'var(--ms-ink)' }}>
      {children}
    </h2>
  );
}

export default function SettingsPage() {
  const navigate = useNavigate();
  const compact = useCompactViewport();
  const { message } = App.useApp();

  // F3:偏好读写走 api/prefs.ts 固定契约;乐观更新 + 失败回滚由 mutation 契约
  // 承担,这里只负责失败 Toast(Switch 值随缓存回滚自动回弹)。
  // 请求失败按 false(现状行为)兜底。
  const { prefs, isLoading } = useUserPreferences();
  const update = useUpdateUserPreferences();

  // 账号与安全(2026-11-20 方案 §6.4):当前手机号 + 绑定/换绑 Modal
  const { data: me } = useMe();
  const currentPhone = me?.phone ?? null;
  const sendCode = useSendPhoneCode();
  const bind = useBindPhone();
  const [phoneOpen, setPhoneOpen] = useState(false);
  const [form] = Form.useForm();
  const sendBtnRef = useRef<SendCodeButtonHandle>(null);

  const openPhoneModal = () => {
    form.resetFields(); // destroyOnHidden 卸载表单,重开前清掉上次残留输入
    setPhoneOpen(true);
  };

  // Modal 内「获取验证码」:前端先归一化再校验(后端为最终裁判);倒计时统一规则
  // =有 retry_after 才启动:429 冷却/配额、502(非 BUSINESS_LIMIT_CONTROL)启动;
  // 400 格式错、409 已被占用(后端已回滚冷却)不带 → 透文案不倒计时,按钮立即可再点
  const onSendCode = async () => {
    const p = normalizePhone(String(form.getFieldValue('phone') ?? ''));
    if (!isValidPhone(p)) {
      message.error('请先输入正确的新手机号');
      return;
    }
    try {
      const res = await sendCode.mutateAsync({ phone: p });
      if (res.retry_after > 0) sendBtnRef.current?.start(res.retry_after);
    } catch (err) {
      message.error(errorMessage(err, '发送失败,请稍后重试'));
      const ra = retryAfterOf(err);
      if (ra > 0) sendBtnRef.current?.start(ra);
    }
  };

  const onBind = async () => {
    try {
      const v = await form.validateFields();
      const p = normalizePhone(String(v.phone ?? ''));
      await bind.mutateAsync({ phone: p, code: String(v.code ?? '').trim() });
      message.success(currentPhone ? '手机号已更换' : '手机号已绑定');
      setPhoneOpen(false); // ['me'] 失效由 useBindPhone onSuccess 承担
    } catch (e) {
      // 表单行内校验失败静默;409 并发占用 / 400 码错·过期 / 429 作废透 detail
      if ((e as { errorFields?: unknown }).errorFields) return;
      message.error(errorMessage(e, currentPhone ? '更换手机失败' : '绑定手机失败'));
    }
  };

  // 卡片基底(照 AdminStatsPanelPage 模块卡片:图标 + 标题 + 描述 + 右侧元素)
  const cardStyle: CSSProperties = {
    display: 'flex', alignItems: 'center', gap: 14, width: '100%',
    padding: compact ? '14px 16px' : '16px 20px',
    background: 'var(--ms-surface)',
    border: '1px solid var(--ms-hairline)',
    borderRadius: 'var(--ms-radius-md)',
  };
  const iconBoxStyle: CSSProperties = {
    display: 'grid', placeItems: 'center', width: 40, height: 40, flexShrink: 0,
    background: 'var(--ms-accent-soft)', borderRadius: 'var(--ms-radius-sm)',
    color: 'var(--ms-accent)',
  };
  const titleStyle: CSSProperties = {
    display: 'block', fontSize: 14.5, fontWeight: 500, color: 'var(--ms-ink)',
  };
  const descStyle: CSSProperties = {
    display: 'block', marginTop: 3, fontSize: 12, lineHeight: 1.5,
    color: 'var(--ms-ink-muted)',
  };

  return (
    <div className="ms-enter">
      {/* 页头(照 AdminStatsPanelPage 惯例) */}
      <div style={{ marginBottom: 'var(--ms-sp-xl)' }}>
        <h1 style={{
          margin: 0, fontFamily: 'var(--ms-font-display)',
          fontSize: 32, fontWeight: 500, letterSpacing: '-0.02em',
          color: 'var(--ms-ink)', lineHeight: 1.1,
        }}>设置</h1>
        <p style={{ margin: '8px 0 0', fontSize: 13, color: 'var(--ms-ink-muted)' }}>
          账号偏好与 MCP / AI 客户端接入
        </p>
      </div>

      {/* 「账号与安全」区块(2026-11-20 方案 §6.4):置于「偏好」之上 */}
      <section style={{ marginBottom: 'var(--ms-sp-lg)' }}>
        <BlockTitle>账号与安全</BlockTitle>
        <div style={{ ...cardStyle, marginTop: 12, maxWidth: 640 }}>
          <span style={iconBoxStyle}>
            <Smartphone size={20} strokeWidth={1.8} />
          </span>
          <span style={{ flex: 1, minWidth: 0 }}>
            <span style={titleStyle}>手机号</span>
            <span style={descStyle}>
              绑定后可用于短信找回密码;换绑即覆盖旧号,旧手机号立即失效。
            </span>
          </span>
          <span style={{ display: 'flex', alignItems: 'center', gap: 12, flexShrink: 0 }}>
            {currentPhone ? (
              <span style={{
                fontFamily: 'var(--ms-font-mono)', fontSize: 13.5, color: 'var(--ms-ink)',
              }}>{currentPhone}</span>
            ) : (
              // 未绑定:灰色 Tag(antd default 即灰)
              <Tag color="default" style={{ margin: 0 }}>未绑定</Tag>
            )}
            <Button size="small" onClick={openPhoneModal}>
              {currentPhone ? '更换手机' : '绑定手机'}
            </Button>
          </span>
        </div>
      </section>

      {/* 「偏好」区块(F3):默认收拢全部文件夹 */}
      <section style={{ marginBottom: 'var(--ms-sp-lg)' }}>
        <BlockTitle>偏好</BlockTitle>
        <div style={{ ...cardStyle, marginTop: 12, maxWidth: 640 }}>
          <span style={iconBoxStyle}>
            <FolderTree size={20} strokeWidth={1.8} />
          </span>
          <span style={{ flex: 1, minWidth: 0 }}>
            <span style={titleStyle}>默认收拢全部文件夹</span>
            <span style={descStyle}>
              开启后进入项目时所有文件夹树默认收拢,点击箭头逐层展开;对选择弹窗同样生效。
              切换后重新进入项目 / 打开弹窗时生效。
            </span>
          </span>
          <Switch
            checked={prefs?.folder_tree_default_collapsed ?? false}
            loading={isLoading || update.isPending}
            onChange={(checked) => {
              update.mutate(
                { folder_tree_default_collapsed: checked },
                { onError: (e) => message.error(errorMessage(e, '保存失败,请稍后重试')) },
              );
            }}
          />
        </div>
      </section>

      {/* 「MCP / AI 接入」区块(F1):入口卡片,整卡可点(照 AdminStatsPanelPage 模块卡片) */}
      <section>
        <BlockTitle>MCP / AI 接入</BlockTitle>
        <button
          onClick={() => navigate('/settings/mcp')}
          style={{
            ...cardStyle, marginTop: 12, maxWidth: 640,
            textAlign: 'left', cursor: 'pointer', fontFamily: 'inherit',
            transition: 'background var(--ms-dur-fast) var(--ms-ease)',
          }}
          onMouseEnter={e => (e.currentTarget.style.background = 'var(--ms-hairline-soft)')}
          onMouseLeave={e => (e.currentTarget.style.background = 'var(--ms-surface)')}
        >
          <span style={iconBoxStyle}>
            <KeyRound size={20} strokeWidth={1.8} />
          </span>
          <span style={{ flex: 1, minWidth: 0 }}>
            <span style={titleStyle}>访问令牌(Personal Access Token)</span>
            <span style={descStyle}>
              创建与管理 MCP / AI 客户端使用的个人访问令牌;令牌等同账号级全权限凭证
            </span>
          </span>
          <ChevronRight size={16} strokeWidth={1.8} style={{ color: 'var(--ms-ink-subtle)', flexShrink: 0 }} />
        </button>
      </section>

      {/* 绑定 / 换绑 Modal(2026-11-20 方案 §6.4):归一化预校验 + 验证码 + 倒计时按钮 */}
      <Modal
        title={currentPhone ? '更换手机' : '绑定手机'}
        open={phoneOpen}
        onCancel={() => setPhoneOpen(false)}
        onOk={onBind}
        okText={currentPhone ? '确认更换' : '确认绑定'}
        confirmLoading={bind.isPending}
        destroyOnHidden
        maskClosable={!bind.isPending}
      >
        {currentPhone && (
          <p style={{ margin: '0 0 16px', fontSize: 13, color: 'var(--ms-ink-muted)' }}>
            当前手机号:{currentPhone}
          </p>
        )}
        <Form form={form} layout="vertical">
          <Form.Item
            name="phone"
            label="新手机号"
            rules={[
              { required: true, message: '请输入新手机号' },
              {
                // 前端先归一化再校验(+86/连字符/点号/空格不拦),与后端 D5 同口径
                validator: (_rule, value: string | undefined) =>
                  isValidPhone(normalizePhone(value ?? ''))
                    ? Promise.resolve()
                    : Promise.reject(new Error('手机号格式不正确')),
              },
            ]}
          >
            <Input placeholder="支持 +86 / 连字符 / 空格" inputMode="tel" maxLength={20} />
          </Form.Item>
          <Form.Item label="短信验证码" required style={{ marginBottom: 8 }}>
            <Space.Compact style={{ width: '100%' }}>
              <Form.Item
                name="code"
                noStyle
                rules={[{ required: true, message: '请输入 6 位验证码' }]}
              >
                <Input placeholder="6 位字母数字" maxLength={6} inputMode="text"
                       style={{ letterSpacing: '0.3em' }} />
              </Form.Item>
              <SendCodeButton
                ref={sendBtnRef}
                loading={sendCode.isPending}
                onClick={onSendCode}
              />
            </Space.Compact>
          </Form.Item>
        </Form>
      </Modal>
    </div>
  );
}
