/// 宫格页快速滚动·专职测试补充边界用例(qdev 2026-11-24 app-fast-scroll 测试
/// 执行批;开发三文件未覆盖的 T 系列口径与盲区,按需保留):
/// - T7 补:首拉挂起(loading)/首拉失败(error)态滚动条不在树;
/// - T8 补:total=99/100 阈值边界(宫格页侧);
/// - T11 补:真实拖动 62.5% 释放 → 缺口多批并行挂起、放行后合并覆盖目标;
/// - T13 补:在途二次 seek → pendingTarget 续补不丢、不并发、不重复;
/// - T14 补:total=501(拖到最底单批)/999(seek 到底两批)非整页;
/// - T15 补:ASC 下拖动 seek 至顶 → offset 窗口落最旧端(offset+limit=total);
/// - T16 补:补齐在途遇 RefreshBus 静默刷新 → 无崩溃、无重复、目标仍覆盖;
/// - T19 补:骨架格 tap/longPress 无交互,已加载格可进预览;
/// - T25 补(高危):ASC 下点已加载末格 → 预览传参=该格资产(显示序换算);
/// - 盲区:补齐在途 total 缩小 → 窗口/滚动条一致无越界;
/// - 盲区:DESC 拖到最顶 onSeek(0) 不发请求;
/// - 盲区:ASC 滚到底自动加载口径(整尾补齐)记录 + 收敛不风暴;
/// - 盲区:失败态骨架命中不自动重试(不风暴),滚动重滑保留重试。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart' show ApiException;
import 'package:ms_app/core/refresh_bus.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/assets/assets_page.dart';
import 'package:ms_app/features/preview/preview_page.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/widgets/fast_scroll_bar.dart';
import 'package:ms_app/widgets/list_skeleton.dart';

import '../helpers/api_harness.dart';

/// 按 offset 编排任意窗口的假 assets 列表(仿 assets_fast_scroll_test 的
/// _SeekAssetsApi,加「首拉挂起/失败」与「缺口全挂起」两档编排):
/// offset=0 返回 firstPage 条;offset>0 按 min(limit, total-offset) 连续生成;
/// 资产 createdAt 随 offset 递减(后端 DESC 域:offset 0 最新),id 编码 offset。
class _EdgeAssetsApi extends FakeAssetsApi {
  _EdgeAssetsApi(super.api);

  final listCalls = <({int limit, int offset})>[];
  int total = 0;
  int firstPage = 0;

  /// 首拉挂起(loading 态显隐用)。
  Completer<AssetPage>? gateFirst;

  /// 首拉失败(error 态显隐用;命中一次自清,任意 offset 首次调用生效)。
  bool failFirst = false;

  /// 下一次缺口(offset>0)请求抛异常一次(失败态用;命中自清)。
  bool failNextGap = false;

  /// 缺口(offset>0)请求全部挂起,由 [releaseGaps] 放行(并发/续补编排)。
  bool gateGaps = false;
  final _gated = <({int offset, int limit, Completer<AssetPage> c})>[];

  @override
  Future<AssetPage> list(
    String folderId, {
    int limit = 30,
    int offset = 0,
  }) async {
    listCalls.add((limit: limit, offset: offset));
    if (failFirst) {
      failFirst = false;
      throw ApiException(500, '首拉失败');
    }
    if (offset > 0 && failNextGap) {
      failNextGap = false;
      throw ApiException(500, '模拟网络失败');
    }
    if (offset == 0) {
      final g = gateFirst;
      if (g != null) return g.future;
      return _page(firstPage, 0);
    }
    if (gateGaps) {
      final c = Completer<AssetPage>();
      _gated.add((offset: offset, limit: limit, c: c));
      return c.future;
    }
    return _page(limit, offset);
  }

  AssetPage _page(int limit, int offset) => AssetPage(
    items: [
      for (var i = 0; i < math.max(0, math.min(limit, total - offset)); i++)
        _asset(offset + i),
    ],
    total: total,
  );

  /// 放行全部挂起缺口(按请求时的 offset/limit 生成页面,读当前 total)。
  void releaseGaps() {
    for (final p in _gated) {
      p.c.complete(_page(p.limit, p.offset));
    }
    _gated.clear();
  }
}

/// 后端 DESC 域资产:offset 越大越旧,id/filename 编码 offset 便于断言。
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

class _EdgeMsApi extends FakeMsApi {
  late final _edge = _EdgeAssetsApi(this);

  @override
  _EdgeAssetsApi get assets => _edge;
}

_EdgeMsApi _install({required int total, required int firstPage}) {
  final api = _EdgeMsApi()
    ..assets.total = total
    ..assets.firstPage = firstPage;
  session.api = api;
  addTearDown(() {
    session.api = null;
    session.me = null;
  });
  return api;
}

/// 路由探针:记录 pushNamed('/preview') 的 arguments。不真渲染 PreviewPage
/// ——其缩略条 48px 小格在缩略图不可用时落 TypeBlock 兜底会触发 8px 溢出
/// (与本批改动无关的既有布局问题),传参口径用探针断言即可。
class _RouteSpy {
  final pushed = <Object?>[];
}

/// 挂宫格页;UniqueKey 强制重挂。[spy] 非空时注册 /preview 探针路由
/// (生产由 app.dart onGenerateRoute 提供)。
Future<void> _pumpPage(WidgetTester tester, {_RouteSpy? spy}) async {
  await tester.pumpWidget(
    MaterialApp(
      key: UniqueKey(),
      onGenerateRoute: spy == null
          ? null
          : (settings) {
              if (settings.name == '/preview') {
                spy.pushed.add(settings.arguments);
                return MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: SizedBox.shrink()),
                );
              }
              return null;
            },
      home: AssetsPage(folderId: 'f1', folderName: '夹A'),
    ),
  );
  await tester.pump(); // 首拉 future.wait 微任务 + setState 重建
  await tester.pump();
}

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

/// 滚动条是否「可见」(组件 visible=false 时仍挂树,断言以入参为准)。
bool _scrollBarShown(WidgetTester tester) {
  if (find.byType(FastScrollBar).evaluate().isEmpty) return false;
  return tester.widget<FastScrollBar>(find.byType(FastScrollBar)).visible;
}

/// 真实手势把滚动条拖到轨道比例 f 处并松手。[fromBelow]=从目标下方进入
/// (f≈0 时用,避免向上越出轨顶)。进入位移 40dp 保证越过触摸 slop 触发
/// onVerticalDragStart;落点=目标 dy,onStart 以当前指针位置为准。
Future<void> _dragBarToF(
  WidgetTester tester,
  double f, {
  bool fromBelow = true,
}) async {
  final rect = tester.getRect(find.byType(FastScrollBar));
  final pos = _gridPosition(tester);
  final trackH = rect.height - 20; // FastScrollBar _trackInset*2
  final thumbH = (trackH * pos.viewportDimension / pos.maxScrollExtent).clamp(
    40.0,
    trackH,
  );
  final span = trackH - thumbH;
  final dy = 10 + thumbH / 2 + f * span;
  const approach = 40.0;
  final startDy = fromBelow ? dy + approach : dy - approach;
  final g = await tester.startGesture(
    Offset(rect.left + 14, rect.top + startDy),
  );
  await g.moveBy(Offset(0, fromBelow ? -approach : approach));
  await tester.pump();
  await tester.pump();
  await g.up();
  await tester.pump();
}

void main() {
  // ── T7 补:loading / error 态滚动条不在树 ────────────────────────────────
  testWidgets('首拉挂起(loading)与首拉失败(error)态均无滚动条', (tester) async {
    final api = _install(total: 2000, firstPage: 200);
    api.assets.gateFirst = Completer<AssetPage>();
    await tester.pumpWidget(
      MaterialApp(
        key: UniqueKey(),
        home: AssetsPage(folderId: 'f1', folderName: '夹A'),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(ListSkeleton), findsOneWidget, reason: '前置:整页骨架态');
    expect(
      find.byType(FastScrollBar),
      findsNothing,
      reason: 'T7-1:loading 态无网格分支,滚动条整体不在树',
    );

    api.assets.gateFirst!.complete(
      AssetPage(items: [for (var i = 0; i < 200; i++) _asset(i)], total: 2000),
    );
    await tester.pump();
    await tester.pump();
    expect(_scrollBarShown(tester), isTrue, reason: '放行后进入列表态 → 滚动条在场');

    final api2 = _install(total: 500, firstPage: 200);
    api2.assets.failFirst = true;
    await _pumpPage(tester);
    expect(find.byType(FastScrollBar), findsNothing, reason: 'T7-2:error 态不在树');
  });

  // ── T8 补:total=99/100 阈值边界 ─────────────────────────────────────────
  testWidgets('total=99 不显示;total=100 显示(阈值含端点)', (tester) async {
    _install(total: 99, firstPage: 99);
    await _pumpPage(tester);
    expect(_scrollBarShown(tester), isFalse, reason: 'D4:99<100 不显示');

    _install(total: 100, firstPage: 100);
    await _pumpPage(tester);
    expect(_scrollBarShown(tester), isTrue, reason: 'D4:恰 100 显示');
  });

  // ── T11 补:真实拖动 62.5% 释放 → 并行缺口批次 ───────────────────────────
  testWidgets('真实拖动 62.5% 释放:缺口多批并行挂起,放行后合并覆盖 seek 目标', (tester) async {
    final api = _install(total: 2000, firstPage: 200);
    api.assets.gateGaps = true;
    await _pumpPage(tester);
    expect(api.assets.listCalls, [(limit: 200, offset: 0)], reason: '前置:只拉一页');

    // 拖到轨道 62.5%(≈显示序 1250)并保持按住(不松手):骨架命中已触发补齐
    final rect = tester.getRect(find.byType(FastScrollBar));
    final pos = _gridPosition(tester);
    final trackH = rect.height - 20;
    final thumbH = (trackH * pos.viewportDimension / pos.maxScrollExtent).clamp(
      40.0,
      trackH,
    );
    final dy = 10 + thumbH / 2 + 0.625 * (trackH - thumbH);
    final g = await tester.startGesture(
      Offset(rect.left + 14, rect.top + dy + 40),
    );
    await g.moveBy(const Offset(0, -40));
    await tester.pump();
    await tester.pump();

    // 缺口请求已在拖动中并行发出(任一响应放行前):offset 连续、首起 200
    final gaps = api.assets.listCalls.sublist(1);
    expect(gaps.length, greaterThanOrEqualTo(3), reason: '拖动落点在骨架区,缺口已并行发出');
    expect(gaps.first.offset, 200, reason: '缺口从已加载末尾起,首页不重拉');
    for (var i = 0; i < gaps.length; i++) {
      expect(gaps[i].limit, lessThanOrEqualTo(500), reason: '批次上限 500');
      if (i > 0) {
        expect(
          gaps[i].offset,
          gaps[i - 1].offset + gaps[i - 1].limit,
          reason: '批间 offset 累进无重复窗口',
        );
      }
    }
    final coveredEnd = gaps.last.offset + gaps.last.limit;
    expect(
      coveredEnd,
      allOf(greaterThanOrEqualTo(1440), lessThanOrEqualTo(2000)),
      reason: '覆盖拖动落点视口末 + 一页余量(实现口径:最深可见骨架+200;落点≈1250)',
    );

    // 松手(onSeek(1250)):在途不并发第二组
    await g.up();
    await tester.pump();
    expect(api.assets.listCalls.length, gaps.length + 1, reason: '释放不并发新请求');

    api.assets.releaseGaps();
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('a1250.jpg'), findsOneWidget, reason: 'seek 目标落位真实 tile');
  });

  // ── T13 补:pendingTarget 续补链 ─────────────────────────────────────────
  testWidgets('在途二次 seek:不并发、续补不丢、全量落地无重复窗口', (tester) async {
    final api = _install(total: 2000, firstPage: 200);
    api.assets.gateGaps = true;
    await _pumpPage(tester);

    // ① seek 1250 → 3 批挂起
    tester.widget<FastScrollBar>(find.byType(FastScrollBar)).onSeek!(1250);
    await tester.pump();
    await tester.pump();
    expect(api.assets.listCalls.sublist(1), [
      (limit: 500, offset: 200),
      (limit: 500, offset: 700),
      (limit: 250, offset: 1200),
    ], reason: '缺口 [200,1450) 恰 3 批');

    // ② 在途再 seek 1900 → 不并发,只记 pendingTarget
    tester.widget<FastScrollBar>(find.byType(FastScrollBar)).onSeek!(1900);
    await tester.pump();
    expect(api.assets.listCalls.length, 4, reason: 'T13-1:在途只挂 pending,不发第二组');

    // ③ 放行批次 A → 自动续补缺口 [1450, 2000)
    api.assets.releaseGaps();
    await tester.pump();
    await tester.pump();
    expect(api.assets.listCalls.sublist(4), [
      (limit: 500, offset: 1450),
      (limit: 50, offset: 1950),
    ], reason: 'T13-2:pendingTarget 续补两批');

    // ④ 放行续补 → 全量 2000 落地
    api.assets.releaseGaps();
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    final allOffsets = api.assets.listCalls.map((c) => c.offset).toList();
    expect(allOffsets.toSet().length, allOffsets.length, reason: '无重复窗口');
    _gridPosition(tester).jumpTo(_gridPosition(tester).maxScrollExtent);
    await tester.pump();
    await tester.pump();
    expect(find.text('a1999.jpg'), findsOneWidget, reason: 'T13-3:全量落地尾部可见');
    expect(find.text('共 2000 个素材'), findsOneWidget);
  });

  // ── T14 补:total=501 / 999 非整页 ───────────────────────────────────────
  testWidgets('total=501 拖到最底松手(=total-1):缺口收敛补齐至 501,页头计数一致', (tester) async {
    final api = _install(total: 501, firstPage: 200);
    await _pumpPage(tester);
    await _dragBarToF(tester, 1.0, fromBelow: false); // 拖到轨道底端=显示序 total-1
    await tester.pump();
    await tester.pump();
    // 缺口 [200,501) 由「到底监听 + 骨架命中续补」两路汇合补齐:窗口连续、
    // 覆盖至 501(监听路=loadedEnd+余量先行,骨架路续补尾部,去重守卫收敛)
    final gaps = api.assets.listCalls.sublist(1);
    expect(gaps.length, lessThanOrEqualTo(3), reason: '无风暴:两路收敛');
    expect(gaps.first.offset, 200);
    for (var i = 0; i < gaps.length; i++) {
      if (i > 0) {
        expect(
          gaps[i].offset,
          gaps[i - 1].offset + gaps[i - 1].limit,
          reason: '批间 offset 连续无重复窗口',
        );
      }
    }
    expect(gaps.last.offset + gaps.last.limit, 501, reason: '缺口最终全量补齐');
    expect(find.text('a500.jpg'), findsOneWidget, reason: '末位渲染真实 tile');
    expect(find.text('共 501 个素材'), findsOneWidget, reason: '页头计数');
  });

  testWidgets('total=999 seek 到最底:两批 (200,500)+(700,299),合并无重复', (
    tester,
  ) async {
    final api = _install(total: 999, firstPage: 200);
    await _pumpPage(tester);
    tester.widget<FastScrollBar>(find.byType(FastScrollBar)).onSeek!(998);
    await tester.pump();
    await tester.pump();
    expect(api.assets.listCalls.sublist(1), [
      (limit: 500, offset: 200),
      (limit: 299, offset: 700),
    ], reason: '缺口 [200,999) 恰两批');
    _gridPosition(tester).jumpTo(_gridPosition(tester).maxScrollExtent);
    await tester.pump();
    await tester.pump();
    expect(find.text('a998.jpg'), findsOneWidget);
    expect(find.text('共 999 个素材'), findsOneWidget);
    final offsets = api.assets.listCalls.map((c) => c.offset).toList();
    expect(offsets.toSet().length, offsets.length, reason: '无重复窗口');
  });

  // ── T15 补:ASC 下拖动 seek 至顶 → 窗口落最旧端 ──────────────────────────
  // 需求 T15/T24 口径:ASC seek 顶 → offset+limit=total → 落地后显示序头部
  // 渲染最旧一条、头部不再是骨架。P0-1 修复后语义(D5/D11):ASC 任何补齐
  // 恒从 loaded 邻接扩展——切换后骨架命中一轮即拉满 [200,2000)(500 上限
  // 分 4 批并行,末批 offset+limit=total 落最旧端),此后拖动 seek/回切均
  // 被守卫吸收不再拉取(旧尾窗口径会给不邻接的 [total-w,total) 尾窗,头部
  // 骨架永存 + 同窗随骨架重建重发,已修复)。
  testWidgets('ASC 拖动 seek 至顶:请求落在最旧端(offset+limit=total),头部渲染最旧', (
    tester,
  ) async {
    final api = _install(total: 2000, firstPage: 200);
    await _pumpPage(tester);
    await tester.tap(find.text('最新优先'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // 切换后骨架命中一轮邻接补齐拉满 [200,2000):4 批 (200,700,1200,1700)
    final callsBeforeSeek = api.assets.listCalls.length;
    expect(callsBeforeSeek, 5, reason: '前置:首页 + 4 批邻接补齐');
    await _dragBarToF(tester, 0.0); // 拖到轨道顶端 f≈0
    await tester.pump();
    await tester.pump();
    // seek 时已全量加载:不发新请求;最近请求=邻接补齐末批,落在最旧端
    final tailBatch = api.assets.listCalls.last;
    expect(tailBatch, (limit: 300, offset: 1700), reason: '末批截到窗口末');
    expect(
      tailBatch.offset + tailBatch.limit,
      2000,
      reason: 'T15 判据:ASC 补齐窗口落在后端最旧端(offset+limit=total)',
    );
    expect(find.text('a1999.jpg'), findsOneWidget, reason: '显示序头部=最旧一条');

    // 切回 DESC:头部恢复最新数据
    await tester.tap(find.text('最早优先'));
    await tester.pump();
    await tester.pump();
    expect(find.text('a0.jpg'), findsOneWidget, reason: 'DESC 头部=最新一条');
    expect(tester.takeException(), isNull);
    expect(
      api.assets.listCalls.length,
      callsBeforeSeek,
      reason: '邻接补齐一轮已拉满,seek/回切 gap=null 不额外拉取',
    );
  });

  // ── T16 补:补齐在途遇静默刷新 ───────────────────────────────────────────
  testWidgets('补齐在途遇 RefreshBus 静默刷新:无崩溃、目标仍被覆盖', (tester) async {
    final api = _install(total: 2000, firstPage: 200);
    api.assets.gateGaps = true;
    await _pumpPage(tester);
    tester.widget<FastScrollBar>(find.byType(FastScrollBar)).onSeek!(1250);
    await tester.pump();
    await tester.pump();
    expect(api.assets.listCalls.length, 4, reason: '前置:3 批挂起');

    RefreshBus.I.invalidate('assets:f1'); // 静默刷新(offset=0 路,不被门挂)
    await tester.pump();
    await tester.pump();
    expect(find.text('共 2000 个素材'), findsOneWidget, reason: 'swap 落地 total 不变');

    api.assets.releaseGaps();
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull, reason: 'T16-1:全程无 crash/越界');
    _gridPosition(tester).jumpTo(_gridPosition(tester).maxScrollExtent * 0.625);
    await tester.pump();
    expect(
      find.text('a1250.jpg'),
      findsOneWidget,
      reason: 'T16-3:swap 未把补齐数据截回首页',
    );
  });

  // ── 盲区:补齐在途 total 缩小 ────────────────────────────────────────────
  testWidgets('补齐在途 total 缩小(他端删除):窗口与滚动条一致、无越界', (tester) async {
    final api = _install(total: 2000, firstPage: 200);
    api.assets.gateGaps = true;
    await _pumpPage(tester);
    tester.widget<FastScrollBar>(find.byType(FastScrollBar)).onSeek!(1250);
    await tester.pump();
    await tester.pump();

    api.assets.total = 1500; // 他端删除 500 条(末尾最旧的),首页 200 不变
    RefreshBus.I.invalidate('assets:f1');
    await tester.pump();
    await tester.pump();
    expect(find.text('共 1500 个素材'), findsOneWidget, reason: 'swap 后 total 同步');
    expect(
      tester.widget<FastScrollBar>(find.byType(FastScrollBar)).total,
      1500,
      reason: '滚动条 total 同步更新',
    );

    api.assets.releaseGaps();
    api.assets.gateGaps = false; // 放行后续自动补齐(否则尾部缺口被门挂住)
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull, reason: '缩窗后放行无越界');
    _gridPosition(tester).jumpTo(_gridPosition(tester).maxScrollExtent);
    await tester.pump();
    await tester.pump();
    expect(
      find.text('a1499.jpg'),
      findsOneWidget,
      reason: '剩余缺口 [1450,1500) 可补齐',
    );
    expect(find.byKey(const Key('asset_tile_skeleton')), findsNothing);
  });

  // ── 盲区:DESC 拖到最顶 ──────────────────────────────────────────────────
  testWidgets('DESC 拖到最顶 onSeek(0):区间已覆盖,不发请求', (tester) async {
    final api = _install(total: 400, firstPage: 200);
    await _pumpPage(tester);
    tester.widget<FastScrollBar>(find.byType(FastScrollBar)).onSeek!(0);
    await tester.pump();
    await tester.pump();
    expect(api.assets.listCalls.length, 1, reason: '显示序 [0,200) 已全加载,gap=null');
  });

  // ── 盲区:ASC 滚到底自动加载口径 ─────────────────────────────────────────
  // 口径记录(D11):ASC 下滚到底/骨架命中任何补齐恒从 loaded 邻接扩展直至
  // 覆盖目标,头部 seek 的代价是近乎补满余量——一轮拉满后自然收敛,无风暴。
  testWidgets('ASC 滚到底自动加载:整尾补齐收敛(口径记录),无风暴', (tester) async {
    final api = _install(total: 1000, firstPage: 200);
    await _pumpPage(tester);
    await tester.tap(find.text('最新优先'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    _gridPosition(tester).jumpTo(_gridPosition(tester).maxScrollExtent);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.takeException(), isNull);
    expect(find.text('a0.jpg'), findsOneWidget, reason: 'ASC 底部=显示序末位=最新一条');
    final offsets = api.assets.listCalls.map((c) => c.offset).toList();
    expect(offsets.toSet().length, offsets.length, reason: '无重复窗口');
    // 收敛后再滚不再发请求(守卫 _items.length >= _total)
    final settled = api.assets.listCalls.length;
    _gridPosition(tester).jumpTo(0);
    await tester.pump();
    _gridPosition(tester).jumpTo(_gridPosition(tester).maxScrollExtent);
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(api.assets.listCalls.length, settled, reason: '全量加载后到底不再发请求');
  });

  // ── 盲区:失败态骨架命中不风暴 + 滚动重滑保留重试 ─────────────────────────
  testWidgets('失败态骨架命中不自动重试(不风暴);滚动重滑可再触发补齐', (tester) async {
    final api = _install(total: 233, firstPage: 200);
    api.assets.failNextGap = true; // 只影响 offset>0 请求,首拉不受影响
    await _pumpPage(tester);
    _gridPosition(tester).jumpTo(_gridPosition(tester).maxScrollExtent);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('加载失败,点击重试'), findsOneWidget, reason: '前置:失败重试条在场');
    expect(api.assets.listCalls.length, 2);

    // 失败态下骨架 tile 反复重建不形成请求风暴
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(api.assets.listCalls.length, 2, reason: '骨架命中被失败态拦截,不风暴');

    // 滚动重滑(再滚到底)保留自动重试语义
    api.assets.failNextGap = false;
    _gridPosition(tester).jumpTo(0);
    await tester.pump();
    _gridPosition(tester).jumpTo(_gridPosition(tester).maxScrollExtent);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(api.assets.listCalls.length, 3, reason: 'F5:滚动重滑重新触发补齐');
    expect(find.text('a232.jpg'), findsOneWidget, reason: '重试成功拼接');
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  // ── T19 补:骨架格不可交互 ───────────────────────────────────────────────
  testWidgets('骨架格 tap/longPress 无交互;已加载格 tap 进预览', (tester) async {
    final api = _install(total: 220, firstPage: 200);
    api.assets.gateGaps = true;
    final spy = _RouteSpy();
    await _pumpPage(tester, spy: spy);
    _gridPosition(tester).jumpTo(_gridPosition(tester).maxScrollExtent - 2000);
    await tester.pump();
    expect(find.byKey(const Key('asset_tile_skeleton')), findsWidgets);

    await tester.tap(find.byKey(const Key('asset_tile_skeleton')).first);
    await tester.pump();
    await tester.pump();
    expect(spy.pushed, isEmpty, reason: 'T19:tap 骨架不进预览');
    expect(tester.takeException(), isNull);
    expect(find.textContaining('已选'), findsNothing, reason: '未进入多选(页头仍夹名)');

    await tester.longPress(find.byKey(const Key('asset_tile_skeleton')).first);
    await tester.pump();
    expect(
      find.textContaining('已选'),
      findsNothing,
      reason: 'T19:longPress 骨架不进多选',
    );
    expect(spy.pushed, isEmpty, reason: 'T19:longPress 骨架不进预览');

    api.assets.releaseGaps();
    await tester.pump();
    await tester.pump();
    _gridPosition(tester).jumpTo(0);
    await tester.pump();
    await tester.tap(find.text('a0.jpg'));
    await tester.pump();
    await tester.pump();
    expect(spy.pushed.length, 1, reason: '对照:已加载格可进预览');
    expect(tester.takeException(), isNull);
  });

  // ── T25 补(高危):ASC 下预览传参换算 ────────────────────────────────────
  testWidgets('预览传参:DESC 直用显示序;ASC 末格换算回 _items 序(点谁开谁)', (tester) async {
    final api = _install(total: 220, firstPage: 200);
    final spy = _RouteSpy();
    await _pumpPage(tester, spy: spy);

    // DESC:显示序 2 = _items[2](首行格,避免视口裁剪导致点按落空)
    await tester.tap(find.text('a2.jpg'));
    await tester.pump();
    await tester.pump();
    var args = spy.pushed.single as PreviewArgs;
    expect(args.index, 2, reason: 'DESC:显示序直传');
    expect(args.items[2].id, 'a2');

    // 返回宫格
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // ASC(判别性构造):门住头部补齐,保持 loaded=200(< total)→ 已加载区在
    // 显示序 [20,220);点显示序 205(=offset 14,中列避开 FAB)→ 换算应传
    // _items 序 185(直传显示序 205 会越界不打开,本用例即红)
    api.assets.gateGaps = true;
    await tester.tap(find.text('最新优先'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    _gridPosition(tester).jumpTo(_gridPosition(tester).maxScrollExtent - 2200);
    await tester.pump();
    await tester.pump();
    // 显示序 205 = 行 68 中列(offset 14):此时已构建但在视口下缘外,
    // ensureVisible 滚入后点按(中列,避开右下 FAB 热区)
    await tester.ensureVisible(find.text('a14.jpg'));
    await tester.pump();
    await tester.tap(find.text('a14.jpg'));
    await tester.pump();
    await tester.pump();
    expect(spy.pushed.length, 2, reason: 'ASC 已加载格可打开预览');
    args = spy.pushed[1] as PreviewArgs;
    expect(
      args.index,
      185,
      reason: 'T25(高危):ASC 显示序 205 → _items 序 205-(220-200)=185(直传会越界不打开)',
    );
    expect(args.items[args.index].id, 'a14', reason: '点谁开谁');
    api.assets.gateGaps = false;
    api.assets.releaseGaps();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  });
}
