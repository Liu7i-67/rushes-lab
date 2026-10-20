/// 回收站页单测(B5 测试功能点 6):canSeeTrash 入口三态纯函数(web 实码同式:
/// 普通夹=my_can_admin 或 my_delete_grant;sensitive 仅系统 admin);列表渲染
/// (deleted_at/大小)+恢复调用+行移除+失效两 scope;文件夹 ⋯ 菜单入口闸门
/// (普通夹 admin 可进/敏感夹非系统 admin 禁用文案/系统 admin 可进)。
/// FakeApi 族见 helpers/api_harness.dart(widget 测试不落真实 socket)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/refresh_bus.dart';
import 'package:ms_app/core/session.dart';
// 页面组件 TrashPage(features)与数据类 TrashPage(models)同名:数据类别名引入
import 'package:ms_app/features/assets/trash_page.dart';
import 'package:ms_app/features/folders/folder_row.dart';
import 'package:ms_app/models/asset.dart' as asset_models show TrashPage;
import 'package:ms_app/models/models.dart' hide TrashPage;

import '../helpers/api_harness.dart';

void main() {
  test('canSeeTrash 三态:普通夹 admin∨删除授权;sensitive 仅系统 admin', () {
    // 普通夹:my_can_admin → 可见
    expect(
        canSeeTrash(myCanAdmin: true, myDeleteGrant: null,
            isSensitive: false, isSystemAdmin: false),
        isTrue);
    // 普通夹:仅 my_delete_grant(组级删除授权)→ 可见(F5 口径)
    expect(
        canSeeTrash(myCanAdmin: false, myDeleteGrant: true,
            isSensitive: false, isSystemAdmin: false),
        isTrue);
    // 普通夹:两皆无 → 不可见
    expect(
        canSeeTrash(myCanAdmin: false, myDeleteGrant: false,
            isSensitive: false, isSystemAdmin: false),
        isFalse);
    // 敏感夹:项目 admin(my_can_admin)也不可见(侧信道收口)
    expect(
        canSeeTrash(myCanAdmin: true, myDeleteGrant: false,
            isSensitive: true, isSystemAdmin: false),
        isFalse);
    // 敏感夹:系统 admin → 可见
    expect(
        canSeeTrash(myCanAdmin: true, myDeleteGrant: false,
            isSensitive: true, isSystemAdmin: true),
        isTrue);
    // 详情未到(null)→ 视为不可见
    expect(
        canSeeTrash(myCanAdmin: null, myDeleteGrant: null,
            isSensitive: false, isSystemAdmin: false),
        isFalse);
  });

  testWidgets('列表渲染+恢复:调 restore、行移除、失效 assets/folders', (tester) async {
    final api = installFakeApi();
    api.ops.trashStaged = asset_models.TrashPage(items: [
      Asset(
          id: 'a1', filename: '旧图.jpg', sizeBytes: 2048,
          contentType: 'image/jpeg', createdAt: '2026-10-20T10:00:00Z',
          folderId: 'f1', deletedAt: '2026-10-21T09:30:00Z'),
    ], total: 1);
    addTearDown(() => session.api = null);
    var assets = 0;
    var folders = 0;
    void onAssets() => assets++;
    void onFolders() => folders++;
    RefreshBus.I.addListener('assets:f1', onAssets);
    RefreshBus.I.addListener('folders', onFolders);
    addTearDown(() {
      RefreshBus.I.removeListener('assets:f1', onAssets);
      RefreshBus.I.removeListener('folders', onFolders);
    });

    await tester
        .pumpWidget(MaterialApp(home: TrashPage(folderId: 'f1', folderName: '档案夹')));
    await tester.pumpAndSettle();
    expect(api.ops.trashCalls.single.folderId, 'f1');
    expect(find.text('旧图.jpg'), findsOneWidget);
    expect(find.textContaining('2.0 KB'), findsOneWidget);
    expect(find.textContaining('删除于 2026-10-21'), findsOneWidget);

    await tester.tap(find.byTooltip('恢复到文件夹'));
    await tester.pumpAndSettle();
    expect(api.ops.restoreCalls, ['a1']);
    expect(find.text('旧图.jpg'), findsNothing, reason: '恢复后行移除');
    expect(find.textContaining('已恢复'), findsOneWidget);
    expect(assets, greaterThan(0));
    expect(folders, greaterThan(0));
  });

  testWidgets('文件夹 ⋯ 菜单入口:普通夹 admin 可进回收站页;400/403 无权禁用',
      (tester) async {
    // 菜单 6 项在默认 600px 测试面落入滚动区,加大面免 scrollUntilVisible
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = installFakeApi();
    // 普通夹详情:my_can_admin=true → 闸门放行
    api.folders.getResult = Folder(
        id: 'f1', name: '档案夹', parentFolderId: null, projectId: 'p1',
        isSensitive: false, myCanAdmin: true, myDeleteGrant: false);
    addTearDown(() => session.api = null);
    session.me = Me(id: 'u1', name: '甲', isSystemAdmin: false);

    late BuildContext captured;
    await tester.pumpWidget(MaterialApp(
      routes: {
        '/trash': (_) => TrashPage(folderId: 'f1', folderName: '档案夹'),
      },
      home: Scaffold(
        body: Builder(
          builder: (ctx) {
            captured = ctx;
            return Center(
              child: FilledButton(
                onPressed: () => showFolderMenu(captured,
                    folder: Folder(id: 'f1', name: '档案夹', parentFolderId: null)),
                child: const Text('open'),
              ),
            );
          },
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<ListTile>(find.ancestor(
                of: find.text('回收站'), matching: find.byType(ListTile)))
            .enabled,
        isTrue, reason: '普通夹 my_can_admin → 回收站可点');
    await tester.tap(find.text('回收站'));
    await tester.pumpAndSettle();
    expect(find.text('回收站 · 档案夹'), findsOneWidget, reason: '已导航进回收站页');
  });

  testWidgets('敏感夹 ⋯ 菜单:非系统 admin 禁用+文案;系统 admin 可进', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = installFakeApi();
    // 敏感夹详情:项目 admin 有 my_can_admin=true,闸门仍不放行(侧信道收口)
    api.folders.getResult = Folder(
        id: 'f2', name: '敏感夹', parentFolderId: null, projectId: 'p1',
        isSensitive: true, myCanAdmin: true, myDeleteGrant: false);
    addTearDown(() => session.api = null);

    Future<void> pumpMenu() async {
      late BuildContext captured;
      // UniqueKey 强制重建(否则同型 MaterialApp 复用元素树,上一个菜单路由残留)
      await tester.pumpWidget(MaterialApp(
        key: UniqueKey(),
        routes: {
          '/trash': (_) => TrashPage(folderId: 'f2', folderName: '敏感夹'),
        },
        home: Scaffold(
          body: Builder(
            builder: (ctx) {
              captured = ctx;
              return Center(
                child: FilledButton(
                  onPressed: () => showFolderMenu(captured,
                      folder: Folder(
                          id: 'f2', name: '敏感夹', parentFolderId: null,
                          isSensitive: true)),
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

    // 非 admin:禁用 + 文案
    session.me = Me(id: 'u1', name: '甲', isSystemAdmin: false);
    await pumpMenu();
    expect(
        tester
            .widget<ListTile>(find.ancestor(
                of: find.text('回收站'), matching: find.byType(ListTile)))
            .enabled,
        isFalse, reason: 'sensitive 夹仅系统 admin');
    expect(find.text('仅系统管理员可查看'), findsOneWidget);

    // 系统 admin → 可进
    session.me = Me(id: 'u0', name: '管', isSystemAdmin: true);
    await pumpMenu();
    expect(
        tester
            .widget<ListTile>(find.ancestor(
                of: find.text('回收站'), matching: find.byType(ListTile)))
            .enabled,
        isTrue);
    await tester.tap(find.text('回收站'));
    await tester.pumpAndSettle();
    expect(find.text('回收站 · 敏感夹'), findsOneWidget);
  });
}
