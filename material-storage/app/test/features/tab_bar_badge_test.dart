/// AppTabBar 自绘四格单测(WP2 §6 F4):传输/通知两类金胶囊角标独立计数、
/// 0 隐藏;选中金点、标签颜色与 Semantics(selected)语义。
library;

import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/polling_controller.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/core/transfers/transfer_queue.dart';
import 'package:ms_app/core/transfers/transfer_task.dart';
import 'package:ms_app/features/shell/home_shell.dart';
import 'package:ms_app/features/shell/tab_bar.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/theme/app_theme.dart';
import 'package:ms_app/theme/tk_colors.dart';

import '../helpers/api_harness.dart';

Widget _bar(Widget bar) => MaterialApp(
  theme: buildAppTheme(Brightness.dark),
  home: Scaffold(body: const SizedBox.shrink(), bottomNavigationBar: bar),
);

void main() {
  testWidgets('传输格角标=running 数(上传+下载混排);归零后隐藏', (tester) async {
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

    await tester.pumpWidget(
      _bar(AppTabBar(index: 0, onChanged: (_) {}, queue: q)),
    );
    await tester.pump();

    expect(find.byKey(const Key('tab_badge_2')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('tab_badge_2')),
        matching: find.text('2'),
      ),
      findsOneWidget,
      reason: 'badge=running 数(上传+下载混排)',
    );

    gates['a']!.complete();
    await tester.pumpAndSettle();
    expect(q.runningCount, 1);
    expect(
      find.descendant(
        of: find.byKey(const Key('tab_badge_2')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );

    await q.cancel(b);
    expect(q.byId(a)!.status, TransferStatus.done);
    await tester.pumpAndSettle();
    expect(q.runningCount, 0);
    expect(find.byKey(const Key('tab_badge_2')), findsNothing);
  });

  testWidgets('无任务 → 传输角标不渲染', (tester) async {
    final q = TransferQueue();
    await tester.pumpWidget(
      _bar(AppTabBar(index: 0, onChanged: (_) {}, queue: q)),
    );
    await tester.pump();
    expect(find.byKey(const Key('tab_badge_2')), findsNothing);
  });

  testWidgets('我的格角标=通知全局未读数;0 时消失', (tester) async {
    final poller = UnreadPoller(sessionOverride: Session());
    poller.unreadCount = 3;
    await tester.pumpWidget(
      _bar(AppTabBar(index: 0, onChanged: (_) {}, poller: poller)),
    );
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const Key('tab_badge_3')),
        matching: find.text('3'),
      ),
      findsOneWidget,
    );

    poller.unreadCount = 0;
    await tester.pump();
    expect(find.byKey(const Key('tab_badge_3')), findsNothing);
  });

  testWidgets('传输与通知角标互不干扰(两个独立金胶囊)', (tester) async {
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
          await hold.future;
        },
      ),
    );
    await tester.pumpWidget(
      _bar(AppTabBar(index: 0, onChanged: (_) {}, queue: q, poller: poller)),
    );
    await tester.pump();
    expect(find.byKey(const Key('tab_badge_2')), findsOneWidget);
    expect(find.byKey(const Key('tab_badge_3')), findsOneWidget);
    expect(find.text('1'), findsNWidgets(2));
    hold.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('选中格:金点 4×4 + tabFgActive + Semantics(selected);点击回调', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var tapped = -1;
    await tester.pumpWidget(
      _bar(AppTabBar(index: 1, onChanged: (i) => tapped = i)),
    );
    await tester.pump();

    // 选中格金点;未选中格无
    expect(find.byKey(const Key('tab_dot_1')), findsOneWidget);
    expect(find.byKey(const Key('tab_dot_0')), findsNothing);
    final dot = tester.widget<Container>(find.byKey(const Key('tab_dot_1')));
    expect((dot.decoration! as BoxDecoration).color, TkColors.dark.goldBright);

    // 选中标签提亮
    final label = tester.widget<Text>(find.text('搜索'));
    expect(label.style?.color, TkColors.dark.tabFgActive);

    // Semantics:selected 仅选中格
    final selected = tester.getSemantics(find.byKey(const Key('tab_1')));
    final idle = tester.getSemantics(find.byKey(const Key('tab_0')));
    expect(
      selected.getSemanticsData().flagsCollection.isSelected,
      Tristate.isTrue,
    );
    expect(
      idle.getSemanticsData().flagsCollection.isSelected,
      isNot(Tristate.isTrue),
    );
    expect(selected.getSemanticsData().label, contains('搜索'));

    await tester.tap(find.byKey(const Key('tab_2')));
    await tester.pump();
    expect(tapped, 2);
    handle.dispose();
  });

  testWidgets('壳层冒烟:320×640 明暗双主题四 tab 渲染无 overflow,tab 可切换', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = installFakeApi();
    api.projects.listStaged = [
      Project(id: 'p1', name: '皮肤科素材', code: 'SKIN', myRoles: ['admin']),
    ];
    session.me = Me(id: 'u1', name: '甲', isProjectCreator: true);
    addTearDown(() {
      session.api = null;
      session.me = null;
    });

    for (final brightness in [Brightness.dark, Brightness.light]) {
      await tester.pumpWidget(
        MaterialApp(theme: buildAppTheme(brightness), home: const HomeShell()),
      );
      await tester.pump();
      await tester.pump();
      expect(
        tester.takeException(),
        isNull,
        reason: '$brightness 项目 tab 无 overflow',
      );

      for (var i = 1; i < 4; i++) {
        await tester.tap(find.byKey(Key('tab_$i')));
        await tester.pump();
        expect(
          tester.takeException(),
          isNull,
          reason: '$brightness tab $i 无 overflow',
        );
      }
      expect(find.byKey(const Key('tab_3')), findsOneWidget);
    }
  });
}
