/// 我的权限单测(B7 测试功能点 3):双数据源合并(projects my_roles +
/// approvals self&approved)/倒计时格式(GrantCountdown 同款 fmt)/
/// 永久/已过期/剩余档位色彩;数据源口径入参断言。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/permissions/grant_row.dart';
import 'package:ms_app/features/permissions/my_permissions_page.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/theme/tokens.dart';
import 'package:ms_app/widgets/error_view.dart';

import '../helpers/api_harness.dart';

Approval grantOf(String id,
    {int? durationSeconds,
    String decidedAt = '2026-10-20T09:00:00Z'}) => Approval(
      id: id,
      applicantUserId: 'u0',
      targetType: 'asset',
      targetId: 'a$id',
      action: 'download',
      durationSeconds: durationSeconds,
      reason: 'r',
      status: 'approved',
      decidedAt: decidedAt,
      createdAt: '2026-10-20T08:00:00Z',
      requesterName: '我',
      targetName: 'A00$id.jpg',
    );

void main() {
  // ── 纯函数:倒计时格式(GrantCountdown fmt 同款)────────────────────────
  test('fmtRemain 四档:秒/分秒/时分/天时', () {
    expect(fmtRemain(45), '45s');
    expect(fmtRemain(125), '2m 5s');
    expect(fmtRemain(7385), '2h 3m');
    expect(fmtRemain(3 * 86400 + 2 * 3600 + 60), '3d 2h');
  });

  test('countdownSpec:永久(decided_at 缺失同)/已过期/档位色(30%/10%)', () {
    final base = DateTime.parse('2026-10-20T09:00:00Z').toLocal();
    DateTime at(int seconds) => base.add(Duration(seconds: seconds));

    // 永久:duration null
    expect(countdownSpec(grantOf('1', durationSeconds: null)).permanent, isTrue);
    // decided_at 缺失兜底永久
    final noDecided = Approval(
        id: 'x', applicantUserId: 'u', targetType: 'asset', targetId: 'a',
        action: 'download', durationSeconds: 3600, reason: 'r',
        status: 'approved', createdAt: '');
    expect(countdownSpec(noDecided).permanent, isTrue);

    final g = grantOf('2', durationSeconds: 1000, decidedAt: '2026-10-20T09:00:00Z');
    // 剩余占比:750s 剩 75% → green;250s 剩 25% → amber;50s 剩 5% → red;到点 → 已过期
    expect(countdownSpec(g, now: at(250)).color, Tk.green);
    expect(countdownSpec(g, now: at(750)).color, Tk.amber);
    expect(countdownSpec(g, now: at(950)).color, Tk.red);
    final expired = countdownSpec(g, now: at(1000));
    expect(expired.expired, isTrue);
    expect(expired.label, '已过期');
  });

  // ── 页面:双数据源合并 ──────────────────────────────────────────────────
  testWidgets('双数据源:项目角色(my_roles)+临时授权(approved)同屏;口径断言',
      (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    api.approvalsOps.listResult = [
      grantOf('1', durationSeconds: null), // 永久
      // 1h 倒计时:decidedAt 取当前时刻(页面不走注入时钟,须相对真实 now)
      grantOf('2', durationSeconds: 3600,
          decidedAt: DateTime.now().toUtc().toIso8601String()),
    ];
    api.projects.listStaged = [
      Project(id: 'p1', name: '项目一', code: 'P1', myRoles: const ['admin']),
      Project(id: 'p2', name: '访客见', code: 'P2', myRoles: const []),
    ];

    await tester.pumpWidget(const MaterialApp(home: MyPermissionsPage()));
    await tester.pumpAndSettle();

    expect(api.approvalsOps.listCalls.single.scope, 'self');
    expect(api.approvalsOps.listCalls.single.status, 'approved',
        reason: '数据源=approvals scope=self&status=approved(勿逐夹 grants)');
    expect(find.text('临时授权'), findsOneWidget);
    expect(find.text('下载'), findsNWidgets(2), reason: '动作 chip(两条均 download)');
    expect(find.text('文件 · A001.jpg'), findsOneWidget);
    expect(find.text('永久'), findsOneWidget);
    expect(find.text('剩余'), findsOneWidget, reason: '有时效授权显倒计时');
    expect(find.text('项目角色'), findsOneWidget);
    expect(find.text('项目一(P1)'), findsOneWidget);
    expect(find.text('仅访客可见'), findsOneWidget);
    expect(find.text('访客见'), findsOneWidget,
        reason: 'guest 行弱化不带 code');
  });

  testWidgets('单源失败(P2-4):approvals 500 仍显项目角色,不整页报错',
      (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    api.approvalsOps.listStaged = [ApiException(500, 'approvals down')];
    api.projects.listStaged = [
      Project(id: 'p1', name: '项目一', code: 'P1', myRoles: const ['admin']),
    ];

    await tester.pumpWidget(const MaterialApp(home: MyPermissionsPage()));
    await tester.pumpAndSettle();

    expect(find.byType(ErrorView), findsNothing,
        reason: '单源失败不整页报错(两源独立可用)');
    expect(api.approvalsOps.listCalls.single.scope, 'self');
    expect(api.approvalsOps.listCalls.single.status, 'approved');
    expect(find.text('项目角色'), findsOneWidget, reason: '成功源照常渲染');
    expect(find.text('项目一(P1)'), findsOneWidget);
    expect(find.text('临时授权'), findsNothing, reason: '失败源落空不显段');
  });

  testWidgets('GrantCountdown:固定时钟渲染剩余文案;过期态展示「已过期」',
      (tester) async {
    final fixed = DateTime.parse('2026-10-20T09:30:00Z'); // 剩余 30m=50%
    final g = grantOf('2', durationSeconds: 3600);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GrantCountdown(
            approval: g, nowProvider: () => fixed),
      ),
    ));
    expect(find.text('30m 0s'), findsOneWidget);
    expect(find.text('剩余'), findsOneWidget);

    final gExpired = grantOf('3', durationSeconds: 60,
        decidedAt: '2026-10-19T09:00:00Z');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GrantCountdown(approval: gExpired, nowProvider: () => fixed),
      ),
    ));
    expect(find.text('已过期'), findsOneWidget);
  });

  testWidgets('GrantRow:访问动作 chip 文案区分 access/download', (tester) async {
    final access = Approval(
        id: 'g9', applicantUserId: 'u0', targetType: 'sensitive_folder',
        targetId: 'f1', action: 'access', durationSeconds: null, reason: 'r',
        status: 'approved', decidedAt: '2026-10-20T09:00:00Z',
        createdAt: '', targetName: '艺人文档');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: GrantRow(approval: access,
                nowProvider: () => DateTime(2026, 10, 20, 10)))));
    expect(find.text('敏感目录 · 艺人文档'), findsOneWidget,
        reason: '行=类型 · 对象名');
    expect(find.text('永久'), findsOneWidget);
  });
}
