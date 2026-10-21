/// FolderOpsApi — /api/v1/folders 管理动作族薄封装(B6;与列表/详情
/// folders_api.dart 分文件守 300 行硬顶)。契约以 routers/folders.py 实码为准:
/// 删夹=仅空夹硬删(非空 409 detail 透传,无软删路径);invite 仅敏感夹
/// (level viewer/downloader + duration_seconds 可选);grants 仅普通一级夹
/// (levels 数组一次授多 level,恒永久无有效期)。
library;

import '../../models/models.dart';
import 'ms_api.dart';

class FolderOpsApi {
  FolderOpsApi(this._api);

  final MsApi _api;

  /// 创建文件夹(201 FolderOut;sensitive 只能直挂 project 一级,子夹恒普通)。
  Future<Folder> create({
    required String projectId,
    String? parentFolderId,
    required String name,
    bool isSensitive = false,
  }) async {
    final r = await _api.http.post('/api/v1/folders', data: {
      'project_id': projectId,
      'parent_folder_id': parentFolderId,
      'name': name,
      'is_sensitive': isSensitive,
    });
    if (r.statusCode != 201) throw _api.err(r, '文件夹创建失败');
    return Folder.fromJson(r.data as Map<String, dynamic>);
  }

  /// 改名(PATCH name;首尾空白/段名非法 422 detail 透传)。
  Future<Folder> rename(String folderId, {required String name}) async {
    final r = await _api.http
        .patch('/api/v1/folders/$folderId', data: {'name': name});
    if (r.statusCode != 200) throw _api.err(r, '重命名失败');
    return Folder.fromJson(r.data as Map<String, dynamic>);
  }

  /// 移动(PATCH parent_folder_id;显式 null = 移为项目一级,与 FolderUpdateIn
  /// 「缺省 ≠ 显式 null」契约对齐——本方法恒传该键)。sensitive 源禁移动 400。
  Future<Folder> move(String folderId, {String? parentFolderId}) async {
    final r = await _api.http.patch('/api/v1/folders/$folderId',
        data: {'parent_folder_id': parentFolderId});
    if (r.statusCode != 200) throw _api.err(r, '移动失败');
    return Folder.fromJson(r.data as Map<String, dynamic>);
  }

  /// 删除空文件夹(204 硬删;非空/回收站未清空 409 detail 透传,不可恢复)。
  Future<void> delete(String folderId) async {
    final r = await _api.http.delete('/api/v1/folders/$folderId');
    if (r.statusCode != 204) throw _api.err(r, '删除失败');
  }

  /// 敏感夹邀请(user_id / group_id 二选一;level viewer|downloader;
  /// durationSeconds null=永久,int=时限 60s..365d)。
  Future<void> invite(
    String folderId, {
    String? userId,
    String? groupId,
    required String level,
    int? durationSeconds,
  }) async {
    final r = await _api.http.post('/api/v1/folders/$folderId/invite', data: {
      'user_id': userId,
      'group_id': groupId,
      'level': level,
      'duration_seconds': durationSeconds,
    });
    if (r.statusCode != 204) throw _api.err(r, '邀请失败');
  }

  /// 撤销邀请(subject=完整 OpenFGA subject;permanent=true 删 invited 永久行,
  /// false 删 explicit_invited 临时行)。
  Future<void> revokeInvite(
    String folderId, {
    required String subject,
    required String level,
    bool permanent = true,
  }) async {
    final r = await _api.http.delete('/api/v1/folders/$folderId/invite',
        queryParameters: {
          'subject': subject,
          'level': level,
          'permanent': permanent,
        });
    if (r.statusCode != 204) throw _api.err(r, '撤销失败');
  }

  /// 敏感夹当前成员列表(需 can_admin)。
  Future<List<FolderMemberRow>> listMembers(String folderId) async {
    final r = await _api.http.get('/api/v1/folders/$folderId/members');
    if (r.statusCode != 200) throw _api.err(r, '成员列表加载失败');
    return ((r.data as List? ?? const []))
        .map((e) => FolderMemberRow.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 普通一级夹 grants 列表(需 can_admin;敏感夹 400 指引 /members)。
  Future<List<FolderGrantRow>> listGrants(String folderId) async {
    final r = await _api.http.get('/api/v1/folders/$folderId/grants');
    if (r.statusCode != 200) throw _api.err(r, '授权列表加载失败');
    return ((r.data as List? ?? const []))
        .map((e) => FolderGrantRow.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 添加 grant(user_id / group_id 二选一;levels 数组一次授多 level
  /// viewer|downloader|uploader;恒永久,后端无有效期入参)。
  Future<void> addGrant(
    String folderId, {
    String? userId,
    String? groupId,
    required List<String> levels,
  }) async {
    final r = await _api.http.post('/api/v1/folders/$folderId/grants', data: {
      'user_id': userId,
      'group_id': groupId,
      'levels': levels,
    });
    if (r.statusCode != 204) throw _api.err(r, '添加授权失败');
  }

  /// 撤销一条 grant(subject=完整 subject;level 单值)。
  Future<void> removeGrant(
    String folderId, {
    required String subject,
    required String level,
  }) async {
    final r = await _api.http.delete('/api/v1/folders/$folderId/grants',
        queryParameters: {'subject': subject, 'level': level});
    if (r.statusCode != 204) throw _api.err(r, '撤销失败');
  }
}
