/// 传输页单测(B3 测试功能点 6 部分):全部/上传/下载分段过滤、进行中
/// (进度/百分比/取消钮)、终态(重试/移除钮)、清已完成只清终态、空态。
/// 注入 TransferQueue 假 worker,无真实 IO。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/transfers/transfer_queue.dart';
import 'package:ms_app/core/transfers/transfer_task.dart';
import 'package:ms_app/features/transfers/transfers_page.dart';

void main() {
  testWidgets('分段过滤 + 进行中/终态卡片 + 取消 + 清已完成', (tester) async {
    final q = TransferQueue();
    final gateRun = Completer<void>();
    final gateDl = Completer<void>();
    final gateRetry = Completer<void>();

    Future<String> add(
      String name,
      TransferKind kind,
      int total,
      Completer<void>? gate, {
      Object? throw_,
    }) =>
        Future.value(q.enqueue(TransferRequest(
          kind: kind,
          filename: name,
          where: '项目A/夹B',
          totalBytes: total,
          worker: (p, token) async {
            if (throw_ != null) throw throw_;
            if (gate == null) return; // 立即成功
            p(total * 3 ~/ 10);
            await gate.future;
          },
        )));

    await add('r1.mov', TransferKind.upload, 100, gateRun);
    await add('f1.bin', TransferKind.upload, 100, null,
        throw_: StateError('网络断开'));
    await add('d1.livp', TransferKind.upload, 100, null); // done
    await add('r2.livp', TransferKind.download, 200, gateDl); // 60% 进度
    // 立即成败的 worker 经微任务收尾,pump 一并刷出
    await tester.pump();

    await tester.pumpWidget(MaterialApp(home: TransfersPage(queue: q)));
    await tester.pump();

    // ── 全部分段:4 张卡都在 ──
    expect(find.text('r1.mov'), findsOneWidget);
    expect(find.text('f1.bin'), findsOneWidget);
    expect(find.text('d1.livp'), findsOneWidget);
    expect(find.text('r2.livp'), findsOneWidget);
    // r2(60B/200B)与 r1(30B/100B)同为 30%,精确匹配整行区分
    expect(find.text('30% · 30 B/100 B'), findsOneWidget,
        reason: '进行中显示百分比(r1 30/100)');
    expect(find.text('30% · 60 B/200 B'), findsOneWidget,
        reason: '下载 running 卡同样有进度行');
    expect(find.byType(LinearProgressIndicator),
        findsNWidgets(2), reason: '两个 running 卡各一条进度条');
    expect(find.byTooltip('取消'), findsNWidgets(2));
    expect(find.byTooltip('重试(从头重传)'), findsOneWidget,
        reason: '仅 failed 提供重试(done 重传必撞同名 409)');
    expect(find.byTooltip('移除'), findsNWidgets(2),
        reason: '终态卡(failed+done)各一个移除钮');

    // ── 上传分段:下载卡隐藏 ──
    // app-polish E7:分段标签带计数(「上传 3」),tap 改 textContaining 锚定
    await tester.tap(find.textContaining('上传'));
    await tester.pump();
    expect(find.text('r2.livp'), findsNothing);

    // ── 下载分段:只剩下载卡 ──
    await tester.tap(find.textContaining('下载'));
    await tester.pump();
    expect(find.text('r2.livp'), findsOneWidget);
    expect(find.text('r1.mov'), findsNothing);

    // ── 回全部,取消一个 running:queue 状态随之变(卡片钮→队列接线)──
    // app-polish E7:取消走 danger 确认(showAppConfirm)后再入队
    await tester.tap(find.textContaining('全部'));
    await tester.pump();
    final beforeRunning = q.runningCount;
    await tester.tap(find.byTooltip('取消').first);
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget,
        reason: 'E7:取消带确认层');
    await tester.tap(find.widgetWithText(FilledButton, '取消任务'));
    await tester.pump();
    expect(q.runningCount, beforeRunning - 1);
    expect(q.tasks.where((t) => t.status == TransferStatus.canceled).length, 1);

    // ── 重试:从头重新入队(旧 id 移除,新任务进列表)──
    // 取消后有 2 张可重试卡(failed+canceled),定位到 f1 卡内重试钮
    final oldFailed =
        q.tasks.firstWhere((t) => t.status == TransferStatus.failed);
    final f1Card = find.ancestor(
        of: find.text(oldFailed.filename), matching: find.byType(ListTile));
    await tester.tap(find.descendant(
        of: f1Card, matching: find.byTooltip('重试(从头重传)')));
    await tester.pump();
    expect(q.byId(oldFailed.id), isNull, reason: '旧任务移出');
    final retried =
        q.tasks.firstWhere((t) => t.filename == oldFailed.filename);
    expect(retried.id, isNot(oldFailed.id));
    expect(retried.doneBytes, 0, reason: '重试无断点续传');

    // ── 清已完成:只清终态,running/queued 保留 ──
    await tester.tap(find.text('清已完成'));
    await tester.pump();
    expect(q.tasks.any((t) => t.status == TransferStatus.done), isFalse);
    expect(q.tasks.any((t) => t.status == TransferStatus.failed), isFalse);
    expect(q.tasks
        .any((t) => !t.status.isTerminal), isTrue, reason: '活动任务保留');

    // 收尾:放行挂起的 worker
    gateRun.complete();
    gateDl.complete();
    gateRetry.complete();
    await tester.pump();
  });

  testWidgets('空队列 → 空态;清已完成无终态时禁用', (tester) async {
    final q = TransferQueue();
    await tester.pumpWidget(MaterialApp(home: TransfersPage(queue: q)));
    await tester.pump();
    expect(find.text('暂无传输任务'), findsOneWidget);
    final clear = tester.widget<TextButton>(
        find.ancestor(
            of: find.text('清已完成'), matching: find.byType(TextButton)));
    expect(clear.onPressed, isNull, reason: '无终态任务时不可点');
  });
}
