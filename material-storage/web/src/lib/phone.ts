/**
 * 手机号归一化与格式校验(2026-11-20 方案 D5 前端同款;后端 normalize_phone 为准)。
 *
 * ForgotPasswordPage 与 SettingsPage 两页共用:仅做输入容错的**前端预校验**
 * (send-code / bind 提交前拦明显格式错),+86 / 86 前缀、空格 / 连字符 / 点号
 * 一律先归一化再校验,不拦不报错;reset/confirm 提交不做前端归一化拦截
 * (后端统一处理)。
 */

/** D5 归一化:strip 空格/连字符/点号 → 去 `+86` / `86` 前缀(国内手机号不以 8 开头,无歧义)。*/
export function normalizePhone(raw: string): string {
  const s = raw.replace(/[\s\-.]/g, '');
  return s.replace(/^\+86/, '').replace(/^86/, '');
}

/** D5 校验:11 位国内手机号(1[3-9] 开头)。*/
export function isValidPhone(s: string): boolean {
  return /^1[3-9]\d{9}$/.test(s);
}
