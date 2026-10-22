/// SheetScaffold/showAppSheet 基础 widget 测试(app-polish A4):
/// 标题/关闭钮渲染与 pop(null)、子内容 pop 结果透传、错误文案行、
/// 吸底按钮区不随内容滚动(长内容走滚动区)、键盘避让 padding。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/widgets/sheet_scaffold.dart';

void main() {
  /// 挂一个「open」按钮,点击时执行 [onOpen](拿到的 ctx 在 Scaffold 下)。
  Future<void> host(WidgetTester tester, void Function(BuildContext) onOpen) =>
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

  testWidgets('showAppSheet 标题/内容渲染;关闭钮 pop(null) 透传', (tester) async {
    Future<bool?>? result;
    await host(tester, (ctx) {
      result = showAppSheet<bool>(
        context: ctx,
        title: '选择目标',
        child: const Text('内容区'),
      );
    });
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('选择目标'), findsOneWidget);
    expect(find.text('内容区'), findsOneWidget);
    // 标题行带关闭钮
    expect(find.byTooltip('关闭'), findsOneWidget);
    // app-polish-2 #5 关闭可见性:图标放大 22→24 + 点击区加大(视觉微调)
    expect(tester.widget<Icon>(find.byIcon(Icons.close)).size, 24);

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(await result, isNull, reason: '关闭钮=pop(null)');
    expect(find.text('选择目标'), findsNothing);
  });

  testWidgets('子内容 Navigator.pop(结果) 经 showAppSheet 透传返回', (tester) async {
    Future<String?>? result;
    await host(tester, (ctx) {
      result = showAppSheet<String>(
        context: ctx,
        title: '表单',
        child: Builder(
          builder: (inner) => TextButton(
            onPressed: () => Navigator.of(inner).pop('done'),
            child: const Text('提交并关闭'),
          ),
        ),
      );
    });
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('提交并关闭'));
    await tester.pumpAndSettle();
    expect(await result, 'done', reason: '返回值透传(兼容存量 bool/结果约定)');
  });

  testWidgets('errorText 渲染在标题下;无 error 不渲染错误行', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SheetScaffold(title: '标题', errorText: '名称不能为空', child: Text('x')),
      ),
    ));
    expect(find.text('名称不能为空'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SheetScaffold(title: '标题', child: Text('x'))),
    ));
    expect(find.text('名称不能为空'), findsNothing);
  });

  testWidgets('长内容走滚动区;吸底按钮不随内容滚动', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SheetScaffold(
          title: '长表单',
          bottomActions: [FilledButton(onPressed: null, child: Text('保存'))],
          child: SizedBox(height: 2000, child: Text('很高内容')),
        ),
      ),
    ));

    expect(find.text('保存'), findsOneWidget);
    final saveCenter = tester.getCenter(find.text('保存'));
    expect(saveCenter.dy, greaterThan(450), reason: '吸底按钮区贴近底部');

    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -300));
    await tester.pump();
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(scrollable.position.pixels, greaterThan(0), reason: '长内容可滚动');
    // 滚动后吸底按钮仍在原位(不随内容滚走)
    expect(tester.getCenter(find.text('保存')).dy, saveCenter.dy);
  });

  testWidgets('键盘避让:viewInsets.bottom 转为骨架底部 padding', (tester) async {
    // 内层 MediaQuery 放 Scaffold body 内(Scaffold 会吞 body 的 viewInsets,
    // 真实调用位是 modal 路由 overlay 不经 Scaffold;此处只验组件读数契约)
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MediaQuery(
          data: const MediaQueryData(viewInsets: EdgeInsets.only(bottom: 200)),
          child: const SheetScaffold(title: 'T', child: Text('x')),
        ),
      ),
    ));
    final bottoms = tester
        .widgetList<Padding>(find.byWidgetPredicate(
            (w) => w is Padding && w.padding is EdgeInsets))
        .map((p) => p.padding as EdgeInsets)
        .toList();
    expect(bottoms, contains(const EdgeInsets.only(bottom: 200)),
        reason: '键盘顶起弹层(A4 键盘避让)');
  });

  testWidgets('无标题短菜单形态:不渲染标题行,内容自适应', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SheetScaffold(child: Text('菜单项'))),
    ));
    expect(find.byTooltip('关闭'), findsNothing, reason: '无标题无关闭钮');
    expect(find.text('菜单项'), findsOneWidget);
  });
}
