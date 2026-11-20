/// AuthApi — /api/v1/auth 族薄封装(契约对齐 api/app/routers/auth.py):
///   POST /local/login      {username,password} → Set-Cookie ms_session
///   GET  /me               → Me(含 must_change_password 等闸门字段)
///   POST /logout           → 清 session cookie
///   POST /change-password  {old_password,new_password}(首登强制流 #149)
///
/// 手机号绑定/短信找回密码四端点(契约见 §5.2 接口契约总表,错误 detail 一律
/// 中文字符串,statusCode != 200 判错惯例;retry_after 双通道钉死):
///   POST /account/phone/send-code        {phone} → 200 {retry_after}(登录态)
///   POST /account/phone/bind             {phone,code} → 200 {phone}(登录态;
///       400 格式/码错/过期;409 占用;429 码作废(不带 retry_after);503 未配置)
///   POST /auth/phone/reset/send-code     {phone} → 200 {retry_after}(公开;
///       400 含「无法发送验证码」= 未绑定/已禁用,不解释原因)
///   POST /auth/phone/reset/confirm       {phone,code} → 200 {username,email,
///       name,new_password}(一次性返回,不落日志)
/// retry_after 通道:200 响应体直接回值;非 200(429 冷却/配额、502)响应体
/// 形状 {"detail":"...","retry_after":n} → ApiException.raw['retry_after'] 读
/// (经 [retryAfterOf]),无该字段(码作废 429 / isv.BUSINESS_LIMIT_CONTROL
/// 502 / 409)不启动倒计时,调用方判 0 即不 start。
library;

import '../../models/models.dart';
import 'ms_api.dart';

/// retry_after 统一读取(200 响应体与 ApiException.raw 共用一条解析通道):
/// num/int 直取,String 容错解析;缺失/非法回 0(调用方 0 = 不启动倒计时)。
int retryAfterOf(Object? data) {
  if (data is Map) {
    final v = data['retry_after'];
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
  }
  return 0;
}

/// POST /auth/phone/reset/confirm 200 响应(一次性返回,不落日志):
/// [displayAccount] 按钉死优先级 username → email → name;[onlyName] =
/// username 与 email 皆空(仅 name)时,页面附「若显示名重复导致无法登录,
/// 请联系管理员」小字(§5.2 文案正本,双端同句)。
class PhoneResetResult {
  PhoneResetResult({
    this.username,
    this.email,
    required this.name,
    required this.newPassword,
  });

  factory PhoneResetResult.fromJson(Map<String, dynamic> j) => PhoneResetResult(
    username: (j['username'] as String?),
    email: (j['email'] as String?),
    name: (j['name'] ?? '') as String,
    newPassword: (j['new_password'] ?? '') as String,
  );

  final String? username;
  final String? email;
  final String name;
  final String newPassword;

  bool get onlyName =>
      (username == null || username!.isEmpty) &&
      (email == null || email!.isEmpty);

  String get displayAccount {
    final u = username;
    if (u != null && u.isNotEmpty) return u;
    final e = email;
    if (e != null && e.isNotEmpty) return e;
    return name;
  }
}

class AuthApi {
  AuthApi(this._api);

  final MsApi _api;

  Future<Me> login(String username, String password) async {
    final r = await _api.http.post(
      '/api/v1/auth/local/login',
      data: {'username': username, 'password': password},
    );
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
    final r = await _api.http.post(
      '/api/v1/auth/change-password',
      data: {'old_password': oldPassword, 'new_password': newPassword},
    );
    if (r.statusCode != 200) throw _api.err(r, '修改密码失败');
  }

  /// 发送绑定验证码(登录态;PAT 403 / 强制改密用户被既有 403 白名单拦下)。
  /// 200 → 冷却秒数(倒计时初值;0 = 不启动);400 格式 / 409 占用 / 429
  /// 冷却·配额 / 502 短信失败 / 503 未配置走 ApiException(detail 透传)。
  Future<int> sendPhoneBindCode(String phone) async {
    final r = await _api.http.post(
      '/api/v1/account/phone/send-code',
      data: {'phone': phone},
    );
    if (r.statusCode != 200) throw _api.err(r, '发送验证码失败');
    return retryAfterOf(r.data);
  }

  /// 绑定/换绑手机号(登录态,只凭验证码 D1)。200 → 归一化后的 phone;
  /// 400 格式/码错/「验证码已过期,请重新获取」/ 409 并发占用 / 429 码作废 /
  /// 503 未配置走 ApiException。
  Future<String> bindPhone(String phone, String code) async {
    final r = await _api.http.post(
      '/api/v1/account/phone/bind',
      data: {'phone': phone, 'code': code},
    );
    if (r.statusCode != 200) throw _api.err(r, '绑定手机号失败');
    final d = r.data;
    final bound = d is Map ? d['phone'] as String? : null;
    return bound ?? phone;
  }

  /// 忘记密码发码(公开端点)。200 → 冷却秒数;400 含「无法发送验证码」
  /// (未绑定/已禁用,原样透出不解释原因)/ 429 冷却·配额 / 502 短信失败 /
  /// 503 未配置走 ApiException。
  Future<int> sendPhoneResetCode(String phone) async {
    final r = await _api.http.post(
      '/api/v1/auth/phone/reset/send-code',
      data: {'phone': phone},
    );
    if (r.statusCode != 200) throw _api.err(r, '发送验证码失败');
    return retryAfterOf(r.data);
  }

  /// 忘记密码确认重置(公开端点;验码即原子消费,系统随机密码一次性返回)。
  /// 200 → [PhoneResetResult];400 码错/过期 / 429 码作废 / 503 未配置走
  /// ApiException。
  Future<PhoneResetResult> confirmPhoneReset(String phone, String code) async {
    final r = await _api.http.post(
      '/api/v1/auth/phone/reset/confirm',
      data: {'phone': phone, 'code': code},
    );
    if (r.statusCode != 200) throw _api.err(r, '重置密码失败');
    return PhoneResetResult.fromJson(r.data as Map<String, dynamic>);
  }
}
