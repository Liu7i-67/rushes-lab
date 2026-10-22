/// GroupPickerField(app-polish-3 测试功能点 5「C/E」,包 C3):空值显示 hint、
/// 1 组显示组名、多组显示「N 组」、点按弹 showGroupPickerSheet、
/// 清除钮回 [](onChanged([]));弹层选中经 DirectoryGroup↔GroupBrief 互转回填
/// (新组人数按搜索结果,memberCount null 兜底 0)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/widgets/pickers/group_picker_field.dart';

import '../helpers/api_harness.dart';

DirectoryGroup _grp(String id, String name, {int memberCount = 3}) =>
    DirectoryGroup(
      id: id,
      name: name,
      description: null,
      memberCount: memberCount,
      createdAt: '2026-01-01T00:00:00Z',
    );

GroupBrief _brief(String id, String name, {int? memberCount}) =>
    GroupBrief(id: id, name: name, memberCount: memberCount);

void main() {
  testWidgets('功能点 5:value 为空 → 显示 hint「选择用户组」', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: GroupPickerField(value: const [], onChanged: (_) {}),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, '选择用户组'), findsOneWidget,
        reason: '无值渲染 PickerField(hint 语义)');
  });

  testWidgets('功能点 5:1 组显示组名;多组显示「N 组」', (tester) async {
    var value = [_grp('g1', '后期组')];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (ctx, setState) => Center(
            child: GroupPickerField(
              value: value,
              onChanged: (v) => setState(() => value = v),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('后期组'), findsOneWidget, reason: '单组显示组名');
    expect(find.text('1 组'), findsNothing, reason: '单组不显示「N 组」形态');

    value = [_grp('g1', '后期组'), _grp('g2', '前期组')];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: GroupPickerField(value: value, onChanged: (_) {}),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('2 组'), findsOneWidget, reason: '多组展示文案 = 「N 组」');
  });

  testWidgets('功能点 5:有值清除钮 → onChanged([])', (tester) async {
    List<DirectoryGroup>? changed;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (ctx, setState) => Center(
            child: GroupPickerField(
              value: [_grp('g1', '后期组')],
              onChanged: (v) => setState(() => changed = v),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.clear));
    await tester.pumpAndSettle();

    expect(changed, isEmpty, reason: '清除 = onChanged([]) 回空(重选入口)');
  });

  testWidgets('功能点 5:点按弹「选择用户组」弹层;勾选完成回填 DirectoryGroup'
      '(原对象 flag 保留,新组人数按搜索结果)', (tester) async {
    final api = installFakeApi();
    api.users.groupResult = [
      _brief('g1', '后期组·改', memberCount: 9),
      _brief('g3', '调色组', memberCount: 2),
    ];
    addTearDown(() => session.api = null);

    DirectoryGroup original = _grp('g1', '后期组', memberCount: 3);
    List<DirectoryGroup> value = [original];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (ctx, setState) => Center(
            child: GroupPickerField(
              value: value,
              onChanged: (v) => setState(() => value = v),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 有值字段点按弹层(弹层初始已含当前组 g1)
    await tester.tap(find.text('后期组'));
    await tester.pumpAndSettle();
    expect(find.text('选择用户组'), findsWidgets, reason: '弹层标题在场(与字段 hint 同文)');

    // 勾一个新组 + 保留原组 → 完成(2)
    await tester.tap(find.descendant(
        of: find.byType(BottomSheet), matching: find.text('调色组')));
    await tester.pump();
    await tester.tap(find.text('完成(2)'));
    await tester.pumpAndSettle();

    expect(value, hasLength(2), reason: '弹层提交经 onChanged 回填');
    expect(value.map((g) => g.id), containsAll(['g1', 'g3']));

    // 已在 value 里的组(弹层 initial 带入、未重点):按 id 保留原对象字段
    final g1 = value.firstWhere((g) => g.id == 'g1');
    expect(g1.name, '后期组', reason: '未重点的原组不改名(initial 带入的选中项)');
    expect(g1.memberCount, 3);
    expect(g1.createdAt, original.createdAt, reason: '原对象 createdAt 等非搜索字段原样保留');
    expect(g1.canCreateProject, original.canCreateProject, reason: '组级 flag 保留');

    final g3 = value.firstWhere((g) => g.id == 'g3');
    expect(g3.name, '调色组');
    expect(g3.memberCount, 2, reason: '新选组人数按搜索结果');
  });

  testWidgets('功能点 5:取消弹层不动现值', (tester) async {
    final api = installFakeApi();
    api.users.groupResult = [_brief('g1', '后期组', memberCount: 1)];
    addTearDown(() => session.api = null);

    List<DirectoryGroup>? changed;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (ctx, setState) => Center(
            child: GroupPickerField(
              value: const [],
              onChanged: (v) => setState(() => changed = v),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextField, '选择用户组'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(changed, isNull, reason: '取消(null)语义:字段维持原值');
  });
}
