/// 项目成员管理单测(B6 测试功能点 5):成员列表(角色徽章)+ 逐角色撤销确认;
/// 添加表单(用户/组 × 角色多选)逐主体 POST;角色枚举=web 实况;
/// 409 detail 透传(自撤 admin/末位 admin)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/projects/project_members_sheet.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

void main() {
  testWidgets('成员列表展示角色;点角色撤销带 subject+role;409 detail 透传', (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = installFakeApi();
    api.projectsOps.listMembersStaged = [
      ProjectMember(
        subject: 'user:u1',
        kind: 'user',
        subjectId: 'u1',
        name: '甲',
        roles: const ['admin', 'viewer'],
      ),
      ProjectMember(
        subject: 'group:g1#member',
        kind: 'group',
        subjectId: 'g1',
        name: '后期组',
        roles: const ['uploader'],
      ),
    ];
    api.projectsOps.removeMemberStaged = ApiException(
      409,
      '不允许撤销自己的项目管理员角色;请先邀请其他管理员,再让对方撤销你',
    );
    addTearDown(() => session.api = null);
    session.me = Me(id: 'u0', name: '管');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: FilledButton(
                onPressed: () => showProjectMembersSheet(
                  ctx,
                  project: Project(id: 'p1', name: '演示项目', code: 'demo'),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('成员 · 演示项目'), findsOneWidget);
    expect(find.text('甲'), findsWidgets, reason: '头像首字+标题');
    expect(find.text('后期组'), findsOneWidget, reason: '群组名');
    expect(find.text('群组 · 项目成员'), findsOneWidget, reason: '来源/角色行');
    // 角色徽章按 ROLE_ORDER 序(admin>uploader>downloader>viewer);
    // app-polish E13:徽章不再带「×」文案,撤销入口=徽章行尾显式移除图标钮
    expect(find.text('管理'), findsOneWidget);
    expect(find.text('查看'), findsOneWidget);
    expect(find.text('上传'), findsOneWidget);

    // 撤自己的 admin → 显式移除钮(语义 icon)→ 确认层 → 409 detail 透传
    await tester.tap(find.byTooltip('移除管理角色'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '撤销'));
    await tester.pumpAndSettle();
    expect(api.projectsOps.removeMemberCalls.single, (
      projectId: 'p1',
      subject: 'user:u1',
      role: 'admin',
    ));
    expect(find.textContaining('不允许撤销自己的项目管理员角色'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6)); // 清 SnackBar timer
    await tester.pumpAndSettle();
  });

  testWidgets('添加成员:组主体×多角色一次授予;角色枚举=web 实况', (tester) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = installFakeApi();
    api.users.groupResult = [GroupBrief(id: 'g1', name: '后期组', memberCount: 5)];
    addTearDown(() => session.api = null);
    session.me = Me(id: 'me1', name: '甲');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: FilledButton(
                onPressed: () => showProjectMembersSheet(
                  ctx,
                  project: Project(id: 'p1', name: '演示项目', code: 'demo'),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加成员'));
    await tester.pumpAndSettle();

    // 选组主体:app-polish D1 起主体选择走弹层(原内联常驻列表已下线)——
    // 点「添加用户 / 用户组」→ 弹层内切「用户组」段 → 勾后期组 → 完成回填
    await tester.tap(find.text('添加用户 / 用户组'));
    await tester.pumpAndSettle(); // 弹层进场动画
    await tester.pump(const Duration(milliseconds: 300)); // 用户段空 query 防抖
    await tester.pumpAndSettle();
    await tester.tap(find.text('用户组'));
    await tester.pump(const Duration(milliseconds: 300)); // 换段按关键词重搜防抖
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '后期组'));
    await tester.pump(); // 勾选即时回填「完成(1)」
    await tester.tap(find.text('完成(1)'));
    await tester.pumpAndSettle(); // 退场动画后 onChanged 回填
    expect(find.textContaining('已选 1 项'), findsOneWidget);

    // 默认勾「查看」,加勾「管理」→ 一次授两角色
    await tester.tap(find.text('管理'));
    await tester.pump();
    await tester.tap(find.text('添加').last);
    await tester.pumpAndSettle();

    final call = api.projectsOps.addMemberCalls.single;
    expect(call.projectId, 'p1');
    expect(call.groupId, 'g1');
    expect(
      call.roles,
      ['admin', 'viewer'],
      reason:
          'roles 固定序=kProjectRoles(admin/uploader/downloader/viewer,web 同款)',
    );
    // 成功回成员列表
    expect(find.text('成员 · 演示项目'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('授权总览:审批/邀请 grant 展示+四元组撤回', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = installFakeApi();
    api.projectsOps.listGrantsStaged = [
      ProjectGrantRow(
        subject: 'user:u2',
        kind: 'user',
        subjectId: 'u2',
        name: '乙',
        objectType: 'sensitive_folder',
        objectId: 'sf1',
        objectName: '敏感夹',
        relation: 'explicit_invited_downloader',
        level: 'download',
        permanent: false,
        expiresAt: '2026-10-25T10:00:00Z',
      ),
    ];
    addTearDown(() => session.api = null);
    session.me = Me(id: 'u0', name: '管');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: FilledButton(
                onPressed: () => showProjectMembersSheet(
                  ctx,
                  project: Project(id: 'p1', name: '演示项目', code: 'demo'),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.textContaining('乙 · 敏感目录「敏感夹」'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '撤回'));
    await tester.pumpAndSettle();
    expect(api.projectsOps.revokeGrantCalls.single, (
      projectId: 'p1',
      objectType: 'sensitive_folder',
      objectId: 'sf1',
      subject: 'user:u2',
      relation: 'explicit_invited_downloader',
    ));
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });
}
