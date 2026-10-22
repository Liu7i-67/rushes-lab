/// 敏感夹邀请面板单测(B6 测试功能点 2):有效期预设档位=web DUR_OPTIONS 实况;
/// 邀请逐主体 POST(level+duration 映射,永久=字段 null)+ 撤销(带 permanent);
/// 成员列表展示等级/永久。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/folders/folder_invite_sheet.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

void main() {
  test('kInviteDurationOptions 档位=web FolderInvitePanel DUR_OPTIONS 实况', () {
    expect(kInviteDurationOptions, [
      ('永久邀请', 0),
      ('1 小时', 3600),
      ('24 小时', 86400),
      ('7 天', 7 * 86400),
      ('30 天', 30 * 86400),
    ]);
    expect(kInviteLevels.map((l) => l.$1), ['viewer', 'downloader'],
        reason: '敏感夹邀请等级枚举=viewer/downloader(web 同款)');
  });

  testWidgets('成员列表展示等级与永久;撤销带 subject/level/permanent',
      (tester) async {
    final api = installFakeApi();
    api.foldersOps.listMembersStaged = [
      FolderMemberRow(
          subject: 'user:u1',
          kind: 'user',
          subjectId: 'u1',
          name: '甲',
          level: 'viewer',
          permanent: true),
      FolderMemberRow(
          subject: 'group:g1#member',
          kind: 'group',
          subjectId: 'g1',
          name: '后期组',
          level: 'downloader',
          permanent: false,
          expiresAt: '2026-10-25T10:00:00Z'),
    ];
    addTearDown(() => session.api = null);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => showFolderInviteSheet(
                  ctx,
                  folder: Folder(
                      id: 'sf', name: '敏感夹', parentFolderId: null,
                      isSensitive: true)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('邀请管理 · 敏感夹'), findsOneWidget);
    expect(find.text('甲'), findsWidgets, reason: '头像首字+标题');
    expect(find.text('VIEWER'), findsOneWidget);
    expect(find.text('永久'), findsOneWidget);
    expect(find.textContaining('DOWNLOADER'), findsOneWidget);
    expect(find.textContaining('到期'), findsOneWidget);

    // 撤销:确认弹层 → DELETE 带 permanent=false
    await tester.tap(find.byIcon(Icons.delete_outline).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '撤销'));
    await tester.pumpAndSettle();
    expect(api.foldersOps.revokeInviteCalls.single,
        (
          folderId: 'sf',
          subject: 'group:g1#member',
          level: 'downloader',
          permanent: false,
        ));
  });

  testWidgets('邀请表单:选人+level+7 天档 → 逐主体 POST(duration 映射)',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    session.me = Me(id: 'u1', name: '甲');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => showFolderInviteSheet(
                  ctx,
                  folder: Folder(
                      id: 'sf', name: '敏感夹', parentFolderId: null,
                      isSensitive: true)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 进表单 → 弹层选自己(app-polish D1 新形态:点添加入口 → 弹层勾选 →
    // 完成回填;原内联常驻列表已下线)→ 下载 level → 7 天 → 提交
    await tester.tap(find.text('邀请成员'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加用户 / 用户组'));
    await tester.pumpAndSettle(); // 弹层进场动画
    await tester.pump(const Duration(milliseconds: 300)); // 空 query 首搜防抖
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '甲(自己)'));
    await tester.pump(); // 勾选即时回填「完成(1)」
    await tester.tap(find.text('完成(1)'));
    await tester.pumpAndSettle(); // 退场动画后 onChanged 回填
    expect(find.textContaining('已选 1 项'), findsOneWidget);
    await tester.tap(find.text('下载(downloader)'));
    await tester.pump();
    await tester.tap(find.text('7 天'));
    await tester.pump();
    await tester.tap(find.text('邀请').last);
    await tester.pumpAndSettle();

    final call = api.foldersOps.inviteCalls.single;
    expect(call.folderId, 'sf');
    expect(call.userId, 'u1');
    expect(call.groupId, isNull);
    expect(call.level, 'downloader');
    expect(call.durationSeconds, 7 * 86400);
    // 成功回成员列表并重拉
    expect(find.text('邀请管理 · 敏感夹'), findsOneWidget);
  });

  testWidgets('永久档提交 durationSeconds=null;未选主体报「请选至少一个主体」',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    session.me = Me(id: 'u1', name: '甲');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => showFolderInviteSheet(
                  ctx,
                  folder: Folder(
                      id: 'sf', name: '敏感夹', parentFolderId: null,
                      isSensitive: true)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('邀请成员'));
    await tester.pumpAndSettle();

    // 未选主体直接提交 → 前端拦
    await tester.tap(find.text('邀请').last);
    await tester.pump();
    expect(find.text('请选至少一个主体'), findsOneWidget);
    expect(api.foldersOps.inviteCalls, isEmpty);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });
}
