/// UsageApi — /api/v1/admin/usage/stats 薄封装(routers/usage_stats.py 实码):
/// 消费既有端点零后端改动(方案 §3.4)。metric:'active_users'(默认)/
/// 'logins'。
///
/// 时区钉子(risk 方案 §12):from/to 必须 tz-aware ISO——naive 串会被后端
/// 422(`usage_stats.py:53-54` 端点自判 tzinfo)。本层统一
/// `DateTime.toUtc().toIso8601String()` 产出恒带「Z」后缀;「照抄 Web」仅指
/// 窗口算法(调用方本地时区今日零点锚定),不含该序列化细节。
library;

import '../../models/usage.dart';
import 'ms_api.dart';

/// metric 口径(web UsageMetric 同款)。
const kUsageMetricActiveUsers = 'active_users';
const kUsageMetricLogins = 'logins';

class UsageApi {
  UsageApi(this._api);

  final MsApi _api;

  /// GET /stats — 聚合(totals / by_platform / by_platform_class / by_network
  /// / cross / daily;各分组独立去重跨组不可加)。daily 后端恒产出(App 无
  /// 关闭诉求,不传 daily 参数,走默认 true)。
  Future<UsageStats> fetchUsageStats({
    required DateTime from,
    required DateTime to,
    String metric = kUsageMetricActiveUsers,
  }) async {
    final r = await _api.http.get(
      '/api/v1/admin/usage/stats',
      queryParameters: {
        'from': from.toUtc().toIso8601String(),
        'to': to.toUtc().toIso8601String(),
        'metric': metric,
      },
    );
    if (r.statusCode != 200) throw _api.err(r, '使用统计加载失败');
    return UsageStats.fromJson(r.data as Map<String, dynamic>);
  }
}
