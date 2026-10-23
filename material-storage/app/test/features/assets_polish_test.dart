/// app-polish 验收用例(对应需求文档 2026-10-21-app-polish.md 包 B 各条):
/// - B1 多选操作栏重排:左端 ✕ 退出多选、「全选/取消全选」勾满/清空、
///   320dp 逻辑宽度不溢出(asset_selection_bar.dart / assets_page.dart);
/// - B3 宫格滚动到底自动加载第二页(fake api 记录 offset,assets_body.dart);
/// - B4 开发日志横条不再渲染(调试信息不得出现在产品 UI,assets_body.dart);
/// - B6 UploadMiniBar 点击跳传输 Tab(openTransfersView 广播 shell:tab:transfers
///   → HomeShell 切传输 tab;非 shell 上下文保留 push 兜底。skip 占位已接活,
///   断言真实切 tab 行为);
/// - B7 缩略图文字元信息字号 ≥11 且对比度提升(asset_tile.dart)。
///
/// 套路:testWidgets + FakeMsApi 记录式假 API(test/helpers/api_harness.dart),
/// 不用真实 HTTP(FakeAsync 下 socket 永不推进)。凡依赖「尚未存在的行为」的
/// 断言均标注 TODO(app-polish Bx):现状应失败,交付后转绿。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/refresh_bus.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/assets/assets_page.dart';
import 'package:ms_app/features/assets/asset_tile.dart';
import 'package:ms_app/features/assets/upload_sheet.dart';
import 'package:ms_app/features/shell/home_shell.dart';
import 'package:ms_app/features/shell/tab_bar.dart';
import 'package:ms_app/features/transfers/transfers_page.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/theme/tk_colors.dart';

import '../helpers/api_harness.dart';

/// 分页记录式假 assets API:AssetsPage 走 list(folderId, limit, offset),
/// [page1]/[page2] 编排两页内容([page2] 为 Exception 则第二页抛)。
class _PagedAssetsApi extends FakeAssetsApi {
  _PagedAssetsApi(super.api);

  final listCalls = <({int limit, int offset})>[];
  List<Asset> page1 = const [];
  int total = 0;
  Object? page2;

  @override
  Future<AssetPage> list(
    String folderId, {
    int limit = 30,
    int offset = 0,
  }) async {
    listCalls.add((limit: limit, offset: offset));
    if (offset > 0) {
      final p2 = page2;
      if (p2 is Exception) throw p2;
      return AssetPage(items: (p2 as List<Asset>?) ?? const [], total: total);
    }
    return AssetPage(items: page1, total: total);
  }
}

class _PagedMsApi extends FakeMsApi {
  late final _paged = _PagedAssetsApi(this);

  @override
  _PagedAssetsApi get assets => _paged;
}

_PagedMsApi _install() {
  final api = _PagedMsApi();
  session.api = api;
  addTearDown(() {
    session.api = null;
    session.me = null;
  });
  return api;
}

/// 挂宫格页;逐 pump 等首轮 loading 落定(避开 pumpAndSettle:缩略图 spinner
/// 为不定长动画)。
Future<void> _pumpAssetsPage(WidgetTester tester, {Size? physicalSize}) async {
  if (physicalSize != null) {
    tester.view.physicalSize = physicalSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }
  await tester.pumpWidget(
    MaterialApp(
      home: AssetsPage(folderId: 'f1', folderName: '夹A'),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  // ── B1 多选操作栏重排 ────────────────────────────────────────────────────
  testWidgets('B1:多选栏「全选」勾满/再点取消清空;左端 ✕ 退出多选', (tester) async {
    final api = _install();
    api.assets.page1 = [
      fakeAsset('a1'),
      fakeAsset('a2'),
      fakeAsset('a3'),
      fakeAsset('a4'),
    ];
    api.assets.total = 4;
    await _pumpAssetsPage(tester);

    // 长按进入多选
    await tester.longPress(find.text('a1.jpg'));
    await tester.pump();
    expect(find.textContaining('已选 1 项'), findsOneWidget);

    // TODO(app-polish B1): 现状应失败,交付后转绿——「全选」不存在
    expect(
      find.textContaining('全选'),
      findsOneWidget,
      reason: 'B1:多选栏提供「全选」入口(勾满/取消全选切换)',
    );
    await tester.tap(find.textContaining('全选'));
    await tester.pump();
    expect(
      find.textContaining('已选 4 项'),
      findsOneWidget,
      reason: 'B1:全选后计数=已加载条目总数',
    );

    // 全选 ↔ 取消全选:再点一次全清(交付后标签可能为「取消全选」,用包含匹配)
    await tester.tap(find.textContaining('全选').first);
    await tester.pump();
    expect(
      find.textContaining('已选'),
      findsNothing,
      reason: 'B1:取消全选后退出多选态(操作栏消失)',
    );

    // 重新进入多选,左端 ✕ 退出
    await tester.longPress(find.text('a2.jpg'));
    await tester.pump();
    expect(find.textContaining('已选 1 项'), findsOneWidget);
    final close = find.byIcon(Icons.close).evaluate().isNotEmpty
        ? find.byIcon(Icons.close)
        : find.byIcon(Icons.close_outlined);
    // TODO(app-polish B1): 现状应失败,交付后转绿——左端 ✕ 退出多选
    expect(close, findsWidgets, reason: 'B1:操作栏左端有 ✕ 退出入口');
    await tester.tap(close.first);
    await tester.pump();
    expect(find.textContaining('已选'), findsNothing, reason: 'B1:✕ 退出多选态');
  });

  testWidgets('B1:320dp 逻辑宽度下多选栏不溢出(全选态含操作键)', (tester) async {
    final api = _install();
    api.assets.page1 = [
      fakeAsset('a1'),
      fakeAsset('a2'),
      fakeAsset('a3'),
      fakeAsset('a4'),
    ];
    api.assets.total = 4;
    await _pumpAssetsPage(tester, physicalSize: const Size(320, 800));
    expect(tester.takeException(), isNull, reason: 'B1 前置:320dp 宫格本身不溢出');

    await tester.longPress(find.text('a1.jpg'));
    await tester.pump();
    // TODO(app-polish B1): 现状应失败(「全选」不存在),交付后转绿;
    // 交付形态下多选栏键数变多,320dp 不得渲染 overflow 异常
    expect(find.textContaining('全选'), findsOneWidget);
    await tester.tap(find.textContaining('全选'));
    await tester.pump();
    expect(
      tester.takeException(),
      isNull,
      reason: 'B1:320dp 宽度多选栏(含全选/操作键)不溢出',
    );
  });

  // ── P2-7 reduced-motion ─────────────────────────────────────────────────
  testWidgets('P2-7:disableAnimations 下宫格选中动效时长归零(无动画 ticker)', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 140,
                  height: 220,
                  child: AssetGridTile(
                    asset: fakeAsset('a1'),
                    selected: true,
                    selecting: true,
                    onTap: () {},
                    onLongPress: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      tester.widget<AnimatedScale>(find.byType(AnimatedScale)).duration,
      Duration.zero,
      reason: '选中缩放瞬时',
    );
    final containers = tester.widgetList<AnimatedContainer>(
      find.byType(AnimatedContainer),
    );
    expect(containers, isNotEmpty);
    expect(
      containers.every((c) => c.duration == Duration.zero),
      isTrue,
      reason: '金环/勾底过渡瞬时',
    );
    expect(
      tester.widget<AnimatedSwitcher>(find.byType(AnimatedSwitcher)).duration,
      Duration.zero,
      reason: '勾形切换瞬时',
    );
    expect(tester.takeException(), isNull);
  });

  // ── B3 滚动到底自动加载 ──────────────────────────────────────────────────
  testWidgets('B3:宫格滚动到底自动请求第二页(offset=首页条数),无需点按', (tester) async {
    final api = _install();
    api.assets.page1 = [for (var i = 1; i <= 30; i++) fakeAsset('a$i')];
    api.assets.total = 33;
    api.assets.page2 = [fakeAsset('a31'), fakeAsset('a32'), fakeAsset('a33')];
    await _pumpAssetsPage(tester);
    expect(api.assets.listCalls.single.offset, 0, reason: '首轮只拉第一页');

    // 只滚动,不点任何按钮——B3 验收点:到底即自动加载
    for (var i = 0; i < 6; i++) {
      await tester.drag(find.byType(GridView), const Offset(0, -800));
      await tester.pumpAndSettle();
    }
    // TODO(app-polish B3): 现状应失败(需手点「加载更多」),交付后转绿
    expect(api.assets.listCalls.length, 2, reason: 'B3:滚动到底自动发起第二页请求');
    expect(api.assets.listCalls.last.offset, 30, reason: 'B3:offset=首页条数');
    expect(find.text('a31.jpg'), findsOneWidget, reason: 'B3:第二页内容拼接渲染');
    expect(
      find.textContaining('加载更多'),
      findsNothing,
      reason: 'B3:「加载更多」格子移除,改底部线性加载指示',
    );
  });

  // ── B4 日志横条移除 ─────────────────────────────────────────────────────
  testWidgets('B4:加载失败反馈不再渲染开发日志横条(调试信息不入产品 UI)', (tester) async {
    final api = _install();
    api.assets.page1 = [for (var i = 1; i <= 30; i++) fakeAsset('a$i')];
    api.assets.total = 33;
    api.assets.page2 = ApiException(500, '网络开小差');
    await _pumpAssetsPage(tester);

    for (var i = 0; i < 6; i++) {
      await tester.drag(find.byType(GridView), const Offset(0, -800));
      await tester.pumpAndSettle();
    }
    // 兼容触发路径:B3 未交付时滚到底不出加载,补点一次「加载更多」;
    // B3 交付后该格子不存在,条件为空操作。
    final more = find.textContaining('加载更多');
    if (tester.any(more)) {
      await tester.tap(more.first);
      await tester.pumpAndSettle();
    }

    // 失败反馈(现状=日志横条文案「加载更多失败:…」;B3 后=toast)
    // TODO(app-polish B4): 现状应失败(横条渲染「加载更多失败:…」),交付后转绿
    expect(
      find.textContaining('加载更多失败'),
      findsNothing,
      reason: 'B4:开发日志横条(_say→logLine)不得出现在产品 UI',
    );
    // 收尾:排空 SnackBar 计时器,避免悬挂 Timer 干扰测试收尾
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  // ── B6 UploadMiniBar 可点跳传输(shell 接线已交付,skip 占位接活)─────────
  testWidgets('B6:HomeShell 监听 shell:tab:transfers——广播即切传输 tab', (
    tester,
  ) async {
    installFakeApi();
    addTearDown(() {
      session.api = null;
      session.me = null;
    });
    await tester.pumpWidget(const MaterialApp(home: HomeShell()));
    await tester.pumpAndSettle();
    expect(
      tester.widget<IndexedStack>(find.byType(IndexedStack)).index,
      0,
      reason: '前置:默认项目 tab',
    );

    RefreshBus.I.invalidate('shell:tab:transfers');
    await tester.pump();
    expect(
      tester.widget<IndexedStack>(find.byType(IndexedStack)).index,
      2,
      reason: 'B6:广播 shell:tab:transfers → IndexedStack 切到传输 tab',
    );
    expect(
      tester.widget<AppTabBar>(find.byType(AppTabBar)).index,
      2,
      reason: 'B6:底部导航同步选中传输格',
    );
    // 卸载树确保 HomeShell dispose(注销监听+清 isInTree),不污染后续用例
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('B6:壳上推入页(宫格场景)点击 → 弹回 shell 且传输 tab 已选中,不叠页', (tester) async {
    installFakeApi();
    addTearDown(() {
      session.api = null;
      session.me = null;
    });
    await tester.pumpWidget(
      MaterialApp(
        onGenerateRoute: (s) => switch (s.name) {
          '/home' => MaterialPageRoute(builder: (_) => const HomeShell()),
          '/assets' => MaterialPageRoute(
            builder: (_) => Scaffold(
              body: Builder(
                builder: (ctx) => Center(
                  child: FilledButton(
                    // 宫格页迷你条点击的等效调用(openTransfersView)
                    onPressed: () => openTransfersView(ctx),
                    child: const Text('mini-bar'),
                  ),
                ),
              ),
            ),
          ),
          _ => null,
        },
        home: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              // 复现真实栈:/(入口)→ /home(shell)→ /assets(宫格,迷你条所在)
              onPressed: () {
                Navigator.of(ctx).pushNamed('/home');
                Navigator.of(ctx).pushNamed('/assets');
              },
              child: const Text('enter'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('enter'));
    await tester.pumpAndSettle();
    expect(find.text('mini-bar'), findsOneWidget, reason: '前置:已进推入页');
    expect(HomeShell.isInTree, isTrue, reason: '前置:shell 在树上(监听接管)');

    await tester.tap(find.text('mini-bar'));
    await tester.pumpAndSettle();
    expect(
      find.text('mini-bar'),
      findsNothing,
      reason: 'B6:shell 接管切 tab 并把推入页弹回(切换可见)',
    );
    expect(
      find.byType(TransfersPage),
      findsOneWidget,
      reason: 'B6:不叠页——传输页只有 shell IndexedStack 常驻那一个',
    );
    expect(
      tester.widget<AppTabBar>(find.byType(AppTabBar)).index,
      2,
      reason: 'B6:弹回后正显示传输 tab',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('B6:非 shell 上下文(无监听接管,如深链页)→ 保留 push 传输页兜底', (tester) async {
    expect(HomeShell.isInTree, isFalse, reason: '前置:无 shell(深链等非 shell 上下文)');
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => openTransfersView(ctx),
              child: const Text('mini-bar'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('mini-bar'));
    await tester.pumpAndSettle();
    expect(
      find.byType(TransfersPage),
      findsOneWidget,
      reason: 'B6:无 shell 接管时 push 传输页全屏路由兜底(返回即回原页)',
    );
  });

  // ── B7 缩略图文字 ───────────────────────────────────────────────────────
  testWidgets('B7:宫格块元信息字号 ≥11 且用 ink3(不再是旧 subtle 灰);'
      '元信息字号不大于文件名(层级不倒置)', (tester) async {
    final asset = fakeAsset('a1');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 120,
              height: 220,
              child: AssetGridTile(
                asset: asset,
                selected: false,
                selecting: false,
                onTap: () {},
                onLongPress: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final meta = tester.widget<Text>(find.textContaining('·'));
    final name = tester.widget<Text>(find.text('a1.jpg'));

    // TODO(app-polish B7): 现状应失败(元信息 fontSize=10),交付后转绿。
    // token 迁移后数值映射由包 A 定,这里只钉验收下限(需求:不小于 11px)。
    expect(
      meta.style?.fontSize ?? 0,
      greaterThanOrEqualTo(11),
      reason: 'B7:元信息字号从 10 提升到 ≥11',
    );
    // 颜色由 DefaultTextStyle 继承(Text 自身 style 只声明字号),取有效色。
    final metaColor = DefaultTextStyle.of(
      tester.element(find.textContaining('·')),
    ).style.color;
    expect(
      metaColor,
      TkColors.light.ink3,
      reason: 'B7:元信息有效色为 ink3(浅色主题),不再用旧 subtle 灰',
    );
    expect(
      (meta.style?.fontSize ?? 0) <= (name.style?.fontSize ?? 0),
      isTrue,
      reason: 'B7:视觉层级不倒置(元信息仍小于文件名)',
    );
  });
}
