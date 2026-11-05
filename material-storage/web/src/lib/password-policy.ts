/**
 * 密码策略(邮箱账号方案 §6.3)—— 改密页(ChangePasswordPage)与重置页
 * (ResetPasswordPage)共用的一份规则,镜像后端 local_auth.validate_password_policy:
 * ≥N 位 + 同时含字母 + 含数字。
 *
 * minLength 来自 GET /auth/public-config 的 password_min_length(后端可配);
 * 拉取失败 / 加载中(unknown)时两页各自回落 DEFAULT_PASSWORD_MIN_LENGTH。
 */

/** public-config 不可用时的回落值(与后端 AUTH_PASSWORD_MIN_LENGTH 默认一致)。 */
export const DEFAULT_PASSWORD_MIN_LENGTH = 8;

/** 组装密码策略正则:≥minLength 位,且同时含字母和数字。
 *  每次渲染按 minLength 新建(输入规则只在提交校验时执行,无热路径,可接受)。 */
export const buildPasswordRe = (minLength: number): RegExp =>
  new RegExp(`^(?=.*[A-Za-z])(?=.*\\d).{${minLength},}$`);

/** 输入框 placeholder / 校验失败的提示文案(与 buildPasswordRe 同源,勿手写分离)。 */
export const passwordPolicyHint = (minLength: number): string =>
  `至少 ${minLength} 位,且同时包含字母和数字`;
