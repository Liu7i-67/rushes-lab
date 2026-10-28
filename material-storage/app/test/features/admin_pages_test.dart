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
import 'package:ms_app/core/api/risk_api.dart' show RiskApi;
import 'package:ms_app/core/api/usage_api.dart'
    show UsageApi, kUsageMetricActiveUsers;
import 'package:ms_app/features/admin/admin_home.dart';
import 'package:ms_app/features/admin/admin_audit_page.dart';
import 'package:ms_app/features/admin/admin_groups_page.dart';
import 'package:ms_app/features/admin/admin_risk_page.dart';
import 'package:ms_app/features/admin/admin_usage_page.dart';
import 'package:ms_app/features/admin/admin_users_page.dart';
import 'package:ms_app/features/admin/apply_default_sheet.dart';
import 'package:ms_app/features/admin/baidu_task_detail_sheet.dart';
import 'package:ms_app/features/admin/baidu_task_file_list.dart'
    show kOwnerOnlyOpsHint;
import 'package:ms_app/features/admin/baidu_task_file_rows.dart'
    show BaiduTaskFileRow;
import 'package:ms_app/features/admin/grant_template_form_sheet.dart'
    show showGrantTemplateFormSheet;
import 'package:ms_app/features/me/admin_tiles.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/models/risk.dart';
import 'package:ms_app/models/usage.dart';
import 'package:ms_app/widgets/badge.dart' as w;
import 'package:ms_app/widgets/app_chip.dart' show AppChip;
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
  Future<DirectoryUsersPage> listUsers({
    String q = '',
    bool? isActive,
    int limit = 20,
    int offset = 0,
  }) async {
    final staged = usersStaged;
    if (staged is Exception) throw staged;
    return staged as DirectoryUsersPage? ??
        DirectoryUsersPage(items: const [], total: 0);
  }

  @override
  Future<DirectoryUserCreated> createUser({
    required String username,
    required String name,
    String? email,
    List<String> groupIds = const [],
  }) async {
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
        temporaryPassword: 'Tmp-Pass-001',
      ),
    );
  }

  @override
  Future<List<DirectoryGroup>> listGroups({
    String q = '',
    int limit = 50,
    int offset = 0,
  }) async {
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
        clearedUserForms: ['zs'],
        clearedIps: const [],
        wasLocked: true,
      ),
    );
  }
}

class FakeAuditApi extends AuditApi {
  FakeAuditApi(super.api);

  List<AuditEvent> listResult = const [];
  final listCalls = <AuditFilter>[];

  @override
  Future<List<AuditEvent>> list({
    AuditFilter filter = const AuditFilter(),
    int limit = 30,
    int offset = 0,
  }) async {
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
  Future<AdminBaiduTaskFilesPage> taskFiles(
    String taskId, {
    String? status,
    int limit = 20,
    int offset = 0,
  }) async {
    final staged = filesStaged;
    if (staged is Exception) throw staged;
    return AdminBaiduTaskFilesPage(
      items: filesResult,
      total: filesResult.length,
    );
  }

  Future<BaiduReviveOut> _op(
    String taskId,
    String fileId,
    String action,
  ) async {
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
    return settleStaged(
      applyOut,
      ApplyDefaultResult(results: const [], totalApplied: 0, totalSkipped: 0),
    );
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

/// 风控域桩(risk-control-module §7.3):锁定快照可编排,unlockIp 记录断言。
class FakeRiskApi extends RiskApi {
  FakeRiskApi(super.api);

  Object? locksStaged;
  var fetchCalls = 0;
  final unlockIpCalls = <String>[];

  @override
  Future<RiskLocks> fetchRiskLocks() async {
    fetchCalls++;
    final staged = locksStaged;
    if (staged is Exception) throw staged;
    return staged as RiskLocks? ?? RiskLocks(users: const [], ips: const []);
  }

  @override
  Future<RiskIpUnlockResult> unlockIp(String ip) async {
    unlockIpCalls.add(ip);
    return RiskIpUnlockResult(ip: ip, wasLocked: true);
  }
}

/// 使用统计域桩:入参记录(窗口/metric 切换断言)+ 桩数据。
class FakeUsageApi extends UsageApi {
  FakeUsageApi(super.api);

  Object? statsStaged;
  final calls = <({String metric, DateTime from, DateTime to})>[];

  @override
  Future<UsageStats> fetchUsageStats({
    required DateTime from,
    required DateTime to,
    String metric = kUsageMetricActiveUsers,
  }) async {
    calls.add((metric: metric, from: from, to: to));
    final staged = statsStaged;
    if (staged is Exception) throw staged;
    return staged as UsageStats? ??
        UsageStats(
          metric: metric,
          from: from.toIso8601String(),
          to: to.toIso8601String(),
          totals: UsageTotals(users: 0, events: 0),
          byPlatform: const [],
          byPlatformClass: const [],
          byNetwork: const [],
          cross: const [],
          daily: const [],
        );
  }
}

class FakeAdminMsApi extends FakeMsApi {
  late final _directory = FakeDirectoryApi(this);
  late final _audit = FakeAuditApi(this);
  late final _adminBaidu = FakeAdminBaiduApi(this);
  late final _adminTemplates = FakeApplyTemplatesApi(this);
  late final _projects = FakeProjectsPagedApi(this);
  late final _risk = FakeRiskApi(this);
  late final _usage = FakeUsageApi(this);

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
  @override
  FakeRiskApi get risk => _risk;
  @override
  FakeUsageApi get usage => _usage;
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

DirectoryUser _user(
  String id, {
  bool locked = false,
  bool active = true,
  bool mustChange = false,
}) => DirectoryUser(
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
  testWidgets('入口双闸门:非 admin 无任何管理磁贴;仅 flag 者仅见目录模板;admin 全见', (tester) async {
    Widget host() => MaterialApp(
      home: Builder(
        builder: (context) =>
            Scaffold(body: Column(children: adminSectionTiles(context))),
      ),
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

    session.me = Me.fromJson({
      'id': 'u3',
      'name': '系统管理员',
      'is_system_admin': true,
    });
    await tester.pumpWidget(host());
    expect(find.text('管理后台'), findsOneWidget);
    expect(find.text('目录模板'), findsOneWidget);
  });

  testWidgets('用户页:建号带组提交 → 一次性密码仅回显一次(可复制提示)', (tester) async {
    final api = _install();
    api.directory.usersStaged = DirectoryUsersPage(
      items: [_user('1')],
      total: 1,
    );
    await tester.pumpWidget(const MaterialApp(home: AdminUsersPage()));
    await tester.pumpAndSettle();
    expect(find.text('用户1'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.person_add_alt_1));
    await tester.pumpAndSettle();
    // 表单字段序(sheet 内):登录名 / 姓名 / 邮箱 / 组搜索
    // (页面背后还有列表搜索框,必须 scope 到 BottomSheet)
    final sheetFields = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(TextField),
    );
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
      items: [_user('1', locked: true), _user('2')],
      total: 2,
    );
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

  testWidgets('用户页:正常/停用状态徽标 + 头像邮箱行卡(墨金行卡)', (tester) async {
    final api = _install();
    api.directory.usersStaged = DirectoryUsersPage(
      items: [_user('1'), _user('2', active: false)],
      total: 2,
    );
    await tester.pumpWidget(const MaterialApp(home: AdminUsersPage()));
    await tester.pumpAndSettle();

    // 正常=ok / 停用=warn;邮箱 13/ink3 作副标题
    expect(find.widgetWithText(w.Badge, '正常'), findsOneWidget);
    expect(find.widgetWithText(w.Badge, '停用'), findsOneWidget);
    expect(find.text('1@x.com'), findsOneWidget);
    expect(find.text('2@x.com'), findsOneWidget);
    // 分页计数进 PageHeader 副标题
    expect(find.text('共 2 名用户'), findsOneWidget);
  });

  testWidgets('用户页 320 宽 + 字号 1.3:满徽标行卡不 overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = _install();
    api.directory.usersStaged = DirectoryUsersPage(
      items: [
        _user('1', locked: true, mustChange: true),
        _user('2', active: false),
      ],
      total: 2,
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: const AdminUsersPage(),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: '320×640 + 1.3 无 overflow');
    expect(find.text('用户1'), findsOneWidget);
  });

  testWidgets('审计页:PageHeader + 快捷 chip + 金色竖线时间线;chip 映射 eventType', (
    tester,
  ) async {
    final api = _install();
    api.audit.listResult = [
      AuditEvent.fromJson({
        'id': 'a1',
        'event_type': 'upload',
        'event_time': '2026-10-20T09:00:00Z',
        'actor_name': '张三',
        'target_project_name': '婚礼项目',
        'target_asset_filename': '封面.jpg',
        'resolved_names': <String, dynamic>{},
        'details': <String, dynamic>{},
      }),
      AuditEvent.fromJson({
        'id': 'a2',
        'event_type': 'download',
        'event_time': '2026-10-20T08:00:00Z',
        'actor_name': '李四',
        'resolved_names': <String, dynamic>{},
        'details': <String, dynamic>{},
      }),
    ];
    await tester.pumpWidget(const MaterialApp(home: AdminAuditPage()));
    await tester.pumpAndSettle();

    expect(find.text('审计日志'), findsOneWidget);
    expect(find.text('关键操作留痕，保留 180 天'), findsOneWidget);
    expect(find.byTooltip('导出 CSV'), findsOneWidget);
    expect(find.text('全部'), findsOneWidget); // 快捷 chip
    expect(find.text('上传'), findsWidgets); // chip + 事件标题
    expect(find.textContaining('张三'), findsOneWidget);
    // 每条事件一行金色 2px 时间线
    expect(find.byKey(const Key('audit-timeline-line')), findsNWidgets(2));

    // 快捷 chip「下载」→ 精确 eventType 筛选(数据流保留;事件标题同名,
    // 按 AppChip 定位避免歧义)
    await tester.tap(find.widgetWithText(AppChip, '下载'));
    await tester.pumpAndSettle();
    expect(api.audit.listCalls.last.eventType, 'download');
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
        isActive: true,
      ),
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

  testWidgets('应用默认:多项目批量勾选 → 确认 → 结果逐项目呈现(部分成功)', (tester) async {
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
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showApplyDefaultSheet(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
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
    session.me = Me.fromJson({
      'id': 'u1',
      'name': '张三',
      'is_system_admin': true,
    });
    api.adminBaidu.filesResult = [
      AdminBaiduTaskFile(
        id: 'f1',
        sourcePath: '/盘/a.jpg',
        relPath: '结构超限.jpg',
        status: 'failed',
        nonRetryable: true,
        updatedAt: '2026-10-20T10:00:00Z',
      ),
      AdminBaiduTaskFile(
        id: 'f2',
        sourcePath: '/盘/b.jpg',
        relPath: '冲突.jpg',
        status: 'failed',
        lastError: 'key_conflict:素材/b.jpg 已被成片.jpg占用',
        updatedAt: '2026-10-20T10:00:00Z',
      ),
      AdminBaiduTaskFile(
        id: 'f3',
        sourcePath: '/盘/c.jpg',
        relPath: '重复.jpg',
        status: 'skipped_exists',
        updatedAt: '2026-10-20T10:00:00Z',
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showBaiduTaskDetailSheet(
                  context,
                  AdminBaiduTask.fromJson({
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
                  }),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 详情头部 + 调度观测字段
    expect(find.textContaining('复活 1 次'), findsOneWidget);
    // 文件明细拆件后逐行渲染(baidu_task_file_rows.dart)
    expect(find.byType(BaiduTaskFileRow), findsWidgets);
    // ① non_retryable 行:重试置灰(disabled)且文案可读
    final greyed = tester.widget<TextButton>(
      find
          .ancestor(of: find.text('不可重试'), matching: find.byType(TextButton))
          .first,
    );
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

  testWidgets('百度任务详情:他人任务文件操作收敛(P2-4:置灰 + 仅任务归属者可操作)', (tester) async {
    final api = _install();
    // 登录者 u2 ≠ 任务归属者 u1(_detailOf)
    session.me = Me.fromJson({
      'id': 'u2',
      'name': '路人',
      'is_system_admin': true,
    });
    api.adminBaidu.filesResult = [
      AdminBaiduTaskFile(
        id: 'f1',
        sourcePath: '/盘/a.jpg',
        relPath: '失败.jpg',
        status: 'failed',
        updatedAt: '2026-10-20T10:00:00Z',
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showBaiduTaskDetailSheet(context, _openTask()),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 表头 amber 提示 + 操作置灰(disabled)
    expect(find.textContaining(kOwnerOnlyOpsHint), findsWidgets);
    final greyed = tester.widget<TextButton>(
      find
          .ancestor(of: find.text('重试'), matching: find.byType(TextButton))
          .first,
    );
    expect(greyed.onPressed, isNull);
    // 点击不发操作(_own_task 守门必 404,前端先收敛)
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(api.adminBaidu.fileOpCalls, isEmpty);
  });

  testWidgets('百度任务详情:文件明细加载失败 → 错误态 + 重试,不冒充「无文件」(P2-2)', (tester) async {
    final api = _install();
    session.me = Me.fromJson({
      'id': 'u1',
      'name': '张三',
      'is_system_admin': true,
    });
    api.adminBaidu.filesStaged = Exception('网络开小差');
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showBaiduTaskDetailSheet(context, _openTask()),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('无文件'), findsNothing);
    // E14(app-polish):原始异常对象不再 `'$e'` 直出,统一 errorMessage 中文
    // 兜底;断言场景不变——错误态以用户文案呈现(非「无文件」),重试可恢复
    expect(find.textContaining('加载失败'), findsOneWidget);
    // 重试恢复后渲染文件行
    api.adminBaidu.filesStaged = null;
    api.adminBaidu.filesResult = [
      AdminBaiduTaskFile(
        id: 'f1',
        sourcePath: '/盘/a.jpg',
        relPath: '失败.jpg',
        status: 'failed',
        updatedAt: '2026-10-20T10:00:00Z',
      ),
    ];
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('失败.jpg'), findsOneWidget);
  });

  testWidgets('权限模板表单:已删主体行 amber「已删除」标记(P2-3)', (tester) async {
    _install();
    session.me = Me.fromJson({
      'id': 'u1',
      'name': '张三',
      'is_system_admin': true,
    });
    final template = GrantTemplate(
      id: 'gt1',
      name: '标准项目',
      isDefault: false,
      description: '旧描述',
      items: [
        GrantTemplateItem(
          kind: 'user',
          id: 'u1',
          roles: const ['viewer'],
          name: '张三',
          missing: false,
        ),
        GrantTemplateItem(
          kind: 'group',
          id: 'g9',
          roles: const ['viewer'],
          name: '',
          missing: true,
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () =>
                    showGrantTemplateFormSheet(context, template: template),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // missing=true 行:amber「已删除」+ 移除/替换提示;正常行无标记
    expect(find.text('已删除'), findsOneWidget);
    expect(find.text('该主体已被删除,保存前请移除此行或替换主体'), findsOneWidget);
    expect(find.textContaining('张三(用户)'), findsOneWidget);
    expect(find.textContaining('(已删除主体'), findsNothing);
  });

  // ── 风控 / 使用统计(risk-control-module-plan §5/§7.3,2026-10-28)────────

  testWidgets('风控/使用统计:非 admin 深链直接锁定 EmptyState(页面级闸刻意加严)', (tester) async {
    _install();
    session.me = Me.fromJson({
      'id': 'u1',
      'name': '普通',
      'is_system_admin': false,
    });
    await tester.pumpWidget(const MaterialApp(home: AdminRiskPage()));
    await tester.pumpAndSettle();
    expect(find.text('只有系统管理员可以进入登录风控'), findsOneWidget);
    expect(find.text('当前无任何登录锁定'), findsNothing);

    await tester.pumpWidget(const MaterialApp(home: AdminUsagePage()));
    await tester.pumpAndSettle();
    expect(find.text('只有系统管理员可以查看使用统计'), findsOneWidget);
  });

  testWidgets('管理后台:风控/使用统计磁贴渲染,_open 直推风控页', (tester) async {
    final api = _install();
    session.me = _adminMe();
    api.risk.locksStaged = RiskLocks(users: const [], ips: const []);
    await tester.pumpWidget(const MaterialApp(home: AdminHomePage()));
    await tester.pumpAndSettle();
    expect(find.text('风控'), findsOneWidget);
    expect(find.text('使用统计'), findsOneWidget);

    // 既有范式:磁贴 _open(context, const XxxPage()) 直推,不走 pushNamed
    await tester.tap(find.text('风控'));
    await tester.pumpAndSettle();
    expect(find.text('登录风控'), findsOneWidget);
    expect(find.text('当前无任何登录锁定'), findsOneWidget);
  });

  testWidgets('风控页:三态账号行 + unknown IP 标注;none/ambiguous 无解锁入口', (tester) async {
    final api = _install();
    session.me = _adminMe();
    api.risk.locksStaged = _riskLocks();
    await tester.pumpWidget(const MaterialApp(home: AdminRiskPage()));
    await tester.pumpAndSettle();

    // unique 主标题 = 账号名(name(username));none / ambiguous = form 原文 + 徽标
    expect(find.text('张三(zhangsan)'), findsOneWidget);
    expect(find.text('zhansa'), findsOneWidget);
    expect(find.text('laowang'), findsOneWidget);
    expect(find.widgetWithText(w.Badge, '未匹配账号'), findsOneWidget);
    expect(find.widgetWithText(w.Badge, '重名歧义'), findsOneWidget);
    // unknown 哨兵:如实展示 + 「未知 IP」标注(§3.1,不静默过滤)
    expect(find.text('unknown'), findsOneWidget);
    expect(find.widgetWithText(w.Badge, '未知 IP'), findsOneWidget);
    expect(find.textContaining('链路异常(IP 缺失)'), findsOneWidget);
    // 剩余约 N 分钟:742s 上取整 = 13 分钟;失败次数 = 当前窗口计数
    expect(find.textContaining('剩余约 13 分钟'), findsOneWidget);
    expect(find.textContaining('当前窗口失败 3 次'), findsOneWidget);
    expect(find.textContaining('近 24h:zhangsan, zhansa'), findsOneWidget);

    // none 行无动作:点行不出弹层(D4)
    await tester.tap(find.text('zhansa'));
    await tester.pumpAndSettle();
    expect(find.text('解锁'), findsNothing);
  });

  testWidgets('风控页:unique 行解锁 + unknown IP 解除(记录式断言)', (tester) async {
    final api = _install();
    session.me = _adminMe();
    api.risk.locksStaged = _riskLocks();
    await tester.pumpWidget(const MaterialApp(home: AdminRiskPage()));
    await tester.pumpAndSettle();
    final fetchesAfterLoad = api.risk.fetchCalls;

    // 账号解锁:行 → 底部弹层 → showAppConfirm → directory.unlockUser → 刷新
    await tester.tap(find.text('张三(zhangsan)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('解锁'));
    await tester.pumpAndSettle();
    expect(find.textContaining('连带清近 24h 失败 IP 的锁'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await tester.pumpAndSettle();
    expect(api.directory.unlockCalls, ['u1']);
    expect(api.risk.fetchCalls, greaterThan(fetchesAfterLoad)); // 解锁后刷新

    // IP 解除(unknown 哨兵可解):弹层 → 确认 → risk.unlockIp 记录
    await tester.tap(find.text('unknown'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('解除锁定'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请确认非暴力破解来源'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await tester.pumpAndSettle();
    expect(api.risk.unlockIpCalls, ['unknown']);
  });

  testWidgets('使用统计页:默认 30 天活跃用户渲染;切近 7 天 / 登录次数重取数', (tester) async {
    final api = _install();
    session.me = _adminMe();
    api.usage.statsStaged = _usageStats();
    await tester.pumpWidget(const MaterialApp(home: AdminUsagePage()));
    await tester.pumpAndSettle();

    // 默认窗口 = 本地时区「今日 -(N-1) 天零点 → now」(web defaultRange 同口径)
    final todayStart = DateTime(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
    );
    expect(api.usage.calls.first.metric, kUsageMetricActiveUsers);
    expect(
      api.usage.calls.first.from,
      todayStart.subtract(const Duration(days: 29)),
    );

    // StatRow totals + 各分组行(AppRow)+ cross + daily(按日聚合 events,倒序)
    expect(find.text('42'), findsOneWidget);
    expect(find.text('1234'), findsOneWidget);
    expect(find.text('网页(三端合并)'), findsOneWidget);
    expect(find.text('网页 · 桌面'), findsOneWidget);
    expect(find.text('Android App'), findsNWidgets(2)); // class + platform 各一行

    // 列表懒构建:滚到页脚,让下半部(内外网/交叉/按日/页脚)进入构建范围
    await tester.dragUntilVisible(
      find.textContaining('跨组数字不可加总'),
      find.byType(ListView).last,
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();

    expect(find.text('内网'), findsOneWidget);
    expect(find.text('Android App · 内网'), findsOneWidget);
    // daily:2026-10-26 两条三元组 events 11+7=18;最近日期在前
    expect(find.text('2026-10-27'), findsOneWidget);
    expect(find.text('30 条事件'), findsOneWidget);
    expect(find.text('2026-10-26'), findsOneWidget);
    expect(find.text('18 条事件'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('2026-10-27')).dy,
      lessThan(tester.getTopLeft(find.text('2026-10-26')).dy),
    );
    expect(find.textContaining('跨组数字不可加总'), findsOneWidget);

    // 切窗口 → 重取数(days=7)
    await tester.tap(find.text('近 7 天'));
    await tester.pumpAndSettle();
    expect(
      api.usage.calls.last.from,
      todayStart.subtract(const Duration(days: 6)),
    );
    // 切 metric → logins
    await tester.tap(find.text('登录次数'));
    await tester.pumpAndSettle();
    expect(api.usage.calls.last.metric, 'logins');
  });

  testWidgets('使用统计页:totals 双零 → 空数据态', (tester) async {
    final api = _install();
    session.me = _adminMe();
    api.usage.statsStaged = UsageStats(
      metric: 'active_users',
      from: '2026-09-29T00:00:00.000Z',
      to: '2026-10-28T10:00:00.000Z',
      totals: UsageTotals(users: 0, events: 0),
    );
    await tester.pumpWidget(const MaterialApp(home: AdminUsagePage()));
    await tester.pumpAndSettle();
    expect(find.text('所选时间范围内暂无可用数据'), findsOneWidget);
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

/// 风控桩数据(§3.1 契约):unique / none / ambiguous 三态 + 普通与 unknown IP。
RiskLocks _riskLocks() => RiskLocks(
  users: [
    RiskUserLock(
      form: 'zhangsan',
      match: RiskUserLockMatch.unique,
      matchedUsers: [
        RiskMatchedUser(id: 'u1', username: 'zhangsan', name: '张三'),
      ],
      failCount: 3,
      lockTtlSeconds: 742,
    ),
    RiskUserLock(
      form: 'zhansa',
      match: RiskUserLockMatch.none,
      matchedUsers: const [],
      failCount: 5,
      lockTtlSeconds: 59,
    ),
    RiskUserLock(
      form: 'laowang',
      match: RiskUserLockMatch.ambiguous,
      matchedUsers: [
        RiskMatchedUser(id: 'u2', username: null, name: '老王'),
        RiskMatchedUser(id: 'u3', username: 'laowang2', name: '老王'),
      ],
      failCount: 2,
      lockTtlSeconds: 300,
    ),
  ],
  ips: [
    RiskIpLock(
      ip: '112.193.57.210',
      failCount: 5,
      lockTtlSeconds: 711,
      recentFailedUserforms: const ['zhangsan', 'zhansa'],
    ),
    RiskIpLock(
      ip: 'unknown',
      failCount: 1,
      lockTtlSeconds: 60,
      recentFailedUserforms: const [],
    ),
  ],
);

/// 使用统计桩数据:三端 / 明细 / 内外网 / 交叉 / daily(两日多条三元组)。
UsageStats _usageStats() => UsageStats(
  metric: 'active_users',
  from: '2026-09-29T00:00:00.000Z',
  to: '2026-10-28T10:00:00.000Z',
  totals: UsageTotals(users: 42, events: 1234),
  byPlatformClass: [
    UsageGroupRow(name: 'web', users: 30, events: 800),
    UsageGroupRow(name: 'android_app', users: 10, events: 300),
    UsageGroupRow(name: 'ios_app', users: 2, events: 134),
  ],
  byPlatform: [
    UsageGroupRow(name: 'web_desktop', users: 18, events: 500),
    UsageGroupRow(name: 'web_mobile', users: 12, events: 300),
    UsageGroupRow(name: 'android_app', users: 10, events: 300),
  ],
  byNetwork: [
    UsageGroupRow(name: 'lan', users: 40, events: 1200),
    UsageGroupRow(name: 'wan', users: 8, events: 34),
  ],
  cross: [
    UsageCrossRow(
      platform: 'android_app',
      network: 'lan',
      users: 10,
      events: 300,
    ),
  ],
  daily: [
    UsageDailyRow(
      date: '2026-10-26',
      platform: 'web',
      network: 'lan',
      users: 5,
      events: 11,
    ),
    UsageDailyRow(
      date: '2026-10-26',
      platform: 'android_app',
      network: 'wan',
      users: 3,
      events: 7,
    ),
    UsageDailyRow(
      date: '2026-10-27',
      platform: 'web',
      network: 'lan',
      users: 6,
      events: 30,
    ),
  ],
);

Me _adminMe() =>
    Me.fromJson({'id': 'u9', 'name': '管理员', 'is_system_admin': true});
