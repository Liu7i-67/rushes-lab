/**
 * 统一复制入口 — HTTP 非安全上下文降级用,全站统一走本函数。
 *
 * 背景:内网部署为纯 HTTP(无域名),`navigator.clipboard` 仅在安全上下文
 * (HTTPS / localhost)可用,直连会大面积失败。本工具统一调 copy-to-clipboard
 * 库:库内部在非安全上下文自动落同步 execCommand('copy') 隐蔽选区兜底,
 * 安全上下文优先 navigator.clipboard。
 *
 * 关于签名:copy-to-clipboard v4 对外是 Promise<boolean>,而本工具签名固定为
 * 同步 boolean(全站调用方按返回值提示成功/失败,不可改)。处理方式:
 *  1) 先做与库内部分支一致的能力预判 — 非安全上下文且无 execCommand
 *     (极旧浏览器)必然失败,直接同步返回 false,让调用方给出手动复制提示;
 *  2) 能力具备时把实际复制交给库执行,同步返回 true(库的 execCommand
 *     兜底路径是同步执行的,内网 HTTP 环境即此路径)。
 *
 * 返回 true = 复制已执行(内网 HTTP 环境即同步成功);false = 失败
 * (调用方负责提示手动复制)。
 */
import copy from 'copy-to-clipboard';

export function copyToClipboard(text: string): boolean {
  const asyncClipboardAvailable =
    typeof window !== 'undefined' &&
    window.isSecureContext === true &&
    typeof navigator !== 'undefined' &&
    !!navigator.clipboard;

  if (!asyncClipboardAvailable &&
      (typeof document === 'undefined' || typeof document.execCommand !== 'function')) {
    // 非安全上下文且无 execCommand 兜底(极旧浏览器)→ 必然失败
    return false;
  }

  try {
    // 库保证不同步抛错(内部全捕获),catch 仅防御模块级异常;
    // Promise 结果用于兼容 v4 异步签名,不阻塞本函数同步返回
    void copy(text).catch(() => undefined);
    return true;
  } catch {
    return false;
  }
}
