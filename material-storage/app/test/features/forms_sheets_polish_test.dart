/// app-polish 验收用例(对应需求文档 2026-10-21-app-polish.md 包 D 各条):
/// - D2 新建项目表单:空名称提交→名称框 errorText(不再只弹 SnackBar);
///   有输入下滑关闭→确认弹层(new_project_sheet.dart);
/// - D4 请求链接:「复制链接」就地反馈,SnackBar 不再浮出(sheet 遮挡回归,
///   request_link_sheet.dart);
/// - D5 批量移动结果:跳过列表显示文件名而非 assetId(batch_move_sheet.dart)。
///
/// 套路:testWidgets + FakeMsApi 记录式假 API(test/helpers/api_harness.dart),
/// 不用真实 HTTP。凡依赖「尚未存在的行为」的断言均标注 TODO(app-polish Dx):
/// 现状应失败,交付后转绿。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/request_links_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/assets/batch_move_sheet.dart';
import 'package:ms_app/features/projects/new_project_sheet.dart';
import 'package:ms_app/features/share/request_link_sheet.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/widgets/sheet_scaffold.dart';

import '../helpers/api_harness.dart';

// ── D4:requestLinks 记录式假 API(同 request_link_sheet_test 套路)──────────
class _RequestLinkFakeApi extends FakeMsApi {
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
  // ── D2 新建项目表单 ─────────────────────────────────────────────────────
  testWidgets('D2:空名称提交→名称框 errorText 就地显示,不弹 SnackBar',
      (tester) async {
    final api = installFakeApi();
    addTearDown(() {
      session.api = null;
      session.me = null;
    });
    session.me = Me(id: 'me1', name: '甲', isProjectCreator: true);
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => showNewProjectSheet(ctx),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('创建'));
    await tester.pump();

    // TODO(app-polish D2): 现状应失败(只有 SnackBar「请输入项目名称」,
    // 字段无 errorText),交付后转绿
    final nameField = tester.widget<TextField>(
        find.widgetWithText(TextField, '项目名称'));
    expect(nameField.decoration?.errorText, isNotNull,
        reason: 'D2:空名称提交→名称框内联 errorText');
    expect(find.byType(SnackBar), findsNothing,
        reason: 'D2:不再只靠提交时 SnackBar 报第一条');
    expect(api.projectsOps.createCalls, isEmpty, reason: '前端校验拦下,不发请求');
    // 收尾:排空现状 SnackBar 计时器(交付后无 SnackBar 也无害)
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('D2:有输入时下滑关闭→弹未保存确认层,sheet 不直接丢弃',
      (tester) async {
    installFakeApi();
    addTearDown(() {
      session.api = null;
      session.me = null;
    });
    session.me = Me(id: 'me1', name: '甲', isProjectCreator: true);
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => showNewProjectSheet(ctx),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '项目名称'), '项目A');
    await tester.pump();

    // 从 sheet 顶部(拖拽把手区,滚动区之外)下滑关闭
    final topLeft = tester.getTopLeft(find.byType(BottomSheet));
    final size = tester.getSize(find.byType(BottomSheet));
    final g = await tester.startGesture(
        Offset(topLeft.dx + size.width / 2, topLeft.dy + 24));
    await g.moveBy(const Offset(0, 200));
    await g.moveBy(const Offset(0, 500));
    await g.up();
    await tester.pumpAndSettle();

    // TODO(app-polish D2): 现状应失败(直接关闭,无确认层),交付后转绿。
    // 确认层经 showAppConfirm(A5,包 A 先行)呈现,文案未定——按类型断言。
    expect(find.byType(AlertDialog), findsOneWidget,
        reason: 'D2:有未保存修改时下滑关闭弹确认层');
    expect(find.widgetWithText(TextField, '项目名称'), findsOneWidget,
        reason: 'D2:确认前 sheet 不关闭(表单仍在)');
  });

  // ── I3(app-polish-2 #5):新建项目弹层高度与取消可见性 ────────────────────
  testWidgets('I3:maxHeightFactor 0.85,长表单触顶封顶(弹层不再占满全屏)',
      (tester) async {
    installFakeApi();
    addTearDown(() {
      session.api = null;
      session.me = null;
    });
    session.me = Me(id: 'me1', name: '甲', isProjectCreator: true);
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => showNewProjectSheet(ctx),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 契约断言:传给 SheetScaffold 的 maxHeightFactor=0.85(原 0.9)
    final scaffold = tester.widget<SheetScaffold>(find.byType(SheetScaffold));
    expect(scaffold.maxHeightFactor, 0.85,
        reason: '#5 弹层太高难发现可取消 → 0.85');

    // 行为断言:弹层总高(自制把手 ~28 + 骨架 ≤0.85*屏高)不超过
    // 0.85*2000+把手余量;0.9 时代约 1828 会越界,此处可甄别回归
    final sheetHeight = tester.getSize(find.byType(BottomSheet)).height;
    expect(sheetHeight, lessThanOrEqualTo(2000 * 0.85 + 33),
        reason: '#5 弹层高度封顶在 0.85 屏 + 自制把手');
    expect(tester.getSize(find.byType(SheetScaffold)).height,
        lessThanOrEqualTo(2000 * 0.85),
        reason: '骨架本体不超 0.85 屏');
  });

  // ── D4 请求链接复制就地反馈 ─────────────────────────────────────────────
  testWidgets('D4:「复制链接」就地反馈,不再有 SnackBar 浮出(sheet 遮挡回归)',
      (tester) async {
    final api = _RequestLinkFakeApi();
    installFakeApi(api);
    addTearDown(() {
      session.api = null;
      session.me = null;
    });
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late BuildContext captured;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (ctx) {
          captured = ctx;
          return Center(
            child: FilledButton(
              onPressed: () => showRequestLinkSheet(captured,
                  targetType: 'folder', targetId: 'f1', targetLabel: '夹A'),
              child: const Text('open'),
            ),
          );
        }),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('生成并复制链接'));
    await tester.pumpAndSettle();
    expect(find.textContaining('链接已生成'), findsOneWidget,
        reason: '前置:创建成功进入结果视图');

    await tester.tap(find.text('复制链接'));
    await tester.pump();
    // TODO(app-polish D4): 现状应失败(「复制链接」弹 SnackBar「链接已复制」,
    // 被 sheet 遮挡不可见),交付后转绿(CopyButton 就地反馈)
    expect(find.byType(SnackBar), findsNothing,
        reason: 'D4:复制反馈不再以 SnackBar 浮出');
    expect(find.text('复制链接'), findsOneWidget,
        reason: 'D4:sheet 内结果视图仍在(就地反馈)');
    // 收尾:排空现状 SnackBar 计时器
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  // ── D5 批量移动结果含文件名 ─────────────────────────────────────────────
  testWidgets('D5:批量移动结果跳过列表显示文件名而非 assetId',
      (tester) async {
    final api = installFakeApi();
    addTearDown(() {
      session.api = null;
      session.me = null;
    });
    api.folders.listResult = [
      Folder(id: 'f1', name: '当前夹', parentFolderId: null, projectId: 'p1'),
      Folder(id: 'f2', name: '目标夹', parentFolderId: null, projectId: 'p1'),
    ];
    api.ops.moveStaged = AssetBatchMoveResult(movedCount: 1, skipped: [
      AssetBatchMoveSkip(assetId: 'a2', reason: 'duplicate_location'),
      AssetBatchMoveSkip(assetId: 'a3', reason: 'duplicate_filename'),
    ]);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => showBatchMoveSheet(ctx,
                  selectedIds: const ['a1', 'a2', 'a3'],
                  sourceFolderId: 'f1',
                  projectId: 'p1',
                  projectLabel: '医美项目',
                  // app-polish D5:文件名映射经可选入参传入(调用方持选中资产
                  // 对象,id→filename;未传兜底截断 id 并注明)
                  assetNames: const {'a1': 'a1.jpg', 'a2': 'a2.jpg', 'a3': 'a3.jpg'}),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('目标夹'));
    await tester.pump();
    await tester.tap(find.text('移动'));
    await tester.pumpAndSettle();
    // 测试报告 P1-D5:工程「对账:成功 1 + 跳过 2」行删除(信息已并入主行
    // 用户口径),前置断言改主行文案
    expect(find.textContaining('已移动 1 项,2 项跳过'), findsOneWidget,
        reason: '前置:结果视图呈现(主行用户口径)');

    // TODO(app-polish D5): 现状应失败(跳过行显示「· a2 — …」assetId),
    // 交付后转绿(行含文件名 a2.jpg;若交付经新增入参传文件名映射,
    // 调用侧按实际签名补参)
    expect(find.textContaining('a2.jpg'), findsOneWidget,
        reason: 'D5:跳过行显示文件名而非 assetId');
    expect(find.textContaining('a3.jpg'), findsOneWidget,
        reason: 'D5:跳过行显示文件名而非 assetId');
  });
}
