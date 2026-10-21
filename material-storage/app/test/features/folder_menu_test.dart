/// ⋯ 菜单闸门单测(B6 测试功能点 1/2/3 入口显隐):闸门=单夹详情(web
/// ProjectDetailPage 实况)——新建子夹 upload;重命名 sensitive?admin:upload;
/// 移动=普通夹+upload;邀请管理仅敏感夹(admin);授权管理仅普通一级夹
/// (admin);删除 sensitive?admin:(upload||delete_grant);409 透传文案。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/refresh_bus.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/folders/folder_row.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

Future<void> pumpMenu(WidgetTester tester, Folder row,
    {bool setView = true}) async {
  if (setView) {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }
  late BuildContext captured;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (ctx) {
          captured = ctx;
          return Center(
            child: FilledButton(
              onPressed: () => showFolderMenu(captured, folder: row),
              child: const Text('open'),
            ),
          );
        },
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

bool enabledOf(WidgetTester tester, String title) => tester
    .widget<ListTile>(find.ancestor(
        of: find.text(title), matching: find.byType(ListTile)))
    .enabled;

void main() {
  testWidgets('普通一级夹(admin):全动作启用,授权管理入口出现,邀请管理不出现',
      (tester) async {
    final api = installFakeApi();
    api.folders.getResult = Folder(
        id: 'f1', name: '档案夹', parentFolderId: null, projectId: 'p1',
        isSensitive: false, myCanAdmin: true, myCanUpload: true,
        myDeleteGrant: false);
    addTearDown(() => session.api = null);
    session.me = Me(id: 'u1', name: '甲');

    await pumpMenu(
        tester,
        Folder(id: 'f1', name: '档案夹', parentFolderId: null));
    expect(enabledOf(tester, '新建子文件夹'), isTrue);
    expect(enabledOf(tester, '重命名'), isTrue);
    expect(enabledOf(tester, '移动'), isTrue);
    expect(enabledOf(tester, '授权管理'), isTrue, reason: '普通一级夹→grants 入口');
    expect(enabledOf(tester, '删除'), isTrue);
    expect(find.text('邀请管理'), findsNothing, reason: '敏感夹才有邀请入口');
    // B9 P2-4 定稿(qplan 口径「项目内发起位=my_can_admin」):folder admin
    // 可见可点发起请求链接
    expect(enabledOf(tester, '请求链接'), isTrue,
        reason: 'folder admin(my_can_admin=true)可见可点,勿置灰');
  });

  testWidgets('普通子夹仅 upload(无 admin):子夹/重命名/移动/删除可,授权管理不出现;'
      '敏感子树夹禁移动', (tester) async {
    final api = installFakeApi();
    api.folders.getResult = Folder(
        id: 'f2', name: '子夹', parentFolderId: 'f1', projectId: 'p1',
        isSensitive: false, myCanAdmin: false, myCanUpload: true,
        myDeleteGrant: false);
    addTearDown(() => session.api = null);
    session.me = Me(id: 'u1', name: '甲');

    await pumpMenu(tester, Folder(id: 'f2', name: '子夹', parentFolderId: 'f1'));
    expect(enabledOf(tester, '新建子文件夹'), isTrue);
    expect(enabledOf(tester, '重命名'), isTrue, reason: '普通夹重命名=upload');
    expect(enabledOf(tester, '移动'), isTrue);
    expect(enabledOf(tester, '删除'), isTrue, reason: '普通夹删除=upload');
    expect(find.text('授权管理'), findsNothing, reason: '仅一级夹有 grants 入口');
    expect(find.text('请求链接'), findsNothing,
        reason: 'my_can_admin=false 完全不渲染(P2-4:勿置灰)');
  });

  testWidgets('敏感夹(admin):邀请管理入口出现,移动禁用;非 admin 删除禁用',
      (tester) async {
    final api = installFakeApi();
    api.folders.getResult = Folder(
        id: 'sf', name: '敏感夹', parentFolderId: null, projectId: 'p1',
        isSensitive: true, myCanAdmin: true, myCanUpload: true);
    addTearDown(() => session.api = null);
    session.me = Me(id: 'u1', name: '甲');
    await pumpMenu(
        tester,
        Folder(id: 'sf', name: '敏感夹', parentFolderId: null,
            isSensitive: true));
    expect(find.text('邀请管理'), findsOneWidget, reason: '0选+敏感→invite(web 实况)');
    expect(enabledOf(tester, '邀请管理'), isTrue);
    expect(enabledOf(tester, '移动'), isFalse, reason: 'sensitive 源禁移动');
    expect(enabledOf(tester, '重命名'), isTrue, reason: '敏感夹重命名=admin');
    expect(find.text('授权管理'), findsNothing, reason: '敏感夹无 grants 入口');
    expect(enabledOf(tester, '删除'), isTrue);
    expect(enabledOf(tester, '请求链接'), isTrue,
        reason: '敏感夹 admin 亦可见请求链接(target=sensitive_folder)');
  });

  testWidgets('删除空夹成功 → 失效 folders + 409 detail 透传(非空夹)',
      (tester) async {
    final api = installFakeApi();
    api.folders.getResult = Folder(
        id: 'f1', name: '档案夹', parentFolderId: null, projectId: 'p1',
        isSensitive: false, myCanAdmin: true, myCanUpload: true);
    api.foldersOps.deleteStaged =
        ApiException(409, '回收站内还有已删除文件,请先在回收站中彻底清空后再删除文件夹');
    addTearDown(() => session.api = null);
    session.me = Me(id: 'u1', name: '甲');
    var folders = 0;
    void onFolders() => folders++;
    RefreshBus.I.addListener('folders', onFolders);
    addTearDown(() => RefreshBus.I.removeListener('folders', onFolders));

    await pumpMenu(
        tester,
        Folder(id: 'f1', name: '档案夹', parentFolderId: null));
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    // 确认文案明示不可恢复
    expect(find.textContaining('不可恢复'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(api.foldersOps.deleteCalls, ['f1']);
    expect(find.textContaining('回收站内还有已删除文件'), findsOneWidget,
        reason: '409 detail 透传');
    expect(folders, 0, reason: '失败不失效');
  });

  testWidgets('删除成功失效 folders', (tester) async {
    final api = installFakeApi();
    api.folders.getResult = Folder(
        id: 'f1', name: '档案夹', parentFolderId: null, projectId: 'p1',
        isSensitive: false, myCanAdmin: true, myCanUpload: true);
    addTearDown(() => session.api = null);
    session.me = Me(id: 'u1', name: '甲');
    var folders = 0;
    void onFolders() => folders++;
    RefreshBus.I.addListener('folders', onFolders);
    addTearDown(() => RefreshBus.I.removeListener('folders', onFolders));

    await pumpMenu(
        tester,
        Folder(id: 'f1', name: '档案夹', parentFolderId: null));
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(folders, greaterThan(0));
  });
}
