import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/projects/projects_page.dart';

import 'helpers/api_harness.dart';

void main() {
  test('项目页标题恒为「项目」(P6:不带 stamp 与用户名)', () {
    expect(projectsTitle(), '项目');
  });

  testWidgets('P6:项目页 AppBar 标题「项目」,无 debug 日志图标', (tester) async {
    final api = installFakeApi();
    api.projects.listStaged = const [];
    addTearDown(() => session.api = null);
    await tester.pumpWidget(const MaterialApp(home: ProjectsPage()));
    await tester.pumpAndSettle();
    expect(find.text('项目'), findsOneWidget);
    expect(find.byIcon(Icons.bug_report_outlined), findsNothing,
        reason: '项目页日志推送入口已移除(登录页/我的页保留)');
  });
}
