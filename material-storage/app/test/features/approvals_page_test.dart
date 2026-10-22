/// 审批中心单测(B7 测试功能点 1 + B7 批 P2-2/P2-3):scope 口径(待我审批=
/// all&pending / 我发起的=self 无 status)/初始段按身份分流(admin=待我审批,
/// 非 admin=我发起的)/分段代际防护(慢旧段响应不覆盖新段)/决策确认+成功刷新
/// /403 detail 透传/MePage badge 仅 admin(pending 数同源)。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/approvals/approvals_page.dart';
import 'package:ms_app/features/me/me_page.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/widgets/badge.dart' as wg;

import '../helpers/api_harness.dart';

Approval approvalOf(String id,
    {String status = 'pending', String? targetName}) => Approval(
      id: id,
      applicantUserId: 'u9',
      targetType: 'asset',
      targetId: 'a$id',
      action: 'download',
      durationSeconds: 86400,
      reason: '关单需要源文件',
      status: status,
      createdAt: '2026-10-20T09:00:00Z',
      requesterName: '小王',
      targetName: targetName ?? 'A001.jpg',
    );

void main() {
  testWidgets('待我审批=scope all&status pending;切我发起的=scope self 无 status',
      (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    addTearDown(() => session.me = null);
    session.me = Me(id: 'u0', name: '管', isSystemAdmin: true);
    api.approvalsOps.listResult = [approvalOf('1')];

    await tester.pumpWidget(const MaterialApp(home: ApprovalsPage()));
    await tester.pumpAndSettle();
    expect(api.approvalsOps.listCalls.first.scope, 'all');
    expect(api.approvalsOps.listCalls.first.status, 'pending');
    expect(find.text('小王 申请下载 · 1 天'), findsOneWidget);
    expect(find.text('文件 · A001.jpg'), findsOneWidget);
    expect(find.text('关单需要源文件'), findsOneWidget);

    await tester.tap(find.text('我发起的'));
    await tester.pumpAndSettle();
    expect(api.approvalsOps.listCalls.last.scope, 'self');
    expect(api.approvalsOps.listCalls.last.status, isNull);
  });

  testWidgets('初始段按身份分流(P2-2):admin=待我审批;非 admin=我发起的',
      (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    addTearDown(() => session.me = null);
    api.approvalsOps.listResult = const [];

    // admin:初始即「待我审批」段(scope=all&status=pending)
    session.me = Me(id: 'u0', name: '管', isSystemAdmin: true);
    await tester.pumpWidget(const MaterialApp(home: ApprovalsPage()));
    await tester.pumpAndSettle();
    expect(api.approvalsOps.listCalls.single.scope, 'all');
    expect(api.approvalsOps.listCalls.single.status, 'pending');
    final adminSeg = tester.widget<SegmentedButton>(
        find.byWidgetPredicate((w) => w is SegmentedButton));
    expect((adminSeg.selected.single as Enum).name, 'pending',
        reason: 'admin 默认待我审批');

    // 非 admin:初始落「我发起的」(scope=self 无 status),不落 scope=all 全组织噪声
    session.me = Me(id: 'u1', name: '员', isSystemAdmin: false);
    api.approvalsOps.listCalls.clear();
    await tester.pumpWidget(
        MaterialApp(home: ApprovalsPage(key: UniqueKey())));
    await tester.pumpAndSettle();
    expect(api.approvalsOps.listCalls.single.scope, 'self',
        reason: '非 admin 默认 self(web 同款)');
    expect(api.approvalsOps.listCalls.single.status, isNull);
    final memberSeg = tester.widget<SegmentedButton>(
        find.byWidgetPredicate((w) => w is SegmentedButton));
    expect((memberSeg.selected.single as Enum).name, 'mine',
        reason: '非 admin 默认我发起的');
  });

  testWidgets('分段代际防护(P2-3):切段后旧段慢响应落地不覆盖新段',
      (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    addTearDown(() => session.me = null);
    session.me = Me(id: 'u0', name: '管', isSystemAdmin: true);
    final oldSeg = Completer<List<Approval>>();
    api.approvalsOps.listStaged = [
      oldSeg, // 首拉(待我审批)挂起 → 模拟慢旧段
      [approvalOf('s1', status: 'approved', targetName: 'SELF1.jpg')], // 切段后立回
    ];

    await tester.pumpWidget(const MaterialApp(home: ApprovalsPage()));
    await tester.pump();
    expect(api.approvalsOps.listCalls.single.scope, 'all',
        reason: '首拉=旧段(挂起中)');

    await tester.tap(find.text('我发起的'));
    await tester.pumpAndSettle();
    expect(api.approvalsOps.listCalls.last.scope, 'self');
    expect(find.textContaining('SELF1.jpg'), findsOneWidget,
        reason: '新段数据已上屏');

    oldSeg.complete([approvalOf('old1', targetName: 'OLD1.jpg')]); // 旧段慢响应放行
    await tester.pumpAndSettle();

    expect(find.textContaining('OLD1.jpg'), findsNothing, reason: '旧段响应被代际丢弃');
    expect(find.textContaining('SELF1.jpg'), findsOneWidget, reason: '新段不被污染');
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: '_loading 不被丢弃的旧段卡死');
  });

  testWidgets('批准带确认→调用 approve→刷新列表', (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    addTearDown(() => session.me = null);
    session.me = Me(id: 'u0', name: '管', isSystemAdmin: true);
    api.approvalsOps.listResult = [approvalOf('a1')];

    await tester.pumpWidget(const MaterialApp(home: ApprovalsPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('批准'));
    await tester.pumpAndSettle();
    expect(find.text('确认通过该申请?'), findsOneWidget, reason: '批准带确认');
    // 卡片按钮与弹窗按钮同名:只点对话框内的那个
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('批准')));
    await tester.pumpAndSettle();

    expect(api.approvalsOps.decideCalls.single.id, 'a1');
    expect(api.approvalsOps.decideCalls.single.approve, isTrue);
    // app-polish E8:决策成功改为按 id 局部更新(不再整列表重拉),滚动位置
    // 天然保持——原「刷新列表 listCalls=2」断言随实现翻转
    expect(api.approvalsOps.listCalls.length, 1,
        reason: 'E8:决策后局部更新,不整列表重拉');
    expect(find.textContaining('已批准'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6)); // 清 SnackBar timer
    await tester.pumpAndSettle();
  });

  testWidgets('非管理者 403 detail 透传(后端 enforce_admin_for_target 守门)',
      (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    addTearDown(() => session.me = null);
    session.me = Me(id: 'u0', name: '管', isSystemAdmin: true);
    api.approvalsOps.listResult = [approvalOf('a1')];
    api.approvalsOps.decideStaged =
        ApiException(403, '无该项目审批权限(仅项目管理员/系统管理员可审批)');

    await tester.pumpWidget(const MaterialApp(home: ApprovalsPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('批准'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('批准')));
    await tester.pumpAndSettle();

    expect(find.textContaining('无该项目审批权限'), findsOneWidget,
        reason: '403 detail 透传');
    expect(api.approvalsOps.listCalls.length, 1, reason: '失败不刷新');
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('MePage 审批中心入口:badge 仅 admin 且=待审数;非 admin 无 badge',
      (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    api.approvalsOps.listResult = [
      approvalOf('1'),
      approvalOf('2'),
    ];

    // admin:入口挂 badge=2,且拉取口径 all&pending(badge 同源)
    session.me = Me(id: 'u0', name: '管', isSystemAdmin: true);
    await tester.pumpWidget(const MaterialApp(home: MePage()));
    await tester.pumpAndSettle();
    expect(find.text('审批中心'), findsOneWidget);
    expect(api.approvalsOps.listCalls.last.scope, 'all');
    expect(api.approvalsOps.listCalls.last.status, 'pending');
    expect(find.descendant(
        of: find.byType(wg.Badge), matching: find.text('2')), findsOneWidget);

    // 非 admin:入口可见但无 badge、不发 badge 请求
    session.me = Me(id: 'u1', name: '员', isSystemAdmin: false);
    api.approvalsOps.listCalls.clear();
    await tester.pumpWidget(MaterialApp(home: MePage(key: UniqueKey())));
    await tester.pumpAndSettle();
    expect(find.text('审批中心'), findsOneWidget);
    expect(api.approvalsOps.listCalls, isEmpty, reason: '非 admin 不拉 badge 数');
    expect(find.descendant(
        of: find.byType(wg.Badge), matching: find.text('2')), findsNothing);
  });
}
