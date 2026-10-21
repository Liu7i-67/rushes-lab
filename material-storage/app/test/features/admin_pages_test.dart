/// B8 管理后台页面 widget 测试(testWidgets + 记录式假 API 族):
/// 入口双闸门显隐、用户建号一次性密码回显/解锁入口与确认、组移出成员、
/// 应用默认批量结果逐项目呈现、百度任务详情文件级三操作。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/admin_baidu_api.dart' show AdminBaiduApi;
import 'package:ms_app/core/api/audit_api.dart' show AuditApi, AuditFilter;
import 'package:ms_app/core/api/directory_api.dart'
    show DirectoryApi, UnlockResult;
import 'package:ms_app/features/admin/admin_groups_page.dart';
import 'package:ms_app/features/admin/admin_users_page.dart';
import 'package:ms_app/features/admin/apply_default_sheet.dart';
import 'package:ms_app/features/admin/baidu_task_detail_sheet.dart';
import 'package:ms_app/features/admin/baidu_task_file_list.dart'
    show kOwnerOnlyOpsHint;
import 'package:ms_app/features/admin/grant_template_form_sheet.dart'
    show showGrantTemplateFormSheet;
import 'package:ms_app/features/me/admin_tiles.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/core/session.dart';

import '../helpers/fake_apis_b6.dart' show FakeAdminTemplatesApi;
import '../helpers/api_harness.dart'
    show FakeMsApi, FakeProjectsApi, settleStaged;

// ── 假 API 族(记录式;对应 MsApi 新增三域)────────────────────────────────

class FakeDirectoryApi extends DirectoryApi {
  FakeDirectoryApi(super.api);

  Object? usersStaged;
  List<DirectoryGroup> groupResult = const [];
  List<GroupMember> memberResult = const [];
  final createCalls = <Map<String, dynamic>>[];
  final unlockCalls = <String>[];
  final removeMemberCalls = <(String, String)>[];
  Object? createOut;
  Object? unlockOut;

  @override
  Future<DirectoryUsersPage> listUsers(
      {String q = '', bool? isActive, int limit = 20, int offset = 0}) async {
    final staged = usersStaged;
    if (staged is Exception) throw staged;
    return staged as DirectoryUsersPage? ??
        DirectoryUsersPage(items: const [], total: 0);
  }

  @override
  Future<DirectoryUserCreated> createUser(
      {required String username,
      required String name,
      String? email,
      List<String> groupIds = const []}) async {
    createCalls.add({
      'username': username,
      'name': name,
      'email': email,
      'group_ids': groupIds,
    });
    return settleStaged(
        createOut,
        DirectoryUserCreated(
            id: 'u9',
            username: username,
            name: name,
            email: email,
            isActive: true,
            mustChangePassword: true,
            createdAt: '2026-10-20T09:00:00Z',
            temporaryPassword: 'Tmp-Pass-001'));
  }

  @override
  Future<List<DirectoryGroup>> listGroups(
      {String q = '', int limit = 50, int offset = 0}) async {
    return groupResult;
  }

  @override
  Future<List<GroupMember>> listMembers(String groupId) async => memberResult;

  @override
  Future<void> removeMember(String groupId, String userId) async {
    removeMemberCalls.add((groupId, userId));
  }

  @override
  Future<UnlockResult> unlockUser(String userId) async {
    unlockCalls.add(userId);
    return settleStaged(
        unlockOut,
        UnlockResult(
            clearedUserForms: ['zs'], clearedIps: const [], wasLocked: true));
  }
}

class FakeAuditApi extends AuditApi {
  FakeAuditApi(super.api);

  List<AuditEvent> listResult = const [];
  final listCalls = <AuditFilter>[];

  @override
  Future<List<AuditEvent>> list(
      {AuditFilter filter = const AuditFilter(),
      int limit = 30,
      int offset = 0}) async {
    listCalls.add(filter);
    return listResult;
  }
}

class FakeAdminBaiduApi extends AdminBaiduApi {
  FakeAdminBaiduApi(super.api);

  Object? detailStaged;
  Object? filesStaged;
  List<AdminBaiduTaskFile> filesResult = const [];
  final fileOpCalls = <(String, String, String)>[];

  @override
  Future<AdminBaiduTaskDetail> taskDetail(String taskId) async =>
      settleStaged(detailStaged, _detailOf());

  @override
  Future<AdminBaiduTaskFilesPage> taskFiles(String taskId,
      {String? status, int limit = 20, int offset = 0}) async {
    final staged = filesStaged;
    if (staged is Exception) throw staged;
    return AdminBaiduTaskFilesPage(items: filesResult, total: filesResult.length);
  }

  Future<BaiduReviveOut> _op(String taskId, String fileId, String action) async {
    fileOpCalls.add((taskId, fileId, action));
    return BaiduReviveOut(finalized: true, status: 'enumerating');
  }

  @override
  Future<BaiduReviveOut> retryFile(String taskId, String fileId) =>
      _op(taskId, fileId, 'retry');

  @override
  Future<BaiduReviveOut> overwriteFile(String taskId, String fileId) =>
      _op(taskId, fileId, 'overwrite');

  @override
  Future<BaiduReviveOut> randomSuffixFile(String taskId, String fileId) =>
      _op(taskId, fileId, 'random-suffix');

  AdminBaiduTaskDetail _detailOf() => AdminBaiduTaskDetail.fromJson({
        'id': 't1',
        'user': {'id': 'u1', 'username': 'zs', 'name': '张三'},
        'status': 'failed',
        'source_dir': '/灵机备份',
        'project': {'id': 'p1', 'name': '婚礼项目'},
        'target_folder': {'id': 'fo1', 'name': '灵机备份'},
        'total_files': 3,
        'done_files': 0,
        'failed_files': 3,
        'skipped_files': 0,
        'cancelled_files': 0,
        'total_bytes': 0,
        'done_bytes': 0,
        'created_at': '2026-10-20T09:00:00Z',
        'updated_at': '2026-10-20T10:00:00Z',
        'fail_reason': 'file_failed',
        'cancel_requested': false,
        'retry_count': 1,
        'enum_done': true,
      });
}

/// 应用默认桩(叠加在 harness FakeAdminTemplatesApi 之上,只补 applyDefault)。
class FakeApplyTemplatesApi extends FakeAdminTemplatesApi {
  FakeApplyTemplatesApi(super.api);

  Object? applyOut;
  final applyCalls = <List<String>>[];

  @override
  Future<ApplyDefaultResult> applyDefault(List<String> projectIds) async {
    applyCalls.add(projectIds);
    return settleStaged(applyOut,
        ApplyDefaultResult(results: const [], totalApplied: 0, totalSkipped: 0));
  }
}

/// projects.listPaged 桩(应用默认/审计项目筛选共用数据源)。
class FakeProjectsPagedApi extends FakeProjectsApi {
  FakeProjectsPagedApi(super.api);

  List<Project> pagedResult = const [];

  @override
  Future<List<Project>> listPaged({int limit = 100, int offset = 0}) async {
    if (offset > 0) return const [];
    return pagedResult;
  }
}

class FakeAdminMsApi extends FakeMsApi {
  late final _directory = FakeDirectoryApi(this);
  late final _audit = FakeAuditApi(this);
  late final _adminBaidu = FakeAdminBaiduApi(this);
  late final _adminTemplates = FakeApplyTemplatesApi(this);
  late final _projects = FakeProjectsPagedApi(this);

  @override
  FakeDirectoryApi get directory => _directory;
  @override
  FakeAuditApi get audit => _audit;
  @override
  FakeAdminBaiduApi get adminBaidu => _adminBaidu;
  @override
  FakeApplyTemplatesApi get adminTemplates => _adminTemplates;
  @override
  FakeProjectsPagedApi get projects => _projects;
}

FakeAdminMsApi _install() {
  final api = FakeAdminMsApi();
  session.api = api;
  addTearDown(() {
    session.api = null;
    session.me = null;
  });
  return api;
}

DirectoryUser _user(String id,
        {bool locked = false, bool active = true, bool mustChange = false}) =>
    DirectoryUser(
      id: id,
      username: 'u$id',
      name: '用户$id',
      email: '$id@x.com',
      isActive: active,
      mustChangePassword: mustChange,
      createdAt: '2026-10-20T08:00:00Z',
      loginLocked: locked,
    );

void main() {
  testWidgets('入口双闸门:非 admin 无任何管理磁贴;仅 flag 者仅见目录模板;admin 全见',
      (tester) async {
    Widget host() => MaterialApp(
          home: Builder(
              builder: (context) =>
                  Scaffold(body: Column(children: adminSectionTiles(context)))),
        );

    session.me = Me.fromJson({
      'id': 'u1',
      'name': '普通',
      'is_system_admin': false,
      'is_folder_template_manager': false,
    });
    await tester.pumpWidget(host());
    expect(find.text('管理后台'), findsNothing);
    expect(find.text('目录模板'), findsNothing);

    session.me = Me.fromJson({
      'id': 'u2',
      'name': '模板管理员',
      'is_system_admin': false,
      'is_folder_template_manager': true,
    });
    await tester.pumpWidget(host());
    expect(find.text('管理后台'), findsNothing);
    expect(find.text('目录模板'), findsOneWidget);

    session.me = Me.fromJson({'id': 'u3', 'name': '系统管理员', 'is_system_admin': true});
    await tester.pumpWidget(host());
    expect(find.text('管理后台'), findsOneWidget);
    expect(find.text('目录模板'), findsOneWidget);
  });

  testWidgets('用户页:建号带组提交 → 一次性密码仅回显一次(可复制提示)', (tester) async {
    final api = _install();
    api.directory.usersStaged = DirectoryUsersPage(
        items: [_user('1')], total: 1);
    await tester.pumpWidget(const MaterialApp(home: AdminUsersPage()));
    await tester.pumpAndSettle();
    expect(find.text('用户1'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.person_add_alt_1));
    await tester.pumpAndSettle();
    // 表单字段序(sheet 内):登录名 / 姓名 / 邮箱 / 组搜索
    // (页面背后还有列表搜索框,必须 scope 到 BottomSheet)
    final sheetFields = find.descendant(
        of: find.byType(BottomSheet), matching: find.byType(TextField));
    await tester.enterText(sheetFields.at(0), 'zhangsan');
    await tester.enterText(sheetFields.at(1), '张三');
    // 表单内容超测试视口:滚到提交键再点(ensureVisible 自动定位其滚动源)
    await tester.ensureVisible(find.text('创建'));
    await tester.pump();
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    // 一次性密码弹层:唯一一次展示文案 + 密码本体
    expect(find.text('用户已创建'), findsOneWidget);
    expect(find.text('Tmp-Pass-001'), findsOneWidget);
    expect(find.textContaining('唯一一次'), findsOneWidget);
    expect(api.directory.createCalls.single['group_ids'], isEmpty);
    // 关闭后密码不再出现在树上(仅回显一次)
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('Tmp-Pass-001'), findsNothing);
  });

  testWidgets('用户页:解锁入口仅登录锁定行渲染;确认后调 unlock', (tester) async {
    final api = _install();
    api.directory.usersStaged = DirectoryUsersPage(
        items: [_user('1', locked: true), _user('2')], total: 2);
    await tester.pumpWidget(const MaterialApp(home: AdminUsersPage()));
    await tester.pumpAndSettle();
    expect(find.text('登录已锁定'), findsOneWidget); // 仅 u1

    await tester.tap(find.text('用户1'));
    await tester.pumpAndSettle();
    expect(find.text('解锁'), findsOneWidget);
    await tester.tap(find.text('解锁'));
    await tester.pumpAndSettle();
    expect(find.textContaining('连带清近 24h 失败 IP'), findsOneWidget); // 确认文案
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await tester.pumpAndSettle();
    expect(api.directory.unlockCalls, ['1']);

    // 未锁定行菜单无解锁项
    await tester.tap(find.text('用户2'));
    await tester.pumpAndSettle();
    expect(find.text('解锁'), findsNothing);
  });

  testWidgets('组页:成员管理抽屉移出成员(确认 → DELETE)', (tester) async {
    final api = _install();
    api.directory.groupResult = [
      DirectoryGroup(
        id: 'g1',
        name: '后期组',
        description: null,
        memberCount: 1,
        createdAt: '2026-10-19T08:00:00Z',
        canCreateProject: true,
      ),
    ];
    api.directory.memberResult = [
      GroupMember(
          userId: 'u1',
          username: 'zs',
          name: '张三',
          email: 'z@x.com',
          isActive: true),
    ];
    await tester.pumpWidget(const MaterialApp(home: AdminGroupsPage()));
    await tester.pumpAndSettle();
    expect(find.text('可建项目'), findsOneWidget);

    await tester.tap(find.text('后期组'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('成员管理'));
    await tester.pumpAndSettle();
    expect(find.textContaining('成员 — 后期组'), findsOneWidget);
    expect(find.text('张三'), findsOneWidget);

    await tester.tap(find.text('移出'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '移出'));
    await tester.pumpAndSettle();
    expect(api.directory.removeMemberCalls.single, ('g1', 'u1'));
    // P2-6:移出成功后抽屉驻留(刷新成员列表),不自动关闭
    expect(find.textContaining('成员 — 后期组'), findsOneWidget);
  });

  testWidgets('应用默认:多项目批量勾选 → 确认 → 结果逐项目呈现(部分成功)',
      (tester) async {
    final api = _install();
    api.projects.pagedResult = [
      Project(id: 'p1', name: '婚礼项目', code: 'wed'),
      Project(id: 'p2', name: '灵机项目', code: 'lj'),
    ];
    api.adminTemplates.applyOut = ApplyDefaultResult(
      results: [
        ApplyDefaultResultItem(projectId: 'p1', applied: 3, skippedStale: 1),
        ApplyDefaultResultItem(projectId: 'p2', error: 'fga write failed'),
      ],
      totalApplied: 3,
      totalSkipped: 1,
    );
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: Center(
                    child: FilledButton(
                        onPressed: () => showApplyDefaultSheet(context),
                        child: const Text('open')))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.textContaining('叠加不删'), findsOneWidget);
    await tester.tap(find.text('婚礼项目(wed)'));
    await tester.pump();
    await tester.tap(find.text('灵机项目(lj)'));
    await tester.pump();
    await tester.tap(find.text('刷新'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始刷新'));
    await tester.pumpAndSettle();

    // 结果视图:逐项目呈现 {applied, skipped_stale} / error(部分成功)
    expect(find.textContaining('部分成功:1 个项目已刷新,1 个失败'), findsOneWidget);
    expect(find.text('补写 3'), findsOneWidget);
    expect(find.text('跳过过期 1'), findsOneWidget);
    expect(find.textContaining('失败:fga write failed'), findsOneWidget);
    expect(api.adminTemplates.applyCalls.single, ['p1', 'p2']);
  });

  testWidgets('百度任务详情:non_retryable 置灰 / key_conflict 分流(随机后缀)/ '
      'skipped 行覆盖导入确认', (tester) async {
    final api = _install();
    // P2-4:操作闸门比对任务归属者,本用例以归属者 u1 登录(操作放行)
    session.me = Me.fromJson(
        {'id': 'u1', 'name': '张三', 'is_system_admin': true});
    api.adminBaidu.filesResult = [
      AdminBaiduTaskFile(
          id: 'f1',
          sourcePath: '/盘/a.jpg',
          relPath: '结构超限.jpg',
          status: 'failed',
          nonRetryable: true,
          updatedAt: '2026-10-20T10:00:00Z'),
      AdminBaiduTaskFile(
          id: 'f2',
          sourcePath: '/盘/b.jpg',
          relPath: '冲突.jpg',
          status: 'failed',
          lastError: 'key_conflict:素材/b.jpg 已被成片.jpg占用',
          updatedAt: '2026-10-20T10:00:00Z'),
      AdminBaiduTaskFile(
          id: 'f3',
          sourcePath: '/盘/c.jpg',
          relPath: '重复.jpg',
          status: 'skipped_exists',
          updatedAt: '2026-10-20T10:00:00Z'),
    ];
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: Center(
                    child: FilledButton(
                        onPressed: () => showBaiduTaskDetailSheet(
                            context,
                            AdminBaiduTask.fromJson({
                              'id': 't1',
                              'user': {
                                'id': 'u1',
                                'username': 'zs',
                                'name': '张三'
                              },
                              'status': 'failed',
                              'source_dir': '/灵机备份',
                              'project': {'id': 'p1', 'name': '婚礼项目'},
                              'total_files': 3,
                              'done_files': 0,
                              'failed_files': 3,
                              'skipped_files': 0,
                              'cancelled_files': 0,
                              'total_bytes': 0,
                              'done_bytes': 0,
                              'created_at': '2026-10-20T09:00:00Z',
                              'updated_at': '2026-10-20T10:00:00Z',
                              'cancel_requested': false,
                            })),
                        child: const Text('open')))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 详情头部 + 调度观测字段
    expect(find.textContaining('复活 1 次'), findsOneWidget);
    // ① non_retryable 行:重试置灰(disabled)且文案可读
    final greyed = tester.widget<TextButton>(
        find.ancestor(
            of: find.text('不可重试'), matching: find.byType(TextButton)).first);
    expect(greyed.onPressed, isNull);
    // ② key_conflict 行:分流为随机后缀(非普通重试)
    expect(find.text('随机后缀'), findsOneWidget);
    await tester.tap(find.text('随机后缀'));
    await tester.pumpAndSettle();
    expect(api.adminBaidu.fileOpCalls.single, ('t1', 'f2', 'random-suffix'));
    // 操作成功 → 抽屉带回 true 关闭
    expect(find.text('结构超限.jpg'), findsNothing);

    // ③ 重开抽屉:skipped 行经菜单覆盖导入(确认文案点名删除语义)
    api.adminBaidu.fileOpCalls.clear();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重复.jpg'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('覆盖导入'));
    await tester.pumpAndSettle();
    expect(find.textContaining('永久删除目标位置的原文件后重新导入'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await tester.pumpAndSettle();
    expect(api.adminBaidu.fileOpCalls.single, ('t1', 'f3', 'overwrite'));
  });

  testWidgets('百度任务详情:他人任务文件操作收敛(P2-4:置灰 + 仅任务归属者可操作)',
      (tester) async {
    final api = _install();
    // 登录者 u2 ≠ 任务归属者 u1(_detailOf)
    session.me = Me.fromJson({'id': 'u2', 'name': '路人', 'is_system_admin': true});
    api.adminBaidu.filesResult = [
      AdminBaiduTaskFile(
          id: 'f1',
          sourcePath: '/盘/a.jpg',
          relPath: '失败.jpg',
          status: 'failed',
          updatedAt: '2026-10-20T10:00:00Z'),
    ];
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: Center(
                    child: FilledButton(
                        onPressed: () =>
                            showBaiduTaskDetailSheet(context, _openTask()),
                        child: const Text('open')))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 表头 amber 提示 + 操作置灰(disabled)
    expect(find.textContaining(kOwnerOnlyOpsHint), findsWidgets);
    final greyed = tester.widget<TextButton>(find.ancestor(
        of: find.text('重试'), matching: find.byType(TextButton)).first);
    expect(greyed.onPressed, isNull);
    // 点击不发操作(_own_task 守门必 404,前端先收敛)
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(api.adminBaidu.fileOpCalls, isEmpty);
  });

  testWidgets('百度任务详情:文件明细加载失败 → 错误态 + 重试,不冒充「无文件」(P2-2)',
      (tester) async {
    final api = _install();
    session.me = Me.fromJson({'id': 'u1', 'name': '张三', 'is_system_admin': true});
    api.adminBaidu.filesStaged = Exception('网络开小差');
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: Center(
                    child: FilledButton(
                        onPressed: () =>
                            showBaiduTaskDetailSheet(context, _openTask()),
                        child: const Text('open')))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('无文件'), findsNothing);
    expect(find.textContaining('网络开小差'), findsOneWidget);
    // 重试恢复后渲染文件行
    api.adminBaidu.filesStaged = null;
    api.adminBaidu.filesResult = [
      AdminBaiduTaskFile(
          id: 'f1',
          sourcePath: '/盘/a.jpg',
          relPath: '失败.jpg',
          status: 'failed',
          updatedAt: '2026-10-20T10:00:00Z'),
    ];
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('失败.jpg'), findsOneWidget);
  });

  testWidgets('权限模板表单:已删主体行 amber「已删除」标记(P2-3)', (tester) async {
    _install();
    session.me = Me.fromJson({'id': 'u1', 'name': '张三', 'is_system_admin': true});
    final template = GrantTemplate(
      id: 'gt1',
      name: '标准项目',
      isDefault: false,
      description: '旧描述',
      items: [
        GrantTemplateItem(
            kind: 'user', id: 'u1', roles: const ['viewer'], name: '张三', missing: false),
        GrantTemplateItem(
            kind: 'group', id: 'g9', roles: const ['viewer'], name: '', missing: true),
      ],
    );
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: Center(
                    child: FilledButton(
                        onPressed: () => showGrantTemplateFormSheet(context,
                            template: template),
                        child: const Text('open')))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // missing=true 行:amber「已删除」+ 移除/替换提示;正常行无标记
    expect(find.text('已删除'), findsOneWidget);
    expect(find.text('该主体已被删除,保存前请移除此行或替换主体'), findsOneWidget);
    expect(find.textContaining('张三(用户)'), findsOneWidget);
    expect(find.textContaining('(已删除主体'), findsNothing);
  });
}

AdminBaiduTask _openTask() => AdminBaiduTask.fromJson({
      'id': 't1',
      'user': {'id': 'u1', 'username': 'zs', 'name': '张三'},
      'status': 'failed',
      'source_dir': '/灵机备份',
      'project': {'id': 'p1', 'name': '婚礼项目'},
      'total_files': 3,
      'done_files': 0,
      'failed_files': 3,
      'skipped_files': 0,
      'cancelled_files': 0,
      'total_bytes': 0,
      'done_bytes': 0,
      'created_at': '2026-10-20T09:00:00Z',
      'updated_at': '2026-10-20T10:00:00Z',
      'cancel_requested': false,
    });
