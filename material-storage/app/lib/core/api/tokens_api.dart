/// TokensApi — /api/v1/auth/tokens 族薄封装(2026-11-19 App 包A;契约
/// api/app/routers/auth_tokens.py 实码)。三端点均 session-only(cookie 通道
/// 天然兼容):POST 创建(明文只回显一次,201)、GET 列表(默认仅活跃行,
/// ?include_revoked=1 含历史)、DELETE 吊销(幂等 204;非本人/不存在 404)。
/// 每用户活跃令牌上限 5 由后端 enforce(409,detail 中文透传)。
library;

import '../../models/models.dart';
import 'ms_api.dart';

class TokensApi {
  TokensApi(this._api);

  final MsApi _api;

  /// 本人令牌列表(永不含明文;默认只回活跃行,含吊销/过期历史传
  /// [includeRevoked])。
  Future<List<PatToken>> listTokens({bool includeRevoked = false}) async {
    final r = await _api.http.get(
      '/api/v1/auth/tokens',
      queryParameters: {
        if (includeRevoked) 'include_revoked': 1,
      },
    );
    if (r.statusCode != 200) throw _api.err(r, '令牌列表加载失败');
    final rows = (r.data ?? const []) as List;
    return [
      for (final e in rows) PatToken.fromJson(e as Map<String, dynamic>),
    ];
  }

  /// 创建 PAT(201;[expiresInDays] 1~365、默认 90,后端 422 拦截越界)。
  /// 响应含明文 [PatTokenCreated.token]——**只此一次**,调用方展示后即丢弃。
  Future<PatTokenCreated> createToken({
    required String name,
    int expiresInDays = 90,
  }) async {
    final r = await _api.http.post(
      '/api/v1/auth/tokens',
      data: {'name': name, 'expires_in_days': expiresInDays},
    );
    if (r.statusCode != 201) throw _api.err(r, '创建令牌失败');
    return PatTokenCreated.fromJson(r.data as Map<String, dynamic>);
  }

  /// 吊销本人令牌(幂等 204:重复吊销/已吊销均 204,不再二次报错)。
  Future<void> revokeToken({required String id}) async {
    final r = await _api.http.delete('/api/v1/auth/tokens/$id');
    if (r.statusCode != 204) throw _api.err(r, '吊销令牌失败');
  }
}
