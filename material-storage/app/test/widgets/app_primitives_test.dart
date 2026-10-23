/// 布局原语单测(WP0b §6 F3):AppCard/SectionCard/SectionLabel/PageHeader/
/// AppRow/AppChip/AppSegmented/StatRow/AssetPlate。全部挂 buildAppTheme,
/// 避免 context.tk 兜底掩盖主题缺省问题。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/theme/app_theme.dart';
import 'package:ms_app/theme/tk_colors.dart';
import 'package:ms_app/theme/tokens.dart';
import 'package:ms_app/widgets/app_card.dart';
import 'package:ms_app/widgets/app_chip.dart';
import 'package:ms_app/widgets/app_row.dart';
import 'package:ms_app/widgets/app_segmented.dart';
import 'package:ms_app/widgets/asset_plate.dart';
import 'package:ms_app/widgets/page_header.dart';
import 'package:ms_app/widgets/section_label.dart';
import 'package:ms_app/widgets/stat_row.dart';

Widget host(Widget child, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: buildAppTheme(brightness),
      home: Scaffold(body: child),
    );

Future<void> pump(
  WidgetTester t,
  Widget w, [
  Brightness b = Brightness.light,
]) => t.pumpWidget(host(w, brightness: b));

Finder desc(Finder of, Type t) =>
    find.descendant(of: of, matching: find.byType(t));

BoxDecoration deco(Widget w) {
  final decoration = w is AnimatedContainer
      ? w.decoration
      : (w as Container).decoration;
  return decoration! as BoxDecoration;
}

Widget plate({int seed = 0, bool showNumber = true, Widget? child}) => Center(
  child: SizedBox.square(
    dimension: 100,
    child: AssetPlate(seed: seed, showNumber: showNumber, child: child),
  ),
);

extension on WidgetTester {
  Text text(String s) => widget<Text>(find.text(s));

  Container boxIn(Finder of) => widget<Container>(desc(of, Container).first);

  bool selectedIn(Finder of) =>
      widget<Semantics>(desc(of, Semantics).first).properties.selected!;

  Color? iconColorIn(Finder of) =>
      widget<IconTheme>(desc(of, IconTheme).first).data.color;
}

void main() {
  testWidgets('AppCard / SectionCard', (tester) async {
    var taps = 0;
    await pump(tester, AppCard(onTap: () => taps++, child: const Text('卡片')));
    final d = deco(tester.boxIn(find.byType(AppCard)));
    expect(d.color, TkColors.light.surface);
    expect((d.border! as Border).top.color, TkColors.light.line);
    expect(d.borderRadius, BorderRadius.circular(Tk.rMd));
    expect(d.boxShadow, TkColors.light.shadow1);
    await tester.tap(find.byType(AppCard));
    expect(taps, 1);

    const rows = [AppRow(title: '一'), AppRow(title: '二'), AppRow(title: '三')];
    await pump(tester, const SectionCard(dividerIndent: 14, children: rows));
    final ds = tester.widgetList<Divider>(find.byType(Divider)).toList();
    expect(ds.length, 2);
    expect(ds.first.color, TkColors.light.line);
    expect(ds.first.indent, 14);
  });

  testWidgets('AppCard 长按回调(P2-10)', (tester) async {
    var longs = 0;
    await pump(
      tester,
      AppCard(onLongPress: () => longs++, child: const Text('长按卡')),
    );
    await tester.longPress(find.byType(AppCard));
    expect(longs, 1, reason: 'P2-10:AppCard 暴露 onLongPress 供 ProjectCard 复用');
  });

  testWidgets('SectionLabel', (tester) async {
    await pump(tester, const SectionLabel(title: '目录', hint: '共 3 项'));
    final title = tester.text('目录').style!;
    expect(title.fontSize, Tk.fzXs);
    expect(title.fontWeight, FontWeight.w600);
    expect(title.letterSpacing, 1.1);
    expect(title.color, TkColors.light.ink3);
    expect(tester.text('共 3 项').style!.fontSize, Tk.fzMd);
    expect(tester.text('共 3 项').style!.color, TkColors.light.ink3);
  });

  testWidgets('PageHeader 大标题/二级页', (tester) async {
    await pump(
      tester,
      const PageHeader(
        title: '项目',
        count: '12',
        subtitle: '进行中的项目',
        actions: [Icon(Icons.add)],
      ),
    );
    final title = tester.text('项目');
    expect(title.style!.fontSize, Tk.fzDisplay);
    expect(title.style!.fontWeight, FontWeight.w600);
    expect(title.style!.color, TkColors.light.ink);
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);
    expect(tester.text('12').style!.fontSize, Tk.fzMd);
    expect(tester.text('12').style!.color, TkColors.light.ink3);
    expect(find.text('进行中的项目'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.byTooltip('返回'), findsNothing);

    var backs = 0;
    await pump(
      tester,
      PageHeader(title: '通知', back: true, onBack: () => backs++),
    );
    expect(tester.text('通知').style!.fontSize, Tk.fzTitle);
    expect(tester.text('通知').style!.fontWeight, FontWeight.w600);
    await tester.tap(find.byTooltip('返回'));
    expect(backs, 1);
  });

  testWidgets('AppRow 标题/副标题/chevron/trailing', (tester) async {
    await pump(
      tester,
      AppRow(title: '外观', subtitle: '跟随系统 · 深色', onTap: () {}),
    );
    final title = tester.text('外观');
    expect(title.style!.fontSize, Tk.fzRowTitle);
    expect(title.style!.fontWeight, FontWeight.w500);
    expect(title.style!.color, TkColors.light.ink);
    expect(tester.text('跟随系统 · 深色').style!.color, TkColors.light.ink3);
    final chevron = tester.widget<Icon>(find.byIcon(Icons.chevron_right));
    expect(chevron.size, 18);
    expect(chevron.color, TkColors.light.ink3);

    await pump(tester, const AppRow(title: 'a', trailing: SizedBox.shrink()));
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    await pump(tester, AppRow(title: 'b', onTap: () {}, showChevron: false));
    expect(find.byIcon(Icons.chevron_right), findsNothing);
  });

  testWidgets('AppRow Icon leading 34×34 + goldIcon', (tester) async {
    const lead = Icon(Icons.notifications);
    await pump(tester, const AppRow(title: '通知', leading: lead));
    final normal = tester.boxIn(find.byType(AppRow));
    expect(normal.constraints!.maxWidth, 34);
    expect(normal.constraints!.maxHeight, 34);
    expect(deco(normal).color, TkColors.light.surface3);

    await pump(
      tester,
      const AppRow(title: '通知', leading: lead, goldIcon: true),
    );
    expect(
      deco(tester.boxIn(find.byType(AppRow))).color,
      TkColors.light.goldSoft,
    );
    expect(tester.iconColorIn(find.byType(AppRow)), TkColors.light.goldInk);
  });

  testWidgets('AppChip 选中/未选中', (tester) async {
    await pump(tester, const AppChip(label: '图片', selected: true));
    final selected = tester.widget<Material>(
      desc(find.byType(AppChip), Material),
    );
    expect(selected.color, TkColors.light.goldSoft);
    expect(
      (selected.shape! as RoundedRectangleBorder).side.color,
      TkColors.light.gold,
    );
    expect(tester.text('图片').style!.color, TkColors.light.goldInk);
    expect(tester.text('图片').style!.fontWeight, FontWeight.w600);
    expect(tester.selectedIn(find.byType(AppChip)), isTrue);

    var taps = 0;
    await pump(
      tester,
      AppChip(label: '全部', icon: Icons.grid_view, onTap: () => taps++),
    );
    final normal = tester.widget<Material>(
      desc(find.byType(AppChip), Material),
    );
    expect(normal.color, TkColors.light.surface2);
    expect(
      (normal.shape! as RoundedRectangleBorder).side.color,
      TkColors.light.controlBorder,
      reason: 'P1-1:未选中 chip 用可交互描边 controlBorder(≥3:1)',
    );
    expect(tester.text('全部').style!.color, TkColors.light.ink2);
    expect(tester.text('全部').style!.fontWeight, FontWeight.w500);
    expect(tester.widget<Icon>(find.byIcon(Icons.grid_view)).size, 14);
    await tester.tap(find.text('全部'));
    expect(taps, 1);
  });

  testWidgets('AppSegmented 切换/滑块/计数', (tester) async {
    var value = 'all';
    await pump(
      tester,
      StatefulBuilder(
        builder: (context, setState) => AppSegmented<String>(
          segments: const [
            Segment(value: 'all', label: '全部', count: 5),
            Segment(value: 'up', label: '上传'),
            Segment(value: 'down', label: '下载'),
          ],
          value: value,
          onChanged: (v) => setState(() => value = v),
        ),
      ),
    );
    expect(
      deco(tester.boxIn(find.byType(AppSegmented<String>))).color,
      TkColors.light.surface3,
    );
    expect(tester.text('5').style!.fontSize, Tk.fzMd);
    expect(
      tester.text('5').style!.color,
      TkColors.light.ink2,
      reason: 'P1-2:计数 ink2,选中滑块(surface4)上 ≥4.5:1',
    );
    var boxes = tester
        .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
        .toList();
    expect(deco(boxes.first).color, TkColors.light.surface4);

    await tester.tap(find.text('上传'));
    await tester.pumpAndSettle();
    expect(value, 'up');
    boxes = tester
        .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
        .toList();
    expect(deco(boxes.first).color, Colors.transparent);
    expect(deco(boxes[1]).color, TkColors.light.surface4);
  });

  testWidgets('AppSegmented 计数深色同样 ink2(P1-2)', (tester) async {
    await pump(
      tester,
      AppSegmented<String>(
        segments: const [Segment(value: 'all', label: '全部', count: 5)],
        value: 'all',
        onChanged: (_) {},
      ),
      Brightness.dark,
    );
    expect(tester.text('5').style!.fontSize, Tk.fzMd);
    expect(tester.text('5').style!.color, TkColors.dark.ink2);
  });

  testWidgets('StatRow 数字/标签/分隔/点击', (tester) async {
    var taps = 0;
    await pump(
      tester,
      StatRow(
        items: [
          const StatItem(value: '12', label: '项目'),
          StatItem(value: '486', label: '素材', onTap: () => taps++),
          const StatItem(value: '3', label: '待审'),
        ],
      ),
    );
    expect(tester.text('12').style!.fontSize, Tk.fzStat);
    expect(tester.text('12').style!.fontWeight, FontWeight.w600);
    expect(tester.text('12').style!.color, TkColors.light.ink);
    final label = tester.text('项目').style!;
    expect(label.fontSize, 11.5);
    expect(label.letterSpacing, 0.46);
    expect(label.color, TkColors.light.ink3);
    expect(
      find.descendant(
        of: find.byType(StatRow),
        matching: find.byWidgetPredicate((w) => w is SizedBox && w.width == 1),
      ),
      findsNWidgets(2),
    );
    expect(deco(tester.boxIn(find.byType(StatRow))).color, TkColors.light.line);
    await tester.tap(find.text('486'));
    expect(taps, 1);
  });

  testWidgets('AssetPlate 编号/画笔/child/深色', (tester) async {
    await pump(tester, plate(seed: 2));
    final number = tester.text('003').style!;
    expect(number.fontSize, 10.5);
    expect(number.letterSpacing, 1.26);
    expect(number.color, Tk.previewFg.withValues(alpha: 0.6));
    final paints = tester
        .widgetList<CustomPaint>(desc(find.byType(AssetPlate), CustomPaint))
        .toList();
    expect(paints.single.painter, isNotNull);
    expect(desc(find.byType(AssetPlate), RepaintBoundary), findsOneWidget);

    await pump(
      tester,
      plate(showNumber: false, child: const Icon(Icons.image_outlined)),
    );
    expect(find.text('001'), findsNothing);
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    await pump(tester, plate(), Brightness.dark);
    expect(
      tester.text('001').style!.color,
      Tk.previewFg.withValues(alpha: 0.6),
    );
  });
}
