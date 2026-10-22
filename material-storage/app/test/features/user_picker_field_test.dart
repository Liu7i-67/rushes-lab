/// UserPickerField(app-polish-3 测试功能点 5「C/E」,包 C2):无值显示 hint、
/// 有值显示用户名(多选「N 人」)、点按弹 showUserPickerSheet 弹层、
/// allowClear 有值时显示清除钮且清除回 [](onChanged([])),
/// allowClear=false 无清除钮;取消弹层不动现值。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/widgets/sheet_scaffold.dart';
import 'package:ms_app/widgets/pickers/user_picker_field.dart';

import '../helpers/api_harness.dart';

UserBrief _u(String id, String name) => UserBrief(id: id, name: name);

/// 受控宿主:外层持 value,onChanged setState 回填(真实用法)。
Widget _host({
  required List<UserBrief> initialValue,
  bool multiple = false,
  bool allowClear = true,
  List<UserBrief>? preset,
}) =>
    MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (ctx, setState) {
            var value = initialValue;
            return Center(
              child: UserPickerField(
                value: value,
                onChanged: (v) => setState(() => initialValue = v),
                multiple: multiple,
                preset: preset,
                allowClear: allowClear,
              ),
            );
          },
        ),
      ),
    );

void main() {
  testWidgets('功能点 5:value 为空 → 显示 hint「选择用户」', (tester) async {
    await tester.pumpWidget(_host(initialValue: const []));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, '选择用户'), findsOneWidget,
        reason: '无值渲染 PickerField(hint 语义)');
  });

  testWidgets('功能点 5:value 非空 → 显示用户名;allowClear 清除钮回 []',
      (tester) async {
    List<UserBrief>? changed;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (ctx, setState) => Center(
            child: UserPickerField(
              value: [_u('u1', '张三')],
              onChanged: (v) => setState(() => changed = v),
              multiple: false,
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('张三'), findsOneWidget, reason: '单选有值显示用户名');
    expect(find.byIcon(Icons.clear), findsOneWidget,
        reason: 'allowClear=true 有值时提供清除钮');

    await tester.tap(find.byIcon(Icons.clear));
    await tester.pumpAndSettle();

    expect(changed, isEmpty, reason: 'D5:清除 = onChanged([]) = 回全部/空语义');
  });

  testWidgets('功能点 5:多选有值显示「N 人」', (tester) async {
    await tester.pumpWidget(_host(
      initialValue: [_u('u1', '张三'), _u('u2', '李四')],
      multiple: true,
    ));
    await tester.pumpAndSettle();

    expect(find.text('2 人'), findsOneWidget, reason: '多选展示文案 = 「N 人」');
  });

  testWidgets('功能点 5:allowClear=false 无清除钮(只读展示 + chevron)',
      (tester) async {
    await tester.pumpWidget(_host(
      initialValue: [_u('u1', '张三')],
      allowClear: false,
    ));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.clear), findsNothing,
        reason: 'allowClear=false 不得出现清除钮(E2 项目管理员场景)');
    expect(find.byIcon(Icons.expand_more), findsOneWidget,
        reason: '以 chevron 表达可点按弹层');
  });

  testWidgets('功能点 5:点按(空值字段)弹选择弹层;取消不改值', (tester) async {
    final api = installFakeApi();
    api.users.userResult = [_u('u1', '张三'), _u('u2', '李四')];
    addTearDown(() => session.api = null);

    List<UserBrief>? changed;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (ctx, setState) => Center(
            child: UserPickerField(
              value: const [],
              onChanged: (v) => setState(() => changed = v),
              multiple: true,
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextField, '选择用户'));
    await tester.pumpAndSettle();

    expect(find.byType(SheetScaffold), findsOneWidget, reason: '点按弹远程弹层');
    expect(find.text('选择用户'), findsWidgets, reason: '弹层标题在场(字段 hint 同文)');

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(changed, isNull, reason: '取消返回 null,不动现值');
  });

  testWidgets('功能点 5:弹层勾选「完成(1)」后 onChanged 回填所勾用户',
      (tester) async {
    final api = installFakeApi();
    api.users.userResult = [_u('u1', '张三'), _u('u2', '李四')];
    addTearDown(() => session.api = null);

    List<UserBrief> value = const [];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (ctx, setState) => Center(
            child: UserPickerField(
              value: value,
              onChanged: (v) => setState(() => value = v),
              multiple: true,
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextField, '选择用户'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(BottomSheet), matching: find.text('张三')));
    await tester.pump();
    await tester.tap(find.text('完成(1)'));
    await tester.pumpAndSettle();

    expect(value, hasLength(1), reason: '弹层提交经 onChanged 回填外层');
    expect(value.single.id, 'u1');
    expect(find.text('1 人'), findsOneWidget, reason: '回填后字段显示「N 人」');
  });
}
