/// ShareApi — /api/v1/share 族薄封装(B5 分享;契约 api/app/routers/share.py)。
/// ShareCreateIn 实况:expires_in_seconds(默认 86400,60s~30 天)+ requires_login
/// (默认 True);**无提取码/下载开关字段**,App requires_login 恒 true(web 硬编码)。
/// 4xx/5xx detail 透传由 [MsApi.err] 渲染(B9 起 validateStatus 全放行,5xx
/// 同走 `_api.err` 中文 fallback 路径,全 API 层统一兜底已收口)。
library;

import '../../models/models.dart';
import 'ms_api.dart';

class ShareApi {
  ShareApi(this._api);

  final MsApi _api;

  /// 有效期档位(web ShareModal TTL_OPTIONS 实况;默认选中 24 小时)。
  static const ttlOptions = <(String, int)>[
    ('1 小时', 3600),
    ('24 小时', 86400),
    ('7 天', 7 * 86400),
    ('30 天', 30 * 86400),
  ];

  /// 分享单资产;后端 enforce can_download(无权 403 detail 透传)。
  Future<ShareLink> shareAsset(String assetId, {required int expiresInSeconds}) =>
      _create('/api/v1/share/assets/$assetId', expiresInSeconds);

  /// 分享文件夹;后端 enforce can_view(403 detail 透传)。
  Future<ShareLink> shareFolder(String folderId, {required int expiresInSeconds}) =>
      _create('/api/v1/share/folders/$folderId', expiresInSeconds);

  Future<ShareLink> _create(String path, int expiresInSeconds) async {
    final r = await _api.http.post(path, data: {
      'expires_in_seconds': expiresInSeconds,
      'requires_login': true, // 恒 true(web 同款硬编码;短链默认需登录)
    });
    if (r.statusCode != 200) throw _api.err(r, '分享链接创建失败');
    return ShareLink.fromJson(r.data as Map<String, dynamic>);
  }
}
