/// P6/R3 项目页 UI 单测(mobile-ux-polish 批 + 二期 R3):
/// - 标题恒「项目」(无 stamp/用户名段,projectsTitle 纯函数另见
///   test/projects_title_test.dart);
/// - AppBar 无 debug 日志按钮(bug_report 图标,logPushButton 已移除;
///   登录页右上角与我的页诊断区入口保留,P10 依赖);
/// - R3:刷新钮删除(与下拉刷新冗余);loading/error/empty 三分支经
///   AlwaysScrollableScrollPhysics 可滚动包装,下拉均可触发 onRefresh;
///   列表态下拉回归不回退。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/projects/projects_page.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

/// 挂页并等到稳定态(首轮 loading → 假桩即回;逐 pump 避开
/// pumpAndSettle:刷新指示器/加载圈为不定长动画)。
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

void main() {
  testWidgets('P6:项目页标题「项目」、无 bug 日志图标;R3:无刷新钮',
      (tester) async {
    final api = installFakeApi();
    api.projects.listStaged = const <Project>[];
    session.me = Me(id: 'u1', name: 'Evan'); // 非 creator:新建钮不出现
    addTearDown(() {
      session.api = null;
      session.me = null;
    });

    await _pumpPage(tester);

    // 标题:恒「项目」,不含 stamp 段与用户名段
    expect(find.descendant(of: find.byType(AppBar), matching: find.text('项目')),
        findsOneWidget);
    expect(find.textContaining('最后编辑'), findsNothing,
        reason: 'P6 移除「最后编辑 <stamp>」段');
    expect(find.textContaining('Evan'), findsNothing,
        reason: 'P6 移除标题用户名段');

    // debug 日志入口移除(项目页 AppBar 不再挂 logPushButton)
    expect(find.byIcon(Icons.bug_report_outlined), findsNothing,
        reason: 'P6:项目页无 debug 图标(入口保留在登录页/我的页)');

    // R3 回归锚:刷新钮删除(刷新入口统一为下拉)
    expect(find.byIcon(Icons.refresh), findsNothing,
        reason: 'R3:AppBar 刷新钮冗余删除');
  });

  testWidgets('R3:空态经可滚动包装,下拉触发 onRefresh', (tester) async {
    final api = installFakeApi();
    api.projects.listStaged = const <Project>[];
    session.me = Me(id: 'u1', name: 'Evan');
    addTearDown(() {
      session.api = null;
      session.me = null;
    });

    await _pumpPage(tester);
    expect(find.text('暂无可见项目'), findsOneWidget);
    expect(api.projects.listCalls, 1, reason: '首轮挂载拉一次');

    await _pullToRefresh(tester);
    expect(api.projects.listCalls, 2, reason: '空态下拉触发刷新');
  });

  testWidgets('R3:error 态经可滚动包装,下拉触发 onRefresh', (tester) async {
    final api = installFakeApi();
    api.projects.listStaged = ApiException(500, 'boom');
    session.me = Me(id: 'u1', name: 'Evan');
    addTearDown(() {
      session.api = null;
      session.me = null;
    });

    await _pumpPage(tester);
    expect(find.textContaining('boom'), findsOneWidget);
    expect(api.projects.listCalls, 1);

    api.projects.listStaged = const <Project>[]; // 刷新后恢复
    await _pullToRefresh(tester);
    expect(api.projects.listCalls, 2, reason: '错误态下拉触发刷新');
    expect(find.text('暂无可见项目'), findsOneWidget, reason: '刷新成功转空态');
  });

  testWidgets('R3:列表态下拉刷新回归(旧数据原地等,不整页替换)', (tester) async {
    final api = installFakeApi();
    api.projects.listStaged = <Project>[
      Project.fromJson({'id': 'p1', 'name': '项目A', 'code': 'PA'}),
    ];
    session.me = Me(id: 'u1', name: 'Evan');
    addTearDown(() {
      session.api = null;
      session.me = null;
    });

    await _pumpPage(tester);
    expect(find.text('项目A'), findsOneWidget);
    expect(api.projects.listCalls, 1);

    await _pullToRefresh(tester);
    expect(api.projects.listCalls, 2, reason: '列表态下拉刷新不回退');
    expect(find.text('项目A'), findsOneWidget);
  });
}
