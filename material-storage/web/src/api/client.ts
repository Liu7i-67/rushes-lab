/**
 * axios client — withCredentials 走 cookie session(prod);
 * VITE_DEV_USER_ID / localStorage 设置时附加 X-User-Id header(dev,backend env=dev 才接)。
 */
import axios, { AxiosError } from 'axios';

export const apiBase = (import.meta.env.VITE_API_BASE ?? '').replace(/\/$/, '');

const DEV_USER_KEY = 'ms_dev_user_id';
export const getDevUserId = (): string | null => {
  try { return localStorage.getItem(DEV_USER_KEY); } catch { return null; }
};
export const setDevUserId = (id: string | null) => {
  // 三元改 if/else:消除 no-unused-expressions,行为不变
  try { if (id) localStorage.setItem(DEV_USER_KEY, id); else localStorage.removeItem(DEV_USER_KEY); } catch { /* ignore */ }
};

export const http = axios.create({
  baseURL: apiBase,
  withCredentials: true,
  timeout: 30_000,
});

http.interceptors.request.use((config) => {
  const devId = getDevUserId() ?? (import.meta.env.VITE_DEV_USER_ID as string | undefined);
  if (devId) {
    config.headers = config.headers ?? {};
    (config.headers as Record<string, string>)['X-User-Id'] = devId;
  }
  return config;
});

http.interceptors.response.use(
  (r) => r,
  (err: AxiosError) => {
    if (err.response?.status === 401) {
      // #149: 认证页(本地登录 / 改密 / dev)自身的 401 是业务响应(如密码错误),不跳转;
      // 其余页面 401(会话失效)→ 本地登录页。带 next 完整路径回业务前端
      // (注意 pathname 含 /ms-static/web basename,所以用 endsWith 判断)
      // 2026-11-20: /forgot-password(短信找回密码)也是认证页,漏豁免会被 401 跳转打死
      const path = window.location.pathname;
      const onAuthPage = path.endsWith('/login') || path.endsWith('/change-password')
        || path.endsWith('/forgot-password') || path.endsWith('/dev-login');
      if (!onAuthPage) {
        const next = encodeURIComponent(path + window.location.search + window.location.hash);
        window.location.href = `/ms-static/web/login?next=${next}`;
      }
    }
    return Promise.reject(err);
  }
);

/** 从 axios error 抽 user-friendly message,优先取 detail。*/
export function errorMessage(err: unknown, fallback = '请求失败'): string {
  if (axios.isAxiosError(err)) {
    const d = err.response?.data as { detail?: unknown } | undefined;
    if (typeof d?.detail === 'string' && d.detail) return d.detail;
    // FastAPI 422(Pydantic v2)的 detail 是对象数组:取各条 msg 拼接成人话
    // (直塞对象给 message.error 会触发 React error #31 整树白屏,返回值必须恒为 string)
    if (Array.isArray(d?.detail)) {
      const msgs = d.detail
        .map((x) => (x && typeof x === 'object' && 'msg' in x ? String((x as { msg?: unknown }).msg) : ''))
        .filter(Boolean);
      if (msgs.length) return msgs.join('; ');
    }
    // 结构化 detail 对象:优先透出后端给的人类可读 message(百度备份 409/429 族
    // {code,message},如「该绑定排队任务已达上限」——此前被吞成兜底文案,用户看不到
    // 真实原因);无 message 字段的(艺人账号内嵌 409 的 {code,username,project_id})
    // 继续落 fallback——对象直塞全局 mutationCache toast 会触发 React
    // 「Objects are not valid as a React child」崩溃,返回值必须恒为 string
    if (d?.detail && typeof d.detail === 'object') {
      const m = (d.detail as { message?: unknown }).message;
      if (typeof m === 'string' && m) return m;
    }
    if (err.response?.status) return `${fallback}(HTTP ${err.response.status})`;
    if (err.message) return err.message;
  }
  return fallback;
}

/** axios 错误体顶层 retry_after(方案 §5.2;429/502 部分携带)。>0 有效秒数,无则 0。
 * (ForgotPasswordPage 与 SettingsPage 原各留一份逐字重复,与 errorMessage 同属
 * 「从 axios error 抽信息」的客户端层工具,收敛于此单一导出。) */
export function retryAfterOf(err: unknown): number {
  const ra = (err as { response?: { data?: { retry_after?: unknown } } })
    ?.response?.data?.retry_after;
  return typeof ra === 'number' && Number.isFinite(ra) && ra > 0 ? Math.floor(ra) : 0;
}
