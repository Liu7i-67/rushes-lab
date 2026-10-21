/// 通知中心单测(B7 测试功能点 2 部分 + 功能点 5):列表+未读橙点/全部已读
/// /kind 白名单跳转三分支(approval→审批中心;folder_invite→对应项目文件夹;
/// 未知 kind 通用详情不崩溃、不把任意 URL 交导航器)/点击标已读+红点即时联动。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/polling_controller.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/notifications/notifications_page.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

void main() {
  testWidgets('列表:未读行+kind chip;全部已读调 mark-read all 且按钮消失',
      (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    api.notifications.listStaged = NotificationsList(
      items: [
        notificationOf('n1'),
        notificationOf('n2', kind: 'approval_decided', unread: false),
      ],
      total: 2,
      unreadCount: 1,
    );

    await tester.pumpWidget(const MaterialApp(home: NotificationsPage()));
    await tester.pumpAndSettle();

    expect(find.text('标题n1'), findsOneWidget);
    expect(find.text('审批待办'), findsOneWidget);
    expect(find.text('审批结果'), findsOneWidget);
    expect(find.text('全部已读'), findsOneWidget);

    await tester.tap(find.text('全部已读'));
    await tester.pumpAndSettle();
    expect(api.notifications.markReadCalls.single.all, isTrue);
    // 重拉后 unread_count=0 → 全部已读入口消失
    expect(find.text('全部已读'), findsNothing);
  });

  testWidgets('白名单 approval_*:点击跳审批中心并标已读(红点即时减一)',
      (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    api.notifications.listStaged = NotificationsList(
      items: [notificationOf('n1')],
      total: 1,
      unreadCount: 1,
    );
    final poller = UnreadPoller(sessionOverride: Session(), api: api);
    poller.unreadCount = 1; // 模拟全局 badge 现值(我的 tab 红点同源)

    await tester.pumpWidget(MaterialApp(
      home: NotificationsPage(poller: poller),
      routes: {
        '/approvals': (_) => Scaffold(
            appBar: AppBar(title: const Text('审批中心T'))),
      },
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('标题n1'));
    await tester.pumpAndSettle();
    expect(find.text('审批中心T'), findsOneWidget, reason: '审批类跳审批中心');
    expect(api.notifications.markReadCalls.single.ids, ['n1']);
    expect(poller.unreadCount, 0, reason: 'mark-read 成功红点即时更新');
  });

  testWidgets('mark-read 成功后行内未读样式即时消除(P2-1:原地替换,不等重拉)',
      (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    api.notifications.listStaged = NotificationsList(
      items: [notificationOf('n1')],
      total: 1,
      unreadCount: 1,
    );
    final poller = UnreadPoller(sessionOverride: Session(), api: api);
    poller.unreadCount = 1;

    await tester.pumpWidget(MaterialApp(
      home: NotificationsPage(poller: poller),
      routes: {
        '/approvals': (_) => const Scaffold(body: Text('审批中心T')),
      },
    ));
    await tester.pumpAndSettle();

    // 未读样式基线:标题加粗 + 页内未读数=1(全部已读入口在)
    expect(tester.widget<Text>(find.text('标题n1')).style?.fontWeight,
        FontWeight.w600);
    expect(find.text('全部已读'), findsOneWidget);

    await tester.tap(find.text('标题n1'));
    await tester.pumpAndSettle();

    // 页面被推入的审批路由盖住(offstage),skipOffstage 命中原列表结构
    expect(
      tester
          .widget<Text>(find.text('标题n1', skipOffstage: false))
          .style
          ?.fontWeight,
      FontWeight.w400,
      reason: '行内未读样式即时消除(原地替换 readAt,无重拉也不复原)',
    );
    expect(find.text('全部已读', skipOffstage: false), findsNothing,
        reason: '页内未读清零,全部已读入口即时消失');
    expect(poller.unreadCount, 0, reason: '全局红点同步减一');
  });

  testWidgets('白名单 folder_invite:link 解析+/projects 反查成功 → 跳对应文件夹页',
      (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    api.notifications.listStaged = NotificationsList(
      items: [
        notificationOf('n1',
            kind: 'folder_invite',
            link: 'https://bucket.taoxiplan.com/ms-static/web/projects/p1/folders/f1'),
      ],
      total: 1,
      unreadCount: 1,
    );
    api.projects.listStaged = [
      Project(id: 'p1', name: '项目一', code: 'P1', myRoles: const ['viewer']),
    ];
    Object? foldersArgs;
    await tester.pumpWidget(MaterialApp(
      onGenerateRoute: (s) {
        if (s.name == '/folders') foldersArgs = s.arguments;
        return MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('FoldersT')));
      },
      home: const NotificationsPage(),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('标题n1'));
    await tester.pumpAndSettle();
    expect(foldersArgs, ('p1', '项目一', const <String>['viewer']),
        reason: '跳对应项目/文件夹(名/角色经 /projects 反查)');
    expect(find.text('FoldersT'), findsOneWidget);
  });

  testWidgets('folder_invite 反查失败(link 缺失/项目不可见)→ 通用详情不盲跳',
      (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    api.notifications.listStaged = NotificationsList(
      items: [notificationOf('n1', kind: 'folder_invite')],
      total: 1,
      unreadCount: 1,
    );
    Object? foldersArgs;
    await tester.pumpWidget(MaterialApp(
      onGenerateRoute: (s) {
        if (s.name == '/folders') foldersArgs = s.arguments;
        return MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('FoldersT')));
      },
      home: const NotificationsPage(),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标题n1'));
    await tester.pumpAndSettle();
    expect(foldersArgs, isNull, reason: '无可跳转字段不盲跳');
    expect(find.text('FoldersT'), findsNothing);
    expect(find.byType(AlertDialog), findsOneWidget, reason: '落通用详情');
  });

  testWidgets('未知 kind:通用详情弹窗,不崩溃、不把任意 URL 交导航器',
      (tester) async {
    final api = installFakeApi();
    addTearDown(() => session.api = null);
    api.notifications.listStaged = NotificationsList(
      items: [
        notificationOf('n1', kind: 'share', link: 'https://evil.example/x'),
      ],
      total: 1,
      unreadCount: 1,
    );
    var navigated = false;
    await tester.pumpWidget(MaterialApp(
      onGenerateRoute: (s) {
        navigated = true;
        return MaterialPageRoute(builder: (_) => const SizedBox());
      },
      home: const NotificationsPage(),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标题n1'));
    await tester.pumpAndSettle();
    expect(navigated, isFalse, reason: '白名单外不导航');
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('正文n1')),
        findsOneWidget);
  });
}
