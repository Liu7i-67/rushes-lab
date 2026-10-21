/// B6 假 API 族(自 api_harness.dart 拆分):foldersOps/projectsOps/
/// adminTemplates/users 记录式假实现,结果经 *_staged 编排(值=Exception 则抛,
/// 否则原样返回/缺省回退;api_harness.dart 的 FakeMsApi 覆写挂载)。
library;

import 'package:ms_app/core/api/admin_templates_api.dart';
import 'package:ms_app/core/api/folders_ops_api.dart';
import 'package:ms_app/core/api/projects_ops_api.dart';
import 'package:ms_app/core/api/users_api.dart';
import 'package:ms_app/models/models.dart';

import 'api_harness.dart' show settleStaged;

/// B6 文件夹管理动作假 API(对应 MsApi.foldersOps)。
class FakeFolderOpsApi extends FolderOpsApi {
  FakeFolderOpsApi(super.api);

  final createCalls =
      <({String projectId, String? parentFolderId, String name, bool isSensitive})>[];
  final renameCalls = <({String folderId, String name})>[];
  final moveCalls = <({String folderId, String? parentFolderId})>[];
  final deleteCalls = <String>[];
  final inviteCalls = <({String folderId, String? userId, String? groupId,
      String level, int? durationSeconds})>[];
  final revokeInviteCalls = <({String folderId, String subject, String level,
      bool permanent})>[];
  final listMembersCalls = <String>[];
  final listGrantsCalls = <String>[];
  final addGrantCalls = <({String folderId, String? userId, String? groupId,
      List<String> levels})>[];
  final removeGrantCalls = <({String folderId, String subject, String level})>[];

  Object? createStaged;
  Object? renameStaged;
  Object? moveStaged;
  Object? deleteStaged;
  Object? inviteStaged;
  Object? revokeInviteStaged;
  Object? listMembersStaged = const <FolderMemberRow>[];
  Object? listGrantsStaged = const <FolderGrantRow>[];
  Object? addGrantStaged;
  Object? removeGrantStaged;

  Folder _folder(String name) =>
      Folder(id: 'new', name: name, parentFolderId: null, projectId: 'p1');

  @override
  Future<Folder> create(
      {required String projectId,
      String? parentFolderId,
      required String name,
      bool isSensitive = false}) async {
    createCalls.add((
      projectId: projectId,
      parentFolderId: parentFolderId,
      name: name,
      isSensitive: isSensitive,
    ));
    return settleStaged(createStaged, _folder(name));
  }

  @override
  Future<Folder> rename(String folderId, {required String name}) async {
    renameCalls.add((folderId: folderId, name: name));
    return settleStaged(renameStaged, _folder(name));
  }

  @override
  Future<Folder> move(String folderId, {String? parentFolderId}) async {
    moveCalls.add((folderId: folderId, parentFolderId: parentFolderId));
    return settleStaged(moveStaged, _folder('moved'));
  }

  @override
  Future<void> delete(String folderId) async {
    deleteCalls.add(folderId);
    if (deleteStaged is Exception) throw deleteStaged!;
  }

  @override
  Future<void> invite(String folderId,
      {String? userId,
      String? groupId,
      required String level,
      int? durationSeconds}) async {
    inviteCalls.add((
      folderId: folderId,
      userId: userId,
      groupId: groupId,
      level: level,
      durationSeconds: durationSeconds,
    ));
    if (inviteStaged is Exception) throw inviteStaged!;
  }

  @override
  Future<void> revokeInvite(String folderId,
      {required String subject,
      required String level,
      bool permanent = true}) async {
    revokeInviteCalls.add((
      folderId: folderId,
      subject: subject,
      level: level,
      permanent: permanent,
    ));
    if (revokeInviteStaged is Exception) throw revokeInviteStaged!;
  }

  @override
  Future<List<FolderMemberRow>> listMembers(String folderId) async {
    listMembersCalls.add(folderId);
    return settleStaged(listMembersStaged, const <FolderMemberRow>[]);
  }

  @override
  Future<List<FolderGrantRow>> listGrants(String folderId) async {
    listGrantsCalls.add(folderId);
    return settleStaged(listGrantsStaged, const <FolderGrantRow>[]);
  }

  @override
  Future<void> addGrant(String folderId,
      {String? userId,
      String? groupId,
      required List<String> levels}) async {
    addGrantCalls.add((
      folderId: folderId,
      userId: userId,
      groupId: groupId,
      levels: levels,
    ));
    if (addGrantStaged is Exception) throw addGrantStaged!;
  }

  @override
  Future<void> removeGrant(String folderId,
      {required String subject, required String level}) async {
    removeGrantCalls
        .add((folderId: folderId, subject: subject, level: level));
    if (removeGrantStaged is Exception) throw removeGrantStaged!;
  }
}

/// B6 项目管理动作假 API(对应 MsApi.projectsOps)。
class FakeProjectOpsApi extends ProjectOpsApi {
  FakeProjectOpsApi(super.api);

  final createCalls = <Map<String, dynamic>>[];
  final listDeletedCalls = <({String? q, int limit, int offset})>[];
  final restoreCalls = <String>[];
  final listMembersCalls = <String>[];
  final addMemberCalls = <({String projectId, String? userId, String? groupId,
      List<String> roles})>[];
  final removeMemberCalls = <({String projectId, String subject, String role})>[];
  final listGrantsCalls = <String>[];
  final revokeGrantCalls = <({String projectId, String objectType,
      String objectId, String subject, String relation})>[];

  Object? createStaged;
  Object? listDeletedStaged =
      DeletedProjectsPage(items: [], total: 0);
  Object? restoreStaged;
  Object? listMembersStaged = const <ProjectMember>[];
  Object? addMemberStaged;
  Object? removeMemberStaged;
  Object? listGrantsStaged = const <ProjectGrantRow>[];
  Object? revokeGrantStaged;

  @override
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
    createCalls.add({
      'code': code,
      'name': name,
      'minio_bucket': minioBucket,
      'admin_user_id': adminUserId,
      'description': description,
      'initial_grants': initialGrants
          ?.map((g) => {'kind': g.kind, 'id': g.id, 'roles': g.roles})
          .toList(),
      'folder_template_id': folderTemplateId,
      'artist_account': artistAccount == null
          ? null
          : {'username': artistAccount.username, 'name': artistAccount.name},
    });
    return settleStaged(
        createStaged,
        ProjectCreated(id: 'np1', name: name, code: code));
  }

  @override
  Future<DeletedProjectsPage> listDeleted(
      {String? q, int limit = 20, int offset = 0}) async {
    listDeletedCalls.add((q: q, limit: limit, offset: offset));
    return settleStaged(listDeletedStaged, DeletedProjectsPage(items: [], total: 0));
  }

  @override
  Future<void> restore(String projectId) async {
    restoreCalls.add(projectId);
    if (restoreStaged is Exception) throw restoreStaged!;
  }

  @override
  Future<List<ProjectMember>> listMembers(String projectId) async {
    listMembersCalls.add(projectId);
    return settleStaged(listMembersStaged, const <ProjectMember>[]);
  }

  @override
  Future<void> addMember(String projectId,
      {String? userId,
      String? groupId,
      required List<String> roles}) async {
    addMemberCalls.add((
      projectId: projectId,
      userId: userId,
      groupId: groupId,
      roles: roles,
    ));
    if (addMemberStaged is Exception) throw addMemberStaged!;
  }

  @override
  Future<void> removeMember(String projectId,
      {required String subject, required String role}) async {
    removeMemberCalls.add((
      projectId: projectId,
      subject: subject,
      role: role,
    ));
    if (removeMemberStaged is Exception) throw removeMemberStaged!;
  }

  @override
  Future<List<ProjectGrantRow>> listGrants(String projectId) async {
    listGrantsCalls.add(projectId);
    return settleStaged(listGrantsStaged, const <ProjectGrantRow>[]);
  }

  @override
  Future<void> revokeGrant(String projectId,
      {required String objectType,
      required String objectId,
      required String subject,
      required String relation}) async {
    revokeGrantCalls.add((
      projectId: projectId,
      objectType: objectType,
      objectId: objectId,
      subject: subject,
      relation: relation,
    ));
    if (revokeGrantStaged is Exception) throw revokeGrantStaged!;
  }
}

/// B6 模板读端点假 API(对应 MsApi.adminTemplates)。
class FakeAdminTemplatesApi extends AdminTemplatesApi {
  FakeAdminTemplatesApi(super.api);

  final grantCalls = <int>[];
  final folderCalls = <int>[];
  List<GrantTemplate> grantResult = const [];
  List<FolderTemplate> folderResult = const [];
  Object? grantStaged;
  Object? folderStaged;

  @override
  Future<List<GrantTemplate>> grantTemplates() async {
    grantCalls.add(1);
    return settleStaged(grantStaged, grantResult);
  }

  @override
  Future<List<FolderTemplate>> folderTemplates() async {
    folderCalls.add(1);
    return settleStaged(folderStaged, folderResult);
  }
}

/// B6 选人数据源假 API(对应 MsApi.users)。
class FakeUsersApi extends UsersApi {
  FakeUsersApi(super.api);

  final userSearchCalls = <({String q, int limit, int offset})>[];
  final groupSearchCalls = <({String q, int limit})>[];
  final usernameAvailableCalls = <String>[];
  List<UserBrief> userResult = const [];
  List<GroupBrief> groupResult = const [];
  Map<String, Object?> usernameStaged = const {};

  @override
  Future<List<UserBrief>> searchUsers(
      {String q = '', int limit = 20, int offset = 0}) async {
    userSearchCalls.add((q: q, limit: limit, offset: offset));
    return userResult;
  }

  @override
  Future<List<GroupBrief>> searchGroups({String q = '', int limit = 30}) async {
    groupSearchCalls.add((q: q, limit: limit));
    return groupResult;
  }

  @override
  Future<bool> usernameAvailable(String username) async {
    usernameAvailableCalls.add(username);
    final staged = usernameStaged[username];
    if (staged is Exception) throw staged;
    return (staged ?? true) as bool;
  }
}

