/**
 * RenameFolderModal — 目录改名(W4,六项优化 2026-10-17)。
 * PATCH /api/v1/folders/{id} body {name};校验对齐后端 check_segment_name + 模板段名口径:
 * 非空、strip 后非空(拒首尾空白)、禁 `/` `\` 与 `.` `..`、≤255 字符。
 * 后端 D1-B 会重算子树 minio_prefix(不动物理对象),既有文件位置不受影响。
 */
import { App, Form, Input, Modal, Typography } from 'antd';
import { useRenameFolder } from '../api/hooks';
import { errorMessage } from '../api/client';
import type { Folder } from '../api/types';

interface Props {
  open: boolean;
  onClose: () => void;
  folder: Folder;
}

/** 段名校验(前端预检,后端 enforce 为准):非空 / strip 后非空 / 禁 / \ . .. / ≤255。*/
function validateSegmentName(_rule: unknown, value: string | undefined): Promise<void> {
  const s = value ?? '';
  if (!s.trim()) return Promise.reject(new Error('请输入文件夹名(不能为空或全空白)'));
  if (s !== s.trim()) return Promise.reject(new Error('首尾不能包含空白字符'));
  if (s.includes('/') || s.includes('\\')) return Promise.reject(new Error('不能包含 / 或 \\ 字符'));
  if (s === '.' || s === '..') return Promise.reject(new Error('不能使用 . 或 .. 作为文件夹名'));
  if (s.length > 255) return Promise.reject(new Error('不能超过 255 个字符'));
  return Promise.resolve();
}

export function RenameFolderModal({ open, onClose, folder }: Props) {
  const rename = useRenameFolder();
  const [form] = Form.useForm();
  const { message } = App.useApp();

  const submit = async () => {
    try {
      const v = await form.validateFields();
      const name = (v.name as string).trim();
      const f = await rename.mutateAsync({
        folder_id: folder.id,
        name,
        project_id: folder.project_id,
      });
      message.success(`文件夹已重命名为「${f.name}」`);
      onClose();
    } catch (e) {
      // 表单校验失败(errorFields)已在行内提示,静默;其余走错误 toast
      if ((e as { errorFields?: unknown }).errorFields) return;
      message.error(errorMessage(e, '重命名失败'));
    }
  };

  return (
    <Modal
      title="重命名文件夹"
      open={open}
      onCancel={onClose}
      okText="重命名"
      confirmLoading={rename.isPending}
      onOk={submit}
      destroyOnHidden
      maskClosable={false}
    >
      <Form form={form} layout="vertical" initialValues={{ name: folder.name }}>
        <Form.Item label="当前位置">
          <Typography.Text code style={{ fontSize: 12, wordBreak: 'break-all' }}>
            {folder.minio_prefix || '项目根'}
          </Typography.Text>
        </Form.Item>
        <Form.Item
          name="name"
          label="文件夹名"
          rules={[{ required: true, validator: validateSegmentName }]}
        >
          <Input placeholder="例:现场原片 / 第 3 次 / 精修" autoFocus maxLength={255} />
        </Form.Item>
        <Typography.Text type="secondary" style={{ fontSize: 12 }}>
          改名后目录路径与新上传文件的存储前缀同步更新;已上传文件本身不迁移、下载分享不受影响。
        </Typography.Text>
      </Form>
    </Modal>
  );
}
