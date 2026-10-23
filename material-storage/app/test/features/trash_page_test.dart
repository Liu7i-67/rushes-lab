/// 回收站页单测(B5 测试功能点 6):canSeeTrash 入口三态纯函数(web 实码同式:
/// 普通夹=my_can_admin 或 my_delete_grant;sensitive 仅系统 admin);列表渲染
/// (deleted_at/大小)+恢复调用+行移除+失效两 scope;文件夹 ⋯ 菜单入口闸门
/// (普通夹 admin 可进/敏感夹非系统 admin 禁用文案/系统 admin 可进)。
/// app-polish E10 交付批:行首图标按 kind 分型(纯函数);「加载更多」按钮改
/// 滚到底自动加载(交互变化:原按钮格无既有用例,新增自动加载用例)。
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
import 'package:ms_app/widgets/app_row.dart';

import '../helpers/api_harness.dart';

/// E10 分页假 API:按 offset 编排两页(首页/第二页,total 独立)。
class _PagedOpsApi extends FakeOpsApi {
  _PagedOpsApi(super.api);

  List<Asset> page1 = const [];
  List<Asset> page2 = const [];
  int total = 0;

  @override
  Future<asset_models.TrashPage> listTrash(
    String folderId, {
    int limit = 500,
    int offset = 0,
  }) async {
    trashCalls.add((folderId: folderId, limit: limit, offset: offset));
    // 页面组件(features TrashPage)与数据类同名:此处构造数据类,用别名
    return asset_models.TrashPage(
      items: offset > 0 ? page2 : page1,
      total: total,
    );
  }
}

class _PagedMsApi extends FakeMsApi {
  late final _paged = _PagedOpsApi(this);

  @override
  _PagedOpsApi get ops => _paged;
}

Asset _trashed(String id) => Asset(
  id: id,
  filename: '$id.jpg',
  sizeBytes: 1,
  contentType: 'image/jpeg',
  createdAt: '2026-10-20T10:00:00Z',
  folderId: 'f1',
  deletedAt: '2026-10-21T09:30:00Z',
);

void main() {
  test('canSeeTrash 三态:普通夹 admin∨删除授权;sensitive 仅系统 admin', () {
    // 普通夹:my_can_admin → 可见
    expect(
      canSeeTrash(
        myCanAdmin: true,
        myDeleteGrant: null,
        isSensitive: false,
        isSystemAdmin: false,
      ),
      isTrue,
    );
    // 普通夹:仅 my_delete_grant(组级删除授权)→ 可见(F5 口径)
    expect(
      canSeeTrash(
        myCanAdmin: false,
        myDeleteGrant: true,
        isSensitive: false,
        isSystemAdmin: false,
      ),
      isTrue,
    );
    // 普通夹:两皆无 → 不可见
    expect(
      canSeeTrash(
        myCanAdmin: false,
        myDeleteGrant: false,
        isSensitive: false,
        isSystemAdmin: false,
      ),
      isFalse,
    );
    // 敏感夹:项目 admin(my_can_admin)也不可见(侧信道收口)
    expect(
      canSeeTrash(
        myCanAdmin: true,
        myDeleteGrant: false,
        isSensitive: true,
        isSystemAdmin: false,
      ),
      isFalse,
    );
    // 敏感夹:系统 admin → 可见
    expect(
      canSeeTrash(
        myCanAdmin: true,
        myDeleteGrant: false,
        isSensitive: true,
        isSystemAdmin: true,
      ),
      isTrue,
    );
    // 详情未到(null)→ 视为不可见
    expect(
      canSeeTrash(
        myCanAdmin: null,
        myDeleteGrant: null,
        isSensitive: false,
        isSystemAdmin: false,
      ),
      isFalse,
    );
  });

  testWidgets('列表渲染+恢复:调 restore、行移除、失效 assets/folders', (tester) async {
    final api = installFakeApi();
    api.ops.trashStaged = asset_models.TrashPage(
      items: [
        Asset(
          id: 'a1',
          filename: '旧图.jpg',
          sizeBytes: 2048,
          contentType: 'image/jpeg',
          createdAt: '2026-10-20T10:00:00Z',
          folderId: 'f1',
          deletedAt: '2026-10-21T09:30:00Z',
        ),
      ],
      total: 1,
    );
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

    await tester.pumpWidget(
      MaterialApp(
        home: TrashPage(folderId: 'f1', folderName: '档案夹'),
      ),
    );
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

  testWidgets('文件夹 ⋯ 菜单入口:普通夹 admin 可进回收站页;400/403 无权禁用', (tester) async {
    // 菜单 6 项在默认 600px 测试面落入滚动区,加大面免 scrollUntilVisible
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = installFakeApi();
    // 普通夹详情:my_can_admin=true → 闸门放行
    api.folders.getResult = Folder(
      id: 'f1',
      name: '档案夹',
      parentFolderId: null,
      projectId: 'p1',
      isSensitive: false,
      myCanAdmin: true,
      myDeleteGrant: false,
    );
    addTearDown(() => session.api = null);
    session.me = Me(id: 'u1', name: '甲', isSystemAdmin: false);

    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        routes: {'/trash': (_) => TrashPage(folderId: 'f1', folderName: '档案夹')},
        home: Scaffold(
          body: Builder(
            builder: (ctx) {
              captured = ctx;
              return Center(
                child: FilledButton(
                  onPressed: () => showFolderMenu(
                    captured,
                    folder: Folder(id: 'f1', name: '档案夹', parentFolderId: null),
                  ),
                  child: const Text('open'),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<AppRow>(
            find.ancestor(of: find.text('回收站'), matching: find.byType(AppRow)),
          )
          .onTap,
      isNotNull,
      reason: '普通夹 my_can_admin → 回收站可点',
    );
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
      id: 'f2',
      name: '敏感夹',
      parentFolderId: null,
      projectId: 'p1',
      isSensitive: true,
      myCanAdmin: true,
      myDeleteGrant: false,
    );
    addTearDown(() => session.api = null);

    Future<void> pumpMenu() async {
      late BuildContext captured;
      // UniqueKey 强制重建(否则同型 MaterialApp 复用元素树,上一个菜单路由残留)
      await tester.pumpWidget(
        MaterialApp(
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
                    onPressed: () => showFolderMenu(
                      captured,
                      folder: Folder(
                        id: 'f2',
                        name: '敏感夹',
                        parentFolderId: null,
                        isSensitive: true,
                      ),
                    ),
                    child: const Text('open'),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    // 非 admin:禁用 + 文案
    session.me = Me(id: 'u1', name: '甲', isSystemAdmin: false);
    await pumpMenu();
    expect(
      tester
          .widget<AppRow>(
            find.ancestor(of: find.text('回收站'), matching: find.byType(AppRow)),
          )
          .onTap,
      isNull,
      reason: 'sensitive 夹仅系统 admin',
    );
    expect(find.text('仅系统管理员可查看'), findsOneWidget);

    // 系统 admin → 可进
    session.me = Me(id: 'u0', name: '管', isSystemAdmin: true);
    await pumpMenu();
    expect(
      tester
          .widget<AppRow>(
            find.ancestor(of: find.text('回收站'), matching: find.byType(AppRow)),
          )
          .onTap,
      isNotNull,
    );
    await tester.tap(find.text('回收站'));
    await tester.pumpAndSettle();
    expect(find.text('回收站 · 敏感夹'), findsOneWidget);
  });

  // ── E10(app-polish 交付批)────────────────────────────────────────────────
  test('E10:回收站行首图标按 kind 分型(原一律 description_outlined)', () {
    expect(
      trashKindIcon(filename: 'a.jpg', contentType: 'image/jpeg'),
      Icons.image_outlined,
      reason: 'image → image',
    );
    expect(
      trashKindIcon(filename: 'a.heic', contentType: 'image/heic'),
      Icons.image_outlined,
      reason: 'heic 归 image 分型',
    );
    expect(
      trashKindIcon(filename: 'b.mov', contentType: 'video/quicktime'),
      Icons.videocam_outlined,
      reason: 'video → videocam',
    );
    expect(
      trashKindIcon(filename: 'c.livp', contentType: 'application/zip'),
      Icons.photo_camera_outlined,
      reason: 'livp → 实况(相机)意象',
    );
    expect(
      trashKindIcon(filename: 'd.mp3'),
      Icons.graphic_eq,
      reason: '音频 → graphic_eq(扩展名补判)',
    );
    expect(
      trashKindIcon(filename: 'e.m4a', contentType: 'audio/x-m4a'),
      Icons.graphic_eq,
      reason: '音频 → graphic_eq(content_type 补判)',
    );
    expect(
      trashKindIcon(filename: 'f.pdf', contentType: 'application/pdf'),
      Icons.description_outlined,
      reason: 'pdf → doc 分型',
    );
    expect(
      trashKindIcon(filename: 'g.md', contentType: 'text/markdown'),
      Icons.description_outlined,
      reason: 'markdown → doc 分型',
    );
    expect(
      trashKindIcon(filename: 'h.bin'),
      Icons.insert_drive_file_outlined,
      reason: '未识别 → 通用文件',
    );
  });

  testWidgets('E10:滚动到底自动加载第二页(offset=首页条数),无需点按', (tester) async {
    final api = installFakeApi(_PagedMsApi()) as _PagedMsApi;
    api.ops.page1 = [for (var i = 1; i <= 30; i++) _trashed('a$i')];
    api.ops.total = 33;
    api.ops.page2 = [_trashed('a31'), _trashed('a32'), _trashed('a33')];
    addTearDown(() => session.api = null);

    await tester.pumpWidget(
      MaterialApp(
        home: TrashPage(folderId: 'f1', folderName: '档案夹'),
      ),
    );
    await tester.pumpAndSettle();
    expect(api.ops.trashCalls.single.offset, 0, reason: '首轮只拉第一页');

    // 只滚动,不点任何按钮——E10 验收点:到底即自动加载(原「加载更多」
    // 按钮格移除,交互变化;该格无既有用例,本用例即其替代)
    for (var i = 0; i < 6; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -800));
      await tester.pumpAndSettle();
    }
    expect(api.ops.trashCalls.length, 2, reason: 'E10:滚动到底自动发起第二页请求');
    expect(api.ops.trashCalls.last.offset, 30, reason: 'E10:offset=首页条数');
    expect(find.text('a31.jpg'), findsOneWidget, reason: 'E10:第二页内容拼接渲染');
    expect(
      find.textContaining('加载更多'),
      findsNothing,
      reason: 'E10:「加载更多」格子移除,改底部线性加载指示',
    );
  });
}
