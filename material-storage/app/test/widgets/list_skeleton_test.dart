/// ListSkeleton 基础 widget 测试(app-polish A9):列表形态行数、宫格形态
/// 行×列格子数、呼吸动画件挂载、无异常冒烟。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/widgets/list_skeleton.dart';

/// 私有骨件类型按名定位(测试与组件同批交付,名字即契约)。
Finder byPrivateName(String name) => find.byWidgetPredicate(
  (w) => w.runtimeType.toString() == name,
  skipOffstage: true,
);

void main() {
  testWidgets('列表形态(默认 6 行):6 个行骨 + 呼吸动画件', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ListSkeleton())),
    );
    expect(byPrivateName('_RowBone'), findsNWidgets(6));
    // 呼吸动画件挂在骨架自己的 Padding 下(MaterialApp 内部也有 FadeTransition,
    // 限定后代防误配)
    expect(
      find.descendant(
        of: find.byType(ListSkeleton),
        matching: find.byType(FadeTransition),
      ),
      findsOneWidget,
      reason: '呼吸闪烁挂载',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('行数参数生效:rows=3 → 3 个行骨', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ListSkeleton(rows: 3))),
    );
    expect(byPrivateName('_RowBone'), findsNWidgets(3));
  });

  testWidgets('宫格形态:columns=3、rows=2 → 6 个方块骨', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ListSkeleton(rows: 2, columns: 3)),
      ),
    );
    expect(byPrivateName('_CellBone'), findsNWidgets(6));
    expect(find.byType(GridView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced-motion:静态 0.7 透明度,不挂呼吸动画', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Scaffold(body: ListSkeleton(rows: 2)),
        ),
      ),
    );
    expect(byPrivateName('_RowBone'), findsNWidgets(2));
    expect(
      find.descendant(
        of: find.byType(ListSkeleton),
        matching: find.byType(FadeTransition),
      ),
      findsNothing,
      reason: 'disableAnimations 下不 repeat 呼吸动画',
    );
    final opacity = tester.widget<Opacity>(
      find.descendant(
        of: find.byType(ListSkeleton),
        matching: find.byType(Opacity),
      ),
    );
    expect(opacity.opacity, 0.7, reason: '静态 0.7 透明度');
    expect(tester.takeException(), isNull);
  });
}
