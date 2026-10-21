/// AppTabBar 传输格 badge 单测(B3 测试功能点 6):badge=running 数,
/// 0 running 隐藏。注入 TransferQueue 假 worker。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/transfers/transfer_queue.dart';
import 'package:ms_app/core/transfers/transfer_task.dart';
import 'package:ms_app/features/shell/tab_bar.dart';

void main() {
  testWidgets('badge=running 数(上传+下载混排);归零后隐藏', (tester) async {
    final q = TransferQueue();
    final gates = <String, Completer<void>>{
      'a': Completer<void>(),
      'b': Completer<void>(),
    };
    TransferRequest req(String name, TransferKind kind) => TransferRequest(
          kind: kind,
          filename: name,
          where: '项目/夹',
          totalBytes: 100,
          worker: (p, token) async {
            p(10);
            await gates[name]!.future;
          },
        );
    final a = q.enqueue(req('a', TransferKind.upload));
    final b = q.enqueue(req('b', TransferKind.download));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: const SizedBox.shrink(),
        bottomNavigationBar:
            AppTabBar(index: 0, onChanged: (_) {}, queue: q),
      ),
    ));
    await tester.pump();

    final badge = tester.widget<Badge>(find.byType(Badge));
    expect(badge.isLabelVisible, isTrue);
    expect(find.descendant(
        of: find.byType(Badge), matching: find.text('2')), findsOneWidget,
        reason: 'badge=running 数(上传+下载混排)');

    // 一个完成 → badge 减 1
    gates['a']!.complete();
    await tester.pumpAndSettle();
    expect(q.runningCount, 1);
    expect(find.descendant(
        of: find.byType(Badge), matching: find.text('1')), findsOneWidget);

    // 全部终态 → badge 隐藏
    await q.cancel(b);
    expect(q.byId(a)!.status, TransferStatus.done);
    await tester.pumpAndSettle();
    expect(q.runningCount, 0);
    expect(
      tester.widget<Badge>(find.byType(Badge)).isLabelVisible,
      isFalse,
    );
  });

  testWidgets('无任务 → badge 不渲染', (tester) async {
    final q = TransferQueue();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: const SizedBox.shrink(),
        bottomNavigationBar:
            AppTabBar(index: 0, onChanged: (_) {}, queue: q),
      ),
    ));
    await tester.pump();
    expect(tester.widget<Badge>(find.byType(Badge)).isLabelVisible, isFalse);
  });
}
