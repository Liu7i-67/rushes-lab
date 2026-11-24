/// 回收站快速滚动(app-fast-scroll F4)行为+回归(文档测试功能点 7):
/// - FastScrollBar 显隐:total≥100 渲染、<100 不渲染(100/99 边界)、
///   空态/错误态无滚动条;
/// - itemCount=_total:已加载区正常行、滚动进未加载区见骨架行且自动补齐
///   (无风暴:在途只挂 pendingTarget);
/// - onSeek(直接调/滚动条拖动释放)后 Fake 收到的 offset/limit 批次正确;
/// - 恢复一条后 total-1、列表与滚动条随之更新;
/// - 回归保持:滚到底自动加载、失败重试条、下拉刷新。
/// Fake API 按「全量清单切窗」编排:listTrash 从 all 按 offset/limit 切片,
/// total 独立(参考 trash_page_test 的 _PagedOpsApi 模式泛化到任意窗口)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
// 页面组件 TrashPage(features)与数据类 TrashPage(models)同名:数据类别名引入
import 'package:ms_app/features/assets/trash_page.dart';
import 'package:ms_app/models/asset.dart' as asset_models show TrashPage;
import 'package:ms_app/models/models.dart' hide TrashPage;
import 'package:ms_app/widgets/fast_scroll_bar.dart';

import '../helpers/api_harness.dart';

/// 任意 offset/limit 切窗的假回收站 API:total 独立于清单长度;failQueue
/// 逐次排队异常(命中即抛,失败重试条用例)。
class _WindowedOpsApi extends FakeOpsApi {
  _WindowedOpsApi(super.api);

  List<Asset> all = const [];
  int total = 0;
  final failQueue = <Object?>[];

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
    return asset_models.TrashPage(
      items: all.skip(offset).take(limit).toList(),
      total: total,
    );
  }
}

class _WindowedMsApi extends FakeMsApi {
  late final _ops = _WindowedOpsApi(this);

  @override
  _WindowedOpsApi get ops => _ops;
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

/// 滚动条「在场且 visible」:visible=false 时组件实现可能就地收缩,
/// 断言以输入位(visible)为准,不依赖内部渲染细节。
Finder get _visibleBar =>
    find.byWidgetPredicate((w) => w is FastScrollBar && w.visible);

/// UniqueKey 强制整树重建(否则同型 MaterialApp 复用 State,initState
/// 不重跑、_refresh 不重发)。
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
  testWidgets('显隐阈值:total≥100 渲染滚动条;<100 不渲染(100/99 边界)', (tester) async {
    final api = installFakeApi(_WindowedMsApi()) as _WindowedMsApi;
    addTearDown(() => session.api = null);

    api.ops
      ..all = _allOf(120)
      ..total = 120;
    await _pumpTrash(tester);
    expect(_visibleBar, findsOneWidget, reason: '120≥100 → 滚动条在场');
    expect(
      tester.widget<FastScrollBar>(find.byType(FastScrollBar)).total,
      120,
      reason: '滚动条 total 透传全量计数',
    );

    api.ops
      ..all = _allOf(100)
      ..total = 100;
    await _pumpTrash(tester);
    expect(_visibleBar, findsOneWidget, reason: '恰 100 → 显示(D4 阈值含端点)');

    api.ops
      ..all = _allOf(99)
      ..total = 99;
    await _pumpTrash(tester);
    expect(_visibleBar, findsNothing, reason: '99<100 → 不显示');

    api.ops
      ..all = _allOf(60)
      ..total = 60;
    await _pumpTrash(tester);
    expect(_visibleBar, findsNothing, reason: '小列表滚动条是噪音');
  });

  testWidgets('itemCount=_total:已加载区正常行、骨架区命中自动补齐', (tester) async {
    final api = installFakeApi(_WindowedMsApi()) as _WindowedMsApi;
    api.ops
      ..all = _allOf(1100)
      ..total = 1100;
    addTearDown(() => session.api = null);

    await _pumpTrash(tester);
    expect(find.text('共 1100 个已删除文件'), findsOneWidget);
    expect(find.text('素材0.jpg'), findsOneWidget, reason: '已加载区正常行');
    expect(
      find.byKey(const Key('trash_row_skeleton')),
      findsNothing,
      reason: '首屏视口在已加载区 [0,500)',
    );

    // 一把拖进骨架区(未到底):骨架行出现 → 帧末补齐把视口拉齐(无风暴:
    // 在途只挂 pendingTarget,补齐批次数远小于骨架行数)
    await tester.drag(find.byType(ListView), const Offset(0, -40000));
    await tester.pumpAndSettle();
    expect(
      api.ops.trashCalls.length,
      greaterThanOrEqualTo(2),
      reason: '骨架命中触发补齐',
    );
    expect(api.ops.trashCalls[1].offset, 500, reason: '缺口从已加载末尾(500)起');
    expect(api.ops.trashCalls[1].limit, 500, reason: '单批封顶 500');
    expect(
      api.ops.trashCalls.length,
      lessThanOrEqualTo(3),
      reason: '无风暴:补齐批次有守卫收敛',
    );
    expect(
      find.byKey(const Key('trash_row_skeleton')),
      findsNothing,
      reason: '命中骨架的补齐已覆盖视口',
    );

    // 再拖到底(大幅位移由 physics clamp 到底):extentAfter<200 触发兜底
    await tester.drag(find.byType(ListView), const Offset(0, -400000));
    await tester.pumpAndSettle();
    expect(find.text('素材1099.jpg'), findsOneWidget, reason: '尾部行已补齐');
    expect(
      api.ops.trashCalls.last.offset,
      greaterThanOrEqualTo(1000),
      reason: '到底补齐推进到尾部窗口',
    );
    expect(
      find.byKey(const Key('trash_row_skeleton')),
      findsNothing,
      reason: '全量加载后无骨架',
    );
  });

  testWidgets('直接调 onSeek:Fake 收到 offset=500 批;跳到底补齐尾部', (tester) async {
    final api = installFakeApi(_WindowedMsApi()) as _WindowedMsApi;
    api.ops
      ..all = _allOf(1100)
      ..total = 1100;
    addTearDown(() => session.api = null);

    await _pumpTrash(tester);
    final bar = tester.widget<FastScrollBar>(find.byType(FastScrollBar));
    bar.onSeek?.call(900); // 不滚动,直接模拟松手回调
    await tester.pumpAndSettle();
    expect(api.ops.trashCalls[1].offset, 500, reason: '缺口从已加载末尾起');
    expect(api.ops.trashCalls[1].limit, 500, reason: '单批封顶 500');

    // 模拟拖动跳转后的列表位置:滚到底 → 视口尾部骨架补齐剩余缺口
    bar.controller.jumpTo(bar.controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(api.ops.trashCalls[2].offset, 1000, reason: '尾部续批');
    expect(find.text('素材1099.jpg'), findsOneWidget);
  });

  testWidgets('滚动条拖动释放:onSeek 触发补齐,列表跟手跳转', (tester) async {
    final api = installFakeApi(_WindowedMsApi()) as _WindowedMsApi;
    api.ops
      ..all = _allOf(1100)
      ..total = 1100;
    addTearDown(() => session.api = null);

    await _pumpTrash(tester);
    final bar = tester.widget<FastScrollBar>(find.byType(FastScrollBar));
    // F2:右缘 ≥28dp 热区;右缘下拖大位移(f clamp 到 1.0)→ 拖到全量底部
    final gesture = await tester.startGesture(const Offset(786, 300));
    await gesture.moveBy(const Offset(0, 600));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      bar.controller.offset,
      greaterThan(60000),
      reason: '拖动中 jumpTo 实时跟手',
    );
    expect(
      api.ops.trashCalls.any((c) => c.offset == 500),
      isTrue,
      reason: '释放后按缺口补齐',
    );
    expect(find.text('素材1099.jpg'), findsOneWidget, reason: '尾部已补齐');
  });

  testWidgets('恢复一条:total-1、行移除、滚动条过阈值消失', (tester) async {
    final api = installFakeApi(_WindowedMsApi()) as _WindowedMsApi;
    api.ops
      ..all = _allOf(100)
      ..total = 100;
    addTearDown(() => session.api = null);

    await _pumpTrash(tester);
    expect(_visibleBar, findsOneWidget, reason: '前置:100 恰在阈值上');
    await tester.tap(find.byTooltip('恢复到文件夹').first);
    await tester.pumpAndSettle();
    expect(api.ops.restoreCalls, ['t0']);
    expect(find.text('素材0.jpg'), findsNothing, reason: '恢复后行移除');
    expect(find.text('共 99 个已删除文件'), findsOneWidget, reason: 'total-1');
    expect(_visibleBar, findsNothing, reason: '99 跌破阈值 → 滚动条消失');
  });

  testWidgets('空态/错误态无滚动条', (tester) async {
    final api = installFakeApi(_WindowedMsApi()) as _WindowedMsApi;
    addTearDown(() => session.api = null);

    api.ops
      ..all = const []
      ..total = 0;
    await _pumpTrash(tester);
    expect(find.text('回收站是空的'), findsOneWidget);
    expect(find.byType(FastScrollBar), findsNothing, reason: '空态无滚动条');

    api.ops.failQueue.add(Exception('boom'));
    await _pumpTrash(tester);
    expect(find.text('回收站加载失败,请下拉重试'), findsOneWidget);
    expect(find.byType(FastScrollBar), findsNothing, reason: '错误态无滚动条');
  });

  testWidgets('回归:补齐失败出重试条,点按重试成功', (tester) async {
    final api = installFakeApi(_WindowedMsApi()) as _WindowedMsApi;
    api.ops
      ..all = _allOf(560)
      ..total = 560;
    addTearDown(() => session.api = null);

    await _pumpTrash(tester);
    // 首窗(500)已就位后,把异常排到下一次调用(补齐批)上
    api.ops.failQueue.add(Exception('net down'));
    await tester.drag(find.byType(ListView), const Offset(0, -400000));
    await tester.pumpAndSettle();
    expect(find.text('加载失败,点击重试'), findsOneWidget, reason: '失败重试条在场');
    expect(api.ops.trashCalls.length, 2);

    await tester.tap(find.text('加载失败,点击重试'));
    await tester.pumpAndSettle();
    expect(find.text('加载失败,点击重试'), findsNothing, reason: '重试成功后重试条退场');
    expect(api.ops.trashCalls.last.offset, 500, reason: '重试按缺口 offset 补齐');
    // 骨架行换实体行后列表撑高,再拖一次到底确认尾部已补齐
    await tester.drag(find.byType(ListView), const Offset(0, -400000));
    await tester.pumpAndSettle();
    expect(find.text('素材559.jpg'), findsOneWidget, reason: '缺口补齐');
    expect(
      find.byKey(const Key('trash_row_skeleton')),
      findsNothing,
      reason: '全量加载后无骨架',
    );
  });

  testWidgets('回归:下拉刷新回到 offset=0 首窗', (tester) async {
    final api = installFakeApi(_WindowedMsApi()) as _WindowedMsApi;
    api.ops
      ..all = _allOf(60)
      ..total = 60;
    addTearDown(() => session.api = null);

    await _pumpTrash(tester);
    expect(api.ops.trashCalls.length, 1);

    await tester.fling(find.text('素材0.jpg'), const Offset(0, 250), 1000);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 800));
    expect(api.ops.trashCalls.length, 2, reason: '下拉触发刷新');
    expect(api.ops.trashCalls.last.offset, 0, reason: '刷新回到首窗');
    expect(api.ops.trashCalls.last.limit, 500);
    expect(find.text('素材0.jpg'), findsOneWidget, reason: '刷新后列表正常');
  });
}
