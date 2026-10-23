/// EmptyState 组件测试(§6 F3 / §11.4):message 兼容为标题、title+message
/// 双行、可选主操作回调、56 圆底图标、字号/颜色。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/theme/app_theme.dart';
import 'package:ms_app/theme/tk_colors.dart';
import 'package:ms_app/widgets/empty_state.dart';

void main() {
  Future<void> host(WidgetTester tester, EmptyState state) => tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      home: Scaffold(body: state),
    ),
  );

  testWidgets('仅 message:作为 16/w600/ink 标题,图标 56 圆底 + 26', (tester) async {
    await host(tester, const EmptyState(message: '暂无可见项目'));
    final tk = TkColors.dark;

    final heading = tester.widget<Text>(find.text('暂无可见项目')).style!;
    expect(heading.fontSize, 16);
    expect(heading.fontWeight, FontWeight.w600);
    expect(heading.color, tk.ink);

    final icon = tester.widget<Icon>(find.byIcon(Icons.inbox_outlined));
    expect(icon.color, tk.ink3);
    expect(icon.size, 26);
    final circleFinder = find
        .ancestor(
          of: find.byIcon(Icons.inbox_outlined),
          matching: find.byType(Container),
        )
        .first;
    final circle = tester.widget<Container>(circleFinder);
    expect(tester.getSize(circleFinder).width, 56);
    expect((circle.decoration! as BoxDecoration).color, tk.surface3);
  });

  testWidgets('title + message:message 作为说明仍可 find;description 追加', (
    tester,
  ) async {
    await host(
      tester,
      const EmptyState(
        icon: Icons.image_outlined,
        title: '暂无素材',
        message: '上传第一个素材开始',
        description: '支持图片 / 视频 / PDF',
      ),
    );
    final tk = TkColors.dark;

    expect(find.text('暂无素材'), findsOneWidget);
    expect(
      find.text('上传第一个素材开始'),
      findsOneWidget,
      reason: 'title 非空时 message 作为说明显示(既有测试兼容)',
    );
    expect(find.text('支持图片 / 视频 / PDF'), findsOneWidget);
    expect(tester.widget<Text>(find.text('暂无素材')).style!.fontSize, 16);
    final desc = tester.widget<Text>(find.text('上传第一个素材开始')).style!;
    expect(desc.fontSize, 13.5);
    expect(desc.height, 1.6);
    expect(desc.color, tk.ink3);
  });

  testWidgets('actionLabel/onAction:渲染 42 高主操作,点击回调', (tester) async {
    var taps = 0;
    await host(
      tester,
      EmptyState(message: '暂无素材', actionLabel: '上传素材', onAction: () => taps++),
    );
    expect(find.text('上传素材'), findsOneWidget);
    final btn = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(
      btn.style?.minimumSize?.resolve({})?.height,
      42,
      reason: '主操作 42 高(视觉高;Material 可点区另含 48 tap target)',
    );
    await tester.tap(find.text('上传素材'));
    expect(taps, 1);
  });

  testWidgets('无 actionLabel 不渲染按钮', (tester) async {
    await host(tester, const EmptyState(message: '空'));
    expect(find.byType(FilledButton), findsNothing);
  });
}
