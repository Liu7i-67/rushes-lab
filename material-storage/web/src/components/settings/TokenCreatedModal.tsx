/**
 * 令牌创建成功弹窗 — 明文唯一一次展示(/settings)。
 *
 * D2:后端只在 POST 响应回显一次明文并带 `Cache-Control: no-store`;本弹窗
 * 关闭后上层立即丢弃 token 对象(不写 localStorage / 不进 react-query 缓存)。
 * 因此关闭方式收窄到页脚按钮:X / 遮罩 / Esc 全部禁用,避免误触后无法找回。
 *
 * 2026-10-31 追加:MCP 使用说明(地址 + 客户端配置示例 + 给 AI 的提示词),
 * 一键复制整段说明;说明里含令牌明文,与弹窗同生命周期、不落任何存储。
 */
import { Alert, App, Button, Modal } from 'antd';
import dayjs from 'dayjs';
import { Copy, KeyRound } from 'lucide-react';
import { useMemo } from 'react';
import { copyToClipboard } from '../../utils/copy';
import type { PatTokenCreated } from '../../api/types';

/** 按当前访问入口生成说明文本(MCP 地址 = 当前 origin + /mcp)。 */
function buildMcpGuide(token: PatTokenCreated): string {
  const origin = window.location.origin;
  const url = `${origin}/mcp`;
  const bearer = `Bearer ${token.token}`;
  return `【素材库 MCP 配置】
MCP 地址：${url}
认证头：Authorization: ${bearer}
传输：Streamable HTTP（单副本；服务重启后客户端需重新 initialize）

【客户端配置示例（支持 HTTP MCP 的客户端；字段名以客户端文档为准）】
{
  "mcpServers": {
    "material-storage": {
      "type": "http",
      "url": "${url}",
      "headers": {
        "Authorization": "${bearer}"
      }
    }
  }
}

【给 AI 的使用提示】
你是素材库（Material Storage）助手，已通过上面的 MCP 地址与令牌接入；身份=令牌所属用户本人，权限与网页登录一致。
挑素材主路径：先 search_assets 搜索，再 get_thumbnail 看缩略图（先 size="small" 看构图，需要细节再 size="large"）。
下载：get_download_url 返回 15 分钟有效的直链，请由客户端自行 HTTP GET 取字节，勿反复续签。
上传：create_upload → 客户端 PUT 直传（URL 15 分钟内有效，ETag 取自 PUT 响应头）→ complete_upload；单文件 ≤5GiB，同文件夹同名会 409。
complete_upload 超时后先 search_assets / list_files 确认资产是否已入库，再决定重试或 abort_upload。

【自检（可选）】
curl -H "Authorization: ${bearer}" ${origin}/api/v1/auth/me`;
}

export function TokenCreatedModal({ token, onClose }: {
  token: PatTokenCreated | null;
  onClose: () => void;
}) {
  const { message } = App.useApp();
  const guide = useMemo(() => (token ? buildMcpGuide(token) : ''), [token]);

  const copy = () => {
    if (!token) return;
    if (copyToClipboard(token.token)) message.success('令牌已复制');
    else message.error('复制失败,请手动选中复制');
  };

  const copyGuide = () => {
    if (!guide) return;
    if (copyToClipboard(guide)) message.success('使用说明已复制');
    else message.error('复制失败,请手动选中复制');
  };

  return (
    <Modal
      title="令牌已创建"
      open={!!token}
      onCancel={onClose}
      closable={false}
      maskClosable={false}
      keyboard={false}
      width={680}
      styles={{ body: { maxHeight: '68vh', overflowY: 'auto' } }}
      footer={<Button type="primary" onClick={onClose}>我已保存,关闭</Button>}
    >
      <Alert
        type="warning"
        showIcon
        style={{ marginBottom: 16 }}
        message="这是令牌明文的唯一一次展示,关闭后无法再次查看"
        description="服务端只保存 SHA-256 哈希,无法找回。本响应带 Cache-Control: no-store,浏览器不会缓存。请立即复制并妥善保管。"
      />

      <div style={{
        display: 'flex', alignItems: 'center', gap: 8,
        padding: '12px 14px', background: 'var(--ms-canvas)',
        border: '1px solid var(--ms-hairline)', borderRadius: 'var(--ms-radius-sm)',
      }}>
        <KeyRound size={15} strokeWidth={1.8}
                  style={{ color: 'var(--ms-ink-muted)', flexShrink: 0 }} />
        <code style={{
          flex: 1, fontFamily: 'var(--ms-font-mono)', fontSize: 14,
          color: 'var(--ms-ink)', letterSpacing: '0.03em',
          overflowWrap: 'anywhere',
        }}>{token?.token}</code>
        <Button size="small" icon={<Copy size={12} strokeWidth={1.8} />} onClick={copy}>
          复制
        </Button>
      </div>

      {/* MCP 使用说明:地址/配置示例/AI 提示词一次给全,整段可一键复制 */}
      <div style={{
        display: 'flex', alignItems: 'center', justifyContent: 'space-between',
        gap: 8, marginTop: 16, marginBottom: 8,
      }}>
        <span style={{ fontSize: 13, fontWeight: 600 }}>MCP 使用说明</span>
        <Button size="small" icon={<Copy size={12} strokeWidth={1.8} />} onClick={copyGuide}>
          复制使用说明
        </Button>
      </div>
      <pre style={{
        margin: 0, padding: '12px 14px', maxHeight: 260, overflow: 'auto',
        background: 'var(--ms-canvas)', border: '1px solid var(--ms-hairline)',
        borderRadius: 'var(--ms-radius-sm)', fontFamily: 'var(--ms-font-mono)',
        fontSize: 12, lineHeight: 1.7, color: 'var(--ms-ink)',
        whiteSpace: 'pre-wrap', overflowWrap: 'anywhere',
      }}>{guide}</pre>
      <div style={{ marginTop: 8, fontSize: 12, color: 'var(--ms-ink-muted)' }}>
        使用说明包含令牌明文,请勿粘贴到公开渠道;关闭本弹窗后无法再次查看。
      </div>

      <div style={{ marginTop: 12, fontSize: 12, color: 'var(--ms-ink-muted)', lineHeight: 1.9 }}>
        <div>名称:{token?.name}</div>
        <div>前缀:<span className="ms-mono">{token?.token_prefix}</span>(列表中以此识别)</div>
        <div>有效期至:{token ? dayjs(token.expires_at).format('YYYY-MM-DD HH:mm') : '—'}</div>
      </div>
    </Modal>
  );
}
