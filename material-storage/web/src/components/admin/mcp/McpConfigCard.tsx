/**
 * MCP 通道与配额卡片(/admin/mcp-settings)。
 *
 * - 独立开关承载「禁用」(滑杆合法域 1~8 不含 0;关闭时滑杆置灰 —— D6);
 * - 四个数值同时提供滑杆 + 数字输入,合法域与后端 McpSettingsIn 一致:
 *   max_concurrency 1~8、per_token_concurrency 1~8 且 ≤ max_concurrency、
 *   per_token_rpm 1~450、per_ip_rpm 1~900 且 ≥ 2 × per_token_rpm;
 * - 跨字段冲突前端先给可读提示(Field 级 validator),后端 422 兜底:
 *   errorMessage 会把 FastAPI 的 detail 数组拼成一句话;
 * - PUT 为整体覆盖、最后写赢(不做乐观锁);保存成功后失效重取配置与指标。
 */
import { Alert, App, Button, Form, InputNumber, Slider, Switch, Tag } from 'antd';
import { RotateCcw, Save } from 'lucide-react';
import { useEffect } from 'react';
import { errorMessage } from '../../../api/client';
import { useUpdateMcpSettings } from '../../../api/hooks';
import type { McpChannelConfig, McpSettingsOut } from '../../../api/types';

/** 只取配置键(丢弃指标字段),用于表单初值与「重置」。 */
const pickConfig = (s: McpChannelConfig): McpChannelConfig => ({
  enabled: s.enabled,
  max_concurrency: s.max_concurrency,
  per_token_concurrency: s.per_token_concurrency,
  per_token_rpm: s.per_token_rpm,
  per_ip_rpm: s.per_ip_rpm,
});

/** 滑杆 + 数字输入组合控件(Form.Item 注入 value/onChange)。 */
function NumSlider({ value, onChange, min, max, disabled, id }: {
  value?: number;
  onChange?: (v: number) => void;
  min: number;
  max: number;
  disabled?: boolean;
  id?: string;
}) {
  const v = typeof value === 'number' ? value : min;
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
      <Slider
        min={min}
        max={max}
        value={v}
        disabled={disabled}
        onChange={(n) => onChange?.(n)}
        style={{ flex: 1, margin: '0 4px' }}
      />
      <InputNumber
        id={id}
        min={min}
        max={max}
        precision={0}
        value={v}
        disabled={disabled}
        onChange={(n) => onChange?.(n ?? min)}
        style={{ width: 84 }}
      />
    </div>
  );
}

export function McpConfigCard({ settings }: { settings: McpSettingsOut }) {
  const [form] = Form.useForm<McpChannelConfig>();
  const update = useUpdateMcpSettings();
  const { message } = App.useApp();
  // 未就绪时用服务端值兜底(Form.useWatch 首帧为 undefined)
  const enabled = Form.useWatch('enabled', form) ?? settings.enabled;

  // 服务端值到达 / 保存后重取时回填表单(手动「刷新」也会回到服务端最新值)
  useEffect(() => {
    form.setFieldsValue(pickConfig(settings));
  }, [form, settings]);

  const submit = async () => {
    try {
      const v = await form.validateFields();
      await update.mutateAsync({
        enabled: !!v.enabled,
        max_concurrency: v.max_concurrency,
        per_token_concurrency: v.per_token_concurrency,
        per_token_rpm: v.per_token_rpm,
        per_ip_rpm: v.per_ip_rpm,
      });
      message.success('MCP 通道设置已保存');
    } catch (e) {
      // 表单校验失败的错误已挂在字段下,不再弹全局错误
      if ((e as { errorFields?: unknown }).errorFields) return;
      message.error(errorMessage(e, '保存失败'));
    }
  };

  const reset = () => form.setFieldsValue(pickConfig(settings));

  return (
    <section style={{
      background: 'var(--ms-surface)',
      border: '1px solid var(--ms-hairline)',
      borderRadius: 'var(--ms-radius-md)',
      padding: '16px 20px',
    }}>
      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 12, flexWrap: 'wrap' }}>
        <div style={{ flex: 1, minWidth: 220 }}>
          <h2 style={{ margin: 0, fontSize: 15, fontWeight: 500, color: 'var(--ms-ink)' }}>
            通道与配额
          </h2>
          <p style={{ margin: '4px 0 0', fontSize: 11.5, color: 'var(--ms-ink-subtle)' }}>
            仅作用于 PAT(令牌)请求;关闭通道即禁用 MCP。保存为整体覆盖,并发修改最后写赢。
          </p>
        </div>
        <Tag color={enabled ? 'green' : 'default'} style={{ marginInlineEnd: 0 }}>
          {enabled ? '通道已开启' : '通道已关闭'}
        </Tag>
      </div>

      <Form
        form={form}
        layout="vertical"
        initialValues={pickConfig(settings)}
        style={{ marginTop: 16 }}
      >
        <Form.Item
          name="enabled"
          label="MCP 通道开关"
          valuePropName="checked"
          style={{ marginBottom: 12 }}
          extra="默认关闭(安全默认);关闭时全部令牌请求 403,不影响网页 / App 的会话请求"
        >
          <Switch checkedChildren="开启" unCheckedChildren="关闭" />
        </Form.Item>

        {!enabled && (
          <Alert
            type="warning"
            showIcon
            style={{ marginBottom: 16 }}
            message="通道当前关闭"
            description="配额滑杆在关闭期间置灰;打开开关并保存后生效(单 worker 且 Redis 写成功时 ≤5s,Redis 与 DB 双失败最坏 65s)。"
          />
        )}

        <Form.Item
          name="max_concurrency"
          label="全局在途并发上限(max_concurrency)"
          rules={[{ required: true, type: 'number', min: 1, max: 8, message: '合法域 1~8' }]}
          extra="默认 8。受数据库连接池(pool 30)约束:峰值约为 3× 并发,上调前须同步评估 pool_size。"
        >
          <NumSlider min={1} max={8} disabled={!enabled} />
        </Form.Item>

        <Form.Item
          name="per_token_concurrency"
          label="每令牌在途并发上限(per_token_concurrency)"
          dependencies={['max_concurrency']}
          rules={[
            { required: true, type: 'number', min: 1, max: 8, message: '合法域 1~8' },
            ({ getFieldValue }) => ({
              validator: (_rule, value) => {
                const max = getFieldValue('max_concurrency');
                return typeof value === 'number' && typeof max === 'number' && value > max
                  ? Promise.reject(new Error('不能大于全局并发上限'))
                  : Promise.resolve();
              },
            }),
          ]}
          extra="默认 4,且不能大于全局上限;用于用户间公平,防单个 agent 占满全局名额。"
        >
          <NumSlider min={1} max={8} disabled={!enabled} />
        </Form.Item>

        <Form.Item
          name="per_token_rpm"
          label="每令牌每分钟请求上限(per_token_rpm)"
          rules={[{ required: true, type: 'number', min: 1, max: 450, message: '合法域 1~450' }]}
          extra="默认 120(约 2 请求/秒)。上限 450 由「2× ≤ per_ip_rpm 900」反推。"
        >
          <NumSlider min={1} max={450} disabled={!enabled} />
        </Form.Item>

        <Form.Item
          name="per_ip_rpm"
          label="前置 IP 每分钟请求上限(per_ip_rpm)"
          dependencies={['per_token_rpm']}
          rules={[
            { required: true, type: 'number', min: 1, max: 900, message: '合法域 1~900' },
            ({ getFieldValue }) => ({
              validator: (_rule, value) => {
                const rpm = getFieldValue('per_token_rpm');
                if (typeof value !== 'number' || typeof rpm !== 'number') return Promise.resolve();
                return value < 2 * rpm
                  ? Promise.reject(new Error(`需 ≥ 2 × 每令牌 RPM(当前至少 ${2 * rpm})`))
                  : Promise.resolve();
              },
            }),
          ]}
          extra="默认 600。保证同一出口至少容纳 2 个满速单令牌 agent;与边缘 nginx limit_req 15r/s 对齐。"
        >
          <NumSlider min={1} max={900} disabled={!enabled} />
        </Form.Item>
      </Form>

      <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
        <span style={{ fontSize: 11.5, color: 'var(--ms-ink-subtle)', flex: 1, minWidth: 200 }}>
          跨字段规则由后端 422 最终 enforce;前端同一套规则先给出可读提示。
        </span>
        <Button icon={<RotateCcw size={13} strokeWidth={2} />} onClick={reset}>
          重置
        </Button>
        <Button
          type="primary"
          icon={<Save size={13} strokeWidth={2} />}
          loading={update.isPending}
          onClick={submit}
        >
          保存设置
        </Button>
      </div>
    </section>
  );
}
