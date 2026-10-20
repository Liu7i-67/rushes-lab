/// AuthApi — /api/v1/auth 族薄封装(契约对齐 api/app/routers/auth.py):
///   POST /local/login      {username,password} → Set-Cookie ms_session
///   GET  /me               → Me(含 must_change_password 等闸门字段)
///   POST /logout           → 清 session cookie
///   POST /change-password  {old_password,new_password}(首登强制流 #149)
library;

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
}
