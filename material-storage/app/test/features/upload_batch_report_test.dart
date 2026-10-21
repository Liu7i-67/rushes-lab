/// D6 上传跳过明细接线用例(app-polish D6;upload_pick.dart 交付批):
/// 两路汇总位已从 `toast(context, batchSummary(...))` 接到
/// `enqueueNamedBatchAndReport`(带名收集 [enqueueBatchNamed] + [showUploadBatchToast]
/// 汇总)。本文件直打该接线缝:
/// - 有跳过 → toast 报双数带「查看」action → 点开跳过清单 sheet(文件名+原因,
///   标题带目标文件夹名);
/// - 无跳过 → success 纯报数,无「查看」。
/// 套路:testWidgets + MaterialApp 泵按钮触发,同 upload_sheet_test.dart 既有
/// 形状(widget 测试不落真实 socket)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/features/assets/upload_pick.dart';

void main() {
  Future<void> pumpTrigger(WidgetTester tester,
      Future<void> Function(BuildContext ctx) onTap) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => onTap(ctx),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ));
  }

  testWidgets('D6:有跳过 → toast 带「查看」,点开显示跳过清单(文件名+原因+目标夹名)',
      (tester) async {
    await pumpTrigger(tester, (ctx) {
      return enqueueNamedBatchAndReport(
        ctx,
        where: '项目A/档案夹',
        items: [
          // 语义同生产闭包:单点失败抛错只跳过,不中断后续项
          ('好图.jpg', () async {}),
          ('坏图.png', () async => throw StateError('iCloud 未下载')),
          ('后图.mov', () async {}),
        ],
      );
    });
    await tester.tap(find.text('go'));
    await tester.pump();
    expect(find.text('已入队 2 个,跳过 1 个'), findsOneWidget,
        reason: 'D6:汇总口径与原 batchSummary 一致(入队数/跳过数不变)');
    // 等 SnackBar 滑入动画落定再点 action(3s 自动收起前,400ms 足够)
    await tester.pump(const Duration(milliseconds: 400));

    // toast「查看」action → 跳过清单 sheet
    await tester.tap(find.text('查看'));
    await tester.pumpAndSettle();
    expect(find.text('跳过的文件 · 档案夹'), findsOneWidget,
        reason: 'D6:清单标题带目标文件夹名(where 末段)');
    expect(find.text('坏图.png'), findsOneWidget, reason: 'D6:清单显示文件名');
    // StateError 非 ApiException → errorMessage 落中文兜底,不直出异常原文
    expect(find.text('无法读取该文件,已跳过'), findsOneWidget,
        reason: 'D6:原因经 errorMessage 中文兜底');
    // 收尾:排空 toast/sheet 计时器
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('D6:无跳过 → success 纯报数,无「查看」action', (tester) async {
    await pumpTrigger(tester, (ctx) {
      return enqueueNamedBatchAndReport(
        ctx,
        where: '项目A/档案夹',
        items: [('a.jpg', () async {})],
      );
    });
    await tester.tap(find.text('go'));
    await tester.pump();
    expect(find.text('已入队 1 个'), findsOneWidget);
    expect(find.text('查看'), findsNothing, reason: 'D6:无跳过不挂「查看」');
    // 收尾:排空 SnackBar 计时器
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}
