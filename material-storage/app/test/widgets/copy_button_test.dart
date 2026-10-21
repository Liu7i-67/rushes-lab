/// CopyButton 单测(mobile-ux-polish-2 批 R1):
/// - 点击写剪贴板 + 图标 copy_outlined → check(Tk 绿)就地反馈;
/// - 反馈窗口期禁点(按钮置禁用),1.5s 后回切恢复可点;
/// - 失败(剪贴板通道抛错)保持原图标、不崩溃,onResult(false) 回调;
/// - 带 label 变体(FilledButton.icon,分享 sheet「复制链接」同位)。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/theme/tokens.dart';
import 'package:ms_app/widgets/copy_button.dart';

void main() {
  late String? clipboard;
  Object? clipboardError;

  void mockClipboard(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        if (clipboardError != null) throw clipboardError!;
        clipboard = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
  }

  IconButton copyIconOf(WidgetTester tester) =>
      tester.widget<IconButton>(find.byType(IconButton));

  testWidgets('成功:写剪贴板 + 图标变 ✓(Tk 绿)且禁点,1.5s 回切恢复',
      (tester) async {
    clipboard = null;
    clipboardError = null;
    mockClipboard(tester);

    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: CopyButton(text: 'secret-123'))));

    expect(copyIconOf(tester).icon, isA<Icon>());
    expect((copyIconOf(tester).icon as Icon).icon, Icons.copy_outlined);

    await tester.tap(find.byType(IconButton));
    await tester.pump();
    expect(clipboard, 'secret-123');
    // 反馈期:图标 ✓ 绿色 + 按钮禁用(防重复点击)
    final successIcon = copyIconOf(tester).icon as Icon;
    expect(successIcon.icon, Icons.check);
    expect(successIcon.color, Tk.green);
    expect(copyIconOf(tester).onPressed, isNull);
    // 期间再点:按钮已禁用,剪贴板不重复写
    await tester.tap(find.byType(IconButton), warnIfMissed: false);
    await tester.pump();
    expect(clipboard, 'secret-123');

    await tester.pump(const Duration(milliseconds: 1600));
    expect((copyIconOf(tester).icon as Icon).icon, Icons.copy_outlined);
    expect(copyIconOf(tester).onPressed, isNotNull, reason: '回切后恢复可点');
  });

  testWidgets('失败:通道抛错 → 保持原图标、按钮仍可重试,onResult(false)',
      (tester) async {
    clipboard = null;
    clipboardError = PlatformException(code: 'channel-error');
    mockClipboard(tester);
    final results = <bool>[];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CopyButton(text: 'x', tooltip: '复制密码', onResult: results.add),
      ),
    ));

    await tester.tap(find.byType(IconButton));
    await tester.pump();
    expect(clipboard, isNull);
    expect(results, [false], reason: '失败结果回调给调用方(降级 UI 接线)');
    // 失败不进反馈态:保持原 copy_outlined 且立即可重试
    expect((copyIconOf(tester).icon as Icon).icon, Icons.copy_outlined);
    expect(copyIconOf(tester).onPressed, isNotNull);

    // 恢复后重试成功 → 正常进 ✓ 反馈
    clipboardError = null;
    await tester.tap(find.byType(IconButton));
    await tester.pump();
    expect((copyIconOf(tester).icon as Icon).icon, Icons.check);
  });

  testWidgets('带 label 变体:FilledButton.icon 同位替换(分享 sheet)',
      (tester) async {
    clipboard = null;
    clipboardError = null;
    mockClipboard(tester);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: CopyButton(text: 'https://ms.test/s/tok', label: '复制链接'),
      ),
    ));
    expect(find.text('复制链接'), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);

    await tester.tap(find.text('复制链接'));
    await tester.pump();
    expect(clipboard, 'https://ms.test/s/tok');
    final btn =
        tester.widget<FilledButton>(find.byType(FilledButton));
    expect(btn.onPressed, isNull, reason: '反馈窗口期禁点');
    expect(
        find.descendant(
            of: find.byType(FilledButton),
            matching: find.byIcon(Icons.check)),
        findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1600));
    expect(
        find.descendant(
            of: find.byType(FilledButton),
            matching: find.byIcon(Icons.copy_outlined)),
        findsOneWidget);
  });
}
