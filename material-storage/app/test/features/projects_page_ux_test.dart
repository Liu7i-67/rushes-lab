/// 项目页 UI 单测(墨金 WP2 更新):
/// - PageHeader 大标题「项目」27 号 + 计数/副标题(无 AppBar);
/// - 无 debug 日志按钮;无刷新钮(刷新统一为下拉);
/// - loading/error/empty/列表四态均可下拉刷新;空态/错误态布局居中;
/// - 搜索行即时过滤(名称/code 不区分大小写),清空恢复全量,无命中轻空态;
/// - ProjectCard 整卡点击进文件夹、长按管理菜单(admin 闸门)、通知铃跳转。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/polling_controller.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/projects/project_card.dart';
import 'package:ms_app/features/projects/projects_page.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/theme/tokens.dart';
import 'package:ms_app/widgets/page_header.dart';

import '../helpers/api_harness.dart';

/// 挂页并等到稳定态(首轮 loading → 假桩即回;逐 pump 避开 pumpAndSettle)。
Future<void> _pumpPage(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: ProjectsPage()));
  await tester.pump();
  await tester.pump();
}

/// 下拉一屏并等刷新完成(onRefresh 假桩即回,圈有固定收起动画时长)。
Future<void> _pullToRefresh(WidgetTester tester) async {
  await tester.drag(find.byType(ListView).first, const Offset(0, 300));
  await tester.pump(); // RefreshIndicator 弹出
  await tester.pump(const Duration(milliseconds: 600)); // onRefresh 完成+收圈
  await tester.pump(const Duration(milliseconds: 600));
}

void _reset() {
  session.api = null;
  session.me = null;
}

void main() {
  testWidgets('PageHeader:「项目」27 号大标题、无 bug 图标;R3:无刷新钮', (tester) async {
    final api = installFakeApi();
    api.projects.listStaged = const <Project>[];
    session.me = Me(id: 'u1', name: 'Evan'); // 非 creator:新建钮不出现
    addTearDown(_reset);

    await _pumpPage(tester);

    expect(find.byType(AppBar), findsNothing, reason: '一级页不再使用 AppBar');
    final title = tester.widget<Text>(
      find.descendant(of: find.byType(PageHeader), matching: find.text('项目')),
    );
    expect(title.style?.fontSize, Tk.fzDisplay, reason: '一级页 27 号大标题');
    expect(
      find.textContaining('最后编辑'),
      findsNothing,
      reason: 'P6 移除「最后编辑 <stamp>」段',
    );
    expect(find.textContaining('Evan'), findsNothing, reason: 'P6 移除标题用户名段');

    expect(
      find.byIcon(Icons.bug_report_outlined),
      findsNothing,
      reason: 'P6:项目页无 debug 图标(入口保留在登录页/我的页)',
    );
    expect(
      find.byIcon(Icons.refresh),
      findsNothing,
      reason: 'R3:AppBar 刷新钮冗余删除',
    );
    expect(
      find.byIcon(Icons.create_new_folder_outlined),
      findsNothing,
      reason: '非 creator 无新建入口',
    );
  });

  testWidgets('空态经可滚动包装,下拉触发 onRefresh', (tester) async {
    final api = installFakeApi();
    api.projects.listStaged = const <Project>[];
    session.me = Me(id: 'u1', name: 'Evan');
    addTearDown(_reset);

    await _pumpPage(tester);
    expect(find.text('暂无可见项目'), findsOneWidget);
    expect(api.projects.listCalls, 1, reason: '首轮挂载拉一次');

    await _pullToRefresh(tester);
    expect(api.projects.listCalls, 2, reason: '空态下拉触发刷新');
  });

  testWidgets('error 态经可滚动包装,下拉触发 onRefresh', (tester) async {
    final api = installFakeApi();
    api.projects.listStaged = ApiException(500, 'boom');
    session.me = Me(id: 'u1', name: 'Evan');
    addTearDown(_reset);

    await _pumpPage(tester);
    expect(find.textContaining('boom'), findsOneWidget);
    expect(api.projects.listCalls, 1);

    api.projects.listStaged = const <Project>[]; // 刷新后恢复
    await _pullToRefresh(tester);
    expect(api.projects.listCalls, 2, reason: '错误态下拉触发刷新');
    expect(find.text('暂无可见项目'), findsOneWidget, reason: '刷新成功转空态');
  });

  testWidgets('列表态下拉刷新回归(旧数据原地等,不整页替换)', (tester) async {
    final api = installFakeApi();
    api.projects.listStaged = <Project>[
      Project.fromJson({'id': 'p1', 'name': '项目A', 'code': 'PA'}),
    ];
    session.me = Me(id: 'u1', name: 'Evan');
    addTearDown(_reset);

    await _pumpPage(tester);
    expect(find.text('项目A'), findsOneWidget);
    expect(api.projects.listCalls, 1);

    await _pullToRefresh(tester);
    expect(api.projects.listCalls, 2, reason: '列表态下拉刷新不回退');
    expect(find.text('项目A'), findsOneWidget);
  });

  // ── 搜索过滤(WP2 保留 J2 行为)───────────────────────────────────────────

  Future<void> pumpTwoProjects(WidgetTester tester) async {
    final api = installFakeApi();
    api.projects.listStaged = <Project>[
      Project.fromJson({'id': 'p1', 'name': '皮肤科素材', 'code': 'SKIN'}),
      Project.fromJson({'id': 'p2', 'name': '外科影像', 'code': 'SUR'}),
    ];
    session.me = Me(id: 'u1', name: 'Evan');
    addTearDown(_reset);
    await _pumpPage(tester);
  }

  testWidgets('搜索行即时过滤(名称/code 不区分大小写),清空恢复全量', (tester) async {
    await pumpTwoProjects(tester);
    expect(find.text('皮肤科素材'), findsOneWidget);
    expect(find.text('外科影像'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'skin');
    await tester.pump();
    expect(find.text('皮肤科素材'), findsOneWidget, reason: 'code=SKIN 包含 skin');
    expect(find.text('外科影像'), findsNothing);

    await tester.enterText(find.byType(TextField), '影像');
    await tester.pump();
    expect(find.text('外科影像'), findsOneWidget);
    expect(find.text('皮肤科素材'), findsNothing);

    await tester.tap(find.byIcon(Icons.clear));
    await tester.pump();
    expect(find.text('皮肤科素材'), findsOneWidget, reason: '清空恢复全量');
    expect(find.text('外科影像'), findsOneWidget);
  });

  testWidgets('过滤无命中 → 「无匹配项目」轻空态,过滤词跨刷新保持', (tester) async {
    final api = installFakeApi();
    api.projects.listStaged = <Project>[
      Project.fromJson({'id': 'p1', 'name': '皮肤科素材', 'code': 'SKIN'}),
    ];
    session.me = Me(id: 'u1', name: 'Evan');
    addTearDown(_reset);
    await _pumpPage(tester);

    await tester.enterText(find.byType(TextField), '不存在的项目xyz');
    await tester.pump();
    expect(find.text('无匹配项目'), findsOneWidget, reason: '有数据但过滤无命中 → 轻空态');

    await _pullToRefresh(tester);
    expect(api.projects.listCalls, 2, reason: '无匹配态仍可下拉刷新');
    expect(find.text('无匹配项目'), findsOneWidget, reason: '过滤词跨刷新保持');

    await tester.tap(find.byIcon(Icons.clear));
    await tester.pump();
    expect(find.text('皮肤科素材'), findsOneWidget);
    expect(find.text('无匹配项目'), findsNothing);
  });

  // ── WP2 新版式 ───────────────────────────────────────────────────────────

  testWidgets('PageHeader 计数/副标题 + 项目卡点击进文件夹', (tester) async {
    final api = installFakeApi();
    api.projects.listStaged = <Project>[
      Project(id: 'p1', name: '皮肤科素材', code: 'SKIN', myRoles: ['admin']),
      Project(id: 'p2', name: '外科影像', code: 'SUR'),
    ];
    session.me = Me(id: 'u1', name: 'Evan', isProjectCreator: true);
    addTearDown(_reset);

    Object? args;
    await tester.pumpWidget(
      MaterialApp(
        onGenerateRoute: (s) {
          if (s.name == '/folders') args = s.arguments;
          return MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('FolderPage')),
          );
        },
        home: const ProjectsPage(),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(ProjectCard), findsNWidgets(2));
    expect(
      find.descendant(
        of: find.byType(PageHeader),
        matching: find.text('共 2 个项目'),
      ),
      findsOneWidget,
    );
    expect(
      find.byIcon(Icons.create_new_folder_outlined),
      findsOneWidget,
      reason: 'creator 有新建入口',
    );

    await tester.tap(find.text('皮肤科素材'));
    await tester.pumpAndSettle();
    expect(args, isA<(String, String, List<String>)>(), reason: '整卡进文件夹');
    final (id, name, roles) = args! as (String, String, List<String>);
    expect(id, 'p1');
    expect(name, '皮肤科素材');
    expect(roles, ['admin']);
  });

  testWidgets('长按管理菜单:admin 项目出现成员管理/请求链接', (tester) async {
    final api = installFakeApi();
    api.projects.listStaged = <Project>[
      Project(id: 'p1', name: '项目A', code: 'PA', myRoles: ['admin']),
    ];
    session.me = Me(id: 'u1', name: 'Evan');
    addTearDown(_reset);
    await _pumpPage(tester);

    await tester.longPress(find.text('项目A'));
    await tester.pumpAndSettle();
    expect(find.text('项目A · 管理'), findsOneWidget);
    expect(find.text('成员管理'), findsOneWidget);
    expect(find.text('请求链接'), findsOneWidget);
  });

  testWidgets('通知铃:未读>0 金点,点击进 /notifications', (tester) async {
    final api = installFakeApi();
    api.projects.listStaged = const <Project>[];
    session.me = Me(id: 'u1', name: 'Evan');
    unreadPoller.unreadCount = 2;
    addTearDown(() {
      unreadPoller.unreadCount = 0;
      _reset();
    });

    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        onGenerateRoute: (s) {
          if (s.name == '/notifications') opened = true;
          return MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('Notifications')),
          );
        },
        home: const ProjectsPage(),
      ),
    );
    await tester.pump();
    await tester.pump();

    final dot = find.byWidgetPredicate(
      (w) => w is Container && w.constraints?.maxWidth == 8.0,
    );
    expect(dot, findsOneWidget, reason: '未读 >0 金点');

    await tester.tap(find.byTooltip('通知'));
    await tester.pumpAndSettle();
    expect(opened, isTrue);
  });
}
