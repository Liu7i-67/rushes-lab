/// ShareLink — POST /api/v1/share/{assets,folders}/{id} 契约
/// (api/app/routers/share.py ShareCreateOut:token/landing_url/expires_at)。
/// 表单入参契约见 core/api/share_api.dart(ShareCreateIn:expires_in_seconds
/// 60s~30 天 + requires_login,无提取码/下载开关字段)。
library;

class ShareLink {
  ShareLink({
    required this.token,
    required this.landingUrl,
    required this.expiresAt,
  });

  factory ShareLink.fromJson(Map<String, dynamic> j) => ShareLink(
        token: j['token'] as String,
        landingUrl: j['landing_url'] as String,
        expiresAt: (j['expires_at'] ?? '') as String,
      );

  final String token;
  final String landingUrl;
  final String expiresAt;
}
