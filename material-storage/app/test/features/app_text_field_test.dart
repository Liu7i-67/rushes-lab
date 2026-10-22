/// AppTextField(app-polish-3 测试功能点 7,D6/E1):浮起 label 裁切回归钉——
/// decoration 不得 isDense(isDense:false 显式)、contentPadding 垂直 ≥12;
/// maxLength 计数器在场;「高级」折叠场景等价复现:展开后
/// 「MinIO bucket(必填)」label 完整在场且无 overflow 异常
/// (真机 0.1.2+6 用户抱怨:浮起标签只显示下半截)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/widgets/form_text_field.dart';

void main() {
  testWidgets('功能点 7:decoration 无 isDense、contentPadding 垂直 ≥12'
      '(裁切根因钉死)', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: AppTextField(label: '项目名称', hint: '输入项目名称'),
      ),
    ));
    await tester.pumpAndSettle();

    // TextFormField 不直接暴露 decoration,读其构建的 TextField
    final deco = tester.widget<TextField>(
      find.byType(TextField),
    ).decoration!;

    expect(deco.isDense, isNot(true),
        reason: 'D6:isDense 在 filled+outline 下压扁竖向内边距,浮起 label 上半截'
            '被裁——AppTextField 必须显式 isDense:false');
    expect(deco.contentPadding, isNotNull);
    expect(deco.contentPadding!.vertical, greaterThanOrEqualTo(12),
        reason: 'D6:竖向 contentPadding ≥ 12(统一 12/12)保住浮起 label 高度');
    expect(find.text('项目名称'), findsOneWidget, reason: 'label 完整在场');
  });

  testWidgets('功能点 7:maxLength 计数器出现且随输入更新(n/max)',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: AppTextField(label: '项目编码', maxLength: 5),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('0/5'), findsOneWidget, reason: '带 maxLength 时计数器在场');

    await tester.enterText(find.byType(TextFormField), 'abcdefgh');
    await tester.pumpAndSettle();

    expect(find.text('5/5'), findsOneWidget,
        reason: '输入超长按 maxLength 截断,计数器同步(63 字符 bucket 同机制)');
  });

  testWidgets('功能点 7:「高级」折叠展开后 MinIO bucket(必填) label 完整在场,'
      '无 overflow 异常(真机 0.1.2+6 回归场景等价复现)', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 等价复现生产形态:主题 filled:true(app_theme.dart inputDecorationTheme)
    // + OutlineInputBorder 组合——旧实现 isDense 在此组合下裁掉浮起 label 上半截
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          border: OutlineInputBorder(),
        ),
      ),
      home: Scaffold(
        body: ListView(
          children: [
            ExpansionTile(
              title: const Text('高级'),
              children: [
                const AppTextField(label: 'MinIO bucket(必填)'),
              ],
            ),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '折叠收起态无异常');

    await tester.tap(find.text('高级'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: 'D6:展开渲染不得抛 overflow(裁切修复的异常级断言)');
    expect(find.text('MinIO bucket(必填)'), findsOneWidget,
        reason: '浮起 label 完整在场(旧实现只显示下半截)');
    expect(find.byType(AppTextField), findsOneWidget);

    // TextFormField 不直接暴露 decoration,读其构建的 TextField
    final deco = tester.widget<TextField>(
      find.byType(TextField),
    ).decoration!;
    expect(deco.isDense, isNot(true),
        reason: '「高级」场景同走去 isDense 口径');
  });
}
