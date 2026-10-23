/// RoleChips 组件测试(§6 F3 / §11.4):FilterChip 选中态金浅底/金边/金字,
/// 点击回调集合,取消选中;hint 文案颜色随空/非空变化。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/theme/app_theme.dart';
import 'package:ms_app/theme/tk_colors.dart';
import 'package:ms_app/widgets/role_chips.dart';

void main() {
  Future<Set<String>> host(
    WidgetTester tester, {
    Set<String> initial = const <String>{},
  }) async {
    var value = initial;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => RoleChips(
              value: value,
              onChanged: (next) => setState(() => value = next),
            ),
          ),
        ),
      ),
    );
    return value;
  }

  FilterChip chipOf(WidgetTester tester, String label) =>
      tester.widget<FilterChip>(find.widgetWithText(FilterChip, label));

  testWidgets('未选:hint warn 色;点选后金浅底+金边+金字,已选文案更新', (tester) async {
    await host(tester);
    final tk = TkColors.light;

    expect(find.text('至少勾选一个角色'), findsOneWidget);
    expect(tester.widget<Text>(find.text('至少勾选一个角色')).style!.color, tk.warn);
    expect(chipOf(tester, '管理').selected, isFalse);

    await tester.tap(find.widgetWithText(FilterChip, '管理'));
    await tester.pumpAndSettle();

    final chip = chipOf(tester, '管理');
    expect(chip.selected, isTrue, reason: '选中态生效');
    expect(chip.selectedColor, tk.goldSoft, reason: '金浅底');
    expect(chip.side!.color, tk.gold, reason: '金边');
    expect(chip.labelStyle!.color, tk.goldInk, reason: '金字');
    expect(find.textContaining('已选:管理'), findsOneWidget);
    expect(find.textContaining('管理:全部权限'), findsOneWidget);
  });

  testWidgets('多选与取消:onChanged 集合正确', (tester) async {
    final initial = await host(tester);
    expect(initial, isEmpty);

    await tester.tap(find.widgetWithText(FilterChip, '上传'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选:上传'), findsOneWidget);
    expect(find.textContaining('上传:传文件'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, '查看'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选:上传 + 查看'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, '上传'));
    await tester.pumpAndSettle();
    expect(chipOf(tester, '上传').selected, isFalse, reason: '再点取消');
    expect(find.textContaining('已选:查看'), findsOneWidget);
  });
}
