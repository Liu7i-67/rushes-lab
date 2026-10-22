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

  // app-polish D1:SubjectPicker 改「已选汇总 + 添加入口」形态,原「分段
  // 常驻列表」用例改写为等价的新形态路径——分段按钮/勾选迁入弹层
  // (showSubjectPickerSheet),选中在弹层内即时回填「完成(N)」计数,
  // 点完成才 onChanged 回填汇总 chips。业务断言(kind/跨段可见/移除同步)不变。
  testWidgets('SubjectPicker:弹层双段勾选;完成回填跨段可见;移除 chip 同步',
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
    // 空态汇总(内联列表已下线)
    expect(find.text('尚未添加主体'), findsOneWidget);

    // 点添加入口弹弹层;settleSearch = 进场动画 + 空 query 首搜 250ms 防抖
    await tester.tap(find.text('添加用户 / 用户组'));
    await settleSearch(tester);

    // 用户段勾乙(行内头像首字与标题重名,widgetWithText 对同一行会重复
    // 命中,取 .first 去重;点的就是该行 ListTile 中心 → InkWell.onTap)
    await tester.tap(find.widgetWithText(ListTile, '乙').first);
    await tester.pump(); // 勾选即时回填,底部完成计数更新
    expect(find.text('完成(1)'), findsOneWidget,
        reason: '弹层内勾选即时回填(原「已选 1 项」的等价中间态)');

    // 弹层内切用户组段(原外置分段的等价形态),等换段重搜防抖后勾后期组
    await tester.tap(find.text('用户组'));
    await settleSearch(tester);
    await tester.tap(find.widgetWithText(ListTile, '后期组'));
    await tester.pump();
    expect(find.text('完成(2)'), findsOneWidget);

    // 点完成 → 退场动画后 future 才回填 → onChanged,汇总跨段可见
    await tester.tap(find.text('完成(2)'));
    await tester.pumpAndSettle();
    expect(subjects.length, 2);
    expect(subjects[0].kind, SubjectKind.user);
    expect(subjects[1].kind, SubjectKind.group);
    expect(find.textContaining('已选 2 项'), findsOneWidget);
    expect(find.widgetWithText(InputChip, '👤 乙'), findsOneWidget);
    expect(find.widgetWithText(InputChip, '🏷 后期组'), findsOneWidget);

    // 移除用户 chip(👤 乙):直接触发 InputChip.onDeleted(删除图标受 tooltip
    // 包装,finder 不稳;语义等价用户点 ×)
    tester.widget<InputChip>(find.widgetWithText(InputChip, '👤 乙'))
        .onDeleted!();
    await tester.pump();
    expect(subjects.single.kind, SubjectKind.group,
        reason: '跨段移除同步 value');
  });
}
