/// DirectoryApi — /api/v1/admin/directory 族薄封装(B8;directory.py 实码):
/// 用户列表(搜索/分页/is_active)、建号(带组+一次性临时密码)、详情、
/// 编辑(name/email 显式 null 清空/group_ids 全量同步)、启停/重置/解锁、
/// 组列表(五组级 flag)、组建/编/删(tri-state PATCH:None=字段省略不动)、
/// 组成员列表/加/移。require_system_admin 全族。
library;

import '../../models/models.dart';
import 'ms_api.dart';

class DirectoryApi {
  DirectoryApi(this._api);

  final MsApi _api;

  // ── users ─────────────────────────────────────────────────────────────────

  /// GET /users — 用户列表分页(q 模糊 username/name/email;is_active 筛选)。
  Future<DirectoryUsersPage> listUsers({
    String q = '',
    bool? isActive,
    int limit = 20,
    int offset = 0,
  }) async {
    final r = await _api.http.get('/api/v1/admin/directory/users',
        queryParameters: {
          'q': q,
          'is_active': ?isActive,
          'limit': limit,
          'offset': offset,
        });
    if (r.statusCode != 200) throw _api.err(r, '用户列表加载失败');
    return DirectoryUsersPage.fromJson(r.data as Map<String, dynamic>);
  }

  /// POST /users — 建号(带组;201 回一次性临时密码,只回显一次)。
  Future<DirectoryUserCreated> createUser({
    required String username,
    required String name,
    String? email,
    List<String> groupIds = const [],
  }) async {
    final r = await _api.http.post('/api/v1/admin/directory/users', data: {
      'username': username,
      'name': name,
      if (email != null && email.isNotEmpty) 'email': email,
      'group_ids': groupIds,
    });
    if (r.statusCode != 201) throw _api.err(r, '创建用户失败');
    return DirectoryUserCreated.fromJson(r.data as Map<String, dynamic>);
  }

  /// GET /users/{id} — 详情(含所属组 ids/names 同序)。
  Future<DirectoryUserDetail> getUser(String userId) async {
    final r = await _api.http.get('/api/v1/admin/directory/users/$userId');
    if (r.statusCode != 200) throw _api.err(r, '用户详情加载失败');
    return DirectoryUserDetail.fromJson(r.data as Map<String, dynamic>);
  }

  /// PATCH /users/{id} — 编辑:[email] 传 String 或显式 null(清空)都会携带
  /// 字段(web D6 留空=清空同款);[groupIds] 全量同步终态(D3)。
  Future<DirectoryUser> updateUser(
    String userId, {
    required String name,
    Object? email,
    required List<String> groupIds,
  }) async {
    final r = await _api.http.patch('/api/v1/admin/directory/users/$userId',
        data: {'name': name, 'email': email, 'group_ids': groupIds});
    if (r.statusCode != 200) throw _api.err(r, '保存用户失败');
    return DirectoryUser.fromJson(r.data as Map<String, dynamic>);
  }

  /// POST /users/{id}/disable — 禁用(撤全部 tuple;409 已禁用透传)。
  Future<void> disableUser(String userId) async {
    final r = await _api.http
        .post('/api/v1/admin/directory/users/$userId/disable');
    if (r.statusCode != 200) throw _api.err(r, '停用失败');
  }

  /// POST /users/{id}/enable — 启用(重建组 tuple;409 已启用透传)。
  Future<void> enableUser(String userId) async {
    final r = await _api.http.post('/api/v1/admin/directory/users/$userId/enable');
    if (r.statusCode != 200) throw _api.err(r, '启用失败');
  }

  /// POST /users/{id}/reset-password — 新一次性临时密码(顺带清登录锁;
  /// 已禁用 409 透传)。
  Future<String> resetPassword(String userId) async {
    final r = await _api.http
        .post('/api/v1/admin/directory/users/$userId/reset-password');
    if (r.statusCode != 200) throw _api.err(r, '重置密码失败');
    return ((r.data as Map<String, dynamic>)['temporary_password'] ?? '')
        as String;
  }

  /// POST /users/{id}/unlock — 解登录锁(清三形态 + 连带清近 24h 失败 IP)。
  Future<UnlockResult> unlockUser(String userId) async {
    final r =
        await _api.http.post('/api/v1/admin/directory/users/$userId/unlock');
    if (r.statusCode != 200) throw _api.err(r, '解锁失败');
    final j = r.data as Map<String, dynamic>;
    return UnlockResult(
      clearedUserForms: ((j['cleared_user_forms'] ?? const []) as List)
          .map((e) => e as String)
          .toList(),
      clearedIps: ((j['cleared_ips'] ?? const []) as List)
          .map((e) => e as String)
          .toList(),
      wasLocked: (j['was_locked'] ?? false) as bool,
    );
  }

  // ── groups ────────────────────────────────────────────────────────────────

  /// GET /groups — 组列表(q 模糊 name/description;带成员数+五组级 flag)。
  Future<List<DirectoryGroup>> listGroups({
    String q = '',
    int limit = 50,
    int offset = 0,
  }) async {
    final r = await _api.http.get('/api/v1/admin/directory/groups',
        queryParameters: {'q': q, 'limit': limit, 'offset': offset});
    if (r.statusCode != 200) throw _api.err(r, '用户组加载失败');
    return ((r.data as List? ?? const []))
        .map((e) => DirectoryGroup.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /groups — 建组(409 重名透传;web 建组态不带 can_delete_project)。
  Future<DirectoryGroup> createGroup({
    required String name,
    String? description,
    bool canCreateProject = false,
    bool canManageFolderTemplates = false,
    bool canCreateArtistAccount = false,
    bool canDeleteFiles = false,
  }) async {
    final r = await _api.http.post('/api/v1/admin/directory/groups', data: {
      'name': name,
      'description': description,
      'can_create_project': canCreateProject,
      'can_manage_folder_templates': canManageFolderTemplates,
      'can_create_artist_account': canCreateArtistAccount,
      'can_delete_files': canDeleteFiles,
    });
    if (r.statusCode != 201) throw _api.err(r, '创建用户组失败');
    return DirectoryGroup.fromJson(r.data as Map<String, dynamic>);
  }

  /// PATCH /groups/{id} — 编辑:flag 三态(bool?=null 即字段省略不动,
  /// directory.py tri-state 防「仅改名保存」静默撤权);description 恒携带
  /// (web 同款;后端 None 不改)。
  Future<DirectoryGroup> updateGroup(
    String groupId, {
    String? name,
    String? description,
    bool? canCreateProject,
    bool? canDeleteProject,
    bool? canManageFolderTemplates,
    bool? canCreateArtistAccount,
    bool? canDeleteFiles,
  }) async {
    final r = await _api.http.patch('/api/v1/admin/directory/groups/$groupId',
        data: {
          'name': ?name,
          'description': description,
          'can_create_project': ?canCreateProject,
          'can_delete_project': ?canDeleteProject,
          'can_manage_folder_templates': ?canManageFolderTemplates,
          'can_create_artist_account': ?canCreateArtistAccount,
          'can_delete_files': ?canDeleteFiles,
        });
    if (r.statusCode != 200) throw _api.err(r, '保存用户组失败');
    return DirectoryGroup.fromJson(r.data as Map<String, dynamic>);
  }

  /// DELETE /groups/{id} — 删组(成员关系一并清)。
  Future<void> deleteGroup(String groupId) async {
    final r = await _api.http.delete('/api/v1/admin/directory/groups/$groupId');
    if (r.statusCode != 200) throw _api.err(r, '删除用户组失败');
  }

  /// GET /groups/{id}/members — 组内成员列表。
  Future<List<GroupMember>> listMembers(String groupId) async {
    final r =
        await _api.http.get('/api/v1/admin/directory/groups/$groupId/members');
    if (r.statusCode != 200) throw _api.err(r, '成员列表加载失败');
    return ((r.data as List? ?? const []))
        .map((e) => GroupMember.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /groups/{id}/members — 加成员(400 已禁用 / 409 已在组中透传)。
  Future<void> addMember(String groupId, String userId) async {
    final r = await _api.http.post('/api/v1/admin/directory/groups/$groupId/members',
        data: {'user_id': userId});
    if (r.statusCode != 201) throw _api.err(r, '添加成员失败');
  }

  /// DELETE /groups/{id}/members/{user_id} — 移除成员。
  Future<void> removeMember(String groupId, String userId) async {
    final r = await _api.http.delete(
        '/api/v1/admin/directory/groups/$groupId/members/$userId');
    if (r.statusCode != 200) throw _api.err(r, '移出成员失败');
  }
}

/// 解锁结果(unlock 响应;was_locked=false = 本就未锁,顺手清了失败计数)。
class UnlockResult {
  UnlockResult({
    required this.clearedUserForms,
    required this.clearedIps,
    required this.wasLocked,
  });

  final List<String> clearedUserForms;
  final List<String> clearedIps;
  final bool wasLocked;
}
