/// ProjectOpsApi — /api/v1/projects 管理动作族薄封装(B6;与列表 projects_api.dart
/// 分文件)。契约以 routers/projects.py 实码为准:create=ProjectCreateIn 全字段
/// (无 visibility;模板展开为 initial_grants 行,无模板 id 入参);deleted/restore
/// 挂 require_project_deleter;members 族需 can_admin(roles 数组一次授多角色)。
/// create 经 MsApi.guard5xx 包装(同 baidu_api.dart 口径):5xx 在 dio 层抛的
/// badResponse 转 ApiException 透传 detail,走 new_project_sheet 的中性引导
/// 文案分支,勿渲染原始 DioException(§4.1)。
library;

import '../../models/models.dart';
import 'ms_api.dart';

class ProjectOpsApi {
  ProjectOpsApi(this._api);

  final MsApi _api;

  /// 新建项目(201 ProjectCreatedOut;带 artist_account 时响应含一次性密码回显)。
  /// 非系统 admin 的 bucket/org 由后端强制忽略(提权口收口),前端仍按表单实况提交。
  Future<ProjectCreated> create({
    required String code,
    required String name,
    required String minioBucket,
    required String adminUserId,
    String? description,
    List<GrantEntry>? initialGrants,
    String? folderTemplateId,
    ({String username, String name})? artistAccount,
  }) async {
    final desc = (description?.trim().isEmpty ?? true) ? null : description;
    final grants =
        (initialGrants == null || initialGrants.isEmpty) ? null : initialGrants;
    final artist = artistAccount == null
        ? null
        : {'username': artistAccount.username, 'name': artistAccount.name};
    // guard5xx:5xx(艺人段/项目段异常、反代 502 等)转 ApiException,
    // sheet 按 projectCreateFailCopy 走中性引导;4xx 仍回 Response 走业务提取
    final r = await _api.guard5xx(
        _api.http.post('/api/v1/projects', data: {
          'code': code,
          'name': name,
          'description': ?desc,
          'minio_bucket': minioBucket,
          'admin_user_id': adminUserId,
          // 可选字段:空 = 省略(web useCreateProject 展开同构,现状行为不变)
          'initial_grants': ?grants,
          'folder_template_id': ?folderTemplateId,
          'artist_account': ?artist,
        }),
        '创建项目失败');
    if (r.statusCode != 201) throw _api.err(r, '创建项目失败');
    return ProjectCreated.fromJson(r.data as Map<String, dynamic>);
  }

  /// 已删除项目分页列表(q 过 code/name;deleted_at 倒序,带 deleted_by_name)。
  Future<DeletedProjectsPage> listDeleted(
      {String? q, int limit = 20, int offset = 0}) async {
    final r = await _api.http.get('/api/v1/projects/deleted',
        queryParameters: {
          'q': ?(q == null || q.isEmpty ? null : q),
          'limit': limit,
          'offset': offset,
        });
    if (r.statusCode != 200) throw _api.err(r, '已删除项目加载失败');
    return DeletedProjectsPage.fromJson(r.data as Map<String, dynamic>);
  }

  /// 恢复逻辑删除的项目(200 {ok, project_id};未删除/不存在 404)。
  Future<void> restore(String projectId) async {
    final r = await _api.http.post('/api/v1/projects/$projectId/restore');
    if (r.statusCode != 200) throw _api.err(r, '恢复失败');
  }

  /// 成员列表(同主体多角色聚合;需 can_admin project)。
  Future<List<ProjectMember>> listMembers(String projectId) async {
    final r = await _api.http.get('/api/v1/projects/$projectId/members');
    if (r.statusCode != 200) throw _api.err(r, '成员列表加载失败');
    return ((r.data as List? ?? const []))
        .map((e) => ProjectMember.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 加成员(user_id / group_id 二选一;roles 数组一次授多角色,后端去重固定序)。
  Future<void> addMember(
    String projectId, {
    String? userId,
    String? groupId,
    required List<String> roles,
  }) async {
    final r =
        await _api.http.post('/api/v1/projects/$projectId/members', data: {
      'user_id': userId,
      'group_id': groupId,
      'roles': roles,
    });
    if (r.statusCode != 204) throw _api.err(r, '添加成员失败');
  }

  /// 移除成员单角色(subject=完整 subject;role 单值;admin 自撤/末位 admin 409)。
  Future<void> removeMember(
    String projectId, {
    required String subject,
    required String role,
  }) async {
    final r = await _api.http.delete('/api/v1/projects/$projectId/members',
        queryParameters: {'subject': subject, 'role': role});
    if (r.statusCode != 204) throw _api.err(r, '移除失败');
  }

  /// 授权总览(#138:审批/邀请获得的 explicit/invited grant;需 can_admin)。
  Future<List<ProjectGrantRow>> listGrants(String projectId) async {
    final r = await _api.http.get('/api/v1/projects/$projectId/grants');
    if (r.statusCode != 200) throw _api.err(r, '授权总览加载失败');
    return ((r.data as List? ?? const []))
        .map((e) => ProjectGrantRow.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 撤回一条授权(四元组与 listGrants 输出对齐;relation 须在可撤回白名单)。
  Future<void> revokeGrant(
    String projectId, {
    required String objectType,
    required String objectId,
    required String subject,
    required String relation,
  }) async {
    final r = await _api.http.delete('/api/v1/projects/$projectId/grants',
        queryParameters: {
          'object_type': objectType,
          'object_id': objectId,
          'subject': subject,
          'relation': relation,
        });
    if (r.statusCode != 204) throw _api.err(r, '撤回失败');
  }
}
