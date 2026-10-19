/**
 * 内置浏览器(微信/企业微信/抖音等 webview)检测 — 纯函数零副作用。
 * 不参与布局切换(布局唯一判定源是 useCompactViewport);
 * 唯一使用点:InAppBrowserTip 引导横幅。
 *
 * 检测两层:inapp-spy 做基础判断,但其官方列表只有国际版(wechat/tiktok 等),
 * 不识别企业微信/抖音(aweme)/钉钉等国产 App — 叠加国产 UA token 补充表
 * 做精确归因与兜底:补充表命中即视为内置浏览器(DingTalk/Weibo 不在
 * inapp-spy 列表内),且补充表优先于 inapp-spy 归因(如企业微信 UA 同含
 * MicroMessenger,会被 inapp-spy 报成 wechat,以 wxwork 命中为准)。
 */
import InAppSpy from 'inapp-spy';

export interface InAppResult {
  isInApp: boolean;
  appName: string;   // 归因名:'微信' | '企业微信' | …(判定内置但未识别时'内置浏览器',非内置为空串)
  isMobile: boolean; // 仅移动端提示(PC 端「用手机浏览器打开」的引导无意义)
}

/** 国产 App UA token 补充表(不区分大小写)。QQ 用 `QQ/` 前缀避开 MQQBrowser — 那是 QQ 浏览器,属完整浏览器非内置。 */
const CN_SUPPLEMENTS: [RegExp, string][] = [
  // wxwork 须先于 micromessenger:企业微信 UA 两者同含,精确归因优先
  [/wxwork/i, '企业微信'],
  [/micromessenger/i, '微信'],
  [/aweme|douyin|bytedancewebview/i, '抖音'],
  [/QQ\//, 'QQ'],
  [/dingtalk/i, '钉钉'],
  [/weibo/i, '微博'],
];

export function detectInApp(): InAppResult {
  const ua = navigator.userAgent;
  const { isInApp: spyIsInApp } = InAppSpy();

  let appName = '';
  for (const [token, name] of CN_SUPPLEMENTS) {
    if (token.test(ua)) {
      appName = name;
      break;
    }
  }

  return {
    isInApp: spyIsInApp || appName !== '',
    appName: appName || (spyIsInApp ? '内置浏览器' : ''),
    // iPadOS 13+ 伪装 Mac UA(maxTouchPoints > 1),同 ua.ts isIOS 思路
    isMobile: /Android|iPhone|iPad|Mobile/i.test(ua)
      || (/Mac/.test(ua) && navigator.maxTouchPoints > 1),
  };
}
