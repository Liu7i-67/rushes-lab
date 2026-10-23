/// AssetSelectionBar 单测(B5 功能点 1:操作栏全量点亮;下载 B4 编排保留):
/// 四键回调点亮/多选置灰(分享·申请权限仅恰好单选)/⋯ 菜单三项;
/// deleteSelectedAssets 编排:确认弹窗、逐条 DELETE、403 detail 透传、失效。
/// 入队经注入 TransferQueue/DownloadIo,PC 零通道。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/refresh_bus.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/core/transfers/transfer_queue.dart';
import 'package:ms_app/features/assets/asset_selection_bar.dart';
import 'package:ms_app/features/assets/asset_tile.dart';
import 'package:ms_app/features/assets/assets_page.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/widgets/asset_plate.dart';
import 'package:ms_app/services/downloads.dart';
import 'package:ms_app/services/media_save.dart';

import '../helpers/api_harness.dart';

Asset _asset(String name) => Asset(
  id: 'a-$name',
  filename: name,
  sizeBytes: 10,
  contentType: 'application/zip',
  createdAt: '2026-10-20T10:00:00Z',
);

Asset _dated(String id, String day) => Asset(
  id: id,
  filename: '$id.jpg',
  sizeBytes: 1,
  contentType: 'image/jpeg',
  createdAt: '2026-10-${day}T10:00:00Z',
);

Asset _typed(String id, String contentType) => Asset(
  id: id,
  filename: id,
  sizeBytes: 1,
  contentType: contentType,
  createdAt: '2026-10-20T10:00:00Z',
);

/// 宫格页假列表 API(排序/角标/打样卡用例)。
class _ListAssetsApi extends FakeAssetsApi {
  _ListAssetsApi(super.api);

  List<Asset> items = const [];

  @override
  Future<AssetPage> list(
    String folderId, {
    int limit = 30,
    int offset = 0,
  }) async => AssetPage(items: items, total: items.length);
}

class _ListMsApi extends FakeMsApi {
  late final _list = _ListAssetsApi(this);

  @override
  _ListAssetsApi get assets => _list;
}

Future<void> _pumpAssets(
  WidgetTester tester,
  List<Asset> items, {
  Size size = const Size(800, 1600),
}) async {
  final api = installFakeApi(_ListMsApi()) as _ListMsApi;
  api.assets.items = items;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.reset();
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

List<String> _gridOrder(WidgetTester tester) => tester
    .widgetList<AssetGridTile>(find.byType(AssetGridTile))
    .map((t) => t.asset.id)
    .toList();

DownloadIo _io() => DownloadIo(
  link: (a) async => 'http://presigned/${a.filename}',
  fetch:
      ({
        required url,
        required savePath,
        required totalBytes,
        required onProgress,
        required token,
      }) async {
        final f = File(savePath);
        await f.writeAsBytes(const [1]);
        onProgress(totalBytes);
        return f;
      },
  freeBytes: (_) async => 1 << 40,
  tempRoot: () => Directory.systemTemp.createTemp('sel_bar_test'),
  savers: PlatformSavers(
    gallery: (f, a) async => const SinkOutcome.ok('相册'),
    downloads: (f) async => const SinkOutcome.ok('Downloads'),
    share: (f) async => const SinkOutcome.ok('share'),
  ),
  toast: (_) {},
);

Future<void> pumpBar(
  WidgetTester tester, {
  required bool? canDownload,
  required VoidCallback onDownload,
  int count = 2,
  VoidCallback? onShare,
  VoidCallback? onMove,
  VoidCallback? onDelete,
  VoidCallback? onBatchTag,
  VoidCallback? onBatchPrefix,
  VoidCallback? onRequest,
  VoidCallback? onClear,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: const SizedBox.shrink(),
        bottomNavigationBar: AssetSelectionBar(
          count: count,
          canDownload: canDownload,
          onDownload: onDownload,
          onShare: onShare,
          onMove: onMove,
          onDelete: onDelete,
          onBatchTag: onBatchTag,
          onBatchPrefix: onBatchPrefix,
          onRequest: onRequest,
          onClear: onClear ?? () {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('P2-1:320 宽 + 1.3 字号六键标签两行完整(取消全选不省略)', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: Scaffold(
              body: const SizedBox.shrink(),
              bottomNavigationBar: AssetSelectionBar(
                count: 2,
                canDownload: true,
                allSelected: true,
                onToggleAll: () {},
                onDownload: () {},
                onShare: () {},
                onMove: () {},
                onDelete: () {},
                onClear: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull, reason: '320/1.3 无溢出异常');
    for (final label in ['取消全选', '下载', '分享', '移动', '删除']) {
      expect(find.text(label), findsOneWidget);
    }
    final paragraph = tester.renderObject<RenderParagraph>(find.text('取消全选'));
    expect(
      paragraph.didExceedMaxLines,
      isFalse,
      reason: '「取消全选」两行内完整渲染,不出现省略号',
    );
    // 最小触控高 48 保持(标签换行只增高,不压缩点击区)。
    final keyBox = tester.getSize(
      find
          .ancestor(of: find.text('取消全选'), matching: find.byType(InkWell))
          .first,
    );
    expect(keyBox.height, greaterThanOrEqualTo(48));
    expect(find.byTooltip('退出多选'), findsOneWidget);
  });

  testWidgets('操作栏全量(B5):四键点亮回调 + ⋯ 菜单三项(打标/前缀/申请)', (tester) async {
    var fired = '';
    await pumpBar(
      tester,
      canDownload: true,
      count: 1,
      onDownload: () => fired = 'download',
      onShare: () => fired = 'share',
      onMove: () => fired = 'move',
      onDelete: () => fired = 'delete',
      onBatchTag: () => fired = 'tag',
      onBatchPrefix: () => fired = 'prefix',
      onRequest: () => fired = 'request',
    );
    expect(find.text('已选 1 项'), findsOneWidget);
    await tester.tap(find.byTooltip('批量下载'));
    expect(fired, 'download');
    await tester.tap(find.byTooltip('分享链接(需登录访问)'));
    expect(fired, 'share');
    await tester.tap(find.byTooltip('移动到其他目录'));
    expect(fired, 'move');
    await tester.tap(find.byTooltip('移入回收站'));
    expect(fired, 'delete');
    // ⋯ 溢出菜单
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('批量打标'));
    await tester.pumpAndSettle();
    expect(fired, 'tag');
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('批量前缀'));
    await tester.pumpAndSettle();
    expect(fired, 'prefix');
  });

  testWidgets('多选置灰:分享/申请权限仅恰好单选可用(B5 钉子);⋯ 菜单申请项禁用', (tester) async {
    var shareFired = 0;
    var requestFired = 0;
    await pumpBar(
      tester,
      canDownload: true,
      count: 2,
      onDownload: () {},
      onShare: () => shareFired++,
      onRequest: () => requestFired++,
    );
    // B1 改因:禁用键不再挂 Tooltip(原「仅单选可用」tooltip 移除),点禁用键
    // 改为 toast 说明原因、回调不触发
    await tester.tap(find.text('分享'), warnIfMissed: false);
    await tester.pump();
    expect(shareFired, 0, reason: '多选分享置灰');
    expect(
      find.textContaining('仅单选可用'),
      findsOneWidget,
      reason: 'B1:点禁用键 toast 说明原因',
    );
    await tester.pump(const Duration(seconds: 5)); // toast 自动收起,不干扰后续断言
    await tester.pumpAndSettle(); // ⋯ 菜单:申请权限带「仅单选可用」副标题且禁用
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('仅单选可用'), findsOneWidget);
    await tester.tap(find.text('申请权限'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(requestFired, 0);
    // 禁用项点选不关闭弹出菜单 → 点空白处先收起,避免遮住后续操作键
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    // 恰好单选时可用(点 label 文本直击 InkWell,绕开 Tooltip 命中怪癖)
    await pumpBar(
      tester,
      canDownload: true,
      count: 1,
      onDownload: () {},
      onShare: () => shareFired++,
      onRequest: () => requestFired++,
    );
    await tester.pump();
    await tester.tap(find.text('分享'));
    await tester.pump();
    expect(shareFired, 1);
    expect(find.byTooltip('仅单选可用'), findsNothing, reason: '单选不再置灰');
  });

  testWidgets('canDownload=false:下载键禁用 + 点按 toast 提示'
      '(B1 改因:禁用原因不再依赖 Tooltip,三态口径同预览页)', (tester) async {
    var fired = 0;
    await pumpBar(tester, canDownload: false, onDownload: () => fired++);
    // B1:禁用键无 Tooltip(原「无下载权限 · 可先在预览页申请」tooltip 移除)
    expect(find.byTooltip('无下载权限 · 可先在预览页申请'), findsNothing);
    // 点禁用键 → toast 说明原因,回调不触发
    await tester.tap(find.text('下载'), warnIfMissed: false);
    await tester.pump(); // toast 进场帧
    expect(fired, 0, reason: '无下载权限:不入队');
    expect(
      find.textContaining('无下载权限'),
      findsOneWidget,
      reason: 'B1:点禁用键 toast 说明原因',
    );
    await tester.pump(const Duration(seconds: 5)); // 排空 toast 计时器
    await tester.pumpAndSettle();
  });

  testWidgets('downloadSelectedAssets:canDownload=false → 提示并不入队', (
    tester,
  ) async {
    final q = TransferQueue();
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) {
              captured = ctx;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    final r = await downloadSelectedAssets(
      captured,
      assets: [_asset('a.jpg')],
      canDownload: false,
      where: 'w',
      queue: q,
      io: _io(),
    );
    expect(r, isNull);
    expect(q.tasks, isEmpty);
    await tester.pump(); // SnackBar 进场帧
    expect(find.textContaining('无下载权限'), findsOneWidget);
  });

  testWidgets('downloadSelectedAssets:≤20 直接逐文件入队,汇总 toast 报数', (tester) async {
    final q = TransferQueue();
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) {
              captured = ctx;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    final r = await downloadSelectedAssets(
      captured,
      assets: [_asset('a.jpg'), _asset('b.jpg')],
      canDownload: true,
      where: '项目/夹',
      queue: q,
      io: _io(),
    );
    expect(r, (2, 0));
    expect(q.tasks.length, 2, reason: '逐文件入队');
    await tester.pump(); // SnackBar 进场帧
    expect(find.text('已加入下载队列 2 个'), findsOneWidget);
    // 不在 testWidgets(FakeAsync)里等队列跑完:worker 走真实文件 IO,
    // FakeAsync 不推进;入队计数与 toast 已断言,编排细节见 downloads_test
  });

  testWidgets('downloadSelectedAssets:>20 弹确认;取消 → 不入队;继续 → 全量入队', (
    tester,
  ) async {
    final q = TransferQueue();
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) {
              captured = ctx;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    final assets = [for (var i = 0; i < 21; i++) _asset('f$i.jpg')];

    // 取消路径:弹窗出现且不入队
    final canceled = downloadSelectedAssets(
      captured,
      assets: assets,
      canDownload: true,
      where: 'w',
      queue: q,
      io: _io(),
    );
    await tester.pump(); // dialog 进场
    expect(find.text('批量下载确认'), findsOneWidget);
    expect(find.textContaining('即将下载 21 个文件'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(await canceled, isNull, reason: '用户取消确认 → null');
    expect(q.tasks, isEmpty);

    // 继续路径:确认后 21 个逐文件入队
    final go = downloadSelectedAssets(
      captured,
      assets: assets,
      canDownload: true,
      where: 'w',
      queue: q,
      io: _io(),
    );
    await tester.pump();
    await tester.tap(find.text('继续下载'));
    final r = await go;
    expect(r, (21, 0));
    expect(q.tasks.length, 21);
  });

  testWidgets('deleteSelectedAssets:确认弹窗取消 → null 不发请求', (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) {
              captured = ctx;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    final r = deleteSelectedAssets(
      captured,
      assets: [_asset('a.jpg')],
      folderId: 'f1',
    );
    await tester.pump(); // 弹窗进场
    expect(find.text('删除 1 个文件?'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(await r, isNull);
    expect(api.assets.deleteCalls, isEmpty);
  });

  testWidgets('deleteSelectedAssets:全败(403)→ (0,1) 不失效;detail 透传入汇总', (
    tester,
  ) async {
    final api = installFakeApi();
    api.assets.deleteStaged = ApiException(
      403,
      'no permission to delete this asset',
    );
    addTearDown(() => session.api = null);
    var assetsInvalidated = 0;
    var foldersInvalidated = 0;
    void onAssets() => assetsInvalidated++;
    void onFolders() => foldersInvalidated++;
    RefreshBus.I.addListener('assets:f1', onAssets);
    RefreshBus.I.addListener('folders', onFolders);
    addTearDown(() {
      RefreshBus.I.removeListener('assets:f1', onAssets);
      RefreshBus.I.removeListener('folders', onFolders);
    });

    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) {
              captured = ctx;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    final allFail = deleteSelectedAssets(
      captured,
      assets: [_asset('403.jpg')],
      folderId: 'f1',
    );
    await tester.pump(); // 弹窗进场
    await tester.tap(find.text('删除'));
    expect(await allFail, (0, 1));
    expect(assetsInvalidated, 0, reason: '全败不失效');
    await tester.pump(); // SnackBar 进场
    expect(find.textContaining('删除 0 个文件 · 失败 1 个'), findsOneWidget);
    expect(
      find.textContaining('首个失败:no permission to delete this asset'),
      findsOneWidget,
      reason: '403 detail 透传入汇总',
    );
  });

  testWidgets('deleteSelectedAssets:全成功 → (n,0) 并失效两 scope', (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    var assetsInvalidated = 0;
    var foldersInvalidated = 0;
    void onAssets() => assetsInvalidated++;
    void onFolders() => foldersInvalidated++;
    RefreshBus.I.addListener('assets:f1', onAssets);
    RefreshBus.I.addListener('folders', onFolders);
    addTearDown(() {
      RefreshBus.I.removeListener('assets:f1', onAssets);
      RefreshBus.I.removeListener('folders', onFolders);
    });

    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) {
              captured = ctx;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    final r = deleteSelectedAssets(
      captured,
      assets: [_asset('ok1.jpg'), _asset('ok2.jpg')],
      folderId: 'f1',
    );
    await tester.pump(); // 弹窗进场
    await tester.tap(find.text('删除'));
    expect(await r, (2, 0));
    expect(api.assets.deleteCalls, [
      'a-ok1.jpg',
      'a-ok2.jpg',
    ], reason: '逐条 DELETE');
    expect(assetsInvalidated, greaterThan(0));
    expect(foldersInvalidated, greaterThan(0));
  });

  testWidgets('deleteSelectedAssets:部分失败(2 ok+1 fail)→ (2,1) 失效一次,'
      '汇总含首个失败 detail', (tester) async {
    final api = installFakeApi();
    api.assets.deleteStagedById['a-403.jpg'] = ApiException(
      403,
      'no permission to delete this asset',
    );
    addTearDown(() {
      session.api = null;
      api.assets.deleteStagedById.clear();
    });
    var assetsInvalidated = 0;
    void onAssets() => assetsInvalidated++;
    RefreshBus.I.addListener('assets:f1', onAssets);
    addTearDown(() => RefreshBus.I.removeListener('assets:f1', onAssets));

    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) {
              captured = ctx;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    final r = deleteSelectedAssets(
      captured,
      assets: [_asset('ok1.jpg'), _asset('403.jpg'), _asset('ok2.jpg')],
      folderId: 'f1',
    );
    await tester.pump(); // 弹窗进场
    await tester.tap(find.text('删除'));
    expect(await r, (2, 1), reason: '失败不中断:ok=2 fail=1');
    expect(api.assets.deleteCalls, [
      'a-ok1.jpg',
      'a-403.jpg',
      'a-ok2.jpg',
    ], reason: '单条失败后继续删完剩余');
    expect(assetsInvalidated, greaterThan(0), reason: '有任一成功即失效(宫格订阅静默刷新)');
    await tester.pump(); // SnackBar 进场
    expect(
      find.text(
        '删除 2 个文件 · 失败 1 个'
        '(首个失败:no permission to delete this asset)',
      ),
      findsOneWidget,
    );
  });

  // ── F8 显式选择态 / 排序 / 类型角标 / 打样卡 ─────────────────────────────
  testWidgets('显式选择态:点「选择」后 0 选中操作栏常驻、动作禁用;「取消」退出', (tester) async {
    await _pumpAssets(tester, [fakeAsset('a1'), fakeAsset('a2')]);
    expect(find.text('选择'), findsOneWidget);
    await tester.tap(find.text('选择'));
    await tester.pump();
    expect(find.text('已选 0 项'), findsOneWidget, reason: '0 选中也显示底部操作栏');
    expect(find.text('全选'), findsOneWidget);
    expect(find.byTooltip('退出多选'), findsOneWidget);
    await tester.tap(find.text('下载'), warnIfMissed: false);
    await tester.pump();
    expect(
      find.textContaining('已加入下载队列'),
      findsNothing,
      reason: '0 选中时动作禁用(不触发下载)',
    );
    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(find.textContaining('已选'), findsNothing);
    expect(find.text('选择'), findsOneWidget);
  });

  testWidgets('排序 chip:默认最新优先,点按切最早优先并即时重排', (tester) async {
    await _pumpAssets(tester, [
      _dated('old', '18'),
      _dated('new', '22'),
      _dated('mid', '20'),
    ]);
    expect(find.text('最新优先'), findsOneWidget);
    expect(_gridOrder(tester), ['new', 'mid', 'old']);
    await tester.tap(find.text('最新优先'));
    await tester.pump();
    expect(find.text('最早优先'), findsOneWidget);
    expect(_gridOrder(tester), ['old', 'mid', 'new']);
  });

  testWidgets('类型角标:PDF/MD/视频/实况;无缩略图渲染 AssetPlate 打样卡', (tester) async {
    final assets = [
      _typed('p.pdf', 'application/pdf'),
      _typed('m.md', 'text/markdown'),
      _typed('v.mov', 'video/quicktime'),
      _typed('l.livp', 'application/zip'),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              for (final a in assets)
                SizedBox(
                  width: 140,
                  height: 220,
                  child: AssetGridTile(
                    asset: a,
                    selected: false,
                    selecting: false,
                    onTap: () {},
                    onLongPress: () {},
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('PDF'), findsOneWidget);
    expect(find.text('MD'), findsOneWidget);
    expect(find.text('视频'), findsOneWidget);
    expect(find.text('实况'), findsOneWidget);
    expect(
      find.byType(AssetPlate),
      findsNWidgets(4),
      reason: '无缩略图/失败用 AssetPlate,而非灰块',
    );
  });
}
