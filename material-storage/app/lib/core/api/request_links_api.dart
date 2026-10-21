/// RequestLinksApi — POST /api/v1/request-links 薄封装(B9 §8.11;契约
/// api/app/routers/request_links.py CreateIn/CreateOut 实码):
/// target_type ∈ sensitive_folder/asset/project/folder;allowed_actions
/// ⊆ access/download(access 仅 sensitive_folder);receiver_user_id 可选
/// (users.id UUID,null=任意登录用户);ttl_seconds 60~30 天,默认 3 天。
/// 权限:system admin 或目标资源 can_admin,非 admin 403 detail 透传——
/// 入口显隐由调用侧闸门(项目页 my_roles 含 admin / 项目内 my_can_admin)。
library;

import '../../models/models.dart';
import 'ms_api.dart';

class RequestLinksApi {
  RequestLinksApi(this._api);

  final MsApi _api;

  /// 有效期档位(web RequestLinkCreateModal TTL_PRESETS 实况,默认 3 天)。
  static const ttlOptions = <(String, int)>[
    ('1 小时', 3600),
    ('1 天', 86400),
    ('3 天', 3 * 86400),
    ('7 天', 7 * 86400),
  ];

  Future<RequestLinkCreated> create({
    required String targetType,
    required String targetId,
    required List<String> allowedActions,
    String? receiverUserId,
    int? ttlSeconds,
  }) async {
    final r = await _api.http.post('/api/v1/request-links', data: {
      'target_type': targetType,
      'target_id': targetId,
      'allowed_actions': allowedActions,
      'receiver_user_id': ?receiverUserId,
      'ttl_seconds': ?ttlSeconds,
    });
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw _api.err(r, '生成申请链接失败');
    }
    return RequestLinkCreated.fromJson(r.data as Map<String, dynamic>);
  }
}
