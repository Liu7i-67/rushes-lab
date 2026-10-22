/// PickerSheet/PickerField 组件基础测试(app-polish-2 I1,#6 表单下拉改弹层):
/// 点选即返回、搜索过滤(labelOf 包含匹配不分大小写)、取消返回 null、
/// 当前项高亮(对勾)、searchable:false 隐藏搜索框、PickerField 只读字段形态
/// (已选值+chevron+点击回调;空值显示 hint)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/widgets/pickers/picker_sheet.dart';

/// 挂一个「open」按钮,点击时执行 [onOpen](拿到的 ctx 在 Scaffold 下)。
Future<void> _host(WidgetTester tester, void Function(BuildContext) onOpen) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => onOpen(ctx),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));

void main() {
  testWidgets('点选条目即关闭并返回该值;当前项高亮(对勾)', (tester) async {
    Future<String?>? result;
    await _host(tester, (ctx) {
      result = showPickerSheet<String>(
        context: ctx,
        title: '选择项目',
        items: const ['项目一', '项目二', '项目三'],
        initial: '项目一',
        labelOf: (p) => p,
      );
    });
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('选择项目'), findsOneWidget);
    // 当前项高亮:initial 行带对勾(I1)
    expect(find.byIcon(Icons.check), findsOneWidget);

    await tester.tap(find.text('项目二'));
    await tester.pumpAndSettle();
    expect(await result, '项目二', reason: 'I1:点选即返回(选即关)');
    expect(find.text('选择项目'), findsNothing);
  });

  testWidgets('搜索过滤:labelOf 包含匹配不分大小写;命中后可选择', (tester) async {
    Future<String?>? result;
    await _host(tester, (ctx) {
      result = showPickerSheet<String>(
        context: ctx,
        title: '选择',
        items: const ['Alpha', 'beta', 'Gamma'],
        labelOf: (s) => s,
        searchTextHint: '搜索…',
      );
    });
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 不分大小写包含匹配
    await tester.enterText(find.widgetWithText(TextField, '搜索…'), 'AL');
    await tester.pump();
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('beta'), findsNothing);
    expect(find.text('Gamma'), findsNothing);

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(await result, 'Alpha');
  });

  testWidgets('无匹配展示空态;取消(关闭钮)返回 null', (tester) async {
    Future<String?>? result;
    await _host(tester, (ctx) {
      result = showPickerSheet<String>(
        context: ctx,
        title: '选择',
        items: const ['甲', '乙'],
        labelOf: (s) => s,
      );
    });
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, '搜索…'), '不存在的词');
    await tester.pump();
    expect(find.text('无匹配'), findsOneWidget, reason: '过滤无命中给空态,不留白屏');

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(await result, isNull, reason: '取消返回 null,调用方维持现状');
  });

  testWidgets('searchable:false 不渲染搜索框,直接列出全部条目', (tester) async {
    Future<String?>? result;
    await _host(tester, (ctx) {
      result = showPickerSheet<String>(
        context: ctx,
        title: '短列表',
        items: const ['A', 'B'],
        labelOf: (s) => s,
        searchable: false,
      );
    });
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing, reason: '不可搜索形态无搜索框');
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    expect(await result, 'B');
  });

  testWidgets('PickerField:展示已选值+chevron,点击触发 onTap;空值显示 hint',
      (tester) async {
    var tapped = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PickerField(label: '事件类型', value: '上传', onTap: () => tapped++),
      ),
    ));
    expect(find.widgetWithText(TextField, '上传'), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsOneWidget, reason: 'chevron 箭头');
    await tester.tap(find.byType(TextField));
    expect(tapped, 1, reason: '只读字段点击=打开弹层入口');

    // 空值 → hint(原下拉 hint 语义)
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PickerField(
            label: 'L', value: null, hint: '权限模板(可选)', onTap: () {}),
      ),
    ));
    await tester.pump();
    expect(find.widgetWithText(TextField, '权限模板(可选)'), findsOneWidget);
  });

  testWidgets('PickerOption:null 项与取消在返回值上可区分(可空项语义)',
      (tester) async {
    // 场景:T = PickerOption<String>,items 含 value=null 的「不使用」项
    Future<PickerOption<String>?>? result;
    await _host(tester, (ctx) {
      result = showPickerSheet<PickerOption<String>>(
        context: ctx,
        title: '模板',
        items: const [PickerOption<String>(null), PickerOption<String>('甲')],
        initial: const PickerOption<String>('甲'),
        labelOf: (o) => o.value == null ? '不使用' : o.value!,
      );
    });
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 选中「不使用」(value=null)→ 返回非 null option、其 value 为 null
    await tester.tap(find.text('不使用'));
    await tester.pumpAndSettle();
    final picked = await result;
    expect(picked, isNotNull, reason: '选中 null 项 ≠ 取消(可区分)');
    expect(picked!.value, isNull);
  });
}
