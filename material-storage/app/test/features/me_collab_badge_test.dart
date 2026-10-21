/// B7 badge/红点驱动单测:我的 tab badge=unreadPoller.unreadCount(0 不渲染)
/// /我的页「通知」入口红点同步;传输格 badge 不受影响(回归锚)。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/polling_controller.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/core/transfers/transfer_queue.dart';
import 'package:ms_app/core/transfers/transfer_task.dart';
import 'package:ms_app/features/me/collab_tiles.dart';
import 'package:ms_app/features/shell/tab_bar.dart';

void main() {
  testWidgets('我的 tab badge=通知全局未读数;0 时连 Badge 一并不渲染',
      (tester) async {
    final poller = UnreadPoller(sessionOverride: Session());
    poller.unreadCount = 3;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: const SizedBox.shrink(),
        bottomNavigationBar: AppTabBar(
            index: 0, onChanged: (_) {}, poller: poller),
      ),
    ));
    await tester.pump();
    expect(find.descendant(
        of: find.byType(Badge), matching: find.text('3')), findsOneWidget,
        reason: 'badge=通知全局未读数');

    poller.unreadCount = 0;
    await tester.pump();
    expect(find.descendant(
        of: find.byType(Badge), matching: find.text('0')), findsNothing);
    expect(
        tester.widgetList<Badge>(find.byType(Badge)).toList()
            .where((b) => b.isLabelVisible),
        isEmpty,
        reason: '未读归零后我的格 badge 消失(传输 0 running 不可见)');
  });

  testWidgets('我的页「通知」入口红点:unread>0 显橙点,归零消失', (tester) async {
    final poller = UnreadPoller(sessionOverride: Session());
    poller.unreadCount = 2;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NotificationsTile(poller: poller))));
    await tester.pump();
    expect(find.text('通知'), findsOneWidget);
    // 橙点=8px 圆 Container(accent 色);未读>0 存在
    final dot = find.byWidgetPredicate(
        (w) => w is Container && w.constraints?.maxWidth == 8.0);
    expect(dot, findsOneWidget);

    poller.unreadCount = 0;
    await tester.pump();
    expect(find.byWidgetPredicate(
        (w) => w is Container && w.constraints?.maxWidth == 8.0),
        findsNothing, reason: '红点即时更新(mark-read 同步)');
  });

  testWidgets('传输格 badge 与我的格 badge 互不干扰(同一 NavigationBar 双 badge)',
      (tester) async {
    final poller = UnreadPoller(sessionOverride: Session());
    poller.unreadCount = 1;
    final q = TransferQueue();
    final hold = Completer<void>();
    q.enqueue(TransferRequest(
      kind: TransferKind.upload,
      filename: 'x',
      where: 'p/f',
      totalBytes: 10,
      worker: (p, token) async {
        p(1);
        await hold.future; // 挂起保 running=1
      },
    ));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: const SizedBox.shrink(),
        bottomNavigationBar: AppTabBar(
            index: 0, onChanged: (_) {}, queue: q, poller: poller),
      ),
    ));
    await tester.pump();
    expect(find.descendant(
        of: find.byType(Badge), matching: find.text('1')), findsNWidgets(2),
        reason: '传输 running=1 + 通知未读=1 各一个 badge');
    hold.complete();
    await tester.pumpAndSettle();
  });
}
