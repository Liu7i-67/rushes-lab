/// 审计筛选栏操作者字段(app-polish-3 测试功能点 8,E4/D5):actor=null 显示
/// hint「全部操作者」;有值时显示用户名 + 清除钮,点清除 onActorChanged 收到
/// 空列表(回「全部操作者」);点字段弹 showUserPickerSheet 可选人,选中回填。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/admin/audit_filter_bar.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

UserBrief _u(String id, String name) => UserBrief(id: id, name: name);

Widget _host({
  required UserBrief? actor,
  required ValueChanged<List<UserBrief>> onActorChanged,
}) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: StatefulBuilder(
        builder: (ctx, setState) => AuditFilterBar(
          eventType: '',
          projectId: '',
          actor: actor,
          day: null,
          projects: [Project(id: 'p1', name: '婚礼A', code: 'wed-a')],
          onEventTypeChanged: (_) {},
          onProjectChanged: (_) {},
          onActorChanged: onActorChanged,
          onPickDate: () {},
          onClearDate: () {},
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('功能点 8:actor=null → 显示 hint「全部操作者」(无清除钮)', (tester) async {
    await tester.pumpWidget(_host(actor: null, onActorChanged: (_) {}));
    await tester.pumpAndSettle();

    expect(
      find.text('全部操作者'),
      findsOneWidget,
      reason: '空值语义 = 全部操作者(字段 hint 承载)',
    );
    expect(
      find.byIcon(Icons.clear),
      findsNothing,
      reason: '空值无清除入口(day=null 本用例亦无日期清除钮)',
    );
  });

  testWidgets('功能点 8:有操作者时显示用户名 + 清除钮;点清除 onActorChanged 收 []', (tester) async {
    List<UserBrief>? changed;
    await tester.pumpWidget(
      _host(actor: _u('u1', '张三'), onActorChanged: (v) => changed = v),
    );
    await tester.pumpAndSettle();

    expect(find.text('张三'), findsOneWidget, reason: '有值显示操作者名');
    expect(
      find.byIcon(Icons.clear),
      findsOneWidget,
      reason: 'D5:allowClear 清除入口(对齐 web AuditPage 语义)',
    );

    await tester.tap(find.byIcon(Icons.clear));
    await tester.pumpAndSettle();

    expect(
      changed,
      isEmpty,
      reason: 'D5:清除 = onChanged([]) = 回「全部操作者」(此前无清除路径)',
    );
  });

  testWidgets('功能点 8:点操作者字段弹用户弹层,选人后 onActorChanged 收到该用户', (tester) async {
    final api = installFakeApi();
    api.users.userResult = [_u('u1', '张三'), _u('u2', '李四')];
    addTearDown(() => session.api = null);

    List<UserBrief>? changed;
    await tester.pumpWidget(
      _host(actor: null, onActorChanged: (v) => changed = v),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('全部操作者'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.text('选择用户'), findsOneWidget, reason: 'E4:点按弹用户弹层');

    await tester.tap(
      find.descendant(of: find.byType(BottomSheet), matching: find.text('张三')),
    );
    await tester.pumpAndSettle(); // 单选点选即关,退场动画后回调落地

    expect(changed, hasLength(1), reason: '选人即回填操作者筛选');
    expect(changed!.single.id, 'u1');
  });

  testWidgets('功能点 8:取消弹层不动现值', (tester) async {
    final api = installFakeApi();
    api.users.userResult = [_u('u1', '张三')];
    addTearDown(() => session.api = null);

    List<UserBrief>? changed;
    await tester.pumpWidget(
      _host(actor: _u('u1', '张三'), onActorChanged: (v) => changed = v),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('张三'), warnIfMissed: false);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(changed, isNull, reason: '取消(null)语义:筛选维持现状');
  });
}
