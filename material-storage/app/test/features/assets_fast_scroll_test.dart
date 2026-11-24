/// 宫格页快速滚动验收(快速滚动批 F3/F5,对应需求文档测试功能点 2/3/4/5/6/8):
/// - 滚动条显隐(2):total≥100 渲染 FastScrollBar;<100 不渲染;多选态隐藏;
/// - itemCount=total(4):未加载区 AssetTileSkeleton、已加载区正常 tile,
///   全量撑出滚动高度(滚到底只见骨架,不再是被截断的 items.length);
/// - 拖动释放补齐(3):onSeek(显示序)→ 缺口按 offset/limit 正确分批
///   (limit=500 上限,offset 累进并行);显示序 210 → offset 200 limit 210;
/// - 骨架命中补齐无风暴(5):连续 rebuild 多次触发只发一轮请求(在途挂
///   pendingTarget,完成后续补被 gap=null 去重);
/// - 回归(6):滚到底自动加载、失败重试条、下拉刷新重置、RefreshBus 静默
///   刷新 swap 不破窗口模型、升序切换骨架在头部且数据序正确(ASC 缺口恒从
///   loaded 邻接扩展,D5/D11);
/// - 气泡(8):拖动中显示「~N / M」。
/// 套路:memory 假 API(test/helpers/api_harness.dart 的 Fake 体系,按 offset
/// 编排任意窗口),不用真实 HTTP;拖动用 tester 手势/直接调 onSeek。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart' show ApiException;
import 'package:ms_app/core/refresh_bus.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/assets/assets_page.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/widgets/fast_scroll_bar.dart';

import '../helpers/api_harness.dart';

/// 按 offset 编排任意窗口的假 assets 列表:offset=0 返回 [firstPage] 条,
/// 其余按 min(limit, total-offset) 连续生成;资产 createdAt 随 offset 递减
/// (后端 DESC 域:offset 0 最新),id/filename 编码 offset 便于断言。
class _SeekAssetsApi extends FakeAssetsApi {
  _SeekAssetsApi(super.api);

  final listCalls = <({int limit, int offset})>[];
  int total = 0;
  int firstPage = 0;

  /// 置真:下一次 offset>0 请求抛异常(失败重试条用例,用后自清)。
  bool failNextGap = false;

  @override
  Future<AssetPage> list(
    String folderId, {
    int limit = 30,
    int offset = 0,
  }) async {
    listCalls.add((limit: limit, offset: offset));
    if (offset > 0 && failNextGap) {
      failNextGap = false;
      throw ApiException(500, '模拟网络失败');
    }
    final count = offset == 0
        ? firstPage
        : math.max(0, math.min(limit, total - offset));
    return AssetPage(
      items: [for (var i = 0; i < count; i++) _asset(offset + i)],
      total: total,
    );
  }
}

/// 后端 DESC 域资产:offset 越大越旧(createdAt 逐分钟递减,无并列)。
Asset _asset(int offset) => Asset(
  id: 'a$offset',
  filename: 'a$offset.jpg',
  sizeBytes: 1,
  contentType: 'image/jpeg',
  createdAt: DateTime.utc(
    2026,
    1,
    1,
  ).subtract(Duration(minutes: offset)).toIso8601String(),
  folderId: 'f1',
);

class _SeekMsApi extends FakeMsApi {
  late final _seek = _SeekAssetsApi(this);

  @override
  _SeekAssetsApi get assets => _seek;
}

_SeekMsApi _install({required int total, required int firstPage}) {
  final api = _SeekMsApi()
    ..assets.total = total
    ..assets.firstPage = firstPage;
  session.api = api;
  addTearDown(() {
    session.api = null;
    session.me = null;
  });
  return api;
}

/// 挂宫格页;逐 pump 等首拉落定(避开 pumpAndSettle:不定长动画会挂)。
/// UniqueKey 强制每次重新挂载(pumpWidget 对同型 root 原地 update 不重挂,
/// 会让上一轮页面状态残留、不按新 api 重拉)。
Future<void> _pumpPage(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: KeyedSubtree(
        key: UniqueKey(),
        child: AssetsPage(folderId: 'f1', folderName: '夹A'),
      ),
    ),
  );
  await tester.pump(); // 首拉 future.wait 微任务 + setState 重建
  await tester.pump();
}

/// 宫格滚动位置(jumpTo 模拟快速滚动落点)。
ScrollPosition _gridPosition(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byType(GridView),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position;

/// 「~N / M」位置气泡文本匹配(快速滚动批 F2 契约格式)。
Finder _bubbleFinder() => find.byWidgetPredicate(
  (w) => w is Text && RegExp(r'^~\d+ / \d+$').hasMatch(w.data ?? ''),
);

/// 滚动条是否「可见」:组件 visible=false 时仍挂树(渲染 shrink),
/// 断言显隐要看入参;不在树中(loading/error/empty 无网格分支)即隐藏。
bool _scrollBarShown(WidgetTester tester) {
  if (find.byType(FastScrollBar).evaluate().isEmpty) return false;
  return tester.widget<FastScrollBar>(find.byType(FastScrollBar)).visible;
}

void main() {
  // ── 测试功能点 2:滚动条显隐 ─────────────────────────────────────────────
  testWidgets('total≥100 渲染 FastScrollBar;进入多选态隐藏;退出恢复', (tester) async {
    _install(total: 220, firstPage: 200);
    await _pumpPage(tester);
    expect(_scrollBarShown(tester), isTrue, reason: 'D4:total≥100 显示快速滚动条');

    await tester.longPress(find.text('a0.jpg'));
    await tester.pump();
    expect(_scrollBarShown(tester), isFalse, reason: 'D4:多选态隐藏滚动条');

    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(_scrollBarShown(tester), isTrue, reason: '退出多选恢复');
  });

  testWidgets('total<100 与空态都不渲染 FastScrollBar', (tester) async {
    _install(total: 50, firstPage: 50);
    await _pumpPage(tester);
    expect(_scrollBarShown(tester), isFalse, reason: 'D4:小列表滚动条是噪音');
    expect(
      find.byType(FastScrollBar),
      findsOneWidget,
      reason: '组件仍挂树(visible=false 渲染 shrink),显隐门控在调用方',
    );

    _install(total: 0, firstPage: 0);
    await _pumpPage(tester);
    expect(
      find.byType(FastScrollBar),
      findsNothing,
      reason: '空态无网格分支,滚动条整体不在树中',
    );
  });

  // ── 测试功能点 4:itemCount=total,骨架/已加载 tile ───────────────────────
  testWidgets('itemCount=total:已加载区正常 tile,尾部未加载区渲染骨架', (tester) async {
    _install(total: 220, firstPage: 200);
    await _pumpPage(tester);
    expect(find.text('a0.jpg'), findsOneWidget, reason: '已加载区正常 tile');
    expect(
      find.text('a199.jpg'),
      findsNothing,
      reason: '已加载区第 200 条在显示序 199,首屏外',
    );
    expect(
      find.byKey(const Key('asset_tile_skeleton')),
      findsNothing,
      reason: '首屏 [0,200) 已全载,无骨架',
    );

    // 滚到骨架区中部(距底尚有 extentAfter>200,不触发自动补齐):
    // 若 itemCount 仍是 items.length(200),此处应为已加载 tile 而非骨架。
    final pos = _gridPosition(tester);
    pos.jumpTo(pos.maxScrollExtent - 2000);
    await tester.pump();
    expect(
      find.byKey(const Key('asset_tile_skeleton')),
      findsWidgets,
      reason: 'itemCount=total:显示序 200..219 未加载 → 骨架',
    );

    // 再滚到底:骨架命中/滚动监听补齐 [200,220) 后尾部数据落位(itemCount 撑到全量)
    pos.jumpTo(pos.maxScrollExtent);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(
      find.text('a219.jpg'),
      findsOneWidget,
      reason: '列表尾=显示序 219(itemCount 按全量撑出,补齐后落位)',
    );
  });

  // ── 测试功能点 3:onSeek 缺口补齐批次 ────────────────────────────────────
  testWidgets('onSeek(210) → 一轮补齐 offset=200 limit=210(显示序+一页余量)', (
    tester,
  ) async {
    final api = _install(total: 1000, firstPage: 200);
    await _pumpPage(tester);
    expect(api.assets.listCalls, [
      (limit: 200, offset: 0),
    ], reason: '前置:首轮只拉一页');

    tester.widget<FastScrollBar>(find.byType(FastScrollBar)).onSeek!(210);
    await tester.pump();
    await tester.pump();
    expect(api.assets.listCalls.length, 2);
    expect(api.assets.listCalls.last, (
      limit: 210,
      offset: 200,
    ), reason: '目标显示序 [0,210+200) → offset 窗口缺口 [200,410)');
    expect(
      find.byKey(const Key('asset_tile_skeleton')),
      findsNothing,
      reason: '显示序 [0,410) 已全覆盖,首屏无骨架',
    );
  });

  testWidgets('onSeek 跨多批缺口:limit=500 分批、offset 累进并行', (tester) async {
    final api = _install(total: 1200, firstPage: 200);
    await _pumpPage(tester);
    tester.widget<FastScrollBar>(find.byType(FastScrollBar)).onSeek!(900);
    await tester.pump();
    await tester.pump();
    expect(api.assets.listCalls.length, 3, reason: '缺口 [200,1100) 分两批');
    expect(api.assets.listCalls[1], (limit: 500, offset: 200));
    expect(api.assets.listCalls[2], (
      limit: 400,
      offset: 700,
    ), reason: '批间 offset 累进,尾批截到窗口末');
    // 补齐后显示序 900 落在已加载区(ASC/DESC 一致:无骨架命中即已覆盖)
    expect(find.byKey(const Key('asset_tile_skeleton')), findsNothing);
  });

  // ── 测试功能点 5:骨架命中补齐无风暴 ─────────────────────────────────────
  testWidgets('快速滚动进骨架区:多枚骨架/滚动监听连续触发只发一轮请求', (tester) async {
    final api = _install(total: 220, firstPage: 200);
    await _pumpPage(tester);
    expect(api.assets.listCalls.length, 1);

    _gridPosition(tester).jumpTo(_gridPosition(tester).maxScrollExtent);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    // 滚动监听 + 一屏骨架 tile 各自触发,收敛为一轮缺口 [200,220)
    expect(api.assets.listCalls.length, 2, reason: '无风暴:只发一轮');
    expect(api.assets.listCalls.last, (limit: 20, offset: 200));
    // 在途续补(pendingTarget)完成后再触发一轮,目标已覆盖 → 空转不加请求
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(api.assets.listCalls.length, 2, reason: '续补被 gap=null 去重');
    expect(find.text('a219.jpg'), findsOneWidget, reason: '补齐后尾部数据可见');
  });

  // ── 测试功能点 6:回归 ──────────────────────────────────────────────────
  testWidgets('回归:逐屏滚到底自动加载既有语义保持(extentAfter<200)', (tester) async {
    final api = _install(total: 233, firstPage: 200);
    await _pumpPage(tester);
    for (var i = 0; i < 40 && api.assets.listCalls.length < 2; i++) {
      await tester.drag(find.byType(GridView), const Offset(0, -800));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(api.assets.listCalls.length, 2, reason: '到底自动发起补齐');
    expect(api.assets.listCalls.last, (limit: 33, offset: 200));
    // 补齐落位后滚到底,尾部内容应直接可见
    final pos = _gridPosition(tester);
    pos.jumpTo(pos.maxScrollExtent);
    await tester.pump();
    await tester.pump();
    expect(find.text('a232.jpg'), findsOneWidget, reason: '尾部内容拼接渲染');
  });

  testWidgets('回归:补齐失败 toast + 底部重试条,点击重试成功', (tester) async {
    final api = _install(total: 233, firstPage: 200);
    api.assets.failNextGap = true;
    await _pumpPage(tester);
    _gridPosition(tester).jumpTo(_gridPosition(tester).maxScrollExtent);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('加载失败,点击重试'), findsOneWidget, reason: 'F5:失败重试条保持');
    expect(find.text('模拟网络失败'), findsOneWidget, reason: 'F5:失败 toast 保持');

    api.assets.failNextGap = false;
    await tester.tap(find.text('加载失败,点击重试'));
    await tester.pump();
    await tester.pump();
    expect(find.text('a232.jpg'), findsOneWidget, reason: '重试成功补齐');
    expect(find.text('加载失败,点击重试'), findsNothing);
    // 排空 toast 计时器,避免悬挂 Timer 干扰收尾
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('回归:RefreshBus 静默刷新 swap 不破窗口模型(骨架区保留)', (tester) async {
    final api = _install(total: 220, firstPage: 200);
    await _pumpPage(tester);
    _gridPosition(tester).jumpTo(_gridPosition(tester).maxScrollExtent);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(
      find.byKey(const Key('asset_tile_skeleton')),
      findsNothing,
      reason: '前置:尾部缺口 [200,220) 已补齐',
    );
    final callsBeforeSwap = api.assets.listCalls.length;

    RefreshBus.I.invalidate('assets:f1');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      api.assets.listCalls.length,
      greaterThan(callsBeforeSwap),
      reason: '静默刷新重拉一页',
    );
    expect(api.assets.listCalls[callsBeforeSwap], (
      limit: 200,
      offset: 0,
    ), reason: 'swap 只拉 offset=0 一页(其后的调用是重挂骨架触发的补齐)');
    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: 'P2-2:静默刷新不整页 spinner',
    );
    _gridPosition(tester).jumpTo(0);
    await tester.pump();
    expect(find.text('a0.jpg'), findsOneWidget, reason: 'swap 落地首屏数据在');

    // swap 重置 loaded=200:滚到底窗口模型驱动的尾部缺口补齐照常工作
    _gridPosition(tester).jumpTo(_gridPosition(tester).maxScrollExtent);
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(api.assets.listCalls.last, (
      limit: 20,
      offset: 200,
    ), reason: '窗口模型未破:swap 后骨架区回到尾部,缺口照常补齐');
  });

  testWidgets('回归:升序切换骨架在头部,ASC 邻接补齐后头部最旧数据真实渲染(大 total)', (tester) async {
    // total=1000 下旧尾窗口径会返回不邻接的 offset 尾窗(如 (800,1000)),
    // 头部骨架永不补齐 + 同窗反复重发(P0);修复后缺口恒从 loaded 邻接扩展。
    final api = _install(total: 1000, firstPage: 200);
    await _pumpPage(tester);
    expect(find.text('a0.jpg'), findsOneWidget, reason: '前置:DESC 首屏最新');

    await tester.tap(find.text('最新优先'));
    await tester.pump();
    // ASC:已加载区(后端最新 200 条)换到显示序 [800,1000),头部 [0,800) 骨架;
    // 首屏(display 0..)应全是骨架,不再是 a0(若骨架仍在尾即此断言红)
    expect(
      find.byKey(const Key('asset_tile_skeleton')),
      findsWidgets,
      reason: 'F3/D8:ASC 骨架在头部',
    );
    expect(
      find.text('a0.jpg'),
      findsNothing,
      reason: 'a0 在 ASC 显示序 999(尾),首屏不应出现',
    );

    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    // 骨架命中触发头部补齐:缺口恒从 loaded=200 邻接扩展到 offset 上界
    // n-0=1000(D5/D11),即 (200,1000) 分两批并行(500 上限、尾批截到窗口
    // 末),一轮收敛;不再是旧口径的 offset 尾窗 [800,1000) 反复重发。
    expect(api.assets.listCalls.length, 3, reason: '首页 + 头部缺口两批,一轮收敛');
    expect(api.assets.listCalls[1], (
      limit: 500,
      offset: 200,
    ), reason: '邻接扩展从 loaded 起');
    expect(api.assets.listCalls[2], (
      limit: 300,
      offset: 700,
    ), reason: '尾批截到窗口末,批间 offset 累进');
    expect(
      find.text('a999.jpg'),
      findsOneWidget,
      reason: '补齐后显示序头部=最旧一条(offset 999)真实渲染',
    );
    expect(find.text('a998.jpg'), findsOneWidget, reason: '显示序 1=offset 998');
    expect(
      find.byKey(const Key('asset_tile_skeleton')),
      findsNothing,
      reason: '头部补齐后无骨架残留',
    );
  });

  testWidgets('回归:下拉刷新重置已加载区(补齐大窗口后刷新,缺口回到 offset=200)', (tester) async {
    final api = _install(total: 1000, firstPage: 200);
    await _pumpPage(tester);
    tester.widget<FastScrollBar>(find.byType(FastScrollBar)).onSeek!(600);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(api.assets.listCalls.length, 3, reason: '前置:缺口 [200,800) 已分两批补齐');

    _gridPosition(tester).jumpTo(0);
    await tester.pump();
    await tester.fling(find.byType(GridView), const Offset(0, 600), 10000);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(api.assets.listCalls.length, 4, reason: 'F5:下拉刷新重拉一页');
    expect(api.assets.listCalls.last, (
      limit: 200,
      offset: 0,
    ), reason: '刷新只拉 offset=0 首页');

    // 刷新后 loaded 重置为 200:滚到底触发缺口,首轮请求 offset 必须回到 200
    // (未重置则是 800 起)
    _gridPosition(tester).jumpTo(_gridPosition(tester).maxScrollExtent);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(api.assets.listCalls.length, greaterThan(4));
    expect(
      api.assets.listCalls[4].offset,
      200,
      reason: '刷新重置生效:缺口从 offset=200 重新开始',
    );
    await tester.pump(const Duration(milliseconds: 100));
  });

  // ── 测试功能点 8:拖动中位置气泡 ─────────────────────────────────────────
  testWidgets('拖动滚动条:实时跟手且气泡显示「~N / M」,松手触发 onSeek 补齐', (tester) async {
    final api = _install(total: 1000, firstPage: 200);
    await _pumpPage(tester);
    final barCenter = tester.getCenter(find.byType(FastScrollBar));

    final gesture = await tester.startGesture(barCenter);
    await gesture.moveBy(const Offset(0, 200));
    await tester.pump();
    expect(_bubbleFinder(), findsOneWidget, reason: 'D3:拖动中显示「~N / M」序号气泡');

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_bubbleFinder(), findsNothing, reason: '松手气泡消失');
    expect(
      api.assets.listCalls.any((c) => c.offset >= 200),
      isTrue,
      reason: '松手 onSeek → 页面按显示序缺口补齐(具体批次随拖动落点)',
    );
  });
}
