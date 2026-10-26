/// 宫格双挂点批量预热集成(T11① 页面侧,storm-fix W3 #17):
/// - 挂点① _applyPage 之后(首载/刷新共用落点):首载后发批、≤100/批、
///   全量覆盖无重复;
/// - 挂点② _loadMore merge 后(不经 _applyPage):第二页增量同样发批,
///   且只传增量页数据;
/// - thumbnailUrl 404 桩隔离宫格单发兜底(批量路径不打单发);
/// - 批量失败静默:页面照常渲染,无整页错误。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart' show ApiException;
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/assets/assets_page.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

/// 分页假 assets API(page2 支持 List / Exception;同 probe_qa 口径)。
class _PagedAssetsApi extends FakeAssetsApi {
  _PagedAssetsApi(super.api);

  final listCalls = <({int limit, int offset})>[];
  List<Asset> page1 = const [];
  int total = 0;
  Object? page2; // List<Asset> | Exception

  @override
  Future<AssetPage> list(
    String folderId, {
    int limit = 30,
    int offset = 0,
  }) async {
    listCalls.add((limit: limit, offset: offset));
    if (offset > 0) {
      final p = page2;
      if (p is Exception) throw p;
      return AssetPage(items: (p as List<Asset>?) ?? const [], total: total);
    }
    return AssetPage(items: page1, total: total);
  }
}

class _PagedMsApi extends FakeMsApi {
  late final _paged = _PagedAssetsApi(this);

  @override
  _PagedAssetsApi get assets => _paged;
}

Asset _thumbAsset(String id) => Asset(
  id: id,
  filename: '$id.jpg',
  sizeBytes: 4,
  contentType: 'image/jpeg',
  createdAt: '2026-10-20T10:00:00Z',
  folderId: 'f1',
  tags: const {'thumbnail_key': 'k'},
);

Future<void> _pump(WidgetTester tester, _PagedMsApi api) async {
  tester.view.physicalSize = const Size(1080, 1920);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  session.api = api;
  addTearDown(() {
    session.api = null;
    session.me = null;
  });
  await tester.pumpWidget(
    MaterialApp(home: AssetsPage(folderId: 'f1', folderName: '夹A')),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('T11①:首载后按页批量预热(挂点①),≤100/批且全量覆盖', (tester) async {
    final api = _PagedMsApi();
    api.assets.page1 = [for (var i = 1; i <= 250; i++) _thumbAsset('a$i')];
    api.assets.total = 250;
    // 单发 404 桩:隔离宫格单发兜底——本用例只许走批量端点
    api.assets.thumbUrlStaged = ApiException(404, '隔离:单发兜底不得签名');
    await _pump(tester, api);

    // 预热 unawaited 异步:再 pump 几拍让分批请求全部发出(逐批 await)
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    final batches = api.assets.thumbnailUrlsCalls;
    expect(batches.length, 3, reason: '250 条按 100 上限分 3 批');
    for (final b in batches) {
      expect(b.length, lessThanOrEqualTo(100), reason: '后端约束 asset_ids 1..100');
    }
    expect(
      batches.expand((b) => b).toSet().length,
      250,
      reason: '250 条各预热一次:无重复、无遗漏(missingOf 去重)',
    );
    expect(api.assets.thumbUrlCalls, isEmpty, reason: '预热路径不打单发签名(404 桩未触)');
  });

  testWidgets('T11①:_loadMore 第二页 merge 后同样发批(挂点②),只传增量', (tester) async {
    final api = _PagedMsApi();
    api.assets.page1 = [for (var i = 1; i <= 30; i++) _thumbAsset('a$i')];
    api.assets.total = 40;
    api.assets.page2 = [for (var i = 31; i <= 40; i++) _thumbAsset('a$i')];
    await _pump(tester, api);
    await tester.pump(); // 首载预热微任务落地
    expect(api.assets.thumbnailUrlsCalls, [
      [for (var i = 1; i <= 30; i++) 'a$i'],
    ], reason: '前置:首载(挂点①)发一批 30 条');

    // 拖到底触发第二页(阈值 extentAfter<200,单拖未必到底,循环拖)
    for (var i = 0; i < 8 && api.assets.listCalls.length < 2; i++) {
      await tester.drag(find.byType(GridView), const Offset(0, -800));
      await tester.pump();
    }
    expect(api.assets.listCalls.length, 2, reason: '前置:到底发起第二页');
    await tester.pumpAndSettle();

    expect(api.assets.thumbnailUrlsCalls.length, 2, reason: '挂点②:第二页增量再发一批');
    expect(api.assets.thumbnailUrlsCalls.last, [for (var i = 31; i <= 40; i++) 'a$i'],
        reason: '只传增量页数据(不重发首载 30 条)');
  });

  testWidgets('T11①:批量预热失败静默——页面照常渲染,无整页错误', (tester) async {
    final api = _PagedMsApi();
    api.assets.page1 = [for (var i = 1; i <= 3; i++) _thumbAsset('a$i')];
    api.assets.total = 3;
    api.assets.thumbnailUrlsStaged = ApiException(500, '预热失败(测试桩)');
    await _pump(tester, api);
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(api.assets.thumbnailUrlsCalls, [
      ['a1', 'a2', 'a3'],
    ], reason: '确有发起(异常被 prewarm 最外层 catch 吞掉)');
    expect(find.text('a1.jpg'), findsOneWidget, reason: '预热失败不影响列表数据');
    expect(find.text('素材加载失败,请下拉重试'), findsNothing, reason: '静默:无整页错误(D2)');
  });
}
