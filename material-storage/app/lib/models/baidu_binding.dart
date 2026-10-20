/// BaiduBindingInfo — /api/v1/baidu/backup/binding 族契约
/// (api/app/models/__init__.py:BaiduBindingOut/BaiduBindOut 实际字段)。
library;

class BaiduBindingInfo {
  BaiduBindingInfo({
    required this.bound,
    required this.status,
    this.expiresAt,
    this.baiduUid,
    this.nickname,
  });

  factory BaiduBindingInfo.fromJson(Map<String, dynamic> j) => BaiduBindingInfo(
        bound: (j['bound'] ?? false) as bool,
        status: (j['status'] ?? 'unbound') as String,
        expiresAt: j['expires_at'] as String?,
        baiduUid: j['baidu_uid'] as String?,
        nickname: j['nickname'] as String?,
      );

  /// bound = status=='active'(expired/unbound 均视为未绑定,需重绑)。
  final bool bound;
  final String status; // active / expired / unbound
  final String? expiresAt;

  /// UI 显示绑定账号(§4:昵称缺失回退展示 uid);未绑定为 null。
  final String? baiduUid;
  final String? nickname;

  /// 展示名:昵称优先,缺省回退 uid,再缺省回落「百度账号」。
  String get displayName =>
      (nickname?.isNotEmpty ?? false) ? nickname! : (baiduUid ?? '百度账号');
}
