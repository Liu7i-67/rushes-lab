/// FastScrollBar 组件级验收(F2 快速滚动条;qdev 2026-11-24 app-fast-scroll
/// 专职测试补充,按需保留;开发测试均为页面级,组件几何/气泡口径未覆盖):
/// - hasClients=false(controller 未挂载)build/拖动不抛错,onSeek 仍回调;
/// - 气泡「~N / M」:f=0.5 精确文本、非整点取整口径(round)、顶/底 clamp;
/// - thumb 高度:超大列表最小 40 生效;中等列表按 viewport/maxExtent 比例;
/// - 热区 28 / 视觉条 4;右缘内 14dp 手势可命中(实时 jumpTo 跟手);
/// - thumb 位置随列表滚动实时跟随(单调映射)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/widgets/fast_scroll_bar.dart';

/// thumb 容器(宽 6 把手)。
Finder _thumb() => find.byWidgetPredicate(
  (w) => w is Container && w.constraints?.maxWidth == 6,
);

/// 视觉轨道(宽 4 的 SizedBox;Container 只有 decoration 无显式尺寸)。
Finder _track() =>
    find.byWidgetPredicate((w) => w is SizedBox && w.width == 4);

/// 最小宿主:600 高视口 ListView(itemExtent 定高,maxExtent 可精确预算)
/// + 右缘 FastScrollBar(total 与列表条数解耦,气泡口径独立验证)。
Widget _host(
  ScrollController controller, {
  int listItems = 100,
  double itemExtent = 100,
  int total = 1000,
  void Function(int)? onSeek,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Stack(
        children: [
          ListView.builder(
            controller: controller,
            itemExtent: itemExtent,
            itemCount: listItems,
            itemBuilder: (_, i) => Text('item $i'),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: FastScrollBar(
              controller: controller,
              total: total,
              visible: true,
              onSeek: onSeek,
            ),
          ),
        ],
      ),
    ),
  );
}

/// 把滚动条拖到轨道比例 f(自 40dp 外进入越过触摸 slop,onStart 落在目标 dy)。
/// [fromBelow]=从下方接近(f≈0 用);默认从上方接近(f=1 时必须从上方)。
/// [release]=false 时保持按住返回(气泡只在拖动中存在,供中途断言),
/// 由调用方自行 `g.up()`——返回值即手势句柄。
Future<TestGesture> _dragToF(
  WidgetTester tester,
  double f, {
  bool fromBelow = false,
  bool release = true,
  int total = 1000,
  int listItems = 100,
}) async {
  final rect = tester.getRect(find.byType(FastScrollBar));
  // 600 视口 ListView:trackH = boxH-20;thumbH = clamp(580*600/maxExtent,40)
  final maxExtent = listItems * 100 - 600;
  final trackH = rect.height - 20;
  final thumbH = (trackH * 600 / maxExtent).clamp(40.0, trackH);
  final dy = 10 + thumbH / 2 + f * (trackH - thumbH);
  const approach = 40.0;
  final g = await tester.startGesture(
    Offset(rect.left + 14, rect.top + (fromBelow ? dy + approach : dy - approach)),
  );
  await g.moveBy(Offset(0, fromBelow ? -approach : approach));
  await tester.pump();
  await tester.pump();
  if (release) {
    await g.up();
    await tester.pump();
  }
  return g;
}

void main() {
  testWidgets('hasClients=false:build/手势不抛错,thumb 不渲染,onSeek 仍回调', (tester) async {
    final controller = ScrollController(); // 未挂任何滚动视口
    var seeked = -1;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: FastScrollBar(
                  controller: controller,
                  total: 1000,
                  visible: true,
                  onSeek: (i) => seeked = i,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull, reason: '未挂载时 build 不抛错');
    expect(_thumb(), findsNothing, reason: 'hasClients=false 不渲染 thumb');
    expect(controller.hasClients, isFalse);

    // 拖动:不 jumpTo(守卫 maxExtent>0),但 f 计算与 onSeek 正常
    final rect = tester.getRect(find.byType(FastScrollBar));
    final g = await tester.startGesture(Offset(rect.left + 14, rect.top + 300));
    await g.moveBy(const Offset(0, 40));
    await tester.pump();
    expect(tester.takeException(), isNull, reason: '未挂载时拖动不抛错(jumpTo 被守卫)');
    expect(find.byWidgetPredicate((w) => w is Text && (w.data ?? '').startsWith('~')),
        findsOneWidget, reason: '拖动中气泡照常显示');
    await g.up();
    await tester.pump();
    expect(seeked, inInclusiveRange(0, 999), reason: 'onSeek 仍回调且 clamp 到 [0,total-1]');
    expect(controller.hasClients, isFalse, reason: '全程未触发 jumpTo');
  });

  testWidgets('气泡精确文本:f=0.5 → 「~500 / 1000」;松手消失', (tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(_host(controller));
    await tester.pump();
    final g = await _dragToF(tester, 0.5, release: false);
    expect(find.text('~500 / 1000'), findsOneWidget, reason: 'D3:气泡格式与取数');
    // 气泡在视口内(不越屏)
    final bubbleRect = tester.getRect(find.text('~500 / 1000'));
    expect(bubbleRect.top, greaterThanOrEqualTo(0));
    expect(bubbleRect.bottom, lessThanOrEqualTo(600));
    await g.up(); // 松手
    await tester.pump();
    expect(find.text('~500 / 1000'), findsNothing, reason: '松手气泡消失');
  });

  testWidgets('非整点取整口径:round(f=0.5×201=100.5 → 101,非 floor 100)', (tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(_host(controller, total: 201));
    await tester.pump();
    final g = await _dragToF(tester, 0.5, release: false, total: 201);
    expect(
      find.text('~101 / 201'),
      findsOneWidget,
      reason: '口径钉死:实现用 round()(口径与用例清单 T17 默认 floor 不同,须回写需求)',
    );
    await g.up();
    await tester.pump();
  });

  testWidgets('气泡顶/底端 clamp:顶端 ~0;底端 ~total-1(非 ~total),均在视口内', (tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(_host(controller));
    await tester.pump();
    var g = await _dragToF(tester, 0.0, fromBelow: true, release: false);
    expect(find.text('~0 / 1000'), findsOneWidget, reason: '顶端 f=0');
    var rect = tester.getRect(find.text('~0 / 1000'));
    expect(rect.top, greaterThanOrEqualTo(0), reason: '顶端不出屏');
    expect(rect.bottom, lessThanOrEqualTo(600));
    await g.up();
    await tester.pump();

    g = await _dragToF(tester, 1.0, release: false);
    expect(
      find.text('~999 / 1000'),
      findsOneWidget,
      reason: '底端 clamp 到 total-1(用例清单 T17-3 钉死「~1000 / 1000」,实现取 total-1,口径须回写)',
    );
    rect = tester.getRect(find.text('~999 / 1000'));
    expect(rect.bottom, lessThanOrEqualTo(600), reason: '底端不出屏');
    await g.up();
    await tester.pump();
  });

  testWidgets('thumb 最小 40:超大列表(比例值<40)不被压瘪', (tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(_host(controller, listItems: 20000, total: 20000));
    await tester.pump();
    expect(_thumb(), findsOneWidget);
    expect(tester.getSize(_thumb().first).height, 40, reason: 'T18:最小 40 生效');
  });

  testWidgets('thumb 比例映射:120×70 列表 → ≈44.6(不被 40 clamp)', (tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(
      _host(controller, listItems: 120, itemExtent: 70, total: 120),
    );
    await tester.pump();
    expect(_thumb(), findsOneWidget);
    final h = tester.getSize(_thumb().first).height;
    expect(h, greaterThan(40), reason: '比例值 >40 不被最小值钳制');
    expect(h, closeTo(580 * 600 / (120 * 70 - 600), 2), reason: 'T18:按 viewport/maxExtent 比例');
  });

  testWidgets('热区 28 / 视觉条 4;右缘内 14dp 手势命中并实时跟手', (tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(_host(controller));
    await tester.pump();
    expect(tester.getSize(find.byType(FastScrollBar)).width, 28, reason: '≥28dp 热区');
    expect(_track(), findsOneWidget);
    expect(tester.getSize(_track().first).width, 4, reason: '视觉条 ~4dp');

    // 右缘内 14dp 处起手势(热区中心),向下拖 → 列表实时 jumpTo 跟手
    final rect = tester.getRect(find.byType(FastScrollBar));
    final before = controller.offset;
    final g = await tester.startGesture(Offset(rect.left + 14, rect.top + 200));
    await g.moveBy(const Offset(0, 200));
    await tester.pump();
    expect(controller.offset, greaterThan(before), reason: 'F2:拖动实时跟手(jumpTo)');
    await g.up();
    await tester.pump();
  });

  testWidgets('thumb 实时跟随:jumpTo 后位置单调映射(f×(trackH-thumbH))', (tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(_host(controller));
    await tester.pump();
    controller.jumpTo(1000);
    await tester.pump();
    final top1 = tester.getTopLeft(_thumb().first).dy;
    controller.jumpTo(5000);
    await tester.pump();
    final top2 = tester.getTopLeft(_thumb().first).dy;
    expect(top2, greaterThan(top1), reason: '向下滚动 thumb 单调下移');
    // 轨道 top=10,thumbH=40:top = 10 + f×540(f=pixels/9400)
    expect(top1, closeTo(10 + (1000 / 9400) * 540, 2), reason: '位置=f 线性映射');
    expect(top2, closeTo(10 + (5000 / 9400) * 540, 2));
  });
}
