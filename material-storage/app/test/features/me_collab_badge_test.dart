/// B7 badge/红点驱动单测(墨金 WP2 更新):我的 tab 角标=unreadPoller.
/// unreadCount(0 不渲染)/我的页「通知」入口金点同步;传输格角标不受影响。
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
  testWidgets('我的 tab 角标=通知全局未读数;0 时角标消失', (tester) async {
    final poller = UnreadPoller(sessionOverride: Session());
    poller.unreadCount = 3;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: const SizedBox.shrink(),
          bottomNavigationBar: AppTabBar(
            index: 0,
            onChanged: (_) {},
            poller: poller,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const Key('tab_badge_3')),
        matching: find.text('3'),
      ),
      findsOneWidget,
      reason: 'badge=通知全局未读数',
    );

    poller.unreadCount = 0;
    await tester.pump();
    expect(find.byKey(const Key('tab_badge_3')), findsNothing);
    expect(
      find.byKey(const Key('tab_badge_2')),
      findsNothing,
      reason: '未读归零后我的格角标消失(传输 0 running 不可见)',
    );
  });

  testWidgets('我的页「通知」入口金点:unread>0 存在,归零消失', (tester) async {
    final poller = UnreadPoller(sessionOverride: Session());
    poller.unreadCount = 2;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: NotificationsTile(poller: poller)),
      ),
    );
    await tester.pump();
    expect(find.text('通知'), findsOneWidget);
    // 金点=8px 圆 Container;未读>0 存在
    final dot = find.byWidgetPredicate(
      (w) => w is Container && w.constraints?.maxWidth == 8.0,
    );
    expect(dot, findsOneWidget);

    poller.unreadCount = 0;
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (w) => w is Container && w.constraints?.maxWidth == 8.0,
      ),
      findsNothing,
      reason: '金点即时更新(mark-read 同步)',
    );
  });

  testWidgets('传输格角标与我的格角标互不干扰', (tester) async {
    final poller = UnreadPoller(sessionOverride: Session());
    poller.unreadCount = 1;
    final q = TransferQueue();
    final hold = Completer<void>();
    q.enqueue(
      TransferRequest(
        kind: TransferKind.upload,
        filename: 'x',
        where: 'p/f',
        totalBytes: 10,
        worker: (p, token) async {
          p(1);
          await hold.future; // 挂起保 running=1
        },
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: const SizedBox.shrink(),
          bottomNavigationBar: AppTabBar(
            index: 0,
            onChanged: (_) {},
            queue: q,
            poller: poller,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.byKey(const Key('tab_badge_2')),
      findsOneWidget,
      reason: '传输 running=1',
    );
    expect(
      find.byKey(const Key('tab_badge_3')),
      findsOneWidget,
      reason: '通知未读=1',
    );
    expect(find.text('1'), findsNWidgets(2));
    hold.complete();
    await tester.pumpAndSettle();
  });
}
