/**
 * 创建访问令牌弹窗(/settings)。
 *
 * - 名称 + 有效期天数(1~365,默认 90;D3);
 * - 每账号最多 5 个活跃令牌(D2):达到上限时禁用提交并给吊销引导,后端仍 enforce;
 * - 创建成功不在此弹窗回显明文 —— 交给 TokenCreatedModal(唯一一次展示语义),
 *   本弹窗只负责把创建结果抛给上层。
 * - 错误提示走 errorMessage:兼容 FastAPI 422 的 detail 数组与业务字符串 detail。
 */
import { Alert, App, Form, Input, InputNumber, Modal } from 'antd';
import { errorMessage } from '../../api/client';
import { useCreateToken } from '../../api/hooks';
import type { PatTokenCreated } from '../../api/types';

const DEFAULT_EXPIRES_IN_DAYS = 90;
const MAX_ACTIVE_TOKENS = 5;

interface FormValues {
  name: string;
  expires_in_days: number;
}

export function CreateTokenModal({ open, onClose, activeCount, onCreated }: {
  open: boolean;
  onClose: () => void;
  /** 当前活跃令牌数(用于展示 N/5 与上限禁用;后端仍会复核)。 */
  activeCount: number;
  onCreated: (token: PatTokenCreated) => void;
}) {
  const [form] = Form.useForm<FormValues>();
  const create = useCreateToken();
  const { message } = App.useApp();
  const full = activeCount >= MAX_ACTIVE_TOKENS;

  const close = () => {
    form.resetFields();
    onClose();
  };

  const submit = async () => {
    try {
      const v = await form.validateFields();
      const out = await create.mutateAsync({
        name: v.name.trim(),
        expires_in_days: v.expires_in_days,
      });
      form.resetFields();
      onCreated(out);
    } catch (e) {
      // antd 表单校验失败不算业务错误(错误已挂在字段下)
      if ((e as { errorFields?: unknown }).errorFields) return;
      message.error(errorMessage(e, '创建令牌失败'));
    }
  };

  return (
    <Modal
      title="创建访问令牌"
      open={open}
      onCancel={close}
      onOk={submit}
      okText="创建令牌"
      cancelText="取消"
      confirmLoading={create.isPending}
      okButtonProps={{ disabled: full }}
      // 创建请求进行中禁止关闭:此时关掉弹窗会让「明文只回显一次」的响应无处展示
      closable={!create.isPending}
      maskClosable={!create.isPending}
      keyboard={!create.isPending}
      cancelButtonProps={{ disabled: create.isPending }}
      destroyOnHidden
    >
      {/* D15 强制文案:创建页必须明示令牌的全权限与内网明文 http 风险 */}
      <Alert
        type="warning"
        showIcon
        style={{ marginBottom: 16 }}
        message="令牌=账号级全权限凭证,等同你的密码;内网入口为明文 http,勿配置到不可信机器"
        description="持有令牌即可调用本账号可访问的全部 API(含上传与下载)。请勿粘贴到聊天工具、截图或代码仓库。"
      />

      {full && (
        <Alert
          type="error"
          showIcon
          style={{ marginBottom: 16 }}
          message={`已达活跃令牌上限(${MAX_ACTIVE_TOKENS} 个)`}
          description="请先在列表中吊销不再使用的令牌,再创建新的。"
        />
      )}

      <Form
        form={form}
        layout="vertical"
        initialValues={{ expires_in_days: DEFAULT_EXPIRES_IN_DAYS }}
      >
        <Form.Item
          name="name"
          label="名称"
          rules={[
            { required: true, whitespace: true, message: '请填写令牌名称' },
            { max: 128, message: '最多 128 个字符' },
          ]}
          extra="用于在令牌列表中识别用途,例如「我的 ZCode」"
        >
          <Input placeholder="我的 ZCode" autoFocus maxLength={128} />
        </Form.Item>

        <Form.Item
          name="expires_in_days"
          label="有效期(天)"
          rules={[
            { required: true, message: '请填写有效期' },
            { type: 'number', min: 1, max: 365, message: '有效期须为 1~365 天' },
          ]}
          extra={`默认 ${DEFAULT_EXPIRES_IN_DAYS} 天;到期后令牌立即失效,也可随时吊销`}
        >
          <InputNumber
            min={1}
            max={365}
            precision={0}
            addonAfter="天"
            style={{ width: '100%' }}
          />
        </Form.Item>

        <div style={{ fontSize: 12, color: 'var(--ms-ink-subtle)' }}>
          当前活跃令牌 <span className="ms-mono">{activeCount}</span> / {MAX_ACTIVE_TOKENS}
        </div>
      </Form>
    </Modal>
  );
}
