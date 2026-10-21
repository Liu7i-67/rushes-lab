/// UsersApi — 选人数据源(B6 §9 pickers;users.py / groups.py 实码):
/// users 简表模糊搜(admin 或 project creator 弱门)、groups 简表、
/// 登录名占用预检(艺人账号内嵌,require_inline_artist_creator 组合弱门)。
library;

import '../../models/models.dart';
import 'ms_api.dart';

class UsersApi {
  UsersApi(this._api);

  final MsApi _api;

  /// 模糊搜 user(匹配 name/email/username/feishu_open_id;留空 = 返前 N)。
  /// offset 分页拉全量做 nameById(web useAllUsers 同源),本批按需分页。
  Future<List<UserBrief>> searchUsers(
      {String q = '', int limit = 20, int offset = 0}) async {
    final r = await _api.http.get('/api/v1/users', queryParameters: {
      'q': q,
      'limit': limit,
      'offset': offset,
    });
    if (r.statusCode != 200) throw _api.err(r, '用户搜索失败');
    return ((r.data as List? ?? const []))
        .map((e) => UserBrief.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 本地组列表(name 模糊 filter;无组回空数组,不是 404)。
  Future<List<GroupBrief>> searchGroups({String q = '', int limit = 30}) async {
    final r = await _api.http
        .get('/api/v1/groups', queryParameters: {'q': q, 'limit': limit});
    if (r.statusCode != 200) throw _api.err(r, '用户组加载失败');
    return ((r.data as List? ?? const []))
        .map((e) => GroupBrief.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 登录名占用预检(GET /users/username-available;400=形状不合法 422 同源)。
  /// 403 = 无内嵌建号能力,调用方(艺人账号区块)已按闸门显隐,异常静默兜底。
  Future<bool> usernameAvailable(String username) async {
    final r = await _api.http
        .get('/api/v1/users/username-available', queryParameters: {
      'username': username,
    });
    if (r.statusCode != 200) throw _api.err(r, '登录名预检失败');
    return ((r.data as Map<String, dynamic>)['available'] ?? false) as bool;
  }
}
