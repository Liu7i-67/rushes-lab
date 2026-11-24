/// 回收站快速滚动·专职测试补充边界用例(qdev 2026-11-24 app-fast-scroll;
/// 开发 trash_fast_scroll_test 未覆盖的口径,按需保留):
/// - T29 补:total=501(非整页)seek 到底 → 恰一批 (offset=500) 返回 1 条,
///   页头计数与列表一致、尾部真实行落位;
/// - T31 补(高危):恢复与补齐并发 → 无崩溃、无重复行、total/itemCount 自洽;
/// - 盲区:失败态骨架行命中不风暴(fail 闸拦自动路),重试条 force 放行。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
// 页面组件 TrashPage(features)与数据类 TrashPage(models)同名:数据类别名引入
import 'package:ms_app/features/assets/trash_page.dart';
import 'package:ms_app/models/asset.dart' as asset_models show TrashPage;
import 'package:ms_app/models/models.dart' hide TrashPage;
import 'package:ms_app/widgets/fast_scroll_bar.dart';

import '../helpers/api_harness.dart';

/// 任意 offset/limit 切窗的假回收站 API;支持单次门挂(completeGate 放行,
/// 响应冻结在请求时点——真实后端在途 GET 反映的是请求时数据)与失败队列。
class _EdgeOpsApi extends FakeOpsApi {
  _EdgeOpsApi(super.api);

  List<Asset> all = const [];
  int total = 0;
  final failQueue = <Object?>[];

  final pendingGate =
      <({Completer<asset_models.TrashPage> c, asset_models.TrashPage page})>[];

  /// 门挂下一次 listTrash;测试侧 [completeGate] 放行。
  bool gateNext = false;

  @override
  Future<asset_models.TrashPage> listTrash(
    String folderId, {
    int limit = 500,
    int offset = 0,
  }) async {
    trashCalls.add((folderId: folderId, limit: limit, offset: offset));
    if (failQueue.isNotEmpty) {
      final staged = failQueue.removeAt(0);
      if (staged is Exception) throw staged;
    }
    if (gateNext) {
      gateNext = false;
      final c = Completer<asset_models.TrashPage>();
      // 冻结请求时点切片(真实语义:在途响应反映请求时的后端状态)
      pendingGate.add((c: c, page: _slice(limit, offset)));
      return c.future;
    }
    return _slice(limit, offset);
  }

  /// 放行最早挂起的门挂批(响应=请求时点冻结切片)。
  void completeGate() {
    final p = pendingGate.removeAt(0);
    p.c.complete(p.page);
  }

  asset_models.TrashPage _slice(int limit, int offset) =>
      asset_models.TrashPage(
        items: all.skip(offset).take(limit).toList(),
        total: total,
      );
}

class _EdgeMsApi extends FakeMsApi {
  late final _ops = _EdgeOpsApi(this);

  @override
  _EdgeOpsApi get ops => _ops;
}

Asset _trashed(int i) => Asset(
  id: 't$i',
  filename: '素材$i.jpg',
  sizeBytes: 1,
  contentType: 'image/jpeg',
  createdAt: '2026-10-20T10:00:00Z',
  folderId: 'f1',
  deletedAt: '2026-10-21T09:30:00Z',
);

List<Asset> _allOf(int n) => [for (var i = 0; i < n; i++) _trashed(i)];

/// 挂回收站页(UniqueKey 强制重挂)。
Future<void> _pumpTrash(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      key: UniqueKey(),
      home: TrashPage(folderId: 'f1', folderName: '档案夹'),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // ── T29 补:total=501 非整页 ─────────────────────────────────────────────
  testWidgets('total=501 seek 到最底:恰一批补齐(offset=500),页头计数一致', (tester) async {
    final api = _EdgeMsApi()
      ..ops.all = _allOf(501)
      ..ops.total = 501;
    session.api = api;
    addTearDown(() {
      session.api = null;
      session.me = null;
    });
    await _pumpTrash(tester);

    tester.widget<FastScrollBar>(find.byType(FastScrollBar)).onSeek?.call(500);
    await tester.pumpAndSettle();
    expect(api.ops.trashCalls.length, 2, reason: '缺口 [500,501) 恰一批');
    expect(api.ops.trashCalls.last.offset, 500);
    expect(api.ops.trashCalls.last.limit, 500, reason: '单批上限 500(后端仅剩 1 条)');
    expect(find.text('共 501 个已删除文件'), findsOneWidget);

    // 拖到底:尾部真实行落位(非骨架)
    await tester.drag(find.byType(ListView), const Offset(0, -400000));
    await tester.pumpAndSettle();
    expect(find.text('素材500.jpg'), findsOneWidget, reason: '末行真实渲染');
    expect(find.byKey(const Key('trash_row_skeleton')), findsNothing);
    final offsets = api.ops.trashCalls.map((c) => c.offset).toSet();
    expect(offsets.length, api.ops.trashCalls.length, reason: '无重复窗口');
  });

  // ── T31 补(高危):恢复与补齐并发 ────────────────────────────────────────
  testWidgets('恢复与补齐并发:无崩溃、无重复行、total/页头计数自洽', (tester) async {
    final api = _EdgeMsApi()
      ..ops.all = _allOf(1200)
      ..ops.total = 1200;
    session.api = api;
    addTearDown(() {
      session.api = null;
      session.me = null;
    });
    await _pumpTrash(tester);

    // ① 补齐批在途(门挂):seek(900) → 缺口 [500, 1100) 一批 (500,500)
    api.ops.gateNext = true;
    tester.widget<FastScrollBar>(find.byType(FastScrollBar)).onSeek?.call(900);
    await tester.pump();
    expect(api.ops.trashCalls.length, 2, reason: '前置:补齐批已发并挂起');
    expect(api.ops.trashCalls.last, (
      folderId: 'f1',
      limit: 500,
      offset: 500,
    ));

    // ② 在途时恢复已加载区可见行(素材0);后端同步移除 t0(offset 域对齐)
    await tester.tap(find.byTooltip('恢复到文件夹').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(api.ops.restoreCalls, ['t0']);
    expect(find.text('素材0.jpg'), findsNothing, reason: '恢复行即时移除');
    expect(find.text('共 1199 个已删除文件'), findsOneWidget, reason: 'total-1');
    api.ops
      ..all = _allOf(1200).where((a) => a.id != 't0').toList()
      ..total = 1199;

    // ③ 放行补齐批(响应=请求时点冻结切片 t500..t999,真实后端语义)
    api.ops.completeGate();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'T31-1:全程无 crash/越界');
    expect(find.text('共 1199 个已删除文件'), findsOneWidget);
    expect(find.text('素材0.jpg'), findsNothing);

    // ④ 拖到底续补尾部,验证窗口自洽无重复(t1000..t1199 落位)
    await tester.drag(find.byType(ListView), const Offset(0, -400000));
    await tester.pumpAndSettle();
    expect(find.text('素材1199.jpg'), findsOneWidget, reason: '尾部行落位');
    expect(find.byKey(const Key('trash_row_skeleton')), findsNothing);
    expect(find.text('共 1199 个已删除文件'), findsOneWidget);
    final offsets = api.ops.trashCalls.map((c) => c.offset).toSet();
    expect(offsets.length, api.ops.trashCalls.length, reason: 'T31:无重复窗口');
    // 回到两批拼接边界(显示序 ~999),验证 t999/t1000 衔接无错位
    final listPos = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          ).first,
        )
        .position;
    listPos.jumpTo(listPos.maxScrollExtent * 998 / 1199);
    await tester.pump();
    expect(find.text('素材999.jpg'), findsOneWidget, reason: '第一批尾');
    expect(find.text('素材1000.jpg'), findsOneWidget, reason: '第二批头(拼接边界无错位)');
  });

  // ── 盲区:失败态骨架行命中不风暴 ─────────────────────────────────────────
  testWidgets('失败态骨架行命中不自动重试(不风暴);重试条 force 放行', (tester) async {
    final api = _EdgeMsApi()
      ..ops.all = _allOf(560)
      ..ops.total = 560;
    session.api = api;
    addTearDown(() {
      session.api = null;
      session.me = null;
    });
    await _pumpTrash(tester);
    // 首窗(500)就位后,把异常排到下一次调用(补齐批)上
    api.ops.failQueue.add(Exception('net down'));

    // 拖到底触发补齐 → 失败
    await tester.drag(find.byType(ListView), const Offset(0, -400000));
    await tester.pumpAndSettle();
    expect(find.text('加载失败,点击重试'), findsOneWidget, reason: '前置:失败重试条在场');
    expect(api.ops.trashCalls.length, 2);

    // 失败态下骨架行随滚动反复重建,不形成请求风暴(fail 闸拦自动路)
    _scrollAround(tester);
    await tester.pump();
    _scrollAround(tester);
    await tester.pump();
    expect(api.ops.trashCalls.length, 2, reason: '失败态自动路被拦,不风暴');

    // 重试条 = 显式 force 路 → 重发成功
    await tester.tap(find.text('加载失败,点击重试'));
    await tester.pumpAndSettle();
    expect(find.text('加载失败,点击重试'), findsNothing, reason: '重试成功重试条退场');
    expect(api.ops.trashCalls.last.offset, 500, reason: '按缺口 offset 补齐');

    // 拖到底确认尾部补齐收敛
    await tester.drag(find.byType(ListView), const Offset(0, -400000));
    await tester.pumpAndSettle();
    expect(find.text('素材559.jpg'), findsOneWidget);
    expect(find.byKey(const Key('trash_row_skeleton')), findsNothing);
    await tester.pump(const Duration(seconds: 3)); // 排空 toast 计时器
    await tester.pumpAndSettle();
  });
}

/// 失败态滚动探针:小幅上下滚动促使骨架行重建(不触底,不再发新自动路)。
void _scrollAround(WidgetTester tester) {
  tester
      .state<ScrollableState>(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ).first,
      )
      .position
      .jumpTo(120);
}
