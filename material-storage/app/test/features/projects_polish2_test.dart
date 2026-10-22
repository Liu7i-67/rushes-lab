/// app-polish-2(P2 批)项目搜索验收用例(对应需求文档 2026-10-22-app-polish-2.md
/// J2 #7):项目页 AppBar 下常驻紧凑搜索框(SearchField)——
/// - 输入过滤词列表仅剩匹配项(名称/code 不区分大小写包含);
/// - 清空(输入清空/清除钮)恢复全量;
/// - 无匹配显示「无匹配项目」EmptyState 变体。
///
/// 套路:同 projects_page_ux_test.dart——FakeProjectsApi 桩即回,逐 pump
/// 避开不定长动画;SearchField 为既有通用组件(A7),可按类型定位。
/// 凡依赖「尚未存在的行为」的断言标注 TODO(app-polish2 J2): 现状应失败,
/// 交付后转绿。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/projects/projects_page.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/widgets/search_field.dart';

import '../helpers/api_harness.dart';

Future<void> _pumpPage(WidgetTester tester, List<Project> projects) async {
  final api = installFakeApi();
  api.projects.listStaged = projects;
  session.me = Me(id: 'u1', name: '甲');
  addTearDown(() {
    session.api = null;
    session.me = null;
  });
  await tester.pumpWidget(const MaterialApp(home: ProjectsPage()));
  await tester.pump();
  await tester.pump();
}

List<Project> get _threeProjects => [
      Project(id: 'p1', name: '婚礼A', code: 'wed-a'),
      Project(id: 'p2', name: '写字楼B', code: 'off-b'),
      Project(id: 'p3', name: '婚礼C', code: 'wed-c'),
    ];

void main() {
  testWidgets('J2:输入过滤词列表仅剩匹配项(名称包含;code 不区分大小写)',
      (tester) async {
    await _pumpPage(tester, _threeProjects);
    expect(find.text('婚礼A'), findsOneWidget, reason: '前置:全量 3 项');
    expect(find.text('写字楼B'), findsOneWidget);
    expect(find.text('婚礼C'), findsOneWidget);

    // 已交付转绿(J2):AppBar 下常驻紧凑搜索框(A7 SearchField)
    expect(find.byType(SearchField), findsOneWidget,
        reason: 'J2:AppBar 下常驻紧凑搜索框');
    await tester.enterText(find.byType(SearchField), '婚礼');
    await tester.pump();
    await tester.pump();
    expect(find.text('婚礼A'), findsOneWidget);
    expect(find.text('婚礼C'), findsOneWidget);
    expect(find.text('写字楼B'), findsNothing, reason: 'J2:不匹配项被过滤');

    // code 过滤不区分大小写:'WED-' 命中 wed-a/wed-c
    await tester.enterText(find.byType(SearchField), 'WED-');
    await tester.pump();
    await tester.pump();
    expect(find.text('婚礼A'), findsOneWidget);
    expect(find.text('婚礼C'), findsOneWidget);
    expect(find.text('写字楼B'), findsNothing, reason: 'J2:code 大小写不敏感包含');
  });

  testWidgets('J2:清除钮清空过滤词恢复全量', (tester) async {
    await _pumpPage(tester, _threeProjects);
    await tester.enterText(find.byType(SearchField), '婚礼');
    await tester.pump();
    await tester.pump();
    expect(find.text('写字楼B'), findsNothing, reason: '前置:过滤生效');

    // 已交付转绿(J2):清除钮清空过滤词(A7 SearchField 语义)
    await tester.tap(find.byTooltip('清除'));
    await tester.pump();
    await tester.pump();
    expect(find.text('婚礼A'), findsOneWidget, reason: 'J2:清空恢复全量');
    expect(find.text('写字楼B'), findsOneWidget);
    expect(find.text('婚礼C'), findsOneWidget);
  });

  testWidgets('J2:无匹配显示「无匹配项目」提示(EmptyState 变体)', (tester) async {
    await _pumpPage(tester, _threeProjects);

    // 已交付转绿(J2):无匹配空态提示
    await tester.enterText(find.byType(SearchField), '不存在的项目xyz');
    await tester.pump();
    await tester.pump();
    expect(find.text('婚礼A'), findsNothing);
    expect(find.textContaining('无匹配'), findsOneWidget,
        reason: 'J2:空结果显示「无匹配项目」提示');
  });
}
