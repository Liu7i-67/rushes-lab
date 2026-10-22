/// RemotePickerSheet(app-polish-3 测试功能点 4/5,包 C1):
/// - showUserPickerSheet 多选勾 2 项「完成(2)」返回 2 项;单选点选即关返回 1 项;
///   点 X 关闭返回 null(取消语义);
/// - 搜索 250ms 防抖:停顿窗口内改词只发最终一次请求(带 q);
/// - 空结果「无匹配」空态;空 query 注入 preset 且不与远程结果重复;
/// - showGroupPickerSheet 单/多选基本路径;memberCount=null 不显示「0 人」。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/widgets/pickers/remote_picker_sheet.dart';

import '../helpers/api_harness.dart';

UserBrief _u(String id, String name, {String? username}) =>
    UserBrief(id: id, name: name, username: username);

GroupBrief _g(String id, String name, {int? memberCount}) =>
    GroupBrief(id: id, name: name, memberCount: memberCount);

/// 弹层内行文本(字段遮罩后仍在树里,行断言一律限定 BottomSheet 去重)。
Finder _sheetText(String label) => find.descendant(
      of: find.byType(BottomSheet),
      matching: find.text(label),
    );

/// 弹层内搜索框。
Finder _sheetField() => find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(TextField),
    );

void main() {
  // ── showUserPickerSheet(功能点 4)──────────────────────────────────────────

  testWidgets('功能点 4:多选勾 2 项 → 底部「完成(2)」返回 2 项(id 一致)',
      (tester) async {
    final api = installFakeApi();
    api.users.userResult = [_u('u1', '张三'), _u('u2', '李四'), _u('u3', '王五')];
    addTearDown(() => session.api = null);

    Future<List<UserBrief>?>? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => picked = showUserPickerSheet(
                  context: ctx, initial: const [], multiple: true),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(_sheetText('张三'));
    await tester.pump();
    await tester.tap(_sheetText('李四'));
    await tester.pumpAndSettle();
    expect(_sheetText('完成(2)'), findsOneWidget,
        reason: '多选底部完成钮即时回显已勾数量');

    await tester.tap(_sheetText('完成(2)'));
    await tester.pumpAndSettle(); // 退场动画后 route 结果才 complete
    final result = await picked;

    expect(result, isNotNull, reason: '完成 = 显式提交,非取消');
    expect(result, hasLength(2), reason: '勾 2 项提交 2 项');
    expect(result!.map((u) => u.id), ['u1', 'u2'], reason: '按勾选序返回');
  });

  testWidgets('功能点 4:单选点选即关并返回 1 项(无需完成钮)', (tester) async {
    final api = installFakeApi();
    api.users.userResult = [_u('u1', '张三'), _u('u2', '李四')];
    addTearDown(() => session.api = null);

    Future<List<UserBrief>?>? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => picked = showUserPickerSheet(
                  context: ctx, initial: const [], multiple: false),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(_sheetText('李四'));
    await tester.pumpAndSettle(); // 退场动画后 route 结果才 complete
    final result = await picked;

    expect(result, hasLength(1), reason: '单选点选即关(I1 口径),返回所点 1 项');
    expect(result!.single.id, 'u2');
  });

  testWidgets('功能点 4:点 X 关闭返回 null(取消不动现值)', (tester) async {
    installFakeApi();
    addTearDown(() => session.api = null);

    Future<List<UserBrief>?>? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => picked = showUserPickerSheet(
                  context: ctx, initial: const [], multiple: true),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle(); // 退场动画后 route 结果才 complete
    final result = await picked;

    expect(result, isNull, reason: '关闭(null)语义 = 取消,调用方不动现值');
  });

  testWidgets('功能点 4:搜索 250ms 防抖——停顿窗口内改词,只按最终词发 1 次',
      (tester) async {
    final api = installFakeApi();
    api.users.userResult = [_u('u1', '张三')];
    addTearDown(() => session.api = null);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => showUserPickerSheet(
                  context: ctx, initial: const [], multiple: true),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final baseCalls = api.users.userSearchCalls.length; // 初始空 query 1 次
    await tester.enterText(_sheetField(), '张');
    await tester.pump(const Duration(milliseconds: 100)); // 停顿窗口内改词
    await tester.enterText(_sheetField(), '张李王');
    await tester.pump(const Duration(milliseconds: 300)); // 越过 250ms 防抖
    await tester.pumpAndSettle();

    final typed = api.users.userSearchCalls.sublist(baseCalls);
    expect(typed, hasLength(1), reason: '防抖窗口内改词必须取消前次计时器,只发 1 次');
    expect(typed.single.q, '张李王', reason: '发出的请求携带最终关键词');
  });

  testWidgets('功能点 4:远程空结果显示「无匹配」空态', (tester) async {
    final api = installFakeApi();
    api.users.userResult = const [];
    addTearDown(() => session.api = null);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => showUserPickerSheet(
                  context: ctx, initial: const [], multiple: true),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(_sheetText('无匹配'), findsOneWidget, reason: '空结果空态文案(I1 口径)');
  });

  testWidgets('功能点 4:空 query 注入 preset——远程未含 preset 时补进候选;'
      '远程已含同 id 时不重复出现', (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    final me = _u('me1', '我甲', username: 'me1');

    // Case A:远程结果不含 preset → 头部注入
    api.users.userResult = [_u('u2', '李四')];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => showUserPickerSheet(
                  context: ctx, initial: const [], preset: [me]),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(_sheetText('我甲'), findsOneWidget, reason: '空 query 注入 preset(自己)');
    expect(_sheetText('李四'), findsOneWidget);

    // Case B:重开弹层,远程结果已含 preset 同 id → 只出现一次(#114 防劫持)
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    api.users.userResult = [me, _u('u2', '李四')];
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(_sheetText('我甲'), findsOneWidget, reason: 'preset 与远程同 id 去重');
  });

  // ── showGroupPickerSheet(功能点 5)─────────────────────────────────────────

  testWidgets('功能点 5:组多选勾 2 项「完成(2)」返回 2 项;单选点选即关返回 1 项',
      (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);

    // 多选
    api.users.groupResult = [_g('g1', '后期组', memberCount: 5), _g('g2', '前期组')];
    Future<List<GroupBrief>?>? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => picked = showGroupPickerSheet(
                  context: ctx, initial: const [], multiple: true),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(_sheetText('后期组'));
    await tester.pump();
    await tester.tap(_sheetText('前期组'));
    await tester.pumpAndSettle();
    await tester.tap(_sheetText('完成(2)'));
    await tester.pumpAndSettle(); // 退场动画后 route 结果才 complete
    final multi = await picked;
    expect(multi, hasLength(2), reason: '组多选同用户多选口径');
    expect(multi!.map((g) => g.id), ['g1', 'g2']);

    // 单选
    api.users.groupResult = [_g('g1', '后期组', memberCount: 5)];
    Future<List<GroupBrief>?>? picked1;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => picked1 = showGroupPickerSheet(
                  context: ctx, initial: const [], multiple: false),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(_sheetText('后期组'));
    await tester.pumpAndSettle(); // 退场动画后 route 结果才 complete
    final single = await picked1;
    expect(single, hasLength(1), reason: '组单选点选即关');
    expect(single!.single.id, 'g1');
  });

  testWidgets('功能点 5:memberCount=null 的组行不显示「0 人」;'
      'memberCount=5 显示「5 人」', (tester) async {
    final api = installFakeApi();
    api.users.groupResult = [_g('g1', '未统计组', memberCount: null), _g('g2', '采购组', memberCount: 5)];
    addTearDown(() => session.api = null);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => showGroupPickerSheet(
                  context: ctx, initial: const [], multiple: true),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(_sheetText('5 人'), findsOneWidget, reason: '有成员数正常显示「N 人」副标题');
    expect(_sheetText('0 人'), findsNothing,
        reason: 'memberCount=null 不得兜底成「0 人」(C1 明细要求)');
    expect(find.descendant(
        of: find.byType(BottomSheet),
        matching: find.textContaining('人'),
      ), findsOneWidget,
      reason: '弹层内唯一含「人」文案 = 「5 人」(null 组不产生人数副标题)');
  });
}
