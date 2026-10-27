/// qdev 专职测试补查用例(qdev 2026-10-21 app-polish 全方位测试;探查性质,
/// 按需保留):E6 相对时间精确边界 / B1 全选口径+删除取消+禁用键说明 /
/// B3 连触去重+失败重试成功链 / E7 取消确认遮罩关闭不误取消 / C2 沉浸态
/// 横滑切张稳定 / D2 创建成功 sheet 关闭。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart' show ApiException;
import 'package:ms_app/core/fmt.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/core/transfers/transfer_queue.dart';
import 'package:ms_app/core/transfers/transfer_task.dart';
import 'package:ms_app/features/assets/assets_page.dart';
import 'package:ms_app/features/projects/new_project_sheet.dart';
import 'package:ms_app/features/preview/preview_media.dart';
import 'package:ms_app/features/preview/preview_page.dart';
import 'package:ms_app/features/transfers/transfers_page.dart';
import 'package:ms_app/models/models.dart';

import 'helpers/api_harness.dart';

/// 分页假 assets API:page2 支持 List / Exception / Completer(挂起编排)。
class _ProbePagedAssetsApi extends FakeAssetsApi {
  _ProbePagedAssetsApi(super.api);

  final listCalls = <({int limit, int offset})>[];
  List<Asset> page1 = const [];
  int total = 0;
  Object? page2; // List<Asset> | Exception | Completer<AssetPage>

  @override
  Future<AssetPage> list(
    String folderId, {
    int limit = 30,
    int offset = 0,
  }) async {
    listCalls.add((limit: limit, offset: offset));
    if (offset > 0) {
      final p = page2;
      if (p is Completer<AssetPage>) return p.future;
      if (p is Exception) throw p;
      return AssetPage(items: (p as List<Asset>?) ?? const [], total: total);
    }
    return AssetPage(items: page1, total: total);
  }
}

class _ProbePagedMsApi extends FakeMsApi {
  late final _paged = _ProbePagedAssetsApi(this);
  @override
  _ProbePagedAssetsApi get assets => _paged;
}

/// C2 用假预览 API:downloadLink 即回假 URL / thumbnailUrl 永挂起
/// (同 preview_polish_test 套路,避真 HTTP 在 FakeAsync 区抛 400)。
class _ProbePreviewAssetsApi extends FakeAssetsApi {
  _ProbePreviewAssetsApi(super.api);

  @override
  Future<String> downloadLink(
    String assetId, {
    bool asAttachment = true,
  }) async => 'http://presigned/$assetId';

  @override
  Future<({String url, int expiresIn})> thumbnailUrl(
    String assetId, {
    required String size,
  }) => Completer<({String url, int expiresIn})>().future;
}

class _ProbePreviewMsApi extends FakeMsApi {
  late final _pv = _ProbePreviewAssetsApi(this);
  @override
  _ProbePreviewAssetsApi get assets => _pv;
}

Future<void> _pumpAssets(
  WidgetTester tester,
  _ProbePagedMsApi api, {
  Size? size,
}) async {
  if (size != null) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }
  session.api = api;
  addTearDown(() {
    session.api = null;
    session.me = null;
  });
  await tester.pumpWidget(
    MaterialApp(
      home: AssetsPage(folderId: 'f1', folderName: '夹A'),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Asset _img(String id) => Asset(
  id: id,
  filename: '$id.jpg',
  sizeBytes: 4,
  contentType: 'image/jpeg',
  createdAt: '2026-10-20T10:00:00Z',
  tags: const {'thumbnail_key': 'k'},
);

Widget _sheetHost() => MaterialApp(
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
);

void main() {
  // ── E6:fmtRelativeTime 精确边界 ────────────────────────────────────────────
  group('E6 补查:fmtRelativeTime 精确边界', () {
    final now = DateTime(2026, 10, 21, 12, 0, 0);

    test('59 秒=刚刚;60 秒=1 分钟前', () {
      expect(
        fmtRelativeTime('2026-10-21T11:59:01', now: now),
        '刚刚',
        reason: '59s < 1min',
      );
      expect(
        fmtRelativeTime('2026-10-21T11:59:00', now: now),
        '1 分钟前',
        reason: '恰好 60s 落分钟档',
      );
    });

    test('23 小时(今日)=N 小时前;恰好 24 小时=昨天', () {
      expect(fmtRelativeTime('2026-10-21T00:00:00', now: now), '12 小时前');
      expect(
        fmtRelativeTime('2026-10-20T12:00:00', now: now),
        '昨天 12:00',
        reason: '恰 24h 且跨日 → 日历档优先',
      );
    });

    test('6/7 天=N 天前;8 天=MM-DD', () {
      expect(fmtRelativeTime('2026-10-15T12:00:00', now: now), '6 天前');
      expect(fmtRelativeTime('2026-10-14T12:00:00', now: now), '7 天前');
      expect(fmtRelativeTime('2026-10-13T12:00:00', now: now), '10-13');
    });

    test('未来 2 小时(时钟偏差)不崩溃(实际落「刚刚」档)', () {
      expect(fmtRelativeTime('2026-10-21T14:00:00', now: now), '刚刚');
    });

    test('非法串/空串原样返回', () {
      expect(fmtRelativeTime('not-a-date'), 'not-a-date');
      expect(fmtRelativeTime(''), '');
    });
  });

  // ── B1:全选口径(第二页未加载)───────────────────────────────────────────
  testWidgets('B1 补查:total>已加载时「全选」只勾满已加载,且不触发第二页请求', (tester) async {
    final api = _ProbePagedMsApi();
    api.assets.page1 = [for (var i = 1; i <= 30; i++) fakeAsset('a$i')];
    api.assets.total = 33;
    api.assets.page2 = <Asset>[]; // 若误触发第二页也不该发生
    await _pumpAssets(tester, api);
    expect(api.assets.listCalls.single.offset, 0, reason: '前置:只拉了第一页');

    await tester.longPress(find.text('a1.jpg'));
    await tester.pump();
    await tester.tap(find.text('全选'));
    await tester.pump();
    expect(
      find.textContaining('已选 30 项'),
      findsOneWidget,
      reason: 'B1:全选只勾满已加载 30 条(非 total 33)',
    );
    expect(find.text('取消全选'), findsOneWidget, reason: 'B1:勾满已加载后键切「取消全选」');
    expect(api.assets.listCalls.length, 1, reason: 'B1:全选不得偷跑第二页请求');

    // 再点「取消全选」→ 清空退出多选
    await tester.tap(find.text('取消全选'));
    await tester.pump();
    expect(find.textContaining('已选'), findsNothing);
  });

  // ── B1:删除确认取消路径 ─────────────────────────────────────────────────
  testWidgets('B1 补查:删除确认点取消 → 不发 DELETE、选中保留', (tester) async {
    final api = _ProbePagedMsApi();
    api.assets.page1 = [fakeAsset('a1'), fakeAsset('a2')];
    api.assets.total = 2;
    await _pumpAssets(tester, api);

    await tester.longPress(find.text('a1.jpg'));
    await tester.pump();
    await tester.tap(find.text('a2.jpg')); // 多选态点选累加
    await tester.pump();
    expect(find.textContaining('已选 2 项'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await tester.pump();
    expect(
      find.byType(AlertDialog),
      findsOneWidget,
      reason: '前置:删除弹 danger 确认',
    );
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pump();
    expect(api.assets.deleteCalls, isEmpty, reason: '取消 → 零 DELETE');
    expect(find.textContaining('已选 2 项'), findsOneWidget, reason: '取消 → 选中态保留');
    expect(find.byType(AlertDialog), findsNothing);
  });

  // ── B1:禁用键点按出原因说明(不依赖 Tooltip)───────────────────────────
  testWidgets('B1 补查:多选态点「分享」(禁用)→ toast 说明、不调分享 API', (tester) async {
    final api = _ProbePagedMsApi();
    api.assets.page1 = [fakeAsset('a1'), fakeAsset('a2')];
    api.assets.total = 2;
    await _pumpAssets(tester, api);

    await tester.longPress(find.text('a1.jpg'));
    await tester.pump();
    await tester.tap(find.text('a2.jpg'));
    await tester.pump();

    await tester.tap(find.text('分享')); // 禁用键:点按出原因 toast
    await tester.pump();
    expect(
      find.textContaining('分享仅单选可用'),
      findsOneWidget,
      reason: 'B1:禁用原因不依赖 Tooltip,点按出说明',
    );
    expect(api.share.calls, isEmpty, reason: '禁用键不触发 API');
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  // ── B3:连触去重(挂起响应期间反复滚动只发一次)──────────────────────────
  testWidgets('B3 补查:第二页在途时连触滚动 → 请求去重(只发一次)', (tester) async {
    final api = _ProbePagedMsApi();
    api.assets.page1 = [for (var i = 1; i <= 30; i++) fakeAsset('a$i')];
    api.assets.total = 60;
    final gate = Completer<AssetPage>();
    api.assets.page2 = gate;
    await _pumpAssets(tester, api);

    // 循环拖到第二页请求发出为止(阈值 extentAfter<200,单拖未必到底)
    for (var i = 0; i < 8 && api.assets.listCalls.length < 2; i++) {
      await tester.drag(find.byType(GridView), const Offset(0, -800));
      await tester.pump();
    }
    expect(api.assets.listCalls.length, 2, reason: '前置:到底发起第二页');

    // 在途(响应挂起)期间连续再滚 3 次 → 不得重复发请求
    for (var i = 0; i < 3; i++) {
      await tester.drag(find.byType(GridView), const Offset(0, -400));
      await tester.pump();
    }
    expect(
      api.assets.listCalls.length,
      2,
      reason: 'B3:_loadingMore 在途去重,连触只发一次',
    );

    gate.complete(
      AssetPage(
        items: [for (var i = 31; i <= 60; i++) fakeAsset('a$i')],
        total: 60,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('a31.jpg'), findsOneWidget, reason: '第二页头部内容拼接');
    expect(api.assets.listCalls.length, 2, reason: '全程仅两次请求');
  });

  // ── B3:失败 → 重试条 → 重试成功链路 ─────────────────────────────────────
  testWidgets('B3 补查:加载失败出底部重试条,点重试成功拼接第二页', (tester) async {
    final api = _ProbePagedMsApi();
    api.assets.page1 = [for (var i = 1; i <= 30; i++) fakeAsset('a$i')];
    api.assets.total = 33;
    final probe = api.assets;
    probe.page2 = ApiException(500, '网络开小差');
    await _pumpAssets(tester, api);

    for (var i = 0; i < 8 && probe.listCalls.length < 2; i++) {
      await tester.drag(find.byType(GridView), const Offset(0, -800));
      await tester.pumpAndSettle();
    }
    expect(find.text('加载失败,点击重试'), findsOneWidget, reason: 'B3:失败出底部重试条');
    expect(probe.listCalls.length, 2);

    // 第二次放行成功
    probe.page2 = [
      Asset(
        id: 'a31',
        filename: 'a31.jpg',
        sizeBytes: 1,
        contentType: 'image/jpeg',
        createdAt: '2026-10-20T10:00:00Z',
      ),
    ];
    probe.total = 33;
    await tester.tap(find.text('加载失败,点击重试'));
    await tester.pumpAndSettle();
    expect(find.text('a31.jpg'), findsOneWidget, reason: 'B3:重试成功拼接');
    expect(probe.listCalls.length, 3, reason: '失败一次+重试一次');
    expect(find.text('加载失败,点击重试'), findsNothing);
    // 排空失败 toast 计时器
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  // ── E7:取消确认遮罩关闭(=null)不误取消任务 ────────────────────────────
  testWidgets('E7 补查:取消确认弹层点遮罩关闭 → 任务继续运行不取消', (tester) async {
    final q = TransferQueue();
    final gate = Completer<void>();
    // enqueue 返回 String(id) 非 Future,不 await
    q.enqueue(
      TransferRequest(
        kind: TransferKind.download,
        filename: 'r1.livp',
        where: '项目A/夹B',
        totalBytes: 100,
        worker: (p, token) async {
          p(30);
          await gate.future;
        },
      ),
    );
    await tester.pump();
    await tester.pumpWidget(MaterialApp(home: TransfersPage(queue: q)));
    await tester.pump();

    await tester.tap(find.byTooltip('取消').first);
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget, reason: '前置:确认层');

    await tester.tapAt(const Offset(20, 20)); // 点遮罩(=null 路径)
    await tester.pump();
    expect(find.byType(AlertDialog), findsNothing, reason: '遮罩关闭弹层');
    expect(q.runningCount, 1, reason: 'E7:遮罩关闭(=null)不取消任务');
    expect(q.tasks.any((t) => t.status == TransferStatus.canceled), isFalse);

    gate.complete();
    await tester.pump();
  });

  // ── C2:沉浸态横滑切张稳定性 ─────────────────────────────────────────────
  testWidgets('C2 补查:沉浸态横滑切张 → 计数推进无异常;退出沉浸恢复', (tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    session.api = _ProbePreviewMsApi();
    addTearDown(() => session.api = null);
    await tester.pumpWidget(
      MaterialApp(
        home: PreviewPage(
          args: PreviewArgs(
            items: [_img('p1'), _img('p2'), _img('p3')],
            index: 0,
            folderId: 'f1',
            canDownload: true,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byType(PreviewMedia)); // 进沉浸
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PreviewMedia), findsOneWidget, reason: '沉浸态媒体仍在');
    expect(tester.takeException(), isNull);

    await tester.fling(find.byType(PreviewMedia), const Offset(-300, 0), 1200);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull, reason: 'C2:沉浸态横滑无异常/NaN');

    await tester.tap(find.byType(PreviewMedia)); // 退沉浸
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('2 / 3'), findsOneWidget, reason: 'C2:沉浸态切张生效且计数正确');
  });

  // ── D2:创建成功 → sheet 关闭 ────────────────────────────────────────────
  testWidgets('D2 补查:合法提交创建成功 → sheet 关闭回宿主页', (tester) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    installFakeApi();
    addTearDown(() {
      session.api = null;
      session.me = null;
    });
    session.me = Me(id: 'me1', name: '甲', isProjectCreator: true);

    await tester.pumpWidget(_sheetHost());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '项目名称'), '项目A');
    await tester.pump();
    await tester.enterText(
      find.widgetWithText(TextField, '项目编码(小写字母/数字/-)'),
      'demo-2026',
    );
    await tester.pump();
    await tester.tap(find.text('创建项目'));
    await tester.pumpAndSettle();
    expect(find.text('创建项目'), findsNothing, reason: 'D2:创建成功 sheet 关闭');
    expect(find.text('open'), findsOneWidget, reason: '回到宿主页');
  });
}
