/// SearchField 基础 widget 测试(app-polish A7):主题圆角不覆盖、清除钮
/// 随文字显隐并回清+onChanged('')、onSubmitted 通道、外部 controller 同步。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/theme/app_theme.dart';
import 'package:ms_app/widgets/search_field.dart';

void main() {
  Future<void> host(
    WidgetTester tester, {
    TextEditingController? controller,
    String? hint,
    ValueChanged<String>? onChanged,
    ValueChanged<String>? onSubmitted,
  }) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SearchField(
            controller: controller,
            hintText: hint,
            onChanged: onChanged,
            onSubmitted: onSubmitted,
          ),
        ),
      ));

  testWidgets('hint 渲染;无文字无清除钮;输入后出现清除钮且 onChanged 透传',
      (tester) async {
    final changed = <String>[];
    await host(tester, hint: '搜索资产', onChanged: changed.add);
    expect(find.text('搜索资产'), findsOneWidget);
    expect(find.byTooltip('清除'), findsNothing);

    await tester.enterText(find.byType(TextField), 'ab');
    await tester.pump();
    expect(changed, ['ab'], reason: 'onChanged 双通道');
    expect(find.byTooltip('清除'), findsOneWidget);
  });

  testWidgets('点清除:文字清空、onChanged(\'\')、清除钮消失', (tester) async {
    final changed = <String>[];
    final controller = TextEditingController();
    await host(tester, controller: controller, onChanged: changed.add);
    await tester.enterText(find.byType(TextField), 'kw');
    await tester.pump();
    expect(find.byTooltip('清除'), findsOneWidget);

    await tester.tap(find.byTooltip('清除'));
    await tester.pump();
    expect(controller.text, isEmpty);
    expect(changed.last, '', reason: '清除通知空串(搜索页据此复位)');
    expect(find.byTooltip('清除'), findsNothing);
  });

  testWidgets('键盘提交走 onSubmitted(search action)', (tester) async {
    var submitted = '';
    await host(tester, onSubmitted: (v) => submitted = v);
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(submitted, 'abc');
  });

  testWidgets('外部 controller 带初始值:清除钮直接可见(监听同步)',
      (tester) async {
    final controller = TextEditingController(text: 'pre');
    await host(tester, controller: controller);
    expect(find.byTooltip('清除'), findsOneWidget, reason: '初始文字→清除钮可见');

    // 外部清空 controller(不经组件),清除钮同步消失
    controller.clear();
    await tester.pump();
    expect(find.byTooltip('清除'), findsNothing);
  });

  testWidgets('圆角走主题(12 输入档),组件不覆盖 border', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: const Scaffold(body: SearchField()),
    ));
    final deco =
        tester.widget<TextField>(find.byType(TextField)).decoration!;
    expect(deco.border, isNull, reason: '不覆盖主题边框(圆角由主题输入档决定)');
    final themeBorder = Theme.of(tester.element(find.byType(TextField)))
        .inputDecorationTheme.border! as OutlineInputBorder;
    expect(themeBorder.borderRadius, BorderRadius.circular(12),
        reason: 'A3 输入档 rMd=12');
  });
}
