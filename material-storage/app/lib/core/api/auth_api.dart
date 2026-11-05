/// AuthApi — /api/v1/auth 族薄封装(契约对齐 api/app/routers/auth.py 与
/// account_security.py / password_reset.py):
///   POST /local/login      {username,password} → Set-Cookie ms_session
///   GET  /me               → Me(含 must_change_password / email 等字段)
///   POST /logout           → 清 session cookie
///   POST /change-password  {old_password,new_password}(首登强制流 #149)
///   GET  /public-config    公开配置(邮箱账号方案 §5.8,登录页显隐依据)
///   POST /email/code|confirm|unbind        邮箱绑定/换绑/验证/解绑(session)
///   POST /password-reset/request|verify|confirm  找回密码(公开;App 只用
///       request 出口,verify/confirm 为契约完整封装,重置页落 Web SPA)
///
/// **新方法全部带 `Options(extra: {'noErrorReport': true})`**(方案 §7.3/
/// 钉子 37):502(SMTP 失败)/503(功能未开)必须在页面内以失败卡片呈现,
/// 不关标记会被 ms_api.err 交全局报错页整页跳 /error-report,永远看不到
/// 失败卡片。参照 assets_api.dart thumbnailUrl 的既有写法。
library;

import 'package:dio/dio.dart';

import '../../models/models.dart';
import 'ms_api.dart';

class AuthApi {
  AuthApi(this._api);

  final MsApi _api;

  Future<Me> login(String username, String password) async {
    final r = await _api.http.post('/api/v1/auth/local/login',
        data: {'username': username, 'password': password});
    if (r.statusCode != 200) throw _api.err(r, '登录失败');
    return me();
  }

  Future<Me> me() async {
    final r = await _api.http.get('/api/v1/auth/me');
    if (r.statusCode != 200) throw _api.err(r, '未登录或会话失效');
    return Me.fromJson(r.data as Map<String, dynamic>);
  }

  Future<void> logout() async {
    await _api.http.post('/api/v1/auth/logout');
  }

  Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
  }) async {
    final r = await _api.http.post('/api/v1/auth/change-password', data: {
      'old_password': oldPassword,
      'new_password': newPassword,
    });
    if (r.statusCode != 200) throw _api.err(r, '修改密码失败');
  }

  // ── 邮箱账号批次(方案 §5.8 契约总表;全部 noErrorReport)────────────────

  /// GET /auth/public-config(公开,高频轮询不写审计;登录页 _onReady
  /// fire-and-forget + 3s 短超时拉取,三态写 Session,§7.1)。
  Future<({bool emailAuthEnabled, bool passwordResetEnabled,
      int passwordMinLength})>
  publicConfig() async {
    final r = await _api.http.get(
      '/api/v1/auth/public-config',
      options: Options(extra: const {'noErrorReport': true}),
    );
    if (r.statusCode != 200) throw _api.err(r, '配置获取失败');
    final d = r.data as Map<String, dynamic>;
    return (
      emailAuthEnabled: (d['email_auth_enabled'] ?? false) as bool,
      passwordResetEnabled: (d['password_reset_enabled'] ?? false) as bool,
      passwordMinLength: (d['password_min_length'] ?? 8) as int,
    );
  }

  /// POST /auth/email/code(session;绑定/换绑/验证三态共用,§5.3.2)。
  /// 成功回脱敏目标邮箱与验证码有效期(弹层第二步展示用)。
  Future<({String maskedEmail, int expiresIn})> sendEmailCode({
    required String email,
    required String password,
  }) async {
    final r = await _api.http.post(
      '/api/v1/auth/email/code',
      data: {'email': email, 'password': password},
      options: Options(extra: const {'noErrorReport': true}),
    );
    if (r.statusCode != 200) throw _api.err(r, '验证码发送失败');
    final d = r.data as Map<String, dynamic>;
    return (
      maskedEmail: (d['masked_email'] ?? '') as String,
      expiresIn: (d['expires_in'] ?? 600) as int,
    );
  }

  /// POST /auth/email/confirm(session;6 位码确认,§5.3.3;session_version
  /// 不变,成功后页面经 session.restore() 刷新 Me)。
  Future<({String email, String action})> confirmEmailCode({
    required String code,
  }) async {
    final r = await _api.http.post(
      '/api/v1/auth/email/confirm',
      data: {'code': code},
      options: Options(extra: const {'noErrorReport': true}),
    );
    if (r.statusCode != 200) throw _api.err(r, '验证码确认失败');
    final d = r.data as Map<String, dynamic>;
    return (
      email: (d['email'] ?? '') as String,
      action: (d['action'] ?? '') as String,
    );
  }

  /// POST /auth/email/unbind(session;仅密码,**不依赖 mail_ready**,SMTP
  /// 关闭仍可用,§5.3.4)。
  Future<void> unbindEmail({required String password}) async {
    final r = await _api.http.post(
      '/api/v1/auth/email/unbind',
      data: {'password': password},
      options: Options(extra: const {'noErrorReport': true}),
    );
    if (r.statusCode != 200) throw _api.err(r, '解除绑定失败');
  }

  /// POST /auth/password-reset/request(公开;§5.4.2;400=邮箱未绑定、
  /// 429 带 Retry-After、502=发送失败、503=功能未开——页面内失败卡片)。
  Future<void> requestPasswordReset({required String email}) async {
    final r = await _api.http.post(
      '/api/v1/auth/password-reset/request',
      data: {'email': email},
      options: Options(extra: const {'noErrorReport': true}),
    );
    if (r.statusCode != 200) throw _api.err(r, '重置邮件发送失败');
  }

  /// POST /auth/password-reset/verify(公开,只读不消费;§5.4.3)。
  Future<({bool valid, String emailMasked, String expiresAt})>
  verifyResetToken({required String token}) async {
    final r = await _api.http.post(
      '/api/v1/auth/password-reset/verify',
      data: {'token': token},
      options: Options(extra: const {'noErrorReport': true}),
    );
    if (r.statusCode != 200) throw _api.err(r, '链接校验失败');
    final d = r.data as Map<String, dynamic>;
    return (
      valid: (d['valid'] ?? false) as bool,
      emailMasked: (d['email_masked'] ?? '') as String,
      expiresAt: (d['expires_at'] ?? '') as String,
    );
  }

  /// POST /auth/password-reset/confirm(公开;§5.4.4;成功即踢全部会话)。
  Future<void> resetPassword({
    required String token,
    required String newPassword,
  }) async {
    final r = await _api.http.post(
      '/api/v1/auth/password-reset/confirm',
      data: {'token': token, 'new_password': newPassword},
      options: Options(extra: const {'noErrorReport': true}),
    );
    if (r.statusCode != 200) throw _api.err(r, '密码重置失败');
  }
}
