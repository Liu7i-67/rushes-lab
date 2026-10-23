/// NotificationsApi — /api/v1/notifications 族薄封装(B7 §8.7;契约
/// api/app/routers/notifications.py 实码)。list 自带 total + unread_count
/// (badge 轮询取 limit=1 的轻量口径);mark-read 二选一:ids(单条/多条,
/// 限本人未读)或 all=true(全部)。
library;

import 'package:dio/dio.dart' show Options;

import '../../models/models.dart';
import 'ms_api.dart';

class NotificationsApi {
  NotificationsApi(this._api);

  final MsApi _api;

  /// 通知列表(created_at 倒序 + unread_count)。
  /// [silent] 仅后台轮询传 true:请求带 noErrorReport extra,失败静默自愈,
  /// 不进全局报错页;其余调用点保持默认 false(行为不变)。
  Future<NotificationsList> list(
      {int limit = 50, int offset = 0, bool silent = false}) async {
    final r = await _api.http.get(
      '/api/v1/notifications',
      queryParameters: {
        'limit': limit,
        'offset': offset,
      },
      options:
          silent ? Options(extra: const {'noErrorReport': true}) : null,
    );
    if (r.statusCode != 200) throw _api.err(r, '通知列表加载失败');
    return NotificationsList.fromJson(r.data as Map<String, dynamic>);
  }

  /// 标记已读:ids 与 all 二选一(两者皆空后端 400)。返回 updated 条数。
  Future<int> markRead({List<String>? ids, bool all = false}) async {
    final r = await _api.http.post('/api/v1/notifications/mark-read', data: {
      'ids': ?ids,
      'all': all,
    });
    if (r.statusCode != 200) throw _api.err(r, '标记已读失败');
    return ((r.data as Map<String, dynamic>)['updated'] ?? 0) as int;
  }
}
