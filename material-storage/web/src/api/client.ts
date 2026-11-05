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
      // 邮箱账号方案 §6.5:找回密码两公开页(/forgot-password、/reset-password)匿名访问
      // 时 useMe 401 同样是预期响应,不豁免会整页跳登录死循环;
      // 其余页面 401(会话失效)→ 本地登录页。带 next 完整路径回业务前端
      // (注意 pathname 含 /ms-static/web basename,所以用 endsWith 判断)
      const path = window.location.pathname;
      const onAuthPage = path.endsWith('/login') || path.endsWith('/change-password')
        || path.endsWith('/dev-login')
        || path.endsWith('/forgot-password') || path.endsWith('/reset-password');
      if (!onAuthPage) {
        const next = encodeURIComponent(path + window.location.search + window.location.hash);
        window.location.href = `/ms-static/web/login?next=${next}`;
      }
    }
    return Promise.reject(err);
  }
);

/** axios 错误 → HTTP 状态码(非 axios 错误 / 网络错误返回 undefined)。
 *  邮箱绑定/找回密码链路的业务失败按 400/409/422/429/502/503 分支展示(方案 §6.2/§6.3)。 */
export function httpErrorStatus(err: unknown): number | undefined {
  return axios.isAxiosError(err) ? err.response?.status : undefined;
}

/** axios 错误 → Retry-After 响应头秒数(缺省/非法返回 undefined;axios 已把头名归一小写)。 */
export function retryAfterSeconds(err: unknown): number | undefined {
  if (!axios.isAxiosError(err)) return undefined;
  const raw = err.response?.headers?.['retry-after'];
  const n = typeof raw === 'string' ? Number(raw) : NaN;
  return Number.isFinite(n) && n > 0 ? Math.ceil(n) : undefined;
}

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
    // 其余非字符串/非数组 detail(如艺人账号内嵌 409 的结构化 {code,username,project_id})
    // 原样返回会被全局 mutationCache toast 渲染 → React「Objects are not valid as a
    // React child」崩溃;一律落到下方 fallback 文案(艺人账号方案 §4.1)
    if (err.response?.status) return `${fallback}(HTTP ${err.response.status})`;
    if (err.message) return err.message;
  }
  return fallback;
}
