import { Alert, App, Button } from 'antd';
import { useMemo, useState } from 'react';
import { useLocation } from 'react-router-dom';
import { detectInApp } from '../lib/inapp';
import { copyToClipboard } from '../utils/copy';

/**
 * 内置浏览器引导横幅 — 非阻断可关(内置浏览器里系统「能用但体验差」,
 * 阻断会把低配场景变成不可用,维护 modal 只留给真不可用场景)。
 * 挂在 BrowserRouter 下与 MaintenanceBanner 同层(不依赖路由),登录页/分享页全覆盖:
 * 分享链接正是在微信里点开的,是最主要的内置浏览器入口。
 * top 动态:常规路由 56(AppHeader 下沿悬浮,header 保持可交互);
 * 无 header 路由(登录/改密/dev-login,AppShell 提前 return 不渲染 header)降 12 贴顶。
 */
const NO_HEADER_ROUTES = new Set(['/login', '/change-password', '/dev-login']);
const DISMISSED_KEY = 'ms-inapp-tip-dismissed';

export function InAppBrowserTip() {
  const { message } = App.useApp();
  const { pathname } = useLocation();
  // UA 判定恒定,挂载后只算一次
  const detected = useMemo(() => detectInApp(), []);
  // 关闭持久化 sessionStorage:当次会话不再弹,新开标签页(新会话)重新提示
  const [dismissed, setDismissed] = useState(() => {
    try {
      return sessionStorage.getItem(DISMISSED_KEY) === '1';
    } catch {
      return false; // 隐私模式等存储不可用,退化为仅当次不弹
    }
  });

  // PC 端(含 MicroMessenger 但非 mobile)不弹:「用手机浏览器打开」引导对 PC 无意义
  if (!detected.isInApp || !detected.isMobile || dismissed) return null;

  // isMobile 下的 iOS/Android 简化区分(各 App 菜单项措辞不一,文案真机核对后可微调)
  const isIOSLike = /iPhone|iPad|Mac/i.test(navigator.userAgent);
  const guide = isIOSLike
    ? '点击右上角「…」,选择在 Safari 中打开;或复制链接后粘贴到浏览器'
    : '点击右上角「…」,选择「在浏览器打开」';

  const handleClose = () => {
    try {
      sessionStorage.setItem(DISMISSED_KEY, '1');
    } catch {
      // 存储不可用时仅当次渲染关闭,不阻断
    }
    setDismissed(true);
  };

  const handleCopy = () => {
    // 全站统一复制入口(内网纯 HTTP 非安全上下文,库内自动落 execCommand 兜底)
    if (!copyToClipboard(window.location.href)) {
      message.warning('复制失败,请长按地址栏手动复制');
    }
  };

  return (
    <Alert
      type="warning"
      showIcon
      closable
      onClose={handleClose}
      message={`当前在 ${detected.appName} 内置浏览器中打开,部分功能(下载/预览)可能不可用`}
      description={guide}
      action={
        <Button size="small" onClick={handleCopy}>
          复制链接
        </Button>
      }
      style={{
        position: 'fixed',
        top: NO_HEADER_ROUTES.has(pathname) ? 12 : 56,
        left: 0,
        right: 0,
        borderRadius: 0,
        zIndex: 'var(--ms-z-inapp-tip, 55)',
      }}
    />
  );
}
