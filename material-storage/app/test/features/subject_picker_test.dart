/// SubjectPicker / UserPicker 单测(B6 测试功能点 7):用户/组分段切换;
/// 搜索防抖后命中;选中回显 chips(跨段可见);单选替换语义(UserPicker);
/// 空 query 注入 preset、有 query 不注入(web #114 同口径)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/widgets/pickers/subject_picker.dart';
import 'package:ms_app/widgets/pickers/user_picker.dart';

import '../helpers/api_harness.dart';

Future<void> settleSearch(WidgetTester tester) async {
  // 250ms 防抖 + load:两次 pump 跨过 timer
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('UserPicker:空 query 注入 preset(自己),搜索过滤后不再注入',
      (tester) async {
    final api = installFakeApi();
    api.users.userResult = [
      UserBrief(id: 'u2', name: '乙', username: 'yi'),
    ];
    addTearDown(() => session.api = null);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: UserPicker(
          value: const [],
          preset: [UserBrief(id: 'u1', name: '甲(自己)')],
          onChanged: (_) {},
        ),
      ),
    ));
    await settleSearch(tester);
    expect(find.text('甲(自己)'), findsOneWidget, reason: 'preset 注入');
    expect(find.text('乙'), findsWidgets, reason: '头像首字+行标题两处');

    await tester.enterText(find.byType(TextField), '乙');
    await settleSearch(tester);
    expect(find.text('甲(自己)'), findsNothing, reason: '有 query 不注入 preset');
    expect(find.text('乙'), findsWidgets);
  });

  testWidgets('UserPicker 单选:点第二个替换第一个', (tester) async {
    final api = installFakeApi();
    api.users.userResult = [
      UserBrief(id: 'u2', name: '乙'),
      UserBrief(id: 'u3', name: '丙'),
    ];
    addTearDown(() => session.api = null);

    List<UserBrief> selected = const [];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: UserPicker(
          value: selected,
          multiple: false,
          onChanged: (v) => selected = v,
        ),
      ),
    ));
    await settleSearch(tester);
    await tester.tap(find.text('乙').last);
    expect(selected.single.id, 'u2');
    await tester.tap(find.text('丙').last);
    expect(selected.single.id, 'u3', reason: '单选=替换语义(新建项目管理员)');
  });

  testWidgets('SubjectPicker:用户/组分段;选中回显跨段可见;移除 chip 同步',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = installFakeApi();
    api.users.userResult = [UserBrief(id: 'u2', name: '乙')];
    api.users.groupResult = [
      GroupBrief(id: 'g1', name: '后期组', memberCount: 5),
    ];
    addTearDown(() => session.api = null);

    var subjects = const <Subject>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => SubjectPicker(
            value: subjects,
            onChanged: (v) => setState(() => subjects = v),
          ),
        ),
      ),
    ));
    // 组段 prefetch 也已发;等两路防抖都落地
    await settleSearch(tester);

    // 用户段选乙(头像首字与标题重名,点标题)
    await tester.tap(find.text('乙').last);
    await tester.pump(); // onChanged→setState 重建后才有回显
    expect(subjects.single.kind, SubjectKind.user);
    expect(find.textContaining('已选 1 项'), findsOneWidget);

    // 切组段选后期组(回显仍在)
    await tester.tap(find.text('用户组'));
    await settleSearch(tester);
    await tester.tap(find.text('后期组'));
    await tester.pump();
    expect(subjects.length, 2);
    expect(find.textContaining('已选 2 项'), findsOneWidget);

    // 移除用户 chip(👤 乙):直接触发 InputChip.onDeleted(删除图标受 tooltip
    // 包装,finder 不稳;语义等价用户点 ×)
    tester.widget<InputChip>(find.widgetWithText(InputChip, '👤 乙'))
        .onDeleted!();
    await tester.pump();
    expect(subjects.single.kind, SubjectKind.group,
        reason: '跨段移除同步 value');
  });
}
