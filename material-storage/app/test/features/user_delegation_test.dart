/// 用户模块组级授权开放(docs/qdev/2026-11-15-user-delegation.md §7 A1-A5)
/// widget 测试:A1 被授权非 admin 磁贴弱门(用户磁贴可见/用户组磁贴不可见,
/// admin home 深链兜底)、A2 用户行创建人列与非 admin 行菜单(§13 放开:
/// 编辑/停用|启用/重置密码,解锁仍 admin-only)、
/// A3 建号表单组选项=me.userCreateGroups(受限态禁远程搜索)与提交体、
/// A4 组表单用户模块开关+目标组多选(编辑态预填/不动不携带/开关关→[]/建组
/// 态携带)、A5 admin 不回归(全磁贴/全菜单/建号组选项走远程搜索)。
/// §11 增量(2026-11-16):建号 sheet 姓名预填=操作者姓名去末段前缀
/// (含 `_` 截前缀/无 `_` 预填空)。§13 增量(2026-11-16 ③):非 admin 编辑
/// sheet 组字段受限本地多选(选项=授权目标组,不打 groups 接口)。
///
/// 假 API 族本文件自持(照 admin_pages_test.dart 记录式桩风格),directory 桩
/// 按 §5.2/§5.3 契约扩展(created_by_name / user_create_group_ids);Me 经
/// Me.fromJson 注入 §5.4 新键 is_user_manager / user_create_groups(弱门回落
/// 同 is_folder_template_manager 先例:构造缺省回落 is_system_admin)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/directory_api.dart'
    show DirectoryApi, UnlockResult;
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/admin/admin_groups_page.dart';
import 'package:ms_app/features/admin/admin_home.dart';
import 'package:ms_app/features/admin/admin_users_page.dart';
import 'package:ms_app/features/me/admin_tiles.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart' show FakeMsApi, settleStaged;

// ── 假 API 族(记录式;directory 域含本次新契约字段)────────────────────────

class FakeDirectoryApi extends DirectoryApi {
  FakeDirectoryApi(super.api);

  Object? usersStaged;
  Object? userDetailStaged;
  List<DirectoryGroup> groupResult = const [];
  final createCalls = <Map<String, dynamic>>[];
  final updateCalls = <Map<String, dynamic>>[];
  final resetCalls = <String>[];
  final unlockCalls = <String>[];
  final createGroupCalls = <Map<String, dynamic>>[];
  final updateGroupCalls = <Map<String, dynamic>>[];
  var listGroupCalls = 0;

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
      null,
      DirectoryUserCreated(
        id: 'u9',
        username: username,
        name: name,
        email: email,
        isActive: true,
        mustChangePassword: true,
        createdAt: '2026-11-15T09:00:00Z',
        temporaryPassword: 'Tmp-Pass-001',
      ),
    );
  }

  @override
  Future<DirectoryUserDetail> getUser(String userId) async {
    final staged = userDetailStaged;
    if (staged is Exception) throw staged;
    return staged as DirectoryUserDetail? ??
        DirectoryUserDetail(
          id: userId,
          username: 'u$userId',
          name: '用户$userId',
          email: '$userId@x.com',
          isActive: true,
          mustChangePassword: false,
          createdAt: '2026-11-14T08:00:00Z',
          groupIds: const [],
          groupNames: const [],
        );
  }

  @override
  Future<DirectoryUser> updateUser(
    String userId, {
    required String name,
    Object? email,
    required List<String> groupIds,
  }) async {
    updateCalls.add({
      'id': userId,
      'name': name,
      'email': email,
      'group_ids': groupIds,
    });
    return DirectoryUser(
      id: userId,
      username: 'u$userId',
      name: name,
      email: email as String?,
      isActive: true,
      mustChangePassword: false,
      createdAt: '2026-11-14T08:00:00Z',
    );
  }

  @override
  Future<String> resetPassword(String userId) async {
    resetCalls.add(userId);
    return 'New-Tmp-777';
  }

  @override
  Future<UnlockResult> unlockUser(String userId) async {
    unlockCalls.add(userId);
    return UnlockResult(
      clearedUserForms: const ['zs'],
      clearedIps: const [],
      wasLocked: true,
    );
  }

  @override
  Future<List<DirectoryGroup>> listGroups({
    String q = '',
    int limit = 50,
    int offset = 0,
  }) async {
    listGroupCalls++;
    return groupResult;
  }

  @override
  Future<DirectoryGroup> createGroup({
    required String name,
    String? description,
    bool canCreateProject = false,
    bool canManageFolderTemplates = false,
    bool canCreateArtistAccount = false,
    bool canDeleteFiles = false,
    List<String> userCreateGroupIds = const [],
  }) async {
    createGroupCalls.add({
      'name': name,
      'description': description,
      'user_create_group_ids': userCreateGroupIds,
    });
    return _group('ng1', name, userCreateGroupIds: userCreateGroupIds);
  }

  @override
  Future<DirectoryGroup> updateGroup(
    String groupId, {
    String? name,
    String? description,
    bool? canCreateProject,
    bool? canDeleteProject,
    bool? canManageFolderTemplates,
    bool? canCreateArtistAccount,
    bool? canDeleteFiles,
    List<String>? userCreateGroupIds,
  }) async {
    updateGroupCalls.add({
      'id': groupId,
      'name': name,
      // tri-state:null=字段省略不动(组授权撤销语义 []=清空)
      'user_create_group_ids': userCreateGroupIds,
    });
    return _group(
      groupId,
      name ?? '组$groupId',
      userCreateGroupIds: userCreateGroupIds ?? const [],
    );
  }
}

class FakeDelegationMsApi extends FakeMsApi {
  late final _directory = FakeDirectoryApi(this);

  @override
  FakeDirectoryApi get directory => _directory;
}

FakeDelegationMsApi _install() {
  final api = FakeDelegationMsApi();
  session.api = api;
  addTearDown(() {
    session.api = null;
    session.me = null;
  });
  return api;
}

// ── 造数助手 ─────────────────────────────────────────────────────────────────

/// 被授权非 admin(§5.4:is_user_manager=true + user_create_groups=目标组集合)。
Me _delegatedMe() => Me.fromJson({
  'id': 'u9',
  'name': '组长小王',
  'is_system_admin': false,
  'is_user_manager': true,
  'user_create_groups': [
    {'id': 'ga', 'name': 'A组'},
    {'id': 'gc', 'name': 'C组'},
  ],
});

/// admin(用户模块恒开;user_create_groups 恒 [] — 全量选项走远程搜索)。
Me _adminMe() =>
    Me.fromJson({'id': 'u1', 'name': '系统管理员', 'is_system_admin': true});

DirectoryUser _user(
  String id, {
  bool locked = false,
  bool active = true,
  String? createdByName,
}) => DirectoryUser(
  id: id,
  username: 'u$id',
  name: '用户$id',
  email: '$id@x.com',
  isActive: active,
  mustChangePassword: false,
  createdAt: '2026-11-14T08:00:00Z',
  loginLocked: locked,
  createdByName: createdByName,
);

DirectoryGroup _group(
  String id,
  String name, {
  List<String> userCreateGroupIds = const [],
}) => DirectoryGroup(
  id: id,
  name: name,
  description: null,
  memberCount: 2,
  createdAt: '2026-11-14T08:00:00Z',
  userCreateGroupIds: userCreateGroupIds,
);

/// 建号表单 sheet 内文本字段序(登录名 / 姓名 / 邮箱,后续可能是组选择字段)。
Finder get _sheetFields => find.descendant(
  of: find.byType(BottomSheet),
  matching: find.byType(TextField),
);

/// 用户模块开关(SwitchListTile 标题含「用户模块」;标题文案随实现微调)。
Finder get _userModuleTile => find.ancestor(
  of: find.textContaining('用户模块'),
  matching: find.byType(SwitchListTile),
);

bool _userModuleOn(WidgetTester tester) =>
    tester.widget<SwitchListTile>(_userModuleTile.first).value;

// ── 用例 ─────────────────────────────────────────────────────────────────────

void main() {
  // A1:被授权非 admin — 我的页磁贴弱门(三态)。
  testWidgets('A1:我的页磁贴 — 被授权非 admin 用户磁贴可见、管理后台(用户组)磁贴不可见', (tester) async {
    Widget host() => MaterialApp(
      home: Builder(
        builder: (context) =>
            Scaffold(body: Column(children: adminSectionTiles(context))),
      ),
    );

    // 未授权普通成员:无任何管理磁贴
    session.me = Me.fromJson({
      'id': 'u0',
      'name': '普通',
      'is_system_admin': false,
    });
    await tester.pumpWidget(host());
    expect(find.text('用户'), findsNothing);
    expect(find.text('管理后台'), findsNothing);

    // 被授权非 admin:用户磁贴可见;管理后台磁贴(用户组等 admin 专区)不可见
    session.me = _delegatedMe();
    await tester.pumpWidget(host());
    expect(find.text('用户'), findsOneWidget);
    expect(find.text('管理后台'), findsNothing);
    expect(find.text('目录模板'), findsNothing);

    // admin:管理后台磁贴在(用户/用户组经其后二级磁贴呈现)
    session.me = _adminMe();
    await tester.pumpWidget(host());
    expect(find.text('管理后台'), findsOneWidget);
  });

  // A1:admin home 深链兜底弱门 — 被授权非 admin 仅见用户磁贴。
  testWidgets('A1:admin home 深链 — 被授权非 admin 仅见用户磁贴,无用户组/审计磁贴', (tester) async {
    _install();
    session.me = _delegatedMe();
    await tester.pumpWidget(const MaterialApp(home: AdminHomePage()));
    await tester.pumpAndSettle();

    expect(find.text('用户'), findsOneWidget);
    expect(find.text('用户组'), findsNothing);
    expect(find.text('审计日志'), findsNothing);
    expect(find.text('备份任务'), findsNothing);
  });

  // A2:创建人列(有值显示/空显示 —)+ §13 非 admin 行菜单放开(编辑/停用
  // |启用,解锁仍 admin-only)+ 重置全流程。
  testWidgets('A2:用户行 — 创建人有值显示名字、空显示 —;非 admin 菜单=编辑/停用/重置密码且无解锁', (
    tester,
  ) async {
    final api = _install();
    session.me = _delegatedMe();
    api.directory.usersStaged = DirectoryUsersPage(
      items: [
        _user('1', createdByName: '张三'),
        _user('2'),
        _user('3', locked: true, createdByName: '张三'),
      ],
      total: 3,
    );
    await tester.pumpWidget(const MaterialApp(home: AdminUsersPage()));
    await tester.pumpAndSettle();

    // 创建人列:有值回显 created_by_name;无来源(NULL)显示 —
    expect(find.textContaining('创建人'), findsWidgets);
    expect(find.textContaining('张三'), findsWidgets);
    expect(find.textContaining('—'), findsOneWidget, reason: '无创建人行显示 —');

    // §13 菜单放开:锁定行(自建)出现 编辑/停用(active 走停用侧)/重置密码;
    // 「解锁」仍 admin-only(D12)不渲染;「启用」不出现(active 对称面);
    // 断言 scope 到菜单 sheet — 页面筛选 chip 轨有同名「停用/启用」
    await tester.tap(find.text('用户3'));
    await tester.pumpAndSettle();
    final menu = find.byType(BottomSheet);
    expect(
      find.descendant(of: menu, matching: find.text('编辑')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: menu, matching: find.text('停用')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: menu, matching: find.text('重置密码')),
      findsOneWidget,
    );
    expect(find.descendant(of: menu, matching: find.text('启用')), findsNothing);
    expect(find.descendant(of: menu, matching: find.text('解锁')), findsNothing);

    // 重置密码全流程可用:确认 → 端点 → 一次性密码回显
    await tester.tap(find.text('重置密码'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await tester.pumpAndSettle();
    expect(api.directory.resetCalls, ['3']);
    expect(find.text('New-Tmp-777'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('New-Tmp-777'), findsNothing);
  });

  // §13 增量(2026-11-16 ③):非 admin 打开编辑 sheet — 组字段=受限本地
  // 多选(选项=授权目标组,不打 groups 接口/无远程搜索),预填=当前所属 ∩
  // 授权范围(越界组不显),保存提交体=勾选终态(全量同步移除越界组)。
  testWidgets('§13:非 admin 编辑 sheet — 组选项=授权目标组,预填交集,提交体 group_ids 全量同步', (
    tester,
  ) async {
    final api = _install();
    session.me = _delegatedMe(); // 授权目标组:A组(ga)/C组(gc)
    api.directory.usersStaged = DirectoryUsersPage(
      items: [_user('1', createdByName: '张三')],
      total: 1,
    );
    // 若误走 admin-only groups 接口,结果也不含授权组,断言必炸
    api.directory.groupResult = [_group('gb', 'B组')];
    // 详情:当前持有越界组 gb(如管理员后加),授权范围内仅 A组
    api.directory.userDetailStaged = DirectoryUserDetail(
      id: '1',
      username: 'u1',
      name: '用户1',
      email: '1@x.com',
      isActive: true,
      mustChangePassword: false,
      createdAt: '2026-11-14T08:00:00Z',
      groupIds: const ['ga', 'gb'],
      groupNames: const ['A组', 'B组'],
    );
    await tester.pumpWidget(const MaterialApp(home: AdminUsersPage()));
    await tester.pumpAndSettle();

    // 行菜单 → 编辑
    await tester.tap(find.text('用户1'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(BottomSheet), matching: find.text('编辑')),
    );
    await tester.pumpAndSettle();

    // 受限组字段:预填=当前所属 ∩ 授权范围=A组(单组显示组名,越界 gb 不显);
    // 未打 admin-only groups 接口
    expect(find.text('A组'), findsOneWidget, reason: '预填交集单组显示组名');
    expect(api.directory.listGroupCalls, 0, reason: '非 admin 不打 groups 接口');

    // 点字段弹受限多选弹层:候选=授权目标组 A组/C组(B组不在列,无远程
    // 搜索);scope 到顶层 sheet(.last — 底层编辑 sheet 同为 BottomSheet,
    // 其组字段预填值也是「A组」)
    await tester.tap(find.widgetWithText(TextField, 'A组'));
    await tester.pumpAndSettle();
    final pickSheet = find.byType(BottomSheet).last;
    expect(
      find.descendant(of: pickSheet, matching: find.text('A组')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: pickSheet, matching: find.text('C组')),
      findsOneWidget,
    );
    expect(find.text('B组'), findsNothing);
    expect(api.users.groupSearchCalls, isEmpty, reason: '受限态禁远程搜索');

    // 勾 C组 → 完成(2) → 字段回显「2 组」
    await tester.tap(find.descendant(of: pickSheet, matching: find.text('C组')));
    await tester.pump();
    await tester.tap(find.text('完成(2)'));
    await tester.pumpAndSettle();
    expect(find.text('2 组'), findsOneWidget);

    // 保存 → 提交体:group_ids=勾选终态 ga/gc(越界 gb 被全量同步移除);
    // 姓名回显携带、邮箱留原值非 null
    await tester.ensureVisible(find.text('保存'));
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(api.directory.updateCalls.single['id'], '1');
    expect(api.directory.updateCalls.single['name'], '用户1');
    expect(api.directory.updateCalls.single['email'], '1@x.com');
    expect(api.directory.updateCalls.single['group_ids'], ['ga', 'gc']);
  });

  // A3:非 admin 建号 — 组选项=me.userCreateGroups(受限态禁远程搜索),提交体正确。
  testWidgets('A3:非 admin 建号 — 组选项仅授权目标组(禁远程搜索),提交体 group_ids 正确', (
    tester,
  ) async {
    final api = _install();
    session.me = _delegatedMe();
    api.directory.usersStaged = DirectoryUsersPage(items: const [], total: 0);
    await tester.pumpWidget(const MaterialApp(home: AdminUsersPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.person_add_alt_1));
    await tester.pumpAndSettle();

    // 受限态:组字段为本地受限多选(空值 hint),点按弹「选择用户组」本地弹层
    // (无远程搜索);字段本体是只读 TextField(hint 在 decoration 内),点它
    expect(find.text('点击选择所属用户组'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextField, '点击选择所属用户组'));
    await tester.pumpAndSettle();

    // 受限弹层:候选=me.userCreateGroups(A组/C组),未授权组不在列,不发远程搜索
    final sheet = find.byType(BottomSheet);
    expect(
      find.descendant(of: sheet, matching: find.text('A组')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: find.text('C组')),
      findsOneWidget,
    );
    expect(find.text('B组'), findsNothing);
    expect(api.users.groupSearchCalls, isEmpty, reason: '受限态禁远程搜索');

    // 勾选 A组 + C组 → 完成(2) 回填字段
    await tester.tap(find.descendant(of: sheet, matching: find.text('A组')));
    await tester.pump();
    await tester.tap(find.descendant(of: sheet, matching: find.text('C组')));
    await tester.pump();
    await tester.tap(find.text('完成(2)'));
    await tester.pumpAndSettle();
    expect(find.text('2 组'), findsOneWidget, reason: '多组展示文案「N 组」');

    await tester.enterText(_sheetFields.at(0), 'zhangsan');
    await tester.enterText(_sheetFields.at(1), '张三');
    await tester.ensureVisible(find.text('创建'));
    await tester.pump();
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(api.directory.createCalls.single['group_ids'], ['ga', 'gc']);
    // 一次性临时密码回显流程不回归
    expect(find.text('用户已创建'), findsOneWidget);
    expect(find.text('Tmp-Pass-001'), findsOneWidget);
  });

  // A4:组表单编辑态 — 用户模块开关+目标组多选预填;不动不携带(tri-state)、
  // 开关关 → [](撤销授权)。
  testWidgets('A4:组表单编辑 — 目标组预填;不动不携带(null);开关关提交 []', (tester) async {
    final api = _install();
    session.me = _adminMe();
    api.directory.groupResult = [
      _group('g1', 'B组', userCreateGroupIds: const ['ga', 'gc']),
      _group('g2', 'A组'),
      _group('g3', 'C组'),
    ];
    api.users.groupResult = [
      GroupBrief(id: 'ga', name: 'A组', memberCount: 3),
      GroupBrief(id: 'gb', name: 'B组', memberCount: 1),
      GroupBrief(id: 'gc', name: 'C组', memberCount: 2),
    ];
    await tester.pumpWidget(const MaterialApp(home: AdminGroupsPage()));
    await tester.pumpAndSettle();

    // 编辑 B 组(已授权 → 目标组 ga/gc)
    await tester.tap(find.text('B组'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑(改名/描述/组级开关)'));
    await tester.pumpAndSettle();

    // 用户模块开关=开(授权态=集合非空,D1),目标组预填 2 组
    expect(_userModuleTile, findsOneWidget);
    expect(_userModuleOn(tester), isTrue);
    expect(find.text('2 组'), findsOneWidget, reason: '目标组预填 A组/C组');

    // ① 未动开关与目标组直接保存 → user_create_group_ids 不携带(null=不动)
    await tester.ensureVisible(find.text('保存'));
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(api.directory.updateGroupCalls.single['id'], 'g1');
    expect(
      api.directory.updateGroupCalls.single['user_create_group_ids'],
      isNull,
      reason: 'tri-state:未改动不随 PATCH 携带',
    );

    // ② 开关关 → 提交体 [](撤销授权;原 B 组成员即时失去用户模块)
    await tester.tap(find.text('B组'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑(改名/描述/组级开关)'));
    await tester.pumpAndSettle();
    expect(_userModuleOn(tester), isTrue);
    await tester.tap(find.textContaining('用户模块'));
    await tester.pumpAndSettle();
    expect(_userModuleOn(tester), isFalse);
    await tester.ensureVisible(find.text('保存'));
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(
      api.directory.updateGroupCalls.last['user_create_group_ids'],
      isEmpty,
    );
  });

  // A4:组表单建组态 — 开关开+选目标组 → 提交体携带所选集合。
  testWidgets('A4:组表单建组 — 开关开+选目标组,提交体 user_create_group_ids 正确', (
    tester,
  ) async {
    final api = _install();
    session.me = _adminMe();
    // 目标组选项 = directory.listGroups(组管理页同源);A4 建组态不涉及远程搜索
    api.directory.groupResult = [
      _group('ga', 'A组'),
      _group('gb', 'B组'),
      _group('gc', 'C组'),
    ];
    await tester.pumpWidget(const MaterialApp(home: AdminGroupsPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.group_add));
    await tester.pumpAndSettle();

    // 开关默认关 → 目标组选择不在场;开关开 → 出现(本地受限多选字段)
    expect(_userModuleTile, findsOneWidget);
    expect(_userModuleOn(tester), isFalse);
    expect(find.text('点击选择用户组'), findsNothing);
    await tester.ensureVisible(find.textContaining('用户模块'));
    await tester.pump();
    await tester.tap(find.textContaining('用户模块'));
    await tester.pumpAndSettle();
    expect(_userModuleOn(tester), isTrue);
    expect(find.text('点击选择用户组'), findsOneWidget);

    // 选 A组 → 完成(1);字段本体是只读 TextField(hint 在 decoration 内)
    await tester.tap(find.widgetWithText(TextField, '点击选择用户组'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(BottomSheet), matching: find.text('A组')),
    );
    await tester.pump();
    await tester.tap(find.text('完成(1)'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: find.byType(BottomSheet), matching: find.text('A组')),
      findsOneWidget,
      reason: '单组显示组名',
    );

    await tester.enterText(_sheetFields.at(0), 'D组');
    await tester.ensureVisible(find.text('创建'));
    await tester.pump();
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(api.directory.createGroupCalls.single['name'], 'D组');
    expect(api.directory.createGroupCalls.single['user_create_group_ids'], [
      'ga',
    ]);
  });

  // A5:admin 不回归 — 用户/用户组磁贴都在。
  testWidgets('A5:admin 磁贴 — admin home 用户/用户组都在,我的页管理后台磁贴在', (tester) async {
    _install();
    session.me = _adminMe();
    await tester.pumpWidget(const MaterialApp(home: AdminHomePage()));
    await tester.pumpAndSettle();
    expect(find.text('用户'), findsOneWidget);
    expect(find.text('用户组'), findsOneWidget);

    session.me = _adminMe();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) =>
              Scaffold(body: Column(children: adminSectionTiles(context))),
        ),
      ),
    );
    expect(find.text('管理后台'), findsOneWidget);
  });

  // A5:admin 不回归 — 行菜单全量(编辑/停用/重置密码/解锁)+ 创建人列照常回显。
  testWidgets('A5:admin 行菜单全量 — 编辑/停用/重置密码/解锁俱在,创建人列不回归', (tester) async {
    final api = _install();
    session.me = _adminMe();
    api.directory.usersStaged = DirectoryUsersPage(
      items: [
        _user('1', locked: true, createdByName: '李四'),
        _user('2', active: false, createdByName: null),
      ],
      total: 2,
    );
    await tester.pumpWidget(const MaterialApp(home: AdminUsersPage()));
    await tester.pumpAndSettle();
    expect(find.textContaining('创建人'), findsWidgets);
    expect(find.textContaining('李四'), findsWidgets);

    await tester.tap(find.text('用户1'));
    await tester.pumpAndSettle();
    // 菜单断言 scope 到 BottomSheet(页面筛选 chip 轨有同名「停用/启用」)
    final menu = find.byType(BottomSheet);
    expect(
      find.descendant(of: menu, matching: find.text('编辑')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: menu, matching: find.text('停用')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: menu, matching: find.text('重置密码')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: menu, matching: find.text('解锁')),
      findsOneWidget,
    );
  });

  // A5:admin 不回归 — 建号组选项走远程搜索路径(GroupMultiSelect),提交体正确。
  testWidgets('A5:admin 建号 — 组选项走远程搜索路径,提交体 group_ids 正确', (tester) async {
    final api = _install();
    session.me = _adminMe();
    api.directory.usersStaged = DirectoryUsersPage(items: const [], total: 0);
    api.users.groupResult = [
      GroupBrief(id: 'ga', name: 'A组', memberCount: 3),
      GroupBrief(id: 'gb', name: 'B组', memberCount: 1),
    ];
    await tester.pumpWidget(const MaterialApp(home: AdminUsersPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.person_add_alt_1));
    await tester.pumpAndSettle();

    // admin 态:组选择字段(空值 hint)→ 点按弹远程搜索弹层
    // (字段本体是只读 TextField,hint 在 decoration 内,点它避免命中提示文案)
    expect(find.text('点击选择所属用户组'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextField, '点击选择所属用户组'));
    await tester.pumpAndSettle();
    expect(api.users.groupSearchCalls, isNotEmpty, reason: 'admin 走远程搜索');
    expect(
      find.descendant(of: find.byType(BottomSheet), matching: find.text('A组')),
      findsOneWidget,
    );

    // 勾 A组 → 完成(1)
    await tester.tap(
      find.descendant(of: find.byType(BottomSheet), matching: find.text('A组')),
    );
    await tester.pump();
    await tester.tap(find.text('完成(1)'));
    await tester.pumpAndSettle();

    await tester.enterText(_sheetFields.at(0), 'zhangsan');
    await tester.enterText(_sheetFields.at(1), '张三');
    await tester.ensureVisible(find.text('创建'));
    await tester.pump();
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(api.directory.createCalls.single['group_ids'], ['ga']);
    expect(find.text('Tmp-Pass-001'), findsOneWidget);
  });

  // §11 增量(2026-11-16):建号表单姓名前缀自动回填 — 操作者姓名含 `_`
  // (如 `素材部_一组_张三`)→ 打开 sheet 时姓名字段初始值=去末段前缀
  // `素材部_一组_`(来源 me.name;每次打开重新回填,可改可清)。
  testWidgets('§11:建号姓名前缀回填 — 操作者姓名含下划线,预填去末段前缀', (tester) async {
    final api = _install();
    // 独立注入:被授权组长(§11 场景主角),姓名含两个 `_`
    session.me = Me.fromJson({
      'id': 'u7',
      'name': '素材部_一组_张三',
      'is_system_admin': false,
      'is_user_manager': true,
      'user_create_groups': [
        {'id': 'ga', 'name': 'A组'},
      ],
    });
    api.directory.usersStaged = DirectoryUsersPage(items: const [], total: 0);
    await tester.pumpWidget(const MaterialApp(home: AdminUsersPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.person_add_alt_1));
    await tester.pumpAndSettle();

    // sheet 文本字段序:登录名(0)/姓名(1)/邮箱(2),姓名初始值=前缀
    expect(
      tester.widget<TextField>(_sheetFields.at(1)).controller!.text,
      '素材部_一组_',
    );
  });

  // §11 增量:操作者姓名不含 `_`(如 Evan/王组长)→ 预填空,行为与现状
  // 完全一致(零影响面)。
  testWidgets('§11:建号姓名前缀回填 — 操作者姓名无下划线,预填空', (tester) async {
    final api = _install();
    // 独立注入:无下划线姓名
    session.me = Me.fromJson({
      'id': 'u8',
      'name': '王组长',
      'is_system_admin': false,
      'is_user_manager': true,
      'user_create_groups': [
        {'id': 'ga', 'name': 'A组'},
      ],
    });
    api.directory.usersStaged = DirectoryUsersPage(items: const [], total: 0);
    await tester.pumpWidget(const MaterialApp(home: AdminUsersPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.person_add_alt_1));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(_sheetFields.at(1)).controller!.text,
      isEmpty,
    );
  });
}
