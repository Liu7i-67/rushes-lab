/// B9 测试功能点 4:请求链接——sheet 提交入参=CreateIn 实码(target_type/
/// target_id/allowed_actions/receiver_user_id/ttl_seconds)/创建即复制(成功
/// snackbar + landing_url 展示)/403 detail 透传 toast/**双入口闸门**(项目页
/// 行内入口=my_roles 含 admin;文件夹 ⋯ 菜单=单夹详情 my_can_admin,P2-4
/// qplan 定稿:有权限可见可点、无权限完全不渲染勿置灰)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/api/request_links_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/folders/folder_row.dart';
import 'package:ms_app/features/projects/projects_page.dart';
import 'package:ms_app/features/share/request_link_sheet.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

/// 记录式假 API:share 域已覆盖,补 requestLinks 域。
class _RequestLinkFakeApi extends FakeMsApi {
  _RequestLinkFakeApi();

  final createCalls = <Map<String, dynamic>>[];
  Object? createStaged;

  @override
  RequestLinksApi get requestLinks => _requestLinks;
  late final _requestLinks = _FakeRequestLinksApi(this);
}

class _FakeRequestLinksApi extends RequestLinksApi {
  _FakeRequestLinksApi(this._host) : super(_host);
  final _RequestLinkFakeApi _host;

  @override
  Future<RequestLinkCreated> create({
    required String targetType,
    required String targetId,
    required List<String> allowedActions,
    String? receiverUserId,
    int? ttlSeconds,
  }) async {
    _host.createCalls.add({
      'target_type': targetType,
      'target_id': targetId,
      'allowed_actions': allowedActions,
      'receiver_user_id': receiverUserId,
      'ttl_seconds': ttlSeconds,
    });
    final staged = _host.createStaged;
    if (staged is Exception) throw staged;
    return RequestLinkCreated(
      token: 'tok1',
      landingUrl: 'https://ms.test/r/tok1',
      expiresAt: '2026-10-23T10:00:00Z',
      allowedActions: allowedActions,
    );
  }
}

void main() {
  testWidgets('sheet:创建即复制(成功 toast + landing_url 展示);入参=实码',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = installFakeApi(_RequestLinkFakeApi());
    addTearDown(() => session.api = null);

    late BuildContext captured;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (ctx) {
          captured = ctx;
          return Center(
            child: FilledButton(
              onPressed: () => showRequestLinkSheet(captured,
                  targetType: 'folder',
                  targetId: 'f1',
                  targetLabel: '成片夹'),
              child: const Text('open'),
            ),
          );
        }),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 表单默认:download 已勾(非敏感夹无 access 项)、TTL 默认 3 天
    expect(find.text('访问(进入敏感目录)'), findsNothing);
    await tester.tap(find.text('生成并复制链接'));
    await tester.pumpAndSettle();

    final fake = api as _RequestLinkFakeApi;
    final body = fake.createCalls.single;
    expect(body['target_type'], 'folder');
    expect(body['target_id'], 'f1');
    expect(body['allowed_actions'], ['download']);
    expect(body['ttl_seconds'], 3 * 86400, reason: '默认 3 天(web 同款)');
    expect(body['receiver_user_id'], isNull);

    // 创建即复制:结果态文案承载确认(sheet 保持打开供浏览器打开落地页)
    expect(find.textContaining('已复制到剪贴板'), findsOneWidget);
    expect(find.text('https://ms.test/r/tok1'), findsOneWidget);
    expect(find.text('在浏览器打开落地页'), findsOneWidget);
  });

  testWidgets('sheet:敏感夹默认动作含 access;失败 403 detail 透传 toast',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = installFakeApi(_RequestLinkFakeApi());
    addTearDown(() => session.api = null);
    (api as _RequestLinkFakeApi).createStaged = ApiException(
        403, '无权对该资源生成申请链接 — 需要 system admin 或该资源 admin');

    late BuildContext captured;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (ctx) {
          captured = ctx;
          return Center(
            child: FilledButton(
              onPressed: () => showRequestLinkSheet(captured,
                  targetType: 'sensitive_folder',
                  targetId: 'fs1',
                  targetLabel: '敏感夹'),
              child: const Text('open'),
            ),
          );
        }),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('访问(进入敏感目录)'), findsOneWidget,
        reason: 'sensitive_folder 才有 access 项');
    await tester.tap(find.text('生成并复制链接'));
    await tester.pumpAndSettle();
    expect(find.textContaining('无权对该资源生成申请链接'), findsOneWidget,
        reason: '403 detail 透传(非 admin 兜底文案)');
    expect(find.text('https://ms.test/r/tok1'), findsNothing);
  });

  testWidgets('项目页入口闸门:my_roles 含 admin 才露出「请求链接」', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = installFakeApi(_RequestLinkFakeApi());
    addTearDown(() => session.api = null);
    api.projects.listStaged = [
      Project(id: 'p1', name: '管理项目', code: 'P1', myRoles: const ['admin']),
      Project(id: 'p2', name: '只读项目', code: 'P2', myRoles: const ['viewer']),
    ];

    await tester.pumpWidget(const MaterialApp(home: ProjectsPage()));
    await tester.pumpAndSettle();

    expect(find.byTooltip('请求链接'), findsOneWidget,
        reason: '仅 admin 项目露出;viewer 项目不露出');
  });

  testWidgets('文件夹 ⋯ 菜单(P2-4 定稿):folder admin 可见可点,发起进 request_link_sheet',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = installFakeApi(_RequestLinkFakeApi());
    addTearDown(() => session.api = null);
    api.folders.getResult = Folder(
        id: 'f1',
        name: '普通一级夹',
        parentFolderId: null,
        projectId: 'p1',
        isSensitive: false,
        myCanAdmin: true,
        myCanUpload: true,
        myDeleteGrant: false);
    session.me = Me(id: 'u1', name: '甲');
    addTearDown(() => session.me = null);

    late BuildContext captured;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (ctx) {
          captured = ctx;
          return Center(
            child: FilledButton(
              onPressed: () => showFolderMenu(captured,
                  folder: Folder(
                      id: 'f1', name: '普通一级夹', parentFolderId: null)),
              child: const Text('open'),
            ),
          );
        }),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // my_can_admin=true(单夹详情回填):tile 可见且可点(非置灰)
    final tile = tester.widget<ListTile>(find.ancestor(
        of: find.text('请求链接'), matching: find.byType(ListTile)));
    expect(tile.enabled, isTrue, reason: 'folder admin 可见可点');

    // 点击发起:菜单收起 → request_link_sheet 打开(target label 随行)
    await tester.tap(find.text('请求链接'));
    await tester.pumpAndSettle();
    expect(find.text('生成申请链接'), findsOneWidget);
    expect(find.text('普通一级夹'), findsOneWidget,
        reason: 'targetLabel=夹名带入发起面板');
    expect(find.text('生成并复制链接'), findsOneWidget);
    expect((api as _RequestLinkFakeApi).createCalls, isEmpty,
        reason: '仅打开发起面板,尚未提交创建');
  });

  testWidgets('文件夹 ⋯ 菜单:my_can_admin=false「请求链接」完全不渲染(P2-4)',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = installFakeApi(_RequestLinkFakeApi());
    addTearDown(() => session.api = null);
    api.folders.getResult = Folder(
        id: 'f2',
        name: '普通子夹',
        parentFolderId: 'f1',
        projectId: 'p1',
        isSensitive: false,
        myCanAdmin: false,
        myCanUpload: true,
        myDeleteGrant: false);
    session.me = Me(id: 'u1', name: '甲');
    addTearDown(() => session.me = null);

    late BuildContext captured;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (ctx) {
          captured = ctx;
          return Center(
            child: FilledButton(
              onPressed: () => showFolderMenu(captured,
                  folder: Folder(
                      id: 'f2', name: '普通子夹', parentFolderId: 'f1')),
              child: const Text('open'),
            ),
          );
        }),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 无权限=不渲染(勿置灰):无 tile、无 hint、无入口图标
    expect(find.text('请求链接'), findsNothing);
    expect(find.text('需文件夹管理权限'), findsNothing);
    expect(find.byIcon(Icons.link_outlined), findsNothing);
  });
}
