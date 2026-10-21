/// R1(mobile-ux-polish-2)modal 态复制就地反馈单测(替换点集成面):
/// 根因=temp_password/artist_account 等复制点处于 showModalBottomSheet 内,
/// 成功 SnackBar 渲染在页面底部被弹层遮挡,用户零感知。目标行为:复制成功=
/// CopyButton 图标 copy_outlined→check 就地反馈(约 1.5s 回切,期间防重复
/// 点击),不再依赖 SnackBar。
/// 分工(dev 落地用例之外的本文件覆盖面):
/// - 组件级行为(图标切换/回切/防连点/失败路径/label 变体)由 dev 落地的
///   test/widgets/copy_button_test.dart 钉死,不重复;
/// - share_create_sheet 替换点(成功就地 ✓/失败降级保留)由 dev 更新的
///   test/features/share_create_sheet_test.dart 钉死,不重复;
/// - 本文件钉 temp_password_sheet 与 ArtistResultView(艺人账号面板,新建
///   项目 sheet 内嵌)两处替换点:复制功能不回退 + 就地反馈 + 无遮挡 SnackBar;
/// - 页面级复制点不变(bind_code SnackBar / request_link 结果视图承载)由一期
///   既有用例钉死(bind_code_page_test / request_link_sheet_test)。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/features/admin/temp_password_sheet.dart';
import 'package:ms_app/features/projects/artist_account_field.dart';

/// 剪贴板桩:记录 setData 文本。返回 tearDown 清桩函数。
VoidCallback stubClipboard(List<String> writes) {
  final binding = TestWidgetsFlutterBinding.instance;
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      writes.add((call.arguments as Map<Object?, Object?>)['text'] as String);
    }
    return null;
  });
  return () => binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null);
}

Future<void> pumpSheetOpener(
  WidgetTester tester,
  Future<void> Function(BuildContext) open,
) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (ctx) => Center(
          child: FilledButton(
            onPressed: () => open(ctx),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('temp_password_sheet(R1 替换点①:临时密码)', () {
    testWidgets('复制成功:图标 copy_outlined→check 就地反馈,无 SnackBar',
        (tester) async {
      final writes = <String>[];
      addTearDown(stubClipboard(writes));
      await pumpSheetOpener(
          tester, (ctx) => showTempPasswordSheet(ctx, password: 'pw-1234'));

      // sheet 内唯一复制钮(CopyButton 默认 IconButton 形态)
      final copyButton = find.byType(IconButton);
      expect(copyButton, findsOneWidget);
      expect(find.byIcon(Icons.copy_outlined), findsOneWidget);

      await tester.tap(copyButton);
      await tester.pump();
      expect(writes, ['pw-1234'], reason: '复制功能不回退:密码进剪贴板');
      expect(find.byIcon(Icons.check), findsOneWidget,
          reason: 'R1:就地反馈=图标变 ✓(modal 态 SnackBar 不可见)');
      expect(find.text('已复制'), findsNothing,
          reason: 'R1:成功反馈不再用被弹层遮挡的 SnackBar');
    });

    testWidgets('回切:约 1.5s 后图标还原 copy_outlined,可再次复制',
        (tester) async {
      final writes = <String>[];
      addTearDown(stubClipboard(writes));
      await pumpSheetOpener(
          tester, (ctx) => showTempPasswordSheet(ctx, password: 'pw-1234'));

      await tester.tap(find.byType(IconButton));
      await tester.pump();
      expect(find.byIcon(Icons.check), findsOneWidget);

      await tester.pump(const Duration(seconds: 2));
      expect(find.byIcon(Icons.check), findsNothing,
          reason: '反馈自动回切(kCopyFeedbackDuration=1.5s)');
      expect(find.byIcon(Icons.copy_outlined), findsOneWidget);

      await tester.tap(find.byType(IconButton));
      await tester.pump();
      expect(writes, ['pw-1234', 'pw-1234'], reason: '回切后可再次复制');
    });

    testWidgets('反馈期间防重复点击:✓ 态再点不再写剪贴板', (tester) async {
      final writes = <String>[];
      addTearDown(stubClipboard(writes));
      await pumpSheetOpener(
          tester, (ctx) => showTempPasswordSheet(ctx, password: 'pw-1234'));

      await tester.tap(find.byType(IconButton));
      await tester.pump();
      await tester.tap(find.byType(IconButton), warnIfMissed: false);
      await tester.pump();
      expect(writes, ['pw-1234'],
          reason: 'R1:反馈期间按钮置禁用(只写一次剪贴板)');
    });
  });

  group('ArtistResultView(R1 替换点②:艺人账号面板,新建项目 sheet 内嵌)', () {
    Future<void> pumpResult(WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ArtistResultView(
            username: 'artist01',
            name: '张三',
            password: 'pw-9i',
            onFinish: _noop,
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('复制登录名:图标就地变 ✓,无「登录名已复制」SnackBar',
        (tester) async {
      final writes = <String>[];
      addTearDown(stubClipboard(writes));
      await pumpResult(tester);

      await tester.tap(find.byTooltip('复制登录名'));
      await tester.pump();
      expect(writes, ['artist01'], reason: '复制功能不回退:登录名进剪贴板');
      expect(find.byIcon(Icons.check), findsOneWidget,
          reason: 'R1:就地反馈(面板处于新建项目 modal 内,SnackBar 不可见)');
      expect(find.text('登录名已复制'), findsNothing);
      expect(find.byIcon(Icons.copy_outlined), findsOneWidget,
          reason: '「复制初始密码」行不受影响(仍 copy 态)');
    });

    testWidgets('复制初始密码:图标就地变 ✓;回切后可再复制', (tester) async {
      final writes = <String>[];
      addTearDown(stubClipboard(writes));
      await pumpResult(tester);

      await tester.tap(find.byTooltip('复制初始密码'));
      await tester.pump();
      expect(writes, ['pw-9i']);
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.text('初始密码已复制'), findsNothing);

      await tester.pump(const Duration(seconds: 2));
      expect(find.byIcon(Icons.check), findsNothing, reason: '反馈回切');
      await tester.tap(find.byTooltip('复制初始密码'));
      await tester.pump();
      expect(writes, ['pw-9i', 'pw-9i'], reason: '回切后可再复制');
    });
  });
}

void _noop() {}
