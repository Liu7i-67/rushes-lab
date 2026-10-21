/// P6 项目页 UI 单测(mobile-ux-polish 批):
/// - 标题恒「项目」(无 stamp/用户名段,projectsTitle 纯函数另见
///   test/projects_title_test.dart);
/// - AppBar 无 debug 日志按钮(bug_report 图标,logPushButton 已移除;
///   登录页右上角与我的页诊断区入口保留,P10 依赖);
/// - 刷新钮保留(回归锚)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/projects/projects_page.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

void main() {
  testWidgets('P6:项目页标题「项目」、无 bug 日志图标、刷新钮保留', (tester) async {
    final api = installFakeApi();
    api.projects.listStaged = const <Project>[];
    session.me = Me(id: 'u1', name: 'Evan'); // 非 creator:新建钮不出现
    addTearDown(() {
      session.api = null;
      session.me = null;
    });

    await tester.pumpWidget(const MaterialApp(home: ProjectsPage()));
    // 首轮 loading → projects.list() 假桩即回 → 空态;逐 pump(避开
    // pumpAndSettle:刷新指示器/加载圈为不定长动画)
    await tester.pump();
    await tester.pump();

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

    // 回归锚:刷新钮仍在
    expect(find.byIcon(Icons.refresh), findsOneWidget);
  });
}
